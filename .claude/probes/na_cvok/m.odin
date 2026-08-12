package main
import "base:intrinsics"
import "core:c"
f :: proc "c" (n: c.int, #c_vararg args: ..any) {
	list: intrinsics.c_va_list
	intrinsics.c_va_start(&list, args)
}
main :: proc() {}
