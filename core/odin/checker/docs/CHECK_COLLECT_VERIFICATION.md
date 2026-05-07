# check_collect Implementation Verification Report

**Date**: 2025-10-03
**Odin Implementation**: `/mnt/d/dev/checker/check_collect.odin` (538 lines)
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4383-5775`
**Status**: **INCOMPLETE - 30% Implemented**

## Executive Summary

The `check_collect.odin` module implements Phase 1 of the checker pipeline - collecting declarations from files and creating file scopes. **Critical entity collection functions are stubbed**, making the implementation functionally incomplete. The implemented portions (when statement handling, file declaration queueing, delayed processing infrastructure) appear correct but cannot be tested until the core collection functions are implemented.

---

## Section 1: Implementation Status

### Implemented Features (30%)

| Component | Status | C++ Reference | Lines |
|-----------|--------|---------------|-------|
| `collect_when_stmt_from_file` | ✅ Complete | checker.cpp:5551-5588 | 31-100 |
| `collect_file_decls_from_when_stmt` | ✅ Complete | checker.cpp:5590-5624 | 105-160 |
| `collect_file_decl` | ✅ Complete | checker.cpp:5627-5691 | 170-268 |
| `collect_file_decls` | ✅ Complete | checker.cpp:5693-5704 | 273-289 |
| `check_create_file_scopes` | ✅ Complete | checker.cpp:5714-5731 | 314-354 |
| `check_collect_entities_all` | ⚠️ Scaffold Only | checker.cpp:5759-5775 | 364-390 |
| Delayed declaration processing | ✅ Complete | checker.cpp:5885-5957 | 463-538 |

### Stubbed/Missing Features (70%)

| Component | Status | C++ Reference | Impact |
|-----------|--------|---------------|--------|
| `check_collect_entities` | ❌ **STUB** | checker.cpp:4840-4930 | **CRITICAL** - Main dispatcher |
| `check_collect_value_decl` | ❌ **STUB** | checker.cpp:4483-4756 | **CRITICAL** - Entity creation |
| `check_add_foreign_import_decl` | ❌ **STUB** | checker.cpp:5490-5545 | **HIGH** - Foreign library support |
| `correct_type_aliases_in_scope` | ❌ **STUB** | checker.cpp:4820-4836 | **MEDIUM** - Type alias resolution |
| AST state flags (has_been_handled) | ❌ Not Implemented | checker.cpp:5633 | **MEDIUM** - Duplicate processing prevention |

**Critical Gap**: The two most important functions - `check_collect_entities` and `check_collect_value_decl` - are completely unimplemented. These are responsible for:
- Creating entities from declarations
- Building the dependency graph
- Registering entities in scopes
- Setting up declaration info structures

---

## Section 2: Entity Collection Coverage

### Declaration Types Handled

The `collect_file_decl` function has switch cases for all declaration types, but most route to **stubbed functions**:

| Declaration Type | Switch Case | Handler Function | Status |
|------------------|-------------|------------------|--------|
| `Value_Decl` | ✅ Line 186-188 | `check_collect_value_decl` | ❌ **STUB** |
| `Import_Decl` | ✅ Line 190-192 | `check_add_import_decl` | ✅ Implemented (check_import.odin) |
| `Foreign_Import_Decl` | ✅ Line 194-196 | `check_add_foreign_import_decl` | ❌ **STUB** |
| `Foreign_Block_Decl` | ✅ Line 198-211 | Delayed queue | ✅ Queue logic correct |
| `When_Stmt` | ✅ Line 213-240 | `collect_when_stmt_from_file` | ✅ Complete |
| `Expr_Stmt` (directives) | ✅ Line 242-263 | Delayed queue | ✅ Queue logic correct |

**Analysis**:
- Framework exists to handle all declaration types
- Only `Import_Decl` has working end-to-end processing
- `Foreign_Import_Decl` stub prevents foreign library support
- `Value_Decl` stub prevents ALL entity creation (constants, variables, procedures, types)

### Missing from `check_collect_entities` (C++ lines 4848-4930)

The C++ implementation processes declarations in phases:

**Phase 1** (C++ 4848-4908): Process non-when statements
- ✅ `BadDecl` - handled
- ⚠️ `WhenStmt` - deferred to phase 2
- ❌ `ValueDecl` - **NOT IMPLEMENTED** (calls stubbed `check_collect_value_decl`)
- ⚠️ `ImportDecl` - queued for delayed processing
- ❌ `ForeignImportDecl` - **NOT IMPLEMENTED** (calls stubbed function)
- ⚠️ `ForeignBlockDecl` - queued for delayed processing

**Phase 2** (C++ 4914-4929): Process when statements and foreign blocks (non-file scope only)
- ❌ **NOT IMPLEMENTED** - Entire second phase missing

The Odin stub at lines 426-429 contains:
```odin
check_collect_entities :: proc(ctx: ^Checker_Context, nodes: []^ast.Stmt) {
	// TODO(PHASE25-GROUP2): Implement main entity collection
	// This will be implemented in the next phase
}
```

This is a **complete no-op** that prevents any entity collection from occurring.

---

## Section 3: Dependency Tracking Analysis

### Infrastructure Status

| Component | Location | Status | C++ Reference |
|-----------|----------|--------|---------------|
| `Decl_Info.deps` | checker.odin:330 | ✅ Field exists | checker.hpp:235-236 |
| `Decl_Info.deps_mutex` | checker.odin:329 | ✅ Field exists | checker.hpp:235 |
| `add_dependency` | entity_helpers.odin:745-761 | ✅ Implemented | checker.cpp:862-870 |
| Dependency graph construction | ❌ Not called | ❌ Missing | checker.cpp:4840-4930 |

### Dependency Tracking Implementation

The `add_dependency` function (entity_helpers.odin:745-761) correctly implements C++ logic:

```odin
add_dependency :: proc(info: ^Checker_Info, decl: ^Decl_Info, entity: ^Entity) {
	if decl == nil || entity == nil {
		return
	}

	if in_single_threaded_checker_stage {
		decl.deps[entity] = {}  // No lock needed
	} else {
		sync.rw_mutex_lock(&decl.deps_mutex)
		defer sync.rw_mutex_unlock(&decl.deps_mutex)
		decl.deps[entity] = {}
	}
}
```

✅ **Matches C++ behavior** (checker.cpp:862-870):
- Conditional locking based on threading mode
- Direct map insertion
- Null checks

❌ **Never Called** because `check_collect_value_decl` is stubbed. In C++, dependencies are added during:
1. Entity creation (checker.cpp:4483-4756)
2. Type expression analysis
3. Initializer expression checking

### Type Info Dependencies

| Component | Status | C++ Reference |
|-----------|--------|---------------|
| `Decl_Info.type_info_deps` | ✅ Field exists | checker.hpp:238-239 |
| `Decl_Info.type_info_deps_mutex` | ✅ Field exists | checker.hpp:238 |
| `add_type_info_dependency` | ❌ Not implemented | checker.cpp:871-884 |

**Missing Function**: `add_type_info_dependency` (C++ checker.cpp:871-884)
```cpp
gb_internal void add_type_info_dependency(CheckerInfo *info, DeclInfo *d, Type *type) {
	if (d == nullptr || type == nullptr) {
		return;
	}
	if (type->kind == Type_Named) {
		Entity *e = type->Named.type_name;
		if (e->TypeName.is_type_alias) {
			type = type->Named.base;
		}
	}
	rw_mutex_lock(&d->type_info_deps_mutex);
	type_set_add(&d->type_info_deps, type);
	rw_mutex_unlock(&d->type_info_deps_mutex);
}
```

This function is called throughout type checking to track which types require RTTI generation.

---

## Section 4: Missing Features

### 4.1 Core Entity Collection (CRITICAL)

**Function**: `check_collect_entities`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4840-4930`
**Current Status**: 3-line stub (check_collect.odin:426-429)

**Missing Logic**:

1. **Declaration filtering** (C++ 4848-4863):
   ```cpp
   for_array(decl_index, nodes) {
       Ast *decl = nodes[decl_index];
       if (!is_ast_decl(decl) && !is_ast_when_stmt(decl)) {
           if (curr_file && decl->kind == Ast_ExprStmt) {
               // Handle directive expressions
           }
           continue;
       }
   ```

2. **Declaration dispatch** (C++ 4865-4907):
   - BadDecl handling
   - WhenStmt deferral
   - ValueDecl → `check_collect_value_decl`
   - ImportDecl queueing
   - ForeignImportDecl → `check_add_foreign_import_decl`
   - ForeignBlockDecl queueing

3. **Second phase processing** (C++ 4914-4929):
   - Non-file-scope foreign blocks
   - Non-file-scope when statements

**Impact**: Without this function, **NO entities are created** from source files.

### 4.2 Value Declaration Collection (CRITICAL)

**Function**: `check_collect_value_decl`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4483-4756`
**Current Status**: 2-line stub (check_collect.odin:433-435)

**Missing Logic** (273 lines of C++ code):

#### Attribute Processing (C++ 4489-4579)
- ❌ `@(private)` visibility handling
- ❌ `@(test)` test procedure marking
- ❌ `@(init)` initialization procedure marking
- ❌ `@(fini)` finalization procedure marking
- ❌ File-level private scope inheritance

#### Mutable Variables (C++ 4581-4635)
```cpp
if (vd->is_mutable) {
    if (!(c->scope->flags&ScopeFlag_File)) {
        return; // Local variables handled elsewhere
    }

    for_array(i, vd->names) {
        Entity *e = alloc_entity_variable(c->scope, name->Ident.token, nullptr);
        e->Variable.is_global = true;
        e->Variable.is_foreign = (fl != nullptr);
        // ... foreign library setup
        DeclInfo *d = make_decl_info(c->scope, c->decl);
        add_entity_and_decl_info(c, name, e, d, is_exported);
    }
}
```
❌ Global variable creation
❌ Foreign variable linkage
❌ Entity-DeclInfo association

#### Immutable Values (C++ 4636-4755)
```cpp
Ast *init = unparen_expr(vd->values[i]);

if (is_ast_type(init)) {
    e = alloc_entity_type_name(d->scope, token, nullptr);
} else if (init->kind == Ast_ProcLit) {
    e = alloc_entity_procedure(d->scope, token, nullptr, pl->tags);
    // ... foreign procedure setup
    // ... calling convention handling
} else if (init->kind == Ast_ProcGroup) {
    e = alloc_entity_proc_group(d->scope, token, nullptr);
} else {
    e = alloc_entity_constant(d->scope, token, nullptr, empty_exact_value);
}
```
❌ Type name creation
❌ Procedure creation
❌ Foreign procedure setup
❌ Procedure group creation
❌ Constant creation
❌ Calling convention resolution (critical for WASM/foreign FFI)

#### Entity Registration
```cpp
add_entity_and_decl_info(c, name, e, d, is_exported);
check_arity_match(c, vd, true);
```
❌ Scope registration
❌ Package export queueing
❌ Arity validation

**Impact**: Without this function:
- No types can be defined
- No procedures can be declared
- No constants can be created
- No global variables exist
- Foreign function declarations fail silently

### 4.3 Foreign Import Declaration (HIGH PRIORITY)

**Function**: `check_add_foreign_import_decl`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:5490-5545`
**Current Status**: 2-line stub (check_collect.odin:440-442)

**Missing Logic**:

1. **Library name validation** (C++ 5499-5507):
   ```cpp
   String library_name = fl->library_name.string;
   if (library_name.len == 0 && fl->fullpaths.count != 0) {
       library_name = path_to_entity_name(fl->library_name.string, fullpath);
   }
   if (library_name.len == 0 || is_blank_ident(library_name)) {
       error(fl->token, "File name, '%.*s', cannot be as a library name");
       return;
   }
   ```

2. **Attribute processing** (C++ 5513-5541):
   - `@(export)` - export to package scope
   - `@(require)` - force linking
   - `@(priority_index)` - linker order
   - `@(ignore_duplicates)` - duplicate suppression
   - `@(extra_linker_flags)` - custom linker flags

3. **Entity creation** (C++ 5521-5525):
   ```cpp
   Entity *e = alloc_entity_library_name(parent_scope, fl->library_name, t_invalid,
                                         fl->fullpaths, library_name);
   e->LibraryName.decl = decl;
   add_entity(ctx, scope, nullptr, e);
   ```

4. **Queue for validation** (C++ 5543):
   ```cpp
   mpsc_enqueue(&ctx->info->foreign_imports_to_check_fullpaths, e);
   ```

**Impact**: Foreign library imports fail silently, breaking FFI entirely.

### 4.4 Type Alias Correction (MEDIUM PRIORITY)

**Function**: `correct_type_aliases_in_scope`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4820-4836`
**Current Status**: 1-line stub (check_collect.odin:417-421)

**Purpose**: Solves the @TypeAliasingProblem where type aliases reference other type aliases:
```odin
A :: C  // Initially parsed as constant
B :: A  // Initially parsed as constant
C :: struct {b: ^B}  // Type definition
```

**Missing Algorithm**:
```cpp
gb_internal void correct_type_aliases_in_scope(CheckerContext *c, Scope *s) {
    for (;;) {
        bool corrections = false;
        corrections |= correct_type_alias_in_scope_backwards(c, s);
        corrections |= correct_type_alias_in_scope_forwards(c, s);
        if (!corrections) {
            return;
        }
    }
}
```

Iteratively scans scope forwards and backwards, converting `Entity_Constant` to `Entity_TypeName` when initializer is a type reference.

**Impact**: Type alias chains may be incorrectly classified as constants, causing type checking errors.

### 4.5 AST State Flag Management

**Functions**:
- `has_been_handled` (check_collect.odin:398-404)
- `mark_been_handled` (check_collect.odin:407-412)

**Current Status**: Partially stubbed

**Issues**:
1. `has_been_handled` always returns `false` (line 403):
   ```odin
   // For MVP, assume nothing has been handled
   return false
   ```
   ❌ Allows duplicate processing of declarations

2. `mark_been_handled` is a no-op (lines 410-411 commented out):
   ```odin
   // flags := &ctx.info.ast_state_flags[rawptr(decl)]
   // *flags |= {.Been_Handled}
   ```
   ❌ Never marks declarations as processed

**C++ Reference**: checker.cpp:4484-4485, 5255-5256, 5491-5492
```cpp
if (decl->state_flags & StateFlag_BeenHandled) return;
decl->state_flags |= StateFlag_BeenHandled;
```

**Impact**:
- Declarations may be processed multiple times
- When statements could cause infinite recursion
- Import declarations could be duplicated

**Fix Required**: Implement proper AST flag storage:
```odin
has_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) -> bool {
	flags := ctx.info.ast_state_flags[rawptr(decl)]
	return .Been_Handled in flags
}

mark_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	flags := &ctx.info.ast_state_flags[rawptr(decl)]
	flags^ += {.Been_Handled}
}
```

---

## Section 5: Semantic Differences

### 5.1 Intentional Design Differences

| Feature | C++ Implementation | Odin Implementation | Justification |
|---------|-------------------|---------------------|---------------|
| **When condition caching** | Direct AST mutation (`ws->is_cond_determined`) | External map (`ctx.info.when_cond_determined`) | core:odin/ast is immutable |
| **AST state flags** | Direct field (`decl->state_flags`) | External map (`ctx.info.ast_state_flags`) | core:odin/ast is immutable |
| **File scope storage** | Direct field (`f->scope`) | External map (`c.info.scopes[file]`) | core:odin/ast is immutable |
| **Package export queue** | `pkg->exported_entity_queue` | Direct scope insertion | Simpler export semantics in MVP |
| **Parallel processing** | Worker threads | Sequential loop | MVP deferred parallelism |

✅ **All differences are architecturally sound** and documented with rationale.

### 5.2 Behavioral Differences

#### When Statement Handling (Lines 217-240)

**C++ Logic** (checker.cpp:5657-5675):
```cpp
if (!ws->is_cond_determined) {
    if (collect_when_stmt_from_file(ctx, ws)) return true;

    CheckerContext nctx = *ctx;
    nctx.collect_delayed_decls = true;
    if (collect_file_decls_from_when_stmt(&nctx, ws)) return true;
} else {
    CheckerContext nctx = *ctx;
    nctx.collect_delayed_decls = true;
    if (collect_file_decls_from_when_stmt(&nctx, ws)) return true;
}
```

**Odin Implementation** (check_collect.odin:219-240):
```odin
if ws not_in ctx.info.when_cond_determined {
    if collect_when_stmt_from_file(ctx, ws) {
        return true
    }

    nctx := ctx^
    nctx.collect_delayed_decls = true
    if collect_file_decls_from_when_stmt(&nctx, ws) {
        return true
    }
} else {
    nctx := ctx^
    nctx.collect_delayed_decls = true
    if collect_file_decls_from_when_stmt(&nctx, ws) {
        return true
    }
}
```

✅ **Functionally equivalent** - both paths correctly handle determined/undetermined conditions.

#### Delayed Declaration Queueing

**Foreign Block** (Lines 204-211):
```odin
if ctx.collect_delayed_decls && ctx.file != nil {
    if ctx.file not_in ctx.info.delayed_decls_foreign_block {
        ctx.info.delayed_decls_foreign_block[ctx.file] = make([dynamic]^ast.Stmt)
    }
    append(&ctx.info.delayed_decls_foreign_block[ctx.file], decl)
}
```

✅ **Matches C++** (checker.cpp:5653):
```cpp
array_add(&curr_file->delayed_decls_queues[AstDelayQueue_ForeignBlock], decl);
```

---

## Section 6: Required Fixes (Prioritized)

### Priority 1: CRITICAL - Blocking All Testing

#### 6.1 Implement `check_collect_entities`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4840-4930` (90 lines)

**Required Implementation**:
```odin
check_collect_entities :: proc(ctx: ^Checker_Context, nodes: []^ast.Stmt) {
	curr_file: ^ast.File = nil
	if .File in ctx.scope.flags {
		curr_file = ctx.scope.file
		assert(curr_file != nil)
	}

	// Phase 1: Process declarations (except when statements)
	for decl in nodes {
		if !is_ast_decl(decl) && !is_ast_when_stmt(decl) {
			if curr_file != nil && is_expr_stmt_directive(decl) {
				if ctx.collect_delayed_decls {
					if has_been_handled(ctx, decl) do continue
					mark_been_handled(ctx, decl)
					queue_delayed_expr(ctx, curr_file, decl)
				}
				continue
			}
			continue
		}

		#partial switch d in decl.derived {
		case ^ast.Bad_Decl:
			// Ignore

		case ^ast.When_Stmt:
			// Deferred to phase 2

		case ^ast.Value_Decl:
			check_collect_value_decl(ctx, decl)

		case ^ast.Import_Decl:
			if curr_file == nil {
				error(decl, "import declarations are only allowed in the file scope")
				continue
			}
			queue_delayed_import(ctx, curr_file, decl)

		case ^ast.Foreign_Import_Decl:
			if .File not_in ctx.scope.flags {
				error(decl, "foreign import declarations are only allowed in the file scope")
				continue
			}
			check_add_foreign_import_decl(ctx, decl)

		case ^ast.Foreign_Block_Decl:
			if curr_file != nil {
				queue_delayed_foreign_block(ctx, curr_file, decl)
			}

		case:
			if .File in ctx.scope.flags {
				error(decl, "Only declarations are allowed at file scope")
			}
		}
	}

	// Phase 2: Process when statements and foreign blocks (non-file scope only)
	if curr_file == nil {
		for decl in nodes {
			if fb, ok := decl.derived.(^ast.Foreign_Block_Decl); ok {
				check_add_foreign_block_decl(ctx, decl)
			}
		}

		for decl in nodes {
			if ws, ok := decl.derived.(^ast.When_Stmt); ok {
				check_collect_entities_from_when_stmt(ctx, ws)
			}
		}
	}
}
```

**Estimated Effort**: 4-6 hours (includes helper functions and testing)

#### 6.2 Implement `check_collect_value_decl`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4483-4756` (273 lines)

**Complexity**: HIGH - handles 6 entity types with complex attribute processing

**Required Subtasks**:
1. Attribute parsing (`@(private)`, `@(test)`, `@(init)`, `@(fini)`)
2. Visibility determination (file/package scope, private flags)
3. Mutable variable handling (global variables, foreign variables)
4. Immutable value handling (types, procedures, constants, proc groups)
5. Foreign library context integration
6. Calling convention resolution (especially WASM handling)
7. Arity checking

**Estimated Effort**: 12-16 hours (most complex function in collection phase)

**Dependencies**:
- `alloc_entity_variable` ✅ (entity_helpers.odin)
- `alloc_entity_type_name` ✅ (entity_helpers.odin)
- `alloc_entity_procedure` ✅ (entity_helpers.odin)
- `alloc_entity_proc_group` ✅ (entity_helpers.odin)
- `alloc_entity_constant` ✅ (entity_helpers.odin)
- `make_decl_info` ✅ (check_decl_helpers.odin)
- `add_entity_and_decl_info` ✅ (entity_helpers.odin:633)
- `check_arity_match` ❓ (needs verification)
- `check_builtin_attributes` ❓ (needs implementation)
- `add_entity_flags_from_file` ❓ (needs implementation)

### Priority 2: HIGH - FFI and Core Features

#### 6.3 Implement `check_add_foreign_import_decl`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:5490-5545` (55 lines)

**Required Implementation**:
```odin
check_add_foreign_import_decl :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	if has_been_handled(ctx, decl) do return
	mark_been_handled(ctx, decl)

	fl, ok := decl.derived.(^ast.Foreign_Import_Decl)
	if !ok do return

	parent_scope := ctx.scope
	assert(.File in parent_scope.flags)

	// Extract library name
	library_name := fl.name.text
	if library_name == "" && len(fl.sources) > 0 {
		library_name = path_to_entity_name(fl.sources[0].fullpath)
	}
	if library_name == "" || is_blank_ident(library_name) {
		error(fl.name, "Invalid library name: %s", library_name)
		return
	}

	// Process attributes (@(export), @(require), etc.)
	ac := check_decl_attributes(ctx, fl.attributes, foreign_import_decl_attribute)

	scope := parent_scope
	if ac.is_export {
		scope = parent_scope.parent
	}

	// Create library entity
	e := alloc_entity_library_name(
		parent_scope,
		fl.name,
		t_invalid,
		fl.sources,
		library_name,
		ctx.checker.allocator,
	)
	e.Library_Name.decl = decl
	add_entity_flags_from_file(ctx, e, parent_scope)
	add_entity(ctx, scope, nil, e)

	// Handle special attributes
	if ac.require_declaration {
		mpsc_enqueue(&ctx.info.required_foreign_imports_through_force_queue, e)
		add_entity_use(ctx, nil, e)
	}
	if ac.foreign_import_priority_index != 0 {
		e.Library_Name.priority_index = ac.foreign_import_priority_index
	}
	if ac.ignore_duplicates {
		e.Library_Name.ignore_duplicates = true
	}
	if ac.extra_linker_flags != "" {
		e.Library_Name.extra_linker_flags = ac.extra_linker_flags
	}

	mpsc_enqueue(&ctx.info.foreign_imports_to_check_fullpaths, e)
}
```

**Estimated Effort**: 3-4 hours

**Dependencies**:
- `alloc_entity_library_name` ❓ (needs implementation)
- `check_decl_attributes` ❓ (needs verification)
- `foreign_import_decl_attribute` ❓ (attribute validator)
- `add_entity_flags_from_file` ❓ (needs implementation)

### Priority 3: MEDIUM - Type System Correctness

#### 6.4 Implement `correct_type_aliases_in_scope`
**C++ Reference**: `/mnt/c/odin/src/checker.cpp:4820-4836` (16 lines)

**Required Implementation**:
```odin
correct_type_aliases_in_scope :: proc(ctx: ^Checker_Context, s: ^Scope) {
	for {
		corrections := false
		corrections |= correct_type_alias_in_scope_backwards(ctx, s)
		corrections |= correct_type_alias_in_scope_forwards(ctx, s)
		if !corrections {
			return
		}
	}
}

correct_type_alias_in_scope_backwards :: proc(ctx: ^Checker_Context, s: ^Scope) -> bool {
	// Iterate scope backwards and correct type aliases
	correction := false
	// NOTE: Odin maps don't have stable iteration order
	// May need to collect entities to array first for stable backwards iteration
	for _, e in s.elements {
		correction |= correct_single_type_alias(ctx, e)
	}
	return correction
}

correct_type_alias_in_scope_forwards :: proc(ctx: ^Checker_Context, s: ^Scope) -> bool {
	correction := false
	for _, e in s.elements {
		correction |= correct_single_type_alias(ctx, e)
	}
	return correction
}

correct_single_type_alias :: proc(ctx: ^Checker_Context, e: ^Entity) -> bool {
	if e.kind != .Constant {
		return false
	}
	d := e.decl_info
	if d == nil || d.init_expr == nil {
		return false
	}

	alias_of := check_entity_from_ident_or_selector(ctx, d.init_expr, true)
	if alias_of != nil && alias_of.kind == .Type_Name {
		e.kind = .Type_Name
		return true
	}
	return false
}
```

**Estimated Effort**: 2-3 hours

**Issue**: Odin maps don't preserve insertion order. The C++ code relies on backwards iteration for stability. May need auxiliary data structure.

#### 6.5 Implement AST State Flag Management

**Required Fixes**:
```odin
has_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) -> bool {
	flags := ctx.info.ast_state_flags[rawptr(decl)]
	return .Been_Handled in flags
}

mark_been_handled :: proc(ctx: ^Checker_Context, decl: ^ast.Stmt) {
	flags := &ctx.info.ast_state_flags[rawptr(decl)]
	flags^ += {.Been_Handled}
}
```

**Estimated Effort**: 15 minutes

### Priority 4: MEDIUM - Support Infrastructure

#### 6.6 Implement Missing Helper Functions

| Function | C++ Reference | Estimated Effort |
|----------|---------------|------------------|
| `check_builtin_attributes` | checker.cpp:4419-4481 | 2 hours |
| `add_entity_flags_from_file` | checker.cpp (inlined) | 1 hour |
| `check_arity_match` | checker.cpp (search needed) | 1 hour |
| `add_type_info_dependency` | checker.cpp:871-884 | 30 minutes |
| `is_ast_decl` | checker.cpp (macro) | 15 minutes |
| `is_ast_when_stmt` | checker.cpp (macro) | 15 minutes |

**Total Estimated Effort**: 5 hours

---

## Section 7: Import Handling Gaps

### 7.1 Regular Import Handling

**Status**: ✅ **COMPLETE** (check_import.odin:56-175)

The `check_add_import_decl` function correctly implements:
- ✅ Package resolution (builtin, intrinsics, user packages)
- ✅ Import name derivation
- ✅ Blank import handling
- ✅ Scope import tracking
- ✅ Entity creation for import names
- ✅ Scope marking as imported

**Verified Against**: C++ checker.cpp:5254-5336

**Minor Gaps**:
- ⚠️ Attribute processing (`@(require)`) - commented as TODO (line 131-132)
- ⚠️ Import name validation could be more robust

### 7.2 Foreign Import Handling

**Status**: ❌ **STUB** (check_collect.odin:440-442)

See Section 6.3 for required implementation.

**Impact**:
- System library imports fail (e.g., `foreign import libc "system:c"`)
- Dynamic library imports fail
- Linker integration broken
- Foreign function declarations cannot resolve library references

### 7.3 Package Scope Handling

**Import Graph Construction**: ✅ **COMPLETE** (check_import.odin:237-275)

The `generate_import_dependency_graph` function correctly:
- ✅ Creates nodes for all packages
- ✅ Builds edges from import declarations
- ✅ Handles when statements in imports
- ✅ Sets dependency counts

**Topological Sort**: ✅ **COMPLETE** (check_import.odin:361-465)

The `topological_sort_packages` function correctly:
- ✅ Implements Kahn's algorithm
- ✅ Detects circular imports
- ✅ Reports cycle paths
- ✅ Prioritizes global scopes
- ✅ Uses package ID for determinism

**Verified Against**: C++ checker.cpp:5132-5168, 5822-5871

**Minor Issue**: C++ comment at line 328 notes the C++ code has arguments BACKWARDS in one call site (scope_import order). Odin implementation correctly uses parent→imported order.

### 7.4 Export Entity Handling

**Status**: ⚠️ **SIMPLIFIED** (check_import.odin:585-596)

The `check_export_entities` function is a documented no-op:
```odin
check_export_entities :: proc(c: ^Checker) {
	// C++ line 5777-5815: check_export_entities_in_pkg
	// Our implementation: No-op since entities are already in correct scopes
}
```

**Justification**:
- C++ uses `exported_entity_queue` for parallel processing
- MVP adds entities directly to scopes during collection
- Export visibility determined by naming convention (`_` prefix = private)

**Future Parallelism**: If parallel entity collection is implemented, will need to:
1. Add `exported_entity_queue` to `Checker_Info`
2. Queue entities during `add_entity_and_decl_info`
3. Drain queue in `check_export_entities`

---

## Section 8: Testing and Validation

### 8.1 Current Testing Status

❌ **Cannot be tested** - core functions are stubs

### 8.2 Validation Checklist

After implementation, verify:
- [ ] All entity types can be created
- [ ] Scope hierarchy is correct
- [ ] Dependencies are tracked
- [ ] Delayed declarations process in correct order
- [ ] Foreign imports create library entities
- [ ] Type aliases resolve correctly
- [ ] AST flags prevent duplicate processing
- [ ] Import graph handles cycles
- [ ] Package ordering is deterministic

---

## Section 9: Architectural Assessment

### 9.1 Design Quality

✅ **Strengths**:
1. **Immutability Adaptation**: External maps for AST state is clean and correct
2. **Clear Separation**: File-level vs entity-level collection clearly delineated
3. **Delayed Processing**: Queue infrastructure is well-designed
4. **Documentation**: C++ line references are excellent
5. **Error Handling**: Proper error propagation patterns

⚠️ **Concerns**:
1. **Stubbed Critical Path**: 70% of functionality is TODO markers
2. **No Incremental Testing**: Cannot validate implemented portions
3. **Complex Dependencies**: `check_collect_value_decl` has many unknown helper functions

### 9.2 Code Consistency

✅ **Consistent Patterns**:
- Error reporting via `error()` function
- AST pattern matching via `#partial switch`
- Context passing via `^Checker_Context`
- Scope assertions via `assert()`

✅ **C++ Fidelity**:
- Line-by-line comments reference C++ source
- Algorithm structure preserved
- Edge cases documented

### 9.3 Technical Debt

**Current Debt**:
1. ❌ Two critical stubs block all usage
2. ⚠️ AST flag management disabled (allows duplicates)
3. ⚠️ Type alias correction disabled (potential misclassification)
4. ⚠️ Missing attribute processing infrastructure

**Recommended Debt Reduction**:
1. Implement stubs in priority order (Section 6)
2. Enable AST flag management immediately (15 minutes, prevents bugs)
3. Build attribute processing framework
4. Add incremental tests after each Priority 1 fix

---

## Section 10: Completion Roadmap

### Phase 1: Core Functionality (1-2 weeks)

**Week 1**:
1. Day 1-2: Implement `check_collect_entities` (6.1)
2. Day 3-5: Implement `check_collect_value_decl` skeleton (basic entity creation only)

**Week 2**:
1. Day 1-3: Complete `check_collect_value_decl` (attributes, foreign handling)
2. Day 4: Implement `check_add_foreign_import_decl` (6.3)
3. Day 5: Enable AST flag management (6.5)

**Deliverable**: Basic entity collection working for simple files

### Phase 2: Robustness (1 week)

1. Day 1-2: Implement `correct_type_aliases_in_scope` (6.4)
2. Day 3-4: Implement missing helper functions (6.6)
3. Day 5: Integration testing

**Deliverable**: Full entity collection with type alias support

### Phase 3: Polish (3 days)

1. Day 1: Fix attribute processing gaps
2. Day 2: Add comprehensive error messages
3. Day 3: Performance optimization

**Deliverable**: Production-ready entity collection

### Total Estimated Effort

| Category | Effort |
|----------|--------|
| Priority 1 (Critical) | 16-22 hours |
| Priority 2 (High) | 3-4 hours |
| Priority 3 (Medium) | 2-3 hours |
| Priority 4 (Support) | 5 hours |
| Testing | 8 hours |
| Documentation | 2 hours |
| **Total** | **36-44 hours** (~1-2 weeks) |

---

## Conclusion

The `check_collect.odin` implementation demonstrates excellent architectural understanding and faithful C++ translation **for the 30% that is implemented**. However, the **70% stub rate** makes this module non-functional.

**Immediate Action Required**:
1. Implement `check_collect_entities` (6.1) - **BLOCKS EVERYTHING**
2. Implement `check_collect_value_decl` (6.2) - **BLOCKS ENTITY CREATION**
3. Enable AST flag management (6.5) - **PREVENTS BUGS**

Once these three items are complete, the module will be minimally functional for testing simple Odin files. The remaining work (foreign imports, type aliases, attributes) can be done incrementally.

**Recommendation**: Do not attempt to use this module in production until at least Priority 1 and Priority 2 items are complete. The stub functions fail silently, which would make debugging extremely difficult.
