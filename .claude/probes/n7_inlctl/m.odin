package main
main :: proc() {
	a := #load("definitely_missing_file.bin")
	_ = a
}
