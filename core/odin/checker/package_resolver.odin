package checker

/*
Package Resolver for the Odin Checker

This module handles recursive package loading and import path resolution.
It enables the checker to work on real codebases by:
1. Resolving import paths like "core:fmt" to filesystem paths
2. Parsing imported packages recursively
3. Adding packages to the checker's package map

C++ Reference: The C++ compiler handles this in the parser phase before
checking. Our implementation does it as a pre-check step.
*/

import "base:runtime"

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// resolve_import_path converts an import path to a filesystem path
// Examples:
//   "core:fmt"     -> ODIN_ROOT/core/fmt
//   "base:runtime" -> ODIN_ROOT/base/runtime
//   "vendor:raylib" -> ODIN_ROOT/vendor/raylib
//   "./relative"   -> current_pkg_dir/relative
//   "../parent"    -> current_pkg_dir/../parent
resolve_import_path :: proc(import_path_raw: string, current_pkg_path: string, allocator := context.temp_allocator) -> (fullpath: string, ok: bool) {
	if len(import_path_raw) == 0 {
		return "", false
	}

	// Strip quotes from the import path (parser may include them)
	import_path := import_path_raw
	if len(import_path) >= 2 && import_path[0] == '"' && import_path[len(import_path) - 1] == '"' {
		import_path = import_path[1:len(import_path) - 1]
	}

	// Check for collection path (contains colon, not Windows drive letter)
	colon_idx := strings.index_byte(import_path, ':')
	if colon_idx > 0 {
		// Check if it's a Windows drive letter (single letter before colon)
		if colon_idx == 1 && len(import_path) > 2 && (import_path[2] == '/' || import_path[2] == '\\') {
			// Windows absolute path like "C:/path"
			return import_path, true
		}

		// Collection path like "core:fmt" or "base:runtime"
		collection := import_path[:colon_idx]
		path_part := import_path[colon_idx + 1:]

		// Get ODIN_ROOT
		odin_root := build_context.ODIN_ROOT
		if len(odin_root) == 0 {
			// Try to get from environment
			odin_root = os.get_env("ODIN_ROOT", allocator)
		}

		if len(odin_root) == 0 {
			return "", false
		}

		// Build: ODIN_ROOT/collection/path
		join_err: runtime.Allocator_Error
		fullpath, join_err = filepath.join({odin_root, collection, path_part}, allocator)
		if join_err != nil {
			return "", false
		}
		return fullpath, true
	}

	// Relative or absolute path
	if import_path[0] == '/' || import_path[0] == '\\' {
		// Absolute path
		return import_path, true
	}

	if strings.has_prefix(import_path, "./") || strings.has_prefix(import_path, "../") {
		// Relative to current package
		if len(current_pkg_path) == 0 {
			return "", false
		}
		join_err: runtime.Allocator_Error
		fullpath, join_err = filepath.join({current_pkg_path, import_path}, allocator)
		if join_err != nil {
			return "", false
		}
		// Clean the path to resolve ../ and ./
		abs_err: os.Error
		fullpath, abs_err = filepath.abs(fullpath, allocator)
		if abs_err != nil {
			return "", false
		}
		return fullpath, true
	}

	// Just a name - treat as relative to current package
	if len(current_pkg_path) > 0 {
		join_err: runtime.Allocator_Error
		fullpath, join_err = filepath.join({current_pkg_path, import_path}, allocator)
		if join_err != nil {
			return "", false
		}
		return fullpath, true
	}

	return import_path, true
}

// Package_Load_Result contains the result of loading packages
Package_Load_Result :: struct {
	packages:     [dynamic]^ast.Package,
	parse_errors: int,
	total_files:  int,
}

// Reserved packages that are synthesized by the compiler rather than parsed from source.
//
// `base:runtime` is deliberately NOT in this list. It is an ordinary package whose source is
// parsed and checked like any other - the only thing special about it is that it is seeded
// first and carries ast.Package_Kind.Runtime (see seed_runtime_package). The C++ compiler draws
// the same line: is_package_name_reserved (src/parser.cpp:6112) names only "builtin" and
// "intrinsics", and determine_path_from_string short-circuits the path resolution only for
// those two (src/parser.cpp:6236), while runtime is added through the normal
// try_add_import_path machinery (src/parser.cpp:7070).
//
// builtin and intrinsics stay here because they genuinely have no source to parse: C++
// synthesizes them in init_universal (src/checker.cpp:1113) and stamps
// pkg->kind = Package_Builtin (src/checker.cpp:1035). They are populated by
// init_builtin_packages / populate_builtin_package_scope, not by the loader.
RESERVED_PACKAGES :: []string{
	"builtin",
	"intrinsics",
	"base:builtin",
	"base:intrinsics",
}

// RUNTIME_IMPORT_PATH is the import path the loader seeds base:runtime under.
//
// It is spelled as a collection path rather than a bare filesystem path so that it resolves
// through the same resolve_import_path that every `import "base:runtime"` in the tree goes
// through, and so that it lands in info.packages under exactly the key those imports will look
// it up by. C++ reaches the same place with get_fullpath_base_collection("runtime")
// (src/parser.cpp:7067).
RUNTIME_IMPORT_PATH :: "base:runtime"

// is_reserved_package checks if an import path refers to a reserved/builtin package
is_reserved_package :: proc(import_path: string) -> bool {
	for reserved in RESERVED_PACKAGES {
		if import_path == reserved {
			return true
		}
	}
	return false
}

// current_build_target describes the platform being checked, in the vocabulary
// core:odin/parser's build-tag matcher speaks.
//
// It is derived from build_context.metrics - the target init_build_context was given - and
// deliberately NOT from the ODIN_OS/ODIN_ARCH constants of the process running the checker.
// Those constants describe the host, and baking the host in would make it impossible to check
// a package for any platform other than the one the checker happens to be running on. The C++
// compiler reads build_context.metrics in exactly the same places (parse_build_tag,
// is_excluded_target_filename), so this keeps the two in step under cross-checking too.
current_build_target :: proc() -> parser.Build_Target {
	return parser.Build_Target{
		os           = odin_os_from_target_os(build_context.metrics.os),
		arch         = odin_arch_from_target_arch(build_context.metrics.arch),
		project_name = build_context.ODIN_BUILD_PROJECT_NAME,
	}
}

// odin_os_from_target_os maps the checker's target OS enum onto runtime.Odin_OS_Type.
//
// Essence and Haiku have no counterpart: the C++ compiler retired both targets and
// runtime.Odin_OS_Type never carried them. They map to .Unknown, which no `#+build` tag can
// name, so when one of them is the target every tagged file is excluded. That is a degenerate
// answer, but those two are already dead entries in Target_Os_Kind (see the stale-constants
// parity task) and no Target_Metrics in named_targets selects them.
@(private = "file")
odin_os_from_target_os :: proc(os_kind: Target_Os_Kind) -> runtime.Odin_OS_Type {
	switch os_kind {
	case .Windows:      return .Windows
	case .Darwin:       return .Darwin
	case .Linux:        return .Linux
	case .Freebsd:      return .FreeBSD
	case .Openbsd:      return .OpenBSD
	case .Netbsd:       return .NetBSD
	case .Wasi:         return .WASI
	case .Js:           return .JS
	case .Orca:         return .Orca
	case .Freestanding: return .Freestanding
	case .Invalid:
		return .Unknown
	}
	return .Unknown
}

// odin_arch_from_target_arch maps the checker's target arch enum onto runtime.Odin_Arch_Type.
@(private = "file")
odin_arch_from_target_arch :: proc(arch_kind: Target_Arch_Kind) -> runtime.Odin_Arch_Type {
	switch arch_kind {
	case .Amd64:     return .amd64
	case .I386:      return .i386
	case .Arm32:     return .arm32
	case .Arm64:     return .arm64
	case .Wasm32:    return .wasm32
	case .Wasm64p32: return .wasm64p32
	case .Riscv64:   return .riscv64
	case .Invalid:
		return .Unknown
	}
	return .Unknown
}

// file_header_selects_target reports whether a file's `#+build` tags admit the target.
//
// The tags live inside the file, but they must be answered BEFORE the file is parsed. The C++
// compiler evaluates them in parse_file (src/parser.cpp:6889) immediately after the package
// clause and returns false on a mismatch, so the declarations of an excluded file are never
// parsed at all. Filtering a fully parsed file instead would be too late: the body of, say, a
// windows-only file would already have produced its syntax errors, which is precisely the noise
// this filter exists to remove.
//
// So this re-walks just the file header with the tokenizer - the same loop parse_file uses to
// gather tags - and stops at the `package` token. Tokenizer errors are swallowed here because
// the real parse re-reports them for every file that survives the filter; reporting them from
// the prescan as well would double them up, and reporting them for an excluded file would
// reintroduce the noise.
// #215: C++ evaluates the tags INSIDE parse_file, and the loop that bails on a mismatch
// (src/parser.cpp:6894) sits BELOW the package-clause checks at 6874-6890. So a file the tags
// exclude has already had its package clause validated, and C++ reports:
//
//	Expected only comments or lines starting with '#+' before the package declaration
//	Invalid package name '_'
//	Use of reserved package name 'X'
//
// and nothing else -- measured with probe tagord, where a body error (`x :: 1 +`) in an
// excluded file is correctly silent on both sides. The port answered the tags before parsing
// at all, so it emitted none of the three. Those checks are replayed here, on the excluded
// path only; files that survive get them from the real parse as before.
@(private = "file")
file_header_selects_target :: proc(fullpath: string, src: string, target: parser.Build_Target, kind: ast.Package_Kind) -> bool {
	t: tokenizer.Tokenizer
	tokenizer.init(&t, src, fullpath, nil)
	if t.ch <= 0 {
		return true
	}

	stub: ast.File
	stub.fullpath = fullpath
	stub.src = src
	defer delete(stub.tags)

	// Mirrors parser.parse_file: collect the file tags that precede the package declaration,
	// skipping comments and stepping over anything else (an invalid token before `package` is
	// the real parse's business to complain about, not ours).
	invalid_pre_package_token: Maybe(tokenizer.Token)
	saw_package := false
	scan_header: for {
		tok := tokenizer.scan(&t)
		// Comments and stray tokens fall through the switch and keep the scan going.
		#partial switch tok.kind {
		case .Package:
			saw_package = true
			break scan_header
		case .EOF:
			break scan_header
		case .File_Tag:
			append(&stub.tags, tok)
		case .Comment:
		// #215: anything else before `package` is what C++ records as first_invalid_token.
		case:
			if invalid_pre_package_token == nil {
				invalid_pre_package_token = tok
			}
		}
	}
	pkg_name_tok: tokenizer.Token
	if saw_package {
		pkg_name_tok = tokenizer.scan(&t)
	}

	// NOTE: stub.docs is left nil on purpose. parse_file_tags will also honour tags written as
	// `//+build` doc comments, but the C++ compiler recognises only `#+` file tags, so feeding
	// it the doc comments would exclude files the compiler would have kept.
	tags := parser.parse_file_tags(stub, context.allocator)
	defer {
		delete(tags.build)
		delete(tags.build_project_name)
	}

	if parser.match_build_tags(tags, target) {
		return true
	}

	// Excluded. Replay the package-clause diagnostics C++ has already emitted by this point.
	// C++ Reference: src/parser.cpp:6872-6891 -- the invalid-token check RETURNS, so at most
	// one of these fires per file.
	if ippt, ok := invalid_pre_package_token.?; ok {
		syntax_error_pos(ippt.pos, "Expected only comments or lines starting with '#+' before the package declaration")
	} else if saw_package && pkg_name_tok.kind == .Ident {
		switch name := pkg_name_tok.text; {
		case name == "_":
			syntax_error_pos(pkg_name_tok.pos, "Invalid package name '_'")
		case parser.is_package_name_reserved(name), kind != .Runtime && name == "runtime":
			syntax_error_pos(pkg_name_tok.pos, "Use of reserved package name '%s'", name)
		}
	}
	return false
}

// collect_package_for_target reads a package directory into an unparsed ^ast.Package, admitting
// only the files that belong to the target being checked.
//
// This replaces parser.collect_package, which parses every .odin file in the directory
// regardless of platform. Two independent mechanisms decide what belongs, and BOTH are needed -
// neither subsumes the other:
//
//  1. The filename suffix. core/sys/darwin/mach_darwin.odin carries no tag whatsoever; a
//     trailing `_<os>`, `_<arch>` or `_<os>_<arch>` component on the file name is the only thing
//     that marks it darwin-only. Applied here before the file is even read, mirroring
//     try_add_import_path (src/parser.cpp:5996), which filters the directory listing through
//     is_excluded_target_filename.
//
//  2. The `#+build` tag. core/os/wasm.odin, core/sys/windows/winver.odin and
//     core/fmt/example.odin are named neutrally and can only be excluded by their tag. Applied
//     after the source is read (the tag is in the source) but before it is parsed - see
//     file_header_selects_target.
//
// Excluded files never enter pkg.files, so they cannot be counted in total_files and cannot
// contribute a parse error.
//
// `kind` is stamped on the package here, before a single file is parsed, because the parser
// reads it: parse_file rejects `package runtime` unless file.pkg.kind is .Runtime
// (core/odin/parser/parser.odin:196, a copy of src/parser.cpp:6887). The C++ compiler has the
// same ordering constraint and solves it the same way - try_add_import_path takes the kind as
// an argument and assigns it (src/parser.cpp:5909) before queueing any file for parsing
// (src/parser.cpp:5999, parser_add_file_to_process).
collect_package_for_target :: proc(path: string, kind: ast.Package_Kind = .Normal) -> (pkg: ^ast.Package, success: bool) {
	NO_POS :: tokenizer.Pos{}

	// Nothing else in the checker's start-up sets a target, and a zeroed build_context would
	// make every one of the decisions below come out as "belongs to some other platform".
	ensure_build_context_initialized()

	target := current_build_target()

	pkg_path, pkg_path_err := os.get_absolute_path(path, context.allocator)
	if pkg_path_err != nil {
		return
	}

	path_pattern := fmt.tprintf("%s/*.odin", pkg_path)
	matches, glob_err := filepath.glob(path_pattern)
	defer {
		for match in matches {
			delete(match)
		}
		delete(matches)
	}

	if glob_err != nil {
		return
	}

	pkg = ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = pkg_path
	pkg.kind = kind

	for match in matches {
		// (1) Filename suffix - decided from the name alone, so the file is never read.
		if is_excluded_target_filename(filepath.base(match)) {
			continue
		}

		fullpath, fullpath_err := os.get_absolute_path(match, context.allocator)
		if fullpath_err != nil {
			return
		}

		src, src_err := os.read_entire_file(fullpath, context.allocator)
		if src_err != nil {
			delete(fullpath)
			return
		}
		if strings.trim_space(string(src)) == "" {
			delete(fullpath)
			delete(src)
			continue
		}

		// (2) `#+build` tags - decided from the file header, still before the parse.
		if !file_header_selects_target(fullpath, string(src), target, kind) {
			delete(fullpath)
			delete(src)
			continue
		}

		file := ast.new(ast.File, NO_POS, NO_POS)
		file.pkg = pkg
		file.src = string(src)
		file.fullpath = fullpath
		pkg.files[fullpath] = file
	}

	success = true
	return
}

// parse_package_for_target is the target-aware counterpart of
// parser.parse_package_from_path: it collects the directory through
// collect_package_for_target and then parses only what survived.
//
// The package-name consistency check lives in parser.parse_package and therefore only ever sees
// the surviving files - which is what silences "different package name" for files such as
// core/fmt/example.odin, whose `#+build ignore` tag means the C++ compiler never compares its
// package clause either.
parse_package_for_target :: proc(path: string, kind: ast.Package_Kind = .Normal, p: ^parser.Parser = nil) -> (pkg: ^ast.Package, ok: bool) {
	pkg, ok = collect_package_for_target(path, kind)
	if !ok {
		return
	}
	ok = parser.parse_package(pkg, p)
	return
}

// Package_To_Load tracks a package with both its import path and filesystem path
Package_To_Load :: struct {
	import_path: string, // The original import path like "core:fmt"
	fullpath:    string, // The resolved filesystem path

	// kind is what the package will be stamped with before it is parsed. Everything the loader
	// discovers by following imports is .Normal; only base:runtime is seeded as .Runtime, and
	// only the loader itself can know that (the import declaration that names it looks exactly
	// like any other).
	kind:        ast.Package_Kind,
}

// load_package_with_dependencies loads a package and all its imported dependencies
// Returns all packages in dependency order (dependencies before dependents)
load_package_with_dependencies :: proc(
	root_path: string,
	info: ^Checker_Info,
	allocator := context.allocator,
) -> (result: Package_Load_Result, ok: bool) {
	result.packages = make([dynamic]^ast.Package, allocator)

	// Track loaded packages by filesystem path to avoid duplicates
	loaded := make(map[string]^ast.Package)
	defer delete(loaded)

	// Queue of packages to load (with both import and filesystem paths)
	to_load := make([dynamic]Package_To_Load, allocator)
	defer delete(to_load)

	// Start with root package
	root_fullpath, root_err := filepath.abs(root_path)
	if root_err != nil {
		return result, false
	}

	// base:runtime is queued BEFORE the root, and therefore loaded first.
	//
	// C++ Reference: src/parser.cpp:7062-7071. The comment there is "Add these packages
	// serially and then process them parallel", and runtime is the first thing added -
	// ahead of the init package, ahead of core:testing, ahead of every extra package -
	// with an explicit Package_Runtime kind.
	//
	// Ordering is not cosmetic. The kind is what lets the file parse at all: `package runtime`
	// is otherwise rejected as a reserved name, so if the root or a dependency reached
	// base/runtime through the ordinary import-following path below it would be stamped
	// .Normal and every one of its files would fail to parse. Seeding it here is the only
	// point at which the loader knows this directory is the runtime.
	//
	// This also makes `check_package_from_path("<odin>/base/runtime")` work: the root's
	// fullpath collides with the seed, the seed wins because it is dequeued first, and the
	// root is then skipped by the `already loaded` guard - so runtime is checked as itself,
	// with the right kind, rather than as an ordinary package that cannot parse.
	if runtime_fullpath, runtime_ok := resolve_import_path(RUNTIME_IMPORT_PATH, "", allocator); runtime_ok {
		// A missing ODIN_ROOT leaves resolve_import_path unable to answer, and a wrong one
		// leaves it answering with a directory that is not there. Neither is worth a
		// diagnostic here - the checker already degrades to "no runtime types" in that case,
		// and the C++ compiler's compiler_error() is not available to a library.
		if os.is_dir(runtime_fullpath) {
			append(&to_load, Package_To_Load{
				import_path = RUNTIME_IMPORT_PATH,
				fullpath    = runtime_fullpath,
				kind        = .Runtime,
			})
		}
	}

	// Root package has empty import path (it's the target, not an import)
	append(&to_load, Package_To_Load{import_path = "", fullpath = root_fullpath, kind = .Normal})

	// Process queue
	for len(to_load) > 0 {
		pkg_to_load := pop_front(&to_load)
		pkg_path := pkg_to_load.fullpath
		import_path := pkg_to_load.import_path

		// Skip if already loaded
		if pkg_path in loaded {
			continue
		}

		// Parse the package, skipping any file that does not belong to the target
		// #180: route parser diagnostics into the checker's collector.
		//
		// The port already had the entire syntax-error path -- syntax_error_va with the
		// "Syntax Error: " prefix, the same collector, the same limit latching -- and
		// syntax_error_pos has EXACTLY the parser's Error_Handler signature. Nothing ever
		// installed it, so every parser diagnostic went to default_error_handler, which
		// fmt.eprintf's straight to stderr: uncounted (errors=0), unsorted, unlabelled, and
		// printed before the harness header rather than through the collector.
		//
		// C++ has no such split -- syntax_error and error share error.cpp's machinery and
		// both land in the same sorted, counted stream.
		syntax_parser := parser.default_parser()
		syntax_parser.err = syntax_error_pos
		// #209: file_allow_newline needs build_context.strict_style and the build-level vet
		// flags. The parser package has no build context of its own, so the driver supplies
		// them -- without this every file parses as if -strict-style were off.
		syntax_parser.strict_style = build_context.strict_style
		syntax_parser.vet_flags = transmute(ast.Vet_Flags)build_context.vet_flags
		// #211: parse_do_body reads this; build_context.disallow_do was stored but never read.
		syntax_parser.disallow_do = build_context.disallow_do
		pkg, parse_ok := parse_package_for_target(pkg_path, pkg_to_load.kind, &syntax_parser)
		if !parse_ok || pkg == nil {
			result.parse_errors += 1
			continue
		}

		// Register the package
		loaded[pkg_path] = pkg
		append(&result.packages, pkg)
		result.total_files += len(pkg.files)

		// Register in info.packages for the checker using the IMPORT path
		// The checker looks up packages by their import path (like "core:fmt")
		if info != nil {
			// Register by import path if we have one.
			//
			// A relative spelling (`./x`, `../x`) is deliberately NOT registered: it is not a
			// globally unique key, so two packages in different directories importing the
			// same literal text would collide on whichever was loaded first and the second
			// would silently resolve to the wrong package. Relative imports are found through
			// the fullpath key below, via lookup_imported_package. C++ has no equivalent
			// hazard because determine_path_from_string (src/parser.cpp:6236) resolves the
			// path before it ever becomes a key.
			if len(import_path) > 0 &&
			   !strings.has_prefix(import_path, "./") &&
			   !strings.has_prefix(import_path, "../") {
				register_package(info, import_path, pkg)
			}
			// Also register by fullpath as a fallback
			register_package(info, pkg_path, pkg)

			// This is the analogue of get_runtime_package (src/checker.cpp:899), which finds
			// the runtime by looking its path up in info->packages and asserts it is there.
			// The lookup is done here, once, at the moment the package is registered, rather
			// than repeated on every call - but the property it establishes is the same one:
			// info.runtime_package is a package that was really parsed, not a synthesized
			// stand-in. check_files' register_packages_from_files sets it too, from the same
			// .Runtime kind; both agree because there is only ever one such package.
			if pkg.kind == .Runtime {
				info.runtime_package = pkg
			}
		}

		// Find and queue all imports
		for _, file in pkg.files {
			for decl in file.decls {
				if import_decl, is_import := decl.derived.(^ast.Import_Decl); is_import {
					child_import_path := import_decl.fullpath

					// Strip quotes from the import path (parser may include them)
					// This ensures consistency between registration and lookup
					stripped_path := child_import_path
					if len(stripped_path) >= 2 && stripped_path[0] == '"' {
						stripped_path = stripped_path[1:len(stripped_path) - 1]
					}

					// Skip reserved/builtin packages - they're handled by the compiler
					if is_reserved_package(stripped_path) {
						continue
					}

					child_fullpath, resolve_ok := resolve_import_path(child_import_path, pkg_path, allocator)
					if resolve_ok && !(child_fullpath in loaded) {
						// Check if the path exists
						if os.is_dir(child_fullpath) {
							// Use the stripped (unquoted) path for registration
							// This matches how check_import_export looks up packages
							append(&to_load, Package_To_Load{
								import_path = stripped_path,
								fullpath    = child_fullpath,
							})
						}
					}
				}
			}
		}
	}

	ok = result.parse_errors == 0
	return result, ok
}

// init_odin_root_from_env initializes ODIN_ROOT from environment if not set
// Falls back to auto-detection from current working directory
// Uses heap allocator to ensure the string persists across temp allocator resets
init_odin_root_from_env :: proc() {
	if len(build_context.ODIN_ROOT) == 0 {
		// Use heap allocator for persistent storage - tests may use temp_allocator
		// which would cause ODIN_ROOT to become garbage after the test completes
		persistent_allocator := context.allocator
		if context.allocator == context.temp_allocator {
			persistent_allocator = runtime.heap_allocator()
		}

		if odin_root := os.get_env("ODIN_ROOT", persistent_allocator); len(odin_root) > 0 {
			build_context.ODIN_ROOT = odin_root
			return
		}

		// Auto-detect ODIN_ROOT by looking for base/runtime in current or parent directories
		// This enables tests to run without ODIN_ROOT being explicitly set
		cwd, cwd_err := os.get_working_directory(persistent_allocator)
		if cwd_err == nil && len(cwd) > 0 {
			// Check if base/runtime exists in cwd (we're at ODIN_ROOT)
			runtime_path, join_err := filepath.join({cwd, "base", "runtime"}, persistent_allocator)
			if join_err != nil {
				return
			}
			if os.is_dir(runtime_path) {
				build_context.ODIN_ROOT = cwd
				return
			}

			// Walk up parent directories to find ODIN_ROOT
			// NOTE: filepath.dir does not allocate - `parent` is a substring of `dir`, and so
			// remains valid for as long as `cwd` does (which is allocated persistently above).
			dir := cwd
			for i := 0; i < 10; i += 1 { // Limit depth to avoid infinite loop
				parent := filepath.dir(dir)
				if parent == dir || len(parent) == 0 {
					break
				}
				runtime_path, join_err = filepath.join({parent, "base", "runtime"}, persistent_allocator)
				if join_err != nil {
					return
				}
				if os.is_dir(runtime_path) {
					build_context.ODIN_ROOT = parent
					return
				}
				dir = parent
			}
		}
	}
}

// Package_Check_Result is the outcome of check_package_from_path.
//
// The failure modes are kept separate on purpose. A package that could not be loaded at
// all must never be indistinguishable from a package that loaded cleanly and produced N
// diagnostics, so a load failure is reported through `load_ok` rather than being folded
// into `check_errors`. For the same reason a run that was cut short by the error cap is
// reported through `limit_reached` rather than looking like an ordinary failed check.
Package_Check_Result :: struct {
	// ok is true only when the package loaded, every file parsed, the checker ran to
	// completion and reported no diagnostics. It is the "this package is clean" flag.
	ok:            bool,

	// load_ok reports whether the package was actually located, parsed and handed to the
	// checker: the loader returned success AND the load produced at least one file.
	//
	// The zero-file case matters because `check_files` over an empty file list trivially
	// returns true - a path that resolves nowhere would otherwise look like a clean pass.
	load_ok:       bool,

	// check_ok is the raw result of check_files. It is only meaningful when at least one
	// file was loaded; with no files the checker is never invoked and this stays false.
	check_ok:      bool,

	// parse_errors counts packages (root or dependency) that failed to parse.
	parse_errors:  int,

	// check_errors is the number of diagnostics the checker reported.
	//
	// When `limit_reached` is set this is a floor, not a total: it counts what was recorded
	// before the cap tripped, and every diagnostic after that was dropped.
	check_errors:  int,

	// limit_reached reports that checking was abandoned because more than
	// build_context.max_error_count errors were produced.
	//
	// This is a third outcome, distinct from both "clean" and "checked and found N errors":
	// the checker stopped partway, so `check_errors` is truncated and the absence of a
	// diagnostic proves nothing about the code. The C++ compiler expresses this by calling
	// exit(1); as a library we cannot, so it is surfaced here instead. See
	// CPP_DEVIATIONS.md [EMBED-1].
	limit_reached: bool,

	// check_warnings is the number of those diagnostics that were warnings rather than errors.
	// Like check_errors, it is a floor when `limit_reached` is set.
	check_warnings: int,

	// diagnostics are the diagnostics themselves, OWNED BY THIS RESULT.
	//
	// check_errors without these is a number the caller cannot act on. The global error
	// collector that produced them is a singleton bounded by init_error_collector /
	// destroy_error_collector, and check_package_from_path owns that whole lifetime - so by the
	// time this result exists, the collector is already gone. Rather than leave the count
	// pointing at freed storage, ownership of the list is transferred here (see
	// take_error_values: a detach, not a copy), which also means results for different packages
	// coexist instead of clobbering one shared buffer.
	//
	// Free with destroy_package_check_result; print with print_package_diagnostics. Each
	// Error_Value.msg is its own allocation, so deleting the array alone leaks every message.
	// Allocated from the `allocator` passed to check_package_from_path.
	diagnostics:   [dynamic]Error_Value,

	// total_files is the number of files loaded across the package and its dependencies.
	total_files:   int,
}

// destroy_package_check_result frees the diagnostics owned by a Package_Check_Result.
//
// Safe on a zero-valued result and idempotent, so it can be deferred immediately after the
// call to check_package_from_path regardless of which failure path was taken.
destroy_package_check_result :: proc(result: ^Package_Check_Result) {
	destroy_error_values(&result.diagnostics)
}

// print_package_diagnostics prints the diagnostics a check produced, in the same format and
// with the same sorting/merging as print_all_errors.
//
// This is the entry point an embedder should use. It reads the result's own list, so it stays
// valid after check_package_from_path has returned and torn the global collector down, and it
// prints nothing when there is nothing to print. The list is mutated in place (sorted, and
// same-position diagnostics merged), so repeated calls print the merged form.
print_package_diagnostics :: proc(result: ^Package_Check_Result) {
	print_error_values(&result.diagnostics)
}

// check_package_from_path is a convenience function that loads and checks a package
// This handles all the setup needed to check real code
//
// The returned result OWNS its diagnostics and must be freed with
// destroy_package_check_result. It is deliberately self-contained: this procedure owns the
// whole lifetime of the global error collector, so once it returns, nothing about the run is
// readable through the global collector any more - which is why `check_errors` travels with the
// diagnostics it counts rather than merely counting them. To print them, call
// print_package_diagnostics(&result); print_all_errors() reads the (already destroyed) global
// collector and is not applicable here.
//
//	res := checker.check_package_from_path(path)
//	defer checker.destroy_package_check_result(&res)
//	if res.check_errors > 0 {
//		checker.print_package_diagnostics(&res)
//	}
check_package_from_path :: proc(path: string, allocator := context.allocator) -> (result: Package_Check_Result) {
	// Initialize ODIN_ROOT from environment if needed
	init_odin_root_from_env()

	// Initialize error collector FIRST - needed by checker initialization.
	//
	// It is given the same allocator as everything else here, because the diagnostics it
	// allocates are handed to the caller on `result.diagnostics` - they must come from the
	// allocator the caller passed in, not from whatever context.allocator happened to be.
	init_error_collector(1000, allocator = allocator)
	defer destroy_error_collector()

	// NOTE: the harvest below is deliberately NOT written as a `defer`, even though a defer
	// would cover both return paths for free. Odin rejects assignments to a named return value
	// inside a defer ("Assignments to named return values within 'defer' will not affect the
	// value that is returned") - but that check only fires on the bare identifier, so
	// `result.check_errors = ...` inside a defer compiles and is then silently discarded. Every
	// return path calls harvest_check_diagnostics explicitly instead.

	// Create checker
	c := &Checker{}
	init_checker(c, allocator)
	defer destroy_checker(c)

	// Load package and dependencies.
	//
	// `loader_ok` must not be discarded: it is false both when a package failed to parse
	// (which also shows up in `parse_errors`) and when the root path could not be resolved
	// at all - and that second case leaves `parse_errors` at 0 with an empty package list.
	load_result, loader_ok := load_package_with_dependencies(path, &c.info, allocator)
	result.parse_errors = load_result.parse_errors
	result.total_files = load_result.total_files

	// Collect all files from all packages (even if some failed to parse)
	files := make([dynamic]^ast.File, allocator)
	defer delete(files)

	for pkg in load_result.packages {
		for _, file in pkg.files {
			append(&files, file)
		}
	}

	result.load_ok = loader_ok && len(files) > 0

	if len(files) == 0 {
		// Nothing was loaded, so there is nothing to check. Do NOT fall through to
		// check_files: it returns true for an empty file list, which would report a
		// non-existent or unreadable package as a clean pass.
		//
		// The loader can still have reported diagnostics, so this path harvests them too - a
		// result must be self-contained however it was reached.
		harvest_check_diagnostics(&result)
		return
	}

	// C++ Reference: src/main.cpp:4257-4260.
	//
	//     if (any_errors()) { print_all_errors(); return 1; }
	//     checker->parser = parser;
	//     init_checker(checker);
	//     ...
	//     check_parsed_files(checker);
	//
	// C++ NEVER type-checks a program whose parse produced diagnostics -- it prints and
	// exits between the two phases. The port checked anyway, running semantic analysis over
	// an AST it already knew was malformed and emitting cascade diagnostics C++ never
	// produces (probe eb4: C++ 1 syntax error, the port that plus 7 invented semantic ones).
	//
	// error_count() is exactly C++'s any_errors() now that #180 routes parser diagnostics
	// through the same collector; before that wiring this gate could not have been written,
	// because the syntax errors were not in any count the checker could see.
	//
	// The library deviation from CPP_DEVIATIONS.md [EMBED-1] still applies: C++ exits the
	// process here, we return a populated result instead.
	if error_count() > 0 {
		harvest_check_diagnostics(&result)
		return
	}

	// Run the checker.
	//
	// The error-limit signal travels out of the checker on the global error collector, the
	// same channel `check_errors` and the diagnostics already use - it is written by error_va
	// on whichever thread trips the cap and read here after every worker has been joined.
	result.check_ok = check_files(c, files[:])

	harvest_check_diagnostics(&result)
	return
}

// harvest_check_diagnostics moves everything the run produced off the global error collector
// and onto the result, then derives `ok`.
//
// It must run while the collector is still alive - i.e. before `destroy_error_collector`, which
// frees every Error_Value.msg - which is why check_package_from_path calls it on each return
// path rather than leaving the counts for the caller to read afterwards. The counts are read
// before take_error_values, since taking the values zeroes them.
@(private = "file")
harvest_check_diagnostics :: proc(result: ^Package_Check_Result) {
	result.check_errors = error_count()
	result.check_warnings = warning_count()
	result.limit_reached = error_limit_reached()
	result.diagnostics = take_error_values()

	// A truncated run is never "ok": check_files bailed out at a phase boundary, so most of
	// the package was never looked at.
	result.ok = result.load_ok && result.check_ok && !result.limit_reached &&
		result.check_errors == 0 && result.parse_errors == 0
}
