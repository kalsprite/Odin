package checker

/*
check_files.odin - Main Orchestration for Semantic Checking

This module implements the main entry point for the Odin semantic checker.
It orchestrates the multi-phase checking workflow that mirrors the C++
compiler's check_parsed_files function (checker.cpp:7282-7542).

C++ Reference: checker.cpp:7282 - void check_parsed_files(Checker *c)

Usage:
    c := &Checker{}
    init_checker(c)
    defer destroy_checker(c)

    init_error_collector(20)  // Max 20 errors
    defer destroy_error_collector()

    success := check_files(c, parsed_files)
*/

import "core:container/queue"
import "core:odin/ast"
import "core:odin/tokenizer"

// =============================================================================
// MAIN ENTRY POINT
// =============================================================================

// check_files is the main entry point for semantic checking.
// It takes parsed AST files and performs full semantic analysis.
//
// C++ Reference: checker.cpp:7282-7542 (check_parsed_files)
//
// Returns true if checking completed without errors, false otherwise.
//
// ERROR LIMIT: if the error cap is hit mid-run, error_va latches
// global_error_collector.limit_reached instead of terminating the process (see
// CPP_DEVIATIONS.md [EMBED-1]). This procedure then unwinds at the next phase boundary and
// returns false. The distinction between "finished and found errors" and "gave up early,
// results are a truncated prefix" is NOT carried in this bool - callers must consult
// error_limit_reached(), exactly as they already consult error_count() for the error total.
// check_package_from_path surfaces both on Package_Check_Result.
check_files :: proc(c: ^Checker, files: []^ast.File) -> bool {
	if len(files) == 0 {
		return true
	}

	// The MPSC queues are producer-side handoff points: an entity is owned by a Checker_Info
	// array only once it has been merged across, and destroy_checker_info requires every queue
	// to be empty. The unwind points below return at phase boundaries when the error cap is
	// hit, skipping the later phases - including the check_merge_queues_into_arrays calls that
	// would have taken ownership of what Phase 4 produced. Merging on the way out makes
	// "queues are drained by the time check_files returns" hold on every exit path rather than
	// only the one that runs to the bottom, so a future unwind point cannot silently strand
	// entities. On the normal path the queues are already empty here and this is a no-op.
	defer {
		check_merge_queues_into_arrays(c)

		// The queues that no array owns belong to phases an unwind skipped outright, so
		// there is nothing to merge them into - see discard_abandoned_queue_work. This is
		// deliberately conditional: on a run that completes, those phases are responsible
		// for their own queues, and mpsc_destroy's assertion is what proves they ran.
		if error_limit_reached() {
			discard_abandoned_queue_work(c)
		}
	}

	// =========================================================================
	// Phase 1: Package Discovery and Registration
	// C++ Reference: checker.cpp:7289-7309
	// =========================================================================

	// Discover unique packages from files
	// C++ gets packages from parser; we extract from file.pkg
	register_packages_from_files(c, files)

	// Create package scopes for all registered packages
	// This must happen before file scope creation
	create_package_scopes(c)

	// =========================================================================
	// Phase 2: File Scope Creation
	// C++ Reference: checker.cpp:5714-5731 (check_create_file_scopes)
	// =========================================================================

	check_create_file_scopes(c)

	// =========================================================================
	// Phase 3: Entity Collection
	// C++ Reference: checker.cpp:7312-7324
	// =========================================================================

	// Collect all entities from all files
	// C++ line 7313: check_collect_entities_all(c)
	check_collect_entities_all(c)

	// Process exports and imports
	// C++ line 7315-7320: export -> import -> export cycle
	check_export_entities(c)
	check_import_entities(c)
	check_export_entities(c) // Second pass for cross-package visibility

	// Drain queues into arrays
	// C++ line 7323: check_merge_queues_into_arrays(c)
	check_merge_queues_into_arrays(c)

	// Unwind point: collection produced more diagnostics than the cap allows. Everything
	// after this would append to a list that is already being discarded.
	if error_limit_reached() {
		return false
	}

	// =========================================================================
	// Phase 4: Global Entity Type Checking
	// C++ Reference: checker.cpp:7327-7337
	// =========================================================================

	// Create base context for global checking
	// C++ line 7328-7329: Context ctx = make_context(c.info)
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	// Type check all global entities in dependency order
	// C++ line 7331: check_all_global_entities(c)
	check_all_global_entities(&ctx)

	// Initialize preloaded types (runtime dependencies)
	// C++ line 7333: init_preload(c)
	init_preload(c)

	// Unwind point: skip procedure body checking, which is by far the most expensive phase
	// and the one most likely to keep generating dropped diagnostics.
	if error_limit_reached() {
		return false
	}

	// =========================================================================
	// Phase 5: Procedure Body Checking
	// C++ Reference: checker.cpp:7340-7346
	// =========================================================================

	// Initialize worker data for procedure checking
	// C++ Reference: checker.cpp:6438-6447
	check_init_worker_data(c)

	// Save builtin context and set up for procedure checking
	prev_ctx := c.builtin_ctx
	defer {
		c.builtin_ctx = prev_ctx
	}

	// Create decl info for procedure body checking
	// C++ line 7341: c->builtin_ctx.decl = make_decl_info(nullptr, nullptr)
	c.builtin_ctx.decl = make_decl_info(nil, nil, c.allocator)

	// Check all procedure bodies
	// C++ line 7343: check_procedure_bodies(c)
	check_procedure_bodies(c)

	// Resolve `foreign import` library paths and finish WASM foreign declarations.
	// C++ Reference: checker.cpp:7710-7711 - "check foreign import fullpaths", between
	// check_procedure_bodies and the merge below. This is the sole consumer of
	// foreign_imports_to_check_fullpaths and foreign_decls_to_check; both are producer-side
	// queues filled during collection, so if this never runs their contents are stranded and
	// Entity_Library_Name.paths is never populated.
	check_foreign_import_fullpaths(&ctx)

	// Drain queues again after procedure checking
	// C++ line 7345: check_merge_queues_into_arrays(c)
	check_merge_queues_into_arrays(c)

	// Unwind point: the post-processing and validation phases below assume the procedure
	// bodies were all checked. After a truncated Phase 5 their findings would be noise.
	if error_limit_reached() {
		return false
	}

	// =========================================================================
	// Phase 6: Post-Processing and Validation
	// C++ Reference: checker.cpp:7348-7400
	// =========================================================================

	// Check deferred procedures (procedures with defer statements)
	// C++ line 7373: check_deferred_procedures(c)
	check_deferred_procedures(c)

	// Sort init/fini procedures by priority
	// C++ line 7377: check_sort_init_and_fini_procedures(c)
	check_sort_init_and_fini_procedures(c)

	// Report intrinsics.__entry_point calls made in a program that has no entry point.
	// C++ Reference: checker.cpp:7900-7909
	check_intrinsics_entry_point_usage(c)

	// Check test procedures
	// C++ line 7400: check_test_procedures(c)
	check_test_procedures(c)

	// Final queue drain
	check_merge_queues_into_arrays(c)

	// =========================================================================
	// Phase 7: Validation (Cycle Detection, Entry Point)
	// C++ Reference: checker.cpp:7364-7427
	// =========================================================================

	// Check for illegal cyclic type declarations
	// C++ Reference: checker.cpp:7400
	check_for_type_cycles(c)

	// Check for recursive inline procedures
	// C++ Reference: checker.cpp:7403
	check_for_inline_cycles(c)

	// Validate unique package names
	check_unique_package_names(c)

	// Check entry point
	// C++ Reference: checker.cpp:7441-7463
	check_entry_point(c)

	// =========================================================================
	// Return Result
	// =========================================================================

	return error_count() == 0
}

// =============================================================================
// HELPER FUNCTIONS
// =============================================================================

// register_packages_from_files discovers and registers all unique packages
// from the given files into c.info.packages.
//
// C++ Reference: checker.cpp:7289-7303 (package iteration from parser)
// The C++ version gets packages directly from parser->packages.
// We extract them from file->pkg since we receive files directly.
register_packages_from_files :: proc(c: ^Checker, files: []^ast.File) {
	for file in files {
		if file == nil {
			continue
		}

		pkg := file.pkg
		if pkg == nil {
			continue
		}

		// Check if already registered by path
		if pkg.fullpath in c.info.packages {
			continue
		}

		// Register the package
		c.info.packages[pkg.fullpath] = pkg

		// Check for special packages
		// C++ line 7294-7303: Special package detection
		if pkg.kind == .Init {
			c.info.init_package = pkg
			c.info.init_fullpath = pkg.fullpath
		}
		if pkg.kind == .Runtime {
			c.info.runtime_package = pkg
		}
	}
}

// create_package_scopes creates scopes for all registered packages.
// This must be called after register_packages_from_files and before check_create_file_scopes.
//
// C++ Reference: checker.cpp:254-278 (create_scope_from_package)
// In C++, this happens as part of package creation. Here we do it as a separate step.
create_package_scopes :: proc(c: ^Checker) {
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)
	for _, pkg in c.info.packages {
		// Skip if already has a scope
		if get_package_scope(&c.info, pkg) != nil {
			continue
		}
		pkg_scope := create_scope_from_package(&ctx, pkg, c.allocator)
		set_package_scope(&c.info, pkg, pkg_scope)
	}
}

// check_merge_queues_into_arrays drains MPSC queues into final arrays.
// This is called after each major phase to consolidate collected entities.
//
// C++ Reference: checker.cpp:7104-7127 (check_merge_queues_into_arrays)
check_merge_queues_into_arrays :: proc(c: ^Checker) {
	// Drain definition queue
	for {
		if entity, ok := queue.mpsc_dequeue(&c.info.definition_queue); ok {
			append(&c.info.definitions, entity)
		} else {
			break
		}
	}

	// Drain entity queue
	for {
		if entity, ok := queue.mpsc_dequeue(&c.info.entity_queue); ok {
			append(&c.info.entities, entity)
		} else {
			break
		}
	}

	// Drain all_procedures queue
	for {
		if proc_info, ok := queue.mpsc_dequeue(&c.info.all_procedures_queue); ok {
			append(&c.info.all_procedures, proc_info)
		} else {
			break
		}
	}

	// Drain required_foreign_imports_through_force queue
	for {
		if entity, ok := queue.mpsc_dequeue(&c.info.required_foreign_imports_through_force_queue); ok {
			append(&c.info.required_foreign_imports_through_force, entity)
		} else {
			break
		}
	}

	// Drain raddbg_type_views queue
	for {
		if view, ok := queue.mpsc_dequeue(&c.info.raddbg_type_views_queue); ok {
			append(&c.info.raddbg_type_views, view)
		} else {
			break
		}
	}
}

// =============================================================================
// CONVENIENCE WRAPPERS
// =============================================================================

// check_package is a convenience function to check a single package.
// It collects all files from the package and calls check_files.
check_package :: proc(c: ^Checker, pkg: ^ast.Package) -> bool {
	if pkg == nil {
		return true
	}

	// Collect files from package
	files := make([dynamic]^ast.File, 0, len(pkg.files), context.temp_allocator)
	for _, file in pkg.files {
		append(&files, file)
	}

	return check_files(c, files[:])
}

// check_packages is a convenience function to check multiple packages.
check_packages :: proc(c: ^Checker, packages: []^ast.Package) -> bool {
	// Collect all files from all packages
	file_count := 0
	for pkg in packages {
		if pkg != nil {
			file_count += len(pkg.files)
		}
	}

	files := make([dynamic]^ast.File, 0, file_count, context.temp_allocator)
	for pkg in packages {
		if pkg == nil {
			continue
		}
		for _, file in pkg.files {
			append(&files, file)
		}
	}

	return check_files(c, files[:])
}

// =============================================================================
// VALIDATION FUNCTIONS
// =============================================================================

// check_for_type_cycles detects illegal cyclic type declarations.
// It iterates through all type name definitions and triggers type_align_of
// to force any cycle detection that's built into the type system.
//
// C++ Reference: checker.cpp:7281-7296 (check_for_type_cycles)
check_for_type_cycles :: proc(c: ^Checker) {
	// NOTE(bill): Check for illegal cyclic type declarations
	for entity in c.info.definitions {
		if entity.kind != .Type_Name {
			continue
		}
		if entity.type != nil && is_type_typed(entity.type) {
			type_name, is_type_name := entity.variant.(Entity_Type_Name)
			if is_type_name && type_name.is_type_alias {
				// Ignore type aliases for the time being
				continue
			}
			// Trigger type_align_of to force cycle detection
			type_align_of(entity.type)
		}
	}
}

// check_for_inline_cycles detects recursive procedures marked as inline.
// Recursive procedures cannot be inlined since that would cause infinite expansion.
//
// C++ Reference: checker.cpp:7298-7315 (check_for_inline_cycles)
check_for_inline_cycles :: proc(c: ^Checker) {
	for entity in c.info.definitions {
		if entity.kind != .Procedure {
			continue
		}
		decl := entity.decl_info
		if decl == nil {
			continue
		}
		proc_lit := decl.proc_lit
		if proc_lit == nil {
			continue
		}
		// Check if procedure is marked inline
		if proc_lit.inlining == .Inline {
			// Check if this procedure depends on itself (recursive)
			if entity in decl.deps {
				error(entity.token, "Cannot inline recursive procedure '%s'", entity.token.text)
			}
		}
	}
}

// check_entry_point validates that an entry point procedure exists for executables.
// For executable builds (not libraries or tests), there must be a 'main' procedure
// in the init package.
//
// C++ Reference: checker.cpp:7441-7463
check_entry_point :: proc(c: ^Checker) {
	// Only check entry point for executable builds
	// C++ Reference: checker.cpp:7442
	if build_context.build_mode != .Executable {
		return
	}
	if build_context.no_entry_point {
		return
	}
	if .Test in build_context.command_kind {
		return
	}

	// Get the init scope
	// C++ Reference: checker.cpp:7443-7445
	init_scope := c.info.init_scope
	if init_scope == nil {
		return
	}

	// Look up 'main' in the init scope
	// C++ Reference: checker.cpp:7446
	main_entity := scope_lookup_current(init_scope, "main")
	if main_entity == nil {
		// Get a token for the error message
		// C++ Reference: checker.cpp:7448-7457
		token: tokenizer.Token
		token.pos.line = 1
		token.pos.column = 1

		// Try to get a better position from the init package's first file
		if c.info.init_package != nil {
			for _, file in c.info.init_package.files {
				if file != nil {
					// Use the package token as a reasonable error location
					token = file.pkg_token
					break
				}
			}
		}

		error(token, "Undefined entry point procedure 'main'")
	} else {
		// Store the entry point for later use
		c.info.entry_point = main_entity
	}
}

// check_unique_package_names validates that no two packages share the same name.
// If multiple packages have the same name but different paths, this is an error
// because it would cause ambiguous imports.
//
// C++ Reference: checker.cpp (package name uniqueness validation)
check_unique_package_names :: proc(c: ^Checker) {
	// Build a map of package name -> first package path seen
	// When we find a duplicate, report an error
	seen: map[string]^ast.Package
	defer delete(seen)

	for _, pkg in c.info.packages {
		if pkg == nil || pkg.name == "" {
			continue
		}

		if existing := seen[pkg.name]; existing != nil {
			// Found duplicate package name with different path
			if existing.fullpath != pkg.fullpath {
				// Get a token for the error from the package
				token: tokenizer.Token
				for _, file in pkg.files {
					if file != nil {
						token = file.pkg_token
						break
					}
				}
				error(
					token,
					"Duplicate package name '%s' found in '%s' and '%s'",
					pkg.name,
					existing.fullpath,
					pkg.fullpath,
				)
			}
		} else {
			seen[pkg.name] = pkg
		}
	}
}