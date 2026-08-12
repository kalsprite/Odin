package main
import "core:c"
f :: proc "c" (n: c.int, #c_vararg args: ..any) {
	x := args
	_ = x
}
main :: proc() {}
