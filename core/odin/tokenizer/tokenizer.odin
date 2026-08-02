// The tokenizer (lexer) for `Odin` files, used to create tooling.
package odin_tokenizer

import "base:intrinsics"
import "core:fmt"
import "core:unicode"
import "core:unicode/utf8"

Error_Handler :: #type proc(pos: Pos, fmt: string, args: ..any)

Flag :: enum {
	Insert_Semicolon,
}
Flags :: distinct bit_set[Flag; u32]

Tokenizer :: struct {
	// Immutable data
	path: string,
	src:  string,
	err:  Error_Handler,

	flags: Flags,

	// Tokenizing state
	ch:          rune,
	offset:      int,
	read_offset: int,
	line_offset: int,
	line_count:  int,
	insert_semicolon: bool,

	// Mutable data
	error_count: int,
}


Keyword_Hash_Entry :: struct {
	hash: u32,
	kind: Token_Kind,
	name: string,
}

KEYWORD_LUT_LEN  :: 1<<9
KEYWORD_LUT_MASK :: KEYWORD_LUT_LEN-1
Keyword_LUT      :: [KEYWORD_LUT_LEN]Keyword_Hash_Entry

global_keyword_lut: Keyword_LUT // protected by `_global_keyword_lut_spinlock`
_global_keyword_lut_initialized: bool // atomic
_global_keyword_lut_spinlock:    bool // atomic

_global_keyword_spin_lock :: proc() {
	for intrinsics.atomic_exchange_explicit(&_global_keyword_lut_spinlock, true, .Acquire) {
		intrinsics.cpu_relax()
	}
}

_global_keyword_spin_unlock :: proc() {
	intrinsics.atomic_store_explicit(&_global_keyword_lut_spinlock, false, .Release)
}

@(require_results)
keyword_hash :: proc(text: string) -> u32 #no_bounds_check {
	h := u32(0x811c9dc5)
	for i in 0..<len(text) {
		h = (h ~ u32(text[i])) * 0x01000193
	}
	return h
}

keyword_lut_init :: proc(lut: ^Keyword_LUT) -> bool {
	if lut == nil {
		return false
	}

	max_keyword_size := 0

	for kind in (Token_Kind.B_Keyword_Begin+Token_Kind(1))..<Token_Kind.B_Keyword_End {
		name := tokens[kind]

		max_keyword_size = max(max_keyword_size, len(name))

		hash := keyword_hash(name)

		entry := &lut[hash & KEYWORD_LUT_MASK]
		assert(entry.kind == .Invalid, name)
		entry.hash = hash
		entry.kind = kind
		entry.name = name
	}

	assert(max_keyword_size >  1)
	assert(max_keyword_size < 16)

	return true
}


init :: proc(t: ^Tokenizer, src: string, path: string, err: Error_Handler = default_error_handler) {
	t.src = src
	t.err = err
	t.ch = ' '
	t.offset = 0
	t.read_offset = 0
	t.line_offset = 0
	t.line_count = len(src) > 0 ? 1 : 0
	t.insert_semicolon = false
	t.error_count = 0
	t.path = path

	if !intrinsics.atomic_load(&_global_keyword_lut_initialized) {
		_global_keyword_spin_lock()
		// The flag MUST be re-tested here. The load above is only a fast path: two threads
		// reaching `init` for the first time can both observe it as false, and the second
		// one arrives here after the first has already filled the table in. Building the
		// table twice trips `assert(entry.kind == .Invalid, name)` inside
		// keyword_lut_init, and an assertion does not unwind - so the spin lock would
		// never be released and every later tokenizer.init in the process would spin on
		// it forever.
		if !intrinsics.atomic_load(&_global_keyword_lut_initialized) {
			ok := keyword_lut_init(&global_keyword_lut)
			intrinsics.atomic_store(&_global_keyword_lut_initialized, ok)
		}
		_global_keyword_spin_unlock()
	}

	advance_rune(t)
	if t.ch == utf8.RUNE_BOM {
		advance_rune(t)
	}
}

@(private)
offset_to_pos :: proc(t: ^Tokenizer, offset: int) -> Pos {
	line := t.line_count
	column := offset - t.line_offset + 1

	return Pos {
		file = t.path,
		offset = offset,
		line = line,
		column = column,
	}
}

default_error_handler :: proc(pos: Pos, msg: string, args: ..any) {
	fmt.eprintf("%s(%d:%d) ", pos.file, pos.line, pos.column)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

error :: proc(t: ^Tokenizer, offset: int, msg: string, args: ..any) {
	pos := offset_to_pos(t, offset)
	if t.err != nil {
		t.err(pos, msg, ..args)
	}
	t.error_count += 1
}

advance_rune :: proc(t: ^Tokenizer) {
	if t.read_offset < len(t.src) {
		t.offset = t.read_offset
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		r, w := rune(t.src[t.read_offset]), 1
		switch {
		case r == 0:
			error(t, t.offset, "Illegal character NUL")
		case r >= utf8.RUNE_SELF:
			r, w = utf8.decode_rune_in_string(t.src[t.read_offset:])
			if r == utf8.RUNE_ERROR && w == 1 {
				error(t, t.offset, "Illegal UTF-8 encoding")
			} else if r == utf8.RUNE_BOM && t.offset > 0 {
				error(t, t.offset, "Illegal byte order mark")
			}
		}
		t.read_offset += w
		t.ch = r
	} else {
		t.offset = len(t.src)
		if t.ch == '\n' {
			t.line_offset = t.offset
			t.line_count += 1
		}
		t.ch = -1
	}
}

peek_byte :: proc(t: ^Tokenizer, offset := 0) -> byte {
	if t.read_offset+offset < len(t.src) {
		return t.src[t.read_offset+offset]
	}
	return 0
}

skip_whitespace :: proc(t: ^Tokenizer) {
	if t.insert_semicolon {
		for {
			switch t.ch {
			case ' ', '\t', '\r':
				advance_rune(t)
			case:
				return
			}
		}
	} else {
		for {
			switch t.ch {
			case ' ', '\t', '\r', '\n':
				advance_rune(t)
			case:
				return
			}
		}
	}
}

is_letter :: proc(r: rune) -> bool {
	if r < utf8.RUNE_SELF {
		switch r {
		case '_':
			return true
		case 'A'..='Z', 'a'..='z':
			return true
		}
	}
	return unicode.is_letter(r)
}
is_digit :: proc(r: rune) -> bool {
	if '0' <= r && r <= '9' {
		return true
	}
	return unicode.is_digit(r)
}


scan_comment :: proc(t: ^Tokenizer) -> string {
	offset := t.offset-1
	next := -1
	general: {
		if t.ch == '/' || t.ch == '!' { // // #! comments
			advance_rune(t)
			for t.ch != '\n' && t.ch >= 0 {
				advance_rune(t)
			}

			next = t.offset
			if t.ch == '\n' {
				next += 1
			}
			break general
		}

		/* style comment */
		advance_rune(t)
		nest := 1
		for t.ch >= 0 && nest > 0 {
			ch := t.ch
			advance_rune(t)
			if ch == '/' && t.ch == '*' {
				nest += 1
			}

			if ch == '*' && t.ch == '/' {
				nest -= 1
				advance_rune(t)
				next = t.offset
				if nest == 0 {
					break general
				}
			}
		}

		// Current position, not the comment START. Reporting at the start produced a
		// NEGATIVE column -- the offset belongs to an earlier line, so subtracting the
		// final line's line_offset underflows, and an unterminated `/*` printed as
		// "(4:-15)". C++'s one-argument tokenizer_err reports where the scan stopped, and
		// clamps: `if (column < 1) { column = 1; }` (src/tokenizer.cpp:320-323).
		// LEDGER #369.
		error(t, t.offset, "Multi-line comment not terminated")
	}

	lit := t.src[offset : t.offset]

	// NOTE(bill): Strip CR for line comments
	for len(lit) > 2 && lit[1] == '/' && lit[len(lit)-1] == '\r' {
		lit = lit[:len(lit)-1]
	}


	return string(lit)
}

scan_file_tag :: proc(t: ^Tokenizer) -> string {
	offset := t.offset - 1

	for t.ch != '\n' && t.ch != utf8.RUNE_EOF {
		if t.ch == '/' {
			next := peek_byte(t, 0)

			if next == '/' || next == '*' {
				break
			}
		}
		advance_rune(t)
	}

	return string(t.src[offset : t.offset])
}

scan_identifier :: proc(t: ^Tokenizer) -> string {
	offset := t.offset

	for is_letter(t.ch) || is_digit(t.ch) {
		advance_rune(t)
	}

	return string(t.src[offset : t.offset])
}

scan_string :: proc(t: ^Tokenizer) -> string {
	offset := t.offset-1

	for {
		ch := t.ch
		if ch == '\n' || ch < 0 {
			// Current position, not the token start: the one-argument tokenizer_err
			// (src/tokenizer.cpp:318-335) builds its TokenPos from t->line_count and
			// t->column_minus_one, i.e. where the scan stopped. LEDGER #369.
			error(t, t.offset, "String literal not terminated")
			break
		}
		advance_rune(t)
		if ch == '"' {
			break
		}
		if ch == '\\' {
			scan_escape(t)
		}
	}

	return string(t.src[offset : t.offset])
}

scan_raw_string :: proc(t: ^Tokenizer) -> string {
	offset := t.offset-1

	for {
		ch := t.ch
		if ch == utf8.RUNE_EOF {
			// Current position, as above.
			error(t, t.offset, "String literal not terminated")
			break
		}
		advance_rune(t)
		if ch == '`' {
			break
		}
	}

	return string(t.src[offset : t.offset])
}

digit_val :: proc(r: rune) -> int {
	switch r {
	case '0'..='9':
		return int(r-'0')
	case 'A'..='F':
		return int(r-'A' + 10)
	case 'a'..='f':
		return int(r-'a' + 10)
	}
	return 16
}

scan_escape :: proc(t: ^Tokenizer) -> bool {
	offset := t.offset

	n: int
	base, max: u32
	switch t.ch {
	case 'a', 'b', 'e', 'f', 'n', 't', 'v', 'r', '\\', '\'', '\"':
		advance_rune(t)
		return true

	case '0'..='7':
		n, base, max = 3, 8, 255
	case 'x':
		advance_rune(t)
		n, base, max = 2, 16, 255
	case 'u':
		advance_rune(t)
		n, base, max = 4, 16, utf8.MAX_RUNE
	case 'U':
		advance_rune(t)
		n, base, max = 8, 16, utf8.MAX_RUNE
	case:
		if t.ch < 0 {
			error(t, offset, "Escape sequence was not terminated")
		} else {
			error(t, offset, "Unknown escape sequence")
		}
		return false
	}

	x: u32
	for n > 0 {
		d := u32(digit_val(t.ch))
		for d >= base {
			if t.ch < 0 {
				error(t, t.offset, "Escape sequence was not terminated")
			} else {
				error(t, t.offset, "Illegal character %d in escape sequence", t.ch)
			}
			return false
		}

		x = x*base + d
		advance_rune(t)
		n -= 1
	}

	if x > max || 0xd800 <= x && x <= 0xdfff {
		error(t, offset, "escape sequence is an invalid Unicode code point")
		return false
	}
	return true
}

scan_rune :: proc(t: ^Tokenizer) -> string {
	offset := t.offset-1
	valid := true
	n := 0
	for {
		ch := t.ch
		if ch == '\n' || ch < 0 {
			// C++ Reference: src/tokenizer.cpp:765-769. The report is UNCONDITIONAL and does
			// NOT clear `valid`, so an unterminated rune literal draws BOTH this and the
			// length complaint below. The port guarded it with `if valid` and then set
			// valid = false, which suppressed the second diagnostic entirely -- `y := 'ab`
			// gave one error where the oracle gives two. It also reported at the token
			// START; the one-argument tokenizer_err (src/tokenizer.cpp:318-335) reports at
			// the CURRENT position, which is the newline. LEDGER #369.
			error(t, t.offset, "Rune literal not terminated")
			break
		}
		advance_rune(t)
		if ch == '\'' {
			break
		}
		n += 1
		if ch == '\\' {
			if !scan_escape(t)  {
				valid = false
			}
		}
	}

	if valid && n != 1 {
		// This one DOES take the token start, via the two-argument tokenizer_err
		// (src/tokenizer.cpp:337): `tokenizer_err(t, token->pos, "Invalid rune literal")`.
		error(t, offset, "Invalid rune literal")
	}

	return string(t.src[offset : t.offset])
}

// scan_number is a direct port of scan_number_to_token (src/tokenizer.cpp:454-582). Every
// structural difference below was a divergence, verified one literal at a time against the
// oracle before being changed. LEDGER #368.
scan_number :: proc(t: ^Tokenizer, seen_decimal_point: bool) -> (Token_Kind, string) {
	// C++ Reference: src/tokenizer.cpp:437-443.
	//
	//     gb_internal gb_inline void scan_mantissa(Tokenizer *t, i32 base, bool force_base) {
	//         if (!force_base) {
	//             base = 16; // always check for any possible letter
	//         }
	//         while (digit_value(t->curr_rune) < base || t->curr_rune == '_') {
	//             advance_to_next_rune(t);
	//         }
	//     }
	//
	// The force_base parameter did not exist in the port, so every unforced call scanned in
	// its NOMINAL base and stopped at the first out-of-range digit. C++ deliberately widens
	// to 16 so the whole run of letters and digits is swallowed into ONE token and the
	// out-of-range digit is diagnosed later, by the value parser, as "Invalid integer
	// literal". Without it `0d1a` tokenized as `0d1` followed by the identifier `a` and the
	// port reported "Expected ';', got identifier" where C++ reports the literal error.
	scan_mantissa :: proc(t: ^Tokenizer, base: int, force_base: bool) {
		b := base
		if !force_base {
			b = 16 // always check for any possible letter
		}
		for digit_val(t.ch) < b || t.ch == '_' {
			advance_rune(t)
		}
	}
	// C++ Reference: src/tokenizer.cpp:562-577. The exponent body is exactly
	//
	//     advance_to_next_rune(t);
	//     if (t->curr_rune == '-' || t->curr_rune == '+') { advance_to_next_rune(t); }
	//     scan_mantissa(t, 10, false);
	//
	// with NO error arm at all -- and force_base is false, so underscores and letters are
	// consumed. The port required a decimal digit immediately after the 'e' and otherwise
	// emitted "illegal floating-point exponent", a message C++ does not have. That rejected
	// `1e_4`, `1e+_4`, `1e-_4`, `1.5e_3`, `1e` and `1eff`, all of which the oracle accepts
	// silently. An underscore is a digit SEPARATOR everywhere else in a literal; the
	// exponent was the only place the port refused it.
	scan_exponent :: proc(t: ^Tokenizer, kind: ^Token_Kind) {
		if t.ch == 'e' || t.ch == 'E' {
			kind^ = .Float
			advance_rune(t)
			if t.ch == '-' || t.ch == '+' {
				advance_rune(t)
			}
			scan_mantissa(t, 10, false)
		}

		// NOTE(bill): This needs to be here for sanity's sake
		switch t.ch {
		case 'i', 'j', 'k':
			kind^ = .Imag
			advance_rune(t)
		}
	}

	offset := t.offset
	kind := Token_Kind.Integer

	if seen_decimal_point {
		offset -= 1
		kind = .Float
		scan_mantissa(t, 10, true)
		scan_exponent(t, &kind)
		return kind, string(t.src[offset : t.offset])
	}

	if t.ch == '0' {
		// C++ takes `prev` at the '0' ITSELF, before advancing, and tests `curr - prev <= 2`
		// -- i.e. nothing was consumed beyond the two prefix bytes. The port took prev at the
		// base letter and tested `<= 1`, which is the same predicate; it is preserved here in
		// C++'s spelling because the `0h` digit-count slice is measured from the same anchor.
		prev := t.offset
		advance_rune(t)

		// C++ Reference: src/tokenizer.cpp:475-508. Each prefixed base ends in `goto end`,
		// so no fraction, no exponent and no imaginary suffix is scanned after one. The port
		// fell through into scan_mantissa/scan_fraction/scan_exponent instead, so `0x1.5`
		// became a SINGLE float token where C++ produces `0x1` and then `.5` (and reports
		// "Expected ';', got float"), and `0b101e5` became a float where C++ stops at `0b101`.
		int_base :: proc(t: ^Tokenizer, kind: ^Token_Kind, prev: int, base: int, msg: string) {
			advance_rune(t)
			scan_mantissa(t, base, false)
			if t.offset - prev <= 2 {
				kind^ = .Invalid
				error(t, t.offset, msg)
			}
		}

		switch t.ch {
		case 'b':
			int_base(t, &kind, prev, 2, "Invalid binary integer")
			return kind, string(t.src[offset : t.offset])
		case 'o':
			int_base(t, &kind, prev, 8, "Invalid octal integer")
			return kind, string(t.src[offset : t.offset])
		case 'd':
			int_base(t, &kind, prev, 10, "Invalid explicitly decimal integer")
			return kind, string(t.src[offset : t.offset])
		case 'z':
			int_base(t, &kind, prev, 12, "Invalid dozenal integer")
			return kind, string(t.src[offset : t.offset])
		case 'x':
			int_base(t, &kind, prev, 16, "Invalid hexadecimal integer")
			return kind, string(t.src[offset : t.offset])
		case 'h':
			kind = .Float
			advance_rune(t)
			scan_mantissa(t, 16, false)
			if t.offset - prev <= 2 {
				kind = .Invalid
				error(t, t.offset, "Invalid hexadecimal float")
			} else {
				sub := t.src[prev + 2 : t.offset]
				digit_count := 0
				for d in sub {
					if d != '_' {
						digit_count += 1
					}
				}

				switch digit_count {
				case 4, 8, 16:
					// C++ has a bare `break` here; the count is valid.
				case:
					error(t, t.offset, "Invalid hexadecimal float, expected 4, 8, or 16 digits, got %d", digit_count)
				}
			}
			return kind, string(t.src[offset : t.offset])

		case:
			scan_mantissa(t, 10, true)
		}
	} else {
		scan_mantissa(t, 10, true)
	}

	// C++ Reference: src/tokenizer.cpp:545-560 (`fraction:`).
	if t.ch == '.' {
		if peek_byte(t) == '.' {
			// NOTE(bill): this is kind of ellipsis
			return kind, string(t.src[offset : t.offset])
		}
		advance_rune(t)
		kind = .Float
		scan_mantissa(t, 10, true)
	}

	scan_exponent(t, &kind)

	return kind, string(t.src[offset : t.offset])
}


scan :: proc(t: ^Tokenizer) -> Token {
	skip_whitespace(t)

	offset := t.offset

	kind: Token_Kind
	lit: string
	pos := offset_to_pos(t, offset)

	switch ch := t.ch; true {
	case is_letter(ch):
		lit = scan_identifier(t)
		kind = .Ident
		check_keyword: if 1 < len(lit) && len(lit) < 16 {
			if intrinsics.atomic_load(&_global_keyword_lut_initialized) {
				entry := &global_keyword_lut[keyword_hash(lit) & KEYWORD_LUT_MASK]
				if entry.kind != .Invalid && entry.name == lit {
					kind = entry.kind
					break check_keyword
				}
			} else {
				for i in Token_Kind.B_Keyword_Begin ..= Token_Kind.B_Keyword_End {
					if lit == tokens[i] {
						kind = Token_Kind(i)
						break check_keyword
					}
				}
			}
			for keyword, i in custom_keyword_tokens {
				if lit == keyword {
					kind = Token_Kind(i+1) + .B_Custom_Keyword_Begin
					break check_keyword
				}
			}
		}
	case '0' <= ch && ch <= '9':
		kind, lit = scan_number(t, false)
	case:
		advance_rune(t)
		switch ch {
		case -1:
			// #200: C++ derives a token's column from Tokenizer::column_minus_one, and
			// advance_to_next_rune (src/tokenizer.cpp:374) increments that counter ONLY while
			// read_curr < end. Reaching EOF therefore never advances the column, so the token
			// produced at EOF sits one column earlier than a positional formula would put it:
			// column_minus_one + 1, where column_minus_one is still -1 on a file ending in a
			// newline. This port computes offset - line_offset + 1, which is always >= 1.
			//
			// The offset is one-past-the-end either way; only the printed column differs, and
			// it differs uniformly by one (verified on both a file ending in a newline and one
			// ending mid-line). Applies to the inserted-semicolon form below too, because C++
			// sets that token's position before it decides the kind.
			pos.column -= 1
			kind = .EOF
			if t.insert_semicolon {
				t.insert_semicolon = false
				kind = .Semicolon
				lit = "\n"
				return Token{kind, lit, pos}
			}
		case '\n':
			t.insert_semicolon = false
			kind = .Semicolon
			lit = "\n"
		case '\\':
			if .Insert_Semicolon in t.flags {
				t.insert_semicolon = false
			}
			token := scan(t)
			if token.pos.line == pos.line {
				error(t, token.pos.offset, "expected a newline after \\")
			}
			return token

		case '\'':
			kind = .Rune
			lit = scan_rune(t)
		case '"':
			kind = .String
			lit = scan_string(t)
		case '`':
			kind = .String
			lit = scan_raw_string(t)
		case '.':
			kind = .Period
			switch t.ch {
			case '0'..='9':
				kind, lit = scan_number(t, true)
			case '.':
				advance_rune(t)
				kind = .Ellipsis
				switch t.ch {
				case '<':
					advance_rune(t)
					kind = .Range_Half
				case '=':
					advance_rune(t)
					kind = .Range_Full
				}
			}
		case '@': kind = .At
		case '$': kind = .Dollar
		case '?': kind = .Question
		case '^': kind = .Pointer
		case ';': kind = .Semicolon
		case ',': kind = .Comma
		case ':': kind = .Colon
		case '(': kind = .Open_Paren
		case ')': kind = .Close_Paren
		case '[': kind = .Open_Bracket
		case ']': kind = .Close_Bracket
		case '{': kind = .Open_Brace
		case '}': kind = .Close_Brace
		case '%':
			kind = .Mod
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Mod_Eq
			case '%':
				advance_rune(t)
				kind = .Mod_Mod
				if t.ch == '=' {
					advance_rune(t)
					kind = .Mod_Mod_Eq
				}
			}
		case '*':
			kind = .Mul
			if t.ch == '=' {
				advance_rune(t)
				kind = .Mul_Eq
			} else if t.ch == '*' {
				advance_rune(t)
				kind = .Mul_Mul
			}
		case '=':
			kind = .Eq
			if t.ch == '=' {
				advance_rune(t)
				kind = .Cmp_Eq
			}
		case '~':
			kind = .Xor
			if t.ch == '=' {
				advance_rune(t)
				kind = .Xor_Eq
			}
		case '!':
			kind = .Not
			if t.ch == '=' {
				advance_rune(t)
				kind = .Not_Eq
			}
		case '+':
			kind = .Add
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Add_Eq
			case '+':
				advance_rune(t)
				kind = .Increment
			}
		case '-':
			kind = .Sub
			switch t.ch {
			case '-':
				advance_rune(t)
				kind = .Decrement
				if t.ch == '-' {
					advance_rune(t)
					kind = .Undef
				}
			case '>':
				advance_rune(t)
				kind = .Arrow_Right
			case '=':
				advance_rune(t)
				kind = .Sub_Eq
			}
		case '#':
			kind = .Hash
			if t.ch == '!' {
				kind = .Comment
				lit = scan_comment(t)
			} else if t.ch == '+' {
				kind = .File_Tag
				lit = scan_file_tag(t)
			}
		case '/':
			kind = .Quo
			switch t.ch {
			case '/', '*':
				kind = .Comment
				lit = scan_comment(t)
			case '=':
				advance_rune(t)
				kind = .Quo_Eq
			}
		case '<':
			kind = .Lt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Lt_Eq
			case '<':
				advance_rune(t)
				kind = .Shl
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shl_Eq
				}
			}
		case '>':
			kind = .Gt
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Gt_Eq
			case '>':
				advance_rune(t)
				kind = .Shr
				if t.ch == '=' {
					advance_rune(t)
					kind = .Shr_Eq
				}
			}
		case '&':
			kind = .And
			switch t.ch {
			case '~':
				advance_rune(t)
				kind = .And_Not
				if t.ch == '=' {
					advance_rune(t)
					kind = .And_Not_Eq
				}
			case '=':
				advance_rune(t)
				kind = .And_Eq
			case '&':
				advance_rune(t)
				kind = .Cmp_And
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_And_Eq
				}
			}
		case '|':
			kind = .Or
			switch t.ch {
			case '=':
				advance_rune(t)
				kind = .Or_Eq
			case '|':
				advance_rune(t)
				kind = .Cmp_Or
				if t.ch == '=' {
					advance_rune(t)
					kind = .Cmp_Or_Eq
				}
			}
		case:
			if ch != utf8.RUNE_BOM {
				error(t, t.offset, "Illegal character: %r (%d) ", ch, ch)
			}
			kind = .Invalid
		}
	}

	if .Insert_Semicolon in t.flags {
		#partial switch kind {
		case .Invalid, .Comment:
			// Preserve insert_semicolon info
		case .Ident, .Context, .Typeid, .Break, .Continue, .Fallthrough, .Return,
		     .Integer, .Float, .Imag, .Rune, .String, .Undef,
		     .Question, .Pointer, .Close_Paren, .Close_Bracket, .Close_Brace,
		     .Increment, .Decrement, .Or_Return, .Or_Break, .Or_Continue:
			/*fallthrough*/
			t.insert_semicolon = true
		case:
			t.insert_semicolon = false
			break
		}
	}

	if lit == "" {
		lit = string(t.src[offset : t.offset])
	}
	return Token{kind, lit, pos}
}
