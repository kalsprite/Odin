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

C++ Reference: /mnt/c/odin/src/checker.cpp:2344-2364 (check_procedure_later)
               /mnt/c/odin/src/checker.cpp:6376-6436 (consume_proc_info, worker_proc)
               /mnt/c/odin/src/checker.cpp:6438-6480 (init_worker_data, check_procedure_bodies)
*/


// ======================================================================================
// GLOBAL STATE
// C++ Reference: /mnt/c/odin/src/checker.cpp:2337-2340
// ======================================================================================

// Debug flag to track all procedures for safety checks
// C++ Reference: checker.cpp:1 (#define DEBUG_CHECK_ALL_PROCEDURES 1)
// Enables tracking of all procedures in the all_procedures_queue
// for verifying none were missed during checking
DEBUG_CHECK_ALL_PROCEDURES :: true

// Global flag tracking if procedure bodies are being processed via worker queue
// C++ Reference: checker.cpp:2337 (gb_global std::atomic<bool> global_procedure_body_in_worker_queue)
global_procedure_body_in_worker_queue: bool = false

// Global flag set after procedure body checking completes
// C++ Reference: checker.cpp:2340 (gb_global std::atomic<bool> global_after_checking_procedure_bodies)
global_after_checking_procedure_bodies: bool = false

// Total count of procedure bodies successfully checked
// C++ Reference: checker.cpp:6374 (gb_global std::atomic<isize> total_bodies_checked)
total_bodies_checked: int = 0

// ======================================================================================
// WORKER DATA STRUCTURES
// C++ Reference: /mnt/c/odin/src/checker.cpp:6405-6410
// ======================================================================================

// Check_Procedure_Body_Worker_Data stores per-worker thread state for parallel checking
// C++ Reference: struct CheckProcedureBodyWorkerData in checker.cpp:6405-6408
Check_Procedure_Body_Worker_Data :: struct {
	c:       ^Checker, // C++ line 6406: Checker *c
	untyped: map[^ast.Expr]^Expr_Info, // C++ line 6407: UntypedExprInfoMap untyped
}

// Global array of worker data (one per thread)
// C++ Reference: checker.cpp:6410 (gb_global CheckProcedureBodyWorkerData *check_procedure_bodies_worker_data)
check_procedure_bodies_worker_data: []Check_Procedure_Body_Worker_Data

// NOTE: Proc_Tag is defined in checker.odin (lines 351-361)

// ======================================================================================
// PROCEDURE DEFERRAL
// C++ Reference: /mnt/c/odin/src/checker.cpp:2344-2364
// ======================================================================================

// check_procedure_later queues a procedure for deferred checking
// C++ Reference: checker.cpp:2344-2364 (check_procedure_later with ProcInfo *)
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
	// C++ Reference: checker.cpp:2348-2351
	if sync.atomic_load(&global_after_checking_procedure_bodies) {
		e := info.decl.entity
		if e != nil {
			debug_entity_type("CHECK PROCEDURE LATER!", e)
		}
	}

	// Decide how to queue based on worker queue status
	// C++ Reference: checker.cpp:2353-2357
	if sync.atomic_load(&global_procedure_body_in_worker_queue) {
		// Parallel mode: Add to worker task queue
		// C++ Reference: checker.cpp:2354
		thread_pool_add_task(check_proc_info_worker_proc, info)
	} else {
		// Sequential mode: Add to procs_to_check array
		// C++ Reference: checker.cpp:2356
		append(&c.procs_to_check, info)
	}

	// For debug builds, track all procedures in the all_procedures_queue
	// C++ Reference: checker.cpp:2359-2363
	when DEBUG_CHECK_ALL_PROCEDURES {
		assert(info != nil)
		assert(info.decl != nil)
		queue.mpsc_enqueue(&c.info.all_procedures_queue, info)
	}
}

// check_procedure_later_from_params creates a ProcInfo and queues it for checking
// C++ Reference: checker.cpp:2366-2378 (check_procedure_later with raw params)
//
// This overload constructs a ProcInfo from raw parameters before deferring.
// Used when we have the procedure components but not a ProcInfo struct yet.
check_procedure_later_from_params :: proc(c: ^Checker, file: ^ast.File, token: tokenizer.Token, decl: ^Decl_Info, type: ^Type, body: ^ast.Block_Stmt, tags: u64) {
	// Allocate and initialize ProcInfo
	// C++ Reference: checker.cpp:2367-2375
	info := new(Proc_Info)
	info.file = file
	info.token = token
	info.decl = decl
	info.type = type
	info.body = body
	info.tags = tags

	// Defer via the main check_procedure_later
	// C++ Reference: checker.cpp:2377
	check_procedure_later(c, info)
}

// check_procedure_later_from_entity extracts procedure info from an entity and defers it
// C++ Reference: checker.cpp:6113-6164 (check_procedure_later_from_entity)
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
	// C++ Reference: checker.cpp:6114-6116
	if e == nil || e.kind != .Procedure {
		return
	}

	// Get procedure variant
	proc_var, ok := e.variant.(Entity_Procedure)
	if !ok {
		return
	}

	// Skip foreign procedures (no body to check)
	// C++ Reference: checker.cpp:6117-6119
	if proc_var.is_foreign {
		return
	}

	// Skip already-checked procedures
	// C++ Reference: checker.cpp:6120-6122
	if sync.atomic_load(&e.proc_body_checked) {
		return
	}

	// Handle procedure aliases (@(link_name) overrides)
	// C++ Reference: checker.cpp:6123-6134
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
		// C++ Reference: checker.cpp:6132
		check_procedure_later_from_params(c, e.file, e.token, e.decl_info, e.type, nil, 0)
		return
	}

	// Validate type
	// C++ Reference: checker.cpp:6135-6139
	type := base_type(e.type)
	if type == nil {
		return
	}

	assert(type.kind == .Proc, "Expected procedure type") // C++ line 6139

	// Only check specialized polymorphic procedures
	// C++ Reference: checker.cpp:6141-6143
	proc_type, type_ok := type.variant.(Type_Proc)
	if !type_ok {
		return
	}

	if proc_type.is_polymorphic && !proc_type.is_poly_specialized {
		return // Unspecialized polymorphic procedures are not checked
	}

	// Validate decl_info exists
	// C++ Reference: checker.cpp:6145
	// Note: Entities from extracted runtime may not have decl_info
	if e.decl_info == nil {
		return
	}

	// Construct ProcInfo from entity
	// C++ Reference: checker.cpp:6147-6156
	pi := new(Proc_Info)
	pi.file = e.file
	pi.token = e.token
	pi.decl = e.decl_info
	pi.type = e.type

	// Extract procedure literal to get body and tags
	// C++ Reference: checker.cpp:6153-6156
	pl := e.decl_info.proc_lit
	assert(pl != nil)
	pi.body = pl.body.derived.(^ast.Block_Stmt)
	pi.tags = u64(transmute(u32)pl.tags)

	// Skip procedures without bodies
	// C++ Reference: checker.cpp:6157-6159
	if pi.body == nil {
		return
	}

	// Debug logging
	// C++ Reference: checker.cpp:6160-6162
	if from_msg != "" {
		debugf("CHECK PROCEDURE LATER [FROM %s]! %s :: %s {...}\n",
			from_msg, e.token.text, type_to_string(e.type))
	}

	// Queue the procedure for checking
	// C++ Reference: checker.cpp:6163
	check_procedure_later(c, pi)
}

// ======================================================================================
// PROCEDURE CONSUMPTION
// C++ Reference: /mnt/c/odin/src/checker.cpp:6376-6403
// ======================================================================================

// consume_proc_info attempts to check a procedure, handling dependencies
// C++ Reference: checker.cpp:6376-6403 (consume_proc_info)
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
	// C++ Reference: checker.cpp:6378-6383
	#partial switch sync.atomic_load(&pi.decl.proc_checked_state) {
	case .In_Progress:
		// Already being checked, don't re-enter
		// C++ Reference: checker.cpp:6379-6380
		return false
	case .Checked:
		// Already checked successfully
		// C++ Reference: checker.cpp:6381-6382
		return true
	}

	// Handle nested procedure dependencies
	// C++ Reference: checker.cpp:6385-6394
	if pi.decl.parent != nil && pi.decl.parent.entity != nil {
		parent := pi.decl.parent.entity

		// Only check nested procedures after their parent is checked
		// This prevents race conditions in multithreaded evaluation
		// In single-threaded mode, this should never trigger
		// C++ Reference: checker.cpp:6387-6393
		if parent.kind == .Procedure {
			parent_checked := sync.atomic_load(&parent.proc_body_checked)
			if !parent_checked {
				// Defer this procedure until parent is ready
				// C++ Reference: checker.cpp:6391-6392
				check_procedure_later(c, pi)
				return false
			}
		}
	}

	// Clear the untyped expression map before checking
	// C++ Reference: checker.cpp:6395-6397
	if untyped != nil {
		clear(untyped)
	}

	// Perform the actual procedure checking
	// C++ Reference: checker.cpp:6398-6401
	success := check_proc_info(c, pi, untyped)

	if success {
		// Increment total checked counter atomically
		// C++ Reference: checker.cpp:6399
		sync.atomic_add(&total_bodies_checked, 1)
		return true
	}

	return false
}

// ======================================================================================
// WORKER THREAD INFRASTRUCTURE
// C++ Reference: /mnt/c/odin/src/checker.cpp:6412-6436
// ======================================================================================

// check_proc_info_worker_proc is the worker thread entry point for parallel checking
// C++ Reference: checker.cpp:6412-6436 (WORKER_TASK_PROC(check_proc_info_worker_proc))
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
	// C++ Reference: checker.cpp:6413-6415
	thread_idx := current_thread_index()
	wd := &check_procedure_bodies_worker_data[thread_idx]
	untyped := &wd.untyped
	c := wd.c

	// Cast the data pointer to ProcInfo
	// C++ Reference: checker.cpp:6417
	pi := cast(^Proc_Info)data

	assert(pi.decl != nil)

	// Handle nested procedure dependencies
	// C++ Reference: checker.cpp:6420-6428
	if pi.decl.parent != nil && pi.decl.parent.entity != nil {
		parent := pi.decl.parent.entity

		// Only check nested procedures after parent's body is checked
		// This prevents race conditions in multithreaded evaluation
		// C++ Reference: checker.cpp:6422-6423
		if parent.kind == .Procedure {
			parent_checked := sync.atomic_load(&parent.proc_body_checked)
			if !parent_checked {
				// Re-queue this task for later (parent not ready)
				// C++ Reference: checker.cpp:6426-6427
				thread_pool_add_task(check_proc_info_worker_proc, pi)
				return 1 // Failure/retry
			}
		}
	}

	// Clear untyped map before checking
	// C++ Reference: checker.cpp:6430
	clear(untyped)

	// Check the procedure
	// C++ Reference: checker.cpp:6431-6434
	if check_proc_info(c, pi, untyped) {
		// Success: increment atomic counter
		// C++ Reference: checker.cpp:6432
		sync.atomic_add(&total_bodies_checked, 1)
		return 0 // Success
	}

	return 1 // Failure
}

// ======================================================================================
// WORKER INITIALIZATION
// C++ Reference: /mnt/c/odin/src/checker.cpp:6438-6447
// ======================================================================================

// check_init_worker_data initializes per-worker thread data for parallel checking
// C++ Reference: checker.cpp:6438-6447 (check_init_worker_data)
//
// Allocates and initializes worker data structures for each thread in the thread pool.
// Each worker gets its own Checker pointer and untyped expression map to avoid contention.
//
// Initializes worker data for all threads in the thread pool
check_init_worker_data :: proc(c: ^Checker) {
	// Get thread count from global thread pool
	// C++ Reference: checker.cpp:6439
	// u32 thread_count = cast(u32)global_thread_pool.threads.count;
	thread_count := 1
	if global_thread_pool != nil {
		thread_count = global_thread_pool.thread_count
	}

	// Allocate worker data array
	// C++ Reference: checker.cpp:6441
	// check_procedure_bodies_worker_data = permanent_alloc_array<CheckProcedureBodyWorkerData>(thread_count)
	check_procedure_bodies_worker_data = make([]Check_Procedure_Body_Worker_Data, thread_count)

	// Initialize each worker's data
	// C++ Reference: checker.cpp:6443-6446
	for i in 0 ..< thread_count {
		check_procedure_bodies_worker_data[i].c = c
		check_procedure_bodies_worker_data[i].untyped = make(map[^ast.Expr]^Expr_Info)
	}
}

// ======================================================================================
// MAIN PROCEDURE CHECKING ENTRY POINT
// C++ Reference: /mnt/c/odin/src/checker.cpp:6449-6480
// ======================================================================================

// check_procedure_bodies is the main entry point for checking all queued procedure bodies
// C++ Reference: checker.cpp:6449-6480 (check_procedure_bodies)
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
	// C++ Reference: checker.cpp:6452-6455
	thread_count := 1
	if global_thread_pool != nil && !build_context.no_threaded_checker {
		thread_count = global_thread_pool.thread_count
	}

	// Sequential mode (single-threaded)
	// C++ Reference: checker.cpp:6457-6465
	if thread_count == 1 {
		// Use worker_data[0]'s untyped map
		// C++ Reference: checker.cpp:6458
		untyped := &check_procedure_bodies_worker_data[0].untyped

		// Process all procedures in procs_to_check array
		// C++ Reference: checker.cpp:6459-6461
		for i in 0 ..< len(c.procs_to_check) {
			// Cooperative cancellation, mirroring the worker path below: once the error cap
			// is hit every further diagnostic is dropped, so there is nothing to gain from
			// checking the remaining bodies. See CPP_DEVIATIONS.md [EMBED-1].
			if error_limit_reached() {
				break
			}
			consume_proc_info(c, c.procs_to_check[i], untyped)
		}

		// Clear the procs_to_check array
		// C++ Reference: checker.cpp:6462
		clear(&c.procs_to_check)

		// Debug output
		// C++ Reference: checker.cpp:6464
		debugf("Total Procedure Bodies Checked: %d\n", sync.atomic_load(&total_bodies_checked))

		return
	}

	// Parallel mode (multi-threaded)
	// C++ Reference: checker.cpp:6468-6479

	// Set global flag to indicate worker queue is active
	// C++ Reference: checker.cpp:6468
	sync.atomic_store(&global_procedure_body_in_worker_queue, true)

	// Add all procedures to worker task queue
	// C++ Reference: checker.cpp:6470-6475
	prev_procs_to_check_count := len(c.procs_to_check)
	for i in 0 ..< len(c.procs_to_check) {
		thread_pool_add_task(check_proc_info_worker_proc, c.procs_to_check[i])
	}
	assert(prev_procs_to_check_count == len(c.procs_to_check))
	clear(&c.procs_to_check)

	// Wait for all workers to complete
	// C++ Reference: checker.cpp:6477
	thread_pool_wait()

	// Clear worker queue flag
	// C++ Reference: checker.cpp:6479
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)

	// Debug output
	debugf("Total Procedure Bodies Checked: %d\n", sync.atomic_load(&total_bodies_checked))
}

// ======================================================================================
// CORE PROCEDURE CHECKING LOGIC
// C++ Reference: /mnt/c/odin/src/checker.cpp:6167-6282
// ======================================================================================

// check_proc_info validates and checks a single procedure's body
// C++ Reference: checker.cpp:6167-6282 (check_proc_info)
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
	// C++ Reference: checker.cpp:6168-6173
	if pi == nil {
		return false
	}
	if pi.type == nil {
		return false
	}

	// Check procedure state with mutex protection
	// C++ Reference: checker.cpp:6175-6196
	decl := pi.decl
	if decl == nil {
		return false
	}

	// State machine transition, guarded by this declaration's own mutex.
	// C++ Reference: checker.cpp:6175-6196 - the C++ MUTEX_GUARD is scoped to exactly this
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
		// C++ Reference: checker.cpp:6181-6195
		state := sync.atomic_load(&decl.proc_checked_state)
		#partial switch state {
		case .In_Progress:
			// Currently being checked (by another thread in parallel mode)
			// C++ Reference: checker.cpp:6182-6186
			return false

		case .Checked:
			// Already checked successfully
			// C++ Reference: checker.cpp:6187-6191
			if decl.entity != nil {
				assert(sync.atomic_load(&decl.entity.proc_body_checked))
			}
			return true

		case .Unchecked:
			// Proceed with checking
			// C++ Reference: checker.cpp:6192-6194
			break
		}

		// Claim the procedure. From here on this thread owns the body check, and every
		// exit path below must move the state off In_Progress.
		// C++ Reference: checker.cpp:6196
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.In_Progress)
	}

	// Validate procedure type
	// C++ Reference: checker.cpp:6198-6200
	assert(pi.type.kind == .Proc)
	pt, pt_ok := &pi.type.variant.(Type_Proc)
	if !pt_ok {
		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
		return false
	}

	name := pi.token.text

	// Check for unspecialized polymorphic procedures
	// C++ Reference: checker.cpp:6202-6210
	if pt.is_polymorphic && !pt.is_poly_specialized {
		token := pi.token
		if pi.poly_def_node != nil {
			// Use polymorphic definition node's token if available
			// C++ Reference: checker.cpp:6204-6206
			token = ast_token(pi.poly_def_node)
		}

		// Error: Cannot check unspecialized polymorphic procedures
		// C++ Reference: checker.cpp:6207
		error(token, "Unspecialized polymorphic procedure '%s'", name)

		sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
		return false
	}

	// Skip unused specialized polymorphic procedures
	// C++ Reference: checker.cpp:6212-6221
	if pt.is_polymorphic && pt.is_poly_specialized {
		e := pi.decl.entity
		assert(e != nil)
		if .Used not_in e.flags {
			// Never used, don't check
			// C++ Reference: checker.cpp:6216-6218
			// NOTE: This may need to be checked later if used elsewhere
			sync.atomic_store(&decl.proc_checked_state, Proc_Checked_State.Unchecked)
			return false
		}
	}

	// Create and setup checker context
	// C++ Reference: checker.cpp:6223-6226
	ctx := make_checker_context(c)
	defer destroy_checker_context(&ctx)

	reset_checker_context(&ctx, pi.file)
	ctx.decl = pi.decl

	// Process procedure tags
	// C++ Reference: checker.cpp:6228-6248
	tags := pi.tags

	// Extract tag bits using direct bitmask (Proc_Tag values are already 1<<n)
	// C++ Reference: checker.cpp:6228-6232
	bounds_check := (tags & u64(Proc_Tag.Bounds_Check)) != 0
	no_bounds_check := (tags & u64(Proc_Tag.No_Bounds_Check)) != 0
	type_assert := (tags & u64(Proc_Tag.Type_Assert)) != 0
	no_type_assert := (tags & u64(Proc_Tag.No_Type_Assert)) != 0

	// Apply bounds checking flags
	// C++ Reference: checker.cpp:6234-6240
	if bounds_check {
		ctx.state_flags += {.Bounds_Check}
		ctx.state_flags -= {.No_Bounds_Check}
	} else if no_bounds_check {
		ctx.state_flags += {.No_Bounds_Check}
		ctx.state_flags -= {.Bounds_Check}
	}

	// Apply type assertion flags
	// C++ Reference: checker.cpp:6242-6248
	if type_assert {
		ctx.state_flags += {.Type_Assert}
		ctx.state_flags -= {.No_Type_Assert}
	} else if no_type_assert {
		ctx.state_flags += {.No_Type_Assert}
		ctx.state_flags -= {.Type_Assert}
	}

	// Check the procedure body
	// C++ Reference: checker.cpp:6250
	body_was_checked := check_proc_body(&ctx, pi.token, pi.decl, pi.type, pi.body)

	// Update entity state based on checking result
	// C++ Reference: checker.cpp:6252-6268
	if body_was_checked {
		// Success: Mark as checked (atomic store for thread safety)
		// C++ Reference: checker.cpp:6253-6259
		//
		// DEVIATION (ordering): C++ stores ProcCheckedState_Checked first and sets
		// EntityFlag_ProcBodyChecked second. It can afford to, because its
		// proc_checked_mutex is held for the whole of check_proc_body_for_proc_info - so
		// no other thread can be inside the `case ProcCheckedState_Checked` arm that
		// asserts on the flag (checker.cpp:6532-6536) while this window is open.
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
		// C++ Reference: checker.cpp:6260-6267
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
	// C++ Reference: checker.cpp:6270
	add_untyped_expressions(&c.info, ctx.untyped)

	// Check dependencies and queue unchecked procedures
	// C++ Reference: checker.cpp:6272-6279
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
// C++ Reference: checker.cpp:1695-1697 (destroy_checker_context)
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
// C++ Reference: checker.cpp:6481-6493
add_untyped_expressions :: proc(info: ^Checker_Info, untyped: ^map[^ast.Expr]^Expr_Info) {
	if untyped == nil {
		return
	}

	// Enqueue all untyped expressions to global queue
	// C++ Reference: checker.cpp:6485-6491
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
	// C++ Reference: checker.cpp:6492
	clear(untyped)
}

// ======================================================================================
// PROCEDURE BODY CHECKING
// C++ Reference: /mnt/c/odin/src/check_decl.cpp:2003-2198
// ======================================================================================

// Proc_Using_Var pairs a using parameter entity with its generated using variable
// C++ Reference: check_decl.cpp:2003-2006
Proc_Using_Var :: struct {
	e:    ^Entity, // Original parameter entity (C++ line 2004)
	uvar: ^Entity, // Generated using variable entity (C++ line 2005)
}

// evaluate_where_clauses checks that all where clauses evaluate to true
// C++ Reference: check_expr.cpp:6717-6797
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
	// C++ Reference: check_expr.cpp:6718
	if clauses == nil || len(clauses) == 0 {
		return true
	}

	// Check each clause
	// C++ Reference: check_expr.cpp:6719-6792
	for clause in clauses {
		operand := Operand{}
		check_expr(ctx, &operand, clause)

		// Must be a constant
		// C++ Reference: check_expr.cpp:6722-6725
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
		// C++ Reference: check_expr.cpp:6726-6729
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
		// C++ Reference: check_expr.cpp:6730-6776
		if !value_bool {
			if print_err {
				// C++ opens an ERROR_BLOCK here (check_expr.cpp:7113) so the header, the
				// definition list and the caller-location line are flushed together. Without
				// it the unblocked error_line output raced ahead of the error() -- which goes
				// through the collector and is position-sorted -- so the continuation lines
				// appeared at the very top of the output, detached from their own diagnostic.
				begin_error_block()
				defer end_error_block()

				// Display error with clause expression
				// C++ Reference: check_expr.cpp:7115-7117
				clause_str := expr_to_string(clause)
				defer delete(clause_str)
				error(clause, "'where' clause evaluated to false:\n\t%s", clause_str)

				// Display polymorphic definitions from scope
				// C++ Reference: check_expr.cpp:6746-6778
				if scope != nil {
					print_count := 0

					// C++ (check_expr.cpp:7121) walks scope->elements in raw hash order.
					// Iterating an Odin map here made this block nondeterministic: ten runs of
					// the SAME binary on the SAME input produced SIX different orderings of
					// the definition list. sweep_det.sh runs under `setarch -R`, so the sweep
					// cannot see it. Sorted by name, as in check_did_you_mean_scope; C++'s own
					// order is a property of its hash table and is not reproducible.
					// LEDGER task 277.
					ordered := make([dynamic]^Entity, 0, len(scope.elements), context.temp_allocator)
					for _, e in scope.elements {
						append(&ordered, e)
					}
					slice.sort_by(ordered[:], proc(a, b: ^Entity) -> bool {
						return a.token.text < b.token.text
					})

					// Iterate through scope elements and display TypeName and Constant entities
					// C++ Reference: check_expr.cpp:7121-7150
					for e in ordered {
						#partial switch e.kind {
						case .Type_Name:
							// Display type definitions: name :: type;
							// C++ Reference: check_expr.cpp:6751-6758
							// Note: The C++ comment says to print header only on first entity,
							// but then doesn't actually use that check (line 6752 is commented out)
							// We'll print without the header for consistency with C++
							type_str := type_to_string(e.type)
							error_line("\t\t%s :: %s;\n", e.token.text, type_str)
							print_count += 1

						case .Constant:
							// Display constant definitions
							// C++ Reference: check_expr.cpp:6760-6774
							if print_count == 0 {
								error_line("\n\tWith the following definitions:\n")
							}

							// Get the constant value as a string
							value_str := exact_value_to_string(e.variant.(Entity_Constant).value)
							defer delete(value_str)

							if is_type_untyped(e.type) {
								// Untyped constant: name :: value;
								// C++ Reference: check_expr.cpp:6764-6765
								error_line("\t\t%s :: %s;\n", e.token.text, value_str)
							} else {
								// Typed constant: name : type : value;
								// C++ Reference: check_expr.cpp:6766-6770
								type_str := type_to_string(e.type)
								error_line("\t\t%s : %s : %s;\n", e.token.text, type_str, value_str)
							}
							print_count += 1
						}
					}
				}

				// C++ check_expr.cpp:7153-7156. Unlike the two "expects a constant boolean
				// evaluation" branches above (C++ 7105/7109), which DO emit a second
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
		// C++ Reference: check_expr.cpp:6780-6791
		if ast_file_vet_style(ctx.file) {
			c := unparen_expr(clause)
			// Check if it's a binary expression with Cmp_And (&&)
			// C++ Reference: check_expr.cpp:6781-6791
			if binary, ok := c.derived.(^ast.Binary_Expr); ok {
				if binary.op.kind == .Cmp_And {
					// Error: Prefer comma over &&
					// C++ Reference: check_expr.cpp:6783-6789
					error(c, "Prefer to separate 'where' clauses with a comma rather than '&&'")

					// Show suggestion with left and right parts
					// C++ Reference: check_expr.cpp:6784-6787
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
// C++ Reference: checker.cpp:554-557
// Note: In Odin AST, nodes don't store their file, so this always returns empty flags
// Callers should use check_vet_flags_from_context instead
check_vet_flags_from_node :: proc(node: ^ast.Node) -> Vet_Flag {
	// In Odin AST, nodes don't have a file() method like C++
	// We would need to track this separately via Checker_Info
	return {} // Empty bit_set = no vet flags
}

// check_vet_flags is overloaded to accept context or node
check_vet_flags :: proc {
	check_vet_flags_from_context,
	check_vet_flags_from_node,
}

// in_vet_packages checks if a file's package should be vetted
// C++ Reference: parser.cpp:5-15
//
// Returns true if the file's package should be included in vetting.
// Logic:
// - If file is nil → return true (vet it)
// - If file's package is nil → return true (vet it)
// - If vet_packages list is empty → return true (vet all packages)
// - Otherwise → return true if package name is in vet_packages set
//
// in_vet_packages checks if a file's package is in the vet packages list
// C++ Reference: parser.cpp:6-15
in_vet_packages :: proc(file: ^ast.File) -> bool {
	// Check if file is nil
	// C++ Reference: parser.cpp:6-8
	if file == nil {
		return true
	}

	// Check if package is nil
	// C++ Reference: parser.cpp:9-11
	if file.pkg == nil {
		return true
	}

	// Check build_context.vet_packages
	// C++ Reference: parser.cpp:12-15
	if len(build_context.vet_packages) == 0 {
		// Empty vet_packages means vet all packages
		return true
	}

	// Check if package name is in vet_packages set
	return file.pkg.name in build_context.vet_packages
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

// scope_insert_no_mutex is defined in scope.odin

// add_deps_from_child_to_parent propagates dependencies from nested to parent proc
// C++ Reference: check_decl.cpp:1972-2001
//
// This function copies all dependencies and type_info dependencies from a nested
// procedure's declaration to its parent procedure's declaration. This is needed
// because nested procedures (lambdas) can reference entities that the parent
// procedure must also depend on for proper dependency analysis.
//
// The function skips propagation if the parent scope is a File, Package, or Global
// scope, as those are not procedure scopes.
add_deps_from_child_to_parent :: proc(decl: ^Decl_Info) {
	// Early validation
	// C++ Reference: check_decl.cpp:1973
	if decl == nil || decl.parent == nil {
		return
	}

	parent_scope := decl.parent.scope

	// Skip if parent is file/pkg/global scope
	// C++ Reference: check_decl.cpp:1975-1976
	if parent_scope != nil && (.File in parent_scope.flags || .Pkg in parent_scope.flags || .Global in parent_scope.flags) {
		return
	}

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
		for type_dep in decl.type_info_deps {
			decl.parent.type_info_deps[type_dep] = {}
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
	// C++ Reference: checker.cpp:850
	check_scope_usage_internal(c, scope, vet_flags, false)

	// Recursively check child scopes (except Proc/Type/File scopes)
	// C++ Reference: checker.cpp:852-858
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
	// C++ Reference: checker.cpp:631-636
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
		// C++ Reference: checker.cpp:719-725
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
	// C++ Reference: checker.cpp:644-646
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
	// C++ Reference: checker.cpp:651-653
	if .Param in e.flags {
		return false
	}

	// Variables in global/file/proc scopes don't shadow
	// C++ Reference: checker.cpp:655-657
	if e.scope != nil && (.Global in e.scope.flags || .File in e.scope.flags || .Proc in e.scope.flags) {
		return false
	}

	// Check parent scope (skip if global/file)
	// C++ Reference: checker.cpp:659-662
	parent := e.scope.parent if e.scope != nil else nil
	if parent == nil {
		return false
	}
	if .Global in parent.flags || .File in parent.flags {
		return false
	}

	// Look for shadowed entity in parent scope
	// C++ Reference: checker.cpp:664-670
	shadowed := scope_lookup(parent, name)
	if shadowed == nil {
		return false
	}
	if shadowed.kind != .Variable {
		return false
	}

	// Allow shadowing of global/file scope (commented out in C++)
	// C++ Reference: checker.cpp:672-674

	// Entities must be in the same file
	// C++ Reference: checker.cpp:676-679
	if e.token.pos.file != shadowed.token.pos.file {
		return false
	}

	// Shadowed identifier must appear before this one
	// C++ Reference: checker.cpp:680-684
	if token_pos_cmp(shadowed.token.pos, e.token.pos) > 0 {
		return false
	}

	// If types differ, don't complain
	// C++ Reference: checker.cpp:685-688
	if !are_types_identical(e.type, shadowed.type) {
		return false
	}

	// Ignore intentional redeclaration (x := x)
	// C++ Reference: checker.cpp:690-700
	if .Using not_in e.flags && e.kind == .Variable {
		if e_var, ok := &e.variant.(Entity_Variable); ok {
			if check_vet_shadowing_assignment(c, shadowed, e_var.init_expr) {
				return false
			}
		}
	}

	// Report shadowing
	// C++ Reference: checker.cpp:702-706
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
	// C++ Reference: checker.cpp:737
	sync.rw_mutex_shared_lock(&scope.mutex)
	defer sync.rw_mutex_shared_unlock(&scope.mutex)

	// Check each entity in the scope
	// C++ Reference: checker.cpp:738-803
	for _, e in scope.elements {
		if e == nil {
			continue
		}

		// Use per-entity vet flags if requested
		// C++ Reference: checker.cpp:742-745
		vet_flags := original_vet_flags
		if per_entity {
			vet_flags = ast_file_vet_flags(e.file)
		}

		// Extract individual vet flag checks
		// C++ Reference: checker.cpp:747-752
		vet_unused := Vet_Flag_Unused & vet_flags != {}
		vet_shadowing := (.Shadowing in vet_flags) || (.Using_Stmt in vet_flags)
		vet_unused_procedures := .Unused_Procedures in vet_flags
		if vet_unused_procedures && e.pkg != nil && e.pkg.kind == .Runtime {
			vet_unused_procedures = false
		}

		// Check for unused entities
		// C++ Reference: checker.cpp:754-777
		ve_unused := Vetted_Entity{}
		ve_shadowed := Vetted_Entity{}
		is_unused := false

		if vet_unused && check_vet_unused(c, e, &ve_unused) {
			is_unused = true
		} else {
		}
		if vet_unused_procedures && e.kind == .Procedure {
			// Special handling for unused procedures
			// C++ Reference: checker.cpp:759-776
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
		// C++ Reference: checker.cpp:778
		is_shadowed := vet_shadowing && check_vet_shadowing(c, e, &ve_shadowed)

		// Add to vetted entities list
		// C++ Reference: checker.cpp:779-786
		if is_unused && is_shadowed {
			ve_both := ve_shadowed
			ve_both.kind = .Shadowed_And_Unused
			append(&vetted_entities, ve_both)
		} else if is_unused {
			append(&vetted_entities, ve_unused)
		} else if is_shadowed {
			append(&vetted_entities, ve_shadowed)
		} else if e.kind == .Variable && (.Param not_in e.flags && .Using not_in e.flags && .Static not_in e.flags && .Field not_in e.flags) {
			// Check for large stack allocations
			// C++ Reference: checker.cpp:787-802
			if e_var, ok := &e.variant.(Entity_Variable); ok && !e_var.is_global && e.type != nil {
				sz := type_size_of(e.type)
				// Warn about allocations >256 KiB
				// C++ Reference: checker.cpp:789-791
				if sz > (1 << 18) {
					is_ref := false
					if .For_Value in e.flags {
						is_ref = type_deref(e_var.for_loop_parent_type) != nil
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
	// C++ Reference: checker.cpp:806
	slice.sort_by_cmp(vetted_entities[:], vetted_entity_variable_pos_cmp)

	// Report errors for vetted entities
	// C++ Reference: checker.cpp:808-844
	for ve in vetted_entities {
		e := ve.entity
		other := ve.other
		name := e.token.text

		// Use per-entity vet flags if requested
		// C++ Reference: checker.cpp:813-816
		vet_flags := original_vet_flags
		if per_entity {
			vet_flags = ast_file_vet_flags(e.file)
		}

		// Report based on kind
		// C++ Reference: checker.cpp:818-843
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
	// C++ Reference: check_decl.cpp:2010-2012
	if body == nil {
		return false
	}
	// Note: body is already typed as ^ast.Block_Stmt, so type system guarantees it's a block

	// Determine procedure name for error messages
	// C++ Reference: check_decl.cpp:2015-2021
	proc_name := token.text if token.kind == .Ident else "(anonymous-procedure)"

	// Create local context copy (allows modification without affecting caller)
	// C++ Reference: check_decl.cpp:2023-2024
	new_ctx := ctx_^
	ctx := &new_ctx

	// Validate procedure type
	// C++ Reference: check_decl.cpp:2026
	assert(type.kind == .Proc)

	// Setup procedure checking context
	// C++ Reference: check_decl.cpp:2028-2033
	ctx.scope = decl.scope
	ctx.decl = decl
	ctx.proc_name = proc_name
	ctx.curr_proc_decl = decl
	ctx.curr_proc_sig = type
	ctx.curr_proc_calling_convention = type.variant.(Type_Proc).calling_convention

	// Link parent procedure for nested procs
	// C++ Reference: check_decl.cpp:2035-2037
	if decl.parent != nil && decl.entity != nil && decl.parent.entity != nil {
		decl.entity.parent_proc_decl = decl.parent
	}

	// Validate calling convention (disallow "none" in non-runtime packages)
	// C++ Reference: check_decl.cpp:2039-2045
	if ctx.pkg == nil {
	} else {
	}
	if ctx.pkg != nil && ctx.pkg.name != "runtime" {
		proc_type := type.variant.(Type_Proc)
		#partial switch proc_type.calling_convention {
		case .None:
			error(body, "Procedures with the calling convention \"none\" are not allowed a body")
		}
	}

	// Process 'using' parameters (expand struct fields into scope)
	// C++ Reference: check_decl.cpp:2049-2103
	//
	// This section handles procedure parameters marked with 'using'.
	// For each 'using' parameter of struct type, we create a using variable
	// entity for each field in the struct and add them to the procedure scope.
	using_entities: [dynamic]Proc_Using_Var
	defer delete(using_entities)

	proc_type := type.variant.(Type_Proc)
	if proc_type.param_count > 0 {
		// Iterate over all parameters
		// C++ Reference: check_decl.cpp:2054-2101
		params := proc_type.params.variant.(Type_Tuple)
		for e in params.variables {
			// Skip non-variables
			// C++ Reference: check_decl.cpp:2057-2059
			if e == nil {
				continue
			}
			if e.kind != .Variable {
				continue
			}

			// Check for unspecialized polymorphic types in parameters
			// C++ Reference: check_decl.cpp:2060-2069
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
			// C++ Reference: check_decl.cpp:2071-2073
			if .Using not_in e.flags {
				continue
			}

			// Using requires non-blank identifier
			// C++ Reference: check_decl.cpp:2074-2077
			if is_blank_ident(e.token.text) {
				error(e.token, "'using' a procedure parameter requires a non blank identifier")
				break
			}

			// Determine if parameter is passed by value
			// C++ Reference: check_decl.cpp:2079
			is_value := (.Value in e.flags) && !is_type_pointer(e.type)

			// Get base struct type (deref pointers)
			// C++ Reference: check_decl.cpp:2081
			t := base_type(type_deref(e.type))

			// Using only works with struct types
			// C++ Reference: check_decl.cpp:2082-2100
			if t.kind == .Struct {
				struct_scope := t.variant.(Type_Struct).scope
				assert(struct_scope != nil)

				// Lock scope mutex for thread safety
				// C++ Reference: check_decl.cpp:2085
				sync.rw_mutex_shared_lock(&struct_scope.mutex)
				defer sync.rw_mutex_shared_unlock(&struct_scope.mutex)

				// Create using variable for each struct field
				// C++ Reference: check_decl.cpp:2086-2095
				for _, field in struct_scope.elements {
					if field.kind == .Variable {
						// Allocate using variable entity
						// C++ Reference: check_decl.cpp:2089
						uvar := alloc_entity_using_variable(e, field.token, field.type, nil)

						// Propagate Value flag if needed
						// C++ Reference: check_decl.cpp:2090
						if is_value {
							uvar.flags += {.Value}
						}

						// Add to using entities list
						// C++ Reference: check_decl.cpp:2092-2093
						puv := Proc_Using_Var {
							e    = e,
							uvar = uvar,
						}
						append(&using_entities, puv)
					}
				}
			} else {
				// Error: using only works with structs
				// C++ Reference: check_decl.cpp:2098-2100
				error(e.token, "'using' can only be applied to variables of type struct")
				break
			}
		}
	}

	// Insert using variables into procedure scope (first pass, check for conflicts)
	// C++ Reference: check_decl.cpp:2105-2117
	// Thread-safe scope modification
	{
		sync.rw_mutex_lock(&ctx.scope.mutex)
		defer sync.rw_mutex_unlock(&ctx.scope.mutex)

		for puv in using_entities {
			e := puv.e
			uvar := puv.uvar

			// Check for naming conflicts in scope
			// C++ Reference: check_decl.cpp:2109
			prev := scope_insert_no_mutex(ctx.scope, uvar)
			if prev != nil {
				// Error: namespace collision
				// C++ Reference: check_decl.cpp:2110-2114
				error(e.token, "Namespace collision while 'using' procedure argument '%s' of: %s", e.token.text, prev.token.text)
				error_line("%s != %s\n", uvar.token.text, prev.token.text)
				break
			}
		}
	}

	// Evaluate where clauses
	// C++ Reference: check_decl.cpp:2120-2124
	where_clauses: []^ast.Expr = nil
	if decl.proc_lit != nil {
		where_clauses = decl.proc_lit.where_clauses
	}
	where_clause_ok := evaluate_where_clauses(ctx, nil, decl.scope, where_clauses, !decl.where_clauses_evaluated)
	if !where_clause_ok {
		// Where clauses failed, don't check body
		// C++ Reference: check_decl.cpp:2121-2123
		return false
	}
	decl.where_clauses_evaluated = true

	// Open procedure body scope
	// C++ Reference: check_decl.cpp:2126
	check_open_scope(ctx, body)
	{
		// Set scope's declaration info
		// C++ Reference: check_decl.cpp:2128
		ctx.scope.decl_info = decl

		// Insert using variables into body scope (second pass, no error checking)
		// C++ Reference: check_decl.cpp:2130-2135
		for puv in using_entities {
			uvar := puv.uvar
			prev := scope_insert(ctx.scope, uvar)
			_ = prev // Ignore conflicts (already checked above)
			// C++ Reference: check_decl.cpp:2133: "Don't err here"
		}

		// Sanity checks for procedure state
		// C++ Reference: check_decl.cpp:2137-2142
		assert(decl.proc_checked_state != .Checked)
		if decl.defer_use_checked {
			assert(is_type_polymorphic(type, true))
			// This should never happen in production
			// C++ Reference: check_decl.cpp:2140
			error(token, "Defer Use Checked: %s", decl.entity.token.text)
			assert(!decl.defer_use_checked)
		}

		// Check all statements in the procedure body
		// C++ Reference: check_decl.cpp:2144
		check_stmt_list(ctx, body.stmts, {.Check_Scope_Decls})

		// Mark defer use as checked
		// C++ Reference: check_decl.cpp:2146
		decl.defer_use_checked = true

		// Validate all value declarations have entities
		// C++ Reference: check_decl.cpp:2188-2198
		// NOTE: In Odin, entities are stored in ast_entity_map, not on AST nodes
		for stmt in body.stmts {
			if stmt.derived != nil {
				if vd, ok := stmt.derived.(^ast.Value_Decl); ok {
					for name in vd.names {
						// Check if name is an identifier (not blank, implicit, etc.)
						if ident, is_ident := name.derived.(^ast.Ident); is_ident {
							if !is_blank_ident(ident.name) {
								// Get entity directly from AST node
								// C++ Reference: check_decl.cpp:2193 (name->Ident.entity)
								entity := cast(^Entity)cast(rawptr)ident.entity
								assert(entity != nil, "Value declaration identifier must have entity")
							}
						}
					}
				}
			}
		}

		// Validate return statements for procedures with results
		// C++ Reference: check_decl.cpp:2161-2169
		if proc_type.result_count > 0 {
			if !check_is_terminating(ctx, &body.node, "") {
				if token.kind == .Ident {
					error(body.close, "Missing return statement at the end of the procedure '%s'", token.text)
				} else {
					// Anonymous procedure (lambda)
					// C++ Reference: check_decl.cpp:2166-2167
					error(body.close, "Missing return statement at the end of the procedure")
				}
			}
		} else if proc_type.diverging {
			// Validate diverging procedures have diverging call
			// C++ Reference: check_decl.cpp:2170-2179
			if !check_is_terminating(ctx, &body.node, "") {
				if token.kind == .Ident {
					error(body.close, "Missing diverging call at the end of the procedure '%s'", token.text)
				} else {
					// Anonymous procedure (lambda)
					// C++ Reference: check_decl.cpp:2175-2176
					error(body.close, "Missing diverging call at the end of the procedure")
				}
			}
		}
	}
	// Close procedure body scope
	// C++ Reference: check_decl.cpp:2182
	check_close_scope(ctx)

	// Check for unused variables and shadowing
	// C++ Reference: check_decl.cpp:2184
	check_scope_usage(ctx.checker, ctx.scope, check_vet_flags(body))

	// Propagate dependencies from nested proc to parent
	// C++ Reference: check_decl.cpp:2186
	add_deps_from_child_to_parent(decl)

	// Track variadic reuse optimization data
	// C++ Reference: check_decl.cpp:2188-2195
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
	// C++ Reference: check_decl.cpp:2197
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
type_align_of :: proc(t: ^Type) -> int {
	if t == nil {
		return 1
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
		#partial switch basic.kind {
		case .String, .String16, .Int, .Uint:
			return 8 // int_size
		case .Cstring, .Cstring16, .Uintptr, .Rawptr:
			return 8 // ptr_size
		case .Any, .Typeid:
			return 8
		case .Complex32, .Complex64, .Complex128:
			return max(basic.size / 2, 1)
		case .Quaternion64, .Quaternion128, .Quaternion256:
			return max(basic.size / 4, 1)
		}
		// Every remaining basic (the plain integers, floats, booleans and runes) aligns
		// to its own size.
		return min(basic.size, 16) if basic.size > 0 else 1

	case .Pointer, .Multi_Pointer, .Soa_Pointer:
		return 8 // 64-bit pointers

	case .Proc:
		return 8 // Procedure pointers

	case .Array:
		arr := bt.variant.(Type_Array)
		return type_align_of(arr.elem)

	case .Enumerated_Array:
		earr := bt.variant.(Type_Enumerated_Array)
		return type_align_of(earr.elem)

	case .Slice:
		return 8 // Pointer alignment

	case .Dynamic_Array:
		return 8 // Pointer alignment

	case .Map:
		return 8 // Pointer alignment

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
			field_align := type_align_of(entity_type(field))
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
		if struc.custom_max_field_align != 0 && struc.custom_max_field_align > struc.custom_min_field_align {
			max_align = min(max_align, int(struc.custom_max_field_align))
		}
		return max_align

	case .Union:
		un := bt.variant.(Type_Union)
		// Union alignment is the max alignment of its variants
		max_align := 1
		for variant in un.variants {
			variant_align := type_align_of(variant)
			if variant_align > max_align {
				max_align = variant_align
			}
		}
		return max_align

	case .Enum:
		enum_type := bt.variant.(Type_Enum)
		return type_align_of(enum_type.base_type)

	case .Bit_Set:
		bs := bt.variant.(Type_Bit_Set)
		if bs.underlying != nil {
			return type_align_of(bs.underlying)
		}
		return 8 // Default

	case .Simd_Vector:
		sv := bt.variant.(Type_Simd_Vector)
		// SIMD vectors have alignment equal to their total size
		elem_size := type_size_of(sv.elem)
		total_size := int(sv.count) * elem_size
		// Round up to power of 2
		return min(total_size, 64) if total_size > 0 else 1

	case .Matrix:
		mat := bt.variant.(Type_Matrix)
		return type_align_of(mat.elem)

	case:
		return 8 // Default to pointer alignment
	}
}

// ======================================================================================
// PROCEDURE VALIDATION
// C++ Reference: /mnt/c/odin/src/checker.cpp:6288-6371, 7085-7134
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
	// C++ Reference: checker.cpp:7098-7100 (if (ap != bp) { order_a < order_b})
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
// C++ Reference: checker.cpp:7122-7124
//
// Fini procedures are sorted in reverse order of init procedures.
// This ensures cleanup happens in reverse order of initialization.
fini_procedures_cmp_generic :: proc(a_ptr, b_ptr: rawptr, user_data: rawptr) -> slice.Ordering {
	// Reverse the comparison by swapping arguments
	// C++ Reference: checker.cpp:7123 (return init_procedures_cmp(b, a))
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
	// C++ Reference: checker.cpp:6370
	remove_neighbouring_duplicate_entries_from_sorted_array(&c.info.testing_procedures)
}

// check_unchecked_bodies detects procedures with unchecked bodies
// C++ Reference: checker.cpp:6288-6320
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
	// C++ Reference: checker.cpp:6300
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)

	// Find all entities in the minimum dependency set and schedule them
	// C++ Reference: checker.cpp:6302-6306
	for entity in c.info.entities {
		if entity.min_dep_count > 0 {
			// This entity is in the dependency graph, ensure its procedure is checked
			check_procedure_later_from_entity(c, entity, "check_unchecked_bodies")
		}
	}

	// Process all scheduled procedures
	// C++ Reference: checker.cpp:6308-6316
	if !sync.atomic_load(&global_procedure_body_in_worker_queue) {
		// Single-threaded mode: process directly
		// C++ Reference: checker.cpp:6309-6313
		untyped := &check_procedure_bodies_worker_data[0].untyped
		for i := 0; i < len(c.procs_to_check); i += 1 {
			pi := c.procs_to_check[i]
			consume_proc_info(c, pi, untyped)
		}
		clear(&c.procs_to_check)
	} else {
		// Parallel mode: wait for workers
		// C++ Reference: checker.cpp:6314-6315
		thread_pool_wait()
	}

	// Reset global flags
	// C++ Reference: checker.cpp:6318-6319
	sync.atomic_store(&global_procedure_body_in_worker_queue, false)
	sync.atomic_store(&global_after_checking_procedure_bodies, true)
}

// check_safety_all_procedures_for_unchecked performs safety validation
// C++ Reference: checker.cpp:6322-6348
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
	// C++ Reference: checker.cpp:6335 (GB_ASSERT(DEBUG_CHECK_ALL_PROCEDURES))
	// In production builds, this is typically disabled
	// We'll implement it for completeness but note it's for debugging

	// Create untyped expression map for checking
	// C++ Reference: checker.cpp:6337
	untyped: map[^ast.Expr]^Expr_Info
	defer delete(untyped)

	// Reserve space in all_procedures array based on queue count
	// C++ Reference: checker.cpp:6341
	queue_count := queue.mpsc_count(&c.info.all_procedures_queue)
	if queue_count > 0 {
		reserve(&c.info.all_procedures, queue_count)
	}

	// Drain the all_procedures_queue and check each one
	// C++ Reference: checker.cpp:6343-6359
	for {
		pi, ok := queue.mpsc_dequeue(&c.info.all_procedures_queue)
		if !ok do break

		// Validate procedure info
		// C++ Reference: checker.cpp:6344-6345
		assert(pi != nil)
		assert(pi.decl != nil)

		// Get entity and check state
		// C++ Reference: checker.cpp:6346-6348
		e := pi.decl.entity
		proc_checked_state := pi.decl.proc_checked_state
		_ = proc_checked_state // Used for debugging in C++

		// Check if procedure needs checking
		// C++ Reference: checker.cpp:6349-6356
		if e != nil && !sync.atomic_load(&e.proc_body_checked) {
			if .Used in e.flags {
				// Debug output (commented in C++)
				// C++ Reference: checker.cpp:6351-6353
				// debugf("%s :: %s\n", e.token.text, type_to_string(e.type))
				// debugf("proc body unchecked\n")
				// debugf("Checked State: %s\n\n", proc_checked_state)

				// Check the procedure
				// C++ Reference: checker.cpp:6355
				consume_proc_info(c, pi, &untyped)
			}
		}

		// Add to all_procedures array
		// C++ Reference: checker.cpp:6359
		append(&c.info.all_procedures, pi)
	}
}

// ======================================================================================
// DEPENDENCY TREE UPDATES
// C++ Reference: /mnt/c/odin/src/checker.cpp:7154-7212
// ======================================================================================

// check_walk_all_dependencies_worker_proc is the thread pool worker for dependency walking
// C++ Reference: checker.cpp:7176-7197
check_walk_all_dependencies_worker_proc :: proc(data: rawptr) -> int {
	decl := cast(^Decl_Info)data
	check_walk_all_dependencies(decl)
	return 0
}

// check_walk_all_dependencies recursively walks a declaration's dependency tree
// C++ Reference: checker.cpp:7154-7162 (single-threaded) or 7176-7197 (multithreaded)
//
// This function processes a declaration and all its children (nested procedures),
// propagating dependencies from child declarations to parent declarations.
// This is critical for proper dependency analysis of nested procedures.
check_walk_all_dependencies :: proc(decl: ^Decl_Info) {
	if decl == nil {
		return
	}

	// Process all child declarations recursively
	// C++ Reference: checker.cpp:7158-7159
	for child := decl.next_child; child != nil; child = child.next_sibling {
		check_walk_all_dependencies(child)
	}

	// Propagate dependencies from this declaration to its parent
	// C++ Reference: checker.cpp:7161
	add_deps_from_child_to_parent(decl)
}

// check_update_dependency_tree_for_procedures walks all procedure dependency trees
// C++ Reference: checker.cpp:7164-7212
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
		// C++ Reference: checker.cpp:7200-7208

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
		// C++ Reference: checker.cpp:7210
		thread_pool_wait()
	} else {
		// Sequential mode: process directly
		// C++ Reference: checker.cpp:7165-7173

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
// C++ Reference: /mnt/c/odin/src/checker.cpp:7214-7242
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
// C++ Reference: checker.cpp:7214-7220
scope_check_file_worker_proc :: proc(data: rawptr) -> int {
	task := cast(^Scope_Check_File_Task)data
	check_scope_usage_file_worker(task.c, task.f)
	return 0
}

// scope_check_pkg_worker_proc is the thread pool worker wrapper for package scope checking
// C++ Reference: checker.cpp:7222-7227
scope_check_pkg_worker_proc :: proc(data: rawptr) -> int {
	task := cast(^Scope_Check_Pkg_Task)data
	check_scope_usage_pkg_worker(task.c, task.pkg)
	return 0
}

// check_scope_usage_file_worker is the worker thread entry point for file scope checking
// C++ Reference: checker.cpp:7214-7220
//
// This function is called by worker threads (or sequentially) to check
// a single file's scope for unused/shadowed variables.
check_scope_usage_file_worker :: proc(c: ^Checker, f: ^ast.File) {
	// Get file-specific vet flags
	// C++ Reference: checker.cpp:7217
	vet_flags := ast_file_vet_flags(f)

	// Check the file's scope
	// C++ Reference: checker.cpp:7218
	// Note: C++ stores scope on AstFile, we track it in info.file_scopes map
	file_scope, has_scope := c.info.file_scopes[f]
	if has_scope {
		check_scope_usage(c, file_scope, vet_flags)
	}
}

// check_scope_usage_pkg_worker is the worker thread entry point for package scope checking
// C++ Reference: checker.cpp:7222-7227
//
// This function is called by worker threads (or sequentially) to check
// a single package's scope for unused/shadowed variables.
check_scope_usage_pkg_worker :: proc(c: ^Checker, pkg: ^ast.Package) {
	// Check package scope with per_entity mode
	// C++ Reference: checker.cpp:7225
	// Note: vet_flags=0 for package scopes, per_entity=true
	// Note: C++ stores scope on AstPackage, we track it in info.package_scopes map
	pkg_scope, has_scope := c.info.package_scopes[pkg]
	if has_scope {
		check_scope_usage_internal(c, pkg_scope, {}, true)
	}
}

// check_all_scope_usages checks all file and package scopes for issues
// C++ Reference: checker.cpp:7231-7242
//
// This function iterates over all files and packages in the checker,
// checking each scope for:
// - Unused variables/parameters/imports
// - Shadowed declarations
// - Large stack allocations
check_all_scope_usages :: proc(c: ^Checker) {
	// Determine thread count for parallel execution
	thread_count := 1
	if global_thread_pool != nil {
		thread_count = global_thread_pool.thread_count
	}

	// Sequential mode (single-threaded)
	if thread_count == 1 {
		// Check all file scopes
		// C++ Reference: checker.cpp:7232-7235
		for file in sorted_files(c.info.files) {
			check_scope_usage_file_worker(c, file)
		}

		// Check all package scopes
		// C++ Reference: checker.cpp:7236-7239
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
	// C++ Reference: checker.cpp:7232-7235
	file_idx := 0
	for file in sorted_files(c.info.files) {
		file_tasks[file_idx] = Scope_Check_File_Task{c = c, f = file}
		thread_pool_add_task(scope_check_file_worker_proc, &file_tasks[file_idx])
		file_idx += 1
	}

	// Submit package scope checking tasks
	// C++ Reference: checker.cpp:7236-7239
	pkg_idx := 0
	for pkg in sorted_packages(&c.info) {
		pkg_tasks[pkg_idx] = Scope_Check_Pkg_Task{c = c, pkg = pkg}
		thread_pool_add_task(scope_check_pkg_worker_proc, &pkg_tasks[pkg_idx])
		pkg_idx += 1
	}

	// Wait for all workers to complete
	// C++ Reference: checker.cpp:7241
	thread_pool_wait()
}
