# Phase 11 Port Specification for odin-checker-porter

## Task: Port Core Builtin Checking Infrastructure

This document provides precise instructions for the odin-checker-porter agent to implement Phase 11A of the builtin checking system.

## Files to Create/Modify

### 1. NEW FILE: `/mnt/d/dev/checker/check_builtin.odin`

Create this file with the following structure:

```odin
package checker

/*
Builtin procedure checking.

This module implements type checking for Odin's built-in procedures,
following the logic in check_builtin.cpp from the Odin compiler.

C++ Reference: /mnt/c/odin/src/check_builtin.cpp

Phase 11A implements:
- len, cap (full implementation)
- size_of, align_of (full implementation with stub type introspection)
- type_of (full implementation)
- offset_of, type_info_of, typeid_of (stubs with clear TODOs)
*/

import "core:odin/ast"
```

**Contents**:

1. **check_builtin_procedure()** - Central dispatcher
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2396-2506`
   - Validates arg count
   - Dispatches to per-builtin handlers
   - Returns true on success

2. **check_builtin_len_cap()** - Handles len() and cap()
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2529-2637`
   - Supports: string, array, slice, dynamic_array, map, enum (as type), simd_vector
   - Constant folding for arrays, enums, strings
   - Type hint support for int/uint

3. **check_builtin_size_of()** - Handles size_of()
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2639-2658`
   - Always returns constant
   - Calls type_size_of()

4. **check_builtin_align_of()** - Handles align_of()
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2660-2679`
   - Always returns constant
   - Calls type_align_of()

5. **check_builtin_type_of()** - Handles type_of()
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2870-2907`
   - Rejects untyped, polymorphic types
   - Returns Addressing_Mode.Type operand

6. **check_builtin_offset_of()** - STUB
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2682-2793`
   - Returns error with message "offset_of() not yet fully implemented"
   - TODO comment referencing full C++ implementation

7. **check_builtin_type_info_of()** - STUB
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2909-2952`
   - Returns error with message "type_info_of() requires RTTI support"
   - TODO comment referencing RTTI requirements

8. **check_builtin_typeid_of()** - STUB
   - C++ ref: `/mnt/c/odin/src/check_builtin.cpp:2954-2990`
   - Returns error with message "typeid_of() requires RTTI support"
   - TODO comment referencing RTTI requirements

### 2. MODIFY: `/mnt/d/dev/checker/types.odin`

Add the following functions at the end:

```odin
// ============================================================================
// Type Predicates (for builtin checking)
// ============================================================================

// is_type_string checks if type is string or cstring
is_type_string :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_array checks if type is a fixed-size array
is_type_array :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_slice checks if type is a slice
is_type_slice :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_dynamic_array checks if type is a dynamic array
is_type_dynamic_array :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_map checks if type is a map
is_type_map :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_enum checks if type is an enum
is_type_enum :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_struct checks if type is a struct
is_type_struct :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_simd_vector checks if type is a SIMD vector
is_type_simd_vector :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_untyped checks if type is an untyped constant
is_type_untyped :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// is_type_polymorphic checks if type is polymorphic
is_type_polymorphic :: proc(t: ^Type) -> bool {
    // Stub for Phase 11A
    return false
}

// is_type_asm_proc checks if type is an asm procedure
is_type_asm_proc :: proc(t: ^Type) -> bool {
    // Stub for Phase 11A
    return false
}

// is_type_bit_set checks if type is a bit_set
is_type_bit_set :: proc(t: ^Type) -> bool {
    // TODO: Implement
    return false
}

// ============================================================================
// Type Introspection (for builtin checking)
// ============================================================================

// type_deref removes one level of pointer indirection
type_deref :: proc(t: ^Type) -> ^Type {
    // TODO: Implement
    return t
}

// type_size_of returns size of type in bytes (stub implementation)
type_size_of :: proc(t: ^Type) -> i64 {
    // TODO: Implement proper size calculation
    // For Phase 11A, return basic sizes
    return 0
}

// type_align_of returns alignment of type in bytes (stub implementation)
type_align_of :: proc(t: ^Type) -> i64 {
    // TODO: Implement proper alignment calculation
    // For Phase 11A, return basic alignments
    return 1
}

// default_type converts untyped to default typed
default_type :: proc(t: ^Type) -> ^Type {
    // TODO: Implement untyped -> typed conversion
    return t
}
```

### 3. MODIFY: `/mnt/d/dev/checker/checker.odin`

Add after the Builtin_Proc_Id enum definition (around line 628):

```odin
// Expr_Kind defines whether builtin returns value or is statement
Expr_Kind :: enum {
    Expr,  // Returns a value
    Stmt,  // Statement (no value)
}

// Builtin_Proc_Info stores metadata for each builtin procedure
Builtin_Proc_Info :: struct {
    name: string,
    arg_count: int,
    variadic: bool,
    kind: Expr_Kind,
    pkg: Builtin_Proc_Pkg,
}

// builtin_proc_infos maps builtin IDs to their metadata
// C++ reference: builtin_procs[] in checker_builtin_procs.hpp:369-728
builtin_proc_infos := [Builtin_Proc_Id]Builtin_Proc_Info{
    .Invalid          = {name="",              arg_count=0, variadic=false, kind=.Stmt, pkg=.Builtin},
    .Len              = {name="len",           arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Cap              = {name="cap",           arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Size_Of          = {name="size_of",       arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Align_Of         = {name="align_of",      arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Offset_Of        = {name="offset_of",     arg_count=1, variadic=true,  kind=.Expr, pkg=.Builtin},
    .Type_Of          = {name="type_of",       arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Type_Info_Of     = {name="type_info_of",  arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Typeid_Of        = {name="typeid_of",     arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Swizzle          = {name="swizzle",       arg_count=1, variadic=true,  kind=.Expr, pkg=.Builtin},
    .Complex          = {name="complex",       arg_count=2, variadic=false, kind=.Expr, pkg=.Builtin},
    .Real             = {name="real",          arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Imag             = {name="imag",          arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Conj             = {name="conj",          arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
}
```

### 4. MODIFY: `/mnt/d/dev/checker/check_expr.odin`

Replace lines 3768-3778 (the builtin stub) with:

```odin
// Step 4: Handle built-in procedures
// Reference: /mnt/c/odin/src/check_expr.cpp:8213-8227
if o.mode == .Builtin {
    builtin_id := o.builtin_id
    success := check_builtin_procedure(ctx, o, call, builtin_id, type_hint)
    if !success {
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Determine expression kind from builtin info
    info := builtin_proc_infos[builtin_id]
    return info.kind == .Expr ? .Expr : .Stmt
}
```

## Implementation Requirements

### Quality Standards

1. **C++ Parity**: Every implemented builtin must match C++ behavior exactly
2. **Error Messages**: Use same format as C++ checker
3. **Constant Folding**: Implement where C++ does
4. **Type Hints**: Support type hint propagation
5. **Stub Quality**: Clear TODOs with C++ line references

### Type Checking Flow

For each builtin:

1. Check arguments using check_expr_or_type() or check_expr()
2. Validate operand mode
3. Determine result type and value
4. Set operand fields (mode, type, value, expr)
5. Return true on success, false on error

### Error Handling

- Use error_node() for errors
- Include builtin name in error messages
- Provide type strings when helpful
- Match C++ error format

### Constants

Assume these global type constants exist:
- `t_int`, `t_uint`, `t_untyped_integer`
- `t_uintptr`, `t_invalid`
- `t_string`, `t_bool`, `t_f64`
- `t_typeid`, `t_type_info_ptr` (for stubs)

## Testing After Implementation

The porter should verify compilation:

```bash
cd /mnt/d/dev/checker
odin build . -debug
```

Expected: No compilation errors

## Success Criteria

- [ ] `/mnt/d/dev/checker/check_builtin.odin` created
- [ ] All 8 builtin handlers implemented (5 full, 3 stubs)
- [ ] `/mnt/d/dev/checker/types.odin` updated with type predicates
- [ ] `/mnt/d/dev/checker/checker.odin` updated with metadata
- [ ] `/mnt/d/dev/checker/check_expr.odin` integration complete
- [ ] Code compiles without errors
- [ ] Each stub has clear TODO with C++ reference

## Notes for Porter

- Focus on Phase 11A scope only (8 core built-ins)
- Stub implementations should be functional (compile and error gracefully)
- Type predicate and introspection functions can return stub values for now
- Match C++ code structure as closely as possible
- Include C++ line references in comments
