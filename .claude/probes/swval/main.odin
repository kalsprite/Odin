package swval

Big :: struct { data: [1 << 19]u8 }   // 512 KiB, well over the 256 KiB threshold
U   :: union { Big, int }

// BY REFERENCE: C++ sets is_ref = !(flags & Value) for a SwitchValue binding,
// so no stack-overflow warning should be emitted.
by_ref :: proc(u: ^U) {
	switch &v in u {
	case Big: _ = v
	case int: _ = v
	}
}

// BY VALUE: is_ref stays false, so the warning IS expected.
by_val :: proc(u: U) {
	switch v in u {
	case Big: _ = v
	case int: _ = v
	}
}

main :: proc() {}
