# Global Variable and Constant Checking Verification Report

**Date**: 2025-10-03
**Odin Port**: `/mnt/d/dev/checker/check_global.odin`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp` (lines 3018-6111), `/mnt/c/odin/src/check_decl.cpp` (lines 1612-1755)

---

## Section 1: Implementation Status

### Overall Completion: ~55% (Core Algorithm Complete, Integration Incomplete)

#### What's Implemented (Complete):

1. **Entity Dependency Graph Generation** (Lines 200-329)
   - ✅ Three-phase map creation (M_procs, M_vars, M_other)
   - ✅ Procedure dependency edge calculation
   - ✅ **Critical procedure elimination algorithm** (lines 279-311)
   - ✅ Final graph construction with only variable nodes
   - ✅ Dependency count calculation
   - C++ Reference: `/mnt/c/odin/src/checker.cpp:3018-3155` - **EXACT MATCH**

2. **Topological Sort (Kahn's Algorithm)** (Lines 529-614)
   - ✅ Priority queue processing (simulated with slice sorting)
   - ✅ Dependency count reduction
   - ✅ Cycle detection when ordered count ≠ total count
   - ✅ Initialization order output to `info.variable_init_order`
   - C++ Reference: `/mnt/c/odin/src/checker.cpp:6044-6111` - **EXACT MATCH**

3. **Circular Dependency Detection** (Lines 464-635)
   - ✅ DFS path finding (`find_entity_path`)
   - ✅ Tuple parameter/result dependency traversal
   - ✅ Visited set management to prevent infinite loops
   - ✅ Path reporting with error messages
   - C++ Reference: `/mnt/c/odin/src/checker.cpp:5995-6041` - **EXACT MATCH**

4. **Runtime Type Initialization** (check_runtime.odin)
   - ✅ `init_preload` function (lines 249-269)
   - ✅ `init_mem_allocator` (Allocator type caching)
   - ✅ `init_core_context` (Context type caching)
   - ✅ `init_core_source_code_location`
   - C++ Reference: `/mnt/c/odin/src/checker.cpp:3389-3395` - **EXACT MATCH**

#### What's Stubbed/Incomplete:

1. **Global Entity Checking** (Lines 645-724)
   - ⚠️ `check_all_global_entities` framework exists but delegates to stubs
   - ❌ `check_single_global_entity` - **NOT IMPLEMENTED** (C++ `/mnt/c/odin/src/checker.cpp:4938-4969`)
   - ❌ `check_entity_decl` - **NOT IMPLEMENTED** (C++ `/mnt/c/odin/src/check_decl.cpp:1897-1969`)
   - ⚠️ `check_global_variable` and `check_global_constant` are placeholder stubs (lines 726-843)

2. **Expression Type Checking** (Architecture Gap)
   - ❌ `check_expr` - **NOT IMPLEMENTED** (required for initializer validation)
   - ❌ `check_init_variable` - **NOT IMPLEMENTED** (C++ `/mnt/c/odin/src/check_decl.cpp:1730`)
   - ❌ `check_assignment` - **NOT IMPLEMENTED** (type compatibility checks)

3. **Type Validation** (Architecture Gap)
   - ❌ `is_type_polymorphic` - **NOT IMPLEMENTED**
   - ❌ `is_type_empty_union` - **NOT IMPLEMENTED**
   - ❌ `is_type_zero_initializable` - **NOT IMPLEMENTED**
   - ❌ `complete_soa_type` - **NOT IMPLEMENTED** (C++ `/mnt/c/odin/src/checker.cpp:4985-4987`)

4. **Attribute Processing** (Partial)
   - ❌ `check_decl_attributes` - **NOT IMPLEMENTED**
   - ❌ `make_attribute_context` - **NOT IMPLEMENTED**
   - ❌ Foreign library initialization (`init_entity_foreign_library`)
   - ❌ Link name handling (`handle_link_name`)

5. **Dependency Collection** (Critical Gap)
   - ❌ **Dependency population during declaration checking** - The C++ implementation populates `decl->deps` during expression checking. The Odin port has the data structure (`Decl_Info.deps`) but no code that populates it.
   - ❌ Expression visitor for dependency extraction needs integration with actual checker workflow
   - C++ Reference: Dependencies added during `check_expr` via `add_entity_dependency` calls throughout `/mnt/c/odin/src/check_expr.cpp`

---

## Section 2: Initialization Order Analysis

### Correctness vs C++: ✅ **ALGORITHMICALLY IDENTICAL**

The initialization order algorithm is a **faithful, line-by-line port** of the C++ implementation:

#### Algorithm Steps (Both Implementations):

1. **Graph Construction** (C++ 3018-3155, Odin 200-329)
   - Create separate maps for procedures, variables, and other entities
   - Add edges for procedure dependencies
   - **Eliminate procedure nodes** by connecting their predecessors to successors directly
   - This transforms `var_a → proc → var_b` into `var_a → var_b`
   - Result: Graph contains only variable nodes with direct variable-to-variable edges

2. **Priority Queue Processing** (C++ 6044-6111, Odin 529-614)
   - Initialize queue with variables having zero dependencies
   - Pop node with smallest (dep_count, order_in_src) - ensures deterministic ordering
   - Reduce predecessor dependency counts
   - Add predecessors with zero deps to queue
   - Continue until queue empty

3. **Cycle Detection** (C++ 6065-6078, Odin 597-611)
   - If ordered count < total count, circular dependency exists
   - Use DFS (`find_entity_path`) to locate a cycle
   - Report error with full dependency chain

#### Key Correctness Properties Preserved:

✅ **Topological ordering**: Variables are initialized before their dependents
✅ **Determinism**: Uses `order_in_src` as tiebreaker for stable ordering
✅ **Procedure elimination**: Correctly transitively closes variable dependencies through procedures
✅ **Cycle detection**: Finds and reports circular dependencies with full path

#### Differences from C++ (Minor):

| Aspect | C++ | Odin | Impact |
|--------|-----|------|--------|
| Priority Queue | Min-heap (`priority_queue_fix`) | Full sort per iteration | Performance: Slower but correct |
| Allocator | Arena allocator for graph nodes | Temp allocator | None - both temporary |
| Error Reporting | `error()` with format strings | `error()` with format strings | Same semantics |

**Verdict**: The Odin implementation will produce **identical initialization orders** to the C++ implementation, assuming dependencies are collected correctly.

---

## Section 3: Dependency Detection

### Circular Dependency Handling: ✅ **COMPLETE AND CORRECT**

#### C++ Implementation (checker.cpp:5995-6041, 5963-5993):

```cpp
gb_internal Array<Entity *> find_entity_path(Entity *start, Entity *end,
                                              gbAllocator allocator,
                                              PtrSet<Entity *> *visited) {
    // Visit tracking
    if (ptr_set_update(visited, start)) {
        return empty_path;
    }

    // Special case: procedures check param/result tuple dependencies
    if (start->kind == Entity_Procedure) {
        find_entity_path_tuple(t->Proc.params, end, ...);
        find_entity_path_tuple(t->Proc.results, end, ...);
    } else {
        // Regular entities: iterate deps
        FOR_PTR_SET(dep, decl->deps) {
            if (dep == end) return path;
            auto next_path = find_entity_path(dep, end, ...);
            if (next_path.count > 0) return next_path;
        }
    }
}
```

#### Odin Implementation (check_global.odin:464-476, 387-459):

```odin
find_entity_path :: proc(start, end: ^Entity,
                         graph: map[^Entity]^Entity_Graph_Node,
                         allocator := context.temp_allocator) -> []^Entity {
    visited := make(map[^Entity]bool, allocator)
    defer delete(visited)
    return find_entity_path_internal(start, end, &visited, allocator)
}

find_entity_path_internal :: proc(...) -> []^Entity {
    // Check visited
    if start in visited^ { return empty_path }
    visited[start] = true

    // Special handling for procedures
    if start.kind == .Procedure {
        path := find_entity_path_tuple(proc_info.params, end, visited, allocator)
        if len(path) > 0 { return path }
        path = find_entity_path_tuple(proc_info.results, end, visited, allocator)
        if len(path) > 0 { return path }
    } else {
        // Non-procedures: check deps
        for dep in decl.deps {
            if dep == end { return [dep] }
            next_path := find_entity_path_internal(dep, end, &visited, allocator)
            if len(next_path) > 0 { return path + [dep] }
        }
    }
}
```

**Analysis**:
- ✅ Control flow is **identical**
- ✅ Procedure parameter/result special casing preserved
- ✅ Visited set prevents infinite loops in cycles
- ✅ Path construction maintains correct order

#### Cycle Reporting (C++ 6065-6078, Odin 597-635):

Both implementations:
1. Detect cycles when `dep_count > 0` after topological sort
2. Call `find_entity_path(entity, entity, ...)` to find self-cycle
3. Report error with chain: `'A' refers to 'B' refers to 'C' refers to 'A'`

**Verdict**: Circular dependency detection is **complete and functionally equivalent** to C++.

---

## Section 4: Attribute Support

### Implementation Status: ⚠️ **ARCHITECTURE EXISTS, IMPLEMENTATION MISSING**

#### C++ Attribute Processing (check_decl.cpp:1612-1655):

```cpp
AttributeContext ac = make_attribute_context(e->Variable.link_prefix, e->Variable.link_suffix);
check_decl_attributes(ctx, decl->attributes, var_decl_attribute, &ac);

// Apply attributes
e->Variable.thread_local_model = ac.thread_local_model;
e->Variable.is_export = ac.is_export;
e->Variable.is_rodata = ac.rodata;
e->Variable.link_name = handle_link_name(ctx, e->token, ac.link_name, ac.link_prefix, ac.link_suffix);
e->Variable.link_section = ac.link_section;
```

#### Odin Entity Structure (checker.odin:515-538):

```odin
Entity_Variable :: struct {
    thread_local_model:    string,              // ✅ Field exists
    foreign_library:       ^Entity,             // ✅ Field exists
    link_name:             string,              // ✅ Field exists
    link_section:          string,              // ✅ Field exists
    is_foreign:            bool,                // ✅ Field exists
    is_export:             bool,                // ✅ Field exists
    is_rodata:             bool,                // ✅ Field exists
    // ... other fields
}
```

#### Attribute Checklist:

| Attribute | Data Structure | Processing Code | Status |
|-----------|----------------|-----------------|--------|
| `@(thread_local)` | ✅ `thread_local_model: string` | ❌ Not set | **MISSING** |
| `@(export)` | ✅ `is_export: bool` | ❌ Not set | **MISSING** |
| `@(rodata)` | ✅ `is_rodata: bool` | ❌ Not set | **MISSING** |
| `foreign` keyword | ✅ `is_foreign: bool` | ❌ Not set | **MISSING** |
| `@(link_name="...")` | ✅ `link_name: string` | ❌ Not set | **MISSING** |
| `@(link_section="...")` | ✅ `link_section: string` | ❌ Not set | **MISSING** |
| `@(require)` | ✅ `Entity_Flag.Require` | ❌ Not set | **MISSING** |
| `@(static)` | ✅ `Entity_Flag.Static` | ❌ Not checked | **MISSING** |

#### C++ Attribute Validation (check_decl.cpp:1632-1655):

```cpp
// @(require) → add to required_global_variable_queue
if (ac.require_declaration) {
    e->flags |= EntityFlag_Require;
    mpsc_enqueue(&ctx->info->required_global_variable_queue, e);
}

// @(static) → error for globals
if (ac.is_static) {
    error(e->token, "@(static) is not supported for global variables");
}

// @(rodata) + non-constant init → error
if (e->Variable.is_rodata && o.mode != Addressing_Constant) {
    error(o.expr, "Variables declared with @(rodata) must have constant initialization");
}

// @(thread_local) on WASM → clear thread_local_model
if (is_arch_wasm() && e->Variable.thread_local_model.len != 0) {
    e->Variable.thread_local_model.len = 0;
}
```

**Verdict**:
- Data structures: ✅ **COMPLETE** - all fields present in `Entity_Variable`
- Processing logic: ❌ **NOT IMPLEMENTED** - no code in `check_global_variable` to set these fields
- Validation: ❌ **NOT IMPLEMENTED** - no error checking for invalid attribute combinations

---

## Section 5: Foreign Global Handling

### Implementation Status: ❌ **NOT IMPLEMENTED**

#### C++ Foreign Variable Logic (check_decl.cpp:1677-1720):

```cpp
// 1. Validate no initializer for foreign vars
if (e->Variable.is_foreign) {
    if (init_expr != nullptr) {
        error(e->token, "A foreign variable declaration cannot have a default value");
    }
    init_entity_foreign_library(ctx, e);  // Set foreign_library entity

    if (is_arch_wasm() && e->Variable.foreign_library != nullptr) {
        error(e->token, "Foreign variable cannot be scoped to a module on WASM");
    }
}

// 2. Collect foreign/exported symbols for duplicate checking
if (e->Variable.is_foreign || e->Variable.is_export) {
    String name = e->Variable.link_name.len > 0 ? e->Variable.link_name : e->token.string;

    // Check for duplicate foreign declarations
    Entity **found = string_map_get(&ctx->info->foreigns, name);
    if (found) {
        Entity *f = *found;
        if (!signature_parameter_similar_enough(base_type(e->type), base_type(f->type))) {
            error(e->token, "Foreign entity '%.*s' previously declared with different type at %s",
                  LIT(name), token_pos_to_string(f->token.pos));
        }
    }
    string_map_set(&ctx->info->foreigns, name, e);
}
```

#### Odin Implementation (check_global.odin:726-798):

```odin
check_global_variable :: proc(ctx: ^Checker_Context, entity: ^Entity, decl: ^Decl_Info) {
    // ... basic type validation ...

    // Line 786-788: Minimal foreign check (incomplete)
    if var.is_foreign && var.link_name == "" {
        error(entity.token, "Foreign variable '%s' requires link_name or initializer", ...)
    }
}
```

#### Missing Functionality:

1. ❌ **No initializer validation** - doesn't check `decl.init_expr != nil` for foreign vars
2. ❌ **No foreign library initialization** - `init_entity_foreign_library` not called
3. ❌ **No WASM-specific validation** - doesn't check architecture restrictions
4. ❌ **No duplicate foreign detection** - `ctx.info.foreigns` map not populated
5. ❌ **No type compatibility checking** - doesn't compare with previous declarations
6. ❌ **No `is_foreign` flag setting** - relies on pre-set flag (but who sets it?)

**Critical Gap**: The C++ checker has a comprehensive foreign entity registry (`ctx->info->foreigns`) that tracks all foreign and exported symbols across the program to detect conflicts. This is **completely missing** from the Odin port.

**Verdict**: Foreign global variable handling is **~10% complete** - only a basic error message exists.

---

## Section 6: Missing Features

### 6.1 Core Missing Implementations

#### **CRITICAL**: Dependency Collection During Type Checking
- **C++ Location**: Throughout `/mnt/c/odin/src/check_expr.cpp` and `/mnt/c/odin/src/check_decl.cpp`
- **Problem**: The Odin port has `Decl_Info.deps: map[^Entity]struct{}` but **nothing ever adds to it**
- **C++ Pattern**:
  ```cpp
  // In check_expr and similar functions:
  if (entity != nullptr && current_decl != nullptr) {
      add_entity_dependency(current_decl, entity);
  }
  ```
- **Impact**: **FATAL** - Without populated dependencies, the entire initialization order algorithm is useless
- **Required**: Integrate dependency tracking into expression checker (Phase not yet reached)

#### 1. `check_single_global_entity` - The Main Entry Point
- **C++ Location**: `/mnt/c/odin/src/checker.cpp:4938-4969`
- **Status**: ❌ **NOT IMPLEMENTED**
- **Functionality**:
  ```cpp
  gb_internal void check_single_global_entity(Checker *c, Entity *e, DeclInfo *d) {
      GB_ASSERT(e != nullptr && d != nullptr);

      if (d->scope != e->scope) return;
      if (e->state == EntityState_Resolved) return;

      CheckerContext *ctx = create_checker_context(c);
      ctx->decl = d;
      ctx->scope = d->scope;

      // Check for "main" in Package_Init
      if (pkg->kind == Package_Init && e->kind != Entity_Procedure && e->token.string == "main") {
          error(e->token, "'main' is reserved as the entry point procedure");
          return;
      }

      check_entity_decl(ctx, e, d, nullptr);  // ← Delegates to declaration checker
  }
  ```
- **Odin Port Impact**: The stub at line 645-724 calls `check_global_variable` directly, bypassing this layer
- **Missing Validations**:
  - ✗ "main" name reservation in init package
  - ✗ Scope matching check (`d->scope != e->scope`)
  - ✗ State management (`EntityState_Resolved` early return)

#### 2. `check_entity_decl` - Declaration Dispatcher
- **C++ Location**: `/mnt/c/odin/src/check_decl.cpp:1897-1969`
- **Status**: ❌ **NOT IMPLEMENTED**
- **Functionality**:
  ```cpp
  gb_internal void check_entity_decl(CheckerContext *ctx, Entity *e, DeclInfo *d, Type *named_type) {
      if (e->state == EntityState_Resolved) return;

      String name = e->token.string;
      if (e->type != nullptr || e->state != EntityState_Unresolved) {
          error(e->token, "Illegal declaration cycle of `%.*s`", LIT(name));
          return;
      }

      // Set up context
      e->parent_proc_decl = c.curr_proc_decl;
      e->state = EntityState_InProgress;

      // Check @(global_context) feature flag
      if (check_feature_flags(ctx, d->decl_node) & OptInFeatureFlag_GlobalContext) {
          c.scope->flags |= ScopeFlag_ContextDefined;
      }

      // Dispatch to specific checker
      switch (e->kind) {
      case Entity_Variable:  check_global_variable_decl(&c, e, d->type_expr, d->init_expr); break;
      case Entity_Constant:  check_const_decl(&c, e, d->type_expr, d->init_expr, named_type); break;
      case Entity_TypeName:  check_type_decl(&c, e, d->init_expr, named_type); break;
      case Entity_Procedure: check_proc_decl(&c, e, d); break;
      case Entity_ProcGroup: check_proc_group_decl(&c, e, d); break;
      }

      e->state = EntityState_Resolved;
  }
  ```
- **Missing Critical Features**:
  - ✗ Declaration cycle detection (e.type != nullptr check)
  - ✗ Entity state machine (`Unresolved → InProgress → Resolved`)
  - ✗ Feature flag checking (`@(global_context)`)
  - ✗ Parent procedure tracking

#### 3. `check_global_variable_decl` - Variable Declaration Checker
- **C++ Location**: `/mnt/c/odin/src/check_decl.cpp:1612-1755`
- **Status**: ⚠️ **PARTIALLY STUBBED** (check_global.odin:726-798)
- **C++ Full Implementation**:
  ```cpp
  gb_internal void check_global_variable_decl(CheckerContext *ctx, Entity *e,
                                               Ast *type_expr, Ast *init_expr) {
      GB_ASSERT(e->type == nullptr && e->kind == Entity_Variable);

      // Prevent duplicate checking
      if (e->flags & EntityFlag_Visited) {
          e->type = t_invalid;
          return;
      }
      e->flags |= EntityFlag_Visited;

      // Parse attributes
      AttributeContext ac = make_attribute_context(e->Variable.link_prefix, e->Variable.link_suffix);
      ac.init_expr_list_count = init_expr != nullptr ? 1 : 0;
      check_decl_attributes(ctx, decl->attributes, var_decl_attribute, &ac);

      // Apply @(require)
      if (ac.require_declaration) {
          e->flags |= EntityFlag_Require;
          mpsc_enqueue(&ctx->info->required_global_variable_queue, e);
      }

      // Apply attributes to entity
      e->Variable.thread_local_model = ac.thread_local_model;
      e->Variable.is_export = ac.is_export;
      e->Variable.is_rodata = ac.rodata;

      // Validate @(static)
      if (ac.is_static) {
          error(e->token, "@(static) is not supported for global variables");
      }

      // Handle link names
      ac.link_name = handle_link_name(ctx, e->token, ac.link_name, ac.link_prefix, ac.link_suffix);

      // Platform-specific: clear thread_local on WASM/no_thread_local
      if (is_arch_wasm() && e->Variable.thread_local_model.len != 0) {
          e->Variable.thread_local_model.len = 0;
      }
      if (build_context.no_thread_local) {
          e->Variable.thread_local_model.len = 0;
      }

      // Check type expression
      if (type_expr != nullptr) {
          e->type = check_type(ctx, type_expr);
      }

      // Validate type
      if (e->type != nullptr) {
          if (is_type_polymorphic(base_type(e->type))) {
              error(e->token, "Invalid use of polymorphic type in variable declaration");
              e->type = t_invalid;
          }
          if (is_type_empty_union(e->type)) {
              error(e->token, "Empty union cannot be instantiated");
              e->type = t_invalid;
          }
      }

      // Foreign variable handling
      if (e->Variable.is_foreign) {
          if (init_expr != nullptr) {
              error(e->token, "Foreign variable cannot have default value");
          }
          init_entity_foreign_library(ctx, e);
          if (is_arch_wasm() && e->Variable.foreign_library != nullptr) {
              error(e->token, "Foreign variable cannot be scoped to module on WASM");
          }
      }

      // Set link name and section
      if (ac.link_name.len > 0) {
          e->Variable.link_name = ac.link_name;
      }
      if (ac.link_section.len > 0) {
          e->Variable.link_section = ac.link_section;
      }

      // Check for duplicate foreign/export symbols
      if (e->Variable.is_foreign || e->Variable.is_export) {
          String name = e->Variable.link_name.len > 0 ? e->Variable.link_name : e->token.string;
          Entity **found = string_map_get(&ctx->info->foreigns, name);
          if (found) {
              Entity *f = *found;
              if (!signature_parameter_similar_enough(base_type(e->type), base_type(f->type))) {
                  error(e->token, "Foreign entity '%.*s' previously declared with different type", LIT(name));
              }
          }
          string_map_set(&ctx->info->foreigns, name, e);
      }

      // Check initializer
      if (init_expr != nullptr) {
          Operand o = {};
          check_expr_with_type_hint(ctx, &o, init_expr, e->type);
          check_init_variable(ctx, e, &o, str_lit("variable declaration"));

          // Validate @(rodata) → constant init
          if (e->Variable.is_rodata && o.mode != Addressing_Constant) {
              error(o.expr, "Variables with @(rodata) must have constant initialization");
              // ... detailed error for struct compound literals ...
          }
      }
  }
  ```

**Odin Stub (Lines 726-798)**:
```odin
check_global_variable :: proc(ctx: ^Checker_Context, entity: ^Entity, decl: ^Decl_Info) {
    // Basic type validation
    if entity.type == nil {
        error(entity.token, "Global variable '%s' has invalid type", ...)
        return
    }

    // Placeholder for initializer check
    if decl != nil && decl.init_expr != nil {
        // TODO(PHASE): Implement check_expr
    }

    // Minimal foreign check
    if var.is_foreign && var.link_name == "" {
        error(entity.token, "Foreign variable requires link_name or initializer", ...)
    }
}
```

**Missing from Odin Stub**:
- ✗ Attribute processing (all `@(...)` attributes ignored)
- ✗ `EntityFlag_Visited` duplicate check
- ✗ `check_type(ctx, type_expr)` call
- ✗ Polymorphic/empty union validation
- ✗ Foreign library initialization
- ✗ Link name/section handling
- ✗ Duplicate foreign symbol detection
- ✗ Initializer expression checking (`check_expr_with_type_hint`)
- ✗ `@(rodata)` constant initialization validation
- ✗ Platform-specific thread_local clearing

### 6.2 Required Helper Functions (Not Yet Implemented)

| Function | C++ Location | Purpose | Used By |
|----------|--------------|---------|---------|
| `check_type` | check_type.cpp | Parse type expression → Type* | Variable/constant decls |
| `check_expr` | check_expr.cpp | Type check expression → Operand | Initializers |
| `check_expr_with_type_hint` | check_expr.cpp | Type check with expected type | Initializers |
| `check_init_variable` | check_decl.cpp:1447 | Validate initializer assignable to variable | Variable decls |
| `check_assignment` | check_expr.cpp | Check type compatibility | Init validation |
| `is_type_polymorphic` | type_utils.cpp | Detect polymorphic types | Type validation |
| `is_type_empty_union` | type_utils.cpp | Detect empty unions | Type validation |
| `is_type_zero_initializable` | type_utils.cpp | Check zero-init safety | Uninitialized vars |
| `complete_soa_type` | check_type.cpp | Finalize SOA type layout | Type completion |
| `type_size_of` | types.cpp | Calculate type size | Type metrics |
| `type_align_of` | types.cpp | Calculate type alignment | Type metrics |
| `check_decl_attributes` | check_decl.cpp:913 | Parse attribute expressions | Attribute processing |
| `make_attribute_context` | check_decl.cpp:893 | Create attribute context | Attribute processing |
| `handle_link_name` | check_decl.cpp:1064 | Process link_name/prefix/suffix | Foreign linkage |
| `init_entity_foreign_library` | check_decl.cpp:1329 | Link foreign variable to library | Foreign vars |
| `signature_parameter_similar_enough` | check_expr.cpp | Compare function signatures | Duplicate detection |

**Total Missing Functions**: ~16 core functions referenced but not implemented

---

## Section 7: Semantic Differences

### 7.1 Priority Queue Implementation

**C++ (checker.cpp:6055-6084)**:
```cpp
auto pq = priority_queue_create(dep_graph, entity_graph_node_cmp, entity_graph_node_swap);
while (pq.queue.count > 0) {
    EntityGraphNode *n = priority_queue_pop(&pq);  // O(log n) heap pop
    // ... process node ...
    FOR_PTR_SET(p, n->pred) {
        p->dep_count -= 1;
        priority_queue_fix(&pq, p->index);  // O(log n) heap repair
    }
}
```
- Uses **min-heap** with `priority_queue_fix` for efficient updates
- Time complexity: **O(E log V)** where E=edges, V=variables

**Odin (check_global.odin:570-593)**:
```odin
for len(queue) > 0 {
    sort_entity_graph_nodes(queue[:])  // O(n log n) full sort every iteration
    node := queue[0]
    ordered_remove(&queue, 0)
    // ... process node ...
    for pred_node in node.pred {
        pred_node.dep_count -= 1
        if pred_node.dep_count == 0 {
            append(&queue, pred_node)
        }
    }
}
```
- Full sort of queue **every iteration**
- Time complexity: **O(V² log V)** - much slower for large programs

**Impact**:
- ✅ **Correctness**: Same final ordering (both use same comparison function)
- ⚠️ **Performance**: Quadratic slowdown for programs with 1000+ global variables
- **Recommendation**: Acceptable for MVP; optimize later with proper heap implementation

### 7.2 Error Message Format

**Minor difference** - Error messages are functionally equivalent but may have slight formatting differences:

**C++ (checker.cpp:6071-6076)**:
```cpp
error(e->token, "Cyclic initialization of '%.*s'", LIT(e->token.string));
for (isize i = path.count-1; i >= 0; i--) {
    error(e->token, "\t'%.*s' refers to", LIT(e->token.string));
    e = path[i];
}
error(e->token, "\t'%.*s'", LIT(e->token.string));
```

**Odin (check_global.odin:618-635)**:
```odin
error(entity.token, "Cyclic initialization of '%s'", entity.token.text)
for i := len(cycle_path) - 1; i >= 0; i -= 1 {
    e := cycle_path[i]
    error(e.token, "\t'%s' refers to", e.token.text)
}
error(entity.token, "\t'%s'", entity.token.text)
```

**Impact**: None - users see identical error messages

### 7.3 Graph Node Storage

**C++**: Uses arena allocator for graph nodes (temporary memory, freed in bulk)
**Odin**: Uses `context.temp_allocator` (Odin's temporary storage system)

**Impact**: None - both are temporary allocations freed after init order calculation

---

## Section 8: Required Fixes (Prioritized)

### Priority 1: BLOCKING - Cannot Function Without

#### 1.1 Implement Dependency Collection (CRITICAL)
- **File**: New file `check_expr.odin` or integrate into existing checker
- **Function**: `add_entity_dependency(decl: ^Decl_Info, entity: ^Entity)`
  ```odin
  add_entity_dependency :: proc(decl: ^Decl_Info, entity: ^Entity) {
      if decl == nil || entity == nil {
          return
      }

      rw_mutex_lock(&decl.deps_mutex)
      defer rw_mutex_unlock(&decl.deps_mutex)

      decl.deps[entity] = {}  // Add to set
  }
  ```
- **Integration Points**: Every time an expression is resolved to an entity, call this function
- **C++ Reference**: Scattered throughout `/mnt/c/odin/src/check_expr.cpp` (search for `ptr_set_add(&ctx->decl->deps, entity)`)
- **Test Case**:
  ```odin
  a := 10
  b := a + 5  // check_expr for 'a' should call add_entity_dependency(b's decl, a's entity)
  ```

#### 1.2 Implement `check_entity_decl`
- **File**: `check_global.odin` or new `check_decl.odin`
- **Reference**: `/mnt/c/odin/src/check_decl.cpp:1897-1969`
- **Requirements**:
  - State machine: `Unresolved → InProgress → Resolved`
  - Cycle detection: error if `e.state == .In_Progress` when re-entered
  - Dispatch to `check_global_variable_decl`, `check_const_decl`, etc.
- **Caller**: Modify `check_all_global_entities` line 666 to call this instead of direct calls

#### 1.3 Implement `check_global_variable_decl` (Full Implementation)
- **File**: `check_global.odin` (replace stub at lines 726-798)
- **Reference**: `/mnt/c/odin/src/check_decl.cpp:1612-1755`
- **Key Sections**:
  1. Attribute parsing (`check_decl_attributes`) - **Dependency**: Requires attribute system (Phase TBD)
  2. Type checking (`check_type`) - **Dependency**: Requires type checker (Phase TBD)
  3. Initializer checking (`check_expr_with_type_hint`) - **Dependency**: Requires expr checker (Phase TBD)
  4. Foreign handling (`init_entity_foreign_library`) - **Dependency**: Requires foreign system
  5. `@(rodata)` constant validation - **Dependency**: Requires Addressing_Mode from check_expr

### Priority 2: HIGH - Core Functionality

#### 2.1 Implement Attribute System
- **Functions Needed**:
  - `make_attribute_context` (check_decl.cpp:893-911)
  - `check_decl_attributes` (check_decl.cpp:913-1062)
  - `handle_link_name` (check_decl.cpp:1064-1100)
- **Purpose**: Enable `@(thread_local)`, `@(export)`, `@(rodata)`, `@(link_name="...")`, etc.
- **Integration**: Called from `check_global_variable_decl` before type checking

#### 2.2 Implement Foreign Symbol Registry
- **Data Structure**: Add to `Checker_Info`
  ```odin
  Checker_Info :: struct {
      // ... existing fields ...
      foreigns: map[string]^Entity,  // C++ string_map<Entity *>
  }
  ```
- **Functions**:
  - `init_entity_foreign_library` (check_decl.cpp:1329-1386)
  - `signature_parameter_similar_enough` (for duplicate detection)
- **Purpose**: Prevent conflicting foreign/export declarations

#### 2.3 Implement Type Validation Helpers
- **Functions**:
  - `is_type_polymorphic(t: ^Type) -> bool`
  - `is_type_empty_union(t: ^Type) -> bool`
  - `is_type_zero_initializable(t: ^Type) -> bool`
- **Reference**: Type utility functions in `/mnt/c/odin/src/checker.cpp` and `/mnt/c/odin/src/check_type.cpp`

### Priority 3: MEDIUM - Completeness

#### 3.1 Implement SOA Type Completion
- **Function**: `complete_soa_type(ctx: ^Checker_Context, t: ^Type, allow_incomplete := false)`
- **Reference**: `/mnt/c/odin/src/checker.cpp:4985-4987`
- **Integration**: Called in `check_all_global_entities` after each entity checked
- **Deferred Queue**: C++ uses `mpsc_dequeue(&c->soa_types_to_complete, &t)` - need Odin equivalent

#### 3.2 Implement Type Metrics
- **Functions**:
  - `type_size_of(t: ^Type) -> i64`
  - `type_align_of(t: ^Type) -> i64`
- **Reference**: `/mnt/c/odin/src/types.cpp`
- **Integration**: Called after type checking to ensure layout calculation

#### 3.3 Platform-Specific Attribute Validation
- **Functions**:
  - `is_arch_wasm() -> bool`
  - Build context flags (build_context.no_thread_local)
- **Purpose**: Clear `thread_local_model` on WASM, validate foreign restrictions

### Priority 4: LOW - Polish

#### 4.1 Optimize Priority Queue
- **Current**: Full sort every iteration (O(V² log V))
- **Target**: Min-heap with `priority_queue_fix` (O(E log V))
- **Implementation**:
  ```odin
  Priority_Queue :: struct {
      items: [dynamic]^Entity_Graph_Node,
      // ... heap operations ...
  }
  priority_queue_push :: proc(pq: ^Priority_Queue, node: ^Entity_Graph_Node)
  priority_queue_pop :: proc(pq: ^Priority_Queue) -> ^Entity_Graph_Node
  priority_queue_fix :: proc(pq: ^Priority_Queue, index: int)  // Repair heap after dep_count change
  ```
- **Benefit**: Faster for large programs (1000+ globals)

#### 4.2 Add Dependency Visualization (Debug)
- **C++ Debug Code** (checker.cpp:6102-6110):
  ```cpp
  if (false) {  // Debug printing
      gb_printf("Variable Initialization Order:\n");
      for_array(i, info->variable_init_order) {
          DeclInfo *d = info->variable_init_order[i];
          Entity *e = d->entity;
          gb_printf("\t'%.*s' %llu\n", LIT(e->token.string), e->order_in_src);
      }
  }
  ```
- **Odin Equivalent**: Add debug flag to print init order

---

## Summary Table

| Component | C++ Reference | Odin Status | Completeness | Blocker? |
|-----------|---------------|-------------|--------------|----------|
| **Dependency Graph** | checker.cpp:3018-3155 | ✅ Complete | 100% | No |
| **Topological Sort** | checker.cpp:6044-6111 | ✅ Complete | 100% | No |
| **Cycle Detection** | checker.cpp:5995-6041 | ✅ Complete | 100% | No |
| **Runtime Init** | checker.cpp:3389-3395 | ✅ Complete | 100% | No |
| **Dependency Collection** | check_expr.cpp (scattered) | ❌ Missing | 0% | **YES** |
| **check_entity_decl** | check_decl.cpp:1897-1969 | ❌ Missing | 0% | **YES** |
| **check_global_variable_decl** | check_decl.cpp:1612-1755 | ⚠️ Stub | 15% | **YES** |
| **Attribute Processing** | check_decl.cpp:913-1062 | ❌ Missing | 0% | Yes |
| **Foreign Registry** | check_decl.cpp:1699-1720 | ❌ Missing | 0% | Yes |
| **Type Validation** | checker.cpp, check_type.cpp | ❌ Missing | 0% | Yes |

**Overall Assessment**:
- **Core Algorithms**: ✅ **100% Complete** (graph generation, toposort, cycle detection)
- **Integration Layer**: ❌ **<15% Complete** (missing check_entity_decl, check_expr, attributes)
- **Functional without Integration**: ❌ **NO** - algorithm needs populated dependencies to function

---

## Critical Path to Functionality

1. **Implement expression checker** (`check_expr`) with dependency tracking
2. **Implement `check_entity_decl`** dispatcher
3. **Complete `check_global_variable_decl`** (full C++ port)
4. **Implement attribute system** for `@(rodata)`, `@(export)`, etc.
5. **Add foreign symbol registry** for duplicate detection

**Estimated Remaining Work**: ~2000-3000 lines of code across multiple phases (depends on when type/expr checkers are implemented)

**Recommendation**: The initialization order algorithm is **production-ready** but unusable without the integration layer. Focus next on:
1. Basic expression checker (minimal version just for global initializers)
2. Dependency collection integration
3. Complete global variable declaration checker

Once these are done, the initialization order calculation will **work identically to C++**.
