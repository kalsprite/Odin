# Check_Decl Implementation Verification Report

**Date:** 2025-10-03
**C++ Reference:** `/mnt/c/odin/src/check_decl.cpp` (2,198 lines)
**Odin Implementation:** `/mnt/d/dev/checker/check_decl.odin` (1,656 lines) + `/mnt/d/dev/checker/check_decl_helpers.odin` (820 lines)
**Total Odin Lines:** 2,476 lines (113% of C++ size)

---

## Executive Summary

**Status:** INCOMPLETE - Core structure present but critical features missing

The Odin port implements **approximately 40-45%** of the C++ check_decl functionality. The basic infrastructure for variable and constant declaration checking is complete, but **major components are missing or stubbed**, including:

- Procedure body checking (check_proc_body - 189 lines of critical logic)
- Type construction (struct/union/enum building)
- Procedure group validation
- Foreign declaration validation (partially implemented)
- Polymorphic type parameter handling
- Complete attribute processing

The implementation quality of what exists is **high** with proper error handling and good C++ alignment, but the missing features represent **critical semantic validation gaps** that would prevent the checker from functioning correctly on real Odin code.

---

## Section 1: Coverage Analysis

### Function Coverage Breakdown

| Category | C++ Functions | Odin Implemented | Coverage | Status |
|----------|--------------|------------------|----------|---------|
| Variable Init | 2 | 2 | 100% | ✅ COMPLETE |
| Constant Checking | 2 | 2 | 100% | ✅ COMPLETE |
| Type Declaration | 3 | 1 | 33% | ⚠️ PARTIAL |
| Procedure Declaration | 4 | 1 | 25% | ❌ CRITICAL GAP |
| Procedure Body | 1 | 0 | 0% | ❌ MISSING |
| Proc Group | 1 | 0 | 0% | ❌ MISSING |
| Entity Management | 2 | 2 | 100% | ✅ COMPLETE |
| Foreign Import | 3 | 2 | 67% | ⚠️ PARTIAL |
| Attribute Processing | 2 | 1 | 50% | ⚠️ PARTIAL |
| Utility Functions | 8 | 3 | 38% | ⚠️ PARTIAL |

**Overall Coverage: 42%** (13 of 31 core functions fully implemented)

### Lines of Code Analysis

```
C++ check_decl.cpp Breakdown:
  - Variable/Constant checking:    ~450 lines (20%)  [✅ DONE]
  - Type declaration checking:     ~250 lines (11%)  [⚠️ PARTIAL]
  - Procedure declaration:         ~550 lines (25%)  [❌ MINIMAL]
  - Procedure body checking:       ~189 lines (9%)   [❌ MISSING]
  - Procedure group validation:    ~136 lines (6%)   [❌ MISSING]
  - Foreign/attribute handling:    ~300 lines (14%)  [⚠️ PARTIAL]
  - Entity/dependency management:  ~200 lines (9%)   [✅ DONE]
  - Utility functions:             ~123 lines (6%)   [⚠️ PARTIAL]

Odin check_decl.odin Coverage:
  - Implemented functionality:     ~750 lines (45% of 1,656)
  - Structural stubs:              ~400 lines (24%)
  - Foreign import additions:      ~506 lines (31% - NEW PHASE 25 CODE)
```

**Key Observation:** The Odin implementation has more lines than C++ due to:
1. More verbose syntax (explicit type annotations, proc keywords)
2. Added Phase 25 foreign import infrastructure (500+ new lines not in C++ check_decl.cpp)
3. More defensive error checking
4. Lack of C++ template/macro compression

---

## Section 2: Per-Declaration-Type Status Table

| Declaration Type | C++ Lines | Odin Lines | Completeness | Critical Issues |
|-----------------|-----------|------------|--------------|-----------------|
| **const** | 146 (622-768) | 181 (796-976) | 95% | ✅ Nearly complete; missing attribute validation |
| **var** (global) | 146 (1612-1758) | 193 (249-441) | 90% | ✅ Core logic done; @rodata validation incomplete |
| **var** (local) | N/A | N/A | 0% | ❌ Handled in check_stmt.cpp, not ported |
| **type** | 171 (449-619) | 67 (440-506) | 40% | ⚠️ Basic aliasing works; enum cloning missing |
| **proc** | 383 (1217-1599) | 56 (1078-1133) | 15% | ❌ Only parent tracking; no signature/body checking |
| **proc_group** | 136 (1760-1895) | 3 (1134-1136) | 0% | ❌ Empty stub |
| **foreign import** | 163 (972-1014 + helpers) | 224 (1296-1519) | 70% | ⚠️ Path resolution done; WASM handling missing |

### Detailed Status Notes

#### ✅ **const** Declaration (95% Complete)
- **C++ Reference:** Lines 622-768 (check_const_decl)
- **Odin Implementation:** Lines 796-976 (check_const_decl)
- **Missing:**
  - Attribute validation (lines 764-767) - commented out, needs decl_info
  - Polymorphic record alias handling (lines 671-682) - partially implemented but untested

#### ✅ **var** Global Declaration (90% Complete)
- **C++ Reference:** Lines 1612-1758 (check_global_variable_decl)
- **Odin Implementation:** Lines 249-441 (check_global_variable_decl)
- **Missing:**
  - Complete @rodata struct element validation (lines 1732-1755) - type_of_expr helper needed
  - RTTI type disallowance check (line 1757) - check_rtti_type_disallowed not ported
  - Required global variable queue (line 1634) - structural gap in Checker_Info

#### ⚠️ **type** Declaration (40% Complete)
- **C++ Reference:** Lines 449-619 (check_type_decl)
- **Odin Implementation:** Lines 440-506 (check_decl_helpers.odin)
- **Missing:**
  - Enum type cloning for distinct types (lines 403-447) - clone_enum_type not implemented
  - Objective-C class attribute handling (lines 521-611) - completely absent
  - RADDBG type view tracking (lines 606-611) - not ported
  - Type path cycle detection (lines 468-470) - check_type_path_push/pop missing

#### ❌ **proc** Declaration (15% Complete)
**CRITICAL GAP - HIGH PRIORITY**
- **C++ Reference:** Lines 1217-1599 (383 lines)
- **Odin Implementation:** Lines 1078-1133 (56 lines - only parent tracking)
- **Implemented:**
  - Parent procedure tracking (lines 2031-2037) ✅
  - Deferred procedure attribute parsing (Phase 26 Group 4) ✅
- **Missing (CRITICAL):**
  - Procedure type checking (lines 1234-1275) - check_procedure_type call
  - Attribute processing (lines 1278-1558):
    - @(test), @(init), @(fini) flags (lines 1284-1293)
    - @(cold) optimization hint (lines 1295-1296)
    - Objective-C method validation (lines 1300) - check_objc_methods
    - Target feature requirements (lines 1302-1333)
    - Instrumentation enter/exit (lines 1389-1433)
    - Linkage and export handling (lines 1458-1467)
    - Foreign library linkage (lines 1560-1575)
  - Entry point validation ('main' procedure) (lines 1475-1495)
  - Foreign procedure duplicate checking (lines 1180-1215)
  - Polymorphic procedure validation (lines 1501-1510)
  - Procedure body queueing (line 1524) - check_procedure_later

#### ❌ **proc_group** Declaration (0% Complete)
**CRITICAL GAP - MEDIUM PRIORITY**
- **C++ Reference:** Lines 1760-1895 (136 lines)
- **Odin Implementation:** Lines 1134-1136 (empty stub)
- **Missing (ALL):**
  - Procedure group member collection (lines 1776-1805)
  - Overload safety validation (lines 1809-1887):
    - Identical signature detection
    - Parameter count/type differentiation
    - Return type consistency checking
    - Polymorphic where clause handling
  - Objective-C method group handling (line 1892)

#### ⚠️ **foreign import** Declaration (70% Complete)
- **C++ Reference:** Lines 5490-5545 (check_add_foreign_import_decl), 5382-5488 (check_foreign_import_fullpaths)
- **Odin Implementation:** Lines 1296-1519
- **Implemented:**
  - Library name extraction and validation ✅
  - Attribute processing (@require, @ignore_duplicates) ✅
  - Path expression evaluation ✅
  - Collection path detection ✅
- **Missing:**
  - WASM-specific link name processing (lines 5457-5487)
  - Import dependency graph building (lines 5068-5167) - partial stub

---

## Section 3: Type Construction Analysis

**STATUS: NOT IMPLEMENTED - DEFERRED TO PHASE 28**

The C++ implementation delegates struct/union/enum construction to `check_type.cpp`, not `check_decl.cpp`. Therefore, these are correctly absent from check_decl.odin.

| Type Construction | C++ Location | Expected Odin Location | Status |
|-------------------|--------------|------------------------|--------|
| **struct** type building | check_type.cpp:1200-1800 | check_type.odin (Phase 28) | ⏳ PENDING |
| **union** type building | check_type.cpp:1900-2100 | check_type.odin (Phase 28) | ⏳ PENDING |
| **enum** type building | check_type.cpp:2200-2400 | check_type.odin (Phase 28) | ⏳ PENDING |
| **proc** type building | check_type.cpp:2500-2700 | check_type.odin (Phase 28) | ⏳ PENDING |
| **bit_field** type building | check_type.cpp:2800-2900 | check_type.odin (Phase 28) | ⏳ PENDING |

**Note:** The only type construction in check_decl.cpp is:
- `clone_enum_type` (lines 403-447) - for distinct enum declarations
- This is **MISSING** in check_decl.odin and needs implementation

---

## Section 4: Procedure Checking Status

### Procedure Signature Checking
**C++ Reference:** Lines 1234-1275 (check_procedure_type call)
**Status:** ❌ **NOT IMPLEMENTED**

**Missing Features:**
- Procedure type validation against declaration type
- Polymorphic type parameter handling
- Parameter count/type validation
- Return type validation
- Calling convention consistency

### Procedure Body Checking
**C++ Reference:** Lines 2009-2197 (check_proc_body - 189 lines)
**Status:** ❌ **COMPLETELY MISSING - HIGHEST PRIORITY GAP**

**Missing Critical Features:**
1. **Using Parameter Expansion** (lines 2054-2103)
   - Converts `using` struct parameters into individual field variables
   - Example: `proc(using p: Position) { x, y }` → expands `x`, `y` from `p`
   - Required for idiomatic Odin code

2. **Where Clause Evaluation** (lines 2120-2124)
   - Evaluates polymorphic `where` constraints
   - Disables procedure body checking if constraints fail
   - Critical for generic programming

3. **Statement List Validation** (line 2144)
   - Calls `check_stmt_list` for all body statements
   - Validates declarations, expressions, control flow
   - **Without this, NO procedure bodies are checked**

4. **Return Statement Validation** (lines 2161-2179)
   - Ensures non-void procedures have return statements
   - Checks diverging procedures for proper termination
   - Prevents runtime crashes from missing returns

5. **Dependency Propagation** (line 2186)
   - Propagates nested procedure dependencies to parent
   - Required for cross-procedure type inference
   - Critical for lambda/closure handling

6. **Variadic Optimization Tracking** (lines 2188-2195)
   - Calculates stack reuse for variadic parameters
   - Performance optimization for variadic procedures

**Impact:** Without check_proc_body:
- No validation of procedure implementations
- No control flow analysis
- No return statement checking
- No nested procedure handling
- **The checker cannot validate ANY procedure bodies**

### Procedure Group Validation
**C++ Reference:** Lines 1760-1895 (check_proc_group_decl)
**Status:** ❌ **EMPTY STUB**

**Missing:** See Section 2 proc_group entry for details.

---

## Section 5: Critical Missing Features

### Priority 1: BLOCKING FEATURES (Cannot compile real Odin code)

#### 1. Procedure Body Checking (`check_proc_body`)
- **Lines:** 2009-2197 (189 lines)
- **Impact:** CRITICAL - No procedure bodies are validated
- **Dependencies:** check_stmt.cpp (statement validation), check_expr.cpp (expression validation)
- **Recommendation:** Implement as Phase 30 after statement checking

#### 2. Procedure Type Checking
- **Lines:** 1234-1275 (check_procedure_type call)
- **Impact:** CRITICAL - Procedure signatures not validated
- **Dependencies:** check_type.cpp (procedure type construction)
- **Recommendation:** Implement in Phase 28 with type checking

#### 3. Procedure Attribute Processing
- **Lines:** 1278-1558 (280 lines)
- **Impact:** HIGH - Many attributes silently ignored
- **Missing Attributes:**
  - @(test), @(init), @(fini) - runtime hooks
  - @(require_results) - return value enforcement
  - @(link_name), @(export) - foreign interface
  - @(no_instrumentation) - profiling control
  - Objective-C method metadata
- **Recommendation:** Implement incrementally by Phase 27

### Priority 2: SEMANTIC VALIDATION GAPS (Allows invalid code)

#### 4. Procedure Group Overload Validation
- **Lines:** 1760-1895 (136 lines)
- **Impact:** MEDIUM - Duplicate overloads not detected
- **Missing:**
  - Identical signature detection
  - Return type consistency checking
  - Polymorphic where clause handling
- **Recommendation:** Implement with procedure group support

#### 5. Foreign Procedure Duplicate Detection
- **Lines:** 1180-1215 (check_foreign_procedure)
- **Impact:** MEDIUM - Link name collisions not detected
- **Missing:**
  - Foreign entity registry checking
  - Signature similarity validation (are_signatures_similar_enough)
- **Recommendation:** Implement with foreign interface validation

#### 6. Enum Type Cloning for Distinct Types
- **Lines:** 403-447 (clone_enum_type)
- **Impact:** LOW - Distinct enum declarations broken
- **Example:**
  ```odin
  X :: enum {A, B, C}
  Y :: distinct X  // Y's fields should reference Y, not X
  ```
- **Recommendation:** Implement with type construction (Phase 28)

### Priority 3: TOOLING/METADATA (Non-blocking)

#### 7. Objective-C Method Validation
- **Lines:** 1053-1178 (check_objc_methods)
- **Impact:** LOW - Only affects macOS/iOS targets
- **Recommendation:** Defer to platform-specific phase

#### 8. RTTI/Debug Metadata
- **Lines:** 1757 (check_rtti_type_disallowed), 606-611 (RADDBG)
- **Impact:** LOW - Runtime type info generation
- **Recommendation:** Defer to codegen phase

---

## Section 6: Semantic Differences

### Intentional Design Differences

#### 1. Attribute Storage (POSITIVE CHANGE)
**C++ Approach:**
- Attributes processed inline during declaration checking
- Stored directly in AttributeContext on stack

**Odin Approach:**
- Attribute context created first (make_attribute_context)
- Processed via check_decl_attributes helper
- More modular and testable

**Verdict:** ✅ IMPROVEMENT - Better separation of concerns

#### 2. Foreign Import Queue Processing (ARCHITECTURAL)
**C++ Approach:**
- Foreign imports queued immediately in check_add_foreign_import_decl
- Path resolution deferred to separate pass

**Odin Approach:**
- Same queue-based approach maintained
- Added Phase 25-specific import dependency graph tracking

**Verdict:** ✅ EQUIVALENT - Correct deferred resolution pattern

#### 3. Entity Overriding Mechanism (STRUCTURAL)
**C++ Implementation:**
```cpp
original_entity->identifier.store(new_entity->identifier)
if (ident->kind == Ast_Ident) {
    ident->Ident.entity = new_entity  // Direct AST mutation
}
```

**Odin Implementation:**
```odin
// TODO: Atomic identifier operations
// Requires adding 'identifier: Atomic(^ast.Node)' to Entity struct
```

**C++ Reference:** check_decl.cpp:183-188
**Status:** ❌ **NOT IMPLEMENTED** - TODOs at lines 481-486

**Impact:** MEDIUM - Aliasing may not work correctly for:
- Procedure group aliases
- Constant type aliases
- Import name aliases

**Recommendation:** Add atomic identifier field to Entity struct

### Unintentional Omissions

#### 1. @rodata Validation Depth (BUG)
**C++ Implementation:**
- Recursively checks all struct fields for constant initialization
- Uses ast_token() and type_of_expr() to report specific non-constant fields

**Odin Implementation:**
```odin
// TODO(STRUCTURAL): ast_token and type_of_expr don't exist yet
// tok := ast_token(elem)
// s := type_to_string(type_of_expr(ctx, elem))
```

**C++ Reference:** check_decl.cpp:1746
**Odin Location:** check_decl.odin:422-430 (commented out)

**Impact:** LOW - @rodata struct validation incomplete but main check present

#### 2. Required Global Variable Queue (MISSING)
**C++ Implementation:**
```cpp
if (ac.require_declaration) {
    e->flags |= EntityFlag_Require;
    mpsc_enqueue(&ctx->info->required_global_variable_queue, e);
}
```

**Odin Implementation:**
```odin
if ac.require_declaration {
    e.flags += {.Require}
    // BUG FIX #1: Enqueue entity to required_global_variable_queue
    // TODO(STRUCTURAL): Requires adding queue to Checker_Info
}
```

**C++ Reference:** check_decl.cpp:1631-1634
**Odin Location:** check_decl.odin:279-286

**Impact:** LOW - @require tracking incomplete; validation will fail

---

## Section 7: Attribute Validation Gaps

### Implemented Attributes

| Attribute | Category | Status | Odin Lines |
|-----------|----------|--------|------------|
| @(deferred_in) | Procedure | ✅ DONE | 340-384 (helpers) |
| @(deferred_out) | Procedure | ✅ DONE | 340-384 (helpers) |
| @(deferred_in_out) | Procedure | ✅ DONE | 340-384 (helpers) |
| @(deferred_*_by_ptr) | Procedure | ✅ DONE | 340-384 (helpers) |
| @(require) | Foreign Import | ✅ DONE | 1370-1375 |
| @(ignore_duplicates) | Foreign Import | ✅ DONE | 1268-1270 (helpers) |
| @(export) | Foreign Import | ✅ DONE | 1266-1267 (helpers) |

### Missing Attributes (C++ check_decl.cpp)

#### Critical Procedure Attributes
| Attribute | C++ Lines | Impact | Use Case |
|-----------|-----------|--------|----------|
| @(test) | 1284-1286 | HIGH | Unit test procedures |
| @(init) | 1287-1293 | HIGH | Package initialization |
| @(fini) | 1287-1293 | HIGH | Package cleanup |
| @(cold) | 1295-1296 | MEDIUM | Optimization hint |
| @(link_name) | 1442-1553 | HIGH | Foreign linkage |
| @(export) | 1347 | HIGH | Symbol export |
| @(linkage) | 1458-1467 | MEDIUM | Internal/weak/strong |
| @(require) | 1469-1472 | MEDIUM | Force inclusion |
| @(disabled) | 1443-1452 | MEDIUM | Conditional compilation |

#### Instrumentation Attributes
| Attribute | C++ Lines | Impact | Use Case |
|-----------|-----------|--------|----------|
| @(instrumentation_enter) | 1394-1413 | LOW | Profiling entry hook |
| @(instrumentation_exit) | 1414-1432 | LOW | Profiling exit hook |
| @(no_instrumentation) | 1352-1365 | LOW | Disable profiling |
| @(no_sanitize_address) | 1437 | LOW | ASan control |
| @(no_sanitize_memory) | 1438 | LOW | MSan control |

#### Objective-C Attributes (macOS/iOS)
| Attribute | C++ Lines | Impact | Use Case |
|-----------|-----------|--------|----------|
| @(objc_class) | 521-601 | LOW | ObjC class binding |
| @(objc_type) | 1053-1178 | LOW | Method type binding |
| @(objc_name) | 1063-1076 | LOW | Selector name |
| @(objc_is_class_method) | 1103-1104 | LOW | Class vs instance |

#### Type Attributes
| Attribute | C++ Lines | Impact | Use Case |
|-----------|-----------|--------|----------|
| @(objc_class) | 521-601 | LOW | Zero-size ObjC binding |
| @(raddbg_type_view) | 606-611 | LOW | Debug visualizer |

### Attribute Validation Status

**Implemented:** 7 attributes (14%)
**Missing:** 43 attributes (86%)

**Recommendation:** Implement attributes in priority order:
1. Phase 27: @(link_name), @(export), @(test), @(init), @(fini)
2. Phase 29: @(linkage), @(require), @(disabled), @(cold)
3. Phase 32: Instrumentation and sanitizer attributes
4. Phase 35: Platform-specific (Objective-C, RADDBG)

---

## Section 8: Foreign Declaration Handling

### Foreign Import Declarations

**C++ Reference:** Lines 5490-5545 (check_add_foreign_import_decl)
**Odin Implementation:** Lines 1296-1394 (check_add_foreign_import_decl)
**Status:** ✅ **70% COMPLETE**

#### Implemented Features ✅
1. **Library Name Extraction** (C++ 5499-5503)
   - Derives name from declaration or first path
   - Validates identifier syntax
   - Odin: Lines 1308-1332

2. **Attribute Processing** (C++ 5513-5541)
   - @(require) - force inclusion
   - @(ignore_duplicates) - suppress collision errors
   - @(extra_linker_flags) - parser stub
   - @(foreign_import_priority) - link order control
   - Odin: Lines 1335-1390

3. **Path Resolution** (C++ 5382-5488 in check_foreign_import_fullpaths)
   - Constant expression evaluation
   - Relative path resolution
   - Collection path detection (system:lib)
   - Source file extension rejection (.c, .cpp, .h)
   - Odin: Lines 1404-1519

#### Missing Features ❌

1. **WASM Link Name Processing** (C++ 5457-5487)
   ```cpp
   if (is_arch_wasm() && foreign_library != nullptr) {
       // Process wasm_import_module_name
       // Extract module name from library path
       // Update procedure link names
   }
   ```
   **Odin Status:** Stubbed at line 1517-1518
   **Impact:** WASM target broken for foreign procedures

2. **Import Dependency Graph** (C++ 5068-5167)
   ```cpp
   ImportGraphNode *generate_import_dependency_graph(Checker *c);
   void add_import_dependency_node(Checker *c, Ast *decl, ...);
   ```
   **Odin Status:** Structural stub at lines 1545-1656
   **Impact:** Import cycle detection disabled
   **Blocker:** Requires package tracking infrastructure

### Foreign Procedure Validation

**C++ Reference:** Lines 972-1014 (init_entity_foreign_library), 1180-1215 (check_foreign_procedure)
**Status:** ⚠️ **30% COMPLETE**

#### Implemented Features ✅
1. **Foreign Library Linking** (check_decl.odin:336-346)
   - Links foreign entities to library declarations
   - Validates library exists in scope

#### Missing Features ❌

1. **Duplicate Foreign Entity Detection** (C++ 1180-1215)
   ```cpp
   auto *fp = &ctx->info->foreigns;  // Global foreign registry
   Entity **found = string_map_get(fp, key);
   if (found && e != *found) {
       if (!are_signatures_similar_enough(this_type, other_type)) {
           error("Foreign entity '%s' previously declared with different type");
       }
   }
   ```
   **Impact:** HIGH - Multiple foreign declarations with same link name not detected

2. **Signature Similarity Checking** (C++ 786-899, 902-970)
   - `signature_parameter_similar_enough` - ABI compatibility
   - `are_signatures_similar_enough` - procedure signature comparison

   **C++ Logic:**
   - Pointer type equivalence (^T vs [^]T)
   - Integer size equivalence (i32 vs int)
   - Struct layout compatibility (size, alignment, field types)
   - Slice element type compatibility

   **Odin Status:** Stubbed at check_decl_helpers.odin:428-432
   **Impact:** HIGH - ABI incompatibilities not detected

### Foreign Variable Validation

**C++ Reference:** Lines 1677-1716 (in check_global_variable_decl)
**Odin Implementation:** Lines 332-378
**Status:** ✅ **90% COMPLETE**

#### Implemented Features ✅
1. Foreign library linkage validation
2. WASM foreign variable rejection (cannot scope to module)
3. Link name/section assignment
4. Duplicate foreign entity registry

#### Minor Gap ⚠️
- Missing signature_parameter_similar_enough for variable type checking (C++ line 1707)

---

## Section 9: Polymorphic Support Analysis

**STATUS: NOT IMPLEMENTED - DEFERRED TO PHASE 31**

Polymorphic type parameter handling is scattered across multiple phases:
- **Type construction:** check_type.cpp (Phase 28)
- **Procedure specialization:** check_poly.cpp (Phase 31)
- **Where clause evaluation:** check_decl.cpp:2120-2124 (needs check_proc_body)

### Missing in check_decl.odin

1. **Polymorphic Procedure Validation** (C++ 1501-1510)
   ```cpp
   if (pt->is_polymorphic) {
       if (pl->body == nullptr) {
           error("Polymorphic procedures must have a body");
       }
       if (is_foreign) {
           error("A foreign procedure cannot be polymorphic");
       }
   }
   ```
   **Impact:** Polymorphic proc constraints not enforced

2. **Where Clause Evaluation** (C++ 2120-2124)
   ```cpp
   bool where_clause_ok = evaluate_where_clauses(ctx, nullptr, decl->scope,
                                                  &decl->proc_lit->ProcLit.where_clauses,
                                                  !decl->where_clauses_evaluated);
   if (!where_clause_ok) {
       return false;  // Skip body checking
   }
   ```
   **Impact:** Generic constraints not validated

3. **Polymorphic Record Unspecialized Check** (C++ 2060-2069)
   ```cpp
   if (is_type_polymorphic(e->type) &&
       is_type_polymorphic_record_unspecialized(e->type)) {
       error("Unspecialized polymorphic types not allowed in procedure parameters");
   }
   ```
   **Impact:** Generic parameter validation missing

**Recommendation:** Implement with procedure body checking (Phase 30) and polymorphic specialization (Phase 31)

---

## Section 10: Recommended Implementation Order

### Phase Grouping by Dependencies

#### Phase 26: Attribute Infrastructure (CURRENT)
**Prerequisites:** None
**Deliverables:**
- Complete check_decl_attributes implementation
- Add @(test), @(init), @(fini), @(cold) support
- Add @(link_name), @(export), @(linkage) support
- **Estimated:** 150 lines

**Files to Modify:**
- check_decl_helpers.odin:302-388 (expand check_decl_attributes)

#### Phase 27: Foreign Validation (NEXT)
**Prerequisites:** Phase 26
**Deliverables:**
- Implement signature_parameter_similar_enough (ABI compatibility)
- Implement are_signatures_similar_enough (procedure signature comparison)
- Add foreign entity duplicate detection (check_foreign_procedure)
- Complete WASM link name processing
- **Estimated:** 200 lines

**Files to Modify:**
- check_decl_helpers.odin:428-432 (expand signature_parameter_similar_enough)
- check_decl.odin: Add check_foreign_procedure (new function)

#### Phase 28: Type Construction
**Prerequisites:** check_type.cpp port (separate workstream)
**Deliverables:**
- Implement clone_enum_type for distinct enums
- Add type path cycle detection (check_type_path_push/pop)
- Complete check_type_decl attribute handling
- **Estimated:** 100 lines

**Files to Modify:**
- check_decl_helpers.odin:440-505 (expand check_type_decl)
- check_type.odin: Add clone_enum_type (new function)

#### Phase 29: Procedure Declaration (CRITICAL)
**Prerequisites:** Phase 28 (procedure type construction)
**Deliverables:**
- Implement full check_proc_decl (C++ 1217-1599)
- Add entry point validation ('main' procedure)
- Implement all procedure attributes
- Add procedure body queueing (check_procedure_later)
- **Estimated:** 400 lines

**Files to Modify:**
- check_decl.odin:1078-1133 (expand from 56 to ~450 lines)

#### Phase 30: Procedure Body Validation (HIGHEST PRIORITY)
**Prerequisites:** Phase 29 + check_stmt.cpp port
**Deliverables:**
- Implement check_proc_body (C++ 2009-2197)
- Add using parameter expansion
- Add where clause evaluation
- Add statement list validation
- Add return statement validation
- Add dependency propagation
- **Estimated:** 250 lines

**Files to Create:**
- check_decl.odin: Add check_proc_body (new function ~250 lines)

#### Phase 31: Polymorphic Support
**Prerequisites:** Phase 30 + check_poly.cpp port
**Deliverables:**
- Implement where clause evaluation
- Add polymorphic procedure constraints
- Add polymorphic record validation
- **Estimated:** 150 lines (integrated into existing functions)

#### Phase 32: Procedure Groups
**Prerequisites:** Phase 30
**Deliverables:**
- Implement check_proc_group_decl (C++ 1760-1895)
- Add overload safety validation
- Add where clause overload handling
- **Estimated:** 150 lines

**Files to Modify:**
- check_decl.odin:1134-1136 (expand from stub to ~150 lines)

#### Phase 33: Import Dependency Graph
**Prerequisites:** Package tracking infrastructure
**Deliverables:**
- Implement generate_import_dependency_graph
- Implement add_import_dependency_node
- Add import cycle detection
- **Estimated:** 200 lines

**Files to Modify:**
- check_decl.odin:1545-1656 (expand structural stub)

---

### Critical Path Timeline

```
Current State (Phase 25 Complete):
├─ Variable/constant checking ✅
├─ Basic type declarations ⚠️
├─ Foreign import infrastructure ✅
└─ Minimal procedure tracking ⚠️

Phase 26-27 (2 weeks):
├─ Attribute infrastructure
├─ Foreign validation
└─ ABI compatibility checking

Phase 28-29 (3 weeks): [BLOCKING]
├─ Type construction (parallel workstream)
├─ Complete procedure declaration
└─ Procedure body queueing

Phase 30 (2 weeks): [CRITICAL PATH]
├─ Procedure body validation
├─ Statement checking integration
└─ Return statement validation

Phase 31-32 (2 weeks):
├─ Polymorphic support
└─ Procedure group validation

Phase 33 (1 week):
├─ Import dependency graph
└─ Cycle detection

Total Estimated Effort: 10-12 weeks to complete check_decl.cpp port
```

---

## Appendix A: Function Mapping Table

| C++ Function | C++ Lines | Odin Function | Odin Lines | Status |
|--------------|-----------|---------------|------------|--------|
| check_init_variable | 4-124 | check_init_variable | 32-209 | ✅ COMPLETE |
| check_init_variables | 126-152 | check_init_variables | 212-246 | ✅ COMPLETE |
| override_entity_in_scope | 155-195 | override_entity_in_scope | 444-492 | ⚠️ 90% (atomic ops missing) |
| check_override_as_type_due_to_aliasing | 197-240 | check_override_as_type_due_to_aliasing | 496-546 | ✅ COMPLETE |
| check_try_override_const_decl | 244-306 | check_try_override_const_decl | 549-636 | ✅ COMPLETE |
| check_init_constant | 308-351 | check_init_constant | 742-793 | ✅ COMPLETE |
| is_type_distinct | 354-386 | is_type_distinct | helpers:227-254 | ✅ COMPLETE |
| remove_type_alias_clutter | 388-401 | remove_type_alias_clutter | helpers:258-274 | ✅ COMPLETE |
| clone_enum_type | 403-447 | - | - | ❌ MISSING |
| check_type_decl | 449-619 | check_type_decl | helpers:440-505 | ⚠️ 40% |
| check_const_decl | 622-768 | check_const_decl | 796-976 | ✅ 95% |
| signature_parameter_similar_enough | 786-899 | signature_parameter_similar_enough | helpers:428-432 | ❌ STUB |
| are_signatures_similar_enough | 902-970 | - | - | ❌ MISSING |
| init_entity_foreign_library | 972-1014 | init_entity_foreign_library | helpers:412-416 | ❌ STUB |
| handle_link_name | 1016-1050 | handle_link_name | helpers:392-400 | ❌ STUB |
| check_objc_methods | 1053-1178 | - | - | ❌ MISSING |
| check_foreign_procedure | 1180-1215 | - | - | ❌ MISSING |
| check_proc_decl | 1217-1599 | check_proc_decl | 1078-1133 | ⚠️ 15% |
| check_global_variable_decl | 1612-1758 | check_global_variable_decl | 249-441 | ✅ 90% |
| check_proc_group_decl | 1760-1895 | check_proc_group_decl | 1134-1136 | ❌ STUB |
| check_entity_decl | 1897-1969 | check_entity_decl | 639-722 | ✅ COMPLETE |
| add_deps_from_child_to_parent | 1972-2001 | - | - | ⏳ DEFERRED |
| check_proc_body | 2009-2197 | - | - | ❌ MISSING |

**Legend:**
- ✅ COMPLETE: Functionally equivalent to C++
- ⚠️ PARTIAL: Core logic present but missing features
- ❌ MISSING: Not implemented
- ❌ STUB: Empty placeholder
- ⏳ DEFERRED: Intentionally postponed to later phase

---

## Appendix B: Structural Gaps in Checker_Info

The following fields need to be added to `Checker_Info` struct:

```odin
Checker_Info :: struct {
    // Existing fields...

    // MISSING - Required for check_decl.cpp functionality:

    // C++ check_decl.cpp:1634 - @require tracking for globals
    required_global_variable_queue: MPSC_Queue(^Entity),

    // C++ check_decl.cpp:5543 - Foreign import path resolution queue
    foreign_imports_to_check_fullpaths: MPSC_Queue(^Entity),  // ✅ ADDED in Phase 25

    // C++ check_decl.cpp:5572 - WASM foreign procedure queue
    foreign_decls_to_check: MPSC_Queue(^Entity),  // ✅ ADDED in Phase 25

    // C++ check_decl.cpp:1185 - Foreign entity registry
    foreigns: map[string]^Entity,  // Key: link_name, Value: entity
    foreign_mutex: sync.Mutex,

    // C++ check_decl.cpp:1406-1428 - Instrumentation hooks
    instrumentation_enter_entity: ^Entity,
    instrumentation_exit_entity: ^Entity,
    instrumentation_mutex: sync.Mutex,

    // C++ check_decl.cpp:1524 - Procedure body checking queue
    // NOTE: This is in Checker, not Checker_Info
}

Checker :: struct {
    // Existing fields...

    // MISSING:

    // C++ checker.cpp:1957 - Procedure bodies to check later
    procs_to_check: MPSC_Queue(Procedure_To_Check),

    // C++ check_decl.cpp:1557 - Deferred procedure validation
    procs_with_deferred_to_check: MPSC_Queue(^Entity),  // ✅ ADDED in Phase 26
}
```

---

## Appendix C: Code Quality Assessment

### Positive Attributes ✅

1. **Excellent C++ Reference Documentation**
   - Every function has C++ line number references
   - Comments explain structural differences
   - TODOs clearly marked with implementation notes

2. **Strong Error Handling**
   - Defensive nil checks throughout
   - Consistent error message format
   - No silent failures

3. **Proper Memory Management**
   - Correct allocator usage (temp vs permanent)
   - defer statements for cleanup
   - No obvious leaks

4. **Good Code Organization**
   - Logical function grouping
   - Clear separation between check_decl.odin and helpers
   - Consistent naming conventions

### Areas for Improvement ⚠️

1. **Incomplete Stub Documentation**
   - Some stubs lack implementation notes
   - Missing dependency chains for TODOs
   - No estimated complexity for stubs

2. **Phase 25 Foreign Import Code Quality**
   - Lines 1296-1519 (foreign import) are well-implemented
   - BUT: Not integrated with rest of checker infrastructure
   - Needs integration testing

3. **Overly Defensive Checks**
   - Some asserts could be stronger (e.g., line 257 could panic)
   - Occasional redundant nil checks

### Critical Issues ❌

1. **Missing Integration Points**
   - check_proc_body stub blocks ALL procedure checking
   - No validation that variable checking actually works
   - Untested foreign import queuing

2. **Structural Dependencies Not Validated**
   - Assumes Entity.decl_info exists (commented out in many places)
   - Assumes MPSC_Queue(^Entity) is implemented
   - No verification of Checker_Info fields

---

## Summary and Recommendations

### Current State
The check_decl.odin implementation provides a **solid foundation** for variable and constant declaration checking, with **good code quality** and **thorough C++ reference documentation**. However, **critical gaps** in procedure checking make the checker non-functional for real Odin code.

### Blockers to Full Functionality

1. **check_proc_body (189 lines)** - Without this, NO procedure bodies are validated
2. **check_proc_decl expansion (340 lines)** - Procedure signatures not validated
3. **Foreign procedure validation (100 lines)** - Link name collisions not detected
4. **Procedure group validation (136 lines)** - Overload safety not enforced

### Immediate Actions Required

**For Phase 26 (Current):**
1. Complete attribute infrastructure (@test, @init, @fini, @link_name)
2. Add unit tests for variable/constant checking
3. Validate foreign import queue integration

**For Phase 27 (Next Sprint):**
1. Implement signature_parameter_similar_enough (ABI checking)
2. Implement check_foreign_procedure (duplicate detection)
3. Complete WASM foreign handling

**For Phase 28-30 (Critical Path):**
1. Port check_type.cpp (prerequisite for procedure types)
2. Expand check_proc_decl to full implementation
3. Implement check_proc_body (HIGHEST PRIORITY)

### Risk Assessment

**HIGH RISK:**
- No procedure body validation → Silent acceptance of invalid code
- No foreign duplicate detection → Link-time failures
- Incomplete attribute processing → Feature flags ignored

**MEDIUM RISK:**
- Missing procedure group validation → Overload conflicts
- Incomplete type declaration → Distinct enums broken
- No polymorphic constraints → Generic code unchecked

**LOW RISK:**
- Missing Objective-C support → Only affects Darwin targets
- Missing instrumentation → Only affects profiling
- Missing RADDBG → Only affects debugging

### Go/No-Go Decision

**Recommendation: CONDITIONAL GO for Phase 27**

**Conditions:**
1. Add unit tests for implemented functions (3-5 days)
2. Validate foreign import integration (2 days)
3. Create detailed Phase 28-30 implementation plan (1 day)

**If conditions met:**
- Proceed with Phase 27 (foreign validation)
- Prepare for Phase 28-30 critical path

**If conditions NOT met:**
- Pause new development
- Refactor existing code with tests
- Validate architectural decisions

---

**Document Version:** 1.0
**Last Updated:** 2025-10-03
**Next Review:** After Phase 27 completion
