package main
import "core:fmt"
f :: proc(prefix: string, rest: ..int) -> int {
	t := 0
	for r in rest { t += r }
	fmt.println(prefix, t)
	return t
}
main :: proc() { _ = f("sum", 1, 2, 3) }
