# Odin Advanced Semantics

*Extracted from: src/check_type.cpp, src/check_decl.cpp, src/check_expr.cpp*

## 1. Polymorphism (Generics)

### 1.0 Deferred Checking (Important!)

**Polymorphic entities are NOT fully type-checked until instantiated with concrete types.**

```odin
// This compiles - body not checked yet
bad_generic :: proc($T: typeid) -> T {
    return "not a T"  // ERROR only when called!
}

// No error yet - never instantiated
// bad_generic(int)  // ERROR: cannot convert string to int
```

The checker:
1. Parses and registers the polymorphic entity
2. Validates the signature structure (parameter syntax, where clause syntax)
3. Does NOT check the body until a concrete instantiation occurs
4. Each unique instantiation is checked independently

This means:
- Unused polymorphic code may contain type errors
- Errors appear at the call site, not the definition
- Different instantiations can succeed or fail independently

### 1.1 Type Parameters

```odin
// $T declares a type parameter
Stack :: struct($T: typeid) {
    data: [dynamic]T,
    len:  int,
}

// Usage creates concrete type - THIS triggers checking
int_stack: Stack(int)
str_stack: Stack(string)
```

### 1.2 Procedure Polymorphism

```odin
// Polymorphic procedure
swap :: proc(a, b: ^$T) {
    a^, b^ = b^, a^
}

// Inferred from arguments
x, y := 1, 2
swap(&x, &y)
```

### 1.3 Constant Type Parameters

```odin
// $N is a constant parameter
Fixed_Array :: struct($N: int, $T: typeid) {
    data: [N]T,
}

arr: Fixed_Array(10, f32)
```

### 1.4 Where Clauses

```odin
// Constrain type parameters
add :: proc(a, b: $T) -> T where intrinsics.type_is_numeric(T) {
    return a + b
}

// Multiple constraints
process :: proc(x: $T) where
    intrinsics.type_is_struct(T),
    intrinsics.type_has_field(T, "id") {
    // ...
}
```

**Where clause evaluation:**
- Where clauses are checked at instantiation time
- If constraint fails, instantiation is rejected
- Provides better error messages than body type errors

```odin
add :: proc(a, b: $T) -> T where intrinsics.type_is_numeric(T) {
    return a + b
}

add("x", "y")  // ERROR: constraint failed - string is not numeric
               // (clearer than "cannot use + on strings")
```

### 1.5 Specialization

```odin
// Generic version
print :: proc(x: $T) { fmt.println(x) }

// Specialized for strings
print :: proc(x: string) { fmt.print("STRING: ", x) }
```

### 1.6 Instantiation and Caching

Each unique set of concrete type arguments creates one instantiation:

```odin
identity :: proc(x: $T) -> T { return x }

identity(1)      // Creates identity(int)
identity(2)      // Reuses identity(int) - same types
identity("hi")   // Creates identity(string)
identity(1.0)    // Creates identity(f64)
```

The checker maintains a cache (`GenTypesData`) to avoid re-checking identical instantiations.

For polymorphic records:
```odin
Vec :: struct($T: typeid) { x, y: T }

a: Vec(f32)  // Creates and checks Vec(f32)
b: Vec(f32)  // Reuses existing Vec(f32)
c: Vec(int)  // Creates and checks Vec(int)
```

### 1.7 Polymorphism Errors

```odin
// ERROR: A polymorphic parameter cannot be variadic
bad :: proc($T: ..typeid) { }

// ERROR: Parameter types cannot be polymorphic
bad :: proc(x: $T, y: T) where T: $U { }  // U not allowed here

// ERROR: Cannot determine polymorphic type from parameter
ambiguous :: proc() -> $T { return {} }  // T can't be inferred
ambiguous()  // ERROR: cannot determine type

// ERROR: Cannot pass polymorphic type as a parameter
pass_type :: proc(t: typeid) { }
pass_type($T)  // ERROR

// ERROR: Invalid use of a non-specialized polymorphic type
Vec :: struct($T: typeid) { data: T }
x: Vec  // ERROR: must specify Vec(concrete_type)
```

### 1.8 Unspecialized vs Specialized

```odin
Vec :: struct($T: typeid) { x, y: T }

// Unspecialized - the template itself
// Cannot be used as a runtime type
_ = size_of(Vec)  // ERROR: cannot use on unspecialized polymorphic

// Specialized - concrete instantiation
_ = size_of(Vec(f32))  // OK: 8 bytes

// Type introspection
intrinsics.type_is_specialized_polymorphic_record(Vec(f32))    // true
intrinsics.type_is_unspecialized_polymorphic_record(Vec)       // true
```

---

## 2. Procedure Groups (Overloading)

### 2.1 Declaration

```odin
// Create overloaded procedure
print :: proc {
    print_int,
    print_string,
    print_float,
}

print_int    :: proc(x: int)    { ... }
print_string :: proc(x: string) { ... }
print_float  :: proc(x: f32)    { ... }
```

### 2.2 Resolution

Overload resolution considers:
1. Exact type match (highest priority)
2. Implicit conversions
3. Polymorphic instantiation (lowest priority)

```odin
print(42)      // Calls print_int
print("hi")    // Calls print_string
print(3.14)    // Calls print_float
```

### 2.3 Ambiguity Errors

```odin
// ERROR: Ambiguous call to procedure group
foo :: proc { foo_a, foo_b }
foo_a :: proc(x: int)  { }
foo_b :: proc(x: i32)  { }  // int == i32 on most platforms

foo(0)  // Ambiguous!
```

### 2.4 Procedure Group Restrictions

```odin
// ERROR: Cannot assign overloaded procedure group to variable
foo :: proc { foo_a, foo_b }
x := foo  // ERROR

// ERROR: procedure group used in binary expression
foo + 1  // ERROR
```

---

## 3. Calling Conventions

### 3.1 Available Conventions

| Convention | Keyword | Context | Description |
|------------|---------|---------|-------------|
| Odin | `"odin"` | Default | Passes implicit context |
| Contextless | `"contextless"` | No context | Odin ABI without context |
| C | `"c"` / `"cdecl"` | FFI | C calling convention |
| Stdcall | `"stdcall"` | Windows | Windows stdcall |
| Fastcall | `"fastcall"` | x86 | Register-based |
| Win64 | `"win64"` | Windows x64 | Windows 64-bit |
| SysV | `"system"` / `"sysv"` | Unix x64 | System V AMD64 |
| Naked | `"naked"` | Low-level | No prologue/epilogue |
| None | `"none"` | Special | No convention |

### 3.2 Platform Restrictions

```odin
// ERROR: Calling convention 'stdcall' is not supported on this architecture
// (on non-x86)
@(export)
my_func :: proc "stdcall" () { }

// ERROR: Calling convention 'win64' is not supported on this architecture
// (on 32-bit)
my_func :: proc "win64" () { }
```

### 3.3 Context Implications

```odin
// Has implicit context
odin_proc :: proc() {
    // Can access 'context'
    _ = context.allocator
}

// No context - cannot access context
c_proc :: proc "c" () {
    // ERROR: cannot access 'context' in contextless procedure
    // _ = context.allocator
}
```

---

## 4. Foreign Function Interface

### 4.1 Foreign Import

```odin
// Import library
foreign import libc "system:c"

// Platform-specific
foreign import kernel32 "system:kernel32.lib" when ODIN_OS == .Windows

// With attributes
@(require)
foreign import mylib "mylib.so"
```

### 4.2 Foreign Block

```odin
foreign libc {
    printf :: proc(fmt: cstring, #c_vararg args: ..any) -> i32 ---
    malloc :: proc(size: c.size_t) -> rawptr ---
    free   :: proc(ptr: rawptr) ---
}
```

### 4.3 Foreign Block Attributes

```odin
@(default_calling_convention="c")
@(link_prefix="my_")
foreign mylib {
    // All procs default to "c" calling convention
    // All link names prefixed with "my_"
    func :: proc() ---  // Links as "my_func"
}
```

### 4.4 Foreign Procedure Rules

```odin
// ERROR: A foreign procedure cannot have a body
foreign libc {
    bad :: proc() { }  // ERROR
}

// ERROR: A foreign procedure cannot be polymorphic
foreign libc {
    bad :: proc($T: typeid) ---  // ERROR
}

// ERROR: A foreign procedure cannot have an 'export' tag
@(export)
foreign libc {
    bad :: proc() ---  // ERROR
}

// Foreign variable must be in foreign block
// ERROR: foreign variable declaration can not be scoped to a module
foreign libc {
    @(link_name="errno")
    errno: i32  // OK
}
```

### 4.5 #c_vararg

```odin
// C variadic only allowed on foreign procedures
foreign libc {
    printf :: proc(fmt: cstring, #c_vararg args: ..any) -> i32 ---
}

// ERROR: must be last parameter
foreign libc {
    bad :: proc(#c_vararg args: ..any, x: int) ---  // ERROR
}

// ERROR: must be foreign
non_foreign :: proc(#c_vararg args: ..any) { }  // ERROR
```

---

## 5. Bit Sets

### 5.1 Basic Bit Set

```odin
Flags :: bit_set[Flag]

Flag :: enum {
    Read,
    Write,
    Execute,
}

flags: Flags = {.Read, .Write}
```

### 5.2 With Underlying Type

```odin
// Specify backing type
Flags :: bit_set[Flag; u8]
Flags :: bit_set[Flag; u32]
```

### 5.3 With Range

```odin
// Range-based bit set
Small_Set :: bit_set[0..<8]      // 0-7
Byte_Set  :: bit_set[0..=255; u32]  // 0-255
```

### 5.4 Bit Set Restrictions

```odin
// ERROR: bit_set does not allow a negative lower bound when underlying type is set
Bad :: bit_set[-1..<8; u8]  // ERROR

// ERROR: bit_set range is greater than N bits
Bad :: bit_set[0..<100; u8]  // ERROR: needs >8 bits

// ERROR: A boolean cannot be used as a key for a map (applies to bit_set iteration)
```

---

## 6. Bit Fields

### 6.1 Basic Bit Field

```odin
Packed :: bit_field u32 {
    x: u8  | 4,   // 4 bits
    y: u8  | 4,   // 4 bits
    z: u16 | 8,   // 8 bits
    w: u16 | 16,  // 16 bits
}  // Total: 32 bits = u32 backing
```

### 6.2 Rules

```odin
// ERROR: bit_field's field must have a type
bit_field u8 { x | 4 }  // ERROR: no type

// ERROR: bit_field's specified bit size cannot be <= 0
bit_field u8 { x: u8 | 0 }  // ERROR

// ERROR: bit_field's specified bit size cannot exceed 64 bits
bit_field u128 { x: u64 | 65 }  // ERROR

// ERROR: bit_field's specified bit size cannot exceed its type
bit_field u8 { x: bool | 2 }  // ERROR: bool is 1 bit max

// ERROR: Total bit size must fit backing type
bit_field u8 {
    a: u8 | 4,
    b: u8 | 4,
    c: u8 | 4,  // ERROR: 12 bits > 8 bits
}
```

### 6.3 Endianness

```odin
// All fields must have same endianness
bit_field u32 {
    a: u16le | 16,
    b: u16be | 16,  // ERROR: mixed endianness
}
```

---

## 7. Enumerated Arrays

### 7.1 Basic Usage

```odin
Direction :: enum { North, South, East, West }

// Array indexed by enum
names: [Direction]string = {
    .North = "N",
    .South = "S",
    .East  = "E",
    .West  = "W",
}

// Access
n := names[.North]
```

### 7.2 Partial Initialization

```odin
// All values must be provided (or use default)
values: [Direction]int = {
    .North = 1,
    // ERROR if not all cases covered and no default
}

// With partial
#partial values: [Direction]int = {
    .North = 1,
    // Others zero-initialized
}
```

---

## 8. SOA (Structure of Arrays)

### 8.1 SOA Struct

```odin
// Original AOS (Array of Structs)
Point :: struct { x, y, z: f32 }
points: [100]Point  // xyzxyzxyz...

// SOA layout
#soa points: [100]Point  // xxx...yyy...zzz...
```

### 8.2 SOA Types

```odin
// Fixed-size SOA
#soa [N]T

// SOA slice
#soa []T

// SOA dynamic array
#soa [dynamic]T
```

### 8.3 SOA Pointer

```odin
// Pointer to SOA struct
ptr: #soa ^[100]Point

// ERROR: #soa pointers require an #soa record type as the element
bad: #soa ^Point  // ERROR
```

### 8.4 SOA Restrictions

```odin
// ERROR: #soa slices are not supported for compound literals
x := #soa []Point{{1,2,3}}  // ERROR

// ERROR: #soa fixed length arrays must specify their length
x: #soa [?]Point = ...  // ERROR
```

### 8.5 SOA Zip/Unzip

```odin
// Convert between SOA and AOS iteration
#soa pts: [100]Point

for p in soa_zip(pts) {
    // p is Point (AOS view)
}

aos_slice := soa_unzip(pts)
```

---

## 9. Matrix Types

### 9.1 Declaration

```odin
// matrix[rows, cols]element_type
Mat4 :: matrix[4, 4]f32
Vec4 :: matrix[4, 1]f32  // Column vector
```

### 9.2 Operations

```odin
a: matrix[2, 3]f32
b: matrix[3, 4]f32
c := a * b  // matrix[2, 4]f32 - matrix multiplication

// Element-wise
d := a + a  // OK
e := a - a  // OK

// ERROR: Operator '/' is not allowed with matrix types
f := a / a  // ERROR

// ERROR: Operator '%' is not allowed with matrix types
g := a % a  // ERROR
```

### 9.3 Row vs Column Major

```odin
// Default is column-major
m: matrix[4, 4]f32

// Row-major
#row_major m: matrix[4, 4]f32
```

---

## 10. SIMD Vectors

### 10.1 Declaration

```odin
// #simd[count]element_type
Vec4f :: #simd[4]f32
Vec8i :: #simd[8]i32
```

### 10.2 Element Count Limits

```odin
// ERROR: #simd support a maximum element count of 64
Bad :: #simd[128]f32  // ERROR
```

### 10.3 SIMD Operations

```odin
a: #simd[4]f32 = {1, 2, 3, 4}
b: #simd[4]f32 = {5, 6, 7, 8}

c := a + b  // Lane-wise add
d := a * b  // Lane-wise multiply

// ERROR: Operator '/' is not allowed with #simd types with integer elements
x: #simd[4]i32
y := x / x  // ERROR for integers
```

---

## 11. Package System

### 11.1 Package Declaration

```odin
// Must be first non-comment statement
package my_package
```

### 11.2 Imports

```odin
// Basic import
import "core:fmt"

// Aliased import
import f "core:fmt"

// Import into current scope
import . "core:fmt"  // Discouraged
```

### 11.3 Visibility

```odin
// Package-visible (default)
public_func :: proc() { }

// File-private
@(private="file")
file_private :: proc() { }

// Package-private (same as no attribute for procs)
@(private)
package_private :: proc() { }
```

### 11.4 Export for FFI

```odin
// Export symbol
@(export)
exported_func :: proc "c" () { }

// With custom link name
@(export, link_name="my_custom_name")
func :: proc "c" () { }
```

---

## 12. Type Assertions and Switches

### 12.1 Union Type Assertion

```odin
Value :: union { int, f32, string }

v: Value = 42

// Type assertion (panics if wrong)
i := v.(int)

// Safe assertion
if i, ok := v.(int); ok {
    use(i)
}
```

### 12.2 Type Switch

```odin
switch x in value {
case int:
    fmt.println("int:", x)
case f32:
    fmt.println("float:", x)
case string:
    fmt.println("string:", x)
case:
    fmt.println("nil or unknown")
}
```

### 12.3 Any Type Assertion

```odin
a: any = 42

// Assert type
if i, ok := a.(int); ok {
    use(i)
}

// Type switch on any
switch x in a {
case int: ...
case string: ...
}
```

### 12.4 Errors

```odin
// ERROR: A type assertion cannot be applied to a constant expression
VALUE :: 42
x := VALUE.(int)  // ERROR

// ERROR: A type assertion cannot be applied to an untyped expression
x := 42.(int)  // ERROR
```

---

## 13. Using Statement/Field

### 13.1 Using Import

```odin
// Bring all exports into scope
using import "core:math"

// Now can use sin() directly instead of math.sin()
```

### 13.2 Using Field

```odin
Base :: struct { x, y: int }

Derived :: struct {
    using base: Base,  // Promotes x, y
    z: int,
}

d: Derived
d.x = 1   // Direct access to base.x
d.y = 2   // Direct access to base.y
```

### 13.3 Using Variable

```odin
v: Vec3
using v  // Brings x, y, z into scope

x = 1.0  // Same as v.x = 1.0
```

### 13.4 Using Parameter (Discouraged)

```odin
// WARNING with -vet or -vet-using-param
process :: proc(using p: Point) {
    // x and y directly accessible
}
```

---

## 14. Inline Assembly

### 14.1 Basic ASM

```odin
result: u64
asm {
    "mov %[result], 42"
    : [result] "=r" (result)
}
```

### 14.2 ASM Restrictions

```odin
// Cannot use asm at file scope (must be in procedure)
// Cannot use asm in foreign procedures
// Cannot use asm with certain calling conventions
```

---

## 15. Testing

### 15.1 Test Procedures

```odin
@(test)
test_addition :: proc(t: ^testing.T) {
    testing.expect(t, 1 + 1 == 2)
}
```

### 15.2 Test Attributes

```odin
// Test must have correct signature
@(test)
bad_test :: proc() { }  // ERROR: wrong signature

// Test cannot be private
@(test, private)
bad :: proc(t: ^testing.T) { }  // ERROR
```

---

## 16. Memory Operations

### 16.1 New and Make

```odin
// new - allocates single value
ptr := new(int)
defer free(ptr)

// make - allocates collections
slice := make([]int, 10)
defer delete(slice)

dyn := make([dynamic]int, 0, 100)
defer delete(dyn)

m := make(map[string]int)
defer delete(m)
```

### 16.2 Allocator Context

```odin
// Uses context.allocator implicitly
ptr := new(int)

// Explicit allocator
ptr := new(int, my_allocator)
```
