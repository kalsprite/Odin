package m
import "base:runtime"
AE  :: proc(a: ^$T/[dynamic]$E, #no_broadcast arg: E, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0,nil }
AES :: proc(a: ^$T/[dynamic]$E, #no_broadcast args: ..E, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0,nil }
AFE :: proc "contextless" (a: ^$T/[dynamic; $N]$E, #no_broadcast args: ..E) -> int { return 0 }
ASE :: proc(a: ^$T/#soa[dynamic]$E, #no_broadcast args: ..E, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0,nil }
AST :: proc(a: ^$T/[dynamic]$E/u8, arg: $A/string, loc := #caller_location) -> (int, runtime.Allocator_Error) #optional_allocator_error { return 0,nil }
G :: proc{AE, AES}
main :: proc() {
	d: [dynamic]int
	G(&d)
	_ = d
}
