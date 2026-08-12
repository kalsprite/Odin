package main
main :: proc() {
	v := "runtime"
	f := asm(i32) -> i32 { v, "=r,r" }
	_ = f
}
