package map_bad
main :: proc() {
	m := make(map[string]int)
	defer delete(m)
	m[1] = 2
	x: string = m["a"]
	y := m.foo
	_ = x; _ = y
}
