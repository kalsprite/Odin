package test_checker

/*
Data-Driven Test Infrastructure

For large test suites (like the 818 error tests), use table-driven testing
to reduce boilerplate and improve maintainability.

Usage:
    type_mismatch_suite := Test_Suite{
        name = "Type Mismatch Errors",
        spec_file = "errors.md",
        spec_section = "type-mismatch",
        cases = {
            {
                id = "ERR-TM-001",
                name = "int to string",
                source = `package test
x: int = "hello"
`,
                expect_error = true,
                error_substr = "cannot",
            },
            // ... more cases
        },
    }

    @(test)
    test_type_mismatch_errors :: proc(t: ^testing.T) {
        run_test_suite(t, type_mismatch_suite)
    }
*/

import "base:runtime"

import "core:strings"
import "core:testing"

// =============================================================================
// TEST CASE DEFINITION
// =============================================================================

// Test_Case represents a single test specification
Test_Case :: struct {
	// Identification
	id:   string, // Unique test ID (e.g., "ERR-TM-001")
	name: string, // Human-readable name

	// Source code to test
	source: string, // Odin source code (must include `package test`)

	// Expected behavior
	expect_error: bool, // true for negative tests, false for positive

	// Error verification (for negative tests)
	error_substr: Maybe(string), // Expected substring in error message
	error_line:   Maybe(int), // Expected error line number
	error_count:  Maybe(int), // Expected number of errors (exact match)
}

// Test_Suite groups related test cases
Test_Suite :: struct {
	// Suite metadata
	name:         string, // Suite name for reporting
	spec_file:    string, // Reference spec file (e.g., "types.md")
	spec_section: string, // Reference section (e.g., "basic-types")

	// Test cases
	cases: []Test_Case,
}

// =============================================================================
// TEST SUITE EXECUTION
// =============================================================================

// run_test_suite executes all test cases in a suite
run_test_suite :: proc(t: ^testing.T, suite: Test_Suite) {
	for tc in suite.cases {
		run_single_case(t, suite, tc)
	}
}

// run_single_case executes a single test case
run_single_case :: proc(t: ^testing.T, suite: Test_Suite, tc: Test_Case) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	if tc.expect_error {
		run_negative_case(t, suite, tc)
	} else {
		run_positive_case(t, suite, tc)
	}
}

// run_positive_case verifies code compiles without errors
run_positive_case :: proc(t: ^testing.T, suite: Test_Suite, tc: Test_Case) {
	result := check_source_internal(tc.source)

	if !result.parse_ok {
		testing.expectf(t, false, "[%s] %s: Parse failed unexpectedly", tc.id, tc.name)
		return
	}

	if result.error_count > 0 {
		testing.expectf(
			t,
			false,
			"[%s] %s: Expected success but got %d errors",
			tc.id,
			tc.name,
			result.error_count,
		)
	}
}

// run_negative_case verifies code produces expected errors
run_negative_case :: proc(t: ^testing.T, suite: Test_Suite, tc: Test_Case) {
	result := check_source_capture_errors(tc.source)
	defer destroy_test_result(&result)

	// Must have at least one error
	if result.error_count == 0 {
		testing.expectf(t, false, "[%s] %s: Expected error but got none", tc.id, tc.name)
		return
	}

	// Check error count if specified
	if expected_count, ok := tc.error_count.?; ok {
		if result.error_count != expected_count {
			testing.expectf(
				t,
				false,
				"[%s] %s: Expected %d errors but got %d",
				tc.id,
				tc.name,
				expected_count,
				result.error_count,
			)
			return
		}
	}

	// Check error message substring if specified (case-insensitive)
	if expected_substr, ok := tc.error_substr.?; ok {
		found := false
		expected_lower := strings.to_lower(expected_substr)
		for err in result.errors {
			msg_lower := strings.to_lower(err.message)
			if strings.contains(msg_lower, expected_lower) {
				found = true
				break
			}
		}
		if !found {
			got_msgs: [dynamic]string
			defer delete(got_msgs)
			for err in result.errors {
				append(&got_msgs, err.message)
			}
			testing.expectf(
				t,
				false,
				"[%s] %s: Expected error containing '%s', got: %v",
				tc.id,
				tc.name,
				expected_substr,
				got_msgs[:],
			)
			return
		}
	}

	// Check error line if specified
	if expected_line, ok := tc.error_line.?; ok {
		found := false
		for err in result.errors {
			if err.line == expected_line {
				found = true
				break
			}
		}
		if !found {
			got_lines: [dynamic]int
			defer delete(got_lines)
			for err in result.errors {
				append(&got_lines, err.line)
			}
			testing.expectf(
				t,
				false,
				"[%s] %s: Expected error at line %d, got lines: %v",
				tc.id,
				tc.name,
				expected_line,
				got_lines[:],
			)
		}
	}
}

// =============================================================================
// SUITE BUILDER HELPERS
// =============================================================================

// pos creates a positive test case (code should compile)
pos :: proc(id: string, name: string, source: string) -> Test_Case {
	return Test_Case{id = id, name = name, source = source, expect_error = false}
}

// neg creates a negative test case (code should error)
neg :: proc(id: string, name: string, source: string, error_substr := "") -> Test_Case {
	tc := Test_Case {
		id           = id,
		name         = name,
		source       = source,
		expect_error = true,
	}
	if error_substr != "" {
		tc.error_substr = error_substr
	}
	return tc
}

// neg_line creates a negative test case expecting error at specific line
neg_line :: proc(id: string, name: string, source: string, line: int) -> Test_Case {
	return Test_Case {
		id           = id,
		name         = name,
		source       = source,
		expect_error = true,
		error_line   = line,
	}
}

// neg_count creates a negative test case expecting exact error count
neg_count :: proc(id: string, name: string, source: string, count: int) -> Test_Case {
	return Test_Case {
		id           = id,
		name         = name,
		source       = source,
		expect_error = true,
		error_count  = count,
	}
}
