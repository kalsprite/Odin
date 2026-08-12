package main
main :: proc() {
	f := asm(i32, i32) -> i32 #side_effects #side_effects { "nop", "=r,r,r" }
	g := asm(i32, i32) -> i32 #att #intel { "nop", "=r,r,r" }
	_ = f; _ = g
}
