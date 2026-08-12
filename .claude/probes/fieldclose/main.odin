package fieldclose

// LEDGER #251: unterminated struct field list. C++ ends expect_closing_brace_of_field_list
// with a bare expect_token -> "Expected '}'", and does NOT scan forward, so whatever follows
// still gets reported.
S :: struct {
	a: int
	b: int

main :: proc() {}
