# Odin Language Semantics

*Extracted from: src/check_stmt.cpp, src/check_expr.cpp, src/tokenizer.cpp, src/parser.cpp*

## 1. Keywords

### 1.1 Reserved Keywords (40)

| Keyword | Category | Description |
|---------|----------|-------------|
| `import` | Module | Import package |
| `foreign` | FFI | Foreign function interface |
| `package` | Module | Package declaration |
| `typeid` | Type | Type identifier value |
| `when` | Control | Compile-time conditional |
| `where` | Constraint | Generic constraints |
| `if` | Control | Conditional branch |
| `else` | Control | Alternative branch |
| `for` | Control | Loop construct |
| `switch` | Control | Multi-way branch |
| `in` | Operator | Membership/iteration |
| `not_in` | Operator | Non-membership |
| `do` | Control | Single-statement body |
| `case` | Control | Switch/type case |
| `break` | Control | Exit loop/switch |
| `continue` | Control | Next iteration |
| `fallthrough` | Control | Fall to next case |
| `defer` | Control | Deferred execution |
| `return` | Control | Return from procedure |
| `proc` | Type | Procedure type/literal |
| `struct` | Type | Structure type |
| `union` | Type | Tagged union type |
| `enum` | Type | Enumeration type |
| `bit_set` | Type | Bit set type |
| `bit_field` | Type | Bit field type |
| `map` | Type | Hash map type |
| `dynamic` | Type | Dynamic array modifier |
| `auto_cast` | Cast | Automatic type cast |
| `cast` | Cast | Explicit type cast |
| `transmute` | Cast | Bit reinterpretation |
| `distinct` | Type | Create distinct type |
| `using` | Scope | Promote scope/fields |
| `context` | Runtime | Implicit context |
| `or_else` | Control | Nil coalescing |
| `or_return` | Control | Error propagation |
| `or_break` | Control | Break on nil/error |
| `or_continue` | Control | Continue on nil/error |
| `asm` | Low-level | Inline assembly |
| `matrix` | Type | Matrix type |

### 1.2 Contextual Identifiers

These are not reserved but have special meaning in context:

| Identifier | Context | Meaning |
|------------|---------|---------|
| `nil` | Expression | Null/empty value |
| `true` | Expression | Boolean true |
| `false` | Expression | Boolean false |
| `---` | Expression | Uninitialized marker |

---

## 2. Control Flow Structures

### 2.1 Block Forms

Odin supports three syntactic forms for control flow bodies:

#### Brace Block `{}`
```odin
if cond {
    stmt1
    stmt2
}
```

#### Do Statement `do`
Single statement only, no braces needed:
```odin
if cond do stmt

for x in items do process(x)
```

#### Inline (No Body)
Some constructs allow no body at all:
```odin
for cond {
    // empty loop
}
```

### 2.2 If Statement

```odin
// Basic
if condition { body }

// With else
if condition { body } else { other }

// With else if
if cond1 { } else if cond2 { } else { }

// With initialization
if x := compute(); x > 0 { use(x) }

// Do form
if cond do single_stmt
```

### 2.3 For Loop Forms

#### C-style For
```odin
for init; cond; post { body }

// Examples:
for i := 0; i < 10; i += 1 { }
for ; running; { }  // while-style
for { }             // infinite loop
```

#### Range-based For
```odin
for value in collection { body }
for index, value in collection { body }
for &value in collection { body }  // mutable reference

// With do
for x in items do process(x)
```

#### Iteratable Types
- Arrays: `for elem in arr` or `for i, elem in arr`
- Slices: `for elem in slice` or `for i, elem in slice`
- Dynamic arrays: `for elem in dyn_arr`
- Maps: `for key, value in map`
- Strings: `for rune in str` or `for i, rune in str`
- Ranges: `for i in 0..<10`
- Enums: `for e in Enum` (all values)

#### Modifiers
```odin
#reverse for x in items { }    // reverse iteration
#unroll for x in items { }     // compile-time unroll
#unroll(4) for x in items { }  // partial unroll
```

### 2.4 Switch Statement

```odin
switch value {
case 1:     // single value
case 2, 3:  // multiple values
case 4..=6: // range
case:       // default
}

// With initialization
switch x := get(); x {
case .A: ...
}

// Partial (non-exhaustive)
#partial switch enum_val {
case .A: ...
// other cases not required
}
```

### 2.5 Type Switch
```odin
switch v in union_val {
case int:    use_int(v)
case string: use_string(v)
case:        // nil or unhandled
}

// Partial type switch
#partial switch v in union_val {
case int: ...
}
```

### 2.6 When Statement (Compile-time)
```odin
when ODIN_OS == .Windows {
    // Windows-only code
} else when ODIN_OS == .Linux {
    // Linux-only code
} else {
    // Other platforms
}
```

---

## 3. Scopes and Blocks

### 3.1 Scope Hierarchy

1. **Universe scope** - Built-in types and procedures
2. **Package scope** - Package-level declarations
3. **File scope** - File-private declarations (`@(private="file")`)
4. **Procedure scope** - Procedure parameters and body
5. **Block scope** - `{}` blocks, control flow bodies

### 3.2 Block Statement
```odin
{
    // Creates new scope
    x := 10
}
// x not visible here
```

### 3.3 Shadowing

Inner scopes can shadow outer declarations:
```odin
x := 1
{
    x := 2  // shadows outer x
}
// x is still 1
```

Warning for ambiguous shadows in for loops:
```odin
x := 10
for x in items { }  // Warning: shadows x
```

### 3.4 Using Statement

Promotes scope members:
```odin
using math  // import all from math into current scope

using v: Vec3  // promote Vec3 fields to local scope
v.x = 1        // same as...
x = 1          // ...this
```

---

## 4. Procedure Parameters

### 4.1 Immutability

**Procedure parameters are immutable by default:**

```odin
add :: proc(x: int, y: int) -> int {
    x = 10  // ERROR: Cannot assign to 'x' which is a procedure parameter
    return x + y
}
```

### 4.2 Mutable References

Use `&` in the for loop to get mutable access:
```odin
for &item in items {
    item = transform(item)  // OK: item is mutable reference
}
```

For procedure parameters, use pointers explicitly:
```odin
modify :: proc(x: ^int) {
    x^ = 10  // OK: modifying through pointer
}
```

### 4.3 Using Parameters

`using` on parameters promotes fields (discouraged):
```odin
// -vet or -vet-using-param will warn:
process :: proc(using p: Point) {
    // x and y available directly (from Point)
}
```

---

## 5. Return Values

### 5.1 Unnamed Returns
```odin
// Single return
square :: proc(x: int) -> int {
    return x * x
}

// Multiple returns (tuple)
divide :: proc(a, b: int) -> (int, int) {
    return a / b, a % b
}
```

### 5.2 Named Returns
```odin
divide :: proc(a, b: int) -> (quotient: int, remainder: int) {
    quotient = a / b
    remainder = a % b
    return  // Implicit: returns quotient, remainder
}

// Can also return explicitly:
divide :: proc(a, b: int) -> (q: int, r: int) {
    return a / b, a % b  // Explicit values
}
```

**Named return semantics:**
- Named returns create local variables initialized to zero
- Bare `return` returns current values of named return variables
- Can mix: assign some, return others explicitly

### 5.3 Multiple Return Usage
```odin
// Capture all
q, r := divide(10, 3)

// Ignore some with blank identifier
q, _ := divide(10, 3)

// Destructure in assignment
q: int
r: int
q, r = divide(10, 3)

// Single value from multi-return (first only, with #optional_ok)
v := lookup("key")  // If lookup has #optional_ok
```

### 5.4 Return Count Validation

```odin
// ERROR: Expected 2 return values, got 1
divide :: proc(a, b: int) -> (int, int) {
    return a / b  // Missing second value
}

// ERROR: No return values expected
nothing :: proc() {
    return 42  // Procedure has no return type
}
```

### 5.5 Optional Ok Pattern (`#optional_ok`)

```odin
lookup :: proc(key: string) -> (value: int, ok: bool) #optional_ok {
    if found {
        return val, true
    }
    return 0, false
}

// Caller can ignore the bool:
v := lookup("key")

// Or capture both:
v, ok := lookup("key")
if ok { use(v) }

// With or_else (uses first return if ok=false):
v := lookup("key") or_else default_value

// With or_return (propagates failure):
v := lookup("key") or_return
```

### 5.6 Optional Allocator Error (`#optional_allocator_error`)

```odin
alloc_thing :: proc() -> (^Thing, runtime.Allocator_Error) #optional_allocator_error {
    ptr := new(Thing) or_return
    return ptr, nil
}

// Can ignore error:
thing := alloc_thing()

// Or handle it:
thing, err := alloc_thing()
if err != nil { handle_error(err) }
```

### 5.7 Diverging Procedures

Procedures that never return (marked with `-> !`):
```odin
fatal :: proc(msg: string) -> ! {
    log_error(msg)
    trap()  // intrinsics.trap() is diverging
}

// ERROR: Diverging procedures may not return
fatal :: proc() -> ! {
    return  // Not allowed
}
```

Statements after diverging calls are flagged:
```odin
fatal("error")
cleanup()  // WARNING: Statements after a diverging procedure call are never executed
```

### 5.8 Named Return Shadowing

Shadowing named returns generates warnings:
```odin
test :: proc() -> (result: int) {
    result := 10  // WARNING: Direct shadowing of named return value 'result'
    return result
}
```

---

## 6. Context System

### 6.1 Implicit Context

Every procedure (except `"contextless"`) receives an implicit `context` parameter:

```odin
// These are equivalent:
my_proc :: proc() { }
my_proc :: proc "odin" () { }  // Odin calling convention includes context

// Contextless:
c_func :: proc "c" () { }      // No context
contextless_func :: proc "contextless" () { }
```

### 6.2 Context Type

The context contains:
```odin
Context :: struct {
    allocator:      Allocator,
    temp_allocator: Allocator,
    assertion_failure_proc: proc(...),
    logger:         Logger,
    // ... platform-specific fields
    user_ptr:       rawptr,
    user_index:     int,
}
```

### 6.3 Accessing Context
```odin
// Read current context
ctx := context

// Modify for scope
context.allocator = my_allocator
// All allocations in this scope use my_allocator

// Pass explicitly (rare)
explicit_context_proc :: proc(ctx: runtime.Context) { }
```

### 6.4 Default Context

Initialize default context:
```odin
context = runtime.default_context()
```

### 6.5 Allocators

Dynamic allocations use `context.allocator`:
```odin
// Uses context.allocator implicitly
arr := make([dynamic]int, 0, 10)

// Warning when using dynamic literals:
// "dynamic literals will implicitly allocate using the current 'context.allocator'"
```

---

## 7. Spread Operator

### 7.1 Array/Slice Expansion

Expand elements as arguments:
```odin
arr := [3]int{1, 2, 3}
sum(..arr)  // Expands to: sum(1, 2, 3)

slice: []int = arr[:]
sum(..slice)  // Same expansion
```

### 7.2 Struct Expansion

Copy and override fields:
```odin
Point :: struct { x, y, z: int }

p1 := Point{1, 2, 3}
p2 := Point{..p1, z = 10}  // x=1, y=2, z=10
```

### 7.3 Variadic Parameters

Spread into variadic:
```odin
printf :: proc(fmt: string, args: ..any) { }

values := []any{1, "hello", 3.14}
printf("values: %v %v %v", ..values)
```

---

## 8. Control Flow Keywords

### 8.1 Break
```odin
for {
    if done do break
}

// With label
outer: for x in xs {
    for y in ys {
        if cond do break outer
    }
}
```

**Restrictions:**
- Only in non-inline loops or switch statements
- Cannot use in `#unroll for` (compile-time)

### 8.2 Continue
```odin
for x in items {
    if skip(x) do continue
    process(x)
}
```

**Restrictions:**
- Only in non-inline loops
- Cannot use in `#unroll for`

### 8.3 Fallthrough
```odin
switch x {
case 1:
    setup()
    fallthrough  // Must be last statement
case 2:
    common_action()
}
```

**Restrictions:**
- Must be at end of case block
- Not allowed in type switch
- Cannot have a label

### 8.4 Defer
```odin
f := open(path)
defer close(f)  // Called when scope exits
// ... use f ...
```

Multiple defers execute in reverse order (LIFO).

### 8.5 Or-Keywords

```odin
// or_else: provide default for nil/error
value := maybe_nil() or_else default

// or_return: propagate error
value := may_fail() or_return

// or_break: break on nil/error
for {
    value := may_fail() or_break
}

// or_continue: continue on nil/error
for item in items {
    value := validate(item) or_continue
    process(value)
}
```

---

## 9. Defer Statement

### 9.1 Basic Defer

Defer executes a statement when the enclosing scope exits:

```odin
test :: proc() {
    f := open("file.txt")
    defer close(f)  // Called when scope exits

    // ... use f ...
}  // close(f) called here
```

### 9.2 Execution Order (LIFO)

Multiple defers execute in reverse order (last-in, first-out):

```odin
test :: proc() {
    defer fmt.println("1")
    defer fmt.println("2")
    defer fmt.println("3")
}
// Output: 3, 2, 1
```

### 9.3 Defer Timing

**Important:** Defer executes AFTER return value is computed:

```odin
counter :: proc() -> (n: int) {
    defer n += 1  // WARNING: Assignments to named return values
                  // within 'defer' will not affect the value that is returned
    n = 5
    return  // Returns 5, not 6
}
```

The return value is captured, then defers run:
```odin
get_value :: proc() -> int {
    x := 10
    defer x = 0   // x becomes 0, but return already captured 10
    return x      // Returns 10
}
```

### 9.4 Defer Restrictions

| Restriction | Error |
|-------------|-------|
| `return` in defer | `'return' cannot be used within a defer statement` |
| Labeled `break` | `A labelled 'break' cannot be used within a 'defer'` |
| Labeled `continue` | `A labelled 'continue' cannot be used within a 'defer'` |
| Assign to named return | Warning: won't affect returned value |

### 9.5 Branch Location (`#branch_location`)

Inside a defer, `#branch_location` provides the source location that triggered the scope exit:

```odin
cleanup :: proc() {
    loc := #branch_location
    fmt.printf("cleanup from %s:%d\n", loc.file_path, loc.line)
}

test :: proc() {
    defer cleanup()

    if error {
        return  // cleanup sees THIS location
    }
    // cleanup sees THIS location on normal exit
}
```

**Restriction:** `#branch_location` may only be used within a defer statement.

### 9.6 Deferred Procedure Attributes

These attributes automatically call a cleanup procedure when the decorated procedure returns:

#### `@(deferred_none)` - No arguments
```odin
@(deferred_none=cleanup)
acquire :: proc() -> Resource {
    // ...
}

cleanup :: proc() {
    // Called with no arguments
}
```

#### `@(deferred_in)` - Pass input arguments
```odin
@(deferred_in=release)
acquire :: proc(name: string, size: int) -> Resource {
    // ...
}

release :: proc(name: string, size: int) {
    // Receives same arguments as acquire
}
```

#### `@(deferred_out)` - Pass return values
```odin
@(deferred_out=release)
acquire :: proc() -> (handle: Handle, ok: bool) {
    // ...
}

release :: proc(handle: Handle, ok: bool) {
    // Receives the return values
}
```

#### `@(deferred_in_out)` - Pass both inputs and outputs
```odin
@(deferred_in_out=release)
acquire :: proc(name: string) -> (handle: Handle) {
    // ...
}

release :: proc(name: string, handle: Handle) {
    // Receives inputs first, then outputs
}
```

#### `*_by_ptr` variants - Pass as pointers

For large types, use pointer variants:

| Attribute | Parameters |
|-----------|------------|
| `@(deferred_in_by_ptr)` | Input args as pointers |
| `@(deferred_out_by_ptr)` | Return values as pointers |
| `@(deferred_in_out_by_ptr)` | Both as pointers |

```odin
@(deferred_out_by_ptr=release)
acquire :: proc() -> BigStruct {
    // ...
}

release :: proc(result: ^BigStruct) {
    // Receives pointer to return value
}
```

### 9.7 Deferred Attribute Rules

- Cannot use a procedure as its own deferred procedure
- Cannot use with polymorphic procedures
- Deferred procedure signature must match:
  - `deferred_in`: params match source params
  - `deferred_out`: params match source results
  - `deferred_in_out`: params match source params + results (in that order)
- Only one `deferred_*` attribute per procedure

```odin
// ERROR: 'acquire' cannot be used as its own deferred_out
@(deferred_out=acquire)
acquire :: proc() -> int { return 1 }

// ERROR: 'deferred_in' cannot be used with a polymorphic procedure
@(deferred_in=release)
acquire :: proc($T: typeid) -> T { ... }
```

---

## 10. Initialization Order

### 10.1 Package Initialization

1. Import dependencies initialized first
2. File-level variables initialized in declaration order
3. `@(init)` procedures called (unspecified order within package)

### 10.2 @(init) Procedures
```odin
@(init)
setup :: proc "contextless" () {
    // Must be contextless
    // Must have no parameters or returns
    // Called at program startup
}
```

### 10.3 @(fini) Procedures
```odin
@(fini)
cleanup :: proc "contextless" () {
    // Called at program shutdown
}
```

---

## 11. Implicit Conversions (Semantic)

### 11.1 Pointer Promotion

Pointers to larger types are NOT automatically promoted. Use explicit `#by_ptr`:

```odin
// Large struct passed by value (copied)
process :: proc(big: BigStruct) { }

// Explicitly pass by pointer
process :: proc(big: #by_ptr BigStruct) { }
```

### 11.2 Slice from Array

Arrays implicitly convert to slices:
```odin
arr: [10]int
slice: []int = arr[:]  // Explicit slice
func(arr[:])           // Pass array as slice
```

### 11.3 Multi-pointer from Pointer

`^T` implicitly converts to `[^]T` and vice versa (same element type).
