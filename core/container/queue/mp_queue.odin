// Multi-producer queue implementations for concurrent access.
//
// This package provides lock-free inspired queue types for multi-threaded scenarios:
// - MPSC_Queue: Multi-Producer Single-Consumer queue
// - MPMC_Queue: Multi-Producer Multi-Consumer queue
//
// These implementations use mutex-based synchronization 
// TODO: Switch to Lock-Free
package container_queue

import "base:runtime"
import "core:sync"

// Every declaration below is polymorphic -- both queue types are `struct($T: typeid)` and every
// procedure takes `^MPSC_Queue($T)` / `^MPMC_Queue($T)`. Polymorphic bodies and field types are
// only resolved on instantiation, and nothing inside this package instantiates them, so when the
// package is checked on its own there is no resolved use of `sync` and
// `odin check core/container/queue -vet -strict-style` reports "'sync' declared but not used".
// The diagnostic is correct, not a compiler bug: the import really is unused at this point.
// `_ :: sync` is the standard way to say "this is deliberate". LEDGER #341.
_ :: sync

// MPSC_Queue is a Multi-Producer Single-Consumer queue.
//
// Multiple threads can safely enqueue items concurrently,
// while a single consumer thread dequeues items.
//
// This is useful for work distribution patterns where multiple workers
// produce results consumed by a single coordinator.
MPSC_Queue :: struct($T: typeid) {
	q:     Queue(T),
	mu:    sync.Mutex,
	count: int, // Track item count
}

// MPMC_Queue is a Multi-Producer Multi-Consumer queue.
//
// Multiple threads can safely enqueue and dequeue items concurrently.
//
// This is useful for general concurrent work queues where multiple
// producers and consumers operate independently.
MPMC_Queue :: struct($T: typeid) {
	q:        Queue(T),
	mu:       sync.Mutex,
	count:    int, // Track item count
	capacity: int, // Track capacity for auto-grow
}

// Initialize an MPSC queue with the specified capacity.
//
// The queue will allocate space for at least `capacity` items.
// Returns an `Allocator_Error` if allocation fails.
mpsc_init :: proc(q: ^MPSC_Queue($T), capacity := 10000, allocator := context.allocator, loc := #caller_location) -> runtime.Allocator_Error {
	init(&q.q, capacity, allocator, loc) or_return
	q.count = 0
	return nil
}

// Enqueue an item to the MPSC queue.
//
// This operation is thread-safe and can be called by multiple producers concurrently.
// Returns the count of items in the queue AFTER the enqueue operation.
mpsc_enqueue :: proc(q: ^MPSC_Queue($T), item: T) -> int {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	push_back(&q.q, item)
	q.count += 1
	return q.count
}

// Dequeue an item from the MPSC queue.
//
// This operation should only be called by the single consumer thread.
// Returns (item, true) if successful, (zero_value, false) if the queue is empty.
mpsc_dequeue :: proc(q: ^MPSC_Queue($T)) -> (item: T, ok: bool) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	if len(q.q) == 0 {
		return {}, false
	}

	item = pop_front(&q.q)
	q.count -= 1
	return item, true
}

// Get the current count of items in the MPSC queue.
//
// This operation is thread-safe.
mpsc_count :: proc(q: ^MPSC_Queue($T)) -> int {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.count
}

// Check if the MPSC queue is empty.
//
// This operation is thread-safe.
mpsc_is_empty :: proc(q: ^MPSC_Queue($T)) -> bool {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.count == 0
}

// Destroy an MPSC queue and free its resources.
//
// The queue must be empty before calling this procedure.
// This will assert if the queue is not empty.
mpsc_destroy :: proc(q: ^MPSC_Queue($T)) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	assert(q.count == 0, "MPSC queue must be empty before destroy")
	destroy(&q.q)
}

// Initialize an MPMC queue with the specified capacity.
//
// The capacity will be rounded up to the next power of 2.
// Returns an `Allocator_Error` if allocation fails.
mpmc_init :: proc(q: ^MPMC_Queue($T), capacity := 10000, allocator := context.allocator, loc := #caller_location) -> runtime.Allocator_Error {
	// Round up to next power of 2
	cap := max(capacity, 8)

	// Next power of 2 calculation
	cap -= 1
	cap |= cap >> 1
	cap |= cap >> 2
	cap |= cap >> 4
	cap |= cap >> 8
	cap |= cap >> 16
	cap |= cap >> 32
	cap += 1

	init(&q.q, cap, allocator, loc) or_return
	q.capacity = cap
	q.count = 0
	return nil
}

// Internal helper to grow MPMC queue capacity.
//
// Doubles the queue capacity. Must be called while holding the mutex.
// Returns false if growth failed.
_mpmc_internal_grow :: proc(q: ^MPMC_Queue($T), loc := #caller_location) -> bool {
	old_cap := q.capacity
	new_cap := old_cap * 2

	// Attempt to resize the underlying queue
	if err := reserve(&q.q, new_cap, loc); err != nil {
		return false
	}

	// Verify the resize happened
	if cap(q.q) < new_cap {
		return false
	}

	q.capacity = new_cap
	return true
}

// Enqueue an item to the MPMC queue.
//
// The queue will automatically grow if it reaches capacity.
// This operation is thread-safe for both producers and consumers.
// Returns the count of items in the queue BEFORE the enqueue operation,
// or -1 if growth failed.
mpmc_enqueue :: proc(q: ^MPMC_Queue($T), item: T, loc := #caller_location) -> int {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	// Auto-grow if at capacity
	if len(q.q) >= q.capacity {
		if !_mpmc_internal_grow(q, loc) {
			return -1 // Growth failed
		}
	}

	push_back(&q.q, item)
	prev_count := q.count
	q.count += 1
	return prev_count
}

// Dequeue an item from the MPMC queue.
//
// This operation is thread-safe and can be called by multiple consumers concurrently.
// Returns (item, true) if successful, (zero_value, false) if the queue is empty.
mpmc_dequeue :: proc(q: ^MPMC_Queue($T)) -> (item: T, ok: bool) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	if len(q.q) == 0 {
		return {}, false
	}

	item = pop_front(&q.q)
	q.count -= 1
	return item, true
}

// Get the current count of items in the MPMC queue.
//
// This operation is thread-safe.
mpmc_count :: proc(q: ^MPMC_Queue($T)) -> int {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.count
}

// Check if the MPMC queue is empty.
//
// This operation is thread-safe.
mpmc_is_empty :: proc(q: ^MPMC_Queue($T)) -> bool {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)
	return q.count == 0
}

// Destroy an MPMC queue and free its resources.
mpmc_destroy :: proc(q: ^MPMC_Queue($T)) {
	sync.mutex_lock(&q.mu)
	defer sync.mutex_unlock(&q.mu)

	destroy(&q.q)
}
