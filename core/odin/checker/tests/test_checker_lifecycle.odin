package test_checker

/*
Test Suite: Checker Lifecycle

Tests for basic checker initialization, destruction, and state management.
These are foundational tests that must pass before more complex tests.

Run with: odin test core/odin/checker/tests
*/

import "core:testing"
import checker ".."

// =============================================================================
// LIFECYCLE TESTS
// =============================================================================

@(test)
test_init_destroy_checker :: proc(t: ^testing.T) {
	// Test that we can create and destroy a checker without errors
	// init_checker / destroy_checker are NOT lock-free: destroy_checker calls
	// reset_runtime_type_globals, which nils the process-global runtime type state, and
	// init_checker repopulates it. Without the mutex these four lifecycle tests do that
	// concurrently with whatever package check holds it -- and a t_atomic_memory_order
	// nilled mid-check is exactly the 37 "Cannot determine type for implicit selector
	// expression" errors in core/sync that #321 kept seeing move between tests. LEDGER #368.
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	// Verify basic state
	testing.expect(t, c.info.checker == c, "Checker info should point back to checker")
}

@(test)
test_init_destroy_error_collector :: proc(t: ^testing.T) {
	// Serialize access to global error collector to avoid race conditions
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	// Test error collector lifecycle
	checker.init_error_collector(20)
	defer checker.destroy_error_collector()

	// Should start with no errors
	testing.expect(t, checker.error_count() == 0, "Should start with zero errors")
	testing.expect(t, checker.warning_count() == 0, "Should start with zero warnings")
}

@(test)
test_checker_context_creation :: proc(t: ^testing.T) {
	// init_checker / destroy_checker are NOT lock-free: destroy_checker calls
	// reset_runtime_type_globals, which nils the process-global runtime type state, and
	// init_checker repopulates it. Without the mutex these four lifecycle tests do that
	// concurrently with whatever package check holds it -- and a t_atomic_memory_order
	// nilled mid-check is exactly the 37 "Cannot determine type for implicit selector
	// expression" errors in core/sync that #321 kept seeing move between tests. LEDGER #368.
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	// Create a context
	ctx := checker.make_checker_context(c)
	defer checker.destroy_checker_context(&ctx)

	testing.expect(t, ctx.checker == c, "Context should reference checker")
	testing.expect(t, ctx.info == &c.info, "Context should reference checker info")
}

// =============================================================================
// SCOPE TESTS
// =============================================================================

@(test)
test_create_scope :: proc(t: ^testing.T) {
	// init_checker / destroy_checker are NOT lock-free: destroy_checker calls
	// reset_runtime_type_globals, which nils the process-global runtime type state, and
	// init_checker repopulates it. Without the mutex these four lifecycle tests do that
	// concurrently with whatever package check holds it -- and a t_atomic_memory_order
	// nilled mid-check is exactly the 37 "Cannot determine type for implicit selector
	// expression" errors in core/sync that #321 kept seeing move between tests. LEDGER #368.
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	// Create a basic scope
	scope := checker.create_scope(nil, c.allocator)
	defer checker.destroy_scope(scope)

	testing.expect(t, scope != nil, "Should create scope")
	testing.expect(t, scope.parent == nil, "Root scope should have no parent")
}

@(test)
test_scope_hierarchy :: proc(t: ^testing.T) {
	// init_checker / destroy_checker are NOT lock-free: destroy_checker calls
	// reset_runtime_type_globals, which nils the process-global runtime type state, and
	// init_checker repopulates it. Without the mutex these four lifecycle tests do that
	// concurrently with whatever package check holds it -- and a t_atomic_memory_order
	// nilled mid-check is exactly the 37 "Cannot determine type for implicit selector
	// expression" errors in core/sync that #321 kept seeing move between tests. LEDGER #368.
	checker_globals_ticket := lock_checker_globals(t)
	defer unlock_checker_globals(checker_globals_ticket)

	c := &checker.Checker{}
	checker.init_checker(c)
	defer checker.destroy_checker(c)

	// Create parent scope
	parent := checker.create_scope(nil, c.allocator)
	defer checker.destroy_scope(parent)

	// Create child scope (will be destroyed recursively by parent)
	child := checker.create_scope(parent, c.allocator)

	testing.expect(t, child.parent == parent, "Child should reference parent")
}
