package pgnamed3

Color :: enum { Red, Green }
pa :: proc(x: int,    c: Color) -> int { return x }
pb :: proc(x: string, c: Color) -> int { return 1 }
pg :: proc{pa, pb}

main :: proc() {
	// a POSITIONAL argument appearing AFTER a named one: the splitter puts it in `named`,
	// so it reaches the loop as a non-Field_Value -> "Expected a 'field = value'"
	_ = pg(1, c = .Green, 5)
}
