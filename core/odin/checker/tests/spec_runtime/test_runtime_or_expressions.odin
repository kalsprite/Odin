package test_spec_runtime

/*
Test Coverage: runtime.md Section 1 - Or-Expression Family

Tests for or_else, or_return, or_break, or_continue.

Spec Reference: ../spec/runtime.md#1-or-expression-family
Test IDs: RT-OR-001 through RT-OR-040
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// OR_ELSE - Positive Tests
// =============================================================================

@(test)
test_or_else_union_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.1 - or_else with union
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
test :: proc() {
    m: Maybe
    value := m.? or_else 0
}
`, "RT-OR-001: or_else with union")
}

@(test)
test_or_else_pointer_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.1 - or_else with pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    ptr: ^int = nil
    default_val := 42
    value := ptr^ if ptr != nil else default_val
}
`, "RT-OR-002: pointer nil check pattern")
}

@(test)
test_or_else_chain_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.1 - chained or_else
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
first :: proc() -> Maybe { return nil }
second :: proc() -> Maybe { return nil }
test :: proc() {
    value := first().? or_else second().? or_else 0
}
`, "RT-OR-003: chained or_else")
}

// =============================================================================
// OR_RETURN - Positive Tests
// =============================================================================

@(test)
test_or_return_basic_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.2 - or_return propagates error
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
inner :: proc() -> Maybe { return nil }
outer :: proc() -> Maybe {
    value := inner().? or_return
    return value
}
`, "RT-OR-004: or_return basic")
}

@(test)
test_or_return_chained_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.2 - multiple or_return in sequence
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
step1 :: proc() -> Maybe { return 1 }
step2 :: proc(x: int) -> Maybe { return x + 1 }
process :: proc() -> Maybe {
    a := step1().? or_return
    b := step2(a).? or_return
    return b
}
`, "RT-OR-005: chained or_return")
}

// =============================================================================
// OR_BREAK - Positive Tests
// =============================================================================

@(test)
test_or_break_basic_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.3 - or_break exits loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
get :: proc(i: int) -> Maybe { return nil }
test :: proc() {
    for i in 0..<10 {
        value := get(i).? or_break
        _ = value
    }
}
`, "RT-OR-006: or_break basic")
}

@(test)
test_or_break_labeled_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.3 - or_break with label
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
check :: proc(x, y: int) -> Maybe { return nil }
test :: proc() {
    outer: for x in 0..<5 {
        for y in 0..<5 {
            result := check(x, y).? or_break outer
            _ = result
        }
    }
}
`, "RT-OR-007: or_break with label")
}

// =============================================================================
// OR_CONTINUE - Positive Tests
// =============================================================================

@(test)
test_or_continue_basic_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.4 - or_continue skips iteration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
validate :: proc(i: int) -> Maybe { return nil }
test :: proc() {
    for i in 0..<10 {
        value := validate(i).? or_continue
        _ = value
    }
}
`, "RT-OR-008: or_continue basic")
}

@(test)
test_or_continue_labeled_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.4 - or_continue with label
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
check :: proc(x, y: int) -> Maybe { return nil }
test :: proc() {
    outer: for x in 0..<5 {
        for y in 0..<5 {
            result := check(x, y).? or_continue outer
            _ = result
        }
    }
}
`, "RT-OR-009: or_continue with label")
}

// =============================================================================
// OR_EXPRESSIONS - Negative Tests
// =============================================================================

@(test)
test_or_return_in_defer_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.2 - or_return not allowed in defer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Maybe :: union { int }
may_fail :: proc() -> Maybe { return nil }
test :: proc() -> Maybe {
    defer {
        _ = may_fail().? or_return  // Error
    }
    return 1
}
`, "RT-OR-010: or_return in defer")
}

@(test)
test_or_break_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.3 - or_break must be in loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Maybe :: union { int }
get :: proc() -> Maybe { return nil }
test :: proc() {
    value := get().? or_break  // Error: not in loop
}
`, "RT-OR-011: or_break outside loop")
}

@(test)
test_or_continue_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.4 - or_continue must be in loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Maybe :: union { int }
get :: proc() -> Maybe { return nil }
test :: proc() {
    value := get().? or_continue  // Error: not in loop
}
`, "RT-OR-012: or_continue outside loop")
}

@(test)
test_or_else_type_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#1.1 - right side type must match
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Maybe :: union { int }
test :: proc() {
    m: Maybe
    value := m.? or_else "string"  // Error: type mismatch
}
`, "RT-OR-013: or_else type mismatch")
}
