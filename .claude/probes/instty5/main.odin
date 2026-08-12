package instty5
import "base:intrinsics"

// C++ check_expr.cpp:8693-8703 -- the INSTANCE-method branch of check_objc_call_expr.
// When an objc instance method is declared to return intrinsics.objc_instancetype, the
// call's operand type becomes the type of the SELF argument (ce->args[0]->tav.type),
// not objc_instancetype. Sibling of instty3, which covers the class-method branch (#296).
@(objc_class="Q", objc_implement=true)
Q :: struct { using _: intrinsics.objc_object }

@(objc_type=Q, objc_name="dup", objc_implement=true)
Q_dup :: proc "c" (self: ^Q) -> intrinsics.objc_instancetype {
	return nil
}

f :: proc() {
	q: ^Q
	x := q->dup()
	y: ^Q = x
	_ = y
}

main :: proc() {}
