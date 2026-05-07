# C++ Parity Implementation Guide

## Overview

This document shows the **exact code changes** needed to eliminate the remaining 12 external maps by moving file/package metadata directly onto AST structs, matching the C++ reference implementation.

---

## Part 1: File Metadata → File Struct

### Current State (External Maps)

```odin
// In Checker_Info (checker.odin:1504-1508)
file_flags:             map[^ast.File]Ast_File_Flags,
file_vet_flags:         map[^ast.File]u64,
file_feature_flags:     map[^ast.File]u64,
file_vet_flags_set:     map[^ast.File]bool,
file_feature_flags_set: map[^ast.File]bool,

// Usage:
flags := checker.info.file_flags[file]
vet_flags := checker.info.file_vet_flags[file]
```

### Proposed Change: Add Fields to File

**File: `/mnt/c/odin/core/odin/ast/ast.odin`**

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

	// Checker Metadata (matching C++ AstFile)
	// C++ Reference: parser.hpp:109-131
	flags:             File_Flags,  // ✅ ADD THIS (C++ line 109: u32 flags)
	vet_flags:         u64,         // ✅ ADD THIS (C++ line 128: u64 vet_flags)
	feature_flags:     u64,         // ✅ ADD THIS (C++ line 129: u64 feature_flags)
	vet_flags_set:     bool,        // ✅ ADD THIS (C++ line 130: bool vet_flags_set)
	feature_flags_set: bool,        // ✅ ADD THIS (C++ line 131: bool feature_flags_set)

	// Delayed declaration queues (matching C++ AstFile)
	// C++ Reference: parser.hpp:161 - Array<Ast *> delayed_decls_queues[AstDelayQueue_COUNT]
	delayed_decls_import:        [dynamic]^Stmt,  // ✅ ADD THIS
	delayed_decls_foreign_block: [dynamic]^Stmt,  // ✅ ADD THIS
	delayed_decls_expr:          [dynamic]^Expr,  // ✅ ADD THIS
}

// Move File_Flag enum from checker.odin to ast.odin
File_Flag :: enum u32 {
	Is_Private_Pkg     = 0,  // From #private directive
	Is_Private_File    = 1,  // From #private file directive
	Is_Lazy            = 4,  // From #load directive with lazy flag
	No_Instrumentation = 5,  // From #no_instrumentation directive
}
File_Flags :: bit_set[File_Flag; u32]
```

### Updated Usage

**Before** (external map):
```odin
// Getting file flags
flags := checker.info.file_flags[file]
vet_flags := checker.info.file_vet_flags[file]

// Setting file flags
checker.info.file_flags[file] = new_flags
checker.info.file_vet_flags[file] = new_vet_flags

// Checking specific flag
if .Is_Private_File in checker.info.file_flags[file] {
	// ...
}
```

**After** (direct field):
```odin
// Getting file flags
flags := file.flags
vet_flags := file.vet_flags

// Setting file flags
file.flags = new_flags
file.vet_flags = new_vet_flags

// Checking specific flag
if .Is_Private_File in file.flags {
	// ...
}
```

### Initialization Changes

**Before** (checker_lifecycle.odin:35-39):
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// File metadata storage
	info.file_flags = make(map[^ast.File]Ast_File_Flags, allocator)
	info.file_vet_flags = make(map[^ast.File]u64, allocator)
	info.file_feature_flags = make(map[^ast.File]u64, allocator)
	info.file_vet_flags_set = make(map[^ast.File]bool, allocator)
	info.file_feature_flags_set = make(map[^ast.File]bool, allocator)

	// ...
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// File metadata cleanup
	delete(info.file_flags)
	delete(info.file_vet_flags)
	delete(info.file_feature_flags)
	delete(info.file_vet_flags_set)
	delete(info.file_feature_flags_set)
	// ...
}
```

**After** (no map initialization needed):
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// File metadata - NO INIT NEEDED! Stored on File struct
	// Files initialize their own fields when created

	// ...
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// File metadata - NO CLEANUP NEEDED! Stored on File struct
	// Files clean up their own fields when destroyed

	// ...
}
```

### Cleanup for Delayed Decls

**Note**: The delayed_decls dynamic arrays need cleanup when File is destroyed:

```odin
// In parser or wherever Files are destroyed
destroy_file :: proc(file: ^ast.File) {
	delete(file.delayed_decls_import)
	delete(file.delayed_decls_foreign_block)
	delete(file.delayed_decls_expr)
	// ... other cleanup ...
}
```

---

## Part 2: Package Metadata → Package Struct

### Current State (External Maps)

```odin
// In Checker_Info (checker.odin:1514-1522)
package_scopes:                 map[^ast.Package]^Scope,
package_decl_infos:             map[^ast.Package]^Decl_Info,
package_is_extra:               map[^ast.Package]bool,
package_order:                  map[^ast.Package]int,
package_exported_entity_queues: map[^ast.Package]MPSC_Queue(Package_Exported_Entity),

// Usage:
pkg_scope := checker.info.package_scopes[pkg]
order := checker.info.package_order[pkg]
```

### Proposed Change: Add Fields to Package

**File: `/mnt/c/odin/core/odin/ast/ast.odin`**

```odin
Package :: struct {
	using node: Node,
	kind:     Package_Kind,
	id:       int,
	name:     string,
	fullpath: string,
	files:    map[string]^File,

	user_data: rawptr,

	// Semantic Analysis Fields (matching C++ AstPackage)
	// C++ Reference: parser.hpp:199-214
	order:      int,        // ✅ ADD THIS (C++ line 199: isize order)
	scope:      ^Scope,     // ✅ ADD THIS (C++ line 212: Scope *scope)
	decl_info:  ^Decl_Info, // ✅ ADD THIS (C++ line 213: DeclInfo *decl_info)
	is_extra:   bool,       // ✅ ADD THIS (C++ line 214: bool is_extra)

	// Multi-threading support (matching C++ AstPackage)
	// C++ Reference: parser.hpp:209
	exported_entity_queue: MPSC_Queue(Package_Exported_Entity),  // ✅ ADD THIS

	// Thread-safety mutexes (C++ has these too)
	files_mutex:          sync.Mutex,  // ✅ ADD THIS
	type_and_value_mutex: sync.Mutex,  // ✅ ADD THIS
}

// Move Package_Exported_Entity from checker.odin to ast.odin
Package_Exported_Entity :: struct {
	identifier: ^Node,   // Identifier node
	entity:     ^Entity, // Associated entity
}
```

### Updated Usage

**Before** (external map):
```odin
// Getting package metadata
pkg_scope := checker.info.package_scopes[pkg]
decl_info := checker.info.package_decl_infos[pkg]
order := checker.info.package_order[pkg]
is_extra := checker.info.package_is_extra[pkg]

// Setting package metadata
checker.info.package_scopes[pkg] = new_scope
checker.info.package_order[pkg] = new_order

// Accessing exported entity queue
queue := &checker.info.package_exported_entity_queues[pkg]
mpsc_queue_push(queue, entity)
```

**After** (direct field):
```odin
// Getting package metadata
pkg_scope := pkg.scope
decl_info := pkg.decl_info
order := pkg.order
is_extra := pkg.is_extra

// Setting package metadata
pkg.scope = new_scope
pkg.order = new_order

// Accessing exported entity queue
mpsc_queue_push(&pkg.exported_entity_queue, entity)
```

### Initialization Changes

**Before** (checker_lifecycle.odin:42-46):
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// Package metadata storage
	info.package_scopes = make(map[^ast.Package]^Scope, allocator)
	info.package_decl_infos = make(map[^ast.Package]^Decl_Info, allocator)
	info.package_is_extra = make(map[^ast.Package]bool, allocator)
	info.package_order = make(map[^ast.Package]int, allocator)
	info.package_exported_entity_queues = make(map[^ast.Package]MPSC_Queue(Package_Exported_Entity), allocator)

	// ...
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// Package metadata cleanup
	delete(info.package_scopes)
	delete(info.package_decl_infos)
	delete(info.package_is_extra)
	delete(info.package_order)

	// Clean up exported entity queues
	for pkg in info.package_exported_entity_queues {
		mpsc_queue_destroy(&info.package_exported_entity_queues[pkg])
	}
	delete(info.package_exported_entity_queues)

	// ...
}
```

**After** (no map initialization needed):
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// Package metadata - NO INIT NEEDED! Stored on Package struct
	// Packages initialize their own fields when created

	// ...
}

destroy_checker_info :: proc(info: ^Checker_Info) {
	// Package metadata - NO CLEANUP NEEDED! Stored on Package struct
	// Packages clean up their own fields when destroyed

	// ...
}
```

### Package Initialization

**When creating a package**:
```odin
create_package :: proc(name: string, allocator := context.allocator) -> ^ast.Package {
	pkg := new(ast.Package, allocator)
	pkg.name = name
	pkg.order = 0
	pkg.is_extra = false
	mpsc_queue_init(&pkg.exported_entity_queue)  // Initialize queue
	return pkg
}

destroy_package :: proc(pkg: ^ast.Package) {
	mpsc_queue_destroy(&pkg.exported_entity_queue)  // Clean up queue
	// ... other cleanup ...
}
```

---

## Part 3: Checker_Info After Full Migration

### Before (12 External Maps)

```odin
Checker_Info :: struct {
	// ... other fields ...

	// File metadata storage (5 maps)
	file_flags:             map[^ast.File]Ast_File_Flags,
	file_vet_flags:         map[^ast.File]u64,
	file_feature_flags:     map[^ast.File]u64,
	file_vet_flags_set:     map[^ast.File]bool,
	file_feature_flags_set: map[^ast.File]bool,

	// Package metadata storage (4 maps)
	package_scopes:                 map[^ast.Package]^Scope,
	package_decl_infos:             map[^ast.Package]^Decl_Info,
	package_is_extra:               map[^ast.Package]bool,
	package_order:                  map[^ast.Package]int,

	// Package exported entity queues (1 map)
	package_exported_entity_queues: map[^ast.Package]MPSC_Queue(Package_Exported_Entity),

	// Delayed declaration queues (3 maps)
	delayed_decls_import:        map[^ast.File][dynamic]^ast.Stmt,
	delayed_decls_foreign_block: map[^ast.File][dynamic]^ast.Stmt,
	delayed_decls_expr:          map[^ast.File][dynamic]^ast.Expr,
}
```

### After (All Maps Deleted!)

```odin
Checker_Info :: struct {
	// ... other fields ...

	// ✅ ALL 12 MAPS DELETED!
	// File metadata now stored directly on ast.File:
	//   - file.flags
	//   - file.vet_flags
	//   - file.feature_flags
	//   - file.vet_flags_set
	//   - file.feature_flags_set
	//   - file.delayed_decls_import
	//   - file.delayed_decls_foreign_block
	//   - file.delayed_decls_expr

	// Package metadata now stored directly on ast.Package:
	//   - pkg.scope
	//   - pkg.decl_info
	//   - pkg.is_extra
	//   - pkg.order
	//   - pkg.exported_entity_queue
}
```

---

## Part 4: Complete Migration Checklist

### Step 1: Extend AST Structs

- [ ] Add 8 fields to `ast.File`:
  - [ ] `flags: File_Flags`
  - [ ] `vet_flags: u64`
  - [ ] `feature_flags: u64`
  - [ ] `vet_flags_set: bool`
  - [ ] `feature_flags_set: bool`
  - [ ] `delayed_decls_import: [dynamic]^Stmt`
  - [ ] `delayed_decls_foreign_block: [dynamic]^Stmt`
  - [ ] `delayed_decls_expr: [dynamic]^Expr`

- [ ] Add 7 fields to `ast.Package`:
  - [ ] `order: int`
  - [ ] `scope: ^Scope`
  - [ ] `decl_info: ^Decl_Info`
  - [ ] `is_extra: bool`
  - [ ] `exported_entity_queue: MPSC_Queue(Package_Exported_Entity)`
  - [ ] `files_mutex: sync.Mutex`
  - [ ] `type_and_value_mutex: sync.Mutex`

- [ ] Move type definitions to AST:
  - [ ] `File_Flag` enum
  - [ ] `File_Flags` bit_set
  - [ ] `Package_Exported_Entity` struct

### Step 2: Update Checker Code

Find all code that accesses the external maps and replace:

**File flags**:
```bash
# Search for file_flags map access
grep -r "info.file_flags\[" /mnt/d/dev/checker/
# Replace with: file.flags
```

**Package metadata**:
```bash
# Search for package_scopes map access
grep -r "info.package_scopes\[" /mnt/d/dev/checker/
# Replace with: pkg.scope
```

**Delayed declarations**:
```bash
# Search for delayed_decls_import map access
grep -r "info.delayed_decls_import\[" /mnt/d/dev/checker/
# Replace with: file.delayed_decls_import
```

### Step 3: Update Lifecycle Code

**File: `/mnt/d/dev/checker/checker_lifecycle.odin`**

Delete map initialization/cleanup:
```odin
// DELETE these lines (35-39):
info.file_flags = make(map[^ast.File]Ast_File_Flags, allocator)
info.file_vet_flags = make(map[^ast.File]u64, allocator)
// ... etc ...

// DELETE these lines (109-113):
delete(info.file_flags)
delete(info.file_vet_flags)
// ... etc ...
```

### Step 4: Add AST Cleanup

Ensure File and Package cleanup their new fields:

```odin
// When destroying File (in parser or checker)
delete(file.delayed_decls_import)
delete(file.delayed_decls_foreign_block)
delete(file.delayed_decls_expr)

// When destroying Package (in parser or checker)
mpsc_queue_destroy(&pkg.exported_entity_queue)
```

### Step 5: Update Map Declaration

**File: `/mnt/d/dev/checker/checker.odin`**

Delete map declarations (lines 1504-1539):
```odin
// DELETE ALL THESE:
file_flags:                      map[^ast.File]Ast_File_Flags,
file_vet_flags:                  map[^ast.File]u64,
file_feature_flags:              map[^ast.File]u64,
file_vet_flags_set:              map[^ast.File]bool,
file_feature_flags_set:          map[^ast.File]bool,

package_scopes:                  map[^ast.Package]^Scope,
package_decl_infos:              map[^ast.Package]^Decl_Info,
package_is_extra:                map[^ast.Package]bool,
package_order:                   map[^ast.Package]int,
package_exported_entity_queues:  map[^ast.Package]MPSC_Queue(...),

delayed_decls_import:            map[^ast.File][dynamic]^ast.Stmt,
delayed_decls_foreign_block:     map[^ast.File][dynamic]^ast.Stmt,
delayed_decls_expr:              map[^ast.File][dynamic]^ast.Expr,
```

---

## Part 5: Code Search & Replace Patterns

### File Flags

```bash
# Pattern 1: Getting flags
# OLD: checker.info.file_flags[file]
# NEW: file.flags

# Pattern 2: Setting flags
# OLD: checker.info.file_flags[file] = flags
# NEW: file.flags = flags

# Pattern 3: Checking flags
# OLD: if .Is_Private_File in checker.info.file_flags[file]
# NEW: if .Is_Private_File in file.flags
```

### Package Metadata

```bash
# Pattern 1: Getting package scope
# OLD: checker.info.package_scopes[pkg]
# NEW: pkg.scope

# Pattern 2: Setting package scope
# OLD: checker.info.package_scopes[pkg] = scope
# NEW: pkg.scope = scope

# Pattern 3: Package order
# OLD: checker.info.package_order[pkg]
# NEW: pkg.order
```

### Delayed Declarations

```bash
# Pattern 1: Appending to delayed decls
# OLD: append(&checker.info.delayed_decls_import[file], stmt)
# NEW: append(&file.delayed_decls_import, stmt)

# Pattern 2: Iterating delayed decls
# OLD: for stmt in checker.info.delayed_decls_import[file]
# NEW: for stmt in file.delayed_decls_import
```

---

## Part 6: Benefits Analysis

### Memory Impact

**Before** (12 external maps):
- Map overhead: ~48 bytes per map = 576 bytes
- Map entries: ~32 bytes per entry per map
- For 500 files: 500 × 12 × 32 = 192 KB
- **Total: ~192 KB + map internal structures**

**After** (direct fields):
- File struct increase: ~64 bytes per file
- Package struct increase: ~56 bytes per package
- For 500 files: 500 × 64 = 32 KB
- For 50 packages: 50 × 56 = 2.8 KB
- **Total: ~35 KB**

**Savings**: ~157 KB + eliminated map overhead

### Performance Impact

**Before** (map lookup):
1. Hash rawptr key (~5-10 cycles)
2. Map lookup (~10-20 cycles)
3. Potential collision chain traversal (~10-50 cycles)
**Total**: ~25-80 cycles per access

**After** (direct field):
1. Field offset calculation (~1 cycle)
**Total**: ~1 cycle per access

**Speedup**: ~25-80x faster access

### Code Complexity

**Before**:
- 12 map declarations in Checker_Info
- 24 lines of init/cleanup code (12 × 2)
- Map key pointer casting required
- Global mutex for map access

**After**:
- 0 map declarations
- 0 lines of init/cleanup code for these maps
- Direct field access (no casting)
- Per-file/package mutexes if needed

**Lines of code removed**: ~50-60 lines

---

## Part 7: Thread Safety Considerations

### Current (External Maps)

```odin
// Global mutex for file_flags map
sync.rw_mutex_lock(&checker.info.some_global_mutex)
checker.info.file_flags[file] = flags
sync.rw_mutex_unlock(&checker.info.some_global_mutex)
```

### After (Per-File Locking)

```odin
// Per-file mutex (if needed)
sync.mutex_lock(&file.mutex)  // Add file.mutex field if needed
file.flags = flags
sync.mutex_unlock(&file.mutex)

// Or for packages
sync.mutex_lock(&pkg.files_mutex)  // Already added!
// ... modify package ...
sync.mutex_unlock(&pkg.files_mutex)
```

**Advantage**: Better parallelism - different files/packages can be modified concurrently without contention.

---

## Part 8: Migration Path (5 Phases)

### Phase 1: Add AST Fields (Non-Breaking)
- Add new fields to File and Package structs
- Move type definitions to ast.odin
- Compile and verify AST changes

### Phase 2: Dual-Mode (Compatibility)
- Keep external maps
- Add code to sync data between maps and AST fields
- Verify both paths produce same results

### Phase 3: Migrate Readers
- Update all code that READS from maps to use AST fields
- Run tests after each file converted

### Phase 4: Migrate Writers
- Update all code that WRITES to maps to use AST fields
- Run tests after each file converted

### Phase 5: Remove Maps
- Delete map declarations from Checker_Info
- Delete map init/cleanup from checker_lifecycle.odin
- Remove dual-mode sync code
- Final test suite run

---

## Summary

**What Changes**:
- **AST**: +15 fields (8 on File, 7 on Package)
- **Checker**: -12 maps, -50 lines of code
- **Usage**: Direct field access replaces map lookups

**Benefits**:
- ✅ ~25-80x faster access
- ✅ ~157 KB memory savings
- ✅ Simpler code (no map management)
- ✅ Better thread-safety (per-object mutexes)
- ✅ **Full C++ architectural parity**

**Trade-offs**:
- ⚠️ Larger AST structs (~120 bytes total increase)
- ⚠️ Checker-specific fields in general AST

**Verdict**: The C++ approach is objectively better for performance, simplicity, and maintainability.
