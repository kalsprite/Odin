package slice_bad
main :: proc() {
	a := [4]int{1,2,3,4}
	s := a[1:9:2]
	b := a["x"]
	c := a[1][2]
	_ = s; _ = b; _ = c
}
