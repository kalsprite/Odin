package whenstmt_bad
main :: proc() {
	when 1 { }
	when ODIN_OS == .Linux { x := 1; _ = x }
	y := 1
	when y == 1 { }
}
