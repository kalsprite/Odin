package label_bad
main :: proc() {
	outer: for i in 0..<3 {
		break nope
	}
	break outer
}
