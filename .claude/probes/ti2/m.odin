package ti2

Foo :: struct { a: int }
Arr :: [4]int

main :: proc() {
	a := len(Foo)
	b := cap(Foo)
	c := len(Arr)
	d := abs(Foo)
	_ = a; _ = b; _ = c; _ = d
}
