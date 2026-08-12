package p
@(enable_target_feature="sse4.2")
en :: proc() {}
main :: proc() { #force_inline en() }
