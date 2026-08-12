package m
import "base:runtime"
E1 :: proc(array: ^$T/[dynamic]$E, #no_broadcast arg: E, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0, nil }
E2 :: proc(array: ^$T/[dynamic]$E, #no_broadcast args: ..E, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0, nil }
G  :: proc{E1, E2}
main :: proc() {
	d: [dynamic]int
	G(&d)
	_ = d
}
