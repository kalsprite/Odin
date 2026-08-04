package test_spec_errors

/*
Test Coverage: errors.md - Scope Errors

Tests for scope-related errors including undeclared identifiers,
use before declaration, and scope visibility.

Spec Reference: ../spec/errors.md#scope
Test IDs: ERR-SC-001 through ERR-SC-040
Last Sync: 2026-01-18
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// SCOPE ERROR TEST SUITE
// =============================================================================

scope_suite := helpers.Test_Suite {
	name         = "Scope Errors",
	spec_file    = "errors.md",
	spec_section = "scope",
	cases        = {
		// Undeclared identifiers
		{
			id           = "ERR-SC-001",
			name         = "undeclared variable",
			source       = `package test
foo :: proc() {
    x = 42
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-SC-002",
			name         = "undeclared function",
			source       = `package test
foo :: proc() {
    bar()
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-SC-003",
			name         = "undeclared type",
			source       = `package test
x: UndefinedType
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		{
			id           = "ERR-SC-004",
			name         = "undeclared field access",
			source       = `package test
Point :: struct { x, y: int }
foo :: proc() {
    p: Point
    _ = p.z  // z not a field
}
`,
			expect_error = true,
			error_substr = "has no field",
		},
		// Use before declaration (in local scope)
		{
			id           = "ERR-SC-005",
			name         = "use before local declaration",
			source       = `package test
foo :: proc() {
    y := x  // x not declared yet
    x := 1
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Package-level forward reference (should work)
		{
			id           = "ERR-SC-006",
			name         = "package-level forward reference OK",
			source       = `package test
y := x  // forward reference to x
x := 42
`,
			expect_error = false,
		},
		{
			id           = "ERR-SC-007",
			name         = "procedure forward reference OK",
			source       = `package test
foo :: proc() { bar() }
bar :: proc() {}
`,
			expect_error = false,
		},
		// Scope visibility - inner to outer
		{
			id           = "ERR-SC-008",
			name         = "access outer scope variable",
			source       = `package test
foo :: proc() {
    x := 1
    {
        y := x  // can access outer x
        _ = y
    }
}
`,
			expect_error = false,
		},
		// Scope visibility - outer to inner (not allowed)
		{
			id           = "ERR-SC-009",
			name         = "access inner scope variable",
			source       = `package test
foo :: proc() {
    {
        x := 1
    }
    y := x  // x not visible here
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// If statement scope
		{
			id           = "ERR-SC-010",
			name         = "if condition variable not visible outside",
			source       = `package test
get :: proc() -> (int, bool) { return 1, true }
foo :: proc() {
    if x, ok := get(); ok {
        _ = x
    }
    _ = x  // x not visible here
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// For loop scope
		{
			id           = "ERR-SC-011",
			name         = "for loop variable not visible outside",
			source       = `package test
foo :: proc() {
    for i in 0..<10 {
        _ = i
    }
    _ = i  // i not visible here
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Switch scope
		{
			id           = "ERR-SC-012",
			name         = "switch variable not visible outside",
			source       = `package test
get :: proc() -> int { return 1 }
foo :: proc() {
    switch x := get(); x {
    case 1:
        break
    }
    _ = x  // x not visible here
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Procedure parameters visible in body
		{
			id           = "ERR-SC-013",
			name         = "parameter visible in body",
			source       = `package test
foo :: proc(x: int) {
    y := x + 1
    _ = y
}
`,
			expect_error = false,
		},
		// Return values visible in body
		{
			id           = "ERR-SC-014",
			name         = "named return visible in body",
			source       = `package test
foo :: proc() -> (result: int) {
    result = 42
    return
}
`,
			expect_error = false,
		},
		// Struct field access
		{
			id           = "ERR-SC-015",
			name         = "struct field access OK",
			source       = `package test
Point :: struct { x, y: int }
foo :: proc() {
    p: Point = {1, 2}
    _ = p.x
    _ = p.y
}
`,
			expect_error = false,
		},
		// Enum field access via type
		{
			id           = "ERR-SC-016",
			name         = "enum field access OK",
			source       = `package test
Color :: enum { Red, Green, Blue }
foo :: proc() {
    c := Color.Red
    _ = c
}
`,
			expect_error = false,
		},
		// Wrong enum field
		{
			id           = "ERR-SC-017",
			name         = "wrong enum field",
			source       = `package test
Color :: enum { Red, Green, Blue }
foo :: proc() {
    c := Color.Purple  // Purple not in Color
    _ = c
}
`,
			expect_error = true,
			error_substr = "has no field",
		},
		// Import scope
		{
			id           = "ERR-SC-018",
			name         = "undeclared in import",
			source       = `package test
import "base:runtime"
foo :: proc() {
    _ = runtime.NonExistent
}
`,
			expect_error = true,
			// Oracle, re-run on exactly this source:
			//   a.odin(4:9) Error: 'NonExistent' is not declared by 'runtime'
			// The earlier "Undeclared name" expectation was recorded when the test harness never
			// loaded base:runtime, so `runtime` resolved to nothing and the port reported the
			// generic undeclared-name error. With the runtime session the import resolves and both
			// compilers give the specific message. LEDGER #354.
			error_substr = "is not declared by",
		},
		// TODO: Implicit context access - needs checker implementation
		// {
		// 	id           = "ERR-SC-019",
		// 	name         = "context accessible in proc",
		// 	source       = `package test
		// foo :: proc() {
		//     _ = context.allocator
		// }
		// `,
		// 	expect_error = false,
		// },
		// Type as value error
		{
			id           = "ERR-SC-020",
			name         = "type used as value",
			source       = `package test
foo :: proc() {
    x := int  // int is a type, not a value
}
`,
			expect_error = true,
			error_substr = "type",
		},
	},
}

@(test)
test_scope_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, scope_suite)
}

// =============================================================================
// ADDITIONAL INDIVIDUAL TESTS
// =============================================================================

@(test)
test_err_scope_defer_captures_variable_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - defer captures variables in scope
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc() {
    x := 1
    defer {
        y := x  // can capture x
        _ = y
    }
}
`, "ERR-SC-021: defer captures variable")
}

@(test)
test_err_scope_nested_proc_no_capture_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - nested procedures cannot capture outer variables
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    x := 1
    bar :: proc() {
        _ = x  // cannot capture x from foo
    }
}
`, "ERR-SC-022: nested proc cannot capture")
}

// TODO: using statement needs checker implementation
// @(test)
// test_err_scope_using_brings_fields_into_scope_pos :: proc(t: ^testing.T) {
// 	// @spec: errors.md - using brings fields into scope
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_pass(t, `package test
// Point :: struct { x, y: int }
// foo :: proc() {
//     p: Point = {1, 2}
//     using p
//     z := x + y  // x and y accessible via using
//     _ = z
// }
// `, "ERR-SC-023: using brings fields into scope")
// }

@(test)
test_err_scope_continue_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - continue outside loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    continue  // not in a loop
}
`, "ERR-SC-024: continue outside loop")
}

@(test)
test_err_scope_break_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - break outside loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    break  // not in a loop
}
`, "ERR-SC-025: break outside loop")
}

@(test)
test_err_scope_fallthrough_outside_switch_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - fallthrough outside switch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    fallthrough  // not in a switch
}
`, "ERR-SC-026: fallthrough outside switch")
}

// TODO: return outside proc - parser behavior unclear
// @(test)
// test_err_scope_return_outside_proc_neg :: proc(t: ^testing.T) {
// 	// @spec: errors.md - return outside procedure
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_fail(t, `package test
// return 42
// `, "ERR-SC-027: return outside proc")
// }

@(test)
test_err_scope_labeled_break_to_nonexistent_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - labeled break to non-existent label
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    for i in 0..<10 {
        break nonexistent
    }
}
`, "ERR-SC-028: labeled break to non-existent label")
}
