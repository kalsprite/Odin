package lentype

Foo :: struct { a: int }
Arr :: [4]int
Bs  :: bit_set[0..<8]

main :: proc() {
	// must be REJECTED: type operand whose result is not constant
	a := len(Foo)
	b := cap(Foo)
	// must stay LEGAL: type operand with a compile-time constant result
	c := len(Arr)
	// bit_set gets the 'card' suggestion
	d := len(Bs)
	// value operands unaffected
	s := []int{1, 2, 3}
	e := len(s)
	_ = a; _ = b; _ = c; _ = d; _ = e
}
