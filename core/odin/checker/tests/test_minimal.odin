package test_checker

import "core:testing"

@(test)
test_true :: proc(t: ^testing.T) {
	testing.expect(t, true, "True should be true")
}
