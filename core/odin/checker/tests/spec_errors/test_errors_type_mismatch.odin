package test_spec_errors

/*
Test Coverage: errors.md - Type Mismatch Errors

Data-driven tests for type mismatch error detection.
Uses the table-driven test pattern for large test suites.

Spec Reference: ../spec/errors.md#type-mismatch
Test IDs: ERR-TM-001 through ERR-TM-050
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// TYPE MISMATCH TEST SUITE
// =============================================================================

type_mismatch_suite := helpers.Test_Suite {
	name         = "Type Mismatch Errors",
	spec_file    = "errors.md",
	spec_section = "type-mismatch",
	cases        = {
		// Basic type mismatches
		{
			id           = "ERR-TM-001",
			name         = "int <- string",
			source       = `package test
x: int = "hello"
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-002",
			name         = "bool <- int",
			source       = `package test
x: bool = 42
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-003",
			name         = "string <- int",
			source       = `package test
x: string = 42
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-004",
			name         = "float <- string",
			source       = `package test
x: f32 = "hello"
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-005",
			name         = "float <- bool",
			source       = `package test
x: f32 = true
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Pointer type mismatches
		{
			id           = "ERR-TM-006",
			name         = "^int <- int",
			source       = `package test
x: ^int = 42
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-007",
			name         = "^int <- ^string",
			source       = `package test
s: string = "hello"
x: ^int = &s
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Array type mismatches
		{
			id           = "ERR-TM-008",
			name         = "[5]int <- [3]int",
			source       = `package test
a: [3]int = {1, 2, 3}
b: [5]int = a
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-009",
			name         = "[5]int <- [5]string",
			source       = `package test
a: [5]string = {"a", "b", "c", "d", "e"}
b: [5]int = a
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Return type mismatches
		{
			id           = "ERR-TM-010",
			name         = "return int <- string",
			source       = `package test
foo :: proc() -> int {
    return "hello"
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-011",
			name         = "return bool <- int",
			source       = `package test
foo :: proc() -> bool {
    return 42
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Argument type mismatches
		{
			id           = "ERR-TM-012",
			name         = "arg int <- string",
			source       = `package test
foo :: proc(x: int) {}
bar :: proc() {
    foo("hello")
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-013",
			name         = "arg bool <- int",
			source       = `package test
foo :: proc(x: bool) {}
bar :: proc() {
    foo(42)
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Struct field mismatches
		{
			id           = "ERR-TM-014",
			name         = "struct field int <- string",
			source       = `package test
Point :: struct { x, y: int }
p: Point = { x = "hello", y = 0 }
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Enum mismatches
		{
			id           = "ERR-TM-015",
			name         = "enum <- int directly",
			source       = `package test
Color :: enum { Red, Green, Blue }
c: Color = 42
`,
			expect_error = true,
			error_substr = "cannot",
		},
		{
			id           = "ERR-TM-016",
			name         = "enum <- wrong enum",
			source       = `package test
Color :: enum { Red, Green, Blue }
Size :: enum { Small, Medium, Large }
c: Color = Size.Small
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Slice type mismatches
		{
			id           = "ERR-TM-017",
			name         = "[]int <- []string",
			source       = `package test
get_strings :: proc() -> []string { return nil }
x: []int = get_strings()
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Map type mismatches
		{
			id           = "ERR-TM-018",
			name         = "map[string]int <- map[int]int",
			source       = `package test
m1: map[int]int
m2: map[string]int = m1
`,
			expect_error = true,
			error_substr = "cannot",
		},
	},
}

@(test)
test_type_mismatch_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, type_mismatch_suite)
}

// =============================================================================
// ADDITIONAL INDIVIDUAL TESTS FOR COMPLEX CASES
// =============================================================================

@(test)
test_err_type_mismatch_compound_assign_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - compound assignment type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x: int = 0
    x += "hello"
}
`, "ERR-TM-019: compound assignment type mismatch")
}

@(test)
test_err_type_mismatch_ternary_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - ternary branches must match
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    b: bool = true
    x := b ? 42 : "hello"
}
`, "ERR-TM-020: ternary branch type mismatch")
}
