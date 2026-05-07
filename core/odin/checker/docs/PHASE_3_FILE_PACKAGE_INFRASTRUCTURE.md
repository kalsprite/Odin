# Phase 3: File/Package Tracking System Architecture

**Date**: 2025-10-08
**Status**: Design Document
**Author**: Checker Port Team

## Overview

This document outlines the architecture for file and package tracking in the native Odin checker, designed to bridge the gap between C++'s mutable AST structures and Odin's immutable `core:odin/ast` structures.

**IMPORTANT**: The types defined in this document (file flags, package metadata) are **NOT present in Odin's `core:odin/ast`** module. The `ast.File` and `ast.Package` structures are minimal and immutable. Therefore, we use **external maps in `Checker_Info`** to track this metadata, following the established pattern from previous phases (AST flags, entity maps, scope maps).

## Executive Summary

The C++ compiler stores extensive metadata directly on `AstFile` and `AstPackage` structures. Since Odin's `ast.File` and `ast.Package` are immutable, we must use **external maps** in `Checker_Info` to track this metadata, following the same pattern established for AST flags and entity mappings.

## C++ vs Odin Infrastructure Comparison

### File-Level Structures

#### C++ AstFile (parser.hpp:107-173)

**Key Fields**:
```cpp
struct AstFile {
    i32          id;
    u32          flags;              // AstFileFlag enum
    AstPackage * pkg;
    Scope *      scope;              // Set by checker

    // Parsing state
    Tokenizer    tokenizer;          // Tokenizer state
    Array<Token> tokens;             // All tokens
    Token        package_token;
    String       package_name;

    // Feature/vet flags
    u64          vet_flags;
    u64          feature_flags;
    bool         vet_flags_set;
    bool         feature_flags_set;

    // Delayed declaration processing
    Array<Ast *> delayed_decls_queues[AstDelayQueue_COUNT];

    // Parsing metrics
    f64          time_to_tokenize;
    f64          time_to_parse;

    // LLVM metadata (codegen)
    struct LLVMOpaqueMetadata *llvm_metadata;
    struct LLVMOpaqueMetadata *llvm_metadata_scope;
};
```

#### Odin ast.File (core:odin/ast)

**Key Fields**:
```odin
File :: struct {
    using node: Node,
    id: int,
    pkg: ^Package,
    fullpath: string,
    src: string,
    tags: [dynamic]tokenizer.Token,
    docs: ^Comment_Group,
    pkg_decl: ^Package_Decl,
    pkg_token: tokenizer.Token,
    pkg_name: string,
    decls: [dynamic]^Stmt,
    imports: [dynamic]^Import_Decl,
    directive_count: int,
    comments: [dynamic]^Comment_Group,
    syntax_warning_count: int,
    syntax_error_count: int,
}
```

**Gap Analysis**:
- ✅ Has: id, pkg, fullpath, pkg_token, pkg_name, decls, comments
- ❌ Missing: scope (needed for checker), flags, vet_flags, feature_flags
- ❌ Missing: delayed_decls_queues (needed for import/foreign/expr processing)
- ❌ Missing: Parsing metrics (time_to_tokenize, time_to_parse)
- ❌ Missing: LLVM metadata (needed for codegen)

### Package-Level Structures

#### C++ AstPackage (parser.hpp:193-215)

**Key Fields**:
```cpp
struct AstPackage {
    PackageKind           kind;
    isize                 id;
    String                name;
    String                fullpath;
    Array<AstFile *>      files;

    // Thread-safety
    BlockingMutex         files_mutex;
    BlockingMutex         foreign_files_mutex;
    BlockingMutex         type_and_value_mutex;

    // Export queue (MPMC)
    MPMCQueue<AstPackageExportedEntity> exported_entity_queue;

    // Set by checker
    Scope *               scope;
    DeclInfo *            decl_info;
    bool                  is_extra;
};
```

#### Odin ast.Package (core:odin/ast)

**Key Fields**:
```odin
Package :: struct {
    using node: Node,
    kind: Package_Kind,
    id: int,
    name: string,
    fullpath: string,
    files: map[string]^File,
    user_data: rawptr,
}

Package_Kind :: enum {
    Normal,
    Runtime,
    Init,
}
```

**Gap Analysis**:
- ✅ Has: kind, id, name, fullpath, files
- ❌ Missing: scope (needed for checker)
- ❌ Missing: decl_info (needed for package-level declarations)
- ❌ Missing: is_extra flag
- ❌ Missing: exported_entity_queue (for multi-threading)
- ⚠️ Note: C++ has `Package_Builtin` kind, Odin doesn't

## Proposed Architecture

### 1. File Metadata Tracking

Add to `Checker_Info` structure:

```odin
Checker_Info :: struct {
    // ... existing fields ...

    // File scope storage (already exists - Bug #4 fix)
    // C++ Reference: checker.cpp:5723 - f->scope = s
    scopes: map[^ast.File]^Scope,

    // Phase 3: File flags storage
    // C++ Reference: parser.hpp:109 - u32 flags
    // NOTE: C++ uses u32 with bit operations, we use proper bit_set
    file_flags: map[^ast.File]Ast_File_Flags,

    // Phase 3: Vet and feature flags
    // C++ Reference: parser.hpp:128-131
    file_vet_flags: map[^ast.File]u64,
    file_feature_flags: map[^ast.File]u64,
    file_vet_flags_set: map[^ast.File]bool,
    file_feature_flags_set: map[^ast.File]bool,

    // Phase 3: Delayed declaration queues (already exists - Phase 30C)
    // C++ Reference: parser.hpp:162 - delayed_decls_queues[AstDelayQueue_COUNT]
    delayed_decls_import: map[^ast.File][dynamic]^ast.Stmt,
    delayed_decls_foreign_block: map[^ast.File][dynamic]^ast.Stmt,
    delayed_decls_expr: map[^ast.File][dynamic]^ast.Expr,

    // Phase 3: Parsing metrics (optional, for diagnostics)
    // C++ Reference: parser.hpp:153-154
    file_time_to_tokenize: map[^ast.File]f64,
    file_time_to_parse: map[^ast.File]f64,

    // Phase 3: LLVM metadata (deferred to codegen phase)
    // C++ Reference: parser.hpp:170-171
    // file_llvm_metadata: map[^ast.File]^LLVM_Metadata,
    // file_llvm_metadata_scope: map[^ast.File]^LLVM_Metadata,
}
```

### 2. Package Metadata Tracking

Add to `Checker_Info` structure:

```odin
Checker_Info :: struct {
    // ... existing fields ...

    // Phase 3: Package scope storage
    // C++ Reference: parser.hpp:212 - Scope *scope
    package_scopes: map[^ast.Package]^Scope,

    // Phase 3: Package declaration info
    // C++ Reference: parser.hpp:213 - DeclInfo *decl_info
    package_decl_infos: map[^ast.Package]^Decl_Info,

    // Phase 3: Package extra flag
    // C++ Reference: parser.hpp:214 - bool is_extra
    package_is_extra: map[^ast.Package]bool,

    // Phase 3: Exported entity queue (for multi-threading)
    // C++ Reference: parser.hpp:209 - MPMCQueue<AstPackageExportedEntity>
    package_exported_entity_queues: map[^ast.Package]MPSC_Queue(Package_Exported_Entity),
}

// Package_Exported_Entity represents an exported entity from a package
// C++ Reference: parser.hpp:188-191
Package_Exported_Entity :: struct {
    identifier: ^ast.Node,  // C++ line 189: Ast *identifier
    entity: ^Entity,        // C++ line 190: Entity *entity
}
```

### 3. Helper Functions

Add accessor functions to encapsulate map operations:

```odin
// File scope accessors
get_file_scope :: proc(info: ^Checker_Info, file: ^ast.File) -> ^Scope {
    return info.scopes[file]
}

set_file_scope :: proc(info: ^Checker_Info, file: ^ast.File, scope: ^Scope) {
    info.scopes[file] = scope
}

// File flags accessors
get_file_flags :: proc(info: ^Checker_Info, file: ^ast.File) -> Ast_File_Flags {
    return info.file_flags[file] or_else {}
}

set_file_flags :: proc(info: ^Checker_Info, file: ^ast.File, flags: Ast_File_Flags) {
    info.file_flags[file] = flags
}

add_file_flag :: proc(info: ^Checker_Info, file: ^ast.File, flag: Ast_File_Flag) {
    flags := get_file_flags(info, file)
    flags += {flag}
    info.file_flags[file] = flags
}

has_file_flag :: proc(info: ^Checker_Info, file: ^ast.File, flag: Ast_File_Flag) -> bool {
    return flag in get_file_flags(info, file)
}

// Package scope accessors
get_package_scope :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> ^Scope {
    return info.package_scopes[pkg]
}

set_package_scope :: proc(info: ^Checker_Info, pkg: ^ast.Package, scope: ^Scope) {
    info.package_scopes[pkg] = scope
}

// Package decl_info accessors
get_package_decl_info :: proc(info: ^Checker_Info, pkg: ^ast.Package) -> ^Decl_Info {
    return info.package_decl_infos[pkg]
}

set_package_decl_info :: proc(info: ^Checker_Info, pkg: ^ast.Package, decl: ^Decl_Info) {
    info.package_decl_infos[pkg] = decl
}

// Delayed declaration queue accessors
get_delayed_imports :: proc(info: ^Checker_Info, file: ^ast.File) -> [dynamic]^ast.Stmt {
    queue, ok := info.delayed_decls_import[file]
    if !ok {
        info.delayed_decls_import[file] = make([dynamic]^ast.Stmt)
        return info.delayed_decls_import[file]
    }
    return queue
}

add_delayed_import :: proc(info: ^Checker_Info, file: ^ast.File, stmt: ^ast.Stmt) {
    queue := get_delayed_imports(info, file)
    append(&queue, stmt)
    info.delayed_decls_import[file] = queue
}
```

## Implementation Strategy

### Phase 3A: File Infrastructure (Priority 1)

**Goal**: Add file-level metadata tracking

**Tasks**:
1. Add file metadata maps to `Checker_Info`
2. Implement file accessor functions
3. Update existing code using `scopes` map (already done)
4. Add file flag tracking (AstFileFlag enum)
5. Add vet/feature flag tracking

**Files Modified**:
- `/mnt/d/dev/checker/checker.odin` - Add maps to Checker_Info
- `/mnt/d/dev/checker/file_helpers.odin` - New file with accessor functions

**Verification**:
- Compile successfully
- Verify existing `scopes` map usage still works
- Test file flag get/set operations

### Phase 3B: Package Infrastructure (Priority 2)

**Goal**: Add package-level metadata tracking

**Tasks**:
1. Add package metadata maps to `Checker_Info`
2. Implement package accessor functions
3. Add `Package_Exported_Entity` structure
4. Add exported entity queue infrastructure

**Files Modified**:
- `/mnt/d/dev/checker/checker.odin` - Add maps to Checker_Info
- `/mnt/d/dev/checker/package_helpers.odin` - New file with accessor functions

**Verification**:
- Compile successfully
- Test package scope get/set operations
- Test decl_info tracking

### Phase 3C: Delayed Declaration Integration (Priority 3)

**Goal**: Integrate delayed declaration queue infrastructure

**Tasks**:
1. Verify delayed_decls_* maps (already exist from Phase 30C)
2. Add queue accessor functions
3. Document integration with existing checker code

**Files Modified**:
- `/mnt/d/dev/checker/file_helpers.odin` - Add delayed decl accessors

**Note**: This work may already be complete from Phase 30C. Verify implementation.

### Phase 3D: Optional Enhancements (Priority 4)

**Goal**: Add optional diagnostic features

**Tasks**:
1. Add parsing metrics tracking (time_to_tokenize, time_to_parse)
2. Add file error tracking
3. Add package kind validation

**Files Modified**:
- `/mnt/d/dev/checker/checker.odin` - Add optional metrics maps
- `/mnt/d/dev/checker/diagnostics.odin` - New file for metrics

**Deferred**:
- LLVM metadata (wait for codegen phase)

## Integration Points

### 1. File Scope Creation

**C++ Reference**: `checker.cpp:5723` - `f->scope = s`

**Current Odin Implementation**: Already integrated via Bug #4 fix
```odin
// In create_scope_from_file
info.scopes[file] = scope
```

### 2. Delayed Declaration Processing

**C++ Reference**: `checker.cpp:5892-5953`

**Current Odin Implementation**: Maps exist from Phase 30C
```odin
// In check_file_delayed_decls
import_queue := info.delayed_decls_import[file]
foreign_queue := info.delayed_decls_foreign_block[file]
expr_queue := info.delayed_decls_expr[file]
```

### 3. Package Scope Attachment

**C++ Reference**: `parser.hpp:212` - Set during checker initialization

**Proposed Odin Implementation**:
```odin
// In init_checker_info or add_package
set_package_scope(info, pkg, pkg_scope)
```

### 4. File Flag Queries

**C++ Reference**: `parser.hpp:92-98` - AstFileFlag enum

**Proposed Odin Implementation**:
```odin
// Check if file is lazy
if has_file_flag(info, file, .Is_Lazy) {
    // Handle lazy loading
}

// Check if file is private
if has_file_flag(info, file, .Is_Private_File) {
    // Enforce visibility
}

// Add multiple flags
flags: Ast_File_Flags = {.Is_Private_File, .No_Instrumentation}
set_file_flags(info, file, flags)
```

## File Flag Definitions

Add to `checker.odin`:

```odin
// Ast_File_Flag controls file-level behavior
// C++ Reference: enum AstFileFlag in parser.hpp:91-98
Ast_File_Flag :: enum u32 {
    Is_Private_Pkg       = 0,  // 1<<0 - Package is private
    Is_Private_File      = 1,  // 1<<1 - File is private
    Is_Lazy              = 4,  // 1<<4 - Lazy loading enabled
    No_Instrumentation   = 5,  // 1<<5 - Disable instrumentation
}

Ast_File_Flags :: bit_set[Ast_File_Flag;u32]
```

## Package Kind Alignment

**C++ Package Kinds** (parser.hpp:77-82):
```cpp
enum PackageKind {
    Package_Normal,
    Package_Runtime,
    Package_Init,
    Package_Builtin,
};
```

**Odin Package_Kind** (core:odin/ast):
```odin
Package_Kind :: enum {
    Normal,
    Runtime,
    Init,
}
```

**Issue**: Odin's `Package_Kind` is missing `Builtin` variant.

**Resolution Options**:
1. **Use external flag**: Add `package_is_builtin: map[^ast.Package]bool` to Checker_Info
2. **Ignore**: Builtin package may be handled specially in C++, may not need variant
3. **Request upstream change**: Ask Odin team to add `.Builtin` to Package_Kind enum

**Recommendation**: Option 1 (use external flag) for now, evaluate need later.

## Memory Management

All maps in `Checker_Info` will be allocated using the checker's allocator and cleaned up when the checker is destroyed.

**Initialization**:
```odin
init_checker_info :: proc(info: ^Checker_Info, allocator: runtime.Allocator) {
    // ... existing initialization ...

    // Phase 3: Initialize file maps
    info.file_flags = make(map[^ast.File]Ast_File_Flags, allocator)
    info.file_vet_flags = make(map[^ast.File]u64, allocator)
    info.file_feature_flags = make(map[^ast.File]u64, allocator)
    info.file_vet_flags_set = make(map[^ast.File]bool, allocator)
    info.file_feature_flags_set = make(map[^ast.File]bool, allocator)

    // Phase 3: Initialize package maps
    info.package_scopes = make(map[^ast.Package]^Scope, allocator)
    info.package_decl_infos = make(map[^ast.Package]^Decl_Info, allocator)
    info.package_is_extra = make(map[^ast.Package]bool, allocator)
    info.package_exported_entity_queues = make(map[^ast.Package]MPSC_Queue(Package_Exported_Entity), allocator)
}
```

**Cleanup**:
```odin
destroy_checker_info :: proc(info: ^Checker_Info) {
    // Phase 3: Clean up file maps
    delete(info.file_flags)
    delete(info.file_vet_flags)
    delete(info.file_feature_flags)
    delete(info.file_vet_flags_set)
    delete(info.file_feature_flags_set)

    // Clean up delayed decl queues
    for file, queue in info.delayed_decls_import {
        delete(queue)
    }
    delete(info.delayed_decls_import)

    for file, queue in info.delayed_decls_foreign_block {
        delete(queue)
    }
    delete(info.delayed_decls_foreign_block)

    for file, queue in info.delayed_decls_expr {
        delete(queue)
    }
    delete(info.delayed_decls_expr)

    // Phase 3: Clean up package maps
    delete(info.package_scopes)
    delete(info.package_decl_infos)
    delete(info.package_is_extra)

    for pkg, queue in info.package_exported_entity_queues {
        // Clean up MPSC queue
        mpsc_queue_destroy(&queue)
    }
    delete(info.package_exported_entity_queues)

    // ... existing cleanup ...
}
```

## Testing Strategy

### Unit Tests

1. **File Metadata**:
   - Test `get_file_scope` / `set_file_scope`
   - Test `get_file_flags` / `set_file_flags` / `has_file_flag`
   - Test vet/feature flag tracking

2. **Package Metadata**:
   - Test `get_package_scope` / `set_package_scope`
   - Test `get_package_decl_info` / `set_package_decl_info`
   - Test package extra flag

3. **Delayed Declarations**:
   - Test `get_delayed_imports` / `add_delayed_import`
   - Test queue operations
   - Test multi-file scenarios

### Integration Tests

1. **File Processing**:
   - Parse multiple files
   - Verify scope attachment
   - Verify delayed declaration queueing

2. **Package Processing**:
   - Process multi-file package
   - Verify package scope creation
   - Verify exported entity tracking

## References

### C++ Source Files

- `/mnt/c/odin/src/parser.hpp:107-173` - AstFile structure
- `/mnt/c/odin/src/parser.hpp:193-215` - AstPackage structure
- `/mnt/c/odin/src/parser.hpp:91-98` - AstFileFlag enum
- `/mnt/c/odin/src/parser.hpp:77-82` - PackageKind enum
- `/mnt/c/odin/src/parser.hpp:100-105` - AstDelayQueueKind enum
- `/mnt/c/odin/src/checker.cpp:5723` - File scope attachment
- `/mnt/c/odin/src/checker.cpp:5892-5953` - Delayed declaration processing

### Odin Source Files

- `/home/kalsprite/Odin/core/odin/ast/ast.odin` - ast.File and ast.Package
- `/mnt/d/dev/checker/checker.odin` - Checker_Info structure
- `/mnt/d/dev/checker/check_decl.odin` - Declaration checking

## Summary

This architecture provides complete file and package metadata tracking without modifying the immutable `core:odin/ast` structures. By using external maps in `Checker_Info`, we maintain the same capabilities as the C++ implementation while respecting Odin's design principles.

The phased implementation approach allows incremental integration with existing checker code, with clear verification points at each phase.
