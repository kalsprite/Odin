# Phase 25 Group 2: Import/Export Processing - Implementation Summary

## Overview

This phase implements the import/export processing functions for the native Odin checker, handling package dependencies and entity visibility across compilation units.

## Files Modified/Created

### Created Files
- `/mnt/d/dev/checker/check_import.odin` (730 lines)

## Implementation Details

### 1. check_add_import_decl (Lines 56-176)

**Purpose**: Process import declaration and add imported package to scope

**C++ Reference**: checker.cpp:5254-5336

**Key Features**:
- Validates import declarations are at file scope
- Resolves import path to package
- Handles special builtin/intrinsics packages
- Creates Entity_Import_Name entities
- Adds entities to scope
- Marks scopes as imported
- Validates identifier names

**Adaptations from C++**:
- AST immutability: Uses external flag map instead of `state_flags` on AST nodes
- Simplified attribute handling: C++ version processes `@(require)` attributes
- Name generation: Simplified from C++ `path_to_entity_name` function

**Pattern**:
```odin
check_add_import_decl :: proc(ctx: ^Checker_Context, import_decl: ^ast.Import_Decl) {
    // Check if already handled
    if has_ast_flag(ctx, decl_node, .Been_Handled) {
        return
    }
    set_ast_flag(ctx, decl_node, .Been_Handled)

    // Resolve package from import path
    import_path := import_decl.fullpath
    scope := resolve_package_scope(import_path)

    // Create import entity
    import_entity := alloc_entity_import_name(...)
    add_entity(ctx, parent_scope, nil, import_entity)

    // Mark scope as imported
    scope_import(parent_scope, scope)
}
```

### 2. check_import_entities (Lines 178-229)

**Purpose**: Import entities from imported packages into current scope in dependency order

**C++ Reference**: checker.cpp:5817-5926

**Key Features**:
- Generates import dependency graph
- Performs topological sort
- Detects circular imports
- Processes imports in dependency order
- Handles when-statement conditional imports

**Simplifications**:
- Single-threaded vs C++ multi-threaded processing
- Simplified file processing (C++ uses delayed_decls_queues)
- No dynamic package loading during processing

**Pattern**:
```odin
check_import_entities :: proc(c: ^Checker) {
    // Build dependency graph
    dep_graph := generate_import_dependency_graph(c, c.allocator)
    defer destroy_import_graph(&dep_graph)

    // Topologically sort packages
    package_order := topological_sort_packages(&dep_graph, c.allocator)
    defer delete(package_order)

    // Process in dependency order
    for node in package_order {
        for file in node.pkg.files {
            // Process import declarations
            check_add_import_decl(&ctx, import_decl)
        }
    }
}
```

### 3. check_export_entities (Lines 521-548)

**Purpose**: Mark entities for export based on visibility rules

**C++ Reference**: checker.cpp:5777-5815

**Key Differences from C++**:
- Odin uses naming convention (no leading underscore) vs explicit export declarations
- C++ version drains `exported_entity_queue` and adds to package scope
- Our simplified version relies on entity naming conventions set during creation

**Pattern**:
```odin
check_export_entities :: proc(c: ^Checker) {
    // In Odin, export is automatic based on naming
    // Entities not starting with '_' are exported

    for path, pkg in c.info.packages {
        // C++ would drain pkg->exported_entity_queue here
        // For our implementation, visibility is determined
        // during entity creation based on name
    }
}
```

### 4. generate_import_dependency_graph (Lines 231-275)

**Purpose**: Build dependency graph of imports for cycle detection and ordering

**C++ Reference**: checker.cpp:5132-5168

**Key Features**:
- Creates nodes for all packages
- Builds directed edges for import relationships
- Sets dependency counts for topological sort
- Stores checker reference for package lookups

**Data Structures**:
```odin
Import_Graph_Node :: struct {
    pkg:       ^ast.Package,
    scope:     ^Scope,
    pred:      map[^Import_Graph_Node]struct{},  // Importers
    succ:      map[^Import_Graph_Node]struct{},  // Imported packages
    index:     int,
    dep_count: int,  // For topological sort
}

Import_Graph :: struct {
    nodes:     map[rawptr]^Import_Graph_Node,
    checker:   ^Checker,
    allocator: runtime.Allocator,
}
```

## Helper Functions

### add_import_dependency_node (Lines 277-350)
- Recursively processes declarations to find imports
- Adds graph edges for import relationships
- Handles when-statement branches
- **Adaptation**: Takes parent_pkg and parent_file parameters to work around immutable AST

### topological_sort_packages (Lines 352-417)
- Implements Kahn's algorithm for topological sorting
- Detects cycles and reports errors
- Returns packages in dependency order
- **Simplification**: Uses linear search vs C++ priority queue

### find_import_cycle (Lines 419-441)
- Detects circular imports using DFS
- Returns path forming the cycle
- Used for error reporting

### find_import_path_recursive (Lines 444-509)
- Recursive DFS for cycle detection
- Builds path from current to target node
- Tracks visited nodes to prevent infinite loops

## Utility Functions

### Path and Name Processing
- `path_to_entity_name`: Extract entity name from import path
- `is_string_an_identifier`: Validate identifier syntax
- `is_package_name_reserved`: Check for builtin/intrinsics

### Identifier Helpers
- `is_letter`: Check if rune is letter
- `is_digit`: Check if rune is digit
- `is_blank_ident`: Check for "_" identifier

### Visibility
- `is_entity_exported`: Check if entity is public (no leading underscore)

### AST Flag Management
- `has_ast_flag`: Check AST node flags
- `set_ast_flag`: Set AST node flags
- **Note**: Placeholders for external flag storage (AST is immutable)

### Context Management
- `reset_checker_context`: Reset context for new file
- `make_checker_context`: Create new checker context
- `add_entity_use`: Mark entity as used

## Architectural Notes

### AST Immutability
The C++ checker mutates AST nodes directly (e.g., `state_flags`, `viral_state_flags`). Our implementation uses external maps:
- `ctx.info.ast_state_flags` - Downward-propagating flags
- `ctx.info.ast_viral_flags` - Upward-propagating flags

### File Tracking
C++ AST nodes have a `file()` method. We pass `parent_pkg` and `parent_file` explicitly through the call chain.

### Multi-threading
The C++ version uses thread pools and MPMC queues for parallel processing. Our implementation is single-threaded, which simplifies the code but reduces performance on multi-core systems.

### Deferred Implementation
Several C++ features are simplified or deferred:
1. **Attribute Processing**: `@(require)` and other import attributes
2. **Export Queues**: `exported_entity_queue` MPMC processing
3. **Delayed Declaration Queues**: `delayed_decls_queues[AstDelayQueue_Import]`
4. **Dynamic Package Loading**: Package loading during import resolution

## Integration Points

### Used By:
- Global entity checking (processes imports before global entities)
- Package initialization (ensures dependency order)

### Uses:
- `entity.odin`: alloc_entity_import_name
- `scope.odin`: scope_import, is_scope_file, is_scope_pkg
- `entity_helpers.odin`: add_entity, is_entity_kind_exported
- `error.odin`: error_node for import errors

## C++ Equivalence

| Function | C++ Lines | Odin Lines | Semantic Equivalence |
|----------|-----------|------------|---------------------|
| check_add_import_decl | 5254-5336 | 56-176 | ✓ High (simplified attributes) |
| check_import_entities | 5817-5926 | 178-229 | ✓ Medium (single-threaded) |
| check_export_entities | 5777-5815 | 521-548 | ✓ Low (naming convention) |
| generate_import_dependency_graph | 5132-5168 | 231-275 | ✓ High |
| add_import_dependency_node | 5068-5129 | 277-350 | ✓ High |
| topological_sort (priority queue) | 5822-5871 | 352-417 | ✓ Medium (linear search) |
| find_import_path | 5175-5222 | 419-509 | ✓ High |

## Testing Considerations

### Test Cases Needed:
1. **Basic imports**: Single package importing another
2. **Circular imports**: Detect A→B→C→A cycles
3. **Multi-level imports**: A→B→C→D chains
4. **Conditional imports**: when-statement branches
5. **Builtin packages**: builtin and intrinsics handling
6. **Invalid imports**: Missing packages, invalid names
7. **Export visibility**: Underscore prefix hiding
8. **Dependency ordering**: Correct topological sort

### Error Scenarios:
- Cyclic imports (should report full cycle)
- Missing packages (should error with package name)
- Invalid import names (should suggest fix)
- Import at non-file scope (should error)

## Known Limitations

1. **Single-threaded**: No parallel processing of packages
2. **Simplified exports**: No explicit export declarations
3. **No attribute support**: Missing `@(require)` and other import attributes
4. **No delayed queues**: Processes imports immediately from decls
5. **External flag storage**: AST flag management needs integration with checker.odin maps

## Future Work

1. **Multi-threading**: Implement parallel package processing using MPMC queues
2. **Attribute processing**: Add support for import/export attributes
3. **Export declarations**: If Odin adds explicit export syntax
4. **Performance**: Replace linear search with heap-based priority queue
5. **AST flag integration**: Connect to global ast_state_flags map
6. **Package reloading**: Handle dynamic package discovery
7. **Import caching**: Cache resolved import paths

## Verification

To verify semantic equivalence with C++:
1. Compare dependency graph structure for same package set
2. Verify topological sort produces valid ordering
3. Test cycle detection matches C++ error reports
4. Confirm entity visibility matches C++ export rules
5. Validate import entity creation and scope insertion

## File Paths

- **Implementation**: `/mnt/d/dev/checker/check_import.odin`
- **C++ Reference**: `/mnt/c/odin/src/checker.cpp:5130-5926`
- **Support files**: `entity.odin`, `scope.odin`, `entity_helpers.odin`, `error.odin`
