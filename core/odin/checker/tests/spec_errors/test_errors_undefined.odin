package test_spec_errors

/*
Test Coverage: errors.md - Undefined Identifier Errors

Data-driven tests for undefined identifier detection.

Spec Reference: ../spec/errors.md#undefined
Test IDs: ERR-UNDEF-001 through ERR-UNDEF-030
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// UNDEFINED IDENTIFIER TEST SUITE
// =============================================================================

undefined_suite := helpers.Test_Suite {
	name         = "Undefined Identifier Errors",
	spec_file    = "errors.md",
	spec_section = "undefined",
	cases        = {
		// Undefined variables
		{
			id           = "ERR-UNDEF-001",
			name         = "undefined variable",
			source       = `package test
x := undefined_var
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-UNDEF-002",
			name         = "undefined in expression",
			source       = `package test
x: int = 1 + undefined_var
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Undefined types
		{
			id           = "ERR-UNDEF-003",
			name         = "undefined type",
			source       = `package test
x: UndefinedType
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-UNDEF-004",
			name         = "undefined type in struct",
			source       = `package test
Foo :: struct {
    x: UndefinedType,
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-UNDEF-005",
			name         = "undefined type in proc param",
			source       = `package test
foo :: proc(x: UndefinedType) {}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-UNDEF-006",
			name         = "undefined type in proc return",
			source       = `package test
foo :: proc() -> UndefinedType { return nil }
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Undefined procedures
		{
			id           = "ERR-UNDEF-007",
			name         = "undefined procedure call",
			source       = `package test
test :: proc() {
    undefined_proc()
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-UNDEF-008",
			name         = "undefined procedure in expression",
			source       = `package test
test :: proc() {
    x := undefined_proc()
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Undefined struct fields
		{
			id           = "ERR-UNDEF-009",
			name         = "undefined struct field access",
			source       = `package test
Point :: struct { x, y: int }
test :: proc() {
    p: Point
    z := p.undefined_field
}
`,
			expect_error = true,
		},
		{
			id           = "ERR-UNDEF-010",
			name         = "undefined struct field in init",
			source       = `package test
Point :: struct { x, y: int }
p: Point = { undefined_field = 42 }
`,
			expect_error = true,
		},
		// Undefined enum values
		{
			id           = "ERR-UNDEF-011",
			name         = "undefined enum value",
			source       = `package test
Color :: enum { Red, Green, Blue }
c: Color = .UndefinedValue
`,
			expect_error = true,
		},
		// Undefined in compound literals
		{
			id           = "ERR-UNDEF-012",
			name         = "undefined in array literal",
			source       = `package test
arr: [3]int = {1, undefined_var, 3}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
	},
}

@(test)
test_undefined_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, undefined_suite)
}

// =============================================================================
// SCOPING ERRORS
// =============================================================================

@(test)
test_err_undefined_out_of_scope_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - variable used out of scope
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    if true {
        x: int = 42
    }
    y := x
}
`, "ERR-UNDEF-013: variable out of scope")
}

@(test)
test_err_undefined_before_declaration_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - use before declaration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    y := x
    x: int = 42
}
`, "ERR-UNDEF-014: use before declaration")
}
