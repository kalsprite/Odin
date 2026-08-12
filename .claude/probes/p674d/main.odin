package main

f :: proc(a: $T/[4]f32, #no_broadcast b: T) -> int { return 1 }

main :: proc() {
	v: [4]f32
	x := f(v, 1.0)
	_ = x
}
