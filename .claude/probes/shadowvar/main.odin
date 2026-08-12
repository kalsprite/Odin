package shadowvar
// PLAIN (non-polymorphic) struct; only the CALLEE is polymorphic.
Entry :: struct { pre_key: [16]u8 }
take :: proc(items: []$E, p: proc(a, b: E) -> bool) {}
f :: proc(items: []Entry) {
	take(items, proc(a, b: Entry) -> bool {
		a, b := a, b
		return a.pre_key[0] < b.pre_key[0]
	})
}
