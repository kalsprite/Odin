package main
main :: proc() {
	a := #force_inline #load("definitely_missing_file.bin")
	_ = a
}
