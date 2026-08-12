package pp1

f :: proc(x: $T) -> T { return x }
g :: proc(p: $P) -> $R { return {} }
h :: proc(cb: $F) { }

main :: proc() {
	h(f)
	g(f)
}
