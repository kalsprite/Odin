package main

f :: proc($N: int) -> int { return N }

main :: proc() {
	x := f("hi")
	_ = x
}
