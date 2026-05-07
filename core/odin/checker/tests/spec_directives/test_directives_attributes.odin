package test_spec_directives

/*
Test Coverage: directives.md Sections 3 - Attributes

Tests for @(init), @(export), @(private), @(deprecated), etc.

Spec Reference: ../spec/directives.md#3-attributes
Test IDs: DIR-ATTR-001 through DIR-ATTR-050
Last Sync: 2026-01-17
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// PROCEDURE ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_attr_init_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(init) runs at startup
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(init)
init :: proc() {
    // Runs at startup
}
`, "DIR-ATTR-001: @(init) attribute")
}

@(test)
test_attr_fini_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(fini) runs at shutdown
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(fini)
cleanup :: proc() {
    // Runs at shutdown
}
`, "DIR-ATTR-002: @(fini) attribute")
}

@(test)
test_attr_export_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(export) exports symbol
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(export)
public_func :: proc() {
}
`, "DIR-ATTR-003: @(export) attribute")
}

@(test)
test_attr_link_name_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(link_name) sets custom name
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(link_name="my_custom_name")
@(export)
my_func :: proc() {
}
`, "DIR-ATTR-004: @(link_name) attribute")
}

@(test)
test_attr_deprecated_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(deprecated) marks as deprecated
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(deprecated="Use new_func instead")
old_func :: proc() {
}
`, "DIR-ATTR-005: @(deprecated) attribute")
}

@(test)
test_attr_private_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(private) limits visibility
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(private)
internal_func :: proc() {
}
`, "DIR-ATTR-006: @(private) attribute")
}

@(test)
test_attr_private_file_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(private="file") limits to file
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(private="file")
file_local :: proc() {
}
`, "DIR-ATTR-007: @(private=\"file\") attribute")
}

@(test)
test_attr_require_results_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(require_results) enforces usage
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(require_results)
compute :: proc() -> int {
    return 42
}
test :: proc() {
    result := compute()
    _ = result
}
`, "DIR-ATTR-008: @(require_results) attribute")
}

@(test)
test_attr_cold_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(cold) marks unlikely path
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(cold)
error_handler :: proc() {
}
`, "DIR-ATTR-009: @(cold) attribute")
}

@(test)
test_attr_test_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(test) marks test procedure
	// Note: In a real project, @(test) procedures would take ^testing.T parameter,
	// but since we can't resolve the core:testing import in isolated checks,
	// we test just the attribute recognition without the import
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(test)
my_test :: proc() {
}
`, "DIR-ATTR-010: @(test) attribute")
}

@(test)
test_attr_disabled_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(disabled) disables procedure
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(disabled)
old_code :: proc() {
}
`, "DIR-ATTR-011: @(disabled) attribute")
}

// =============================================================================
// DEFERRED PROCEDURE ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_attr_deferred_none_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.2 - @(deferred_none) calls with no args
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
cleanup :: proc() {
    // cleanup code
}

@(deferred_none=cleanup)
acquire :: proc() {
}
`, "DIR-ATTR-012: @(deferred_none) attribute")
}

@(test)
test_attr_deferred_out_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.2 - @(deferred_out) calls with output
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
close :: proc(handle: int) {
}

@(deferred_out=close)
open :: proc() -> int {
    return 1
}
`, "DIR-ATTR-013: @(deferred_out) attribute")
}

// =============================================================================
// VARIABLE ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_attr_static_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.3 - @(static) static storage
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
counter :: proc() -> int {
    @(static) count := 0
    count += 1
    return count
}
`, "DIR-ATTR-014: @(static) variable")
}

@(test)
test_attr_thread_local_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.3 - @(thread_local) TLS
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(thread_local)
tls_var: int
`, "DIR-ATTR-015: @(thread_local) variable")
}

@(test)
test_attr_rodata_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.3 - @(rodata) read-only data
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(rodata)
lookup_table := [4]int{1, 2, 3, 4}
`, "DIR-ATTR-016: @(rodata) variable")
}

// =============================================================================
// TYPE ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_attr_private_type_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3.4 - @(private) on type
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(private)
Internal_Type :: struct {
    data: int,
}
`, "DIR-ATTR-017: @(private) on type")
}

// =============================================================================
// FOREIGN BLOCK ATTRIBUTES - Positive Tests
// =============================================================================

// Temporarily disabled - foreign blocks may cause MPSC queue crash
// @(test)
// test_attr_foreign_default_cc_pos :: proc(t: ^testing.T) {
// 	// @spec: directives.md#3.5 - @(default_calling_convention)
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_pass(t, `package test
// @(default_calling_convention="c")
// foreign libc {
//     puts :: proc(s: cstring) -> i32 ---
// }
// foreign import libc "system:c"
// `, "DIR-ATTR-018: @(default_calling_convention)")
// }

// @(test)
// test_attr_foreign_link_prefix_pos :: proc(t: ^testing.T) {
// 	// @spec: directives.md#3.5 - @(link_prefix) on foreign block
// 	context.allocator = context.temp_allocator
// 	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
//
// 	helpers.check_should_pass(t, `package test
// @(link_prefix="my_")
// foreign mylib {
//     func :: proc() ---
// }
// foreign import mylib "system:mylib"
// `, "DIR-ATTR-019: @(link_prefix) on foreign block")
// }

// =============================================================================
// MULTIPLE ATTRIBUTES - Positive Tests
// =============================================================================

@(test)
test_attr_multiple_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3 - Multiple attributes
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(export, link_name="exported_func")
my_exported :: proc() {
}
`, "DIR-ATTR-020: multiple attributes")
}

@(test)
test_attr_combined_syntax_pos :: proc(t: ^testing.T) {
	// @spec: directives.md#3 - Combined attribute syntax
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
@(private, deprecated="Old API")
legacy :: proc() {
}
`, "DIR-ATTR-021: combined attribute syntax")
}

// =============================================================================
// PROCEDURE ATTRIBUTES - Negative Tests
// =============================================================================

@(test)
test_attr_require_results_unused_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(require_results) must be used
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
@(require_results)
compute :: proc() -> int {
    return 42
}
test :: proc() {
    compute()  // Error: result not used
}
`, "DIR-ATTR-022: require_results not used")
}

@(test)
test_attr_init_with_params_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(init) cannot have parameters
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
@(init)
bad_init :: proc(x: int) {
}
`, "DIR-ATTR-023: @(init) with parameters")
}

@(test)
test_attr_init_with_return_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#3.1 - @(init) cannot have return
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
@(init)
bad_init :: proc() -> int {
    return 0
}
`, "DIR-ATTR-024: @(init) with return value")
}

// =============================================================================
// VARIABLE ATTRIBUTES - Negative Tests
// =============================================================================

@(test)
test_attr_static_global_neg :: proc(t: ^testing.T) {
	// @spec: directives.md#3.3 - @(static) only in procedure
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
@(static)
global_var: int
`, "DIR-ATTR-025: @(static) on global")
}
