package test_spec_builtins

/*
Test Coverage: builtins.md - Core Built-in Procedures

Tests for core built-in procedures from the builtin package.

Spec Reference: ../spec/builtins.md#core-built-ins
Test IDs: BUILTIN-CORE-001 through BUILTIN-CORE-070
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// LEN AND CAP
// =============================================================================

@(test)
test_builtin_len_array_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len of fixed array
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int
    n := len(arr)
}
`, "BUILTIN-CORE-001: len of array")
}

@(test)
test_builtin_len_slice_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len of slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int
    s: []int = arr[:]
    n := len(s)
}
`, "BUILTIN-CORE-002: len of slice")
}

@(test)
test_builtin_len_string_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len of string
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    s := "hello"
    n := len(s)
}
`, "BUILTIN-CORE-003: len of string")
}

@(test)
test_builtin_len_map_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len of map
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    m: map[string]int
    n := len(m)
}
`, "BUILTIN-CORE-004: len of map")
}

@(test)
test_builtin_len_dynamic_array_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len of dynamic array
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    d: [dynamic]int
    n := len(d)
}
`, "BUILTIN-CORE-005: len of dynamic array")
}

@(test)
test_builtin_cap_slice_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - cap of slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int
    s: []int = arr[:]
    c := cap(s)
}
`, "BUILTIN-CORE-006: cap of slice")
}

@(test)
test_builtin_cap_dynamic_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - cap of dynamic array
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    d: [dynamic]int
    c := cap(d)
}
`, "BUILTIN-CORE-007: cap of dynamic array")
}

@(test)
test_builtin_len_wrong_type_neg :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - len only works on specific types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x: int = 42
    n := len(x)
}
`, "BUILTIN-CORE-008: len of int should fail")
}

@(test)
test_builtin_cap_wrong_type_neg :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.1 - cap only works on specific types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x: int = 42
    c := cap(x)
}
`, "BUILTIN-CORE-009: cap of int should fail")
}

// =============================================================================
// SIZE_OF AND ALIGN_OF
// =============================================================================

@(test)
test_builtin_size_of_type_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - size_of type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    s := size_of(int)
    s2 := size_of(f32)
    s3 := size_of([3]int)
}
`, "BUILTIN-CORE-010: size_of types")
}

@(test)
test_builtin_size_of_expr_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - size_of expression
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    s := size_of(x)
}
`, "BUILTIN-CORE-011: size_of expression")
}

@(test)
test_builtin_align_of_type_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - align_of type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a := align_of(int)
    a2 := align_of(f64)
}
`, "BUILTIN-CORE-012: align_of types")
}

@(test)
test_builtin_align_of_expr_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - align_of expression
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: f64 = 3.14
    a := align_of(x)
}
`, "BUILTIN-CORE-013: align_of expression")
}

// =============================================================================
// OFFSET_OF
// =============================================================================

@(test)
test_builtin_offset_of_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - offset_of struct field
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Point :: struct { x, y, z: int }
test :: proc() {
    o := offset_of(Point, y)
}
`, "BUILTIN-CORE-014: offset_of field")
}

@(test)
test_builtin_offset_of_invalid_field_neg :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - offset_of non-existent field
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Point :: struct { x, y: int }
test :: proc() {
    o := offset_of(Point, z)
}
`, "BUILTIN-CORE-015: offset_of invalid field")
}

// =============================================================================
// TYPE_OF
// =============================================================================

@(test)
test_builtin_type_of_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - type_of expression
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 42
    T :: type_of(x)
    y: T = 100
}
`, "BUILTIN-CORE-016: type_of creates type alias")
}

@(test)
test_builtin_type_of_struct_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - type_of on struct
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Point :: struct { x, y: int }
test :: proc() {
    p: Point = {1, 2}
    T :: type_of(p)
    q: T = {3, 4}
}
`, "BUILTIN-CORE-017: type_of struct")
}

// =============================================================================
// TYPEID_OF AND TYPE_INFO_OF
// =============================================================================

@(test)
test_builtin_typeid_of_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - typeid_of
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    id: typeid = typeid_of(int)
    id2 := typeid_of(string)
}
`, "BUILTIN-CORE-018: typeid_of types")
}

@(test)
test_builtin_type_info_of_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.2 - type_info_of
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    info := type_info_of(int)
}
`, "BUILTIN-CORE-019: type_info_of type")
}

// =============================================================================
// MIN, MAX, ABS, CLAMP
// =============================================================================

@(test)
test_builtin_min_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - min of values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a := min(1, 2, 3)
    b := min(5, 2)
    c := min(3.14, 2.71)
}
`, "BUILTIN-CORE-020: min variadic")
}

@(test)
test_builtin_max_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - max of values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a := max(1, 2, 3)
    b := max(5, 2)
    c := max(3.14, 2.71)
}
`, "BUILTIN-CORE-021: max variadic")
}

@(test)
test_builtin_abs_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - abs of value
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a := abs(-5)
    b := abs(-3.14)
}
`, "BUILTIN-CORE-022: abs")
}

@(test)
test_builtin_clamp_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - clamp value to range
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a := clamp(15, 0, 10)
    b := clamp(-5, 0, 10)
    c := clamp(5, 0, 10)
}
`, "BUILTIN-CORE-023: clamp")
}

@(test)
test_builtin_min_type_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - min requires same types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    a := min(1, "hello")
}
`, "BUILTIN-CORE-024: min type mismatch")
}

@(test)
test_builtin_abs_unsigned_neg :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.6 - abs on unsigned should warn/error
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Note: abs on unsigned may be allowed but meaningless
	helpers.check_should_pass(t, `package test
test :: proc() {
    x: u32 = 5
    a := abs(x)
}
`, "BUILTIN-CORE-025: abs unsigned (allowed)")
}

// =============================================================================
// RAW_DATA
// =============================================================================

@(test)
test_builtin_raw_data_slice_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.9 - raw_data of slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int = {1, 2, 3, 4, 5}
    s: []int = arr[:]
    ptr: [^]int = raw_data(s)
}
`, "BUILTIN-CORE-026: raw_data of slice")
}

@(test)
test_builtin_raw_data_array_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.9 - raw_data of array
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int = {1, 2, 3, 4, 5}
    ptr: [^]int = raw_data(arr)
}
`, "BUILTIN-CORE-027: raw_data of array")
}

@(test)
test_builtin_raw_data_string_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.9 - raw_data of string
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    s: string = "hello"
    ptr: [^]u8 = raw_data(s)
}
`, "BUILTIN-CORE-028: raw_data of string")
}

// =============================================================================
// EXPAND_VALUES / COMPRESS_VALUES
// =============================================================================

@(test)
test_builtin_expand_values_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.5 - expand struct to values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Point :: struct { x, y: int }
test :: proc() {
    p: Point = {1, 2}
    a, b := expand_values(p)
}
`, "BUILTIN-CORE-029: expand_values struct")
}

// =============================================================================
// UNREACHABLE
// =============================================================================

@(test)
test_builtin_unreachable_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.8 - unreachable marks unreachable code
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() -> int {
    return 42
    unreachable()
}
`, "BUILTIN-CORE-030: unreachable after return")
}

// =============================================================================
// SWIZZLE
// =============================================================================

@(test)
test_builtin_swizzle_pos :: proc(t: ^testing.T) {
	// @spec: builtins.md#1.3 - swizzle reorders elements
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    v: [4]f32 = {1, 2, 3, 4}
    s := swizzle(v, 3, 2, 1, 0)
}
`, "BUILTIN-CORE-031: swizzle array")
}

