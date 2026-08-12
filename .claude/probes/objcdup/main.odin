package objcdup
import "base:intrinsics"

// C++ check_decl.cpp:540: two types claiming the SAME @(objc_class) name.
@(objc_class="Same")
A :: struct { using _: intrinsics.objc_object }

@(objc_class="Same")
B :: struct { using _: intrinsics.objc_object }

main :: proc() {}
