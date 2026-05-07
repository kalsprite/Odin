package test_spec_runtime

import "base:runtime"
import "core:testing"
import "core:fmt"
import helpers ".."

@(test)
test_debug_cstring_to_string :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(`package test
test :: proc() {
    c: cstring = "hello"
    s := string(c)
    _ = s
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug cstring to string ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_typeid_switch :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(`package test
test :: proc() {
    id: typeid = int
    switch id {
    case int:
        _ = 1
    case f32:
        _ = 2
    case:
        _ = 0
    }
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug typeid switch ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}
