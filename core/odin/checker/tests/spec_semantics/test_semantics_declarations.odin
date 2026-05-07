package test_spec_semantics

/*
Test Coverage: semantics.md Section 3 - Scopes and Blocks

Tests for scope hierarchy, shadowing, using statements.

Spec Reference: ../spec/semantics.md#3-scopes-and-blocks
Test IDs: SEM-DECL-001 through SEM-DECL-060
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// BLOCK SCOPE - Positive Tests
// =============================================================================

@(test)
test_block_scope_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#3.2 - block creates new scope
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 1
    {
        y := 2
        _ = x  // outer visible
        _ = y
    }
    _ = x
}
`, "SEM-DECL-001: block scope")
}

@(test)
test_shadowing_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#3.3 - shadowing outer declarations
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x := 1
    {
        x := 2  // shadows outer x
        _ = x
    }
    _ = x  // original x
}
`, "SEM-DECL-002: shadowing")
}

@(test)
test_package_scope_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#3.1 - package level declarations
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
CONSTANT :: 42
global_var: int

test :: proc() {
    _ = CONSTANT
    _ = global_var
}
`, "SEM-DECL-003: package scope")
}

@(test)
test_nested_procs_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#3.1 - nested procedures
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    inner :: proc() {
        // Local procedure
    }
    inner()
}
`, "SEM-DECL-004: nested procedure")
}

@(test)
test_constant_decl_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md - constant declarations
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
PI :: 3.14159
SIZE :: 100
NAME :: "test"
`, "SEM-DECL-005: constant declarations")
}

@(test)
test_multiple_var_decl_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md - multiple variable declaration
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
test :: proc() {
    x, y, z: int
    a, b := 1, 2
}
`, "SEM-DECL-006: multiple var decl")
}

// =============================================================================
// RETURN VALUES - Positive Tests
// =============================================================================

@(test)
test_return_single_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.1 - single return value
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
square :: proc(x: int) -> int {
    return x * x
}
`, "SEM-DECL-007: single return")
}

@(test)
test_return_multiple_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.1 - multiple return values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
divide :: proc(a, b: int) -> (int, int) {
    return a / b, a % b
}
`, "SEM-DECL-008: multiple returns")
}

@(test)
test_named_return_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.2 - named return values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
divide :: proc(a, b: int) -> (quotient: int, remainder: int) {
    quotient = a / b
    remainder = a % b
    return
}
`, "SEM-DECL-009: named returns")
}

@(test)
test_named_return_explicit_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.2 - named returns with explicit values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
divide :: proc(a, b: int) -> (q: int, r: int) {
    return a / b, a % b
}
`, "SEM-DECL-010: named returns explicit")
}

@(test)
test_return_capture_all_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.3 - capture all returns
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
divide :: proc(a, b: int) -> (int, int) {
    return a / b, a % b
}
test :: proc() {
    q, r := divide(10, 3)
    _ = q
    _ = r
}
`, "SEM-DECL-011: capture all returns")
}

@(test)
test_return_ignore_some_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.3 - ignore some returns with _
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
divide :: proc(a, b: int) -> (int, int) {
    return a / b, a % b
}
test :: proc() {
    q, _ := divide(10, 3)
    _ = q
}
`, "SEM-DECL-012: ignore some returns")
}

// =============================================================================
// PROCEDURE PARAMETERS - Positive Tests
// =============================================================================

@(test)
test_proc_params_basic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#4.1 - basic procedure parameters
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
add :: proc(a: int, b: int) -> int {
    return a + b
}
`, "SEM-DECL-013: proc params basic")
}

@(test)
test_proc_params_same_type_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#4.1 - parameters with same type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
add :: proc(a, b, c: int) -> int {
    return a + b + c
}
`, "SEM-DECL-014: proc params same type")
}

@(test)
test_proc_pointer_param_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md#4.2 - pointer parameter for mutation
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
modify :: proc(x: ^int) {
    x^ = 10
}
`, "SEM-DECL-015: pointer param")
}

@(test)
test_proc_variadic_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md - variadic parameters
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
sum :: proc(nums: ..int) -> int {
    total := 0
    for n in nums {
        total += n
    }
    return total
}
`, "SEM-DECL-016: variadic params")
}

@(test)
test_proc_default_param_pos :: proc(t: ^testing.T) {
	// @spec: semantics.md - default parameter values
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
greet :: proc(name := "World") -> string {
    return name
}
test :: proc() {
    _ = greet()
    _ = greet("Odin")
}
`, "SEM-DECL-017: default params")
}

// =============================================================================
// DECLARATIONS - Negative Tests
// =============================================================================

@(test)
test_redeclaration_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md - redeclaration in same scope
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    x := 1
    x := 2  // Error: redeclaration
}
`, "SEM-DECL-018: redeclaration")
}

@(test)
test_undeclared_name_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md - use of undeclared name
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    y := x  // Error: x not declared
}
`, "SEM-DECL-019: undeclared name")
}

@(test)
test_block_var_outside_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#3.2 - block-scoped var not visible outside
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
test :: proc() {
    {
        y := 2
    }
    _ = y  // Error: y not visible
}
`, "SEM-DECL-020: block var outside scope")
}

@(test)
test_return_wrong_count_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.4 - wrong return count
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
divide :: proc(a, b: int) -> (int, int) {
    return a / b  // Error: missing second return
}
`, "SEM-DECL-021: return wrong count")
}

@(test)
test_return_no_value_expected_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#5.4 - return value when none expected
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
nothing :: proc() {
    return 42  // Error: no return expected
}
`, "SEM-DECL-022: return unexpected value")
}

@(test)
test_param_immutable_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md#4.1 - parameters are immutable
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
modify :: proc(x: int) {
    x = 10  // Error: cannot assign to parameter
}
`, "SEM-DECL-023: param immutable")
}

@(test)
test_constant_reassign_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md - constants cannot be reassigned
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
VALUE :: 42
test :: proc() {
    VALUE = 100  // Error: cannot assign to constant
}
`, "SEM-DECL-024: constant reassign")
}

@(test)
test_duplicate_param_name_neg :: proc(t: ^testing.T) {
	// @spec: semantics.md - duplicate parameter names
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
bad :: proc(x: int, x: int) -> int {  // Error: duplicate param name
    return x
}
`, "SEM-DECL-025: duplicate param name")
}
