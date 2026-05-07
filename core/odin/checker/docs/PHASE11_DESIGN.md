# Phase 11 Design: Odin Builtin Checking Architecture

## Overview

This document details the architecture for implementing builtin procedure checking in the native Odin checker. The design maintains exact C++ parity while leveraging Odin's type system for cleaner implementation.

## Current State Assessment

### Existing Infrastructure

The checker already has partial builtin support:

1. **Entity Support** (`entity.odin:267-285`):
   ```odin
   alloc_entity_builtin :: proc(
       name: string,
       id: Builtin_Proc_Id,
       pkg := Builtin_Proc_Pkg.Builtin,
   ) -> ^Entity
   ```

2. **Enum Definition** (`checker.odin:611-628`):
   ```odin
   Builtin_Proc_Id :: enum {
       Invalid,
       Len,
       Cap,
       Size_Of,
       Align_Of,
       Offset_Of,
       Type_Of,
       Type_Info_Of,
       Typeid_Of,
       Swizzle,
       Complex,
       Real,
       Imag,
       Conj,
   }
   ```

3. **Call Expression Stub** (`check_expr.odin:3770-3778`):
   ```odin
   if o.mode == .Builtin {
       // TODO(Phase 11?): Built-in procedure calls
       error_node(call.expr, "Built-in procedures not yet implemented")
       o.mode = .Invalid
       o.expr = node
       return .Stmt
   }
   ```

### Integration Point

The integration point is well-defined and ready for implementation:
- Location: `/mnt/d/dev/checker/check_expr.odin:3770`
- Context: After type/proc group checks, before procedure validation
- Input: Operand with `.Builtin` mode and `builtin_id` set
- Output: Checked operand with result type and value

## Module Structure

### New File: `/mnt/d/dev/checker/check_builtin.odin`

This file will contain all builtin checking logic, matching the C++ organization:

```odin
package checker

/*
Builtin procedure checking.

This module implements type checking for Odin's built-in procedures,
following the logic in check_builtin.cpp from the Odin compiler.

Organization:
- Builtin metadata tables
- Central dispatcher: check_builtin_procedure()
- Per-builtin handlers: check_builtin_len_cap(), etc.
- Helper functions for type introspection
*/

import "core:odin/ast"
import "core:odin/tokenizer"
```

## Data Structures

### 1. Builtin Metadata (expand `checker.odin`)

```odin
// Expr_Kind already exists
Expr_Kind :: enum {
    Expr,  // Returns a value
    Stmt,  // Statement (no value)
}

// Builtin_Proc_Pkg already exists
Builtin_Proc_Pkg :: enum {
    Builtin,
    Intrinsics,
}

// NEW: Builtin metadata structure
Builtin_Proc_Info :: struct {
    name: string,
    arg_count: int,
    variadic: bool,
    kind: Expr_Kind,
    pkg: Builtin_Proc_Pkg,
    diverging: bool,           // Never returns (e.g., unreachable)
    ignore_results: bool,      // Can ignore return value
}

// NEW: Metadata table (global constant)
builtin_proc_infos := [Builtin_Proc_Id]Builtin_Proc_Info{
    .Invalid = {name="", arg_count=0, variadic=false, kind=.Stmt, pkg=.Builtin},

    // Phase 11A: Core type/memory builtins
    .Len              = {name="len",              arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Cap              = {name="cap",              arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Size_Of          = {name="size_of",          arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Align_Of         = {name="align_of",         arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Offset_Of        = {name="offset_of",        arg_count=1, variadic=true,  kind=.Expr, pkg=.Builtin},
    .Type_Of          = {name="type_of",          arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Type_Info_Of     = {name="type_info_of",     arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    .Typeid_Of        = {name="typeid_of",        arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},

    // Phase 11B/C: Stubbed for future
    .Swizzle          = {name="swizzle",          arg_count=1, variadic=true,  kind=.Expr, pkg=.Builtin},
    .Complex          = {name="complex",          arg_count=2, variadic=false, kind=.Expr, pkg=.Builtin},
    // ... etc
}
```

### 2. Helper Type Predicates (expand `types.odin`)

```odin
// Type category checks (many already exist, add missing ones)

is_type_string :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    #partial switch t.kind {
    case .Basic:
        basic := t.variant.(Type_Basic)
        return basic.kind == .String || basic.kind == .CString
    }
    return false
}

is_type_array :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Array
}

is_type_slice :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Slice
}

is_type_dynamic_array :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Dynamic_Array
}

is_type_map :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Map
}

is_type_enum :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Enum
}

is_type_struct :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Struct
}

is_type_simd_vector :: proc(t: ^Type) -> bool {
    if t == nil {
        return false
    }
    return t.kind == .Simd_Vector
}

is_type_untyped :: proc(t: ^Type) -> bool {
    if t == nil || t.kind != .Basic {
        return false
    }
    basic := t.variant.(Type_Basic)
    return basic.flags & .Untyped != {}
}

is_type_polymorphic :: proc(t: ^Type) -> bool {
    // TODO: Implement polymorphic type detection
    // For now, return false
    return false
}

is_type_asm_proc :: proc(t: ^Type) -> bool {
    // TODO: Implement asm proc detection
    // For now, return false
    return false
}
```

### 3. Type Introspection Functions (new section in `types.odin`)

```odin
// type_deref removes one level of pointer indirection
// If type is not a pointer, returns the type unchanged
type_deref :: proc(t: ^Type) -> ^Type {
    if t == nil {
        return nil
    }
    if t.kind == .Pointer {
        ptr := t.variant.(Type_Pointer)
        return ptr.elem
    }
    return t
}

// type_size_of returns the size of a type in bytes
// Stub for Phase 11A - full implementation requires layout calculation
type_size_of :: proc(t: ^Type) -> i64 {
    if t == nil {
        return 0
    }

    // For Phase 11A, return basic sizes
    // TODO: Full type size calculation with alignment
    #partial switch t.kind {
    case .Basic:
        basic := t.variant.(Type_Basic)
        switch basic.kind {
        case .Bool, .B8:   return 1
        case .I8, .U8:     return 1
        case .I16, .U16:   return 2
        case .I32, .U32:   return 4
        case .I64, .U64:   return 8
        case .Int, .Uint:  return 8  // Platform dependent, assume 64-bit
        case .F32:         return 4
        case .F64:         return 8
        case .String:      return 16  // data + len
        // ... etc
        }
    case .Pointer:
        return 8  // Assume 64-bit pointers
    case .Array:
        arr := t.variant.(Type_Array)
        return arr.count * type_size_of(arr.elem)
    case .Slice:
        return 16  // data + len (assume 64-bit)
    // ... etc
    }

    // Default
    return 0
}

// type_align_of returns the alignment of a type in bytes
// Stub for Phase 11A
type_align_of :: proc(t: ^Type) -> i64 {
    if t == nil {
        return 1
    }

    // For Phase 11A, return basic alignments
    // TODO: Full type alignment calculation
    #partial switch t.kind {
    case .Basic:
        basic := t.variant.(Type_Basic)
        switch basic.kind {
        case .Bool, .B8, .I8, .U8:   return 1
        case .I16, .U16:              return 2
        case .I32, .U32, .F32:        return 4
        case .I64, .U64, .F64:        return 8
        case .Int, .Uint:             return 8
        case .String:                 return 8
        }
    case .Pointer:
        return 8
    case .Array:
        arr := t.variant.(Type_Array)
        return type_align_of(arr.elem)
    }

    return 1
}

// default_type converts untyped types to their default typed equivalents
default_type :: proc(t: ^Type) -> ^Type {
    if t == nil {
        return nil
    }

    if !is_type_untyped(t) {
        return t
    }

    // Map untyped to default types
    basic := t.variant.(Type_Basic)
    switch basic.kind {
    case .Untyped_Integer:  return t_int
    case .Untyped_Float:    return t_f64
    case .Untyped_Complex:  return t_complex128
    case .Untyped_String:   return t_string
    case .Untyped_Bool:     return t_bool
    case .Untyped_Rune:     return t_rune
    case .Untyped_Nil:      return t_rawptr  // Or context-dependent
    }

    return t
}
```

### 4. Field Lookup (expand existing in `check_type.odin`)

```odin
// Selection represents the result of a field lookup
// C++ equivalent: struct Selection in checker.hpp
Selection :: struct {
    entity: ^Entity,
    indirect: bool,  // Field accessed through pointer
    index: []int,    // Path to field (for nested structs)
}

// lookup_field finds a field by name in a struct/union type
// C++ reference: lookup_field() in checker.cpp
lookup_field :: proc(type: ^Type, name: string, operand_is_type: bool) -> Selection {
    sel: Selection

    t := type_deref(type)
    if t == nil {
        return sel
    }

    #partial switch t.kind {
    case .Struct:
        st := t.variant.(Type_Struct)
        // TODO: Implement full field lookup with scope search
        // For Phase 11A stub, just return empty selection
        // Full implementation needs:
        // - Scope traversal
        // - Using/embedding support
        // - Nested field paths
        return sel

    case .Union:
        // TODO: Union field lookup
        return sel
    }

    return sel
}

// type_offset_of_from_selection computes field offset from selection
// Stub for Phase 11A
type_offset_of_from_selection :: proc(type: ^Type, sel: Selection) -> i64 {
    // TODO: Implement field offset calculation
    // Requires:
    // - Field index tracking
    // - Struct layout with padding
    // - Alignment consideration
    return 0
}
```

## Central Dispatcher

### `check_builtin_procedure()` Implementation

Location: `/mnt/d/dev/checker/check_builtin.odin`

```odin
// check_builtin_procedure is the central dispatcher for builtin checking
// C++ reference: check_builtin_procedure() in check_builtin.cpp:2396
check_builtin_procedure :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
    id: Builtin_Proc_Id,
    type_hint: ^Type,
) -> bool {
    // Step 1: Get builtin metadata
    info := builtin_proc_infos[id]

    // Step 2: Validate argument count
    // C++ ref: check_builtin.cpp:2402-2419
    arg_count := len(call.args)
    if arg_count < info.arg_count {
        error_node(call, "Too few arguments for '%s', expected %d, got %d",
                   info.name, info.arg_count, arg_count)
        return false
    }
    if arg_count > info.arg_count && !info.variadic {
        error_node(call, "Too many arguments for '%s', expected %d, got %d",
                   info.name, info.arg_count, arg_count)
        return false
    }

    // Step 3: Pre-check first argument for special builtins
    // C++ ref: check_builtin.cpp:2421-2468
    // Some builtins accept types or expressions, handle specially
    switch id {
    case .Len, .Cap, .Size_Of, .Align_Of, .Offset_Of,
         .Type_Of, .Type_Info_Of, .Typeid_Of:
        // These are checked inside their handlers
        break

    case:
        // Default: check first arg as multi-expr
        if arg_count > 0 {
            check_multi_expr(ctx, operand, call.args[0])
        }
    }

    // Step 4: Dispatch to per-builtin handler
    // C++ ref: check_builtin.cpp:2506 (main switch)
    result := false
    switch id {
    case .Len, .Cap:
        result = check_builtin_len_cap(ctx, operand, call, id, type_hint)

    case .Size_Of:
        result = check_builtin_size_of(ctx, operand, call)

    case .Align_Of:
        result = check_builtin_align_of(ctx, operand, call)

    case .Offset_Of:
        result = check_builtin_offset_of(ctx, operand, call)

    case .Type_Of:
        result = check_builtin_type_of(ctx, operand, call)

    case .Type_Info_Of:
        result = check_builtin_type_info_of(ctx, operand, call)

    case .Typeid_Of:
        result = check_builtin_typeid_of(ctx, operand, call)

    case:
        // Phase 11B/C builtins
        error_node(call, "Builtin '%s' not yet implemented", info.name)
        return false
    }

    // Step 5: Set expression node
    if result {
        operand.expr = call
    }

    return result
}
```

## Per-Builtin Handlers

### 1. `len()` and `cap()`

```odin
// check_builtin_len_cap handles len() and cap() builtins
// C++ reference: check_builtin.cpp:2529-2637
check_builtin_len_cap :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
    id: Builtin_Proc_Id,
    type_hint: ^Type,
) -> bool {
    // Check argument (type or expression)
    check_expr_or_type(ctx, operand, call.args[0])
    if operand.mode == .Invalid {
        return false
    }

    op_type := type_deref(operand.type)
    result_type := t_int  // Default

    // Type hint support (int or uint)
    if type_hint != nil {
        bt := base_type(type_hint)
        if bt == t_int || bt == t_uint {
            result_type = type_hint
        }
    }

    mode := Addressing_Mode.Invalid
    value: Exact_Value = nil

    // Dispatch by operand type
    if is_type_string(op_type) && id == .Len {
        // String length
        if operand.mode == .Constant {
            mode = .Constant
            if str, ok := operand.value.(string); ok {
                value = i64(len(str))
            }
            result_type = t_untyped_integer
        } else {
            mode = .Value
            // TODO: Add runtime dependency for cstring_len if needed
        }

    } else if is_type_array(op_type) {
        // Array length - always constant
        arr := op_type.variant.(Type_Array)
        mode = .Constant
        value = arr.count
        result_type = t_untyped_integer

    } else if is_type_slice(op_type) && id == .Len {
        // Slice length - runtime value
        mode = .Value

    } else if is_type_dynamic_array(op_type) {
        // Dynamic array len/cap - runtime value
        mode = .Value

    } else if is_type_map(op_type) {
        // Map length - runtime value
        mode = .Value

    } else if operand.mode == .Type && is_type_enum(op_type) {
        // Enum len/cap on type
        // TODO: Extract enum min/max values
        // For now, stub with constant
        mode = .Constant
        value = i64(0)  // Placeholder
        result_type = t_untyped_integer

    } else if is_type_simd_vector(op_type) {
        // SIMD vector length - constant
        // TODO: Extract simd count
        mode = .Constant
        value = i64(0)  // Placeholder
        result_type = t_untyped_integer

    } else {
        // Unsupported type
        builtin_name := builtin_proc_infos[id].name
        type_str := type_to_string(op_type)
        if is_type_bit_set(op_type) && id == .Len {
            error_node(call, "'%s' is not supported for '%s', did you mean 'card'?",
                      builtin_name, type_str)
        } else {
            error_node(call, "'%s' is not supported for '%s'",
                      builtin_name, type_str)
        }
        return false
    }

    // Type operand must result in constant
    if operand.mode == .Type && mode != .Constant {
        mode = .Invalid
    }

    if mode == .Invalid {
        return false
    }

    operand.mode = mode
    operand.value = value
    operand.type = result_type
    return true
}
```

### 2. `size_of()`

```odin
// check_builtin_size_of handles size_of() builtin
// C++ reference: check_builtin.cpp:2639-2658
check_builtin_size_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    // Check argument (type or expression)
    o: Operand
    check_expr_or_type(ctx, &o, call.args[0])
    if o.mode == .Invalid {
        return false
    }

    t := o.type
    if t == nil || t == t_invalid {
        error_node(call.args[0], "Invalid argument for 'size_of'")
        return false
    }

    t = default_type(t)

    operand.mode = .Constant
    operand.value = type_size_of(t)
    operand.type = t_untyped_integer
    return true
}
```

### 3. `align_of()`

```odin
// check_builtin_align_of handles align_of() builtin
// C++ reference: check_builtin.cpp:2660-2679
check_builtin_align_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    // Nearly identical to size_of
    o: Operand
    check_expr_or_type(ctx, &o, call.args[0])
    if o.mode == .Invalid {
        return false
    }

    t := o.type
    if t == nil || t == t_invalid {
        error_node(call.args[0], "Invalid argument for 'align_of'")
        return false
    }

    t = default_type(t)

    operand.mode = .Constant
    operand.value = type_align_of(t)
    operand.type = t_untyped_integer
    return true
}
```

### 4. `offset_of()` (stub for Phase 11A)

```odin
// check_builtin_offset_of handles offset_of() builtin
// C++ reference: check_builtin.cpp:2682-2793
// STUB: Full implementation requires field lookup infrastructure
check_builtin_offset_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    // TODO: Full implementation
    // For Phase 11A, just provide basic structure
    error_node(call, "offset_of() not yet fully implemented")
    operand.mode = .Constant
    operand.value = i64(0)
    operand.type = t_uintptr
    return false  // Return false until implemented
}
```

### 5. `type_of()`

```odin
// check_builtin_type_of handles type_of() builtin
// C++ reference: check_builtin.cpp:2870-2907
check_builtin_type_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    o: Operand
    check_expr_or_type(ctx, &o, call.args[0])

    if o.mode == .Invalid || o.mode == .Builtin {
        return false
    }

    if o.type == nil || o.type == t_invalid || is_type_asm_proc(o.type) {
        error_node(o.expr, "Invalid argument to 'type_of'")
        return false
    }

    if is_type_untyped(o.type) {
        type_str := type_to_string(o.type)
        error_node(o.expr, "'type_of' of %s cannot be determined", type_str)
        return false
    }

    // TODO: Prevent type cycles for procedure declarations
    // if ctx.curr_proc_sig == o.type {
    //     error_node(o.expr, "Invalid cyclic type usage from 'type_of'")
    //     return false
    // }

    if is_type_polymorphic(o.type) {
        error_node(o.expr, "'type_of' of polymorphic type cannot be determined")
        return false
    }

    operand.mode = .Type
    operand.type = o.type
    return true
}
```

### 6. `type_info_of()` (stub for Phase 11A)

```odin
// check_builtin_type_info_of handles type_info_of() builtin
// C++ reference: check_builtin.cpp:2909-2952
// STUB: Requires RTTI infrastructure
check_builtin_type_info_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    // TODO: RTTI support
    // - Check scope flags for runtime package restriction
    // - Check build flags for no_rtti
    // - Initialize type info system
    // - Register type for RTTI generation
    error_node(call, "type_info_of() requires RTTI support (not yet implemented)")
    operand.mode = .Value
    operand.type = t_type_info_ptr  // Assume this global exists
    return false  // Return false until implemented
}
```

### 7. `typeid_of()` (stub for Phase 11A)

```odin
// check_builtin_typeid_of handles typeid_of() builtin
// C++ reference: check_builtin.cpp:2954-2990
// STUB: Requires RTTI infrastructure
check_builtin_typeid_of :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
) -> bool {
    // TODO: RTTI support
    // Similar to type_info_of but returns typeid value
    error_node(call, "typeid_of() requires RTTI support (not yet implemented)")
    operand.mode = .Value
    operand.type = t_typeid  // Assume this global exists
    return false  // Return false until implemented
}
```

## Integration Changes

### Update `check_expr.odin` Call Expression Handler

Replace the stub at line 3770:

```odin
// Step 4: Handle built-in procedures
// Reference: /mnt/c/odin/src/check_expr.cpp:8213-8227
if o.mode == .Builtin {
    // Dispatch to builtin checker
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

## Phased Implementation Strategy

### Phase 11A Deliverables (This Phase)

**Fully Implemented**:
1. `len()` - Complete with all type support
2. `cap()` - Complete with all type support
3. `size_of()` - Complete
4. `align_of()` - Complete
5. `type_of()` - Complete

**Stubbed with Clear TODOs**:
6. `offset_of()` - Stub (requires field lookup infrastructure)
7. `type_info_of()` - Stub (requires RTTI)
8. `typeid_of()` - Stub (requires RTTI)

**Infrastructure**:
- Builtin metadata table
- Central dispatcher
- Type predicate helpers (partial)
- Type introspection helpers (stub implementations)

### Phase 11B Requirements (Future)

**Infrastructure Needed**:
1. Field lookup with Selection support
2. Struct layout calculation with padding
3. RTTI system initialization
4. Type info registration

**Additional Built-ins**:
- Memory/allocation: `new()`, `make()`, `delete()`, `free()`
- Aggregation: `min()`, `max()`, `abs()`, `clamp()`

### Phase 11C Requirements (Future)

**Additional Built-ins**:
- SIMD operations
- Intrinsics
- Advanced type queries

## Compilation Strategy

### File Organization

1. `/mnt/d/dev/checker/check_builtin.odin` - New file
   - Builtin metadata expansions
   - Central dispatcher
   - All per-builtin handlers

2. `/mnt/d/dev/checker/types.odin` - Expand
   - Type predicate functions
   - Type introspection stubs
   - Field lookup stubs

3. `/mnt/d/dev/checker/check_expr.odin` - Modify
   - Replace builtin stub (line 3770)

4. `/mnt/d/dev/checker/checker.odin` - Expand
   - Builtin_Proc_Info definition
   - builtin_proc_infos table

### Testing Strategy

**Compile Test**: Basic builtin calls should compile

```odin
test_builtins :: proc() {
    arr: [5]int
    x := len(arr)        // Should work: constant 5
    y := cap(arr)        // Should work: constant 5

    s := size_of(int)    // Should work: constant
    a := align_of(int)   // Should work: constant

    T := type_of(x)      // Should work: returns int type

    // These should error with clear "not yet implemented" messages:
    // o := offset_of(Point, x)
    // ti := type_info_of(int)
    // tid := typeid_of(int)
}
```

**Error Test**: Invalid uses should error appropriately

```odin
test_builtin_errors :: proc() {
    x := len(42)         // Error: not supported for 'int'
    y := cap(42)         // Error: not supported for 'int'
    z := type_of(nil)    // Error: invalid argument
}
```

## Success Criteria

Phase 11A is complete when:

1. ✅ `len()` and `cap()` work for arrays, slices, dynamic arrays, maps
2. ✅ `size_of()` and `align_of()` return values for basic types
3. ✅ `type_of()` returns type operands correctly
4. ✅ Error messages match C++ checker format
5. ✅ Stubbed built-ins have clear TODO markers with C++ line references
6. ✅ Integration with call expression works
7. ✅ Compilation succeeds without errors
8. ✅ No regressions in existing functionality

## Quality Assurance Checklist

- [ ] All implemented built-ins match C++ behavior exactly
- [ ] Error messages are clear and consistent with C++ checker
- [ ] Constant folding works where applicable
- [ ] Type hints are propagated correctly
- [ ] Stub implementations have TODO comments with C++ references
- [ ] Code compiles cleanly
- [ ] Integration point works correctly
- [ ] Addressing modes are set appropriately

## Next Phase Planning

Phase 11B will require:

1. **Field Lookup Infrastructure** (for `offset_of()`):
   - Scope-based field resolution
   - Using/embedding support
   - Nested field paths
   - Struct layout calculation

2. **RTTI Support** (for `type_info_of()`, `typeid_of()`):
   - Type info initialization
   - Type registration
   - Runtime dependency tracking

3. **Memory Built-ins**:
   - `new()`, `make()`, `delete()`, `free()`
   - Allocator tracking
   - Memory initialization
