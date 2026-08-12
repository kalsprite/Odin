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
	// C++ Reference: checker.cpp check_parsed_files:7710-7711 - "check foreign import fullpaths", between
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

	// C++ Reference: check_parsed_files, TIME_SECTION("add basic type information") --
	// checker.cpp:7728-7745, immediately after "check all scope usages" and before "check for
	// type cycles". This is that position: the comment above already named this phase as the
	// marker for where check_all_scope_usages belongs, but the phase itself was never written.
	//
	// The port's type-info roster was therefore only what the min-dep walk REACHED, a strict
	// subset of C++'s. Inert for diagnostics -- nothing in the checker reads the roster -- but
	// it is checker output consumed by a BACKEND, so the subset is a real parity gap rather
	// than a cosmetic one. LEDGER #637.
	add_basic_type_information(c)

	// C++ line 7745: the merge immediately follows the loop, because add_type_info_type
	// enqueues rather than writing the array directly.
	check_merge_queues_into_arrays(c)

	// Check deferred procedures (procedures with defer statements)
	// C++ line 7373: check_deferred_procedures(c)
	check_deferred_procedures(c)

	// Validate @(objc_context_provider) procedure signatures.
	// C++ Reference: check_parsed_files, TIME_SECTION("check objc context provider
	// procedures"), immediately after check_deferred_procedures. This is the sole consumer
	// of procs_with_objc_context_provider_to_check; without it that queue is a producer-only
	// dead end and no @(objc_context_provider) signature is ever validated.
	check_objc_context_provider_procedures(c)

	// C++ Reference: check_parsed_files, TIME_SECTION("calculate global init order") --
	// checker.cpp check_parsed_files:7759-7760. THIS IS THE CORRECT PHASE and the port used to run
	// it in the wrong one: the call lived inside check_all_global_entities, which runs at line 152
	// above, BEFORE check_procedure_bodies. The entity dependency graph is grown by body checking,
	// so computing the order there used a graph missing every edge that bodies, deferred procedures
	// and objc context providers contribute.
	//
	// TWO CONSEQUENCES, one of which no gate here can see:
	//   * variable_init_order is BACKEND state -- its only consumer is llvm_backend.cpp:3374 -- so a
	//     wrong global initialisation order is invisible to every diagnostic gate, exactly like the
	//     canonical-name tags in #601.
	//   * calculate_global_init_order also EMITS DIAGNOSTICS ("Cyclic initialization of '%s'" plus
	//     its refers-to chain, checker.cpp:6425-6430). Fewer graph edges means fewer detectable
	//     cycles, so the early call was also a potential UNDER-REJECTION.
	// Parity was at baseline before this move, which means no corpus package exercises a global
	// initialisation cycle -- the diagnostic half of this is UNMEASURED, not proven inert.
	store_global_init_order(c)

	// C++ Reference: check_parsed_files, TIME_SECTION("add type info for type definitions")
	// through TIME_SECTION("check #soa types") -- checker.cpp check_parsed_files:7755-7768. THREE phases that the
	// port implemented but never called.
	//
	// LEDGER task 222 claimed "all 28 phases present and called except one". That was wrong:
	// I had enumerated the phase list through `head -40` and stopped reading before these.
	add_type_info_for_type_definitions(c)
	check_merge_queues_into_arrays(c)

	check_update_dependency_tree_for_procedures(c)

	// C++ runs generate_minimum_dependency_set(c, entry_point) HERE (checker.cpp:3110), and the
	// port now does too -- the walk landed in LEDGER #638 stage 2. Until then this position was
	// documented but empty, so `min_dep_count` never rose above zero and the loop inside
	// check_unchecked_bodies found nothing to do.
	generate_minimum_dependency_set_internal(c, c.info.entry_point)
	//
	// SCOPE (task #272, decided by enumerating every reader of min_dep_count in C++):
	//   llvm_backend*.cpp x5, main.cpp:3408          -> CODEGEN, out of scope for a checker
	//   checker.cpp:6650  check_unchecked_bodies      -> a RACE BACKSTOP; bill's own comment there
	//                                                   calls it "a partial hack ... HACK TODO:
	//                                                   Actually fix this race condition"
	//   checker.cpp:7509/7513 add_type_info_for_type_definitions -> populates the RTTI type-info
	//                                                   table
	// NONE of them emit a diagnostic, so the missing pass does not affect diagnostic parity, and
	// the corpus agrees: parity.sh is 225/225 on both counts and text with the loop empty.
	//
	// The earlier version of this comment blamed task #42. That was wrong by the time it was read:
	// #42 closed with the OPPOSITE conclusion ("the error cap all along -- NOT a dependency set"),
	// so nothing was ever going to make this loop non-empty. Corrected here.
	// C++ checker.cpp:3111-3202, the FORCE_ADD_RUNTIME_ENTITIES roster inside
	// generate_minimum_dependency_set. This is a SECOND dependency mechanism, separate from
	// add_package_dependency, and the port had no equivalent at all -- none of
	// memory_compare_zero / memory_equal / memory_compare / __init_context / _cleanup_runtime
	// were referenced anywhere. LEDGER #547-B.
	//
	// SCOPE. C++'s force_add_dependency_entity does TWO things: `e->flags |= EntityFlag_Used`
	// and `add_dependency_to_set(c, e)`. BOTH ARE NOW DONE -- this routes through the port's
	// force_add_dependency_entity (scope.odin:805), which performs both.
	//
	// IT DID NOT USED TO. #272 scoped the dependency SET out on evidence: every min_dep_count
	// reader is codegen, a race backstop, or the RTTI table, and none emits a diagnostic. That
	// reasoning was sound FOR DIAGNOSTICS and is why only the flag half was ported (the flag is
	// entity state the model dump compares directly, which #272 could not have weighed because
	// the dump did not exist yet).
	//
	// WHAT CHANGED IS THE CONSUMER, NOT THE EVIDENCE. "Every reader is codegen" is an argument
	// for building the set once a BACKEND exists, not against it -- the set is the checker's
	// output to codegen, and a backend asking for an entity the set never received gets nothing.
	// So the set half is now built too. #272 stays correct about diagnostics and stops being a
	// reason to skip this. LEDGER #638 stage 1.
	//
	// This also activates add_dependency_to_set, which had ZERO callers and had therefore never
	// executed. Its recursion terminates on the `min_dep_count > 1` early return (scope.odin:844),
	// checked before switching it on rather than after -- unexercised recursive code is how #23
	// happened.
	//
	// VERIFIED before being written: force-adding just memory_compare_zero and memset over four
	// packages took the `used` divergence 70 -> 65 and dropped both entities out of the residual,
	// which is what established that this mechanism is the cause rather than a guess.
	force_add_runtime_used(c)

	check_unchecked_bodies(c)

	check_merge_queues_into_arrays(c)

	// Sort init/fini procedures by priority
	// C++ line 7377: check_sort_init_and_fini_procedures(c)
	check_sort_init_and_fini_procedures(c)

	// Report intrinsics.__entry_point calls made in a program that has no entry point.
	// C++ Reference: checker.cpp check_parsed_files:7900-7909
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
	// C++ Reference: check_parsed_files, `bool package_names_are_unique = check_unique_package_names(c);`
	// -- checker.cpp check_parsed_files:7824. The result is carried to the type-info collision
	// check at the tail of this driver, exactly as C++ carries its local (#711).
	package_names_are_unique := check_unique_package_names(c)

	// Check entry point
	// C++ Reference: checker.cpp:7441-7463
	check_entry_point(c)

	// Safety net: any procedure that is .Used but whose body was never checked gets checked
	// here, and every Proc_Info is moved into info.all_procedures.
	// C++ Reference: check_parsed_files, TIME_SECTION("check unchecked (safety measure)"),
	// immediately after the entry-point block. NOTE the guard is `#define
	// DEBUG_CHECK_ALL_PROCEDURES 1` (checker.cpp:1) -- it is ON, so C++ runs this in EVERY
	// build, not only debug ones. The port had the procedure implemented but with zero call
	// sites, so a body that slipped past the worker queue was never checked and its errors
	// were never reported.
	when DEBUG_CHECK_ALL_PROCEDURES {
		check_safety_all_procedures_for_unchecked(c)
	}

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

	// Build the final type-info table: sort the minimum-dependency type set by canonical hash,
	// fill the open-addressed lookup array, and detect hash collisions.
	//
	// C++ Reference: check_parsed_files, TIME_SECTION("initialize and check for collisions in
	// type info array") -- checker.cpp check_parsed_files:7851-7902. C++ runs this block
	// immediately after TIME_SECTION("add untyped expression values") (:7842-7849), which is
	// `resolve_global_untyped_expressions` above, and immediately before TIME_SECTION("sort init
	// and fini procedures") (:7905). That is the position here.
	//
	// LEDGER #711: this phase existed as a well-formed named procedure in type_info.odin and had
	// ZERO CALLERS. Same shape as #637/#638 -- C++ runs the work INLINE inside its big driver, the
	// port hoisted it into a tidy procedure, and the call was never written (#158).
	//
	// EXPLICITLY UNMEASURED, like #709: the only reader of what this populates is
	// `type_info_index` / `type_info_index_pair`, and those have ZERO CALLERS in this port -- in
	// C++ their only real caller is `lb_type_info_index` in the LLVM backend
	// (llvm_backend_type.cpp:8, llvm_backend.cpp:3299), which is out of scope here. So wiring it
	// makes the port's phase sequence faithful and populates the table C++ populates; no gate in
	// this repository can observe the table itself (#155/#156).
	//
	// What IS observable is the collision panic, which is why `package_names_are_unique` is
	// threaded down: C++ suppresses the panic when a duplicate package declaration was already
	// reported (:7882). Reachability of the panic is NOT established in either implementation --
	// it needs two distinct types whose canonical hashes collide (#169/#174 discipline).
	finalize_minimum_dependency_type_info(c, package_names_are_unique)

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

			// `#+feature ...` and `#+vet ...` are NOT read here. They used to be, by a
			// whitespace split over the raw tag tokens, which was a simplified stand-in
			// for C++'s parse_vet_tag / parse_feature_tag and silently accepted four
			// things C++ rejects (#305). The faithful port lives in file_tags.odin and
			// runs on the PARSE side of check_package_from_path's error gate, where C++
			// runs it -- by the time control reaches here, file.vet_flags and
			// file.feature_flags are already populated.
		}

		// Check if already registered by path
		if pkg.fullpath in c.info.packages {
			continue
		}

		// Register the package
		register_package(&c.info, pkg.fullpath, pkg)

		// Check for special packages
		// C++ line 7294-7303: Special package detection
		//
		// init_package is NOT set here. C++ sets it from the SCOPE FLAG, in the same loop that
		// creates the scopes (checker.cpp:7671-7673), because the flag is a disjunction of the
		// kind and a fullpath comparison -- a kind test alone misses the case where the requested
		// package is base/runtime. See create_package_scopes below.
		//
		// init_fullpath is not set here either: it belongs to the loader, which is this port's
		// analogue of C++'s parser (parser.cpp:7099), and is the value the caller ASKED for.
		// Setting it from a loaded package's kind was circular -- the only writer sat inside
		// `if pkg.kind == .Init`, and nothing ever stamped that kind, so both halves of
		// checker.cpp:268 were permanently false (#589).
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
		pkg_scope := get_package_scope(&c.info, pkg)
		if pkg_scope == nil {
			pkg_scope = create_scope_from_package(&ctx, pkg, c.allocator)
			set_package_scope(&c.info, pkg, pkg_scope)
		}

		// C++ Reference: checker.cpp:7671-7673
		//     if (scope->flags&ScopeFlag_Init) {
		//         c->info.init_package = p;
		//         c->info.init_scope = scope;
		//     }
		//
		// Read the FLAG, not the kind. create_scope_from_package set it from C++'s disjunction
		// (`pkg.fullpath == info.init_fullpath || pkg.kind == .Init`, checker.cpp:268), so this
		// also catches the package that could not be stamped `.Init` because the runtime seed
		// claimed its queue slot -- i.e. when the requested package IS base/runtime, which then
		// carries both `.Init` and `.Global`.
		//
		// The pair must be written TOGETHER. init_scope was previously never written at all,
		// and check_entry_point returns early on `init_scope == nil`, so info.entry_point was
		// never populated and C++'s "no main" diagnostic had no working counterpart (#589).
		//
		// This runs even when the scope already existed: the assignment is a property of the
		// package, not of who created its scope, and the early `continue` this replaces would
		// have skipped it.
		if .Init in pkg_scope.flags {
			c.info.init_package = pkg
			c.info.init_scope = pkg_scope
		}
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

	// NOTE: all_procedures_queue is deliberately NOT drained here. In C++ that queue has
	// exactly ONE consumer, checker.cpp:6677 inside check_safety_all_procedures_for_unchecked,
	// and check_merge_queues_into_arrays (checker.cpp:7444-7451) does not touch it. Draining
	// it here -- which the port used to do -- both populated info.all_procedures early
	// (masking the omission) and left the queue empty, so the safety phase had nothing to
	// examine even once it was called. The safety phase does the appending itself.

	// Drain required_foreign_imports_through_force queue
	// C++ Reference: checker.cpp:2975-2978, inside generate_minimum_dependency_set_internal.
	// C++ also calls add_to_set(c, e) here; that belongs to generate_minimum_dependency_set,
	// which the port does not implement (task #272 -- SCOPED OUT: no reader of min_dep_count
	// emits a diagnostic). Only the array_add half is reproduced, and that is sufficient.
	// (This previously cited task #42, which closed with an unrelated conclusion.)
	for {
		if entity, ok := queue.mpsc_dequeue(&c.info.required_foreign_imports_through_force_queue); ok {
			append(&c.info.required_foreign_imports_through_force, entity)
		} else {
			break
		}
	}

	// Drain required_global_variable queue, marking each entity Used.
	// C++ Reference: checker.cpp:2980-2983 (same function):
	//     for (Entity *e; mpsc_dequeue(&c->info.required_global_variable_queue, &e); ) {
	//         e->flags |= EntityFlag_Used;
	//         add_to_set(c, e);
	//     }
	// The port had NO live consumer for this queue at all -- its only dequeue was in the
	// dead drain_required_global_variable_queue. A single `@(require)` global therefore left
	// an item in the queue and tripped mpsc_destroy's "MPSC queue must be empty before
	// destroy" assertion at teardown, killing the checker on a package C++ accepts silently.
	// As above, add_to_set belongs to the dependency-set pass scoped out under #272; the .Used
	// marking is reproduced here because it is observable semantics, not bookkeeping.
	// (This previously cited task #42, which closed with an unrelated conclusion.)
	for {
		if entity, ok := queue.mpsc_dequeue(&c.info.required_global_variable_queue); ok {
			if entity != nil {
				entity.flags |= {.Used}
			}
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
// C++ Reference: checker.cpp:7789-7811 (`TIME_SECTION("check entry point")`)
check_entry_point :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:7790
	//     if (build_context.build_mode == BuildMode_Executable && !build_context.no_entry_point &&
	//         build_context.command_kind != Command_test) {
	// Kept as C++'s single if / else-if rather than three early returns, because the else-if
	// arm below is REACHABLE and an early return on no_entry_point would skip it.
	if build_context.build_mode == .Executable &&
	   !build_context.no_entry_point &&
	   .Test not_in build_context.command_kind {
		// C++ Reference: checker.cpp:7791-7793
		//     Scope *s = c->info.init_scope;
		//     GB_ASSERT(s != nullptr);
		//     GB_ASSERT(s->flags&ScopeFlag_Init);
		//
		// DELIBERATE DIVERGENCE: C++ asserts, this returns. C++ can assert because its driver
		// has already exited on an unresolvable init path, so by here a package always exists.
		// This checker is a LIBRARY and is reachable with a path that resolved to nothing, which
		// leaves no package to carry the Init flag; aborting the host process over a bad argument
		// would be wrong.
		//
		// This return is also what hid #589 for so long -- init_scope was NEVER written, so the
		// whole procedure was a no-op and no gate could see it. It is now a genuine
		// nothing-was-loaded guard rather than a permanent one.
		init_scope := c.info.init_scope
		if init_scope == nil {
			return
		}

		// C++ Reference: checker.cpp:7794
		main_entity := scope_lookup_current(init_scope, "main")
		if main_entity == nil {
			// C++ Reference: checker.cpp:7795-7807. C++ starts from a zeroed token with
			// line/column forced to 1, then replaces it with the first token of the init
			// package's first file if there is one. That first token is the `package` keyword,
			// which is what pkg_token holds (#197 pinned the anchor to the keyword, not the
			// package name).
			token: tokenizer.Token
			token.pos.line = 1
			token.pos.column = 1

			if c.info.init_package != nil {
				for file in sorted_files(c.info.init_package.files) {
					if file != nil {
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
	} else if build_context.build_mode == .Dynamic_Library && build_context.no_entry_point {
		// C++ Reference: checker.cpp:7808-7810
		//     } else if (build_context.build_mode == BuildMode_DynamicLibrary &&
		//                build_context.no_entry_point) {
		//         c->info.entry_point = nullptr;
		//     }
		//
		// NOT redundant with entry_point's zero value: check_decl.odin's proc-declaration path
		// (C++ check_decl.cpp:1557) writes info.entry_point for any `main` in the init package,
		// with no regard for build mode. A dynamic library built with -no-entry-point therefore
		// arrives here with a non-nil entry_point that must be cleared, or a backend would emit
		// an entry symbol for a library. Unreachable before #589 -- nothing was ever the init
		// package, so nothing ever set it in the first place.
		c.info.entry_point = nil
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

// package_first_pkg_decl returns C++'s `pkg->files[0]->pkg_decl`
// (checker.cpp check_unique_package_names:7403-7404).
//
// C++ indexes `files[0]` directly. The port goes through `sorted_files` so the choice is
// order-stable; that selects the SAME element, because C++'s `pkg->files` is already sorted by the
// time this phase runs (LEDGER #170 dispositioned every raw `pkg.files` iteration by sort TIMING).
package_first_pkg_decl :: proc(pkg: ^ast.Package) -> ^ast.Package_Decl {
	for file in sorted_files(pkg.files) {
		if file != nil {
			return file.pkg_decl
		}
	}
	return nil
}

// check_unique_package_names validates that no two packages share the same name.
//
// C++ Reference: checker.cpp check_unique_package_names:7380-7434.
//
// The return value is C++'s `bool ok` (declared :7382, returned :7433): false once a genuine
// duplicate has been reported. C++ captures it at check_parsed_files:7824 as
// `package_names_are_unique` and uses it at :7882 to SUPPRESS the type-info hash-collision panic
// (LEDGER #711).
//
// LEDGER #712: this was a REIMPLEMENTATION, not a port, and it diverged from C++ in four MEASURED
// ways -- all reproduced against the oracle with probe `n712` (two subpackages both `package dup`,
// imported by a third):
//   1. invented message text `Duplicate package name '%s' found in '%s' and '%s'`;
//   2. the caret: it reported on a `tokenizer.Token`, which is ONE position (`^`), where C++ reports
//      on the `pkg_decl` AST NODE, which carries a span (`^~~~~~~~~~^`). ONE root cause, TWO
//      symptoms -- fixing the anchor fixes the caret for free (#574's shape);
//   3. the three-line explanatory `error_line` block was absent entirely;
//   4. the `<pos> found at previous location` line was absent entirely.
// It also compared `existing.fullpath != pkg.fullpath` where C++ compares `curr == prev` NODE
// IDENTITY and calls equality "a false positive", and it opened no error block.
//
// NONE of that was visible to any gate here: every package in the 323-package corpus has a unique
// name, so the emitting branch is never taken. An invented diagnostic on an unexercised path is
// invisible to a comparator that only ever sees the path not taken (#71's shape from the other
// side) -- which is why this was found by reading C++, not by a sweep.
//
// KNOWN REMAINING GAP, deliberate and scoped: C++ :7418-7428 adds a case-folded-directory note for
// upstream issue 5080, but it sits inside `#if defined(GB_SYSTEM_WINDOWS)` -- a HOST compile-time
// guard, compiled out on this machine. It is NOT one of the four measurable divergences and cannot
// be gated locally (LEDGER #161). It is omitted rather than written blind: carrying it would need a
// `strings` import that is unused on every non-Windows host, which breaks the `-vet` gate. Port it
// with `when ODIN_OS == .Windows` if this checker is ever built on a Windows host.
check_unique_package_names :: proc(c: ^Checker) -> (ok: bool) {
	ok = true

	// C++ :7385-7387 -- `StringMap<AstPackage *> pkgs`, keyed by package NAME.
	pkgs: map[string]^ast.Package
	defer delete(pkgs)

	for pkg in sorted_packages(&c.info) {
		if pkg == nil {
			continue
		}
		// C++ :7390-7392 -- its own comment is "Sanity check". Note this is a FILE-COUNT guard.
		// The port previously skipped on `pkg.name == ""` instead, which C++ does not do.
		if len(pkg.files) == 0 {
			continue
		}

		name := pkg.name
		found, exists := pkgs[name]
		if !exists {
			// C++ :7397-7400 -- first sighting of this name, record and move on.
			pkgs[name] = pkg
			continue
		}

		curr := package_first_pkg_decl(pkg)
		prev := package_first_pkg_decl(found)

		// C++ :7405-7409 -- "NOTE(bill): A false positive was found, ignore it". NODE IDENTITY, not
		// a path comparison. This `continue` does NOT clear `ok`.
		if curr == prev {
			continue
		}

		ok = false

		// C++ :7411 / :7430 -- begin_error_block() ... end_error_block() around the whole report.
		begin_error_block()
		defer end_error_block()

		// C++ :7412 -- anchored on `curr`, the pkg_decl NODE, which is what draws the span caret.
		error_node(curr, "Duplicate declaration of 'package %s'", name)
		// C++ :7413-7415 -- ONE error_line call carrying all three lines.
		error_line(
			"\tA package name must be unique\n" +
			"\tThere is no relation between a package name and the directory that contains it, so they can be completely different\n" +
			"\tA package name is required for link name prefixing to have a consistent ABI\n",
		)
		// C++ :7416.
		error_line("%s found at previous location\n", token_pos_to_string(ast_token(prev).pos))
	}

	return ok
}
// force_add_runtime_used marks the runtime entities C++ force-adds to the minimum dependency set.
//
// C++ Reference: checker.cpp:3111-3202, the FORCE_ADD_RUNTIME_ENTITIES macro inside
// generate_minimum_dependency_set, and force_add_dependency_entity at checker.cpp:3086.
//
// Only the ENTITY FLAG half of C++'s force_add_dependency_entity is reproduced -- see the note at
// the call site for why the dependency-set half stays out of scope per #272. C++'s helper returns
// silently when the lookup fails (its GB_ASSERT_MSG sits after an `if (e == nullptr) return;`, so
// it is unreachable), and several roster names are documented there as "only if these exist", so a
// missing name is expected rather than a defect here.
force_add_runtime_used :: proc(c: ^Checker) {
	rt := get_core_package(&c.info, "runtime")
	if rt == nil {
		return
	}
	scope := get_package_scope(&c.info, rt)
	if scope == nil {
		return
	}

	// Routed through force_add_dependency_entity (scope.odin:805) rather than setting the flag
	// inline, so this does BOTH halves of C++'s helper -- `e->flags |= EntityFlag_Used` AND
	// `add_dependency_to_set(c, e)`. See the note at the call site for why the set half was
	// deliberately omitted before and what changed. LEDGER #638.
	add :: proc(c: ^Checker, scope: ^Scope, names: []string) {
		for name in names {
			force_add_dependency_entity(c, scope, name)
		}
	}

	// Always required. NOTE cstring_to_string is commented out in C++ and is omitted here too.
	add(c, scope, {
		// Odin types
		"Source_Code_Location", "Context", "Allocator", "Logger",
		// Odin internal procedures
		"__init_context", "_cleanup_runtime",
		// Pseudo-CRT required procedures
		"memset",
		// Utility procedures
		"memory_equal", "memory_compare", "memory_compare_zero",
	})

	if build_context.no_crt {
		add(c, scope, {"memcpy", "memmove"})
	}
	if build_context.metrics.arch == .Arm32 {
		add(c, scope, {"aeabi_d2h"})
	}
	if is_arch_wasm() {
		// The extended-data-type entries above these are commented out in C++; only the three
		// WASM-specific ones are live.
		add(c, scope, {"__ashlti3", "__multi3", "__lshrti3"})
	}
	if !build_context.no_rtti {
		add(c, scope, {"Type_Info", "type_table", "__type_info_of"})
	}
	if !build_context.no_entry_point {
		add(c, scope, {"args__"})
	}
	if build_context.no_crt && !is_arch_wasm() {
		add(c, scope, {"_tls_index", "_fltused"})
	}
	if !build_context.no_bounds_check {
		add(c, scope, {
			"bounds_check_error", "matrix_bounds_check_error",
			"slice_expr_error_hi", "slice_expr_error_lo_hi",
			"multi_pointer_slice_expr_error",
		})
	}
}
