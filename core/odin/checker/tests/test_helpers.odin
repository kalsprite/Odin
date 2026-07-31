package test_checker

/*
Test Helper Infrastructure

Enhanced utilities for systematic testing of the Odin checker.
Provides helpers for both positive and negative tests with error message capture.

Usage:
    // Positive test - code should compile
    check_should_pass(t, `package test; x: int = 42`)

    // Negative test - code should error
    check_should_fail(t, `package test; x: int = "hello"`)

    // Negative test with message verification
    check_expects_error_containing(t, `package test; x: int = "hello"`, "cannot")

    // Get full error details
    result := check_source_capture_errors(t, `package test; x: int = "hello"`)
    for err in result.errors {
        fmt.println(err.line, err.message)
    }
*/

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:strings"
import "core:testing"

import checker ".."

// =============================================================================
// TEST RESULT TYPES
// =============================================================================

// Captured_Error holds details of a single error for test verification
Captured_Error :: struct {
	line:       int,
	column:     int,
	message:    string, // Owned, must be freed
	is_warning: bool,
}

// Test_Check_Result holds complete results from checking source code
Test_Check_Result :: struct {
	parse_ok:    bool,
	check_ok:    bool,
	error_count: int,
	errors:      []Captured_Error, // Owned slice, use destroy_test_result to free
	allocator:   runtime.Allocator,
}

// destroy_test_result frees all memory associated with a test result
destroy_test_result :: proc(result: ^Test_Check_Result) {
	for &err in result.errors {
		delete(err.message, result.allocator)
	}
	delete(result.errors, result.allocator)
	result.errors = nil
}

// =============================================================================
// POSITIVE TEST HELPERS
// =============================================================================

// check_should_pass verifies that source code compiles without errors
// Returns true if no errors occurred
check_should_pass :: proc(t: ^testing.T, src: string, msg := "") -> bool {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	result := check_source_internal(t, src)

	if !result.parse_ok {
		testing.expectf(t, false, "%s: Parse failed unexpectedly", msg != "" ? msg : "Positive test")
		return false
	}

	if result.error_count > 0 {
		testing.expectf(
			t,
			false,
			"%s: Expected no errors but got %d",
			msg != "" ? msg : "Positive test",
			result.error_count,
		)
		return false
	}

	return true
}

// check_should_pass_multi verifies multiple source snippets all compile
check_should_pass_multi :: proc(t: ^testing.T, sources: []string) -> bool {
	all_passed := true
	for src, i in sources {
		if !check_should_pass(t, src, "") {
			testing.expectf(t, false, "Source snippet %d failed", i)
			all_passed = false
		}
	}
	return all_passed
}

// =============================================================================
// NEGATIVE TEST HELPERS (Simple)
// =============================================================================

// check_should_fail verifies that source code produces at least one error
// Returns true if errors were detected
check_should_fail :: proc(t: ^testing.T, src: string, msg := "") -> bool {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(t, src)

	if !has_error {
		testing.expectf(t, false, "%s: Expected error but got none", msg != "" ? msg : "Negative test")
		return false
	}

	return true
}

// =============================================================================
// NEGATIVE TEST HELPERS (With Message Verification)
// =============================================================================

// check_expects_error_containing verifies an error containing the expected substring
check_expects_error_containing :: proc(
	t: ^testing.T,
	src: string,
	expected_substr: string,
	msg := "",
) -> bool {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	result := check_source_capture_errors(t, src)
	defer destroy_test_result(&result)

	if result.error_count == 0 {
		testing.expectf(
			t,
			false,
			"%s: Expected error containing '%s' but got no errors",
			msg != "" ? msg : "Error check",
			expected_substr,
		)
		return false
	}

	// Check if any error contains the expected substring (case-insensitive)
	expected_lower := strings.to_lower(expected_substr)
	for err in result.errors {
		msg_lower := strings.to_lower(err.message)
		if strings.contains(msg_lower, expected_lower) {
			return true
		}
	}

	// Build error message showing what we got
	got_msgs: [dynamic]string
	defer delete(got_msgs)
	for err in result.errors {
		append(&got_msgs, err.message)
	}

	testing.expectf(
		t,
		false,
		"%s: Expected error containing '%s', got: %v",
		msg != "" ? msg : "Error check",
		expected_substr,
		got_msgs[:],
	)
	return false
}

// check_expects_error_at_line verifies an error occurs on the specified line
check_expects_error_at_line :: proc(t: ^testing.T, src: string, expected_line: int) -> bool {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	result := check_source_capture_errors(t, src)
	defer destroy_test_result(&result)

	if result.error_count == 0 {
		testing.expectf(t, false, "Expected error at line %d but got no errors", expected_line)
		return false
	}

	for err in result.errors {
		if err.line == expected_line {
			return true
		}
	}

	// Build list of lines where errors occurred
	got_lines: [dynamic]int
	defer delete(got_lines)
	for err in result.errors {
		append(&got_lines, err.line)
	}

	testing.expectf(t, false, "Expected error at line %d, got errors at lines: %v", expected_line, got_lines[:])
	return false
}

// check_expects_n_errors verifies exactly N errors occur
check_expects_n_errors :: proc(t: ^testing.T, src: string, expected_count: int) -> bool {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	_, count := check_expects_error(t, src)

	if count != expected_count {
		testing.expectf(t, false, "Expected %d errors but got %d", expected_count, count)
		return false
	}

	return true
}

// =============================================================================
// PACKAGE-LEVEL RESULT HELPERS
// =============================================================================

// expect_not_limit_reached fails the test if checking a package was abandoned because the
// error cap was hit.
//
// This is a THIRD outcome, and it must be reported as its own thing:
//   - "clean"                -> res.ok
//   - "checked, found N"     -> res.check_errors == N, res.limit_reached == false
//   - "gave up after N"      -> res.limit_reached == true
// In the last case the checker unwound at a phase boundary, so res.check_errors is a
// truncated prefix and the *absence* of any particular diagnostic means nothing. Treating it
// as a pass would be wrong (most of the package was never checked); treating it as a plain
// check failure would be wrong too (it hides that the numbers are not comparable to a
// completed run). Before this existed the checker called os.exit(1) here and took the whole
// test binary with it - see CPP_DEVIATIONS.md [EMBED-1].
expect_not_limit_reached :: proc(t: ^testing.T, path: string, res: checker.Package_Check_Result) -> bool {
	if res.limit_reached {
		testing.expectf(
			t,
			false,
			"LIMIT REACHED: %s produced more errors than the cap allows; checking was abandoned "+
			"after %d recorded errors and the result is incomplete",
			path,
			res.check_errors,
		)
		return false
	}
	return true
}

// =============================================================================
// FULL ERROR CAPTURE
// =============================================================================

// check_source_capture_errors runs the checker and captures all error details
// Caller must call destroy_test_result when done
check_source_capture_errors :: proc(
	t: ^testing.T,
	src: string,
	filename := "test.odin",
	allocator := context.allocator,
) -> Test_Check_Result {
	result: Test_Check_Result
	result.allocator = allocator

	// Parse
	file := new(ast.File)
	file.fullpath = filename
	file.src = src

	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

	result.parse_ok = parser.parse_file(&p, file)
	if !result.parse_ok {
		return result
	}

	// Check with mutex protection
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	// Use default_allocator for the checker to ensure types persist
	// beyond the temp_allocator's lifetime set by the test
	checker.init_checker(c, runtime.default_allocator())
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	// Create package
	pkg := new(ast.Package)
	pkg.fullpath = "test_package"
	pkg.name = "test"
	pkg.files = make(map[string]^ast.File)
	pkg.files[file.fullpath] = file
	file.pkg = pkg

	result.check_ok = checker.check_files(c, {file})
	result.error_count = checker.error_count()

	// Capture error details from global collector
	error_values := checker.get_error_values()
	if len(error_values) > 0 {
		result.errors = make([]Captured_Error, len(error_values), allocator)
		for ev, i in error_values {
			result.errors[i] = Captured_Error {
				line       = ev.pos.line,
				column     = ev.pos.column,
				message    = strings.clone(string(ev.msg[:]), allocator),
				is_warning = ev.kind == .Warning,
			}
		}
	}

	return result
}

// =============================================================================
// INTERNAL HELPERS
// =============================================================================

// check_source_internal runs basic check without error capture
check_source_internal :: proc(t: ^testing.T, src: string, filename := "test.odin") -> Test_Check_Result {
	result: Test_Check_Result

	file := new(ast.File)
	file.fullpath = filename
	file.src = src

	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

	result.parse_ok = parser.parse_file(&p, file)
	if !result.parse_ok {
		return result
	}

	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	// Use default_allocator for the checker to ensure types persist
	// beyond the temp_allocator's lifetime set by the test
	checker.init_checker(c, runtime.default_allocator())
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	pkg := new(ast.Package)
	pkg.fullpath = "test_package"
	pkg.name = "test"
	pkg.files = make(map[string]^ast.File)
	pkg.files[file.fullpath] = file
	file.pkg = pkg

	result.check_ok = checker.check_files(c, {file})
	result.error_count = checker.error_count()

	return result
}

// =============================================================================
// SPEC REFERENCE HELPERS
// =============================================================================

// Spec_Ref documents which spec section a test covers
// Use in test comments: // @spec: types.md#basic-types
Spec_Ref :: struct {
	file:    string, // e.g., "types.md"
	section: string, // e.g., "basic-types"
	id:      string, // e.g., "TYPES-001"
}
