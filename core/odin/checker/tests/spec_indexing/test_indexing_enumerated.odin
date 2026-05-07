package test_spec_indexing

/*
Test Coverage: indexing.md Section 3 - Enumerated Arrays

Tests for enum-indexed arrays, #sparse modifier, literal syntax

Spec Reference: ../spec/indexing.md#3-enumerated-arrays
Test IDs: IDX-ENUM-001 through IDX-ENUM-035
Last Sync: 2025-01-16
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// ENUMERATED ARRAY DECLARATION - Positive Tests
// =============================================================================

@(test)
test_idx_enum_array_decl_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.1-declaration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int
`, "IDX-ENUM-001: enumerated array declaration")
}

@(test)
test_idx_enum_array_init_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.1-declaration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int = {
    .Red = 1,
    .Green = 2,
    .Blue = 3,
}
`, "IDX-ENUM-002: enumerated array with initializer")
}

@(test)
test_idx_enum_array_index_enum_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.2-index-type-requirement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int = { .Red = 1, .Green = 2, .Blue = 3 }
x := color_values[.Red]
`, "IDX-ENUM-003: indexing with enum value")
}

@(test)
test_idx_enum_array_index_var_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.2-enum-variable-index
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int = { .Red = 1, .Green = 2, .Blue = 3 }
c: Color = .Green
x := color_values[c]
`, "IDX-ENUM-004: indexing with enum variable")
}

@(test)
test_idx_enum_array_assign_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3-assignment
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int
test :: proc() {
    color_values[.Blue] = 42
}
`, "IDX-ENUM-005: assignment through enum index")
}

// =============================================================================
// #SPARSE ENUMERATED ARRAYS - Positive Tests
// =============================================================================

@(test)
test_idx_sparse_enum_array_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.4-sparse-modifier
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Sparse :: enum {
    A = 0,
    B = 10,
    C = 20,
}
arr: #sparse [Sparse]int
`, "IDX-ENUM-006: sparse enumerated array")
}

@(test)
test_idx_sparse_enum_array_init_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.4-sparse-with-init
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Sparse :: enum {
    A = 0,
    B = 10,
    C = 20,
}
arr: #sparse [Sparse]int = {
    .A = 1,
    .B = 2,
    .C = 3,
}
`, "IDX-ENUM-007: sparse enumerated array with init")
}

// =============================================================================
// ENUMERATED ARRAY LITERALS - Positive Tests
// =============================================================================

@(test)
test_idx_enum_literal_full_pos :: proc(t: ^testing.T) {
	// @spec: indexing.md#13.1-full-initialization
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Color :: enum { Red, Green, Blue }
colors := [Color]string{
    .Red = "red",
    .Green = "green",
    .Blue = "blue",
}
`, "IDX-ENUM-008: full enumerated array literal")
}

// =============================================================================
// NEGATIVE TESTS - Index Type Errors
// =============================================================================

@(test)
test_idx_enum_array_int_index_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.2-must-use-enum-type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int = { .Red = 1, .Green = 2, .Blue = 3 }
x := color_values[0]
`, "IDX-ENUM-009: cannot index enum array with int")
}

@(test)
test_idx_enum_array_wrong_enum_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.2-must-use-correct-enum
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
Size :: enum { Small, Medium, Large }
color_values: [Color]int = { .Red = 1, .Green = 2, .Blue = 3 }
x := color_values[Size.Small]
`, "IDX-ENUM-010: cannot index with wrong enum type")
}

// =============================================================================
// NEGATIVE TESTS - Non-Contiguous Enums
// =============================================================================

@(test)
test_idx_noncontiguous_without_sparse_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.3-contiguous-requirement
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Sparse :: enum {
    A = 0,
    B = 10,
    C = 20,
}
arr: [Sparse]int
`, "IDX-ENUM-011: non-contiguous enum requires #sparse")
}

// =============================================================================
// NEGATIVE TESTS - Cannot Slice Enumerated Arrays
// =============================================================================

@(test)
test_idx_enum_array_slice_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#3.6-cannot-slice
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
color_values: [Color]int = { .Red = 1, .Green = 2, .Blue = 3 }
s := color_values[:]
`, "IDX-ENUM-012: cannot slice enumerated array")
}

// =============================================================================
// NEGATIVE TESTS - Literal Syntax Errors
// =============================================================================

@(test)
test_idx_enum_literal_bare_elements_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#13.2-bare-elements-not-allowed
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
colors := [Color]string{"red", "green", "blue"}
`, "IDX-ENUM-013: bare elements not allowed in enum array literal")
}

@(test)
test_idx_enum_literal_missing_cases_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#13.3-missing-cases
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
colors := [Color]string{
    .Red = "red",
}
`, "IDX-ENUM-014: missing enum cases in literal")
}

@(test)
test_idx_enum_literal_wrong_count_neg :: proc(t: ^testing.T) {
	// @spec: indexing.md#13-wrong-element-count
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Color :: enum { Red, Green, Blue }
colors := [Color]string{
    .Red = "red",
    .Green = "green",
    .Blue = "blue",
    .Red = "also red",
}
`, "IDX-ENUM-015: duplicate enum case in literal")
}
