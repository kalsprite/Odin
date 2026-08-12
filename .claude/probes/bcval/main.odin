package bcval
f :: proc(x: any) -> int {
	v := #bounds_check x.(int)
	return v
}
main :: proc() {}
