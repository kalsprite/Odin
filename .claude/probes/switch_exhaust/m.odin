package switch_exhaust
E :: enum { A, B, C }
main :: proc() {
	e := E.A
	#partial switch e {
	case .A:
	}
	switch e {
	case .A:
	}
}
