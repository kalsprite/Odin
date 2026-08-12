package p_grpC
c1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
c2 :: proc(a: ^$T/#soa[dynamic]$E, args: ..E) {}
grpC :: proc{c1, c2}
main :: proc() {
	d: [dynamic]int
	grpC(&d)
	_ = d
}
