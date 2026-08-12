package dirw

f :: proc(x: any) -> int {
	v := #type_assert x.(int)
	w := #no_type_assert x.(int)
	return v + w
}

g :: proc() -> int {
	return #force_inline f(1)
}

main :: proc() {}
