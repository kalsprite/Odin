package partialpoly

// f is a POLYMORPHIC procedure; its entity type stays polymorphic.
f :: proc(x: $T) -> T { return x }

// h takes a polymorphic value parameter, so passing `f` drives
// determine_type_from_polymorphic down the ExactValue_Procedure branch.
h :: proc(cb: $F) { }

main :: proc() {
	h(f)
}
