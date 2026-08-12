package p
@(enable_target_feature="not_a_real_feature")
en :: proc() {}
main :: proc() { en() }
