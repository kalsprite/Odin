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
import "core:odin/parser"
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

	// Drain the foreign-block queue BEFORE the second export pass.
	//
	// collect_file_decls (inside check_import_entities) is the only path that descends into a
	// file-scope `when`, so blocks nested there are queued during that call - after the
	// collection-time drain has already emptied the queue. They must then be processed while
	// there is still an export pass left to run, or their entities stay in the file scope and
	// never reach the package scope: `core/c/libc` itself checked clean but every importer
	// still reported `'stderr' is not declared by 'libc'`.
	//
	// C++ has the same coupling and expresses it differently - its drain lives INSIDE
	// check_import_entities (checker.cpp:6268-6288) and, when a foreign block adds something,
	// rewinds `pkg_index` to re-check and re-export the package (6277-6280). Draining here,
	// between the import pass and the export that follows it, reaches the same state.
	check_delayed_foreign_blocks_all(c)

	check_export_entities(c) // Second pass for cross-package visibility

	// File-scope directive expressions (`#assert`, `#config`) are evaluated HERE, not
	// during collection: C++ drains this queue inside check_import_entities
	// (checker.cpp:6295), after each package's entities have been exported into its
	// package scope. Running it earlier means a `#assert(size_of(T) == N)` cannot see
	// types declared in other files of the same package, and any type it forces to be
	// sized gets that wrong size cached permanently.
	check_delayed_expressions_all(c)

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

	// Hand every untyped expression collected during global checking over to the queue that
	// resolve_global_untyped_expressions drains.
	// C++ Reference: check_parsed_files, TIME_SECTION("add global untyped expression to
	// queue") - add_untyped_expressions(&c->info, &c->info.global_untyped), directly after
	// init_preload and before the builtin_ctx.decl handoff into check_procedure_bodies.
	add_untyped_expressions(&c.info, &c.info.global_untyped)

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

	// Report unused variables/procedures/imports and shadowed declarations across every
	// file scope and package scope.
	// C++ Reference: check_parsed_files, TIME_SECTION("check all scope usages"), directly
	// after the check_merge_queues_into_arrays that follows check_foreign_import_fullpaths
	// and before "add basic type information"/check_for_type_cycles. That is the position
	// below: the only thing between it and the merge is the error-cap unwind guard, which
	// is a no-op on a run that has not hit the cap.
	//
	// It must stay AFTER that guard, not before it. Entities are marked .Used while their
	// procedure bodies are checked, so on a truncated Phase 5 every entity in every body
	// that never got checked still looks unused - running this phase there would emit a
	// flood of false "declared but not used" on top of an already-truncated report.
	check_all_scope_usages(c)

	// Check deferred procedures (procedures with defer statements)
	// C++ line 7373: check_deferred_procedures(c)
	check_deferred_procedures(c)

	// Validate @(objc_context_provider) procedure signatures.
	// C++ Reference: check_parsed_files, TIME_SECTION("check objc context provider
	// procedures"), immediately after check_deferred_procedures. This is the sole consumer
	// of procs_with_objc_context_provider_to_check; without it that queue is a producer-only
	// dead end and no @(objc_context_provider) signature is ever validated.
	check_objc_context_provider_procedures(c)

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

	// @(instrumentation_enter) and @(instrumentation_exit) only make sense as a pair.
	// C++ Reference: check_parsed_files, TIME_SECTION("check instrumentation calls") - an
	// inline block (not a named procedure, which is why it never showed up in a scan for
	// uncalled phases) between the sanity-check merge and the untyped-value drain below.
	//
	// NOTE: this is inert until the attribute parser learns @(instrumentation_enter) and
	// @(instrumentation_exit). check_decl.odin already consumes ac.instrumentation_enter /
	// ac.instrumentation_exit and is what assigns info.instrumentation_*_entity, but
	// check_decl_attributes never sets those two flags - along with no_instrumentation,
	// no_sanitize_address and no_sanitize_memory, the names fall through to the
	// silently-ignore branch. The phase is wired at its C++ position so it starts
	// reporting the moment that producer gap is closed.
	check_instrumentation_calls(c)

	// Record the resolved type and value of every global untyped expression on its AST node.
	// C++ Reference: check_parsed_files, TIME_SECTION("add untyped expression values") -
	// the mpsc_dequeue loop over c->global_untyped_queue calling add_type_and_value. C++
	// runs it after check_unique_package_names and the sanity-check merge, i.e. at the tail
	// of the driver, which is the position below. This is the sole consumer of
	// global_untyped_queue; without it no global untyped expression ever gets a TAV entry.
	resolve_global_untyped_expressions(c)

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

		// Populate the FILE FLAGS from the file's `#+` tags.
		//
		// The whole file-flag layer was previously write-free: mark_file_private,
		// mark_file_private_to_pkg, mark_file_lazy and disable_file_instrumentation all
		// existed with ZERO callers, while readers were live --
		// `is_file_private_to_pkg(info, e.file) || is_file_private(info, e.file)` in
		// entity.odin:459 and `is_file_lazy` in entity_helpers.odin:385. Same
		// declared-and-read-but-never-written family as tasks #74 / #104.
		//
		// The visible consequence was that `#+private` was NEVER ENFORCED: 178 files in
		// the corpus carry it, and an entity in one of them stayed visible to other
		// packages. C++ sets these in the parser (parser.cpp:6810 for lazy); the port's
		// parser already produces the tags, so the connection is all that was missing.
		{
			tags := parser.parse_file_tags(file^, context.temp_allocator)
			switch tags.private {
			case .Package:
				mark_file_private_to_pkg(&c.info, file)
			case .File:
				mark_file_private(&c.info, file)
			case .Public:
				// no flag
			}
			if tags.lazy {
				mark_file_lazy(&c.info, file)
			}
			if tags.no_instrumentation {
				disable_file_instrumentation(&c.info, file)
			}
		}

		// Check if already registered by path
		if pkg.fullpath in c.info.packages {
			continue
		}

		// Register the package
		register_package(&c.info, pkg.fullpath, pkg)

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
	for pkg in sorted_packages(&c.info) {
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
	// Complete any #soa types that were minted since the last merge.
	//
	// C++ Reference: checker.cpp:7444-7450. This is the FIRST thing
	// check_merge_queues_into_arrays does, ahead of the entity and definition drains, because
	// complete_soa_type can itself enqueue entities and definitions - draining them first
	// would leave that work stranded until the next merge point.
	//
	// The port had this step only inside drain_all_queues (queue_drain.odin:893), which has no
	// callers, so soa_types_to_complete was drained at exactly one place in the whole pipeline
	// (check_global_init.odin:594) and any #soa type produced after it stayed incomplete -
	// and, if the queue was still non-empty at teardown, tripped mpsc_destroy's
	// "MPSC queue must be empty before destroy" assertion.
	drain_and_complete_soa_types(c)

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
	for file in sorted_files(pkg.files) {
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
		for file in sorted_files(pkg.files) {
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
			for file in sorted_files(c.info.init_package.files) {
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

// check_instrumentation_calls reports a lone @(instrumentation_enter) or
// @(instrumentation_exit); the backend needs both or neither.
//
// C++ Reference: check_parsed_files, TIME_SECTION("check instrumentation calls")
check_instrumentation_calls :: proc(c: ^Checker) {
	enter := c.info.instrumentation_enter_entity
	exit := c.info.instrumentation_exit_entity

	// C++ uses `(enter != nullptr) ^ (exit != nullptr)` - exactly one of the two present.
	if (enter != nil) != (exit != nil) {
		e := enter
		if e == nil {
			e = exit
		}
		error(e.token, "Both @(instrumentation_enter) and @(instrumentation_exit) must be defined")
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

	for pkg in sorted_packages(&c.info) {
		if pkg == nil || pkg.name == "" {
			continue
		}

		if existing := seen[pkg.name]; existing != nil {
			// Found duplicate package name with different path
			if existing.fullpath != pkg.fullpath {
				// Get a token for the error from the package
				token: tokenizer.Token
				for file in sorted_files(pkg.files) {
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