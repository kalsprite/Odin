package test_spec_types

/*
Test Coverage: types.md Section 1 - Basic Types

Tests for boolean, integer, float, complex, quaternion, rune, string, pointer types.

Spec Reference: ../spec/types.md#1-basic-types
Test IDs: TYPES-BASIC-001 through TYPES-BASIC-040
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// BOOLEAN TYPES - Positive Tests
// =============================================================================

@(test)
test_types_bool_declaration_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-bool
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
b: bool = true
`,
		"TYPES-BASIC-001: bool declaration",
	)
}

@(test)
test_types_bool_sizes_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-sized-booleans
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
my_b8:  b8  = true
my_b16: b16 = true
my_b32: b32 = true
my_b64: b64 = true
`,
		"TYPES-BASIC-002: sized bool declarations",
	)
}

// =============================================================================
// INTEGER TYPES - Positive Tests
// =============================================================================

@(test)
test_types_signed_integers_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-signed-integers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
my_i8:   i8   = -128
my_i16:  i16  = -32768
my_i32:  i32  = -2147483648
my_i64:  i64  = -9223372036854775807
my_i128: i128 = 0
`,
		"TYPES-BASIC-003: signed integer declarations",
	)
}

@(test)
test_types_unsigned_integers_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-unsigned-integers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
my_u8:   u8   = 255
my_u16:  u16  = 65535
my_u32:  u32  = 4294967295
my_u64:  u64  = 9223372036854775807
my_u128: u128 = 0
`,
		"TYPES-BASIC-004: unsigned integer declarations",
	)
}

@(test)
test_types_platform_integers_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-platform-sized
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
int_val:     int     = 42
uint_val:    uint    = 42
uintptr_val: uintptr = 0
`,
		"TYPES-BASIC-005: platform-sized integer declarations",
	)
}

// =============================================================================
// FLOATING POINT TYPES - Positive Tests
// =============================================================================

@(test)
test_types_floats_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-floats
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
f16_val: f16 = 3.14
f32_val: f32 = 3.14159
f64_val: f64 = 3.141592653589793
`,
		"TYPES-BASIC-006: float declarations",
	)
}

// =============================================================================
// COMPLEX TYPES - Positive Tests
// =============================================================================

@(test)
test_types_complex_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-complex
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
my_c32:  complex32  = 1 + 2i
my_c64:  complex64  = 1 + 2i
my_c128: complex128 = 1 + 2i
`,
		"TYPES-BASIC-007: complex number declarations",
	)
}

// =============================================================================
// QUATERNION TYPES - Positive Tests
// =============================================================================

@(test)
test_types_quaternion_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-quaternion
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
my_q64:  quaternion64  = 1 + 2i + 3j + 4k
my_q128: quaternion128 = 1 + 2i + 3j + 4k
my_q256: quaternion256 = 1 + 2i + 3j + 4k
`,
		"TYPES-BASIC-008: quaternion declarations",
	)
}

// =============================================================================
// RUNE TYPE - Positive Tests
// =============================================================================

@(test)
test_types_rune_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-rune
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
r: rune = 'a'
r2: rune = '\n'
r3: rune = '\u0041'
`,
		"TYPES-BASIC-009: rune declarations",
	)
}

// =============================================================================
// STRING TYPES - Positive Tests
// =============================================================================

@(test)
test_types_string_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-string
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
s: string = "hello world"
s2: string = ""
`,
		"TYPES-BASIC-010: string declarations",
	)
}

@(test)
test_types_cstring_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-cstring
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
cs: cstring = "hello"
cs_nil: cstring = nil
`,
		"TYPES-BASIC-011: cstring declarations",
	)
}

// =============================================================================
// POINTER TYPES - Positive Tests
// =============================================================================

@(test)
test_types_rawptr_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-rawptr
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
p: rawptr = nil
`,
		"TYPES-BASIC-012: rawptr declarations",
	)
}

@(test)
test_types_typed_pointer_pos :: proc(t: ^testing.T) {
	// @spec: types.md#2.8-pointer-types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
p: ^int = nil
`,
		"TYPES-BASIC-013: typed pointer declarations",
	)
}

@(test)
test_types_multi_pointer_pos :: proc(t: ^testing.T) {
	// @spec: types.md#2.8-multi-pointer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
mp: [^]int = nil
`,
		"TYPES-BASIC-014: multi-pointer declarations",
	)
}

// =============================================================================
// ANY AND TYPEID - Positive Tests
// =============================================================================

@(test)
test_types_any_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-any
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
a: any = 42
a2: any = "hello"
a3: any = true
`,
		"TYPES-BASIC-015: any type declarations",
	)
}

@(test)
test_types_typeid_pos :: proc(t: ^testing.T) {
	// @spec: types.md#1.1-typeid
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(
		t,
		`package test
tid: typeid = int
tid2: typeid = string
`,
		"TYPES-BASIC-016: typeid declarations",
	)
}

// =============================================================================
// NEGATIVE TESTS - Type Mismatches
// =============================================================================

@(test)
test_types_bool_int_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: types.md#1.2-BasicFlag_Boolean
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(
		t,
		`package test
b: bool = 42
`,
		"TYPES-BASIC-017: cannot assign int to bool",
	)
}

@(test)
test_types_int_string_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: types.md - type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(
		t,
		`package test
x: int = "hello"
`,
		"TYPES-BASIC-018: cannot assign string to int",
	)
}

@(test)
test_types_float_bool_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: types.md - type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(
		t,
		`package test
f: f32 = true
`,
		"TYPES-BASIC-019: cannot assign bool to f32",
	)
}

@(test)
test_types_pointer_int_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: types.md - pointer type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(
		t,
		`package test
p: ^int = 42
`,
		"TYPES-BASIC-020: cannot assign int to pointer",
	)
}

@(test)
test_types_string_int_mismatch_neg :: proc(t: ^testing.T) {
	// @spec: types.md - type mismatch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(
		t,
		`package test
s: string = 42
`,
		"TYPES-BASIC-021: cannot assign int to string",
	)
}
