package test_spec_advanced

import "base:runtime"
import "core:testing"
import "core:fmt"
import helpers ".."

@(test)
test_debug_poly_struct :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(`package test
Container :: struct($T: typeid) {
    value: T,
}
test :: proc() {
    c: Container(int)
    c.value = 42
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug polymorphic struct ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }

    // Test const + type param
    result2 := helpers.check_source_capture_errors(`package test
Fixed_Array :: struct($N: int, $T: typeid) {
    data: [N]T,
}
test :: proc() {
    arr: Fixed_Array(10, f32)
    arr.data[0] = 1.0
}
`)
    defer helpers.destroy_test_result(&result2)
    fmt.println("=== Debug const+type param ===")
    fmt.println("Error count:", result2.error_count)
    for err in result2.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_poly_proc :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    // Test polymorphic procedure instantiation
    result := helpers.check_source_capture_errors(`package test
zero :: proc($T: typeid) -> T {
    return T{}
}
test :: proc() {
    x := zero(int)
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug polymorphic proc ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_proc_group :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    result := helpers.check_source_capture_errors(`package test
add_int :: proc(a, b: int) -> int { return a + b }
add_f32 :: proc(a, b: f32) -> f32 { return a + b }
add :: proc { add_int, add_f32 }
test :: proc() {
    x := add(1, 2)
    _ = x
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug proc group ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }

    // Test proc group with polymorphic procedure
    result2 := helpers.check_source_capture_errors(`package test
show_specific :: proc(x: int) {}
show_generic :: proc(x: $T) {}
show :: proc { show_specific, show_generic }
test :: proc() {
    show(42)
    show("test")
}
`)
    defer helpers.destroy_test_result(&result2)
    fmt.println("=== Debug proc group with poly ===")
    fmt.println("Error count:", result2.error_count)
    for err in result2.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_simple_proc_call :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    // Test simple procedure call without proc group
    result := helpers.check_source_capture_errors(`package test
add :: proc(a, b: int) -> int { return a + b }
test :: proc() {
    x := add(1, 2)
    _ = x
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug simple proc call ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}

@(test)
test_debug_no_alias :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator
    runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

    // Test #no_alias parameter flag
    result := helpers.check_source_capture_errors(`package test
copy :: proc(dst: #no_alias ^int, src: ^int) {
    dst^ = src^
}
`)
    defer helpers.destroy_test_result(&result)
    fmt.println("=== Debug #no_alias ===")
    fmt.println("Error count:", result.error_count)
    for err in result.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }

    // Test #any_int parameter flag
    result2 := helpers.check_source_capture_errors(`package test
shift :: proc(x: int, amount: #any_int int) -> int {
    return x << uint(amount)
}
`)
    defer helpers.destroy_test_result(&result2)
    fmt.println("=== Debug #any_int ===")
    fmt.println("Error count:", result2.error_count)
    for err in result2.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }

    // Test #by_ptr parameter flag
    result3 := helpers.check_source_capture_errors(`package test
BigStruct :: struct {
    data: [1000]int,
}
process :: proc(s: #by_ptr BigStruct) {
    _ = s.data[0]
}
`)
    defer helpers.destroy_test_result(&result3)
    fmt.println("=== Debug #by_ptr ===")
    fmt.println("Error count:", result3.error_count)
    for err in result3.errors {
        fmt.println("  Line", err.line, ":", err.message)
    }
}
