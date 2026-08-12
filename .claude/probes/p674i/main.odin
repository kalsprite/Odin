package main

f :: proc(a: $T, #any_int n: int) -> int { return 1 }

main :: proc() {
	x := f(1, "hi")
	_ = x
}
