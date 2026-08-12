package p_pv
solo :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
g1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
g2 :: proc(a: ^$T/#soa[dynamic]$E, args: ..E) {}
grp :: proc{g1, g2}
main :: proc() {
	d: [dynamic]int
	solo(&d)      // single polymorphic proc, zero varargs
	grp(&d)       // group with 2 members, zero varargs
	_ = d
}
