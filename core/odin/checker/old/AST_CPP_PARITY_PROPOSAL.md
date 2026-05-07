# AST C++ Parity Proposal

## Overview

This document shows what `/mnt/c/odin/core/odin/ast/ast.odin` would look like if we fully matched the C++ implementation's architecture, where all semantic and checker metadata is stored directly on AST structs.

## Current State vs Proposed Changes

### Node (Base AST Type)

**Current**:
```odin
Node :: struct {
	pos:         tokenizer.Pos,
	end:         tokenizer.Pos,
	state_flags: Node_State_Flags,
	derived:     Any_Node,

	// Semantic Analysis Fields
	viral_state_flags: Node_Viral_State_Flags,  // ✅ Already matches C++
	file_id:           i32,                      // ✅ Already matches C++
	tav:               ^Type_And_Value,          // ❌ C++ uses value, not pointer!
}
```

**Proposed** (C++ Parity):
```odin
Node :: struct {
	pos:         tokenizer.Pos,
	end:         tokenizer.Pos,
	state_flags: Node_State_Flags,
	derived:     Any_Node,

	// Semantic Analysis Fields
	viral_state_flags: Node_Viral_State_Flags,  // ✅ Matches C++
	file_id:           i32,                      // ✅ Matches C++
	tav:               Type_And_Value,           // ✅ CHANGED: By value (C++ optimization)
}
```

**Impact**:
- Every AST node increases by ~32-40 bytes (size of Type_And_Value struct)
- Better cache locality - tav data co-located with node
- No pointer dereference needed
- Matches C++ comment: "Making this a pointer is slower"

---

### File

**Current**:
```odin
File :: struct {
	using node: Node,
	id: int,
	pkg: ^Package,

	fullpath: string,
	src:      string,

	tags: [dynamic]tokenizer.Token,
	docs: ^Comment_Group,

	pkg_decl:  ^Package_Decl,
	pkg_token: tokenizer.Token,
	pkg_name:  string,

	decls:   [dynamic]^Stmt,
	imports: [dynamic]^Import_Decl,
	directive_count: int,

	comments: [dynamic]^Comment_Group,

	syntax_warning_count: int,
	syntax_error_count:   int,

	// Semantic Analysis Fields
	scope: ^Scope,  // ✅ Already added in recent refactoring
}
```

**Proposed** (C++ Parity):
```odin
File :: struct {
	using node: Node,
	id: int,
	pkg: ^Package,

	fullpath: string,
	src:      string,

	tags: [dynamic]tokenizer.Token,
	docs: ^Comment_Group,

	pkg_decl:  ^Package_Decl,
	pkg_token: tokenizer.Token,
	pkg_name:  string,

	decls:   [dynamic]^Stmt,
	imports: [dynamic]^Import_Decl,
	directive_count: int,

	comments: [dynamic]^Comment_Group,

	syntax_warning_count: int,
	syntax_error_count:   int,

	// Semantic Analysis Fields
	scope: ^Scope,  // ✅ Already exists

	// Checker Metadata (from C++ AstFile)
	// C++ parser.hpp:109 - u32 flags
	flags: File_Flags,

	// C++ parser.hpp:128-131 - vet and feature flags
	vet_flags:         u64,
	feature_flags:     u64,
	vet_flags_set:     bool,
	feature_flags_set: bool,

	// Delayed declaration queues (C++ parser.hpp:161)
	// These are temporary working queues populated during parsing/checking
	// C++ uses: Array<Ast *> delayed_decls_queues[AstDelayQueue_COUNT]
	delayed_decls_import:        [dynamic]^Stmt,
	delayed_decls_foreign_block: [dynamic]^Stmt,
	delayed_decls_expr:          [dynamic]^Expr,
}

// File_Flag from checker.odin would move here
File_Flag :: enum u32 {
	Is_Private_Pkg     = 0,  // From #private directive
	Is_Private_File    = 1,  // From #private file directive
	Is_Lazy            = 4,  // From #load directive with lazy flag
	No_Instrumentation = 5,  // From #no_instrumentation directive
}
File_Flags :: bit_set[File_Flag; u32]
```

**Impact**:
- File struct increases by ~56 bytes (1 bit_set, 2 u64s, 2 bools, 3 dynamic arrays)
- Eliminates 8 external maps from Checker_Info:
  - `file_flags: map[^ast.File]Ast_File_Flags`
  - `file_vet_flags: map[^ast.File]u64`
  - `file_feature_flags: map[^ast.File]u64`
  - `file_vet_flags_set: map[^ast.File]bool`
  - `file_feature_flags_set: map[^ast.File]bool`
  - `delayed_decls_import: map[^ast.File][dynamic]^ast.Stmt`
  - `delayed_decls_foreign_block: map[^ast.File][dynamic]^ast.Stmt`
  - `delayed_decls_expr: map[^ast.File][dynamic]^ast.Expr`
- Simpler code: `file.flags` instead of `checker.info.file_flags[file]`
- Thread-safety: Can use per-file mutex instead of global map mutex

---

### Package

**Current**:
```odin
Package :: struct {
	using node: Node,
	kind:     Package_Kind,
	id:       int,
	name:     string,
	fullpath: string,
	files:    map[string]^File,

	user_data: rawptr,
}
```

**Proposed** (C++ Parity):
```odin
Package :: struct {
	using node: Node,
	kind:     Package_Kind,
	id:       int,
	name:     string,
	fullpath: string,
	files:    map[string]^File,

	user_data: rawptr,

	// Semantic Analysis Fields (from C++ AstPackage)
	// C++ parser.hpp:210-214
	order:      int,        // Package order for dependency resolution
	scope:      ^Scope,     // Package-level scope
	decl_info:  ^Decl_Info, // Package declaration info
	is_extra:   bool,       // Extra package flag (runtime, vendor, etc.)

	// Multi-threading support
	// C++ parser.hpp:209
	exported_entity_queue: MPSC_Queue(Package_Exported_Entity),

	// Thread-safety mutexes (C++ has these too)
	files_mutex:           sync.Mutex,
	type_and_value_mutex:  sync.Mutex,
}

// Package_Exported_Entity would move from checker.odin to here
Package_Exported_Entity :: struct {
	identifier: ^Node,
	entity:     ^Entity,
}
```

**Impact**:
- Package struct increases by ~64 bytes
- Eliminates 5 external maps from Checker_Info:
  - `package_scopes: map[^ast.Package]^Scope`
  - `package_decl_infos: map[^ast.Package]^Decl_Info`
  - `package_is_extra: map[^ast.Package]bool`
  - `package_order: map[^ast.Package]int`
  - `package_exported_entity_queues: map[^ast.Package]MPSC_Queue(...)`
- Better thread-safety: Per-package mutexes instead of global map mutexes
- Cleaner API: `pkg.scope` instead of `checker.info.package_scopes[pkg]`

---

## Type Definitions That Would Move to AST

Several types currently in `checker.odin` would need to move to `ast.odin`:

### From checker.odin to ast.odin:

```odin
// These are referenced by AST structs, so they belong in the AST package

// File_Flag (already shown above)
File_Flag :: enum u32 { ... }
File_Flags :: bit_set[File_Flag; u32]

// Package_Exported_Entity (already shown above)
Package_Exported_Entity :: struct { ... }

// MPSC_Queue (needed for Package.exported_entity_queue)
// This is a utility type - might stay in checker, with Package using it via import
MPSC_Queue :: struct(T: typeid) { ... }
```

---

## Complete Modified AST Package Structure

```odin
package odin_ast

import "core:odin/tokenizer"
import "core:sync"

// ============================================================================
// ENUMS AND FLAGS
// ============================================================================

Proc_Tag :: enum { ... }  // Already exists
Proc_Tags :: distinct bit_set[Proc_Tag; u32]

Proc_Inlining :: enum u32 { ... }  // Already exists

Node_State_Flag :: enum { ... }  // ✅ Already exists (recently updated)
Node_State_Flags :: distinct bit_set[Node_State_Flag]

Node_Viral_State_Flag :: enum u8 { ... }  // ✅ Already exists (recently added)
Node_Viral_State_Flags :: distinct bit_set[Node_Viral_State_Flag; u8]

// NEW: File-level flags
File_Flag :: enum u32 {
	Is_Private_Pkg     = 0,
	Is_Private_File    = 1,
	Is_Lazy            = 4,
	No_Instrumentation = 5,
}
File_Flags :: bit_set[File_Flag; u32]

Package_Kind :: enum { ... }  // Already exists

// ============================================================================
// SEMANTIC TYPES (Currently in checker.odin, would need to move)
// ============================================================================

// Forward declarations for types that would be in ast/semantic_types.odin
Entity :: struct { ... }
Type :: struct { ... }
Scope :: struct { ... }
Decl_Info :: struct { ... }
Type_And_Value :: struct { ... }

// NEW: Package exported entity
Package_Exported_Entity :: struct {
	identifier: ^Node,
	entity:     ^Entity,
}

// NOTE: MPSC_Queue might stay in checker as utility, imported here
MPSC_Queue :: struct(T: typeid) { ... }

// ============================================================================
// BASE NODE
// ============================================================================

Node :: struct {
	pos:         tokenizer.Pos,
	end:         tokenizer.Pos,
	state_flags: Node_State_Flags,
	derived:     Any_Node,

	// Semantic Analysis Fields
	viral_state_flags: Node_Viral_State_Flags,
	file_id:           i32,
	tav:               Type_And_Value,  // ← CHANGED from ^Type_And_Value
}

// ============================================================================
// TOP-LEVEL STRUCTURES
// ============================================================================

Package :: struct {
	using node: Node,
	kind:     Package_Kind,
	id:       int,
	name:     string,
	fullpath: string,
	files:    map[string]^File,

	user_data: rawptr,

	// Semantic Analysis Fields (NEW)
	order:      int,
	scope:      ^Scope,
	decl_info:  ^Decl_Info,
	is_extra:   bool,

	// Multi-threading Support (NEW)
	exported_entity_queue: MPSC_Queue(Package_Exported_Entity),
	files_mutex:           sync.Mutex,
	type_and_value_mutex:  sync.Mutex,
}

File :: struct {
	using node: Node,
	id:  int,
	pkg: ^Package,

	fullpath: string,
	src:      string,

	tags: [dynamic]tokenizer.Token,
	docs: ^Comment_Group,

	pkg_decl:  ^Package_Decl,
	pkg_token: tokenizer.Token,
	pkg_name:  string,

	decls:   [dynamic]^Stmt,
	imports: [dynamic]^Import_Decl,
	directive_count: int,

	comments: [dynamic]^Comment_Group,

	syntax_warning_count: int,
	syntax_error_count:   int,

	// Semantic Analysis Fields
	scope: ^Scope,

	// Checker Metadata (NEW)
	flags:             File_Flags,
	vet_flags:         u64,
	feature_flags:     u64,
	vet_flags_set:     bool,
	feature_flags_set: bool,

	// Delayed Declaration Queues (NEW)
	delayed_decls_import:        [dynamic]^Stmt,
	delayed_decls_foreign_block: [dynamic]^Stmt,
	delayed_decls_expr:          [dynamic]^Expr,
}

// ============================================================================
// STATEMENT AND EXPRESSION NODES (unchanged from current)
// ============================================================================

// All existing stmt/expr nodes remain the same...
Block_Stmt :: struct { ... }
If_Stmt :: struct { ... }
// etc...

```

---

## Migration Impact Analysis

### Size Changes

| Struct | Current Size | Proposed Size | Increase | Instances |
|--------|--------------|---------------|----------|-----------|
| Node | ~40 bytes | ~72 bytes | +32 bytes | Every AST node |
| File | ~200 bytes | ~256 bytes | +56 bytes | ~100s per compilation |
| Package | ~80 bytes | ~144 bytes | +64 bytes | ~10s per compilation |

**Total memory impact** (rough estimate for medium project):
- 100,000 AST nodes × 32 bytes = 3.2 MB
- 500 files × 56 bytes = 28 KB
- 50 packages × 64 bytes = 3.2 KB
- **Total: ~3.2 MB additional memory**

For a 64-bit system with GBs of RAM, this is negligible.

### Maps Eliminated from Checker_Info

**13 external maps removed**:
1. `file_flags`
2. `file_vet_flags`
3. `file_feature_flags`
4. `file_vet_flags_set`
5. `file_feature_flags_set`
6. `delayed_decls_import`
7. `delayed_decls_foreign_block`
8. `delayed_decls_expr`
9. `package_scopes`
10. `package_decl_infos`
11. `package_is_extra`
12. `package_order`
13. `package_exported_entity_queues`

**Savings**:
- No more map overhead (hash tables, collision chains)
- No more global mutexes for map access
- No more rawptr casting for map keys
- Simpler initialization/cleanup code

### Code Simplification

**Before** (external map):
```odin
// Getting file flags
flags := checker.info.file_flags[file]

// Setting file flags (requires mutex)
sync.rw_mutex_lock(&checker.info.file_flags_mutex)
checker.info.file_flags[file] = new_flags
sync.rw_mutex_unlock(&checker.info.file_flags_mutex)
```

**After** (direct field):
```odin
// Getting file flags
flags := file.flags

// Setting file flags (can use per-file mutex if needed)
file.flags = new_flags
```

### Initialization Changes

**Before** (in checker_lifecycle.odin):
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// Initialize 13 maps
	info.file_flags = make(map[^ast.File]Ast_File_Flags, allocator)
	info.file_vet_flags = make(map[^ast.File]u64, allocator)
	// ... 11 more maps ...
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// Clean up 13 maps
	delete(info.file_flags)
	delete(info.file_vet_flags)
	// ... 11 more deletes ...
	// Plus special handling for maps of dynamic arrays
	for file in info.delayed_decls_import {
		delete(info.delayed_decls_import[file])
	}
	// ... etc ...
}
```

**After**:
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// 13 fewer maps to initialize!
	// Files/packages initialize their own fields
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// 13 fewer maps to clean up!
	// Files/packages clean up their own fields
}
```

---

## Performance Implications

### Better Performance ✅

1. **Direct field access**: `file.flags` instead of map lookup
2. **Cache locality**: Semantic data co-located with AST node
3. **No hash computation**: No map key hashing overhead
4. **No mutex contention**: Per-file/package mutexes instead of global map mutexes
5. **tav by value**: Eliminates pointer dereference (C++ optimization)

### Neutral Impact ⚖️

1. **Memory usage**: ~3 MB more for medium project (negligible on modern systems)
2. **Struct sizes**: Larger, but still fit in cache lines

### No Downsides ❌

The C++ implementation proves this architecture works well in production.

---

## Migration Path

### Phase 1: Add Fields to AST
1. Add new fields to `Node`, `File`, `Package` in `/mnt/c/odin/core/odin/ast/ast.odin`
2. Move type definitions (`File_Flags`, `Package_Exported_Entity`) to AST package
3. Update AST initialization to zero-initialize new fields

### Phase 2: Dual-Mode Operation
1. Keep external maps in checker
2. Add code to copy data between maps and AST fields
3. Verify both approaches produce same results

### Phase 3: Migrate Checker Code
1. Update checker code to use AST fields directly
2. Remove external map access one at a time
3. Run tests after each map removal

### Phase 4: Cleanup
1. Delete all external maps from `Checker_Info`
2. Remove initialization/cleanup code
3. Delete migration/copying code

### Phase 5: Optimize tav
1. Change `Node.tav` from pointer to value
2. Update all code that accesses tav
3. Benchmark performance improvement

---

## Recommendation

**Strongly recommend adopting full C++ parity** for these reasons:

1. ✅ **Proven architecture**: C++ implementation has years of production use
2. ✅ **Better performance**: Direct field access, better cache locality, no map overhead
3. ✅ **Simpler code**: Eliminates 13 external maps and associated complexity
4. ✅ **Better thread-safety**: Per-object mutexes instead of global map mutexes
5. ✅ **Easier to maintain**: Semantic data co-located with the structures it describes
6. ✅ **Minimal cost**: ~3 MB extra memory is negligible

The only "cost" is larger struct sizes, but this is offset by:
- Elimination of map overhead (which also uses memory)
- Better cache performance (co-located data)
- Simpler codebase (less code = fewer bugs)

**The C++ approach is objectively better.**
