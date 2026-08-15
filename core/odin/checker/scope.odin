package checker

/*
Scope management for hierarchical symbol visibility.

This module implements the scope system for name resolution,
including scope creation, entity lookup, and import handling.
*/

import "core:container/queue"
import "core:odin/ast"
import "core:sync"

// Single-threaded checker stage optimization
// When true, scope operations skip mutex locking -- valid ONLY inside the one region C++
// marks single threaded. It is NOT "true during initialization": see LEDGER #855 below.
// C++ Reference: checker.cpp:383 (std::atomic<bool> in_single_threaded_checker_stage)
//
// C++ Transition Points:
//   - Set to true at start of check_all_global_entities() (checker.cpp:4972)
//   - Set to false at end of check_all_global_entities() (checker.cpp:4994)
//
// Used in:
//   - scope_lookup_parent() (scope.odin) - conditional read locking
//   - add_entity() (scope.odin) - conditional write locking
//   - add_dependency() (entity_helpers.odin) - conditional dependency tracking
//
// State transitions implemented in check_all_global_entities (check_global_init.odin)
// Set to true at start, false at end to enable parallel procedure checking
//
// NOTE: Uses atomic operations for thread safety when tests run in parallel
//
// LEDGER #855. The INITIAL VALUE must be false, not true. C++ declares this as
//     gb_global std::atomic<bool> in_single_threaded_checker_stage;   // checker.cpp:388
// with no initialiser, so it is zero-initialised to FALSE, and the only writes are the
// true/false pair bracketing check_all_global_entities (checker.cpp:5317 / 5339).
//
// The port started it at `true`, which is not a harmless default: check_files runs
// check_collect_entities_all -- a THREAD-POOL phase -- at check_files.odin:98, long before
// check_all_global_entities. With the flag stuck true for that whole window every
// `locked := !in_single_threaded_checker_stage()` guard in the checker evaluated to
// locked=false, so the parallel collect phase ran with EVERY conditional mutex skipped:
// scope.odin's three scope guards, entity_helpers.odin's add_dependency, type_info.odin's
// type-info guard, and all three global_untyped guards in check_expr.odin.
//
// Found by #850's crash: enabling check_set_expr_info's first writer made concurrent collect
// workers grow c.info.global_untyped with no lock held, which aborts inside glibc
// ("double free or corruption") once two threads resize the same map. Confirmed by coredump
// backtrace -- check_collect_entities_all_worker_proc -> check_expr_base -> add_untyped ->
// check_set_expr_info -> map_grow -> heap_free -> abort -- and by the flag's own history:
// the guarded writes had zero callers until then, which is why nothing had tripped over it.
@(private = "file")
_in_single_threaded_checker_stage: bool = false

// Thread-safe getter for in_single_threaded_checker_stage
in_single_threaded_checker_stage :: #force_inline proc() -> bool {
	return sync.atomic_load(&_in_single_threaded_checker_stage)
}

// Thread-safe setter for in_single_threaded_checker_stage
set_single_threaded_checker_stage :: proc(value: bool) {
	sync.atomic_store(&_in_single_threaded_checker_stage, value)
}

// create_scope creates a new scope with given parent
// C++ Reference: checker.cpp create_scope
create_scope :: proc(parent: ^Scope, allocator := context.allocator) -> ^Scope {
	s := new(Scope, allocator)
	s.parent = parent
	s.elements = make(map[string]^Entity, DEFAULT_SCOPE_CAPACITY, allocator)
	s.imported = make(map[^Scope]struct{}, allocator)

	// Link as child of parent (with thread-safety and builtin_pkg check)
	// C++ Reference: checker.cpp create_scope
	// NOTE: The C++ version uses atomic operations to prevent race conditions when
	// multiple threads create child scopes simultaneously. It also excludes builtin_pkg
	// scope from the child chain (global scope that doesn't need parent tracking).
	if parent != nil {
		// Check if parent is the builtin package scope
		// In Odin, we check if parent has the Builtin flag set
		// C++ line 220: if (parent != nullptr && parent != builtin_pkg->scope)
		is_builtin := .Builtin in parent.flags

		if !is_builtin {
			// THREAD-SAFETY: The C++ version uses atomic exchange operations here:
			// C++ Reference: checker.cpp create_scope
			//   Scope *prev_head_child = parent->head_child.exchange(s, std::memory_order_acq_rel);
			//   if (prev_head_child) {
			//       s->next.store(prev_head_child, std::memory_order_release);
			//   }
			//
			// In Odin, we protect the parent's head_child linked list with a mutex
			// to prevent race conditions during concurrent scope creation.
			// This is simpler than atomic pointer operations and provides equivalent safety.
			sync.rw_mutex_lock(&parent.mutex)
			s.next = parent.head_child
			parent.head_child = s
			sync.rw_mutex_unlock(&parent.mutex)
		}
	}

	// Propagate ContextDefined flag from parent to child
	// C++ Reference: checker.cpp create_scope
	if parent != nil && .Context_Defined in parent.flags {
		s.flags += {.Context_Defined}
	}

	return s
}

// destroy_scope frees scope resources recursively
// C++ Reference: checker.cpp:283-292
// Recursively destroys all child scopes before destroying the scope itself
destroy_scope :: proc(s: ^Scope) {
	// Recursively destroy all child scopes first
	for child := s.head_child; child != nil; child = child.next {
		destroy_scope(child)
	}

	delete(s.elements)
	delete(s.imported)
	// NOTE: In C++ the scope is not freed because it's allocated in an arena
	// In Odin we free it since we use the standard allocator
	free(s)
}

// scope_reserve pre-allocates capacity in scope map
scope_reserve :: proc(s: ^Scope, count: int) {
	reserve(&s.elements, count * 2)
}

// scope_lookup_current looks up identifier in current scope only (no parent chain)
// C++ Reference: checker.cpp
scope_lookup_current :: proc(s: ^Scope, name: string) -> ^Entity {
	if s == nil {
		return nil
	}

	// Only check current scope
	if entity, found := s.elements[name]; found {
		return entity
	}

	return nil
}

// scope_lookup looks up an identifier in scope and parent scopes
// C++ Reference: checker.cpp:436-440
scope_lookup :: proc(s: ^Scope, name: string) -> ^Entity {
	_, entity := scope_lookup_parent(s, name)
	return entity
}

// check_identifier_exists reports whether an identifier or selector expression
// resolves, WITHOUT checking it and therefore without emitting any diagnostic.
//
// C++ Reference: check_expr.cpp:6304-6330
//
// This is what `#defined` must use. Resolving the argument with check_ident
// instead makes the very case `#defined` exists to test - a name that is not
// declared on this platform - emit "Undeclared name".
check_identifier_exists :: proc(s: ^Scope, node: ^ast.Node, nested := false, out_scope: ^^Scope = nil) -> bool {
	if node == nil {
		return false
	}

	#partial switch n in node.derived {
	case ^ast.Ident:
		e := scope_lookup_current(s, n.name) if nested else scope_lookup(s, n.name)
		if e != nil {
			if out_scope != nil {
				out_scope^ = e.scope
			}
			return true
		}
	case ^ast.Selector_Expr:
		lhs_scope: ^Scope = nil
		if check_identifier_exists(s, n.expr, nested, &lhs_scope) {
			return check_identifier_exists(lhs_scope, n.field, true)
		}
	}

	return false
}

// scope_lookup_parent_with_mutex searches up the scope chain with mutex protection
// Ported from checker.cpp:385-434 (multi-threaded version)
// This respects scope boundaries - labels and local variables cannot cross proc boundaries
scope_lookup_parent_with_mutex :: proc(s: ^Scope, name: string) -> (scope: ^Scope, entity: ^Entity) {
	if s == nil {
		return nil, nil
	}

	gone_thru_proc := false
	gone_thru_package := false

	for current := s; current != nil; current = current.parent {
		// Check current scope
		sync.rw_mutex_shared_lock(&current.mutex)
		found, ok := current.elements[name]
		sync.rw_mutex_shared_unlock(&current.mutex)

		if ok {
			e := found

			// Check if entity is accessible across proc boundaries
			if gone_thru_proc {
				// Labels cannot cross procedure boundaries
				if e.kind == .Label {
					if current.flags & {.Proc} == {.Proc} {
						gone_thru_proc = true
					}
					if current.flags & {.Pkg} == {.Pkg} {
						gone_thru_package = true
					}
					continue
				}

				// Local variables cannot cross procedure boundaries
				// unless they are file-level globals or static/thread_local
				if e.kind == .Variable {
					if e.scope != nil && e.scope.flags & {.File} == {.File} {
						// Global variables are file-level and accessible
					} else if .Static in e.flags {
						// Allow static/thread_local variables to be referenced
					} else {
						if current.flags & {.Proc} == {.Proc} {
							gone_thru_proc = true
						}
						if current.flags & {.Pkg} == {.Pkg} {
							gone_thru_package = true
						}
						continue
					}
				}
			}

			return current, e
		}

		// Track proc boundary crossing
		if current.flags & {.Proc} == {.Proc} {
			gone_thru_proc = true
		}
		if current.flags & {.Pkg} == {.Pkg} {
			gone_thru_package = true
		}
	}

	return nil, nil
}

// scope_lookup_parent_no_mutex searches up the scope chain without mutex locking
// Ported from checker.cpp:385-434 (single-threaded version with is_single_threaded=true)
// This respects scope boundaries - labels and local variables cannot cross proc boundaries
// NOTE: Only safe to use during single-threaded initialization phase
scope_lookup_parent_no_mutex :: proc(s: ^Scope, name: string) -> (scope: ^Scope, entity: ^Entity) {
	if s == nil {
		return nil, nil
	}

	gone_thru_proc := false
	gone_thru_package := false

	for current := s; current != nil; current = current.parent {
		// Check current scope (no mutex locking in single-threaded mode)
		found, ok := current.elements[name]

		if ok {
			e := found

			// Check if entity is accessible across proc boundaries
			if gone_thru_proc {
				// Labels cannot cross procedure boundaries
				if e.kind == .Label {
					if current.flags & {.Proc} == {.Proc} {
						gone_thru_proc = true
					}
					if current.flags & {.Pkg} == {.Pkg} {
						gone_thru_package = true
					}
					continue
				}

				// Local variables cannot cross procedure boundaries
				// unless they are file-level globals or static/thread_local
				if e.kind == .Variable {
					if e.scope != nil && e.scope.flags & {.File} == {.File} {
						// Global variables are file-level and accessible
					} else if .Static in e.flags {
						// Allow static/thread_local variables to be referenced
					} else {
						if current.flags & {.Proc} == {.Proc} {
							gone_thru_proc = true
						}
						if current.flags & {.Pkg} == {.Pkg} {
							gone_thru_package = true
						}
						continue
					}
				}
			}

			return current, e
		}

		// Track proc boundary crossing
		if current.flags & {.Proc} == {.Proc} {
			gone_thru_proc = true
		}
		if current.flags & {.Pkg} == {.Pkg} {
			gone_thru_package = true
		}
	}

	return nil, nil
}

// scope_lookup_parent searches up the scope chain with proc boundary checks
// Ported from checker.cpp:385-434
// Dispatcher: chooses mutex or no-mutex version based on threading mode
scope_lookup_parent :: proc(s: ^Scope, name: string) -> (scope: ^Scope, entity: ^Entity) {
	if in_single_threaded_checker_stage() {
		return scope_lookup_parent_no_mutex(s, name)
	}
	return scope_lookup_parent_with_mutex(s, name)
}

// scope_insert_with_name_with_mutex adds an entity with explicit name (mutex-protected)
// Ported from checker.cpp scope_insert_with_name (multi-threaded version)
// Handles result parameter shadowing in procedure scopes
scope_insert_with_name_with_mutex :: proc(s: ^Scope, name: string, entity: ^Entity) -> ^Entity {
	if name == "" {
		return nil
	}

	sync.rw_mutex_lock(&s.mutex)
	defer sync.rw_mutex_unlock(&s.mutex)

	// Check for existing entity in current scope
	if existing, ok := s.elements[name]; ok {
		if entity != existing {
			return existing // Collision
		}
		return nil
	}

	// Check parent scope for result parameter shadowing
	// Result parameters in proc scopes cannot be shadowed directly
	if s.parent != nil && s.parent.flags & {.Proc} == {.Proc} {
		sync.rw_mutex_shared_lock(&s.parent.mutex)
		parent_entity, parent_ok := s.parent.elements[name]
		sync.rw_mutex_shared_unlock(&s.parent.mutex)

		if parent_ok {
			if .Result in parent_entity.flags {
				if entity != parent_entity {
					return parent_entity // Cannot shadow result parameter
				}
			}
		}
	}

	// Insert entity
	s.elements[name] = entity
	if entity.scope == nil {
		entity.scope = s
	}

	return nil
}

// scope_insert_with_name_no_mutex adds an entity with explicit name (no mutex locking)
// Ported from checker.cpp:442-476 (single-threaded version)
// Handles result parameter shadowing in procedure scopes
// NOTE: Only safe to use during single-threaded initialization phase
scope_insert_with_name_no_mutex :: proc(s: ^Scope, name: string, entity: ^Entity) -> ^Entity {
	if name == "" {
		return nil
	}

	// Check for existing entity in current scope (no mutex in single-threaded mode)
	if existing, ok := s.elements[name]; ok {
		if entity != existing {
			return existing // Collision
		}
		return nil
	}

	// Check parent scope for result parameter shadowing
	// Result parameters in proc scopes cannot be shadowed directly
	// NOTE: C++ version accesses parent->elements without locking (line 498)
	if s.parent != nil && s.parent.flags & {.Proc} == {.Proc} {
		parent_entity, parent_ok := s.parent.elements[name]

		if parent_ok {
			if .Result in parent_entity.flags {
				if entity != parent_entity {
					return parent_entity // Cannot shadow result parameter
				}
			}
		}
	}

	// Insert entity
	s.elements[name] = entity
	if entity.scope == nil {
		entity.scope = s
	}

	return nil
}

// scope_insert_with_name adds an entity with explicit name
// Ported from checker.cpp scope_insert_with_name
// Dispatcher: chooses mutex or no-mutex version based on threading mode
scope_insert_with_name :: proc(s: ^Scope, name: string, entity: ^Entity) -> ^Entity {
	if in_single_threaded_checker_stage() {
		return scope_insert_with_name_no_mutex(s, name, entity)
	}
	return scope_insert_with_name_with_mutex(s, name, entity)
}

// scope_insert adds an entity to the scope
// Ported from checker.cpp:519-526
// Returns existing entity if name collision, nil on success
scope_insert :: proc(s: ^Scope, entity: ^Entity) -> ^Entity {
	if entity == nil || entity.token.text == "" {
		return nil
	}

	name := entity.token.text
	if in_single_threaded_checker_stage() {
		return scope_insert_with_name_no_mutex(s, name, entity)
	}
	return scope_insert_with_name_with_mutex(s, name, entity)
}

// scope_insert_no_mutex adds an entity without mutex protection
// Ported from checker.cpp:528-531
// Only safe to use during single-threaded initialization phase
scope_insert_no_mutex :: proc(s: ^Scope, entity: ^Entity) -> ^Entity {
	if entity == nil || entity.token.text == "" {
		return nil
	}
	name := entity.token.text
	return scope_insert_with_name_no_mutex(s, name, entity)
}

// scope_import imports another scope's entities
scope_import :: proc(s: ^Scope, imported: ^Scope) {
	if imported == nil {
		return
	}

	sync.rw_mutex_lock(&s.mutex)
	defer sync.rw_mutex_unlock(&s.mutex)

	s.imported[imported] = {}
}

// find_entity_in_scope locates an entity by name
find_entity_in_scope :: proc(s: ^Scope, name: string) -> ^Entity {
	_, entity := scope_lookup_parent(s, name)
	return entity
}

// is_scope_file checks if scope is a file scope
is_scope_file :: proc(s: ^Scope) -> bool {
	return .File in s.flags
}

// is_scope_pkg checks if scope is a package scope
is_scope_pkg :: proc(s: ^Scope) -> bool {
	return .Pkg in s.flags
}

// is_scope_proc checks if scope is a procedure scope
is_scope_proc :: proc(s: ^Scope) -> bool {
	return .Proc in s.flags
}

// get_scope_depth returns nesting depth of scope
get_scope_depth :: proc(s: ^Scope) -> int {
	depth := 0
	for current := s; current != nil; current = current.parent {
		depth += 1
	}
	return depth
}

// scope_insert_entity is an alias for scope_insert for compatibility
// Some code may use this name from the C++ version
scope_insert_entity :: scope_insert

// add_scope associates a scope with an AST node
// C++ Reference: checker.cpp:295-315
// C++ mutates AST directly (node->ProcType.scope = scope), we use external map
add_scope :: proc(ctx: ^Checker_Context, node: ^ast.Node, scope: ^Scope) {
	assert(node != nil, "add_scope: node is nil")
	assert(scope != nil, "add_scope: scope is nil")

	info := ctx.info
	scope.node = node

	// Store in ast_scope_map using node pointer as key
	sync.rw_mutex_lock(&info.ast_scope_map_mutex)
	defer sync.rw_mutex_unlock(&info.ast_scope_map_mutex)

	info.ast_scope_map[rawptr(node)] = scope
}

// scope_of_node retrieves the scope associated with an AST node
// C++ Reference: checker.cpp:317-339
// C++ reads scope directly from AST, we use external map
scope_of_node :: proc(info: ^Checker_Info, node: ^ast.Node) -> ^Scope {
	if node == nil {
		return nil
	}

	sync.rw_mutex_shared_lock(&info.ast_scope_map_mutex)
	defer sync.rw_mutex_shared_unlock(&info.ast_scope_map_mutex)

	if scope, found := info.ast_scope_map[rawptr(node)]; found {
		return scope
	}

	return nil
}

// create_scope_from_file creates a file-level scope
// C++ Reference: checker.cpp:234-249
// Creates a scope for a file with capacity based on declaration count
create_scope_from_file :: proc(parent: ^Scope, file: ^ast.File, allocator := context.allocator) -> ^Scope {
	assert(file != nil, "create_scope_from_file: file is nil")
	assert(file.pkg != nil, "create_scope_from_file: file.pkg is nil")
	assert(parent != nil, "create_scope_from_file: parent scope is nil")

	// Calculate initial capacity based on file declaration count
	// C++ line 239: gb_max(DEFAULT_SCOPE_CAPACITY, 2*f->total_file_decl_count)
	//
	// This used to use len(file.decls) under a comment calling the difference a "minor perf
	// impact". That was wrong about the CONSEQUENCE (#657): the same count also decides the
	// scope map's starting capacity, and therefore C++'s iteration order. It is only a size hint
	// HERE -- an Odin map's capacity cannot affect its order -- but there must be exactly one
	// notion of "declaration count" in this file, or the next reader re-learns #657 the hard way.
	total_decls := file_decl_count(file)
	init_capacity := max(DEFAULT_SCOPE_CAPACITY, 2 * total_decls)

	// Create scope with package scope as parent
	s := create_scope(parent, allocator)

	// Pre-allocate capacity for better performance
	reserve(&s.elements, init_capacity)

	// Set file scope flags and association
	s.flags += {.File}
	s.file = file

	return s
}

// create_scope_from_package creates a package-level scope
// C++ Reference: checker.cpp create_scope_from_package
// Creates a scope for a package with Init, Runtime, and Global flags as appropriate
// NOTE: This requires builtin_pkg to be available in the Checker_Info or Checker
// Structural Differences to cpp:
//   1. pkg->scope = s → Must be stored by caller in ctx.info.package_scopes[pkg]
//     - Reason: core:odin/ast is immutable, cannot mutate pkg
//     - C++ line 265: pkg->scope = s
//     - IMPORTANT: Caller must manually store: ctx.info.package_scopes[pkg] = returned_scope
//   2. builtin_pkg->scope → Looked up from ctx.info.package_scopes[ctx.info.builtin_package]
//     - Reason: core:odin/ast is immutable, cannot read pkg.scope
//     - C++ line 260: create_scope(c->info, builtin_pkg->scope)
//   3. c->checker->parser->init_fullpath → ctx.info.init_fullpath
//     - Reason: No Parser struct; field moved to Checker_Info
//     - Complete: Added at checker.odin:1418
create_scope_from_package :: proc(ctx: ^Checker_Context, pkg: ^ast.Package, allocator := context.allocator) -> ^Scope {
	assert(pkg != nil, "create_scope_from_package: pkg is nil")

	// Calculate total declaration count across all files in package
	// C++ lines 254-256: for (AstFile *file : pkg->files) { total_pkg_decl_count += file->total_file_decl_count; }
	// In Odin: pkg.files is map[string]^File, iterate and sum file_decl_count, which is C++'s
	// calc_decl_count (parser.cpp:6720) -- NOT len(file.decls). See the note in
	// create_scope_from_file and #657.
	total_pkg_decl_count := 0
	for _, file in pkg.files {
		total_pkg_decl_count += file_decl_count(file)
	}

	// Calculate initial capacity
	// C++ line 259: gb_max(DEFAULT_SCOPE_CAPACITY, 2*total_pkg_decl_count)
	init_capacity := max(DEFAULT_SCOPE_CAPACITY, 2 * total_pkg_decl_count)

	// Create scope with builtin package scope as parent
	// C++ line 260: create_scope(c->info, builtin_pkg->scope)
	// In Odin: Get builtin_package scope from ctx.info.package_scopes map
	builtin_scope: ^Scope = nil
	if ctx.info.builtin_package != nil {
		builtin_scope = ctx.info.package_scopes[ctx.info.builtin_package]
	}
	s := create_scope(builtin_scope, allocator)

	// Pre-allocate capacity
	reserve(&s.elements, init_capacity)

	// Set package scope flags
	s.flags += {.Pkg}
	s.pkg = pkg

	// C++ Reference: checker.cpp create_scope_from_package - `pkg->scope = s;`
	pkg.scope = s

	// The assignment above was omitted for a long time, and the omission was load-bearing in the
	// worst way: check_export_entities walks c.info.packages and drains each package's
	// exported_entity_queue into `pkg.scope`, skipping any package whose scope is nil
	// (check_import_export.odin:526). With pkg.scope nil for every parsed package that guard fired
	// every time, the queues were never drained, and NO exported entity ever reached its package
	// scope - a declaration in one file of a package was invisible to every other file of the same
	// package, and `pkg.Name` selectors resolved against an empty scope. It was the direct cause
	// of the "Undeclared name: X" flood over the core packages, base:runtime included (Type_Info,
	// Allocator_Error and RUNTIME_LINKAGE are all cross-file references).
	//
	// Measured effect of restoring it, over the whole dependency closure of each package:
	//   core/strings  6079 -> 2210 diagnostics total, 1048 -> 414 in its own files
	//   core/unicode  3404 -> 1096 diagnostics total,  713 ->   0 in its own files
	//   core/slice    2876 -> 1180 diagnostics total,  184 ->  84 in its own files
	// and all 258 "'#caller_location' requires base:runtime to be imported" errors disappear.
	//
	// It could not be applied until four unrelated defects were fixed, because a populated package
	// scope is what makes the checker get far enough to reach any of them. For the record:
	//
	//   1. Six empty critical sections (lock and its scope-scoped `defer` unlock both inside an
	//      `if !in_single_threaded_checker_stage()` block, so the unlock fired before the guarded
	//      work). Fixed previously; that was the "double free or corruption in map_grow_dynamic".
	//   2. task_deque_take did not restore `bottom` after winning the CAS for the last element,
	//      leaving the work-stealing deque at size -1 and silently losing the next task pushed to
	//      it while `tasks_left` still counted it - a hard deadlock of the whole thread pool.
	//      See queue_drain.odin.
	//   3. Fourteen unsynchronised readers of Checker_Info.type_and_value_map racing the writer's
	//      map growth. See tav_lookup in check_expr.odin.
	//   4. Two unbounded recursions in the polymorphic-record machinery: a missing
	//      `is_polymorphic^ = true` for a still-generic type-parameter operand, and an invented
	//      Struct/Union arm in is_polymorphic_type_assignable that formed a closed cycle with
	//      check_type_specialization_to. See check_type.odin.
	//
	// The `ident.name == e.token.text` assertion in add_entity_and_decl_info, which used to fire
	// as soon as this line was applied, does not fire any more: it was a downstream symptom of
	// (2)/(3), not an entity-construction defect. It is C++'s GB_ASSERT at checker.cpp:2219 and
	// stays.

	// Check if this is the init package
	// C++ lines 267-269: if (pkg->fullpath == c->checker->parser->init_fullpath || pkg->kind == Package_Init)
	// Dynamically created runtime packages may have .Init kind OR match the init_fullpath
	if pkg.fullpath == ctx.info.init_fullpath || pkg.kind == .Init {
		s.flags += {.Init}
	}

	// Runtime package gets Global flag
	// C++ lines 271-273: if (pkg->kind == Package_Runtime)
	if pkg.kind == .Runtime {
		s.flags += {.Global}
	}

	// Init and Global packages are marked as HasBeenImported
	// C++ lines 275-277
	if .Init in s.flags || .Global in s.flags {
		s.flags += {.Has_Been_Imported}
	}

	// All package scopes have ContextDefined flag
	// C++ line 278
	s.flags += {.Context_Defined}

	return s
}

// check_open_scope creates and enters a new nested scope during checking
// C++ Reference: checker.cpp:341-367
// Opens a scope for a statement or type node, setting appropriate flags
check_open_scope :: proc(ctx: ^Checker_Context, node: ^ast.Node) {
	// NOTE: C++ unparen_expr is not needed in Odin since we work with ast.Node directly
	assert(node != nil, "check_open_scope: node is nil")

	// Create new scope as child of current scope
	scope := create_scope(ctx.scope)
	add_scope(ctx, node, scope)

	// Set scope flags based on node type
	// C++ lines 349-360
	#partial switch n in node.derived {
	case ^ast.Proc_Type:
		scope.flags += {.Proc}
	case ^ast.Struct_Type:
		scope.flags += {.Type}
	case ^ast.Enum_Type:
		scope.flags += {.Type}
	case ^ast.Union_Type:
		scope.flags += {.Type}
	case ^ast.Bit_Set_Type:
		scope.flags += {.Type}
	case ^ast.Bit_Field_Type:
		scope.flags += {.Type}
	}

	// Number scopes within procedure body depth-first
	// C++ lines 361-364
	if ctx.decl != nil && ctx.decl.proc_lit != nil {
		scope.index = ctx.decl.scope_index
		ctx.decl.scope_index += 1
	}

	// Enter the new scope
	ctx.scope = scope

	// Set bounds_check state flag
	// C++ line 366: c->state_flags |= StateFlag_bounds_check
	ctx.state_flags += {.Bounds_Check}
}

// check_close_scope exits the current scope during checking
// C++ Reference: checker.cpp:369-371
check_close_scope :: proc(ctx: ^Checker_Context) {
	assert(ctx.scope != nil, "check_close_scope: already at root scope")
	ctx.scope = ctx.scope.parent
}

// correct_single_type_alias corrects a single entity if it's a type alias
// misidentified as a constant
// C++ Reference: checker.cpp:4782-4795
correct_single_type_alias :: proc(ctx: ^Checker_Context, e: ^Entity) -> bool {
	if e == nil {
		return false
	}

	// Check if this is a constant that should actually be a type alias
	if e.kind == .Constant {
		if e.decl_info != nil && e.decl_info.init_expr != nil {
			// Try to resolve the init expression to see if it's a type
			init := e.decl_info.init_expr

			// Check if init references a TypeName entity
			// This handles: A :: SomeType
			alias_of := check_entity_from_ident_or_selector(ctx, init, true)
			if alias_of != nil && alias_of.kind == .Type_Name {
				// This constant is actually a type alias.
				//
				// C++ (checker.cpp:5126) only flips e->kind, because Entity's payload is a
				// union and the existing fields stay put. This port has a tagged variant, so
				// the variant must be replaced — but it must CARRY THE STATE OVER, not be
				// zeroed. Writing Entity_Type_Name{} discarded the entity's type and left
				// is_type_alias false, which is not what flipping a union tag does.
				e.kind = .Type_Name
				e.variant = Entity_Type_Name {
					type          = e.type,
					is_type_alias = true,
				}
				return true
			}
		}
	}
	return false
}

// correct_type_alias_in_scope_backwards iterates backwards through scope correcting type aliases
// C++ Reference: checker.cpp:4797-4807
correct_type_alias_in_scope_backwards :: proc(ctx: ^Checker_Context, s: ^Scope) -> bool {
	if s == nil {
		return false
	}

	correction := false

	// NOTE: Odin maps don't preserve insertion order, so we can't iterate backwards
	// In practice this shouldn't matter since we iterate in both directions
	for _, entity in s.elements {
		if entity != nil {
			correction |= correct_single_type_alias(ctx, entity)
		}
	}

	return correction
}

// correct_type_alias_in_scope_forwards iterates forwards through scope correcting type aliases
// C++ Reference: checker.cpp:4808-4817
correct_type_alias_in_scope_forwards :: proc(ctx: ^Checker_Context, s: ^Scope) -> bool {
	if s == nil {
		return false
	}

	correction := false

	for _, entity in s.elements {
		if entity != nil {
			correction |= correct_single_type_alias(ctx, entity)
		}
	}

	return correction
}

// correct_type_aliases_in_scope solves the type aliasing problem where type aliases
// of type aliases are confused as constants
// Example that needs correction:
//     A :: C
//     B :: A
//     C :: struct {b: ^B}
// C++ Reference: checker.cpp:4820-4837
correct_type_aliases_in_scope :: proc(ctx: ^Checker_Context, s: ^Scope) {
	if s == nil {
		return
	}

	// NOTE(bill, 2022-02-04): This is used to solve the problem caused by type aliases
	// of type aliases being "confused" as constants
	// See @TypeAliasingProblem for more information

	// Iterate until no more corrections are needed
	for {
		corrections := false
		corrections |= correct_type_alias_in_scope_backwards(ctx, s)
		corrections |= correct_type_alias_in_scope_forwards(ctx, s)
		if !corrections {
			return
		}
	}
}

// force_add_dependency_entity looks up an entity by name and forces it as a dependency
// C++ Reference: checker.cpp:2695-2703
force_add_dependency_entity :: proc(c: ^Checker, scope: ^Scope, name: string) {
	if c == nil || scope == nil {
		return
	}

	// Look up the entity in the scope
	e := scope_lookup(scope, name)
	if e == nil {
		return
	}

	// Mark entity as used
	e.flags += {.Used}

	// Add to dependency set for force-include mechanics
	add_dependency_to_set(c, e)
}

// generate_minimum_dependency_set_internal walks the roots and seeds the dependency set.
// C++ Reference: checker.cpp generate_minimum_dependency_set_internal.
//
// WHAT THIS IS FOR, since no diagnostic reads the result: the dependency set is the checker's
// output to a BACKEND. add_dependency_to_set drains each reached entity's decl.type_info_deps
// into add_min_dep_type_info, which is the ONLY route into the type-info roster -- in C++ as
// well as here (the only non-recursive callers are two sites in checker.cpp, both inside
// add_dependency_to_set). Basic types therefore arrive TRANSITIVELY, because
// add_min_dep_type_info recurses through composites into their constituents
// (checker.cpp:2657-2767). LEDGER #638 stage 2.
//
// WHAT THIS DELIBERATELY DOES NOT DO. C++'s @(init)/@(fini) arms (checker.cpp:3009-3086) carry a
// large block of VALIDATION DIAGNOSTICS -- signature, calling convention, file scope, disabled,
// blank identifier. The port already emits all of those at DECLARATION time
// (check_decl.odin:1140-1195, LEDGER #286), so only the set/roster half belongs here.
// Re-porting the diagnostics would DOUBLE-REPORT every one of them.
generate_minimum_dependency_set_internal :: proc(c: ^Checker, start: ^Entity) {
	// C++ 2965-2981: the definitions walk. Builtin-scope entities are added only when they have
	// NO type -- C++'s own condition, not a simplification.
	builtin_scope := get_package_scope(&c.info, c.info.builtin_package)
	for e in c.info.definitions {
		if e == nil {
			continue
		}
		if e.scope != nil && e.scope == builtin_scope {
			if e.type == nil {
				add_dependency_to_set(c, e)
			}
		} else if e.kind == .Procedure {
			if v, ok := e.variant.(Entity_Procedure); ok && v.is_export {
				add_dependency_to_set(c, e)
			}
		} else if e.kind == .Variable {
			if v, ok := e.variant.(Entity_Variable); ok && v.is_export {
				add_dependency_to_set(c, e)
			}
		}
	}

	// C++ 2983-2986: forced foreign imports. C++ moves each entity from the queue into the
	// array AND adds it, so the array read-back stays the record of what was forced.
	for {
		e, ok := queue.mpsc_dequeue(&c.info.required_foreign_imports_through_force_queue)
		if !ok {
			break
		}
		append(&c.info.required_foreign_imports_through_force, e)
		add_dependency_to_set(c, e)
	}

	// C++ 2988-2991: required global variables are FLAGGED used as well as added.
	for {
		e, ok := queue.mpsc_dequeue(&c.info.required_global_variable_queue)
		if !ok {
			break
		}
		e.flags += {.Used}
		add_dependency_to_set(c, e)
	}

	// C++ 2993-3088: the entities walk.
	for e in c.info.entities {
		if e == nil {
			continue
		}
		#partial switch e.kind {
		case .Variable:
			if v, ok := e.variant.(Entity_Variable); ok && v.is_export {
				add_dependency_to_set(c, e)
			} else if .Require in e.flags {
				add_dependency_to_set(c, e)
			}
		case .Procedure:
			if v, ok := e.variant.(Entity_Procedure); ok && v.is_export {
				add_dependency_to_set(c, e)
			} else if .Require in e.flags {
				add_dependency_to_set(c, e)
			}
			// C++ 3009-3049 / 3050-3086: the @(init) and @(fini) arms. Only the two lines
			// that are NOT diagnostics -- see the header note. C++ gates these on its
			// `is_init` / `is_fini` locals, which are false exactly when one of the
			// validations failed; the port's equivalent gate is that a rejected procedure
			// never reaches the roster it appends to.
			if .Init in e.flags {
				add_dependency_to_set(c, e)
			} else if .Fini in e.flags {
				add_dependency_to_set(c, e)
			}
		}
	}

	// C++ 3090-3105 is the Command_test arm, DELIBERATELY NOT PORTED HERE. It needs
	// collect_testing_procedures_of_package (checker.cpp:2919, ~45 lines carrying its own
	// test-signature diagnostics), which the port does not have at all. It is gated on
	// `-test`, which no checker harness uses. Filed rather than stubbed, so it cannot pass as
	// done -- the same treatment #524 gave its deliberately-excluded named-argument case.

	// C++ 3106-3109: the entry point, when there is one.
	if start != nil {
		start.flags += {.Used}
		add_dependency_to_set(c, start)
	}
}

// add_dependency_to_set adds an entity to the global dependency tracking set
// C++ Reference: checker.cpp add_dependency_to_set
// Used for minimum dependency set generation (only include what's actually used)
// (STRANDED above a different procedure until #734 -- another procedure was inserted between
//  this doc comment and the definition it documents.)
add_dependency_to_set :: proc(c: ^Checker, entity: ^Entity) {
	if entity == nil {
		return
	}

	// C++ Reference: checker.cpp add_dependency_to_set
	// The previous citation pointed ~200 lines earlier, into check_procedure_later's tail.
	// Skip polymorphic entities that haven't been specialized
	if entity.type != nil && is_type_polymorphic(entity.type) {
		decl := entity.decl_info
		if decl != nil && decl.gen_proc_type == nil {
			return
		}
	}

	// C++ Reference: checker.cpp:2582-2584
	// Use atomic increment to prevent duplicate processing
	// If this entity was already added (min_dep_count > 0), skip it
	sync.atomic_add(&entity.min_dep_count, 1)
	if entity.min_dep_count > 1 {
		return
	}

	// C++ Reference: checker.cpp:2586-2589
	decl := entity.decl_info
	if decl == nil {
		return
	}

	// C++ Reference: checker.cpp:2590-2592
	// Add all type_info dependencies
	sync.rw_mutex_shared_lock(&decl.type_info_deps_mutex)
	for _, type_dep in decl.type_info_deps {
		add_min_dep_type_info(c, type_dep)
	}
	sync.rw_mutex_shared_unlock(&decl.type_info_deps_mutex)

	// C++ Reference: checker.cpp:2593-2618
	// First pass: Add foreign library dependencies
	sync.rw_mutex_shared_lock(&decl.deps_mutex)
	for dep in decl.deps {
		#partial switch dep.kind {
		case .Procedure:
			proc_variant, ok := dep.variant.(Entity_Procedure)
			if ok && proc_variant.is_foreign {
				fl := proc_variant.foreign_library
				if fl != nil {
					assert(fl.kind == .Library_Name && .Used in fl.flags, "Foreign library must be used")
					add_dependency_to_set(c, fl)
				}
			}
		case .Variable:
			var, ok := dep.variant.(Entity_Variable)
			if ok && var.is_foreign {
				fl := var.foreign_library
				if fl != nil {
					assert(fl.kind == .Library_Name && .Used in fl.flags, "Foreign library must be used")
					add_dependency_to_set(c, fl)
				}
			}
		case:
		// Skip other entity kinds
		}
	}
	sync.rw_mutex_shared_unlock(&decl.deps_mutex)

	// C++ Reference: checker.cpp:2620-2622
	// Second pass: Recursively add all dependencies
	sync.rw_mutex_shared_lock(&decl.deps_mutex)
	for dep in decl.deps {
		add_dependency_to_set(c, dep)
	}
	sync.rw_mutex_shared_unlock(&decl.deps_mutex)
}


// C++ Reference: src/checker.hpp:282-395 (ScopeMap) and 468-515 (its iteration order).
//
// #214a. Diagnostics that walk a scope emit entities in C++'s SLOT order, and two earlier
// ledger entries (277, 334) recorded that order as "a property of its hash table" and
// therefore unreproducible. That was wrong, and it cost real parity:
//
//   * Scope::elements is NOT the StringMap used elsewhere in the compiler. It is a dedicated
//     open-addressed Robin Hood table with a fixed inline capacity of 16.
//   * InternedString::hash() hashes the string CONTENTS (src/string_interner.cpp:105), not an
//     address. No pointer, no ASLR, no allocation order -- the layout is a pure function of
//     the names and the order they were inserted.
//
// Verified by simulating this table against the oracle BEFORE porting it: it predicted the
// binding order for 4 independent name sets (including freshly invented ones), and then
// predicted 8/8 cases of whether the "With the following definitions:" header fires -- which
// depends purely on whether slot 0 holds a Constant. See LEDGER 353.
//
// SCOPE: this exists to order DIAGNOSTIC OUTPUT only. Lookup still goes through the map, and
// every other scope iteration stays name-sorted for determinism (task #50 / LEDGER 277).
SCOPE_MAP_INLINE_CAP :: 16

// C++ Reference: src/string_map.cpp:15. fnv32a masked to 31 bits, with 0 reserved as the
// "empty slot" marker so a real hash of 0 is bumped to 1.
scope_map_hash :: proc(s: string) -> u32 {
	h: u32 = 2166136261
	for i in 0..<len(s) {
		h ~= u32(s[i])
		h *= 16777619
	}
	r := h & 0x7fffffff
	return r if r != 0 else 1
}

Scope_Map_Slot :: struct {
	hash: u32,
	e:    ^Entity,
}

// C++ Reference: src/checker.hpp:300 scope_map_insert_for_rehash -- Robin Hood insertion,
// displacing whichever resident entry is closer to its ideal slot.
scope_map_sim_insert :: proc(slots: []Scope_Map_Slot, mask: u32, hash_in: u32, e_in: ^Entity) {
	hash, e := hash_in, e_in
	pos := hash & mask
	dist: u32 = 0
	for {
		s := &slots[pos]
		if s.hash == 0 {
			s.hash, s.e = hash, e
			return
		}
		existing := (pos - s.hash) & mask
		if dist > existing {
			s.hash, hash = hash, s.hash
			s.e, e = e, s.e
			dist = existing
		}
		dist += 1
		pos = (pos + 1) & mask
	}
}

// calc_decl_count is C++'s parser.cpp calc_decl_count. It counts DECLARED NAMES, not
// statements: `a, b, c :: 1, 2, 3` counts 3, a `when` contributes max(body, else), and a foreign
// block contributes its body's count. It feeds the scope-map RESERVE, so getting it wrong changes
// the map's capacity and therefore the iteration order (#657) -- it is not merely a size hint.
calc_decl_count :: proc(decl: ^ast.Node) -> int {
	if decl == nil {
		return 0
	}
	#partial switch d in decl.derived {
	case ^ast.Block_Stmt:
		count := 0
		for stmt in d.stmts {
			count += calc_decl_count(stmt)
		}
		return count
	case ^ast.When_Stmt:
		// C++ Reference: parser.cpp:6728-6736 -- MAX of the two arms, not their sum.
		inner := calc_decl_count(d.body)
		if d.else_stmt != nil {
			inner = max(inner, calc_decl_count(d.else_stmt))
		}
		return inner
	case ^ast.Value_Decl:
		return len(d.names)
	case ^ast.Foreign_Block_Decl:
		return calc_decl_count(d.body)
	case ^ast.Import_Decl:
		return 1
	case ^ast.Foreign_Import_Decl:
		return 1
	}
	return 0
}

// file_decl_count / pkg_decl_count mirror C++'s f->total_file_decl_count and the sum of it across
// a package's files (checker.cpp:254-256).
file_decl_count :: proc(file: ^ast.File) -> int {
	if file == nil {
		return 0
	}
	count := 0
	for decl in file.decls {
		count += calc_decl_count(decl)
	}
	return count
}

// scope_map_initial_cap reproduces the capacity C++'s scope map STARTS at, which is NOT always
// SCOPE_MAP_INLINE_CAP. Two different call sites reserve, with DIFFERENT formulas -- verified
// individually rather than assumed to share a rule (#657):
//   PACKAGE scope: checker.cpp:261 `scope_map_reserve(&s->elements, 2*total_pkg_decl_count)`
//   FILE scope:    checker.cpp:240-242 reserves `2 * max(DEFAULT_SCOPE_CAPACITY, 2*decl_count)`,
//                  because scope_reserve (checker.cpp:57) itself doubles what it is handed
// scope_map_reserve (checker.hpp:375) then adopts `next_pow2(n)` only when it EXCEEDS the inline
// capacity, which is why small scopes stay at 16 and matched even before this fix.
scope_map_initial_cap :: proc(scope: ^Scope) -> u32 {
	requested := 0
	if scope != nil {
		if .Pkg in scope.flags && scope.pkg != nil {
			total := 0
			for _, file in scope.pkg.files {
				total += file_decl_count(file)
			}
			requested = 2 * total
		} else if .File in scope.flags && scope.file != nil {
			requested = 2 * max(DEFAULT_SCOPE_CAPACITY, 2 * file_decl_count(scope.file))
		}
	}
	if requested <= SCOPE_MAP_INLINE_CAP {
		return u32(SCOPE_MAP_INLINE_CAP)
	}
	// next_pow2, as C++ next_pow2_u32
	n := u32(requested - 1)
	n |= n >> 1;  n |= n >> 2;  n |= n >> 4;  n |= n >> 8;  n |= n >> 16
	n += 1
	if n <= u32(SCOPE_MAP_INLINE_CAP) {
		return u32(SCOPE_MAP_INLINE_CAP)
	}
	return n
}

// entities must be given in INSERTION order (for a polymorphic parameter scope that is source
// order). Returns them in the slot order C++ would iterate.
//
// start_cap is what C++'s map was RESERVED to before the first insert -- see
// scope_map_initial_cap. It defaults to the inline capacity for scopes that are never reserved
// (proc bodies, blocks, parameter scopes).
scope_map_slot_order :: proc(entities: []^Entity, allocator := context.temp_allocator, start_cap: u32 = SCOPE_MAP_INLINE_CAP) -> []^Entity {
	cap_ := start_cap
	slots := make([]Scope_Map_Slot, cap_, context.temp_allocator)

	count: u32 = 0
	for e in entities {
		// C++ Reference: src/checker.hpp:392 -- grow at 75% load BEFORE inserting, rehashing
		// in old-slot order (not insertion order), which can permute the result.
		if count >= cap_ - (cap_ >> 2) {
			new_cap := cap_ << 1
			new_slots := make([]Scope_Map_Slot, new_cap, context.temp_allocator)
			for i in 0..<cap_ {
				if slots[i].hash != 0 {
					scope_map_sim_insert(new_slots, new_cap - 1, slots[i].hash, slots[i].e)
				}
			}
			slots, cap_ = new_slots, new_cap
		}
		scope_map_sim_insert(slots, cap_ - 1, scope_map_hash(e.token.text), e)
		count += 1
	}

	out := make([dynamic]^Entity, 0, len(entities), allocator)
	for i in 0..<cap_ {
		if slots[i].hash != 0 {
			append(&out, slots[i].e)
		}
	}
	return out[:]
}
