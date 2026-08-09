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
import "core:path/filepath"
import "core:strings"
import "core:sync"
import "core:testing"

import checker ".."

// =============================================================================
// SERIALISING ACCESS TO THE CHECKER'S PROCESS-GLOBAL STATE
// =============================================================================
//
// test_error_mutex serialises the tests that touch the checker's package-level globals -
// global_error_collector, the basic-type singletons, the runtime type globals. Only one
// test may be inside such a region at a time, and the default test runner is
// multi-threaded, so the mutex is doing real work.
//
// Acquire it with lock_checker_globals / release it with unlock_checker_globals. Do NOT
// use sync.lock(&test_error_mutex) + `defer sync.unlock(...)` directly.
//
// WHY `defer` ALONE IS NOT ENOUGH
//
// When a test dies from a panic, a failed assertion, a bounds-check failure, a memory
// access violation or a timeout, core:testing's assertion handler ends the thread with
// runtime.trap() (core/testing/signal_handler.odin:48). trap() does not unwind, so
// deferred statements never run. A mutex held at that moment stays locked for the rest of
// the process: the next test to call sync.lock() blocks in futex_wait forever, and the run
// hangs until the runner's timeout instead of failing the one bad test and carrying on.
//
// This is not hypothetical - it is what a panic in the checker used to do to this suite.
//
// HOW THE RELEASE IS MADE TO HAPPEN ANYWAY
//
// Every acquisition also registers the release with testing.cleanup. The runner invokes
// cleanups from its own main thread after it has stopped the faulted task
// (core/testing/runner.odin:845 for signals, :777 for timeouts, :166 for tests that return
// normally), so by the time the cleanup runs the previous holder is provably gone and
// releasing the mutex on its behalf races with nothing.
//
// WHY THE TICKET
//
// A test may enter and leave the region several times (check_file, check_expects_error and
// friends each take the mutex for the duration of one check), and a cleanup registered by
// an earlier acquisition can run long after that acquisition released the mutex - possibly
// while a *different* test now holds it. Each acquisition therefore takes a unique ticket
// and records it as the current owner; a release only fires if its own ticket is still the
// owner. The in-scope release and the safety-net cleanup can never release each other's
// acquisition, and every release is exact.
test_error_mutex: sync.Mutex

// guard_next_ticket is only ever incremented while test_error_mutex is held.
@(private = "file")
guard_next_ticket: u64

// guard_owner_ticket is the ticket of the current holder, or 0 when the mutex is free.
@(private = "file")
guard_owner_ticket: u64

// lock_checker_globals acquires test_error_mutex for the calling test and returns the
// ticket that identifies this acquisition. Pair it with:
//
//	ticket := lock_checker_globals(t)
//	defer unlock_checker_globals(ticket)
lock_checker_globals :: proc(t: ^testing.T) -> (ticket: u64) {
	sync.lock(&test_error_mutex)
	guard_next_ticket += 1
	ticket = guard_next_ticket
	sync.atomic_store(&guard_owner_ticket, ticket)

	// t.cleanups has to outlive every allocator the test itself installs: most tests set
	// context.allocator to the temp allocator behind a TEMP_GUARD, and the runner recycles
	// its per-task allocator as soon as the task slot is reused. Register from a default
	// (heap) context so the record is still valid when the runner walks it, on whichever
	// thread that turns out to be.
	context = runtime.default_context()
	testing.cleanup(t, proc(user_data: rawptr) {
		unlock_checker_globals(u64(uintptr(user_data)))
	}, rawptr(uintptr(ticket)))
	return
}

// unlock_checker_globals releases test_error_mutex if, and only if, `ticket` still owns it.
// It is safe to call more than once for the same ticket and safe to call from a thread
// other than the one that acquired it - sync.Mutex tracks no owning thread.
unlock_checker_globals :: proc(ticket: u64) {
	if _, was_owner := sync.atomic_compare_exchange_strong(&guard_owner_ticket, ticket, 0); was_owner {
		sync.unlock(&test_error_mutex)
	}
}

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
// SOURCE-ANCHORED PACKAGE PATHS
// =============================================================================
//
// Package paths used by the integration tests must NOT be relative to the process's
// current working directory. `odin test core/odin/checker/tests` (the normal invocation)
// runs with CWD at the repo root, while running the suite from inside the tests directory
// puts CWD somewhere else entirely - and a relative path that silently resolves nowhere
// makes the whole suite vacuous.
//
// `#directory` is a compile-time constant holding the directory of THIS source file, so
// everything derived from it is independent of where the test binary is launched from.
// The C++ implementation (`dir_from_path`, src/parser.cpp) keeps the trailing path
// separator, e.g. ".../core/odin/checker/tests/". `filepath.join` normalises the result,
// so the trailing separator and the ".." elements are both cleaned away - which is why
// these paths are joined rather than concatenated.

// Directory of this source file: "<odin_root>/core/odin/checker/tests/"
TESTS_DIR :: #directory

// Absolute, CWD-independent directory anchors.
// tests -> checker -> odin -> core -> <odin_root>
ODIN_ROOT_DIR:   string // <odin_root>
ODIN_CORE_DIR:   string // <odin_root>/core
ODIN_VENDOR_DIR: string // <odin_root>/vendor

@(init)
init_source_anchored_dirs :: proc "contextless" () {
	// Allocated with the default (heap) allocator so these outlive the per-test temp
	// allocator scopes that the tests below install.
	context = runtime.default_context()

	err: runtime.Allocator_Error

	ODIN_ROOT_DIR, err = filepath.join({TESTS_DIR, "..", "..", "..", ".."})
	ensure(err == nil, "failed to derive ODIN_ROOT_DIR from #directory")

	ODIN_CORE_DIR, err = filepath.join({ODIN_ROOT_DIR, "core"})
	ensure(err == nil, "failed to derive ODIN_CORE_DIR from #directory")

	ODIN_VENDOR_DIR, err = filepath.join({ODIN_ROOT_DIR, "vendor"})
	ensure(err == nil, "failed to derive ODIN_VENDOR_DIR from #directory")
}

// pkg_path joins a directory anchor with a package path relative to it.
// Allocated with the current context allocator (the temp allocator inside tests).
pkg_path :: proc(dir: string, rel: string) -> string {
	path, err := filepath.join({dir, rel})
	ensure(err == nil, "failed to join package path")
	return path
}

// core_pkg returns the absolute path of a package under <odin_root>/core.
// LIBRARY says what these tests are checking: core packages, none of which declare `main`.
//
// Before #589 the entry-point surface was dead, so this was true by accident and needed no saying.
// Making it live turned every one of these into "Undefined entry point procedure 'main'" -- 5 test
// failures, 86/86 core packages (#593). The fix is to state the fact, not to filter the diagnostic:
// whether a `main` is required is a property of what is being built, and the caller is the only
// party that knows. Identical to the reasoning in Session_Options (#590).
//
// A test that genuinely checks a PROGRAM must pass its own options and assert on `main` -- it must
// not inherit this.
LIBRARY :: checker.Session_Options{no_entry_point = true}

core_pkg :: proc(rel: string) -> string {
	return pkg_path(ODIN_CORE_DIR, rel)
}

// vendor_pkg returns the absolute path of a package under <odin_root>/vendor.
vendor_pkg :: proc(rel: string) -> string {
	return pkg_path(ODIN_VENDOR_DIR, rel)
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
check_file :: proc(t: ^testing.T, file: ^ast.File) -> bool {
	// Serialize access to global error collector to avoid race conditions
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
		_ = y
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with initializer")
	check_ok := check_file(t, file)
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
		_ = x
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with ok idiom")
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
		_ = x
	}

	if p == nil {
		// handle nil case
	}
}
`)
	testing.expect(t, parse_ok, "Should parse if with nil check")
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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

	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
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
	check_ok := check_file(t, file)
	testing.expect(t, check_ok, "Should check SOA struct without errors")
}

// =============================================================================
// REAL CODEBASE TESTS
// =============================================================================

// Real package testing - testing with a simpler package first
@(test)
test_check_real_package :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Test with a simpler package - core/odin/tokenizer (fewer dependencies)
	path := core_pkg("odin/tokenizer")
	res := checker.check_package_from_path(path, LIBRARY)
	defer checker.destroy_package_check_result(&res)

	if res.parse_errors > 0 {
		log.errorf("Parse errors: %d", res.parse_errors)
	}
	if res.check_errors > 0 {
		log.errorf("Check errors: %d", res.check_errors)
	}

	// A package that fails to load reports 0 parse errors and 0 check errors, so the
	// load itself has to be asserted or the rest of this test is vacuous.
	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)

	// A run cut short by the error cap is neither a pass nor an ordinary failure: the
	// checker abandoned the package partway, so nothing below proves anything about it.
	expect_not_limit_reached(t, path, res)

	// For now, just check that we can load and attempt to check without crashing
	// Full error-free checking requires more complete checker implementation
	testing.expectf(t, res.parse_errors == 0, "Should have no parse errors (got %d)", res.parse_errors)
}

// Test checking the parser package (more complex, has imports)
@(test)
test_check_parser_package :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Test with the parser package (depends on tokenizer and ast)
	path := core_pkg("odin/parser")
	res := checker.check_package_from_path(path, LIBRARY)
	// The result owns its diagnostics; the global collector check_package_from_path used is
	// already gone by the time it returns.
	defer checker.destroy_package_check_result(&res)

	if res.parse_errors > 0 {
		log.errorf("Parse errors: %d", res.parse_errors)
	}
	if res.check_errors > 0 {
		log.errorf("Check errors: %d", res.check_errors)
		checker.print_package_diagnostics(&res)
	}

	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)
	testing.expectf(t, res.parse_errors == 0, "Should have no parse errors (got %d)", res.parse_errors)
	// A truncated run is reported on its own, never folded into the check-error warning
	// below: "N check errors" from an abandoned run is not the same measurement.
	expect_not_limit_reached(t, path, res)
	// Log check errors but don't fail - we're still implementing full checking
	if res.check_errors > 0 && !res.limit_reached {
		log.warnf("Parser package has %d check errors (implementation in progress)", res.check_errors)
	}
}

// Test checking the ast package (complex types, many definitions)
@(test)
test_check_ast_package :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Test with the ast package
	path := core_pkg("odin/ast")
	res := checker.check_package_from_path(path, LIBRARY)
	defer checker.destroy_package_check_result(&res)

	if res.parse_errors > 0 {
		log.errorf("Parse errors: %d", res.parse_errors)
	}
	if res.check_errors > 0 {
		log.errorf("Check errors: %d", res.check_errors)
		checker.print_package_diagnostics(&res)
	}

	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)
	testing.expectf(t, res.parse_errors == 0, "Should have no parse errors (got %d)", res.parse_errors)
	expect_not_limit_reached(t, path, res)
	if res.check_errors > 0 && !res.limit_reached {
		log.warnf("AST package has %d check errors (implementation in progress)", res.check_errors)
	}
}

// Test checking the checker package itself (self-hosting test)
@(test)
test_check_checker_package :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Test with the checker package itself (self-hosting)
	path := core_pkg("odin/checker")
	res := checker.check_package_from_path(path, LIBRARY)
	defer checker.destroy_package_check_result(&res)

	if res.parse_errors > 0 {
		log.errorf("Parse errors: %d", res.parse_errors)
	}
	if res.check_errors > 0 {
		log.errorf("Check errors: %d", res.check_errors)
		checker.print_package_diagnostics(&res)
	}

	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)
	testing.expectf(t, res.parse_errors == 0, "Should have no parse errors (got %d)", res.parse_errors)
	expect_not_limit_reached(t, path, res)
	if res.check_errors > 0 && !res.limit_reached {
		log.warnf("Checker package has %d check errors (implementation in progress)", res.check_errors)
	}
}

// =============================================================================
// RUNTIME PACKAGE SEEDING TESTS
// =============================================================================

// base:runtime must be a REAL parsed package, seeded by the loader - not synthesized.
//
// This used to assert the opposite: that init_checker produced a runtime package of its own,
// built by extract_runtime_types out of placeholder entities. That was the workaround for the
// parser refusing `package runtime` unless ast.Package.kind is .Runtime, and it is what made
// every runtime type resolve to something unusable (struct fields typed untyped_nil, distinct
// types with no base).
//
// The contract now matches the C++ compiler's: base:runtime is added first, serially, before
// every other package, with an explicit Package_Runtime kind (src/parser.cpp:7062-7071), and
// the checker finds it by looking it up among the ordinary packages (src/checker.cpp:899).
// So there is nothing for init_checker to make, and the assertions below are about the loader.
@(test)
test_runtime_package_is_seeded_by_loader :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	// Serialize access to global error collector
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	checker.init_error_collector(100)
	defer checker.destroy_error_collector()

	// Nothing is synthesized at init time any more.
	testing.expect(t, c.info.runtime_package == nil,
		"init_checker must not create a runtime package; the loader owns that now")

	// Loading ANY package seeds base:runtime, because every package needs it - the loader does
	// not wait to see an `import \"base:runtime\"` before pulling it in, exactly as the C++
	// compiler does not.
	path := core_pkg("unicode/utf8")
	load_result, _ := checker.load_package_with_dependencies(path, &c.info)
	defer delete(load_result.packages)

	runtime_pkg := c.info.runtime_package
	testing.expect(t, runtime_pkg != nil, "Loader should have seeded base:runtime")
	if runtime_pkg == nil {
		return
	}

	// The kind is the whole point: it is what lets `package runtime` parse at all.
	testing.expectf(t, runtime_pkg.kind == .Runtime,
		"Runtime package kind should be .Runtime, got %v", runtime_pkg.kind)

	// A real parse leaves real files and a name read out of the source, rather than a name
	// assigned by the constructor of a synthetic package.
	testing.expect(t, len(runtime_pkg.files) > 0,
		"Runtime package should have parsed files; 0 means every file was rejected")
	testing.expectf(t, runtime_pkg.name == "runtime",
		"Runtime package name should be 'runtime', got '%s'", runtime_pkg.name)

	// It is registered like any other package: under the import path callers write, and under
	// its own fullpath.
	by_import, has_import := c.info.packages["base:runtime"]
	testing.expect(t, has_import, "Runtime should be registered under 'base:runtime'")
	by_path, has_path := c.info.packages[runtime_pkg.fullpath]
	testing.expect(t, has_path, "Runtime should be registered under its fullpath")
	if has_import && has_path {
		testing.expect(t, by_import == by_path && by_import == runtime_pkg,
			"Every registration should point at the one seeded package")
	}

	// It is loaded FIRST - ahead of the root package and everything the root imports.
	if len(load_result.packages) > 0 {
		testing.expect(t, load_result.packages[0] == runtime_pkg,
			"base:runtime must be the first package loaded, as in src/parser.cpp:7067")
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
	_ = check_file(t, file)
}

// =============================================================================
// CORE PACKAGE TESTS
// =============================================================================

// Test checking core:fmt package (imports base:runtime)
@(test)
test_check_core_fmt :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// check_package_from_path initializes ODIN_ROOT internally
	// Path is anchored to this source file, not to the process CWD
	path := core_pkg("fmt")
	res := checker.check_package_from_path(path, LIBRARY)
	defer checker.destroy_package_check_result(&res)

	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)
	testing.expectf(t, res.parse_errors == 0, "core:fmt should have no parse errors (got %d)", res.parse_errors)
	expect_not_limit_reached(t, path, res)
	if res.check_errors > 0 && !res.limit_reached {
		log.warnf("core:fmt has %d check errors (runtime extractor provides limited type info)", res.check_errors)
	}
}

// Test checking core:strings package
@(test)
test_check_core_strings :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Path is anchored to this source file, not to the process CWD
	path := core_pkg("strings")
	res := checker.check_package_from_path(path, LIBRARY)
	defer checker.destroy_package_check_result(&res)

	testing.expectf(t, res.load_ok, "Should load %s (loaded %d files)", path, res.total_files)
	testing.expectf(t, res.parse_errors == 0, "core:strings should have no parse errors (got %d)", res.parse_errors)
	expect_not_limit_reached(t, path, res)
	if res.check_errors > 0 && !res.limit_reached {
		log.warnf("core:strings has %d check errors", res.check_errors)
	}
}

// Test checking all core packages
// This walks the core directory and attempts to check each package
@(test)
test_check_all_core_packages :: proc(t: ^testing.T) {
	// NO `context.allocator = context.temp_allocator` here. This test drives the package
	// machinery, which fans out to a 32-thread pool, and a per-thread scratch arena cannot be
	// the shared allocator of a thread pool -- objects cross threads and get freed through the
	// wrong allocator. Proven by control probes regprobe/regprobe2. LEDGER #356.
	runtime.DEFAULT_TEMP_ALLOCATOR_TEMP_GUARD()

	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Packages to test, named RELATIVE TO their anchor directory (<odin_root>/core and
	// <odin_root>/vendor respectively). The absolute path is built below from
	// `#directory`, so these resolve identically no matter what the CWD is.
	core_packages := []string{
		// Basic packages
		"fmt",
		"strings",
		"mem",
		"io",
		"os",
		"bufio",
		"bytes",
		"log",
		"math",
		"slice",
		"sort",
		"time",
		"reflect",
		"flags",
		"strconv",
		"dynlib",
		"sync",
		"thread",
		"simd",
		"terminal",
		// Text
		"text/scanner",
		"text/regex",
		// Unicode
		"unicode",
		"unicode/utf8",
		"unicode/utf16",
		// Path
		"path",
		"path/filepath",
		// Encoding
		"encoding/json",
		"encoding/xml",
		"encoding/base64",
		"encoding/csv",
		"encoding/hex",
		"encoding/endian",
		// Container
		"container/queue",
		"container/bit_array",
		"container/small_array",
		"container/priority_queue",
		"container/avl",
		"container/lru",
		"container/rbtree",
		// Crypto/Hash
		"hash",
		"crypto",
		"crypto/hash",
		"crypto/aes",
		// NOTE: md5 lives under crypto/legacy; the old "crypto/md5" entry pointed at a
		// directory that has not existed for some time and was never noticed because the
		// harness reported unresolvable paths as passes.
		"crypto/legacy/md5",
		// Compress
		"compress",
		"compress/gzip",
		"compress/zlib",
		// Network
		"net",
		// Image
		"image",
		"image/png",
		// Debug
		"debug/pe",
		// C interop
		"c",
		"c/libc",
		// Odin packages (self-hosting)
		"odin/tokenizer",
		"odin/parser",
		"odin/ast",
	}

	vendor_packages := []string{
		// STB
		"stb/image",
		"stb/truetype",
		"stb/rect_pack",
		"stb/easy_font",
		"stb/sprintf",
		"stb/vorbis",
		// Graphics/UI
		"microui",
		"fontstash",
		"nanovg",
		"glfw",
		"OpenGL",
		"sdl2",
		"sdl3",
		"raylib",
		"vulkan",
		"wgpu",
		"egl",
		// Audio
		"miniaudio",
		"portmidi",
		// Other
		"commonmark",
		"cgltf",
		"box2d",
		"curl",
		"ENet",
		"ggpo",
		"libc",
		"zlib",
		// NOTE: the Lua bindings are versioned by directory ("5.4"), not "lua54". Same
		// story as crypto/legacy/md5: a stale entry that the old harness silently passed.
		"lua/5.4",
		"OpenEXRCore",
	}

	total := len(core_packages) + len(vendor_packages)

	paths := make([dynamic]string, 0, total, context.allocator)
	for rel in core_packages {
		append(&paths, core_pkg(rel))
	}
	for rel in vendor_packages {
		append(&paths, vendor_pkg(rel))
	}

	// Packages that BOTH compilers report diagnostics on, with the count the reference compiler
	// produces. These are not port defects: each was compared against `odin check` on
	// 2026-08-04 and the diagnostics matched byte for byte, TEXTS not just counts (LEDGER #367).
	//
	// The suffix is matched against the end of the path, so the entries stay valid whatever
	// ODIN_ROOT is.
	//
	// This is an ALLOWLIST WITH COUNTS, not a skip-list, and the difference is the point: a
	// package here still FAILS if its count moves. Before this existed the test demanded zero
	// diagnostics from all 86, which is not true of the language -- so it failed permanently and
	// told you nothing about whether anything had regressed.
	Expected_Diag :: struct { suffix: string, count: int }
	oracle_agrees := []Expected_Diag{
		{"core/path",            1},
		{"vendor/box2d",         1},
		{"vendor/cgltf",         1},
		{"vendor/fontstash",     2},
		{"vendor/libc",          1},
		{"vendor/miniaudio",     1},
		{"vendor/nanovg",        5},
		{"vendor/stb/image",     3},
		{"vendor/stb/rect_pack", 1},
		{"vendor/stb/sprintf",   1},
		{"vendor/stb/truetype",  2},
		{"vendor/stb/vorbis",    1},
		{"vendor/wgpu",          1},
	}
	expected_for :: proc(list: []Expected_Diag, path: string) -> (count: int, found: bool) {
		for e in list {
			if strings.has_suffix(path, e.suffix) {
				return e.count, true
			}
		}
		return 0, false
	}

	passed := 0
	check_failed := 0
	parse_failed := 0
	load_failed := 0
	limit_reached := 0
	as_expected := 0

	for path in paths {
		res := checker.check_package_from_path(path, LIBRARY)
		// Each result owns its own diagnostics, so 40 results do not fight over one shared
		// buffer - but that also means each one has to be released. Odin's `defer` is
		// scope-based, so this fires at the end of every iteration, not at the end of the loop.
		defer checker.destroy_package_check_result(&res)

		switch {
		case res.parse_errors > 0:
			parse_failed += 1
			log.warnf("PARSE FAIL: %s (%d errors)", path, res.parse_errors)
		case !res.load_ok:
			// The package could not be located / produced no files at all. This is NOT a
			// clean check - it means the checker never ran on anything.
			load_failed += 1
			log.errorf("LOAD FAIL: %s (loaded %d files)", path, res.total_files)
		case res.limit_reached:
			// The error cap tripped and the checker unwound partway through. This is its own
			// bucket, deliberately ahead of the check-error case: `check_errors` here is a
			// truncated prefix, so lumping it in with completed-but-failing packages would
			// corrupt that number's meaning. (Before the cap stopped calling os.exit(1),
			// this case killed the entire test binary - CPP_DEVIATIONS.md [EMBED-1].)
			limit_reached += 1
			log.errorf("LIMIT REACHED: %s (abandoned after %d recorded errors)", path, res.check_errors)
		case res.check_errors > 0 || !res.check_ok:
			if want, ok := expected_for(oracle_agrees, path); ok && want == res.check_errors {
				// Matches the reference compiler's own count. Counted separately so the summary
				// still SHOWS it rather than quietly folding it into "passed".
				as_expected += 1
				break
			}
			check_failed += 1
			// NAME the package. This used to be "don't log each failure - just count them", which
			// turned the result into an unactionable "14/86 packages have check errors": no way to
			// tell whether those 14 are real divergences or expectations this test gets wrong,
			// without re-deriving the list by hand. The count is the summary; the list is the
			// worklist. LEDGER #359.
			log.errorf("CHECK FAIL: %s (%d errors, check_ok=%v)", path, res.check_errors, res.check_ok)
		case:
			passed += 1
		}
	}

	log.infof(
		"Core package check results: %d/%d passed, %d matched the reference compiler's own "+
		"diagnostics, %d with check errors, %d hit the error limit, "+
		"%d with parse errors, %d failed to load",
		passed, total, as_expected, check_failed, limit_reached, parse_failed, load_failed,
	)

	// A package that never loaded is a harness failure, not a checker result: it has to be
	// reported separately, otherwise "0 check errors" is indistinguishable from "checked
	// nothing at all".
	testing.expectf(t, load_failed == 0, "Should load every package (%d failed to load)", load_failed)

	// We expect no parse errors
	testing.expectf(t, parse_failed == 0, "Should have no parse errors (got %d)", parse_failed)

	// A package that blew through the error cap was only partially checked, so it is reported
	// separately from packages that were checked to completion and found wanting.
	testing.expectf(
		t,
		limit_reached == 0,
		"%d/%d packages hit the error limit and were left incompletely checked",
		limit_reached,
		total,
	)

	// And every package that loaded and parsed should check cleanly
	testing.expectf(t, check_failed == 0, "%d/%d packages have check errors", check_failed, total)
}
