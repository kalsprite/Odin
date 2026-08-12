package nameidx

f1 :: proc(alpha: int, beta: int) {}
f2 :: proc(alpha: string, beta: string) {}
g :: proc{f1, f2}

use :: proc() {
	g(alpha = 1.5, beta = 2.5)
}

main :: proc() { use() }
