package checker

import "base:runtime"
import "core:container/queue"
import "core:fmt"
import "core:math/big"
import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:sync"
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
	queue.mpsc_destroy(&info.objc_class_implementations)
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
			cpu_count := os.processor_core_count()
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

	// Initialize ODIN_ROOT from environment if not set
	// This is needed for the runtime extractor to find base/runtime
	init_odin_root_from_env()

	// Extract runtime types from base/runtime source
	// This allows code that imports base:runtime to access runtime types
	info.runtime_package = extract_runtime_types(info, allocator)
	if info.runtime_package != nil {
		// Register under both "runtime" and "base:runtime" import paths
		info.packages["runtime"] = info.runtime_package
		info.packages["base:runtime"] = info.runtime_package
	}
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

// populate_builtin_package_scope adds builtin type entities to the builtin package scope.
// This allows code like `x: int` to resolve `int` through scope lookup.
// C++ Reference: checker.cpp:1071-1091 (create_type_entity, init_universe)
populate_builtin_package_scope :: proc(info: ^Checker_Info, allocator := context.allocator) {
	if info.builtin_package == nil {
		return
	}

	builtin_scope := info.builtin_package.scope
	if builtin_scope == nil {
		return
	}

	// Helper to create and register a builtin type entity
	add_builtin_type :: proc(scope: ^Scope, name: string, type: ^Type, alloc: mem.Allocator) {
		if type == nil {
			return
		}
		token := make_token_ident(name)
		entity := alloc_entity_type_name(scope, token, type, .Resolved, alloc)
		scope_insert(scope, entity)
	}

	// Boolean types
	add_builtin_type(builtin_scope, "bool", t_bool, allocator)
	add_builtin_type(builtin_scope, "b8", t_b8, allocator)
	add_builtin_type(builtin_scope, "b16", t_b16, allocator)
	add_builtin_type(builtin_scope, "b32", t_b32, allocator)
	add_builtin_type(builtin_scope, "b64", t_b64, allocator)

	// Integer types
	add_builtin_type(builtin_scope, "i8", t_i8, allocator)
	add_builtin_type(builtin_scope, "i16", t_i16, allocator)
	add_builtin_type(builtin_scope, "i32", t_i32, allocator)
	add_builtin_type(builtin_scope, "i64", t_i64, allocator)
	add_builtin_type(builtin_scope, "i128", t_i128, allocator)
	add_builtin_type(builtin_scope, "int", t_int, allocator)

	add_builtin_type(builtin_scope, "u8", t_u8, allocator)
	add_builtin_type(builtin_scope, "u16", t_u16, allocator)
	add_builtin_type(builtin_scope, "u32", t_u32, allocator)
	add_builtin_type(builtin_scope, "u64", t_u64, allocator)
	add_builtin_type(builtin_scope, "u128", t_u128, allocator)
	add_builtin_type(builtin_scope, "uint", t_uint, allocator)
	add_builtin_type(builtin_scope, "uintptr", t_uintptr, allocator)

	// Floating point types
	add_builtin_type(builtin_scope, "f16", t_f16, allocator)
	add_builtin_type(builtin_scope, "f32", t_f32, allocator)
	add_builtin_type(builtin_scope, "f64", t_f64, allocator)

	// Character types
	add_builtin_type(builtin_scope, "rune", t_rune, allocator)
	add_builtin_type(builtin_scope, "byte", t_u8, allocator) // byte is alias for u8

	// Complex types
	add_builtin_type(builtin_scope, "complex32", t_complex32, allocator)
	add_builtin_type(builtin_scope, "complex64", t_complex64, allocator)
	add_builtin_type(builtin_scope, "complex128", t_complex128, allocator)

	// Quaternion types
	add_builtin_type(builtin_scope, "quaternion64", t_quaternion64, allocator)
	add_builtin_type(builtin_scope, "quaternion128", t_quaternion128, allocator)
	add_builtin_type(builtin_scope, "quaternion256", t_quaternion256, allocator)

	// String types
	add_builtin_type(builtin_scope, "string", t_string, allocator)
	add_builtin_type(builtin_scope, "cstring", t_cstring, allocator)

	// Pointer and special types
	add_builtin_type(builtin_scope, "rawptr", t_rawptr, allocator)
	add_builtin_type(builtin_scope, "typeid", t_typeid, allocator)
	add_builtin_type(builtin_scope, "any", t_any, allocator)

	// Boolean constants
	// C++ Reference: init_preload(), builtin_procs.cpp
	add_builtin_const :: proc(scope: ^Scope, name: string, type: ^Type, value: Exact_Value, alloc: mem.Allocator) {
		if type == nil {
			return
		}
		token := make_token_ident(name)
		entity := alloc_entity_constant(scope, token, type, value)
		entity.state = .Resolved
		scope_insert(scope, entity)
	}

	add_builtin_const(builtin_scope, "true", t_untyped_bool, exact_value_bool(true), allocator)
	add_builtin_const(builtin_scope, "false", t_untyped_bool, exact_value_bool(false), allocator)
	add_builtin_const(builtin_scope, "nil", t_untyped_nil, nil, allocator)

	// Add builtin procedures (len, cap, size_of, etc.)
	// C++ Reference: checker.cpp:1354-1376
	intrinsics_scope := info.intrinsics_package != nil ? info.intrinsics_package.scope : nil

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
