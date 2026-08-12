package divwarn

main :: proc() {
	i := 3
	a := 1.5 / i        // constant untyped float / typed int -> value variant
	_ = a

	f := 2.5
	b := f / i          // non-constant untyped? -> no-value variant
	_ = b

	c := 7.5
	c /= i              // QuoEq: C++ guards it, port's case list omits it
	_ = c
}
