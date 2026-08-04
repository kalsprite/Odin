package test_spec_directives

import "base:runtime"
import "core:testing"
import "core:fmt"
import helpers ".."

@(test)
test_debug_caller_location :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(t, `package test
import "base:runtime"
log :: proc(msg: string, loc := #caller_location) {}
test :: proc() {
    log("hello")
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug #caller_location ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_config :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(t, `package test
DEBUG :: #config(DEBUG, false)
test :: proc() {
    _ = DEBUG
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug #config ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_param_no_alias :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(t, `package test
foo :: proc(#no_alias x: ^int) {}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug #no_alias param ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}
