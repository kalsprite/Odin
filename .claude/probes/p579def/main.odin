package m
// #579 A: an untyped constant argument prefers the candidate whose parameter is its DEFAULT type.
// Pre-#579 both f_int and f_i64 score 1, so the call is Ambiguous. The diagnostic below names r's
// resolved type, which is what makes the winning overload observable.
f_int :: proc(x: int) -> int { return 1 }
f_i64 :: proc(x: i64) -> i64 { return 2 }
f :: proc{f_int, f_i64}
main :: proc() {
	r := f(1)
	bad: string = r
	_ = bad
}
