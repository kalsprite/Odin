# CHECK_DECL_HELPERS VERIFICATION REPORT

**Verification Date**: 2025-10-03
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp` (2198 lines, 27 helper functions)
**Odin Implementation**: `/mnt/d/dev/checker/check_decl_helpers.odin` (819 lines, 33 functions)
**Verifier**: Code Port Verification Specialist

---

## SECTION 1: IMPLEMENTATION STATUS

### Overall Completeness: ~60% FUNCTIONAL, 40% STUBBED

**What's Done (Fully Implemented - 20 functions):**
- ✅ `entity_of_node` - Entity extraction from AST nodes (lines 27-84)
- ✅ `decl_info_of_entity` - Declaration info retrieval (lines 88-96)
- ✅ `is_type_distinct` - Distinct type checking (lines 227-254)
- ✅ `remove_type_alias_clutter` - Type alias unwrapping (lines 258-274)
- ✅ `alloc_type_named` - Named type allocation (lines 278-288)
- ✅ `make_attribute_context` - Attribute context creation (lines 292-298)
- ✅ `exact_value_typeid` - Typeid exact value (lines 165-172)
- ✅ `exact_value_procedure` - Procedure exact value (lines 176-181)
- ✅ `exact_value_compound` - Compound literal exact value (lines 185-190)
- ✅ `exact_value_pointer` - Pointer exact value (lines 194-199)
- ✅ `exact_value_quaternion` - Quaternion exact value (lines 203-214)
- ✅ `exact_value_string16` - UTF-16 string exact value (lines 218-223)
- ✅ `make_decl_info` - Declaration info creation (lines 516-559)
- ✅ `destroy_decl_info` - Declaration info cleanup (lines 562-572)
- ✅ `decl_info_set_parent` - Parent relationship setter (lines 588-596)
- ✅ `decl_info_is_nested` - Nested declaration check (lines 600-608)
- ✅ `decl_info_get_entity` - Entity retrieval from decl (lines 612-620)
- ✅ `check_init_variable_internal` - Variable initialization (lines 628-671)
- ✅ `check_variable_type` - Variable type validation (lines 675-698)
- ✅ `check_variable_foreign` - Foreign variable validation (lines 702-725)

**What's Partially Implemented (7 functions):**
- ⚠️ `check_unpack_arguments` - Basic single-value case only (lines 100-149)
  - C++ Reference: `/mnt/c/odin/src/check_expr.cpp:6046-6156` (110 lines)
  - Missing: Multi-return unpacking, tuple unpacking, optional-ok patterns
  - Impact: Assignment expressions with multiple returns won't work correctly

- ⚠️ `check_decl_attributes` - Only deferred_* attributes implemented (lines 302-388)
  - C++ Reference: `/mnt/c/odin/src/checker.cpp:4227-4317` (90 lines)
  - Implemented: 7 deferred_* attributes out of ~75 total attributes
  - Missing: export, linkage, link_name, static, thread_local, deprecated, etc.
  - Impact: Most declaration attributes will be silently ignored

- ⚠️ `check_type_decl` - Basic type alias/distinct handling (lines 440-505)
  - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:449-517` (68 lines)
  - Missing: Distinct enum cloning, type path tracking, full validation
  - Impact: Some edge cases with distinct types may fail

**What's Stubbed (6 functions):**
- ❌ `add_type_info_type` - RTTI type tracking (line 157-161)
- ❌ `handle_link_name` - Link name processing (lines 392-400)
- ❌ `is_arch_wasm` - WASM architecture check (lines 404-408)
- ❌ `init_entity_foreign_library` - Foreign library init (lines 412-416)
- ❌ `token_pos_to_string` - Position formatting (lines 420-424)
- ❌ `signature_parameter_similar_enough` - ABI compatibility (lines 428-432)

**What's Implemented for Other Phases (6 functions):**
- ✅ `check_const_value` - Constant validation (lines 733-766)
- ✅ `open_scope_with_flags` - Scope creation (lines 774-791)
- ✅ `close_scope` - Scope popping (lines 795-805)
- ✅ `scope_set_flags` - Scope flag setting (lines 809-819)

---

## SECTION 2: HELPER FUNCTION COVERAGE

### C++ Helper Functions in check_decl.cpp (27 total)

| Line | C++ Function | Odin Status | Notes |
|------|-------------|-------------|-------|
| 4 | `check_init_variable` | ✅ IMPLEMENTED | As `check_init_variable_internal` |
| 126 | `check_init_variables` | ❌ MISSING | Multi-variable initialization |
| 155 | `override_entity_in_scope` | ❌ MISSING | Entity override for aliasing |
| 197 | `check_override_as_type_due_to_aliasing` | ❌ MISSING | Type aliasing resolution |
| 242 | `check_proc_decl` (forward) | N/A | Phase 20 function |
| 244 | `check_try_override_const_decl` | ❌ MISSING | Const override checking |
| 308 | `check_init_constant` | ❌ MISSING | Constant initialization |
| 354 | `is_type_distinct` | ✅ IMPLEMENTED | Exact match |
| 388 | `remove_type_alias_clutter` | ✅ IMPLEMENTED | Exact match |
| 403 | `clone_enum_type` | ❌ MISSING | Distinct enum cloning |
| 449 | `check_type_decl` | ⚠️ PARTIAL | Basic impl, missing enum cloning |
| 622 | `check_const_decl` | ❌ MISSING | Full constant declaration |
| 772 | `sig_compare` (overload 1) | ❌ MISSING | Signature comparison utility |
| 777 | `sig_compare` (overload 2) | ❌ MISSING | Signature comparison utility |
| 786 | `signature_parameter_similar_enough` | ❌ STUBBED | Returns `are_types_identical` |
| 902 | `are_signatures_similar_enough` | ❌ MISSING | Full signature comparison |
| 972 | `init_entity_foreign_library` | ❌ STUBBED | Returns nil |
| 1016 | `handle_link_name` | ❌ STUBBED | Returns link_name unchanged |
| 1053 | `check_objc_methods` | ❌ MISSING | Objective-C method validation |
| 1180 | `check_foreign_procedure` | ❌ MISSING | Foreign proc validation |
| 1217 | `check_proc_decl` | N/A | Phase 20 main function |
| 1612 | `check_global_variable_decl` | N/A | Phase 20 main function |
| 1760 | `check_proc_group_decl` | N/A | Phase 20 main function |
| 1897 | `check_entity_decl` | N/A | Phase 20 main function |
| 1972 | `add_deps_from_child_to_parent` | ❌ MISSING | Dependency propagation |
| 2009 | `check_proc_body` | N/A | Phase 21 function |

### Additional Functions Required from checker.cpp

| Line | C++ Function | Odin Status | Purpose |
|------|-------------|-------------|---------|
| 3417 | `foreign_block_decl_attribute` | ❌ MISSING | Foreign block attribute handler |
| 3490 | `proc_group_attribute` | ❌ MISSING | Proc group attribute handler |
| 3544 | `proc_decl_attribute` | ❌ MISSING | Proc attribute handler (400+ lines) |
| 3967 | `var_decl_attribute` | ❌ MISSING | Variable attribute handler |
| 4111 | `const_decl_attribute` | ❌ MISSING | Constant attribute handler |
| 4135 | `type_decl_attribute` | ❌ MISSING | Type attribute handler |
| 5237 | `import_decl_attribute` | ❌ MISSING | Import attribute handler |
| 5338 | `foreign_import_decl_attribute` | ❌ MISSING | Foreign import handler |

---

## SECTION 3: ATTRIBUTE PROCESSING ANALYSIS

### Current Implementation (Odin)

**Attributes Implemented**: 7 of ~75 (9%)

The Odin implementation only handles deferred procedure attributes:
- `deferred_in` (line 341)
- `deferred_out` (line 341)
- `deferred_in_out` (line 341)
- `deferred_in_by_ptr` (line 341)
- `deferred_out_by_ptr` (line 341)
- `deferred_in_out_by_ptr` (line 341)
- `deferred_none` (line 341)

**Processing Location**: `/mnt/d/dev/checker/check_decl_helpers.odin:302-388`

### C++ Reference Implementation

**Total Attributes**: ~75 across 8 handler functions

#### foreign_block_decl_attribute (/mnt/c/odin/src/checker.cpp:3417-3488)
- `default_calling_convention` - Sets foreign block default CC
- `link_prefix` - Foreign symbol prefix
- `link_suffix` - Foreign symbol suffix
- `private` - Visibility control (file/package)
- `require_results` - Mandate return value usage

#### proc_decl_attribute (/mnt/c/odin/src/checker.cpp:3544-3965)
**Major attributes (~40+ total)**:
- `export` - Export symbol visibility
- `linkage` - Linkage type (internal/strong/weak/link_once)
- `link_name` - Custom link name
- `link_prefix` - Symbol prefix
- `link_suffix` - Symbol suffix
- `link_section` - ELF section name
- `require` - Require declaration
- `require_results` - Mandate return value usage
- `test` - Mark as test function
- `init` - Package initializer
- `fini` - Package finalizer
- `cold` - Mark as cold path
- `optimization_mode` - Per-proc optimization level
- `disabled` - Disable procedure
- `deferred_*` (7 variants) - **IMPLEMENTED IN ODIN**
- `require_target_feature` - CPU feature requirements
- `enable_target_feature` - Enable CPU features
- `entry_point_only` - Entry point restriction
- `no_instrumentation` - Disable instrumentation
- `instrumentation_enter` - Enter hook
- `instrumentation_exit` - Exit hook
- `no_sanitize_address` - Disable ASAN
- `no_sanitize_memory` - Disable MSAN
- Objective-C attributes (objc_name, objc_type, objc_class, etc.)

#### var_decl_attribute (/mnt/c/odin/src/checker.cpp:3967-4109)
- `static` - Static storage
- `thread_local` - Thread-local storage
- `export` - Export variable
- `linkage` - Variable linkage
- `link_name` - Custom link name
- `link_section` - ELF section
- `rodata` - Read-only data section

#### const_decl_attribute (/mnt/c/odin/src/checker.cpp:4111-4133)
- Tag attributes only

#### type_decl_attribute (/mnt/c/odin/src/checker.cpp:4135-4225)
- Objective-C type attributes
- `packed` - Packed struct layout
- `align` - Explicit alignment
- `raddbg_type_view` - Debugger type visualization

### Correctness Assessment

**CRITICAL DEFICIENCY**: The Odin implementation is missing 90% of attribute processing.

**Correctness of Implemented Attributes** (deferred_*):
- ✅ **Structurally correct**: Matches C++ logic flow
- ✅ **Duplicate detection**: Checks for previous deferred_* usage (line 360)
- ✅ **Entity validation**: Verifies procedure entity (lines 354-357)
- ✅ **Kind assignment**: Correctly maps attribute names to kinds (lines 366-381)
- ✅ **Context storage**: Stores in `ac.deferred_procedure` correctly

**Semantic Match**: The 7 implemented deferred attributes match C++ behavior at:
- `/mnt/c/odin/src/checker.cpp:3641-3723` (deferred_in through deferred_in_out_by_ptr)

**Missing Semantic Behavior**:
1. **No attribute name validation**: Unknown attributes should trigger errors or warnings
2. **No duplicate attribute checking**: C++ uses StringSet to detect duplicates (line 4283)
3. **No calling convention parsing**: `string_to_calling_convention` not implemented
4. **No link name validation**: `is_foreign_name_valid` check missing
5. **No optimization mode parsing**: ProcedureOptimizationMode handling absent
6. **No exact value parsing**: `check_decl_attribute_value` stub needed

---

## SECTION 4: FOREIGN CONTEXT HANDLING

### C++ Foreign Context Structure

**Location**: `/mnt/c/odin/src/checker.hpp` (inferred from usage)

```cpp
struct ForeignContext {
    ProcCallingConvention default_cc;
    String link_prefix;
    String link_suffix;
    bool require_results;
    EntityVisiblityKind visibility_kind;
};
```

**Usage Pattern**: Checker context maintains foreign_context state that gets modified by `foreign_block_decl_attribute` and consumed by foreign procedure/variable declarations.

### Odin Implementation Status

**Structure**: ❌ MISSING - No Foreign_Context struct defined in `/mnt/d/dev/checker/checker.odin`

**Functions**:
- ❌ `init_entity_foreign_library` - STUBBED (line 412-416)
  - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:972-1014` (42 lines)
  - Should: Validate foreign library ident, lookup library entity, set flags
  - Currently: Returns nil immediately

- ❌ `handle_link_name` - STUBBED (line 392-400)
  - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:1016-1050` (34 lines)
  - Should: Concatenate link_prefix + name + link_suffix, validate conflicts
  - Currently: Returns link_name unchanged

**Completeness**: 0% - Critical infrastructure missing

### Required Implementation

1. **Add Foreign_Context struct** to `checker.odin`:
```odin
Foreign_Context :: struct {
    default_cc:      Proc_Calling_Convention,
    link_prefix:     string,
    link_suffix:     string,
    require_results: bool,
    visibility_kind: Entity_Visibility_Kind,
}
```

2. **Add to Checker_Context**:
```odin
Checker_Context :: struct {
    // ... existing fields ...
    foreign_context: Foreign_Context,
}
```

3. **Implement `init_entity_foreign_library`**:
   - Validate `e.Procedure.foreign_library_ident` or `e.Variable.foreign_library_ident`
   - Perform scope lookup for library name entity
   - Verify entity is `Entity_LibraryName` kind
   - Set `foreign_library` pointer on entity
   - Add entity use tracking

4. **Implement `handle_link_name`**:
   - Check for conflicting link_name + link_prefix usage
   - Check for conflicting link_name + link_suffix usage
   - Concatenate prefix + token.text + suffix
   - Allocate permanent string storage

5. **Implement `foreign_block_decl_attribute`** handler:
   - Parse `default_calling_convention` attribute
   - Parse `link_prefix` and validate with `is_foreign_name_valid`
   - Parse `link_suffix` and validate
   - Handle `private` visibility (file/package)
   - Handle `require_results` flag

---

## SECTION 5: MISSING HELPERS

### Critical Missing Functions (Block Phase 19-20 Progress)

1. **`check_init_variables`** - REQUIRED FOR PHASE 19
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:126-152` (26 lines)
   - Purpose: Multi-variable initialization with unpacking
   - Used by: Variable declarations with multiple LHS (a, b := foo())
   - Impact: Multiple assignment statements will fail

2. **`check_init_constant`** - REQUIRED FOR PHASE 19
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:308-351` (43 lines)
   - Purpose: Constant initialization and validation
   - Used by: All constant declarations
   - Impact: Constant declarations won't validate properly

3. **`clone_enum_type`** - REQUIRED FOR DISTINCT ENUMS
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:403-447` (44 lines)
   - Purpose: Clone enum for distinct type declarations (Y :: distinct X where X is enum)
   - Used by: Distinct enum declarations
   - Impact: Distinct enums will have wrong entity types

4. **`check_const_decl`** - REQUIRED FOR PHASE 19
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:622-768` (146 lines)
   - Purpose: Full constant declaration checking
   - Used by: Constant declarations
   - Impact: Constants won't be properly checked

5. **`are_signatures_similar_enough`** - REQUIRED FOR FOREIGN
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:902-970` (68 lines)
   - Purpose: Check if two procedure signatures are ABI-compatible
   - Used by: Foreign procedure validation
   - Impact: Foreign procedure redeclarations won't validate

6. **`override_entity_in_scope`** - REQUIRED FOR OVERRIDES
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:155-195` (40 lines)
   - Purpose: Override entity in scope for const/type overrides
   - Used by: Type aliasing, const overrides
   - Impact: Override behavior won't work

### Helper Functions for Future Phases

7. **`add_deps_from_child_to_parent`** - PHASE 21
   - C++ Reference: `/mnt/c/odin/src/check_decl.cpp:1972-2007` (35 lines)
   - Purpose: Propagate dependencies from nested to parent procedures
   - Impact: Dependency tracking for nested procedures

8. **Attribute Handler Functions** - PHASE 20-21
   - `foreign_block_decl_attribute` - `/mnt/c/odin/src/checker.cpp:3417-3488`
   - `proc_decl_attribute` - `/mnt/c/odin/src/checker.cpp:3544-3965` (421 lines!)
   - `var_decl_attribute` - `/mnt/c/odin/src/checker.cpp:3967-4109`
   - `const_decl_attribute` - `/mnt/c/odin/src/checker.cpp:4111-4133`
   - `type_decl_attribute` - `/mnt/c/odin/src/checker.cpp:4135-4225`

---

## SECTION 6: SEMANTIC DIFFERENCES

### 1. Ternary When Expression Handling (INTENTIONAL LIMITATION)

**Location**: `/mnt/d/dev/checker/check_decl_helpers.odin:71-80`

**C++ Behavior** (`/mnt/c/odin/src/checker.cpp:1653-1660`):
```cpp
case Ast_TernaryWhenExpr:
    we = cast(AstTernaryWhenExpr *)node;
    if (we->cond->tav.mode == Addressing_Constant) {
        if (we->cond->tav.value.kind == ExactValue_Bool) {
            if (we->cond->tav.value.value_bool) {
                return entity_of_node(we->x);
            } else {
                return entity_of_node(we->y);
            }
        }
    }
```

**Odin Behavior**:
```odin
case ^ast.Ternary_When_Expr:
    // Returns nil - optimization disabled
    return nil
```

**Reason**: Type and value (TAV) information is stored in `Checker_Context.type_and_value_map`, but `entity_of_node` only receives `Checker_Info`. Changing the signature would require updating all call sites.

**Impact**:
- Minor optimization loss - won't resolve entity through compile-time when-expressions
- Functionally safe - just less optimal
- Does not break correctness

**Assessment**: ACCEPTABLE - This is a documented limitation, not a bug.

### 2. Calling Convention String Conversion (MISSING)

**C++ Implementation** (`/mnt/c/odin/src/parser.cpp:3981-4005`):
```cpp
ProcCallingConvention string_to_calling_convention(String const &s) {
    if (s == "odin")        return ProcCC_Odin;
    if (s == "contextless") return ProcCC_Contextless;
    if (s == "cdecl" || s == "c") return ProcCC_CDecl;
    // ... 12 total conventions
}
```

**Odin Status**: ❌ NOT IMPLEMENTED

**Location Needed**: Should be in `/mnt/d/dev/checker/check_decl_helpers.odin` or type utilities

**Impact**: Cannot parse calling convention attributes in foreign blocks or procedures

### 3. Signature Parameter Similarity (OVERLY STRICT)

**C++ Implementation** (`/mnt/c/odin/src/check_decl.cpp:786-900`):
The C++ version checks ABI-level compatibility:
- Pointer vs multi-pointer (compatible)
- Integer of same size (compatible)
- Integer vs boolean of same size (compatible)
- cstring vs u8 pointer (compatible)
- uintptr vs rawptr (compatible)
- Slice element types recursively (compatible if elements similar)
- 15+ different compatibility rules

**Odin Stub** (line 428-432):
```odin
signature_parameter_similar_enough :: proc(x, y: ^Type) -> bool {
    return are_types_identical(x, y)
}
```

**Impact**:
- Foreign procedure redeclarations require EXACT type match
- C interop becomes more restrictive than C++ checker
- Valid C declarations may be rejected

**Assessment**: CRITICAL DEFICIENCY - Will break foreign procedure validation

### 4. Entity Override Mechanism (MISSING)

**C++ Implementation** (`/mnt/c/odin/src/check_decl.cpp:155-195`):
```cpp
void override_entity_in_scope(Entity *original, Entity *new_entity) {
    // Find scope containing original
    // Update scope->elements map
    // Mark original with EntityFlag_Overridden
    // Copy type and variant data
    // Update identifier->entity link
}
```

**Odin Status**: ❌ NOT IMPLEMENTED

**Impact**:
- Type aliasing edge cases won't work (@TypeAliasingProblem)
- Const overrides won't work
- Some valid redeclarations will fail

**Assessment**: CRITICAL - Required for correct override semantics

---

## SECTION 7: REQUIRED FIXES

### PRIORITY 1: CRITICAL BLOCKERS (Must fix for Phase 19-20)

#### 1.1 Implement `check_init_variables`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:126-152`

```odin
check_init_variables :: proc(
    ctx: ^Checker_Context,
    lhs: []^Entity,
    inits: []^ast.Expr,
    context_name: string,
) {
    if len(lhs) == 0 && len(inits) == 0 {
        return
    }

    // Use temporary allocator for operands array
    operands := make([dynamic]Operand, context.temp_allocator)
    defer delete(operands)

    // Unpack arguments with optional-ok and undef support
    check_unpack_arguments(ctx, lhs, &operands, inits, {.Allow_Ok, .Allow_Undef})

    rhs_count := len(operands)
    max := min(len(lhs), rhs_count)

    for i in 0..<max {
        e := lhs[i]
        o := &operands[i]
        check_init_variable(ctx, e, o, context_name)

        // Store init expression in decl info
        if d := decl_info_of_entity(e); d != nil {
            d.init_expr = o.expr
        }
    }

    if rhs_count > 0 && len(lhs) != rhs_count {
        error(lhs[0].token, "Assignment count mismatch '%d' = '%d'", len(lhs), rhs_count)
    }
}
```

#### 1.2 Implement `check_init_constant`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:308-351`

```odin
check_init_constant :: proc(ctx: ^Checker_Context, e: ^Entity, operand: ^Operand) {
    if operand.mode == .Invalid {
        return
    }

    // Constants must be untyped or have explicit type
    if e.type != nil && e.type != t_invalid {
        check_assignment(ctx, operand, e.type, "constant declaration")
    }

    // Must be constant mode
    if operand.mode != .Constant {
        if !is_type_untyped(operand.type) {
            gbString expr_str = expr_to_string(operand.expr)
            error(operand.expr, "Constant declaration requires constant value, got '%s'", expr_str)
            delete(expr_str)
            return
        }
    }

    // Set type if not specified
    if e.type == nil || e.type == t_invalid {
        t := operand.type
        if is_type_untyped(t) {
            t = default_type(t)
        }
        e.type = t
    }

    // Store constant value
    if const_ent, ok := &e.variant.(Entity_Constant); ok {
        const_ent.value = operand.value
    }
}
```

#### 1.3 Implement `signature_parameter_similar_enough`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:786-900`

This is a 115-line function with complex ABI compatibility rules. See C++ reference for full implementation. Key checks:
- Bit set to integer conversion
- Pointer type compatibility (pointer/multi-pointer/proc)
- Integer size matching
- Integer/boolean size matching
- cstring/u8 pointer compatibility
- uintptr/rawptr compatibility
- Slice element compatibility (recursive)
- Dynamic array compatibility
- Array element compatibility

#### 1.4 Implement `override_entity_in_scope`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:155-195`

```odin
override_entity_in_scope :: proc(original_entity: ^Entity, new_entity: ^Entity) {
    // Find scope containing original
    original_name := original_entity.token.text
    found_scope: ^Scope = nil
    found_entity: ^Entity = nil
    scope_lookup_parent(original_entity.scope, original_name, &found_scope, &found_entity)

    if found_scope == nil {
        return
    }

    // Update scope elements map
    // TODO: Add mutex locking for thread safety
    found_scope.elements[original_name] = new_entity

    // Mark original as overridden
    original_entity.flags += {.Overridden}
    original_entity.type = new_entity.type
    original_entity.kind = new_entity.kind
    original_entity.decl_info = new_entity.decl_info
    original_entity.aliased_of = new_entity

    // Update identifier link
    if ident := original_entity.identifier; ident != nil {
        if ident_node, ok := ident.derived.(^ast.Ident); ok {
            ident_node.entity = new_entity
        }
    }

    // Copy variant data (memcpy equivalent)
    // This ensures all entity-specific fields are copied
    original_entity.variant = new_entity.variant
}
```

#### 1.5 Add Foreign Context Support
**File**: `/mnt/d/dev/checker/checker.odin`

Add to structs:
```odin
Foreign_Context :: struct {
    default_cc:      Proc_Calling_Convention,
    link_prefix:     string,
    link_suffix:     string,
    require_results: bool,
    visibility_kind: Entity_Visibility_Kind,
}

Checker_Context :: struct {
    // ... existing fields ...
    foreign_context: Foreign_Context,
}
```

**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`

Implement helpers:
```odin
init_entity_foreign_library :: proc(ctx: ^Checker_Context, e: ^Entity) -> ^Entity {
    ident: ^ast.Node = nil
    foreign_library: ^^Entity = nil

    switch &v in e.variant {
    case Entity_Procedure:
        ident = v.foreign_library_ident
        foreign_library = &v.foreign_library
    case Entity_Variable:
        ident = v.foreign_library_ident
        foreign_library = &v.foreign_library
    case:
        return nil
    }

    if ident == nil {
        error(e.token, "foreign entities must declare which library they are from")
        return nil
    }

    if ident_node, ok := ident.derived.(^ast.Ident); !ok {
        error(ident, "foreign library names must be an identifier")
        return nil
    } else {
        name := ident_node.name
        found := scope_lookup(ctx.scope, name)

        if found == nil {
            if is_blank_ident(name) {
                // Link against nothing
            } else {
                error(ident, "Undeclared name: %s", name)
            }
        } else if found.kind != .Library_Name {
            error(ident, "'%s' cannot be used as a library name", name)
        } else {
            foreign_library^ = found
            found.flags += {.Used}
            add_entity_use(ctx, ident, found)
            return found
        }
    }

    return nil
}

handle_link_name :: proc(
    ctx: ^Checker_Context,
    token: tokenizer.Token,
    link_name, link_prefix, link_suffix: string,
) -> string {
    original_link_name := link_name
    result := link_name

    if len(link_prefix) > 0 {
        if len(original_link_name) > 0 {
            error(token, "'link_name' and 'link_prefix' cannot be used together")
        } else {
            result = fmt.aprintf("%s%s", link_prefix, token.text)
        }
    }

    if len(link_suffix) > 0 {
        if len(original_link_name) > 0 {
            error(token, "'link_name' and 'link_suffix' cannot be used together")
        } else {
            new_name := token.text
            if result != original_link_name {
                new_name = result
            }
            result = fmt.aprintf("%s%s", new_name, link_suffix)
        }
    }

    return result
}
```

### PRIORITY 2: ATTRIBUTE PROCESSING (Required for correctness)

#### 2.1 Implement Full `check_decl_attributes`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4227-4317`

Current implementation only handles deferred_* attributes. Need to:
1. Add StringSet for duplicate detection
2. Preserve link_prefix/link_suffix across attributes
3. Call appropriate handler based on declaration type
4. Handle runtime package special case

#### 2.2 Implement Attribute Handlers
**Files**: Create `/mnt/d/dev/checker/check_decl_attributes.odin`

Implement handlers:
- `foreign_block_decl_attribute` (72 lines) - Priority HIGH
- `proc_decl_attribute` (421 lines) - Priority HIGH
- `var_decl_attribute` (142 lines) - Priority MEDIUM
- `const_decl_attribute` (22 lines) - Priority LOW
- `type_decl_attribute` (90 lines) - Priority LOW
- `import_decl_attribute` - Priority MEDIUM
- `foreign_import_decl_attribute` - Priority HIGH

Each handler needs access to:
- `check_decl_attribute_value` - Parse attribute value to ExactValue
- `string_to_calling_convention` - Parse calling convention strings
- `is_foreign_name_valid` - Validate foreign symbol names

### PRIORITY 3: MISSING HELPER FUNCTIONS (Required for Phase 20-21)

#### 3.1 Implement `clone_enum_type`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:403-447`

Required for: `Y :: distinct X` where X is an enum

#### 3.2 Implement `check_const_decl`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:622-768` (146 lines)

Full constant declaration checking including override detection.

#### 3.3 Implement `are_signatures_similar_enough`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`
**C++ Reference**: `/mnt/c/odin/src/check_decl.cpp:902-970`

Wrapper around `signature_parameter_similar_enough` for full signature comparison.

### PRIORITY 4: UTILITY FUNCTIONS

#### 4.1 Implement `string_to_calling_convention`
**File**: `/mnt/d/dev/checker/type_utils.odin` (or check_decl_helpers.odin)
**C++ Reference**: `/mnt/c/odin/src/parser.cpp:3981-4005`

```odin
string_to_calling_convention :: proc(s: string) -> Proc_Calling_Convention {
    switch s {
    case "odin":        return .Odin
    case "contextless": return .Contextless
    case "cdecl", "c":  return .CDecl
    case "stdcall", "std": return .StdCall
    case "fastcall", "fast": return .FastCall
    case "none":        return .None
    case "naked":       return .Naked
    case "win64":       return .Win64
    case "sysv":        return .SysV
    case "system":
        // TODO: Check build_context.metrics.os
        when ODIN_OS == .Windows {
            return .StdCall
        } else {
            return .CDecl
        }
    }
    return .Invalid
}
```

#### 4.2 Complete `check_unpack_arguments`
**File**: `/mnt/d/dev/checker/check_decl_helpers.odin:100-149`
**C++ Reference**: `/mnt/c/odin/src/check_expr.cpp:6046-6156`

Current stub only handles single values. Need:
- Multi-return value unpacking
- Tuple unpacking
- Optional-ok pattern detection and handling
- Proper count validation

#### 4.3 Implement Supporting Utilities
- `is_foreign_name_valid` - Validate foreign symbol names
- `check_decl_attribute_value` - Parse attribute values to ExactValue
- `is_arch_wasm` - Check for WASM target
- `token_pos_to_string` - Format token position with file path

---

## SUMMARY

### Overall Assessment: INCOMPLETE - 60% Functional

The check_decl_helpers implementation provides basic infrastructure but is missing critical functionality for Phase 19-20 completion:

**Strengths**:
- Core helper functions (entity_of_node, type checking) are correct
- Exact value constructors match C++ semantics
- Scope management helpers implemented
- Deferred procedure attributes fully functional

**Critical Gaps**:
1. **90% of attribute processing missing** - Only 7 of ~75 attributes implemented
2. **Foreign context infrastructure absent** - No Foreign_Context struct or handlers
3. **Key initialization helpers missing** - check_init_variables, check_init_constant
4. **ABI compatibility broken** - signature_parameter_similar_enough too strict
5. **Override mechanism missing** - Type aliasing edge cases won't work

**Recommended Action Plan**:

1. **Immediate (Block Phase 19)**:
   - Implement `check_init_variables` (26 lines)
   - Implement `check_init_constant` (43 lines)
   - Add Foreign_Context infrastructure
   - Implement `handle_link_name` (34 lines)
   - Implement `init_entity_foreign_library` (42 lines)

2. **Short-term (Block Phase 20)**:
   - Implement `signature_parameter_similar_enough` (115 lines)
   - Implement `override_entity_in_scope` (40 lines)
   - Implement `foreign_block_decl_attribute` (72 lines)
   - Implement `clone_enum_type` (44 lines)
   - Add `string_to_calling_convention` (25 lines)

3. **Medium-term (Complete Phase 20)**:
   - Implement `proc_decl_attribute` (421 lines) - Large but critical
   - Implement `var_decl_attribute` (142 lines)
   - Complete `check_unpack_arguments` (110 lines)
   - Implement `check_const_decl` (146 lines)

4. **Long-term (Phase 21+)**:
   - Remaining attribute handlers (const, type, import)
   - Objective-C attribute support
   - Optimization attributes
   - Instrumentation attributes

**Estimated Work**: ~1500 lines of ported code across 20+ functions

**Risk Level**: HIGH - Missing critical path functions will block declaration checking

---

**Verification Complete**
Generated: 2025-10-03
By: Claude Code Port Verification Specialist
