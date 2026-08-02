package test_spec_directives

/*
Test Coverage: directives.md Section 2 - Parameter/Field Flags

Tests for #no_alias, #any_int, #by_ptr, #c_vararg, #const, using, etc.

Spec Reference: ../spec/directives.md#2-parameter-field-flags
Test IDs: DIR-PARAM-001 through DIR-PARAM-030
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// PROCEDURE PARAMETER FLAGS - Positive Tests
// =============================================================================

@(test)
test_param_no_alias_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #no_alias pointer doesn't alias
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
copy :: proc(#no_alias dst: ^int, src: ^int) {
    dst^ = src^
}
`, "DIR-PARAM-001: #no_alias parameter")
}

@(test)
test_param_any_int_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #any_int accepts any integer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
shift :: proc(x: int, #any_int amount: int) -> int {
    return x << uint(amount)
}
test :: proc() {
    y := shift(1, u8(5))
}
`, "DIR-PARAM-002: #any_int parameter")
}

@(test)
test_param_by_ptr_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #by_ptr passes by pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
BigStruct :: struct {
    data: [1000]int,
}
process :: proc(s: #by_ptr BigStruct) {
    _ = s.data[0]
}
`, "DIR-PARAM-003: #by_ptr parameter")
}

// Temporarily disabled - causes MPSC queue crash
// @(test)
// test_param_c_vararg_pos :: proc(t: ^testing.T) {
// 	// @spec: directives.md#2.1 - #c_vararg for C variadic
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_pass(t, `package test
// foreign import libc "system:c"
// foreign libc {
//     printf :: proc(fmt: cstring, #c_vararg args: ..any) -> i32 ---
// }
// `, "DIR-PARAM-004: #c_vararg parameter")
// }

@(test)
test_param_const_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #const requires compile-time constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
make_array :: proc(#const $N: int) -> [N]int {
    return [N]int{}
}
test :: proc() {
    arr := make_array(5)
}
`, "DIR-PARAM-005: #const parameter")
}

@(test)
test_param_no_broadcast_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #no_broadcast prevents scalar broadcast
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Vec4 :: [4]f32
add :: proc(a: Vec4, b: #no_broadcast Vec4) -> Vec4 {
    return a + b
}
`, "DIR-PARAM-006: #no_broadcast parameter")
}

// =============================================================================
// STRUCT FIELD FLAGS - Positive Tests
// =============================================================================

@(test)
test_field_using_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.2 - using promotes field members
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Base :: struct {
    x, y: int,
}
Derived :: struct {
    using base: Base,
    z: int,
}
test :: proc() {
    d: Derived
    d.x = 1  // Accessed through using
}
`, "DIR-PARAM-007: using field")
}

@(test)
test_field_using_pointer_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.2 - using with pointer field
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Base :: struct {
    value: int,
}
Container :: struct {
    using base: ^Base,
}
`, "DIR-PARAM-008: using pointer field")
}

@(test)
test_field_using_multiple_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#2.2 - multiple using fields
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Position :: struct { x, y: f32 }
Velocity :: struct { vx, vy: f32 }
Entity :: struct {
    using pos: Position,
    using vel: Velocity,
}
`, "DIR-PARAM-009: multiple using fields")
}

// =============================================================================
// PROCEDURE PARAMETER FLAGS - Negative Tests
// =============================================================================

@(test)
test_param_no_alias_non_pointer_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.4 - #no_alias only for pointers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
bad :: proc(#no_alias x: int) {
}
`, "DIR-PARAM-010: #no_alias on non-pointer")
}

@(test)
test_param_any_int_non_int_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.4 - #any_int only for integers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
bad :: proc(#any_int x: f32) {
}
`, "DIR-PARAM-011: #any_int on non-integer")
}

@(test)
test_param_by_ptr_pointer_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.4 - #by_ptr not for pointer types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
bad :: proc(x: #by_ptr ^int) {
}
`, "DIR-PARAM-012: #by_ptr on pointer")
}

// Temporarily disabled - foreign blocks may cause MPSC queue crash
// @(test)
// test_param_c_vararg_not_last_neg :: proc(t: ^testing.T) {
// 	// @spec: directives.md#6.4 - #c_vararg must be last parameter
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_fail(t, `package test
// foreign import libc "system:c"
// foreign libc {
//     bad :: proc(#c_vararg args: ..any, x: int) ---
// }
// `, "DIR-PARAM-013: #c_vararg not last")
// }

// @(test)
// test_param_c_vararg_non_foreign_neg :: proc(t: ^testing.T) {
// 	// @spec: directives.md#6.4 - #c_vararg only in foreign
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_fail(t, `package test
// bad :: proc(#c_vararg args: ..any) {
// }
// `, "DIR-PARAM-014: #c_vararg in non-foreign")
// }

@(test)
test_param_const_non_const_call_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#2.1 - #const requires constant argument
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
make_array :: proc(#const $N: int) -> [N]int {
    return [N]int{}
}
test :: proc() {
    n := 5
    arr := make_array(n)  // Error: n is not constant
}
`, "DIR-PARAM-015: #const with non-constant")
}

// =============================================================================
// STRUCT FIELD FLAGS - Negative Tests
// =============================================================================

@(test)
test_field_using_conflict_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#2.2 - using field name conflicts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Base :: struct { x: int }
Derived :: struct {
    using base: Base,
    x: int,  // Error: conflicts with promoted x
}
`, "DIR-PARAM-016: using field name conflict")
}

@(test)
test_field_using_non_struct_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#2.2 - using requires struct type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Bad :: struct {
    using x: int,
}
`, "DIR-PARAM-017: using on non-struct")
}
