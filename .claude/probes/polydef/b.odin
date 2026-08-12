package polydef
// The accepted contrast set: a polymorphic proc that DOES instantiate to the target, used
// both as the default and passed explicitly. Must produce NO diagnostic.
ok :: proc(x: $T) -> T { return x }
good :: proc(cb: proc(x: int) -> int = ok) -> int { return cb(1) }
use :: proc() -> int { return good() + good(ok) }
main :: proc() { _ = use() }
