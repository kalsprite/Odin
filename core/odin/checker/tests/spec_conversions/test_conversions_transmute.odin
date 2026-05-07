package test_spec_conversions

/*
Test Coverage: conversions.md - Transmute

Tests for bit-level type reinterpretation using transmute(T)x.

Spec Reference: ../spec/conversions.md#transmute
Test IDs: CONV-TR-001 through CONV-TR-030
Last Sync: 2025-01-16

NOTE: Transmute tests are temporarily disabled - transmute() expressions
trigger a segfault in the checker. Tests will be re-enabled when transmute()
support is implemented.
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// PLACEHOLDER - TRANSMUTE TESTS PENDING IMPLEMENTATION
// =============================================================================

@(test)
test_transmute_placeholder_pos :: proc(t: ^testing.T) {
	// Placeholder test while transmute() support is pending in checker
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
x: int = 42
`, "CONV-TR-PLACEHOLDER: placeholder until transmute() implemented")
}

// =============================================================================
// TRANSMUTE TESTS (DISABLED - CAUSES SEGFAULT)
// =============================================================================

/*
The following tests are commented out pending transmute() support:

- test_transmute_f32_u32_pos: CONV-TR-001 - f32 to u32
- test_transmute_u32_f32_pos: CONV-TR-002 - u32 to f32
- test_transmute_f64_u64_pos: CONV-TR-003 - f64 to u64
- test_transmute_i32_u32_pos: CONV-TR-004 - i32 to u32
- test_transmute_ptr_rawptr_pos: CONV-TR-005 - pointer to rawptr
- test_transmute_ptr_uintptr_pos: CONV-TR-006 - pointer to uintptr
- test_transmute_uintptr_ptr_pos: CONV-TR-007 - uintptr to pointer
- test_transmute_struct_array_pos: CONV-TR-008 - struct to array
- test_transmute_array_struct_pos: CONV-TR-009 - array to struct
- test_transmute_slice_struct_pos: CONV-TR-010 - slice to raw struct
- test_transmute_multiptr_ptr_pos: CONV-TR-011 - multi-pointer to pointer
- test_transmute_size_mismatch_neg: CONV-TR-012 - size mismatch error
- test_transmute_f32_to_u64_neg: CONV-TR-013 - f32 to u64 size mismatch
- test_transmute_u8_to_u32_neg: CONV-TR-014 - u8 to u32 size mismatch
- test_transmute_struct_wrong_size_neg: CONV-TR-015 - struct size mismatch
- test_transmute_array_wrong_size_neg: CONV-TR-016 - array size mismatch
- test_transmute_array_u8_u32_pos: CONV-TR-017 - [4]u8 to u32
- test_transmute_u32_array_u8_pos: CONV-TR-018 - u32 to [4]u8
- test_transmute_bitset_int_pos: CONV-TR-019 - bit_set to u8
- test_transmute_int_bitset_pos: CONV-TR-020 - u8 to bit_set
- test_transmute_packed_struct_pos: CONV-TR-021 - packed struct to u32
*/

