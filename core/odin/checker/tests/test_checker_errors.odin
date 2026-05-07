package test_checker

/*
Test Suite: Checker Error Detection

Negative tests that verify the checker correctly detects errors.
These tests parse code that should fail type checking.

Run with: odin test core/odin/checker/tests
*/

import "base:runtime"

import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:sync"
import "core:testing"

import checker ".."

// =============================================================================
// HELPER - Check that errors ARE produced
// =============================================================================

// Helper to check that code produces errors
check_expects_error :: proc(src: string) -> (has_errors: bool, error_count: int) {
	file := new(ast.File)
	file.fullpath = "test_error.odin"
	file.src = src

	p := parser.default_parser()
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

	if !parser.parse_file(&p, file) {
		// Parse error - not a type error
		return false, 0
	}

	// Serialize access to global error collector to avoid race conditions
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	c := &checker.Checker{}
	checker.init_checker(c)
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

	checker.check_files(c, {file})

	count := checker.error_count()
	return count > 0, count
}

// =============================================================================
// TYPE MISMATCH ERRORS
// =============================================================================

@(test)
test_error_type_mismatch_int_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: int = "hello"  // ERROR: cannot assign string to int
`)
	testing.expect(t, has_error, "Should detect type mismatch: string to int")
}

@(test)
test_error_type_mismatch_bool_int :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: bool = 42  // ERROR: cannot assign int to bool
`)
	testing.expect(t, has_error, "Should detect type mismatch: int to bool")
}

@(test)
test_error_return_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

foo :: proc() -> int {
	return "not an int"  // ERROR: wrong return type
}
`)
	testing.expect(t, has_error, "Should detect return type mismatch")
}

// =============================================================================
// UNDEFINED IDENTIFIER ERRORS
// =============================================================================

@(test)
test_error_undefined_identifier :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x := undefined_variable  // ERROR: undefined identifier
`)
	testing.expect(t, has_error, "Should detect undefined identifier")
}

@(test)
test_error_undefined_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: UndefinedType  // ERROR: undefined type
`)
	testing.expect(t, has_error, "Should detect undefined type")
}

@(test)
test_error_undefined_procedure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	undefined_proc()  // ERROR: undefined procedure
}
`)
	testing.expect(t, has_error, "Should detect undefined procedure call")
}

// =============================================================================
// OPERATOR ERRORS
// =============================================================================

@(test)
test_error_invalid_binary_op :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x := "hello" + 42  // ERROR: cannot add string and int
`)
	testing.expect(t, has_error, "Should detect invalid binary operation")
}

@(test)
test_error_invalid_unary_op :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x := -"hello"  // ERROR: cannot negate string
`)
	testing.expect(t, has_error, "Should detect invalid unary operation")
}

// =============================================================================
// PROCEDURE CALL ERRORS
// =============================================================================

@(test)
test_error_wrong_arg_count :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

add :: proc(a, b: int) -> int {
	return a + b
}

test :: proc() {
	x := add(1)  // ERROR: too few arguments
}
`)
	testing.expect(t, has_error, "Should detect wrong argument count")
}

@(test)
test_error_wrong_arg_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

add :: proc(a, b: int) -> int {
	return a + b
}

test :: proc() {
	x := add("a", "b")  // ERROR: wrong argument types
}
`)
	testing.expect(t, has_error, "Should detect wrong argument types")
}

// =============================================================================
// REDECLARATION ERRORS
// =============================================================================

@(test)
test_error_redeclaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: int = 1
x: int = 2  // ERROR: redeclaration
`)
	testing.expect(t, has_error, "Should detect redeclaration")
}

// =============================================================================
// CONTROL FLOW ERRORS
// =============================================================================

@(test)
test_error_non_bool_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if 42 {  // ERROR: condition must be bool
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect non-bool condition")
}

// =============================================================================
// STRUCT FIELD ERRORS
// =============================================================================

@(test)
test_error_undefined_field :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Point :: struct {
	x, y: f32,
}

test :: proc() {
	p := Point{}
	z := p.z  // ERROR: undefined field 'z'
}
`)
	testing.expect(t, has_error, "Should detect undefined struct field")
}

// =============================================================================
// BREAK/CONTINUE ERRORS
// =============================================================================

@(test)
test_error_break_outside_loop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	break  // ERROR: break outside loop
}
`)
	testing.expect(t, has_error, "Should detect break outside loop")
}

@(test)
test_error_continue_outside_loop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	continue  // ERROR: continue outside loop
}
`)
	testing.expect(t, has_error, "Should detect continue outside loop")
}

// =============================================================================
// INDEXING ERRORS
// =============================================================================

@(test)
test_error_index_non_indexable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	y := x[0]  // ERROR: cannot index int
}
`)
	testing.expect(t, has_error, "Should detect indexing non-indexable type")
}

@(test)
test_error_index_wrong_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr["hello"]  // ERROR: index must be integer
}
`)
	testing.expect(t, has_error, "Should detect non-integer index")
}

@(test)
test_error_index_with_float :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr[1.5]  // ERROR: index must be integer, not float
}
`)
	testing.expect(t, has_error, "Should detect float index")
}

@(test)
test_error_index_with_bool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr[true]  // ERROR: index must be integer, not bool
}
`)
	testing.expect(t, has_error, "Should detect bool index")
}

@(test)
test_error_index_negative_constant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr[-1]  // ERROR: negative index
}
`)
	testing.expect(t, has_error, "Should detect negative constant index")
}

@(test)
test_error_index_out_of_bounds_constant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr[10]  // ERROR: index 10 out of bounds for [5]int
}
`)
	testing.expect(t, has_error, "Should detect out of bounds constant index")
}

@(test)
test_error_index_exactly_at_length :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	x := arr[5]  // ERROR: index 5 out of bounds (valid: 0..4)
}
`)
	testing.expect(t, has_error, "Should detect index exactly at array length")
}

// =============================================================================
// ENUMERATED ARRAY INDEXING ERRORS
// =============================================================================

@(test)
test_error_enum_array_wrong_enum_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Color :: enum { Red, Green, Blue }
Size :: enum { Small, Medium, Large }

test :: proc() {
	arr: [Color]int
	x := arr[.Small]  // ERROR: expected Color, got Size
}
`)
	testing.expect(t, has_error, "Should detect wrong enum type for enumerated array index")
}

@(test)
test_error_enum_array_integer_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Color :: enum { Red, Green, Blue }

test :: proc() {
	arr: [Color]int
	x := arr[0]  // ERROR: enumerated array requires enum index, not integer
}
`)
	testing.expect(t, has_error, "Should detect integer index for enumerated array")
}

// NOTE: Using enum index on regular array (arr[Color.Red]) is valid in Odin
// because enums have integer backing values. No test needed.

// =============================================================================
// SLICE INDEXING ERRORS
// =============================================================================

@(test)
test_error_slice_index_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	s: []int
	x := s["hello"]  // ERROR: slice index must be integer
}
`)
	testing.expect(t, has_error, "Should detect string index for slice")
}

@(test)
test_error_slice_range_wrong_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [10]int
	s := arr["a":"b"]  // ERROR: slice range indices must be integers
}
`)
	testing.expect(t, has_error, "Should detect non-integer slice range")
}

@(test)
test_error_slice_negative_start :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [10]int
	s := arr[-1:5]  // ERROR: negative slice start
}
`)
	testing.expect(t, has_error, "Should detect negative slice start index")
}

// =============================================================================
// DYNAMIC ARRAY INDEXING ERRORS
// =============================================================================

@(test)
test_error_dynamic_array_string_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [dynamic]int
	x := arr["hello"]  // ERROR: dynamic array index must be integer
}
`)
	testing.expect(t, has_error, "Should detect string index for dynamic array")
}

// =============================================================================
// STRING INDEXING ERRORS
// =============================================================================

@(test)
test_error_string_float_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	s := "hello"
	c := s[1.5]  // ERROR: string index must be integer
}
`)
	testing.expect(t, has_error, "Should detect float index for string")
}

@(test)
test_error_string_negative_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	s := "hello"
	c := s[-1]  // ERROR: negative string index
}
`)
	testing.expect(t, has_error, "Should detect negative string index")
}

// =============================================================================
// MAP INDEXING ERRORS
// =============================================================================

@(test)
test_error_map_wrong_key_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	m: map[string]int
	x := m[42]  // ERROR: map key type mismatch, expected string
}
`)
	testing.expect(t, has_error, "Should detect wrong map key type")
}

@(test)
test_error_map_incompatible_key :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	m: map[int]string
	x := m["hello"]  // ERROR: map key type mismatch, expected int
}
`)
	testing.expect(t, has_error, "Should detect incompatible map key")
}

// =============================================================================
// MULTI-DIMENSIONAL ARRAY ERRORS
// =============================================================================

// NOTE: Matrix single index (m[0]) is valid in Odin - returns a row/column vector.

@(test)
test_error_matrix_string_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	m: matrix[3, 3]f32
	x := m["a", "b"]  // ERROR: matrix indices must be integers
}
`)
	testing.expect(t, has_error, "Should detect string indices for matrix")
}

@(test)
test_error_2d_array_string_indices :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [3][3]int
	x := arr["a"]["b"]  // ERROR: array indices must be integers
}
`)
	testing.expect(t, has_error, "Should detect string indices for 2D array")
}

@(test)
test_error_nested_array_out_of_bounds :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [3][3]int
	x := arr[0][5]  // ERROR: inner index out of bounds
}
`)
	testing.expect(t, has_error, "Should detect out of bounds in nested array")
}

// =============================================================================
// POINTER INDEXING ERRORS
// =============================================================================

@(test)
test_error_pointer_string_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	p := &arr[0]
	x := p["hello"]  // ERROR: pointer index must be integer
}
`)
	testing.expect(t, has_error, "Should detect string index for pointer")
}

@(test)
test_error_multi_pointer_string_index :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	arr: [5]int
	p: [^]int = &arr[0]
	x := p["hello"]  // ERROR: multi-pointer index must be integer
}
`)
	testing.expect(t, has_error, "Should detect string index for multi-pointer")
}

// =============================================================================
// ARRAY ERRORS
// =============================================================================

@(test)
test_error_array_too_many_elements :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

arr: [3]int = {1, 2, 3, 4, 5}  // ERROR: too many elements
`)
	testing.expect(t, has_error, "Should detect too many array elements")
}

@(test)
test_error_array_element_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

arr: [3]int = {1, "hello", 3}  // ERROR: element type mismatch
`)
	testing.expect(t, has_error, "Should detect array element type mismatch")
}

// =============================================================================
// ENUM ERRORS
// =============================================================================

@(test)
test_error_invalid_enum_member :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Color :: enum { Red, Green, Blue }

test :: proc() {
	c: Color = .Yellow  // ERROR: Yellow is not a member of Color
}
`)
	testing.expect(t, has_error, "Should detect invalid enum member")
}

// =============================================================================
// POINTER ERRORS
// =============================================================================

@(test)
test_error_deref_non_pointer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	y := x^  // ERROR: cannot dereference non-pointer
}
`)
	testing.expect(t, has_error, "Should detect dereference of non-pointer")
}

// =============================================================================
// STRUCT LITERAL ERRORS
// =============================================================================

@(test)
test_error_struct_unknown_field_in_literal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Point :: struct { x, y: int }

p := Point{ x = 1, y = 2, z = 3 }  // ERROR: unknown field z
`)
	testing.expect(t, has_error, "Should detect unknown field in struct literal")
}

@(test)
test_error_struct_field_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Point :: struct { x, y: int }

p := Point{ x = "hello", y = 2 }  // ERROR: field type mismatch
`)
	testing.expect(t, has_error, "Should detect struct field type mismatch")
}

// =============================================================================
// SCOPE ERRORS
// =============================================================================

@(test)
test_error_use_after_scope :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() -> int {
	{
		x := 42
	}
	return x  // ERROR: x is not in scope
}
`)
	testing.expect(t, has_error, "Should detect use of variable after scope ends")
}

// =============================================================================
// ASSIGNMENT ERRORS
// =============================================================================

@(test)
test_error_assign_to_constant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

X :: 42

test :: proc() {
	X = 100  // ERROR: cannot assign to constant
}
`)
	testing.expect(t, has_error, "Should detect assignment to constant")
}

// =============================================================================
// CALL EXPRESSION ERRORS
// =============================================================================

@(test)
test_error_call_non_procedure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: int = 42

test :: proc() {
	x()  // ERROR: cannot call non-procedure
}
`)
	testing.expect(t, has_error, "Should detect calling non-procedure")
}

// =============================================================================
// COMPARISON ERRORS
// =============================================================================

@(test)
test_error_compare_incompatible_types :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() -> bool {
	return "hello" < 42  // ERROR: cannot compare string and int
}
`)
	testing.expect(t, has_error, "Should detect comparison of incompatible types")
}

// =============================================================================
// SLICE ERRORS
// =============================================================================

@(test)
test_error_slice_non_sliceable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	s := x[0:5]  // ERROR: cannot slice int
}
`)
	testing.expect(t, has_error, "Should detect slicing non-sliceable type")
}

// =============================================================================
// VALUE DECLARATION / ASSIGNMENT ERRORS
// =============================================================================

@(test)
test_error_decl_wrong_number_multi_assign :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	a, b := 1, 2, 3  // ERROR: wrong number of values
}
`)
	testing.expect(t, has_error, "Should detect wrong number in multi-assignment")
}

@(test)
test_error_decl_too_few_values :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	a, b, c := 1, 2  // ERROR: too few values for declaration
}
`)
	testing.expect(t, has_error, "Should detect too few values in declaration")
}

@(test)
test_error_decl_untyped_nil :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x := nil  // ERROR: cannot infer type from untyped nil
}
`)
	testing.expect(t, has_error, "Should detect untyped nil inference")
}

@(test)
test_error_decl_assign_nil_to_int :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

x: int = nil  // ERROR: cannot assign nil to int
`)
	testing.expect(t, has_error, "Should detect nil assigned to non-pointer type")
}

@(test)
test_error_decl_compound_assign_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	x += "hello"  // ERROR: cannot add string to int
}
`)
	testing.expect(t, has_error, "Should detect compound assignment type mismatch")
}

@(test)
test_error_decl_assign_proc_to_int :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

foo :: proc() {}
x: int = foo  // ERROR: cannot assign procedure to int
`)
	testing.expect(t, has_error, "Should detect procedure assigned to int")
}

@(test)
test_error_decl_struct_to_int :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Point :: struct { x, y: int }

p: int = Point{1, 2}  // ERROR: cannot assign struct to int
`)
	testing.expect(t, has_error, "Should detect struct assigned to int")
}

@(test)
test_error_decl_enum_to_string :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Color :: enum { Red, Green, Blue }

c: string = Color.Red  // ERROR: cannot assign enum to string
`)
	testing.expect(t, has_error, "Should detect enum assigned to string")
}

@(test)
test_error_decl_array_to_slice_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

arr: [5]int = {1, 2, 3, 4, 5}
s: []string = arr[:]  // ERROR: cannot convert []int to []string
`)
	testing.expect(t, has_error, "Should detect slice element type mismatch")
}

@(test)
test_error_assign_to_literal :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	42 = 100  // ERROR: cannot assign to literal
}
`)
	testing.expect(t, has_error, "Should detect assignment to literal")
}

@(test)
test_error_assign_to_expression :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x := 1
	y := 2
	x + y = 10  // ERROR: cannot assign to expression
}
`)
	testing.expect(t, has_error, "Should detect assignment to expression")
}

@(test)
test_error_assign_to_proc_call :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

foo :: proc() -> int { return 42 }

test :: proc() {
	foo() = 100  // ERROR: cannot assign to procedure call
}
`)
	testing.expect(t, has_error, "Should detect assignment to procedure call")
}

@(test)
test_error_decl_distinct_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

MyInt :: distinct int

x: int = 42
y: MyInt = x  // ERROR: cannot assign int to distinct MyInt
`)
	testing.expect(t, has_error, "Should detect distinct type mismatch")
}

@(test)
test_error_decl_incompatible_pointer_types :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	y: string = "hello"
	p: ^int = &y  // ERROR: cannot assign ^string to ^int
}
`)
	testing.expect(t, has_error, "Should detect incompatible pointer types")
}

// =============================================================================
// IF STATEMENT ERRORS
// =============================================================================

@(test)
test_error_if_string_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if "hello" {  // ERROR: condition must be bool, not string
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect string as if condition")
}

@(test)
test_error_if_float_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if 3.14 {  // ERROR: condition must be bool, not f64
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect float as if condition")
}

@(test)
test_error_if_pointer_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = 42
	p := &x
	if p {  // ERROR: condition must be bool, not ^int (Odin requires explicit nil check)
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect pointer as if condition (requires explicit nil check)")
}

@(test)
test_error_if_struct_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

Point :: struct { x, y: int }

test :: proc() {
	p := Point{1, 2}
	if p {  // ERROR: condition must be bool, not struct
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect struct as if condition")
}

@(test)
test_error_if_initializer_not_bool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if x := 42; x {  // ERROR: x is int, not bool
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect non-bool variable as condition after initializer")
}

@(test)
test_error_if_undefined_in_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if undefined > 0 {  // ERROR: undefined identifier
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect undefined identifier in if condition")
}

@(test)
test_error_if_undefined_in_else :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x := 10
	if x > 5 {
		y := 20
	} else {
		z := y  // ERROR: y not defined in this branch
	}
}
`)
	testing.expect(t, has_error, "Should detect use of variable from other if branch")
}

@(test)
test_error_inline_if_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x: int = "hello" if true else 42  // ERROR: type mismatch in ternary
}
`)
	testing.expect(t, has_error, "Should detect type mismatch in inline if branches")
}

@(test)
test_error_inline_if_non_bool_condition :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x := 1 if 42 else 2  // ERROR: condition must be bool
}
`)
	testing.expect(t, has_error, "Should detect non-bool condition in inline if")
}

@(test)
test_error_else_if_non_bool :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	x := 10
	if x > 5 {
		// ...
	} else if "yes" {  // ERROR: else if condition must be bool
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect non-bool in else if condition")
}

@(test)
test_error_if_comparison_type_mismatch :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	has_error, _ := check_expects_error(`
package test

test :: proc() {
	if 42 > "hello" {  // ERROR: cannot compare int and string
		// ...
	}
}
`)
	testing.expect(t, has_error, "Should detect comparison type mismatch in if")
}
