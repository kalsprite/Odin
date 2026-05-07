package test_spec_advanced

/*
Test Coverage: advanced.md Section 2 - Procedure Groups (Overloading)

Tests for procedure groups, overload resolution, etc.

Spec Reference: ../spec/advanced.md#2-procedure-groups
Test IDs: ADV-PG-001 through ADV-PG-050
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// PROCEDURE GROUPS - Positive Tests
// =============================================================================

@(test)
test_proc_group_basic_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.1 - basic procedure group
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
show_int :: proc(x: int) {}
show_string :: proc(x: string) {}

show :: proc {
    show_int,
    show_string,
}

test :: proc() {
    show(42)
    show("hello")
}
`, "ADV-PG-001: basic proc group")
}

@(test)
test_proc_group_with_return_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.1 - proc group with returns
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
parse_int :: proc(s: string) -> int { return 0 }
parse_float :: proc(s: string) -> f32 { return 0 }

// Note: these have same param but different returns
// Resolution uses expected type context
`, "ADV-PG-002: proc group with returns")
}

@(test)
test_proc_group_exact_match_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.2 - exact match priority
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
handle_i32 :: proc(x: i32) {}
handle_i64 :: proc(x: i64) {}

handle :: proc {
    handle_i32,
    handle_i64,
}

test :: proc() {
    x: i32 = 42
    handle(x)  // Calls handle_i32 (exact match)
}
`, "ADV-PG-003: exact match priority")
}

@(test)
test_proc_group_three_overloads_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.1 - three overloads
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
process_int :: proc(x: int) -> int { return x }
process_float :: proc(x: f32) -> f32 { return x }
process_string :: proc(x: string) -> string { return x }

process :: proc {
    process_int,
    process_float,
    process_string,
}

test :: proc() {
    _ = process(42)
    _ = process(3.14)
    _ = process("hi")
}
`, "ADV-PG-004: three overloads")
}

@(test)
test_proc_group_param_count_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.2 - different param counts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
add1 :: proc(a: int) -> int { return a }
add2 :: proc(a, b: int) -> int { return a + b }
add3 :: proc(a, b, c: int) -> int { return a + b + c }

add :: proc {
    add1,
    add2,
    add3,
}

test :: proc() {
    _ = add(1)
    _ = add(1, 2)
    _ = add(1, 2, 3)
}
`, "ADV-PG-005: different param counts")
}

@(test)
test_proc_group_with_poly_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.2 - proc group with polymorphic
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
show_specific :: proc(x: int) {}
show_generic :: proc(x: $T) {}

show :: proc {
    show_specific,  // Higher priority for int
    show_generic,
}

test :: proc() {
    show(42)      // Calls show_specific
    show("test")  // Calls show_generic
}
`, "ADV-PG-006: proc group with poly")
}

// =============================================================================
// PROCEDURE GROUPS - Negative Tests
// =============================================================================

@(test)
test_proc_group_ambiguous_neg :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.2 - ambiguous overload resolution
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
handle_a :: proc(x: int, y: int) {}
handle_b :: proc(x: int, y: int) {}

handle :: proc {
    handle_a,
    handle_b,
}

test :: proc() {
    handle(1, 2)  // Error: ambiguous
}
`, "ADV-PG-007: ambiguous overload")
}

@(test)
test_proc_group_no_match_neg :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.2 - no matching overload
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
handle_int :: proc(x: int) {}
handle_string :: proc(x: string) {}

handle :: proc {
    handle_int,
    handle_string,
}

test :: proc() {
    handle(3.14)  // Error: no match for f64
}
`, "ADV-PG-008: no matching overload")
}

@(test)
test_proc_group_empty_neg :: proc(t: ^testing.T) {
	// @spec: advanced.md#2.1 - empty proc group
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
empty :: proc {
    // Error: no procedures
}
`, "ADV-PG-009: empty proc group")
}
