package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
Bar :: struct($T: typeid) { y: T }
// REJECT: Bar(int) is NOT a specialization of Foo -- the where clause must fail.
f :: proc(v: $V) -> int where intrinsics.type_is_specialization_of(V, Foo) { return 1 }
g :: proc() -> int { return f(Bar(int){}) }
main :: proc() {}
