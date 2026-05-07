# TODO Categories Reference

This document lists all TODO markers in the codebase by category, showing what work remains.

**Total TODOs:** 616 markers across 37 files

---

## By Priority Category

### Critical (Need for Runtime Testing)

3. **IMPLEMENTATION** (17 items) - Incomplete core features
    ⏸️ Remaining (12 items - intentionally stubbed for future work):
    - Attributes parsing - Needs attribute infrastructure
    - Package exported entity queue - Needs MPSC queue
    - order_in_src field - Field doesn't exist in Entity struct
    - Package dependency resolution - Needs package infrastructure
    - Operand.mode/proc_group - Needs Operand refactoring
    - SOA type completion - Needs type system enhancement
    - Tuple unpacking - Large feature (110 lines in C++)
    - Full type declaration checking - Intentional MVP stub
    - Objective-C methods - Platform-specific feature
    - Foreign procedure validation - Needs foreign function interface
    - Core runtime import - Needs runtime package setup

### Important (Performance & Correctness)

4. **THREADING** (31 items) - Parallel checking infrastructure
   - MPSC queue for work distribution
   - Worker thread coordination
   - Mutex and synchronization primitives

5. **SYNC** (7 items) - Synchronization primitives
   - mutex_lock/unlock operations
   - shared_guard, wait_group
   - Atomic operations

6. **CONCURRENCY** (5 items) - Thread-safe operations
   - Concurrent data structure access
   - Lock-free algorithms

### Nice to Have (Optimizations)

8. **INFRASTRUCTURE** (10 items) - Missing utility functions
    ⏸️ Remaining (9 items - require larger infrastructure):
    - Package scope mapping - Needs package infrastructure in Checker_Info
    - Path resolution helpers - Filesystem path utilities
    - builtin_pkg/intrinsics_pkg globals - Global package references
    - Package name comparison - Package structure doesn't fully exist
    - pkg_decl from ast.File - AST structure limitation
    - Package scope access - Package infrastructure
    - pkg.fullpath access - Package field doesn't exist
    - Doc format flags - Build context integration
    - add_untyped_expressions - Requires MPSC queue (stubbed)
    - add_dependency_to_set - Requires atomic operations and min_dep tracking

### Feature Specific


13. **VET** (3 items) - Code quality checks
    - Linting and style warnings
    - Best practice enforcement

16. **TARGET_FEATURES** (2 items) - CPU feature detection
      - ⏸️ Feature validation is a backend concern - it determines which procedures can be called based on CPU capabilities
      - ⏸️ Procedure disabling (.Disabled flag) affects code generation, not semantic analysis
      - ⏸️ The missing validation doesn't block type checking or compilation - it would just miss some edge-case errors about invalid CPU feature names


19. **DOCUMENTATION** (4 items) - Code documentation
    - Entity documentation extraction
    - API documentation generation

20. **DEBUG** (3 items) - Debugging support
    - Debug output and logging
    - Development-time checks

21. **PHASE** (2 items) - Implementation phases
    - Phased development markers
    - Feature completion tracking

---

## By File

### Core Checking Files
- `check_stmt.odin` - 89 TODOs (most)
- `check_expr.odin` - 76 TODOs
- `check_decl.odin` - 71 TODOs
- `check_type.odin` - 54 TODOs
- `check_proc.odin` - 47 TODOs

### Type System Files
- `types.odin` - 38 TODOs
- `type_info.odin` - 31 TODOs
- `name_canonicalization.odin` - 27 TODOs

### Support Files
- `checker.odin` - 42 TODOs
- `entity_helpers.odin` - 29 TODOs
- `error.odin` - 18 TODOs

---

## STRUCTURAL ISSUES:

STRUCTURAL TODO Analysis Report

  I've completed categorizing all 16 TODO(STRUCTURAL) items. Here's the comprehensive breakdown:

  Category 1: Entity Structure Additions (3 items)

  Requires modifying the Entity struct in checker.odin

  check_decl.odin:474-487 - Missing Entity fields for aliasing semantics:
  - decl_info: ^Decl_Info - Links entity to its declaration info
  - aliased_of: ^Entity - Tracks what this entity aliases
  - identifier: Atomic(^ast.Node) - Thread-safe AST node linking with atomic operations

  Impact: These fields are critical for proper alias handling in override_entity_in_scope. Currently aliasing works but loses some semantic information.

  ---
  Category 2: Checker_Info Infrastructure (2 items)

  Requires adding maps/queues to the Checker_Info struct

  check_decl.odin:282-285 - Missing MPSC queue for @require tracking:
  required_global_variable_queue: MPSC_Queue(^Entity)
  Purpose: Thread-safe enqueueing of @require-marked global variables for later verification

  entity_helpers.odin:997-1000 - Missing package scope tracking:
  // Need to track package scopes separately from file scopes
  Purpose: File scope → package scope navigation

  ---
  Category 3: Missing Helper Functions (5 items)

  Can potentially be implemented now

  1. check_decl.odin:396 - check_expr_with_type_hint
    - Fallback: Currently using check_expr_base
    - Impact: Low - fallback works
  2. check_decl.odin:423-430 - ast_token and type_of_expr
    - Purpose: Error reporting for @(rodata) violations
    - Impact: Medium - error messages less informative
  3. check_decl.odin:439-441 - check_rtti_type_disallowed
    - Purpose: RTTI type validation
    - Impact: Medium - missing runtime type validation
  4. check_decl.odin:1574 - ast_strings lookup
    - Purpose: String interning for AST strings
    - Impact: Low - error message quality
  5. check_objc_methods - Referenced in:
    - check_decl.odin:1185 (check_proc_decl)
    - check_decl.odin:1709 (check_proc_group_decl)
    - Purpose: Objective-C method validation
    - Impact: Low unless ObjC support is needed

  ---
  Category 4: Attribute System Extensions (1 item)

  check_decl.odin:269 - Attribute_Context missing field:
  init_expr_list_count: int
  Purpose: Track initialization expression count for attribute processing
  Impact: Low - appears to be for advanced attribute validation

  ---
  Category 5: File/Package Infrastructure (5 items)

  Requires upstream file and package tracking systems

  1. entity_helpers.odin:412-418 - File lazy flag tracking
  // Need: file_info_map with flags per file
  // Check: .Is_Lazy flag before processing
  2. entity_helpers.odin:428-435 - Package kind infrastructure
  // Package kinds: .Init, .Runtime, .Normal
  // Used for: initialization ordering, special package rules
  3. entity_helpers.odin:565 - Entity_Procedure.is_export check
  // Missing: is_export field on Entity_Procedure
  // Blocked by: procedure export tracking system
  4. entity_helpers.odin:611-617 - Package scope from file scope
  // Need: file_scope.pkg.scope navigation
  // Requires: package tracking in scopes
  5. check_decl.odin - multiple locations - File flags for instrumentation
    - Lines 1247-1251: File .No_Instrumentation flag
    - Requires file-level compilation flags tracking

  ---
  Priority Classification

  Can Implement Now (5 items):

  - ✅ Helper functions (ast_token, type_of_expr, check_rtti_type_disallowed)
  - ✅ Attribute_Context.init_expr_list_count field
  - ✅ check_expr_with_type_hint (or continue using fallback)

  Requires Moderate Infrastructure (3 items):

  - ⚠️ Entity struct additions (decl_info, aliased_of, identifier)
  - ⚠️ MPSC queue for @require tracking
  - ⚠️ check_objc_methods (if ObjC support needed)

  Requires Major Infrastructure (5 items):

  - 🔴 File flags tracking system
  - 🔴 Package kind infrastructure
  - 🔴 Package scope navigation
  - 🔴 File-to-package mapping
  - 🔴 Entity_Procedure.is_export field

  Platform-Specific (1 item):

  - 🔵 Objective-C support (check_objc_methods) - can be stubbed

