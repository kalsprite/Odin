package main

f :: proc(a: ^$T, b: int) -> int { return b }

main :: proc() {
	y := 3
	x := f(y, "no")
	_ = x
}
