package loadmiss

main :: proc() {
	data := #load("definitely-does-not-exist.bin") or_else panic("missing")
	x: []u8 = data
	_ = x
}
