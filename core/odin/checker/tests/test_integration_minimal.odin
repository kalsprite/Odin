package test_checker

// Minimal integration test to isolate panic trigger

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:sync"
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
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

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
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	testing.expect(t, checker.error_count() == 0, "Should have no errors")
}
