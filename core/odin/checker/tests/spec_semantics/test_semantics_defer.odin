package test_spec_semantics

/*
Test Coverage: semantics.md Section 9 - Defer Statement

Tests for defer execution order, restrictions, and special directives.

Spec Reference: ../spec/semantics.md#9-defer-statement
Test IDs: SEM-DEFER-001 through SEM-DEFER-030
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// BASIC DEFER - Positive Tests
// =============================================================================

@(test)
test_defer_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.1 - basic defer statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
close :: proc(x: int) {}
test :: proc() {
    f := 1
    defer close(f)
    _ = f
}
`, "SEM-DEFER-001: basic defer")
}

@(test)
test_defer_multiple_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.2 - multiple defers (LIFO order)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
log :: proc(x: int) {}
test :: proc() {
    defer log(1)
    defer log(2)
    defer log(3)
}
`, "SEM-DEFER-002: multiple defers")
}

@(test)
test_defer_in_loop_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.1 - defer in loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
close :: proc(x: int) {}
test :: proc() {
    for i in 0..<3 {
        defer close(i)
    }
}
`, "SEM-DEFER-003: defer in loop")
}

@(test)
test_defer_in_block_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.1 - defer in block scope
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
cleanup :: proc() {}
test :: proc() {
    {
        defer cleanup()
        x := 1
        _ = x
    }  // cleanup called here
}
`, "SEM-DEFER-004: defer in block")
}

@(test)
test_defer_if_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.1 - defer with if condition
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
cleanup :: proc() {}
test :: proc(cond: bool) {
    if cond {
        defer cleanup()
    }
}
`, "SEM-DEFER-005: defer in if")
}

@(test)
test_defer_block_stmt_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.1 - defer with block statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 0
    defer {
        x = 1
        y := 2
        _ = y
    }
}
`, "SEM-DEFER-006: defer block")
}

// =============================================================================
// DEFER RESTRICTIONS - Negative Tests
// =============================================================================

@(test)
test_defer_return_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.4 - return not allowed in defer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() -> int {
    defer {
        return 0  // Error: return in defer
    }
    return 1
}
`, "SEM-DEFER-007: return in defer")
}

@(test)
test_defer_labeled_break_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.4 - labeled break not allowed in defer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    outer: for {
        defer {
            break outer  // Error: labeled break in defer
        }
        break
    }
}
`, "SEM-DEFER-008: labeled break in defer")
}

@(test)
test_defer_labeled_continue_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#9.4 - labeled continue not allowed in defer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    outer: for i in 0..<10 {
        defer {
            continue outer  // Error: labeled continue in defer
        }
    }
}
`, "SEM-DEFER-009: labeled continue in defer")
}

// =============================================================================
// OR-KEYWORDS - Positive Tests
// =============================================================================

@(test)
test_or_else_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.5 - or_else for nil coalescing
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
test :: proc() {
    m: Maybe
    value := m.? or_else 0
}
`, "SEM-DEFER-010: or_else")
}

@(test)
test_or_return_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.5 - or_return propagates error
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Maybe :: union { int }
inner :: proc() -> Maybe { return nil }
outer :: proc() -> Maybe {
    value := inner().? or_return
    return value
}
`, "SEM-DEFER-011: or_return")
}

@(test)
test_or_break_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.5 - or_break exits loop
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
`, "SEM-DEFER-012: or_break")
}

@(test)
test_or_continue_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.5 - or_continue skips iteration
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
`, "SEM-DEFER-013: or_continue")
}

// =============================================================================
// DIVERGING PROCEDURES - Positive Tests
// =============================================================================

@(test)
test_diverging_proc_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.7 - diverging procedure with -> !
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
import "base:intrinsics"
fatal :: proc() -> ! {
    intrinsics.trap()
}
`, "SEM-DEFER-014: diverging proc")
}

// =============================================================================
// DIVERGING - Negative Tests
// =============================================================================

@(test)
test_diverging_with_return_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.7 - diverging may not return
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
fatal :: proc() -> ! {
    return  // Error: diverging cannot return
}
`, "SEM-DEFER-015: diverging return")
}
