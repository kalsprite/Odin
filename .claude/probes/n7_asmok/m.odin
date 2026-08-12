package main
main :: proc() {
	a := asm(i32, i32) -> i32 #side_effects #align_stack #intel { "nop", "=r,r,r" }
	b := asm(i32, i32) -> i32 #att { "nop", "=r,r,r" }
	_ = a; _ = b
}
