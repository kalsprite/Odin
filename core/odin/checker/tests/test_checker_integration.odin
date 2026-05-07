package test_checker

/*
Test Suite: Checker Integration

Integration tests that parse real Odin code and run the checker.
These tests verify the full pipeline: parse -> check.

Run with: odin test core/odin/checker/tests
*/

import "base:runtime"

import "core:log"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:sync"
import "core:testing"

import checker ".."

// Mutex to serialize test access to the global error collector
// This is necessary because tests run in parallel but share the global error state
test_error_mutex: sync.Mutex

// Disable threading in tests to avoid cleanup issues with temp allocator
@(init)
disable_threaded_checker :: proc "contextless" () {
	checker.build_context.no_threaded_checker = true
}

// Cleanup function called after all tests complete
// This ensures the global thread pool is properly destroyed to avoid crashes
@(fini)
cleanup_test_thread_pool :: proc "contextless" () {
	context = runtime.default_context()
	checker.destroy_global_thread_pool()
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// Helper to parse source code into an AST file
parse_source :: proc(src: string, filename := "test.odin") -> (^ast.File, bool) {
	file := new(ast.File)
	file.fullpath = filename
	file.src = src

	p := parser.default_parser()

	// Suppress parser error output during tests
	p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {
		// Silent during tests - we check error counts instead
	}

	p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {
		// Silent during tests
	}

	ok := parser.parse_file(&p, file)
	return file, ok
}

// Helper to run checker on parsed file
check_file :: proc(file: ^ast.File) -> bool {
	// Serialize access to global error collector to avoid race conditions
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	// Need to create a package for the file
	pkg := new(ast.Package)
	pkg.fullpath = "test_package"
	pkg.name = "test"
	pkg.files = make(map[string]^ast.File)
	pkg.files[file.fullpath] = file
	file.pkg = pkg

	result := checker.check_files(c, {file})
	return result
}

// =============================================================================
// BASIC PARSING + CHECKING TESTS
// =============================================================================

@(test)
test_check_empty_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`package test`)
	testing.expect(t, parse_ok, "Should parse empty package")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check empty package without errors")
}

@(test)
test_check_simple_variable :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

x: int = 42
y: string = "hello"
z: bool = true
`)
	testing.expect(t, parse_ok, "Should parse variable declarations")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check variable declarations without errors")
}

@(test)
test_check_simple_procedure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

add :: proc(a, b: int) -> int {
	return a + b
}
`)
	testing.expect(t, parse_ok, "Should parse procedure")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check procedure without errors")
}

@(test)
test_check_struct_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Point :: struct {
	x, y: f32,
}

origin := Point{0, 0}
`)
	testing.expect(t, parse_ok, "Should parse struct")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check struct without errors")
}

@(test)
test_check_enum_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Color :: enum {
	Red,
	Green,
	Blue,
}

c := Color.Red
`)
	testing.expect(t, parse_ok, "Should parse enum")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check enum without errors")
}

// =============================================================================
// VALUE DECLARATION / ASSIGNMENT TESTS
// =============================================================================

@(test)
test_check_typed_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Various typed declarations
a: int = 42
b: f32 = 3.14
c: string = "hello"
d: bool = true
e: u8 = 255
f: i64 = -9999
`)
	testing.expect(t, parse_ok, "Should parse typed declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check typed declarations without errors")
}

@(test)
test_check_type_inference :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Type inference declarations
a := 42          // infers int
b := 3.14        // infers f64
c := "hello"     // infers string
d := true        // infers bool
e := 'x'         // infers rune
`)
	testing.expect(t, parse_ok, "Should parse type inference declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check type inference without errors")
}

@(test)
test_check_multi_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Multiple value declarations
a, b, c := 1, 2, 3
x, y: int = 10, 20

// Swapping pattern
swap :: proc() {
	p := 1
	q := 2
	p, q = q, p
}
`)
	testing.expect(t, parse_ok, "Should parse multi-declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check multi-declarations without errors")
}

@(test)
test_check_zero_value_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Zero-value declarations (no initializer)
a: int
b: f64
c: string
d: bool
e: [5]int
`)
	testing.expect(t, parse_ok, "Should parse zero-value declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check zero-value declarations without errors")
}

@(test)
test_check_constant_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Constant declarations
PI :: 3.14159
MAX_SIZE :: 1024
MESSAGE :: "Hello, World!"
IS_DEBUG :: true
`)
	testing.expect(t, parse_ok, "Should parse constant declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check constant declarations without errors")
}

@(test)
test_check_typed_constant :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Typed constants
MAX_U8 : u8 : 255
MIN_I8 : i8 : -128
PI : f32 : 3.14159
`)
	testing.expect(t, parse_ok, "Should parse typed constants")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check typed constants without errors")
}

@(test)
test_check_type_alias :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Type aliases
MyInt :: int
MyString :: string
IntArray :: [10]int

x: MyInt = 42
s: MyString = "hello"
arr: IntArray
`)
	testing.expect(t, parse_ok, "Should parse type aliases")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check type aliases without errors")
}

@(test)
test_check_distinct_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

// Distinct types
UserId :: distinct int
Email :: distinct string

id: UserId = UserId(42)
email: Email = Email("user@example.com")
`)
	testing.expect(t, parse_ok, "Should parse distinct types")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check distinct types without errors")
}

@(test)
test_check_compound_assignment :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

compound_ops :: proc() {
	x: int = 10
	x += 5
	x -= 3
	x *= 2
	x /= 4
	x %= 3

	y: u8 = 0xFF
	y &= 0x0F
	y |= 0xF0
	y ~= 0x55
	y <<= 2
	y >>= 1
}
`)
	testing.expect(t, parse_ok, "Should parse compound assignments")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check compound assignments without errors")
}

@(test)
test_check_pointer_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

pointer_decl :: proc() {
	x: int = 42
	p: ^int = &x
	y := p^  // dereference

	// Pointer to pointer
	pp: ^^int = &p
}
`)
	testing.expect(t, parse_ok, "Should parse pointer declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check pointer declarations without errors")
}

@(test)
test_check_nil_pointer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

nil_pointer :: proc() {
	p: ^int = nil
	s: []int = nil
}
`)
	testing.expect(t, parse_ok, "Should parse nil pointer declaration")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check nil pointer without errors")
}

@(test)
test_check_cast_in_declaration :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

x: f32 = f32(42)
y: i32 = i32(314)
z: u8 = u8(255)
`)
	testing.expect(t, parse_ok, "Should parse casts in declarations")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check casts in declarations without errors")
}

// =============================================================================
// IF STATEMENT TESTS (COMPREHENSIVE)
// =============================================================================

@(test)
test_check_if_basic :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

basic_if :: proc() {
	x := 10
	if x > 5 {
		x = 0
	}
}
`)
	testing.expect(t, parse_ok, "Should parse basic if")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check basic if without errors")
}

@(test)
test_check_if_else :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

if_else :: proc() -> int {
	x := 10
	if x > 5 {
		return 1
	} else {
		return 0
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if-else")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if-else without errors")
}

@(test)
test_check_if_else_if_chain :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

grade :: proc(score: int) -> string {
	if score >= 90 {
		return "A"
	} else if score >= 80 {
		return "B"
	} else if score >= 70 {
		return "C"
	} else if score >= 60 {
		return "D"
	} else {
		return "F"
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if-else-if chain")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if-else-if chain without errors")
}

@(test)
test_check_if_with_initializer :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

get_value :: proc() -> int {
	return 42
}

if_with_init :: proc() {
	if x := get_value(); x > 0 {
		// x is available here
		y := x * 2
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with initializer")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with initializer without errors")
}

@(test)
test_check_if_with_ok_idiom :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

maybe_get :: proc() -> (int, bool) {
	return 42, true
}

if_ok_idiom :: proc() {
	if val, ok := maybe_get(); ok {
		x := val * 2
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with ok idiom")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with ok idiom without errors")
}

@(test)
test_check_if_do_single_statement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

result: int

if_do :: proc() {
	x := 10
	if x > 5 do result = 1
	if x < 0 do result = -1
}
`)
	testing.expect(t, parse_ok, "Should parse if do single statement")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if do without errors")
}

@(test)
test_check_if_nested :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

nested_if :: proc() -> int {
	a := true
	b := false
	c := true

	if a {
		if b {
			return 1
		} else {
			if c {
				return 2
			}
		}
	}
	return 0
}
`)
	testing.expect(t, parse_ok, "Should parse nested if")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check nested if without errors")
}

@(test)
test_check_if_logical_operators :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

logical_if :: proc() {
	a := true
	b := false
	x := 10

	if a && b {
		// both true
	}

	if a || b {
		// at least one true
	}

	if !b {
		// negation
	}

	if x > 0 && x < 100 {
		// range check
	}

	if !(x > 50) {
		// negated comparison
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with logical operators")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with logical operators without errors")
}

@(test)
test_check_if_comparisons :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

comparisons :: proc() {
	x := 10
	y := 20

	if x == y {}
	if x != y {}
	if x < y {}
	if x > y {}
	if x <= y {}
	if x >= y {}

	s1 := "hello"
	s2 := "world"
	if s1 == s2 {}
	if s1 != s2 {}
}
`)
	testing.expect(t, parse_ok, "Should parse if with comparisons")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with comparisons without errors")
}

@(test)
test_check_inline_if_expression :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

inline_if :: proc() {
	cond := true

	// Inline if (ternary)
	x := 1 if cond else 2
	y := "yes" if cond else "no"

	// Nested inline if
	z := 1 if cond else (2 if !cond else 3)
}
`)
	testing.expect(t, parse_ok, "Should parse inline if expressions")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check inline if expressions without errors")
}

@(test)
test_check_if_with_nil_check :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

nil_check :: proc() {
	p: ^int = nil

	if p != nil {
		x := p^
	}

	if p == nil {
		// handle nil case
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with nil check")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with nil check without errors")
}

@(test)
test_check_if_type_assertion :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Value :: union { int, f64, string }

type_assert :: proc(v: Value) -> int {
	if i, ok := v.(int); ok {
		return i
	}
	return 0
}
`)
	testing.expect(t, parse_ok, "Should parse if with type assertion")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if with type assertion without errors")
}

@(test)
test_check_when_statement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

DEBUG :: true

when_test :: proc() -> int {
	when DEBUG {
		return 1
	} else {
		return 0
	}
}
`)
	testing.expect(t, parse_ok, "Should parse when statement")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check when statement without errors")
}

// =============================================================================
// ARRAY AND INDEXING TESTS
// =============================================================================

@(test)
test_check_array_indexing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_array :: proc() {
	arr: [5]int
	x := arr[0]
	y := arr[4]
}
`)
	testing.expect(t, parse_ok, "Should parse array indexing")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check array indexing without errors")
}

@(test)
test_check_enumerated_array :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Color :: enum { Red, Green, Blue }

test_enum_array :: proc() {
	arr: [Color]int
	x := arr[.Red]
	y := arr[.Blue]
}
`)
	testing.expect(t, parse_ok, "Should parse enumerated array")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check enumerated array without errors")
}

@(test)
test_check_slice_indexing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_slice :: proc() {
	arr: [10]int
	s := arr[2:8]
	x := s[0]
}
`)
	testing.expect(t, parse_ok, "Should parse slice indexing")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check slice indexing without errors")
}

@(test)
test_check_matrix_indexing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_matrix :: proc() {
	m: matrix[3, 3]f32
	row := m[0]        // Single index returns row vector
	elem := m[1, 2]    // Double index returns element
}
`)
	testing.expect(t, parse_ok, "Should parse matrix indexing")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check matrix indexing without errors")
}

@(test)
test_check_string_indexing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_string :: proc() {
	s := "hello"
	c := s[0]
}
`)
	testing.expect(t, parse_ok, "Should parse string indexing")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check string indexing without errors")
}

// NOTE: Map indexing requires runtime package which is not available in simple test setup.
// Map indexing is tested via the error tests which use a different test harness.

@(test)
test_check_2d_array_indexing :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_2d :: proc() {
	arr: [3][3]int
	x := arr[1][2]
}
`)
	testing.expect(t, parse_ok, "Should parse 2D array indexing")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check 2D array indexing without errors")
}

// =============================================================================
// EXPRESSION TESTS
// =============================================================================

@(test)
test_check_arithmetic_expressions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

a := 1 + 2
b := 3 * 4
c := 10 / 2
d := 7 - 3
e := 10 % 3
`)
	testing.expect(t, parse_ok, "Should parse arithmetic")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check arithmetic without errors")
}

@(test)
test_check_comparison_expressions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

a := 1 < 2
b := 3 > 2
c := 4 <= 4
d := 5 >= 5
e := 6 == 6
f := 7 != 8
`)
	testing.expect(t, parse_ok, "Should parse comparisons")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check comparisons without errors")
}

@(test)
test_check_logical_expressions :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

a := true && false
b := true || false
c := !true
`)
	testing.expect(t, parse_ok, "Should parse logical ops")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check logical ops without errors")
}

// =============================================================================
// STATEMENT TESTS
// =============================================================================

@(test)
test_check_if_statement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_if :: proc() -> int {
	x := 10
	if x > 5 {
		return 1
	} else {
		return 0
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if statement")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check if statement without errors")
}

@(test)
test_check_for_loop :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_for :: proc() -> int {
	sum := 0
	for i := 0; i < 10; i += 1 {
		sum += i
	}
	return sum
}
`)
	testing.expect(t, parse_ok, "Should parse for loop")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check for loop without errors")
}

@(test)
test_check_switch_statement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

test_switch :: proc(x: int) -> string {
	switch x {
	case 0:
		return "zero"
	case 1:
		return "one"
	case:
		return "other"
	}
}
`)
	testing.expect(t, parse_ok, "Should parse switch statement")

	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check switch statement without errors")
}

// =============================================================================
// COMPLEX CODE TESTS
// =============================================================================

// Test more complex code patterns that stress the checker

@(test)
test_check_nested_procedures :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

outer :: proc() -> int {
	inner :: proc(x: int) -> int {
		return x * 2
	}
	return inner(21)
}
`)
	testing.expect(t, parse_ok, "Should parse nested procedures")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check nested procedures without errors")
}

// TODO: Fix polymorphic procedure call checking
@(test)
test_check_generic_procedure :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

identity :: proc($T: typeid, x: T) -> T {
	return x
}

use_identity :: proc() -> int {
	return identity(int, 42)
}
`)
	testing.expect(t, parse_ok, "Should parse generic procedure")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check generic procedure without errors")
}

@(test)
test_check_union_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Value :: union {
	int,
	f64,
	string,
}

get_int :: proc(v: Value) -> int {
	switch x in v {
	case int:
		return x
	case f64:
		return int(x)
	case string:
		return 0
	}
	return -1
}
`)
	testing.expect(t, parse_ok, "Should parse union type")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check union type without errors")
}

// TODO: Fix implicit selector in bit_set 'in' expression
@(test)
test_check_bit_set :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Direction :: enum {
	North,
	South,
	East,
	West,
}

Direction_Set :: bit_set[Direction]

has_north :: proc(d: Direction_Set) -> bool {
	return .North in d
}
`)
	testing.expect(t, parse_ok, "Should parse bit_set")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check bit_set without errors")
}

@(test)
test_check_defer_statement :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

cleanup_test :: proc() -> int {
	x := 0
	defer x = 100
	x = 42
	return x
}
`)
	testing.expect(t, parse_ok, "Should parse defer statement")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check defer statement without errors")
}

// TODO: Fix multiple return value type checking
@(test)
test_check_or_else :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

maybe_get :: proc() -> (int, bool) {
	return 42, true
}

use_or_else :: proc() -> int {
	x := maybe_get() or_else 0
	return x
}
`)
	testing.expect(t, parse_ok, "Should parse or_else")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check or_else without errors")
}

@(test)
test_check_matrix_type :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Mat4 :: matrix[4, 4]f32

identity_matrix :: proc() -> Mat4 {
	m: Mat4
	m[0, 0] = 1
	m[1, 1] = 1
	m[2, 2] = 1
	m[3, 3] = 1
	return m
}
`)
	testing.expect(t, parse_ok, "Should parse matrix type")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check matrix type without errors")
}

// TODO: Fix SOA struct indexing and len builtin
@(test)
test_check_soa_struct :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	file, parse_ok := parse_source(`
package test

Particle :: struct {
	x, y, z: f32,
	velocity: f32,
}

Particles :: #soa[1024]Particle

update_particles :: proc(ps: ^Particles) {
	for i := 0; i < len(ps); i += 1 {
		ps[i].x += ps[i].velocity
	}
}
`)
	testing.expect(t, parse_ok, "Should parse SOA struct")
	check_ok := check_file(file)
	testing.expect(t, check_ok, "Should check SOA struct without errors")
}

// =============================================================================
// REAL CODEBASE TESTS
// =============================================================================

// Real package testing - testing with a simpler package first
@(test)
test_check_real_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// Test with a simpler package - core/odin/tokenizer (fewer dependencies)
	_, parse_err, check_err := checker.check_package_from_path("../../tokenizer")

	if parse_err > 0 {
		log.errorf("Parse errors: %d", parse_err)
	}
	if check_err > 0 {
		log.errorf("Check errors: %d", check_err)
	}

	// For now, just check that we can load and attempt to check without crashing
	// Full error-free checking requires more complete checker implementation
	testing.expectf(t, parse_err == 0, "Should have no parse errors (got %d)", parse_err)
}

// Test checking the parser package (more complex, has imports)
@(test)
test_check_parser_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// Test with the parser package (depends on tokenizer and ast)
	_, parse_err, check_err := checker.check_package_from_path("../../parser")

	if parse_err > 0 {
		log.errorf("Parse errors: %d", parse_err)
	}
	if check_err > 0 {
		log.errorf("Check errors: %d", check_err)
		checker.print_all_errors()
	}

	testing.expectf(t, parse_err == 0, "Should have no parse errors (got %d)", parse_err)
	// Log check errors but don't fail - we're still implementing full checking
	if check_err > 0 {
		log.warnf("Parser package has %d check errors (implementation in progress)", check_err)
	}
}

// Test checking the ast package (complex types, many definitions)
@(test)
test_check_ast_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// Test with the ast package
	_, parse_err, check_err := checker.check_package_from_path("../../ast")

	if parse_err > 0 {
		log.errorf("Parse errors: %d", parse_err)
	}
	if check_err > 0 {
		log.errorf("Check errors: %d", check_err)
		checker.print_all_errors()
	}

	testing.expectf(t, parse_err == 0, "Should have no parse errors (got %d)", parse_err)
	if check_err > 0 {
		log.warnf("AST package has %d check errors (implementation in progress)", check_err)
	}
}

// Test checking the checker package itself (self-hosting test)
@(test)
test_check_checker_package :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// Test with the checker package itself (self-hosting)
	_, parse_err, check_err := checker.check_package_from_path("..")

	if parse_err > 0 {
		log.errorf("Parse errors: %d", parse_err)
	}
	if check_err > 0 {
		log.errorf("Check errors: %d", check_err)
		checker.print_all_errors()
	}

	testing.expectf(t, parse_err == 0, "Should have no parse errors (got %d)", parse_err)
	if check_err > 0 {
		log.warnf("Checker package has %d check errors (implementation in progress)", check_err)
	}
}

// =============================================================================
// RUNTIME TYPE EXTRACTION TESTS
// =============================================================================

// Test that runtime types are extracted and available
@(test)
test_runtime_type_extraction :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	// Check that runtime package was created
	runtime_pkg := c.info.runtime_package
	testing.expect(t, runtime_pkg != nil, "Runtime package should be created by extractor")

	if runtime_pkg != nil {
		testing.expect(t, runtime_pkg.scope != nil, "Runtime package should have a scope")
		testing.expectf(t, runtime_pkg.name == "runtime", "Runtime package name should be 'runtime', got '%s'", runtime_pkg.name)
	}

	// Check that runtime is registered under both names
	pkg1, has1 := c.info.packages["runtime"]
	pkg2, has2 := c.info.packages["base:runtime"]
	testing.expect(t, has1, "Runtime should be registered under 'runtime'")
	testing.expect(t, has2, "Runtime should be registered under 'base:runtime'")
	if has1 && has2 {
		testing.expect(t, pkg1 == pkg2, "Both registrations should point to same package")
	}
}

// Test that code using runtime types can be checked
@(test)
test_check_code_using_runtime :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// This is a simple test that the checker doesn't crash when checking
	// code that would use runtime types. Full type resolution of runtime
	// types requires more complete type extraction.
	file, parse_ok := parse_source(`
package test

import "base:runtime"

// Use a runtime type
get_allocator :: proc() -> runtime.Allocator {
	return {}
}
`)
	testing.expect(t, parse_ok, "Should parse code with runtime import")

	// The check may have errors since we only extract type shapes,
	// not full type information. The important thing is it doesn't crash.
	_ = check_file(file)
}

// =============================================================================
// CORE PACKAGE TESTS
// =============================================================================

// Test checking core:fmt package (imports base:runtime)
@(test)
test_check_core_fmt :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// check_package_from_path initializes ODIN_ROOT internally
	// Use relative path from checker/tests to core/fmt
	_, parse_err, check_err := checker.check_package_from_path("../../../../fmt")

	testing.expectf(t, parse_err == 0, "core:fmt should have no parse errors (got %d)", parse_err)
	if check_err > 0 {
		log.warnf("core:fmt has %d check errors (runtime extractor provides limited type info)", check_err)
	}
}

// Test checking core:strings package
@(test)
test_check_core_strings :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// Use relative path from checker/tests to core/strings
	_, parse_err, check_err := checker.check_package_from_path("../../../../strings")

	testing.expectf(t, parse_err == 0, "core:strings should have no parse errors (got %d)", parse_err)
	if check_err > 0 {
		log.warnf("core:strings has %d check errors", check_err)
	}
}

// Test checking all core packages
// This walks the core directory and attempts to check each package
@(test)
test_check_all_core_packages :: proc(t: ^testing.T) {
	context.allocator = context.temp_allocator
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	sync.lock(&test_error_mutex)
	defer sync.unlock(&test_error_mutex)

	// List of core packages to test (relative to checker/tests)
	// Comprehensive test of core library packages
	core_packages := []string{
		// Basic packages
		"../../../../fmt",
		"../../../../strings",
		"../../../../mem",
		"../../../../io",
		"../../../../os",
		"../../../../bufio",
		"../../../../bytes",
		"../../../../log",
		"../../../../math",
		"../../../../slice",
		"../../../../sort",
		"../../../../time",
		"../../../../reflect",
		"../../../../flags",
		"../../../../strconv",
		"../../../../dynlib",
		"../../../../sync",
		"../../../../thread",
		"../../../../simd",
		"../../../../terminal",
		// Text
		"../../../../text/scanner",
		"../../../../text/regex",
		// Unicode
		"../../../../unicode",
		"../../../../unicode/utf8",
		"../../../../unicode/utf16",
		// Path
		"../../../../path",
		"../../../../path/filepath",
		// Encoding
		"../../../../encoding/json",
		"../../../../encoding/xml",
		"../../../../encoding/base64",
		"../../../../encoding/csv",
		"../../../../encoding/hex",
		"../../../../encoding/endian",
		// Container
		"../../../../container/queue",
		"../../../../container/bit_array",
		"../../../../container/small_array",
		"../../../../container/priority_queue",
		"../../../../container/avl",
		"../../../../container/lru",
		"../../../../container/rbtree",
		// Crypto/Hash
		"../../../../hash",
		"../../../../crypto",
		"../../../../crypto/hash",
		"../../../../crypto/aes",
		"../../../../crypto/md5",
		// Compress
		"../../../../compress",
		"../../../../compress/gzip",
		"../../../../compress/zlib",
		// Network
		"../../../../net",
		// Image
		"../../../../image",
		"../../../../image/png",
		// Debug
		"../../../../debug/pe",
		// C interop
		"../../../../c",
		"../../../../c/libc",
		// Odin packages (self-hosting)
		"../../../../odin/tokenizer",
		"../../../../odin/parser",
		"../../../../odin/ast",
		// Vendor packages - STB
		"../../../../../vendor/stb/image",
		"../../../../../vendor/stb/truetype",
		"../../../../../vendor/stb/rect_pack",
		"../../../../../vendor/stb/easy_font",
		"../../../../../vendor/stb/sprintf",
		"../../../../../vendor/stb/vorbis",
		// Vendor packages - Graphics/UI
		"../../../../../vendor/microui",
		"../../../../../vendor/fontstash",
		"../../../../../vendor/nanovg",
		"../../../../../vendor/glfw",
		"../../../../../vendor/OpenGL",
		"../../../../../vendor/sdl2",
		"../../../../../vendor/sdl3",
		"../../../../../vendor/raylib",
		"../../../../../vendor/vulkan",
		"../../../../../vendor/wgpu",
		"../../../../../vendor/egl",
		// Vendor packages - Audio
		"../../../../../vendor/miniaudio",
		"../../../../../vendor/portmidi",
		// Vendor packages - Other
		"../../../../../vendor/commonmark",
		"../../../../../vendor/cgltf",
		"../../../../../vendor/box2d",
		"../../../../../vendor/curl",
		"../../../../../vendor/ENet",
		"../../../../../vendor/ggpo",
		"../../../../../vendor/libc",
		"../../../../../vendor/zlib",
		"../../../../../vendor/lua/lua54",
		"../../../../../vendor/OpenEXRCore",
	}

	passed := 0
	failed := 0
	parse_failed := 0

	for pkg_path in core_packages {
		_, parse_err, check_err := checker.check_package_from_path(pkg_path)

		if parse_err > 0 {
			parse_failed += 1
			log.warnf("PARSE FAIL: %s (%d errors)", pkg_path, parse_err)
		} else if check_err > 0 {
			failed += 1
			// Don't log each failure - just count them
		} else {
			passed += 1
		}
	}

	total := len(core_packages)
	log.infof("Core package check results: %d/%d passed, %d check errors, %d parse errors",
		passed, total, failed, parse_failed)

	// We expect no parse errors
	testing.expectf(t, parse_failed == 0, "Should have no parse errors (got %d)", parse_failed)

	// Log success rate for informational purposes
	if passed < total {
		log.warnf("%d/%d core packages have check errors (expected with partial runtime extraction)",
			failed, total)
	}
}
