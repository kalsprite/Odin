package objcdup2
import "base:intrinsics"

@(objc_class="Same", objc_implement=true)
A :: struct { using _: intrinsics.objc_object }

@(objc_class="Same", objc_implement=true)
B :: struct { using _: intrinsics.objc_object }

main :: proc() {}
