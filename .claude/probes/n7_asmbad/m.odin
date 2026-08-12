package main
main :: proc() {
	f := asm(i32, i32) -> i32 #bogus { "nop", "=r,r,r" }
	_ = f
}
