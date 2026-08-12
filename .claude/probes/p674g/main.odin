package main

f :: proc($N: f32) -> f32 { return N }

main :: proc() {
	x := f(3)
	_ = x
}
