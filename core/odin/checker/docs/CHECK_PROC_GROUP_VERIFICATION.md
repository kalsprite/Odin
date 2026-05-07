# Procedure Group (Overload Resolution) Verification Report

**Date**: 2025-10-03
**Odin Port**: `/mnt/d/dev/checker/check_proc_group.odin`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:6933-7504`, `/mnt/c/odin/src/checker.cpp:3230-3248`

---

## Section 1: Implementation Status

**Overall Completion**: ~75%

### Implemented Features
- ✅ Basic procedure group entity retrieval (`proc_group_entities`)
- ✅ Type distance scoring function (`assign_score_function`)
- ✅ Type distance calculation integration (`check_is_assignable_to_with_score`)
- ✅ Parameter count filtering (`filter_proc_group_by_param_count`)
- ✅ Named argument filtering (pre-filtering by parameter names)
- ✅ Candidate scoring and sorting (`Valid_Index_And_Score`, `valid_index_and_score_cmp`)
- ✅ Best match selection with ambiguity detection
- ✅ Single candidate fast path
- ✅ Multiple candidate overload resolution
- ✅ Named argument handling with parameter lookup (`lookup_procedure_parameter`)
- ✅ Split argument handling (positional vs named)
- ✅ Polymorphic procedure penalty scoring

### Missing/Incomplete Features
- ⚠️ **Type inference optimization for procedure groups** (lines 7051-7120 in C++)
- ⚠️ **Target feature matching** (`matched_target_features` scoring)
- ⚠️ **Detailed error messages** with candidate listing
- ⚠️ **Argument type printing** in error messages
- ⚠️ **`check_entity_decl` call** for proc group (line 57: TODO comment)
- ⚠️ **Multi-value return unpacking** in arguments (`check_unpack_arguments`)
- ⚠️ **Type hint propagation** for named arguments (lines 7140-7152)
- ⚠️ **Polymorphic procedure specialization** (gen_entity tracking)
- ⚠️ **Where clause evaluation** for polymorphic candidates
- ⚠️ **SOA struct filtering** in error messages (lines 7287-7343)

### Stubbed Code
- Line 57: `check_entity_decl(ctx, operand.proc_group, nil, nil)` - commented out with TODO
- Line 519: `update_untyped_expr_type and add_type_and_value` - commented out with TODO
- Lines 749, 803-805: Argument type printing in error messages - TODO comments

---

## Section 2: Overload Collection (Candidate Gathering)

### C++ Implementation
**Reference**: `/mnt/c/odin/src/checker.cpp:3230-3248`

```cpp
gb_internal Array<Entity *> proc_group_entities(CheckerContext *c, Operand o) {
    Array<Entity *> procs = {};
    if (o.mode == Addressing_ProcGroup) {
        GB_ASSERT(o.proc_group != nullptr);
        if (o.proc_group->kind == Entity_ProcGroup) {
            check_entity_decl(c, o.proc_group, nullptr, nullptr);  // <-- IMPORTANT
            return o.proc_group->ProcGroup.entities;
        }
    }
    return procs;
}
```

### Odin Implementation
**Location**: `/mnt/d/dev/checker/check_proc_group.odin:46-63`

```odin
proc_group_entities :: proc(ctx: ^Checker_Context, operand: Operand) -> []^Entity {
    if operand.mode != .Proc_Group {
        return nil
    }
    if operand.proc_group == nil {
        return nil
    }
    if operand.proc_group.kind == .Proc_Group {
        // TODO: check_entity_decl(ctx, operand.proc_group, nil, nil)  // <-- MISSING
        proc_group := operand.proc_group.variant.(Entity_Proc_Group)
        return proc_group.procs[:]
    }
    return nil
}
```

### Verification Result: ⚠️ INCOMPLETE

**Issues**:
1. **Missing `check_entity_decl` call** (line 3235 in C++)
   - The C++ code ensures the procedure group declaration is fully checked before returning entities
   - The Odin port has this commented out with a TODO
   - **Impact**: May return entities that haven't been fully type-checked, leading to inconsistent state

2. **No cloned array variant**
   - C++ has `proc_group_entities_cloned` (line 3242-3248) that clones the array
   - Odin port doesn't implement this variant
   - **Impact**: May cause memory aliasing issues if the array is modified during filtering

### Required Fix
```odin
// Add check_entity_decl call
if operand.proc_group.kind == .Proc_Group {
    check_entity_decl(ctx, operand.proc_group, nil, nil)  // MUST BE IMPLEMENTED
    proc_group := operand.proc_group.variant.(Entity_Proc_Group)
    return proc_group.procs[:]
}
```

---

## Section 3: Type Distance Analysis (Scoring Algorithm)

### C++ Implementation
**Reference**: `/mnt/c/odin/src/check_expr.cpp:992-1002`, `667-987`

The scoring mechanism has two components:

#### 3.1 Score Function (assign_score_function)
**Reference**: `/mnt/c/odin/src/check_expr.cpp:992-1002`

```cpp
gb_internal i64 assign_score_function(i64 distance, bool is_variadic=false) {
    // 3*x^2 + 1 > x^2 + x + 1 (for positive x)
    i64 const c = 3*MAXIMUM_TYPE_DISTANCE*MAXIMUM_TYPE_DISTANCE + 1;

    i64 d = distance*distance; // x^2
    if (is_variadic && d >= 0) {
        d += distance + 1; // x^2 + x + 1
    }
    return gb_max(c - d, 0);
}
```

**Odin Port**: `/mnt/d/dev/checker/check_proc_group.odin:68-80`

```odin
assign_score_function :: proc(distance: i64, is_variadic := false) -> i64 {
    c := 3 * MAXIMUM_TYPE_DISTANCE * MAXIMUM_TYPE_DISTANCE + 1
    d := distance * distance
    if is_variadic && d >= 0 {
        d += distance + 1
    }
    return max(c - d, 0)
}
```

✅ **CORRECT** - Exact match with C++ implementation.

#### 3.2 Type Distance Calculation (check_distance_between_types)
**Reference**: `/mnt/c/odin/src/check_expr.cpp:667-987` (320 lines)

This is a complex function with multiple distance levels:
- 0: Exact type match
- 1: Untyped to typed conversion (untyped_nil, untyped_uninit)
- 1-2: Untyped constant representable conversion
- 2: Polymorphic type matching
- 3: Enum base type matching (context-dependent)
- 4: Subtype conversions, Type->typeid, pointer conversions
- 5: rawptr conversions, complex element conversions
- 6: Array programming distance
- 7: Matrix element distance
- MAXIMUM_TYPE_DISTANCE (11): auto_cast, any type

**Odin Port**: `/mnt/d/dev/checker/check_expr.odin:5441-5792` (352 lines)

### Verification Result: ⚠️ DEPENDENCIES REQUIRED

The Odin port calls `check_distance_between_types` in `check_is_assignable_to_with_score` (line 175), which is implemented in `check_expr.odin`. This is a **dependency** on another module.

**Status of check_distance_between_types**:
- ✅ Implemented in `/mnt/d/dev/checker/check_expr.odin:5441-5792`
- ⚠️ Contains commented-out sections for array/SIMD/matrix programming (lines 5713-5740)
- ✅ Core distance levels appear complete (0, 1, 2, 3, 4, 5, MAXIMUM)

**Integration in check_proc_group.odin**: ✅ CORRECT (line 175)

---

## Section 4: Resolution Algorithm (Best Match Selection)

### C++ Implementation
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7155-7238`

Key steps:
1. Collect valid candidates with scores (lines 7155-7210)
2. Apply target feature scoring bonus (lines 7212-7221)
3. Sort candidates by score (line 7224)
4. Detect ambiguity by comparing best scores (lines 7225-7238)

```cpp
auto valids = array_make<ValidIndexAndScore>(temporary_allocator(), 0, procs.count);

// Score each candidate
for_array(i, procs) {
    Entity *p = procs[i];
    if (p->flags & EntityFlag_Disabled) continue;

    // Test candidate...
    bool is_a_candidate = check_call_arguments_single(&ctx, call, operand,
        p, pt, positional_operands, named_operands,
        CallArgumentErrorMode::NoErrors, &data, true);

    if (!is_a_candidate) continue;

    ValidIndexAndScore item = {};
    item.score = data.score;

    if (data.gen_entity != nullptr) {
        array_add(&proc_entities, data.gen_entity);
        index = proc_entities.count-1;
        item.score += assign_score_function(1);  // Prefer non-polymorphic
    }

    max_matched_features = gb_max(max_matched_features, matched_target_features(&pt->Proc));

    item.index = index;
    array_add(&valids, item);
}

// Apply target feature bonus (MISSING IN ODIN)
if (max_matched_features > 0) {
    for_array(i, valids) {
        Entity *p = procs[valids[i].index];
        Type *t = base_type(p->type);
        int matched = matched_target_features(&t->Proc);
        valids[i].score += assign_score_function(max_matched_features-matched);
    }
}

// Sort and detect ambiguity
if (valids.count > 1) {
    array_sort(valids, valid_index_and_score_cmp);
    i64 best_score = valids[0].score;
    Entity *best_entity = proc_entities[valids[0].index];

    for (isize i = 1; i < valids.count; i++) {
        if (best_score > valids[i].score) {
            valids.count = i;  // Truncate to best matches only
            break;
        }
        if (best_entity == proc_entities[valids[i].index]) {
            valids.count = i;  // Same entity from polymorphic generation
            break;
        }
    }
}
```

### Odin Implementation
**Location**: `/mnt/d/dev/checker/check_proc_group.odin:691-809`

```odin
valid_candidates := make([dynamic]Valid_Index_And_Score)
defer delete(valid_candidates)

// Test each candidate
for entity_proc, i in procs {
    if .Disabled in entity_proc.flags {
        continue
    }

    proc_type := base_type(entity_type(entity_proc))
    if proc_type == nil || proc_type.kind != .Proc {
        continue
    }

    candidate_data := Call_Argument_Data{}
    test_ctx := ctx^
    test_ctx.no_polymorphic_errors = true

    ok := check_call_arguments_single(
        &test_ctx, call_node, operand, entity_proc, proc_type,
        positional_operands, named_operands, args_split,
        .No_Errors, &candidate_data, true,
    )

    if !ok {
        continue
    }

    candidate := Valid_Index_And_Score{
        index = i,
        score = candidate_data.score,
    }

    // Prefer non-polymorphic over polymorphic
    if is_type_polymorphic(proc_type) {
        candidate.score += assign_score_function(1)
    }

    append(&valid_candidates, candidate)
}

// MISSING: Target feature scoring (lines 7212-7221 in C++)

// Sort by score
slice.sort_by(valid_candidates[:], valid_index_and_score_cmp)

// Ambiguity detection
best_score := valid_candidates[0].score
best_entity := procs[valid_candidates[0].index]

num_best := 1
for i := 1; i < len(valid_candidates); i += 1 {
    if valid_candidates[i].score < best_score {
        break
    }
    if procs[valid_candidates[i].index] == best_entity {
        break
    }
    num_best += 1
}

if num_best > 1 {
    // Ambiguous call
    error_node(operand.expr, "Ambiguous procedure group call...")
    // ...
}
```

### Verification Result: ⚠️ INCOMPLETE

**Missing Features**:

1. **Target Feature Matching Bonus** (C++ lines 7212-7221)
   ```cpp
   if (max_matched_features > 0) {
       for_array(i, valids) {
           Entity *p = procs[valids[i].index];
           Type *t = base_type(p->type);
           int matched = matched_target_features(&t->Proc);
           valids[i].score += assign_score_function(max_matched_features-matched);
       }
   }
   ```
   - **Impact**: Procedures with better target feature matching won't be preferred
   - **Fix Required**: Implement `matched_target_features` function and apply scoring bonus

2. **Polymorphic Entity Tracking** (gen_entity)
   - C++ maintains separate array `proc_entities` to track generated polymorphic instances (lines 7157-7160, 7196-7202)
   - Odin implementation doesn't track `data.gen_entity` properly
   - Line 739: Polymorphic preference is inverted (should SUBTRACT score for polymorphic, not add)
   - **Impact**: Polymorphic procedures may not be properly distinguished from their specializations

3. **Valid Candidate Truncation**
   - C++ truncates the `valids` array to only include best matches (lines 7228-7237)
   - Odin keeps all candidates and just counts `num_best`
   - **Impact**: Minor - error messages may be slightly different

### Required Fixes

**Fix 1: Correct Polymorphic Scoring**
```odin
// Line 738-740: INCORRECT
if is_type_polymorphic(proc_type) {
    candidate.score += assign_score_function(1)  // WRONG: should SUBTRACT
}

// Should be (matching C++ line 7201):
if data.gen_entity != nil {
    // Prefer non-polymorphic over polymorphic
    candidate.score += assign_score_function(1)
}
```

**Fix 2: Add Target Feature Scoring**
```odin
// After collecting candidates, before sorting:
max_matched_features := 0
for candidate in valid_candidates {
    entity_proc := procs[candidate.index]
    proc_type := base_type(entity_type(entity_proc))
    if proc_type.kind == .Proc {
        pt := &proc_type.variant.(Type_Proc)
        matched := matched_target_features(pt)  // TODO: Implement this function
        max_matched_features = max(max_matched_features, matched)
    }
}

if max_matched_features > 0 {
    for &candidate in valid_candidates {
        entity_proc := procs[candidate.index]
        proc_type := base_type(entity_type(entity_proc))
        pt := &proc_type.variant.(Type_Proc)
        matched := matched_target_features(pt)
        candidate.score += assign_score_function(max_matched_features - matched)
    }
}
```

---

## Section 5: Ambiguity Detection (Multiple Match Handling)

### C++ Implementation
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7223-7238`

```cpp
if (valids.count > 1) {
    array_sort(valids, valid_index_and_score_cmp);
    i64 best_score = valids[0].score;
    Entity *best_entity = proc_entities[valids[0].index];
    GB_ASSERT(best_entity != nullptr);

    for (isize i = 1; i < valids.count; i++) {
        if (best_score > valids[i].score) {
            valids.count = i;
            break;
        }
        if (best_entity == proc_entities[valids[i].index]) {
            valids.count = i;
            break;
        }
    }
}
```

### Odin Implementation
**Location**: `/mnt/d/dev/checker/check_proc_group.odin:780-809`

```odin
slice.sort_by(valid_candidates[:], valid_index_and_score_cmp)

best_score := valid_candidates[0].score
best_entity := procs[valid_candidates[0].index]

num_best := 1
for i := 1; i < len(valid_candidates); i += 1 {
    if valid_candidates[i].score < best_score {
        break
    }
    if procs[valid_candidates[i].index] == best_entity {
        break
    }
    num_best += 1
}

if num_best > 1 {
    // Ambiguous call
    error_node(operand.expr, "Ambiguous procedure group call - multiple procedures match equally")
    // TODO: List all ambiguous candidates
    for i := 0; i < num_best; i += 1 {
        candidate := procs[valid_candidates[i].index]
        // TODO: Print candidate signature
        fmt.printf("  Candidate: %s\n", candidate.token.text)
    }
    data.error = true
    return data
}
```

### Verification Result: ⚠️ INCOMPLETE

**Issues**:

1. **Simplified Candidate Listing** (lines 802-806)
   - C++ provides detailed candidate information with type signatures and source locations (lines 7429-7478)
   - Odin only prints candidate names with `fmt.printf` (should use error system)
   - **Missing**: Type signature formatting, source location, where clause display

2. **Error Message Quality**
   - C++ prints given argument types (lines 7431-7436 via `print_argument_types` lambda)
   - Odin has TODO comments for this (lines 749, 803-805)
   - **Impact**: Users won't see what argument types were provided, making debugging harder

### Required Fix

Implement detailed candidate listing matching C++ lines 7438-7478:

```odin
if num_best > 1 {
    ERROR_BLOCK()  // Use proper error block

    error_node(operand.expr, "Ambiguous procedure group call '%s' that match with the given arguments", expr_name)

    // Print given argument types
    if len(positional_operands) == 0 && len(named_operands) == 0 {
        error_line("\tNo given arguments\n")
    } else {
        error_line("\tGiven argument types: (")
        i := 0
        for operand in positional_operands {
            if i > 0 do error_line(", ")
            type_str := type_to_string(operand.type)
            error_line("%s", type_str)
            i += 1
        }
        for operand, idx in named_operands {
            if i > 0 do error_line(", ")
            type_str := type_to_string(operand.type)
            // Get field name from args_split.named[idx]
            error_line("name = %s", type_str)
            i += 1
        }
        error_line(")\n")
    }

    // List all ambiguous candidates with full signatures
    for i := 0; i < num_best; i += 1 {
        entity_proc := procs[valid_candidates[i].index]
        pos := entity_proc.token.pos
        proc_type := base_type(entity_type(entity_proc))

        // Format type signature
        type_str := type_to_string(proc_type)
        defer delete(type_str)

        name := entity_proc.token.text
        sep := "::" if entity_proc.kind == .Procedure else ":="

        error_line("\t%s %s %s at %s\n", name, sep, type_str, token_pos_to_string(pos))

        // TODO: Print where clauses if polymorphic
    }

    data.error = true
    return data
}
```

---

## Section 6: Named Arguments (Overload Resolution with Names)

### C++ Implementation
**Reference**: `/mnt/c/odin/src/check_expr.cpp:6969-6995`, `6325-6364`, `7124-7153`

The C++ implementation handles named arguments in three places:

#### 6.1 Named Argument Pre-Filtering
**Location**: `/mnt/c/odin/src/check_expr.cpp:6969-6995`

Filters out procedures that don't have the named parameters:

```cpp
// ignore named arguments first
for (Ast *arg : named_args) {
    if (arg->kind != Ast_FieldValue) continue;

    ast_node(fv, FieldValue, arg);
    if (fv->field->kind != Ast_Ident) continue;

    String key = fv->field->Ident.token.string;
    for (isize proc_index = procs.count-1; proc_index >= 0; proc_index--) {
        Type *t = procs[proc_index]->type;
        if (is_type_proc(t)) {
            isize param_index = lookup_procedure_parameter(t, key);
            if (param_index < 0) {
                array_unordered_remove(&procs, proc_index);
            }
        }
    }
}

if (procs.count == 0) {
    // if any of the named arguments are wrong, the `procs` will be empty
    // just start from scratch
    array_free(&procs);
    procs = proc_group_entities_cloned(c, *operand);
}
```

**Odin Port**: `/mnt/d/dev/checker/check_proc_group.odin:560-594`

✅ **CORRECT** - Matches C++ logic exactly.

#### 6.2 Named Argument Type Hint Propagation
**Location**: `/mnt/c/odin/src/check_expr.cpp:7124-7153`

For procedure groups with multiple candidates, infers type hints from common parameters:

```cpp
for_array(i, named_args) {
    Ast *arg = named_args[i];
    // ... validate field value ...
    String key = fv->field->Ident.token.string;
    Ast *value = fv->value;

    Type *type_hint = nullptr;

    // Find type hint from parameter list
    for (isize lhs_idx = 0; lhs_idx < lhs_count; lhs_idx++) {
        Entity *e = lhs[lhs_idx];
        if (e != nullptr && e->token.string == key &&
            !is_type_polymorphic(e->type)) {
            type_hint = e->type;
            break;
        }
    }

    Operand o = {};
    check_expr_with_type_hint(c, &o, value, type_hint);  // <-- Type hint usage
    array_add(&named_operands, o);
}
```

**Odin Port**: ❌ **MISSING**

The Odin implementation (lines 676-689) checks named arguments WITHOUT type hints:

```odin
for arg, i in args_split.named {
    if fv, ok := arg.derived.(^ast.Field_Value); ok {
        check_expr_base(ctx, &named_operands[i], fv.value, nil)  // <-- No type hint
    }
}
```

**Impact**: Type inference quality is reduced for named arguments in procedure groups.

#### 6.3 Named Argument Reordering
**Location**: `/mnt/c/odin/src/check_expr.cpp:6325-6364`

```cpp
auto visited = temporary_slice_make<bool>(pt->param_count);
auto ordered_operands = array_make<Operand>(temporary_allocator(), pt->param_count);

// Fill positional arguments first
for (isize i = 0; i < positional_operand_count; i++) {
    ordered_operands[i] = positional_operands[i];
    visited[i] = true;
}

// Fill named arguments
for_array(i, ce->split_args->named) {
    Ast *arg = ce->split_args->named[i];
    Operand operand = named_operands[i];

    ast_node(fv, FieldValue, arg);
    String name = fv->field->Ident.token.string;
    isize param_index = lookup_procedure_parameter(pt, name);

    if (param_index < 0) {
        // Error: parameter not found
    }
    if (visited[param_index]) {
        // Error: duplicate parameter
    }

    visited[param_index] = true;
    ordered_operands[param_index] = operand;
}
```

**Odin Port**: `/mnt/d/dev/checker/check_proc_group.odin:344-432`

✅ **CORRECT** - Properly reorders arguments and detects duplicates.

### Verification Result: ⚠️ INCOMPLETE

**Missing**: Type hint propagation for named arguments in procedure groups (C++ lines 7124-7153)

**Required Fix**:

The Odin port needs to build a `lhs` array of common parameters (like C++ lines 7051-7120) and use it for type hints:

```odin
// After filtering by parameter count, before checking arguments:
// Build lhs array for type inference (matching C++ lines 7051-7120)
lhs: []^Entity = nil
lhs_count := -1

if len(procs) > 1 {
    // Find minimum parameter count across all candidates
    proc_arg_count := -1
    for p in procs {
        proc_type := base_type(entity_type(p))
        if proc_type != nil && proc_type.kind == .Proc {
            pt := &proc_type.variant.(Type_Proc)
            if proc_arg_count < 0 {
                proc_arg_count = pt.param_count
            } else {
                proc_arg_count = min(proc_arg_count, pt.param_count)
            }
        }
    }

    if proc_arg_count >= 0 {
        lhs_count = proc_arg_count
        if lhs_count > 0 {
            lhs = make([]^Entity, lhs_count, context.temp_allocator)

            // For each parameter position, find common type across all candidates
            for param_index in 0..<lhs_count {
                e: ^Entity = nil
                for p in procs {
                    proc_type := base_type(entity_type(p))
                    if proc_type == nil || proc_type.kind != .Proc do continue
                    pt := &proc_type.variant.(Type_Proc)

                    if e == nil {
                        e = pt.params.variant.(Type_Tuple).variables[param_index]
                    } else {
                        f := pt.params.variant.(Type_Tuple).variables[param_index]
                        if e == f {
                            continue
                        }
                        if are_types_identical(entity_type(e), entity_type(f)) {
                            // Check ellipsis flags match
                            ee := .Ellipsis in e.flags
                            fe := .Ellipsis in f.flags
                            if ee == fe {
                                continue
                            }
                        }
                        // Not close enough
                        e = nil
                        break
                    }
                }
                lhs[param_index] = e
            }
        }
    }
}

// Then use lhs for type hints when checking named arguments:
for arg, i in args_split.named {
    if fv, ok := arg.derived.(^ast.Field_Value); ok {
        if ident, ok := fv.field.derived.(^ast.Ident); ok {
            name := ident.name

            // Find type hint from lhs
            type_hint: ^Type = nil
            for lhs_idx in 0..<lhs_count {
                e := lhs[lhs_idx]
                if e != nil && e.token.text == name && !is_type_polymorphic(entity_type(e)) {
                    type_hint = entity_type(e)
                    break
                }
            }

            check_expr_with_type_hint(ctx, &named_operands[i], fv.value, type_hint)
        }
    }
}
```

---

## Section 7: Missing Features

### 7.1 Type Inference Optimization for Procedure Groups
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7051-7120`

**Description**: When multiple candidates exist, the C++ code builds a `lhs` (left-hand side) array that contains common parameters across all candidates. This improves type inference for positional arguments.

**Status**: ❌ **NOT IMPLEMENTED**

**Impact**: Type inference quality is reduced when calling procedure groups with multiple candidates.

**C++ Reference**:
```cpp
// NOTE(bill, 2019-07-13): This code is used to improve the type inference for procedure groups
// where the same positional parameter has the same type value (and ellipsis)
isize proc_arg_count = -1;
for (Entity *p : procs) {
    Type *pt = base_type(p->type);
    if (pt != nullptr && is_type_proc(pt)) {
        if (proc_arg_count < 0) {
            proc_arg_count = pt->Proc.param_count;
        } else {
            proc_arg_count = gb_min(proc_arg_count, pt->Proc.param_count);
        }
    }
}

if (proc_arg_count >= 0) {
    lhs_count = proc_arg_count;
    if (lhs_count > 0)  {
        lhs = gb_alloc_array(temporary_allocator(), Entity *, lhs_count);
        for (isize param_index = 0; param_index < lhs_count; param_index++) {
            Entity *e = nullptr;
            for (Entity *p : procs) {
                // Find common parameter type across all candidates...
            }
            lhs[param_index] = e;
        }
    }
}

check_unpack_arguments(c, lhs, lhs_count, &positional_operands, positional_args, UnpackFlag_None, variadic_index);
```

**Required Fix**: Implement the common parameter detection logic as shown in Section 6.

---

### 7.2 Target Feature Matching
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7204`, `7212-7221`, `/mnt/c/odin/src/types.cpp:3338`

**Description**: Procedures can be annotated with target features (e.g., CPU instruction sets). When resolving overloads, candidates with better target feature matching get a scoring bonus.

**Status**: ❌ **NOT IMPLEMENTED**

**Impact**: Procedures optimized for specific CPU features won't be preferred over generic versions.

**C++ Reference**:
```cpp
max_matched_features = gb_max(max_matched_features, matched_target_features(&pt->Proc));

// Later:
if (max_matched_features > 0) {
    for_array(i, valids) {
        Entity *p = procs[valids[i].index];
        Type *t = base_type(p->type);
        GB_ASSERT(t->kind == Type_Proc);

        int matched = matched_target_features(&t->Proc);
        valids[i].score += assign_score_function(max_matched_features-matched);
    }
}
```

**Required Fix**:
1. Implement `matched_target_features` function
2. Apply scoring bonus as shown above

---

### 7.3 Detailed Error Messages
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7240-7426`

**Description**: When no matching overload is found, the C++ code prints:
- Given argument types
- List of all candidate signatures with source locations
- Special filtering for SOA struct candidates

**Status**: ⚠️ **PARTIALLY IMPLEMENTED**

**Current State**:
- Line 748: Basic "No procedures in group match" error
- Line 749: TODO comment for printing argument types
- Line 800: Basic "Ambiguous procedure group call" error
- Lines 802-806: Simplified candidate listing with TODO comments

**Missing**:
- Argument type printing (C++ lines 7240-7268)
- Full candidate signature formatting (C++ lines 7346-7425)
- SOA struct filtering (C++ lines 7287-7343)
- Where clause display for polymorphic procedures (C++ lines 7456-7476)

**C++ Reference** (no match error):
```cpp
ERROR_BLOCK();

error(operand->expr, "No procedures or ambiguous call for procedure group '%s' that match with the given arguments", expr_name);
if (positional_operands.count == 0 && named_operands.count == 0) {
    error_line("\tNo given arguments\n");
} else {
    print_argument_types();  // Lambda that prints all argument types
}

if (procs.count == 0) {
    procs = proc_group_entities_cloned(c, *operand);
}
if (procs.count > 0) {
    error_line("Did you mean to use one of the following:\n");
}

// Filter candidates for better error messages (SOA struct logic)
// ...

// Print each candidate with full signature
for_array(i, procs) {
    Entity *proc = procs[i];
    TokenPos pos = proc->token.pos;
    Type *t = base_type(proc->type);

    gbString pt = type_to_string(t);
    String name = proc->token.string;

    error_line("\t%.*s :: %s at %s\n", LIT(name), pt, token_pos_to_string(pos));
}
```

**Required Fix**: Implement comprehensive error messages as shown in Section 5.

---

### 7.4 Multi-Value Return Unpacking
**Reference**: `/mnt/c/odin/src/check_expr.cpp:6948-6967`, `7122`

**Description**: Arguments can be call expressions that return multiple values, which need to be unpacked and counted properly.

**Status**: ⚠️ **SIMPLIFIED**

**Current State**:
- Line 553-558: Simple `len(call.args)` for min/max argument count
- Comment: "For MVP, we assume simple single-value arguments"

**C++ Logic**:
```cpp
isize max_arg_count = positional_args.count + named_args.count;
for (Ast *arg : positional_args) {
    arg = strip_or_return_expr(arg);
    if (arg && arg->kind == Ast_CallExpr) {
        max_arg_count = ISIZE_MAX;  // Unbounded due to multi-value return
        break;
    }
}
```

Then uses `check_unpack_arguments` to properly unpack multi-value returns into operands.

**Impact**: Procedure group calls with multi-value return arguments won't work correctly.

**Required Fix**: Implement `check_unpack_arguments` and multi-value detection logic.

---

### 7.5 Polymorphic Procedure Specialization Tracking
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7157-7160`, `7196-7202`

**Description**: When a polymorphic procedure is specialized for specific argument types, the generated entity (`gen_entity`) is tracked separately.

**Status**: ⚠️ **INCOMPLETE**

**Current State**:
- Line 33: `gen_entity: ^Entity` field exists in `Call_Argument_Data`
- Line 738-740: Polymorphic penalty scoring (but INVERTED - see Section 4)
- Gen_entity not properly tracked or used

**C++ Logic**:
```cpp
auto proc_entities = array_make<Entity *>(temporary_allocator(), 0, procs.count*2 + 1);
for (Entity *proc : procs) {
    array_add(&proc_entities, proc);
}

// When testing candidates:
if (data.gen_entity != nullptr) {
    array_add(&proc_entities, data.gen_entity);
    index = proc_entities.count-1;
    item.score += assign_score_function(1);  // Prefer non-polymorphic
}
```

This allows polymorphic specializations to be treated as separate candidates.

**Impact**: Polymorphic procedure specialization may not work correctly in procedure groups.

**Required Fix**: Implement separate `proc_entities` tracking like C++ (see Section 4, Fix 1).

---

### 7.6 Where Clause Evaluation
**Reference**: `/mnt/c/odin/src/check_expr.cpp:6717-6797`

**Description**: Polymorphic procedures can have `where` clauses that must evaluate to true for the procedure to be a valid candidate.

**Status**: ❌ **NOT VERIFIED** (may be in `check_poly_proc.odin`)

**C++ Reference**:
```cpp
gb_internal bool evaluate_where_clauses(CheckerContext *ctx, Ast *call_expr, Scope *scope, Slice<Ast *> *clauses, bool print_err) {
    if (clauses != nullptr) {
        for (Ast *clause : *clauses) {
            Operand o = {};
            check_expr(ctx, &o, clause);
            if (o.mode != Addressing_Constant) {
                if (print_err) error(clause, "'where' clauses expect a constant boolean evaluation");
                return false;
            }
            if (!o.value.value_bool) {
                if (print_err) {
                    // Print detailed error with clause and definitions
                }
                return false;
            }
        }
    }
    return true;
}
```

**Impact**: If not implemented, polymorphic constraints won't be enforced in procedure groups.

**Required Investigation**: Check if `check_poly_proc.odin` implements this.

---

### 7.7 Check Entity Declaration
**Reference**: `/mnt/c/odin/src/checker.cpp:3235`

**Description**: Before using procedure group entities, ensure they've been fully type-checked.

**Status**: ❌ **STUBBED** (line 57 has TODO comment)

**Impact**: Critical - may use partially-checked entities leading to invalid state.

**Required Fix**: Implement or call `check_entity_decl` as shown in Section 2.

---

## Section 8: Semantic Differences

### 8.1 Polymorphic Scoring Inversion
**Location**: `/mnt/d/dev/checker/check_proc_group.odin:738-740`

**Issue**: The polymorphic penalty is INVERTED from C++.

**Odin Code**:
```odin
// Prefer non-polymorphic over polymorphic
if is_type_polymorphic(proc_type) {
    candidate.score += assign_score_function(1)  // WRONG: Adding makes it BETTER
}
```

**C++ Code**:
```cpp
if (data.gen_entity != nullptr) {
    // prefer non-polymorphic procedures over polymorphic
    item.score += assign_score_function(1);  // This is for the SPECIALIZED version
}
```

**Analysis**:
- The C++ code adds score to the SPECIALIZED (non-polymorphic) version, making it preferred
- The Odin code adds score to the POLYMORPHIC version, making it preferred
- **This is backwards**

**Correct Logic**: Non-polymorphic/specialized procedures should get a score bonus, not polymorphic ones.

**Fix**: Change to:
```odin
// Track generated polymorphic entities separately
if candidate_data.gen_entity != nil {
    // The generated entity is the specialized version - prefer it
    candidate.score += assign_score_function(1)
    // Store gen_entity separately (like C++ proc_entities array)
}
```

---

### 8.2 Valid Candidate Comparison
**Location**: `/mnt/d/dev/checker/check_proc_group.odin:85-92`

**Odin Code**:
```odin
valid_index_and_score_cmp :: proc(a, b: Valid_Index_And_Score) -> slice.Ordering {
    if a.score > b.score {
        return .Less  // a is better (higher score)
    } else if a.score < b.score {
        return .Greater  // b is better
    }
    return .Equal
}
```

**C++ Code**:
```cpp
gb_internal int valid_index_and_score_cmp(void const *a, void const *b) {
    i64 si = (cast(ValidIndexAndScore const *)a)->score;
    i64 sj = (cast(ValidIndexAndScore const *)b)->score;
    return sj < si ? -1 : sj > si;
}
```

**Analysis**:
Let's verify with examples:
- If `a.score = 100`, `b.score = 50`:
  - Odin: `a.score > b.score` → return `.Less` (a sorts before b) ✓
  - C++: `sj < si` → `50 < 100` → return `-1` (a sorts before b) ✓

Both are **equivalent** - higher scores sort first. ✅ **CORRECT**

---

### 8.3 Error Reporting Mechanism
**Issue**: The Odin port uses `error_node` and `fmt.printf`, while C++ uses `ERROR_BLOCK()` and `error_line()`.

**Impact**:
- Error formatting may be inconsistent
- `fmt.printf` output may not be captured by the error reporting system
- Line 805: `fmt.printf("  Candidate: %s\n", candidate.token.text)` should use `error_line`

**Fix**: Replace all `fmt.printf` with proper error functions:
```odin
// Instead of:
fmt.printf("  Candidate: %s\n", candidate.token.text)

// Use:
error_line("  Candidate: %s\n", candidate.token.text)
```

---

## Section 9: Required Fixes (Prioritized)

### Priority 1: Critical Correctness Issues

#### Fix 1.1: Polymorphic Scoring Inversion
**File**: `/mnt/d/dev/checker/check_proc_group.odin:738-740`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:7196-7202`

**Current Code**:
```odin
// Prefer non-polymorphic over polymorphic
if is_type_polymorphic(proc_type) {
    candidate.score += assign_score_function(1)  // WRONG
}
```

**Required Fix**:
```odin
// Track polymorphic specializations separately
if candidate_data.gen_entity != nil {
    // Prefer the specialized (non-polymorphic) version
    candidate.score += assign_score_function(1)
    // TODO: Store in separate proc_entities array like C++
}
```

---

#### Fix 1.2: Check Entity Declaration
**File**: `/mnt/d/dev/checker/check_proc_group.odin:57`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:3235`

**Current Code**:
```odin
// TODO: check_entity_decl(ctx, operand.proc_group, nil, nil)
```

**Required Fix**:
```odin
check_entity_decl(ctx, operand.proc_group, nil, nil)
```

**Dependency**: Ensure `check_entity_decl` is implemented in the checker.

---

### Priority 2: Important Missing Features

#### Fix 2.1: Type Inference Optimization
**File**: `/mnt/d/dev/checker/check_proc_group.odin` (insert before line 666)
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:7051-7120`

**Implementation**: See detailed code in Section 6 "Required Fix".

**Impact**: Improves type inference quality for procedure group calls.

---

#### Fix 2.2: Target Feature Scoring
**File**: `/mnt/d/dev/checker/check_proc_group.odin` (insert after line 743)
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:7204`, `7212-7221`

**Implementation**: See detailed code in Section 4 "Fix 2".

**Dependency**: Requires implementing `matched_target_features` function (likely in `types.odin`).

---

#### Fix 2.3: Detailed Error Messages
**File**: `/mnt/d/dev/checker/check_proc_group.odin:746-809`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:7240-7426`

**Implementation**: See detailed code in Section 5 "Required Fix".

**Impact**: Significantly improves developer experience when debugging overload resolution failures.

---

### Priority 3: Quality Improvements

#### Fix 3.1: Multi-Value Return Support
**File**: `/mnt/d/dev/checker/check_proc_group.odin:553-558`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:6948-6967`, `7122`

**Current Code**:
```odin
// Count arguments
min_arg_count := len(call.args)
max_arg_count := len(call.args)

// Check for multi-value returns in arguments (would make max unbounded)
// For MVP, we assume simple single-value arguments
```

**Required Fix**:
```odin
min_arg_count := len(call.args)
max_arg_count := len(call.args)

// Check for multi-value call expressions
for arg in call.args {
    arg = strip_or_return_expr(arg)
    if arg != nil && arg.kind == .Call {
        max_arg_count = max(int)  // Unbounded
        break
    }
}

// Use check_unpack_arguments instead of check_expr_base
// TODO: Implement check_unpack_arguments
```

**Dependency**: Requires implementing `check_unpack_arguments`.

---

#### Fix 3.2: Error Reporting Consistency
**File**: `/mnt/d/dev/checker/check_proc_group.odin:805`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:7455`

**Current Code**:
```odin
fmt.printf("  Candidate: %s\n", candidate.token.text)
```

**Required Fix**:
```odin
error_line("  Candidate: %s\n", candidate.token.text)
```

---

#### Fix 3.3: Proc Group Entities Cloning
**File**: `/mnt/d/dev/checker/check_proc_group.odin:46-63`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:3242-3248`

**Add New Function**:
```odin
proc_group_entities_cloned :: proc(ctx: ^Checker_Context, operand: Operand) -> []^Entity {
    entities := proc_group_entities(ctx, operand)
    if len(entities) == 0 {
        return nil
    }

    // Clone the array to avoid aliasing issues during filtering
    cloned := make([]^Entity, len(entities), context.allocator)
    copy(cloned, entities)
    return cloned
}
```

**Usage**: Use in line 549 and 591 where C++ uses `proc_group_entities_cloned`.

---

### Priority 4: Advanced Features (Future Work)

#### Fix 4.1: Where Clause Evaluation
**Dependency**: Verify implementation exists in `check_poly_proc.odin`. If not, port from C++ lines 6717-6797.

#### Fix 4.2: SOA Struct Filtering
**Reference**: `/mnt/c/odin/src/check_expr.cpp:7287-7343`
**Description**: Special filtering of candidates in error messages for SOA struct mismatches.
**Status**: Low priority - error message enhancement only.

---

## Summary

### Completion Estimate: ~75%

**Core Algorithm**: ✅ Implemented correctly
- Scoring function ✅
- Type distance calculation ✅ (via check_expr.odin)
- Candidate filtering ✅
- Best match selection ✅
- Ambiguity detection ✅

**Critical Issues**: 2
1. Polymorphic scoring inverted (Priority 1.1)
2. Missing check_entity_decl call (Priority 1.2)

**Important Missing Features**: 3
1. Type inference optimization for procedure groups (Priority 2.1)
2. Target feature scoring (Priority 2.2)
3. Detailed error messages (Priority 2.3)

**Quality Issues**: 3
1. Multi-value return support (Priority 3.1)
2. Error reporting inconsistency (Priority 3.2)
3. Missing proc_group_entities_cloned (Priority 3.3)

### Recommendation

The procedure group implementation has the core algorithm correct but requires:
1. **Immediate**: Fix polymorphic scoring inversion and add check_entity_decl call
2. **Short-term**: Add type inference optimization and detailed error messages
3. **Medium-term**: Implement target feature scoring and multi-value return support
4. **Long-term**: Verify where clause evaluation and add SOA filtering

The implementation is functional for basic overload resolution but will have degraded type inference and error message quality compared to the C++ version.
