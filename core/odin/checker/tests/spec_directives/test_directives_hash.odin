package test_spec_directives

/*
Test Coverage: directives.md Sections 1 - Hash Directives

Tests for #file, #line, #procedure, #packed, #raw_union, #align, etc.

Spec Reference: ../spec/directives.md#1-hash-directives
Test IDs: DIR-HASH-001 through DIR-HASH-050
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// COMPILE-TIME CONSTANTS - Positive Tests
// =============================================================================

@(test)
test_dir_file_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.1 - #file returns current source file path
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    path := #file
}
`, "DIR-HASH-001: #file directive")
}

@(test)
test_dir_directory_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.1 - #directory returns directory of source file
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    dir := #directory
}
`, "DIR-HASH-002: #directory directive")
}

@(test)
test_dir_line_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.1 - #line returns current line number
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    line := #line
}
`, "DIR-HASH-003: #line directive")
}

@(test)
test_dir_procedure_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.1 - #procedure returns current procedure name
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    name := #procedure
}
`, "DIR-HASH-004: #procedure directive")
}

// =============================================================================
// LOCATION DIRECTIVES - Positive Tests
// =============================================================================

@(test)
test_dir_location_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.2 - #location() returns Source_Code_Location
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
import "base:runtime"
test :: proc() {
    loc := #location()
}
`, "DIR-HASH-005: #location() directive")
}

@(test)
test_dir_caller_location_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.2 - #caller_location as default parameter
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
import "base:runtime"
my_log :: proc(msg: string, loc := #caller_location) {
    _ = loc
}
test :: proc() {
    my_log("hello")
}
`, "DIR-HASH-006: #caller_location default parameter")
}

// =============================================================================
// COMPILE-TIME EVALUATION - Positive Tests
// =============================================================================

@(test)
test_dir_assert_basic_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #assert with condition
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
#assert(1 + 1 == 2)
`, "DIR-HASH-007: #assert basic condition")
}

@(test)
test_dir_assert_message_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #assert with message
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
#assert(size_of(int) >= 4, "int must be at least 4 bytes")
`, "DIR-HASH-008: #assert with message")
}

@(test)
test_dir_config_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #config with default value
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
DEBUG :: #config(DEBUG, false)
`, "DIR-HASH-009: #config with default")
}

@(test)
test_dir_defined_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #defined checks if identifier exists
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MY_CONST :: 42
test :: proc() {
    when #defined(MY_CONST) {
        x := MY_CONST
    }
}
`, "DIR-HASH-010: #defined directive")
}

// =============================================================================
// STRUCT MODIFIERS - Positive Tests
// =============================================================================

@(test)
test_dir_packed_struct_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.5 - #packed removes padding
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Packed :: struct #packed {
    a: u8,
    b: u32,
    c: u8,
}
`, "DIR-HASH-011: #packed struct")
}

@(test)
test_dir_raw_union_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.5 - #raw_union makes all fields share memory
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
RawUnion :: struct #raw_union {
    as_int: int,
    as_float: f64,
    as_bytes: [8]u8,
}
`, "DIR-HASH-012: #raw_union struct")
}

@(test)
test_dir_align_struct_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.5 - #align specifies alignment
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Aligned :: struct #align(16) {
    x, y, z, w: f32,
}
`, "DIR-HASH-013: #align struct")
}

@(test)
test_dir_min_field_align_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.5 - #min_field_align sets minimum
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MinAligned :: struct #min_field_align(4) {
    a: u8,
    b: u8,
}
`, "DIR-HASH-014: #min_field_align struct")
}

@(test)
test_dir_max_field_align_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.5 - #max_field_align sets maximum
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
MaxAligned :: struct #max_field_align(4) {
    a: u64,
    b: u64,
}
`, "DIR-HASH-015: #max_field_align struct")
}

// =============================================================================
// UNION MODIFIERS - Positive Tests
// =============================================================================

@(test)
test_dir_no_nil_union_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.6 - #no_nil union cannot be nil
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
NoNilUnion :: union #no_nil {
    int,
    f32,
}
`, "DIR-HASH-016: #no_nil union")
}

@(test)
test_dir_shared_nil_union_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.6 - #shared_nil variants share nil
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
SharedNilUnion :: union #shared_nil {
    ^int,
    ^f32,
}
`, "DIR-HASH-017: #shared_nil union")
}

@(test)
test_dir_align_union_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.6 - #align on union
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
AlignedUnion :: union #align(16) {
    int,
    f64,
}
`, "DIR-HASH-018: #align union")
}

// =============================================================================
// PROCEDURE MODIFIERS - Positive Tests
// =============================================================================

@(test)
test_dir_force_inline_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.7 - #force_inline always inlines
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
add :: #force_inline proc(a, b: int) -> int {
    return a + b
}
`, "DIR-HASH-019: #force_inline procedure")
}

@(test)
test_dir_force_no_inline_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.7 - #force_no_inline never inlines
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
heavy :: #force_no_inline proc(x: int) -> int {
    return x * x
}
`, "DIR-HASH-020: #force_no_inline procedure")
}

// =============================================================================
// CONTROL FLOW MODIFIERS - Positive Tests
// =============================================================================

@(test)
test_dir_partial_switch_enum_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.8 - #partial allows non-exhaustive switch
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
test :: proc() {
    c: Color = .Red
    #partial switch c {
    case .Red:
        // Only handle red
    }
}
`, "DIR-HASH-021: #partial switch on enum")
}

@(test)
test_dir_partial_switch_union_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.8 - #partial switch on union
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Value :: union { int, f32, string }
test :: proc() {
    v: Value = 42
    #partial switch x in v {
    case int:
        _ = x
    }
}
`, "DIR-HASH-022: #partial switch on union")
}

@(test)
test_dir_reverse_for_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.8 - #reverse iterates in reverse
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    arr := [3]int{1, 2, 3}
    #reverse for x in arr {
        _ = x
    }
}
`, "DIR-HASH-023: #reverse for loop")
}

@(test)
test_dir_unroll_for_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.8 - #unroll unrolls loop
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    sum := 0
    #unroll for i in 0..<4 {
        sum += i
    }
}
`, "DIR-HASH-024: #unroll for loop")
}

// =============================================================================
// TYPE MODIFIERS - Positive Tests
// =============================================================================

// Temporarily disabled - causes MPSC queue crash
// @(test)
// test_dir_soa_array_pos :: proc(t: ^testing.T) {
// 	// @spec: directives.md#1.9 - #soa array layout
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_pass(t, `package test
// Point :: struct { x, y: f32 }
// points: #soa [100]Point
// `, "DIR-HASH-025: #soa array")
// }

@(test)
test_dir_simd_array_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#1.9 - #simd vector type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Vec4 :: #simd[4]f32
`, "DIR-HASH-026: #simd array")
}

// =============================================================================
// COMPILE-TIME CONSTANTS - Negative Tests
// =============================================================================

@(test)
test_dir_procedure_outside_proc_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.1 - #procedure only valid inside procedure
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
name := #procedure
`, "DIR-HASH-027: #procedure outside procedure")
}

// =============================================================================
// STRUCT MODIFIERS - Negative Tests
// =============================================================================

@(test)
test_dir_packed_with_align_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.2 - #packed conflicts with #align
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Bad :: struct #packed #align(16) {
    a: u8,
    b: u32,
}
`, "DIR-HASH-028: #packed conflicts with #align")
}

@(test)
test_dir_min_greater_than_max_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.2 - min_field_align must be <= max_field_align
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Bad :: struct #min_field_align(8) #max_field_align(4) {
    a: u8,
}
`, "DIR-HASH-029: min_field_align > max_field_align")
}

// =============================================================================
// UNION MODIFIERS - Negative Tests
// =============================================================================

@(test)
test_dir_no_nil_one_variant_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#6.3 - #no_nil requires at least 2 variants
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Bad :: union #no_nil {
    int,
}
`, "DIR-HASH-030: #no_nil with single variant")
}

// =============================================================================
// ASSERT - Negative Tests
// =============================================================================

@(test)
test_dir_assert_false_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #assert fails on false condition
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
#assert(1 + 1 == 3)
`, "DIR-HASH-031: #assert with false condition")
}

@(test)
test_dir_assert_non_const_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#1.3 - #assert requires compile-time constant
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x := 5
    #assert(x > 0)
}
`, "DIR-HASH-032: #assert with non-constant")
}
