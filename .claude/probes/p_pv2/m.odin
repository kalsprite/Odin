package p_pv2
a1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
grpA :: proc{a1}                                  // group, ONE polymorphic member

b1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
b2 :: proc(a: ^int) {}
grpB :: proc{b1, b2}                              // group, one poly + one concrete

c1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
c2 :: proc(a: ^$T/#soa[dynamic]$E, args: ..E) {}
grpC :: proc{c1, c2}                              // group, TWO polymorphic members

d1 :: proc(a: ^$T/[dynamic]$E, arg: E) {}
d2 :: proc(a: ^$T/#soa[dynamic]$E, arg: E) {}
grpD :: proc{d1, d2}                              // two poly, NON-variadic

main :: proc() {
	d: [dynamic]int
	grpA(&d)
	grpB(&d)
	grpC(&d)
	grpD(&d, 1)
	_ = d
}
