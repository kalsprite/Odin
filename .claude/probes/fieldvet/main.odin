package fieldvet

// If struct-field scopes lacked the .Type flag, every one of these fields would
// be reported as an unused variable under -vet.
Big :: struct {
	alpha, beta, gamma: int,
	delta:  string,
	eps:    [4]f32,
	zeta:   ^Big,
	eta:    map[string]int,
}

Nested :: struct {
	using inner: Big,
	theta: bool,
}

U :: union { Big, Nested }

E :: enum { A, B, C }

main :: proc() {}
