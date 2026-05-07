# Scope Implementation Verification Report

**Date:** 2025-10-03
**Source:** `/mnt/c/odin/src/checker.cpp` (lines 57-531) and `/mnt/c/odin/src/checker.hpp` (lines 285-305)
**Target:** `/mnt/d/dev/checker/scope.odin`
**Status:** **INCOMPLETE - Missing Critical Functions**

---

## Executive Summary

The Odin port of the scope management system is **functionally incomplete**. While core scope operations (lookup, insert, creation) are correctly ported with proper threading considerations, **4 critical utility functions** used throughout the checker codebase are missing:

1. `add_scope` - Associates scope with AST nodes (C++ lines 295-315)
2. `scope_of_node` - Retrieves scope from AST nodes (C++ lines 317-338)
3. `scope_insert_no_mutex` - Direct no-mutex insertion (C++ lines 528-531)
4. Hash optimization parameter - Performance optimization for lookups (C++ lines 385-439)

Additionally, the Odin implementation uses non-atomic pointers where C++ uses `std::atomic<Scope *>` for `next` and `head_child` fields, which may cause race conditions in multi-threaded scenarios.

---

## Overview

### C++ Scope Structure
**Location:** `/mnt/c/odin/src/checker.hpp:285-305`

```cpp
struct Scope {
    Ast *         node;
    Scope *       parent;
    std::atomic<Scope *> next;           // ← ATOMIC
    std::atomic<Scope *> head_child;     // ← ATOMIC

    i32 index; // within a procedure

    RwMutex mutex;
    StringMap<Entity *> elements;
    PtrSet<Scope *> imported;

    DeclInfo *decl_info;

    i32 flags; // ScopeFlag
    union {
        AstPackage *pkg;
        AstFile *   file;
        Entity *    procedure_entity;
    };
};
```

### Odin Scope Structure
**Location:** `/mnt/d/dev/checker/checker.odin:393-409`

```odin
Scope :: struct {
    node:       ^ast.Node,
    parent:     ^Scope,
    next:       ^Scope,              // ← NOT ATOMIC (potential race condition)
    head_child: ^Scope,              // ← NOT ATOMIC (potential race condition)
    index:      i32,
    elements:   map[string]^Entity,
    imported:   map[^Scope]struct{},
    mutex:      sync.RW_Mutex,
    decl_info:  ^Decl_Info,
    flags:      Scope_Flag,

    // Union-like storage
    pkg:        ^ast.Package,
    file:       ^ast.File,
    procedure:  ^Entity,
}
```

**Issue:** The Odin version does not use atomic operations for `next` and `head_child`, while the C++ version does. This is critical because `create_scope` performs atomic exchange operations on `parent->head_child` (C++ line 221):

```cpp
Scope *prev_head_child = parent->head_child.exchange(s, std::memory_order_acq_rel);
```

---

## Completeness Analysis

### ✅ Correctly Ported Functions

| Function | C++ Location | Odin Location | Status |
|----------|--------------|---------------|--------|
| `create_scope` | checker.cpp:216-232 | scope.odin:32-45 | ✅ Correct (missing atomic operations) |
| `destroy_scope` | checker.cpp:283-292 | scope.odin:48-52 | ✅ Correct (simplified) |
| `scope_reserve` | checker.cpp:57-59 | scope.odin:55-57 | ✅ Correct |
| `scope_lookup_current` | checker.cpp:374-380 | scope.odin:60-68 | ✅ Correct (added mutex, reasonable) |
| `scope_lookup` | checker.cpp:436-440 | scope.odin:71-88 | ⚠️ Partial (missing hash param, different impl) |
| `scope_lookup_parent` | checker.cpp:385-434 | scope.odin:93-231 | ✅ Correct (split into 3 variants) |
| `scope_insert_with_name` | checker.cpp:479-517 | scope.odin:236-326 | ✅ Correct (split into 3 variants) |
| `scope_insert` | checker.cpp:519-526 | scope.odin:331-341 | ✅ Correct |
| `scope_import` | Used at 5102, 5293 | scope.odin:344-353 | ✅ Correct |

### ❌ Missing Critical Functions

#### 1. **`add_scope` - CRITICAL MISSING**
**C++ Location:** `/mnt/c/odin/src/checker.cpp:295-315`

```cpp
gb_internal void add_scope(CheckerContext *c, Ast *node, Scope *scope) {
    GB_ASSERT(node != nullptr);
    GB_ASSERT(scope != nullptr);
    scope->node = node;
    switch (node->kind) {
    case Ast_BlockStmt:       node->BlockStmt.scope       = scope; break;
    case Ast_IfStmt:          node->IfStmt.scope          = scope; break;
    case Ast_ForStmt:         node->ForStmt.scope         = scope; break;
    case Ast_RangeStmt:       node->RangeStmt.scope       = scope; break;
    case Ast_UnrollRangeStmt: node->UnrollRangeStmt.scope = scope; break;
    case Ast_CaseClause:      node->CaseClause.scope      = scope; break;
    case Ast_SwitchStmt:      node->SwitchStmt.scope      = scope; break;
    case Ast_TypeSwitchStmt:  node->TypeSwitchStmt.scope  = scope; break;
    case Ast_ProcType:        node->ProcType.scope        = scope; break;
    case Ast_StructType:      node->StructType.scope      = scope; break;
    case Ast_UnionType:       node->UnionType.scope       = scope; break;
    case Ast_EnumType:        node->EnumType.scope        = scope; break;
    case Ast_BitFieldType:    node->BitFieldType.scope    = scope; break;
    default: GB_PANIC("Invalid node for add_scope");
    }
}
```

**Impact:** This function is **actively used** in `/mnt/d/dev/checker/check_poly_proc.odin:363`:
```odin
add_scope(&nctx, pl.type, final_proc_type.variant.(Type_Proc).scope)
```

This will cause a **compilation error** since the function doesn't exist. The Odin codebase cannot build without this function.

---

#### 2. **`scope_of_node` - CRITICAL MISSING**
**C++ Location:** `/mnt/c/odin/src/checker.cpp:317-338`

```cpp
gb_internal Scope *scope_of_node(Ast *node) {
    if (node == nullptr) {
        return nullptr;
    }
    switch (node->kind) {
    case Ast_BlockStmt:       return node->BlockStmt.scope;
    case Ast_IfStmt:          return node->IfStmt.scope;
    case Ast_ForStmt:         return node->ForStmt.scope;
    case Ast_RangeStmt:       return node->RangeStmt.scope;
    case Ast_UnrollRangeStmt: return node->UnrollRangeStmt.scope;
    case Ast_CaseClause:      return node->CaseClause.scope;
    case Ast_SwitchStmt:      return node->SwitchStmt.scope;
    case Ast_TypeSwitchStmt:  return node->TypeSwitchStmt.scope;
    case Ast_ProcType:        return node->ProcType.scope;
    case Ast_StructType:      return node->StructType.scope;
    case Ast_UnionType:       return node->UnionType.scope;
    case Ast_EnumType:        return node->EnumType.scope;
    case Ast_BitFieldType:    return node->BitFieldType.scope;
    }
    GB_PANIC("Invalid node for scope_of_node");
    return nullptr;
}
```

**Impact:** This is a complementary function to `add_scope` and is used throughout the checker to retrieve scopes from AST nodes. Without it, code that needs to query "what scope is associated with this node?" will fail.

---

#### 3. **`scope_insert_no_mutex` - MISSING**
**C++ Location:** `/mnt/c/odin/src/checker.cpp:528-531`

```cpp
gb_internal Entity *scope_insert_no_mutex(Scope *s, Entity *entity) {
    String name = entity->token.string;
    return scope_insert_with_name_no_mutex(s, name, entity);
}
```

**Impact:** Used in `/mnt/c/odin/src/check_decl.cpp:2109`:
```cpp
Entity *prev = scope_insert_no_mutex(ctx->scope, uvar);
```

This is a performance optimization for known single-threaded contexts where the caller explicitly wants to bypass the threading mode check in `scope_insert`. Without this, the port must use `scope_insert` and rely on the global `in_single_threaded_checker_stage` flag, which is less explicit and may not match the C++ semantics in all cases.

---

#### 4. **Hash Optimization Parameter - MISSING**
**C++ Location:** `/mnt/c/odin/src/checker.cpp:385-439`

The C++ versions of `scope_lookup_parent` and `scope_lookup` accept an optional `u32 hash` parameter:

```cpp
gb_internal void scope_lookup_parent(Scope *scope, String const &name,
                                     Scope **scope_, Entity **entity_,
                                     u32 hash)  // ← Hash parameter

gb_internal Entity *scope_lookup(Scope *s, String const &name, u32 hash)
```

**Purpose:** Pre-computed hash values avoid re-hashing the same string multiple times during repeated lookups (lines 391-396):

```cpp
StringHashKey key = {};
if (hash) {
    key.hash = hash;
    key.string = name;
} else {
    key = string_hash_string(name);
}
```

**Impact:** The Odin version always re-hashes strings (uses `map[string]^Entity`), which is simpler but potentially slower in hot lookup paths. This is a **performance regression**, not a correctness issue, but it deviates from the C++ implementation's optimization strategy.

**Odin Implementation:**
```odin
// scope.odin:71-88 - No hash parameter
scope_lookup :: proc(s: ^Scope, name: string) -> ^Entity {
    // Check current scope
    if entity := scope_lookup_current(s, name); entity != nil {
        return entity
    }

    // Check imported scopes
    // ...
}
```

**Note:** The Odin `scope_lookup` also has a **different semantic** - it checks imported scopes, while the C++ version only calls `scope_lookup_parent` (line 438). This is a **behavioral divergence**.

---

## Intent Preservation

### ✅ Correctly Preserved Intent

1. **Threading Model:** The Odin port correctly implements the dual-path threading optimization:
   - `in_single_threaded_checker_stage` flag (scope.odin:29)
   - Dispatcher functions that choose mutex vs no-mutex variants (lines 226-231, 321-326, 337-340)
   - Detailed comments explaining C++ transition points (lines 14-28)

2. **Scope Boundary Semantics:** Correctly preserves proc/package boundary crossing logic:
   - Labels cannot cross procedure boundaries (scope.odin:113-121, 179-186)
   - Local variables cannot cross unless file-level or static (lines 125-138, 191-204)
   - Identical logic to C++ lines 404-416

3. **Result Parameter Shadowing:** Correctly prevents shadowing of result parameters (scope.odin:254-266, 294-306), matching C++ lines 497-506.

4. **Import Mechanism:** Correctly implements scope import using `map[^Scope]struct{}` (scope.odin:344-353), matching C++'s `ptr_set_add` pattern (lines 5102, 5293).

### ⚠️ Intent Deviations

#### 1. **`scope_lookup` Semantic Change**
**C++ Behavior (lines 436-439):**
```cpp
gb_internal Entity *scope_lookup(Scope *s, String const &name, u32 hash) {
    Entity *entity = nullptr;
    scope_lookup_parent(s, name, nullptr, &entity, hash);
    return entity;
}
```
Simply wraps `scope_lookup_parent`.

**Odin Behavior (scope.odin:71-88):**
```odin
scope_lookup :: proc(s: ^Scope, name: string) -> ^Entity {
    // Check current scope
    if entity := scope_lookup_current(s, name); entity != nil {
        return entity
    }

    // Check imported scopes
    sync.rw_mutex_shared_lock(&s.mutex)
    defer sync.rw_mutex_shared_unlock(&s.mutex)

    for imported_scope in s.imported {
        if entity := scope_lookup_current(imported_scope, name); entity != nil {
            return entity
        }
    }

    return nil
}
```

**Divergence:** The Odin version checks imported scopes, while the C++ version does not. This changes the lookup semantics. The Odin version appears to implement what might be a "flat lookup" (current + imports), while the C++ version delegates to the parent chain lookup.

**Assessment:** This appears to be an **intentional enhancement** or a **misunderstanding** of the original design. Without seeing how `scope_lookup` is used in the broader codebase, it's unclear if this is correct. The comment in scope.odin:70 says "searches current scope and imported scopes," suggesting this was deliberate, but it doesn't match the C++ implementation.

#### 2. **Atomic Pointer Operations**
**C++ (checker.cpp:221-224):**
```cpp
if (parent != nullptr && parent != builtin_pkg->scope) {
    Scope *prev_head_child = parent->head_child.exchange(s, std::memory_order_acq_rel);
    if (prev_head_child) {
        s->next.store(prev_head_child, std::memory_order_release);
    }
}
```

**Odin (scope.odin:38-42):**
```odin
// Link as child of parent
if parent != nil {
    s.next = parent.head_child
    parent.head_child = s
}
```

**Divergence:** The Odin version uses simple pointer assignments instead of atomic operations. This is **unsafe in multi-threaded contexts** where multiple threads might be creating scopes simultaneously. The C++ version uses `exchange` (atomic swap) to safely prepend to the child list.

**Impact:** Potential race conditions when scopes are created concurrently. This is mitigated by the fact that scope creation likely happens during single-threaded initialization, but the C++ code explicitly protects against concurrent creation with atomics.

---

## Missing or Incomplete Features

### CRITICAL: Missing Functions

| Function | Purpose | Impact |
|----------|---------|--------|
| `add_scope` | Associates scope with AST node | **Build failure** - Used in check_poly_proc.odin:363 |
| `scope_of_node` | Retrieves scope from AST node | Cannot query node-associated scopes |
| `scope_insert_no_mutex` | Direct no-mutex insertion | Less explicit control over threading behavior |

### MODERATE: Performance Optimizations

| Feature | C++ Implementation | Odin Implementation | Impact |
|---------|-------------------|---------------------|--------|
| Hash caching | `u32 hash` parameter in lookups | Always re-hash | Performance regression in hot paths |
| Atomic child linking | `std::atomic<Scope *>` | Plain pointers | Potential race conditions |

### LOW: Utility Functions

The following helper functions from C++ are not present in scope.odin but are implemented elsewhere:

| Function | C++ Location | Odin Location | Notes |
|----------|--------------|---------------|-------|
| `check_open_scope` | checker.cpp:341-367 | check_stmt.odin:117-123 | ✅ Implemented (simplified) |
| `check_close_scope` | checker.cpp:369-371 | check_stmt.odin:127-131 | ✅ Implemented |

These are correctly located in check_stmt.odin as they operate on `Checker_Context`, not just `Scope`.

---

## Detailed Code Comparison

### `create_scope` Comparison

**C++ (lines 216-232):**
```cpp
gb_internal Scope *create_scope(CheckerInfo *info, Scope *parent) {
    Scope *s = gb_alloc_item(permanent_allocator(), Scope);
    s->parent = parent;

    if (parent != nullptr && parent != builtin_pkg->scope) {
        Scope *prev_head_child = parent->head_child.exchange(s, std::memory_order_acq_rel);
        if (prev_head_child) {
            s->next.store(prev_head_child, std::memory_order_release);
        }
    }

    if (parent != nullptr && parent->flags & ScopeFlag_ContextDefined) {
        s->flags |= ScopeFlag_ContextDefined;
    }

    return s;
}
```

**Odin (scope.odin:32-45):**
```odin
create_scope :: proc(parent: ^Scope, allocator := context.allocator) -> ^Scope {
    s := new(Scope, allocator)
    s.parent = parent
    s.elements = make(map[string]^Entity, DEFAULT_SCOPE_CAPACITY, allocator)
    s.imported = make(map[^Scope]struct{}, allocator)

    // Link as child of parent
    if parent != nil {
        s.next = parent.head_child       // ← Not atomic
        parent.head_child = s            // ← Not atomic
    }

    return s
}
```

**Differences:**
1. ✅ Odin initializes `elements` and `imported` maps (C++ does this in `create_scope_from_file`/`create_scope_from_package`)
2. ❌ Odin doesn't check for `builtin_pkg->scope` exception
3. ❌ Odin doesn't propagate `ContextDefined` flag
4. ❌ Odin doesn't use atomic operations for child linking
5. ✅ Odin allows custom allocator (more flexible)

**Assessment:** The Odin version is **simplified and less complete**. It's unclear if the missing builtin_pkg check and ContextDefined propagation will cause issues - this depends on whether they're handled elsewhere or are necessary at all.

---

### `destroy_scope` Comparison

**C++ (lines 283-292):**
```cpp
gb_internal void destroy_scope(Scope *scope) {
    for (Scope *child = scope->head_child; child != nullptr; child = child->next) {
        destroy_scope(child);  // Recursive destruction
    }

    string_map_destroy(&scope->elements);
    ptr_set_destroy(&scope->imported);

    // NOTE(bill): No need to free scope as it "should" be allocated
    // in an arena (except for the global scope)
}
```

**Odin (scope.odin:48-52):**
```odin
destroy_scope :: proc(s: ^Scope) {
    delete(s.elements)
    delete(s.imported)
    free(s)
}
```

**Difference:** The Odin version **does not recursively destroy child scopes**. This is a **memory leak** if child scopes are not destroyed separately.

**Counter-argument:** The C++ comment suggests scopes are arena-allocated, so explicit freeing may not be expected. The Odin version may rely on arena/bulk deallocation. However, the map cleanup is still necessary, and the lack of recursive cleanup is a semantic difference.

---

### `scope_lookup_parent` Comparison

This is the most complex function. Both versions correctly implement the boundary-crossing logic.

**Key Similarity:** Both properly handle:
- Proc boundary crossing
- Label restrictions (lines 113-121 Odin, 405-406 C++)
- Variable scope restrictions (lines 125-138 Odin, 408-415 C++)

**Key Difference:**
- C++ uses hash optimization (lines 390-396)
- Odin always accesses `elements[name]` directly

Both implement the single-threaded/multi-threaded dispatch pattern correctly.

---

### `scope_insert_with_name` Comparison

**Critical Issue in C++ (lines 497-506):**
```cpp
if (s->parent != nullptr && (s->parent->flags & ScopeFlag_Proc) != 0) {
    found = string_map_get(&s->parent->elements, key);  // NO MUTEX!
    if (found) {
        if ((*found)->flags & EntityFlag_Result) {
            if (entity != *found) {
                result = *found;
            }
            goto end;
        }
    }
}
```

The C++ multi-threaded version **does not lock the parent scope** when checking for result parameter shadowing. This appears to be a **potential race condition in the C++ code** or a performance optimization assuming the parent scope is already finalized.

**Odin multi-threaded version (scope.odin:254-266):**
```odin
if s.parent != nil && s.parent.flags & {.Proc} == {.Proc} {
    sync.rw_mutex_shared_lock(&s.parent.mutex)     // ← ADDS MUTEX
    parent_entity, parent_ok := s.parent.elements[name]
    sync.rw_mutex_shared_unlock(&s.parent.mutex)

    if parent_ok {
        if .Result in parent_entity.flags {
            if entity != parent_entity {
                return parent_entity
            }
        }
    }
}
```

**The Odin version adds mutex protection** for the parent scope read, which is arguably **more correct** than the C++ version. This is an **improvement**, not a regression, unless the C++ code relies on the lack of locking for performance reasons or has external synchronization guarantees.

---

## Recommendations

### 1. **CRITICAL: Implement Missing Functions**

Add the following to `/mnt/d/dev/checker/scope.odin`:

```odin
// add_scope associates a scope with an AST node
// C++ Reference: checker.cpp:295-315
add_scope :: proc(ctx: ^Checker_Context, node: ^ast.Node, scope: ^Scope) {
    assert(node != nil)
    assert(scope != nil)
    scope.node = node

    // This must use type assertions/switch on the Odin AST node type
    // The exact implementation depends on how Odin's ast.Node is structured
    #partial switch n in node.derived {
    case ^ast.Block_Stmt:
        n.scope = scope
    case ^ast.If_Stmt:
        n.scope = scope
    case ^ast.For_Stmt:
        n.scope = scope
    case ^ast.Range_Stmt:
        n.scope = scope
    case ^ast.Case_Clause:
        n.scope = scope
    case ^ast.Switch_Stmt:
        n.scope = scope
    case ^ast.Type_Switch_Stmt:
        n.scope = scope
    case ^ast.Proc_Type:
        n.scope = scope
    case ^ast.Struct_Type:
        n.scope = scope
    case ^ast.Union_Type:
        n.scope = scope
    case ^ast.Enum_Type:
        n.scope = scope
    case ^ast.Bit_Field_Type:
        n.scope = scope
    case:
        panic(fmt.tprintf("Invalid node kind for add_scope: %v", node.derived))
    }
}

// scope_of_node retrieves the scope associated with an AST node
// C++ Reference: checker.cpp:317-338
scope_of_node :: proc(node: ^ast.Node) -> ^Scope {
    if node == nil {
        return nil
    }

    #partial switch n in node.derived {
    case ^ast.Block_Stmt:
        return n.scope
    case ^ast.If_Stmt:
        return n.scope
    case ^ast.For_Stmt:
        return n.scope
    case ^ast.Range_Stmt:
        return n.scope
    case ^ast.Case_Clause:
        return n.scope
    case ^ast.Switch_Stmt:
        return n.scope
    case ^ast.Type_Switch_Stmt:
        return n.scope
    case ^ast.Proc_Type:
        return n.scope
    case ^ast.Struct_Type:
        return n.scope
    case ^ast.Union_Type:
        return n.scope
    case ^ast.Enum_Type:
        return n.scope
    case ^ast.Bit_Field_Type:
        return n.scope
    case:
        panic(fmt.tprintf("Invalid node kind for scope_of_node: %v", node.derived))
    }

    return nil
}

// scope_insert_no_mutex inserts entity without thread-safety checks
// C++ Reference: checker.cpp:528-531
// Only use when you're certain the context is single-threaded
scope_insert_no_mutex :: proc(s: ^Scope, entity: ^Entity) -> ^Entity {
    name := entity.token.text
    return scope_insert_with_name_no_mutex(s, name, entity)
}
```

**Note:** The exact AST node field access depends on how Odin's `core:odin/ast` structures are defined. You may need to adjust the field names (e.g., `n.scope` might need to be accessed differently).

### 2. **Consider Hash Optimization** (Optional)

If performance profiling shows scope lookups are a bottleneck, add hash parameter variants:

```odin
// Add hash parameter to lookup functions
scope_lookup_parent_hashed :: proc(s: ^Scope, name: string, hash: u32) -> (scope: ^Scope, entity: ^Entity) {
    // Pre-hash optimization - requires hash-based map implementation
    // This may require switching from map[string]^Entity to a custom hash map
    // or using Odin's intrinsics.map_cell_hash
}
```

However, Odin's built-in maps already hash strings efficiently, so this optimization may have minimal impact unless the C++ StringHashKey has special properties.

### 3. **Fix Atomic Operations in `create_scope`**

Replace plain pointer assignments with proper synchronization:

```odin
create_scope :: proc(parent: ^Scope, allocator := context.allocator) -> ^Scope {
    s := new(Scope, allocator)
    s.parent = parent
    s.elements = make(map[string]^Entity, DEFAULT_SCOPE_CAPACITY, allocator)
    s.imported = make(map[^Scope]struct{}, allocator)

    // Link as child of parent with proper synchronization
    if parent != nil {
        // Option 1: Use mutex (simpler, slightly slower)
        sync.mutex_lock(&parent.mutex)
        s.next = parent.head_child
        parent.head_child = s
        sync.mutex_unlock(&parent.mutex)

        // Option 2: Use atomic operations (matches C++ exactly)
        // Requires next and head_child to be declared as atomic.Pointer[Scope]
        // This would be more complex but matches C++ semantics exactly
    }

    return s
}
```

**Recommended:** Use Option 1 (mutex) unless profiling shows it's a bottleneck. The C++ atomic operations are likely a micro-optimization that may not be necessary in Odin.

### 4. **Fix `destroy_scope` Recursive Cleanup**

```odin
destroy_scope :: proc(s: ^Scope) {
    // Recursively destroy children
    for child := s.head_child; child != nil; child = child.next {
        destroy_scope(child)
    }

    delete(s.elements)
    delete(s.imported)
    free(s)
}
```

### 5. **Clarify `scope_lookup` Semantics**

The Odin `scope_lookup` checks imported scopes, but the C++ version does not. Determine if this is intentional:

**Option A:** Keep the current behavior if it's an enhancement
**Option B:** Match C++ exactly:

```odin
scope_lookup :: proc(s: ^Scope, name: string) -> ^Entity {
    _, entity := scope_lookup_parent(s, name)
    return entity
}
```

Then add a separate function for import-aware lookup:

```odin
scope_lookup_with_imports :: proc(s: ^Scope, name: string) -> ^Entity {
    // Current scope.odin:71-88 implementation
}
```

### 6. **Add Missing `create_scope` Features**

Complete the `create_scope` implementation:

```odin
// Global variable to track builtin package scope (set during init)
builtin_pkg_scope: ^Scope

create_scope :: proc(parent: ^Scope, allocator := context.allocator) -> ^Scope {
    s := new(Scope, allocator)
    s.parent = parent
    s.elements = make(map[string]^Entity, DEFAULT_SCOPE_CAPACITY, allocator)
    s.imported = make(map[^Scope]struct{}, allocator)

    // Link as child of parent (except for builtin_pkg->scope)
    if parent != nil && parent != builtin_pkg_scope {
        sync.mutex_lock(&parent.mutex)  // Or use atomics
        s.next = parent.head_child
        parent.head_child = s
        sync.mutex_unlock(&parent.mutex)
    }

    // Propagate ContextDefined flag
    if parent != nil && .Context_Defined in parent.flags {
        s.flags += {.Context_Defined}
    }

    return s
}
```

---

## Testing Recommendations

1. **Compilation Test:** Verify that `check_poly_proc.odin` compiles after adding `add_scope`
2. **Scope Chain Test:** Verify parent-child linkage works correctly with concurrent scope creation
3. **Boundary Crossing Test:** Test label and variable lookup across proc boundaries
4. **Result Shadowing Test:** Verify result parameters cannot be shadowed
5. **Import Test:** Verify imported scope lookup works correctly
6. **Recursive Destroy Test:** Ensure all child scopes are properly cleaned up

---

## Conclusion

The Odin scope implementation demonstrates a solid understanding of the core scope semantics and threading model, with excellent documentation. However, it is **incomplete and will not build** due to missing utility functions that are actively used in other parts of the codebase.

### Priority Actions:
1. **IMMEDIATE:** Implement `add_scope` to fix build failure
2. **HIGH:** Implement `scope_of_node` for completeness
3. **MEDIUM:** Add `scope_insert_no_mutex` for explicit control
4. **MEDIUM:** Fix `destroy_scope` recursive cleanup
5. **LOW:** Add atomic operations or mutex protection to `create_scope`
6. **LOW:** Clarify `scope_lookup` semantics vs. C++

Once these issues are addressed, the scope implementation will be functionally equivalent to the C++ version with proper Odin idioms.
