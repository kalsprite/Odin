package main

f :: proc(a: $T, b: ^T) -> int { return 1 }

main :: proc() {
	y: f32
	x := f(1, &y)
	_ = x
}
