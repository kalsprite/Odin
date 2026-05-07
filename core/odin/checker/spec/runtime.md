# Odin Runtime Semantics

*Extracted from: src/check_expr.cpp, src/checker.cpp, src/check_decl.cpp*

## 1. Or-Expression Family

### 1.1 or_else

Returns left side if "ok", otherwise returns right side:

```odin
// With #optional_ok procedure
lookup :: proc(key: string) -> (int, bool) #optional_ok { ... }

value := lookup("key") or_else 0
value := lookup("key") or_else default_value
```

**Semantics:**
1. Evaluate left expression
2. If result has "ok" semantic (bool is true, pointer is non-nil, etc.), return left
3. Otherwise, evaluate and return right expression

**Type rules:**
- Left must be a type with nil/ok semantic (optional_ok, pointer, union, etc.)
- Right must be assignable to the "value" part of left
- Right can be a diverging expression (e.g., `panic()`)

```odin
// Diverging right side is allowed
value := lookup("key") or_else panic("not found")
```

**Special case: #load**
```odin
// #load or_else requires constant right side
data := #load("file.txt") or_else default_bytes
// ERROR if default_bytes is not constant (unless chaining #load)
```

### 1.2 or_return

Returns early from procedure if "not ok":

```odin
parse :: proc(s: string) -> (Value, Error) {
    x := parse_int(s) or_return  // Returns (zero, error) if parse_int fails
    return Value{x}, nil
}
```

**Semantics:**
1. Evaluate expression
2. If "not ok", return from current procedure with error value
3. If "ok", unwrap and continue with value

**Type propagation:**
- Error type of expression must be compatible with procedure's return error type
- The error portion is propagated, value portion is unwrapped

```odin
// Procedure must have compatible return type
read_file :: proc(path: string) -> ([]u8, Error) {
    f := open(path) or_return  // Error propagates
    defer close(f)
    return read_all(f)
}
```

**Restrictions:**
```odin
// ERROR: 'or_return' cannot be used within a defer statement
defer {
    x := may_fail() or_return  // ERROR
}
```

### 1.3 or_break

Break from loop if "not ok":

```odin
for item in items {
    value := validate(item) or_break
    process(value)
}
```

**With labels:**
```odin
outer: for x in xs {
    for y in ys {
        result := check(x, y) or_break outer  // Breaks outer loop
    }
}

// ERROR: Label 'name' can only be used with 'or_break'
// (when label points to switch, not loop)
```

### 1.4 or_continue

Continue to next iteration if "not ok":

```odin
for item in items {
    value := validate(item) or_continue  // Skip invalid items
    process(value)
}
```

**With labels:**
```odin
outer: for x in xs {
    for y in ys {
        result := check(x, y) or_continue outer
    }
}
```

### 1.5 Split Types

The or-expressions "split" types with ok semantics:

| Expression Type | Left (value) | Right (error/nil) |
|-----------------|--------------|-------------------|
| `(T, bool) #optional_ok` | T | bool |
| `(T, Error) #optional_allocator_error` | T | Error |
| `union { nil, T }` | T | nil |
| `^T` | ^T (non-nil) | nil |
| `Maybe(T)` | T | nil |

---

## 2. RTTI (Runtime Type Information)

### 2.1 type_info

Every type has associated `Type_Info` accessible at runtime:

```odin
info := type_info_of(int)
// info is ^runtime.Type_Info
```

### 2.2 typeid

Runtime type identifier:

```odin
id: typeid = int  // Type as value
id = typeid_of(some_value)

// Compare types at runtime
if id == string {
    // ...
}
```

### 2.3 type_info_of vs typeid_of

```odin
// type_info_of: compile-time type -> ^Type_Info
info := type_info_of(MyStruct)

// typeid_of: runtime value -> typeid
id := typeid_of(my_value)

// type_info from typeid
info := type_info_of(id)
```

### 2.4 RTTI Build Flag

```odin
// Build with: odin build . -no-rtti
// Sets: ODIN_NO_RTTI = true

when !ODIN_NO_RTTI {
    // RTTI available
    info := type_info_of(T)
}
```

**When RTTI disabled:**
- `type_info_of` not available
- `typeid` comparisons still work
- Type assertions still work (checked differently)
- Reduces binary size

---

## 3. Bounds Checking

### 3.1 Default Behavior

Bounds checking is **enabled by default**:

```odin
arr: [10]int
x := arr[15]  // Runtime panic: index out of bounds
```

### 3.2 Build Flag

```odin
// Build with: odin build . -no-bounds-check
// Sets: ODIN_NO_BOUNDS_CHECK = true

// Disables all bounds checking - UNSAFE
```

### 3.3 Procedure-Level Control

```odin
// Enable bounds checking for specific procedure
@(bounds_check)
safe_access :: proc(arr: []int, i: int) -> int {
    return arr[i]  // Checked even with -no-bounds-check
}

// Disable for specific procedure
@(no_bounds_check)
unsafe_access :: proc(arr: []int, i: int) -> int {
    return arr[i]  // No check even without -no-bounds-check
}
```

### 3.4 What's Checked

| Operation | Checked |
|-----------|---------|
| Array index `arr[i]` | Yes |
| Slice index `slice[i]` | Yes |
| Matrix index `mat[r, c]` | Yes |
| Multi-pointer index `ptr[i]` | Partial (if enabled) |
| Slice expression `arr[lo:hi]` | Yes (lo <= hi <= len) |
| String index | Yes |

### 3.5 Runtime Functions

With bounds checking, these runtime functions are used:
- `bounds_check_error`
- `matrix_bounds_check_error`
- `slice_expr_error_hi`
- `slice_expr_error_lo_hi`
- `multi_pointer_slice_expr_error`

---

## 4. Thread-Local Storage

### 4.1 Basic Usage

```odin
@(thread_local)
my_tls: int  // Each thread gets own copy
```

### 4.2 Models

```odin
@(thread_local)           // Default model
@(thread_local="default") // Explicit default

// Platform-specific models (implementation defined)
@(thread_local="initial-exec")
@(thread_local="local-exec")
@(thread_local="local-dynamic")
@(thread_local="global-dynamic")
```

### 4.3 Restrictions

```odin
// ERROR: thread_local not allowed with static
@(static, thread_local)  // ERROR: redundant, pick one
tls_var: int

// ERROR: thread_local variables cannot be declared within a defer
defer {
    @(thread_local)
    bad: int  // ERROR
}

// ERROR: thread_local not allowed on '_'
@(thread_local)
_: int  // ERROR

// ERROR: A thread local variable declaration cannot have initialization values
@(thread_local)
x: int = 42  // ERROR on some platforms

// Silently disabled on WASM (no threads)
```

### 4.4 Build Flag

```odin
// Build with: odin build . -no-thread-local
// Converts all thread_local to regular globals
```

---

## 5. Build Flags Affecting Semantics

### 5.1 Safety Flags

| Flag | Effect | Global Constant |
|------|--------|-----------------|
| `-no-bounds-check` | Disable array bounds checking | `ODIN_NO_BOUNDS_CHECK` |
| `-no-type-assert` | Disable type assertion checks | `ODIN_NO_TYPE_ASSERT` |
| `-no-rtti` | Disable runtime type info | (affects type_info availability) |

### 5.2 Threading Flags

| Flag | Effect |
|------|--------|
| `-no-thread-local` | Convert TLS to regular globals |
| `-no-threaded-checker` | Single-threaded type checking |

### 5.3 Entry Point Flags

| Flag | Effect |
|------|--------|
| `-no-entry-point` | Don't require/generate main |
| `-no-crt` | Don't link C runtime |

### 5.4 Attribute Flags

| Flag | Effect |
|------|--------|
| `-ignore-unknown-attributes` | Don't error on unknown @(...) |
| `-custom-attribute:name` | Allow specific custom attribute |

### 5.5 Checking Compile-Time

```odin
when ODIN_NO_BOUNDS_CHECK {
    // Bounds checking disabled
}

when ODIN_DEBUG {
    // Debug build
}
```

---

## 6. String Handling

### 6.1 String Types

| Type | Description | Nil Value |
|------|-------------|-----------|
| `string` | UTF-8 slice (ptr + len) | `""` (nil ptr, 0 len) |
| `cstring` | Null-terminated C string | `nil` |
| `string16` | UTF-16 slice | `""` |
| `cstring16` | Null-terminated UTF-16 | `nil` |

### 6.2 String Literals

```odin
s := "hello"           // string
c : cstring = "hello"  // cstring (null-terminated)

// Raw strings
r := `raw\nstring`     // Backslash is literal
```

### 6.3 String Interning

String literals are interned at compile time:
```odin
a := "hello"
b := "hello"
// a.ptr == b.ptr (same memory)
```

### 6.4 Conversions

```odin
// string -> cstring (runtime, needs allocator or transmute)
s: string = "hello"
c := strings.clone_to_cstring(s)  // Allocates

// cstring -> string (safe)
c: cstring = "hello"
s := string(c)  // Scans for null terminator

// []u8 <-> string
bytes: []u8 = transmute([]u8)s
s2 := string(bytes)
```

---

## 7. Reserved Keywords Reference

For completeness, `asm` is reserved but not implemented:

```odin
// asm is a keyword but currently produces:
// "Inline assembly is not yet supported"

asm { ... }  // Will error
```

---

## 8. Constant Expressions

### 8.1 What Must Be Constant

| Context | Requirement |
|---------|-------------|
| Array size `[N]T` | N must be constant |
| Enum values | Must be constant |
| Global variable init | Must be constant (or `---`) |
| `#assert` condition | Must be constant |
| `#config` default | Must be constant |
| `when` condition | Must be constant |
| `@(align=N)` | N must be constant |
| Bit field sizes | Must be constant |
| `#unroll` count | Must be constant |

### 8.2 Constant Expressions Include

- Literals
- `size_of`, `align_of`, `offset_of`
- Arithmetic on constants
- `len` of fixed arrays/strings
- Enum values
- Compile-time procedure calls (limited)

### 8.3 Not Constant

- Procedure calls (except specific builtins)
- Variable references
- Pointer operations
- `len` of slices/dynamic arrays
