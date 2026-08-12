package main

f :: proc(a: []$T, b: int) -> int { return b }

main :: proc() {
	x := f(1, "no")
	_ = x
}
