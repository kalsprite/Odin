package foreignblk_bad
foreign import lib "system:c"
@(default_calling_convention="c")
foreign lib {
	puts :: proc(s: cstring) -> i32 ---
	bad  :: proc(s: cstring) -> i32 { return 0 }
}
main :: proc() { _ = puts("x") }
