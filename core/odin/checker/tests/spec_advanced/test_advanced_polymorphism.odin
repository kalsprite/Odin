package test_spec_advanced

/*
Test Coverage: advanced.md Section 1 - Polymorphism (Generics)

Tests for type parameters, where clauses, specialization, etc.

Spec Reference: ../spec/advanced.md#1-polymorphism-generics
Test IDs: ADV-POLY-001 through ADV-POLY-060
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// TYPE PARAMETERS - Positive Tests
// =============================================================================

@(test)
test_poly_struct_basic_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.1 - polymorphic struct
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Box :: struct($T: typeid) {
    value: T,
}
test :: proc() {
    int_box: Box(int)
    int_box.value = 42
}
`, "ADV-POLY-001: polymorphic struct")
}

@(test)
test_poly_proc_basic_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - polymorphic procedure
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
identity :: proc(x: $T) -> T {
    return x
}
test :: proc() {
    a := identity(42)
    b := identity("hello")
}
`, "ADV-POLY-002: polymorphic procedure")
}

@(test)
test_poly_swap_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - swap with pointers
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
swap :: proc(a, b: ^$T) {
    a^, b^ = b^, a^
}
test :: proc() {
    x, y := 1, 2
    swap(&x, &y)
}
`, "ADV-POLY-003: polymorphic swap")
}

@(test)
test_poly_const_param_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.3 - constant type parameters
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Fixed_Array :: struct($N: int, $T: typeid) {
    data: [N]T,
}
test :: proc() {
    arr: Fixed_Array(10, f32)
    arr.data[0] = 1.0
}
`, "ADV-POLY-004: const type param")
}

@(test)
test_poly_inferred_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - type inference from arguments
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
max :: proc(a, b: $T) -> T {
    return a if a > b else b
}
test :: proc() {
    _ = max(1, 2)
    _ = max(1.5, 2.5)
}
`, "ADV-POLY-005: type inference")
}

@(test)
test_poly_multiple_params_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.1 - multiple type parameters
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Pair :: struct($K: typeid, $V: typeid) {
    key: K,
    value: V,
}
test :: proc() {
    p: Pair(string, int)
    p.key = "x"
    p.value = 42
}
`, "ADV-POLY-006: multiple type params")
}

@(test)
test_poly_nested_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.1 - nested polymorphic types
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
Box :: struct($T: typeid) { value: T }
test :: proc() {
    nested: Box(Box(int))
    nested.value.value = 42
}
`, "ADV-POLY-007: nested poly types")
}

@(test)
test_poly_return_type_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - explicit return type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
make_default :: proc($T: typeid) -> T {
    return T{}
}
test :: proc() {
    _ = make_default(int)
    _ = make_default(f32)
}
`, "ADV-POLY-008: poly return type")
}

@(test)
test_poly_slice_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - polymorphic with slices
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
first :: proc(items: []$T) -> T {
    return items[0]
}
test :: proc() {
    arr := [3]int{1, 2, 3}
    _ = first(arr[:])
}
`, "ADV-POLY-009: poly with slices")
}

@(test)
test_poly_explicit_call_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.2 - explicit type instantiation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
zero :: proc($T: typeid) -> T {
    return T{}
}
test :: proc() {
    x := zero(int)
    y := zero(f32)
}
`, "ADV-POLY-010: explicit instantiation")
}

// =============================================================================
// WHERE CLAUSES - Positive Tests
// =============================================================================

@(test)
test_where_size_pos :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.4 - where with size_of
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
small :: proc(x: $T) where size_of(T) <= 8 {
    _ = x
}
test :: proc() {
    small(42)
    small(3.14)
}
`, "ADV-POLY-011: where with size_of")
}

// =============================================================================
// POLYMORPHISM - Negative Tests
// =============================================================================

@(test)
test_poly_unspecialized_use_neg :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.7 - cannot use unspecialized type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
Vec :: struct($T: typeid) { x, y: T }
test :: proc() {
    v: Vec  // Error: must specify concrete type
}
`, "ADV-POLY-012: unspecialized type")
}

@(test)
test_poly_variadic_type_neg :: proc(t: ^testing.T) {
	// @spec: advanced.md#1.7 - type param cannot be variadic
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
bad :: proc($T: ..typeid) {  // Error
}
`, "ADV-POLY-013: variadic type param")
}
