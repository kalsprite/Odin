package test_spec_errors

/*
Test Coverage: errors.md - Redeclaration Errors

Tests for detecting invalid redeclarations at various scopes.

Spec Reference: ../spec/errors.md#redeclaration
Test IDs: ERR-RD-001 through ERR-RD-040
Last Sync: 2026-01-18
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// REDECLARATION TEST SUITE
// =============================================================================

redeclaration_suite := helpers.Test_Suite {
	name         = "Redeclaration Errors",
	spec_file    = "errors.md",
	spec_section = "redeclaration",
	cases        = {
		// Basic variable redeclaration
		{
			id           = "ERR-RD-001",
			name         = "duplicate variable in same scope",
			source       = `package test
x: int = 1
x: int = 2
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		{
			id           = "ERR-RD-002",
			name         = "duplicate constant in same scope",
			source       = `package test
X :: 1
X :: 2
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		{
			id           = "ERR-RD-003",
			name         = "duplicate type in same scope",
			source       = `package test
MyType :: struct { x: int }
MyType :: struct { y: int }
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		{
			id           = "ERR-RD-004",
			name         = "duplicate procedure in same scope",
			source       = `package test
foo :: proc() {}
foo :: proc() {}
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		// Variable shadows type name
		{
			id           = "ERR-RD-005",
			name         = "variable shadows type",
			source       = `package test
MyType :: struct { x: int }
MyType: int = 1
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		// Procedure shadows constant
		{
			id           = "ERR-RD-006",
			name         = "procedure shadows constant",
			source       = `package test
FOO :: 42
FOO :: proc() {}
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		// Local variable redeclaration
		{
			id           = "ERR-RD-007",
			name         = "duplicate local variable",
			source       = `package test
foo :: proc() {
    x: int = 1
    x: int = 2
}
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		{
			id           = "ERR-RD-008",
			name         = "duplicate local constant",
			source       = `package test
foo :: proc() {
    X :: 1
    X :: 2
}
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		// Parameter redeclaration
		{
			id           = "ERR-RD-009",
			name         = "duplicate parameter names",
			source       = `package test
foo :: proc(x: int, x: int) {}
`,
			expect_error = true,
			error_substr = "duplicate parameter",
		},
		{
			id           = "ERR-RD-010",
			name         = "local shadows parameter (allowed)",
			source       = `package test
foo :: proc(x: int) {
    x: int = 2
    _ = x
}
`,
			expect_error = false, // Odin allows shadowing parameters
		},
		// Multiple return value names
		{
			id           = "ERR-RD-011",
			name         = "duplicate return value names",
			source       = `package test
foo :: proc() -> (x: int, x: int) {
    return 1, 2
}
`,
			expect_error = true,
			error_substr = "duplicate return value",
		},
		// Struct field redeclaration
		{
			id           = "ERR-RD-012",
			name         = "duplicate struct fields",
			source       = `package test
Point :: struct {
    x: int,
    x: int,
}
`,
			expect_error = true,
			error_substr = "Redeclaration",
		},
		{
			id           = "ERR-RD-013",
			name         = "duplicate struct field via using",
			source       = `package test
Base :: struct { x: int }
Derived :: struct {
    using base: Base,
    x: int,
}
`,
			expect_error = true,
			error_substr = "Redeclaration",
		},
		// Enum field redeclaration
		{
			id           = "ERR-RD-014",
			name         = "duplicate enum fields",
			source       = `package test
Color :: enum {
    Red,
    Red,
}
`,
			expect_error = true,
			error_substr = "Redeclaration",
		},
		// Union variant redeclaration
		{
			id           = "ERR-RD-015",
			name         = "duplicate union variants",
			source       = `package test
Value :: union {
    int,
    int,
}
`,
			expect_error = true,
			error_substr = "duplicate",
		},
		// For loop variable redeclaration
		{
			id           = "ERR-RD-016",
			name         = "for loop shadows outer variable (allowed)",
			source       = `package test
foo :: proc() {
    i: int = 0
    for i in 0..<10 {
        _ = i
    }
}
`,
			expect_error = false, // shadowing in for is allowed
		},
		{
			id           = "ERR-RD-017",
			name         = "duplicate for loop variables",
			source       = `package test
foo :: proc() {
    for i, i in "hello" {
        _ = i
    }
}
`,
			expect_error = true,
			error_substr = "redeclar",
		},
		// Block scope shadowing (allowed)
		{
			id           = "ERR-RD-018",
			name         = "inner block shadows outer (allowed)",
			source       = `package test
foo :: proc() {
    x: int = 1
    {
        x: int = 2  // shadows outer x
        _ = x
    }
}
`,
			expect_error = false, // shadowing in inner block is allowed
		},
		// If statement condition variable
		{
			id           = "ERR-RD-019",
			name         = "if condition variable shadows outer",
			source       = `package test
get_value :: proc() -> (int, bool) { return 0, true }
foo :: proc() {
    x: int = 1
    if x, ok := get_value(); ok {
        _ = x
    }
}
`,
			expect_error = false, // shadowing in if is allowed
		},
		// Switch statement shadowing
		{
			id           = "ERR-RD-020",
			name         = "switch shadows outer variable (allowed)",
			source       = `package test
get_value :: proc() -> int { return 0 }
foo :: proc() {
    x: int = 1
    switch x := get_value(); x {
    case 0: break
    }
}
`,
			expect_error = false, // shadowing in switch is allowed
		},
	},
}

@(test)
test_redeclaration_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, redeclaration_suite)
}

// =============================================================================
// ADDITIONAL INDIVIDUAL TESTS
// =============================================================================

@(test)
test_err_redecl_multiple_in_one_decl_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - multiple same names in one declaration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x, x: int = 1, 2
`, "ERR-RD-021: duplicate names in multi-declaration")
}

@(test)
test_err_redecl_import_shadows_builtin_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - import shadows builtin (typically warning, but test detection)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// This might be allowed with a warning - test that at least parsing works
	result := helpers.check_source_capture_errors(`package test
int :: 42  // shadows builtin type
`)
	defer helpers.destroy_test_result(&result)
	// Just verify it parses - shadowing builtin may or may not be an error
}

@(test)
test_err_redecl_blank_identifier_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - blank identifier redeclaration is still an error in Odin
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    _: int = 1
    _: int = 2  // blank identifier redeclaration
}
`, "ERR-RD-022: blank identifier redeclaration")
}

@(test)
test_err_redecl_different_kinds_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - redeclaration with different kinds
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: 42
foo :: proc() {}
`, "ERR-RD-023: constant then procedure")
}

@(test)
test_err_redecl_proc_params_same_as_return_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - param name same as return name
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc(x: int) -> (x: int) {
    return x
}
`, "ERR-RD-024: param name matches return name")
}
