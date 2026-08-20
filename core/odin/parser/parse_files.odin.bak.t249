package odin_parser

import "core:odin/tokenizer"
import "core:odin/ast"
import "core:path/filepath"
import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

collect_package :: proc(path: string) -> (pkg: ^ast.Package, success: bool) {
	NO_POS :: tokenizer.Pos{}

	pkg_path, pkg_path_err := os.get_absolute_path(path, context.allocator)
	if pkg_path_err != nil {
		return
	}

	path_pattern := fmt.tprintf("%s/*.odin", pkg_path)
	matches, err := filepath.glob(path_pattern)
	defer delete(matches)

	if err != nil {
		return
	}

	pkg = ast.new(ast.Package, NO_POS, NO_POS)
	pkg.fullpath = pkg_path

	for match in matches {
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

		file := ast.new(ast.File, NO_POS, NO_POS)
		file.pkg = pkg
		file.src = string(src)
		file.fullpath = fullpath
		pkg.files[fullpath] = file
	}

	success = true
	return
}

parse_package :: proc(pkg: ^ast.Package, p: ^Parser = nil) -> bool {
	p := p
	if p == nil {
		p = &Parser{}
		p^ = default_parser()
	}

	ok := true

	files := make([]^ast.File, len(pkg.files), context.temp_allocator)
	i := 0
	for _, file in pkg.files {
		files[i] = file
		i += 1
	}
	slice.sort(files)

	for file in files {
		// LEDGER #307: the package-name block below is reachable ONLY when parse_file
		// succeeded.
		//
		// C++ Reference: src/parser.cpp:7009-7026 -- the whole block, name comparison and all,
		// is the body of `if (parse_file(p, file))`. The port ran it unconditionally, and
		// parse_file returns false precisely when it never consumed a package clause, which
		// leaves file.pkg_decl nil. `pkg.name = file.pkg_decl.name` then dereferenced nil:
		// a single file whose contents are `#+vet bogusname` with no `package` line
		// SEGFAULTED the checker, 20/20 runs, deterministically, before it printed anything.
		//
		// SCOPE NOTE: C++ also only does `array_add(&pkg->files, file)` on success, so a file
		// that failed to parse is not a member of its package at all. The port's pkg.files map
		// is populated earlier, by collect_package, and is not pruned here. That difference is
		// left alone deliberately: check_package_from_path bails on error_count() > 0 before
		// any checking runs, so a failed file's continued membership cannot reach output.
		if !parse_file(p, file) {
			ok = false
			continue
		}
		if pkg.name == "" {
			pkg.name = file.pkg_decl.name
		} else if pkg.name != file.pkg_decl.name {
			// C++ Reference: src/parser.cpp:7017-7024 --
			//     if (file->tokens.count > 0 && file->tokens[0].kind != Token_EOF) {
			//         Token tok = file->package_token;
			//         tok.pos.file_id = file->id;
			//         tok.pos.line   = gb_max(tok.pos.line, 1);
			//         tok.pos.column = gb_max(tok.pos.column, 1);
			//         syntax_error(tok, "Different package name, expected '%.*s', got '%.*s'", ...);
			//     }
			// "Different" is capitalised there. Only visible once #180 routed parser
			// diagnostics through the collector.
			//
			// ANCHOR (LEDGER #197): C++ reports at file->package_token -- the `package`
			// KEYWORD, column 1. The port used file.pkg_decl.pos, which the parser sets to
			// the package NAME (parser.odin:211 passes pkg_name.pos), i.e. column 9 for
			// `package lib`. Package_Decl.token already holds the keyword token
			// (parser.odin:213 assigns p.file.pkg_token), so the fix is which field is read.
			//
			// GUARD: C++ suppresses this entirely for a file with no tokens, or whose first
			// token is EOF -- an empty or unreadable file should not also be blamed for the
			// package name. The clamps to >= 1 cover a synthesised zero position.
			if len(file.pkg_decl.name) > 0 {
				pos := file.pkg_decl.token.pos
				pos.line   = max(pos.line, 1)
				pos.column = max(pos.column, 1)
				error(p, pos, "Different package name, expected '%s', got '%s'", pkg.name, file.pkg_decl.name)
			}
		}
	}

	return ok
}

parse_package_from_path :: proc(path: string, p: ^Parser = nil) -> (pkg: ^ast.Package, ok: bool) {
	pkg, ok = collect_package(path)
	if !ok {
		return
	}
	ok = parse_package(pkg, p)
	return
}
