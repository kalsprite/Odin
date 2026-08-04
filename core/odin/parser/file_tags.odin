package odin_parser

import "base:runtime"
import "core:strings"
import "core:reflect"
import "core:slice"
import "core:unicode"
import "core:unicode/utf8"

import "../ast"
import "../tokenizer"

Private_Flag :: enum {
	Public,
	Package,
	File,
}

Build_Kind :: struct {
	os:   runtime.Odin_OS_Types,
	arch: runtime.Odin_Arch_Types,
	// C++ Reference: parser.cpp:6449-6452. `bedrock` is a build-tag term alongside the os/arch
	// terms, but it is a plain bool rather than a set, so it needs its own tri-state: nil means
	// the group said nothing about bedrock and matches either way. C++ spells the same thing as
	// `this_kind_correct = build_context.bedrock == !is_notted`, where a group that never mentions
	// bedrock simply never runs that line. LEDGER #340.
	bedrock: Maybe(bool),
}

// empty build kind acts as a marker for separating multiple lines with build tags
BUILD_KIND_NEWLINE_MARKER :: Build_Kind{}

File_Tags :: struct {
	build_project_name: [][]string,
	build:              []Build_Kind,
	private:            Private_Flag,
	ignore:             bool,
	lazy:               bool,
	no_instrumentation: bool,
}

@require_results
get_build_os_from_string :: proc(str: string) -> (found_os: runtime.Odin_OS_Type, found_subtarget: runtime.Odin_Platform_Subtarget_Type) {
	str_os, _, str_subtarget := strings.partition(str, ":")

	fields := reflect.enum_fields_zipped(runtime.Odin_OS_Type)
	for os in fields {
		if strings.equal_fold(os.name, str_os) {
			found_os = runtime.Odin_OS_Type(os.value)
			break
		}
	}
	if str_subtarget != "" {
		st_fields := reflect.enum_fields_zipped(runtime.Odin_Platform_Subtarget_Type)
		for subtarget in st_fields {
			if strings.equal_fold(subtarget.name, str_subtarget) {
				found_subtarget = runtime.Odin_Platform_Subtarget_Type(subtarget.value)
				break
			}
		}
	}

	return
}
@require_results
get_build_arch_from_string :: proc(str: string) -> runtime.Odin_Arch_Type {
	fields := reflect.enum_fields_zipped(runtime.Odin_Arch_Type)
	for os in fields {
		if strings.equal_fold(os.name, str) {
			return runtime.Odin_Arch_Type(os.value)
		}
	}
	return .Unknown
}

@require_results
parse_file_tags :: proc(file: ast.File, allocator := context.allocator) -> (tags: File_Tags) {
	next_char :: proc(src: string, i: ^int) -> (ch: u8) {
		if i^ < len(src) {
			ch = src[i^]
		}
		i^ += 1
		return
	}
	skip_whitespace :: proc(src: string, i: ^int) {
		for {
			switch next_char(src, i) {
			case ' ', '\t':
				continue
			case:
				i^ -= 1
				return
			}
		}
	}
	scan_value :: proc(src: string, i: ^int) -> string {
		start := i^
		for {
			switch next_char(src, i) {
			case ' ', '\t', '\n', '\r', 0, ',':
				i^ -= 1
				return src[start:i^]
			case:
				continue
			}
		}
	}

	parse_tag :: proc(text: string, tags: ^File_Tags, build_kinds: ^[dynamic]Build_Kind,
	                  build_project_name_strings: ^[dynamic]string,
	                  build_project_name_spans: ^[dynamic][2]int) {
		i := 0

		skip_whitespace(text, &i)

		if next_char(text, &i) == '+' {
			switch scan_value(text, &i) {
			case "ignore":
				tags.ignore = true
			case "lazy":
				tags.lazy = true
			case "no-instrumentation":
				tags.no_instrumentation = true
			case "private":
				skip_whitespace(text, &i)
				switch scan_value(text, &i) {
				case "file":
					tags.private = .File
				case "package", "":
					tags.private = .Package
				}
			case "build-project-name":
				// LEDGER #24 / #306: this used to publish `build_project_name_strings[index_start:]`
				// -- a slice INTO a [dynamic]string that later appends reallocate, and that the
				// tail of this procedure then `delete`s outright. Every group in
				// tags.build_project_name was therefore a dangling slice, and match_build_tags
				// reading name[0] SEGFAULTED: 15/15 runs on `#+build-project-name !`, reproduced
				// identically on three binaries predating this change, so long-standing rather
				// than new.
				//
				// Each group now gets its own allocation (see the clone below), so growing the
				// scratch array cannot invalidate a published group. Groups are recorded as index
				// pairs during the scan and materialised afterwards, because the scratch array is
				// still growing while the scan runs.
				//
				// An EMPTY group is still recorded, which matters: match_build_tags treats a group
				// with no names as vacuously correct, so `#+build-project-name` with no payload
				// must keep selecting the file. The old code got that from its `defer`.
				groups_loop: for {
					index_start := len(build_project_name_strings)

					for {
						skip_whitespace(text, &i)
						name_start := i

						switch next_char(text, &i) {
						case 0, '\r', '\n':
							i -= 1
							append(build_project_name_spans, [2]int{index_start, len(build_project_name_strings)})
							break groups_loop
						case ',':
							append(build_project_name_spans, [2]int{index_start, len(build_project_name_strings)})
							continue groups_loop
						case '!':
							// include ! in the name
						case:
							i -= 1
						}

						scan_value(text, &i)
						append(build_project_name_strings, text[name_start:i])
					}
				}
			case "build":

				if len(build_kinds) > 0 {
					append(build_kinds, BUILD_KIND_NEWLINE_MARKER)
				}

				kinds_loop: for {
					os_positive: runtime.Odin_OS_Types
					os_negative: runtime.Odin_OS_Types

					arch_positive: runtime.Odin_Arch_Types
					arch_negative: runtime.Odin_Arch_Types

					bedrock_required: Maybe(bool)

					defer append(build_kinds, Build_Kind{
						os      = (os_positive   == {} ? runtime.ALL_ODIN_OS_TYPES   : os_positive)  -os_negative,
						arch    = (arch_positive == {} ? runtime.ALL_ODIN_ARCH_TYPES : arch_positive)-arch_negative,
						bedrock = bedrock_required,
					})

					for {
						skip_whitespace(text, &i)

						is_notted: bool
						switch next_char(text, &i) {
						case 0, '\r', '\n':
							i -= 1
							break kinds_loop
						case ',':
							continue kinds_loop
						case '!':
							is_notted = true
						case:
							i -= 1
						}

						value := scan_value(text, &i)

						if value == "ignore" {
							tags.ignore = true
						} else if value == "bedrock" {
							// C++ parser.cpp:6449-6452. Was missing entirely: `bedrock` fell
							// through to the unknown-value case and was silently discarded, so
							// `#+build !bedrock` never excluded anything and the port checked
							// base/runtime's i128 and map files under -bedrock -- files upstream
							// skips. LEDGER #340.
							bedrock_required = !is_notted
						} else if os, subtarget := get_build_os_from_string(value); os != .Unknown {
							_ = subtarget // TODO(bill): figure out how to handle the subtarget logic
							if is_notted {
								os_negative += {os}
							} else {
								os_positive += {os}
							}
						} else if arch := get_build_arch_from_string(value); arch != .Unknown {
							if is_notted {
								arch_negative += {arch}
							} else {
								arch_positive += {arch}
							}
						}
					}
				}
			}
		}
	}

	context.allocator = allocator

	if file.docs == nil && file.tags == nil {
		return
	}

	build_kinds: [dynamic]Build_Kind
	build_project_names: [dynamic][]string

	// Scratch for the build-project-name scan. `spans` records each group as a [start, end) pair
	// into `strings`, because `strings` is still growing while the scan runs and a slice taken
	// mid-scan would be invalidated by the next append (LEDGER #24).
	build_project_name_strings: [dynamic]string
	build_project_name_spans:   [dynamic][2]int
	defer delete(build_project_name_spans)


	if file.docs != nil {
		for comment in file.docs.list {
			if len(comment.text) < 3 || comment.text[:2] != "//" {
				continue
			}
			text := comment.text[2:]

			parse_tag(text, &tags, &build_kinds, &build_project_name_strings, &build_project_name_spans)
		}
	}

	for tag in file.tags {
		if len(tag.text) < 3 || tag.text[:2] != "#+" {
			continue
		}
		// Only skip # because parse_tag skips the plus
		text := tag.text[1:]

		parse_tag(text, &tags, &build_kinds, &build_project_name_strings, &build_project_name_spans)
	}

	// Materialise the groups now that the scratch array has stopped growing. Each group is CLONED
	// so that it does not alias the scratch, which is freed immediately below; without this the
	// published groups dangle and match_build_tags segfaults reading name[0] (LEDGER #24).
	//
	// The clones are owned by the caller alongside the outer slice -- see destroy_file_tags.
	for span in build_project_name_spans {
		append(&build_project_names, slice.clone(build_project_name_strings[span[0]:span[1]]))
	}

	shrink(&build_kinds)
	shrink(&build_project_names)
	delete(build_project_name_strings)

	tags.build = build_kinds[:]
	tags.build_project_name = build_project_names[:]

	return
}

Build_Target :: struct {
	os:           runtime.Odin_OS_Type,
	arch:         runtime.Odin_Arch_Type,
	project_name: string,
	// Mirrors build_context.bedrock, which C++ reads as a global from inside the tag walk.
	bedrock:      bool,
}

@require_results
match_build_tags :: proc(file_tags: File_Tags, target: Build_Target) -> bool {

	project_name_correct := len(target.project_name) == 0 || len(file_tags.build_project_name) == 0

	for group in file_tags.build_project_name {
		group_correct := true
		for name in group {
			if name[0] == '!' {
				group_correct &&= target.project_name != name[1:]
			} else {
				group_correct &&= target.project_name == name
			}
		}
		project_name_correct ||= group_correct
	}

	os_and_arch_correct := true

	if len(file_tags.build) > 0 {
		os_and_arch_correct_line := false

		for kind in file_tags.build {
			if kind == BUILD_KIND_NEWLINE_MARKER {
				os_and_arch_correct &&= os_and_arch_correct_line
				os_and_arch_correct_line = false
			} else {
				// A group that never named `bedrock` carries nil and matches either way -- the
				// same effect as C++ never executing its bedrock line for that group.
				bedrock_ok := true
				if req, ok := kind.bedrock.?; ok {
					bedrock_ok = req == target.bedrock
				}
				os_and_arch_correct_line ||= target.os in kind.os && target.arch in kind.arch && bedrock_ok
			}
		}
		os_and_arch_correct &&= os_and_arch_correct_line
	}

	return !file_tags.ignore && project_name_correct && os_and_arch_correct
}

// =================================================================================================
// FILE-TAG DIAGNOSTICS
//
// C++ Reference: src/parser.cpp:6370-6387 (build_tag_get_token), 6390-6402
// (build_require_space_after), 6404-6517 (parse_build_tag), 6727-6776
// (parse_build_project_directory_tag).
//
// The procedures above this line decide INCLUSION and are silent. C++'s parse_build_tag does both
// jobs in one pass: it walks the tag and, on the way, reports six distinct malformed-tag errors.
// This package had the walk but none of the reporting, so `#+build bogusplatform`,
// `#+buildlinux`, `#+build linux windows` and friends were accepted without a word (LEDGER #306,
// probes bt_space / bt_bang / bt_comma / bt_subt / bt_plat / bt_projb).
//
// WHY THE DIAGNOSTIC WALK IS SEPARATE FROM THE INCLUSION WALK. The inclusion scanners above are
// long-standing and verified across the whole core tree; re-deriving inclusion from C++'s walk
// would put two answers to the same question in one file. Only this walk reports, and only the
// scanners above decide, so the two cannot contradict each other in output.
// =================================================================================================

// tag_is_letter / tag_is_digit mirror C++'s rune_is_letter / rune_is_digit (src/unicode.cpp:15-38).
// '_' COUNTS AS A LETTER there, which is why it is spelled out rather than deferred to
// unicode.is_letter.
@(private = "file")
tag_is_letter :: proc(r: rune) -> bool {
	if r < 0x80 {
		if r == '_' {
			return true
		}
		return (u32(r) | 0x20) - 0x61 < 26
	}
	return unicode.is_letter(r)
}

@(private = "file")
tag_is_digit :: proc(r: rune) -> bool {
	if r < 0x80 {
		return (u32(r) - '0') < 10
	}
	return unicode.is_number(r)
}

// tag_trim_whitespace mirrors C++'s string_trim_whitespace (src/string.cpp:333-348): ASCII
// whitespace from both ends, then trailing NULs, and rune_is_whitespace is exactly
// ' ' \t \n \r -- a narrower set than strings.trim_space would use.
@(private = "file")
tag_trim_whitespace :: proc(str: string) -> string {
	is_ws :: proc(c: u8) -> bool {
		switch c {
		case ' ', '\t', '\n', '\r':
			return true
		}
		return false
	}
	s := str
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

// C++ Reference: src/parser.cpp:6390-6402. The test is `!= ' '` specifically, so a TAB after the
// prefix is a diagnostic too.
@(private = "file")
tag_require_space_after :: proc(s: string, prefix: string) -> bool {
	if len(s) == len(prefix) {
		return false
	}
	stripped := tag_trim_whitespace(s[len(prefix):])
	if s[len(prefix)] != ' ' && len(stripped) != 0 {
		return true
	}
	return false
}

// build_tag_get_token peels one platform token off the front of `s`, writing the rest to `out`.
//
// C++ Reference: src/parser.cpp:6370-6387. Distinct from the vet/feature peeler: it accepts ':'
// (for `darwin:iphone`) but NOT '-'. A leading '!' is kept in the token. When a terminating rune
// appears FIRST the token is that single rune, which is what makes a bare `,` come back as ","
// and end the group.
@(private = "file")
build_tag_get_token :: proc(str: string, out: ^string) -> string {
	s := tag_trim_whitespace(str)
	n := 0
	for n < len(s) {
		r, width := utf8.decode_rune_in_string(s[n:])
		if n == 0 && r == '!' {
			// kept in the token
		} else if !tag_is_letter(r) && !tag_is_digit(r) && r != ':' {
			k := max(max(n, width), 1)
			out^ = s[k:]
			return s[:k]
		}
		n += width
	}
	out^ = ""
	return s
}

// tag_subtarget_valid mirrors the subtarget half of get_target_os_from_string
// (src/build_settings.cpp:962-983) together with parse_build_tag's iOS special case (6468-6478).
//
// The names are matched as STRINGS, exactly as C++ matches subtarget_strings, rather than against
// runtime.Odin_Platform_Subtarget_Type -- that enum does not carry every name C++ accepts
// (playdate), and matching it would reject tags the reference allows.
@(private = "file")
tag_subtarget_valid :: proc(sub: string) -> bool {
	if len(sub) == 0 {
		return true // no ':' at all -- Subtarget_Default
	}
	switch {
	case strings.equal_fold(sub, "generic"),
	     strings.equal_fold(sub, "default"),
	     strings.equal_fold(sub, "iphone"),
	     strings.equal_fold(sub, "iphonesimulator"),
	     strings.equal_fold(sub, "android"),
	     strings.equal_fold(sub, "playdate"),
	     // parse_build_tag accepts the pseudo-subtarget "ios" even though it is not one of
	     // subtarget_strings; it maps onto iPhone/iPhoneSimulator at match time.
	     strings.equal_fold(sub, "ios"):
		return true
	}
	return false
}

// report_build_tag emits the five diagnostics of C++'s parse_build_tag.
//
// C++ Reference: src/parser.cpp:6404-6517. Control flow is reproduced, not just the messages:
// each error `break`s the inner group loop, so at most one fires per comma-separated group, and a
// group that has already reported is not also reported against for a later token in it.
// Public so the CHECKER's single ordered tag walk can drive it per tag: C++ handles every tag
// kind in one loop in source order (parser.cpp:6893-6900), and the vet/feature flag tables live
// checker-side, so the loop has to live there and call in here. LEDGER #308.
report_build_tag :: proc(err: Error_Handler, pos: tokenizer.Pos, str: string) {
	PREFIX :: "build"
	if tag_require_space_after(str, PREFIX) {
		err(pos, "Expected a space after #+%s", PREFIX)
		return
	}
	s := tag_trim_whitespace(str[len(PREFIX):])
	if len(s) == 0 {
		return
	}

	for len(s) > 0 {
		os_seen := false
		arch_seen := false
		num_tokens := 0

		group: for {
			p := tag_trim_whitespace(build_tag_get_token(s, &s))
			if len(p) == 0 {
				break group
			}
			if p == "," {
				break group
			}

			if p[0] == '!' {
				p = p[1:]
				if len(p) == 0 {
					err(pos, "Expected a build platform after '!'")
					break group
				}
			}

			// C++ continues past these without any platform check.
			if p == "ignore" || p == "bedrock" {
				continue group
			}

			os_str, _, sub_str := strings.partition(p, ":")
			os, _ := get_build_os_from_string(p)
			arch := get_build_arch_from_string(p)
			_ = os_str
			num_tokens += 1

			// Catches 'windows linux', and more than two things in one comma group.
			if num_tokens > 2 ||
			   (os_seen && os != .Unknown) ||
			   (arch_seen && arch != .Unknown) {
				err(
					pos,
					"Invalid build tag: Missing ',' before '%s'. Format: '#+build linux, windows amd64, darwin'",
					p,
				)
				break group
			}

			if !tag_subtarget_valid(sub_str) {
				err(pos, "Invalid subtarget '%s'.", sub_str)
				break group
			}

			if os != .Unknown {
				os_seen = true
			} else if arch != .Unknown {
				arch_seen = true
			}

			if os == .Unknown && arch == .Unknown {
				err(pos, "Invalid build tag platform: %s", p)
				break group
			}

			if len(s) == 0 {
				break group
			}
		}
	}
}

// C++ Reference: src/parser.cpp:6727-6776. Only one diagnostic here; the rest of that procedure
// is project-name matching, which the scanners above already do.
// Public for the same reason as report_build_tag.
report_build_project_name_tag :: proc(err: Error_Handler, pos: tokenizer.Pos, str: string) {
	PREFIX :: "build-project-name"
	s := tag_trim_whitespace(str[len(PREFIX):])
	if len(s) == 0 {
		return
	}
	for len(s) > 0 {
		group: for {
			p := tag_trim_whitespace(build_tag_get_token(s, &s))
			if len(p) == 0 {
				break group
			}
			if p == "," {
				break group
			}
			if p[0] == '!' {
				p = p[1:]
				if len(p) == 0 {
					err(pos, "Expected a build-project-name after '!'")
					break group
				}
			}
			if len(s) == 0 {
				break group
			}
		}
	}
}

// report_file_tag_diagnostics reports the malformed-tag errors for one file's `#+` lines.
//
// It is deliberately SEPARATE from parse_file_tags, which has two callers in the checker (one to
// decide inclusion at collect time, one to read the flags after the parse) and must stay silent
// so that neither call double-reports. This is called exactly once per file, at collect time,
// which is also the only point at which a file the build tags EXCLUDE is still in hand -- C++
// reports from inside parse_file_tag and only then returns false to exclude, so a malformed tag
// on an excluded file still reports there. LEDGER #306.
report_file_tag_diagnostics :: proc(file: ast.File, err: Error_Handler) {
	if err == nil {
		return
	}
	for tok in file.tags {
		if len(tok.text) < 3 || tok.text[:2] != "#+" {
			continue
		}
		lt := tag_trim_whitespace(tok.text[2:])
		switch {
		case strings.has_prefix(lt, "build-project-name"):
			report_build_project_name_tag(err, tok.pos, lt)
		case strings.has_prefix(lt, "build"):
			report_build_tag(err, tok.pos, lt)
		}
	}
}
