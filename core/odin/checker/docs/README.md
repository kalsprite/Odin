# Odin Checker Package

Semantic analysis and type checking for Odin AST, designed to mirror the architecture of the Odin compiler's C++ checker implementation.

## Overview

This package provides comprehensive semantic analysis including:

- **Type checking**: Validates type expressions and infers types
- **Name resolution**: Resolves identifiers across scopes
- **Semantic validation**: Enforces language rules and constraints
- **Dependency analysis**: Orders declarations for any-order compilation
- **Error reporting**: Provides detailed diagnostics with source locations

## Architecture

The checker follows a multi-phase design inspired by the Odin compiler's C++ implementation:

### Core Components

- **`Checker`**: Top-level type checker state
- **`Checker_Info`**: Symbol table and metadata repository
- **`Checker_Context`**: Per-operation checking context
- **`Decl_Info`**: Declaration metadata enabling any-order processing
- **`Scope`**: Hierarchical symbol scopes
- **`Entity`**: Declared symbols (variables, types, procedures, etc.)
- **`Type`**: Type representations
- **`Operand`**: Intermediate expression values during checking

### Module Organization

```
checker.odin        - Core types and public API
scope.odin          - Scope management and name resolution
types.odin          - Type system and type utilities
check_expr.odin     - Expression type checking (TODO)
check_stmt.odin     - Statement validation (TODO)
check_decl.odin     - Declaration processing (TODO)
check_type.odin     - Type expression checking (TODO)
builtins.odin       - Builtin procedure definitions (TODO)
```

## Usage

```odin
import "checker"

// Initialize checker
c := checker.init_checker()
defer checker.destroy_checker(c)

// Initialize basic types
checker.init_basic_types()

// Check files
success := checker.check_files(c, parsed_files)
```

## Design Principles

1. **Any-order declarations**: Declarations can reference symbols defined later through dependency tracking
2. **Thread-safety**: Fine-grained locking enables parallel checking (future enhancement)
3. **Untyped constants**: Maintains exact precision until conversion to typed context
4. **Error recovery**: Continues checking after errors to report multiple issues

## Implementation Status

### Completed
- ✅ Core type definitions (`Checker`, `Checker_Context`, `Checker_Info`)
- ✅ Entity and scope structures
- ✅ Type system foundation
- ✅ Scope management module
- ✅ Basic type utilities

### In Progress
- 🚧 Expression checking
- 🚧 Statement validation
- 🚧 Declaration processing
- 🚧 Type checking

### Planned
- ⏳ Builtin procedure definitions
- ⏳ Polymorphic type checking
- ⏳ Dependency graph construction
- ⏳ Parallel checking support
- ⏳ Comprehensive error reporting

## Relationship to Odin Compiler

This package is designed to eventually become a core library at `core:odin/checker`. It closely follows the design patterns of the Odin compiler's C++ checker implementation (found in `src/checker.cpp`, `src/check_*.cpp`):

- **38,000+ lines** of C++ implementation analyzed
- **6 modules**: checker, type, expression, statement, declaration, builtin
- **Threading model**: MPSC queues, RW mutexes, atomic operations
- **Dependency tracking**: Entity graph nodes with topological sorting

### Key Architectural Patterns Ported

1. **Operand model**: Addressing modes distinguish lvalues, rvalues, constants, types
2. **DeclInfo workflow**: Enables any-order declarations through lazy resolution
3. **Scope hierarchy**: Parent-child linking with import semantics
4. **Type canonicalization**: Base type unwrapping for structural comparison
5. **Error contexts**: Position-aware error reporting with source locations

## Contributing

This package is being developed to match the Odin compiler's semantic analysis behavior. When contributing:

- Reference the C++ implementation for design decisions
- Maintain compatibility with `core:odin/ast` package conventions
- Follow Odin core library style guidelines
- Add tests for semantic validation rules

## References

- Odin compiler source: `/mnt/c/odin/src/checker*.{cpp,hpp}`
- C++ checker modules analyzed:
  - `checker.cpp` (7.5k lines) - Architecture and coordination
  - `check_type.cpp` (3.8k lines) - Type validation
  - `check_expr.cpp` (12.5k lines) - Expression checking
  - `check_stmt.cpp` (3k lines) - Statement validation
  - `check_decl.cpp` (2.2k lines) - Declaration processing
  - `check_builtin.cpp` (7.7k lines) - Builtin procedures

## License

This package is intended for inclusion in the Odin core library and follows Odin's BSD-3-Clause license.
