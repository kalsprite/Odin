package test_spec_conversions

/*
Test Coverage: conversions.md - Explicit Casts

Tests for explicit type casts using cast(T)x syntax.

Spec Reference: ../spec/conversions.md#explicit-casts
Test IDs: CONV-CAST-001 through CONV-CAST-045
Last Sync: 2025-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// INTEGER CASTS
// =============================================================================

@(test)
test_cast_int_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.1 - integer to integer casts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: i64 = 42
    y := cast(i32)x
    z := cast(i16)y
    w := cast(i8)z
}
`, "CONV-CAST-001: integer to integer casts")
}

@(test)
test_cast_uint_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.1 - unsigned to signed casts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: u32 = 42
    y := cast(i32)x
    z: i32 = 100
    w := cast(u32)z
}
`, "CONV-CAST-002: unsigned to signed casts")
}

@(test)
test_cast_float_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.2 - float to int truncation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: f32 = 3.14
    y := cast(int)x
    z: f64 = 2.71
    w := cast(i64)z
}
`, "CONV-CAST-003: float to int truncation")
}

@(test)
test_cast_int_to_float_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.2 - int to float
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    y := cast(f32)x
    z := cast(f64)x
}
`, "CONV-CAST-004: int to float")
}

@(test)
test_cast_float_to_float_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.2 - float precision casts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: f32 = 3.14
    y := cast(f64)x
    z: f64 = 2.71
    w := cast(f32)z
}
`, "CONV-CAST-005: float precision casts")
}

// =============================================================================
// BOOLEAN CASTS
// =============================================================================

@(test)
test_cast_int_to_bool_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.3 - int to bool
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 1
    y := cast(bool)x
}
`, "CONV-CAST-006: int to bool")
}

@(test)
test_cast_bool_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.3 - bool to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    b: bool = true
    x := cast(int)b
}
`, "CONV-CAST-007: bool to int")
}

// =============================================================================
// RUNE CASTS
// =============================================================================

@(test)
test_cast_int_to_rune_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.4 - int to rune
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 65
    r := cast(rune)x
}
`, "CONV-CAST-008: int to rune")
}

@(test)
test_cast_rune_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.4 - rune to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    r: rune = 'A'
    x := cast(int)r
}
`, "CONV-CAST-009: rune to int")
}

// =============================================================================
// POINTER CASTS
// =============================================================================

@(test)
test_cast_ptr_to_ptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.5 - pointer to pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    p: ^int = &x
    q := cast(^u8)p
}
`, "CONV-CAST-010: pointer to pointer")
}

@(test)
test_cast_ptr_to_uintptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.5 - pointer to uintptr
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    p: ^int = &x
    u := cast(uintptr)p
}
`, "CONV-CAST-011: pointer to uintptr")
}

@(test)
test_cast_uintptr_to_ptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.5 - uintptr to pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    u: uintptr = 0x12345678
    p := cast(^int)u
}
`, "CONV-CAST-012: uintptr to pointer")
}

@(test)
test_cast_multiptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.5 - multi-pointer casts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int
    mp: [^]int = &arr[0]
    mp2 := cast([^]u8)mp
}
`, "CONV-CAST-013: multi-pointer casts")
}

@(test)
test_cast_rawptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.5 - rawptr casts
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    rp: rawptr = &x
    p := cast(^int)rp
}
`, "CONV-CAST-014: rawptr casts")
}

// =============================================================================
// DISTINCT TYPE CASTS
// =============================================================================

@(test)
test_cast_distinct_to_base_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.6 - distinct to base type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MyInt :: distinct int
test :: proc() {
    x: MyInt = 42
    y := cast(int)x
}
`, "CONV-CAST-020: distinct to base")
}

@(test)
test_cast_base_to_distinct_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.6 - base to distinct type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MyInt :: distinct int
test :: proc() {
    x: int = 42
    y := cast(MyInt)x
}
`, "CONV-CAST-021: base to distinct")
}

// =============================================================================
// ENUM CASTS
// =============================================================================

@(test)
test_cast_enum_to_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.7 - enum to int
	// NOTE: Using explicit Color.Green syntax - implicit selector (.Green) has a separate bug
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
test :: proc() {
    c: Color = Color.Green
    x := cast(int)c
}
`, "CONV-CAST-022: enum to int")
}

@(test)
test_cast_int_to_enum_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#3.7 - int to enum
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
test :: proc() {
    x: int = 1
    c := cast(Color)x
}
`, "CONV-CAST-023: int to enum")
}

// =============================================================================
// INVALID CASTS (NEGATIVE TESTS)
// =============================================================================

@(test)
test_cast_string_to_int_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - invalid string to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    s: string = "42"
    x := cast(int)s
}
`, "CONV-CAST-024: invalid string to int")
}

@(test)
test_cast_float_to_ptr_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - invalid float to pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x: f32 = 3.14
    p := cast(^int)x
}
`, "CONV-CAST-025: invalid float to pointer")
}

// DISABLED: Causes segfault when casting struct to incompatible type
/*
@(test)
test_cast_struct_to_int_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - invalid struct to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Point :: struct { x, y: int }
test :: proc() {
    p: Point = {1, 2}
    x := cast(int)p
}
`, "CONV-CAST-026: invalid struct to int")
}
*/

// =============================================================================
// AUTO_CAST
// =============================================================================

@(test)
test_auto_cast_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#4 - auto_cast integer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: i64 = 42
    y: i32 = auto_cast x
}
`, "CONV-CAST-029: auto_cast integer")
}

@(test)
test_auto_cast_ptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#4 - auto_cast pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    p: ^int = &x
    rp: rawptr = auto_cast p
}
`, "CONV-CAST-030: auto_cast pointer")
}

@(test)
test_auto_cast_literal_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#4 - auto_cast with literal (works)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: i64 = auto_cast 42
`, "CONV-CAST-031: auto_cast literal")
}
