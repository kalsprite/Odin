package p_ppp
gen :: proc(a: $T, b: $U) -> T { return a }
takes :: proc(f: proc(x: $V) -> V, v: V) -> V { return f(v) }
main :: proc() {
	_ = takes(gen, 3)
}
