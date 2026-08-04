package typeswitch_bad
U :: union { int, f32 }
main :: proc() {
	u: U
	switch v in u {
	case int:
	case string:
	case f32:
	case f32:
	}
	x := 1
	switch y in x {
	case int:
	}
}
