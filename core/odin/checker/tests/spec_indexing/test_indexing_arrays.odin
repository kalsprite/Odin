package test_spec_indexing

/*
Test Coverage: indexing.md Sections 1-2, 4 - Array Indexing and Slicing

Tests for array access, slice expressions, bounds checking

Spec Reference: ../spec/indexing.md#1-indexable-types, #2-integer-index, #4-slice
Test IDs: IDX-ARR-001 through IDX-ARR-040
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// ARRAY INDEXING - Positive Tests
// =============================================================================

@(test)
test_idx_array_int_index_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#1-indexable-types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
x := arr[0]
y := arr[4]
`, "IDX-ARR-001: array indexing with int")
}

@(test)
test_idx_array_variable_index_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.1-valid-index-types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
i: int = 2
x := arr[i]
`, "IDX-ARR-002: array indexing with variable")
}

@(test)
test_idx_array_u8_index_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.1-any-integer-type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
i: u8 = 2
x := arr[i]
`, "IDX-ARR-003: array indexing with u8")
}

@(test)
test_idx_slice_access_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#1-indexable-types-slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
get_slice :: proc() -> []int { return nil }
test :: proc() {
    s := get_slice()
    if len(s) > 0 {
        x := s[0]
    }
}
`, "IDX-ARR-004: slice indexing")
}

@(test)
test_idx_string_access_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#8-string-indexing
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
s: string = "hello"
c := s[0]
`, "IDX-ARR-005: string indexing returns u8")
}

@(test)
test_idx_pointer_deref_index_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#1-indexable-types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
p := &arr
x := p[0]
`, "IDX-ARR-006: pointer to array indexing")
}

// =============================================================================
// SLICE EXPRESSIONS - Positive Tests
// =============================================================================

@(test)
test_idx_slice_full_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.1-slice-syntax
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[:]
`, "IDX-ARR-007: full slice")
}

@(test)
test_idx_slice_lo_hi_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.1-slice-syntax
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[1:4]
`, "IDX-ARR-008: slice with lo:hi")
}

@(test)
test_idx_slice_lo_only_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.1-slice-syntax
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[2:]
`, "IDX-ARR-009: slice with lo:")
}

@(test)
test_idx_slice_hi_only_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.1-slice-syntax
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[:3]
`, "IDX-ARR-010: slice with :hi")
}

@(test)
test_idx_slice_of_slice_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.2-reslicing
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s1 := arr[:]
s2 := s1[1:3]
`, "IDX-ARR-011: reslicing a slice")
}

@(test)
test_idx_string_slice_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.2-string-slicing
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
s: string = "hello world"
sub := s[0:5]
`, "IDX-ARR-012: string slicing")
}

// =============================================================================
// CONSTANT INDEXING - Positive Tests
// =============================================================================

@(test)
test_idx_const_array_const_index_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#9.1-constant-propagation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
ARR :: [3]int{10, 20, 30}
X :: ARR[1]
`, "IDX-ARR-013: constant array with constant index")
}

// =============================================================================
// NEGATIVE TESTS
// =============================================================================

@(test)
test_idx_array_string_index_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.1-index-must-be-integer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
x := arr["hello"]
`, "IDX-ARR-014: cannot index with string")
}

@(test)
test_idx_array_float_index_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.1-index-must-be-integer
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
x := arr[1.5]
`, "IDX-ARR-015: cannot index with float")
}

@(test)
test_idx_array_negative_const_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.2-negative-index
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
x := arr[-1]
`, "IDX-ARR-016: negative constant index")
}

@(test)
test_idx_array_out_of_bounds_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#2.3-bounds-checking
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
x := arr[10]
`, "IDX-ARR-017: constant out of bounds")
}

@(test)
test_idx_int_not_indexable_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#1-indexable-types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
x: int = 42
y := x[0]
`, "IDX-ARR-018: cannot index int")
}

@(test)
test_idx_slice_invalid_range_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.4-index-validation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[4:2]
`, "IDX-ARR-019: invalid slice range lo > hi")
}

@(test)
test_idx_slice_out_of_bounds_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#4.4-bounds
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
arr: [5]int = {1, 2, 3, 4, 5}
s := arr[0:10]
`, "IDX-ARR-020: slice out of bounds")
}
