package main

f :: proc(a: $T, b: T) -> int { return 1 }

main :: proc() {
	x := f(1, "hi")
	_ = x
}
