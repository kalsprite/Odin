package polyproc
f :: proc(x: $T) -> T { return x }
g :: proc(a: $T, b: T) -> T { return a }
main :: proc() {
	_ = f(1)
	_ = g(1, "x")
	_ = f()
}
