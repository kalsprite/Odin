# Odin Indexing and Array Access Rules

*Extracted from: src/check_expr.cpp, src/check_type.cpp*

## 1. Indexable Types

The following types support indexing with `expr[index]`:

| Type | Index Type | Result Type | Notes |
|------|------------|-------------|-------|
| `[N]T` (array) | integer | T | Bounds checked |
| `[]T` (slice) | integer | T | Bounds checked |
| `[dynamic]T` | integer | T | Bounds checked |
| `[^]T` (multi-pointer) | integer | T | Optional bounds check |
| `string` | integer | u8 | Bounds checked |
| `string16` | integer | u16 | Bounds checked |
| `map[K]V` | K | V | Key lookup |
| `matrix[R,C]T` | integer | [C]T or [R]T | Column/row by layout |
| `[E]T` (enumerated) | E (enum) | T | Bounds checked |
| `#soa [N]T` | integer | T | SOA element access |

---

## 2. Integer Index Requirements

### 2.1 Valid Index Types

For non-enumerated array indexing:
- Any integer type (`int`, `i8`, `i16`, `i32`, `i64`, `u8`, etc.)
- Enum values (converted to integer)

```odin
arr: [10]int
x := arr[5]       // OK: integer literal
y := arr[u8(3)]   // OK: any integer type
```

### 2.2 Negative Index Check

At compile time, negative constant indices are rejected:

```odin
arr: [10]int
x := arr[-1]  // ERROR: Index cannot be a negative value
```

Exception: Multi-pointers allow negative indices (pointer arithmetic).

### 2.3 Bounds Checking

For constant indices, bounds are checked at compile time:

```odin
arr: [10]int
x := arr[15]  // ERROR: Index is out of bounds (compile-time)
```

For runtime indices, bounds checking occurs at runtime (unless disabled).

---

## 3. Enumerated Arrays

### 3.1 Declaration

Arrays indexed by enum type:

```odin
Color :: enum { Red, Green, Blue }
color_values: [Color]int  // Indexed by Color, not int
```

### 3.2 Index Type Requirement

**Must use the enum type for indexing:**

```odin
Color :: enum { Red, Green, Blue }
values: [Color]int

x := values[.Red]     // OK: enum value
y := values[0]        // ERROR: Index must be an enum of type 'Color'
z := values[Color(0)] // OK: explicit cast to enum
```

### 3.3 Contiguous Enum Requirement

By default, enumerated arrays require contiguous enum values:

```odin
Sparse :: enum {
    A = 0,
    B = 10,  // Gap!
    C = 20,
}

// ERROR: Non-contiguous enumeration used as index
arr: [Sparse]int
```

### 3.4 #sparse Modifier

Use `#sparse` to allow non-contiguous enums:

```odin
Sparse :: enum {
    A = 0,
    B = 10,
    C = 20,
}

// OK: #sparse allows gaps
arr: #sparse [Sparse]int
```

**Warning:** With large gaps, #sparse arrays allocate space for the entire range:
```
// If enum_count * 2 < array_length, warning is shown
// Suggestion: this warning will be removed if #sparse is applied
```

### 3.5 Enumerated Array Length

The length of an enumerated array is `max_value - min_value + 1`:

```odin
E :: enum { A = 5, B = 6, C = 7 }
arr: [E]int  // Length is 3 (7 - 5 + 1)
```

### 3.6 Cannot Slice Enumerated Arrays

```odin
arr: [Color]int
slice := arr[:]  // ERROR: Cannot slice enumerated arrays
```

---

## 4. Slice Expressions

### 4.1 Syntax

```odin
expr[lo:hi]   // Half-open: lo <= i < hi
expr[lo:]     // From lo to end
expr[:hi]     // From 0 to hi
expr[:]       // Full slice
```

### 4.2 Valid Slice Sources

| Source Type | Result Type | Notes |
|-------------|-------------|-------|
| `[N]T` | `[]T` | Must be addressable |
| `[]T` | `[]T` | Reslicing |
| `[dynamic]T` | `[]T` | Dynamic to slice |
| `string` | `string` | Substring |
| `[^]T` | `[]T` or `[^]T` | See multi-pointer rules |
| `#soa [N]T` | `#soa []T` | SOA slicing |

### 4.3 Addressability Requirement

Arrays must be addressable to slice:

```odin
get_array :: proc() -> [5]int { ... }

slice := get_array()[:]  // ERROR: Cannot slice, value not addressable

arr := get_array()
slice := arr[:]  // OK: arr is addressable
```

### 4.4 Index Validation

```odin
arr: [10]int
s1 := arr[5:3]   // ERROR: Invalid slice indices: [5 > 3]
s2 := arr[0:15]  // ERROR: Index out of bounds
```

### 4.5 Multi-Pointer Slicing

```odin
ptr: [^]int

x := ptr[:]     // [^]int (no upper bound, stays multi-pointer)
y := ptr[i:]    // [^]int
z := ptr[:n]    // []int  (upper bound converts to slice)
w := ptr[i:n]   // []int
```

### 4.6 Constant String Slicing

```odin
s :: "hello"

// Constant indices required for constant strings
sub := s[1:4]        // OK: constant indices -> constant result
sub2 := s[i:j]       // ERROR: Cannot slice with non-constant indices
                     // Suggestion: store the constant into a variable
```

---

## 5. Matrix Indexing

### 5.1 Single Index (Column/Row Access)

```odin
m: matrix[3, 4]f32

col := m[0]  // Gets column 0 (or row 0 if row-major)
// Type depends on layout:
// Column-major: m[i] -> [3]f32 (column vector)
// Row-major: m[i] -> [4]f32 (row vector)
```

### 5.2 Two-Index (Element Access)

```odin
m: matrix[3, 4]f32

elem := m[row, col]  // f32 element
m[1, 2] = 5.0        // Assignment
```

### 5.3 Constant Matrix Indexing

```odin
M :: matrix[2, 2]int{1, 2, 3, 4}

x := M[0, 1]     // OK: constant indices
y := M[i, j]     // ERROR: Cannot index constant matrix with non-constant indices
```

---

## 6. Map Indexing

### 6.1 Key Lookup

```odin
m: map[string]int

value := m["key"]  // Returns int (zero if not found)
```

### 6.2 Typeid Keys

For `map[typeid]V`, the key can be a type expression:

```odin
type_map: map[typeid]string
type_map[int] = "integer"
name := type_map[f32]
```

### 6.3 Optional-Ok Pattern

```odin
value, ok := m["key"]  // ok is false if key not present
```

---

## 7. SOA Struct Indexing

### 7.1 SOA Fixed Array

```odin
Entity :: struct { x, y: f32; id: int }

entities: #soa [100]Entity

e := entities[5]  // Returns Entity (reconstructed from SOA layout)
entities[5].x = 10.0  // Direct field access
```

### 7.2 SOA Slicing

```odin
entities: #soa [100]Entity

slice := entities[10:20]  // #soa []Entity
```

**Addressability:** SOA fixed arrays must be addressable to slice.

---

## 8. String Indexing

### 8.1 Byte Access

```odin
s: string = "hello"
b := s[0]  // u8 (ASCII value of 'h')
```

### 8.2 String16 Access

```odin
s: string16 = ...
c := s[0]  // u16
```

### 8.3 No Rune Indexing

String indexing returns bytes, not runes:

```odin
s := "hello"
// s[i] returns u8, not rune
// Use utf8.decode_rune or iterate for runes
```

---

## 9. Constant Indexing

### 9.1 Constant Propagation

Indexing a constant with a constant index yields a constant:

```odin
ARR :: [3]int{10, 20, 30}
X :: ARR[1]  // X is constant 20
```

### 9.2 Variable Index on Constant

```odin
ARR :: [3]int{10, 20, 30}
i := get_index()
x := ARR[i]  // ERROR: Cannot index a constant with variable index
             // Suggestion: store the constant into a variable
```

### 9.3 Types Supporting Constant Indexing

- Arrays (`[N]T`)
- Enumerated arrays (`[E]T`)
- Slices (constant slice values)
- Strings
- Matrices

---

## 10. Addressing Modes After Indexing

| Source | Result Mode |
|--------|-------------|
| Variable array | Variable (assignable) |
| Pointer to array | Variable (assignable) |
| Value array (temporary) | Value (read-only) |
| Constant | Constant (if index constant) |
| Slice | Variable |
| Dynamic array | Variable |
| Map | MapIndex (special) |
| SOA | SoaVariable |

---

## 11. Bounds Check Control

### 11.1 Build Flag

```bash
odin build . -no-bounds-check  # Disable all bounds checking
```

### 11.2 Procedure Attributes

```odin
@(no_bounds_check)
fast_access :: proc(arr: []int, i: int) -> int {
    return arr[i]  // No bounds check
}

@(bounds_check)
safe_access :: proc(arr: []int, i: int) -> int {
    return arr[i]  // Always checked
}
```

---

## 12. Error Messages

### 12.1 Type Errors

| Error | Cause |
|-------|-------|
| `Cannot index '%s' of type '%s'` | Type not indexable |
| `Cannot index constant '%s' of type '%s'` | Invalid constant indexing |
| `Missing index for '%s'` | Empty brackets `[]` |
| `Index must be an integer` | Non-integer, non-enum index |
| `Index '%s' must be an enum of type '%s'` | Wrong enum type for enumerated array |

### 12.2 Bounds Errors

| Error | Cause |
|-------|-------|
| `Index cannot be a negative value` | Negative constant index |
| `Index is out of bounds` | Constant exceeds array length |
| `Index is out of bounds range A ..= B` | Enum index outside valid range |
| `Invalid slice indices: [%d > %d]` | lo > hi in slice |

### 12.3 Enumerated Array Errors

| Error | Cause |
|-------|-------|
| `Non-contiguous enumeration used as index` | Gaps without #sparse |
| `Cannot slice enumerated arrays` | Slicing not supported |

### 12.4 Slice Errors

| Error | Cause |
|-------|-------|
| `Cannot slice array '%s', value is not addressable` | Temporary array |
| `Cannot slice '%s' of type '%s'` | Type not sliceable |
| `Cannot slice constant value '%s'` | Variable slice on constant |

---

## 13. Enumerated Array Literals

### 13.1 Full Initialization

```odin
Color :: enum { Red, Green, Blue }

// All fields required (unless #partial)
colors := [Color]string{
    .Red = "red",
    .Green = "green",
    .Blue = "blue",
}
```

### 13.2 Bare Elements Not Allowed

```odin
// ERROR: Enumerated array literals must only have 'field = value' elements
colors := [Color]string{"red", "green", "blue"}
```

### 13.3 Missing Cases Error

```odin
colors := [Color]string{
    .Red = "red",
    // ERROR: Unhandled enumerated array cases: Green, Blue
}
```

---

## 14. Type Introspection

### 14.1 type_is_enumerated_array

```odin
import "core:intrinsics"

T :: [Color]int
is_ea := intrinsics.type_is_enumerated_array(T)  // true
```

### 14.2 Runtime Type Info

```odin
info := type_info_of([Color]int)
// info is Type_Info_Enumerated_Array with:
// - index type
// - element type
// - min/max values
// - is_sparse flag
```
