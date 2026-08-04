package usingsub
Base :: struct { x: int }
Derived :: struct { using b: Base, y: int }
takes :: proc(b: Base) {}
main :: proc() {
	d: Derived
	takes(d)
	_ = d.x
	_ = d.nope
}
