package checker

import "core:container/queue"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:slice"
import "core:sync"
/*
Procedure checking infrastructure and parallel worker support.

This module implements procedure checking infrastructure including:
- Deferred procedure checking queue management
- Worker data initialization for parallel checking
- Sequential and parallel procedure checking coordination
- Nested procedure dependency handling

SCOPE:
This module handles procedure checking ORCHESTRATION, not signature validation.
Procedure signature checking (check_procedure_type, check_get_params, check_get_results)
belongs in check_type.odin per architectural separation.

C++ Reference: checker.cpp check_procedure_later
               checker.cpp consume_proc_info, check_proc_info_worker_proc
               checker.cpp check_init_worker_data, check_procedure_bodies
*/


// ======================================================================================
// GLOBAL STATE
// C++ Reference: checker.cpp:2545-2546
// ======================================================================================

// Debug flag to track all procedures for safety checks
// C++ Reference: checker.cpp:1 (#define DEBUG_CHECK_ALL_PROCEDURES 1)
// Enables tracking of all procedures in the all_procedures_queue
// for verifying none were missed during checking
DEBUG_CHECK_ALL_PROCEDURES :: true

// Global flag tracking if procedure bodies are being processed via worker queue
// C++ Reference: checker.cpp:2545 (gb_global std::atomic<bool> global_procedure_body_in_worker_queue)
global_procedure_body_in_worker_queue: bool = false

// Global flag set after procedure body checking completes
// C++ Reference: checker.cpp:2546 (gb_global std::atomic<bool> global_after_checking_procedure_bodies)
global_after_checking_procedure_bodies: bool = false

// Total count of procedure bodies successfully checked
// C++ Reference: checker.cpp:6729 (gb_global std::atomic<isize> total_bodies_checked)
total_bodies_checked: int = 0

// ======================================================================================
// WORKER DATA STRUCTURES
// C++ Reference: checker.cpp:6763-6768
// ======================================================================================

// Check_Procedure_Body_Worker_Data stores per-worker thread state for parallel checking
// C++ Reference: struct CheckProcedureBodyWorkerData in checker.cpp:6763-6766
Check_Procedure_Body_Worker_Data :: struct {
	c:       ^Checker, // C++ line 6764: Checker *c
	untyped: map[^ast.Expr]^Expr_Info, // C++ line 6765: UntypedExprInfoMap untyped
}

// Global array of worker data (one per thread)
// C++ Reference: checker.cpp:6768 (gb_global CheckProcedureBodyWorkerData *check_procedure_bodies_worker_data)
check_procedure_bodies_worker_data: []Check_Procedure_Body_Worker_Data

// NOTE: Proc_Tag is defined in checker.odin (lines 351-361)

// ======================================================================================
// PROCEDURE DEFERRAL
// C++ Reference: checker.cpp check_procedure_later
// ======================================================================================

// check_procedure_later queues a procedure for deferred checking
// C++ Reference: checker.cpp check_procedure_later (the ProcInfo * overload)
//
// This is the main entry point for scheduling procedure body checking.
// Depending on whether parallel checking is active, procedures are either:
// - Added to the worker task queue (parallel mode)
// - Added to procs_to_check array (sequential mode)
//
// Note: This overload takes a ProcInfo pointer.
// C++ also has an overload taking raw parameters (line 2366-2378).
check_procedure_later :: proc(c: ^Checker, info: ^Proc_Info) {
	assert(info != nil)
	assert(info.decl != nil)

	// Debug: Log if we're scheduling after bodies have been checked
	// C++ Reference: checker.cpp check_procedure_later
	if sync.atomic_load(&global_after_checking_procedure_bodies) {
		e := info.decl.entity
		if e != nil {
			debug_entity_type("CHECK PROCEDURE LATER!", e)
		}
	}

	// Decide how to queue based on worker queue status
	// C++ Reference: checker.cpp check_procedure_later
	if sync.atomic_load(&global_procedure_body_in_worker_queue) {
		// Parallel mode: Add to worker task queue
		// C++ Reference: checker.cpp check_procedure_later
		thread_pool_add_task(check_proc_info_worker_proc, info)
	} else {
		// Sequential mode: Add to procs_to_check array
		// C++ Reference: checker.cpp check_procedure_later
		append(&c.procs_to_check, info)
	}

	// For debug builds, track all procedures in the all_procedures_queue
	// C++ Reference: checker.cpp check_procedure_later
	when DEBUG_CHECK_ALL_PROCEDURES {
		assert(info != nil)
		assert(info.decl != nil)
		queue.mpsc_enqueue(&c.info.all_procedures_queue, info)
	}
}

// check_procedure_later_from_params creates a ProcInfo and queues it for checking
// C++ Reference: checker.cpp check_procedure_later (the raw-parameter overload)
//
// This overload constructs a ProcInfo from raw parameters before deferring.
// Used when we have the procedure components but not a ProcInfo struct yet.
check_procedure_later_from_params :: proc(c: ^Checker, file: ^ast.File, token: tokenizer.Token, decl: ^Decl_Info, type: ^Type, body: ^ast.Block_Stmt, tags: u64) {
	// Allocate and initialize ProcInfo
	// C++ Reference: checker.cpp check_procedure_later
	info := new(Proc_Info)
	info.file = file
	info.token = token
	info.decl = decl
	info.type = type
	info.body = body
	info.tags = tags

	// Defer via the main check_procedure_later
	// C++ Reference: checker.cpp check_procedure_later
	check_procedure_later(c, info)
}

// check_procedure_later_from_entity extracts procedure info from an entity and defers it
// C++ Reference: checker.cpp check_procedure_later_from_entity
//
// This function converts an Entity_Procedure into a ProcInfo and queues it for checking.
// It handles several edge cases:
// - Foreign procedures (skipped)
// - Already-checked procedures (skipped)
// - Procedure aliases/overrides (special handling)
// - Polymorphic procedures (only check specialized ones)
// - Procedures without bodies (skipped)
//
// Parameters:
//   c: Checker context
//   e: Entity to extract procedure info from
//   from_msg: Debug message indicating caller (for logging)
check_procedure_later_from_entity :: proc(c: ^Checker, e: ^Entity, from_msg: string = "") {
	// Early validation
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if e == nil || e.kind != .Procedure {
		return
	}

	// Get procedure variant
	proc_var, ok := e.variant.(Entity_Procedure)
	if !ok {
		return
	}

	// Skip foreign procedures (no body to check)
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if proc_var.is_foreign {
		return
	}

	// Skip already-checked procedures
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if sync.atomic_load(&e.proc_body_checked) {
		return
	}

	// Handle procedure aliases (@(link_name) overrides)
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if .Overridden in e.flags {
		// NOTE(zen3ger): Delay checking of a proc alias until the underlying proc is checked
		assert(e.aliased_of != nil)
		assert(e.aliased_of.kind == .Procedure)

		// If aliased procedure is already checked, mark this as checked too
		if sync.atomic_load(&e.aliased_of.proc_body_checked) {
			sync.atomic_store(&e.proc_body_checked, true)
			return
		}

		// Defer the alias (with nil body and 0 tags since it's an alias)
		// C++ Reference: checker.cpp check_procedure_later_from_entity
		check_procedure_later_from_params(c, e.file, e.token, e.decl_info, e.type, nil, 0)
		return
	}

	// Validate type
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	//
	// C++ tests `type == t_invalid`, NOT nullptr, and RETURNS. The port tested only nil and then
	// asserted kind == .Proc -- so an entity whose procedure type failed to check reached that
	// assertion and PANICKED the checker where C++ walks away quietly. t_invalid is Basic-kinded, so
	// the assertion could not have passed. The fix is C++'s own test either way.
	//
	// REACHABILITY MEASURED (tick 138) AND THIS GUARD WAS NOT REACHED. A hit counter on the branch
	// below (probe presence verified in-source BEFORE building, after tick 136's vacuous-zero
	// mistake) recorded 0 hits on all of:
	//     $S/phase2/wit_badproctype/bpt_badparam   `f :: proc(x: NoSuchType) {}` plus a call
	//     $S/phase2/wit_badproctype/bpt_badresult  `g :: proc() -> NoSuchType` plus a call
	//     $S/phase2/wit_badproctype/bpt_group      the same inside a proc GROUP
	//     core/odin/checker                        (a large real package)
	// All three cells DO produce diagnostics and all three MATCH the oracle exactly, so an
	// invalid-typed procedure entity is certainly produced -- it simply never arrives here.
	// Recorded as UNREACHED ON FOUR INPUTS, not as dead code.
	//
	// The nil arm is a port-only defence with no C++ counterpart -- C++ would hand nullptr to
	// base_type and segfault. Kept deliberately, not inherited.
	type := base_type(e.type)
	if type == nil || type == t_invalid {
		return
	}

	assert(type.kind == .Proc, "Expected procedure type") // C++ GB_ASSERT_MSG

	// Only check specialized polymorphic procedures
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	//
	// C++ calls is_type_polymorphic(type), the RECURSIVE structural predicate; the port read
	// Type_Proc.is_polymorphic, the raw flag. The predicate is strictly WIDER -- its .Proc arm
	// returns true for the flag OR a polymorphic parameter tuple OR a polymorphic result tuple
	// (types.cpp is_type_polymorphic; the port's equivalent arm is check_type.odin:1933 onward and
	// carries all three conditions). Reading the flag alone UNDER-detects, so the port queued
	// bodies C++ declines to check.
	proc_type, type_ok := type.variant.(Type_Proc)
	if !type_ok {
		return
	}

	if is_type_polymorphic(type) && !proc_type.is_poly_specialized {
		return // Unspecialized polymorphic procedures are not checked
	}

	// Validate decl_info exists
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	// Note: Entities from extracted runtime may not have decl_info
	if e.decl_info == nil {
		return
	}

	// Construct ProcInfo from entity
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	pi := new(Proc_Info)
	pi.file = e.file
	pi.token = e.token
	pi.decl = e.decl_info
	pi.type = e.type

	// Extract procedure literal to get body and tags
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	pl := e.decl_info.proc_lit
	assert(pl != nil)
	pi.body = pl.body.derived.(^ast.Block_Stmt)
	pi.tags = u64(transmute(u32)pl.tags)

	// Skip procedures without bodies
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if pi.body == nil {
		return
	}

	// Debug logging
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	if from_msg != "" {
		debugf("CHECK PROCEDURE LATER [FROM %s]! %s :: %s {...}\n",
			from_msg, e.token.text, type_to_string(e.type))
	}

	// Queue the procedure for checking
	// C++ Reference: checker.cpp check_procedure_later_from_entity
	check_procedure_later(c, pi)
}

// ======================================================================================
// PROCEDURE CONSUMPTION
// C++ Reference: checker.cpp consume_proc_info
// ======================================================================================

// consume_proc_info attempts to check a procedure, handling dependencies
// C++ Reference: checker.cpp consume_proc_info
//
// Returns true if the procedure was successfully checked.
// Returns false if checking was deferred (dependency not ready, already checked, etc.)
//
// Key behaviors:
// - Skip if already checked or in progress
// - Defer nested procedures until parent is checked
// - Increment total_bodies_checked on success
consume_proc_info :: proc(c: ^Checker, pi: ^Proc_Info, untyped: ^map[^ast.Expr]^Expr_Info) -> bool {
	if pi == nil {
		return false
	}
	if pi.decl == nil {
		return false
	}

	// Check current procedure checking state
	// C++ Reference: checker.cpp consume_proc_info
	#partial switch sync.atomic_load(&pi.decl.proc_checked_state) {
	case .In_Progress:
		// Already being checked, don't re-enter
		// C++ Reference: checker.cpp consume_proc_info
		return false
	case .Checked:
		// Already checked successfully
		// C++ Reference: checker.cpp consume_proc_info
		return true
	}

	// Handle nested procedure dependencies
	// C++ Reference: checker.cpp consume_proc_info
	if pi.decl.parent != nil && pi.decl.parent.entity != nil {
		parent := pi.decl.parent.entity

		// Only check nested procedures after their parent is checked
		// This prevents race conditions in multithreaded evaluation
		// In single-threaded mode, this should never trigger
		// C++ Reference: checker.cpp consume_proc_info
		//
		// THE POLYMORPHIC GATE WAS MISSING HERE, exactly as it was missing from the SIBLING copy of
		// this block in check_proc_info_worker_proc (fixed in #592). C++ defers only when the parent
		// is NOT an unspecialized-polymorphic procedure; when it IS, C++ falls through and checks
		// the nested body now. The port deferred unconditionally.
		//
		// That is not a wording divergence. An unspecialized polymorphic parent NEVER gets
		// proc_body_checked -- check_procedure_later_from_entity returns early for exactly that case
		// (checker.cpp:6495-6497) -- so the parent flag can never become true, and the sequential
		// drain in check_procedure_bodies re-evaluates len(procs_to_check) every iteration. An
		// unconditional re-defer therefore feeds the loop its own work indefinitely.
		//
		// REACHABILITY MEASURED (tick 136), and this gate was NOT REACHED. Instrumented with a hit
		// counter and run over five packages: the three purpose-built shapes in
		// $S/phase2/wit_polynest (uninstantiated `outer :: proc($T: typeid)` with a nested proc, the
		// same instantiated, and a doubly-nested polymorphic variant) plus core/fmt and
		// core/odin/checker -- 0 hits on ALL FIVE, while the sibling gate below took 25042 hits on the
		// six-line cell alone. Recorded as UNREACHED ON FIVE PACKAGES, not as dead code: the
		// precondition (a Proc_Info enqueued for a nested procedure whose parent body is never checked)
		// may need a shape not yet built. Kept for parity, and the failure mode it guards is a hang
		// rather than a wrong diagnostic.
		if parent.kind == .Procedure && !sync.atomic_load(&parent.proc_body_checked) {
			// C++ Reference: checker.cpp consume_proc_info
			is_poly := false
			if parent.type != nil {
				if pt, ok := base_type(parent.type).variant.(Type_Proc); ok {
					is_poly = pt.is_polymorphic && !pt.is_poly_specialized
				}
			}
			if !is_poly {
				// Defer this procedure until parent is ready
				// C++ Reference: checker.cpp consume_proc_info
				check_procedure_later(c, pi)
				return false
			}
		}
	}

	// Clear the untyped expression map before checking
	// C++ Reference: checker.cpp consume_proc_info
	if untyped != nil {
		clear(untyped)
	}

	// Perform the actual procedure checking
	// C++ Reference: checker.cpp consume_proc_info
	success := check_proc_info(c, pi, untyped)

	if success {
		// Increment total checked counter atomically
		// C++ Reference: checker.cpp consume_proc_info
		sync.atomic_add(&total_bodies_checked, 1)
		return true
	}

	return false
}

// ======================================================================================
// WORKER THREAD INFRASTRUCTURE
// C++ Reference: checker.cpp check_proc_info_worker_proc
// ======================================================================================

// check_proc_info_worker_proc is the worker thread entry point for parallel checking
// C++ Reference: checker.cpp check_proc_info_worker_proc (WORKER_TASK_PROC(check_proc_info_worker_proc))
//
// This function is called by worker threads to process procedures from the work queue.
// It handles:
// - Nested procedure dependencies (re-queue if parent not ready)
// - Per-worker untyped expression maps
// - Atomic counter updates
//
// Returns:
// - 0 on success (procedure checked)
// - 1 on failure or re-queue
check_proc_info_worker_proc :: proc(data: rawptr) -> int {
	// Cooperative cancellation: the error cap was hit on some thread. Instead of the C++
	// exit(1) (see CPP_DEVIATIONS.md [EMBED-1]) every worker drops its remaining task so the
	// pool drains and thread_pool_wait() returns promptly. Bailing here - before the
	// parent-not-ready re-queue below - is what guarantees the queue actually empties rather
	// than re-feeding itself.
	if error_limit_reached() {
		return 1
	}

	// In C++, this retrieves per-worker data via current_thread_index()
	// C++ Reference: checker.cpp check_proc_info_worker_proc
	thread_idx := current_thread_index()
	wd := &check_procedure_bodies_worker_data[thread_idx]
	untyped := &wd.untyped
	c := wd.c

	// Cast the data pointer to ProcInfo
	// C++ Reference: checker.cpp check_proc_info_worker_proc
	pi := cast(^Proc_Info)data

	assert(pi.decl != nil)

	// Handle nested procedure dependencies
	// C++ Reference: checker.cpp check_proc_info_worker_proc
	if pi.decl.parent != nil && pi.decl.parent.entity != nil {
		parent := pi.decl.parent.entity

		// Only check nested procedures after parent's body is checked
		// This prevents race conditions in multithreaded evaluation
		// C++ Reference: checker.cpp check_proc_info_worker_proc
		if parent.kind == .Procedure && !sync.atomic_load(&parent.proc_body_checked) {
			// C++ Reference: checker.cpp check_proc_info_worker_proc
			//     Type *pt = base_type(parent->type);
			//     if (!pt->Proc.is_polymorphic || pt->Proc.is_poly_specialized) {
			//
			// THIS GATE WAS MISSING. Without it the re-queue below is unconditional whenever the
			// parent's body is unchecked, and for a parent that is polymorphic and NOT
			// poly-specialized that condition never clears -- an uninstantiated generic's body is
			// never checked, so the task re-queues itself forever. C++ deliberately FALLS THROUGH
			// in that case and checks the nested body now.
			//
			// REACHABILITY MEASURED (tick 136): THIS GATE IS HOT. A hit counter recorded 25042 hits on
			// a SIX-LINE cell, 135722 on core/fmt and 281148 on core/odin/checker, which is consistent
			// with it sitting inside the re-queue/wait spin rather than being an edge case. So the
			// guard is load-bearing on the ordinary threaded path and porting it was necessary, not
			// merely defensible.
			// STILL UNMEASURED, and the distinction matters: the LIVELOCK needs this gate AND the
			// specific condition inside it. Gate reachability is established; the combination is not.
			// The three wit_polynest shapes all complete with rc=0 and outputs matching the oracle, so
			// no hang has been observed in either compiler.
			//
			// A missing variant is treated as NOT polymorphic, which is the conservative reading:
			// it keeps C++'s re-queue behaviour rather than silently skipping the wait.
			is_poly := false
			if parent.type != nil {
				if pt, ok := base_type(parent.type).variant.(Type_Proc); ok {
					is_poly = pt.is_polymorphic && !pt.is_poly_specialized
				}
			}
			if !is_poly {
				// Re-queue this task for later (parent not ready)
				// C++ Reference: checker.cpp check_proc_info_worker_proc
				thread_pool_add_task(check_proc_info_worker_proc, pi)
				return 1 // Failure/retry
			}
		}
	}

	// Clear untyped map before checking
	// C++ Reference: checker.cpp check_proc_info_worker_proc
	clear(untyped)

	// Check the procedure
	// C++ Reference: checker.cpp check_proc_info_worker_proc
	if check_proc_info(c, pi, untyped) {
		// Success: increment atomic counter
		// C++ Reference: checker.cpp check_proc_info_worker_proc
		sync.atomic_add(&total_bodies_checked, 1)
		return 0 // Success
	}

	return 1 // Failure
}

// ======================================================================================
// WORKER INITIALIZATION
// C++ Reference: checker.cpp check_init_worker_data
// ======================================================================================

// check_init_worker_data initializes per-worker thread data for parallel checking
// C++ Reference: checker.cpp check_init_worker_data (check_init_worker_data)
//
// Allocates and initializes worker data structures for each thread in the thread pool.
// Each worker gets its own Checker pointer and untyped expression map to avoid contention.
//
// Initializes worker data for all threads in the thread pool
check_init_worker_data :: proc(c: ^Checker) {
	// Get thread count from global thread pool
	// C++ Reference: checker.cpp check_init_worker_data
	// u32 thread_count = cast(u32)global_thread_pool.threads.count;
	thread_count := 1
	if global_thread_pool != nil {
		thread_count = global_thread_pool.thread_count
	}

	// Allocate worker data array
	// C++ Reference: checker.cpp check_init_worker_data
	// check_procedure_bodies_worker_data = permanent_alloc_array<CheckProcedureBodyWorkerData>(thread_count)
	check_procedure_bodies_worker_data = make([]Check_Procedure_Body_Worker_Data, thread_count)

	// Initialize each worker's data
	// C++ Reference: checker.cpp check_init_worker_data
	for i in 0 ..< thread_count {
		check_procedure_bodies_worker_data[i].c = c
		check_procedure_bodies_worker_data[i].untyped = make(map[^ast.Expr]^Expr_Info)
	}
}

// ======================================================================================
// MAIN PROCEDURE CHECKING ENTRY POINT
// C++ Reference: checker.cpp check_procedure_bodies
// ======================================================================================

// check_procedure_bodies is the main entry point for checking all queued procedure bodies
// C++ Reference: checker.cpp check_procedure_bodies
//
// This function coordinates procedure body checking, supporting both:
// - Sequential mode (single-threaded, simple loop)
// - Parallel mode (worker threads, task queue)
//
// The mode is determined by:
// - Thread pool size (from global_thread_pool.threads.count)
// - Build flag (build_context.no_threaded_checker)
check_procedure_bodies :: proc(c: ^Checker) {
	assert(c != nil)

	// Determine thread count
	// C++ Reference: checker.cpp check_procedure_bodies
	thread_count := 1
	if global_thread_pool != nil && !build_context.no_threaded_checker {
		thread_count = global_thread_pool.thread_count
	}

	// Sequential mode (single-threaded)
	// C++ Reference: checker.cpp check_procedure_bodies
	if thread_count == 1 {
		// Use worker_data[0]'s untyped map
		// C++ Reference: checker.cpp check_procedure_bodies
		untyped := &check_procedure_bodies_worker_data[0].untyped

		// Process all procedures in procs_to_check array
		// C++ Reference: checker.cpp check_procedure_bodies
		// THE BOUND MUST BE RE-READ EVERY ITERATION. C++ spells this `for_array(i,
		// c->procs_to_check)`, and for_array_off (common.cpp:39) expands to
		//     for (isize i = 0; i < (array).count; i++)
		// which reloads `.count` on every test. That is load-bearing here, not incidental:
		// consume_proc_info CHECKS A BODY, and checking a body that contains a procedure literal
		// reaches check_procedure_later (check_expr.cpp:7380). On this path
		// global_procedure_body_in_worker_queue is FALSE -- it is only set on the parallel branch
		// below -- so check_procedure_later takes its `else` arm and APPENDS to procs_to_check.
		// C++ therefore consumes those newly-discovered bodies in the SAME loop, and keeps going
		// until the array stops growing.
		//
		// `for i in 0 ..< len(c.procs_to_check)` evaluates its bound ONCE, so the port checked only
		// the entries present when the loop started -- and then `clear` a few lines down DISCARDED
		// every body appended during the pass. MEASURED, not assumed: a probe binary printing the
		// count either side of this loop showed the array growing 302 -> 493 on a two-proc witness,
		// 323 -> 522 on core/crypto, and 3325 -> 8220 on core/odin/parser. Thousands of bodies per
		// package were being dropped here.
		//
		// The port still reached the right ANSWER because check_unchecked_bodies sweeps up
		// whatever this loop missed, which is exactly why no corpus cell and no parity package ever
		// showed it. That makes this a PHASE divergence rather than a missing-diagnostic one: the
		// bodies were checked, in the wrong phase, via the safety net rather than the main loop.
		for i := 0; i < len(c.procs_to_check); i += 1 {
			// Cooperative cancellation, mirroring the worker path below: once the error cap
			// is hit every further diagnostic is dropped, so there is nothing to gain from
			// checking the remaining bodies. See CPP_DEVIATIONS.md [EMBED-1].
			if error_limit_reached() {
				break
			}
			consume_proc_info(c, c.procs_to_check[i], untyped)
		}

		// Clear the procs_to_check array
		// C++ Reference: checker.cpp check_procedure_bodies
		clear(&c.procs_to_check)

		// Debug output
		// C++ Reference: checker.cpp check_procedure_bodies
		debugf("Total Procedure Bodies Checked: %d\n", sync.atomic_load(&total_bodies_checked))

		return
	}

	// Parallel mode (multi-threaded)
	// C++ Reference: checker.cpp check_procedure_bodies

	// Set global flag to indicate worker queue is active
	// C++ Reference: checker.cpp check_procedure_bodies
	sync.atomic_store(&global_procedure_body_in_worker_queue, true)

	// Add all procedures to worker task queue
	// C++ Reference: checker.cpp check_procedure_bodies
	prev_procs_to_check_count := len(c.procs_to_check)
	for i in 0 ..< len(c.procs_to_check) {
		thread_pool_add_task(check_proc_info_worker_proc, c.procs_to_check[i])
	}
	assert(prev_procs_to_check_count == len(c.procs_to_check))
	clear(&c.procs_to_check)

	// Wait for all workers to complete
	// C++ Reference: checker.cpp check_procedure_bodies
	thread_pool_wait()

	// Clear worker queue flag
	// C++ Reference: checker.cpp check_procedure_bodies
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)

	// Debug output
	debugf("Total Procedure Bodies Checked: %d\n", sync.atomic_load(&total_bodies_checked))
}

// ======================================================================================
// CORE PROCEDURE CHECKING LOGIC
// C++ Reference: checker.cpp check_proc_info
// ======================================================================================

// check_proc_info validates and checks a single procedure's body
// C++ Reference: checker.cpp check_proc_info
//
// This is the core procedure checking function. It performs:
// 1. Procedure state validation (mutex-protected state machine)
// 2. Polymorphic procedure validation
// 3. Procedure tag processing (#bounds_check, #type_assert, etc.)
// 4. Actual body checking via check_proc_body
// 5. Entity flag updates based on result
// 6. Dependency resolution (queue unchecked dependencies)
//
// Returns:
//   true if checking completed successfully
//   false if deferred or failed
//
// Parameters:
//   c: Checker context
//   pi: Procedure information to check
//   untyped: Map for storing untyped expression info (may be nil)
check_proc_info :: proc(c: ^Checker, pi: ^Proc_Info, untyped: ^map[^ast.Expr]^Expr_Info) -> bool {
	// Early validation
	// C++ Reference: checker.cpp check_proc_info
	if pi == nil {
		return false
	}
	if pi.type == nil {
		return false
	}

	// Check procedure state with mutex protection
	// C++ Reference: checker.cpp check_proc_info
	decl := pi.decl
	if decl == nil {
		return false
	}

	// State machine transition, guarded by this declaration's own mutex.
	// C++ Reference: checker.cpp check_proc_info - the C++ MUTEX_GUARD is scoped to exactly this
	// block and locks DeclInfo::proc_checked_mutex, not a global.
	//
	// The guard MUST NOT extend over check_proc_body below. It is only here to make
	// "read the state, and claim it if it is Unchecked" indivisible, so that two threads
	// racing on the same declaration cannot both start checking it. Holding it any longer
	// would serialise every procedure body in the program onto one thread - and, because
	// the checker's internal invariants are enforced with panic/assert (which end the
	// thread via runtime.trap() without unwinding), any such failure inside the body would
	// leave the lock held forever and wedge every other thread that reaches this point.
	// A global mutex here used to do both.
	{
		sync.lock(&decl.proc_checked_mutex)
		defer sync.unlock(&decl.proc_checked_mutex)

		// State machine check
		// C++ Reference: checker.cpp check_proc_info
		state := sync.atomic_load(&decl.proc_checked_state)
		#partial switch state {
		case .In_Progress:
			// Currently being checked (by another thread in parallel mode)
			// C++ Reference: checker.cpp check_proc_info
			return false

		case .Checked:
			// Already checked successfully
			// C++ Reference: checker.cpp check_proc_info
			if decl.entity != nil {
				assert(sync.atomic_load(&decl.entity.proc_body_checked))
			}
			return true

		case .Unchecked:
			// Proceed with checking
			// C++ Reference: checker.cpp check_proc_info
			break
		}

		// Claim the procedure. From here on this thread owns the body check, and every
		// exit path below must move the state off In_Progress.
		// C++ Reference: checker.cpp check_proc_info
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.In_Progress)
	}

	// Validate procedure type
	// C++ Reference: checker.cpp check_proc_info
	assert(pi.type.kind == .Proc)
	pt, pt_ok := &pi.type.variant.(Type_Proc)
	if !pt_ok {
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
		return false
	}

	name := pi.token.text

	// Check for unspecialized polymorphic procedures
	// C++ Reference: checker.cpp check_proc_info
	if pt.is_polymorphic && !pt.is_poly_specialized {
		token := pi.token
		if pi.poly_def_node != nil {
			// Use polymorphic definition node's token if available
			// C++ Reference: checker.cpp check_proc_info
			token = ast_token(pi.poly_def_node)
		}

		// Error: Cannot check unspecialized polymorphic procedures
		// C++ Reference: checker.cpp check_proc_info
		error(token, "Unspecialized polymorphic procedure '%s'", name)

		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
		return false
	}

	// Skip unused specialized polymorphic procedures
	// C++ Reference: checker.cpp check_proc_info
	if pt.is_polymorphic && pt.is_poly_specialized {
		e := pi.decl.entity
		assert(e != nil)
		if .Used not_in e.flags {
			// Never used, don't check
			// C++ Reference: checker.cpp check_proc_info
			// NOTE: This may need to be checked later if used elsewhere
			sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
			return false
		}
	}

	// Create and setup checker context
	// C++ Reference: checker.cpp check_proc_info
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	reset_checker_context(&ctx, pi.file)
	ctx.decl = pi.decl

	// Process procedure tags
	// C++ Reference: checker.cpp check_proc_info
	tags := pi.tags

	// #940: THESE FOUR TESTS WERE ALL WRONG, and the comment that stood here said why it was
	// expected to work: "Proc_Tag values are already 1<<n". THEY ARE NOT. `Proc_Tag` is
	// `ast.Proc_Tag` (checker.odin), a plain enum with SEQUENTIAL values -- Bounds_Check=0,
	// No_Bounds_Check=1, Type_Assert=2, No_Type_Assert=3 -- while `tags` is a `bit_set` transmuted
	// to u64, where the flag lives at BIT n. Masking with the ordinal read the wrong bit or none:
	//
	//     bounds_check    tags & 0  -> ALWAYS FALSE
	//     no_bounds_check tags & 1  -> tests the Bounds_Check bit
	//     type_assert     tags & 2  -> tests the No_Bounds_Check bit
	//     no_type_assert  tags & 3  -> tests Bounds_Check OR No_Bounds_Check
	//
	// So `f :: proc() #no_bounds_check` (bit 1) left no_bounds_check FALSE and turned type_assert
	// TRUE. MEASURED: `_ = a[9]` on a `[4]int` under `#no_bounds_check` was reported out of bounds
	// where the oracle is silent (`boundscheck` cell bc.NOBOUNDS.outrange). The STATEMENT form
	// `#no_bounds_check { ... }` was always correct -- it goes through check_stmt's state_flags
	// path and never touches this conversion -- which is why only the procedure form diverged.
	//
	// Testing the bit_set directly removes the ordinal-vs-bit confusion at the root rather than
	// spelling `1 << u64(...)` four times.
	// C++ Reference: checker.cpp check_proc_info
	tag_set := transmute(ast.Proc_Tags)u32(tags)
	bounds_check := .Bounds_Check in tag_set
	no_bounds_check := .No_Bounds_Check in tag_set
	type_assert := .Type_Assert in tag_set
	no_type_assert := .No_Type_Assert in tag_set

	// Apply bounds checking flags
	// C++ Reference: checker.cpp check_proc_info
	if bounds_check {
		ctx.state_flags += {.Bounds_Check}
		ctx.state_flags -= {.No_Bounds_Check}
	} else if no_bounds_check {
		ctx.state_flags += {.No_Bounds_Check}
		ctx.state_flags -= {.Bounds_Check}
	}

	// Apply type assertion flags
	// C++ Reference: checker.cpp check_proc_info
	if type_assert {
		ctx.state_flags += {.Type_Assert}
		ctx.state_flags -= {.No_Type_Assert}
	} else if no_type_assert {
		ctx.state_flags += {.No_Type_Assert}
		ctx.state_flags -= {.Type_Assert}
	}

	// Check the procedure body
	// C++ Reference: checker.cpp check_proc_info
	body_was_checked := check_proc_body(&ctx, pi.token, pi.decl, pi.type, pi.body)

	// Update entity state based on checking result
	// C++ Reference: checker.cpp check_proc_info
	if body_was_checked {
		// Success: Mark as checked (atomic store for thread safety)
		// C++ Reference: checker.cpp check_proc_info
		//
		// DEVIATION (ordering): C++ stores ProcCheckedState_Checked first and sets
		// EntityFlag_ProcBodyChecked second. It can afford to, because its
		// proc_checked_mutex is held for the whole of check_proc_body_for_proc_info - so
		// no other thread can be inside the `case ProcCheckedState_Checked` arm that
		// asserts on the flag (checker.cpp check_proc_info) while this window is open.
		//
		// This port deliberately narrows that guard to the state transition alone (see the
		// long comment above the claim, and CPP_DEVIATIONS): the C++ shape would serialise
		// every body onto one thread and, worse, would leave the lock held forever if an
		// internal assert tripped inside a body. The cost is that the window IS observable
		// here, so the two writes are swapped: the flag is published before the state, and
		// a reader that sees .Checked is therefore guaranteed to see the flag. Both writes
		// are sequentially consistent, so the order is not reordered by the compiler or the
		// CPU. A reader that sees the flag while the state is still .In_Progress is
		// harmless - nothing keys off the flag alone.
		if pi.body != nil {
			e := pi.decl.entity
			if e != nil {
				// Atomic flag set for thread safety
				sync.atomic_store(&e.proc_body_checked, true)
			}
		}
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Checked)
	} else {
		// Failure: Mark as unchecked (atomic store for thread safety)
		// C++ Reference: checker.cpp check_proc_info
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
		if pi.body != nil {
			e := pi.decl.entity
			if e != nil {
				// Atomic flag clear for thread safety
				sync.atomic_store(&e.proc_body_checked, false)
			}
		}
	}

	// Add untyped expressions to global queue
	// C++ Reference: checker.cpp check_proc_info
	add_untyped_expressions(&c.info, ctx.untyped)

	// Check dependencies and queue unchecked procedures
	// C++ Reference: checker.cpp check_proc_info
	// Thread-safe read access to dependencies
	sync.rw_mutex_shared_lock(&ctx.decl.deps_mutex)
	defer sync.rw_mutex_shared_unlock(&ctx.decl.deps_mutex)

	for dep in ctx.decl.deps {
		if dep != nil && dep.kind == .Procedure {
			if !sync.atomic_load(&dep.proc_body_checked) {
				check_procedure_later_from_entity(c, dep, "")
			}
		}
	}

	return true
}

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================


// make_checker_context is defined in check_collect.odin

// destroy_checker_context cleans up a checker context
// C++ Reference: checker.cpp destroy_checker_context (destroy_checker_context)
//
// Cleans up resources owned by the Checker_Context:
// - type_path: OWNED by the root context returned from make_checker_context, freed here
// - type_and_value_map: DELETED - now stored in Checker_Info, not owned by context
// - untyped: Pointer to external map, NOT freed (managed elsewhere)
// - Other fields: Primitives or pointers to external resources (not owned)
//
// Only call this on a context produced by make_checker_context, never on a `c := ctx^`
// copy: copies deliberately share the root's type path, exactly as in C++.
destroy_checker_context :: proc(ctx: ^Checker_Context) {
	// C++ line 1696: destroy_checker_type_path(ctx->type_path)
	// The path was allocated from the checker's allocator by make_checker_context.
	if ctx.type_path != nil {
		allocator := ctx.checker != nil ? ctx.checker.allocator : context.allocator
		destroy_checker_type_path(ctx.type_path, allocator)
		ctx.type_path = nil
	}

	// Note: ctx.untyped is a pointer to an external map (^map[^ast.Expr]^Expr_Info)
	// It's not owned by this context, so we don't delete it.
	// It either points to:
	// - Worker data untyped map (check_procedure_bodies_worker_data[i].untyped)
	// - c.info.global_untyped
	// Both are managed by their respective owners.

	// Note: All other fields are either:
	// - Primitives (ints, bools, enums, etc.) - no cleanup needed
	// - Pointers to external resources (checker, info, file, pkg, scope, etc.) - not owned
	// - Flags and state (bit_set types) - no cleanup needed
}

// reset_checker_context is defined in check_import_export.odin

// add_untyped_expressions adds untyped expressions to the global queue
// C++ Reference: checker.cpp add_untyped_expressions
add_untyped_expressions :: proc(info: ^Checker_Info, untyped: ^map[^ast.Expr]^Expr_Info) {
	if untyped == nil {
		return
	}

	// Enqueue all untyped expressions to global queue
	// C++ Reference: checker.cpp add_untyped_expressions
	for expr, expr_info in untyped {
		if expr != nil && expr_info != nil {
			ue_info := Untyped_Expr_Info {
				expr = expr,
				info = expr_info,
			}
			queue.mpsc_enqueue(&info.checker.global_untyped_queue, ue_info)
		}
	}

	// Clear the map
	// C++ Reference: checker.cpp add_untyped_expressions
	clear(untyped)
}

// ======================================================================================
// PROCEDURE BODY CHECKING
// C++ Reference: check_decl.cpp:2003-2198
// ======================================================================================

// Proc_Using_Var pairs a using parameter entity with its generated using variable
// C++ Reference: check_decl.cpp:2003-2006
Proc_Using_Var :: struct {
	e:    ^Entity, // Original parameter entity (C++ line 2004)
	uvar: ^Entity, // Generated using variable entity (C++ line 2005)
}

// evaluate_where_clauses checks that all where clauses evaluate to true
// C++ Reference: check_expr.cpp check_call_arguments_internal
//
// This function evaluates each where clause in a polymorphic procedure or type
// to verify they are constant boolean expressions that evaluate to true.
//
// Parameters:
//   ctx: Checker context
//   call_expr: Optional call site for error reporting (may be nil)
//   scope: Scope for displaying polymorphic type definitions in errors
//   clauses: Slice of where clause AST expressions
//   print_err: Whether to print error messages on failure
//
// Returns:
//   true if all clauses pass, false if any fail
evaluate_where_clauses :: proc(ctx: ^Checker_Context, call_expr: ^ast.Expr, scope: ^Scope, clauses: []^ast.Expr, print_err: bool) -> bool {
	// C++ Reference: check_expr.cpp evaluate_where_clauses
	if clauses == nil || len(clauses) == 0 {
		return true
	}

	// Check each clause
	// C++ Reference: check_expr.cpp evaluate_where_clauses
	for clause in clauses {
		operand := Operand{}
		check_expr(ctx, &operand, clause)

		// Must be a constant
		// C++ Reference: check_expr.cpp evaluate_where_clauses
		if operand.mode != .Constant {
			if print_err {
				error(clause, "'where' clauses expect a constant boolean evaluation")
				if call_expr != nil {
					error(call_expr, "at caller location")
				}
			}
			return false
		}

		// Must be a boolean
		// C++ Reference: check_expr.cpp evaluate_where_clauses
		value_bool, is_bool := operand.value.(bool)
		if !is_bool {
			if print_err {
				error(clause, "'where' clauses expect a constant boolean evaluation")
				if call_expr != nil {
					error(call_expr, "at caller location")
				}
			}
			return false
		}

		// Must evaluate to true
		// C++ Reference: check_expr.cpp evaluate_where_clauses
		if !value_bool {
			if print_err {
				// C++ opens an ERROR_BLOCK here (check_expr.cpp evaluate_where_clauses) so the header, the
				// definition list and the caller-location line are flushed together. Without
				// it the unblocked error_line output raced ahead of the error() -- which goes
				// through the collector and is position-sorted -- so the continuation lines
				// appeared at the very top of the output, detached from their own diagnostic.
				begin_error_block()
				defer end_error_block()

				// Display error with clause expression
				// C++ Reference: check_expr.cpp evaluate_where_clauses
				clause_str := expr_to_string(clause)
				defer delete(clause_str)
				error(clause, "'where' clause evaluated to false:\n\t%s", clause_str)

				// Display polymorphic definitions from scope
				// C++ Reference: check_expr.cpp evaluate_where_clauses
				if scope != nil {
					print_count := 0

					// C++ (check_expr.cpp evaluate_where_clauses) walks scope->elements in SLOT order.
					//
					// Iterating an Odin map directly made this block nondeterministic: ten runs
					// of the SAME binary on the SAME input produced SIX different orderings.
					// sweep_det.sh runs under `setarch -R`, so the sweep cannot see it.
					// LEDGER 277 therefore sorted by name and recorded C++'s order as "a
					// property of its hash table and not reproducible".
					//
					// #214a / LEDGER 353: that is wrong. Scope::elements is ScopeMap, whose hash
					// is over the string CONTENTS, so its layout is a pure function of the names
					// and their insertion order. scope_map_slot_order (scope.odin) reproduces it.
					// This also fixes the block's PRESENCE, not just its order: the
					// "With the following definitions:" header below fires only when slot 0
					// holds a Constant, and that header truncates the block (see there).
					//
					// Insertion order for a polymorphic parameter scope is source order, so the
					// entities are put back into declaration order before the table is simulated.
					ordered := make([dynamic]^Entity, 0, len(scope.elements), context.temp_allocator)
					for _, e in scope.elements {
						append(&ordered, e)
					}
					slice.sort_by(ordered[:], proc(a, b: ^Entity) -> bool {
						if a.token.pos.file != b.token.pos.file {
							return a.token.pos.file < b.token.pos.file
						}
						if a.token.pos.offset != b.token.pos.offset {
							return a.token.pos.offset < b.token.pos.offset
						}
						return a.token.text < b.token.text
					})
					ordered_slots := scope_map_slot_order(ordered[:], context.temp_allocator)

					// Iterate through scope elements and display TypeName and Constant entities
					// C++ Reference: check_expr.cpp evaluate_where_clauses
					for e in ordered_slots {
						#partial switch e.kind {
						case .Type_Name:
							// Display type definitions: name :: type;
							// C++ Reference: check_expr.cpp evaluate_where_clauses
							// Note: The C++ comment says to print header only on first entity,
							// but then doesn't actually use that check (line 6752 is commented out)
							// The header fires from THIS arm too now. It used to be commented out
							// in C++'s Entity_TypeName case while still bumping print_count, so a
							// type name printed first suppressed the header for the whole block --
							// filed as #174, fixed upstream and merged (PR #7222). Both arms now
							// carry it. LEDGER #385.
							if print_count == 0 {
								error_line("  \n\tWith the following definitions:\n")
							}
							type_str := type_to_string(e.type)
							error_line("\t\t%s :: %s;\n", e.token.text, type_str)
							print_count += 1

						case .Constant:
							// Display constant definitions
							// C++ Reference: check_expr.cpp evaluate_where_clauses
							// C++ Reference: check_expr.cpp evaluate_where_clauses.
							//
							// THE TWO LEADING SPACES ARE LOAD-BEARING, and they are the whole of
							// the upstream fix. The old header began with "\n", which put a BLANK
							// LINE in the message; print_errors_standard breaks on the first empty
							// line -- faithfully, C++ error.cpp print_all_errors does the same -- so emitting
							// the header TRUNCATED the rest of the block. The binding lines and
							// "at caller location" were built and then discarded at print time.
							// LEDGER 334 measured that and #185 could not explain it.
							//
							// Upstream now writes "  \n\tWith the following definitions:\n". Two
							// spaces before the newline mean the line is NOT empty, so the break
							// never fires and the block survives intact. That also retires the
							// trade-off this comment used to record: the port sorts scope elements
							// by name for determinism (LEDGER 277) and could not track C++'s hash
							// order, so keeping the header matched 8 probes and missed 4-5. With
							// truncation gone the hash order no longer decides what SURVIVES, only
							// what comes first. LEDGER #385.
							if print_count == 0 {
								error_line("  \n\tWith the following definitions:\n")
							}

							// Get the constant value as a string
							value_str := exact_value_to_string(e.variant.(Entity_Constant).value)
							defer delete(value_str)

							if is_type_untyped(e.type) {
								// Untyped constant: name :: value;
								// C++ Reference: check_expr.cpp evaluate_where_clauses
								error_line("\t\t%s :: %s;\n", e.token.text, value_str)
							} else {
								// Typed constant: name : type : value;
								// C++ Reference: check_expr.cpp evaluate_where_clauses
								type_str := type_to_string(e.type)
								error_line("\t\t%s : %s : %s;\n", e.token.text, type_str, value_str)
							}
							print_count += 1
						}
					}
				}

				// C++ check_expr.cpp evaluate_where_clauses. Unlike the two "expects a constant boolean
				// evaluation" branches above (C++ 7145/7149), which DO emit a second
				// diagnostic, this branch writes a CONTINUATION line carrying the position
				// itself: error_line("%s at caller location\n", ...). The port used error()
				// here too, which prefixed "Error: " and incremented the error count, so a
				// single failing clause was reported as two errors instead of one.
				if call_expr != nil {
					error_line("%s at caller location\n", token_pos_to_string(ast_token_pos(call_expr)))
				}
			}
			return false
		}

		// Style check: prefer comma over &&
		// C++ Reference: check_expr.cpp evaluate_where_clauses
		if ast_file_vet_style(ctx.file) {
			c := unparen_expr(clause)
			// Check if it's a binary expression with Cmp_And (&&)
			// C++ Reference: check_expr.cpp evaluate_where_clauses
			if binary, ok := c.derived.(^ast.Binary_Expr); ok {
				if binary.op.kind == .Cmp_And {
					// Error: Prefer comma over &&
					// C++ Reference: check_expr.cpp evaluate_where_clauses
					error(c, "Prefer to separate 'where' clauses with a comma rather than '&&'")

					// Show suggestion with left and right parts
					// C++ Reference: check_expr.cpp evaluate_where_clauses
					x := expr_to_string(binary.left)
					defer delete(x)
					y := expr_to_string(binary.right)
					defer delete(y)
					error_line("\tSuggestion: '%s, %s'\n", x, y)
				}
			}
		}
	}

	return true
}

// check_vet_flags_from_context retrieves vet flags for current context
// C++ Reference: checker.cpp:543-552
check_vet_flags_from_context :: proc(ctx: ^Checker_Context) -> Vet_Flag {
	file := ctx.file

	// If no file, try to get from current procedure declaration's entity
	// C++ Reference: checker.cpp:545-549
	if file == nil && ctx.curr_proc_decl != nil && ctx.curr_proc_decl.entity != nil {
		file = ctx.curr_proc_decl.entity.file
	}

	return ast_file_vet_flags(file)
}

// check_vet_flags_from_node retrieves vet flags from an AST node
// C++ Reference: checker.cpp check_vet_flags
// Note: In Odin AST, nodes don't store their file, so this always returns empty flags
// Callers should use check_vet_flags_from_context instead
// C++ Reference: checker.cpp check_vet_flags.
//
//	gb_internal u64 check_vet_flags(Ast *node) {
//		AstFile *file = node->file();
//		return ast_file_vet_flags(file);
//	}
//
// This previously returned `{}` unconditionally, on the stated grounds that "nodes don't have a
// file() method like C++". They effectively do: get_file_from_node resolves the owning file
// through node.pos.file, which the tokenizer stamps on every position (see file_helpers.odin for
// why that is the correct identity and node.file_id is not). Returning an empty set here did not
// merely lose per-file `#+vet` precision -- it disabled the ENTIRE proc-body vet surface, because
// the sole caller (check_proc.odin, after check_close_scope) passes the result straight to
// check_scope_usage as its only vet gate. Every unused variable, unused procedure, shadowed
// declaration and using-shadow inside any procedure body went unreported tree-wide.
//
// Resolving to nil is not a failure mode that needs guarding here: ast_file_vet_flags(nil) falls
// through to in_vet_packages(nil), which returns true, yielding build_context.vet_flags -- exactly
// what C++ does when node->file() yields null.
check_vet_flags_from_node :: proc(info: ^Checker_Info, node: ^ast.Node) -> Vet_Flag {
	file := get_file_from_node(info, node)
	return ast_file_vet_flags(file)
}

// check_vet_flags is overloaded to accept context or node
check_vet_flags :: proc {
	check_vet_flags_from_context,
	check_vet_flags_from_node,
}

// in_vet_packages checks if a file's package is in the vet packages list.
//
// C++ Reference: parser.cpp in_vet_packages.
//
// Every bail returns TRUE, i.e. "vet it": an unknown package is vetted, not skipped.
//
// The NAME LOOKUP used to be just `file.pkg.name`, which is empty for a file whose package
// has not been named yet -- and an empty name is never a member of the set, so
// `-vet-packages:foo` silently skipped exactly those files. Upstream fixed it (the commit
// is "Fix -vet-packages not working in certain cases") by falling back to the package
// DECLARATION's own identifier token, and by treating a still-empty name as "vet it"
// rather than as a failed lookup. The nil pkg_decl guard is new for the same reason.
// LEDGER #386.
in_vet_packages :: proc(file: ^ast.File) -> bool {
	// C++ Reference: parser.cpp in_vet_packages
	if file == nil {
		return true
	}

	// C++ Reference: parser.cpp in_vet_packages
	if file.pkg == nil {
		return true
	}

	// C++ Reference: parser.cpp in_vet_packages
	if file.pkg_decl == nil {
		return true
	}

	// C++ Reference: parser.cpp in_vet_packages. Empty vet_packages means vet all packages.
	if len(build_context.vet_packages) == 0 {
		return true
	}

	// C++ Reference: parser.cpp in_vet_packages.
	//
	// C++ tests `name_token.kind == Token_Ident` on the package declaration's NAME TOKEN.
	// The port's Package_Decl keeps only the name TEXT (parser.odin:299 stores
	// `pkg_name.text` whatever kind the token turned out to be), and its `token` field is
	// the `package` keyword, so the kind is not recoverable here. is_string_an_identifier
	// decides the same question from the text: on a malformed declaration the stored text
	// is whatever token was found -- `123`, say -- which is not an identifier, so the name
	// stays empty and the guard below vets the file, exactly as C++ does.
	pkg_name := ""
	if len(file.pkg.name) > 0 {
		pkg_name = file.pkg.name
	} else if is_string_an_identifier(file.pkg_decl.name) {
		pkg_name = file.pkg_decl.name
	}

	// C++ Reference: parser.cpp in_vet_packages
	if len(pkg_name) == 0 {
		return true
	}

	return pkg_name in build_context.vet_packages
}

// ast_file_vet_flags gets vet flags from a file
// C++ Reference: parser.cpp:18-28
//
// Returns the active vet flags for a file, checking:
// 1. File-specific vet flags (if vet_flags_set is true)
// 2. Build context flags (if file is in vet packages list)
// 3. Default: 0 (no vet checking)
ast_file_vet_flags :: proc(file: ^ast.File) -> Vet_Flag {
	// Check for file-specific vet flags first
	// C++ Reference: parser.cpp:19-21
	if file != nil && file.vet_flags_set {
		// ast.Vet_Flags and Vet_Flag are both distinct bit_set[Vet_Flag_Bit; u64]
		return transmute(Vet_Flag)file.vet_flags
	}

	// Check if file is in vet packages list
	// C++ Reference: parser.cpp:23-26
	found := in_vet_packages(file)
	if found {
		return build_context.vet_flags
	}

	// No vetting for this file
	return {} // Empty bit_set = no vet flags
}

// ast_file_vet_style checks if style vetting is enabled for a file
// C++ Reference: parser.cpp:30-31
ast_file_vet_style :: proc(file: ^ast.File) -> bool {
	flags := ast_file_vet_flags(file)
	return .Style in flags
}

// ast_file_vet_deprecated checks if deprecation vetting is enabled for a file
// C++ Reference: parser.cpp:56-58
//
// Gates the severity of the `core:` -> `base:` import deprecation: error under
// `#+vet deprecated`, warning otherwise (parser.cpp:6241-6246).
ast_file_vet_deprecated :: proc(file: ^ast.File) -> bool {
	flags := ast_file_vet_flags(file)
	return .Deprecated in flags
}

// scope_insert_no_mutex is defined in scope.odin

// add_deps_from_child_to_parent propagates dependencies from nested to parent proc
// C++ Reference: check_decl.cpp:1972-2001
//
// This function copies all dependencies and type_info dependencies from a nested
// procedure's declaration to its parent procedure's declaration. This is needed
// because nested procedures (lambdas) can reference entities that the parent
// procedure must also depend on for proper dependency analysis.
//
// IT DOES NOT SKIP FILE/PKG/GLOBAL PARENTS, DESPITE WHAT THE REFERENCE'S OWN COMMENT SAYS.
// LEDGER #1210. src/check_decl.cpp:2222-2225 reads:
//
//     if (decl && decl->parent) {
//         Scope *ps = decl->parent->scope;
//         if (ps->flags & (ScopeFlag_File & ScopeFlag_Pkg & ScopeFlag_Global)) {
//             return;
//
// The three flags are joined with `&`, not `|`. They are distinct single bits --
// ScopeFlag_Pkg = 1<<1, ScopeFlag_Global = 1<<3, ScopeFlag_File = 1<<4 (src/checker.hpp:531-534)
// -- so `16 & 2 & 8` is 0, `ps->flags & 0` is 0, and the early return is UNREACHABLE. The
// reference propagates unconditionally, for every parent scope kind.
//
// The port used to spell the guard `||`, which is what the reference's comment describes and
// what a reader would assume the code does. That made it fire for exactly the case the guard
// was written to think about: a proc literal nested inside a TOP-LEVEL procedure, whose parent
// decl was created at collect time with the FILE scope. So every such literal's dependencies
// were dropped instead of propagated -- silently, because a dependency that is never recorded
// emits no diagnostic.
//
// Ported as the reference BEHAVES, not as it reads: this is the "a reference quirk is the
// contract" rule, and the quirk here is not a crash. Filed upstream separately, because the
// reference's intent and its code disagree and only they can say which one they meant.
//
// MEASURED INERT IN THE PORT TODAY, AND THE REASON MATTERS. Instrumenting this function to
// print `decl.parent.scope.flags` on every call, over $S/phase2/wit_nestdep250c, produced
// {Proc} or {Proc, Context_Defined} on ALL ~300 calls and File/Pkg/Global on none. So the old
// `||` guard never fired and removing it moved nothing: the mindep dumps before and after are
// BYTE-IDENTICAL (in_set=205 both), with unref_global/unref_proc at in=0 confirming the
// instrument discriminates reachability rather than marking everything live.
//
// It is unreachable because of a SECOND divergence, not because the case cannot arise.
// `decl.parent` is non-nil only for a decl minted while ctx.decl was non-nil, and the port
// leaves ctx.decl NIL at file scope -- C++ puts the package's Decl_Info there
// (checker.cpp:1702, fed by checker.cpp:7693), the port has no writer for
// info.package_decl_infos at all. So the port's file-scope decls have parent == nil and leave
// at the check above, while C++'s have the package decl as parent, whose scope carries
// ScopeFlag_Pkg.
//
// THAT IS WHY THIS EDIT HAD TO COME FIRST. If the package Decl_Info is ever wired up, every
// top-level decl acquires a Pkg-scoped parent, the `||` guard would start firing, and the port
// would begin diverging from a reference that propagates unconditionally. Removing it now makes
// that future change safe instead of silently wrong. See the disposition note on
// info.package_decl_infos for why the parent itself is a write-only sink.
add_deps_from_child_to_parent :: proc(decl: ^Decl_Info) {
	// Early validation
	// C++ Reference: check_decl.cpp:1973
	if decl == nil || decl.parent == nil {
		return
	}

	// No scope test here -- see the header comment. src/check_decl.cpp:2223's guard is dead code,
	// so the reference falls straight through to the two copy loops below for every parent.

	// Copy entity dependencies
	// C++ Reference: check_decl.cpp:1980-1988
	// Thread-safe read from child deps, write to parent deps
	{
		sync.rw_mutex_shared_lock(&decl.deps_mutex)
		sync.rw_mutex_lock(&decl.parent.deps_mutex)
		for dep in decl.deps {
			decl.parent.deps[dep] = {}
		}
		sync.rw_mutex_unlock(&decl.parent.deps_mutex)
		sync.rw_mutex_shared_unlock(&decl.deps_mutex)
	}

	// Copy type info dependencies
	// C++ Reference: check_decl.cpp:1990-1998
	// Thread-safe read from child type_info_deps, write to parent type_info_deps
	{
		sync.rw_mutex_shared_lock(&decl.type_info_deps_mutex)
		sync.rw_mutex_lock(&decl.parent.type_info_deps_mutex)
		for h, type_dep in decl.type_info_deps {
			// C++ Reference: check_decl.cpp:2100-2101 `for (auto const &tt : decl->type_info_deps)
			// type_set_add(&decl->parent->type_info_deps, tt)`. The pair carries its hash, so the
			// parent is keyed identically -- no rehash, and the incumbent is not displaced.
			if h not_in decl.parent.type_info_deps {
				decl.parent.type_info_deps[h] = type_dep
			}
		}
		sync.rw_mutex_unlock(&decl.parent.type_info_deps_mutex)
		sync.rw_mutex_shared_unlock(&decl.type_info_deps_mutex)
	}
}

// check_scope_usage checks scope for unused/shadowed variables (main entry point)
// C++ Reference: checker.cpp:849-859
//
// This function recursively checks a scope and its children for:
// - Unused variables/parameters
// - Unused procedures
// - Unused imports
// - Shadowed declarations
// - Large stack allocations
//
// Child scopes with Proc, Type, or File flags are skipped (checked separately).
check_scope_usage :: proc(c: ^Checker, scope: ^Scope, vet_flags: Vet_Flag) {
	// Check this scope
	// C++ Reference: checker.cpp check_scope_usage_internal
	check_scope_usage_internal(c, scope, vet_flags, false)

	// Recursively check child scopes (except Proc/Type/File scopes)
	// C++ Reference: checker.cpp check_scope_usage_internal
	for child := scope.head_child; child != nil; child = child.next {
		if .Proc in child.flags || .Type in child.flags || .File in child.flags {
			// These scopes are checked separately, skip them
			continue
		}
		check_scope_usage(c, child, vet_flags)
	}
}

// Vetted_Entity tracks an entity that needs vetting with context
// C++ Reference: checker.cpp (VettedEntity struct, implementation detail)
Vetted_Entity :: struct {
	kind:   Vetted_Entity_Kind,
	entity: ^Entity,
	other:  ^Entity, // For shadowing, the shadowed entity
}

Vetted_Entity_Kind :: enum {
	None,
	Unused,
	Shadowed,
	Shadowed_And_Unused,
}

// check_vet_shadowing_assignment checks if variable shadows via assignment
// C++ Reference: checker.cpp:619-640
//
// This function checks if a variable assignment is an intentional redeclaration:
// x := x          // Intentional shadowing (ignore)
// x := x if c else y  // Intentional conditional shadowing (ignore)
check_vet_shadowing_assignment :: proc(c: ^Checker, shadowed: ^Entity, node: ^ast.Node) -> bool {
	if node == nil {
		return false
	}

	// Get the expression (ast.Node is the base, we need to cast to Expr)
	// In Odin AST, all expressions derive from ast.Expr which derives from ast.Node
	expr := cast(^ast.Expr)node

	// Unwrap parentheses
	// C++ Reference: checker.cpp:620-623
	init := unparen_expr(expr)
	if init == nil {
		return false
	}

	// Check if assignment is from the shadowed variable itself
	// C++ Reference: checker.cpp:624-630
	if ident, ok := init.derived.(^ast.Ident); ok {
		// Get entity directly from AST node
		entity := cast(^Entity)cast(rawptr)ident.entity
		return entity == shadowed
	}

	// Check ternary if expressions (x if cond else y)
	// C++ Reference: checker.cpp check_vet_shadowing_assignment
	if ternary, ok := init.derived.(^ast.Ternary_If_Expr); ok {
		x := check_vet_shadowing_assignment(c, shadowed, cast(^ast.Node)ternary.x)
		y := check_vet_shadowing_assignment(c, shadowed, cast(^ast.Node)ternary.y)
		return x || y
	}

	return false
}

// check_vet_unused checks if an entity is unused
// C++ Reference: checker.cpp:709-728
//
// Returns true if the entity is unused and should be reported.
// Fills in the VettedEntity structure with details.
check_vet_unused :: proc(c: ^Checker, e: ^Entity, ve: ^Vetted_Entity) -> bool {
	// Only report unused entities that aren't marked as used
	// C++ Reference: checker.cpp:710
	if .Used in e.flags {
		return false
	}

	// Check entity kinds that can be unused
	// C++ Reference: checker.cpp:711-727
	#partial switch e.kind {
	case .Variable:
		// Skip global, type, file-scoped, and static variables
		// C++ Reference: checker.cpp:712-718
		if e.scope != nil && (.Global in e.scope.flags || .Type in e.scope.flags || .File in e.scope.flags) {
			return false
		}
		if .Static in e.flags {
			return false
		}
		// Report unused local variables
		ve.kind = .Unused
		ve.entity = e
		return true

	case .Import_Name, .Library_Name:
		// Report unused imports/libraries
		// C++ Reference: checker.cpp check_vet_unused
		ve.kind = .Unused
		ve.entity = e
		return true
	}

	return false
}

// check_vet_shadowing checks if a variable shadows another variable
// C++ Reference: checker.cpp:643-707
//
// Returns true if shadowing is detected and should be reported.
// Fills in the VettedEntity structure with details.
check_vet_shadowing :: proc(c: ^Checker, e: ^Entity, ve: ^Vetted_Entity) -> bool {
	// Only variables can shadow
	// C++ Reference: checker.cpp check_vet_shadowing_assignment
	if e.kind != .Variable {
		return false
	}

	// Blank identifiers don't shadow
	// C++ Reference: checker.cpp:647-650
	name := e.token.text
	if name == "_" {
		return false
	}

	// Parameters don't shadow
	// C++ Reference: checker.cpp check_vet_shadowing
	if .Param in e.flags {
		return false
	}

	// Variables in global/file/proc scopes don't shadow
	// C++ Reference: checker.cpp check_vet_shadowing
	if e.scope != nil && (.Global in e.scope.flags || .File in e.scope.flags || .Proc in e.scope.flags) {
		return false
	}

	// Check parent scope (skip if global/file)
	// C++ Reference: checker.cpp check_vet_shadowing
	parent := e.scope.parent if e.scope != nil else nil
	if parent == nil {
		return false
	}
	if .Global in parent.flags || .File in parent.flags {
		return false
	}

	// Look for shadowed entity in parent scope
	// C++ Reference: checker.cpp check_vet_shadowing
	shadowed := scope_lookup(parent, name)
	if shadowed == nil {
		return false
	}
	if shadowed.kind != .Variable {
		return false
	}

	// Allow shadowing of global/file scope (commented out in C++)
	// C++ Reference: checker.cpp check_vet_shadowing

	// Entities must be in the same file
	// C++ Reference: checker.cpp check_vet_shadowing
	if e.token.pos.file != shadowed.token.pos.file {
		return false
	}

	// Shadowed identifier must appear before this one
	// C++ Reference: checker.cpp check_vet_shadowing
	if token_pos_cmp(shadowed.token.pos, e.token.pos) > 0 {
		return false
	}

	// If types differ, don't complain
	// C++ Reference: checker.cpp check_vet_shadowing
	if !are_types_identical(e.type, shadowed.type) {
		return false
	}

	// Ignore intentional redeclaration (x := x)
	// C++ Reference: checker.cpp check_vet_shadowing
	if .Using not_in e.flags && e.kind == .Variable {
		if e_var, ok := &e.variant.(Entity_Variable); ok {
			if check_vet_shadowing_assignment(c, shadowed, e_var.init_expr) {
				return false
			}
		}
	}

	// Report shadowing
	// C++ Reference: checker.cpp check_vet_shadowing
	ve.kind = .Shadowed
	ve.entity = e
	ve.other = shadowed
	return true
}

// vetted_entity_variable_pos_cmp compares two vetted entities by token position
// C++ Reference: checker.cpp:610-617
vetted_entity_variable_pos_cmp :: proc(a, b: Vetted_Entity) -> slice.Ordering {
	x := a.entity
	y := b.entity
	assert(x != nil)
	assert(y != nil)

	cmp := token_pos_cmp(x.token.pos, y.token.pos)
	if cmp < 0 do return .Less
	if cmp > 0 do return .Greater
	return .Equal
}

// check_scope_usage_internal performs the actual scope usage checking
// C++ Reference: checker.cpp:730-846
//
// This is the core implementation that examines all entities in a scope
// and checks for various issues based on vet flags.
check_scope_usage_internal :: proc(c: ^Checker, scope: ^Scope, vet_flags_param: Vet_Flag, per_entity: bool) {
	original_vet_flags := vet_flags_param

	// Collect vetted entities (entities with issues)
	// C++ Reference: checker.cpp:733-735
	vetted_entities: [dynamic]Vetted_Entity
	defer delete(vetted_entities)

	// Lock scope for reading (thread safety)
	// C++ Reference: checker.cpp check_scope_usage_internal
	sync.rw_mutex_shared_lock(&scope.mutex)
	defer sync.rw_mutex_shared_unlock(&scope.mutex)

	// Check each entity in the scope
	// C++ Reference: checker.cpp check_scope_usage_internal
	for _, e in scope.elements {
		if e == nil {
			continue
		}

		// Use per-entity vet flags if requested
		// C++ Reference: checker.cpp check_scope_usage_internal
		vet_flags := original_vet_flags
		if per_entity {
			vet_flags = ast_file_vet_flags(e.file)
		}

		// Extract individual vet flag checks
		// C++ Reference: checker.cpp check_scope_usage_internal
		vet_unused := Vet_Flag_Unused & vet_flags != {}
		vet_shadowing := (.Shadowing in vet_flags) || (.Using_Stmt in vet_flags)
		vet_unused_procedures := .Unused_Procedures in vet_flags
		if vet_unused_procedures && e.pkg != nil && e.pkg.kind == .Runtime {
			vet_unused_procedures = false
		}

		// Check for unused entities
		// C++ Reference: checker.cpp check_scope_usage_internal
		ve_unused := Vetted_Entity{}
		ve_shadowed := Vetted_Entity{}
		is_unused := false

		if vet_unused && check_vet_unused(c, e, &ve_unused) {
			is_unused = true
		} else {
		}
		if vet_unused_procedures && e.kind == .Procedure {
			// Special handling for unused procedures
			// C++ Reference: checker.cpp check_scope_usage_internal
			if .Used in e.flags {
				is_unused = false
			} else if .Require in e.flags {
				is_unused = false
			} else if .Init in e.flags {
				is_unused = false
			} else if .Fini in e.flags {
				is_unused = false
			} else if proc_var, ok := &e.variant.(Entity_Procedure); ok && proc_var.is_export {
				is_unused = false
			} else if e.pkg != nil && e.pkg.kind == .Init && e.token.text == "main" {
				is_unused = false
			} else {
				is_unused = true
				ve_unused.kind = .Unused
				ve_unused.entity = e
			}
		}

		// Check for shadowing
		// C++ Reference: checker.cpp check_scope_usage_internal
		is_shadowed := vet_shadowing && check_vet_shadowing(c, e, &ve_shadowed)

		// Add to vetted entities list
		// C++ Reference: checker.cpp check_scope_usage_internal
		if is_unused && is_shadowed {
			ve_both := ve_shadowed
			ve_both.kind = .Shadowed_And_Unused
			append(&vetted_entities, ve_both)
		} else if is_unused {
			append(&vetted_entities, ve_unused)
		} else if is_shadowed {
			append(&vetted_entities, ve_shadowed)
		// #1114 (B2-h h1). C++ Reference: checker.cpp check_scope_usage_internal:
		//
		//     } else if (e->kind == Entity_Variable &&
		//                ((e->flags & (Param|Using|Static|Field)) == 0 ||
		//                 (e->flags & EntityFlag_Result) != 0) &&
		//               !e->Variable.is_global) {
		//
		// THE `|| Result` DISJUNCT WAS DROPPED. Named results carry Param AND Result together
		// (check_type.cpp sets Used|Param|Result on them, and the port's alloc_entity_param plus
		// check_get_results do the same), so the Param bit alone excluded EVERY named result from
		// the stack-overflow warning. C++'s Result disjunct is what rescues them.
		//
		// This warning is NOT gated on any vet flag — it sits outside the vet_flags block — so it
		// fires on a plain `odin check`.
		// MEASURED, and note BOTH compilers exit 0 because it is a WARNING:
		//     `big :: proc() -> (buf: [1 << 20]u8) { return }`
		// t243: CLOSED. RE-MEASURED BYTE-IDENTICAL on both forms (witness wit_bigres243):
		//     named   `-> (buf: [1 << 20]u8)`: both warn for `buf` AND for the call-site local
		//     unnamed `-> ([1 << 20]u8)`     : both warn for the call-site local ONLY
		// This note previously ended "port: the call-site local only", recording the named result
		// as MISSING on the port side. That divergence no longer reproduces; it was closed by a
		// later change elsewhere and the note was never revisited. A stale claim here is worse
		// than no claim, because a comment asserting a MEASURED gap invites the next reader to
		// "fix" a path that is already at parity. RE-MEASURE before trusting any divergence a
		// comment reports -- including this one.
		} else if e.kind == .Variable &&
		   ((.Param not_in e.flags && .Using not_in e.flags && .Static not_in e.flags && .Field not_in e.flags) ||
		    .Result in e.flags) {
			// Check for large stack allocations
			// C++ Reference: checker.cpp check_scope_usage_internal
			if e_var, ok := &e.variant.(Entity_Variable); ok && !e_var.is_global && e.type != nil {
				sz := type_size_of(e.type)
				// Warn about allocations >256 KiB
				// C++ Reference: checker.cpp check_scope_usage_internal
				if sz > (1 << 18) {
					// C++ Reference: checker.cpp check_scope_usage_internal. C++ derives is_ref from TWO
					// entity flags, not one:
					//
					//	if ((e->flags & EntityFlag_ForValue) != 0) {
					//		is_ref = type_deref(e->Variable.for_loop_parent_type) != NULL;
					//	} else if ((e->flags & EntityFlag_SwitchValue) != 0) {
					//		is_ref = !(e->flags & EntityFlag_Value);
					//	}
					//
					// The SwitchValue arm was never ported, so a BY-REFERENCE type-switch
					// binding (`switch &v in u`) over a >256KiB variant was treated as a
					// by-value declaration and drew a spurious stack-overflow warning that
					// the oracle does not emit. Probe swval covers both forms.
					//
					// The flags this reads are already set correctly: check_stmt.odin:2508
					// adds .Switch_Value unconditionally and .Value only when the binding is
					// not addressed, mirroring check_stmt.cpp:1603.
					is_ref := false
					if .For_Value in e.flags {
						is_ref = type_deref(e_var.for_loop_parent_type) != nil
					} else if .Switch_Value in e.flags {
						is_ref = .Value not_in e.flags
					}
					if !is_ref {
						type_str := type_to_string(e.type)
						warning(e.token, "Declaration of '%s' may cause a stack overflow due to its type '%s' having a size of %d bytes", e.token.text, type_str, sz)
					}
				}
			}
		}
	}

	// Sort vetted entities by token position
	// C++ Reference: checker.cpp check_scope_usage_internal
	slice.sort_by_cmp(vetted_entities[:], vetted_entity_variable_pos_cmp)

	// Report errors for vetted entities
	// C++ Reference: checker.cpp check_scope_usage_internal
	for ve in vetted_entities {
		e := ve.entity
		other := ve.other
		name := e.token.text

		// Use per-entity vet flags if requested
		// C++ Reference: checker.cpp check_scope_usage_internal
		vet_flags := original_vet_flags
		if per_entity {
			vet_flags = ast_file_vet_flags(e.file)
		}

		// Report based on kind
		// C++ Reference: checker.cpp check_scope_usage_internal
		if ve.kind == .Shadowed_And_Unused {
			error(e.token, "'%s' declared but not used, possibly shadows declaration at line %d", name, other.token.pos.line)
		} else if vet_flags != {} {
			#partial switch ve.kind {
			case .Unused:
				if e.kind == .Variable && .Unused_Variables in vet_flags {
					error(e.token, "'%s' declared but not used", name)
				}
				if e.kind == .Procedure && .Unused_Procedures in vet_flags {
					error(e.token, "'%s' declared but not used", name)
				}
				if (e.kind == .Import_Name || e.kind == .Library_Name) && .Unused_Imports in vet_flags {
					error(e.token, "'%s' declared but not used", name)
				}

			case .Shadowed:
				if (.Shadowing in vet_flags || .Using_Stmt in vet_flags) && .Using in e.flags {
					error(e.token, "Declaration of '%s' from 'using' shadows declaration at line %d", name, other.token.pos.line)
				} else if .Shadowing in vet_flags {
					error(e.token, "Declaration of '%s' shadows declaration at line %d", name, other.token.pos.line)
				}
			}
		}
	}
}

// check_proc_body validates and checks a procedure body
// C++ Reference: check_decl.cpp:2009-2198
//
// This is the core procedure checking function that:
// 1. Sets up the procedure checking context
// 2. Validates procedure calling conventions
// 3. Processes 'using' parameters (expands struct fields into scope)
// 4. Evaluates where clauses
// 5. Checks all statements in the procedure body
// 6. Validates return statements and control flow
// 7. Checks for unused variables and shadowing
// 8. Propagates dependencies to parent procedures
//
// Returns:
//   true if checking succeeded, false if failed
check_proc_body :: proc(ctx_: ^Checker_Context, token: tokenizer.Token, decl: ^Decl_Info, type: ^Type, body: ^ast.Block_Stmt) -> bool {
	// Early validation
	// C++ Reference: check_decl.cpp check_proc_body
	if body == nil {
		return false
	}
	// Note: body is already typed as ^ast.Block_Stmt, so type system guarantees it's a block

	// Determine procedure name for error messages
	// C++ Reference: check_decl.cpp check_proc_body
	proc_name := token.text if token.kind == .Ident else "(anonymous-procedure)"

	// Create local context copy (allows modification without affecting caller)
	// C++ Reference: check_decl.cpp check_proc_body
	new_ctx := ctx_^
	ctx := &new_ctx

	// Validate procedure type
	// C++ Reference: check_decl.cpp check_proc_body
	assert(type.kind == .Proc)

	// Setup procedure checking context
	// C++ Reference: check_decl.cpp check_proc_body
	ctx.scope = decl.scope
	ctx.decl = decl
	ctx.proc_name = proc_name
	ctx.curr_proc_decl = decl
	ctx.curr_proc_sig = type
	ctx.curr_proc_calling_convention = type.variant.(Type_Proc).calling_convention

	// Link parent procedure for nested procs
	// C++ Reference: check_decl.cpp check_proc_body
	if decl.parent != nil && decl.entity != nil && decl.parent.entity != nil {
		decl.entity.parent_proc_decl = decl.parent
	}

	// Validate calling convention (disallow "none" in non-runtime packages)
	// C++ Reference: check_decl.cpp check_proc_body
	//
	// An empty `if ctx.pkg == nil {} else {}` sat here doing nothing at all -- left-over
	// scaffolding from someone investigating whether pkg can be nil. Deleted (#587).
	//
	// The `ctx.pkg != nil` guard below is a PORT-ONLY divergence: C++ writes
	// `if (ctx->pkg->name != "runtime")` and dereferences unguarded, so a nil pkg segfaults it.
	// MEASURED (tick 139), by exactly the method this note prescribed -- instrument the nil branch and
	// look for a hit. A counter on `ctx.pkg == nil` at this point recorded 0 hits on core/fmt,
	// core/odin/checker, base/runtime, core/sys/linux and a single-file cell (probe presence verified
	// in-source before building). So ctx.pkg is never nil here on any input tried, and C++'s unguarded
	// `ctx->pkg->name` dereference is safe for all of them.
	// THE GUARD STAYS: 0 hits on five inputs is not a proof of unreachability, and the asymmetry the
	// original note gave still holds -- removing it can only turn a working check into a crash, while
	// keeping it can only suppress one. Now recorded as MEASURED-INERT rather than unmeasured.
	if ctx.pkg != nil && ctx.pkg.name != "runtime" {
		proc_type := type.variant.(Type_Proc)
		#partial switch proc_type.calling_convention {
		case .None:
			error(body, "Procedures with the calling convention \"none\" are not allowed a body")
		}
	}

	// Process 'using' parameters (expand struct fields into scope)
	// C++ Reference: check_decl.cpp check_proc_body
	//
	// This section handles procedure parameters marked with 'using'.
	// For each 'using' parameter of struct type, we create a using variable
	// entity for each field in the struct and add them to the procedure scope.
	using_entities: [dynamic]Proc_Using_Var
	defer delete(using_entities)

	proc_type := type.variant.(Type_Proc)
	if proc_type.param_count > 0 {
		// Iterate over all parameters
		// C++ Reference: check_decl.cpp check_proc_body
		params := proc_type.params.variant.(Type_Tuple)
		for e in params.variables {
			// Skip non-variables
			// C++ Reference: check_decl.cpp check_proc_body
			if e == nil {
				continue
			}
			if e.kind != .Variable {
				continue
			}

			// Check for unspecialized polymorphic types in parameters
			// C++ Reference: check_decl.cpp check_proc_body
			is_poly := is_type_polymorphic(e.type)
			if is_poly && is_type_polymorphic_record_unspecialized(e.type) {
				type_str := type_to_string(e.type)

				msg := "Unspecialized polymorphic types are not allowed in procedure parameters, got %s"
				if e_var, ok := &e.variant.(Entity_Variable); ok && e_var.type_expr != nil {
					error(e_var.type_expr, msg, type_str)
				} else {
					error(e.token, msg, type_str)
				}
			}

			// Check if parameter has 'using' flag
			// C++ Reference: check_decl.cpp check_proc_body
			if .Using not_in e.flags {
				continue
			}

			// Using requires non-blank identifier
			// C++ Reference: check_decl.cpp check_proc_body
			if is_blank_ident(e.token.text) {
				error(e.token, "'using' a procedure parameter requires a non blank identifier")
				break
			}

			// Determine if parameter is passed by value
			// C++ Reference: check_decl.cpp check_proc_body
			is_value := (.Value in e.flags) && !is_type_pointer(e.type)

			// Get base struct type (deref pointers)
			// C++ Reference: check_decl.cpp check_proc_body
			t := base_type(type_deref(e.type))

			// Using only works with struct types
			// C++ Reference: check_decl.cpp check_proc_body
			if t.kind == .Struct {
				struct_scope := t.variant.(Type_Struct).scope
				assert(struct_scope != nil)

				// Lock scope mutex for thread safety
				// C++ Reference: check_decl.cpp check_proc_body
				sync.rw_mutex_shared_lock(&struct_scope.mutex)
				defer sync.rw_mutex_shared_unlock(&struct_scope.mutex)

				// Create using variable for each struct field, in SLOT order. LEDGER #500.
				//
				// CITEMONO: this citation registers as an INVERSION and the inversion is CORRECT to ignore --
				// it deliberately re-cites the SAME C++ block (2189-2207) that the `if t.kind == .Struct`
				// above already cites, because this note explains that block's iteration order. A second
				// reference to an already-cited range always reads as a backwards jump. Do not "fix" it.
				//
				// C++ Reference: check_decl.cpp check_proc_body (the old citation said 2086-2095, which
				// is dependency propagation between decl->deps and decl->parent->deps -- a drifted
				// reference of the #134 family, found by grepping for alloc_entity_using_variable
				// rather than trusting the line number):
				//     Scope *scope = t->Struct.scope;
				//     for (auto const &entry : scope->elements) {
				//         Entity *f = entry.value;
				//         if (f->kind == Entity_Variable) { ... array_add(&using_entities, puv); }
				//     }
				// That range-for is a slot walk (ScopeMapIterator, checker.hpp:468-505).
				//
				// ORDER IS OBSERVABLE, and it took reading the CONSUMER to establish that -- the
				// loop itself has no bail and no diagnostic, it only appends. But the first
				// consumer (below, ~line 1817) inserts each using-variable into ctx.scope and
				// BREAKS on the first collision, so the order of using_entities decides which
				// "Namespace collision while 'using' procedure argument" is reported.
				// Measured with four colliding parameters: the port printed alpha/beta/beta/alpha/
				// gamma/delta/delta/beta across eight runs where the oracle printed delta every time.
				ordered := make([dynamic]^Entity, 0, len(struct_scope.elements), context.temp_allocator)
				for _, field in struct_scope.elements {
					if field != nil {
						append(&ordered, field)
					}
				}
				slice.sort_by(ordered[:], proc(a, b: ^Entity) -> bool {
					if a.token.pos.file != b.token.pos.file {
						return a.token.pos.file < b.token.pos.file
					}
					if a.token.pos.offset != b.token.pos.offset {
						return a.token.pos.offset < b.token.pos.offset
					}
					return a.token.text < b.token.text
				})

				for field in scope_map_slot_order(ordered[:], context.temp_allocator) {
					if field == nil {
						continue
					}
					if field.kind == .Variable {
						// Allocate using variable entity
						// C++ Reference: check_decl.cpp check_proc_body
						uvar := alloc_entity_using_variable(e, field.token, field.type, nil)

						// Propagate Value flag if needed
						// C++ Reference: check_decl.cpp check_proc_body
						if is_value {
							uvar.flags += {.Value}
						}

						// Add to using entities list
						// C++ Reference: check_decl.cpp check_proc_body
						puv := Proc_Using_Var {
							e    = e,
							uvar = uvar,
						}
						append(&using_entities, puv)
					}
				}
			} else {
				// Error: using only works with structs
				// C++ Reference: check_decl.cpp check_proc_body
				error(e.token, "'using' can only be applied to variables of type struct")
				break
			}
		}
	}

	// Insert using variables into procedure scope (first pass, check for conflicts)
	// C++ Reference: check_decl.cpp check_proc_body
	// Thread-safe scope modification
	{
		sync.rw_mutex_lock(&ctx.scope.mutex)
		defer sync.rw_mutex_unlock(&ctx.scope.mutex)

		for puv in using_entities {
			e := puv.e
			uvar := puv.uvar

			// Check for naming conflicts in scope
			// C++ Reference: check_decl.cpp check_proc_body
			prev := scope_insert_no_mutex(ctx.scope, uvar)
			if prev != nil {
				// Error: namespace collision
				// C++ Reference: check_decl.cpp check_proc_body
				error(e.token, "Namespace collision while 'using' procedure argument '%s' of: %s", e.token.text, prev.token.text)
				error_line("%s != %s\n", uvar.token.text, prev.token.text)
				break
			}
		}
	}

	// Evaluate where clauses
	// C++ Reference: check_decl.cpp check_proc_body
	where_clauses: []^ast.Expr = nil
	if decl.proc_lit != nil {
		where_clauses = decl.proc_lit.where_clauses
	}
	// LEDGER #886: RELAXED load, matching C++ check_decl.cpp:2227
	// `!decl->where_clauses_evaluated.load(std::memory_order_relaxed)`.
	where_clause_ok := evaluate_where_clauses(ctx, nil, decl.scope, where_clauses, !sync.atomic_load_explicit(&decl.where_clauses_evaluated, .Relaxed))
	if !where_clause_ok {
		// Where clauses failed, don't check body
		// C++ Reference: check_decl.cpp check_proc_body
		return false
	}
	// PORT ADDITION -- C++'s check_proc_body HAS NO STORE HERE. Corrected at tick 248; the comment
	// this replaces read "seq-cst store, matching C++'s plain `= true` on a std::atomic", which
	// cited check_expr.cpp:7397. That store is real but lives in a DIFFERENT function on a
	// DIFFERENT path: the committed (non-return_on_failure) branch of the polymorphic CALL site.
	// check_decl.cpp check_proc_body (the counterpart of THIS procedure) reads the flag at
	// check_decl.cpp:2369 and never writes it. A citation to a store in another function is not
	// authority for a store here.
	//
	// CONSEQUENCE, as far as it can be reasoned: this line runs ONLY on success (a failing clause
	// returns above), and a successful evaluation prints nothing whatever print_err is. It can
	// therefore only matter if the SAME decl is evaluated again later and fails that time -- in
	// which case the port suppresses a render C++ would emit at the caller, because the call
	// site's compare-exchange (check_expr.odin, #890) would find the flag already claimed.
	// For one instantiation the bindings are the same in both places, so that combination looks
	// unreachable -- but "looks unreachable" is exactly the reasoning that was wrong about the
	// field-tag guard at tick 247, so it is NOT being removed on inspection.
	//
	// EXPERIMENT TO RUN: delete this line, rebuild to a new binary, and re-run corpus_scan2 plus
	// the wit_where* families. If no cell moves, the store is inert and should go for
	// faithfulness. If a cell moves, this comment gets the witness it currently lacks.
	sync.atomic_store(&decl.where_clauses_evaluated, true)

	// Open procedure body scope
	// C++ Reference: check_decl.cpp check_proc_body
	check_open_scope(ctx, body)
	{
		// Set scope's declaration info
		// C++ Reference: check_decl.cpp check_proc_body
		ctx.scope.decl_info = decl

		// Insert using variables into body scope (second pass, no error checking)
		// C++ Reference: check_decl.cpp check_proc_body
		for puv in using_entities {
			uvar := puv.uvar
			prev := scope_insert(ctx.scope, uvar)
			_ = prev // Ignore conflicts (already checked above)
			// C++ Reference: check_decl.cpp check_proc_body: "Don't err here"
		}

		// Sanity checks for procedure state
		// C++ Reference: check_decl.cpp check_proc_body
		assert(decl.proc_checked_state != .Checked)
		if decl.defer_use_checked {
			assert(is_type_polymorphic(type, true))
			// This should never happen in production
			// C++ Reference: check_decl.cpp check_proc_body
			error(token, "Defer Use Checked: %s", decl.entity.token.text)
			assert(!decl.defer_use_checked)
		}

		// Check all statements in the procedure body
		// C++ Reference: check_decl.cpp check_proc_body
		check_stmt_list(ctx, body.stmts, {.Check_Scope_Decls})

		// Mark defer use as checked
		// C++ Reference: check_decl.cpp check_proc_body
		decl.defer_use_checked = true

		// Validate all value declarations have entities
		// C++ Reference: check_decl.cpp check_proc_body
		// NOTE: In Odin, entities are stored in ast_entity_map, not on AST nodes
		for stmt in body.stmts {
			if stmt.derived != nil {
				if vd, ok := stmt.derived.(^ast.Value_Decl); ok {
					for name in vd.names {
						// Check if name is an identifier (not blank, implicit, etc.)
						if ident, is_ident := name.derived.(^ast.Ident); is_ident {
							if !is_blank_ident(ident.name) {
								// Get entity directly from AST node
								// C++ Reference: check_decl.cpp check_proc_body (name->Ident.entity)
								entity := cast(^Entity)cast(rawptr)ident.entity
								assert(entity != nil, "Value declaration identifier must have entity")
							}
						}
					}
				}
			}
		}

		// Validate return statements for procedures with results
		// C++ Reference: check_decl.cpp check_proc_body
		if proc_type.result_count > 0 {
			if !check_is_terminating(ctx, &body.node, "") {
				if token.kind == .Ident {
					error(body.close, "Missing return statement at the end of the procedure '%s'", token.text)
				} else {
					// Anonymous procedure (lambda)
					// C++ Reference: check_decl.cpp check_proc_body
					error(body.close, "Missing return statement at the end of the procedure")
				}
			}
		} else if proc_type.diverging {
			// Validate diverging procedures have diverging call
			// C++ Reference: check_decl.cpp check_proc_body
			if !check_is_terminating(ctx, &body.node, "") {
				if token.kind == .Ident {
					error(body.close, "Missing diverging call at the end of the procedure '%s'", token.text)
				} else {
					// Anonymous procedure (lambda)
					// C++ Reference: check_decl.cpp check_proc_body
					error(body.close, "Missing diverging call at the end of the procedure")
				}
			}
		}
	}
	// Close procedure body scope
	// C++ Reference: check_decl.cpp check_proc_body
	check_close_scope(ctx)

	// Check for unused variables and shadowing
	// C++ Reference: check_decl.cpp check_proc_body
	check_scope_usage(ctx.checker, ctx.scope, check_vet_flags(&ctx.checker.info, &body.node))

	// Propagate dependencies from nested proc to parent
	// C++ Reference: check_decl.cpp check_proc_body
	add_deps_from_child_to_parent(decl)

	// Track variadic reuse optimization data
	// C++ Reference: check_decl.cpp check_proc_body
	for vr in decl.variadic_reuses {
		if vr.slice_type == nil do continue
		assert(vr.slice_type.kind == .Slice, "variadic_reuse slice_type must be Slice")
		slice := &vr.slice_type.variant.(Type_Slice)
		elem := slice.elem
		size := i64(type_size_of(elem))
		align := i64(type_align_of(elem))
		decl.variadic_reuse_max_bytes = max(decl.variadic_reuse_max_bytes, size * vr.max_count)
		decl.variadic_reuse_max_align = max(decl.variadic_reuse_max_align, align)
	}

	// Success
	// C++ Reference: check_decl.cpp check_proc_body
	return true
}

// base_type returns the underlying type, unwrapping named types
base_type :: proc(t: ^Type) -> ^Type {
	if t == nil {
		return nil
	}

	// Unwrap named types to get to the base
	result := t
	iterations := 0
	for result.kind == .Named {
		iterations += 1
		if iterations > 100 {
			// Cycle detected, avoid infinite loop
			return t
		}
		named, ok := &result.variant.(Type_Named)
		if !ok || named.base == nil {
			break
		}
		// Check for direct cycle
		if named.base == result {
			break
		}
		result = named.base
	}

	return result
}

// default_type converts untyped types to their default typed versions
// and resolves specialized Generic types
// C++ Reference: types.cpp:3196-3216
//
// This function handles:
// - Untyped types (UntypedBool -> bool, UntypedInteger -> int, etc.)
// - Generic types (returns specialized type if available)
// - All other types (returned as-is)
default_type :: proc(t: ^Type) -> ^Type {
	if t == nil {
		return t_invalid
	}

	// Handle untyped basic types
	// C++ Reference: types.cpp:3200-3209
	if t.kind == .Basic {
		basic := &t.variant.(Type_Basic)
		#partial switch basic.kind {
		case .Untyped_Bool:
			return t_bool
		case .Untyped_Integer:
			return t_int
		case .Untyped_Float:
			return t_f64
		case .Untyped_Complex:
			return t_complex128
		case .Untyped_Quaternion:
			return t_quaternion256
		case .Untyped_String:
			return t_string
		case .Untyped_Rune:
			return t_rune
		}
	} else if t.kind == .Generic {
		// Handle specialized generic types recursively
		// C++ Reference: types.cpp:3210-3213
		generic := &t.variant.(Type_Generic)
		if generic.specialized != nil {
			return default_type(generic.specialized)
		}
	}

	// Return type as-is for all other cases
	// C++ Reference: types.cpp:3215
	return t
}

// type_align_of returns the alignment requirement of a type in bytes
// C++ Reference: checker.cpp (various locations)
// type_target_max_align ports C++ type_target_max_align (src/types.cpp), added upstream 2026-08-17.
//
// C++ Reference:
//     // The largest alignment the target permits. The i386 System V psABI caps every scalar at 4,
//     // unlike Windows. Anything that derives its alignment from a COMPONENT rather than from its
//     // own size has to be capped here too.
//     gb_internal i64 type_target_max_align(void) {
//         i64 max_align = build_context.max_align;
//         if (build_context.metrics.arch == TargetArch_i386 &&
//             build_context.metrics.os != TargetOs_windows) {
//             max_align = gb_min(max_align, 4);
//         }
//         return max_align;
//     }
//
// UNWITNESSABLE ON THIS TARGET, like #1115 before it: the i386 arm is the only thing that makes
// this differ from build_context.max_align, and the corpus runs amd64. Ported by reading.
type_target_max_align :: proc() -> int {
	max_align := int(build_context.max_align)
	if build_context.metrics.arch == .I386 && build_context.metrics.os != .Windows {
		max_align = min(max_align, 4)
	}
	return max_align
}

type_align_of :: proc(t: ^Type) -> int {
	// C++ Reference: src/types.cpp:4339 type_align_of -- the public entry point creates the
	// TypePath, calls the internal, and frees it. See the Type_Path block in types.odin for
	// why this level of guard exists at all when Checker_Type_Path already does; in short,
	// polymorphic instantiation reaches the size/alignment walk without ever tripping the
	// declaration-cycle detector, and before #1260 that was a SIGSEGV rather than a
	// diagnostic.
	path: Type_Path
	defer delete(path.path)
	return type_align_of_internal(t, &path)
}

// C++ Reference: src/types.cpp:4370 type_align_of_internal.
type_align_of_internal :: proc(t: ^Type, path: ^Type_Path) -> int {
	if t == nil {
		return 1
	}
	// C++ Reference: src/types.cpp:4371-4374 -- `if (t->failure) return FAILURE_ALIGNMENT;`.
	// Unlike the nil case above this returns 0, not 1: a type already known to be part of an
	// illegal cycle has no alignment, and every caller checks path.failure before using the
	// value rather than dividing by it.
	if .Failure in t.flags {
		return FAILURE_ALIGNMENT
	}

	bt := base_type(t)
	if bt == nil {
		return 1
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		// C++ Reference: types.cpp, type_align_of_internal, `case Type_Basic`.
		//
		// "Alignment is same as size, capped at 16" -- what this used to do -- is an
		// invented rule and wrong for every MULTI-WORD basic. A `string` is 16 bytes but
		// aligns to 8, as do `any` and `complex128`. C++ enumerates these explicitly:
		// string/string16 align to int_size, cstring/cstring16 and uintptr/rawptr to
		// ptr_size, any and typeid to 8, complex to size/2 and quaternion to size/4.
		//
		// Over-aligning `string` propagated: any struct containing one got align 16, so
		// a later field was pushed to the next 16-byte boundary and the struct grew.
		// core/nbio's `Operation` measured 400 instead of 384 and failed its own
		// `#assert(size_of(Operation) <= 384)`.
		//
		// The widths themselves come from build_context, not from a literal 8 and not from
		// the size baked into the basic type: C++ reads build_context.int_size / ptr_size on
		// every call so one Type serves every target. LEDGER #580.
		#partial switch basic.kind {
		case .String, .String16, .Int, .Uint:
			return int(build_context.int_size)
		case .Cstring, .Cstring16, .Uintptr, .Rawptr:
			return int(build_context.ptr_size)
		case .Any, .Typeid:
			return 8 // C++ returns a literal 8 for both, not a word
		// A complex aligns to one component and a quaternion to one of its four. Both are now
		// capped by type_target_max_align() -- upstream 2026-08-17, because a type that derives
		// its alignment from a COMPONENT rather than from its own size still must not exceed what
		// the target permits. C++ Reference: types.cpp type_align_of_internal --
		//     case Basic_complex32: case Basic_complex64: case Basic_complex128:
		//         return gb_min(type_size_of_internal(t, path) / 2, type_target_max_align());
		//     case Basic_quaternion64: case Basic_quaternion128: case Basic_quaternion256:
		//         return gb_min(type_size_of_internal(t, path) / 4, type_target_max_align());
		// The port's `max(..., 1)` floor is NOT in the reference and is dropped with this change:
		// no complex or quaternion basic has a size small enough to reach it, so it never fired,
		// and keeping it would be a guard the reference does not have (see LEDGER #302 on what
		// that costs).
		case .Complex32, .Complex64, .Complex128:
			return min(basic.size / 2, type_target_max_align())
		case .Quaternion64, .Quaternion128, .Quaternion256:
			return min(basic.size / 4, type_target_max_align())
		}
		// Every remaining basic (the plain integers, floats, booleans and runes) aligns
		// to its own size.
		// #1115 (B2-h h6). C++ Reference: types.cpp type_align_of_internal's tail:
		//     return gb_clamp(next_pow2(type_size_of_internal(t, path)), 1, build_context.max_align);
		// The port hard-coded the cap as 16 and omitted next_pow2. The literal COINCIDES with
		// build_context.max_align on amd64, which is why no witness on this target can separate
		// them — but max_align is 8 on linux_arm32 (build_settings.odin's metrics table), and it is
		// also 8 on amd64 when built against LLVM < 18. On those targets i128/u128 align 8 in the
		// reference and 16 here.
		// KNOWN, UNWITNESSABLE-ON-THIS-TARGET divergence, fixed by reading rather than by probe;
		// see the note in COVERAGE.md about why that is still worth doing.
		// The cap became type_target_max_align() upstream 2026-08-17; on i386 non-Windows that is
		// 4 rather than build_context.max_align.
		return clamp(next_pow2_int(basic.size), 1, type_target_max_align()) if basic.size > 0 else 1

	// C++ has NO explicit Type_Pointer / Type_MultiPointer / Type_Proc arm in
	// type_align_of_internal -- all three fall to its tail,
	//     gb_clamp(next_pow2(type_size_of_internal(t, path)), 1, build_context.max_align)
	// which for a one-word type is exactly ptr_size. Spelling it out here rather than
	// reproducing the clamp keeps the arms readable; the value is the same for every target in
	// the metrics table, where ptr_size is always a power of two. Type_SoaPointer DOES have its
	// own arm and returns int_size, so it is separated out. LEDGER #580.
	case .Pointer, .Multi_Pointer, .Proc:
		return int(build_context.ptr_size)

	case .Soa_Pointer:
		// C++ Reference: types.cpp type_align_of_internal, `case Type_SoaPointer: return
		// build_context.int_size;` -- one word, even though the type is two words wide.
		return int(build_context.int_size)

	case .Array:
		arr := bt.variant.(Type_Array)
		// C++ Reference: src/types.cpp:4402-4411 -- the element is PUSHED before its alignment
		// is asked for, so `A :: struct { x: [1]B }` with B leading back to A closes the cycle
		// here rather than recursing.
		pushed := type_path_push(path, arr.elem)
		if path.failure {
			return FAILURE_ALIGNMENT
		}
		align := type_align_of_internal(arr.elem, path)
		if pushed {
			type_path_pop(path)
		}
		return align

	case .Enumerated_Array:
		earr := bt.variant.(Type_Enumerated_Array)
		// C++ Reference: src/types.cpp:4413-4422 -- same shape as the plain array above.
		pushed := type_path_push(path, earr.elem)
		if path.failure {
			return FAILURE_ALIGNMENT
		}
		align := type_align_of_internal(earr.elem, path)
		if pushed {
			type_path_pop(path)
		}
		return align

	// C++ Reference: types.cpp type_align_of_internal -- Slice and DynamicArray return
	// build_context.int_size, Map returns build_context.ptr_size. They are NOT all "pointer
	// alignment": on a target where int_size != ptr_size the three would disagree. LEDGER #580.
	case .Slice:
		return int(build_context.int_size)

	case .Dynamic_Array:
		return int(build_context.int_size)

	case .Map:
		return int(build_context.ptr_size)

	// C++ Reference: types.cpp type_align_of_internal, case Type_BitField --
	//     return type_align_of_internal(t->BitField.backing_type, path);
	// This arm was MISSING, so bit_field fell through to the function's default of 8 and every
	// bit_field reported align 8 regardless of backing width: u8 -> 8 (want 1), u16 -> 8 (want 2),
	// u32 -> 8 (want 4). Only the u64-backed case was right, and only by coincidence. type_size_of
	// already delegates to backing_type (types.odin, case .Bit_Field) -- this is its missing mirror,
	// and the exact sibling of #113 (type_align_of ignored struct alignment directives).
	case .Bit_Field:
		bf := bt.variant.(Type_Bit_Field)
		return type_align_of_internal(bf.backing_type, path)

	case .Struct:
		struc := bt.variant.(Type_Struct)

		// C++ Reference: types.cpp type_align_of_internal, case Type_Struct.
		// `#align(N)` wins outright, and `#packed` forces 1.
		if struc.custom_align > 0 {
			return max(int(struc.custom_align), 1)
		}
		if struc.is_packed {
			return 1
		}

		// Struct alignment is the max alignment of its fields
		max_align := 1
		for field in struc.fields {
			// entity_type, not `.type`: the base field is not always populated.
			// C++ Reference: src/types.cpp:4498-4508 -- each field type is pushed for the
			// duration of its own alignment query and popped after. Sequential fields of the
			// same named type are therefore NOT a cycle; only nesting is.
			field_type := entity_type(field)
			pushed := type_path_push(path, field_type)
			if path.failure {
				return FAILURE_ALIGNMENT
			}
			field_align := type_align_of_internal(field_type, path)
			if pushed {
				type_path_pop(path)
			}
			if field_align > max_align {
				max_align = field_align
			}
		}

		// `#min_field_align(N)` raises the result and `#max_field_align(N)` caps it.
		// Both were ignored, so `IO_Uring_Getevents_Arg` in core/sys/linux/types.odin —
		// declared `struct #min_field_align(8)` — aligned to 8 only by accident of its
		// field types, and any struct relying on the directive got the wrong alignment.
		if struc.custom_min_field_align > 0 {
			max_align = max(max_align, int(struc.custom_min_field_align))
		}
		// C++ Reference: types.cpp type_align_of_internal, Type_Struct arm. Upstream DROPPED
		// the `> custom_min_field_align` conjunct: #max_field_align now caps the alignment
		// whenever it is set, even when it is <= #min_field_align. Previously a struct with
		// `#min_field_align(8) #max_field_align(4)` ignored the cap entirely. LEDGER #800.
		if struc.custom_max_field_align != 0 {
			max_align = min(max_align, int(struc.custom_max_field_align))
		}
		return max_align

	case .Union:
		un := bt.variant.(Type_Union)

		// #1114 (B2-h h5). C++ Reference: types.cpp type_align_of_internal, case Type_Union:
		//
		//     if (t->Union.variants.count == 0) { return 1; }
		//     if (t->Union.custom_align > 0)    { return gb_max(t->Union.custom_align, 1); }
		//     ... then the max-of-variants walk ...
		//
		// BOTH early returns were missing. `union #align(N)` was therefore ignored entirely and the
		// alignment came out as the max of the variants — which also makes the SIZE and every
		// enclosing struct's field OFFSETS wrong, since type_size_of rounds to the alignment.
		// The field is not unused elsewhere: check_equivalence.odin and name_canonicalization.odin
		// both read union custom_align, so only this function ignored it.
		// MEASURED: `U :: union #align(32) { u8, u16 }` — `#assert(align_of(U) == 32)` passes on the
		// oracle and FAILED here. The sibling .Struct arm two cases up already honours its own
		// custom_align, so the two disagreed with each other.
		if len(un.variants) == 0 {
			return 1
		}
		if un.custom_align > 0 {
			return max(int(un.custom_align), 1)
		}

		// Union alignment is the max alignment of its variants
		max_align := 1
		for variant in un.variants {
			// C++ Reference: src/types.cpp:4471-4481 -- same push/pop discipline as the struct
			// field walk above.
			pushed := type_path_push(path, variant)
			if path.failure {
				return FAILURE_ALIGNMENT
			}
			variant_align := type_align_of_internal(variant, path)
			if pushed {
				type_path_pop(path)
			}
			if variant_align > max_align {
				max_align = variant_align
			}
		}
		return max_align

	case .Enum:
		enum_type := bt.variant.(Type_Enum)
		return type_align_of_internal(enum_type.base_type, path)

	case .Bit_Set:
		// C++ Reference: types.cpp type_align_of_internal. The `underlying` branch was ported; the BIT-COUNT
		// LADDER under it was replaced with a bare `return 8`, so every bit_set without an
		// explicit backing type reported align 8 regardless of width.
		//
		// LEDGER #475. Found by the first cross-implementation MODEL diff, not by any diagnostic
		// gate -- align is not printed in any message, so all 323 parity packages were green with
		// this present. It is the #416 shape exactly (that was type_align_of's missing Bit_Field
		// arm; this is Bit_Set's truncated one) and the #268/#294 family: C++'s logic reduced to a
		// constant that happens to be right for the common 64-bit case.
		bs := bt.variant.(Type_Bit_Set)
		if bs.underlying != nil {
			return type_align_of_internal(bs.underlying, path)
		}
		bits := bs.upper - bs.lower + 1
		switch {
		case bits <= 8:
			return 1
		case bits <= 16:
			return 2
		case bits <= 32:
			return 4
		case bits <= 64:
			return 8
		case bits <= 128:
			return 16
		}
		return 8 // C++: "Could be an invalid range so limit it for now"

	case .Simd_Vector:
		sv := bt.variant.(Type_Simd_Vector)
		// SIMD vectors have alignment equal to their total size
		elem_size := type_size_of_internal(sv.elem, path)
		total_size := int(sv.count) * elem_size
		// Round up to power of 2
		// #1115 (B2-h h6). C++ Reference: types.cpp type_align_of_internal, case Type_SimdVector:
		//     return gb_clamp(next_pow2(type_size_of_internal(t, path)), 1, build_context.max_simd_align);
		// The port hard-coded 64 and omitted next_pow2. 64 == max_simd_align*2 on amd64 as
		// max_simd_align then stood (32), so this target could not witness it.
		// UPSTREAM 2026-08-17 dropped the `*2` AND re-tabled max_simd_align on every target
		// (build_settings.odin): 512 for x86 and riscv, 16 for arm64 and darwin, 8 for arm32.
		// Both halves are needed -- the multiplier and the table are one change, and porting
		// either alone gives a cap that matches no target.
		return clamp(next_pow2_int(total_size), 1, int(build_context.max_simd_align)) if total_size > 0 else 1

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: types.cpp type_align_of_internal, case Type_FixedCapacityDynamicArray:
		//     return gb_max(build_context.int_size, type_align_of_internal(elem, path));
		//
		// There was NO arm here at all, so `[dynamic; N]T` fell through to the default `return 8`
		// and any element aligned more strictly than a word reported the word's alignment:
		//     [dynamic; 4]Big            oracle 16   port 8    (Big is struct #align(16))
		//     [dynamic; 2]matrix[4,4]f32 oracle 32   port 8
		// The second only became visible after #514 fixed matrix alignment -- before that the
		// element itself measured 4, so the wrong answer here was masked by a wrong answer
		// underneath it. Worth noting as a general hazard of layout defects: they compose, and
		// fixing one can be what makes the next one measurable.
		fcda := bt.variant.(Type_Fixed_Capacity_Dynamic_Array)
		// C++ Reference: src/types.cpp:4429-4438 -- the element is pushed here too.
		pushed := type_path_push(path, fcda.elem)
		if path.failure {
			return FAILURE_ALIGNMENT
		}
		elem_align := type_align_of_internal(fcda.elem, path)
		if pushed {
			type_path_pop(path)
		}
		return max(int(build_context.int_size), elem_align)

	case .Matrix:
		mat := bt.variant.(Type_Matrix)
		return matrix_align_of(mat)

	case:
		// KNOWN DIVERGENCE, left alone deliberately. C++'s tail is
		//     return gb_clamp(next_pow2(type_size_of_internal(t, path)), 1, build_context.max_align);
		// The arms above cover every Type_Kind except Invalid, Generic and Tuple (Named is stripped
		// by base_type before the switch). For Invalid and Generic C++'s formula yields 1, not 8;
		// for Tuple C++ has its OWN arm, computing the maximum member alignment, which the port
		// does not have at all.
		//
		// MEASURED DEAD, which is why it stays a literal. #580 left this as "no probe I have
		// reaches this arm", which is an absence of evidence; #581 replaced it with evidence.
		// A counter on this arm, swept over all 323 packages in pkglist.txt:
		//
		//     ALIGNTAIL lines: 0
		//
		// and the detector is not vacuous -- deleting the `.Enum` arm as a positive control made
		// it print `ALIGNTAIL Enum=282` on core/strings alone. So Invalid, Generic and Tuple never
		// reach type_align_of anywhere in the corpus, and the value returned here is unobservable.
		//
		// The C++ arms are still worth naming, because "unreachable on this corpus" is not
		// "unreachable": for Invalid and Generic C++'s tail yields 1, and Tuple has its OWN arm
		// (`i64 max = 1; for each variable: max = gb_max(max, align)`) that the port lacks
		// entirely. If anything ever makes this arm fire, that is what to port. Writing those arms
		// now would be #266's mistake pointing the other way -- code no input reaches, verified by
		// nothing.
		return 8
	}
}

// matrix_align_of ports C++ matrix_align_of (src/types.cpp).
//
// The port had `return type_align_of(mat.elem)` -- the ELEMENT's alignment. That is wrong for every
// matrix whose total size exceeds its element size, i.e. all of them, and it is the same shape of
// defect as #416 (type_align_of missing its Bit_Field arm) and #475 (its Bit_Set arm truncated to a
// constant). Found by modeldiff on core/math/linalg, where SIZES agreed on all six identity
// constants and ALIGNMENTS diverged on all six:
//
//     matrix[2,2]f16   C++ 8    port 2        matrix[4,4]f16   C++ 32   port 2
//     matrix[2,2]f32   C++ 16   port 4        matrix[4,4]f32   C++ 32   port 4
//     matrix[2,2]f64   C++ 32   port 8        matrix[4,4]f64   C++ 32   port 8
//
// C++'s rule, and its own comment explains WHY it is not simply the element alignment: the strategy
// is ZERO PADDING. Padding each column to its natural alignment would be faster, but Odin
// deliberately trades that away so third-party libraries can assume a matrix is densely packed.
//
// *** UPSTREAM 2026-08-17 REPLACED THE WHOLE COMPUTATION. *** The total-size derivation above --
// largest power of two dividing the total, floored at the element alignment, capped at
// max_simd_align -- is gone. row_count, column_count and elem_size are now unused (C++ marks all
// three `gb_unused`), and the answer is simply the ELEMENT's alignment, clamped:
//
//     gb_internal i64 matrix_align_of(Type *t, struct TypePath *tp) {
//         gb_unused(row_count); gb_unused(column_count); gb_unused(elem_size);
//         return gb_clamp(elem_align, 1, build_context.max_simd_align);
//     }
//
// Which lands, ironically, close to the `return type_align_of(mat.elem)` the port started with and
// #514 replaced -- but NOT identical to it, because of the clamp, and it was still right to fix:
// the old port answer disagreed with the reference of its day on all six linalg identity constants.
// The zero-padding rationale still holds, it is just no longer what sets the alignment.
//
// The commented-out `prev_pow2(elem_align * row_count)` line is preserved in C++ as the rejected
// alternative; it is not ported, and this note is here so that a future reader who finds it does
// not mistake it for something the port dropped.
@(private = "file")
matrix_align_of :: proc(mat: Type_Matrix) -> int {
	elem_align := type_align_of(mat.elem)
	return clamp(elem_align, 1, int(build_context.max_simd_align))
}

// prev_pow2_int ports C++ prev_pow2(i64) (src/common.cpp:535) -- the largest power of two <= n.
@(private = "file")
// next_pow2_int is C++'s next_pow2 (src/common.cpp), used by type_align_of_internal's clamps.
// Returns v rounded UP to a power of two; v <= 0 yields 0, matching the reference's guard shape.
next_pow2_int :: proc(v: int) -> int {
	if v <= 0 {
		return 0
	}
	n := v - 1
	n |= n >> 1
	n |= n >> 2
	n |= n >> 4
	n |= n >> 8
	n |= n >> 16
	n |= n >> 32
	return n + 1
}

prev_pow2_int :: proc(v: int) -> int {
	if v <= 0 {
		return 0
	}
	n := v
	n |= n >> 1
	n |= n >> 2
	n |= n >> 4
	n |= n >> 8
	n |= n >> 16
	n |= n >> 32
	return n - (n >> 1)
}

// ======================================================================================
// PROCEDURE VALIDATION
// C++ Reference: checker.cpp:6288-6371, 7085-7134
// ======================================================================================

// init_procedures_cmp_generic compares two entities for init procedure sorting
// C++ Reference: checker.cpp:7085-7120
//
// This comparison function uses the Generic_Cmp signature (rawptr arguments)
// to sort procedures marked with @(init) attribute in a deterministic order based on:
// 1. Package dependency order (from topological sort)
// 2. File name (lexicographic comparison)
// 3. Source order (order_in_src field)
// 4. Token position offset (as final tiebreaker)
init_procedures_cmp_generic :: proc(a_ptr, b_ptr: rawptr, user_data: rawptr) -> slice.Ordering {
	a := (^^Entity)(a_ptr)^
	b := (^^Entity)(b_ptr)^
	_ = user_data // Reserved for future use (Checker_Info)

	if a == b {
		return .Equal
	}

	// Compare package order first
	// C++ Reference: checker.cpp init_procedures_cmp (if (x->pkg != y->pkg) { ... })
	// The previous citation here pointed ~360 lines earlier, into handle_raddbg_type_view --
	// unrelated string parsing. Same systematic checker.cpp drift LEDGER 134 measured at
	// +193..+334, now larger. Line numbers of the stale target are deliberately NOT repeated:
	// citefn.py scans for file.cpp:NNNN and cannot tell a citation from a mention of one.
	// Package order is populated in check_import_entities().
	if a.pkg != b.pkg {
		order_a := a.pkg.order if a.pkg != nil else 0
		order_b := b.pkg.order if b.pkg != nil else 0
		if order_a < order_b do return .Less
		if order_a > order_b do return .Greater
	}

	// Compare file paths (if different files)
	if a.file != b.file {
		path_a := a.file.fullpath if a.file != nil else ""
		path_b := b.file.fullpath if b.file != nil else ""

		// Extract filename from path for comparison
		// C++ uses filename_from_path() which gets the basename
		file_a := path_a
		file_b := path_b

		// Simple filename extraction (last path component)
		for i := len(path_a) - 1; i >= 0; i -= 1 {
			if path_a[i] == '/' || path_a[i] == '\\' {
				file_a = path_a[i + 1:]
				break
			}
		}
		for i := len(path_b) - 1; i >= 0; i -= 1 {
			if path_b[i] == '/' || path_b[i] == '\\' {
				file_b = path_b[i + 1:]
				break
			}
		}

		if file_a < file_b do return .Less
		if file_a > file_b do return .Greater
	}

	// Compare source order
	if a.order_in_src < b.order_in_src do return .Less
	if a.order_in_src > b.order_in_src do return .Greater

	// Finally compare token offsets
	if a.token.pos.offset < b.token.pos.offset do return .Less
	if a.token.pos.offset > b.token.pos.offset do return .Greater

	return .Equal
}

// fini_procedures_cmp_generic compares two entities for fini procedure sorting
// C++ Reference: checker.cpp:7490-7492 (fini_procedures_cmp)
// The previous citation pointed ~370 lines earlier, into unrelated string parsing.
//
// Fini procedures are sorted in reverse order of init procedures.
// This ensures cleanup happens in reverse order of initialization.
fini_procedures_cmp_generic :: proc(a_ptr, b_ptr: rawptr, user_data: rawptr) -> slice.Ordering {
	// Reverse the comparison by swapping arguments
	// C++ Reference: checker.cpp:7491 (return init_procedures_cmp(b, a))
	return init_procedures_cmp_generic(b_ptr, a_ptr, user_data)
}

// remove_neighbouring_duplicate_entries_from_sorted_array removes consecutive duplicates
// C++ Reference: checker.cpp:6353-6365
remove_neighbouring_duplicate_entries_from_sorted_array :: proc(array: ^[dynamic]^Entity) {
	if len(array) == 0 do return

	prev: ^Entity = nil
	i := 0

	for i < len(array) {
		curr := array[i]
		if prev == curr {
			// Remove current element (ordered removal to preserve sorting)
			ordered_remove(array, i)
			// Don't increment i, check same position again
		} else {
			prev = curr
			i += 1
		}
	}
}

// check_sort_init_and_fini_procedures sorts init/fini procedures by priority
// C++ Reference: checker.cpp:7126-7134
//
// This function sorts procedures marked with @(init) and @(fini) attributes:
// - Init procedures are sorted in ascending order (by source order)
// - Fini procedures are sorted in descending order (reverse of init)
// - Duplicates are removed after sorting
//
// The sorting ensures initialization happens in a deterministic order based on:
// 1. Package dependency order
// 2. File order within package
// 3. Declaration order within file
check_sort_init_and_fini_procedures :: proc(c: ^Checker) {
	// Sort init procedures in ascending order
	// C++ Reference: checker.cpp:7130
	//
	// Note: We use a simple bubble sort here since Odin's slice.sort_by_generic_cmp
	// may not be available in all versions. This is called infrequently (once per compilation).
	for i in 0 ..< len(c.info.init_procedures) {
		for j in i + 1 ..< len(c.info.init_procedures) {
			if init_procedures_cmp_generic(&c.info.init_procedures[i], &c.info.init_procedures[j], &c.info) == .Greater {
				c.info.init_procedures[i], c.info.init_procedures[j] = c.info.init_procedures[j], c.info.init_procedures[i]
			}
		}
	}

	// Sort fini procedures in descending order (reverse of init)
	// C++ Reference: checker.cpp:7131
	for i in 0 ..< len(c.info.fini_procedures) {
		for j in i + 1 ..< len(c.info.fini_procedures) {
			if fini_procedures_cmp_generic(&c.info.fini_procedures[i], &c.info.fini_procedures[j], &c.info) == .Greater {
				c.info.fini_procedures[i], c.info.fini_procedures[j] = c.info.fini_procedures[j], c.info.fini_procedures[i]
			}
		}
	}

	// Remove possible duplicates from the init/fini lists
	// Since arrays are sorted, we only need to check neighboring elements
	// C++ Reference: checker.cpp:7133
	remove_neighbouring_duplicate_entries_from_sorted_array(&c.info.init_procedures)
	remove_neighbouring_duplicate_entries_from_sorted_array(&c.info.fini_procedures)
}

// check_test_procedures validates and sorts test procedures
// C++ Reference: checker.cpp:6368-6371
//
// This function processes procedures marked with @(test) attribute:
// - Sorts test procedures by source order (same as init procedures)
// - Removes duplicates from the test list
// - Validation of test procedure signatures happens during attribute checking
check_test_procedures :: proc(c: ^Checker) {
	// Sort test procedures using same order as init procedures
	// C++ Reference: checker.cpp:6369
	//
	// Note: We use a simple bubble sort here since Odin's slice.sort_by_generic_cmp
	// may not be available in all versions. This is called infrequently (once per compilation).
	for i in 0 ..< len(c.info.testing_procedures) {
		for j in i + 1 ..< len(c.info.testing_procedures) {
			if init_procedures_cmp_generic(&c.info.testing_procedures[i], &c.info.testing_procedures[j], &c.info) == .Greater {
				c.info.testing_procedures[i], c.info.testing_procedures[j] = c.info.testing_procedures[j], c.info.testing_procedures[i]
			}
		}
	}

	// Remove duplicates (sorted array, check neighbors only)
	// C++ Reference: checker.cpp check_test_procedures
	// (An earlier citation here landed inside find_entity_path -- the wrong function.
	// C++ spells the helper `remove_neighbouring_duplicate_entires_from_sorted_array`, with `entires`
	// for `entries`; the port corrects the spelling deliberately, so the names differ by that typo.)
	remove_neighbouring_duplicate_entries_from_sorted_array(&c.info.testing_procedures)
}

// check_unchecked_bodies detects procedures with unchecked bodies
// C++ Reference: checker.cpp check_unchecked_bodies
//
// This is a sanity checker to ensure all procedure bodies have been checked.
// It handles race conditions from multithreaded parsing where procedures might
// be added but not yet checked.
//
// The function:
// 1. Identifies entities with min_dep_count > 0 (in dependency graph)
// 2. Schedules unchecked procedures for checking
// 3. Processes the procedure queue either single-threaded or via thread pool
check_unchecked_bodies :: proc(c: ^Checker) {
	// Sanity check - this should only be called after procedure checking phase
	assert(len(c.procs_to_check) == 0, "procs_to_check should be empty")

	// Worker queue support is active - global_procedure_body_in_worker_queue controls
	// whether procedures are queued to thread pool or processed directly

	// Set global flag to false before starting
	// C++ Reference: checker.cpp check_unchecked_bodies
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)

	// Find all entities in the minimum dependency set and schedule them
	// C++ Reference: checker.cpp check_unchecked_bodies
	for entity in c.info.entities {
		if entity.min_dep_count > 0 {
			// This entity is in the dependency graph, ensure its procedure is checked
			check_procedure_later_from_entity(c, entity, "check_unchecked_bodies")
		}
	}

	// Process all scheduled procedures
	// C++ Reference: checker.cpp check_unchecked_bodies
	if !sync.atomic_load(&global_procedure_body_in_worker_queue) {
		// Single-threaded mode: process directly
		// C++ Reference: checker.cpp check_unchecked_bodies
		untyped := &check_procedure_bodies_worker_data[0].untyped
		for i := 0; i < len(c.procs_to_check); i += 1 {
			pi := c.procs_to_check[i]
			consume_proc_info(c, pi, untyped)
		}
		clear(&c.procs_to_check)
	} else {
		// Parallel mode: wait for workers
		// C++ Reference: checker.cpp check_unchecked_bodies
		thread_pool_wait()
	}

	// Reset global flags
	// C++ Reference: checker.cpp check_unchecked_bodies
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)
	sync.atomic_store(&global_after_checking_procedure_bodies, true)
}

// check_safety_all_procedures_for_unchecked performs safety validation
// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
//
// This function is a debug/safety measure that checks all procedures in
// the all_procedures_queue to ensure none were missed during checking.
// It only runs when DEBUG_CHECK_ALL_PROCEDURES is enabled.
//
// The function:
// 1. Drains the all_procedures_queue
// 2. Checks each procedure that is used but not yet body-checked
// 3. Adds all procedures to the final all_procedures array
check_safety_all_procedures_for_unchecked :: proc(c: ^Checker) {
	// This is a debug-only function in C++
	// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked (GB_ASSERT(DEBUG_CHECK_ALL_PROCEDURES))
	// In production builds, this is typically disabled
	// We'll implement it for completeness but note it's for debugging

	// Create untyped expression map for checking
	// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
	untyped: map[^ast.Expr]^Expr_Info
	defer delete(untyped)

	// Reserve space in all_procedures array based on queue count
	// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
	queue_count := queue.mpsc_count(&c.info.all_procedures_queue)
	if queue_count > 0 {
		reserve(&c.info.all_procedures, queue_count)
	}

	// Drain the all_procedures_queue and check each one
	// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
	for {
		pi, ok := queue.mpsc_dequeue(&c.info.all_procedures_queue)
		if !ok do break

		// Validate procedure info
		// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
		assert(pi != nil)
		assert(pi.decl != nil)

		// Get entity and check state
		// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
		e := pi.decl.entity
		proc_checked_state := pi.decl.proc_checked_state
		_ = proc_checked_state // Used for debugging in C++

		// Check if procedure needs checking
		// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
		if e != nil && !sync.atomic_load(&e.proc_body_checked) {
			if .Used in e.flags {
				// Debug output (commented in C++)
				// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
				// debugf("%s :: %s\n", e.token.text, type_to_string(e.type))
				// debugf("proc body unchecked\n")
				// debugf("Checked State: %s\n\n", proc_checked_state)

				// Check the procedure
				// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
				consume_proc_info(c, pi, &untyped)
			}
		}

		// Add to all_procedures array
		// C++ Reference: checker.cpp check_safety_all_procedures_for_unchecked
		append(&c.info.all_procedures, pi)
	}
}

// ======================================================================================
// DEPENDENCY TREE UPDATES
// C++ Reference: checker.cpp:7520-7580
// ======================================================================================

// check_walk_all_dependencies_worker_proc is the thread pool worker for dependency walking
// C++ Reference: checker.cpp:7546-7558
check_walk_all_dependencies_worker_proc :: proc(data: rawptr) -> int {
	decl := cast(^Decl_Info)data
	check_walk_all_dependencies(decl)
	return 0
}

// check_walk_all_dependencies recursively walks a declaration's dependency tree
// C++ Reference: checker.cpp:7522-7530 (the #if 0 sequential form, which this mirrors)
//
// This function processes a declaration and all its children (nested procedures),
// propagating dependencies from child declarations to parent declarations.
// This is critical for proper dependency analysis of nested procedures.
check_walk_all_dependencies :: proc(decl: ^Decl_Info) {
	if decl == nil {
		return
	}

	// Process all child declarations recursively
	// C++ Reference: checker.cpp:7526-7528
	for child := decl.next_child; child != nil; child = child.next_sibling {
		check_walk_all_dependencies(child)
	}

	// Propagate dependencies from this declaration to its parent
	// C++ Reference: checker.cpp:7529
	add_deps_from_child_to_parent(decl)
}

// check_update_dependency_tree_for_procedures walks all procedure dependency trees
// C++ Reference: checker.cpp:7567-7579
//
// This function processes two sets of declarations:
// 1. Nested procedure literals (from c.nested_proc_lits)
// 2. All entity declarations (from c.info.entities)
//
// For each declaration, it recursively walks the dependency tree to ensure
// all dependencies are properly propagated from nested procedures to their
// parents. This is essential for correct dependency ordering during code generation.
check_update_dependency_tree_for_procedures :: proc(c: ^Checker) {
	use_threading := global_thread_pool != nil && !build_context.no_threaded_checker

	if use_threading {
		// Multithreaded mode: submit tasks to thread pool
		// C++ Reference: checker.cpp:7568-7576

		// Process nested procedure literals
		{
			sync.lock(&c.nested_proc_lits_mutex)
			defer sync.unlock(&c.nested_proc_lits_mutex)

			for decl in c.nested_proc_lits {
				thread_pool_add_task(check_walk_all_dependencies_worker_proc, decl)
			}
		}

		// Process all entity declarations
		for entity in c.info.entities {
			decl := entity.decl_info
			if decl != nil {
				thread_pool_add_task(check_walk_all_dependencies_worker_proc, decl)
			}
		}

		// Wait for all workers to complete
		// C++ Reference: checker.cpp check_update_dependency_tree_for_procedures
		thread_pool_wait()
	} else {
		// Sequential mode: process directly
		// C++ Reference: checker.cpp:7533-7541

		// Process nested procedure literals
		{
			sync.lock(&c.nested_proc_lits_mutex)
			defer sync.unlock(&c.nested_proc_lits_mutex)

			for decl in c.nested_proc_lits {
				check_walk_all_dependencies(decl)
			}
		}

		// Process all entity declarations
		for entity in c.info.entities {
			decl := entity.decl_info
			check_walk_all_dependencies(decl)
		}
	}
}

// ======================================================================================
// SCOPE USAGE VALIDATION
// C++ Reference: checker.cpp check_scope_usage_file_worker,
//                check_scope_usage_pkg_worker, check_all_scope_usages
// ======================================================================================

// Scope_Check_Task holds data for a scope checking task
// Used to pass both checker and target to worker threads
Scope_Check_File_Task :: struct {
	c: ^Checker,
	f: ^ast.File,
}

Scope_Check_Pkg_Task :: struct {
	c:   ^Checker,
	pkg: ^ast.Package,
}

// scope_check_file_worker_proc is the thread pool worker wrapper for file scope checking
// C++ Reference: checker.cpp check_scope_usage_file_worker
scope_check_file_worker_proc :: proc(data: rawptr) -> int {
	task := cast(^Scope_Check_File_Task)data
	check_scope_usage_file_worker(task.c, task.f)
	return 0
}

// scope_check_pkg_worker_proc is the thread pool worker wrapper for package scope checking
// C++ Reference: checker.cpp check_scope_usage_pkg_worker
scope_check_pkg_worker_proc :: proc(data: rawptr) -> int {
	task := cast(^Scope_Check_Pkg_Task)data
	check_scope_usage_pkg_worker(task.c, task.pkg)
	return 0
}

// check_scope_usage_file_worker is the worker thread entry point for file scope checking
// C++ Reference: checker.cpp check_scope_usage_file_worker
//
// This function is called by worker threads (or sequentially) to check
// a single file's scope for unused/shadowed variables.
check_scope_usage_file_worker :: proc(c: ^Checker, f: ^ast.File) {
	// Get file-specific vet flags
	// C++ Reference: checker.cpp check_scope_usage_file_worker
	vet_flags := ast_file_vet_flags(f)

	// Check the file's scope
	// C++ Reference: checker.cpp check_scope_usage_file_worker
	// Note: C++ stores scope on AstFile, we track it in info.file_scopes map
	file_scope, has_scope := c.info.file_scopes[f]
	if has_scope {
		check_scope_usage(c, file_scope, vet_flags)
	}
}

// check_scope_usage_pkg_worker is the worker thread entry point for package scope checking
// C++ Reference: checker.cpp check_scope_usage_pkg_worker
//
// This function is called by worker threads (or sequentially) to check
// a single package's scope for unused/shadowed variables.
check_scope_usage_pkg_worker :: proc(c: ^Checker, pkg: ^ast.Package) {
	// Check package scope with per_entity mode
	// C++ Reference: checker.cpp check_scope_usage_pkg_worker
	// Note: vet_flags=0 for package scopes, per_entity=true
	// Note: C++ stores scope on AstPackage, we track it in info.package_scopes map
	pkg_scope, has_scope := c.info.package_scopes[pkg]
	if has_scope {
		check_scope_usage_internal(c, pkg_scope, {}, true)
	}
}

// check_all_scope_usages checks all file and package scopes for issues
// C++ Reference: checker.cpp check_all_scope_usages
//
// This function iterates over all files and packages in the checker,
// checking each scope for:
// - Unused variables/parameters/imports
// - Shadowed declarations
// - Large stack allocations
// TWO PORT-ONLY SHAPES HERE, both deliberate and both verified against C++ while reading:
//   * C++ has NO thread-count branch (checker.cpp check_all_scope_usages): it always adds tasks and then calls
//     thread_pool_wait(). The port's sequential path exists because global_thread_pool may be nil in
//     a hosted session; with one thread the two are observationally identical, since C++'s pool would
//     run the same tasks to completion inside thread_pool_wait().
//   * C++ iterates c->info.files and c->info.packages as MAPS, i.e. in hash order. The port iterates
//     sorted_files / sorted_packages in BOTH branches. That is the deterministic-iteration policy of
//     the #50/#214 family, and it is safe here specifically because these workers only emit
//     diagnostics, which are collected and sorted before printing -- submission order cannot reach
//     the output.
check_all_scope_usages :: proc(c: ^Checker) {
	// Determine thread count for parallel execution
	thread_count := 1
	if global_thread_pool != nil {
		thread_count = global_thread_pool.thread_count
	}

	// Sequential mode (single-threaded)
	if thread_count == 1 {
		// Check all file scopes
		// C++ Reference: checker.cpp check_all_scope_usages
		for file in sorted_files(c.info.files) {
			check_scope_usage_file_worker(c, file)
		}

		// Check all package scopes
		// C++ Reference: checker.cpp check_all_scope_usages
		for pkg in sorted_packages(&c.info) {
			check_scope_usage_pkg_worker(c, pkg)
		}
		return
	}

	// Parallel mode (multi-threaded)
	// Allocate task structs for parallel execution
	file_tasks := make([]Scope_Check_File_Task, len(c.info.files))
	defer delete(file_tasks)
	pkg_tasks := make([]Scope_Check_Pkg_Task, len(c.info.packages))
	defer delete(pkg_tasks)

	// Submit file scope checking tasks
	// C++ Reference: checker.cpp check_all_scope_usages
	file_idx := 0
	for file in sorted_files(c.info.files) {
		file_tasks[file_idx] = Scope_Check_File_Task{c = c, f = file}
		thread_pool_add_task(scope_check_file_worker_proc, &file_tasks[file_idx])
		file_idx += 1
	}

	// Submit package scope checking tasks
	// C++ Reference: checker.cpp check_all_scope_usages
	pkg_idx := 0
	for pkg in sorted_packages(&c.info) {
		pkg_tasks[pkg_idx] = Scope_Check_Pkg_Task{c = c, pkg = pkg}
		thread_pool_add_task(scope_check_pkg_worker_proc, &pkg_tasks[pkg_idx])
		pkg_idx += 1
	}

	// Wait for all workers to complete
	// C++ Reference: checker.cpp check_all_scope_usages
	thread_pool_wait()
}

