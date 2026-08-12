package a
Buf :: struct($N: int, $T: typeid) { data: [N]T }
Foo :: struct($T: typeid) { x: T }
main :: proc() {
	a: Buf(4, int)
	b: string = a
	c: Foo(int)
	d: string = c
}
