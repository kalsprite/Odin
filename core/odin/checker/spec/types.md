# Odin Type System Specification

*Extracted from: src/types.cpp*

## 1. Basic Types

### 1.1 BasicKind Enumeration

| Kind | Description |
|------|-------------|
| `bool` | Boolean (native) |
| `b8`, `b16`, `b32`, `b64` | Sized booleans |
| `i8`, `i16`, `i32`, `i64`, `i128` | Signed integers |
| `u8`, `u16`, `u32`, `u64`, `u128` | Unsigned integers |
| `int`, `uint`, `uintptr` | Platform-sized integers |
| `f16`, `f32`, `f64` | Floating point |
| `complex32`, `complex64`, `complex128` | Complex numbers |
| `quaternion64`, `quaternion128`, `quaternion256` | Quaternions |
| `rune` | Unicode codepoint (i32) |
| `string` | UTF-8 string ([]u8 + length) |
| `cstring` | C-style null-terminated string |
| `rawptr` | Untyped pointer |
| `any` | Dynamic type (rawptr + ^Type_Info) |
| `typeid` | Type identifier |

### 1.2 BasicFlags (Properties)

```
BasicFlag_Boolean     - Is a boolean type
BasicFlag_Integer     - Is an integer type
BasicFlag_Unsigned    - Is unsigned
BasicFlag_Float       - Is floating point
BasicFlag_Complex     - Is complex number
BasicFlag_Quaternion  - Is quaternion
BasicFlag_Pointer     - Is pointer-like
BasicFlag_String      - Is string type
BasicFlag_Rune        - Is rune type
BasicFlag_Untyped     - Is untyped constant
```

### 1.3 Composite Flags

```
Numeric        = Integer | Float | Complex | Quaternion
Ordered        = Integer | Float | String | Pointer | Rune
OrderedNumeric = Integer | Float | Rune
ConstantType   = Boolean | Numeric | String | Pointer | Rune
SimpleCompare  = Boolean | Integer | Pointer | Rune
```

## 2. Composite Types

### 2.1 Struct
- Fields with types and tags
- Optional: packed, raw_union, all_or_none
- SOA variants: Fixed, Slice, Dynamic
- Polymorphic support

### 2.2 Union
- Variant types list
- Tag type (u8/u16/u32/u64 based on variant count)
- Kinds: Normal, no_nil, shared_nil, maybe

### 2.3 Enum
- Base type (integer)
- Named values
- Optional: #flags for bitfield enums

### 2.4 Array
- Element type
- Count (compile-time constant)
- Special: [?]T for inferred count

### 2.5 Slice
- Element type
- Runtime: pointer + length

### 2.6 Dynamic Array
- Element type  
- Runtime: pointer + length + capacity + allocator

### 2.7 Map
- Key type (must satisfy key constraints)
- Value type

### 2.8 Pointer Types
- `^T` - Single pointer
- `[^]T` - Multi-pointer
- `#soa ^T` - SOA pointer

### 2.9 Procedure Type
- Parameters (with flags: #no_alias, #any_int, #by_ptr, etc.)
- Results
- Calling convention
- Optional: diverging, contextless

## 3. Type Compatibility Rules

*See conversions.md for detailed rules*
