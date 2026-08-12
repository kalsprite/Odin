package a
import "base:intrinsics"
Foo :: struct($T: typeid) { x: T }
Bar :: struct($T: typeid) { y: T }
// Both directions as CONSTANT assertions -- no `where` clause, so no #660 definitions-block flake.
#assert(intrinsics.type_is_specialization_of(Foo(int), Foo))
#assert(!intrinsics.type_is_specialization_of(Bar(int), Foo))
#assert(!intrinsics.type_is_specialization_of(int, Foo))
main :: proc() {}
