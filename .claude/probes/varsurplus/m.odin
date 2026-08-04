package varsurplus
// Group calls that pass MORE arguments than the procedure has parameters.
// This is the shape the whole probe corpus was missing: every other polymorphic
// probe supplies FEWER arguments than parameters, so a change that mishandles
// surplus variadic arguments passes them all and still breaks real code
// (core/debug/trace and core/rexcode/ir/wasm both do exactly this).
main :: proc() {
	cmd: [dynamic]string
	defer delete(cmd)
	append(&cmd, "prog", "--functions", "--exe", "")

	b: [dynamic]u8
	defer delete(b)
	v := u32(0x1234_5678)
	append(&b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))

	n: [dynamic]int
	defer delete(n)
	append(&n, 1, 2, 3)
	append(&n, 1)
	_ = cmd; _ = b; _ = n
}
