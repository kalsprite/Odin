# Odin Type Conversions

*Extracted from: src/check_expr.cpp*

## 1. Conversion Categories

Odin has three categories of type conversions:

1. **Implicit (Assignment)** - Automatic, no syntax required
2. **Explicit (Cast)** - Requires `cast(T)x` syntax
3. **Transmute** - Bit-level reinterpretation, requires `transmute(T)x`

---

## 2. Implicit Conversions (Assignment Compatible)

### 2.1 Identical Types

Types that are identical are always assignment compatible.

### 2.2 Untyped Constants

Untyped constants convert implicitly to compatible typed values:

| Untyped Type | Converts To |
|--------------|-------------|
| `untyped_bool` | Any boolean type |
| `untyped_int` | Any integer or rune type |
| `untyped_rune` | Any integer or rune type |
| `untyped_float` | Any float type |
| `untyped_complex` | Any complex type, any quaternion type |
| `untyped_quaternion` | Any quaternion type |
| `untyped_string` | Any string type |
| `untyped_nil` | Types with nil (pointers, slices, maps, procs, unions, etc.) |

### 2.3 Pointer Conversions

| From | To | Implicit |
|------|-----|----------|
| `^T` | `rawptr` | Yes |
| `[^]T` | `rawptr` | Yes |
| `^T` | `[^]T` | Yes (same T) |
| `[^]T` | `^T` | Yes (same T) |

### 2.4 Union Variant Assignment

A value can be implicitly assigned to a union if it matches one of the variants:

```odin
Value :: union {int, f32, string}
v: Value = 42      // OK: int is a variant
v = 3.14           // OK: f32 is a variant
v = "hello"        // OK: string is a variant
```

### 2.5 Subtype (Using) Assignment

If type B has A as a subtype via `using`, values of A can be assigned where B is expected:

```odin
Base :: struct { x: int }
Derived :: struct { using base: Base, y: int }

b: Base = {10}
d: Derived
d.base = b  // OK
```

### 2.6 Complex/Quaternion Widening

| From | To |
|------|-----|
| Float | Complex (same precision) |
| Float | Quaternion (same precision) |
| Complex | Quaternion (same precision) |

### 2.7 Array/SIMD Broadcasting

Scalars can be implicitly broadcast to arrays or SIMD vectors:

```odin
a: [4]int = 5      // OK: broadcasts to {5, 5, 5, 5}
v: #simd[4]f32 = 1.0  // OK: broadcasts
```

### 2.8 Matrix Identity Initialization

Scalars can initialize square matrices as scaled identity:

```odin
m: matrix[3,3]f32 = 1.0  // Identity matrix
```

### 2.9 Any Type

Any non-polymorphic value can be assigned to `any`:

```odin
a: any = 42
a = "hello"
a = [3]int{1,2,3}
```

Note: `context` values cannot be assigned to `any`.

### 2.10 Polymorphic Procedures

Polymorphic procedures can be assigned where a monomorphic procedure type is expected if instantiation is possible.

### 2.11 Enum Base Type (In Enum Context)

Within an enum definition, values of the base type can be assigned:

```odin
Flags :: enum u8 {
    A = 1,      // OK: literal -> u8 -> Flags
    B = 1 << 1, // OK
}
```

---

## 3. Explicit Casts

Use `cast(T)x` to perform explicit conversions.

### 3.1 Numeric Conversions

All numeric types can be cast between each other:

| From | To | Notes |
|------|-----|-------|
| Integer | Integer | Truncation/sign extension |
| Integer | Float | Precision loss possible |
| Float | Integer | Truncation toward zero |
| Float | Float | Precision change |
| Integer | Boolean | 0 = false, non-zero = true |
| Boolean | Integer | false = 0, true = 1 |
| Integer | Rune | Direct cast |
| Rune | Integer | Direct cast |

### 3.2 Complex/Quaternion Casts

| From | To | Notes |
|------|-----|-------|
| Complex | Complex | Precision change |
| Quaternion | Quaternion | Precision change |
| Float | Complex | Real part only |
| Float | Quaternion | Real part only |
| Complex | Quaternion | Complex subset |

### 3.3 Pointer Casts

| From | To | Notes |
|------|-----|-------|
| `^T` | `^U` | Any pointer to any pointer |
| `[^]T` | `[^]U` | Multi-pointer to multi-pointer |
| `^T` | `[^]U` | Pointer to multi-pointer |
| `[^]T` | `^U` | Multi-pointer to pointer |
| `uintptr` | `^T` | Integer to pointer |
| `^T` | `uintptr` | Pointer to integer |
| `uintptr` | `[^]T` | Integer to multi-pointer |
| `[^]T` | `uintptr` | Multi-pointer to integer |

### 3.4 String Conversions

| From | To | Notes |
|------|-----|-------|
| `[]u8` | `string` | Slice to string |
| `[]u16` | `string16` | Slice to string16 |
| `cstring` | `string` | C string to Odin string |
| `cstring16` | `string16` | C string16 to string16 |
| `cstring` | `^u8` | Not for constants |
| `cstring` | `[^]u8` | Not for constants |
| `cstring` | `rawptr` | Not for constants |
| `^u8` | `cstring` | Not for constants |
| `[^]u8` | `cstring` | Not for constants |
| `rawptr` | `cstring` | Not for constants |

Similar rules apply for `cstring16` ↔ `^u16`/`[^]u16`/`rawptr`.

### 3.5 Constant String to Array

Constant strings can be cast to fixed arrays:

```odin
s :: "hello"
a := cast([5]u8)s     // OK: length matches
r := cast([5]rune)s   // OK: rune count matches
```

### 3.6 Procedure Casts

| From | To | Notes |
|------|-----|-------|
| `proc(...)` | `proc(...)` | Any proc to any proc |
| `proc(...)` | `rawptr` | Procedure to raw pointer |
| `rawptr` | `proc(...)` | Raw pointer to procedure |

### 3.7 Matrix Casts

Matrices can be cast between compatible sizes:
- Square matrices can cast to other square matrices
- Non-square matrices can cast if total element count matches

Element types must be castable.

### 3.8 SIMD Vector Casts

SIMD vectors can be cast if:
- Lane counts are equal
- Element types are castable

### 3.9 Array Casts

Arrays can be cast if:
- Element counts match
- Element types are identical

### 3.10 Bit Field Casts

Bit fields can be cast to/from their backing type:

```odin
BF :: bit_field u32 { a: u8 | 8, b: u8 | 8 }
bf: BF
raw := cast(u32)bf   // OK
bf2 := cast(BF)raw   // OK
```

### 3.11 Scalar to Array/Vector

A scalar can be cast to an array or SIMD vector (broadcast):

```odin
a := cast([4]int)5      // {5, 5, 5, 5}
v := cast(#simd[4]f32)1.0
```

---

## 4. Transmute

`transmute(T)x` reinterprets the bits of x as type T.

### 4.1 Requirements

- `size_of(T) == size_of(type_of(x))`
- Result is unspecified if alignment requirements aren't met

### 4.2 Common Uses

```odin
// Reinterpret float bits as integer
f: f32 = 3.14
bits := transmute(u32)f

// Pointer type punning
p: ^int = ...
raw := transmute(rawptr)p

// Struct to array
Vec3 :: struct { x, y, z: f32 }
v: Vec3 = {1, 2, 3}
arr := transmute([3]f32)v
```

---

## 5. Auto Cast

`auto_cast x` automatically casts x to the expected type if a cast is valid:

```odin
ptr: rawptr = ...
int_ptr := auto_cast ptr  // Inferred as ^int from context
```

Equivalent to writing `cast(T)x` where T is inferred from context.

---

## 6. Type Distance Scoring

The type checker uses a scoring system to rank conversion quality:

| Conversion Type | Base Score |
|-----------------|------------|
| Identical types | 0 |
| Untyped → typed (exact match) | 1 |
| Untyped → typed (compatible) | 2 |
| Enum base type in context | 3 |
| Proc matching | 3-4 |
| Subtype via using | 4+ level |
| Pointer → rawptr | 5 |
| Multi-pointer ↔ pointer | 4 |
| Complex element match | 5 |
| Array/SIMD broadcast | 6+ |
| Matrix broadcast | 7+ |
| To `any` | Maximum |

Lower scores are preferred in overload resolution.

---

## 7. Conversion Errors

### 7.1 Common Error Messages

- `Cannot convert '%s' to '%s'` - Types incompatible
- `Cannot cast '%s' as '%s'` - Cast not allowed
- `String concatenation is only allowed with constant strings` - Runtime string +
- `Cannot convert numeric value '%s' from '%s' to '%s'` - Value out of range
- `Cannot convert untyped value '%s' to '%s'` - Untyped incompatible
- `Cannot assign to '%s'` - Target not assignable

### 7.2 Suggestions

The checker provides suggestions for common mistakes:
- Using `*ptr` instead of `ptr^` for dereference
- Using `!x` on integers instead of `~x` or `x == 0`

---

## 8. Nil Compatibility

Types that accept `nil`:

| Type | Nil Meaning |
|------|-------------|
| `^T` | Null pointer |
| `[^]T` | Null multi-pointer |
| `rawptr` | Null pointer |
| `[]T` | Empty slice (nil ptr, 0 len) |
| `[dynamic]T` | Empty dynamic array |
| `map[K]V` | Empty map |
| `proc(...)` | Null procedure |
| `union` | No variant (unless `#no_nil`) |
| `cstring` | Null C string |
| `any` | No value |
| `typeid` | Invalid type |

Types that do NOT accept `nil`:
- Basic types (int, float, bool, etc.)
- Arrays
- Structs
- Enums
- Bit sets
- Matrices
- SIMD vectors

---

## 9. Conversion Table Summary

| From ↓ / To → | int | float | bool | ptr | slice | string | any |
|---------------|-----|-------|------|-----|-------|--------|-----|
| int | cast | cast | cast | - | - | - | impl |
| float | cast | cast | - | - | - | - | impl |
| bool | cast | - | impl | - | - | - | impl |
| ptr | uintptr | - | - | cast | - | - | impl |
| slice | - | - | - | - | impl | cast* | impl |
| string | - | - | - | - | cast* | impl | impl |
| untyped_int | impl | impl | impl | - | - | - | impl |
| untyped_float | - | impl | - | - | - | - | impl |

Legend:
- `impl` = implicit (assignment compatible)
- `cast` = explicit cast required
- `cast*` = cast with restrictions
- `-` = not convertible
