package main
main :: proc() {
	X :: 1 << 200
	Y :: 1 << 1024
	_ = X; _ = Y
}
