package cyclediag
A :: struct { b: B }
B :: struct { a: A }
main :: proc() {
	x: A
	z: int = x          // message must name x's type
	w := x.b            // field access through a cycled type
	q: string = w
	_ = z; _ = q
}
