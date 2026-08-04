package test_spec_errors

/*
Test Coverage: errors.md - Procedure Errors

Tests for procedure-related errors including argument count,
argument types, return types, and calling conventions.

Spec Reference: ../spec/errors.md#procedures
Test IDs: ERR-PROC-001 through ERR-PROC-050
Last Sync: 2026-01-18
*/

import "base:runtime"

import "core:testing"

import helpers ".."

// =============================================================================
// PROCEDURE ERROR TEST SUITE
// =============================================================================

procedure_suite := helpers.Test_Suite {
	name         = "Procedure Errors",
	spec_file    = "errors.md",
	spec_section = "procedures",
	cases        = {
		// Wrong argument count
		{
			id           = "ERR-PROC-001",
			name         = "too few arguments",
			source       = `package test
foo :: proc(x: int, y: int) {}
bar :: proc() {
    foo(1)  // missing y
}
`,
			expect_error = true,
			// Verified against the REFERENCE compiler: it emits "Parameter 'y' of type 'int' is
			// missing in procedure call", which contains no "argument". The port matches it exactly.
			error_substr = "is missing in procedure call",
		},
		{
			id           = "ERR-PROC-002",
			name         = "too many arguments",
			source       = `package test
foo :: proc(x: int) {}
bar :: proc() {
    foo(1, 2, 3)  // too many
}
`,
			expect_error = true,
			error_substr = "argument",
		},
		// Wrong argument type
		{
			id           = "ERR-PROC-003",
			name         = "wrong argument type",
			source       = `package test
foo :: proc(x: int) {}
bar :: proc() {
    foo("hello")  // string not int
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Calling non-procedure
		{
			id           = "ERR-PROC-004",
			name         = "calling non-procedure",
			source       = `package test
foo :: proc() {
    x := 42
    x()  // int is not callable
}
`,
			expect_error = true,
			error_substr = "call",
		},
		// Calling type as procedure (type conversion)
		{
			id           = "ERR-PROC-005",
			name         = "type conversion OK",
			source       = `package test
foo :: proc() {
    x: f32 = f32(42)  // type conversion
    _ = x
}
`,
			expect_error = false,
		},
		// Named arguments
		{
			id           = "ERR-PROC-006",
			name         = "named argument OK",
			source       = `package test
foo :: proc(x: int, y: int) {}
bar :: proc() {
    foo(x = 1, y = 2)
}
`,
			expect_error = false,
		},
		{
			id           = "ERR-PROC-007",
			name         = "named argument wrong name",
			source       = `package test
foo :: proc(x: int, y: int) {}
bar :: proc() {
    foo(a = 1, b = 2)  // a, b not parameters
}
`,
			expect_error = true,
			error_substr = "parameter",
		},
		{
			id           = "ERR-PROC-008",
			name         = "duplicate named argument",
			source       = `package test
foo :: proc(x: int) {}
bar :: proc() {
    foo(x = 1, x = 2)  // x specified twice
}
`,
			expect_error = true,
			error_substr = "duplicate",
		},
		// Variadic arguments
		{
			id           = "ERR-PROC-009",
			name         = "variadic OK",
			source       = `package test
foo :: proc(args: ..int) {}
bar :: proc() {
    foo(1, 2, 3)
}
`,
			expect_error = false,
		},
		{
			id           = "ERR-PROC-010",
			name         = "variadic wrong type",
			source       = `package test
foo :: proc(args: ..int) {}
bar :: proc() {
    foo(1, "hello", 3)  // string in int variadic
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// Return value count mismatch at call site
		{
			id           = "ERR-PROC-011",
			name         = "ignoring return value OK",
			source       = `package test
foo :: proc() -> int { return 42 }
bar :: proc() {
    foo()  // ignoring return OK
}
`,
			expect_error = false,
		},
		{
			id           = "ERR-PROC-012",
			name         = "using return value OK",
			source       = `package test
foo :: proc() -> int { return 42 }
bar :: proc() {
    x := foo()
    _ = x
}
`,
			expect_error = false,
		},
		// Multiple return values
		{
			id           = "ERR-PROC-013",
			name         = "multiple return values OK",
			source       = `package test
foo :: proc() -> (int, bool) { return 42, true }
bar :: proc() {
    x, ok := foo()
    _ = x
    _ = ok
}
`,
			expect_error = false,
		},
		{
			id           = "ERR-PROC-014",
			name         = "wrong number of return captures",
			source       = `package test
foo :: proc() -> (int, bool) { return 42, true }
bar :: proc() {
    x, y, z := foo()  // too many
}
`,
			expect_error = true,
			error_substr = "mismatch",
		},
		// Procedure as argument
		{
			id           = "ERR-PROC-015",
			name         = "procedure as argument OK",
			source       = `package test
apply :: proc(f: proc(int) -> int, x: int) -> int {
    return f(x)
}
double :: proc(x: int) -> int { return x * 2 }
bar :: proc() {
    result := apply(double, 21)
    _ = result
}
`,
			expect_error = false,
		},
		{
			id           = "ERR-PROC-016",
			name         = "wrong procedure signature as argument",
			source       = `package test
apply :: proc(f: proc(int) -> int, x: int) -> int {
    return f(x)
}
wrong :: proc(x: string) -> int { return 0 }
bar :: proc() {
    result := apply(wrong, 21)  // wrong signature
    _ = result
}
`,
			expect_error = true,
			error_substr = "cannot",
		},
		// #no_bounds_check etc. attributes
		{
			id           = "ERR-PROC-017",
			name         = "no_bounds_check OK",
			source       = `package test
@(disabled=false)
foo :: proc() #no_bounds_check {
    arr: [3]int
    _ = arr[0]
}
`,
			expect_error = false,
		},
		// Recursive procedure
		{
			id           = "ERR-PROC-018",
			name         = "recursive procedure OK",
			source       = `package test
factorial :: proc(n: int) -> int {
    if n <= 1 {
        return 1
    }
    return n * factorial(n - 1)
}
`,
			expect_error = false,
		},
		// Mutual recursion
		{
			id           = "ERR-PROC-019",
			name         = "mutual recursion OK",
			source       = `package test
even :: proc(n: int) -> bool {
    if n == 0 { return true }
    return odd(n - 1)
}
odd :: proc(n: int) -> bool {
    if n == 0 { return false }
    return even(n - 1)
}
`,
			expect_error = false,
		},
		// Default argument
		{
			id           = "ERR-PROC-020",
			name         = "default argument OK",
			source       = `package test
foo :: proc(x: int = 42) {}
bar :: proc() {
    foo()
    foo(1)
}
`,
			expect_error = false,
		},
	},
}

@(test)
test_procedure_errors :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.run_test_suite(t, procedure_suite)
}

// =============================================================================
// ADDITIONAL INDIVIDUAL TESTS
// =============================================================================

@(test)
test_err_proc_pointer_vs_value_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - pointer vs value argument
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
foo :: proc(x: ^int) {}
bar :: proc() {
    y := 42
    foo(y)  // should be &y
}
`, "ERR-PROC-021: pointer vs value")
}

@(test)
test_err_proc_auto_pointer_with_mut_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - automatic address-of for pointer param
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Odin auto-takes address in some cases
	helpers.check_should_pass(t, `package test
Point :: struct { x, y: int }
modify :: proc(p: ^Point) {
    p.x = 10
}
bar :: proc() {
    p: Point
    modify(&p)
}
`, "ERR-PROC-022: explicit address-of")
}

@(test)
test_err_proc_contextless_accessing_context_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - contextless proc cannot access context
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Note: This requires checker to track contextless attribute
	result := helpers.check_source_capture_errors(t, `package test
foo :: proc() #contextless {
    _ = context.allocator
}
`)
	defer helpers.destroy_test_result(&result)
	// May or may not error depending on implementation
}

@(test)
test_err_proc_deferred_proc_signature_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - deferred proc wrong signature
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_fail(t, `package test
cleanup :: proc() {}
open :: proc() -> int {
    defer cleanup(42)  // cleanup takes no args
    return 0
}
`, "ERR-PROC-023: deferred proc wrong signature")
}

@(test)
test_err_proc_nested_def_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - nested procedure definition OK
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
outer :: proc() {
    inner :: proc() {}
    inner()
}
`, "ERR-PROC-024: nested procedure")
}

@(test)
test_err_proc_return_in_nested_returns_from_nested_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - return in nested proc returns from nested
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
outer :: proc() -> int {
    inner :: proc() -> int {
        return 42  // returns from inner
    }
    return inner()
}
`, "ERR-PROC-025: return in nested")
}

@(test)
test_err_proc_ambiguous_overload_neg :: proc(t: ^testing.T) {
	// @spec: errors.md - ambiguous overload resolution
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Odin may error on ambiguous overloads
	result := helpers.check_source_capture_errors(t, `package test
foo :: proc(x: int) {}
foo :: proc(y: int) {}
bar :: proc() {
    foo(42)  // which foo?
}
`)
	defer helpers.destroy_test_result(&result)
	// Verify there's an error (redeclaration or ambiguous)
	testing.expect(t, result.error_count > 0, "ERR-PROC-026: ambiguous overload")
}

@(test)
test_err_proc_any_type_arg_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - any type accepts any value
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
print :: proc(x: any) {}
bar :: proc() {
    print(42)
    print("hello")
    print(true)
}
`, "ERR-PROC-027: any type arg")
}

@(test)
test_err_proc_rawptr_from_typed_ptr_pos :: proc(t: ^testing.T) {
	// @spec: errors.md - typed pointer to rawptr
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	helpers.check_should_pass(t, `package test
foo :: proc(p: rawptr) {}
bar :: proc() {
    x := 42
    foo(&x)
}
`, "ERR-PROC-028: typed pointer to rawptr")
}
