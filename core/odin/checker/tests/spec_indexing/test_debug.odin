package test_spec_indexing

import "base:runtime"
import "core:testing"
import "core:fmt"
import helpers ".."

// Debug test for ad-hoc testing of checker functionality
@(test)
test_debug :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Test what runtime symbols are accessible
	fmt.println("=== Testing runtime symbol access ===")

	// Test Context type
	result1 := helpers.check_source_capture_errors(`package test
import "base:runtime"
test :: proc() {
    ctx: runtime.Context
    _ = ctx
}
`)
	defer helpers.destroy_test_result(&result1)
	fmt.println("runtime.Context:", result1.error_count == 0 ? "OK" : "FAIL")

	// Test Source_Code_Location type
	result2 := helpers.check_source_capture_errors(`package test
import "base:runtime"
test :: proc() {
    loc: runtime.Source_Code_Location
    _ = loc
}
`)
	defer helpers.destroy_test_result(&result2)
	fmt.println("runtime.Source_Code_Location:", result2.error_count == 0 ? "OK" : "FAIL")

	// Test Allocator type
	result3 := helpers.check_source_capture_errors(`package test
import "base:runtime"
test :: proc() {
    a: runtime.Allocator
    _ = a
}
`)
	defer helpers.destroy_test_result(&result3)
	fmt.println("runtime.Allocator:", result3.error_count == 0 ? "OK" : "FAIL")

	// Test DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD procedure
	result4 := helpers.check_source_capture_errors(`package test
import "base:runtime"
test :: proc() {
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()
}
`)
	defer helpers.destroy_test_result(&result4)
	fmt.println("runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD:", result4.error_count == 0 ? "OK" : "FAIL")
	if result4.error_count > 0 {
		for err in result4.errors {
			fmt.printf("  Error: %s\n", err.message)
		}
	}
}
