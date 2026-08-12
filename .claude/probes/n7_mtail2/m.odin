package main
callee :: proc(x: int) -> int { return x }
caller :: proc() -> int {
	return #must_tail callee(1)
}
main :: proc() { _ = caller() }
