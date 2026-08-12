package pgnamed

Color :: enum { Red, Green, Blue }
Flags :: bit_set[Color]

// a PROC GROUP -- the named-arg path under test
pa :: proc(x: int,   c: Color) -> int { return x }
pb :: proc(x: string, c: Color) -> int { return 1 }
pg :: proc{pa, pb}

main :: proc() {
	// named argument whose VALUE needs a type hint (implicit enum selector)
	_ = pg(1, c = .Green)
	// named argument needing a hint for a compound literal
	_ = pg("s", c = Color.Blue)
}
