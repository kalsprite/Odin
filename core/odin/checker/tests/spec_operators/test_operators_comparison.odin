package test_spec_operators

/*
Test Coverage: operators.md Sections 5-6 - Logical and Comparison Operators

Tests for &&, ||, ==, !=, <, <=, >, >=

Spec Reference: ../spec/operators.md#5-logical, #6-comparison
Test IDs: OP-CMP-001 through OP-CMP-040
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// LOGICAL OPERATORS - Positive Tests
// =============================================================================

@(test)
test_op_logical_and_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#5.1-logical-and
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: bool = true
b: bool = false
c := a && b
`, "OP-CMP-001: logical AND")
}

@(test)
test_op_logical_or_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#5.2-logical-or
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: bool = true
b: bool = false
c := a || b
`, "OP-CMP-002: logical OR")
}

@(test)
test_op_logical_chain_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#5 - chained logical
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: bool = true
b: bool = false
c: bool = true
d := a && b || c
`, "OP-CMP-003: chained logical operators")
}

// =============================================================================
// COMPARISON OPERATORS - Positive Tests
// =============================================================================

@(test)
test_op_eq_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 42
b: int = 42
c := a == b
`, "OP-CMP-004: int equality")
}

@(test)
test_op_neq_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 42
b: int = 43
c := a != b
`, "OP-CMP-005: int inequality")
}

@(test)
test_op_lt_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 10
b: int = 20
c := a < b
`, "OP-CMP-006: less than")
}

@(test)
test_op_lte_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 10
b: int = 10
c := a <= b
`, "OP-CMP-007: less than or equal")
}

@(test)
test_op_gt_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 20
b: int = 10
c := a > b
`, "OP-CMP-008: greater than")
}

@(test)
test_op_gte_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 10
b: int = 10
c := a >= b
`, "OP-CMP-009: greater than or equal")
}

@(test)
test_op_eq_bool_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: bool = true
b: bool = true
c := a == b
`, "OP-CMP-010: bool equality")
}

@(test)
test_op_eq_string_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: string = "hello"
b: string = "hello"
c := a == b
`, "OP-CMP-011: string equality")
}

@(test)
test_op_lt_string_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering-string
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: string = "abc"
b: string = "abd"
c := a < b
`, "OP-CMP-012: string ordering")
}

@(test)
test_op_eq_pointer_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-pointer-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
p1 := &x
p2 := &x
c := p1 == p2
`, "OP-CMP-013: pointer equality")
}

@(test)
test_op_eq_enum_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1-enum-equality
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
a: Color = .Red
b: Color = .Red
c := a == b
`, "OP-CMP-014: enum equality")
}

@(test)
test_op_lt_float_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2-ordering
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: f32 = 1.5
b: f32 = 2.5
c := a < b
`, "OP-CMP-015: float ordering")
}

// =============================================================================
// NEGATIVE TESTS
// =============================================================================

@(test)
test_op_logical_and_int_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#5.1 - logical only on bools
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 1
b: int = 2
c := a && b
`, "OP-CMP-016: logical AND on ints")
}

@(test)
test_op_logical_or_int_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#5.2 - logical only on bools
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 1
b: int = 2
c := a || b
`, "OP-CMP-017: logical OR on ints")
}

@(test)
test_op_eq_incompatible_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#6.1 - must compare same types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 42
b: string = "hello"
c := a == b
`, "OP-CMP-018: equality on incompatible types")
}

@(test)
test_op_lt_incompatible_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2 - must compare same ordered types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 42
b: string = "hello"
c := a < b
`, "OP-CMP-019: ordering on incompatible types")
}

@(test)
test_op_lt_bool_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#6.2 - bools not ordered
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: bool = true
b: bool = false
c := a < b
`, "OP-CMP-020: ordering on bools")
}
