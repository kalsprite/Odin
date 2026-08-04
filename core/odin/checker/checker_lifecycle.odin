package checker

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:math/big"
import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:sync"
import "core:time"
/*
Checker Lifecycle Management

This module implements initialization and cleanup for the checker system

*/


// ======================================================================================
// CHECKER_INFO INITIALIZATION
// ======================================================================================

// init_checker_info initializes all maps and queues in Checker_Info
// C++ Reference: Checker initialization in checker.cpp
init_checker_info :: proc(info: ^Checker_Info, allocator := context.allocator) {
	// Core maps
	info.files = make(map[string]^ast.File, allocator)
	info.packages = make(map[string]^ast.Package, allocator)
	info.foreigns = make(map[string]^Entity, allocator)
	info.package_scopes = make(map[^ast.Package]^Scope, allocator)
	info.file_scopes = make(map[^ast.File]^Scope, allocator)
	info.files_by_id = make(map[i32]^ast.File, allocator)
	// C++ Reference: checker.hpp obcj_class_name_set -- guarded by objc_class_name_mutex.
	info.objc_class_names = make(map[string]bool, allocator)

	// AST state flags map for tracking node state during checking
	info.ast_state_flags = make(map[rawptr]ast.Node_State_Flags, allocator)

	// ast_entity_map deleted - entities now stored directly on AST nodes
	// ast_parent_entity_map deleted - not needed

	// AST flag storage deleted - flags now stored directly on AST nodes
	// node.state_flags and node.viral_state_flags

	// When statement condition memoization deleted - stored directly on AST nodes

	// File scope storage - DELETED (stored directly on ast.File.scope)

	// File metadata storage - DELETED (all stored directly on ast.File)

	// Package metadata storage - DELETED (stored directly on ast.Package)
	// Exported entity queues are now stored on pkg.exported_entity_queue

	// AST node to scope mapping - DELETED (stored directly on statement/type nodes)

	// Delayed declaration queues - DELETED (stored directly on ast.File)

	// Global untyped expressions
	info.global_untyped = make(map[^ast.Expr]^Expr_Info, allocator)

	// Type and value mapping - DELETED (stored directly on ast.Node.tav)

	// Minimum dependency type info tracking
	info.min_dep_type_info_set = make(map[u64]Type_Info_Pair, allocator)
	info.min_dep_type_info_index_map = make(map[u64]i64, allocator)

	// Initialize entity processing queues
	queue.mpsc_init(&info.definition_queue)
	queue.mpsc_init(&info.entity_queue)
	queue.mpsc_init(&info.required_global_variable_queue)
	queue.mpsc_init(&info.required_foreign_imports_through_force_queue)
	queue.mpsc_init(&info.foreign_imports_to_check_fullpaths)
	queue.mpsc_init(&info.foreign_decls_to_check)
	queue.mpsc_init(&info.raddbg_type_views_queue)
	queue.mpsc_init(&info.intrinsics_entry_point_usage)
	queue.mpsc_init(&info.objc_class_implementations)
	queue.mpsc_init(&info.all_procedures_queue)

	// Initialize dynamic arrays
	info.definitions = make([dynamic]^Entity, allocator)
	info.entities = make([dynamic]^Entity, allocator)
	info.all_procedures = make([dynamic]^Proc_Info, allocator)
	info.raddbg_type_views = make([dynamic]Raddbg_Type_View, allocator)
	info.required_foreign_imports_through_force = make([dynamic]^Entity, allocator)
	info.testing_procedures = make([dynamic]^Entity, allocator)
	info.init_procedures = make([dynamic]^Entity, allocator)
	info.fini_procedures = make([dynamic]^Entity, allocator)
	info.variable_init_order = make([dynamic]^Decl_Info, allocator)
	info.type_info_types_hash_map = make([dynamic]Type_Info_Pair, allocator)
}

// ======================================================================================
// CHECKER_INFO CLEANUP
// ======================================================================================

destroy_checker_info :: proc(info: ^Checker_Info) {
	// Core maps
	delete(info.files)
	delete(info.packages)
	delete(info.foreigns)
	delete(info.package_scopes)
	delete(info.file_scopes)
	delete(info.files_by_id)
	delete(info.objc_class_names)
	delete(info.ast_state_flags)

	// ast_entity_map deleted - no cleanup needed
	// ast_parent_entity_map deleted - no cleanup needed

	// AST flag storage deleted - no cleanup needed (stored on AST nodes)

	// When statement memoization deleted - no cleanup needed

	// File scopes - DELETED (no cleanup needed, stored on AST nodes)

	// File metadata cleanup - DELETED (all stored on AST nodes, no cleanup needed)

	// Package metadata cleanup - DELETED (stored on AST nodes, no cleanup needed)
	// Exported entity queues are now on ast.Package and cleaned up by package allocator

	// AST scope mapping - DELETED (no cleanup needed, stored on AST nodes)

	// Delayed declaration cleanup - DELETED (stored on AST nodes, cleaned up by AST allocator)

	// Global untyped expressions
	delete(info.global_untyped)

	// Type and value mapping - DELETED (no cleanup needed, stored on AST nodes)

	// Minimum dependency type info
	delete(info.min_dep_type_info_set)
	delete(info.min_dep_type_info_index_map)

	// Clean up entity processing queues
	queue.mpsc_destroy(&info.definition_queue)
	queue.mpsc_destroy(&info.entity_queue)
	queue.mpsc_destroy(&info.required_global_variable_queue)
	queue.mpsc_destroy(&info.required_foreign_imports_through_force_queue)
	queue.mpsc_destroy(&info.foreign_imports_to_check_fullpaths)
	queue.mpsc_destroy(&info.foreign_decls_to_check)
	queue.mpsc_destroy(&info.raddbg_type_views_queue)
	queue.mpsc_destroy(&info.intrinsics_entry_point_usage)
	// C++ Reference: checker.cpp:1678 -- `// mpsc_destroy(&i->objc_class_implementations);`
	// is COMMENTED OUT upstream, deliberately. The queue's consumer lives in the BACKEND
	// (llvm_backend.cpp:1571 dequeues it), which runs after checking, so the queue is
	// legitimately non-empty when the checker finishes and must not be torn down here.
	//
	// The port destroyed it, and this port's mpsc_destroy asserts the queue is EMPTY (LEDGER
	// #16), so the first program to enqueue anything aborted the checker with SIGILL at
	// teardown -- after checking succeeded, which is why the diagnostics never reached the
	// output. Latent until now only because the @(objc_implement) gate was dead (wrong
	// attribute name, LEDGER #283), so nothing was ever enqueued. This is LEDGER #21, and it
	// is NOT darwin-specific: it aborts on any target once the queue is populated.
	// queue.mpsc_destroy(&info.objc_class_implementations)
	queue.mpsc_destroy(&info.all_procedures_queue)

	// Clean up dynamic arrays
	delete(info.definitions)
	delete(info.entities)
	delete(info.all_procedures)
	delete(info.raddbg_type_views)
	delete(info.required_foreign_imports_through_force)
	delete(info.testing_procedures)
	delete(info.init_procedures)
	delete(info.fini_procedures)
	delete(info.variable_init_order)
	delete(info.type_info_types_hash_map)
}

// ======================================================================================
// CHECKER INITIALIZATION
// ======================================================================================

// Global mutex to protect one-time initialization of thread pool and basic types
// This prevents race conditions when multiple threads call init_checker concurrently
@(private="file")
init_mutex: sync.Mutex

// init_checker initializes a Checker instance
// C++ Reference: Checker construction in checker.cpp
init_checker :: proc(c: ^Checker, allocator := context.allocator) {
	c.allocator = allocator

	// Thread-safe one-time initialization of global resources
	// Use mutex to prevent race conditions when tests run in parallel
	{
		sync.lock(&init_mutex)
		defer sync.unlock(&init_mutex)

		// Initialize thread pool for parallel checking (if not already initialized)
		// C++ Reference: main.cpp:15-20 (ThreadPool initialization)
		// The global thread pool is shared across all checkers
		if global_thread_pool == nil && !build_context.no_threaded_checker {
			// Use hardware thread count (or minimum of 1 worker)
			// C++ uses same approach: worker_count = max(1, cpu_count - 1)
			cpu_count := os.get_processor_core_count()
			worker_count := max(1, cpu_count - 1) // Leave one core for main thread
			global_thread_pool = thread_pool_init(worker_count, runtime.default_allocator())
		}

		// Initialize basic type singletons (idempotent - only runs once)
		// C++ Reference: Basic types are global statics initialized at startup
		// Note: Always use default allocator for basic types since they're global singletons
		// that must persist across test runs (temp allocator would invalidate them)
		if t_int == nil {
			init_basic_types(runtime.default_allocator())
		}
	}

	// Initialize Checker_Info
	init_checker_info(&c.info, allocator)
	c.info.checker = c

	// LEDGER #329. This field was declared (checker.odin:1148) and NEVER assigned, so it was nil
	// for the whole life of every Checker and all 28 of its nil-guarded read sites silently took
	// the nil branch -- among them the entire entry-point block in check_decl.odin (the 'proc()'
	// type check, the custom-calling-convention check, the entry_point registration and its
	// redeclaration diagnostic) and the is-darwin predicate in check_decl_helpers.odin.
	//
	// C++ keeps build_context as a global; the port ALSO has that global (build_settings.odin:478)
	// and most of the checker reads it directly. The Checker_Info copy was introduced "for better
	// encapsulation", threaded through 28 sites, and then never connected to anything. Pointing it
	// at the same global is what makes those readers agree with the direct readers.
	//
	// Taking the address here is safe before ensure_build_context_initialized() runs: the global is
	// a package-level variable and always addressable, and every reader dereferences it during
	// checking, long after the target has been filled in.
	c.info.build_context = &build_context

	// Initialize the builtin context the same way C++ init_checker_context does, so that
	// anything reached through it has a valid type path to push onto.
	// C++ Reference: checker.cpp:1685-1693
	c.builtin_ctx.checker = c
	c.builtin_ctx.info = &c.info
	c.builtin_ctx.type_path = new_checker_type_path(allocator)
	c.builtin_ctx.type_level = 0

	// Initialize builtin packages (builtin, intrinsics, config)
	// C++ Reference: checker.cpp:1102-1105
	init_builtin_packages(&c.info, allocator)

	// Populate builtin package with type entities (int, bool, string, etc.)
	// This enables scope lookup for builtin type names
	populate_builtin_package_scope(&c.info, allocator)

	// Initialize processing arrays
	c.procs_to_check = make([dynamic]^Proc_Info, allocator)
	c.nested_proc_lits = make([dynamic]^Decl_Info, allocator)

	// Initialize additional queues
	queue.mpsc_init(&c.procs_with_deferred_to_check)
	queue.mpsc_init(&c.procs_with_objc_context_provider_to_check)
	queue.mpsc_init(&c.global_untyped_queue)
	queue.mpsc_init(&c.soa_types_to_complete)
}

// destroy_checker cleans up a Checker instance
destroy_checker :: proc(c: ^Checker) {
	// Clean up the builtin context's type path
	// C++ Reference: checker.cpp:1695-1697 (destroy_checker_context)
	destroy_checker_type_path(c.builtin_ctx.type_path, c.allocator)
	c.builtin_ctx.type_path = nil

	// Clean up Checker_Info
	destroy_checker_info(&c.info)

	// Clean up processing arrays
	delete(c.procs_to_check)
	delete(c.nested_proc_lits)

	// Clean up additional queues
	queue.mpsc_destroy(&c.procs_with_deferred_to_check)
	queue.mpsc_destroy(&c.procs_with_objc_context_provider_to_check)
	queue.mpsc_destroy(&c.global_untyped_queue)
	queue.mpsc_destroy(&c.soa_types_to_complete)

	// Reset runtime type globals to prevent stale pointers
	// This is critical for tests that use temp_allocator - without this,
	// the next test would read freed memory and panic with "unhandled type kind"
	reset_runtime_type_globals()
}

// destroy_global_thread_pool cleans up the global thread pool
// C++ Reference: main.cpp:3779 (thread_pool_destroy)
// Should be called at program exit (not per-checker since pool is shared)
destroy_global_thread_pool :: proc() {
	if global_thread_pool != nil {
		thread_pool_destroy(global_thread_pool)
		global_thread_pool = nil
	}
}

// ======================================================================================
// BUILTIN PACKAGE INITIALIZATION
// ======================================================================================

// create_builtin_package creates a synthetic package for builtin entities
// C++ Reference: checker.cpp:1098-1112
create_builtin_package :: proc(name: string, allocator := context.allocator) -> ^ast.Package {
	pkg := new(ast.Package, allocator)
	pkg.name = name
	pkg.kind = .Normal
	pkg.scope = create_scope(nil, allocator) // No parent scope for builtin packages
	pkg.scope.flags += {.Pkg}
	return pkg
}

// init_builtin_packages initializes the builtin, intrinsics, config, and runtime packages
// C++ Reference: checker.cpp:1102-1105
init_builtin_packages :: proc(info: ^Checker_Info, allocator := context.allocator) {
	info.builtin_package = create_builtin_package("builtin", allocator)
	info.intrinsics_package = create_builtin_package("intrinsics", allocator)
	info.config_package = create_builtin_package("config", allocator)

	// Register builtin package scopes in the package_scopes map
	// This allows create_scope_from_package to find the builtin scope as parent
	if info.builtin_package != nil && info.builtin_package.scope != nil {
		info.package_scopes[info.builtin_package] = info.builtin_package.scope
	}
	if info.intrinsics_package != nil && info.intrinsics_package.scope != nil {
		info.package_scopes[info.intrinsics_package] = info.intrinsics_package.scope
	}
	if info.config_package != nil && info.config_package.scope != nil {
		info.package_scopes[info.config_package] = info.config_package.scope
	}

	// Initialize ODIN_ROOT from environment if not set.
	// The loader needs it to resolve `base:runtime` and every other collection path.
	init_odin_root_from_env()

	// NOTE: base:runtime is deliberately NOT created here, and info.runtime_package is left nil.
	//
	// It used to be synthesized at this point by extract_runtime_types, which produced a package
	// of placeholder entities - struct fields typed t_untyped_nil, distinct types with no base -
	// because nothing here can resolve types before checking has begun. It is now a real,
	// parsed, checked package, seeded by the loader (see seed comment in
	// load_package_with_dependencies) exactly as the C++ compiler seeds it in parse_packages
	// (src/parser.cpp:7062-7071), which is likewise a parser-phase job and not a checker-init
	// job. info.runtime_package is set when that package is registered, and again by
	// register_packages_from_files from its .Runtime kind.
	//
	// The consequence for a caller that bypasses the loader - handing check_files a file list it
	// assembled itself - is that there is no runtime package at all, and the preload types
	// (t_type_info and friends) stay nil. That was already the outcome whenever ODIN_ROOT could
	// not be found; it is now simply the outcome whenever runtime was not loaded. Every consumer
	// of info.runtime_package tolerates nil for that reason.
}

// populate_config_package_scope adds defined_values to config_package scope as constants
// C++ Reference: checker.cpp:1380-1410
// Called after init_builtin_packages, before checking user code
populate_config_package_scope :: proc(info: ^Checker_Info) -> (had_double_declaration: bool) {
	if info.config_package == nil {
		return false
	}

	config_scope := info.config_package.scope
	if config_scope == nil {
		return false
	}

	for name, value in build_context.defined_values {
		// Determine type from value kind
		// C++ checker.cpp:1386-1399
		type: ^Type = nil
		#partial switch _ in value {
		case bool:
			type = t_untyped_bool
		case string:
			type = t_untyped_string
		case big.Int:
			type = t_untyped_integer
		case f64:
			type = t_untyped_float
		}

		if type == nil {
			continue // Skip invalid values (complex, quaternion, etc.)
		}

		// Create constant entity
		// C++ checker.cpp:1401-1403
		entity := alloc_entity_constant(nil, make_token_ident(name), type, value)
		entity.state = .Resolved

		// Insert into config scope - returns nil on success, existing entity on collision
		// C++ checker.cpp:1404-1408
		if scope_insert(config_scope, entity) != nil {
			error(entity.token, "'%s' defined as an argument is already declared at the global scope", name)
			had_double_declaration = true
		}
	}

	return had_double_declaration
}

// Global_Enum_Value is one member of a synthesized universe-scope enum.
// C++ Reference: checker.cpp:1044-1047 (struct GlobalEnumValue)
Global_Enum_Value :: struct {
	name:  string,
	value: i64,
}

// add_global_type_entity registers a type under `name` in `scope`.
// C++ Reference: checker.cpp:1026-1028 (add_global_type_entity)
@(private = "file")
add_global_type_entity :: proc(scope: ^Scope, name: string, type: ^Type, alloc: mem.Allocator) {
	if type == nil {
		return
	}
	token := make_token_ident(name)
	entity := alloc_entity_type_name(scope, token, type, .Resolved, alloc)
	scope_insert(scope, entity)
}

// set_type_name_entity_type points a type-name entity at `type`.
//
// Both fields have to be written: `Entity.type` is what most of the checker reads, but
// get_entity_type (check_expr.odin:303-305) goes through the Entity_Type_Name variant, which
// alloc_entity only fills in from the `type` argument - and these entities are necessarily
// allocated before their named type exists, because the named type points back at them.
@(private = "file")
set_type_name_entity_type :: proc(entity: ^Entity, type: ^Type) {
	entity.type = type
	if tn, ok := &entity.variant.(Entity_Type_Name); ok {
		tn.type = type
	}
}

// add_global_constant registers a constant under `name` in `scope`.
// C++ Reference: checker.cpp:1012-1016 (add_global_constant)
@(private = "file")
add_global_constant :: proc(scope: ^Scope, name: string, type: ^Type, value: Exact_Value, alloc: mem.Allocator) {
	if type == nil {
		return
	}
	token := make_token_ident(name)
	entity := alloc_entity_constant(scope, token, type, value, alloc)
	entity.state = .Resolved
	scope_insert(scope, entity)
}

// C++ Reference: checker.cpp:1019-1021 (add_global_string_constant)
@(private = "file")
add_global_string_constant :: proc(scope: ^Scope, name: string, value: string, alloc: mem.Allocator) {
	add_global_constant(scope, name, t_untyped_string, exact_value_string(value), alloc)
}

// C++ Reference: checker.cpp:1023-1025 (add_global_bool_constant)
@(private = "file")
add_global_bool_constant :: proc(scope: ^Scope, name: string, value: bool, alloc: mem.Allocator) {
	add_global_constant(scope, name, t_untyped_bool, exact_value_bool(value), alloc)
}

// add_global_enum_type synthesizes a named enum type whose members are `values`.
//
// C++ Reference: checker.cpp:1049-1091 (add_global_enum_type)
//
// The type-name entity is deliberately NOT inserted into the builtin scope: exactly as in
// C++, these enum types are anonymous as far as checked code is concerned. Only the constants
// derived from them (ODIN_OS, ODIN_ENDIAN, ...) are visible, and the enum's own scope exists
// so that an implicit selector (`.Little`) has fields to resolve against. Callers that do want
// the name visible (intrinsics.Atomic_Memory_Order) insert the returned entity themselves.
@(private = "file")
// add_global_type_name creates a named type entity and registers it in `scope`.
// C++ Reference: /mnt/c/odin/src/checker.cpp `add_global_type_name`.
add_global_type_name :: proc(scope: ^Scope, name: string, base: ^Type, alloc: mem.Allocator) -> ^Type {
	entity := alloc_entity_type_name(scope, make_token_ident(name), nil, .Resolved, alloc)
	named_type := alloc_type_named(name, base, entity)
	set_base_type(named_type, base)
	set_type_name_entity_type(entity, named_type)
	entity.flags += {.Visited}
	scope_insert(scope, entity)
	return named_type
}

// init_objc_intrinsics_types synthesises the Objective-C opaque types and registers them.
// C++ Reference: /mnt/c/odin/src/checker.cpp:1513-1525. Same reasoning as
// init_c_va_list_type: base:intrinsics is never parsed, so these must be synthesised rather
// than looked up. They are opaque — no field of them is ever named by user code — so an
// empty struct is the whole definition, exactly as in C++.
init_objc_intrinsics_types :: proc(intrinsics_scope: ^Scope, alloc: mem.Allocator) {
	if intrinsics_scope == nil {
		return
	}

	t_objc_object   = add_global_type_name(intrinsics_scope, "objc_object",   alloc_type_struct_complete(), alloc)
	t_objc_selector = add_global_type_name(intrinsics_scope, "objc_selector", alloc_type_struct_complete(), alloc)
	t_objc_class    = add_global_type_name(intrinsics_scope, "objc_class",    alloc_type_struct_complete(), alloc)
	t_objc_ivar     = add_global_type_name(intrinsics_scope, "objc_ivar",     alloc_type_struct_complete(), alloc)

	t_objc_id    = alloc_type_pointer(t_objc_object)
	t_objc_SEL   = alloc_type_pointer(t_objc_selector)
	t_objc_Class = alloc_type_pointer(t_objc_class)
	t_objc_Ivar  = alloc_type_pointer(t_objc_ivar)

	// C++ line 1524. Unlike the four above, this is an ALIAS: its backing type is t_objc_id
	// (i.e. ^objc_object), not a fresh struct. Probes oi_ivar/oi_inst confirmed both names were
	// simply absent from the port -- `'objc_ivar' is not declared by 'intrinsics'` where the
	// reference resolves them silently (#295).
	t_objc_instancetype = add_global_type_name(intrinsics_scope, "objc_instancetype", t_objc_id, alloc)
}

// init_c_va_list_type synthesises `intrinsics.c_va_list` and registers it.
//
// C++ Reference: /mnt/c/odin/src/checker.cpp:1528-1591. C++ builds this struct itself in
// init_universal and registers it into the intrinsics package's scope, because
// base:intrinsics is a RESERVED package whose source is never parsed.
//
// The port previously tried to SOURCE the type instead — init_c_va_list_types (type_info.odin)
// called find_intrinsics_type("c_va_list"), looking it up in exactly that unparsed package —
// so it was permanently nil and the name was never in scope at all. Every
// `va_list :: intrinsics.c_va_list` (core/c/libc/stdarg.odin, and every libc declaration
// taking a `^va_list`) therefore failed.
//
// The layout is platform-specific and must match the C ABI.
init_c_va_list_type :: proc(intrinsics_scope: ^Scope, alloc: mem.Allocator) {
	if intrinsics_scope == nil {
		return
	}

	scope := create_scope(intrinsics_scope, alloc)
	fields := make([dynamic]^Entity, 0, 5, alloc)

	add_field :: proc(fields: ^[dynamic]^Entity, scope: ^Scope, type: ^Type, index: i32, name: string, alloc: mem.Allocator) {
		e := alloc_entity_field(scope, make_token_ident(name), type, false, index, .Resolved, alloc)
		append(fields, e)
	}

	bc := &build_context
	switch bc.metrics.arch {
	case .Amd64:
		// C++ line 1541-1554
		#partial switch bc.metrics.os {
		case .Freestanding, .Linux, .Freebsd, .Netbsd, .Openbsd:
			add_field(&fields, scope, t_u32,    0, "gp_offset", alloc)
			add_field(&fields, scope, t_u32,    1, "fp_offset", alloc)
			add_field(&fields, scope, t_rawptr, 2, "overflow_arg_area", alloc)
			add_field(&fields, scope, t_rawptr, 3, "reg_save_area", alloc)
		}
	case .Arm64:
		// C++ line 1556-1576
		#partial switch bc.metrics.os {
		case .Darwin:
			// AARCH64 on darwin differs from other arm64 platforms
			add_field(&fields, scope, t_rawptr, 0, "_", alloc)
		case .Freestanding, .Linux, .Freebsd, .Netbsd, .Openbsd:
			add_field(&fields, scope, t_rawptr, 0, "__stack", alloc)
			add_field(&fields, scope, t_rawptr, 1, "__gr_top", alloc)
			add_field(&fields, scope, t_rawptr, 2, "__vr_top", alloc)
			add_field(&fields, scope, t_i32,    3, "__gr_offs", alloc)
			add_field(&fields, scope, t_i32,    4, "__vr_offs", alloc)
		}
	case .Invalid, .I386, .Arm32, .Wasm32, .Wasm64p32, .Riscv64:
		// C++ leaves these to the fallback below.
	}

	// C++ line 1580-1582: never leave it empty, or size_of would be 0.
	if len(fields) == 0 {
		add_field(&fields, scope, t_rawptr, 0, "_", alloc)
	}

	va_list_struct := alloc_type_struct_complete()
	st := &va_list_struct.variant.(Type_Struct)
	st.scope = scope
	st.fields = fields

	t_c_va_list = add_global_type_name(intrinsics_scope, "c_va_list", va_list_struct, alloc)
	t_c_va_list_ptr = alloc_type_pointer(t_c_va_list)
}

add_global_enum_type :: proc(
	builtin_scope: ^Scope,
	type_name: string,
	values: []Global_Enum_Value,
	backing_type: ^Type,
	alloc: mem.Allocator,
) -> (
	fields: []^Entity,
	named_type: ^Type,
) {
	scope := create_scope(builtin_scope, alloc)
	entity := alloc_entity_type_name(scope, make_token_ident(type_name), nil, .Resolved, alloc)

	enum_type := alloc_type_enum()
	named_type = alloc_type_named(type_name, enum_type, entity)
	set_base_type(named_type, enum_type)
	set_type_name_entity_type(entity, named_type)

	et := &enum_type.variant.(Type_Enum)
	et.base_type = backing_type != nil ? backing_type : t_int
	et.scope = scope

	field_array := make([dynamic]^Entity, 0, len(values), alloc)
	for v in values {
		e := alloc_entity_constant(scope, make_token_ident(v.name), named_type, exact_value_i64(v.value), alloc)
		e.flags += {.Visited}
		e.state = .Resolved
		append(&field_array, e)
		scope_insert(scope, e)
	}

	et.fields = field_array
	et.min_value_index = 0
	et.max_value_index = i64(len(values) - 1)
	if len(values) > 0 {
		et.min_value = exact_value_i64(values[0].value)
		et.max_value = exact_value_i64(values[len(values) - 1].value)
	}

	return field_array[:], named_type
}

// add_global_enum_constant registers `name` as a constant of the enum whose members are
// `fields`, picking the member whose value is `value`.
//
// C++ Reference: checker.cpp:1092-1102 (add_global_enum_constant)
//
// DEVIATION: C++ calls GB_PANIC when no member matches. The port cannot: the port's own
// target tables are a superset of the C++ ones (Target_Os_Kind still carries the retired
// Essence and Haiku entries - see the note in package_resolver.odin; task #5 is CLOSED and
// left these deliberately, so the superset is permanent), so a
// build context naming one of those has no member to select. Registering nothing leaves the
// name undeclared, which is a diagnostic rather than a crash.
@(private = "file")
add_global_enum_constant :: proc(
	scope: ^Scope,
	fields: []^Entity,
	values: []Global_Enum_Value,
	name: string,
	value: i64,
	alloc: mem.Allocator,
) {
	for v, i in values {
		if v.value == value {
			field := fields[i]
			add_global_constant(scope, name, field.type, field.variant.(Entity_Constant).value, alloc)
			return
		}
	}
}

// odin_os_enum_value maps a target OS onto the C++ TargetOsKind ordinal.
// C++ Reference: build_settings.cpp:14-31
//
// The port's Target_Os_Kind still carries Essence and Haiku, which upstream retired; both
// map to Unknown here so that the synthesized Odin_OS_Type matches C++ member-for-member.
@(private = "file")
odin_os_enum_value :: proc(os: Target_Os_Kind) -> i64 {
	switch os {
	case .Invalid:
		return 0
	case .Windows:
		return 1
	case .Darwin:
		return 2
	case .Linux:
		return 3
	case .Freebsd:
		return 4
	case .Openbsd:
		return 5
	case .Netbsd:
		return 6
	case .Wasi:
		return 7
	case .Js:
		return 8
	case .Orca:
		return 9
	case .Freestanding:
		return 10
	}
	return 0
}

// odin_subtarget_enum_value maps a subtarget onto the C++ Subtarget ordinal.
// C++ Reference: build_settings.cpp:169-178
//
// The port has no Playdate subtarget (task #5 is CLOSED; this was left as-is) and carries an
// `Invalid` sentinel
// where C++ puts Playdate; `Invalid` is never a selected subtarget, so it maps to Default.
@(private = "file")
odin_subtarget_enum_value :: proc(st: Subtarget) -> i64 {
	switch st {
	case .Default, .Invalid:
		return 0
	case .IPhone:
		return 1
	case .IPhoneSimulator:
		return 2
	case .Android:
		return 3
	}
	return 0
}

// odin_calling_convention_enum_value maps a calling convention onto the C++ ProcCC ordinal.
// C++ Reference: parser.hpp:288-311
odin_calling_convention_enum_value :: proc(cc: Calling_Convention) -> i64 {
	switch cc {
	case .Odin:
		return 1
	case .Contextless:
		return 2
	case .C:
		return 3
	case .Std:
		return 4
	case .Fast:
		return 5
	case .None:
		return 6
	case .Naked:
		return 7
	case .Inline_Asm:
		return 8
	case .Win64:
		return 9
	case .SysV:
		return 10
	case .Preserve_None:
		return 11
	case .Preserve_Most:
		return 12
	case .Preserve_All:
		return 13
	case .Invalid:
		return 0
	}
	return 0
}

// parse_minimum_os_version turns "major.minor.revision" into (major*10000)+(minor*100)+revision.
// C++ Reference: checker.cpp:1338-1352
@(private = "file")
parse_minimum_os_version :: proc(s: string) -> i64 {
	if len(s) == 0 {
		return 0
	}
	// C++ uses sscanf("%d.%d.%d"), which leaves any component it could not read at its
	// initial value - 0 for revision, indeterminate for major/minor, in practice 0.
	parts: [3]i64
	idx := 0
	seen_digit := false
	for ch in s {
		if ch >= '0' && ch <= '9' {
			parts[idx] = parts[idx] * 10 + i64(ch - '0')
			seen_digit = true
		} else if ch == '.' {
			if !seen_digit {
				break
			}
			idx += 1
			seen_digit = false
			if idx >= len(parts) {
				break
			}
		} else {
			break
		}
	}
	return parts[0] * 10000 + parts[1] * 100 + parts[2]
}

// populate_builtin_package_scope populates the universe scope: builtin types, the ODIN_*
// build constants and their enum types, and the builtin/intrinsics procedures.
//
// C++ Reference: checker.cpp:1113-1592 (init_universal)
//
// Everything here that describes the target is read from `build_context`, never from the
// host, because the checker supports cross-target checking. C++ guarantees the ordering by
// running init_build_context in main before init_universal; the port has no main, so this
// calls ensure_build_context_initialized directly.
populate_builtin_package_scope :: proc(info: ^Checker_Info, allocator := context.allocator) {
	if info.builtin_package == nil {
		return
	}

	builtin_scope := info.builtin_package.scope
	if builtin_scope == nil {
		return
	}

	// Every implicit allocation below (alloc_type, the big.Int digits behind
	// exact_value_i64, the enum field arrays) must come from the checker's allocator, not
	// from whatever context the embedder happened to call init_checker under. The universe
	// entities live exactly as long as the Checker does.
	context.allocator = allocator

	// C++ runs init_build_context (main.cpp) long before init_universal; without a target
	// here every ODIN_* constant below would describe the zero value instead of the target.
	ensure_build_context_initialized()

	bc := &build_context

	// ------------------------------------------------------------------------------
	// Types
	// C++ Reference: checker.cpp:1120-1133
	//
	// C++ walks the `basic_types` table and registers every entry whose name has no space
	// in it (which is how "invalid type", "llvm bool" and every "untyped x" are skipped).
	// The port keeps that filtering implicit by naming the registered types outright.
	// ------------------------------------------------------------------------------

	// C++ Reference: checker.cpp:1123-1129 - `-bedrock` drops the 128-bit integers.
	bedrock := bc.bedrock

	// Boolean types
	add_global_type_entity(builtin_scope, "bool", t_bool, allocator)
	add_global_type_entity(builtin_scope, "b8", t_b8, allocator)
	add_global_type_entity(builtin_scope, "b16", t_b16, allocator)
	add_global_type_entity(builtin_scope, "b32", t_b32, allocator)
	add_global_type_entity(builtin_scope, "b64", t_b64, allocator)

	// Integer types
	add_global_type_entity(builtin_scope, "i8", t_i8, allocator)
	add_global_type_entity(builtin_scope, "i16", t_i16, allocator)
	add_global_type_entity(builtin_scope, "i32", t_i32, allocator)
	add_global_type_entity(builtin_scope, "i64", t_i64, allocator)
	add_global_type_entity(builtin_scope, "int", t_int, allocator)

	add_global_type_entity(builtin_scope, "u8", t_u8, allocator)
	add_global_type_entity(builtin_scope, "u16", t_u16, allocator)
	add_global_type_entity(builtin_scope, "u32", t_u32, allocator)
	add_global_type_entity(builtin_scope, "u64", t_u64, allocator)
	add_global_type_entity(builtin_scope, "uint", t_uint, allocator)
	add_global_type_entity(builtin_scope, "uintptr", t_uintptr, allocator)

	// Floating point types
	add_global_type_entity(builtin_scope, "f16", t_f16, allocator)
	add_global_type_entity(builtin_scope, "f32", t_f32, allocator)
	add_global_type_entity(builtin_scope, "f64", t_f64, allocator)

	// Character types
	add_global_type_entity(builtin_scope, "rune", t_rune, allocator)
	add_global_type_entity(builtin_scope, "byte", t_u8, allocator) // byte is alias for u8

	// Complex types
	add_global_type_entity(builtin_scope, "complex32", t_complex32, allocator)
	add_global_type_entity(builtin_scope, "complex64", t_complex64, allocator)
	add_global_type_entity(builtin_scope, "complex128", t_complex128, allocator)

	// Quaternion types
	add_global_type_entity(builtin_scope, "quaternion64", t_quaternion64, allocator)
	add_global_type_entity(builtin_scope, "quaternion128", t_quaternion128, allocator)
	add_global_type_entity(builtin_scope, "quaternion256", t_quaternion256, allocator)

	// String types
	add_global_type_entity(builtin_scope, "string", t_string, allocator)
	add_global_type_entity(builtin_scope, "cstring", t_cstring, allocator)

	// UTF-16 string types
	// C++ Reference: types.cpp:529-530 (basic_types entries string16/cstring16)
	add_global_type_entity(builtin_scope, "string16", t_string16, allocator)
	add_global_type_entity(builtin_scope, "cstring16", t_cstring16, allocator)

	// Pointer and special types
	add_global_type_entity(builtin_scope, "rawptr", t_rawptr, allocator)
	add_global_type_entity(builtin_scope, "typeid", t_typeid, allocator)
	add_global_type_entity(builtin_scope, "any", t_any, allocator)

	// Explicitly-endian types
	// C++ Reference: types.cpp:537-562 (the "// Endian" block of basic_types)
	add_global_type_entity(builtin_scope, "i16le", t_i16le, allocator)
	add_global_type_entity(builtin_scope, "u16le", t_u16le, allocator)
	add_global_type_entity(builtin_scope, "i32le", t_i32le, allocator)
	add_global_type_entity(builtin_scope, "u32le", t_u32le, allocator)
	add_global_type_entity(builtin_scope, "i64le", t_i64le, allocator)
	add_global_type_entity(builtin_scope, "u64le", t_u64le, allocator)

	add_global_type_entity(builtin_scope, "i16be", t_i16be, allocator)
	add_global_type_entity(builtin_scope, "u16be", t_u16be, allocator)
	add_global_type_entity(builtin_scope, "i32be", t_i32be, allocator)
	add_global_type_entity(builtin_scope, "u32be", t_u32be, allocator)
	add_global_type_entity(builtin_scope, "i64be", t_i64be, allocator)
	add_global_type_entity(builtin_scope, "u64be", t_u64be, allocator)

	if !bedrock {
		add_global_type_entity(builtin_scope, "i128", t_i128, allocator)
		add_global_type_entity(builtin_scope, "u128", t_u128, allocator)
		add_global_type_entity(builtin_scope, "i128le", t_i128le, allocator)
		add_global_type_entity(builtin_scope, "u128le", t_u128le, allocator)
		add_global_type_entity(builtin_scope, "i128be", t_i128be, allocator)
		add_global_type_entity(builtin_scope, "u128be", t_u128be, allocator)
	}

	add_global_type_entity(builtin_scope, "f16le", t_f16le, allocator)
	add_global_type_entity(builtin_scope, "f32le", t_f32le, allocator)
	add_global_type_entity(builtin_scope, "f64le", t_f64le, allocator)

	add_global_type_entity(builtin_scope, "f16be", t_f16be, allocator)
	add_global_type_entity(builtin_scope, "f32be", t_f32be, allocator)
	add_global_type_entity(builtin_scope, "f64be", t_f64be, allocator)

	// ------------------------------------------------------------------------------
	// Constants
	// C++ Reference: checker.cpp:1145-1477
	// ------------------------------------------------------------------------------

	// DEVIATION: C++ registers `nil` with alloc_entity_nil (Entity_Nil). The port has
	// alloc_entity_nil, but nothing in check_ident handles the .Nil entity kind, so `nil`
	// stays a constant of type untyped nil - observationally the same thing.
	add_global_constant(builtin_scope, "nil", t_untyped_nil, nil, allocator)
	add_global_bool_constant(builtin_scope, "true", true, allocator)
	add_global_bool_constant(builtin_scope, "false", false, allocator)

	add_global_string_constant(builtin_scope, "ODIN_VENDOR", bc.ODIN_VENDOR, allocator)
	add_global_string_constant(builtin_scope, "ODIN_VERSION", bc.ODIN_VERSION, allocator)
	add_global_string_constant(builtin_scope, "ODIN_ROOT", bc.ODIN_ROOT, allocator)
	add_global_string_constant(builtin_scope, "ODIN_BUILD_PROJECT_NAME", bc.ODIN_BUILD_PROJECT_NAME, allocator)

	add_global_bool_constant(builtin_scope, "ODIN_BEDROCK", bedrock, allocator)

	// Odin_Windows_Subsystem_Type / ODIN_WINDOWS_SUBSYSTEM
	// C++ Reference: checker.cpp:1160-1180
	{
		values := []Global_Enum_Value {
			{"Unknown", 0},
			{"Boot_Application", 1},
			{"Console", 2},
			{"EFI_Application", 3},
			{"EFI_Boot_Service_Driver", 4},
			{"EFI_Rom", 5},
			{"EFI_Runtime_Driver", 6},
			{"Native", 7},
			{"Posix", 8},
			{"Windows", 9},
			{"Windows_CE", 10},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Windows_Subsystem_Type", values, nil, allocator)
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_WINDOWS_SUBSYSTEM",
			i64(bc.ODIN_WINDOWS_SUBSYSTEM),
			allocator,
		)
		add_global_string_constant(
			builtin_scope,
			"ODIN_WINDOWS_SUBSYSTEM_STRING",
			windows_subsystem_names[bc.ODIN_WINDOWS_SUBSYSTEM],
			allocator,
		)
	}

	// Odin_OS_Type / ODIN_OS
	// C++ Reference: checker.cpp:1182-1199
	{
		values := []Global_Enum_Value {
			{"Unknown", 0},
			{"Windows", 1},
			{"Darwin", 2},
			{"Linux", 3},
			{"FreeBSD", 4},
			{"OpenBSD", 5},
			{"NetBSD", 6},
			{"WASI", 7},
			{"JS", 8},
			{"Orca", 9},
			{"Freestanding", 10},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_OS_Type", values, nil, allocator)
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_OS",
			odin_os_enum_value(bc.metrics.os),
			allocator,
		)
		add_global_string_constant(builtin_scope, "ODIN_OS_STRING", bc.ODIN_OS, allocator)
	}

	// Odin_Arch_Type / ODIN_ARCH
	// C++ Reference: checker.cpp:1201-1214
	{
		values := []Global_Enum_Value {
			{"Unknown", 0},
			{"amd64", 1},
			{"i386", 2},
			{"arm32", 3},
			{"arm64", 4},
			{"wasm32", 5},
			{"wasm64p32", 6},
			{"riscv64", 7},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Arch_Type", values, nil, allocator)
		add_global_enum_constant(builtin_scope, fields, values, "ODIN_ARCH", i64(bc.metrics.arch), allocator)
		add_global_string_constant(builtin_scope, "ODIN_ARCH_STRING", bc.ODIN_ARCH, allocator)
	}

	add_global_string_constant(builtin_scope, "ODIN_MICROARCH_STRING", get_final_microarchitecture(), allocator)

	// Odin_Build_Mode_Type / ODIN_BUILD_MODE
	// C++ Reference: checker.cpp:1218-1230
	{
		values := []Global_Enum_Value {
			{"Executable", 0},
			{"Dynamic", 1},
			{"Static", 2},
			{"Object", 3},
			{"Assembly", 4},
			{"LLVM_IR", 5},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Build_Mode_Type", values, nil, allocator)
		add_global_enum_constant(builtin_scope, fields, values, "ODIN_BUILD_MODE", i64(bc.build_mode), allocator)
	}

	// Odin_Endian_Type / ODIN_ENDIAN
	// C++ Reference: checker.cpp:1232-1241
	//
	// This is the pair that `#assert(ODIN_ENDIAN == .Little)` needs: the constant must carry
	// a real enum type, or the implicit selector on the right has nothing to infer from.
	{
		values := []Global_Enum_Value{{"Little", 0}, {"Big", 1}}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Endian_Type", values, nil, allocator)
		endian := target_endians[bc.metrics.arch]
		add_global_enum_constant(builtin_scope, fields, values, "ODIN_ENDIAN", i64(endian), allocator)
		add_global_string_constant(builtin_scope, "ODIN_ENDIAN_STRING", target_endian_names[endian], allocator)
	}

	// Odin_Platform_Subtarget_Type / ODIN_PLATFORM_SUBTARGET
	// C++ Reference: checker.cpp:1243-1255
	{
		values := []Global_Enum_Value {
			{"Default", 0},
			{"iPhone", 1},
			{"iPhoneSimulator", 2},
			{"Android", 3},
			{"Playdate", 4},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Platform_Subtarget_Type", values, nil, allocator)
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_PLATFORM_SUBTARGET",
			odin_subtarget_enum_value(bc.subtarget),
			allocator,
		)
	}

	// Odin_Error_Pos_Style_Type / ODIN_ERROR_POS_STYLE
	// C++ Reference: checker.cpp:1257-1265
	{
		values := []Global_Enum_Value{{"Default", 0}, {"Unix", 1}}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Error_Pos_Style_Type", values, nil, allocator)
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_ERROR_POS_STYLE",
			i64(bc.ODIN_ERROR_POS_STYLE),
			allocator,
		)
	}

	// Odin_Calling_Convention / ODIN_DEFAULT_CALLING_CONVENTION
	// C++ Reference: checker.cpp:1310-1336
	{
		values := []Global_Enum_Value {
			{"Invalid", 0},
			{"Odin", 1},
			{"Contextless", 2},
			{"CDecl", 3},
			{"Std_Call", 4},
			{"Fast_Call", 5},
			{"None", 6},
			{"Naked", 7},
			{"_", 8}, // ProcCC_InlineAsm, deliberately unnameable in C++ too
			{"Win64", 9},
			{"SysV", 10},
			{"PreserveNone", 11},
			{"PreserveMost", 12},
			{"PreserveAll", 13},
		}
		fields, named_type := add_global_enum_type(builtin_scope, "Odin_Calling_Convention", values, t_u8, allocator)
		t_odin_calling_convention = named_type
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_DEFAULT_CALLING_CONVENTION",
			odin_calling_convention_enum_value(default_calling_convention()),
			allocator,
		)
	}

	// ODIN_MINIMUM_OS_VERSION
	// C++ Reference: checker.cpp:1338-1352
	add_global_constant(
		builtin_scope,
		"ODIN_MINIMUM_OS_VERSION",
		t_untyped_integer,
		exact_value_i64(parse_minimum_os_version(bc.minimum_os_version_string)),
		allocator,
	)

	// C++ Reference: checker.cpp:1354-1368
	add_global_bool_constant(builtin_scope, "ODIN_DEBUG", bc.ODIN_DEBUG, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_DISABLE_ASSERT", bc.ODIN_DISABLE_ASSERT, allocator)
	add_global_bool_constant(
		builtin_scope,
		"ODIN_DEFAULT_TO_NIL_ALLOCATOR",
		bc.ODIN_DEFAULT_TO_NIL_ALLOCATOR,
		allocator,
	)
	add_global_bool_constant(builtin_scope, "ODIN_NO_BOUNDS_CHECK", bc.no_bounds_check, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_NO_TYPE_ASSERT", bc.no_type_assert, allocator)
	add_global_bool_constant(
		builtin_scope,
		"ODIN_DEFAULT_TO_PANIC_ALLOCATOR",
		bc.ODIN_DEFAULT_TO_PANIC_ALLOCATOR,
		allocator,
	)
	add_global_bool_constant(builtin_scope, "ODIN_NO_CRT", bc.no_crt, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_USE_SEPARATE_MODULES", bc.use_separate_modules, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_TEST", .Test in bc.command_kind, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_NO_ENTRY_POINT", bc.no_entry_point, allocator)
	add_global_bool_constant(
		builtin_scope,
		"ODIN_FOREIGN_ERROR_PROCEDURES",
		bc.ODIN_FOREIGN_ERROR_PROCEDURES,
		allocator,
	)
	add_global_bool_constant(builtin_scope, "ODIN_NO_RTTI", bc.no_rtti, allocator)
	add_global_bool_constant(builtin_scope, "ODIN_VALGRIND_SUPPORT", bc.ODIN_VALGRIND_SUPPORT, allocator)

	// ODIN_COMPILE_TIMESTAMP
	// C++ Reference: checker.cpp:1370 (odin_compile_timestamp, checker.cpp:1104-1109):
	// nanoseconds since the Unix epoch, captured while the universe is being built.
	add_global_constant(
		builtin_scope,
		"ODIN_COMPILE_TIMESTAMP",
		t_untyped_integer,
		exact_value_i64(time.to_unix_nanoseconds(time.now())),
		allocator,
	)

	// ODIN_VERSION_HASH
	// C++ Reference: checker.cpp:1372-1382 - the GIT_SHA the compiler was built with, empty
	// when it was not defined. The checker is not built with one, so it is always empty.
	add_global_string_constant(builtin_scope, "ODIN_VERSION_HASH", "", allocator)

	// __ODIN_LLVM_F16_SUPPORTED
	// C++ Reference: checker.cpp:1384-1397
	{
		f16_supported := true
		if is_arch_wasm() {
			f16_supported = false
		} else if bc.metrics.os == .Darwin && bc.metrics.arch == .Amd64 {
			// NOTE(laytan) in C++: see #3222.
			f16_supported = false
		}
		add_global_bool_constant(builtin_scope, "__ODIN_LLVM_F16_SUPPORTED", f16_supported, allocator)
	}

	// Odin_Sanitizer_Flag / Odin_Sanitizer_Flags / ODIN_SANITIZER_FLAGS
	// C++ Reference: checker.cpp:1399-1424
	{
		values := []Global_Enum_Value{{"Address", 0}, {"Memory", 1}, {"Thread", 2}}
		_, enum_type := add_global_enum_type(builtin_scope, "Odin_Sanitizer_Flag", values, nil, allocator)

		bit_set_type := alloc_type_bit_set()
		bst := &bit_set_type.variant.(Type_Bit_Set)
		bst.elem = enum_type
		bst.underlying = t_u32
		bst.lower = 0
		bst.upper = 2

		TYPE_NAME :: "Odin_Sanitizer_Flags"
		scope := create_scope(builtin_scope, allocator)
		entity := alloc_entity_type_name(scope, make_token_ident(TYPE_NAME), nil, .Resolved, allocator)
		named_type := alloc_type_named(TYPE_NAME, bit_set_type, entity)
		set_base_type(named_type, bit_set_type)
		set_type_name_entity_type(entity, named_type)

		add_global_constant(
			builtin_scope,
			"ODIN_SANITIZER_FLAGS",
			named_type,
			exact_value_u64(u64(transmute(u32)bc.sanitizer_flags)),
			allocator,
		)
	}

	// Odin_Optimization_Mode / ODIN_OPTIMIZATION_MODE
	// C++ Reference: checker.cpp:1426-1437
	{
		values := []Global_Enum_Value {
			{"None", -1},
			{"Minimal", 0},
			{"Size", 1},
			{"Speed", 2},
			{"Aggressive", 3},
		}
		fields, _ := add_global_enum_type(builtin_scope, "Odin_Optimization_Mode", values, nil, allocator)
		add_global_enum_constant(
			builtin_scope,
			fields,
			values,
			"ODIN_OPTIMIZATION_MODE",
			i64(bc.optimization_level),
			allocator,
		)
	}

	// Add builtin procedures (len, cap, size_of, etc.)
	// C++ Reference: checker.cpp:1480-1508
	intrinsics_scope := info.intrinsics_package != nil ? info.intrinsics_package.scope : nil

	// intrinsics.Atomic_Memory_Order
	// C++ Reference: checker.cpp:1296-1308
	//
	// This is what gives `intrinsics.atomic_load_explicit(p, .Acquire)` a type to resolve
	// its implicit selector against; t_atomic_memory_order had no producer before this.
	if intrinsics_scope != nil {
		values := []Global_Enum_Value {
			{"Relaxed", 0},
			{"Consume", 1},
			{"Acquire", 2},
			{"Release", 3},
			{"Acq_Rel", 4},
			{"Seq_Cst", 5},
		}
		_, named_type := add_global_enum_type(builtin_scope, "Atomic_Memory_Order", values, nil, allocator)
		t_atomic_memory_order = named_type
		scope_insert(intrinsics_scope, named_type.variant.(Type_Named).type_name)
	}

	// intrinsics.Fast_Math_Flag / intrinsics.Fast_Math_Flags
	// C++ Reference: checker.cpp:1267-1294
	if intrinsics_scope != nil {
		values := []Global_Enum_Value {
			{"Allow_Reassoc", 0},
			{"No_NaNs", 1},
			{"No_Infs", 2},
			{"No_Signed_Zeros", 3},
			{"Allow_Reciprocal", 4},
			{"Allow_Contract", 5},
			{"Approx_Func", 6},
		}
		_, flag_type := add_global_enum_type(builtin_scope, "Fast_Math_Flag", values, t_u8, allocator)
		scope_insert(intrinsics_scope, flag_type.variant.(Type_Named).type_name)

		bit_set_type := alloc_type_bit_set()
		bst := &bit_set_type.variant.(Type_Bit_Set)
		bst.elem = flag_type
		bst.underlying = t_u32
		bst.lower = 0
		bst.upper = i64(len(values) - 1)

		TYPE_NAME :: "Fast_Math_Flags"
		scope := create_scope(builtin_scope, allocator)
		entity := alloc_entity_type_name(scope, make_token_ident(TYPE_NAME), nil, .Resolved, allocator)
		named_type := alloc_type_named(TYPE_NAME, bit_set_type, entity)
		set_base_type(named_type, bit_set_type)
		set_type_name_entity_type(entity, named_type)
		t_fast_math_flags = named_type

		scope_insert(intrinsics_scope, entity)
	}

	// intrinsics.c_va_list and the objc opaque types — synthesised, not sourced.
	// See init_c_va_list_type for why.
	init_c_va_list_type(intrinsics_scope, allocator)
	init_objc_intrinsics_types(intrinsics_scope, allocator)

	for id in Builtin_Proc_Id {
		proc_info := builtin_proc_infos[id]
		if len(proc_info.name) == 0 {
			continue
		}

		entity := alloc_entity_builtin(proc_info.name, id, proc_info.pkg, allocator)
		entity.state = .Resolved

		// Add to appropriate scope based on package
		target_scope := builtin_scope
		if proc_info.pkg == .Intrinsics && intrinsics_scope != nil {
			target_scope = intrinsics_scope
		}
		scope_insert(target_scope, entity)
	}

	// `expand_to_tuple` is the deprecated spelling of `expand_values`, registered as a second
	// builtin entity with the same id.
	// C++ Reference: checker.cpp:1510-1516
	{
		entity := alloc_entity_builtin("expand_to_tuple", .Expand_Values, .Builtin, allocator)
		entity.state = .Resolved
		scope_insert(builtin_scope, entity)
	}
}

// ======================================================================================
// VALIDATION AND DIAGNOSTICS
// ======================================================================================

// Validation_Issue represents a detected inconsistency in checker state
Validation_Issue :: struct {
	category:    string,
	description: string,
	severity:    enum {
		Warning,
		Error,
	},
}

// validate_checker_state performs consistency checks on checker state
// Returns true if state is valid, false if inconsistencies found
validate_checker_state :: proc(c: ^Checker) -> bool {
	when ODIN_DEBUG {
		issues := validate_checker_consistency(c)
		defer delete(issues)

		if len(issues) > 0 {
			print_validation_issues(issues[:])
			// Return false only for errors, not warnings
			for issue in issues {
				if issue.severity == .Error {
					return false
				}
			}
		}
	}

	return true
}

// validate_checker_consistency performs various consistency checks
// C++ Reference: Various assertions throughout checker.cpp
validate_checker_consistency :: proc(c: ^Checker, allocator := context.allocator) -> [dynamic]Validation_Issue {
	issues := make([dynamic]Validation_Issue, allocator)

	// Check that info.checker back-reference is correct
	if c.info.checker != c {
		append(&issues, Validation_Issue {
			category = "Checker",
			description = "info.checker back-reference is incorrect",
			severity = .Error,
		})
	}

	// Check builtin packages exist if checking has started
	if c.info.builtin_package == nil && len(c.info.packages) > 0 {
		append(&issues, Validation_Issue {
			category = "Packages",
			description = "builtin_package is nil but packages exist",
			severity = .Warning,
		})
	}

	// Check that all entities in entities array are not nil
	for entity, i in c.info.entities {
		if entity == nil {
			append(&issues, Validation_Issue {
				category = "Entities",
				description = fmt.tprintf("Entity at index %d is nil", i),
				severity = .Error,
			})
		}
	}

	// Check that all definitions are resolved
	for def, i in c.info.definitions {
		if def == nil {
			append(&issues, Validation_Issue {
				category = "Definitions",
				description = fmt.tprintf("Definition at index %d is nil", i),
				severity = .Error,
			})
		} else if def.state == .Unresolved {
			append(&issues, Validation_Issue {
				category = "Definitions",
				description = fmt.tprintf("Definition '%s' at index %d is unresolved", def.token.text, i),
				severity = .Warning,
			})
		}
	}

	return issues
}

// print_validation_issues outputs validation issues to stderr
print_validation_issues :: proc(issues: []Validation_Issue) {
	fmt.eprintln("=== Checker Validation Issues ===")
	for issue in issues {
		severity_str := "WARNING" if issue.severity == .Warning else "ERROR"
		fmt.eprintf("[%s] %s: %s\n", severity_str, issue.category, issue.description)
	}
	fmt.eprintln("=================================")
}

// ======================================================================================
// NOTES ON EXISTING HELPER FUNCTIONS
// ======================================================================================

// The following functions are already implemented elsewhere in the codebase:
// - reset_checker_context: check_import_export.odin:663
// - make_checker_context: check_collect.odin:1058
// - destroy_checker_context: check_proc.odin:787
//
// This module focuses solely on init/destroy for Checker_Info and Checker.
