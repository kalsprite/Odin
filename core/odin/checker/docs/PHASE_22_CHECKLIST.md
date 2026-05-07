# Phase 22: Structural Foundation - Implementation Checklist

**Priority**: ⭐⭐⭐⭐⭐ CRITICAL BLOCKER
**Duration**: 2 weeks (8-16 hours implementation + testing)
**LOC**: 125 lines
**Risk**: LOW
**Force Multiplier**: 12.6x (unlocks 1,572 LOC of Phase 19)

---

## Overview

Phase 22 removes the structural blockers preventing Phase 19 integration. This is the **highest ROI task** in the entire roadmap.

**What This Unlocks**:
- ✅ Phase 19 code compilation (1,572 LOC)
- ✅ Phase 23 helper function implementation
- ✅ Phase 24 statement completion
- ✅ Statement coverage: 75% → 100%
- ✅ Declaration checking: 40% → 100%

---

## Task Breakdown

### Task 1: Entity Structure Completion (50 LOC, 4 hours)

**File**: `/mnt/d/dev/checker/entity.odin`

**Changes Required**:

#### 1.1 Add Base Entity Fields
```odin
Entity :: struct {
    // ... existing fields ...

    // PHASE 22 ADDITIONS:
    decl_info: ^Decl_Info,              // Declaration information
    aliased_of: ^Entity,                // For type aliases
    identifier: sync.Atomic(^ast.Node), // Concurrent access to identifier

    // ... rest of fields ...
}
```

**C++ Reference**: `/mnt/c/odin/src/checker.cpp:862-900`

**Verification**:
- [ ] decl_info field added (type: ^Decl_Info)
- [ ] aliased_of field added (type: ^Entity)
- [ ] identifier field added (type: sync.Atomic(^ast.Node))
- [ ] All Entity constructors updated to initialize new fields

---

#### 1.2 Complete Entity_Variable Fields
```odin
Entity_Variable :: struct {
    using entity: Entity,

    // ... existing fields ...

    // PHASE 22 ADDITIONS:
    link_name: string,                  // Foreign link name
    link_section: string,               // Foreign link section
    thread_local_model: i32,            // Thread-local storage model
    is_export: bool,                    // Exported symbol
    is_rodata: bool,                    // Read-only data section
    foreign_library: ^Entity,           // Foreign library entity
    parent_proc_decl: ^Entity,          // Parent procedure declaration
    init_expr: ^ast.Node,               // Initialization expression
}
```

**C++ Reference**: `/mnt/c/odin/src/entity.cpp:45-120`

**Verification**:
- [ ] link_name field added
- [ ] link_section field added
- [ ] thread_local_model field added
- [ ] is_export field added
- [ ] is_rodata field added
- [ ] foreign_library field added (type: ^Entity)
- [ ] parent_proc_decl field added (type: ^Entity)
- [ ] init_expr field added (type: ^ast.Node)

---

### Task 2: Entity_Nil Variant (10 LOC, 2 hours)

**File**: `/mnt/d/dev/checker/entity.odin`

**Changes Required**:

#### 2.1 Add Entity_Nil to Entity Union
```odin
Entity :: union {
    Entity_Constant,
    Entity_Variable,
    Entity_Type_Name,
    Entity_Procedure,
    Entity_Proc_Group,
    Entity_Label,
    Entity_Library_Name,
    Entity_Import_Name,
    Entity_Nil,  // PHASE 22 ADDITION
}
```

#### 2.2 Define Entity_Nil Struct
```odin
Entity_Nil :: struct {
    using entity: Entity,
    // Nil entity has no additional fields
}
```

**C++ Reference**: `/mnt/c/odin/src/entity.cpp:25-30` (implied by nil checks)

**Verification**:
- [ ] Entity_Nil variant added to union
- [ ] Entity_Nil struct defined
- [ ] entity_of_node can return nil entities
- [ ] Nil entity checks updated throughout codebase

---

### Task 3: Checker_Info Queue Addition (20 LOC, 3 hours)

**File**: `/mnt/d/dev/checker/checker.odin`

**Changes Required**:

#### 3.1 Add Queue Declaration
```odin
Checker_Info :: struct {
    // ... existing queues ...

    // PHASE 22 ADDITION:
    required_global_variable_queue: MPSC_Queue(^Entity),

    // ... rest of fields ...
}
```

#### 3.2 Initialize Queue
**Location**: `init_checker_info` procedure
```odin
init_checker_info :: proc(info: ^Checker_Info) {
    // ... existing queue initialization ...

    // PHASE 22 ADDITION:
    mpsc_queue_init(&info.required_global_variable_queue, 256)

    // ... rest of initialization ...
}
```

#### 3.3 Destroy Queue
**Location**: `destroy_checker_info` procedure
```odin
destroy_checker_info :: proc(info: ^Checker_Info) {
    // ... existing queue destruction ...

    // PHASE 22 ADDITION:
    mpsc_queue_destroy(&info.required_global_variable_queue)

    // ... rest of destruction ...
}
```

**C++ Reference**: `/mnt/c/odin/src/checker.hpp:496` (queue declaration)

**Verification**:
- [ ] required_global_variable_queue declared
- [ ] Queue initialized in init_checker_info
- [ ] Queue destroyed in destroy_checker_info
- [ ] Queue drain function added to queue_drain.odin (see Task 3.4)

---

#### 3.4 Add Queue Drain Function
**File**: `/mnt/d/dev/checker/queue_drain.odin`

```odin
drain_required_global_variable_queue :: proc(info: ^Checker_Info) {
    for {
        entity, ok := mpsc_dequeue(&info.required_global_variable_queue)
        if !ok do break
        append(&info.required_global_variables, entity)
    }
}
```

**C++ Reference**: `/mnt/c/odin/src/checker.cpp:5100-5120` (queue processing)

**Verification**:
- [ ] Drain function implemented
- [ ] Added to drain_all_queues call list

---

### Task 4: Decl_Info Parent Linkage (15 LOC, 2 hours)

**File**: `/mnt/d/dev/checker/check_decl_helpers.odin`

**Changes Required**:

#### 4.1 Update make_decl_info Signature
```odin
// BEFORE (Phase 20):
make_decl_info :: proc(
    scope: ^Scope,
    allocator := context.allocator,
) -> ^Decl_Info

// AFTER (Phase 22):
make_decl_info :: proc(
    scope: ^Scope,
    parent: ^Decl_Info = nil,  // NEW PARAMETER
    allocator := context.allocator,
) -> ^Decl_Info
```

#### 4.2 Add Parent Linkage Logic
```odin
make_decl_info :: proc(
    scope: ^Scope,
    parent: ^Decl_Info = nil,
    allocator := context.allocator,
) -> ^Decl_Info {
    d := new(Decl_Info, allocator)
    d.scope = scope
    d.parent = parent  // Set parent reference

    // PHASE 22 ADDITION: Parent-child linking
    if parent != nil {
        d.next_sibling = parent.next_child
        parent.next_child = d
    }

    // ... rest of initialization ...

    return d
}
```

**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4971-4980`

**Verification**:
- [ ] Parent parameter added to signature
- [ ] Parent reference stored in d.parent
- [ ] Sibling linking logic implemented
- [ ] All call sites updated (5 locations - see Task 4.3)

---

#### 4.3 Update Call Sites

**Locations to Update**:
1. `/mnt/d/dev/checker/check_type.odin` - Procedure type checking (2 sites)
2. `/mnt/d/dev/checker/check_decl.odin` - Entity declaration (1 site)
3. `/mnt/d/dev/checker/check_stmt.odin` - Block statements (2 sites)

**Pattern**:
```odin
// BEFORE:
decl := make_decl_info(scope)

// AFTER:
decl := make_decl_info(scope, parent_decl_info)
```

**Verification**:
- [ ] Procedure type checking updated (check_type.odin)
- [ ] Entity declaration updated (check_decl.odin)
- [ ] Block statements updated (check_stmt.odin)
- [ ] All sites compile without errors

---

### Task 5: Variadic Reuse Decision (30 LOC, 2 hours)

**File**: `/mnt/d/dev/checker/checker.odin`

**Decision Required**: Does Phase 22 need variadic procedure support?

**Analysis**:
- **C++ Fields**: 3 fields in Decl_Info
  - `gen_proc_stack_data: bool`
  - `variadic_reuse_type: ^Type`
  - `variadic_reuse_index: i32`
- **Usage**: 25 usages in C++, mostly in backend (llvm_backend_proc.cpp)
- **Impact**: Variadic procedure optimization, not core type checking

**Options**:

#### Option A: Defer to Later Phase (Recommended for MVP)
```odin
Decl_Info :: struct {
    // ... existing fields ...

    // TODO(Phase 28+): Variadic procedure optimization fields
    // These are used in backend code generation, not core type checking.
    // Deferring to later phase to maintain focus on MVP.
    // C++ Reference: checker.cpp:248-249
    //
    // When implementing, add:
    // gen_proc_stack_data: bool
    // variadic_reuse_type: ^Type
    // variadic_reuse_index: i32
}
```

**Pros**:
- Faster Phase 22 completion
- MVP doesn't need variadic optimization
- Clear documentation of decision

**Cons**:
- Potential rework in Phase 28+

---

#### Option B: Implement Now (Complete Parity)
```odin
Decl_Info :: struct {
    // ... existing fields ...

    // PHASE 22 ADDITIONS: Variadic procedure optimization
    gen_proc_stack_data: bool,
    variadic_reuse_type: ^Type,
    variadic_reuse_index: i32,
}
```

**Pros**:
- Complete structural parity with C++
- No rework needed later

**Cons**:
- Adds 30 LOC now
- Not used until Phase 28+ (polymorphic procedures)

---

**Recommendation**: **Option A (Defer)**

**Rationale**:
1. MVP focus is non-generic programs (Phases 22-26)
2. Variadic optimization is backend-specific
3. Clear TODO documents the deferral
4. Can implement in Phase 28 when polymorphic procedures are added

**Verification**:
- [ ] Decision documented in checker.odin
- [ ] TODO added with C++ reference
- [ ] Team aware of deferral
- [ ] No impact on Phase 19 integration

---

## Testing Checklist

### Compilation Tests
- [ ] `odin check /mnt/d/dev/checker -no-entry-point` passes
- [ ] `odin check /mnt/d/dev/checker -no-entry-point -strict-style` passes
- [ ] Zero errors, zero warnings
- [ ] All files compile successfully

### Integration Tests
- [ ] Phase 19 code compiles without structural errors
- [ ] check_decl.odin compiles (was blocked)
- [ ] check_stmt.odin compiles (was blocked)
- [ ] Entity fields accessible from all modules

### Functional Tests
- [ ] Entity creation with new fields works
- [ ] Decl_info parent linkage functional
- [ ] required_global_variable_queue enqueue/dequeue works
- [ ] Entity_Nil variant can be created and checked

### Regression Tests
- [ ] Existing Phase 1-21 functionality unchanged
- [ ] No performance degradation
- [ ] All existing tests still pass

---

## Implementation Order

**Day 1 (4 hours)**:
1. ✅ Task 1.1: Add base Entity fields (1 hour)
2. ✅ Task 1.2: Complete Entity_Variable fields (1 hour)
3. ✅ Task 2: Add Entity_Nil variant (1 hour)
4. ✅ Compile and test (1 hour)

**Day 2 (4 hours)**:
5. ✅ Task 3: Add required_global_variable_queue (2 hours)
6. ✅ Task 4: Update make_decl_info and call sites (2 hours)

**Day 3 (4 hours)**:
7. ✅ Task 5: Document variadic reuse decision (1 hour)
8. ✅ Full integration testing (2 hours)
9. ✅ Documentation and commit (1 hour)

**Total**: 12 hours over 3 days (within 2-week buffer)

---

## Success Criteria

**Phase 22 is complete when**:
- ✅ All Entity struct fields from C++ present
- ✅ Entity_Nil variant implemented
- ✅ required_global_variable_queue operational
- ✅ Decl_Info parent linkage functional
- ✅ Variadic reuse decision documented
- ✅ Zero compilation errors/warnings
- ✅ Phase 19 code compiles without structural errors
- ✅ All tests passing

**Phase 22 unlocks**:
- ✅ Phase 23 helper function implementation (39 functions)
- ✅ Phase 24 statement completion (activate 1,572 LOC)
- ✅ Statement coverage: 75% → 100%
- ✅ Declaration checking: 40% → 100%

---

## Files to Modify

### Primary Files (Must Edit)
1. `/mnt/d/dev/checker/entity.odin`
   - Lines to add: ~60 LOC (Tasks 1-2)

2. `/mnt/d/dev/checker/checker.odin`
   - Lines to add: ~40 LOC (Task 3, 5)

3. `/mnt/d/dev/checker/check_decl_helpers.odin`
   - Lines to modify: ~15 LOC (Task 4)

4. `/mnt/d/dev/checker/queue_drain.odin`
   - Lines to add: ~10 LOC (Task 3.4)

### Secondary Files (Call Site Updates)
5. `/mnt/d/dev/checker/check_type.odin` - Update make_decl_info calls
6. `/mnt/d/dev/checker/check_decl.odin` - Update make_decl_info calls
7. `/mnt/d/dev/checker/check_stmt.odin` - Update make_decl_info calls

**Total Files**: 7 files to modify
**Total LOC**: ~125 lines added/modified

---

## C++ Reference Guide

### Entity Fields Reference
- `/mnt/c/odin/src/entity.cpp:45-120` - Entity_Variable fields
- `/mnt/c/odin/src/checker.cpp:862-900` - Entity base fields

### Decl_Info Parent Linkage Reference
- `/mnt/c/odin/src/checker.cpp:4971-4980` - init_decl_info with parent
- `/mnt/c/odin/src/checker.cpp:100-150` - Parent-child linking

### Queue Processing Reference
- `/mnt/c/odin/src/checker.hpp:496` - required_global_variable_queue declaration
- `/mnt/c/odin/src/checker.cpp:5100-5120` - Queue drain logic

### Variadic Reuse Reference
- `/mnt/c/odin/src/checker.cpp:248-249` - Decl_Info variadic fields
- `/mnt/c/odin/src/llvm_backend_proc.cpp:*` - Variadic usage (25 sites)

---

## Risk Mitigation

### Potential Issues & Solutions

**Issue 1**: Field type mismatches
- **Probability**: 5%
- **Impact**: Compilation errors
- **Solution**: Verify each field type against C++ reference
- **Time**: +2 hours debugging

**Issue 2**: Atomic type configuration
- **Probability**: 10%
- **Impact**: Thread safety issues
- **Solution**: Test atomic operations, check sync package docs
- **Time**: +2 hours research

**Issue 3**: Call site discovery incomplete
- **Probability**: 15%
- **Impact**: Runtime errors
- **Solution**: Grep for "make_decl_info(" in all files
- **Time**: +1 hour searching

**Issue 4**: Queue initialization order
- **Probability**: 5%
- **Impact**: Runtime panics
- **Solution**: Follow existing queue pattern exactly
- **Time**: +1 hour debugging

**Total Risk Buffer**: +6 hours (within 2-week estimate)

---

## Commit Strategy

**Commit 1**: Entity structure fields
```
Phase 22.1: Add Entity base fields and Entity_Variable completion

- Add decl_info, aliased_of, identifier to base Entity
- Complete Entity_Variable with 8 missing fields
- Add Entity_Nil variant to union
- Update all entity constructors

C++ Reference: entity.cpp:45-120, checker.cpp:862-900
LOC: +60
```

**Commit 2**: Checker infrastructure
```
Phase 22.2: Add required_global_variable_queue and parent linkage

- Add required_global_variable_queue to Checker_Info
- Initialize/destroy queue in checker lifecycle
- Add drain function to queue_drain.odin
- Update make_decl_info with parent parameter
- Implement parent-child linking logic

C++ Reference: checker.hpp:496, checker.cpp:4971-4980
LOC: +55
```

**Commit 3**: Call site updates and documentation
```
Phase 22.3: Update make_decl_info call sites and document decisions

- Update 5 call sites with parent parameter
- Document variadic reuse deferral decision
- Add comprehensive testing
- Verify Phase 19 code compiles

LOC: +10
Status: Phase 22 COMPLETE ✅
Unlocks: 1,572 LOC of Phase 19 code
```

---

## Phase 22 Completion Verification

**Before proceeding to Phase 23, verify**:

### Structural Verification
- [ ] Entity has all C++ fields (decl_info, aliased_of, identifier)
- [ ] Entity_Variable has all 8 missing fields
- [ ] Entity_Nil variant exists and is usable
- [ ] Checker_Info has required_global_variable_queue
- [ ] Queue is initialized and destroyed properly

### Functional Verification
- [ ] make_decl_info accepts parent parameter
- [ ] Parent-child linking works (next_child, next_sibling)
- [ ] All 5 call sites updated and compile
- [ ] Queue enqueue/dequeue works

### Integration Verification
- [ ] Phase 19 check_decl.odin compiles
- [ ] Phase 19 check_stmt.odin compiles
- [ ] No structural errors in Phase 19 code
- [ ] All Phase 1-21 tests still pass

### Documentation Verification
- [ ] Variadic reuse decision documented
- [ ] C++ references added to all new code
- [ ] Commit messages explain changes
- [ ] Phase 22 status document created

**When all checks pass**: ✅ **Phase 22 Complete → Proceed to Phase 23**

---

**Next Phase**: See `/mnt/d/dev/checker/PHASE_23_CHECKLIST.md` (to be created)

**Full Roadmap**: `/mnt/d/dev/checker/COMPLETION_ROADMAP.md`
**Dependencies**: `/mnt/d/dev/checker/PHASE_DEPENDENCY_GRAPH.md`
**Summary**: `/mnt/d/dev/checker/IMPLEMENTATION_SUMMARY.md`
