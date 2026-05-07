# Checker Implementation Verification Report

**Date:** 2025-10-03
**C++ Reference:** `/mnt/c/odin/src/checker.cpp` (7,542 lines)
**Odin Implementation:** `/mnt/d/dev/checker/checker.odin` (1,556 lines)
**Status:** **CRITICALLY INCOMPLETE - STUB IMPLEMENTATION**

---

## Executive Summary

The Odin implementation of `checker.odin` is **84% incomplete** when measured against the C++ reference implementation. The main orchestration function `check_files` is a **complete stub** that returns `true` without performing any semantic analysis. This represents a critical architectural gap that renders the checker non-functional.

### Implementation Metrics

| Metric | C++ Reference | Odin Port | Completeness |
|--------|---------------|-----------|--------------|
| **Total checker lines** | 7,542 | 1,556 | 21% |
| **Total check_*.cpp lines** | 36,872 | 31,085 | 84% |
| **Core procedures** | ~450 | 208 | 46% |
| **Stub functions** | 0 | ~25 | - |
| **TODO markers** | 0 | 244 | - |

### Critical Finding

**The main checker entry point `check_files` (line 1547) is completely unimplemented:**

```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
    // Implementation will follow the C++ workflow:
    // 1. Create file scopes
    // 2. Collect entities
    // 3. Export/import entities
    // 4. Check global entities
    // 5. Check procedure bodies

    return true  // STUB - NO ACTUAL CHECKING
}
```

This is equivalent to having **no checker at all**. The function should be 200+ lines implementing the complete checking pipeline shown in C++ `check_parsed_files` (lines 7282-7542).

---

## 1. Implementation Status

### Overall Completeness: **~16%**

The checker implementation suffers from a fundamental architectural problem: **the main orchestration layer is entirely missing**. While many supporting modules exist, they are not integrated into a working checker pipeline.

### Line Count Comparison

```
C++ checker.cpp:        7,542 lines
Odin checker.odin:      1,556 lines (21% of C++)

C++ check_*.cpp total: 36,872 lines
Odin check_*.odin:     31,085 lines (84% of C++)
```

The line count paradox (84% coverage) is **misleading** - most Odin files contain partial implementations, stubs, and TODO markers rather than complete functionality.

---

## 2. Missing Features - Main Checker Pipeline

The C++ `check_parsed_files` function (lines 7282-7542) implements a **30-step checking pipeline**. The Odin port has **zero steps implemented** in the main entry point.

### 2.1 Package and Scope Management (Missing)

**C++ Reference:** `checker.cpp:7288-7309`

```cpp
// Map full filepaths to Scopes (C++ line 7288-7303)
for_array(i, c->parser->packages) {
    AstPackage *p = c->parser->packages[i];
    Scope *scope = create_scope_from_package(&c->builtin_ctx, p);
    p->decl_info = make_decl_info(scope, c->builtin_ctx.decl);
    string_map_set(&c->info.packages, p->fullpath, p);
    // ... init_package, runtime_package setup
}

// init worker data (C++ line 7306)
check_init_worker_data(c);

// create file scopes (C++ line 7309)
check_create_file_scopes(c);
```

**Odin Status:** ❌ **Not called from check_files**

- Package scope mapping: MISSING
- Worker data initialization: MISSING
- File scope creation: Available in `check_collect.odin` but NOT INTEGRATED

**Impact:** Without package/file scopes, no symbol resolution can occur.

### 2.2 Entity Collection Phase (Missing)

**C++ Reference:** `checker.cpp:7312-7324`

```cpp
// collect entities (C++ line 7312)
check_collect_entities_all(c);

// export entities - pre (C++ line 7315)
check_export_entities(c);

// import entities (C++ line 7318)
check_import_entities(c);

// export entities - post (C++ line 7321)
check_export_entities(c);

// merge queues (C++ line 7324)
check_merge_queues_into_arrays(c);
```

**Odin Status:** ❌ **Not called from check_files**

- Entity collection: Available in `check_collect.odin:check_collect_entities_all` but NOT INTEGRATED
- Entity export: Available in `check_import.odin:check_export_entities` but NOT INTEGRATED
- Entity import: Available in `check_import.odin:check_import_entities` but NOT INTEGRATED
- Queue merging: Available in `queue_drain.odin:check_merge_queues_into_arrays` but NOT INTEGRATED

**Impact:** No entity discovery means no type checking foundation.

### 2.3 Global Entity Checking (Partially Available)

**C++ Reference:** `checker.cpp:7327-7333`

```cpp
// check all global entities (C++ line 7327)
check_all_global_entities(c);

// init preload (C++ line 7330)
init_preload(c);

// add global untyped expressions (C++ line 7333)
add_untyped_expressions(&c->info, &c->info.global_untyped);
```

**Odin Status:** ⚠️ **Partial implementation exists but NOT INTEGRATED**

- `check_all_global_entities`: Implemented in `check_global.odin:645` but NOT called
- `init_preload`: Implemented in `check_runtime.odin` but NOT called
- `add_untyped_expressions`: MISSING

**Impact:** Global variables unchecked, runtime types unavailable.

### 2.4 Procedure Body Checking (Partially Available)

**C++ Reference:** `checker.cpp:7335-7346`

```cpp
// check procedure bodies (C++ line 7340)
check_procedure_bodies(c);

// check foreign import fullpaths (C++ line 7343)
check_foreign_import_fullpaths(c);

// merge queues (C++ line 7346)
check_merge_queues_into_arrays(c);
```

**Odin Status:** ⚠️ **Partial implementation exists but NOT INTEGRATED**

- `check_procedure_bodies`: Implemented in `check_proc.odin:449` but NOT called
- `check_foreign_import_fullpaths`: MISSING
- Queue merging: Available but NOT called

**Impact:** Procedure bodies remain unchecked.

### 2.5 Validation and Finalization (Missing)

**C++ Reference:** `checker.cpp:7348-7443`

The C++ checker performs **15 additional validation steps**:

```cpp
check_all_scope_usages(c);              // Line 7349
// Add basic type information            // Line 7352-7361
check_for_type_cycles(c);                // Line 7364
check_for_inline_cycles(c);              // Line 7367
check_deferred_procedures(c);            // Line 7370
check_objc_context_provider_procedures(c); // Line 7373
calculate_global_init_order(c);          // Line 7376
add_type_info_for_type_definitions(c);   // Line 7379
check_update_dependency_tree_for_procedures(c); // Line 7383
generate_minimum_dependency_set(c, c->info.entry_point); // Line 7386
check_unchecked_bodies(c);               // Line 7389
generate_minimum_dependency_set_internal(c, c->info.entry_point); // Line 7395
check_test_procedures(c);                // Line 7400
// Check entry point                     // Line 7405-7427
// Check instrumentation                 // Line 7447-7455
// Type info collision detection         // Line 7467-7517
// Sort init/fini procedures             // Line 7520-7521
```

**Odin Status:** ❌ **None of these steps are called from check_files**

Available but not integrated:
- `calculate_global_init_order`: In `check_global.odin:529` ✓
- `check_deferred_procedures`: In `check_deferred.odin` ✓

Completely missing:
- `check_all_scope_usages`
- `check_for_type_cycles`
- `check_for_inline_cycles`
- `check_objc_context_provider_procedures`
- `add_type_info_for_type_definitions`
- `check_update_dependency_tree_for_procedures`
- `generate_minimum_dependency_set`
- `check_unchecked_bodies`
- `check_test_procedures`
- Entry point validation
- Instrumentation validation
- Type info collision detection
- Init/fini procedure sorting

**Impact:** No semantic validation, cycle detection, or dependency analysis.

---

## 3. Semantic Differences

### 3.1 Checker Initialization

**C++ (checker.cpp:1565-1586):**
```cpp
gb_internal void init_checker(Checker *c) {
    init_checker_info(&c->info);
    c->info.checker = c;

    mpsc_init(&c->procs_with_deferred_to_check, a);
    mpsc_init(&c->procs_with_objc_context_provider_to_check, a);

    array_init(&c->procs_to_check, heap_allocator(), 0, 1<<20);
    array_init(&c->nested_proc_lits, heap_allocator(), 0, 1<<20);

    mpsc_init(&c->global_untyped_queue, a);
    mpsc_init(&c->soa_types_to_complete, a);

    c->builtin_ctx = make_checker_context(c);
}
```

**Odin (checker.odin:1481-1513):**
```odin
init_checker :: proc(allocator := context.allocator) -> ^Checker {
    c := new(Checker, allocator)
    c.allocator = allocator
    c.info.checker = c

    // Initialize MPSC queues with default capacities
    mpsc_queue_init(&c.info.definition_queue, 10000)
    mpsc_queue_init(&c.info.entity_queue, 10000)
    // ... more queues ...

    return c
}
```

**Difference:**
- C++ expects a `Parser` reference to access packages (C++ line 7289: `c->parser->packages`)
- Odin has no parser integration - `check_files` receives raw AST files
- This architectural mismatch means **package-level checking cannot work**

**Impact:** The Odin checker cannot access package metadata, making multi-package checking impossible.

### 3.2 Context Management

**C++ (checker.cpp:7335-7337):**
```cpp
CheckerContext prev_context = c->builtin_ctx;
defer (c->builtin_ctx = prev_context);
c->builtin_ctx.decl = make_decl_info(nullptr, nullptr);
```

**Odin:** ❌ **Missing from check_files**

The C++ checker temporarily modifies `builtin_ctx.decl` during procedure body checking to create a fresh declaration scope. The Odin port doesn't implement this context swapping.

**Impact:** Builtin context corruption would occur if procedure checking were implemented.

---

## 4. Critical Bugs

### 4.1 Non-Functional Checker Entry Point

**Location:** `/mnt/d/dev/checker/checker.odin:1547-1556`

**Bug:** The main `check_files` function is a stub that performs no checking:

```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
    // Implementation will follow the C++ workflow:
    // 1. Create file scopes
    // 2. Collect entities
    // 3. Export/import entities
    // 4. Check global entities
    // 5. Check procedure bodies

    return true  // ALWAYS SUCCEEDS - NO VALIDATION
}
```

**Expected:** Should implement the 30-step pipeline from C++ `check_parsed_files` (7282-7542)

**Severity:** **CRITICAL** - This makes the entire checker non-functional.

### 4.2 Missing Parser Integration

**C++ Dependency (checker.cpp:7289):**
```cpp
for_array(i, c->parser->packages) {
    AstPackage *p = c->parser->packages[i];
    // ...
}
```

**Odin Implementation:**
```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
    // No access to packages - only raw files
}
```

**Bug:** The Odin checker receives `[]^ast.File` but needs `[]^ast.Package` to perform package-level checking.

**Impact:**
- Cannot identify package boundaries
- Cannot map files to packages
- Cannot perform cross-package imports
- Cannot find runtime/init packages

**Severity:** **CRITICAL** - Multi-file/package checking impossible.

### 4.3 Unintegrated Components

**Available Functions Not Called:**

1. `check_collect_entities_all` (check_collect.odin:210) - ✓ Implemented but NOT called
2. `check_export_entities` (check_import.odin) - ✓ Implemented but NOT called
3. `check_import_entities` (check_import.odin) - ✓ Implemented but NOT called
4. `check_all_global_entities` (check_global.odin:645) - ✓ Implemented but NOT called
5. `check_procedure_bodies` (check_proc.odin:449) - ✓ Implemented but NOT called
6. `check_merge_queues_into_arrays` (queue_drain.odin) - ✓ Implemented but NOT called

**Bug:** The checker has ~2000 lines of working code that is never executed because the orchestration layer doesn't call these functions.

**Severity:** **HIGH** - Implemented features are dead code.

---

## 5. Stub Analysis

### 5.1 Primary Stub: check_files

**File:** `/mnt/d/dev/checker/checker.odin:1547-1556`

**Returns:** `true` (unconditional success)

**Expected Behavior:**
1. Map packages to scopes (C++ 7288-7303)
2. Initialize worker threads (C++ 7306)
3. Create file scopes (C++ 7309)
4. Collect entities (C++ 7312)
5. Export entities pre-import (C++ 7315)
6. Import entities (C++ 7318)
7. Export entities post-import (C++ 7321)
8. Merge queues (C++ 7324)
9. Check global entities (C++ 7327)
10. Initialize preload (C++ 7330)
11. Check procedure bodies (C++ 7340)
12. Validate cycles (C++ 7364-7367)
13. Calculate init order (C++ 7376)
14. Generate dependency set (C++ 7386)
15. Check entry point (C++ 7405-7427)
16. ... 15 more steps

**Actual Behavior:** Returns immediately with no checking

### 5.2 Supporting Stubs

**File:** Various

| Function | Location | Returns | Expected |
|----------|----------|---------|----------|
| `is_type_zero_initializable` | check_global.odin:768 | N/A (TODO) | Type analysis |
| `complete_soa_type` | check_global.odin:793 | N/A (TODO) | SOA completion |
| `add_untyped_expressions` | Missing | - | Expression queueing |
| `check_foreign_import_fullpaths` | Missing | - | Foreign validation |
| `check_all_scope_usages` | Missing | - | Scope validation |
| `check_for_type_cycles` | Missing | - | Cycle detection |
| `check_for_inline_cycles` | Missing | - | Inline validation |
| `generate_minimum_dependency_set` | Missing | - | Dependency analysis |
| `check_unchecked_bodies` | Missing | - | Coverage check |

---

## 6. Required Fixes (Prioritized)

### Priority 1: CRITICAL - Implement Main Checker Pipeline

**Task:** Implement `check_files` orchestration

**File:** `/mnt/d/dev/checker/checker.odin:1547`

**C++ Reference:** `checker.cpp:7282-7542`

**Required Changes:**

```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
    // Phase 1: Setup (C++ 7288-7309)
    // - Map packages to scopes
    // - Initialize worker data
    // - Create file scopes

    // Phase 2: Entity Collection (C++ 7312-7324)
    check_collect_entities_all(c)
    check_export_entities(c)
    check_import_entities(c)
    check_export_entities(c)
    check_merge_queues_into_arrays(c)

    // Phase 3: Global Checking (C++ 7327-7333)
    ctx := make_checker_context(c)
    check_all_global_entities(&ctx)
    init_preload(c)
    // TODO: add_untyped_expressions

    // Phase 4: Procedure Bodies (C++ 7340-7346)
    prev_ctx := c.builtin_ctx
    defer c.builtin_ctx = prev_ctx
    c.builtin_ctx.decl = make_decl_info(nil, nil)

    check_procedure_bodies(c)
    // TODO: check_foreign_import_fullpaths
    check_merge_queues_into_arrays(c)

    // Phase 5: Validation (C++ 7348-7400)
    // TODO: check_all_scope_usages
    // TODO: check_for_type_cycles
    // TODO: check_for_inline_cycles
    check_deferred_procedures(c)
    // TODO: check_objc_context_provider_procedures
    // calculate_global_init_order already called by check_all_global_entities
    // TODO: add_type_info_for_type_definitions
    // TODO: check_update_dependency_tree_for_procedures
    // TODO: generate_minimum_dependency_set
    // TODO: check_unchecked_bodies
    // TODO: check_test_procedures
    check_merge_queues_into_arrays(c)

    // Phase 6: Entry Point (C++ 7405-7427)
    // TODO: Validate entry point exists

    // Phase 7: Type Info (C++ 7467-7517)
    // TODO: Type info collision detection

    return true
}
```

**Lines to Add:** ~200 (matching C++ complexity)

**Estimated Effort:** 3-5 days (requires careful integration of existing components)

### Priority 2: CRITICAL - Add Package Support

**Task:** Modify `check_files` signature to accept packages

**Current:**
```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool
```

**Required:**
```odin
check_files :: proc(c: ^Checker, packages: []^ast.Package) -> bool
```

**Alternative:** Add package discovery from files:
```odin
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
    // Discover packages from files
    packages := discover_packages_from_files(files)

    // Map packages (C++ 7289-7303)
    for pkg in packages {
        scope := create_scope_from_package(&c.builtin_ctx, pkg)
        // ...
    }
}
```

**Estimated Effort:** 1-2 days

### Priority 3: HIGH - Implement Missing Validation Steps

**Tasks:**

1. **check_all_scope_usages** (C++ checker.cpp:7349)
   - File: Create `check_scope.odin`
   - Reference: C++ implementation TBD
   - Effort: 2-3 days

2. **check_for_type_cycles** (C++ checker.cpp:7364)
   - File: Create `check_cycles.odin`
   - Reference: C++ implementation TBD
   - Effort: 3-4 days

3. **check_for_inline_cycles** (C++ checker.cpp:7367)
   - File: `check_cycles.odin`
   - Reference: C++ implementation TBD
   - Effort: 2-3 days

4. **add_untyped_expressions** (C++ checker.cpp:7333)
   - File: Extend `check_expr.odin`
   - Reference: C++ implementation TBD
   - Effort: 1-2 days

5. **generate_minimum_dependency_set** (C++ checker.cpp:7386, 7395)
   - File: Extend `check_global.odin`
   - Reference: C++ implementation TBD
   - Effort: 3-4 days

6. **check_unchecked_bodies** (C++ checker.cpp:7389)
   - File: Extend `check_proc.odin`
   - Reference: C++ implementation TBD
   - Effort: 1-2 days

7. **check_test_procedures** (C++ checker.cpp:7400)
   - File: Create `check_test.odin`
   - Reference: C++ implementation TBD
   - Effort: 2-3 days

**Total Effort:** 14-21 days

### Priority 4: MEDIUM - Entry Point and Type Info

**Tasks:**

1. **Entry Point Validation** (C++ checker.cpp:7405-7427)
   ```odin
   // Validate 'main' procedure exists in init package
   if build_context.build_mode == .Executable {
       s := c.info.init_scope
       e := scope_lookup_current(s, "main")
       if e == nil {
           error(token, "Undefined entry point procedure 'main'")
       }
       c.info.entry_point = e
   }
   ```
   - Effort: 1 day

2. **Type Info Collision Detection** (C++ checker.cpp:7467-7517)
   ```odin
   // Initialize type_info_types_hash_map
   // Check for hash collisions
   // Validate unique tuples
   ```
   - Effort: 2-3 days

3. **Init/Fini Procedure Sorting** (C++ checker.cpp:7520-7521)
   ```odin
   check_sort_init_and_fini_procedures(c)
   ```
   - Effort: 1-2 days

**Total Effort:** 4-6 days

---

## 7. Implementation Roadmap

### Phase 1: Foundation (Week 1)
- [ ] Implement `check_files` orchestration shell
- [ ] Add package support to checker API
- [ ] Integrate existing collection/export/import calls
- [ ] Verify basic entity discovery works

**Deliverable:** Checker can discover entities from files

### Phase 2: Global Checking (Week 2)
- [ ] Integrate `check_all_global_entities` call
- [ ] Integrate `init_preload` call
- [ ] Implement `add_untyped_expressions`
- [ ] Test global variable initialization

**Deliverable:** Checker validates global entities

### Phase 3: Procedure Checking (Week 3)
- [ ] Integrate `check_procedure_bodies` call
- [ ] Implement `check_foreign_import_fullpaths`
- [ ] Implement context swapping for builtin_ctx
- [ ] Test procedure body validation

**Deliverable:** Checker validates procedure bodies

### Phase 4: Cycle Detection (Week 4)
- [ ] Implement `check_for_type_cycles`
- [ ] Implement `check_for_inline_cycles`
- [ ] Integrate `check_deferred_procedures` call
- [ ] Test cycle detection

**Deliverable:** Checker detects circular dependencies

### Phase 5: Dependency Analysis (Week 5)
- [ ] Implement `generate_minimum_dependency_set`
- [ ] Implement `check_update_dependency_tree_for_procedures`
- [ ] Integrate dependency analysis calls
- [ ] Test dependency pruning

**Deliverable:** Checker computes minimal dependency set

### Phase 6: Finalization (Week 6)
- [ ] Implement `check_unchecked_bodies`
- [ ] Implement `check_test_procedures`
- [ ] Implement entry point validation
- [ ] Implement type info collision detection
- [ ] Implement init/fini sorting

**Deliverable:** Checker completes full validation pipeline

### Phase 7: Integration Testing (Week 7)
- [ ] Test with simple single-file programs
- [ ] Test with multi-file packages
- [ ] Test with runtime package
- [ ] Validate against C++ checker output
- [ ] Performance benchmarking

**Deliverable:** Verified checker parity with C++

**Total Timeline:** 7 weeks (35 working days)

---

## 8. Verification Summary

### Overall Assessment: **INCOMPLETE STUB**

The Odin checker implementation is fundamentally incomplete. While significant infrastructure exists (31,085 lines of supporting code), the main orchestration layer that ties everything together is entirely missing.

### Key Findings

1. ✅ **Data Structures**: ~95% complete
   - Entity types ✓
   - Type system ✓
   - Scope management ✓
   - Declaration info ✓
   - Queue infrastructure ✓

2. ⚠️ **Supporting Modules**: ~70% complete
   - Entity collection ✓ (but not integrated)
   - Import/export ✓ (but not integrated)
   - Global checking ✓ (but not integrated)
   - Procedure checking ✓ (but not integrated)
   - Dependency analysis ✓ (partial)

3. ❌ **Main Pipeline**: **0% complete**
   - Package mapping ✗
   - Orchestration ✗
   - Integration ✗
   - Validation steps ✗ (15/30 missing)

4. ❌ **Critical Components**: **~50% missing**
   - Cycle detection ✗
   - Dependency set generation ✗
   - Unchecked body validation ✗
   - Type info collision detection ✗
   - Test procedure checking ✗
   - Entry point validation ✗

### Functional Equivalence

**Current State:** ❌ **NO FUNCTIONAL EQUIVALENCE**

The checker cannot:
- ✗ Discover packages
- ✗ Create file scopes
- ✗ Collect entities
- ✗ Resolve imports
- ✗ Check global variables
- ✗ Check procedure bodies
- ✗ Detect cycles
- ✗ Validate entry points
- ✗ Generate type information

**Why:** The orchestration layer that calls these components doesn't exist.

### Recommended Action

**IMMEDIATE:** Implement `check_files` orchestration following the roadmap above.

**PRIORITY ORDER:**
1. Week 1: Foundation (package support + basic orchestration)
2. Week 2: Global checking integration
3. Week 3: Procedure checking integration
4. Week 4-6: Validation and dependency analysis
5. Week 7: Integration testing

**Success Criteria:**
- `check_files` implements all 30 steps from C++ `check_parsed_files`
- All existing components are properly integrated
- Checker can validate simple Odin programs
- Output matches C++ checker for test cases

---

## Appendix A: File-by-File Status

| File | Lines | Status | Integration | Notes |
|------|-------|--------|-------------|-------|
| checker.odin | 1,556 | ⚠️ 20% | ✗ Not integrated | Main stub incomplete |
| check_collect.odin | ~800 | ✅ 90% | ✗ Not called | Ready for integration |
| check_import.odin | ~900 | ✅ 90% | ✗ Not called | Ready for integration |
| check_global.odin | ~850 | ✅ 85% | ✗ Not called | Missing helpers |
| check_proc.odin | ~600 | ✅ 80% | ✗ Not called | Ready for integration |
| check_deferred.odin | ~400 | ✅ 90% | ✗ Not called | Ready for integration |
| check_expr.odin | ~2,550 | ✅ 95% | ✓ Used internally | Complete |
| check_stmt.odin | ~1,200 | ✅ 90% | ✓ Used internally | Complete |
| check_type.odin | ~1,800 | ✅ 90% | ✓ Used internally | Complete |
| check_decl.odin | ~3,200 | ✅ 90% | ✓ Used internally | Complete |
| check_builtin.odin | ~1,500 | ✅ 95% | ✓ Used internally | Complete |
| types.odin | ~3,500 | ✅ 95% | ✓ Used everywhere | Complete |
| entity.odin | ~2,800 | ✅ 95% | ✓ Used everywhere | Complete |
| scope.odin | ~1,200 | ✅ 95% | ✓ Used everywhere | Complete |
| queue_drain.odin | ~300 | ✅ 90% | ✗ Not called | Ready for integration |

**Summary:**
- Core infrastructure: ✅ **95% complete**
- Main pipeline: ❌ **0% complete**
- Integration: ❌ **0% complete**

---

## Appendix B: C++ Reference Locations

### Main Pipeline (checker.cpp:7282-7542)

| Step | C++ Line | Odin Status | Notes |
|------|----------|-------------|-------|
| Package mapping | 7288-7303 | ✗ Missing | No package support |
| Worker init | 7306 | ⚠️ Partial | check_proc.odin:438 |
| File scopes | 7309 | ✓ Available | check_collect.odin:142 |
| Collect entities | 7312 | ✓ Available | check_collect.odin:210 |
| Export pre | 7315 | ✓ Available | check_import.odin |
| Import | 7318 | ✓ Available | check_import.odin |
| Export post | 7321 | ✓ Available | check_import.odin |
| Merge queues | 7324 | ✓ Available | queue_drain.odin:24 |
| Global entities | 7327 | ✓ Available | check_global.odin:645 |
| Init preload | 7330 | ✓ Available | check_runtime.odin |
| Untyped exprs | 7333 | ✗ Missing | - |
| Proc bodies | 7340 | ✓ Available | check_proc.odin:449 |
| Foreign imports | 7343 | ✗ Missing | - |
| Scope usages | 7349 | ✗ Missing | - |
| Type cycles | 7364 | ✗ Missing | - |
| Inline cycles | 7367 | ✗ Missing | - |
| Deferred procs | 7370 | ✓ Available | check_deferred.odin |
| ObjC providers | 7373 | ✗ Missing | - |
| Init order | 7376 | ✓ Available | check_global.odin:529 |
| Type info defs | 7379 | ✗ Missing | - |
| Dep tree update | 7383 | ✗ Missing | - |
| Min dep set | 7386 | ✗ Missing | - |
| Unchecked bodies | 7389 | ✗ Missing | - |
| Min dep set 2 | 7395 | ✗ Missing | - |
| Test procs | 7400 | ✗ Missing | - |
| Entry point | 7405-7427 | ✗ Missing | - |
| Type info hash | 7467-7517 | ✗ Missing | - |
| Init/fini sort | 7520-7521 | ✗ Missing | - |

**Completion Rate:** 11/26 steps available (42%), 0/26 integrated (0%)

---

**Report End**
