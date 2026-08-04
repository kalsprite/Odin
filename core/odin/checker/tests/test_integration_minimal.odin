package test_checker

// Minimal integration test to isolate panic trigger

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:testing"

import checker ".."

@(test)
test_parse_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file := new(ast.File)
	file.fullpath = "test.odin"
	file.src = "package test\nx := 1"

	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

	ok := parser.parse_file(&p, file)
	testing.expect(t, ok, "Should parse simple package")
}

@(test)
test_checker_init_only :: proc(t: ^testing.T) {
	// The fifth instance of #368's defect, and the one the per-FILE count missed: this file's
	// other test does take the lock, so the file looked covered. Only a per-TEST-PROC scan found
	// it. destroy_checker nils the process-global runtime type state, so without the lock this
	// test does that at an arbitrary moment -- including inside a package check on another thread.
	// The temp-allocator install goes for the same reason it went from the other twelve sites:
	// type constructors spend context.allocator, so the types init_checker builds would die at the
	// guard while the globals pointing at them survive. LEDGER #368.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	testing.expect(t, c.info.checker == c, "Checker should init")
}

@(test)
test_error_collector_only :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector to avoid race conditions
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	testing.expect(t, checker.error_count() == 0, "Should have no errors")
}
