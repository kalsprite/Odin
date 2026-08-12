package shadowparam

import "core:slice"

Entry :: struct($T: typeid) {
	pre_key: [16]u8,
	val:     T,
}

// Polymorphic INSTANTIATED parameter type -- the exact cbor/marshal.odin shape.
sorted :: proc(items: []Entry(^[]byte)) {
	slice.sort_by_cmp(items, proc(a, b: Entry(^[]byte)) -> slice.Ordering {
		a, b := a, b
		if a.pre_key[0] < b.pre_key[0] { return .Less }
		return .Greater
	})
}
