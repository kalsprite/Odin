package typearg

ga :: proc($T: typeid, x: int) -> int { return x }
gb :: proc(a: string, b: string) -> int { return 0 }
g  :: proc{ga, gb}

main :: proc() {
	_ = g(42, 1)
}
