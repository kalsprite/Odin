package main
main :: proc() {
	f := asm(Undefined_Type) -> i32 { "nop", "=r,r" }
	_ = f
}
