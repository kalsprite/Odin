# C++ Parity Achieved - Semantic AST Refactoring Complete

## Summary

The Odin checker now has **full architectural parity** with the C++ Odin compiler implementation. All metadata that C++ stores directly on AST nodes is now stored the same way in our implementation.

**Total maps eliminated: 12** (all metadata-related external maps)

## What Was Moved to AST Nodes

### File Metadata (ast.File)
Moved from `Checker_Info` maps to direct fields on `ast.File`:

| C++ (AstFile)              | Odin (ast.File)                    | Status |
|----------------------------|------------------------------------|--------|
| `u32 flags`                | `flags: File_Flags`                | ✅     |
| `u64 vet_flags`            | `vet_flags: Vet_Flags`             | ✅     |
| `u64 feature_flags`        | `feature_flags: Feature_Flags`     | ✅     |
| `bool vet_flags_set`       | `vet_flags_set: bool`              | ✅     |
| `bool feature_flags_set`   | `feature_flags_set: bool`          | ✅     |
| `Scope *scope`             | `scope: ^Scope`                    | ✅     |
| `Array delayed_decls[3]`   | `delayed_decls_import/foreign_block/expr` | ✅ |

**Maps Deleted:**
- `file_flags: map[^ast.File]Ast_File_Flags` → `file.flags`
- `file_vet_flags: map[^ast.File]u64` → `file.vet_flags`
- `file_vet_flags_set: map[^ast.File]bool` → `file.vet_flags_set`
- `file_feature_flags: map[^ast.File]u64` → `file.feature_flags`
- `file_feature_flags_set: map[^ast.File]bool` → `file.feature_flags_set`
- `delayed_decls_import: map[^ast.File][dynamic]^ast.Stmt` → `file.delayed_decls_import`
- `delayed_decls_foreign_block: map[^ast.File][dynamic]^ast.Stmt` → `file.delayed_decls_foreign_block`
- `delayed_decls_expr: map[^ast.File][dynamic]^ast.Expr` → `file.delayed_decls_expr`

### Package Metadata (ast.Package)
Moved from `Checker_Info` maps to direct fields on `ast.Package`:

| C++ (AstPackage)     | Odin (ast.Package)         | Status |
|----------------------|----------------------------|--------|
| `isize order`        | `order: int`               | ✅     |
| `Scope *scope`       | `scope: ^Scope`            | ✅     |
| `DeclInfo *decl_info`| `decl_info: ^Decl_Info`    | ✅     |
| `bool is_extra`      | `is_extra: bool`           | ✅     |

**Maps Deleted:**
- `package_order: map[^ast.Package]int` → `pkg.order`
- `package_scopes: map[^ast.Package]^Scope` → `pkg.scope`
- `package_decl_infos: map[^ast.Package]^Decl_Info` → `pkg.decl_info`
- `package_is_extra: map[^ast.Package]bool` → `pkg.is_extra`

### AST Node Metadata (Previously Deleted)
Already moved in earlier phases:

| C++                          | Odin                           | Status |
|------------------------------|--------------------------------|--------|
| `u32 state_flags`            | `node.state_flags`             | ✅     |
| `u8 viral_state_flags`       | `node.viral_state_flags`       | ✅     |
| `TypeAndValue *tav`          | `node.tav`                     | ✅     |
| `When_Stmt condition cache`  | `when_stmt.is_cond_determined` | ✅     |
| Statement/type scopes        | Direct scope fields            | ✅     |

## What Remains in Checker_Info

### Legitimately External Data

**Package Exported Entity Queues:**
```odin
package_exported_entity_queues: map[^ast.Package]MPSC_Queue(Package_Exported_Entity)
```

**Why External:**
- C++ embeds `MPMCQueue<AstPackageExportedEntity>` directly in AstPackage
- In Odin, `MPSC_Queue` is checker-specific infrastructure
- `core:odin/ast` cannot depend on checker package (circular dependency)
- This is **working state** for parallel entity collection, not structural metadata
- Semantically equivalent to C++, just architecturally different due to module boundaries

### Core Checker State (Matches C++)

**Maps** (same as C++):
- `files: map[string]^ast.File` (C++ StringMap<AstFile *>)
- `packages: map[string]^ast.Package` (C++ StringMap<AstPackage *>)
- `foreigns: map[string]^Entity`

**Queues** (same as C++):
- `definition_queue: MPSC_Queue(^Entity)` (C++ line 494)
- `entity_queue: MPSC_Queue(^Entity)` (C++ line 495)
- `required_global_variable_queue: MPSC_Queue(^Entity)` (C++ line 496)
- Plus 6 more specialized queues

**Arrays** (same as C++):
- `definitions: [dynamic]^Entity`
- `entities: [dynamic]^Entity`
- `all_procedures: [dynamic]^Proc_Info` (C++ line 521)
- Plus 5 more specialized arrays

**Synchronization** (same as C++):
- `foreign_mutex`, `type_info_mutex`, `instrumentation_mutex`
- Plus additional mutexes for thread-safe access

## Type Safety Improvements

### Before (Raw u64):
```odin
file_vet_flags: map[^ast.File]u64
file_feature_flags: map[^ast.File]u64
```

### After (Typed Bit Sets):
```odin
// In ast.odin
Vet_Flag_Bit :: enum {
    Shadowing = 0,
    Using_Stmt = 1,
    // ... 12 total flags
}
Vet_Flags :: distinct bit_set[Vet_Flag_Bit; u64]

Feature_Flag_Bit :: enum {
    Dynamic_Literals = 0,
    Global_Context = 1,
    // ... 6 total flags
}
Feature_Flags :: distinct bit_set[Feature_Flag_Bit; u64]

// Direct on File
File :: struct {
    vet_flags: Vet_Flags,
    feature_flags: Feature_Flags,
    // ...
}
```

## Files Modified

### Core AST (ast.odin)
- Added `File_Flag`, `Vet_Flag_Bit`, `Feature_Flag_Bit` enums
- Added typed `File_Flags`, `Vet_Flags`, `Feature_Flags` bit sets
- Extended `File` struct with 8 new fields
- Extended `Package` struct with 4 new fields

### Helper Functions Updated

**build_infrastructure.odin:**
- Updated 5 file flag functions to use direct field access
- Changed return types from `u64` to typed `Vet_Flags` and `Feature_Flags`

**file_helpers.odin:**
- Updated 9 delayed declaration helper functions
- Changed from map-based queuing to direct field access

**package_helpers.odin:**
- Updated 6 package metadata helper functions
- Changed from map lookups to direct field access

**type_info.odin:**
- Updated `get_package_scope` and `set_package_scope`
- Direct field access instead of map lookup

### Checker Infrastructure

**checker.odin:**
- Deleted 12 map declarations
- Added comprehensive documentation comments

**checker_lifecycle.odin:**
- Deleted map initialization code (8 files + 4 packages = 12 maps)
- Deleted map cleanup code

**check_collect.odin:**
- Updated 7 locations for delayed declaration processing
- Direct field access for queuing imports, foreign blocks, directives

**check_import_export.odin:**
- Updated package order assignment: `pkg.order = 1 + pkg_index`

**check_proc.odin:**
- Updated package order comparison in procedure sorting

## Benefits

### Performance
- ✅ Eliminated 12 map lookups per operation
- ✅ Better cache locality (data with struct, not external)
- ✅ Reduced allocator pressure

### Code Quality
- ✅ Type-safe flag operations (bit_set instead of raw u64)
- ✅ Clearer ownership (data lives where it logically belongs)
- ✅ Simplified helper functions (direct access vs map lookup)

### Maintainability
- ✅ Matches C++ architecture exactly
- ✅ Easier to understand for C++ developers
- ✅ Natural evolution path to using core:odin/ast semantic types

## Architectural Notes

### Module Boundary Constraints

The one remaining external map (`package_exported_entity_queues`) exists due to Odin's module system:

**C++ Approach:**
- No module boundaries
- Can embed any type anywhere
- `AstPackage` directly contains `MPMCQueue<AstPackageExportedEntity>`

**Odin Approach:**
- Strict module boundaries
- `core:odin/ast` cannot depend on checker
- `MPSC_Queue` is checker infrastructure
- Must store working state externally

This is **semantically equivalent** - both approaches achieve the same goal, just adapted to their respective language constraints.

### Future Evolution

With the semantic AST now matching C++ architecture, the path forward to using `core:odin/ast` semantic types is clear:

1. ✅ **Phase 1 Complete:** AST nodes now carry semantic data directly
2. **Phase 2 (Future):** Replace checker's Entity/Type/Scope with ast.Entity/Type/Scope
3. **Phase 3 (Future):** Unify type systems completely

## Verification

To verify parity, compare:

**C++ AstFile (parser.hpp:107-173)** ↔ **Odin ast.File**
- All fields present ✅
- Flags use proper types ✅
- Delayed decls as dynamic arrays ✅

**C++ AstPackage (parser.hpp:193-215)** ↔ **Odin ast.Package**
- All fields present ✅
- Order, scope, decl_info, is_extra ✅
- Exported entity queue (external but equivalent) ✅

**C++ CheckerInfo (checker.hpp:442-533)** ↔ **Odin Checker_Info**
- No metadata maps ✅
- Same core working state ✅
- Same queue infrastructure ✅

## Conclusion

**The refactoring is complete.** The Odin checker now has full C++ parity in its semantic AST architecture. All metadata is stored directly on AST nodes exactly as C++ does, with the only exception being module boundary constraints that require external storage of working state queues.

This represents a significant architectural improvement that:
- Eliminates unnecessary indirection
- Improves type safety
- Simplifies code
- Matches the reference implementation
- Paves the way for future unification with core:odin/ast semantic types
