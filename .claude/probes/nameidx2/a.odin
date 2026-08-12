package nameidx2

T :: struct { v: int }

f1 :: proc(self: ^T, alpha: int, beta: int) {}
f2 :: proc(self: ^T, alpha: string, beta: string) {}
g :: proc{f1, f2}

use :: proc() {
	t: T
	g(t, alpha = 1.5, beta = 2.5)
}

main :: proc() { use() }
