package test_spec_conversions

/*
Test Coverage: conversions.md - Implicit Conversions

Tests for assignment-compatible type conversions that happen automatically.

Spec Reference: ../spec/conversions.md#implicit-conversions
Test IDs: CONV-IMP-001 through CONV-IMP-045
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// UNTYPED CONSTANT CONVERSIONS
// =============================================================================

@(test)
test_conv_untyped_bool_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_bool converts to any boolean
	// NOTE: Sized booleans (b8, b16, b32, b64) not yet implemented in checker
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: bool = true
y: bool = false
`, "CONV-IMP-001: untyped bool to bool types")
}

@(test)
test_conv_untyped_int_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_int converts to any integer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: i8 = 42
b: i16 = 42
c: i32 = 42
d: i64 = 42
e: int = 42
f: u8 = 42
g: u16 = 42
h: u32 = 42
i: u64 = 42
j: uint = 42
`, "CONV-IMP-002: untyped int to integer types")
}

@(test)
test_conv_untyped_int_to_rune_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_int converts to rune
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
r: rune = 65
`, "CONV-IMP-003: untyped int to rune")
}

@(test)
test_conv_untyped_rune_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_rune converts to integer/rune
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
r: rune = 'A'
i: int = 'B'
u: u8 = 'C'
`, "CONV-IMP-004: untyped rune to integer/rune types")
}

@(test)
test_conv_untyped_float_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_float converts to any float
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: f16 = 3.14
b: f32 = 3.14
c: f64 = 3.14
`, "CONV-IMP-005: untyped float to float types")
}

@(test)
test_conv_untyped_string_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_string converts to string types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
s: string = "hello"
`, "CONV-IMP-006: untyped string to string")
}

@(test)
test_conv_untyped_nil_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.2 - untyped_nil converts to nil-compatible types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
p: ^int = nil
mp: [^]int = nil
rp: rawptr = nil
sl: []int = nil
dyn: [dynamic]int = nil
m: map[string]int = nil
pr: proc() = nil
`, "CONV-IMP-007: untyped nil to nil-compatible types")
}

// =============================================================================
// POINTER CONVERSIONS
// =============================================================================

@(test)
test_conv_ptr_to_rawptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.3 - ^T implicitly converts to rawptr
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
p: ^int = &x
rp: rawptr = p
`, "CONV-IMP-008: pointer to rawptr")
}

@(test)
test_conv_multiptr_to_rawptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.3 - [^]T implicitly converts to rawptr
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int
mp: [^]int = &arr[0]
rp: rawptr = mp
`, "CONV-IMP-009: multi-pointer to rawptr")
}

@(test)
test_conv_ptr_to_multiptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.3 - ^T to [^]T (same T)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
p: ^int = &x
mp: [^]int = p
`, "CONV-IMP-010: pointer to multi-pointer")
}

@(test)
test_conv_multiptr_to_ptr_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.3 - [^]T to ^T (same T)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int
mp: [^]int = &arr[0]
p: ^int = mp
`, "CONV-IMP-011: multi-pointer to pointer")
}

// =============================================================================
// UNION VARIANT ASSIGNMENT
// =============================================================================

@(test)
test_conv_union_variant_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.4 - value implicitly assigns to union variant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Value :: union { int, f32, string }
test :: proc() {
    v: Value
    v = 42
    v = 3.14
    v = "hello"
}
`, "CONV-IMP-012: union variant assignment")
}

@(test)
test_conv_union_wrong_type_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.4 - wrong type for union should error
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Value :: union { int, f32 }
test :: proc() {
    v: Value = "hello"
}
`, "CONV-IMP-013: union wrong variant type")
}

// =============================================================================
// ARRAY BROADCAST
// =============================================================================

@(test)
test_conv_scalar_to_array_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.7 - scalar broadcasts to array
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
a: [4]int = 5
b: [3]f32 = 1.5
`, "CONV-IMP-014: scalar broadcast to array")
}

// =============================================================================
// ANY TYPE CONVERSION
// =============================================================================

@(test)
test_conv_to_any_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.9 - any value can be assigned to any
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    a: any
    a = 42
    a = "hello"
    a = 3.14
    a = true
}
`, "CONV-IMP-015: various types to any")
}

// =============================================================================
// NEGATIVE TESTS - INCOMPATIBLE IMPLICIT CONVERSIONS
// =============================================================================

@(test)
test_conv_int_to_ptr_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - int doesn't implicitly convert to pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
p: ^int = 42
`, "CONV-IMP-016: int to pointer should fail")
}

@(test)
test_conv_float_to_int_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - float doesn't implicitly convert to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = 3.14
`, "CONV-IMP-017: float to int should require cast")
}

@(test)
test_conv_string_to_int_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - string doesn't convert to int
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = "42"
`, "CONV-IMP-018: string to int should fail")
}

@(test)
test_conv_ptr_types_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - ^T doesn't implicitly convert to ^U
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = 42
p: ^int = &x
q: ^string = p
`, "CONV-IMP-019: pointer type mismatch should fail")
}

@(test)
test_conv_nil_to_non_nil_type_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md#8 - nil not compatible with basic types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = nil
`, "CONV-IMP-020: nil to int should fail")
}

@(test)
test_conv_nil_to_array_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md#8 - arrays don't accept nil
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
a: [3]int = nil
`, "CONV-IMP-021: nil to array should fail")
}

@(test)
test_conv_nil_to_struct_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md#8 - structs don't accept nil
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Point :: struct { x, y: int }
p: Point = nil
`, "CONV-IMP-022: nil to struct should fail")
}

@(test)
test_conv_nil_to_enum_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#8 - enums DO accept nil (verified with odin check)
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
c: Color = nil
`, "CONV-IMP-023: nil to enum is valid")
}

// =============================================================================
// IDENTICAL TYPE TESTS
// =============================================================================

@(test)
test_conv_identical_types_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.1 - identical types are assignment compatible
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x: int = 42
    y: int = x

    a: [3]int = {1, 2, 3}
    b: [3]int = a

    s1: string = "hello"
    s2: string = s1
}
`, "CONV-IMP-024: identical type assignment")
}

// =============================================================================
// DISTINCT TYPE TESTS
// =============================================================================

@(test)
test_conv_distinct_type_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - distinct types are not assignment compatible
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
MyInt :: distinct int
test :: proc() {
    x: int = 42
    y: MyInt = x
}
`, "CONV-IMP-025: distinct type not implicitly convertible")
}

@(test)
test_conv_distinct_to_base_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - distinct to base type requires cast
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
MyInt :: distinct int
test :: proc() {
    y: MyInt = 42
    x: int = y
}
`, "CONV-IMP-026: distinct to base requires cast")
}

// =============================================================================
// TYPE ALIAS TESTS
// =============================================================================

@(test)
test_conv_type_alias_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md#2.1 - type aliases are identical
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MyInt :: int
test :: proc() {
    x: int = 42
    y: MyInt = x
    z: int = y
}
`, "CONV-IMP-027: type alias is identical to base")
}

// =============================================================================
// PROCEDURE TYPE TESTS
// =============================================================================

@(test)
test_conv_proc_compatible_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md - identical procedure types are compatible
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc(x: int) -> int { return x }
test :: proc() {
    f: proc(int) -> int = foo
}
`, "CONV-IMP-028: procedure type assignment")
}

@(test)
test_conv_proc_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: conversions.md - different procedure signatures not compatible
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc(x: int) -> int { return x }
test :: proc() {
    f: proc(string) -> int = foo
}
`, "CONV-IMP-029: procedure type mismatch")
}

// =============================================================================
// SLICE IMPLICIT CONVERSION TESTS
// =============================================================================

@(test)
test_conv_array_to_slice_pos :: proc(t: ^testing.T) {
	// @spec: conversions.md - array can be sliced to get slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr: [5]int = {1, 2, 3, 4, 5}
    s: []int = arr[:]
}
`, "CONV-IMP-030: array slice to slice type")
}

