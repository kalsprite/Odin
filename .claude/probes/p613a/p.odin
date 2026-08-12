package p
@(require_target_feature="avx512f")
needs :: proc() {}
main :: proc() { needs() }
