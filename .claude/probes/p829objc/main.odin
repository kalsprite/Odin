package p829objc

import "base:intrinsics"

@(objc_class="NSBase")
Base :: struct {}

@(objc_class="NSDerived", objc_superclass=Base)
Derived :: struct { using _: Base }

main :: proc() {
	d: ^Derived
	intrinsics.objc_send(rawptr, intrinsics.objc_super(d), "init")
}
