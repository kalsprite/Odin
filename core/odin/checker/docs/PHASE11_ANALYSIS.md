# Phase 11 Analysis: C++ Builtin Architecture

## Executive Summary

The C++ checker implements ~150 builtin procedures in `/mnt/c/odin/src/check_builtin.cpp` (7,702 LOC). The architecture is based on:

1. **Enum-based dispatch** using `BuiltinProcId` (368 enum values)
2. **Metadata table** `builtin_procs[]` with name, arg count, variadic flag, expr kind, and package
3. **Central dispatcher** `check_builtin_procedure()` with switch statement (line 2396+)
4. **Per-builtin handlers** for each builtin's specific checking logic

## C++ Architecture Details

### 1. Builtin Procedure Enum (`checker_builtin_procs.hpp`)

```cpp
enum BuiltinProcId {
    BuiltinProc_Invalid,

    // Core builtins (Phase 11A target)
    BuiltinProc_len,              // Line 6
    BuiltinProc_cap,              // Line 7
    BuiltinProc_size_of,          // Line 9
    BuiltinProc_align_of,         // Line 10
    BuiltinProc_offset_of,        // Line 11
    BuiltinProc_type_of,          // Line 13
    BuiltinProc_type_info_of,     // Line 14
    BuiltinProc_typeid_of,        // Line 15

    // ... 150+ more builtins

    BuiltinProc_COUNT,
};
```

### 2. Builtin Metadata Table

```cpp
struct BuiltinProc {
    String   name;
    isize    arg_count;
    bool     variadic;
    ExprKind kind;         // Expr_Expr or Expr_Stmt
    BuiltinProcPkg pkg;    // builtin or intrinsics
    bool diverging;
    bool ignore_results;
};

gb_global BuiltinProc builtin_procs[BuiltinProc_COUNT] = {
    {STR_LIT("len"),              1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("cap"),              1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("size_of"),          1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("align_of"),         1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("offset_of"),        1, true,  Expr_Expr, BuiltinProcPkg_builtin},  // variadic!
    {STR_LIT("type_of"),          1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("type_info_of"),     1, false, Expr_Expr, BuiltinProcPkg_builtin},
    {STR_LIT("typeid_of"),        1, false, Expr_Expr, BuiltinProcPkg_builtin},
    // ...
};
```

### 3. Central Dispatcher (`check_builtin_procedure()`)

**Location**: `/mnt/c/odin/src/check_builtin.cpp:2396`

**Dispatch Flow**:
```cpp
bool check_builtin_procedure(CheckerContext *c, Operand *operand, Ast *call, i32 id, Type *type_hint) {
    ast_node(ce, CallExpr, call);

    // 1. Validate arg count against metadata
    BuiltinProc *bp = &builtin_procs[id];
    if (ce->args.count < bp->arg_count ||
        (ce->args.count > bp->arg_count && !bp->variadic)) {
        error(...);
        return false;
    }

    // 2. Pre-check first argument for certain builtins
    switch (id) {
    case BuiltinProc_len:
    case BuiltinProc_cap:
    case BuiltinProc_size_of:
    // ... these may accept types, checked specially
        break;
    default:
        check_multi_expr(c, operand, ce->args[0]);
    }

    // 3. Dispatch to per-builtin handler
    switch (id) {
    case BuiltinProc_len:
    case BuiltinProc_cap:
        // Handler implementation...
        break;
    case BuiltinProc_size_of:
        // Handler implementation...
        break;
    // ... etc
    }

    operand->expr = call;
    return true;
}
```

## Phase 11A: Core Builtin Implementations

### 1. `len()` and `cap()` (Lines 2529-2637)

**Signatures**:
- `len :: proc(x: T) -> int` where T is array-like
- `cap :: proc(x: T) -> int` where T supports capacity

**Implementation Strategy**:
```cpp
case BuiltinProc_len:
case BuiltinProc_cap: {
    check_expr_or_type(c, operand, ce->args[0]);
    Type *op_type = type_deref(operand->type);
    Type *type = t_int;  // Default return type

    // Type hint support for int/uint
    if (type_hint == t_int || type_hint == t_uint) {
        type = type_hint;
    }

    // Dispatch by operand type
    if (is_type_string(op_type) && id == BuiltinProc_len) {
        // String length - can be constant
        if (operand->mode == Addressing_Constant) {
            mode = Addressing_Constant;
            value = exact_value_i64(str.len);
            type = t_untyped_integer;
        } else {
            mode = Addressing_Value;
        }
    } else if (is_type_array(op_type)) {
        // Array - always constant
        mode = Addressing_Constant;
        value = exact_value_i64(at->Array.count);
        type = t_untyped_integer;
    } else if (is_type_slice(op_type) && id == BuiltinProc_len) {
        mode = Addressing_Value;
    } else if (is_type_dynamic_array(op_type)) {
        mode = Addressing_Value;
    } else if (is_type_map(op_type)) {
        mode = Addressing_Value;
    } else if (operand->mode == Addressing_Type && is_type_enum(op_type)) {
        // Enum len/cap - constant
        mode = Addressing_Constant;
        if (id == BuiltinProc_len) {
            value = exact_value_i64(bt->Enum.fields.count);
        } else {  // cap
            value = exact_value_sub(*bt->Enum.max_value, *bt->Enum.min_value);
            value = exact_value_increment_one(value);
        }
    } else if (is_type_simd_vector(op_type)) {
        mode = Addressing_Constant;
        value = exact_value_i64(bt->SimdVector.count);
    } else {
        error(...);
        return false;
    }

    operand->mode = mode;
    operand->value = value;
    operand->type = type;
}
```

**Key Features**:
- Supports both value and type operands (e.g., `len([3]int)` vs `len(my_array)`)
- Constant folding for arrays, enums, strings
- Type hint propagation for return type
- Special handling for SOA structs

### 2. `size_of()` (Lines 2639-2658)

**Signature**: `size_of :: proc(T: Type or expr) -> untyped int`

**Implementation**:
```cpp
case BuiltinProc_size_of: {
    Operand o = {};
    check_expr_or_type(c, &o, ce->args[0]);

    Type *t = o.type;
    if (t == nullptr || t == t_invalid) {
        error(ce->args[0], "Invalid argument for 'size_of'");
        return false;
    }
    t = default_type(t);  // Convert untyped -> typed

    operand->mode = Addressing_Constant;
    operand->value = exact_value_i64(type_size_of(t));
    operand->type = t_untyped_integer;
}
```

**Key Features**:
- Always constant
- Accepts both types and expressions
- Returns untyped integer

### 3. `align_of()` (Lines 2660-2679)

**Signature**: `align_of :: proc(T: Type or expr) -> untyped int`

**Implementation**: Nearly identical to `size_of()`, calls `type_align_of(t)`

### 4. `offset_of()` (Lines 2682-2793)

**Signature**:
- `offset_of :: proc(value.field) -> uintptr`
- `offset_of :: proc(Type, field) -> uintptr`

**Implementation**:
```cpp
case BuiltinProc_offset_of: {
    Type *type = nullptr;
    Ast *field_arg = nullptr;

    if (ce->args.count == 1) {
        // Form: offset_of(value.field)
        Ast *arg0 = unparen_expr(ce->args[0]);
        if (arg0->kind != Ast_SelectorExpr) {
            error(..., "not a selector expression");
            return false;
        }
        ast_node(se, SelectorExpr, arg0);

        Operand x = {};
        check_expr(c, &x, se->expr);
        type = type_deref(x.type);
        field_arg = se->selector;

    } else if (ce->args.count == 2) {
        // Form: offset_of(Type, field)
        type = check_type(c, ce->args[0]);
        field_arg = unparen_expr(ce->args[1]);
    } else {
        error(...);
        return false;
    }

    // Extract field name
    String field_name = {};
    if (field_arg->kind == Ast_Ident) {
        field_name = field_arg->Ident.token.string;
    } else {
        error(..., "Expected an identifier");
        return false;
    }

    // Validate struct type
    Type *bt = base_type(type);
    if (is_type_polymorphic(bt)) {
        error(..., "unspecialized polymorphic struct");
        return false;
    }

    // Lookup field
    Selection sel = lookup_field(type, field_name, false);
    if (sel.entity == nullptr) {
        error(..., "'%s' has no field named '%s'", ...);
        return false;
    }
    if (sel.indirect) {
        error(..., "Field embedded via pointer");
        return false;
    }

    operand->mode = Addressing_Constant;
    operand->value = exact_value_i64(type_offset_of_from_selection(type, sel));
    operand->type = t_uintptr;
}
```

**Key Features**:
- Two forms: selector expression or type+field
- Field lookup with validation
- Rejects polymorphic types, indirect (pointer) fields
- Always returns constant uintptr

### 5. `type_of()` (Lines 2870-2907)

**Signature**: `type_of :: proc(val: Type) -> type(Type)`

**Implementation**:
```cpp
case BuiltinProc_type_of: {
    Operand o = {};
    check_expr_or_type(c, &o, ce->args[0]);

    if (o.mode == Addressing_Invalid || o.mode == Addressing_Builtin) {
        return false;
    }
    if (o.type == nullptr || o.type == t_invalid || is_type_asm_proc(o.type)) {
        error(o.expr, "Invalid argument to 'type_of'");
        return false;
    }

    if (is_type_untyped(o.type)) {
        error(o.expr, "'type_of' of %s cannot be determined", ...);
        return false;
    }

    // Prevent cycles
    if (c->curr_proc_sig == o.type) {
        error(o.expr, "Invalid cyclic type usage from 'type_of'");
        return false;
    }

    if (is_type_polymorphic(o.type)) {
        error(o.expr, "'type_of' of polymorphic type cannot be determined");
        return false;
    }

    operand->mode = Addressing_Type;
    operand->type = o.type;
}
```

**Key Features**:
- Returns type as operand (mode = Addressing_Type)
- Rejects untyped, polymorphic, and asm proc types
- Cycle detection for recursive procedures

### 6. `type_info_of()` (Lines 2909-2952)

**Signature**: `type_info_of :: proc(T: Type) -> ^Type_Info`

**Implementation**:
```cpp
case BuiltinProc_type_info_of: {
    if (c->scope->flags & ScopeFlag_Global) {
        compiler_error("Cannot be declared within runtime package");
    }
    if (build_context.no_rtti) {
        error(call, "'%s' has been disallowed", ...);
        return false;
    }

    init_core_type_info(c->checker);  // Ensure runtime is initialized

    Operand o = {};
    check_expr_or_type(c, &o, ce->args[0]);

    Type *t = o.type;
    if (t == nullptr || t == t_invalid || is_type_polymorphic(t)) {
        error(...);
        return false;
    }
    t = default_type(t);

    add_type_info_type(c, t);  // Register for RTTI generation

    if (is_operand_value(o) && is_type_typeid(t)) {
        add_package_dependency(c, "runtime", "__type_info_of");
    } else if (o.mode != Addressing_Type) {
        error(expr, "Expected a type or typeid");
        return false;
    }

    operand->mode = Addressing_Value;
    operand->type = t_type_info_ptr;
}
```

**Key Features**:
- RTTI dependency - disabled with `-no-rtti`
- Runtime package restriction
- Registers type for type info generation
- Returns `^Type_Info` pointer

### 7. `typeid_of()` (Lines 2954-2990)

**Signature**: `typeid_of :: proc(T: Type) -> typeid`

**Implementation**:
```cpp
case BuiltinProc_typeid_of: {
    if (c->scope->flags & ScopeFlag_Global) {
        compiler_error("Cannot be declared within runtime package");
    }
    if (build_context.no_rtti) {
        error(call, "'%s' has been disallowed", ...);
        return false;
    }

    init_core_type_info(c->checker);

    Operand o = {};
    check_expr_or_type(c, &o, ce->args[0]);

    Type *t = o.type;
    if (t == nullptr || t == t_invalid || is_type_polymorphic(t)) {
        error(...);
        return false;
    }
    t = default_type(t);

    add_type_info_type(c, t);

    if (o.mode != Addressing_Type) {
        error(expr, "Expected a type");
        return false;
    }

    operand->mode = Addressing_Value;
    operand->type = t_typeid;
    operand->value = exact_value_typeid(t);  // Constant typeid value
}
```

**Key Features**:
- Similar to `type_info_of()` but returns `typeid` value
- Can be constant-folded
- RTTI-dependent

## Helper Functions Required

From analysis of the C++ code, we need these helper functions:

1. **Type checking helpers**:
   - `is_type_string()`, `is_type_array()`, `is_type_slice()`, etc.
   - `is_type_dynamic_array()`, `is_type_map()`, `is_type_enum()`
   - `is_type_simd_vector()`, `is_type_struct()`
   - `type_deref()` - dereference pointer types

2. **Type introspection**:
   - `type_size_of()` - get size in bytes
   - `type_align_of()` - get alignment
   - `type_offset_of_from_selection()` - compute field offset
   - `default_type()` - convert untyped to default typed

3. **Field lookup**:
   - `lookup_field()` - find struct field by name
   - Returns `Selection` with entity, indirect flag

4. **Value helpers**:
   - `exact_value_i64()` - create integer exact value
   - `exact_value_typeid()` - create typeid exact value

5. **RTTI support**:
   - `init_core_type_info()` - initialize type info system
   - `add_type_info_type()` - register type for RTTI
   - `add_package_dependency()` - track runtime dependencies

## Integration Points

### 1. Call Expression Checking

Currently in `/mnt/d/dev/checker/check_expr.odin`, `check_call_expr()` handles:
- Regular procedure calls
- Type assertions
- Type conversions

**Integration needed**:
```odin
check_call_expr :: proc(ctx: ^Checker_Context, operand: ^Operand, node: ^ast.Call_Expr) -> bool {
    // ... existing code ...

    // After checking proc expression
    if operand.mode == .Builtin {
        // NEW: Dispatch to builtin checker
        builtin_id := operand.builtin_id
        return check_builtin_procedure(ctx, operand, node, builtin_id, type_hint)
    }

    // ... rest of existing code ...
}
```

### 2. Builtin Entity Registration

Builtins are registered in universal scope during checker initialization. Current Odin implementation has basic builtin support in `entity.odin`:

```odin
alloc_entity_builtin :: proc(
    name: string,
    id: Builtin_Proc_Id,
    pkg := Builtin_Proc_Pkg.Builtin,
) -> ^Entity
```

## Error Messages

The C++ implementation has specific error messages for each builtin. Examples:

- `len()`: `"'len' is not supported for '%s'"`, with special hint for bit_set suggesting `card()`
- `offset_of()`: `"'%s' has no field named '%s'"` with did-you-mean suggestions
- `type_of()`: `"'type_of' of %s cannot be determined"` for untyped
- `type_info_of()`: `"'type_info_of' has been disallowed"` when no-rtti

## Architecture Recommendations for Odin Port

### 1. Enum and Metadata Structure

```odin
// Expand existing Builtin_Proc_Id in checker.odin
Builtin_Proc_Id :: enum {
    Invalid,

    // Phase 11A
    Len,
    Cap,
    Size_Of,
    Align_Of,
    Offset_Of,
    Offset_Of_By_String,  // Advanced variant
    Type_Of,
    Type_Info_Of,
    Typeid_Of,

    // Phase 11B (stub)
    // ... memory/allocation built-ins

    // Phase 11C (stub)
    // ... advanced built-ins
}

Builtin_Proc_Info :: struct {
    name: string,
    arg_count: int,
    variadic: bool,
    kind: Expr_Kind,  // Expr or Stmt
    pkg: Builtin_Proc_Pkg,
}

builtin_proc_infos := [Builtin_Proc_Id]Builtin_Proc_Info{
    .Len = {name="len", arg_count=1, variadic=false, kind=.Expr, pkg=.Builtin},
    // ...
}
```

### 2. Central Dispatcher

```odin
// New file: check_builtin.odin
check_builtin_procedure :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
    id: Builtin_Proc_Id,
    type_hint: ^Type,
) -> bool {
    // Validate arg count
    info := builtin_proc_infos[id]
    if len(call.args) < info.arg_count {
        error(call, "Too few arguments for '%s'", info.name)
        return false
    }
    if len(call.args) > info.arg_count && !info.variadic {
        error(call, "Too many arguments for '%s'", info.name)
        return false
    }

    // Dispatch
    switch id {
    case .Len, .Cap:
        return check_builtin_len_cap(ctx, operand, call, id, type_hint)
    case .Size_Of:
        return check_builtin_size_of(ctx, operand, call)
    case .Align_Of:
        return check_builtin_align_of(ctx, operand, call)
    case .Offset_Of:
        return check_builtin_offset_of(ctx, operand, call)
    case .Type_Of:
        return check_builtin_type_of(ctx, operand, call)
    case .Type_Info_Of:
        return check_builtin_type_info_of(ctx, operand, call)
    case .Typeid_Of:
        return check_builtin_typeid_of(ctx, operand, call)
    case:
        error(call, "Builtin '%v' not yet implemented", id)
        return false
    }
}
```

### 3. Per-Builtin Handlers

Each handler follows the pattern:
```odin
check_builtin_len_cap :: proc(
    ctx: ^Checker_Context,
    operand: ^Operand,
    call: ^ast.Call_Expr,
    id: Builtin_Proc_Id,
    type_hint: ^Type,
) -> bool {
    // Check argument
    check_expr_or_type(ctx, operand, call.args[0])
    if operand.mode == .Invalid {
        return false
    }

    // Determine result type and value
    // ... port C++ logic ...

    operand.mode = result_mode
    operand.value = result_value
    operand.type = result_type
    operand.expr = call
    return true
}
```

## Phase 11A Scope Summary

**In Scope**:
- 8 core type/memory builtins with COMPLETE implementations
- Full error handling and validation
- Constant folding where applicable
- Type hint support
- Integration with existing call expression checking

**Out of Scope** (Phase 11B/C):
- Memory/allocation builtins (new, make, delete, free)
- Mathematical builtins (min, max, abs, clamp)
- SIMD operations
- Intrinsics
- Advanced type query builtins

**Success Criteria**:
1. All 8 builtins compile and type-check correctly
2. Error messages match C++ checker
3. Constant folding works for arrays, enums, strings
4. Integration with call expression checking complete
5. No regressions in existing functionality

## Next Steps

1. Design Odin architecture (data structures, module organization)
2. Port helper functions (type queries, introspection)
3. Implement 8 core built-ins with full C++ parity
4. Integrate with call expression checking
5. Verify compilation and functionality
6. Document Phase 11B requirements
