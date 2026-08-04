package procgroup_bad
fi :: proc(a: int) {}
fs :: proc(a: string) {}
g :: proc{fi, fs}
main :: proc() {
	g(1)
	g("x")
	g(1.5)
	g()
}
