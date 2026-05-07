package test_spec_errors

/*
Test Coverage: errors.md - Control Flow Errors

Tests for control flow statement errors including if, for, switch,
break, continue, fallthrough, and return.

Spec Reference: ../spec/errors.md#control-flow
Test IDs: ERR-CF-001 through ERR-CF-050
Last Sync: 2026-01-18
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// CONTROL FLOW ERROR TEST SUITE
// =============================================================================

control_flow_suite := helpers.Test_Suite {
	name         = "Control Flow Errors",
	spec_file    = "errors.md",
	spec_section = "control-flow",
	cases        = {
		// If statement condition must be bool
		{
			id           = "ERR-CF-001",
			name         = "if condition must be bool",
			source       = `package test
foo :: proc() {
    if 42 {  // int not bool
    }
}
`,
			expect_error = true,
			error_substr = "bool",
		},
		{
			id           = "ERR-CF-002",
			name         = "if condition string not bool",
			source       = `package test
foo :: proc() {
    if "hello" {
    }
}
`,
			expect_error = true,
			error_substr = "bool",
		},
		// For loop condition must be bool
		{
			id           = "ERR-CF-003",
			name         = "for condition must be bool",
			source       = `package test
foo :: proc() {
    for 42 {
    }
}
`,
			expect_error = true,
			error_substr = "bool",
		},
		// While loop (for without range) OK
		{
			id           = "ERR-CF-004",
			name         = "while loop with bool",
			source       = `package test
foo :: proc() {
    i := 0
    for i < 10 {
        i += 1
    }
}
`,
			expect_error = false,
		},
		// For range over non-iterable
		{
			id           = "ERR-CF-005",
			name         = "for range over int",
			source       = `package test
foo :: proc() {
    for x in 42 {  // can't iterate over int
        _ = x
    }
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// For range over array OK
		{
			id           = "ERR-CF-006",
			name         = "for range over array OK",
			source       = `package test
foo :: proc() {
    arr := [3]int{1, 2, 3}
    for x in arr {
        _ = x
    }
}
`,
			expect_error = false,
		},
		// For range over string OK
		{
			id           = "ERR-CF-007",
			name         = "for range over string OK",
			source       = `package test
foo :: proc() {
    for c in "hello" {
        _ = c
    }
}
`,
			expect_error = false,
		},
		// For range over slice OK
		{
			id           = "ERR-CF-008",
			name         = "for range over slice OK",
			source       = `package test
foo :: proc() {
    s: []int = nil
    for x in s {
        _ = x
    }
}
`,
			expect_error = false,
		},
		// For range over map OK
		{
			id           = "ERR-CF-009",
			name         = "for range over map OK",
			source       = `package test
foo :: proc() {
    m: map[string]int
    for k, v in m {
        _ = k
        _ = v
    }
}
`,
			expect_error = false,
		},
		// TODO: Switch expression type mismatch - needs checker implementation
		// {
		// 	id           = "ERR-CF-010",
		// 	name         = "switch case type mismatch",
		// 	source       = `package test
		// foo :: proc() {
		//     x := 42
		//     switch x {
		//     case "hello":  // string case for int switch
		//         break
		//     }
		// }
		// `,
		// 	expect_error = true,
		// 	error_substr = "cannot",
		// },
		// Switch duplicate cases
		{
			id           = "ERR-CF-011",
			name         = "switch duplicate case",
			source       = `package test
foo :: proc() {
    x := 42
    switch x {
    case 1:
        break
    case 1:  // duplicate
        break
    }
}
`,
			expect_error = true,
			error_substr = "duplicate",
		},
		// Return type mismatch
		{
			id           = "ERR-CF-012",
			name         = "return wrong type",
			source       = `package test
foo :: proc() -> int {
    return "hello"
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Return missing value
		{
			id           = "ERR-CF-013",
			name         = "return missing value",
			source       = `package test
foo :: proc() -> int {
    return  // missing return value
}
`,
			expect_error = true,
			error_substr = "return",
		},
		// Return extra value
		{
			id           = "ERR-CF-014",
			name         = "return extra value",
			source       = `package test
foo :: proc() {
    return 42  // unexpected return value
}
`,
			expect_error = true,
			error_substr = "return",
		},
		// Return wrong number of values
		{
			id           = "ERR-CF-015",
			name         = "return wrong count",
			source       = `package test
foo :: proc() -> (int, int) {
    return 1  // missing second value
}
`,
			expect_error = true,
			error_substr = "return",
		},
		// TODO: Fallthrough in last case - needs checker implementation
		// {
		// 	id           = "ERR-CF-016",
		// 	name         = "fallthrough in last case",
		// 	source       = `package test
		// foo :: proc() {
		//     x := 1
		//     switch x {
		//     case 1:
		//         fallthrough  // last case
		//     }
		// }
		// `,
		// 	expect_error = true,
		// 	error_substr = "fallthrough",
		// },
		// Break with label in wrong scope
		{
			id           = "ERR-CF-017",
			name         = "break to label in different proc",
			source       = `package test
foo :: proc() {
    outer: for {
        break
    }
}
bar :: proc() {
    break outer  // label not visible here
}
`,
			expect_error = true,
			error_substr = "undeclared",
		},
		// Continue in switch (not allowed without label to loop)
		{
			id           = "ERR-CF-018",
			name         = "continue in switch without loop",
			source       = `package test
foo :: proc() {
    x := 1
    switch x {
    case 1:
        continue  // no loop to continue
    }
}
`,
			expect_error = true,
			error_substr = "continue",
		},
		// Defer in loop (allowed)
		{
			id           = "ERR-CF-019",
			name         = "defer in loop OK",
			source       = `package test
close :: proc(x: int) {}
foo :: proc() {
    for i in 0..<10 {
        defer close(i)
    }
}
`,
			expect_error = false,
		},
		// Multiple returns in non-returning proc
		{
			id           = "ERR-CF-020",
			name         = "multiple returns OK",
			source       = `package test
foo :: proc(x: int) {
    if x > 0 {
        return
    }
    return
}
`,
			expect_error = false,
		},
	},
}

@(test)
test_control_flow_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, control_flow_suite)
}

// =============================================================================
// ADDITIONAL INDIVIDUAL TESTS
// =============================================================================

@(test)
test_err_cf_for_range_with_wrong_value_count_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - for range with wrong number of values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    arr := [3]int{1, 2, 3}
    for a, b, c in arr {  // too many values
        _ = a
        _ = b
        _ = c
    }
}
`, "ERR-CF-021: for range wrong value count")
}

// TODO: switch on procedure type - needs checker implementation
// @(test)
// test_err_cf_switch_on_proc_neg :: proc(t: ^testing.T) {
// 	// @spec: errors.md - cannot switch on procedure type
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_fail(t, `package test
// bar :: proc() {}
// foo :: proc() {
//     switch bar {  // can't switch on proc
//     }
// }
// `, "ERR-CF-022: switch on procedure")
// }

@(test)
test_err_cf_infinite_loop_without_break_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - infinite loop is allowed (may have break inside)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc() {
    for {
        break
    }
}
`, "ERR-CF-023: infinite loop with break")
}

@(test)
test_err_cf_or_else_non_optional_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - or_else on non-optional type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() {
    x := 42
    y := x or_else 0  // x is not optional
}
`, "ERR-CF-024: or_else on non-optional")
}

@(test)
test_err_cf_defer_return_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - return not allowed in defer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc() -> int {
    defer {
        return 0  // not allowed
    }
    return 1
}
`, "ERR-CF-025: return in defer")
}

@(test)
test_err_cf_if_else_branch_types_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - if/else branches with compatible types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc(b: bool) -> int {
    if b {
        return 1
    } else {
        return 2
    }
}
`, "ERR-CF-026: if/else branch types")
}

@(test)
test_err_cf_ternary_type_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - ternary branches must have same type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc(b: bool) {
    x := b ? 42 : "hello"  // int vs string
    _ = x
}
`, "ERR-CF-027: ternary type mismatch")
}

@(test)
test_err_cf_for_c_style_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - C-style for loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc() {
    for i := 0; i < 10; i += 1 {
        _ = i
    }
}
`, "ERR-CF-028: C-style for loop")
}

@(test)
test_err_cf_switch_no_fallthrough_by_default_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - switch doesn't fallthrough by default
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc() {
    x := 1
    switch x {
    case 1:
        y := 1
        _ = y
    case 2:
        z := 2
        _ = z
    }
}
`, "ERR-CF-029: switch no fallthrough")
}

@(test)
test_err_cf_switch_with_type_union_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - type switch on union
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Value :: union { int, string }
foo :: proc() {
    v: Value = 42
    switch x in v {
    case int:
        _ = x + 1
    case string:
        _ = x
    }
}
`, "ERR-CF-030: type switch on union")
}
