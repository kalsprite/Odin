package checker

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf16"
import "core:unicode/utf8"

/*
Name canonicalization and type hashing infrastructure.

This module provides canonical string representation and hashing for types and entities,
used for type deduplication, RTTI generation, and name mangling.

C++ Reference: name_canonicalization.cpp
               name_canonicalization.hpp

Architecture:
- TypeWriter: Abstraction for writing canonical strings (to string or hash)
- write_type_to_canonical_string: Serializes a type to canonical form
- write_canonical_entity_name: Serializes an entity name to canonical form
- type_hash_canonical_type: Computes FNV-1a hash of canonical type representation
- type_to_canonical_string: Generates human-readable canonical type string

Canonical Name Format Rules (from name_canonicalization.hpp:1-22):
- No spaces between any values
- Normal declarations: pkg::name
- Builtin names: just their normal name (e.g., `i32` or `string`)
- Nested (zero level): pkg::parent1::parent2::name
- Nested (more scopes): pkg::parent1::parent2::name[4] (4th scope in depth-first order)
- File private: pkg::[file_name]::name
- Polymorphic procedure/type: pkg::foo:TYPE
- Anonymous procedures: pkg::foo::$anon[file.odin:123] (123 is file offset in bytes)
*/


// ======================================================================================
// CANONICAL NAME SEPARATORS AND CONSTANTS
// C++ Reference: name_canonicalization.hpp:24-44
// ======================================================================================

CANONICAL_TYPE_SEPARATOR :: ":"
CANONICAL_NAME_SEPARATOR :: "::"
CANONICAL_BIT_FIELD_SEPARATOR :: "|"
CANONICAL_PARAM_SEPARATOR :: ","
CANONICAL_PARAM_TYPEID :: "$"
CANONICAL_PARAM_CONST :: "$$"
CANONICAL_PARAM_C_VARARG :: "#c_vararg"
CANONICAL_PARAM_VARARG :: ".."
CANONICAL_FIELD_SEPARATOR :: ","
CANONICAL_ANON_PREFIX :: "$anon"
CANONICAL_NONE_TYPE :: "<>"
CANONICAL_RANGE_OPERATOR :: "..="

// TYPE_SET_TOMBSTONE marks deleted entries in TypeSet hash table
// C++ Reference: name_canonicalization.hpp:69
TYPE_SET_TOMBSTONE :: max(u64)

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// filename_without_directory extracts just the filename from a full path
// Used for file-private entities and anonymous procedure names
filename_without_directory :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i + 1:]
		}
	}
	return path
}

// default_calling_convention returns the default calling convention for procedures
// C++ Reference: parser.hpp:319-321
default_calling_convention :: proc() -> Calling_Convention {
	return .Odin
}

// proc_calling_convention_strings maps Calling_Convention to its CANONICAL string.
// C++ Reference: parser.hpp `proc_calling_convention_strings[ProcCC_MAX]`.
//
// #960, from rule_engine findings/078: FOUR OF FOURTEEN ENTRIES DIVERGED. The header above claims
// this table mirrors C++'s, and it did not:
//
//     member        C++            port (before)
//     Std           "stdcall"      "std"
//     Fast          "fastcall"     "fast"
//     Inline_Asm    "inlineasm"    "inline_asm"
//     Invalid       ""             "invalid"
//
// These strings ESCAPE. This table feeds the CANONICAL TYPE NAME (write_canonical_type below),
// `type_to_string` (check_expr.odin), and three diagnostics (check_type.odin x2, check_expr.odin).
// So the same source produced a different canonical name and a different diagnostic under the two
// checkers -- and since canonical names feed type hashing, this reached the model a backend reads,
// not just the text a user sees.
//
// MEASURED by the reporter: `h :: proc "std" () {}` built for arm64 makes the reference say
//     Invalid procedure calling convention "stdcall" for target architecture ...
// i.e. the compiler CANONICALISES through this table rather than echoing the source spelling, which
// is what makes the divergence observable at all. The port printed "std".
//
// NOT a round-trip break, and that is why nothing was being rejected: the PARSER keeps its own
// independent accept list (`core/odin/parser/parser.odin`, which takes "stdcall" and "std",
// "fastcall" and "fast"), so both spellings remain valid source under both implementations. Only
// the canonical OUTPUT was wrong.
//
// `Invalid` is the sharpest of the four: C++ emits the EMPTY string, so an invalid convention
// contributes NOTHING to a canonical name, where the port contributed the literal "invalid" --
// changing a name's shape rather than one word in it.
proc_calling_convention_strings := [Calling_Convention]string {
	.Odin        = "odin",
	.Contextless = "contextless",
	.C           = "cdecl",
	.Std         = "stdcall",
	.Fast        = "fastcall",
	.None        = "none",
	.Naked       = "naked",
	.Inline_Asm  = "inlineasm",
	.Win64       = "win64",
	.SysV        = "sysv",
	.Preserve_None = "preserve/none",
	.Preserve_Most = "preserve/most",
	.Preserve_All  = "preserve/all",
	.Invalid       = "",
}

// quote_to_ascii escapes special characters in strings for canonical representation
// C++ Reference: string.cpp quote_to_ascii (String) and string.cpp quote_to_ascii (String16)
quote_to_ascii :: proc {
	quote_to_ascii_string,
	quote_to_ascii_string16,
}

// quote_to_ascii_string escapes a UTF-8 string and wraps the result in `quote`.
//
// C++ Reference: string.cpp quote_to_ascii (quote_to_ascii for String)
//
// The surrounding quote characters are part of the result, exactly as in C++.
// All three call sites depend on that: exact_value_to_string renders a string
// constant as `"text"`, and write_type_to_canonical_string embeds a quoted
// struct tag.
quote_to_ascii_string :: proc(s: string, allocator := context.allocator, quote: byte = '"') -> string {
	// C++ always builds — there is no unescaped fast path, because even a string
	// needing no escapes still has to gain its quote characters.
	sb := strings.builder_make(0, len(s) + 2, allocator)
	strings.write_byte(&sb, quote)

	b := transmute([]byte)s
	for len(b) > 0 {
		r := rune(b[0])
		width := 1
		if r >= utf8.RUNE_SELF {
			r, width = utf8.decode_rune(b)
		}

		// C++ line 861: a one-byte decode yielding U+FFFD is malformed input, so
		// the original byte is emitted rather than the replacement character.
		if width == 1 && r == utf8.RUNE_ERROR {
			fmt.sbprintf(&sb, "\\x%02x", b[0])
			b = b[1:]
			continue
		}

		if r == rune(quote) || r == '\\' {
			strings.write_byte(&sb, '\\')
			strings.write_byte(&sb, byte(r))
			b = b[width:]
			continue
		}
		if r < 0x80 && is_printable_ascii(r) {
			strings.write_byte(&sb, byte(r))
			b = b[width:]
			continue
		}

		// C++ lines 879-931: the switch over '\a'..'\v' gives those cases no body of
		// their own, so every remaining rune falls into `default`, where the two
		// tests below run in SEQUENCE rather than as alternatives. A control
		// character therefore emits BOTH forms: a newline renders as an \x0a
		// escape immediately followed by a \u000a escape.
		if r < ' ' {
			fmt.sbprintf(&sb, "\\x%02x", byte(r))
		}
		if r > utf8.MAX_RUNE {
			r = 0xFFFD
		}
		if r < 0x10000 {
			fmt.sbprintf(&sb, "\\u%04x", r)
		} else {
			fmt.sbprintf(&sb, "\\U%08x", r)
		}
		b = b[width:]
	}

	strings.write_byte(&sb, quote)
	return strings.to_string(sb)
}

// quote_to_ascii_string16 escapes a UTF-16 string to ASCII, wrapping the result
// in `quote`.
//
// C++ Reference: string.cpp quote_to_ascii (quote_to_ascii for String16)
quote_to_ascii_string16 :: proc(val: Exact_Value_String16, allocator := context.allocator, quote: byte = '"') -> string {
	sb := strings.builder_make(0, val.len * 2 + 2, allocator)
	strings.write_byte(&sb, quote)

	utf16_slice := val.text[:val.len] if val.text != nil else nil

	// Process each UTF-16 code unit
	i := 0
	for i < len(utf16_slice) {
		c := utf16_slice[i]
		r := rune(c)
		width := 1

		// C++ lines 946-957. Note that a LONE LOW surrogate matches neither branch,
		// so `r` keeps its raw value and escapes as \udcxx rather than being folded
		// into the replacement character.
		if c < 0xd800 || 0xe000 <= c {
			// Not a surrogate — keep as-is.
		} else if 0xd800 <= c && c < 0xdc00 {
			// High surrogate: pair with the next unit, or fail.
			if i + 1 < len(utf16_slice) {
				r = utf16.decode_surrogate_pair(rune(c), rune(utf16_slice[i + 1]))
				if r != utf16.REPLACEMENT_CHAR {
					width = 2
				}
			} else {
				r = utf16.REPLACEMENT_CHAR
			}
		}

		// Handle invalid UTF-16 sequences
		// C++ Reference: string.cpp quote_to_ascii
		//
		// UPSTREAM (LEDGER task 275): C++ indexes lower_hex with the full u16
		// `s[0]>>4`, which for the surrogate values that are the only way to reach
		// this branch is 0xd80..0xdbf — an out-of-bounds read of a 16-byte table.
		// There is no stable output to match, so the port emits the low byte.
		if width == 1 && r == utf16.REPLACEMENT_CHAR {
			fmt.sbprintf(&sb, "\\x%02x", c & 0xff)
			i += 1
			continue
		}

		// Handle quote and backslash escaping
		// C++ Reference: string.cpp quote_to_ascii
		if r == rune(quote) || r == '\\' {
			strings.write_byte(&sb, '\\')
			strings.write_byte(&sb, byte(r))
			i += width
			continue
		}

		// Handle printable ASCII
		// C++ Reference: string.cpp quote_to_ascii
		if r < 0x80 && is_printable_ascii(r) {
			strings.write_byte(&sb, byte(r))
			i += width
			continue
		}

		// C++ lines 976-1006: as in quote_to_ascii_string, the switch cases carry no
		// body, so these tests run in SEQUENCE. A control character emits both its
		// \xNN escape and its \u00NN escape.
		if r < ' ' {
			fmt.sbprintf(&sb, "\\x%02x", byte(r))
		}
		if r > utf8.MAX_RUNE {
			r = 0xFFFD
		}
		if r < 0x10000 {
			fmt.sbprintf(&sb, "\\u%04x", r)
		} else {
			fmt.sbprintf(&sb, "\\U%08x", r)
		}

		i += width
	}

	strings.write_byte(&sb, quote)
	return strings.to_string(sb)
}

// is_printable_ascii checks if a rune is printable ASCII
// C++ Reference: string.cpp:757-768
is_printable_ascii :: proc(r: rune) -> bool {
	if r <= 0xff {
		if 0x20 <= r && r <= 0x7e {
			return true
		}
		if 0xa1 <= r && r <= 0xff {
			return r != 0xad
		}
		return false
	}
	return false
}

// ======================================================================================
// TYPE WRITER INFRASTRUCTURE
// C++ Reference: name_canonicalization.cpp:241-300
// ======================================================================================

// Type_Writer_Proc is the callback for writing data
// Returns true on success
// C++ Reference: name_canonicalization.cpp:241-242
Type_Writer_Proc :: #type proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool

// Type_Writer abstracts writing canonical strings to different backends
// C++ Reference: name_canonicalization.cpp:245-248
Type_Writer :: struct {
	proc_:     Type_Writer_Proc,
	user_data: rawptr,
}

// C++ Reference: name_canonicalization.cpp:250-252
type_writer_append :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	return w.proc_(w, ptr, len)
}

// C++ Reference: name_canonicalization.cpp:254-256
type_writer_appendb :: proc(w: ^Type_Writer, b: byte) -> bool {
	temp := b
	return w.proc_(w, &temp, 1)
}

// C++ Reference: name_canonicalization.cpp:258-261
type_writer_appendc :: proc(w: ^Type_Writer, str: string) -> bool {
	return w.proc_(w, raw_data(str), len(str))
}

// C++ Reference: name_canonicalization.cpp:263-271
type_writer_append_fmt :: proc(w: ^Type_Writer, format: string, args: ..any) -> bool {
	// Use temp allocator for formatting (equivalent to C++ gb_bprintf)
	str := fmt.tprintf(format, ..args)
	return type_writer_appendc(w, str)
}

// ======================================================================================
// STRING WRITER BACKEND
// C++ Reference: name_canonicalization.cpp:275-288
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:275-279
type_writer_string_writer_proc :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	builder := cast(^strings.Builder)w.user_data
	bytes := slice.bytes_from_ptr(cast(^byte)ptr, len)
	strings.write_bytes(builder, bytes)
	return true
}

// C++ Reference: name_canonicalization.cpp:281-284
type_writer_make_string :: proc(w: ^Type_Writer, builder: ^strings.Builder) {
	w.user_data = builder
	w.proc_ = type_writer_string_writer_proc
}

// C++ Reference: name_canonicalization.cpp:286-288
type_writer_destroy_string :: proc(w: ^Type_Writer) {
	// In Odin, caller manages builder lifetime
	w.user_data = nil
	w.proc_ = nil
}

// ======================================================================================
// HASHER WRITER BACKEND
// C++ Reference: name_canonicalization.cpp:291-300
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:291-295
type_writer_hasher_writer_proc :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	ctx := cast(^Typeid_Hash_Context)w.user_data
	typeid_hash_context_update(ctx, ptr, len)
	return true
}

// C++ Reference: name_canonicalization.cpp:434-438
type_writer_make_hasher :: proc(w: ^Type_Writer, ctx: ^Typeid_Hash_Context) {
	typeid_hash_context_init(ctx)
	w.user_data = ctx
	w.proc_ = type_writer_hasher_writer_proc
}

// ======================================================================================
// TYPEID HASH -- SipHash, matching C++ EXACTLY
// C++ Reference: name_canonicalization.cpp:245-372
//
// A `typeid` IS this value: `lb_typeid` (llvm_backend_type.cpp:78-88) puts
// `type_hash_canonical_type(type)` straight into the emitted constant. So this
// is not an internal hash that merely has to be self-consistent -- it is the
// RUNTIME IDENTITY of a type, shared with every object the reference compiler
// has ever produced.
//
// This used to be FNV-1a, which is self-consistent and wrong: every typeid the
// port computed disagreed with the reference's. Found by comparing computed
// values against `typeid_of` in a running reference binary.
//
// This is SipHash-2-4, and it is now the standard one -- but only since upstream
// corrected `rotate_left64`, which had shifted right by a CONSTANT 62 rather than
// by `64 - s` and so was not a rotate at all.
//
// That correction changed EVERY TYPEID IN THE LANGUAGE. Under the old expression
// `int` hashed to 0x967158c028419176; it is now 0xf8f180427c5584cc, which is what
// standard SipHash-2-4 of "int" under this key produces. This port reproduced the
// defect faithfully and had to be updated in step.
//
// The failure mode when the two sides disagree is worth recording, because it was
// observed rather than reasoned about: a typeid is emitted as a compile-time
// IMMEDIATE, not a relocation, so nothing fails to link. Programs build and run,
// assertions still trap correctly -- because a value is only ever compared with
// another value from the same compiler -- and the only symptom is that the
// RUNTIME's type table does not recognise the constant. The reported message
// degrades from "Invalid type assertion from int to bool" to "from  to ".
// ======================================================================================

SIP_BLOCK_SIZE :: 8

Typeid_Hash_Context :: struct {
	v0, v1, v2, v3: u64,
	k0, k1:         u64,
	c_rounds:       int,
	d_rounds:       int,
	buf:            [SIP_BLOCK_SIZE]u8,
	last_block:     int,
	total_length:   int,
	is_initialized: bool,
}

// C++ Reference: name_canonicalization.cpp:263-281
typeid_hash_context_init :: proc(ctx: ^Typeid_Hash_Context) {
	ctx.c_rounds = 2
	ctx.d_rounds = 4

	// The C++ seed, verbatim -- "some random numbers to act as the seed".
	ctx.k0 = 0xa6592ea25e04ac3c
	ctx.k1 = 0xba3cba04ed28a9ae

	ctx.v0 = 0x736f6d6570736575 ~ ctx.k0
	ctx.v1 = 0x646f72616e646f6d ~ ctx.k1
	ctx.v2 = 0x6c7967656e657261 ~ ctx.k0
	ctx.v3 = 0x7465646279746573 ~ ctx.k1

	ctx.last_block = 0
	ctx.total_length = 0
	ctx.is_initialized = true
}

// rotate_left64 matches C++'s `rotate_left64`.
//
// C++ Reference: name_canonicalization.cpp:284-288
//
//	u64 s = k & (n-1);
//	return (x<<s) | (x>>(n-s));
//
// This shifted right by a CONSTANT `n - 2` = 62 until upstream corrected it, so
// it was a left shift with two stray bits rather than a rotation, and this port
// reproduced the defect deliberately. The correction changed every typeid in the
// language, so the port had to follow it -- see the note above `sip_compress`.
@(private)
rotate_left64 :: proc(x: u64, k: u64) -> u64 {
	n :: u64(64)
	s := k & (n - 1)
	return (x << s) | (x >> (n - s))
}

// C++ Reference: name_canonicalization.cpp:289-305
@(private)
sip_compress :: proc(ctx: ^Typeid_Hash_Context) {
	ctx.v0 += ctx.v1
	ctx.v1 = rotate_left64(ctx.v1, 13)
	ctx.v1 ~= ctx.v0
	ctx.v0 = rotate_left64(ctx.v0, 32)
	ctx.v2 += ctx.v3
	ctx.v3 = rotate_left64(ctx.v3, 16)
	ctx.v3 ~= ctx.v2
	ctx.v0 += ctx.v3
	ctx.v3 = rotate_left64(ctx.v3, 21)
	ctx.v3 ~= ctx.v0
	ctx.v2 += ctx.v1
	ctx.v1 = rotate_left64(ctx.v1, 17)
	ctx.v1 ~= ctx.v2
	ctx.v2 = rotate_left64(ctx.v2, 32)
}

// C++ Reference: name_canonicalization.cpp:307-324
@(private)
sip_block :: proc(ctx: ^Typeid_Hash_Context, data: []u8) {
	d := data
	for len(d) >= SIP_BLOCK_SIZE {
		m: u64
		for i in 0 ..< 8 {
			m |= u64(d[i]) << (8 * u64(i))
		}
		ctx.v3 ~= m
		for _ in 0 ..< ctx.c_rounds {
			sip_compress(ctx)
		}
		ctx.v0 ~= m
		d = d[SIP_BLOCK_SIZE:]
	}
}

// C++ Reference: name_canonicalization.cpp:326-355
typeid_hash_context_update :: proc(ctx: ^Typeid_Hash_Context, ptr: rawptr, length: int) {
	assert(ctx.is_initialized)
	if length <= 0 {
		return
	}
	data := slice.bytes_from_ptr(ptr, length)
	ctx.total_length += length

	if ctx.last_block > 0 {
		n := min(SIP_BLOCK_SIZE - ctx.last_block, len(data))
		copy(ctx.buf[ctx.last_block:], data[:n])
		ctx.last_block += n
		if ctx.last_block == SIP_BLOCK_SIZE {
			sip_block(ctx, ctx.buf[:])
			ctx.last_block = 0
		}
		data = data[n:]
	}

	if len(data) >= SIP_BLOCK_SIZE {
		n := len(data) & ~int(SIP_BLOCK_SIZE - 1)
		sip_block(ctx, data[:n])
		data = data[n:]
	}
	if len(data) > 0 {
		n := min(SIP_BLOCK_SIZE, len(data))
		copy(ctx.buf[:], data[:n])
		ctx.last_block = n
	}
}

// C++ Reference: name_canonicalization.cpp:357-372
typeid_hash_context_fini :: proc(ctx: ^Typeid_Hash_Context) -> u64 {
	assert(ctx.is_initialized)
	tmp: [SIP_BLOCK_SIZE]u8
	copy(tmp[:], ctx.buf[:min(ctx.last_block, SIP_BLOCK_SIZE)])
	tmp[7] = u8(ctx.total_length & 0xff)
	sip_block(ctx, tmp[:])

	ctx.v2 ~= 0xff
	for _ in 0 ..< ctx.d_rounds {
		sip_compress(ctx)
	}
	return ctx.v0 ~ ctx.v1 ~ ctx.v2 ~ ctx.v3
}

// ======================================================================================
// FNV-1a HASH FUNCTION
// C++ Reference: gb/gb.h:4804-4814
// ======================================================================================

// fnv64a computes FNV-1a 64-bit hash
// C++ Reference: gb.h:4804-4814
fnv64a :: proc(data: rawptr, len: int, seed: u64 = 0xcbf29ce484222325) -> u64 {
	h := seed
	bytes := slice.bytes_from_ptr(cast(^byte)data, len)

	for i in 0 ..< len {
		h = (h ~ u64(bytes[i])) * 0x100000001b3
	}

	return h
}

// ======================================================================================
// CANONICAL PARAMETER WRITING
// C++ Reference: name_canonicalization.cpp:305-370
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:305-370
write_canonical_params :: proc(w: ^Type_Writer, params: ^Type) {
	type_writer_appendc(w, "(")
	defer type_writer_appendc(w, ")")

	if params == nil {
		return
	}

	assert(params.kind == .Tuple, "write_canonical_params: params must be a Tuple")
	tuple := params.variant.(Type_Tuple)

	for v, i in tuple.variables {
		if i > 0 {
			type_writer_appendc(w, CANONICAL_PARAM_SEPARATOR)
		}

		type_writer_append(w, raw_data(v.token.text), len(v.token.text))
		type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)

		#partial switch v.kind {
		case .Variable:
			if .C_Var_Arg in v.flags {
				type_writer_appendc(w, CANONICAL_PARAM_C_VARARG)
			}
			if .Ellipsis in v.flags {
				slice_type := base_type(v.type)
				type_writer_appendc(w, CANONICAL_PARAM_VARARG)
				assert(v.type.kind == .Slice, "Ellipsis parameter must have slice type")
				slice_variant := slice_type.variant.(Type_Slice)
				write_type_to_canonical_string(w, slice_variant.elem)
			} else {
				write_type_to_canonical_string(w, v.type)
			}

			// Handle default values for doc writer
			// C++ Reference: name_canonicalization.cpp write_canonical_params
			if is_in_doc_writer() {
				var_ent := v.variant.(Entity_Variable)
				// Get default value expression - try init_expr first, then param_value
				expr := var_ent.init_expr
				if expr == nil {
					expr = var_ent.param_value.original_ast_expr
				}
				if expr != nil {
					type_writer_appendc(w, "=")
					shorthand := .Short in build_context.cmd_doc_flags
					s := shorthand ? expr_to_string_shorthand(expr) : expr_to_string(expr)
					defer delete(s)
					type_writer_append(w, raw_data(s), len(s))
				}
			}

		case .Type_Name:
			type_writer_appendc(w, CANONICAL_PARAM_TYPEID)
			write_type_to_canonical_string(w, v.type)

		case .Constant:
			const_ent := v.variant.(Entity_Constant)
			type_writer_appendc(w, CANONICAL_PARAM_CONST)
			// C++ Reference: name_canonicalization.cpp -- both constant-writing sites pass a string limit of
			// 1<<16. With the default (36) a constant string longer than 36 chars is ELIDED in
			// the canonical name, so two distinct constants can canonicalise identically.
			s := exact_value_to_string(const_ent.value, 1 << 16)
			defer delete(s)
			type_writer_append(w, raw_data(s), len(s))

		case:
			panic("write_canonical_params: Unsupported parameter entity kind")
		}
	}
}

// ======================================================================================
// TYPE HASHING
// C++ Reference: name_canonicalization.cpp:372-390
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:372-390
type_hash_canonical_type :: proc(type: ^Type) -> u64 {
	if type == nil {
		return 0
	}

	// Check cached hash (C++ uses atomic load)
	// C++ Reference: line 376-379
	prev_hash := type.canonical_hash
	if prev_hash != 0 {
		return prev_hash
	}

	// A type ALIAS hashes as the type it aliases.
	//
	// C++ Reference: name_canonicalization.cpp:519-526 -- "Unwrap type aliases
	// similar to are_types_identical*". The port wrote `type` directly, so
	// `MyInt :: int` hashed differently from `int` here and identically in the
	// reference. That is a second divergence, independent of the digest: it
	// survives any change to the hash function.
	type_unaliased := type
	if type.kind == .Named {
		if named, is_named := type.variant.(Type_Named); is_named {
			if e := named.type_name; e != nil {
				if tn, is_tn := e.variant.(Entity_Type_Name); is_tn && tn.is_type_alias {
					type_unaliased = named.base
				}
			}
		}
	}

	// C++ Reference: line 527-530
	ctx: Typeid_Hash_Context
	w: Type_Writer
	type_writer_make_hasher(&w, &ctx)
	write_type_to_canonical_string(&w, type_unaliased)
	hash := typeid_hash_context_fini(&ctx)

	// Ensure hash is non-zero (C++ line 385)
	hash = hash != 0 ? hash : 1

	// C++ Reference: name_canonicalization.cpp:531-540.
	//
	// Deliberate and flag-gated, unlike the rotate defect above: clearing the
	// top bit puts every typeid in [1, 2^63) so a type switch over `any` has a
	// case span the WebKit wasm JIT can represent. Omitting it made the port
	// disagree with the reference under `-webkit-switch-workaround`, which is a
	// configuration nothing here had exercised.
	if build_context.webkit_switch_workaround {
		hash &= 0x7fffffffffffffff
		hash = hash != 0 ? hash : 1
	}

	// Cache the hash (single-threaded, no atomics needed)
	// C++ Reference: line 387
	type.canonical_hash = hash

	return hash
}

// ======================================================================================
// CANONICAL STRING GENERATION
// C++ Reference: name_canonicalization.cpp:392-407
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:392-399
type_to_canonical_string :: proc(type: ^Type, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)

	w: Type_Writer
	type_writer_make_string(&w, &builder)
	write_type_to_canonical_string(&w, type)

	return strings.clone(strings.to_string(builder), allocator)
}

// C++ Reference: name_canonicalization.cpp:401-407
temp_canonical_string :: proc(type: ^Type) -> string {
	return type_to_canonical_string(type, context.temp_allocator)
}

// C++ Reference: name_canonicalization.cpp:409-414
string_canonical_entity_name :: proc(e: ^Entity, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)

	w: Type_Writer
	type_writer_make_string(&w, &builder)
	write_canonical_entity_name(&w, e)

	return strings.clone(strings.to_string(builder), allocator)
}

// ======================================================================================
// CANONICAL PARENT PREFIX WRITING
// C++ Reference: name_canonicalization.cpp:418-466
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:418-466
write_canonical_parent_prefix :: proc(w: ^Type_Writer, e: ^Entity) {
	assert(e != nil, "write_canonical_parent_prefix: entity is nil")

	// C++ Reference: src/name_canonicalization.cpp:576-577 --
	//     if (e->kind == Entity_Procedure || e->kind == Entity_AsmTemplate ||
	//         e->kind == Entity_TypeName  || e->kind == Entity_Variable)
	// TWO kinds were missing from the port's guard, and BOTH fall through to the `panic` at the
	// bottom of this procedure rather than to a diagnostic: `.Asm_Template` (#1242) and
	// `.Variable`, which has no connection to asm and predates it.
	if e.kind == .Procedure || e.kind == .Asm_Template || e.kind == .Type_Name || e.kind == .Variable {
		// C++ Reference: line 421-424
		if e.kind == .Procedure {
			proc_ent := e.variant.(Entity_Procedure)
			if proc_ent.is_export || proc_ent.is_foreign {
				// No prefix for exported/foreign procedures
				return
			}
		}

		// C++ Reference: line 425-434
		if e.parent_proc_decl != nil {
			p := e.parent_proc_decl.entity
			write_canonical_parent_prefix(w, p)
			type_writer_append(w, raw_data(p.token.text), len(p.token.text))
			if is_type_polymorphic(p.type) {
				type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
				write_type_to_canonical_string(w, p.type)
			}
			type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)

			// C++ Reference: line 435-441
			// Check if entity is in package-level scope (not file-private)
		} else if e.pkg != nil && e.pkg.scope != nil {
			// NOTE: checker.Scope is an alias to ast.Scope, so e.pkg.scope can be used directly
			if scope_lookup_current(e.pkg.scope, e.token.text) == e {
				// Entity is at package level - use simple package::name format
				type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
				if e.pkg.name == "llvm" {
					type_writer_appendc(w, "$")
				}
				type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
				// Don't add file name prefix - fall through to write_base_name
			} else {
				// Entity not in package scope or lookup failed, treat as file-private
				file_name := filename_without_directory(e.file.fullpath)

				type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
				if e.pkg.name == "llvm" {
					type_writer_appendc(w, "$")
				}
				type_writer_append_fmt(w, "%s[%s]%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR)
			}
		} else {
			// C++ Reference: line 442-448
			file_name := filename_without_directory(e.file.fullpath)

			type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
			if e.pkg.name == "llvm" {
				type_writer_appendc(w, "$")
			}
			type_writer_append_fmt(w, "%s%s%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR)
		}
	} else {
		panic(fmt.tprintf("write_canonical_parent_prefix: Unsupported entity kind %v", e.kind))
	}

	// C++ Reference: line 452-457
	if e.kind == .Procedure {
		proc_ent := e.variant.(Entity_Procedure)
		if proc_ent.is_anonymous {
			file_name := filename_without_directory(e.file.fullpath)
			type_writer_append_fmt(w, "%s_%s:%d", CANONICAL_ANON_PREFIX, file_name, e.token.pos.offset)
		} else {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		}
	} else {
		type_writer_append(w, raw_data(e.token.text), len(e.token.text))
	}

	// C++ Reference: line 459-463
	if is_type_polymorphic(e.type) {
		type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
		write_type_to_canonical_string(w, e.type)
	}
	type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
}

// ======================================================================================
// CANONICAL ENTITY NAME WRITING
// C++ Reference: name_canonicalization.cpp:468-599
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:468-599
write_canonical_entity_name :: proc(w: ^Type_Writer, e: ^Entity) {
	assert(e != nil, "write_canonical_entity_name: entity is nil")

	// C++ Reference: line 471-476
	if e.token.text == "_" {
		panic("write_canonical_entity_name: _ entity")
	}
	if len(e.token.text) == 0 {
		panic("write_canonical_entity_name: empty string entity")
	}

	// C++ Reference: line 478-494
	if e.kind == .Variable {
		var_ent := e.variant.(Entity_Variable)
		is_foreign := var_ent.is_foreign
		is_export := var_ent.is_export

		if len(var_ent.link_name) > 0 {
			type_writer_append(w, raw_data(var_ent.link_name), len(var_ent.link_name))
			return
		} else if is_foreign || is_export {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
			return
		}
	} else if e.kind == .Procedure {
		proc_ent := e.variant.(Entity_Procedure)
		if len(proc_ent.link_name) > 0 {
			type_writer_append(w, raw_data(proc_ent.link_name), len(proc_ent.link_name))
			return
		} else if proc_ent.is_export {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
			return
		}
	}

	write_scope_index_suffix := false

	// C++ Reference: line 498-547
	if .Builtin in e.scope.flags {
		// Jump to write_base_name
	} else if (.File not_in e.scope.flags && .Pkg not_in e.scope.flags) || .Not_Exported in e.flags {
		s := e.scope

		// Find parent scope with decl_info or procedure/file flags
		// C++ Reference: line 504-509
		for (.Proc not_in s.flags && .File not_in s.flags) && s.decl_info == nil {
			if s.parent == nil {
				break
			}
			s = s.parent
		}

		// C++ Reference: line 511-517
		if s.decl_info != nil && s.decl_info.entity != nil {
			parent := s.decl_info.entity
			write_canonical_parent_prefix(w, parent)
			if e.scope.index > 0 {
				write_scope_index_suffix = true
			}
			// Jump to write_base_name
		} else if (.File in s.flags) && s.file != nil {
			// C++ Reference: line 519-526
			file_name := filename_without_directory(s.file.fullpath)

			// The guard above tests `s.file`, NOT `e.pkg` -- and C++ is the same here
			// (name_canonicalization.cpp, write_canonical_entity_name: the `(s->flags &
			// ScopeFlag_File) && s->file != nullptr` arm dereferences `e->pkg->name` with no nil
			// test, while a LATER site in the same function does guard `e->pkg != nullptr`).
			// So this line is FAITHFUL, not a port defect.
			//
			// It matters here anyway because `string_canonical_entity_name` is a PUBLIC API of
			// this package, and external consumers call it on arbitrary entities. C++ only ever
			// reaches this function from the LLVM backend (globals, procedures, debug info) and
			// on `Named.type_name` -- none of which is a FIELD entity. rexcode/mir passed a
			// `bit_field` field entity (`.Variable`, non-nil scope, no `pkg`) and took a SEGFAULT
			// with no diagnostic and no position.
			//
			// ASSERT rather than a silent nil-guard: inventing a fallback string would be a
			// behavioural divergence from C++ with nothing to anchor it to, whereas an assert
			// keeps the semantics identical on every input C++ can produce and converts an
			// unreachable-by-construction violation into a diagnosable failure. Same trade the
			// `#exists`/`#load` guards record: the difference between a diagnostic and an abort.
			// Style matches the other assert in this same function.
			assert(e.pkg != nil, "write_canonical_entity_name: file-scope branch reached with a nil pkg (entity is not package-owned -- see the bit_field field case)")

			type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
			if e.pkg.name == "llvm" {
				type_writer_appendc(w, "$")
			}
			type_writer_appendc(w, fmt.tprintf("%s[%s]%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR))
			// Jump to write_base_name
		} else if .Builtin in s.flags {
			// Jump to write_base_name
		} else if e.kind == .Type_Name {
			// C++ Reference: name_canonicalization.cpp write_canonical_entity_name --
			//     if (e->kind == Entity_TypeName) {
			//         goto write_base_name;
			//     }
			// LEDGER #482. This escape was MISSING, so any Type_Name reaching here panicked.
			// Measured: `-dump-doc` on core/unicode/utf8 died with "Weird entity Odin_Arch_Type"
			// -- a UNIVERSE-SCOPE type name, i.e. entirely ordinary input, not an edge case.
			// C++ takes the goto and writes the base name; only NON-TypeName entities reach its
			// diagnostic. The old comment cited "C++ line 530-546", which is the typeid-hashing
			// and WebKit-workaround block -- a drifted citation pointing at unrelated code.
		} else {
			// C++ Reference: name_canonicalization.cpp write_canonical_entity_name onward -- C++ prints a detailed
			// WEIRD ENTITY TYPE diagnostic (position, type, scope flags, decl_info) and then dies.
			// The port keeps the die; the diagnostic detail is not reproduced.
			panic(fmt.tprintf("write_canonical_entity_name: Weird entity %s", e.token.text))
		}

	// C++ Reference: name_canonicalization.cpp write_canonical_entity_name
	//
	// LEDGER #880. THIS IS AN `else if`, NOT AN `if`, AND THAT IS THE WHOLE DEFECT.
	//
	// C++ reaches its package-prefix block by FALLING OFF THE END of the chain above. Every arm
	// that does not fall off ends in `goto write_base_name`, which jumps PAST this block:
	//     Builtin scope                      -> goto write_base_name
	//     parent decl_info                   -> goto write_base_name
	//     file scope (writes pkg::[file]::)  -> goto write_base_name
	//     Builtin scope, inner               -> goto write_base_name
	//     TypeName                           -> goto write_base_name
	//     anything else                      -> GB_PANIC
	// So the package prefix is written on EXACTLY ONE path: the one where neither outer condition
	// held. An `else if` is the faithful rendering of that; a plain `if` is not.
	//
	// The port had a plain `if`, and each of those gotos survived only as a `// Jump to
	// write_base_name` COMMENT with no control flow under it. Every entity taking an inner arm
	// therefore fell through and had its package name appended a SECOND time:
	//     @private runtime.__init_context
	//       port  runtime::[core.odin]::runtime::__init_context
	//       C++   runtime::[core.odin]::__init_context
	// -- the file-scope arm above writes `runtime::[core.odin]::`, then this block wrote
	// `runtime::` again. A `@private` entity qualifies via `.Not_Exported in e.flags`; a public one
	// skips the chain entirely, which is why `default_context` in the SAME FILE was always correct
	// and is the control for this fix (measured unchanged: `runtime::default_context`).
	//
	// WHY NO GATE CAUGHT IT, and why one still cannot. The canonical name IS the linker symbol, so
	// the only way to see this is to compare against a symbol the reference compiler EMITTED --
	// read out of its `.rela.text`, not out of a diagnostic. corpus/parity/parity_vet compare
	// diagnostics; modelsweep compares layout; entity_symbol_name has ZERO in-tree callers. A
	// port-vs-port comparison agrees with itself on the wrong name. This is the same blind spot
	// that hid #601 (the missing `!` / `#optional_ok` tags), found the same way -- by mirc failing
	// to link -- and the probe at $S/p880 is the only instrument here that can observe it.
	} else if e.pkg != nil {
		type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
		type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
	}

	// write_base_name: (C++ Reference: line 553)

	// C++ Reference: line 555-592
	#partial switch e.kind {
	case .Type_Name:
		// C++ Reference: line 557-573
		params: ^Type = nil
		parent := type_get_polymorphic_parent(e.type, &params)

		if parent != nil && e.token.text == parent.token.text {
			// Check for `distinct` forms (C++ line 561-564)
			type_writer_append(w, raw_data(parent.token.text), len(parent.token.text))
			write_canonical_params(w, params)
		} else if parent != nil && strings.has_prefix(e.token.text, parent.token.text) && strings.contains_rune(e.token.text, '(') {
			// Check for named specialization forms (C++ line 565-569)
			type_writer_append(w, raw_data(parent.token.text), len(parent.token.text))
			write_canonical_params(w, params)
		} else {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		}

	case .Constant:
		// For debug symbols only (C++ line 576-578)
		fallthrough

	// C++ Reference: src/name_canonicalization.cpp:743-745 -- Procedure, AsmTemplate and
	// Variable share one arm, with Constant falling into it. `.Asm_Template` added by #1242;
	// the port's `case:` below is a panic, not a diagnostic.
	case .Procedure, .Asm_Template, .Variable:
		type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		if is_type_polymorphic(e.type) {
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, e.type)
		}

	case:
		panic(fmt.tprintf("write_canonical_entity_name: Unsupported entity kind %v", e.kind))
	}

	// C++ Reference: line 593-596
	if write_scope_index_suffix {
		assert(e != nil && e.scope != nil)
		type_writer_append_fmt(w, "%s$%d", CANONICAL_NAME_SEPARATOR, e.scope.index)
	}
}

// ======================================================================================
// CANONICAL TYPE STRING WRITING
// C++ Reference: name_canonicalization.cpp:602-844
// ======================================================================================

// write_type_to_canonical_string serializes a type to canonical form
// This is the core function for type identity and hashing
// C++ Reference: name_canonicalization.cpp:602-844
write_type_to_canonical_string :: proc(w: ^Type_Writer, type: ^Type) {
	if type == nil {
		type_writer_appendc(w, CANONICAL_NONE_TYPE)
		return
	}

	// THE REFERENCE'S TWO LINES HERE ARE COMMENTED OUT, AND THE PORT PORTED THEM AS LIVE CODE.
	//
	// C++ Reference: name_canonicalization.cpp:609-610, verbatim --
	//     // type = default_type(type);
	//     // GB_ASSERT(!is_type_untyped(type));
	// Both are `//`-disabled in the reference, and the Basic arm below then writes
	// `type->Basic.name` for whatever it was handed, untyped included. The port ran the
	// default_type() and asserted, which COLLAPSES every untyped type onto its default:
	// `untyped integer` hashed identically to `int`, `untyped rune` to `rune`, and so on.
	//
	// That is not cosmetic. type_hash_canonical_type is a CACHE KEY -- for the doc writer's
	// type_cache, for type_info_deps (type_info.odin:270), for the type-switch duplicate-variant
	// test (check_stmt.odin:37) -- so the collapse made two genuinely distinct types share one
	// slot, and the first one visited decided what the other resolved to.
	//
	// MEASURED with triage_docbin on core/unicode/utf8: the oracle's .odin-doc contains ten
	// distinct Basic types including BOTH `int` and `untyped integer`, and BOTH `rune` and
	// `untyped rune`; the port's contained seven, with `int` and `rune` absent entirely because
	// every reference to them resolved to the untyped entry that got there first. `RUNE_EOF`
	// documented its type as `untyped rune` where the reference says `rune`.
	//
	// dump_doc.odin's #490 note describes this collision as by-design ("`untyped rune` and `rune`
	// hash identically by design"); the reference's own output is what shows it is not.
	//
	// NOTE: Cannot reassign parameter in Odin, so use a new variable.
	actual_type := type

	#partial switch actual_type.kind {
	case .Basic:
		// C++ Reference: line 613-615
		basic := actual_type.variant.(Type_Basic)
		name := basic_kind_to_string(basic.kind)
		type_writer_append(w, raw_data(name), len(name))

	case .Pointer:
		// C++ Reference: line 616-619
		type_writer_appendb(w, '^')
		ptr := actual_type.variant.(Type_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Multi_Pointer:
		// C++ Reference: line 620-623
		type_writer_appendc(w, "[^]")
		ptr := actual_type.variant.(Type_Multi_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Soa_Pointer:
		// C++ Reference: line 624-627
		type_writer_appendc(w, "#soa^")
		ptr := actual_type.variant.(Type_Soa_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Enumerated_Array:
		// C++ Reference: line 628-636
		ea := actual_type.variant.(Type_Enumerated_Array)
		// C++ Reference: line 629-631
		if ea.is_sparse {
			type_writer_appendc(w, "#sparse")
		}
		type_writer_appendb(w, '[')
		write_type_to_canonical_string(w, ea.index)
		type_writer_appendb(w, ']')
		write_type_to_canonical_string(w, ea.elem)

	case .Array:
		// C++ Reference: line 637-640
		arr := actual_type.variant.(Type_Array)
		type_writer_append_fmt(w, "[%d]", arr.count)
		write_type_to_canonical_string(w, arr.elem)

	case .Slice:
		// C++ Reference: line 641-644
		slice := actual_type.variant.(Type_Slice)
		type_writer_appendc(w, "[]")
		write_type_to_canonical_string(w, slice.elem)

	case .Dynamic_Array:
		// C++ Reference: line 645-648
		dyn := actual_type.variant.(Type_Dynamic_Array)
		type_writer_appendc(w, "[dynamic]")
		write_type_to_canonical_string(w, dyn.elem)

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: name_canonicalization.cpp write_type_to_canonical_string --
		//     type_writer_append_fmt(w, "[dynamic;%lld]", capacity);
		//     write_type_to_canonical_string(w, elem);
		// LEDGER #482. This arm was MISSING, so `[dynamic; N]T` panicked in the canonical-name
		// writer. Reached via the doc path: a Generic whose default_type() is a fixed-capacity
		// dynamic array. Same family as #309 (the type kind missing from the literal switch) and
		// #89 (missing from is_ast_type) -- [dynamic; N]T keeps being the one kind left out.
		fcda := actual_type.variant.(Type_Fixed_Capacity_Dynamic_Array)
		type_writer_appendc(w, fmt.tprintf("[dynamic;%d]", fcda.capacity))
		write_type_to_canonical_string(w, fcda.elem)

	case .Simd_Vector:
		// C++ Reference: line 649-652
		simd := actual_type.variant.(Type_Simd_Vector)
		type_writer_append_fmt(w, "#simd[%d]", simd.count)
		write_type_to_canonical_string(w, simd.elem)

	case .Matrix:
		// C++ Reference: line 653-659
		mat := actual_type.variant.(Type_Matrix)
		if mat.is_row_major {
			type_writer_appendc(w, "#row_major ")
		}
		type_writer_append_fmt(w, "matrix[%d, %d]", mat.row_count, mat.column_count)
		write_type_to_canonical_string(w, mat.elem)

	case .Map:
		// C++ Reference: line 660-665
		map_type := actual_type.variant.(Type_Map)
		type_writer_appendc(w, "map[")
		write_type_to_canonical_string(w, map_type.key)
		type_writer_appendc(w, "]")
		write_type_to_canonical_string(w, map_type.value)

	case .Enum:
		// C++ Reference: line 667-689
		enum_type := actual_type.variant.(Type_Enum)
		type_writer_appendc(w, "enum")
		if enum_type.base_type != nil {
			type_writer_appendb(w, ' ')
			write_type_to_canonical_string(w, enum_type.base_type)
			type_writer_appendb(w, ' ')
		}
		type_writer_appendb(w, '{')
		for f, i in enum_type.fields {
			assert(f.kind == .Constant, "Enum field must be constant")
			const_ent := f.variant.(Entity_Constant)
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, "=")

			// C++ Reference: name_canonicalization.cpp -- both constant-writing sites pass a string limit of
			// 1<<16. With the default (36) a constant string longer than 36 chars is ELIDED in
			// the canonical name, so two distinct constants can canonicalise identically.
			s := exact_value_to_string(const_ent.value, 1 << 16)
			defer delete(s)
			type_writer_append(w, raw_data(s), len(s))
		}
		type_writer_appendb(w, '}')

	case .Bit_Set:
		// C++ Reference: line 690-706
		bs := actual_type.variant.(Type_Bit_Set)
		type_writer_appendc(w, "bit_set[")
		if bs.elem == nil {
			type_writer_appendc(w, CANONICAL_NONE_TYPE)
		} else if is_type_enum(bs.elem) {
			write_type_to_canonical_string(w, bs.elem)
		} else {
			// t205: C++ name_canonicalization.cpp writes the ELEMENT TYPE between the range
			// operator and the upper bound, and PARENTHESISES the upper bound:
			//     lower  ..=  <elem>  (upper)
			// The port wrote `lower..=upper`, which is the shape of type_to_string's bit_set arm
			// (src/types.cpp), not the canonical writer's -- a drifted twin. Because the canonical
			// string IS the typeid digest, dropping the elem made `bit_set[0..=7]` and
			// `bit_set['\x00'..='\x07']` COLLIDE on one typeid. Witness wit_canon205/{c1,c5}.
			type_writer_append_fmt(w, "%d", bs.lower)
			type_writer_appendc(w, CANONICAL_RANGE_OPERATOR)
			write_type_to_canonical_string(w, bs.elem)
			type_writer_append_fmt(w, "(%d)", bs.upper)
		}
		if bs.underlying != nil {
			type_writer_appendc(w, ";")
			write_type_to_canonical_string(w, bs.underlying)
		}
		type_writer_appendc(w, "]")

	case .Union:
		// C++ Reference: line 708-729
		union_type := actual_type.variant.(Type_Union)
		type_writer_appendc(w, "union")

		// Handle polymorphic_params for doc writer
		// C++ Reference: name_canonicalization.cpp write_type_to_canonical_string
		if is_in_doc_writer() && union_type.polymorphic_params != nil {
			write_canonical_params(w, union_type.polymorphic_params)
		}

		switch union_type.kind {
		case .No_Nil:
			type_writer_appendc(w, "#no_nil")
		case .Maybe:
			// Maybe was merged with normal unions - nothing to print
		case .Shared_Nil:
			type_writer_appendc(w, "#shared_nil")
		case .Normal: // No suffix
		}

		if union_type.custom_align != 0 {
			type_writer_append_fmt(w, "#align(%d)", union_type.custom_align)
		}

		type_writer_appendc(w, "{")
		for variant, i in union_type.variants {
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			write_type_to_canonical_string(w, variant)
		}
		type_writer_appendc(w, "}")

	case .Struct:
		// C++ Reference: line 730-773
		struct_type := actual_type.variant.(Type_Struct)

		// Handle SOA types (C++ line 731-739)
		if struct_type.soa_kind != .None {
			#partial switch struct_type.soa_kind {
			case .Fixed:
				type_writer_append_fmt(w, "#soa[%d]", struct_type.soa_count)
			case .Slice:
				type_writer_appendc(w, "#soa[]")
			case .Dynamic:
				type_writer_appendc(w, "#soa[dynamic]")
			}
			write_type_to_canonical_string(w, struct_type.soa_elem)
			return
		}

		type_writer_appendc(w, "struct")

		// Handle polymorphic_params for doc writer
		// C++ Reference: name_canonicalization.cpp write_type_to_canonical_string
		if is_in_doc_writer() && struct_type.polymorphic_params != nil {
			write_canonical_params(w, struct_type.polymorphic_params)
		}

		if struct_type.is_packed {
			type_writer_appendc(w, "#packed")
		}
		if struct_type.is_raw_union {
			type_writer_appendc(w, "#raw_union")
		}
		// t205: C++ writes #all_or_none here, between #raw_union and #min_field_align. The port
		// omitted it, so `struct #all_or_none {a,b}` and `struct {a,b}` shared one canonical name
		// and therefore one typeid. This is the THIRD writer of this flag -- check_expr.odin's
		// type_to_string already carries a note that fixing two of them was incomplete. Now three.
		if struct_type.is_all_or_none {
			type_writer_appendc(w, "#all_or_none")
		}
		if struct_type.custom_min_field_align != 0 {
			type_writer_append_fmt(w, "#min_field_align(%d)", struct_type.custom_min_field_align)
		}
		if struct_type.custom_max_field_align != 0 {
			type_writer_append_fmt(w, "#max_field_align(%d)", struct_type.custom_max_field_align)
		}
		if struct_type.custom_align != 0 {
			type_writer_append_fmt(w, "#align(%d)", struct_type.custom_align)
		}

		type_writer_appendb(w, '{')
		for f, i in struct_type.fields {
			assert(f.kind == .Variable, "Struct field must be variable")
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			// t205: C++ prefixes the field name with "#subtype " when the field carries
			// EntityFlags_IsSubtype (== Using|Subtype, so a `using` field prints BOTH prefixes)
			// and then "using " for EntityFlag_Using. The port printed neither, collapsing
			// `using b: B`, `#subtype b: B` and plain `b: B` onto ONE canonical name and one
			// typeid. The flags are written (check_type.odin) and read elsewhere -- they were
			// simply never printed here. Witness wit_canon205/{c7,c8}, control c10.
			if Entity_Flags_Is_Subtype & f.flags != {} {
				type_writer_appendc(w, "#subtype ")
			}
			if .Using in f.flags {
				type_writer_appendc(w, "using ")
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, f.type)

			// Handle struct tags (C++ line 762-770)
			tag := ""
			if i < len(struct_type.tags) {
				tag = struct_type.tags[i]
			}
			if len(tag) != 0 {
				escaped_tag := quote_to_ascii(tag, context.temp_allocator)
				type_writer_append(w, raw_data(escaped_tag), len(escaped_tag))
			}
		}
		type_writer_appendb(w, '}')

	case .Bit_Field:
		// C++ Reference: line 775-791
		bf := actual_type.variant.(Type_Bit_Field)
		type_writer_appendc(w, "bit_field")
		write_type_to_canonical_string(w, bf.backing_type)
		type_writer_appendc(w, " {")
		for f, i in bf.fields {
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, f.type)
			type_writer_appendc(w, CANONICAL_BIT_FIELD_SEPARATOR)
			// C++ Reference: line 786-787
			type_writer_append_fmt(w, "%d", bf.bit_sizes[i])
		}
		type_writer_appendc(w, " }")

	case .Proc:
		// C++ Reference: line 793-806
		proc_type := actual_type.variant.(Type_Proc)
		type_writer_appendc(w, "proc")

		// C++ Reference: line 795-799
		if default_calling_convention() != proc_type.calling_convention {
			type_writer_appendc(w, "\"")
			type_writer_appendc(w, proc_calling_convention_strings[proc_type.calling_convention])
			type_writer_appendc(w, "\"")
		}

		write_canonical_params(w, proc_type.params)
		if proc_type.result_count > 0 {
			type_writer_appendc(w, "->")
			write_canonical_params(w, proc_type.results)
		}

		// C++ Reference: name_canonicalization.cpp write_type_to_canonical_string
		//
		// BOTH TAGS WERE MISSING. The port stopped after the results, so every #optional_ok
		// procedure got a canonical name 12 characters shorter than the reference's, and every
		// diverging procedure lost its `!`.
		//
		// The canonical name is the LINK-TIME IDENTITY of an instantiation, so this is not
		// cosmetic. mirc found it by cross-linking against reference-compiled objects: the
		// reference defines
		//     runtime::append_elem:proc(...)->(...)#optional_ok
		// and mirc referenced the same string without the tag -- byte-identical for 137 characters,
		// then divergent. Unresolved symbol. That covers `append`, map access and the `, ok` form
		// of type assertions, i.e. everything spelled with an optional second result.
		//
		// It is INVISIBLE to any same-compiler comparison -- port-vs-port agrees on the wrong name
		// -- which is why no gate here caught it and only a mixed link could.
		//
		// ORDER IS LOAD-BEARING: results, then `!`, then `#optional_ok`. This is a name; a different
		// order is a different symbol. The doc writer already emitted both tags in this order
		// (docs_writer.odin:1142-1145), which is corroboration that the fields carry what C++ reads.
		if proc_type.diverging {
			type_writer_appendc(w, "!")
		}
		if proc_type.optional_ok {
			type_writer_appendc(w, "#optional_ok")
		}

	case .Generic:
		// C++ Reference: name_canonicalization.cpp:991-1007, all three branches.
		//
		// THE DOC-WRITER BRANCH WAS MISSING, and the comment that stood here said so and then
		// claimed the remainder "matches the C++ behavior exactly" -- two statements that cannot
		// both be true. It also called the infrastructure absent: is_in_doc_writer() EXISTS in
		// this port and is already consulted at the three other C++ sites (the vararg/default-value
		// site at :612, Union.polymorphic_params at :1227, Struct.polymorphic_params at :1276).
		// This arm was the only one left out.
		//
		// WHAT IT COST. The canonical string is the doc writer's type_cache KEY
		// (docs_writer.cpp:505-507; the port matches). Collapsing every unspecialized generic to
		// the literal "rawptr" made them all hash identically, so the first one written won and
		// every later one returned ITS index -- one shared Doc_Type standing in for every type
		// parameter in the package. The claim that this "is correct since they're all treated as
		// pointer-sized opaque types" holds for RTTI, where the hash means layout; it is false for
		// the doc format, where the hash means identity and the NAME is the payload.
		// MEASURED with docbin.sh: core/slice rendered `Generic(name=E)` for $T, $U, $V, $K, $S,
		// []$U and [dynamic]$E alike, and reported 233 types where the oracle reports 296;
		// core/sort 77 against 81; core/container/queue 92 against 101.
		//
		// The id is what separates two generics that share a name -- `$T` in one procedure and
		// `$T` in the next are different types and must not share a doc entry.
		generic := actual_type.variant.(Type_Generic)
		if is_in_doc_writer() {
			type_writer_appendc(w, "$")
			type_writer_append(w, raw_data(generic.name), len(generic.name))
			type_writer_append_fmt(w, "-%d", generic.id)
			if generic.specialized != nil {
				type_writer_appendc(w, "/")
				write_type_to_canonical_string(w, generic.specialized)
			}
		} else if generic.specialized != nil {
			// If we have a specialized type, use that instead of panicking
			// C++ Reference: name_canonicalization.cpp:1000-1002
			write_type_to_canonical_string(w, generic.specialized)
		} else {
			// For unspecialized generics, use a generic placeholder string
			// C++ Reference: name_canonicalization.cpp:1003-1005
			type_writer_appendc(w, "rawptr")
		}

	case .Named:
		// C++ Reference: line 826-832
		named := actual_type.variant.(Type_Named)
		if named.type_name != nil {
			write_canonical_entity_name(w, named.type_name)
		} else {
			type_writer_append(w, raw_data(named.name), len(named.name))
		}

	case .Tuple:
		// C++ Reference: line 834-837
		type_writer_appendc(w, "params")
		write_canonical_params(w, type)

	case:
		// LEDGER #482. This used to print `type.kind` -- the ORIGINAL type's kind -- while the
		// switch above dispatches on `actual_type.kind` (actual_type := default_type(type)).
		// So an unhandled kind was reported under the name of whatever was passed IN, and a
		// Generic input whose default_type() lands on an unhandled kind said "Unknown type kind
		// Generic" -- pointing at the .Generic arm, which exists and is fine. It cost a wrong fix
		// attempt (caught only by a duplicate-case compile error). Report BOTH.
		panic(fmt.tprintf(
			"write_type_to_canonical_string: Unknown type kind %v (from %v)",
			actual_type.kind, type.kind))
	}
}

// entity_symbol_name returns the LINKER SYMBOL for an entity.
//
// C++ Reference: lb_get_entity_name (llvm_backend_general.cpp:1771). Four cases, in order:
//
//     TypeName with ir_mangled_name set  -> ir_mangled_name
//     Procedure with link_name set       -> link_name            (i.e. @(link_name))
//     e.pkg == nil                       -> e.token.text         (builtins / universe)
//     otherwise                          -> string_canonical_entity_name(e)
//
// WHY IT LIVES HERE. The canonical name IS the symbol, and the rule that maps an entity to it is
// linking-critical: any backend that reproduces it slightly differently emits objects that will
// not link against anything the existing compiler produced. Two copies in two languages WILL
// drift. The rule now has one home.
//
// DELIBERATE DIVERGENCE -- THIS DOES NOT CACHE. C++ writes the computed name back into
// TypeName.ir_mangled_name / Procedure.link_name / Variable.link_name and returns the cached value
// on subsequent calls. That is a backend-local memoisation, and it is safe there because the
// backend is the last thing to run and owns the model. It is NOT safe for an exported checker
// procedure, for three reasons:
//
//   1. It writes into the fields that carry the USER'S OVERRIDE. After caching you cannot
//      distinguish "the source said @(link_name)" from "somebody asked for the symbol once".
//      That is information-destroying, and the checker is now a library with several readers.
//
//   2. dump_model EMITS ir_mangled_name (dump_model.odin, `mangled`). A caching version would make
//      the model dump depend on whether any consumer had called this -- so the parity and
//      modelsweep measurements would depend on consumer behaviour rather than on the checker.
//      An instrument must not be perturbable by its observers.
//
//   3. Two consumers disagreeing on whether to cache leaves a later reader seeing different state
//      depending on who ran first. Raised by the mir backend work, and correct.
//
// The name PRODUCED is identical either way -- C++'s cache is pure memoisation, so this is an
// ownership divergence, not a behavioural one. Recorded in CPP_DEVIATIONS.md.
//
// The returned string is allocated from `allocator` in the fourth case ONLY; the first three
// return borrowed slices of the entity. Callers that free unconditionally will fault -- if you
// need uniform ownership, clone the result.
entity_symbol_name :: proc(e: ^Entity, allocator := context.allocator) -> string {
	if e == nil {
		return ""
	}

	// Case 1 and 2: an already-set name wins. Note the asymmetry, which is C++'s: TypeName is
	// consulted through ir_mangled_name, Procedure through link_name.
	#partial switch v in e.variant {
	case Entity_Type_Name:
		if len(v.ir_mangled_name) != 0 {
			return v.ir_mangled_name
		}
	case Entity_Procedure:
		if len(v.link_name) != 0 {
			return v.link_name
		}
	}

	// Case 3: no package -- builtins and the universe scope. Their symbol is their spelling.
	if e.pkg == nil {
		return e.token.text
	}

	// Case 4: the canonical name IS the symbol.
	//
	// GUARDED, and this is the second deliberate divergence. write_canonical_entity_name handles
	// exactly FIVE entity kinds -- TypeName, Constant, Procedure, AsmTemplate, Variable -- and
	// PANICS on anything else (C++: `default: GB_PANIC("TODO(bill): entity kind %d")`,
	// name_canonicalization.cpp). The port is faithful there and panics too.
	//
	// It said FOUR until #1242: upstream added Entity_AsmTemplate to that arm
	// (name_canonicalization.cpp:744) and both the count in this comment and the filter below
	// were stale. An asm template does get a linker symbol in the reference.
	//
	// That is safe in C++ because lb_get_entity_name is only ever reached from the backend, on
	// entities it is about to EMIT, and it never emits a builtin. It is NOT safe for an exported
	// library procedure: a consumer walking a package scope sees Entity_Builtin, Import_Name,
	// Library_Name, Label and Nil alongside the four, and the first builtin would abort the host
	// process (#12: the checker must not kill its caller).
	//
	// So kinds with no linker symbol return "" rather than panicking. This invents no name --
	// for the four kinds C++ handles the result is bit-for-bit what C++ produces; it only
	// replaces an abort with an empty answer for kinds C++ never asks about. Callers should treat
	// "" as "this entity has no symbol", which is the truth: builtins, imports, libraries and
	// labels are compile-time only and are never emitted by any backend.
	#partial switch _ in e.variant {
	case Entity_Type_Name, Entity_Constant, Entity_Procedure, Entity_Asm_Template, Entity_Variable:
		return string_canonical_entity_name(e, allocator)
	}
	return ""
}
