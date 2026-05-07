package test_spec_operators

/*
Test Coverage: operators.md Sections 1-2 - Unary and Arithmetic Operators

Tests for +, -, *, /, %, %%, unary +/-, ~, !, &, ^

Spec Reference: ../spec/operators.md#1-unary-operators, #2-binary-arithmetic
Test IDs: OP-ARITH-001 through OP-ARITH-050
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// UNARY OPERATORS - Positive Tests
// =============================================================================

@(test)
test_op_unary_plus_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.1-unary-plus
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
y := +x
`, "OP-ARITH-001: unary plus on int")
}

@(test)
test_op_unary_minus_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.1-unary-minus
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
y := -x
`, "OP-ARITH-002: unary minus on int")
}

@(test)
test_op_unary_minus_float_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.1-unary-minus
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: f32 = 3.14
y := -x
`, "OP-ARITH-003: unary minus on float")
}

@(test)
test_op_bitwise_not_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.2-bitwise-not
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
y := ~x
`, "OP-ARITH-004: bitwise not on int")
}

@(test)
test_op_logical_not_bool_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.3-logical-not
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
b: bool = true
c := !b
`, "OP-ARITH-005: logical not on bool")
}

@(test)
test_op_address_of_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.5-address-of
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
p := &x
`, "OP-ARITH-006: address-of operator")
}

@(test)
test_op_dereference_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#1.4-dereference
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
p := &x
y := p^
`, "OP-ARITH-007: dereference operator")
}

// =============================================================================
// BINARY ARITHMETIC - Positive Tests
// =============================================================================

@(test)
test_op_add_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.1-addition
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 10
b: int = 20
c := a + b
`, "OP-ARITH-008: int addition")
}

@(test)
test_op_add_float_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.1-addition
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: f32 = 1.5
b: f32 = 2.5
c := a + b
`, "OP-ARITH-009: float addition")
}

@(test)
test_op_add_string_const_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.1-string-concatenation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
S :: "hello" + " " + "world"
`, "OP-ARITH-010: constant string concatenation")
}

@(test)
test_op_sub_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.2-subtraction
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 20
b: int = 10
c := a - b
`, "OP-ARITH-011: int subtraction")
}

@(test)
test_op_mul_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.3-multiplication
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 5
b: int = 6
c := a * b
`, "OP-ARITH-012: int multiplication")
}

@(test)
test_op_div_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.4-division
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 20
b: int = 5
c := a / b
`, "OP-ARITH-013: int division")
}

@(test)
test_op_div_float_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.4-division
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: f32 = 10.0
b: f32 = 3.0
c := a / b
`, "OP-ARITH-014: float division")
}

@(test)
test_op_mod_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.5-modulo
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 17
b: int = 5
c := a % b
`, "OP-ARITH-015: truncated modulo")
}

@(test)
test_op_floor_mod_int_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#2.5-floored-modulo
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = -17
b: int = 5
c := a %% b
`, "OP-ARITH-016: floored modulo")
}

// =============================================================================
// BITWISE OPERATORS - Positive Tests
// =============================================================================

@(test)
test_op_bitwise_and_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#3.1-bitwise-and
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 0b1100
b: int = 0b1010
c := a & b
`, "OP-ARITH-017: bitwise AND")
}

@(test)
test_op_bitwise_or_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#3.2-bitwise-or
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 0b1100
b: int = 0b1010
c := a | b
`, "OP-ARITH-018: bitwise OR")
}

@(test)
test_op_bitwise_xor_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#3.3-bitwise-xor
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 0b1100
b: int = 0b1010
c := a ~ b
`, "OP-ARITH-019: bitwise XOR")
}

@(test)
test_op_and_not_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#3.4-and-not
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 0b1111
b: int = 0b1010
c := a &~ b
`, "OP-ARITH-020: AND NOT")
}

@(test)
test_op_shift_left_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#4.1-left-shift
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 1
b := a << 4
`, "OP-ARITH-021: left shift")
}

@(test)
test_op_shift_right_pos :: proc(t: ^testing.T) {
	// @spec: operators.md#4.2-right-shift
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: int = 16
b := a >> 2
`, "OP-ARITH-022: right shift")
}

// =============================================================================
// NEGATIVE TESTS - Type Mismatches
// =============================================================================

@(test)
test_op_add_int_string_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#2.1 - cannot add int and string
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 42
b: string = "hello"
c := a + b
`, "OP-ARITH-023: cannot add int and string")
}

@(test)
test_op_add_string_runtime_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#2.1 - string concat requires constants
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
get_string :: proc() -> string { return "hello" }
s := get_string() + " world"
`, "OP-ARITH-024: string concat requires constants")
}

@(test)
test_op_logical_not_int_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#1.3 - logical not only on bool
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = 42
y := !x
`, "OP-ARITH-025: logical not on int")
}

@(test)
test_op_mod_float_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#2.5 - modulo only on integers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: f32 = 10.0
b: f32 = 3.0
c := a % b
`, "OP-ARITH-026: modulo on floats")
}

@(test)
test_op_shift_float_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#4 - shift only on integers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: f32 = 1.0
b := a << 2
`, "OP-ARITH-027: shift on float")
}

@(test)
test_op_bitwise_and_float_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#3.1 - bitwise only on integers/bools
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: f32 = 1.0
b: f32 = 2.0
c := a & b
`, "OP-ARITH-028: bitwise AND on floats")
}

@(test)
test_op_div_incompatible_types_neg :: proc(t: ^testing.T) {
	// @spec: operators.md - type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: int = 10
b: string = "hello"
c := a / b
`, "OP-ARITH-029: division with incompatible types")
}

@(test)
test_op_address_of_literal_neg :: proc(t: ^testing.T) {
	// @spec: operators.md#1.5 - address-of requires lvalue
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
p := &42
`, "OP-ARITH-030: cannot take address of literal")
}
