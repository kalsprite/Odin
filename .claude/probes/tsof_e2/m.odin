package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
// "Invalid specialization type" -- C++ 7364-7369.
X :: intrinsics.type_is_specialization_of(Foo(int), NotAType)
main :: proc() {}
