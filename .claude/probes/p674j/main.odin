package main

f1 :: proc($N: int) -> int { return N }
f2 :: proc(a: f32, b: f32) -> int { return 2 }
g :: proc{f1, f2}

main :: proc() {
	x := g("hi")
	_ = x
}
