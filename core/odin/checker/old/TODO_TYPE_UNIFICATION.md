# Type Unification TODO

## Problem
The checker defines its own `Entity`, `Type`, `Scope`, `Decl_Info` and related types in `checker.odin`, but the semantic AST at `/mnt/c/odin/core/odin/ast/semantic_types.odin` already defines these same types.

The AST nodes reference `^ast.Entity`, but the checker uses `^checker.Entity`. These are different types requiring type casting via rawptr.

## Root Cause
The semantic types were added to the AST package to allow AST nodes to have semantic fields (e.g., `Ident.entity: ^Entity`). The checker was ported before this refactoring and still has its own duplicate definitions.

## Solution
1. Delete all duplicate type definitions from `checker.odin`:
   - Entity and all Entity_* types
   - Type and all Type_* types
   - Scope
   - Decl_Info
   - All supporting enums and bit sets

2. Import these types from `ast` package (which is `odin_ast` package)

3. Add type aliases for convenience at top of checker.odin:
   ```odin
   Entity :: ast.Entity
   Type :: ast.Type
   Scope :: ast.Scope
   Decl_Info :: ast.Decl_Info
   // ... etc
   ```

4. Remove all type casts in:
   - entity_helpers.odin (lines 226, 229, 245, 248)
   - check_proc.odin (lines 1153, 1705)

5. Keep only checker-specific types that don't belong in AST:
   - Checker
   - Checker_Info
   - Checker_Context
   - Operand
   - Build-related types
   - Etc.

## Benefits
- Eliminates type casting
- Single source of truth for semantic types
- Easier to maintain
- Matches the architectural intent of semantic AST

## Status
Deferred - requires dedicated refactoring session to avoid breaking many files at once.
Current workaround: type casting via rawptr (works because memory layouts are identical).
