package m
import "base:runtime"
myv :: proc(a: ^[dynamic]int, args: ..int) {}
myn :: proc(a: ^[dynamic]int, #no_broadcast args: ..int) {}
main :: proc() {
	d: [dynamic]int
	myv(&d)                     // plain variadic, empty
	myn(&d)                     // #no_broadcast variadic, empty
	runtime.append_elems(&d)    // the real one, called DIRECTLY (not via the group)
	_ = d
}
