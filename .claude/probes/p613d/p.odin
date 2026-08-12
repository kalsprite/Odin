package p
@(enable_target_feature="sse4.2")
en :: proc "contextless" () -> int { return 1 }
g := #force_inline en()
main :: proc() {}
