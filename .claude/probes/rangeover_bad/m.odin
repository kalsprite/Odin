package rangeover_bad
E :: enum { A, B }
main :: proc() {
	for x in 1 { _ = x }
	m := make(map[int]int); defer delete(m)
	for k, v, extra in m { _ = k; _ = v; _ = extra }
	for c in "abc" { _ = c }
	for e in E { _ = e }
}
