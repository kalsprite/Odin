package p
@(require_target_feature="not_a_real_feature")
needs :: proc() {}
main :: proc() { needs() }
