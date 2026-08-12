package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
f :: proc(x: $S) -> int where intrinsics.type_is_specialization_of(S, Foo($T)) { return 1 }
main :: proc() { _ = f(Foo(int){}) }
