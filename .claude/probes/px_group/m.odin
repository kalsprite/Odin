package m
// non-polymorphic group with a variadic member
nv1 :: proc(a: ^[dynamic]int, args: ..int) {}
nv2 :: proc(a: ^[dynamic]int, s: string) {}
ng  :: proc{nv1, nv2}

// polymorphic group with a variadic member (append's shape)
pv1 :: proc(a: ^$T/[dynamic]$E, args: ..E) {}
pv2 :: proc(a: ^$T/[dynamic]$E, s: string) {}
pg  :: proc{pv1, pv2}

main :: proc() {
	d: [dynamic]int
	ng(&d)      // non-poly group, empty variadic
	pg(&d)      // poly group, empty variadic
	_ = d
}
