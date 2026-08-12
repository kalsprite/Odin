package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
v := 1
// "Expected a type for 'type_is_specialization_of'" -- C++ 7350-7355.
X :: intrinsics.type_is_specialization_of(v, Foo($T))
main :: proc() {}
