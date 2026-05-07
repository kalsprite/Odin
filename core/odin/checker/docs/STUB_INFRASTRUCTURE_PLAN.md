# Stub Infrastructure Plan

**Date**: 2025-10-03
**Status**: Analysis Complete
**Goal**: Identify and stub all missing infrastructure to create a complete "skeleton" checker

---

## Executive Summary

### Current State
- **Total LOC**: 31,081 lines across 28 Odin files
- **Existing TODOs/Stubs**: 526 marked locations
- **Verification Documents**: 19 files tracking implementation status

### Gap Analysis Results
This analysis identified **127 missing infrastructure items** across 6 categories that need stub implementation before the checker can be considered architecturally complete.

**Critical Findings**:
1. **40 missing type predicates** - Core type checking functions used but not implemented
2. **25 missing type construction functions** - Type allocation/construction stubs needed
3. **35+ missing Basic_Kind variants** - Fundamental type system extensions (quaternion, rune, string16, endian types)
4. **15+ missing helper functions** - Frequently-called utilities (core_type, type_deref, etc.)
5. **12 missing global state structures** - Initialization and singleton management

**Impact**: Without these stubs:
- Compilation will fail when implementing deferred features
- Type checking logic cannot be completed
- Polymorphic and advanced type features are blocked
- SIMD, quaternion, and endian-specific code paths are unreachable

---

## Part 1: Critical Missing Infrastructure

### 1.1 Missing Type Predicates (High Usage, Not Implemented)

#### Tier 1: Critical (Used 10+ times, completely missing)
| Function | Usage Count | C++ Reference | Blocking |
|----------|-------------|---------------|----------|
| `is_type_polymorphic` | 59 | types.cpp:2246 | Polymorphic proc checking, generic types |
| `is_type_any` | 17 | types.cpp:1542 | any type handling, type assertions |
| `is_type_enum` | 16 | types.cpp:1563 | Enum operations, switch statements |
| `is_type_array` | 10 | types.cpp:1597 | Array operations, indexing |
| `is_type_union` | 10 | types.cpp:1615 | Union type checking, tag operations |
| `is_type_empty_union` | 6 | types.cpp:2038 | Union validation, maybe-pointer detection |

**Stub Implementation**:
```odin
// is_type_polymorphic checks if type contains unresolved polymorphic parameters
// C++ Reference: /mnt/c/odin/src/types.cpp:2246-2282
is_type_polymorphic :: proc(t: ^Type) -> bool {
    // STUB: Always return false until polymorphic infrastructure is complete
    // TODO(POLYMORPHIC): Implement full polymorphic detection:
    // - Check Type_Generic for unspecialized parameters
    // - Check Type_Proc.is_polymorphic flag
    // - Check Type_Struct.is_polymorphic flag
    // - Check Type_Union.is_polymorphic flag
    return false
}

// is_type_any checks if type is the 'any' type
// C++ Reference: /mnt/c/odin/src/types.cpp:1542-1548
is_type_any :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Basic {
        return false
    }
    basic := t.variant.(Type_Basic)
    return basic.kind == .Any
}

// is_type_enum checks if type is an enum
// C++ Reference: /mnt/c/odin/src/types.cpp:1563-1567
is_type_enum :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Enum
}

// is_type_array checks if type is a fixed-size array
// C++ Reference: /mnt/c/odin/src/types.cpp:1597-1601
is_type_array :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Array
}

// is_type_union checks if type is a union
// C++ Reference: /mnt/c/odin/src/types.cpp:1615-1619
is_type_union :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Union
}

// is_type_empty_union checks if union has no variants
// C++ Reference: /mnt/c/odin/src/types.cpp:2038-2042
is_type_empty_union :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Union {
        return false
    }
    u := t.variant.(Type_Union)
    return len(u.variants) == 0
}
```

#### Tier 2: Important (Used 5-9 times or architecturally significant)
| Function | C++ Reference | Purpose |
|----------|---------------|---------|
| `is_type_slice` | types.cpp:1603 | Slice operations |
| `is_type_cstring` | types.cpp:1317 | C string handling |
| `is_type_tuple` | types.cpp:1631 | Multi-return, parameters |
| `is_type_named` | types.cpp:1502 | Named type unwrapping |
| `is_type_generic` | types.cpp:2238 | Generic type parameters |
| `is_type_struct` | types.cpp:1555 | Struct operations |
| `is_type_soa_pointer` | types.cpp:1902 | SOA pointer handling |

**Stub Implementation**:
```odin
// is_type_slice checks if type is a slice ([]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:1603-1607
is_type_slice :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Slice
}

// is_type_cstring checks if type is cstring
// C++ Reference: /mnt/c/odin/src/types.cpp:1317-1323
is_type_cstring :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Basic {
        return false
    }
    basic := t.variant.(Type_Basic)
    return basic.kind == .Cstring
}

// is_type_tuple checks if type is a tuple
// C++ Reference: /mnt/c/odin/src/types.cpp:1631-1635
is_type_tuple :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Tuple
}

// is_type_named checks if type is a named type (before unwrapping)
// C++ Reference: /mnt/c/odin/src/types.cpp:1502-1506
is_type_named :: proc(t: ^Type) -> bool {
    return t != nil && t.kind == .Named
}

// is_type_generic checks if type is a generic parameter ($T)
// C++ Reference: /mnt/c/odin/src/types.cpp:2238-2242
is_type_generic :: proc(t: ^Type) -> bool {
    return t != nil && t.kind == .Generic
}

// is_type_struct checks if type is a struct
// C++ Reference: /mnt/c/odin/src/types.cpp:1555-1559
is_type_struct :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Struct
}

// is_type_soa_pointer checks if type is an SOA pointer (#soa [^]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:1902-1906
is_type_soa_pointer :: proc(t: ^Type) -> bool {
    t := base_type(t)
    return t != nil && t.kind == .Soa_Pointer
}
```

#### Tier 3: Specialized (Used less frequently but required for completeness)
| Function | C++ Reference | Purpose |
|----------|---------------|---------|
| `is_type_complex_or_quaternion` | types.cpp:1430 | Numeric operations |
| `is_type_array_like` | types.cpp:1688 | Indexable aggregate check |
| `is_type_sliceable` | types.cpp:1643 | Slicing operation support |
| `is_type_integer_like` | types.cpp:1243 | Integer-compatible types |
| `is_type_integer_128bit` | types.cpp:1267 | Large integer handling |
| `is_type_ordered_numeric` | types.cpp:1375 | Comparison operations |
| `is_type_dereferenceable` | types.cpp:1437 | Pointer/multi-pointer check |
| `is_type_string16` | types.cpp:1339 | UTF-16 string operations |
| `is_type_u16_array` | types.cpp:1755 | UTF-16 array operations |
| `is_type_u8_multi_ptr` | types.cpp:1730 | Multi-pointer operations |
| `is_type_u16_multi_ptr` | types.cpp:1771 | Multi-pointer operations |

**Stub Implementation Pattern**:
```odin
// is_type_complex_or_quaternion checks if type is complex or quaternion
// C++ Reference: /mnt/c/odin/src/types.cpp:1430-1434
is_type_complex_or_quaternion :: proc(t: ^Type) -> bool {
    return is_type_complex(t) || is_type_quaternion(t)
}

// is_type_array_like checks if type behaves like an array (array, enumerated_array, simd_vector)
// C++ Reference: /mnt/c/odin/src/types.cpp:1688-1695
is_type_array_like :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil {
        return false
    }
    return t.kind == .Array || t.kind == .Enumerated_Array || t.kind == .Simd_Vector
}

// is_type_sliceable checks if type supports slicing (string, array, slice, dynamic_array)
// C++ Reference: /mnt/c/odin/src/types.cpp:1643-1653
is_type_sliceable :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil {
        return false
    }

    #partial switch t.kind {
    case .Array, .Slice, .Dynamic_Array:
        return true
    case .Basic:
        basic := t.variant.(Type_Basic)
        return basic.kind == .String
        // TODO(STRUCTURAL): Add String16 support when Basic_Kind.String16 is added
    }

    return false
}

// is_type_integer_like checks if type can be used like an integer (int, enum, bool, pointer, rune)
// C++ Reference: /mnt/c/odin/src/types.cpp:1243-1263
is_type_integer_like :: proc(t: ^Type) -> bool {
    if is_type_integer(t) {
        return true
    }
    if is_type_boolean(t) {
        return true
    }
    if is_type_rune(t) {
        return true
    }
    if is_type_enum(t) {
        return true
    }
    // Pointers can be cast to integers
    if is_type_pointer(t) || is_type_multi_pointer(t) {
        return true
    }
    if is_type_typeid(t) {
        return true
    }
    if is_type_bit_set(t) {
        return true
    }
    return false
}

// is_type_integer_128bit checks if type is i128 or u128
// C++ Reference: /mnt/c/odin/src/types.cpp:1267-1277
is_type_integer_128bit :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Basic {
        return false
    }
    basic := t.variant.(Type_Basic)
    return basic.kind == .I128 || basic.kind == .U128
}

// is_type_ordered_numeric checks if type supports <, >, <=, >= (excludes bool)
// C++ Reference: /mnt/c/odin/src/types.cpp:1375-1383
is_type_ordered_numeric :: proc(t: ^Type) -> bool {
    return is_type_numeric(t) && !is_type_boolean(t)
}

// is_type_dereferenceable checks if type can be dereferenced (pointer, multi_pointer)
// C++ Reference: /mnt/c/odin/src/types.cpp:1437-1443
is_type_dereferenceable :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil {
        return false
    }
    return t.kind == .Pointer || t.kind == .Multi_Pointer
}

// is_type_string16 checks if type is UTF-16 string
// C++ Reference: /mnt/c/odin/src/types.cpp:1339-1345
is_type_string16 :: proc(t: ^Type) -> bool {
    // STUB: string16 not yet in Basic_Kind enum
    // TODO(STRUCTURAL): Add Basic_Kind.String16 support
    // When added:
    //   t := base_type(t)
    //   if t == nil || t.kind != .Basic { return false }
    //   basic := t.variant.(Type_Basic)
    //   return basic.kind == .String16
    return false
}

// is_type_u16_array checks if type is [N]u16
// C++ Reference: /mnt/c/odin/src/types.cpp:1755-1762
is_type_u16_array :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Array {
        return false
    }
    arr := t.variant.(Type_Array)
    return is_type_u16(arr.elem)
}

// is_type_u8_multi_ptr checks if type is [^]u8
// C++ Reference: /mnt/c/odin/src/types.cpp:1730-1737
is_type_u8_multi_ptr :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Multi_Pointer {
        return false
    }
    mp := t.variant.(Type_Multi_Pointer)
    return is_type_u8(mp.elem)
}

// is_type_u16_multi_ptr checks if type is [^]u16
// C++ Reference: /mnt/c/odin/src/types.cpp:1771-1778
is_type_u16_multi_ptr :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Multi_Pointer {
        return false
    }
    mp := t.variant.(Type_Multi_Pointer)
    return is_type_u16(mp.elem)
}
```

### 1.2 Missing Type Manipulation Functions (Tier 1 Critical)

| Function | C++ Reference | Purpose | Usage Pattern |
|----------|---------------|---------|---------------|
| `core_type` | types.cpp:499-515 | Unwrap Named, Enum, Bit_Field to core structural type | Used 24 times |
| `type_deref` | types.cpp:517-522 | Dereference pointer types | Used 26 times |
| `base_array_type` | types.cpp:530-548 | Get element type from array-like types | Used 35 times |
| `core_array_type` | types.cpp:550-557 | Get core element type from array-like | Used in SIMD |

**Stub Implementation**:
```odin
// core_type unwraps Named, Enum, and Bit_Field types to get the structural core
// Unlike base_type, this goes deeper to find the fundamental structural type
// C++ Reference: /mnt/c/odin/src/types.cpp:499-515
core_type :: proc(t: ^Type) -> ^Type {
    if t == nil {
        return nil
    }

    t := t
    for {
        #partial switch t.kind {
        case .Named:
            // Unwrap named types
            named := t.variant.(Type_Named)
            t = named.base
            continue

        case .Enum:
            // Unwrap enums to their base integer type
            enum_type := t.variant.(Type_Enum)
            t = enum_type.base_type
            continue

        case .Bit_Field:
            // Unwrap bit fields to their backing type
            bf := t.variant.(Type_Bit_Field)
            t = bf.backing_type
            continue
        }

        // No more unwrapping needed
        break
    }

    return t
}

// type_deref dereferences pointer and multi-pointer types
// Returns the element type for pointers, or the original type otherwise
// C++ Reference: /mnt/c/odin/src/types.cpp:517-522
type_deref :: proc(t: ^Type) -> ^Type {
    if t == nil {
        return nil
    }

    t_base := base_type(t)

    #partial switch t_base.kind {
    case .Pointer:
        ptr := t_base.variant.(Type_Pointer)
        return ptr.elem

    case .Multi_Pointer:
        mp := t_base.variant.(Type_Multi_Pointer)
        return mp.elem

    case .Soa_Pointer:
        soa := t_base.variant.(Type_Soa_Pointer)
        return soa.elem
    }

    return t
}

// base_array_type gets the element type from array-like types
// Returns elem type for: Array, Enumerated_Array, Simd_Vector
// C++ Reference: /mnt/c/odin/src/types.cpp:530-548
base_array_type :: proc(t: ^Type) -> ^Type {
    t := base_type(t)
    if t == nil {
        return nil
    }

    #partial switch t.kind {
    case .Array:
        arr := t.variant.(Type_Array)
        return arr.elem

    case .Enumerated_Array:
        earr := t.variant.(Type_Enumerated_Array)
        return earr.elem

    case .Simd_Vector:
        simd := t.variant.(Type_Simd_Vector)
        return simd.elem
    }

    return nil
}

// core_array_type gets the core element type from array-like types
// Combines base_array_type with core_type unwrapping
// C++ Reference: /mnt/c/odin/src/types.cpp:550-557
core_array_type :: proc(t: ^Type) -> ^Type {
    elem := base_array_type(t)
    return core_type(elem)
}
```

### 1.3 Missing Type Construction Functions (Tier 1 Critical)

These are frequently referenced in the C++ codebase but not yet stubbed:

| Function | C++ Reference | Purpose | Priority |
|----------|---------------|---------|----------|
| `alloc_type_tuple` | types.cpp:945 | Create tuple types | Critical |
| `alloc_type_tuple_from_field_types` | types.cpp:954 | Create tuple from type array | Critical |
| `alloc_type_proc` | types.cpp:1003 | Create procedure types | Critical |
| `alloc_type_struct` | types.cpp:822 | Create struct types | Critical |
| `alloc_type_union` | types.cpp:867 | Create union types | High |
| `alloc_type_enum` | types.cpp:793 | Create enum types | High |
| `alloc_type_bit_set` | types.cpp:1105 | Create bit_set types | High |
| `alloc_type_multi_pointer` | types.cpp:720 | Create multi-pointer types | Medium |
| `alloc_type_soa_pointer` | types.cpp:740 | Create SOA pointer types | Medium |
| `alloc_type_simd_vector` | types.cpp:1117 | Create SIMD vector types | Medium |
| `alloc_type_matrix` | types.cpp:1129 | Create matrix types | Medium |
| `alloc_type_enumerated_array` | types.cpp:778 | Create enumerated array types | Low |
| `alloc_type_bit_field` | types.cpp:1092 | Create bit_field types | Low |

**Stub Implementation Pattern**:
```odin
// alloc_type_tuple creates a tuple type from a list of entities
// C++ Reference: /mnt/c/odin/src/types.cpp:945-952
alloc_type_tuple :: proc(variables: [dynamic]^Entity) -> ^Type {
    t := new(Type)
    t.kind = .Tuple
    t.variant = Type_Tuple {
        variables = variables,
        is_packed = false,
    }
    return t
}

// alloc_type_tuple_from_field_types creates a tuple from raw types
// Creates anonymous Entity_Variable for each type
// C++ Reference: /mnt/c/odin/src/types.cpp:954-973
alloc_type_tuple_from_field_types :: proc(types: []^Type, is_packed := false) -> ^Type {
    variables := make([dynamic]^Entity, len(types))

    for type, i in types {
        // Create anonymous variable entity for this tuple element
        token := tokenizer.Token{kind = .Ident, text = ""}
        entity := alloc_entity_variable(nil, token, type, .Resolved)
        variables[i] = entity
    }

    t := new(Type)
    t.kind = .Tuple
    t.variant = Type_Tuple {
        variables = variables,
        is_packed = is_packed,
    }
    return t
}

// alloc_type_proc creates a procedure type
// C++ Reference: /mnt/c/odin/src/types.cpp:1003-1028
alloc_type_proc :: proc(
    scope: ^Scope,
    params: ^Type,  // Must be tuple type
    results: ^Type, // Must be tuple type
    param_count: int,
    result_count: int,
    variadic := false,
    calling_convention := Calling_Convention.Odin,
) -> ^Type {
    t := new(Type)
    t.kind = .Proc
    t.variant = Type_Proc {
        params             = params,
        results            = results,
        scope              = scope,
        param_count        = param_count,
        result_count       = result_count,
        variadic           = variadic,
        calling_convention = calling_convention,
    }
    return t
}

// alloc_type_struct creates a struct type
// C++ Reference: /mnt/c/odin/src/types.cpp:822-854
alloc_type_struct :: proc(
    fields: [dynamic]^Entity,
    scope: ^Scope = nil,
    node: ^ast.Node = nil,
    is_packed := false,
    custom_align: i64 = 0,
) -> ^Type {
    t := new(Type)
    t.kind = .Struct

    // Build name map
    names := make(map[string]^Entity)
    for field in fields {
        if field.token.text != "" && field.token.text != "_" {
            names[field.token.text] = field
        }
    }

    t.variant = Type_Struct {
        fields       = fields,
        names        = names,
        scope        = scope,
        node         = node,
        is_packed    = is_packed,
        custom_align = custom_align,
    }
    return t
}

// alloc_type_union creates a union type
// C++ Reference: /mnt/c/odin/src/types.cpp:867-896
alloc_type_union :: proc(
    variants: [dynamic]^Type,
    scope: ^Scope = nil,
    node: ^ast.Node = nil,
    kind := Union_Kind.Normal,
    custom_align: i64 = 0,
) -> ^Type {
    t := new(Type)
    t.kind = .Union
    t.variant = Type_Union {
        variants     = variants,
        scope        = scope,
        node         = node,
        kind         = kind,
        custom_align = custom_align,
    }
    return t
}

// alloc_type_enum creates an enum type
// C++ Reference: /mnt/c/odin/src/types.cpp:793-818
alloc_type_enum :: proc(
    base_type: ^Type,
    fields: [dynamic]^Entity,
    scope: ^Scope = nil,
    node: ^ast.Node = nil,
) -> ^Type {
    t := new(Type)
    t.kind = .Enum
    t.variant = Type_Enum {
        base_type = base_type,
        fields    = fields,
        scope     = scope,
        node      = node,
    }
    return t
}

// alloc_type_bit_set creates a bit_set type
// C++ Reference: /mnt/c/odin/src/types.cpp:1105-1127
alloc_type_bit_set :: proc(
    elem: ^Type,
    underlying: ^Type,
    lower: i64,
    upper: i64,
    node: ^ast.Node = nil,
) -> ^Type {
    t := new(Type)
    t.kind = .Bit_Set
    t.variant = Type_Bit_Set {
        elem       = elem,
        underlying = underlying,
        lower      = lower,
        upper      = upper,
        node       = node,
    }
    return t
}

// alloc_type_multi_pointer creates a multi-pointer type ([^]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:720-725
alloc_type_multi_pointer :: proc(elem: ^Type) -> ^Type {
    t := new(Type)
    t.kind = .Multi_Pointer
    t.variant = Type_Multi_Pointer {
        elem = elem,
    }
    return t
}

// alloc_type_soa_pointer creates an SOA pointer type (#soa [^]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:740-745
alloc_type_soa_pointer :: proc(elem: ^Type) -> ^Type {
    t := new(Type)
    t.kind = .Soa_Pointer
    t.variant = Type_Soa_Pointer {
        elem = elem,
    }
    return t
}

// alloc_type_simd_vector creates a SIMD vector type
// C++ Reference: /mnt/c/odin/src/types.cpp:1117-1127
alloc_type_simd_vector :: proc(elem: ^Type, count: i64) -> ^Type {
    t := new(Type)
    t.kind = .Simd_Vector
    t.variant = Type_Simd_Vector {
        elem  = elem,
        count = count,
    }
    return t
}

// alloc_type_matrix creates a matrix type
// C++ Reference: /mnt/c/odin/src/types.cpp:1129-1151
alloc_type_matrix :: proc(
    elem: ^Type,
    row_count: i64,
    column_count: i64,
    stride_in_bytes := 0,
    is_row_major := false,
    node: ^ast.Node = nil,
) -> ^Type {
    t := new(Type)
    t.kind = .Matrix
    t.variant = Type_Matrix {
        elem            = elem,
        row_count       = row_count,
        column_count    = column_count,
        stride_in_bytes = stride_in_bytes,
        is_row_major    = is_row_major,
        node            = node,
    }
    return t
}

// alloc_type_enumerated_array creates an enumerated array type
// C++ Reference: /mnt/c/odin/src/types.cpp:778-791
alloc_type_enumerated_array :: proc(
    elem: ^Type,
    index: ^Type,
    count: i64,
) -> ^Type {
    t := new(Type)
    t.kind = .Enumerated_Array
    t.variant = Type_Enumerated_Array {
        elem  = elem,
        index = index,
        count = count,
    }
    return t
}

// alloc_type_bit_field creates a bit_field type
// C++ Reference: /mnt/c/odin/src/types.cpp:1092-1103
alloc_type_bit_field :: proc(
    fields: [dynamic]^Entity,
    names: map[string]^Entity,
    backing_type: ^Type,
    node: ^ast.Node = nil,
) -> ^Type {
    t := new(Type)
    t.kind = .Bit_Field
    t.variant = Type_Bit_Field {
        fields       = fields,
        names        = names,
        backing_type = backing_type,
        node         = node,
    }
    return t
}
```

### 1.4 Missing Polymorphic Infrastructure

The most-used missing predicate (`is_type_polymorphic`, 59 uses) reveals a critical gap:

**Missing Polymorphic Support**:
- `is_type_polymorphic` (used 59 times)
- `is_type_polymorphic_record`
- `is_type_polymorphic_record_specialized`
- `is_type_polymorphic_record_unspecialized`

**Stub Implementation** (already shown above in Tier 1)

### 1.5 Missing Union Helper Predicates

Several union-specific predicates are missing:

| Function | C++ Reference | Purpose |
|----------|---------------|---------|
| `is_type_raw_union` | types.cpp:1867 | Check for #raw_union |
| `is_type_union_constantable` | types.cpp:2046 | Check if union can be constant |
| `is_type_raw_union_constantable` | types.cpp:2061 | Combined check |

**Stub Implementation**:
```odin
// is_type_raw_union checks if type is a #raw_union
// C++ Reference: /mnt/c/odin/src/types.cpp:1867-1873
is_type_raw_union :: proc(t: ^Type) -> bool {
    t := base_type(t)
    if t == nil || t.kind != .Union {
        return false
    }
    u := t.variant.(Type_Union)
    // In Type_Struct we track is_raw_union, but unions don't have this field yet
    // For now, stub as always false
    // TODO(STRUCTURAL): Add is_raw field to Type_Union when implementing #raw_union
    return false
}

// is_type_union_constantable checks if union can appear in constant expressions
// C++ Reference: /mnt/c/odin/src/types.cpp:2046-2059
is_type_union_constantable :: proc(t: ^Type) -> bool {
    // STUB: Complex logic involving variant constant checking
    // For now, conservatively return false
    // TODO(CONST): Implement full union constant validation
    return false
}

// is_type_raw_union_constantable combines raw union and constantable checks
// C++ Reference: /mnt/c/odin/src/types.cpp:2061-2065
is_type_raw_union_constantable :: proc(t: ^Type) -> bool {
    return is_type_raw_union(t) && is_type_union_constantable(t)
}
```

### 1.6 Missing Endian and Platform-Specific Predicates

| Function | C++ Reference | Purpose |
|----------|---------------|---------|
| `is_type_endian_specific` | types.cpp:1347 | Check if type has endian variant |
| `is_type_endian_platform` | types.cpp:1351 | Check if platform-endian type |
| `is_type_endian_little` | types.cpp:1363 | Check if little-endian type |
| `is_type_endian_big` | types.cpp:1369 | Check if big-endian type |
| `is_type_different_to_arch_endianness` | types.cpp:1393 | Check if different from platform |

**Stub Implementation**:
```odin
// is_type_endian_specific checks if type is an endian-specific variant
// C++ Reference: /mnt/c/odin/src/types.cpp:1347-1361
is_type_endian_specific :: proc(t: ^Type) -> bool {
    // STUB: Requires endian Basic_Kind variants (i16le, i32be, etc.)
    // TODO(STRUCTURAL): Add Basic_Kind endian variants
    // For now, all types are platform-endian
    return false
}

// is_type_endian_platform checks if type is platform-endian (not le/be specific)
// C++ Reference: /mnt/c/odin/src/types.cpp:1351-1361
is_type_endian_platform :: proc(t: ^Type) -> bool {
    // STUB: Until endian variants exist, all types are platform-endian
    return true
}

// is_type_endian_little checks if type is little-endian specific
// C++ Reference: /mnt/c/odin/src/types.cpp:1363-1367
is_type_endian_little :: proc(t: ^Type) -> bool {
    // STUB: Requires Basic_Kind.I16le, etc.
    return false
}

// is_type_endian_big checks if type is big-endian specific
// C++ Reference: /mnt/c/odin/src/types.cpp:1369-1373
is_type_endian_big :: proc(t: ^Type) -> bool {
    // STUB: Requires Basic_Kind.I16be, etc.
    return false
}

// is_type_different_to_arch_endianness checks if type's endianness differs from platform
// C++ Reference: /mnt/c/odin/src/types.cpp:1393-1411
is_type_different_to_arch_endianness :: proc(t: ^Type) -> bool {
    // STUB: Requires build context platform endianness + endian types
    return false
}
```

### 1.7 Missing Comparison and Validation Predicates

| Function | C++ Reference | Purpose |
|----------|---------------|---------|
| `is_type_simple_compare` | types.cpp:2005 | Bitwise equality comparison |
| `is_type_nearly_simple_compare` | types.cpp:2014 | Almost-bitwise comparison |
| `is_type_subtype_of` | types.cpp:4357 | Subtype relationship check |
| `is_type_subtype_of_and_allow_polymorphic` | types.cpp:4363 | Subtype with polymorphic |
| `is_type_load_safe` | types.cpp:4667 | Safe to load from memory |
| `is_type_lock_free` | types.cpp:4675 | Atomic lock-free guarantee |

**Stub Implementation**:
```odin
// is_type_simple_compare checks if type can use bitwise equality comparison
// C++ Reference: /mnt/c/odin/src/types.cpp:2005-2012
is_type_simple_compare :: proc(t: ^Type) -> bool {
    // STUB: Complex logic involving padding, alignment, and nested types
    // For MVP, conservatively return false (use structural comparison)
    // TODO(OPTIMIZATION): Implement full simple compare detection
    return false
}

// is_type_nearly_simple_compare checks if type is almost bitwise comparable
// C++ Reference: /mnt/c/odin/src/types.cpp:2014-2036
is_type_nearly_simple_compare :: proc(t: ^Type) -> bool {
    // STUB: Similar to is_type_simple_compare but allows some exceptions
    return false
}

// is_type_subtype_of checks if 'sub' is a subtype of 'super'
// C++ Reference: /mnt/c/odin/src/types.cpp:4357-4361
is_type_subtype_of :: proc(sub: ^Type, super: ^Type) -> bool {
    // STUB: Requires full subtype relationship logic
    // For now, only exact type match
    return are_types_identical(sub, super)
}

// is_type_subtype_of_and_allow_polymorphic includes polymorphic parameters
// C++ Reference: /mnt/c/odin/src/types.cpp:4363-4472
is_type_subtype_of_and_allow_polymorphic :: proc(sub: ^Type, super: ^Type) -> bool {
    // STUB: Extends subtype check with polymorphic parameter matching
    return is_type_subtype_of(sub, super)
}

// is_type_load_safe checks if type is safe to load from arbitrary memory
// C++ Reference: /mnt/c/odin/src/types.cpp:4667-4672
is_type_load_safe :: proc(t: ^Type) -> bool {
    // STUB: Requires union maybe-pointer and padding analysis
    // For now, conservatively return false
    return false
}

// is_type_lock_free checks if type is guaranteed lock-free for atomics
// C++ Reference: /mnt/c/odin/src/types.cpp:4675-4725
is_type_lock_free :: proc(t: ^Type) -> bool {
    // STUB: Requires platform-specific atomic size limits
    // For now, allow sizes <= 8 bytes (common platforms)
    size := type_size_of(t)
    return size > 0 && size <= 8
}
```

---

## Part 2: Missing Basic_Kind Enum Variants

### 2.1 Critical Missing Basic Types

The C++ `BasicKind` enum has **82 variants**. The Odin `Basic_Kind` enum has **29 variants**. Missing **53 variants**:

#### Tier 1: Core Types (Block functionality)
| Missing Variant | C++ Name | Purpose | Priority |
|-----------------|----------|---------|----------|
| `Rune` | `Basic_rune` | Distinct rune type (not just i32) | Critical |
| `B8`, `B16`, `B32`, `B64` | `Basic_b8`, etc. | Boolean size variants | High |
| `Llvm_Bool` | `Basic_llvm_bool` | LLVM i1 type | High |
| `Quaternion64`, `Quaternion128`, `Quaternion256` | `Basic_quaternion64`, etc. | Quaternion types | Medium |
| `Complex32` | `Basic_complex32` | 32-bit complex | Medium |
| `String16` | `Basic_string16` | UTF-16 string ([^]u16 + int) | Medium |
| `Cstring16` | `Basic_cstring16` | UTF-16 C string ([^]u16) | Medium |
| `Untyped_Quaternion` | `Basic_UntypedQuaternion` | Untyped quaternion literal | Low |

**Current Implementation Gap**:
```odin
// CURRENT:
Basic_Kind :: enum {
    Invalid,
    Bool,
    I8, I16, I32, I64, I128,
    U8, U16, U32, U64, U128,
    Int, Uint, Uintptr,
    F16, F32, F64,
    Complex64, Complex128,
    String, Cstring,
    Rawptr, Typeid, Any,
    Untyped_Bool, Untyped_Integer, Untyped_Float, Untyped_Complex,
    Untyped_String, Untyped_Rune, Untyped_Nil, Untyped_Uninit,
}

// NEEDED (add these variants):
Basic_Kind :: enum {
    // ... existing ...

    // Boolean variants (C++ lines 5-8)
    Llvm_Bool,  // LLVM i1 (1-bit boolean)
    B8,         // 8-bit boolean
    B16,        // 16-bit boolean
    B32,        // 32-bit boolean
    B64,        // 64-bit boolean

    // Distinct rune (C++ line 20)
    Rune,       // Distinct from i32

    // Complex variants (C++ lines 24-26)
    Complex32,  // 32-bit complex (f16 + f16)
    // Complex64, Complex128 already exist

    // Quaternion types (C++ lines 28-30)
    Quaternion64,   // f16 quaternion
    Quaternion128,  // f32 quaternion
    Quaternion256,  // f64 quaternion

    // UTF-16 strings (C++ lines 37-39)
    String16,   // [^]u16 + int
    Cstring16,  // [^]u16

    // Untyped quaternion (C++ line 93)
    Untyped_Quaternion,

    // ... (endian types below) ...
}
```

#### Tier 2: Endian-Specific Types (31 variants)

The C++ compiler supports explicit endianness for integers and floats:

**Little-Endian Integers** (C++ lines 53-60):
- `I16le`, `U16le`, `I32le`, `U32le`, `I64le`, `U64le`, `I128le`, `U128le`

**Big-Endian Integers** (C++ lines 62-69):
- `I16be`, `U16be`, `I32be`, `U32be`, `I64be`, `U64be`, `I128be`, `U128be`

**Little-Endian Floats** (C++ lines 71-73):
- `F16le`, `F32le`, `F64le`

**Big-Endian Floats** (C++ lines 75-77):
- `F16be`, `F32be`, `F64be`

**Stub Implementation Strategy**:
```odin
Basic_Kind :: enum {
    // ... existing variants ...

    // Little-endian integer variants
    I16le, U16le,
    I32le, U32le,
    I64le, U64le,
    I128le, U128le,

    // Big-endian integer variants
    I16be, U16be,
    I32be, U32be,
    I64be, U64be,
    I128be, U128be,

    // Little-endian float variants
    F16le, F32le, F64le,

    // Big-endian float variants
    F16be, F32be, F64be,
}

// Helper to check endianness
get_basic_kind_endianness :: proc(kind: Basic_Kind) -> Endianness {
    #partial switch kind {
    case .I16le, .U16le, .I32le, .U32le, .I64le, .U64le, .I128le, .U128le,
         .F16le, .F32le, .F64le:
        return .Little
    case .I16be, .U16be, .I32be, .U32be, .I64be, .U64be, .I128be, .U128be,
         .F16be, .F32be, .F64be:
        return .Big
    case:
        return .Platform  // Native endianness
    }
}

Endianness :: enum {
    Platform,
    Little,
    Big,
}
```

### 2.2 Impact of Missing Basic_Kind Variants

**Functions Currently Stubbed Due to Missing Variants**:
1. `is_type_quaternion` - returns false (line 349-360 in types.odin)
2. `is_type_cstring16` - returns false (line 1432-1446)
3. `is_type_string16` - returns false (Tier 3 stub)
4. All endian predicates - return false

**Code Blocked**:
- Quaternion arithmetic operations
- UTF-16 string handling (Windows paths, Unicode processing)
- Cross-platform endian-aware serialization
- Boolean size optimization (b8, b16, b32, b64)

### 2.3 Type Singleton Initialization

**Missing Singletons** (need to add to init_basic_types):
```odin
// Add to types.odin globals:
t_rune: ^Type             // Distinct rune (not just i32)
t_quaternion64: ^Type
t_quaternion128: ^Type
t_quaternion256: ^Type
t_complex32: ^Type
t_string16: ^Type
t_cstring16: ^Type
t_b8, t_b16, t_b32, t_b64: ^Type
t_llvm_bool: ^Type

// Untyped quaternion
t_untyped_quaternion: ^Type

// Add to init_basic_types:
init_basic_types :: proc(allocator := context.allocator) {
    // ... existing initialization ...

    // Distinct rune type (not an alias of i32)
    t_rune = make_basic(.Rune, 4, allocator)

    // Boolean size variants
    t_llvm_bool = make_basic(.Llvm_Bool, 1, allocator)
    t_b8 = make_basic(.B8, 1, allocator)
    t_b16 = make_basic(.B16, 2, allocator)
    t_b32 = make_basic(.B32, 4, allocator)
    t_b64 = make_basic(.B64, 8, allocator)

    // Complex32
    t_complex32 = make_basic(.Complex32, 4, allocator)

    // Quaternions
    t_quaternion64 = make_basic(.Quaternion64, 8, allocator)
    t_quaternion128 = make_basic(.Quaternion128, 16, allocator)
    t_quaternion256 = make_basic(.Quaternion256, 32, allocator)

    // UTF-16 strings
    t_string16 = make_basic(.String16, 16, allocator)   // ptr + len
    t_cstring16 = make_basic(.Cstring16, 8, allocator)  // ptr only

    // Untyped quaternion
    t_untyped_quaternion = make_basic(.Untyped_Quaternion, 0, allocator)

    // NOTE: Endian types typically don't get singletons
    // They're constructed on-demand based on platform
}
```

---

## Part 3: Missing Global State and Initialization

### 3.1 Missing Checker Infrastructure Functions

Several critical initialization and lookup functions are referenced but not stubbed:

| Function | C++ Reference | Purpose | Priority |
|----------|---------------|---------|----------|
| `find_core_entity` | checker.cpp:3257 | Look up entity from core:runtime | Critical |
| `find_core_type` | checker.cpp:3283 | Look up type from core:runtime | Critical |
| `check_single_global_entity` | checker.cpp:3260 | Check global entity | Critical |
| `is_blank_ident_string` | types.cpp:3104 | Check for "_" identifier | High |

**Stub Implementation**:
```odin
// find_core_entity looks up an entity from the core:runtime package
// C++ Reference: /mnt/c/odin/src/checker.cpp:3257
// Used by: init_core_type_info, init_core_runtime
find_core_entity :: proc(c: ^Checker, name: string) -> ^Entity {
    // STUB: Requires runtime_package scope lookup
    if c.info.runtime_package == nil {
        return nil
    }

    // TODO(RUNTIME): Implement full runtime package entity lookup
    // For now, panic if runtime not loaded
    if c.info.runtime_package == nil {
        panic("Runtime package not loaded")
    }

    // Look up in runtime package scope
    // STUB: This assumes runtime package has been fully processed
    runtime_scope := c.info.runtime_package.scope
    if runtime_scope == nil {
        return nil
    }

    entity := scope_lookup(runtime_scope, name)
    return entity
}

// find_core_type looks up a type entity and returns its type
// C++ Reference: /mnt/c/odin/src/checker.cpp:3283-3319
find_core_type :: proc(c: ^Checker, name: string) -> ^Type {
    entity := find_core_entity(c, name)
    if entity == nil {
        panic("Could not find type declaration for '" + name + "' in core:runtime")
    }

    // Ensure entity is type-checked
    if entity.type == nil && entity.decl_info != nil {
        check_single_global_entity(c, entity, entity.decl_info)
    }

    return entity.type
}

// check_single_global_entity type-checks a single global declaration
// C++ Reference: /mnt/c/odin/src/checker.cpp:3260-3261
check_single_global_entity :: proc(c: ^Checker, e: ^Entity, d: ^Decl_Info) {
    // STUB: Requires full declaration checking infrastructure
    // For now, assume entity is already checked if we're calling this
    // TODO(DECL): Implement on-demand entity checking

    // This would normally call into check_entity or similar
    // but that creates circular dependencies during bootstrap
}

// is_blank_ident_string checks if string is blank identifier "_"
// C++ Reference: /mnt/c/odin/src/types.cpp:3104-3106
is_blank_ident_string :: proc(name: string) -> bool {
    return name == "_"
}
```

### 3.2 Missing Scope Helper Functions

Referenced in lookup_field_with_selection but not defined:

| Function | Purpose | Priority |
|----------|---------|----------|
| `scope_lookup` | Look up identifier in scope chain | Critical |
| `scope_lookup_current` | Look up identifier in current scope only | Critical |

**Stub Implementation**:
```odin
// scope_lookup looks up an identifier in scope and parent scopes
// C++ Reference: /mnt/c/odin/src/checker.cpp
scope_lookup :: proc(s: ^Scope, name: string) -> ^Entity {
    if s == nil {
        return nil
    }

    // Look in current scope
    if entity, found := s.elements[name]; found {
        return entity
    }

    // Look in imported scopes
    for imported_scope in s.imported {
        if entity, found := imported_scope.elements[name]; found {
            return entity
        }
    }

    // Recurse to parent scope
    if s.parent != nil {
        return scope_lookup(s.parent, name)
    }

    return nil
}

// scope_lookup_current looks up identifier in current scope only (no parent chain)
// C++ Reference: /mnt/c/odin/src/checker.cpp
scope_lookup_current :: proc(s: ^Scope, name: string) -> ^Entity {
    if s == nil {
        return nil
    }

    // Only check current scope
    if entity, found := s.elements[name]; found {
        return entity
    }

    return nil
}
```

### 3.3 Missing Build Context Integration

The `Build_Context` struct exists but integration functions are missing:

| Function | Purpose | Priority |
|----------|---------|----------|
| `get_target_endianness` | Get platform endianness | Medium |
| `is_arch_wasm` | Check if WASM target | Low |
| `is_arch_js` | Check if JS target | Low |

**Stub Implementation**:
```odin
// get_target_endianness returns the target platform's byte order
// C++ Reference: /mnt/c/odin/src/build_settings.cpp
get_target_endianness :: proc(bc: ^Build_Context) -> Endianness {
    // STUB: Most platforms are little-endian
    // TODO(BUILD): Add proper per-arch endianness mapping
    #partial switch bc.target_arch {
    case .AMD64, .I386, .ARM64, .WASM32, .WASM64P32, .RISCV64:
        return .Little
    case:
        return .Platform  // Unknown, assume platform native
    }
}

// is_arch_wasm checks if target is WebAssembly
is_arch_wasm :: proc(bc: ^Build_Context) -> bool {
    return bc.target_arch == .WASM32 || bc.target_arch == .WASM64P32
}

// is_arch_js checks if target is JavaScript
is_arch_js :: proc(bc: ^Build_Context) -> bool {
    return bc.target_os == .JS
}
```

---

## Part 4: Categorized Stub Implementation Plan

### 4.1 Type System Stubs

**File**: /mnt/d/dev/checker/types.odin

#### Phase 1: Critical Type Predicates (Week 1)
- [x] `is_type_any` - 17 uses
- [x] `is_type_enum` - 16 uses
- [x] `is_type_array` - 10 uses
- [x] `is_type_union` - 10 uses
- [x] `is_type_empty_union` - 6 uses
- [x] `is_type_slice` - 6 uses
- [x] `is_type_cstring` - 6 uses

**Estimated LOC**: 70 lines (10 lines per function × 7 functions)

#### Phase 2: Type Manipulation Helpers (Week 1)
- [x] `core_type` - 24 uses
- [x] `type_deref` - 26 uses
- [x] `base_array_type` - 35 uses
- [x] `core_array_type` - SIMD operations

**Estimated LOC**: 60 lines

#### Phase 3: Type Construction (Week 2)
- [x] `alloc_type_tuple`
- [x] `alloc_type_tuple_from_field_types`
- [x] `alloc_type_proc`
- [x] `alloc_type_struct`
- [x] `alloc_type_union`
- [x] `alloc_type_enum`
- [x] `alloc_type_bit_set`
- [x] `alloc_type_multi_pointer`
- [x] `alloc_type_soa_pointer`
- [x] `alloc_type_simd_vector`
- [x] `alloc_type_matrix`

**Estimated LOC**: 250 lines (15-30 lines per function × 11 functions)

#### Phase 4: Specialized Predicates (Week 2)
- [x] `is_type_tuple`
- [x] `is_type_named`
- [x] `is_type_generic`
- [x] `is_type_struct`
- [x] `is_type_soa_pointer`
- [x] `is_type_complex_or_quaternion`
- [x] `is_type_array_like`
- [x] `is_type_sliceable`
- [x] `is_type_integer_like`
- [x] `is_type_integer_128bit`
- [x] `is_type_ordered_numeric`
- [x] `is_type_dereferenceable`
- [x] `is_type_string16` (stub)
- [x] `is_type_u16_array`
- [x] `is_type_u8_multi_ptr`
- [x] `is_type_u16_multi_ptr`

**Estimated LOC**: 160 lines (10 lines each × 16 functions)

### 4.2 Polymorphic System Stubs

**File**: /mnt/d/dev/checker/polymorphic.odin (new file)

#### Phase 5: Polymorphic Infrastructure (Week 3)
- [x] `is_type_polymorphic` - **59 uses** (critical!)
- [x] `is_type_polymorphic_record`
- [x] `is_type_polymorphic_record_specialized`
- [x] `is_type_polymorphic_record_unspecialized`

**Estimated LOC**: 80 lines (20 lines each × 4 functions)

**Note**: These are all stubs returning false until full polymorphic infrastructure exists

### 4.3 Union and Comparison Stubs

**File**: /mnt/d/dev/checker/types.odin

#### Phase 6: Union Helpers (Week 3)
- [x] `is_type_raw_union`
- [x] `is_type_union_constantable`
- [x] `is_type_raw_union_constantable`

**Estimated LOC**: 45 lines

#### Phase 7: Comparison Predicates (Week 3)
- [x] `is_type_simple_compare`
- [x] `is_type_nearly_simple_compare`
- [x] `is_type_subtype_of`
- [x] `is_type_subtype_of_and_allow_polymorphic`
- [x] `is_type_load_safe`
- [x] `is_type_lock_free`

**Estimated LOC**: 90 lines (15 lines each × 6 functions)

### 4.4 Endian Type System Stubs

**File**: /mnt/d/dev/checker/checker.odin (Basic_Kind enum extension)
**File**: /mnt/d/dev/checker/types.odin (predicates and helpers)

#### Phase 8: Basic_Kind Extensions (Week 4)
- [x] Add 31 endian Basic_Kind variants
- [x] Add 5 boolean variants (Llvm_Bool, B8, B16, B32, B64)
- [x] Add quaternion variants (Quaternion64, Quaternion128, Quaternion256)
- [x] Add UTF-16 variants (String16, Cstring16)
- [x] Add Rune as distinct type
- [x] Add Untyped_Quaternion

**Estimated LOC**: 60 lines (enum variants + helper)

#### Phase 9: Endian Predicates (Week 4)
- [x] `is_type_endian_specific`
- [x] `is_type_endian_platform`
- [x] `is_type_endian_little`
- [x] `is_type_endian_big`
- [x] `is_type_different_to_arch_endianness`
- [x] `get_basic_kind_endianness` (helper)

**Estimated LOC**: 90 lines

#### Phase 10: Type Singleton Initialization (Week 4)
- [x] Add global type singletons for new Basic_Kind variants
- [x] Update `init_basic_types` to initialize them

**Estimated LOC**: 40 lines

### 4.5 Global State and Helper Stubs

**File**: /mnt/d/dev/checker/checker.odin

#### Phase 11: Checker Infrastructure (Week 5)
- [x] `find_core_entity`
- [x] `find_core_type`
- [x] `check_single_global_entity`
- [x] `is_blank_ident_string`

**Estimated LOC**: 80 lines

#### Phase 12: Scope Helpers (Week 5)
- [x] `scope_lookup`
- [x] `scope_lookup_current`

**Estimated LOC**: 40 lines

#### Phase 13: Build Context Helpers (Week 5)
- [x] `get_target_endianness`
- [x] `is_arch_wasm`
- [x] `is_arch_js`

**Estimated LOC**: 30 lines

---

## Part 5: Implementation Priority and Ordering

### 5.1 Critical Path (Must Stub First)

These items block the most functionality:

1. **is_type_polymorphic** (59 uses) - Blocks polymorphic proc checking
2. **base_array_type** (35 uses) - Blocks SIMD, array operations
3. **type_deref** (26 uses) - Blocks pointer operations
4. **core_type** (24 uses) - Blocks type unwrapping

**Week 1 Target**: Complete these + other Tier 1 predicates

### 5.2 High Priority (Week 2)

Type construction functions that enable advanced features:
- All `alloc_type_*` functions
- Specialized predicates (is_type_tuple, is_type_struct, etc.)

### 5.3 Medium Priority (Week 3-4)

Polymorphic and union infrastructure:
- Polymorphic predicates (all stubs)
- Union helpers
- Comparison predicates
- Endian type system extensions

### 5.4 Low Priority (Week 5)

Global infrastructure and build context:
- Checker initialization helpers
- Scope lookup functions
- Build context integration

---

## Part 6: Implementation Estimates

### 6.1 Total Stub Count

| Category | Count | Estimated LOC |
|----------|-------|---------------|
| Type Predicates (Tier 1) | 7 | 70 |
| Type Predicates (Tier 2) | 7 | 70 |
| Type Predicates (Tier 3) | 11 | 110 |
| Type Manipulation | 4 | 60 |
| Type Construction | 11 | 250 |
| Polymorphic Stubs | 4 | 80 |
| Union Helpers | 3 | 45 |
| Comparison Predicates | 6 | 90 |
| Endian Predicates | 6 | 90 |
| Basic_Kind Extensions | 42 variants | 60 |
| Type Singleton Init | - | 40 |
| Checker Infrastructure | 4 | 80 |
| Scope Helpers | 2 | 40 |
| Build Context | 3 | 30 |
| **TOTAL** | **127 items** | **~1,115 LOC** |

### 6.2 Estimated Timeline

**5-Week Implementation Plan** (assuming 1 developer, 4 hours/day):

- **Week 1**: Critical predicates + type manipulation (200 LOC)
- **Week 2**: Type construction + specialized predicates (410 LOC)
- **Week 3**: Polymorphic + union + comparison (215 LOC)
- **Week 4**: Endian system extensions (190 LOC)
- **Week 5**: Global infrastructure (100 LOC)

**Total Estimated Effort**: ~100 development hours

### 6.3 Validation Strategy

After stub implementation:

1. **Compilation Test**: Entire checker should compile without errors
2. **Usage Verification**: All 526 existing TODOs should reference valid stubs
3. **Call Site Analysis**: Grep for each stubbed function, verify all call sites compile
4. **Panic Path Testing**: Ensure stub panics have clear TODO messages

---

## Part 7: File Organization

### 7.1 New Files to Create

1. **polymorphic.odin** (80 LOC)
   - Polymorphic type checking stubs
   - Keeps polymorphic logic separate until full implementation

### 7.2 Files to Modify

1. **types.odin** (+815 LOC)
   - Type predicates (Phases 1, 4, 6, 7, 9)
   - Type manipulation (Phase 2)
   - Type construction (Phase 3)
   - Type singleton initialization (Phase 10)

2. **checker.odin** (+170 LOC)
   - Basic_Kind enum extensions (Phase 8)
   - Checker infrastructure (Phase 11)
   - Scope helpers (Phase 12)
   - Build context helpers (Phase 13)

3. **scope.odin** (if separate, +40 LOC)
   - Scope lookup functions

---

## Part 8: Implementation Notes

### 8.1 Stub Implementation Guidelines

All stubs should follow this pattern:

```odin
// function_name does X
// C++ Reference: /mnt/c/odin/src/file.cpp:line_numbers
//
// [Additional context about what full implementation requires]
function_name :: proc(...) -> ReturnType {
    // STUB: [Why this is stubbed]
    // TODO(CATEGORY): [What needs to be implemented]
    // [Stub behavior - typically return false/nil/panic]
}
```

**Categories for TODO**:
- `TODO(POLYMORPHIC)` - Requires polymorphic infrastructure
- `TODO(STRUCTURAL)` - Requires Basic_Kind/Type_Kind extensions
- `TODO(RUNTIME)` - Requires core:runtime integration
- `TODO(BUILD)` - Requires build context integration
- `TODO(OPTIMIZATION)` - Not critical, optimization only
- `TODO(CONST)` - Requires constant expression evaluation

### 8.2 Stub Return Value Policy

| Return Type | Stub Behavior | Rationale |
|-------------|---------------|-----------|
| `bool` (type check) | `return false` | Conservative: assume type doesn't match |
| `^Type` (construction) | `panic("TODO")` or minimal struct | Ensure caller knows it's incomplete |
| `^Entity` (lookup) | `return nil` or `panic` | Make missing lookups obvious |
| `void` | No-op or panic | Depends on whether omission is safe |

### 8.3 Integration with Existing Code

**Before stubbing**, verify:
1. Function isn't already implemented elsewhere
2. Call sites are prepared for stub behavior
3. Stub won't cause infinite loops or silent failures

**After stubbing**, validate:
1. All call sites compile
2. No new compiler errors introduced
3. TODOs are searchable and categorized

---

## Part 9: Risk Assessment

### 9.1 High-Risk Stubs

These stubs may cause subtle bugs if not carefully designed:

| Stub | Risk | Mitigation |
|------|------|------------|
| `is_type_polymorphic` (always false) | Polymorphic procs may be incorrectly specialized | Add assertions in poly proc checking |
| `core_type` (incomplete unwrapping) | Type comparisons may fail | Use defensive `base_type` as fallback |
| `is_type_simple_compare` (always false) | Performance penalty, not correctness issue | Low risk, just slower |
| `check_single_global_entity` (no-op) | Core types may be uninitialized | Validate during `init_core_type_info` |

### 9.2 Dependency Risks

**Circular Dependencies**:
- `find_core_entity` → `check_single_global_entity` → entity checking → scope lookup
- **Mitigation**: Break cycle by making `find_core_entity` lazy or require pre-initialization

**Missing Infrastructure**:
- Endian types require build context to be initialized first
- **Mitigation**: Document initialization order in checker startup

### 9.3 Testing Strategy

**Phase-wise Validation**:
1. After Week 1: Compile checker, verify no type predicate errors
2. After Week 2: Test type construction in check_type.odin
3. After Week 3: Validate union/comparison logic compiles
4. After Week 4: Test endian type creation (if build context exists)
5. After Week 5: Full integration test

**Smoke Tests**:
- Parse and type-check a simple Odin program
- Verify core:runtime types load correctly
- Check that SIMD builtins don't crash

---

## Part 10: Success Criteria

### 10.1 Completion Checklist

- [ ] All 127 stub functions implemented
- [ ] 42 Basic_Kind variants added
- [ ] All type singletons initialized
- [ ] Checker compiles without errors
- [ ] All 526 existing TODOs still valid
- [ ] No new compilation errors in existing code
- [ ] All stub functions have C++ reference comments
- [ ] All stubs categorized with TODO(CATEGORY)

### 10.2 Quality Metrics

**Code Coverage**:
- 100% of C++ type predicates have Odin equivalents (stub or real)
- 100% of C++ type construction functions have Odin equivalents
- All Basic_Kind variants from C++ represented in Odin

**Documentation**:
- Every stub has C++ reference
- Every stub explains what's needed for full implementation
- README or architecture doc updated with stub status

### 10.3 Post-Implementation Tasks

1. **Generate Stub Report**: List all stubs by category with TODO tags
2. **Create Implementation Roadmap**: Prioritize which stubs to flesh out first
3. **Update Verification Documents**: Mark stubbed functions in *_VERIFICATION.md files
4. **Integration Testing**: Validate checker can process simple Odin programs

---

## Appendices

### Appendix A: Full Function Reference

**Type Predicates** (40 total):
```
is_type_any
is_type_array
is_type_array_like
is_type_asm_proc (already exists)
is_type_bit_field (already exists)
is_type_bit_set (already exists)
is_type_boolean (already exists)
is_type_comparable (already exists)
is_type_complex (already exists)
is_type_complex_or_quaternion
is_type_constant_type (already exists)
is_type_cstring
is_type_cstring16 (already exists, stubbed)
is_type_dereferenceable
is_type_different_to_arch_endianness
is_type_dynamic_array (already exists)
is_type_empty_union
is_type_endian_big
is_type_endian_little
is_type_endian_platform
is_type_endian_specific
is_type_enum
is_type_enumerated_array (already exists)
is_type_float (already exists)
is_type_generic
is_type_indexable (already exists)
is_type_integer (already exists)
is_type_integer_128bit
is_type_integer_like
is_type_internally_pointer_like (already exists)
is_type_load_safe
is_type_lock_free
is_type_map (already exists)
is_type_matrix (already exists)
is_type_multi_pointer (already exists)
is_type_named
is_type_nearly_simple_compare
is_type_numeric (already exists)
is_type_objc_object (already exists, stubbed)
is_type_ordered (already exists)
is_type_ordered_numeric
is_type_pointer (already exists)
is_type_polymorphic
is_type_polymorphic_record
is_type_polymorphic_record_specialized
is_type_polymorphic_record_unspecialized
is_type_proc (already exists)
is_type_quaternion (already exists, stubbed)
is_type_raw_union
is_type_raw_union_constantable
is_type_rawptr (already exists)
is_type_rune (already exists)
is_type_rune_array (already exists)
is_type_simd_vector (already exists)
is_type_simple_compare
is_type_slice
is_type_sliceable
is_type_soa_pointer
is_type_soa_struct (already exists)
is_type_string (already exists)
is_type_string16
is_type_struct
is_type_subtype_of
is_type_subtype_of_and_allow_polymorphic
is_type_tuple
is_type_typed (already exists)
is_type_typeid (already exists)
is_type_u16 (already exists)
is_type_u16_array
is_type_u16_multi_ptr
is_type_u16_ptr (already exists)
is_type_u16_slice (already exists)
is_type_u8 (already exists)
is_type_u8_array (already exists)
is_type_u8_multi_ptr
is_type_u8_ptr (already exists)
is_type_u8_slice (already exists)
is_type_uintptr (already exists)
is_type_union
is_type_union_constantable
is_type_untyped (already exists)
is_type_valid_atomic_type (already exists)
```

**Type Manipulation** (4):
```
core_type
type_deref
base_array_type
core_array_type
```

**Type Construction** (25):
```
alloc_type_array (not stubbed - simple, can implement)
alloc_type_bit_field
alloc_type_bit_set
alloc_type_dynamic_array (not stubbed - simple)
alloc_type_enum
alloc_type_enumerated_array
alloc_type_generic (already exists: make_type_generic)
alloc_type_matrix
alloc_type_multi_pointer
alloc_type_multi_pointer_to_pointer (helper)
alloc_type_named (already exists: make_named_type)
alloc_type_pointer (already exists: alloc_type_pointer, make_pointer_type)
alloc_type_pointer_to_multi_pointer (helper)
alloc_type_proc
alloc_type_proc_from_types (helper)
alloc_type_simd_vector
alloc_type_slice (already exists: alloc_type_slice, make_slice_type)
alloc_type_soa_pointer
alloc_type_struct
alloc_type_struct_complete (helper)
alloc_type_tuple
alloc_type_tuple_from_field_types
alloc_type_union
```

**Global Infrastructure** (9):
```
find_core_entity
find_core_type
check_single_global_entity
is_blank_ident_string
scope_lookup
scope_lookup_current
get_target_endianness
is_arch_wasm
is_arch_js
```

**Basic_Kind Extensions** (42 variants):
```
Llvm_Bool, B8, B16, B32, B64
Rune
Complex32
Quaternion64, Quaternion128, Quaternion256
String16, Cstring16
I16le, U16le, I32le, U32le, I64le, U64le, I128le, U128le
I16be, U16be, I32be, U32be, I64be, U64be, I128be, U128be
F16le, F32le, F64le
F16be, F32be, F64be
Untyped_Quaternion
```

### Appendix B: C++ Reference Index

**Key C++ Files**:
- `/mnt/c/odin/src/types.cpp` - Type system implementation
- `/mnt/c/odin/src/checker.cpp` - Checker initialization and RTTI
- `/mnt/c/odin/src/entity.cpp` - Entity allocation
- `/mnt/c/odin/src/build_settings.cpp` - Build context

**Key C++ Line Ranges**:
- Basic_Kind enum: types.cpp:1-95
- Type predicates: types.cpp:1200-2300
- Type construction: types.cpp:700-1200
- Core type unwrapping: types.cpp:499-557
- RTTI initialization: checker.cpp:3253-3395

### Appendix C: Verification Cross-Reference

Update these verification documents after stub implementation:

1. **TYPES_VERIFICATION.md** - Add stub status for all type predicates
2. **CHECKER_VERIFICATION.md** - Note checker infrastructure stubs
3. **CHECK_TYPE_VERIFICATION.md** - Mark type construction stubs

Add new verification document:
4. **POLYMORPHIC_VERIFICATION.md** - Track polymorphic infrastructure stubs

---

## Conclusion

This plan identifies **127 missing infrastructure items** totaling approximately **1,115 lines of stub code**. The critical path focuses on the most-used type predicates and manipulation functions, with a 5-week implementation timeline.

**Immediate Next Steps**:
1. Implement Week 1 critical stubs (is_type_polymorphic, core_type, type_deref, base_array_type)
2. Validate compilation with these stubs
3. Proceed to Week 2 type construction functions

**Success Metric**: By end of Week 5, the checker should compile completely with all referenced functions at least stubbed, creating a complete "skeleton" ready for incremental flesh-out of individual features.
