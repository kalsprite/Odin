# Semantic AST Refactoring Documentation Index

## Overview

This directory contains documentation for the semantic AST refactoring project, which migrated the checker from external map-based semantic storage to storing semantic data directly on AST nodes.

## Documentation Files

### 📋 Quick Reference
**[SEMANTIC_AST_QUICK_REFERENCE.md](SEMANTIC_AST_QUICK_REFERENCE.md)**
- **Start here if you're**: Writing code that accesses semantic information
- **Contains**: Before/after code examples for all semantic data access patterns
- **Useful for**: Daily development, migration of existing code

### ✅ Progress Tracking
**[MAP_DELETION_PROGRESS.md](MAP_DELETION_PROGRESS.md)**
- **Contains**: Complete list of deleted maps and replacement strategies
- **Useful for**: Understanding what changed, verifying refactoring completeness

### 🔍 Architecture Comparison
**[CPP_VS_ODIN_COMPARISON.md](CPP_VS_ODIN_COMPARISON.md)**
- **Contains**: Detailed comparison with C++ reference implementation
- **Useful for**: Understanding architectural decisions, identifying remaining differences

### 📐 Future Work Proposal
**[AST_CPP_PARITY_PROPOSAL.md](AST_CPP_PARITY_PROPOSAL.md)**
- **Contains**: Concrete proposal for full C++ architectural parity
- **Useful for**: Planning next phase of refactoring, architecture decisions

### 🛠️ Implementation Guide
**[CPP_PARITY_IMPLEMENTATION_GUIDE.md](CPP_PARITY_IMPLEMENTATION_GUIDE.md)**
- **Contains**: Exact code changes, before/after examples, migration steps
- **Useful for**: Implementing full C++ parity, understanding concrete changes

### 🎯 Summary
**[SEMANTIC_AST_REFACTORING_COMPLETE.md](SEMANTIC_AST_REFACTORING_COMPLETE.md)**
- **Contains**: Executive summary of completed work, benefits, statistics
- **Useful for**: Understanding the big picture, project status

### 🔧 Technical Debt
**[TODO_TYPE_UNIFICATION.md](TODO_TYPE_UNIFICATION.md)**
- **Contains**: Documentation of Entity/Type/Scope type duplication issue
- **Useful for**: Understanding future unification work needed

## Quick Navigation

### I want to...

**...understand what changed**
→ Read [MAP_DELETION_PROGRESS.md](MAP_DELETION_PROGRESS.md)

**...migrate existing code**
→ Read [SEMANTIC_AST_QUICK_REFERENCE.md](SEMANTIC_AST_QUICK_REFERENCE.md)

**...understand why we differ from C++**
→ Read [CPP_VS_ODIN_COMPARISON.md](CPP_VS_ODIN_COMPARISON.md)

**...see the overall project status**
→ Read [SEMANTIC_AST_REFACTORING_COMPLETE.md](SEMANTIC_AST_REFACTORING_COMPLETE.md)

**...understand what remains to be done**
→ Read [AST_CPP_PARITY_PROPOSAL.md](AST_CPP_PARITY_PROPOSAL.md)

**...implement full C++ parity**
→ Read [CPP_PARITY_IMPLEMENTATION_GUIDE.md](CPP_PARITY_IMPLEMENTATION_GUIDE.md)

## Key Changes Summary

### ✅ Deleted (10 maps)
- `ast_entity_map` → Use `Ident.entity`
- `ast_parent_entity_map` → Not needed
- `when_cond_determined`, `when_cond_value` → Use `When_Stmt.is_cond_determined`, `determined_cond`
- `ast_state_flags`, `ast_viral_flags` → Use `Node.state_flags`, `Node.viral_state_flags`
- `scopes` (file scope map) → Use `File.scope`
- `ast_scope_map` → Use scope fields on statement/type nodes
- `type_and_value_map` (2 instances) → Use `Node.tav`

### 🔄 Retained (12 maps)
**File metadata** (5 maps):
- `file_flags`, `file_vet_flags`, `file_feature_flags`, `file_vet_flags_set`, `file_feature_flags_set`

**Package metadata** (4 maps):
- `package_scopes`, `package_decl_infos`, `package_is_extra`, `package_order`

**Delayed declarations** (3 maps):
- `delayed_decls_import`, `delayed_decls_foreign_block`, `delayed_decls_expr`

### 🎯 AST Extensions
- Extended `Node_State_Flag` enum with 3 new flags
- Created `Node_Viral_State_Flag` enum and typed bit_set
- Added `scope: ^Scope` to `File` struct
- Added `is_cond_determined`, `determined_cond` to `When_Stmt`

## Benefits Achieved

✅ **Performance**: Eliminated map lookup overhead for hot paths
✅ **Type Safety**: No more rawptr casting for semantic data access
✅ **Code Quality**: Direct field access with cleaner code
✅ **Memory**: Reduced allocations from eliminated map structures
✅ **Maintainability**: Semantic data co-located with AST nodes

## Modified Files

1. `/mnt/c/odin/core/odin/ast/ast.odin` - AST extensions
2. `/mnt/d/dev/checker/checker.odin` - Map deletions
3. `/mnt/d/dev/checker/checker_lifecycle.odin` - Init/cleanup updates

## Code Examples

### Before (External Map)
```odin
entity := checker.info.ast_entity_map[rawptr(ident)]
tav := ctx.type_and_value_map[rawptr(node)]
scope := checker.info.ast_scope_map[rawptr(stmt)]
flags := checker.info.ast_state_flags[rawptr(node)]
```

### After (Direct Fields)
```odin
entity := ident.entity
tav := node.tav^
scope := stmt.scope
flags := node.state_flags
```

## Statistics

- **Maps deleted**: 7 categories (10 individual maps)
- **Maps retained**: 3 categories (12 maps)
- **Lines of code removed**: ~50
- **AST fields added**: 4
- **AST fields leveraged**: 3

## Related Work

### Completed
- ✅ External map deletion for semantic data
- ✅ AST semantic field extensions
- ✅ Comprehensive documentation

### Future Considerations
- ⚠️ Full C++ parity (move file/package metadata to AST)
- ⚠️ Type/Entity/Scope unification (eliminate type duplication)
- ⚠️ Change `Node.tav` from pointer to value (C++ optimization)

## Questions?

Refer to the FAQ section in [SEMANTIC_AST_QUICK_REFERENCE.md](SEMANTIC_AST_QUICK_REFERENCE.md) or consult the detailed comparison in [CPP_VS_ODIN_COMPARISON.md](CPP_VS_ODIN_COMPARISON.md).

---

**Status**: ✅ Refactoring Complete
**Last Updated**: 2025-10-11
**Compatibility**: Odin AST mutable branch
