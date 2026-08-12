package objchang

import "base:intrinsics"

Object :: struct { isa: rawptr }
Copying :: struct($T: typeid) { using _: Object }

@(objc_class="NSFoo")
Foo :: struct { using _: Copying(Foo) }

@(objc_type=Foo, objc_name="alloc", objc_is_class_method=true)
Foo_alloc :: proc "c" () -> ^Foo {
	return intrinsics.objc_send(^Foo, Foo, "alloc")
}

main :: proc() {}
