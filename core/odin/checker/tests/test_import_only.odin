package test_checker

// Minimal test that only imports checker to see if that triggers the panic

import _ ".."

import "core:testing"

@(test)
test_import_checker :: proc(t: ^testing.T) {
	// Just verify the checker module can be imported
	// We're not calling any functions that use complex types
	testing.expect(t, true, "Checker import works")
}
