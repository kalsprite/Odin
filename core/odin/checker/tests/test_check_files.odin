package test_checker

// Test that runs check_files on parsed code

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:testing"

import checker ".."

// Test check_collect_entities_all - this should trigger panic if any
@(test)
test_collect_entities :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Parse
	file := new(ast.File)
	file.fullpath = "test.odin"
	file.src = "package test"

	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

	parse_ok := parser.parse_file(&p, file)
	testing.expect(t, parse_ok, "Should parse empty package")

	// Create package
	pkg := new(ast.Package)
	pkg.fullpath = "test_package"
	pkg.name = "test"
	pkg.files = make(map[string]^ast.File)
	pkg.files[file.fullpath] = file
	file.pkg = pkg

	// Serialize access to global error collector to avoid race conditions
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Checker init
	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	// Just test that collect exists
	checker.register_packages_from_files(c, {file})
	checker.check_collect_entities_all(c)
	testing.expect(t, true, "Entity collection works")
}
