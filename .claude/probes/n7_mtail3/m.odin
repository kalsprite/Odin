package main
callee :: proc() -> int { return 1 }
caller :: proc() -> int {
	return #must_tail callee()
}
main :: proc() { _ = caller() }
