package checker

/*
Queue drain functions for transferring entities from MPSC queues to final arrays.

These functions are called after the entity collection phase to move queued
entities into their final storage locations where they can be processed sequentially.

C++ Reference: The C++ implementation drains queues at various points during checking.
While C++ may drain inline, we provide explicit drain functions for clarity.

WORKER COORDINATION ARCHITECTURE
=================================

The C++ checker uses a sophisticated work-stealing thread pool for parallel processing:

1. Thread Pool Structure (thread_pool.cpp:27-34, threading.cpp:61-76):
   - ThreadPool contains array of Thread structs (one per worker + main thread)
   - Each Thread has a work-stealing deque (TaskQueue) for local tasks
   - Global futexes for task availability signaling and completion tracking
   - Main thread (index 0) participates in work execution

2. Work Stealing Protocol (thread_pool.cpp:101-152):
   - Workers take tasks from bottom of their own deque (LIFO, cache-friendly)
   - Idle workers steal from top of other workers' deques (FIFO, breadth-first)
   - Chase-Lev deque algorithm for lock-free concurrent access
   - CAS operations prevent race conditions during stealing

3. Task Submission (thread_pool.cpp:154-161):
   - thread_pool_add_task(proc, data) pushes to current thread's deque
   - Increments global tasks_left counter
   - Broadcasts on tasks_available futex to wake sleeping workers
   - Returns immediately (non-blocking)

4. Barrier Synchronization (thread_pool.cpp:163-184):
   - thread_pool_wait() blocks until all tasks complete
   - Main thread helps process tasks while waiting (work participation)
   - Uses futex_wait on tasks_left for efficient sleep/wake
   - Critical memory ordering ensures wake happens if tasks added during check

5. Worker Thread Lifecycle (thread_pool.cpp:186-248):
   - Worker loop: take local tasks → steal remote tasks → sleep
   - Futex-based sleep when no work available (CPU-efficient)
   - Broadcast wake when new work arrives or pool shuts down
   - Graceful shutdown via running flag

6. Queue Draining Integration (checker.cpp:7076-7083):
   - Drain SOA types inline (complete_soa_type is thread-safe)
   - Drain entity/definition queues to arrays (lock-free MPSC queues)
   - thread_pool_wait() ensures all worker tasks complete
   - Critical for consistency: arrays fully populated before next phase

SYNCHRONIZATION POINTS IN CHECKER
==================================

The C++ checker calls thread_pool_wait() at these critical junctures:

1. After dependency graph generation (checker.cpp:2999)
   - Ensures all dependency edges discovered before graph processing

2. After entity collection (checker.cpp:5774, 5814)
   - Waits for all file/package workers to finish entity discovery
   - Ensures entity queues complete before draining

3. After procedure body checking (checker.cpp:6315, 6477)
   - Waits for all procedure validation workers
   - Ensures deferred checking completes

4. After queue merging (checker.cpp:7082, 7210, 7241, 7403, 7429)
   - Multiple drain-and-wait cycles throughout checking pipeline
   - Guarantees arrays synchronized before dependent phases

5. After final validation (checker.cpp:7443)
   - Final barrier before checker completes

THREAD POOL API (To Be Implemented)
====================================

The following functions define the thread pool interface. These match the C++
implementation's signatures and semantics. Implementation will be added in a
separate thread_pool.odin module.

Thread Pool Management:
- thread_pool_init(worker_count: int) -> ^Thread_Pool
- thread_pool_destroy(pool: ^Thread_Pool)

Task Submission:
- thread_pool_add_task(proc: Worker_Task_Proc, data: rawptr) -> bool
  C++ Reference: thread_pool.cpp:154-161
  Submits task to current thread's work queue
  Returns: true if task added successfully

Synchronization:
- thread_pool_wait()
  C++ Reference: thread_pool.cpp:163-184
  Blocks until all submitted tasks complete
  Main thread participates in work processing while waiting
  Uses futex for efficient blocking

Thread Identification:
- current_thread_index() -> int
  C++ Reference: thread_pool.cpp:36-38
  Returns: 0 for main thread, 1..N for workers
  Used for accessing per-thread data arrays

ARCHITECTURAL NOTE: Declaration Dependency Processing
================================================================

The C++ implementation does NOT use a dedicated "decl_info_queue" for declaration processing.
Instead, it uses a dependency graph approach:

1. EntityGraphNode (checker.hpp:313-320) tracks declaration dependencies:
   - Each entity gets a graph node with pred/succ sets and a dep_count
   - DeclInfo.deps map (checker.hpp:236) stores entity dependencies
   - generate_entity_dependency_graph() builds the full dependency graph

2. Dependency-ordered processing (checker.cpp:3018+):
   - Builds dependency graph from all DeclInfo.deps
   - Uses topological sort to find processing order
   - Processes declarations when dep_count reaches zero
   - NO queue is used - it's a graph traversal algorithm

3. Our Odin implementation:
   - Entity_Graph_Node (checker.odin:680-687) matches C++ EntityGraphNode
   - Decl_Info.deps (checker.odin:303) tracks entity dependencies
   - Processing will use graph-based ordering, not queue-based

The 14 MPSC queues in our system are for:
  1. definition_queue           (entities to define)
  2. entity_queue               (entities to check)
  3. required_global_variable_queue
  4. required_foreign_imports_through_force_queue
  5. foreign_imports_to_check_fullpaths
  6. foreign_decls_to_check
  7. raddbg_type_views_queue
  8. intrinsics_entry_point_usage
  9. objc_class_implementations
  10. all_procedures_queue
  11. procs_with_deferred_to_check
  12. procs_with_objc_context_provider_to_check
  13. global_untyped_queue
  14. soa_types_to_complete

None of these are for declaration dependency ordering - that's handled by
the dependency graph algorithm, not by queuing.
*/

import "base:intrinsics"
import "core:container/queue"
import "core:mem"
import "core:odin/ast"
import "core:slice"
import "core:sync"
import "core:thread"

// =============================================================================
// CHASE-LEV WORK-STEALING DEQUE
// =============================================================================
//
// C++ Reference: thread_pool.cpp:49-152
//
// The Chase-Lev deque is a lock-free data structure that allows:
// - The owner thread to push/pop from the bottom (LIFO for cache locality)
// - Other threads to steal from the top (FIFO for load balancing)
//
// Key invariants:
// - bottom always >= top
// - size = bottom - top
// - Empty when bottom == top
// - Single item when bottom == top + 1

// Task represents a unit of work for the thread pool
// C++ Reference: thread_pool.cpp:43-47 (Task struct)
Task :: struct {
	do_work: Worker_Task_Proc,
	data:    rawptr,
}

// Task_Ring_Buffer is a growable circular buffer for tasks
// C++ Reference: thread_pool.cpp:49-59 (TaskRingBuffer)
Task_Ring_Buffer :: struct {
	capacity: int,
	mask:     int, // capacity - 1, for efficient modulo
	buffer:   []Task,
}

// Create a new ring buffer with the given capacity (must be power of 2)
task_ring_buffer_create :: proc(capacity: int, allocator := context.allocator) -> ^Task_Ring_Buffer {
	ring := new(Task_Ring_Buffer, allocator)
	ring.capacity = capacity
	ring.mask = capacity - 1
	ring.buffer = make([]Task, capacity, allocator)
	return ring
}

// Grow the ring buffer, copying existing tasks
// C++ Reference: thread_pool.cpp:61-76 (grow_ring_buffer)
task_ring_buffer_grow :: proc(old: ^Task_Ring_Buffer, bottom, top: int, allocator := context.allocator) -> ^Task_Ring_Buffer {
	new_capacity := old.capacity * 2
	new_ring := task_ring_buffer_create(new_capacity, allocator)

	// Copy existing tasks to new buffer
	for i := top; i < bottom; i += 1 {
		new_ring.buffer[i & new_ring.mask] = old.buffer[i & old.mask]
	}

	return new_ring
}

// Task_Deque is a Chase-Lev work-stealing deque
// C++ Reference: thread_pool.cpp:78-131
Task_Deque :: struct {
	top:    int,               // Steal end (other threads read/CAS)
	bottom: int,               // Owner end (only owner writes)
	ring:   ^Task_Ring_Buffer, // Circular buffer of tasks
}

// Deque grab result
Grab_Result :: enum {
	Success,    // Got a task
	Empty,      // Queue is empty
	Failed,     // CAS failed (another stealer won)
}

// Initialize a task deque
task_deque_init :: proc(deque: ^Task_Deque, initial_capacity := 1024, allocator := context.allocator) {
	deque.top = 0
	deque.bottom = 0
	deque.ring = task_ring_buffer_create(initial_capacity, allocator)
}

// Push a task onto the bottom of the deque (owner only)
// C++ Reference: thread_pool.cpp:78-99
task_deque_push :: proc(deque: ^Task_Deque, task: Task, allocator := context.allocator) {
	bot := sync.atomic_load_explicit(&deque.bottom, .Relaxed)
	top := sync.atomic_load_explicit(&deque.top, .Acquire)
	ring := sync.atomic_load_explicit(&deque.ring, .Relaxed)

	size := bot - top
	if size > ring.capacity - 1 {
		// Need to grow the ring buffer
		ring = task_ring_buffer_grow(ring, bot, top, allocator)
		// Store with Release to ensure new buffer contents visible to stealers
		sync.atomic_store_explicit(&deque.ring, ring, .Release)
	}

	// Store task to buffer slot
	// Use atomic stores for individual fields to help TSAN understand synchronization
	slot := &ring.buffer[bot & ring.mask]
	sync.atomic_store_explicit(cast(^rawptr)&slot.do_work, cast(rawptr)task.do_work, .Relaxed)
	sync.atomic_store_explicit(&slot.data, task.data, .Relaxed)
	// Use Release store to ensure task write is visible before bottom increment is seen by stealers
	sync.atomic_store_explicit(&deque.bottom, bot + 1, .Release)
}

// Take a task from the bottom of the deque (owner only, LIFO)
// C++ Reference: thread_pool.cpp:101-131
task_deque_take :: proc(deque: ^Task_Deque) -> (task: Task, result: Grab_Result) {
	bot := sync.atomic_load_explicit(&deque.bottom, .Relaxed) - 1
	ring := sync.atomic_load_explicit(&deque.ring, .Acquire)
	sync.atomic_store_explicit(&deque.bottom, bot, .Relaxed)
	sync.atomic_thread_fence(.Seq_Cst) // Synchronize with stealers
	top := sync.atomic_load_explicit(&deque.top, .Relaxed)

	if top <= bot {
		// Non-empty queue
		// Use atomic loads for individual fields to match atomic stores in push and help TSAN
		slot := &ring.buffer[bot & ring.mask]
		task.do_work = cast(Worker_Task_Proc)sync.atomic_load_explicit(cast(^rawptr)&slot.do_work, .Relaxed)
		task.data = sync.atomic_load_explicit(&slot.data, .Relaxed)
		if top == bot {
			// Last item - race with stealers
			_, ok := sync.atomic_compare_exchange_strong_explicit(
				&deque.top, top, top + 1, .Seq_Cst, .Relaxed)
			if !ok {
				// Stealer won
				sync.atomic_store_explicit(&deque.bottom, bot + 1, .Relaxed)
				return {}, .Empty
			}
		}
		return task, .Success
	} else {
		// Empty queue
		sync.atomic_store_explicit(&deque.bottom, bot + 1, .Relaxed)
		return {}, .Empty
	}
}

// Steal a task from the top of the deque (other threads, FIFO)
// C++ Reference: thread_pool.cpp:133-152
task_deque_steal :: proc(deque: ^Task_Deque) -> (task: Task, result: Grab_Result) {
	top := sync.atomic_load_explicit(&deque.top, .Acquire)
	sync.atomic_thread_fence(.Seq_Cst) // Synchronize with owner
	bot := sync.atomic_load_explicit(&deque.bottom, .Acquire)

	if top < bot {
		// Non-empty queue
		// C++ uses memory_order_consume here, but Acquire is safer and portable
		ring := sync.atomic_load_explicit(&deque.ring, .Acquire)
		// Use atomic loads for individual fields to match atomic stores in push and help TSAN
		slot := &ring.buffer[top & ring.mask]
		task.do_work = cast(Worker_Task_Proc)sync.atomic_load_explicit(cast(^rawptr)&slot.do_work, .Relaxed)
		task.data = sync.atomic_load_explicit(&slot.data, .Relaxed)
		_, ok := sync.atomic_compare_exchange_strong_explicit(
			&deque.top, top, top + 1, .Seq_Cst, .Relaxed)
		if !ok {
			// Another stealer won
			return {}, .Failed
		}
		return task, .Success
	}
	return {}, .Empty
}

// =============================================================================
// THREAD POOL
// =============================================================================

// Worker_Task_Proc is the signature for worker task functions
// C++ Reference: threading.cpp:41-42 (WORKER_TASK_PROC macro)
Worker_Task_Proc :: #type proc(data: rawptr) -> int

// Futex values for task availability signaling
NOBODY_WAITING  :: 0
SOMEONE_WAITING :: 1

// Thread_Data holds per-thread state
// C++ Reference: thread_pool.cpp:27-34 (Thread struct)
Thread_Data :: struct {
	deque:        Task_Deque,    // Work-stealing deque for this thread
	thread:       ^thread.Thread, // Thread handle (nil for main thread)
	thread_index: int,           // Index in thread array (0 = main)
}

// Thread_Pool represents the global work-stealing thread pool
// C++ Reference: thread_pool.cpp:27-34, main.cpp:15
Thread_Pool :: struct {
	threads:         []Thread_Data,   // Thread data array (index 0 = main thread)
	thread_count:    int,             // Total thread count (workers + 1)

	// Synchronization
	running:         bool,            // False to signal shutdown
	tasks_left:      sync.Futex,      // Number of pending tasks (atomic, also used as futex for completion)
	tasks_available: sync.Futex,      // Signaled when work is available (workers sleep on this)

	allocator:       mem.Allocator,   // Allocator for pool resources
}

// Thread-local storage for current thread index
// C++ Reference: thread_pool.cpp:36-38
@(thread_local)
tls_thread_index: int

// Global thread pool instance (to be initialized at checker startup)
// C++ Reference: main.cpp:15 (gb_global ThreadPool global_thread_pool)
global_thread_pool: ^Thread_Pool = nil

// current_thread_index returns the current thread's index
// C++ Reference: thread_pool.cpp:36-38
//
// Returns: 0 for main thread, 1..N for worker threads
// Used to index into per-thread data arrays
current_thread_index :: proc() -> int {
	return tls_thread_index
}

// thread_pool_init initializes the global thread pool with specified worker count
// C++ Reference: thread_pool.cpp:40-55, main.cpp:16-20
//
// Creates worker_count threads plus main thread (total = worker_count + 1)
// Each thread gets its own work-stealing deque and arena allocators
// Sets up futexes for task availability and completion signaling
thread_pool_init :: proc(worker_count: int, allocator := context.allocator) -> ^Thread_Pool {
	pool := new(Thread_Pool, allocator)
	pool.allocator = allocator
	pool.thread_count = worker_count + 1 // Workers + main thread
	pool.threads = make([]Thread_Data, pool.thread_count, allocator)
	pool.running = true
	pool.tasks_left = sync.Futex(0)
	pool.tasks_available = sync.Futex(NOBODY_WAITING)

	// Initialize main thread (index 0)
	pool.threads[0].thread_index = 0
	pool.threads[0].thread = nil
	task_deque_init(&pool.threads[0].deque, 1024, allocator)
	tls_thread_index = 0

	// Create and start worker threads
	for i := 1; i < pool.thread_count; i += 1 {
		pool.threads[i].thread_index = i
		task_deque_init(&pool.threads[i].deque, 1024, allocator)

		// Create worker thread
		t := thread.create(worker_thread_proc)
		t.data = pool
		t.user_index = i
		pool.threads[i].thread = t
		thread.start(t)
	}

	return pool
}

// worker_thread_proc is the main loop for worker threads
// C++ Reference: thread_pool.cpp:186-248
worker_thread_proc :: proc(t: ^thread.Thread) {
	pool := cast(^Thread_Pool)t.data
	thread_idx := t.user_index

	// Set thread-local index
	tls_thread_index = thread_idx

	my_deque := &pool.threads[thread_idx].deque

	for intrinsics.atomic_load(&pool.running) {
		finished := 0

		// Process own queue (LIFO for cache locality)
		for {
			task, result := task_deque_take(my_deque)
			if result != .Success do break

			task.do_work(task.data)
			sync.atomic_sub_explicit(&pool.tasks_left, 1, .Release)
			finished += 1
		}

		// Signal main thread if we finished work and no tasks remain
		// C++ Reference: thread_pool.cpp:206-208 - signal tasks_left futex
		if finished > 0 && sync.atomic_load_explicit(&pool.tasks_left, .Acquire) == 0 {
			sync.futex_signal(&pool.tasks_left)
		}

		// Try stealing from other threads
		if sync.atomic_load_explicit(&pool.tasks_left, .Acquire) > 0 {
			steal_loop: for victim_offset := 1; victim_offset < pool.thread_count; victim_offset += 1 {
				if sync.atomic_load_explicit(&pool.tasks_left, .Acquire) == 0 do break

				victim := (thread_idx + victim_offset) % pool.thread_count
				victim_deque := &pool.threads[victim].deque

				task, result := task_deque_steal(victim_deque)
				if result == .Success {
					task.do_work(task.data)
					sync.atomic_sub_explicit(&pool.tasks_left, 1, .Release)

					if sync.atomic_load_explicit(&pool.tasks_left, .Acquire) == 0 {
						sync.futex_signal(&pool.tasks_left)
					}
					continue steal_loop
				}
			}
		}

		// No work available - sleep until woken
		sync.atomic_store_explicit(&pool.tasks_available, sync.Futex(SOMEONE_WAITING), .Release)
		if !intrinsics.atomic_load(&pool.running) do break
		sync.futex_wait(&pool.tasks_available, SOMEONE_WAITING)
	}
}

// task_deque_destroy frees the ring buffer associated with a deque
task_deque_destroy :: proc(deque: ^Task_Deque, allocator := context.allocator) {
	if deque.ring != nil {
		delete(deque.ring.buffer, allocator)
		free(deque.ring, allocator)
		deque.ring = nil
	}
}

// thread_pool_destroy shuts down thread pool and joins all worker threads
// C++ Reference: thread_pool.cpp:57-68, main.cpp:3779
//
// Sets running flag to false, broadcasts to wake sleeping workers
// Joins each worker thread and frees resources
thread_pool_destroy :: proc(pool: ^Thread_Pool) {
	if pool == nil do return

	// Signal shutdown
	intrinsics.atomic_store(&pool.running, false)

	// Wake all sleeping workers (they may be waiting on either futex)
	sync.futex_broadcast(&pool.tasks_available)
	sync.futex_broadcast(&pool.tasks_left)

	// Join all worker threads
	for i := 1; i < pool.thread_count; i += 1 {
		if pool.threads[i].thread != nil {
			thread.join(pool.threads[i].thread)
			thread.destroy(pool.threads[i].thread)
		}
	}

	// Destroy task deques (free ring buffers)
	for i := 0; i < pool.thread_count; i += 1 {
		task_deque_destroy(&pool.threads[i].deque, pool.allocator)
	}

	// Free resources
	delete(pool.threads, pool.allocator)
	free(pool, pool.allocator)
}

// thread_pool_add_task submits a task to the thread pool for execution
// C++ Reference: thread_pool.cpp:154-161, main.cpp:21-23
//
// Pushes task to current thread's work deque (bottom, LIFO)
// Increments global tasks_left counter
// Broadcasts to wake idle workers if any are waiting
//
// Returns: true if task was added successfully
thread_pool_add_task :: proc(task_proc: Worker_Task_Proc, data: rawptr) -> bool {
	pool := global_thread_pool
	if pool == nil do return false

	// Get current thread's deque
	thread_idx := current_thread_index()
	my_deque := &pool.threads[thread_idx].deque

	// Push task to deque
	task := Task{do_work = task_proc, data = data}
	task_deque_push(my_deque, task, pool.allocator)

	// Increment task counter
	sync.atomic_add_explicit(&pool.tasks_left, 1, .Release)

	// Wake sleeping workers if any
	_, swapped := sync.atomic_compare_exchange_strong_explicit(
		&pool.tasks_available,
		sync.Futex(SOMEONE_WAITING),
		sync.Futex(NOBODY_WAITING),
		.Seq_Cst, .Relaxed)
	if swapped {
		sync.futex_broadcast(&pool.tasks_available)
	}

	return true
}

// thread_pool_wait blocks until all submitted tasks complete
// C++ Reference: thread_pool.cpp:163-184, main.cpp:24-26
//
// Main thread participates in work processing while waiting:
// 1. Take tasks from own deque (LIFO)
// 2. Process tasks and decrement tasks_left
// 3. Check tasks_left with acquire ordering
// 4. If zero, return; otherwise futex_wait
//
// Critical memory ordering ensures wake happens if tasks added during check
thread_pool_wait :: proc() {
	pool := global_thread_pool
	if pool == nil do return

	thread_idx := current_thread_index()
	my_deque := &pool.threads[thread_idx].deque

	for {
		// Process own queue
		for {
			task, result := task_deque_take(my_deque)
			if result != .Success do break

			task.do_work(task.data)
			sync.atomic_sub_explicit(&pool.tasks_left, 1, .Release)
		}

		// Check if all work is done
		rem_tasks := sync.atomic_load_explicit(&pool.tasks_left, .Acquire)
		if rem_tasks == 0 do return

		// Try to steal work while waiting
		stole := false
		for victim_offset := 1; victim_offset < pool.thread_count; victim_offset += 1 {
			victim := (thread_idx + victim_offset) % pool.thread_count
			victim_deque := &pool.threads[victim].deque

			task, result := task_deque_steal(victim_deque)
			if result == .Success {
				task.do_work(task.data)
				sync.atomic_sub_explicit(&pool.tasks_left, 1, .Release)
				stole = true
				break
			}
		}

		if stole do continue

		// No work to steal, wait for signal on tasks_left
		// C++ Reference: thread_pool.cpp:181 - futex_wait(&tasks_left, rem_tasks)
		rem_tasks = sync.atomic_load_explicit(&pool.tasks_left, .Acquire)
		if rem_tasks == 0 do return

		// Wait on tasks_left - will wake when value changes (task completes)
		sync.futex_wait(&pool.tasks_left, u32(rem_tasks))
	}
}

// =============================================================================
// QUEUE DRAINING FUNCTIONS
// =============================================================================

// drain_definition_queue transfers all queued definitions to the definitions array
// C++ Reference: checker.cpp:7068-7074 (check_add_definitions_from_queues)
// Should be called after all entity definitions have been collected
drain_definition_queue :: proc(info: ^Checker_Info) {
	// C++ line 7069: Pre-allocate array capacity based on queue size
	// isize cap = c->info.definitions.count + c->info.definition_queue.count.load(std::memory_order_relaxed);
	// array_reserve(&c->info.definitions, cap);

	// C++ line 7071-7073: Drain queue into array
	// for (Entity *e; queue.mpsc_dequeue(&c->info.definition_queue, &e); /**/) {
	//     array_add(&c->info.definitions, e);
	// }

	// Reserve capacity based on queue size to avoid reallocations
	queue_count := queue.mpsc_count(&info.definition_queue)
	reserve(&info.definitions, len(info.definitions) + queue_count)

	for {
		entity, ok := queue.mpsc_dequeue(&info.definition_queue)
		if !ok do break
		append(&info.definitions, entity)
	}

	// Sort by order_in_src for deterministic processing
	// C++ Reference: C++ sorts definitions by order_in_src after collection
	if len(info.definitions) > 1 {
		slice.sort_by(info.definitions[:], proc(a, b: ^Entity) -> bool {
			return a.order_in_src < b.order_in_src
		})
	}
}

// drain_entity_queue transfers all queued entities to the entities array
// C++ Reference: checker.cpp:7060-7066 (check_add_entities_from_queues)
// Should be called after all entities have been collected
drain_entity_queue :: proc(info: ^Checker_Info) {
	// C++ line 7061: Pre-allocate array capacity based on queue size
	// isize cap = c->info.entities.count + c->info.entity_queue.count.load(std::memory_order_relaxed);
	// array_reserve(&c->info.entities, cap);

	// Reserve capacity based on queue size to avoid reallocations
	queue_count := queue.mpsc_count(&info.entity_queue)
	reserve(&info.entities, len(info.entities) + queue_count)

	// C++ line 7063-7065: Drain queue into array
	// for (Entity *e; queue.mpsc_dequeue(&c->info.entity_queue, &e); /**/) {
	//     array_add(&c->info.entities, e);
	// }
	for {
		entity, ok := queue.mpsc_dequeue(&info.entity_queue)
		if !ok do break
		append(&info.entities, entity)
	}
}

// drain_procedures_queue transfers all queued procedures to the procedures array
// C++ Reference: All procedures are collected for later checking
// Should be called after all procedure entities have been created
drain_procedures_queue :: proc(info: ^Checker_Info) {
	for {
		proc_info, ok := queue.mpsc_dequeue(&info.all_procedures_queue)
		if !ok do break
		append(&info.all_procedures, proc_info)
	}
}

// drain_required_global_variable_queue processes @require tagged globals
// C++ Reference: Required globals are validated to ensure dependencies exist
// Should be called during global variable checking phase
drain_required_global_variable_queue :: proc(info: ^Checker_Info) -> [dynamic]^Entity {
	required := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&info.required_global_variable_queue)
		if !ok do break
		append(&required, entity)
	}
	return required
}

// drain_required_foreign_imports_through_force transfers foreign imports with @require attribute
// C++ Reference: checker.cpp:2765-2768 - drained during generate_minimum_dependency_set
// These entities are also added to the dependency set and used for linking validation
// Should be called during minimum dependency set generation phase
drain_required_foreign_imports_through_force :: proc(info: ^Checker_Info) {
	for {
		entity, ok := queue.mpsc_dequeue(&info.required_foreign_imports_through_force_queue)
		if !ok do break
		append(&info.required_foreign_imports_through_force, entity)
		// Note: C++ also calls add_to_set(c, e) here, but that's done by the caller
		// in the context of dependency graph generation
	}
}

// drain_foreign_imports_to_check_fullpaths processes foreign imports needing path validation
// C++ Reference: Foreign imports are checked for valid file paths
// Should be called during foreign library validation
drain_foreign_imports_to_check_fullpaths :: proc(info: ^Checker_Info) -> [dynamic]^Entity {
	foreign_imports := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&info.foreign_imports_to_check_fullpaths)
		if !ok do break
		append(&foreign_imports, entity)
	}
	return foreign_imports
}

// drain_foreign_decls_to_check processes foreign declarations
// C++ Reference: Foreign declarations are validated for consistency
// Should be called during foreign declaration checking
drain_foreign_decls_to_check :: proc(info: ^Checker_Info) -> [dynamic]^Entity {
	foreign_decls := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&info.foreign_decls_to_check)
		if !ok do break
		append(&foreign_decls, entity)
	}
	return foreign_decls
}

// drain_raddbg_type_views_queue transfers RadDbg type views to final array
// C++ Reference: RadDbg type views are collected during type checking for debug info
// Enqueued at check_decl.cpp:610, drained for RadDbg output generation
// NOTE(DEFERRED): @(raddbg_type_view) attribute processing is a debug info feature
drain_raddbg_type_views_queue :: proc(info: ^Checker_Info) {
	for {
		view, ok := queue.mpsc_dequeue(&info.raddbg_type_views_queue)
		if !ok do break
		append(&info.raddbg_type_views, view)
	}
}

// drain_intrinsics_entry_point_usage collects intrinsics entry point usages
// C++ Reference: Intrinsics entry points are tracked for validation
// Should be called during intrinsics validation phase
drain_intrinsics_entry_point_usage :: proc(info: ^Checker_Info) -> [dynamic]^ast.Node {
	usages := make([dynamic]^ast.Node)
	for {
		node, ok := queue.mpsc_dequeue(&info.intrinsics_entry_point_usage)
		if !ok do break
		append(&usages, node)
	}
	return usages
}

// drain_objc_class_implementations collects Objective-C class implementations
// C++ Reference: ObjC classes are processed during ObjC validation
// Should be called during Objective-C checking phase
drain_objc_class_implementations :: proc(info: ^Checker_Info) -> [dynamic]^Entity {
	implementations := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&info.objc_class_implementations)
		if !ok do break
		append(&implementations, entity)
	}
	return implementations
}

// drain_procs_with_deferred_to_check collects procedures with defer statements
// C++ Reference: Procedures with defer need special validation
// Should be called during procedure validation phase
drain_procs_with_deferred_to_check :: proc(c: ^Checker) -> [dynamic]^Entity {
	procs := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&c.procs_with_deferred_to_check)
		if !ok do break
		append(&procs, entity)
	}
	return procs
}

// drain_procs_with_objc_context_provider_to_check collects ObjC context provider procs
// C++ Reference: ObjC context providers need special handling
// Should be called during Objective-C procedure checking
drain_procs_with_objc_context_provider_to_check :: proc(c: ^Checker) -> [dynamic]^Entity {
	procs := make([dynamic]^Entity)
	for {
		entity, ok := queue.mpsc_dequeue(&c.procs_with_objc_context_provider_to_check)
		if !ok do break
		append(&procs, entity)
	}
	return procs
}

// drain_global_untyped_queue collects untyped expressions for later resolution
// C++ Reference: Untyped expressions are resolved after type inference
// Should be called during untyped expression resolution phase
drain_global_untyped_queue :: proc(c: ^Checker) -> [dynamic]Untyped_Expr_Info {
	untyped := make([dynamic]Untyped_Expr_Info)
	for {
		info, ok := queue.mpsc_dequeue(&c.global_untyped_queue)
		if !ok do break
		append(&untyped, info)
	}
	return untyped
}

// drain_soa_types_to_complete collects SOA types needing completion
// C++ Reference: SOA types need field layout completion
// Should be called during SOA type finalization
// WARNING: This function only drains to an array without processing.
// For inline processing matching C++ semantics, use drain_and_complete_soa_types instead.
drain_soa_types_to_complete :: proc(c: ^Checker) -> [dynamic]^Type {
	types := make([dynamic]^Type)
	for {
		type, ok := queue.mpsc_dequeue(&c.soa_types_to_complete)
		if !ok do break
		append(&types, type)
	}
	return types
}

// drain_and_complete_soa_types processes SOA types immediately during drain
// C++ Reference: checker.cpp:7077-7079, 4985-4987 - SOA types are completed inline
// This matches C++ semantics where complete_soa_type is called during dequeue
// Should be used in check_merge_queues_into_arrays equivalent
drain_and_complete_soa_types :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:7077-7079
	// for (Type *t = nullptr; queue.mpsc_dequeue(&c->soa_types_to_complete, &t); /**/) {
	//     complete_soa_type(c, t, false);
	// }

	for {
		soa_type, ok := queue.mpsc_dequeue(&c.soa_types_to_complete)
		if !ok do break

		complete_soa_type(c, soa_type, false)
	}
}

// =============================================================================
// WORKER COORDINATION FUNCTIONS
// =============================================================================

// drain_all_queues replicates C++ check_merge_queues_into_arrays semantics
// C++ Reference: checker.cpp:7076-7083
//
// This function performs a critical synchronization operation that ensures
// all worker threads have completed their tasks and all queued work has been
// transferred to final arrays before the next checking phase begins.
//
// Call sites in C++ checker (all must use this pattern):
// - After entity collection (line 7324)
// - After procedure bodies (line 7346)
// - After basic type info (line 7361)
// - After type definitions (line 7380)
// - After #soa types check (line 7392)
// - After test procedures (line 7402)
// - Final sanity checks (line 7443)
//
// The ordering is critical:
// 1. Complete SOA types first (they may enqueue entities/definitions)
// 2. Drain entity and definition queues
// 3. Wait for all worker threads to complete
drain_all_queues :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:7077-7079
	// First, complete SOA types inline (C++ does this first)
	// This must happen before draining entities because complete_soa_type
	// may add new entities or definitions to the queues
	drain_and_complete_soa_types(c)

	// C++ Reference: checker.cpp:7080-7081
	// Then drain entities and definitions to their arrays
	// These are the primary work queues that worker threads populate
	drain_entity_queue(&c.info)
	drain_definition_queue(&c.info)

	// C++ Reference: checker.cpp:7082
	// CRITICAL: Wait for all worker threads to complete
	// This barrier ensures:
	// - All parallel tasks have finished execution
	// - All memory writes from worker threads are visible
	// - No worker is still modifying shared state
	// - Safe to proceed to next sequential phase
	thread_pool_wait()
}

// verify_queues_empty checks that all primary queues are empty after draining
// C++ Reference: checker.cpp:7444-7445 - assertions that queues are empty
//
// This should be called after final draining to ensure no work was missed.
// Helps catch bugs in queue draining or entity processing logic.
//
// The C++ checker only verifies entity_queue and definition_queue because:
// - These are the primary work queues that MUST be empty after final drain
// - Other queues (procedures, SOA types) are drained to local arrays in specific
//   phases and may legitimately have items during intermediate phases
// - Only entity_queue and definition_queue have the invariant: "must be empty
//   after final check_merge_queues_into_arrays call"
verify_queues_empty :: proc(c: ^Checker) {
	// C++ Reference: checker.cpp:7444-7445
	// GB_ASSERT(c->info.entity_queue.count.load(std::memory_order_relaxed) == 0);
	// GB_ASSERT(c->info.definition_queue.count.load(std::memory_order_relaxed) == 0);

	assert(queue.mpsc_is_empty(&c.info.entity_queue), "entity_queue should be empty after final drain")
	assert(queue.mpsc_is_empty(&c.info.definition_queue), "definition_queue should be empty after final drain")

	// NOTE: C++ does NOT check all_procedures_queue or soa_types_to_complete
	// These queues are drained to local arrays in specific functions (drain_procedures_queue,
	// drain_and_complete_soa_types) but may legitimately have items during intermediate phases.
	// Only entity_queue and definition_queue must be empty after final drain.
}

// =============================================================================
// WORKER COORDINATION PROTOCOL DOCUMENTATION
// =============================================================================

/*
DETAILED WORKER COORDINATION PROTOCOL (From C++ Implementation)
================================================================

The C++ checker uses a Chase-Lev work-stealing deque algorithm for lock-free
parallel task execution. Understanding this protocol is critical for correct
threading implementation.

1. DEQUE STRUCTURE (thread_pool.cpp:49-59)

   Each thread has a TaskQueue with:
   - top: atomic<isize>     // Steal end (other threads read/write)
   - bottom: atomic<isize>  // Owner end (only owner writes)
   - ring: TaskRingBuffer*  // Circular buffer of tasks

   Invariants:
   - bottom always >= top
   - size = bottom - top
   - Empty when bottom == top
   - Single item when bottom == top + 1

2. PUSH OPERATION (thread_pool.cpp:78-99)

   Owner thread pushes to bottom (LIFO for cache locality):

   ```cpp
   bot = queue.bottom.load(relaxed)
   top = queue.top.load(acquire)      // Check for full
   if (bot - top > ring.size - 1) {
       ring = grow_ring(ring, bot, top)  // Allocate larger buffer
   }
   ring.buffer[bot % ring.size] = task
   fence(release)                      // Ensure task visible
   queue.bottom.store(bot + 1, relaxed)

   tasks_left.fetch_add(1, release)
   if (tasks_available.CAS(Someone_Waiting, Nobody_Waiting)) {
       futex_broadcast(tasks_available)  // Wake sleeping workers
   }
   ```

   Key points:
   - Only owner writes to bottom (no atomics needed)
   - Release fence ensures task write happens before bottom increment
   - Broadcast only if workers are waiting (CAS optimization)

3. TAKE OPERATION (thread_pool.cpp:101-131)

   Owner thread takes from bottom (LIFO, cache-friendly):

   ```cpp
   bot = queue.bottom.load(relaxed) - 1
   queue.bottom.store(bot, relaxed)
   fence(seq_cst)                      // Synchronize with stealers
   top = queue.top.load(relaxed)

   if (top <= bot) {
       task = ring.buffer[bot % ring.size]
       if (top == bot) {
           // Last item - race with stealers
           if (!queue.top.CAS(top, top+1, seq_cst)) {
               queue.bottom.store(bot + 1, relaxed)
               return Grab_Empty  // Stealer won
           }
       }
       return Grab_Success
   } else {
       // Empty queue
       queue.bottom.store(bot + 1, relaxed)
       return Grab_Empty
   }
   ```

   Key points:
   - Decrement bottom first, then check for race
   - seq_cst fence prevents reordering with stealer's top increment
   - CAS on last item prevents double-take with stealer

4. STEAL OPERATION (thread_pool.cpp:133-152)

   Other threads steal from top (FIFO, breadth-first):

   ```cpp
   top = queue.top.load(acquire)
   fence(seq_cst)                      // Synchronize with owner
   bot = queue.bottom.load(acquire)

   if (top < bot) {
       ring = queue.ring.load(consume)
       task = ring.buffer[top % ring.size]
       if (!queue.top.CAS(top, top+1, seq_cst)) {
           return Grab_Failed  // Another stealer won
       }
       return Grab_Success
   }
   return Grab_Empty
   ```

   Key points:
   - Read top before bottom (prevents missing work)
   - seq_cst fence synchronizes with owner's take
   - CAS prevents multiple stealers from taking same task

5. WAIT OPERATION (thread_pool.cpp:163-184)

   Main thread waits for completion while helping:

   ```cpp
   while (tasks_left.load(acquire)) {
       // Help process own work
       while (queue_take(current_thread, &task) == Grab_Success) {
           task.do_work(task.data)
           tasks_left.fetch_sub(1, release)
       }

       // Check again with memory barrier
       rem_tasks = tasks_left.load(acquire)
       if (rem_tasks == 0) return

       // Sleep until woken or tasks_left changes
       futex_wait(&tasks_left, rem_tasks)
   }
   ```

   Key points:
   - Main thread participates (not just waiting)
   - Acquire load ensures all worker writes visible
   - futex_wait has implicit CAS (only sleeps if value matches)

6. WORKER LOOP (thread_pool.cpp:186-248)

   Worker threads continuously process work:

   ```cpp
   while (running.load(seq_cst)) {
       finished = 0

       // Process own queue
       while (queue_take(self, &task) == Grab_Success) {
           task.do_work(task.data)
           tasks_left.fetch_sub(1, release)
           finished++
       }

       if (finished > 0 && tasks_left.load(acquire) == 0) {
           futex_signal(&tasks_left)  // Wake main thread
       }

       // Try stealing from others
       if (tasks_left.load(acquire) > 0) {
           for each thread {
               if (tasks_left == 0) break
               if (queue_steal(thread, &task) == Grab_Success) {
                   task.do_work(task.data)
                   tasks_left.fetch_sub(1, release)
                   if (tasks_left == 0) futex_signal(&tasks_left)
                   goto main_loop_continue
               }
           }
       }

       // No work available - sleep
       tasks_available.store(Someone_Waiting)
       if (!running) break
       futex_wait(&tasks_available, Someone_Waiting)

   main_loop_continue:
   }
   ```

   Key points:
   - LIFO from own queue (cache locality)
   - FIFO from other queues (breadth-first stealing)
   - Signal main thread when tasks complete
   - Round-robin stealing starting from self+1

7. MEMORY ORDERING RATIONALE

   - relaxed: Single-threaded operations (owner writes to bottom)
   - acquire/release: Synchronize task visibility between threads
   - seq_cst: Prevent races in CAS operations
   - fence: Ensure visibility without full barriers on hot path

   Critical pairs:
   - Push release fence + Steal acquire load (task visibility)
   - Take seq_cst fence + Steal seq_cst fence (last-item race)
   - tasks_left release dec + Wait acquire load (completion detection)

8. FUTEX USAGE

   - tasks_available: Binary semaphore for "work is available"
     * Set to Someone_Waiting when worker sleeps
     * Broadcast to Nobody_Waiting when work added
     * Workers wake up and check for work

   - tasks_left: Counter with signaling
     * Incremented when task added
     * Decremented when task completes
     * futex_wait blocks until value changes
     * futex_signal wakes one waiter (main thread)

This protocol provides:
- Lock-free task submission (no contention on push)
- LIFO execution for cache locality (owner takes from bottom)
- FIFO stealing for load balancing (stealers take from top)
- Minimal synchronization overhead
- Scalable to many threads
*/
