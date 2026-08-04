package typeargpos

fa :: proc($T: typeid, x: int) -> int { return x }
fb :: proc(a: string, b: string) -> int { return 0 }
fg :: proc{fa, fb}

main :: proc() {
	v := 3
	_ = fg(v, 1)
}
