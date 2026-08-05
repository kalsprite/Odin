package checker

/*
	File-tag parsing: the `#+...` lines that precede a package declaration.

	C++ Reference: src/parser.cpp:6390-6402 (build_require_space_after),
	                            6519-6536 (vet_tag_get_token),
	                            6539-6597 (parse_vet_tag),
	                            6599-6682 (parse_feature_tag),
	                            6772-6820 (parse_file_tag),
	                            6893-6900 (the loop that drives it, inside parse_file).

	WHY THIS LIVES IN THE CHECKER AND NOT IN core:odin/parser

	C++ parses file tags inside parse_file, so the diagnostics they produce are counted by
	any_errors() and therefore stop the compile before check_parsed_files ever runs
	(src/main.cpp:4257-4260; the port's equivalent gate is the `error_count() > 0` bail in
	check_package_from_path). core:odin/parser has no notion of vet or feature flags at all --
	File_Tags carries build/private/ignore/lazy/no-instrumentation and nothing else -- so the
	port runs this pass immediately after parser.parse_package, which is still on the parse side
	of that gate. Probe vettag6 pins the behaviour being reproduced: a bad tag in one file of a
	package suppresses the semantic diagnostics of every OTHER file in it too.

	SPLIT OF RESPONSIBILITY WITH parser.parse_file_tags

	The build / build-project-name / test / ignore arms of C++'s parse_file_tag exist to return
	false, which aborts parse_file and so excludes the file. The port makes that decision earlier,
	in collect_package_for_target, which never hands an excluded file to the parser in the first
	place; and private / lazy / no-instrumentation are applied from parser.parse_file_tags in
	check_files.odin. Those arms are therefore present here only so that the catch-all below does
	not mistake a recognised tag for an unknown one -- exactly the role they play in C++'s
	if/else chain, which tests them for their prefix and then falls through.
*/

import "core:strings"
import "core:unicode/utf8"

import "../ast"
import "../parser"
import "../tokenizer"

// string_trim_whitespace trims ASCII whitespace from both ends, and trailing NUL bytes.
//
// C++ Reference: src/string.cpp:333-348. The NUL pass is not incidental: it runs BETWEEN the
// trailing-whitespace pass and the leading-whitespace pass, and rune_is_whitespace
// (src/unicode.cpp:63-72) recognises exactly ' ', '\t', '\n' and '\r' -- not the wider set
// strings.trim_space would use.
@(private = "file")
string_trim_whitespace :: proc(str: string) -> string {
	s := str
	is_ws :: proc(c: u8) -> bool {
		switch c {
		case ' ', '\t', '\n', '\r':
			return true
		}
		return false
	}
	for len(s) > 0 && is_ws(s[len(s) - 1]) {
		s = s[:len(s) - 1]
	}
	for len(s) > 0 && s[len(s) - 1] == 0 {
		s = s[:len(s) - 1]
	}
	for len(s) > 0 && is_ws(s[0]) {
		s = s[1:]
	}
	return s
}

// build_require_space_after reports whether `s` carries a payload that is not separated from
// `prefix` by a space -- `#+vetstyle` rather than `#+vet style`.
//
// C++ Reference: src/parser.cpp:6390-6402. Note that the test is `!= ' '` specifically, not
// "is not whitespace": a tab after the prefix is a diagnostic in C++ too.
@(private = "file")
build_require_space_after :: proc(s: string, prefix: string) -> bool {
	assert(strings.has_prefix(s, prefix))

	if len(s) == len(prefix) {
		return false
	}
	stripped := string_trim_whitespace(s[len(prefix):])

	if s[len(prefix)] != ' ' && len(stripped) != 0 {
		return true
	}
	return false
}

// vet_tag_get_token peels one flag name off the front of `s`, writing the remainder to `out`.
//
// C++ Reference: src/parser.cpp:6519-6536.
//
// A leading '!' is kept as part of the token (the callers strip it themselves so they can
// diagnose a bare '!'). Any other rune that is not a letter, digit, '-' -- or ':' when
// allow_colon is set, which is what lets `integer-division-by-zero:trap` survive as one token --
// terminates the token. Crucially, when such a rune appears FIRST the token returned is that
// single rune, so `#+vet style;extra` yields "style" and then ";", and the caller reports ";" as
// an invalid flag name rather than silently skipping it.
@(private = "file")
vet_tag_get_token :: proc(str: string, out: ^string, allow_colon: bool) -> string {
	s := string_trim_whitespace(str)
	n := 0
	for n < len(s) {
		r, width := utf8.decode_rune_in_string(s[n:])
		if n == 0 && r == '!' {
			// Kept in the token; see the note above.
		} else if !is_letter(r) && !is_digit(r) && r != '-' && !(allow_colon && r == ':') {
			k := max(max(n, width), 1)
			out^ = s[k:]
			return s[:k]
		}
		n += width
	}
	out^ = ""
	return s
}

// parse_vet_tag parses a `#+vet ...` line, layering it over the flags already in force.
//
// C++ Reference: src/parser.cpp:6539-6597.
@(private = "file")
parse_vet_tag :: proc(token_for_pos: tokenizer.Token, str: string, base_vet_flags: Vet_Flag) -> Vet_Flag {
	PREFIX :: "vet"
	assert(strings.has_prefix(str, PREFIX))

	if build_require_space_after(str, PREFIX) {
		syntax_error(token_for_pos, "Expected a space after #+%s", PREFIX)
		// C++ writes `return true` from a function returning u64 (parser.cpp:6544), so the
		// file ends up with flag bit 0 -- VetFlag_Shadowing -- set. That is an upstream slip,
		// not a rule; it is reproduced here because the file's vet state is observable and
		// diverging from it would show up as a real diagnostic difference.
		return {.Shadowing}
	}
	s := string_trim_whitespace(str[len(PREFIX):])

	vet_flags := base_vet_flags

	// A bare `#+vet` turns everything on.
	if len(s) == 0 {
		vet_flags |= Vet_Flag_All
	}

	for len(s) > 0 {
		p := string_trim_whitespace(vet_tag_get_token(s, &s, false))
		if len(p) == 0 {
			break
		}

		is_notted := false
		if p[0] == '!' {
			is_notted = true
			p = p[1:]
			if len(p) == 0 {
				syntax_error(token_for_pos, "Expected a vet flag name after '!'")
				return vet_flags
			}
		}

		flag := get_vet_flag_from_name(p)
		if flag != {} {
			if is_notted {
				vet_flags &~= flag
			} else {
				vet_flags |= flag
			}
		} else {
			begin_error_block()
			syntax_error(token_for_pos, "Invalid vet flag name: %s", p)
			error_line("\tExpected one of the following\n")
			error_line("\tunused\n")
			error_line("\tunused-variables\n")
			error_line("\tunused-imports\n")
			error_line("\tunused-procedures\n")
			error_line("\tshadowing\n")
			error_line("\tusing-stmt\n")
			error_line("\tusing-param\n")
			error_line("\tstyle\n")
			// "extra" is listed by C++ but is still NOT accepted by get_vet_flag_from_name
			// (src/build_settings.cpp:328-357). Reproduced verbatim: the list is output.
			//
			// "semicolon" and "deprecated" used to be missing here too -- accepted by the
			// name lookup but absent from the list. Upstream added them (parser.cpp:6589-6590)
			// and the port follows. LEDGER #385.
			error_line("\textra\n")
			error_line("\tsemicolon\n")
			error_line("\tdeprecated\n")
			error_line("\tcast\n")
			error_line("\ttabs\n")
			error_line("\texplicit-allocators\n")
			end_error_block()
			return vet_flags
		}
	}

	return vet_flags
}

// parse_feature_tag parses a `#+feature ...` line.
//
// C++ Reference: src/parser.cpp:6599-6682.
//
// Unlike vet, feature flags do not layer over a base: the positive and negative names are
// accumulated separately and combined at the end, and a line consisting only of notted names
// resolves to nothing at all rather than to "everything except those".
@(private = "file")
parse_feature_tag :: proc(token_for_pos: tokenizer.Token, str: string) -> Opt_In_Feature_Flag {
	PREFIX :: "feature"
	assert(strings.has_prefix(str, PREFIX))

	if build_require_space_after(str, PREFIX) {
		syntax_error(token_for_pos, "Expected a space after #+%s", PREFIX)
		// Same upstream `return true` as parse_vet_tag; here bit 0 is DynamicLiterals.
		return {.Dynamic_Literals}
	}
	s := string_trim_whitespace(str[len(PREFIX):])

	if len(s) == 0 {
		return {}
	}

	feature_flags: Opt_In_Feature_Flag
	feature_not_flags: Opt_In_Feature_Flag

	for len(s) > 0 {
		p := string_trim_whitespace(vet_tag_get_token(s, &s, true))
		if len(p) == 0 {
			break
		}

		is_notted := false
		if p[0] == '!' {
			is_notted = true
			p = p[1:]
			if len(p) == 0 {
				syntax_error(token_for_pos, "Expected a feature flag name after '!'")
				return {}
			}
		}

		flag := get_feature_flag_from_name(p)
		if flag != {} {
			if is_notted {
				feature_not_flags |= flag
			} else {
				feature_flags |= flag
			}
			if is_notted {
				// C++ lists Trap, Zero and AllBits here but NOT Self (parser.cpp:6638-6643),
				// so `#+feature !integer-division-by-zero:self` is accepted in silence.
				NO_NOT :: Opt_In_Feature_Flag{
					.Integer_Division_By_Zero_Trap,
					.Integer_Division_By_Zero_Zero,
					.Integer_Division_By_Zero_All_Bits,
				}
				if flag & NO_NOT != {} {
					syntax_error(token_for_pos, "Feature flag does not support notting with '!' - '%s'", p)
				}
			}
		} else {
			begin_error_block()
			syntax_error(token_for_pos, "Invalid feature flag name: %s", p)
			error_line("\tExpected one of the following\n")
			error_line("\tdynamic-literals\n")
			error_line("\tglobal-context\n")
			error_line("\tusing-stmt\n")
			error_line("\tinteger-division-by-zero:trap\n")
			error_line("\tinteger-division-by-zero:zero\n")
			error_line("\tinteger-division-by-zero:self\n")
			error_line("\tinteger-division-by-zero:all-bits\n")
			end_error_block()
			return {}
		}
	}

	res: Opt_In_Feature_Flag

	if feature_flags == {} && feature_not_flags == {} {
		res = {}
	} else if feature_flags == {} && feature_not_flags != {} {
		res = {} &~ feature_not_flags
	} else if feature_flags != {} && feature_not_flags == {} {
		res = feature_flags
	} else {
		res = feature_flags &~ feature_not_flags
	}

	if card(res & Opt_In_Feature_Flag_Integer_Division_By_Zero_All) > 1 {
		syntax_error(token_for_pos, "Only one integer-division-by-zero feature flag can be enabled")
	}

	return res
}

// parse_file_tag dispatches one `#+` tag, with the tag text already stripped of its `#+` and
// trimmed.
//
// C++ Reference: src/parser.cpp:6772-6820.
//
// The prefix tests are `string_starts_with`, not equality, for every arm except the last two --
// so `#+ignoreme` is an ignore tag but `#+lazyish` is an unknown one. That asymmetry is C++'s
// and is reproduced exactly, because the catch-all at the end is the only thing standing between
// a mistyped tag and silence.
@(private = "file")
parse_file_tag :: proc(lc: string, tok: tokenizer.Token, f: ^ast.File) {
	switch {
	case strings.has_prefix(lc, "build-project-name"):
		// Exclusion is decided in collect_package_for_target; see the header note.
	case strings.has_prefix(lc, "build"):
		// Ditto.
	case strings.has_prefix(lc, "vet"):
		f.vet_flags = transmute(ast.Vet_Flags)parse_vet_tag(tok, lc, ast_file_vet_flags(f))
		f.vet_flags_set = true
	case strings.has_prefix(lc, "test"):
		// C++ excludes the file unless the command is `odin test`; the port has no test
		// command, so there is nothing to gate.
	case strings.has_prefix(lc, "ignore"):
		// Exclusion is decided in collect_package_for_target.
	case strings.has_prefix(lc, "private"):
		// Applied from parser.parse_file_tags in check_files.odin.
	case strings.has_prefix(lc, "feature"):
		f.feature_flags |= transmute(ast.Feature_Flags)parse_feature_tag(tok, lc)
		f.feature_flags_set = true
	case lc == "lazy":
		// Applied from parser.parse_file_tags in check_files.odin.
	case lc == "no-instrumentation":
		// Ditto.
	case:
		syntax_error(tok, "Unknown tag '%s'", lc)
	}
}

// check_file_tags is the port's parse_file_tag LOOP: one ordered walk over a file's `#+` lines.
//
// C++ Reference: src/parser.cpp:6893-6900 --
//     for (Token const &tok : tags) {
//         String lt = string_trim_whitespace(substring(tok.string, 2, tok.string.len));
//         if (parse_file_tag(lt, tok, f) == false) { return false; }
//     }
// Two properties of that loop are load-bearing and were BOTH missing:
//
//   SOURCE ORDER, ONE PASS. The port had two independent passes -- build diagnostics at collect
//   time, vet/feature/unknown after the parse -- so a file could get one and not the other.
//   Probe bt_order2 (`#+vet bogusname` then `#+build windows`): the reference reports the bad vet
//   flag and only THEN excludes, while the port dropped the file before its vet pass ever ran and
//   said nothing. Now every kind is dispatched from this one loop, in C++'s prefix order.
//
//   STOP AT THE FIRST EXCLUDING TAG. `return false` ends the loop, so tags AFTER an excluding one
//   are never examined. Probe bt_order (`#+build windows` then `#+vet bogusname`) must therefore
//   stay silent -- and it did before this change too, but by accident rather than by rule.
//
// Exclusion is asked of match_build_tags one tag at a time rather than re-derived here: that
// keeps a single source of truth for "does this tag select the file", which the collect loop and
// this walk must agree on.
//
// WHY IT RUNS AT COLLECT TIME. This is the only point where a build-EXCLUDED file is still in
// hand; C++ reports from inside parse_file_tag and only afterwards returns false to exclude.
// `saw_package` is the caller's header scan telling us a package clause exists -- without one C++
// bails at parser.cpp:6862 long before the tag loop, so such a file yields no tag diagnostics at
// all (LEDGER #307, probes vt_nopkg/vt_nopkg2).
check_file_tags_for_file :: proc(file: ^ast.File, tags: []tokenizer.Token, saw_package: bool, target: parser.Build_Target) {
	if file == nil || !saw_package {
		return
	}

	for tok in tags {
		if len(tok.text) < 3 || tok.text[:2] != "#+" {
			continue
		}
		lt := string_trim_whitespace(tok.text[2:])

		// C++'s prefix chain, in its order -- `build-project-name` before `build`, and the last
		// two by exact match so `#+lazyish` is an unknown tag while `#+ignoreme` is an ignore.
		switch {
		case strings.has_prefix(lt, "build-project-name"):
			parser.report_build_project_name_tag(syntax_error_pos, tok.pos, lt)
		case strings.has_prefix(lt, "build"):
			parser.report_build_tag(syntax_error_pos, tok.pos, lt)
		case strings.has_prefix(lt, "vet"):
			file.vet_flags = transmute(ast.Vet_Flags)parse_vet_tag(tok, lt, ast_file_vet_flags(file))
			file.vet_flags_set = true
		case strings.has_prefix(lt, "test"):
			// C++ excludes unless the command is `odin test`; the port has no test command.
		case strings.has_prefix(lt, "ignore"):
			// Exclusion only, handled below.
		case strings.has_prefix(lt, "private"):
			// Applied from parser.parse_file_tags in check_files.odin.
		case strings.has_prefix(lt, "feature"):
			file.feature_flags |= transmute(ast.Feature_Flags)parse_feature_tag(tok, lt)
			file.feature_flags_set = true
		case lt == "lazy":
			// Applied from parser.parse_file_tags in check_files.odin.
		case lt == "no-instrumentation":
			// Ditto.
		case:
			syntax_error(tok, "Unknown tag '%s'", lt)
		}

		// Does THIS tag exclude the file? If so the reference stops here and later tags are
		// never seen. Only the selecting kinds can exclude; asking about the others would be a
		// wasted parse.
		switch {
		case strings.has_prefix(lt, "build"), strings.has_prefix(lt, "ignore"):
			stub: ast.File
			stub.fullpath = file.fullpath
			stub.src = file.src
			append(&stub.tags, tok)
			defer delete(stub.tags)
			t := parser.parse_file_tags(stub, context.temp_allocator)
			if !parser.match_build_tags(t, target) {
				return
			}
		}
	}
}
