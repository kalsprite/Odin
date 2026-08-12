package instty3
import "base:intrinsics"

@(objc_class="P", objc_implement=true)
P :: struct { using _: intrinsics.objc_object }

@(objc_type=P, objc_name="make", objc_is_class_method=true, objc_implement=true)
P_make :: proc "c" () -> intrinsics.objc_instancetype {
	return nil
}

f :: proc() {
	x := P.make()
	y: ^P = x
	_ = y
}

main :: proc() {}
