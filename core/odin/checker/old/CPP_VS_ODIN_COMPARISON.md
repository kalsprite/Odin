# C++ vs Odin Checker Architecture Comparison

## Overview

The C++ Odin compiler stores semantic data **directly on AST structs**, making them mutable. Our Odin checker port initially used **external maps** to avoid mutating the `core:odin/ast` package. This document tracks the migration to a semantic AST architecture that matches the C++ approach.

## C++ Architecture (Reference Implementation)

### AstFile Structure (C++ parser.hpp:108-173)
```cpp
struct AstFile {
    i32          id;
    u32          flags;                    // ✅ File-level flags
    AstPackage * pkg;
    Scope *      scope;                    // ✅ Direct scope pointer

    Ast *        pkg_decl;
    String       fullpath;
    // ... tokenizer fields ...

    u64          vet_flags;                // ✅ Vet directive flags
    u64          feature_flags;            // ✅ Feature directive flags
    bool         vet_flags_set;            // ✅ Whether flags were set
    bool         feature_flags_set;        // ✅ Whether flags were set

    // ... parser state fields ...

    Slice<Ast *> decls;
    Array<Ast *> imports;

    // Delayed declaration queues
    Array<Ast *> delayed_decls_queues[AstDelayQueue_COUNT];  // ✅ Direct arrays

    // ... parser metadata ...
};
```

### AstPackage Structure (C++ parser.hpp:194-215)
```cpp
struct AstPackage {
    PackageKind           kind;
    isize                 id;
    String                name;
    String                fullpath;
    Array<AstFile *>      files;
    isize                 order;           // ✅ Package order for dependency resolution

    // Thread-safety mutexes
    BlockingMutex         files_mutex;
    BlockingMutex         type_and_value_mutex;

    MPMCQueue<AstPackageExportedEntity> exported_entity_queue;  // ✅ Direct queue

    // Semantic fields (set by checker)
    Scope *   scope;                       // ✅ Package scope
    DeclInfo *decl_info;                   // ✅ Package decl info
    bool      is_extra;                    // ✅ Extra package flag
};
```

### Ast Base Structure (C++ parser.hpp:851-865)
```cpp
struct Ast {
    AstKind      kind;
    u8           state_flags;              // ✅ State flags directly on node
    u8           viral_state_flags;        // ✅ Viral flags directly on node
    i32          file_id;                  // ✅ File reference
    TypeAndValue tav;                      // ✅ Type and value directly on node (NOT a pointer!)

    union {
        // All AST variant types here
        AstBlockStmt     BlockStmt;        // Has scope field
        AstIfStmt        IfStmt;           // Has scope field
        AstProcType      ProcType;         // Has scope field
        AstStructType    StructType;       // Has scope field
        // ... etc ...
    };
};
```

**Key Observation**: In C++, `TypeAndValue` is stored **by value**, not by pointer! This is a critical performance optimization mentioned in the comment.

## Odin Port Architecture

### Initial Design (External Maps)
We started with external maps because `core:odin/ast` was treated as immutable:

```odin
// Checker_Info had these maps:
scopes:              map[^ast.File]^Scope           // ❌ Now deleted
file_flags:          map[^ast.File]Ast_File_Flags   // 🔄 Still external
file_vet_flags:      map[^ast.File]u64              // 🔄 Still external
delayed_decls_import: map[^ast.File][dynamic]^ast.Stmt  // 🔄 Still external

package_scopes:      map[^ast.Package]^Scope        // 🔄 Still external
package_decl_infos:  map[^ast.Package]^Decl_Info   // 🔄 Still external
package_order:       map[^ast.Package]int           // 🔄 Still external

ast_scope_map:       map[rawptr]^Scope              // ❌ Now deleted
type_and_value_map:  map[rawptr]Type_And_Value     // ❌ Now deleted
ast_state_flags:     map[rawptr]State_Flags         // ❌ Now deleted
ast_viral_flags:     map[rawptr]Viral_State_Flags   // ❌ Now deleted
```

### Current Design (Hybrid Approach)

After refactoring, we now have:

```odin
// AST now has semantic fields (matching C++):
Node :: struct {
    pos:               tokenizer.Pos,
    end:               tokenizer.Pos,
    state_flags:       Node_State_Flags,           // ✅ Matches C++ (on node)

    viral_state_flags: Node_Viral_State_Flags,     // ✅ Matches C++ (on node)
    file_id:           i32,                         // ✅ Matches C++ (on node)
    tav:               ^Type_And_Value,             // ⚠️  Pointer (C++ uses value!)
}

File :: struct {
    // ... base fields ...
    scope: ^Scope,                                  // ✅ Matches C++ (on File)

    // ❌ Missing from AST (still in external maps):
    // - flags (u32)
    // - vet_flags (u64)
    // - feature_flags (u64)
    // - vet_flags_set (bool)
    // - feature_flags_set (bool)
    // - delayed_decls_queues arrays
}

Package :: struct {
    // ... base fields ...

    // ❌ Missing from AST (still in external maps):
    // - scope
    // - decl_info
    // - is_extra
    // - order
}
```

## Analysis: Why Keep Some Maps External?

### Legitimate Reasons to Keep External

Some maps we're keeping external **differ from C++** intentionally:

#### 1. File Flags (`file_flags`, `file_vet_flags`, etc.)
- **C++ approach**: Stored directly on `AstFile`
- **Our approach**: External maps
- **Justification**: These are **build-configuration-specific**. Different build contexts might need different flags for the same AST.
- **Verdict**: ⚠️ **Questionable** - C++ stores them on the file because they're parsed from file-level directives (`#vet`, `#private-file`, etc.). These are part of the source code, not build config.

#### 2. Delayed Declaration Queues
- **C++ approach**: Direct arrays on `AstFile` (`delayed_decls_queues[AstDelayQueue_COUNT]`)
- **Our approach**: External maps
- **Justification**: Temporary working state for checker algorithm
- **Verdict**: ⚠️ **Questionable** - C++ stores them on the file. They're temporary, but file-local.

#### 3. Package Metadata
- **C++ approach**: Direct fields on `AstPackage` (`scope`, `decl_info`, `is_extra`, `order`)
- **Our approach**: External maps
- **Justification**: Keep Package struct minimal
- **Verdict**: ❌ **Inconsistent with C++** - These are semantic fields that C++ stores directly.

### Real Architectural Difference

The **one major difference** between C++ and our implementation:

| Aspect | C++ | Odin Port |
|--------|-----|-----------|
| **AST Mutability** | Fully mutable, semantic fields added during checking | Originally immutable, now hybrid |
| **File/Package structs** | Include checker-specific metadata | Kept minimal, metadata in maps |
| **TypeAndValue storage** | By value on Ast node (performance!) | By pointer on Node |

## Recommendations

### Option 1: Match C++ Exactly (Recommended)
Add these fields to `core:odin/ast` to fully match C++:

```odin
File :: struct {
    // ... existing fields ...

    // Semantic fields (populated by checker)
    scope:             ^Scope,
    flags:             File_Flags,      // Add this
    vet_flags:         u64,             // Add this
    feature_flags:     u64,             // Add this
    vet_flags_set:     bool,            // Add this
    feature_flags_set: bool,            // Add this

    // Delayed declaration queues (temporary checker state)
    delayed_decls_import:        [dynamic]^Stmt,  // Add this
    delayed_decls_foreign_block: [dynamic]^Stmt,  // Add this
    delayed_decls_expr:          [dynamic]^Expr,  // Add this
}

Package :: struct {
    // ... existing fields ...

    // Semantic fields (populated by checker)
    scope:      ^Scope,      // Add this
    decl_info:  ^Decl_Info,  // Add this
    is_extra:   bool,        // Add this
    order:      int,         // Add this

    exported_entity_queue: MPSC_Queue(Package_Exported_Entity),  // Add this
}

// IMPORTANT: Change tav from pointer to value!
Node :: struct {
    // ... existing fields ...
    tav: Type_And_Value,  // Change from ^Type_And_Value to value type
}
```

**Benefits**:
- ✅ Perfect C++ parity
- ✅ Better performance (no map lookups, tav by value)
- ✅ Simpler checker code
- ✅ Thread-safety easier (mutex per File/Package instead of global maps)

**Drawbacks**:
- ⚠️  AST structs become larger
- ⚠️  Checker-specific fields pollute general-purpose AST

### Option 2: Current Hybrid (What We Have Now)
Keep file/package metadata external, but AST node semantic fields direct.

**Benefits**:
- ✅ Minimal AST structs
- ✅ Clear separation of concerns

**Drawbacks**:
- ❌ Inconsistent with C++ reference
- ❌ Map lookup overhead for common operations
- ❌ External map key pointer issues (rawptr casting)
- ❌ Thread-safety harder (need global mutexes for maps)

### Option 3: Pure External Maps (Original Design)
Keep everything external (what we started with).

**Verdict**: ❌ **Rejected** - We already moved away from this because it was too slow and complex.

## Performance Comparison

### TypeAndValue Access (Hot Path)

**C++ (by value on node)**:
```cpp
TypeAndValue tav = expr->tav;  // Direct field access, value copy
```
- **Cost**: 1 field access + struct copy (~40 bytes)
- **Cache behavior**: Excellent (co-located with node)

**Odin (by pointer on node)**:
```odin
tav := node.tav^  // Field access + pointer dereference
```
- **Cost**: 1 field access + 1 pointer dereference
- **Cache behavior**: Good (but extra indirection)

**Odin (external map - old approach)**:
```odin
tav := type_and_value_map[rawptr(node)]  // Map lookup
```
- **Cost**: Hash computation + map lookup + possible collision chain
- **Cache behavior**: Poor (map entries scattered)

### Conclusion

We've successfully moved the **critical hot-path data** (entity, tav, scope, flags) onto AST nodes. The remaining external maps (file/package metadata) have **lower access frequency** and represent a conscious trade-off between AST size and checker complexity.

However, **C++ stores all of these on the structs**, suggesting our external maps might be premature optimization. The C++ approach values simplicity and performance over minimalism.

## Final Verdict

**Current state**:
- ✅ Hot-path data (tav, entity, scope, flags) now on AST nodes - **matches C++**
- ⚠️  File/package metadata still external - **differs from C++**
- ⚠️  tav stored by pointer instead of by value - **differs from C++**

**Recommendation**: Consider moving file/package metadata onto AST structs to fully match C++ architecture. The C++ implementation has proven performance characteristics, and our deviation adds complexity without clear benefit.
