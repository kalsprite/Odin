package m
// #579 C: a value-polymorphic candidate ($S: string) outranks a plain generic one (x: $T).
// Pre-#579 both score the same and the call is Ambiguous. The result type reveals the winner:
// int means g_val won, f32 means g_gen did.
g_val :: proc($S: string) -> int { return 1 }
g_gen :: proc(x: $T)      -> f32 { return 2 }
g :: proc{g_val, g_gen}
main :: proc() {
	r := g("hi")
	bad: bool = r
	_ = bad
}
