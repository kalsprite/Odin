package polydef
// #386: upstream removed the "polymorphic procedure as default value" short-circuit from
// check_is_assignable_to_with_score. It accepted ANY polymorphic proc for ANY concrete proc
// type on the promise it would be "properly instantiated when actually used", so a
// polymorphic proc that could never instantiate to the target was taken silently.
// One rejected shape per declaration.
p1 :: proc(a, b: $T) -> T { return a }
bad_arity_2v1 :: proc(cb: proc(x: int) -> int = p1) -> int { return cb(1) }

p2 :: proc(x: $T) -> T { return x }
bad_arity_1v2 :: proc(cb: proc(x: int, y: int) -> int = p2) -> int { return cb(1, 2) }

p3 :: proc(x: $T) { }
bad_result_0v1 :: proc(cb: proc(x: int) -> int = p3) -> int { return cb(1) }
