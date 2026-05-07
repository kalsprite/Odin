package test_spec_semantics

/*
Test Coverage: semantics.md Section 2 - Control Flow Structures

Tests for if, for, switch, when statements and their variants.

Spec Reference: ../spec/semantics.md#2-control-flow-structures
Test IDs: SEM-CF-001 through SEM-CF-060
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// IF STATEMENT - Positive Tests
// =============================================================================

@(test)
test_if_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - Basic if statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 5
    if x > 0 {
        y := x * 2
        _ = y
    }
}
`, "SEM-CF-001: basic if")
}

@(test)
test_if_else_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - if-else statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 5
    if x > 0 {
        y := 1
    } else {
        y := -1
    }
}
`, "SEM-CF-002: if-else")
}

@(test)
test_if_else_if_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - if-else if chain
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 5
    if x < 0 {
        y := -1
    } else if x == 0 {
        y := 0
    } else {
        y := 1
    }
}
`, "SEM-CF-003: if-else if-else")
}

@(test)
test_if_init_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - if with initialization
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
compute :: proc() -> int { return 42 }
test :: proc() {
    if x := compute(); x > 0 {
        _ = x
    }
}
`, "SEM-CF-004: if with init")
}

@(test)
test_if_do_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - if do form
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 5
    y := 0
    if x > 0 do y = 1
}
`, "SEM-CF-005: if do")
}

// =============================================================================
// FOR LOOP - Positive Tests
// =============================================================================

@(test)
test_for_cstyle_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - C-style for loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    sum := 0
    for i := 0; i < 10; i += 1 {
        sum += i
    }
}
`, "SEM-CF-006: C-style for")
}

@(test)
test_for_while_style_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - while-style for
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    running := true
    count := 0
    for running {
        count += 1
        if count >= 10 do running = false
    }
}
`, "SEM-CF-007: while-style for")
}

@(test)
test_for_infinite_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - infinite for loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    for {
        break
    }
}
`, "SEM-CF-008: infinite for")
}

@(test)
test_for_range_value_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - range-based for (value only)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr := [3]int{1, 2, 3}
    sum := 0
    for x in arr {
        sum += x
    }
}
`, "SEM-CF-009: for with value")
}

@(test)
test_for_range_index_value_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - range-based for (index, value)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr := [3]int{1, 2, 3}
    for i, x in arr {
        _ = i
        _ = x
    }
}
`, "SEM-CF-010: for with index, value")
}

@(test)
test_for_range_mutable_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - range-based for with mutable reference
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr := [3]int{1, 2, 3}
    for &x in arr {
        x *= 2
    }
}
`, "SEM-CF-011: for with mutable ref")
}

@(test)
test_for_range_numeric_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - for over numeric range
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    sum := 0
    for i in 0..<10 {
        sum += i
    }
}
`, "SEM-CF-012: for over range")
}

@(test)
test_for_do_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.3 - for do form
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
process :: proc(x: int) {}
test :: proc() {
    arr := [3]int{1, 2, 3}
    for x in arr do process(x)
}
`, "SEM-CF-013: for do")
}

// =============================================================================
// SWITCH STATEMENT - Positive Tests
// =============================================================================

@(test)
test_switch_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - basic switch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 2
    switch x {
    case 1:
        y := 1
    case 2:
        y := 2
    case:
        y := 0
    }
}
`, "SEM-CF-014: basic switch")
}

@(test)
test_switch_multiple_values_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - switch with multiple values per case
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 2
    switch x {
    case 1, 2, 3:
        y := "small"
    case 4, 5:
        y := "medium"
    case:
        y := "large"
    }
}
`, "SEM-CF-015: switch multiple values")
}

@(test)
test_switch_range_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - switch with range case
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 5
    switch x {
    case 1..=3:
        y := "low"
    case 4..=6:
        y := "mid"
    case:
        y := "high"
    }
}
`, "SEM-CF-016: switch range")
}

@(test)
test_switch_init_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - switch with initialization
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
get :: proc() -> int { return 1 }
test :: proc() {
    switch x := get(); x {
    case 1:
        _ = x
    case:
        _ = x
    }
}
`, "SEM-CF-017: switch with init")
}

@(test)
test_switch_enum_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - switch on enum (exhaustive)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
test :: proc() {
    c: Color = .Red
    switch c {
    case .Red:
        _ = 1
    case .Green:
        _ = 2
    case .Blue:
        _ = 3
    }
}
`, "SEM-CF-018: switch enum exhaustive")
}

// =============================================================================
// TYPE SWITCH - Positive Tests
// =============================================================================

@(test)
test_type_switch_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.5 - type switch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Value :: union { int, f32, string }
test :: proc() {
    v: Value = 42
    switch x in v {
    case int:
        _ = x
    case f32:
        _ = x
    case string:
        _ = x
    case:
        // nil
    }
}
`, "SEM-CF-019: type switch")
}

// =============================================================================
// WHEN STATEMENT - Positive Tests
// =============================================================================

@(test)
test_when_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.6 - when statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
when size_of(int) == 8 {
    Int_Size :: 64
} else {
    Int_Size :: 32
}
`, "SEM-CF-020: when statement")
}

// =============================================================================
// BREAK/CONTINUE - Positive Tests
// =============================================================================

@(test)
test_break_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.1 - break statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    for i := 0; i < 10; i += 1 {
        if i == 5 do break
    }
}
`, "SEM-CF-021: break")
}

@(test)
test_break_labeled_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.1 - labeled break
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    outer: for x in 0..<10 {
        for y in 0..<10 {
            if x + y > 5 do break outer
        }
    }
}
`, "SEM-CF-022: labeled break")
}

@(test)
test_continue_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.2 - continue statement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    sum := 0
    for i in 0..<10 {
        if i % 2 == 0 do continue
        sum += i
    }
}
`, "SEM-CF-023: continue")
}

@(test)
test_fallthrough_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.3 - fallthrough
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 1
    switch x {
    case 1:
        y := 1
        fallthrough
    case 2:
        z := 2
    }
}
`, "SEM-CF-024: fallthrough")
}

// =============================================================================
// CONTROL FLOW - Negative Tests
// =============================================================================

@(test)
test_if_non_bool_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.2 - if requires bool
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    if 42 {  // Error: not a bool
        x := 1
    }
}
`, "SEM-CF-025: if non-bool condition")
}

@(test)
test_break_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.1 - break must be in loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    break  // Error: not in loop
}
`, "SEM-CF-026: break outside loop")
}

@(test)
test_continue_outside_loop_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.2 - continue must be in loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    continue  // Error: not in loop
}
`, "SEM-CF-027: continue outside loop")
}

@(test)
test_fallthrough_not_last_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.3 - fallthrough must be last
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x := 1
    switch x {
    case 1:
        fallthrough
        y := 1  // Error: statement after fallthrough
    case 2:
        z := 2
    }
}
`, "SEM-CF-028: fallthrough not last")
}

@(test)
test_fallthrough_in_type_switch_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#8.3 - fallthrough not in type switch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Value :: union { int, f32 }
test :: proc() {
    v: Value = 42
    switch x in v {
    case int:
        fallthrough  // Error: not allowed in type switch
    case f32:
        _ = x
    }
}
`, "SEM-CF-029: fallthrough in type switch")
}

@(test)
test_switch_duplicate_case_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#2.4 - duplicate case values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x := 1
    switch x {
    case 1:
        y := 1
    case 1:  // Error: duplicate case
        y := 2
    }
}
`, "SEM-CF-030: duplicate switch case")
}
