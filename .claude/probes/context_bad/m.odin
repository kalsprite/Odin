package context_bad
f :: proc "contextless" () {
	_ = context.allocator
}
main :: proc() { f() }
