package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
// `where` is the real use site. ACCEPT: Foo(int) IS a specialization of Foo.
f :: proc(v: $V) -> int where intrinsics.type_is_specialization_of(V, Foo) { return 1 }
g :: proc() -> int { return f(Foo(int){}) }
main :: proc() {}
