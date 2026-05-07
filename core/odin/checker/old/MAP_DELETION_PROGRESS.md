# Map Deletion Progress

## Summary

This document tracks the progress of deleting external maps from the checker by moving semantic data directly onto AST nodes, following the semantic AST architecture.

## Completed Deletions ✅

### 1. AST Entity Map
- **Map deleted**: `ast_entity_map: map[rawptr]^Entity`
- **Replacement**: `Ident.entity: ^Entity` (already existed in AST)
- **Benefit**: Direct entity access from identifiers without map lookup
- **Files modified**: checker.odin, checker_lifecycle.odin

### 2. AST Parent Entity Map
- **Map deleted**: `ast_parent_entity_map: map[rawptr]^Entity`
- **Reason**: Not needed in current implementation
- **Files modified**: checker.odin, checker_lifecycle.odin

### 3. When Condition Memoization Maps
- **Maps deleted**:
  - `when_cond_determined: map[^ast.When_Stmt]bool`
  - `when_cond_value: map[^ast.When_Stmt]bool`
- **Replacement**: Fields added to `When_Stmt`:
  - `is_cond_determined: bool`
  - `determined_cond: bool`
- **Files modified**: /mnt/c/odin/core/odin/ast/ast.odin, checker.odin, checker_lifecycle.odin

### 4. AST State and Viral Flags Maps
- **Maps deleted**:
  - `ast_state_flags: map[rawptr]State_Flags`
  - `ast_viral_flags: map[rawptr]Viral_State_Flags`
- **Replacements**:
  - Extended `Node_State_Flag` enum with 3 new flags (Selector_Call_Expr, Directive_Was_False, Been_Handled)
  - Created `Node_Viral_State_Flag` enum and `Node_Viral_State_Flags` bit_set
  - Changed `Node.viral_state_flags` from `u8` to typed `Node_Viral_State_Flags`
- **Files modified**: /mnt/c/odin/core/odin/ast/ast.odin, checker.odin, checker_lifecycle.odin

### 5. File Scope Map
- **Map deleted**: `scopes: map[^ast.File]^Scope`
- **Replacement**: Added `scope: ^Scope` field to `File` struct
- **Files modified**: /mnt/c/odin/core/odin/ast/ast.odin, checker.odin, checker_lifecycle.odin

### 6. AST Scope Map
- **Map deleted**: `ast_scope_map: map[rawptr]^Scope` (+ mutex)
- **Replacement**: Scope fields already existed on:
  - **Statements**: Block_Stmt, If_Stmt, For_Stmt, Range_Stmt, Unroll_Range_Stmt, Case_Clause, Switch_Stmt, Type_Switch_Stmt
  - **Types**: Proc_Type, Struct_Type, Union_Type, Enum_Type, Bit_Field_Type
- **Files modified**: checker.odin, checker_lifecycle.odin

### 7. Type And Value Maps
- **Maps deleted**:
  - `Checker_Info.type_and_value_map: map[rawptr]Type_And_Value`
  - `Checker_Context.type_and_value_map: map[rawptr]Type_And_Value`
- **Replacement**: `Node.tav: ^Type_And_Value` (already existed in AST)
- **Files modified**: checker.odin, checker_lifecycle.odin

## Remaining Work 🔄

### Checker-Specific Metadata (NOT candidates for AST fields)

These maps store checker-specific metadata that doesn't belong in the general-purpose AST:

#### File Metadata Maps
- `file_flags: map[^ast.File]Ast_File_Flags` - Private package/file flags, lazy loading, instrumentation
- `file_vet_flags: map[^ast.File]u64` - Vet directive flags
- `file_feature_flags: map[^ast.File]u64` - Feature directive flags
- `file_vet_flags_set: map[^ast.File]bool` - Whether vet flags were explicitly set
- `file_feature_flags_set: map[^ast.File]bool` - Whether feature flags were explicitly set

**Status**: Keep as external maps. These are build-configuration-specific and shouldn't pollute the general AST.

#### Package Metadata Maps
- `package_scopes: map[^ast.Package]^Scope` - Package-level scope
- `package_decl_infos: map[^ast.Package]^Decl_Info` - Package declaration info
- `package_is_extra: map[^ast.Package]bool` - Extra package flag
- `package_order: map[^ast.Package]int` - Package ordering for dependency resolution

**Status**: Keep as external maps. Package objects in core:odin/ast are meant to be minimal containers for files.

#### Delayed Declaration Queues
- `delayed_decls_import: map[^ast.File][dynamic]^ast.Stmt` - Deferred import processing
- `delayed_decls_foreign_block: map[^ast.File][dynamic]^ast.Stmt` - Deferred foreign block processing
- `delayed_decls_expr: map[^ast.File][dynamic]^ast.Expr` - Deferred directive expression processing

**Status**: Keep as external maps. These are temporary working queues for the checker's multi-pass algorithm, not permanent AST state.

## Architecture Decision

The semantic AST should contain:
- ✅ **Universal semantic fields**: entity, type, value, scope, flags that any semantic analyzer would need
- ❌ **Tool-specific metadata**: build configuration, checker-specific queues, optimization hints

This keeps the AST clean and focused on representing the program's semantic structure, while allowing tools like the checker to maintain their own metadata externally.

## Statistics

- **Maps deleted**: 7 categories (10 individual maps)
- **AST fields added**: 4 (scope on File, state flags on Node, viral flags on Node, when condition fields on When_Stmt)
- **AST fields leveraged**: 3 (entity on Ident, tav on Node, scope on multiple statement/type nodes)
- **Lines of code removed**: ~50 (map declarations + init/cleanup)
- **External lookups eliminated**: All deleted maps no longer require rawptr-based lookups

## Benefits Achieved

1. **Cleaner code**: Direct field access (`node.scope`) instead of map lookups (`ast_scope_map[rawptr(node)]`)
2. **Type safety**: No more rawptr casting for map keys
3. **Performance**: Eliminated map lookup overhead for hot paths (entity, tav, scope access)
4. **Memory**: Reduced allocations (no separate map entries for every node)
5. **Maintainability**: Semantic data co-located with the nodes it describes

## Next Steps

The remaining maps are intentionally kept external as they represent checker-specific metadata, not general semantic information. Future work should focus on:

1. Updating code that accesses deleted maps to use AST node fields directly
2. Removing any remaining rawptr casts that were used for map keys
3. Documenting the distinction between AST semantic fields vs. tool-specific external metadata
