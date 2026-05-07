package test_spec_runtime

/*
Test Coverage: runtime.md Sections 2-8 - RTTI, Bounds, TLS, Constants

Tests for typeid, type_info, bounds checking attributes, thread_local, etc.

Spec Reference: ../spec/runtime.md#2-rtti-runtime-type-information
Test IDs: RT-TYPE-001 through RT-TYPE-040
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// TYPEID - Positive Tests
// =============================================================================

@(test)
test_typeid_basic_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#2.2 - typeid as value
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    id: typeid = int
    _ = id
}
`, "RT-TYPE-001: typeid basic")
}

@(test)
test_typeid_comparison_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#2.2 - compare typeids
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    id: typeid = int
    if id == int {
        x := 1
    }
}
`, "RT-TYPE-002: typeid comparison")
}

@(test)
test_typeid_switch_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#2.2 - switch on typeid
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    id: typeid = int
    switch id {
    case int:
        _ = 1
    case f32:
        _ = 2
    case:
        _ = 0
    }
}
`, "RT-TYPE-003: typeid switch")
}

@(test)
test_type_info_of_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#2.3 - type_info_of builtin
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
import "base:runtime"
test :: proc() {
    info := type_info_of(int)
    _ = info
}
`, "RT-TYPE-004: type_info_of")
}

// =============================================================================
// THREAD LOCAL - Positive Tests
// =============================================================================

@(test)
test_thread_local_basic_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#4.1 - basic thread_local
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(thread_local)
my_tls: int
`, "RT-TYPE-005: thread_local basic")
}

@(test)
test_thread_local_model_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#4.2 - thread_local with model
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(thread_local="default")
tls_default: int
`, "RT-TYPE-006: thread_local with model")
}

// =============================================================================
// BOUNDS CHECKING ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_bounds_check_attr_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#3.3 - @(bounds_check) attribute
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(bounds_check)
safe_access :: proc(arr: []int, i: int) -> int {
    return arr[i]
}
`, "RT-TYPE-007: bounds_check attribute")
}

@(test)
test_no_bounds_check_attr_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#3.3 - @(no_bounds_check) attribute
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(no_bounds_check)
unsafe_access :: proc(arr: []int, i: int) -> int {
    return arr[i]
}
`, "RT-TYPE-008: no_bounds_check attribute")
}

// =============================================================================
// CONSTANT EXPRESSIONS - Positive Tests
// =============================================================================

@(test)
test_const_array_size_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.1 - array size must be constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
SIZE :: 10
arr: [SIZE]int
`, "RT-TYPE-009: constant array size")
}

@(test)
test_const_size_of_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.2 - size_of is constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
BYTES :: size_of(int)
arr: [BYTES]u8
`, "RT-TYPE-010: size_of as constant")
}

@(test)
test_const_align_of_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.2 - align_of is constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
ALIGN :: align_of(int)
S :: struct #align(ALIGN) { x: int }
`, "RT-TYPE-011: align_of as constant")
}

@(test)
test_const_len_fixed_array_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.2 - len of fixed array is constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr :: [5]int{}
N :: len(arr)
arr2: [N]int
`, "RT-TYPE-012: len of fixed array")
}

// =============================================================================
// STRING TYPES - Positive Tests
// =============================================================================

@(test)
test_string_literal_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#6.2 - string literals
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    s := "hello"
    r := ` + "`raw\\nstring`" + `
}
`, "RT-TYPE-013: string literals")
}

@(test)
test_cstring_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#6.1 - cstring type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    c: cstring = "hello"
    _ = c
}
`, "RT-TYPE-014: cstring type")
}

@(test)
test_cstring_to_string_pos :: proc(t: ^testing.T) {
	// @spec: runtime.md#6.4 - cstring to string conversion
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    c: cstring = "hello"
    s := string(c)
    _ = s
}
`, "RT-TYPE-015: cstring to string")
}

// =============================================================================
// CONSTANT EXPRESSIONS - Negative Tests
// =============================================================================

@(test)
test_const_array_size_var_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.1 - array size must be constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    n := 10
    arr: [n]int  // Error: n is not constant
}
`, "RT-TYPE-016: variable array size")
}

@(test)
test_const_len_slice_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#8.3 - len of slice is not constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    s: []int
    N :: len(s)  // Error: len of slice is not constant
}
`, "RT-TYPE-017: len of slice not constant")
}

// =============================================================================
// THREAD LOCAL - Negative Tests
// =============================================================================

@(test)
test_thread_local_blank_neg :: proc(t: ^testing.T) {
	// @spec: runtime.md#4.3 - thread_local not allowed on _
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
@(thread_local)
_: int  // Error
`, "RT-TYPE-018: thread_local on blank")
}
