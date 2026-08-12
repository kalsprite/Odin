package pgnamed2

Color :: enum { Red, Green }
pa :: proc(x: int,    c: Color) -> int { return x }
pb :: proc(x: string, c: Color) -> int { return 1 }
pg :: proc{pa, pb}

S :: struct { y: int }
s: S

main :: proc() {
	// named argument whose FIELD is not an identifier -> "Invalid parameter name"
	_ = pg(1, s.y = .Green)
	// unknown named parameter (control: should still be diagnosed somehow)
	_ = pg(1, nope = .Green)
}
