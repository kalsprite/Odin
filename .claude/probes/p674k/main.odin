package main

f :: proc($T: typeid, x: int) -> int { return x }

main :: proc() {
	y := f(1)
	_ = y
}
