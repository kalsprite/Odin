package abi_riscv64

import abi "core:rexcode/abi"
import riscv "core:rexcode/isa/riscv"

// RISC-V LP64D classification.
//
// The third architecture, and a third structural model. It is not SysV's
// per-eightbyte merge and it is not AAPCS64's homogeneous aggregate:
//
//   * one or two floating-point members go in FP registers, and their widths
//     need NOT match -- `struct{f32, f64}` is (fa0, fa1), where AAPCS64 would
//     require both members to be the same type to be an HFA;
//   * one float plus one integer goes in one FP and one integer register, in
//     DECLARED order, so `struct{i8, f32}` and `struct{f32, i8}` differ;
//   * three or more floats fall back to integer registers entirely, where
//     AAPCS64 would use three SIMD registers;
//   * unions never flatten;
//   * there is no unaligned-fields-are-memory rule -- `#packed{i8, f32}` still
//     gets (fa0, a0) where SysV sends it to the stack.
//
// Every one of those was measured against clang over the enumerated universe,
// not read from the specification. See README.

// The register widths are read from the CONVENTION, not fixed here: LP64D and
// ILP32D are the same rules over a 4- or 8-byte word, and the whole point of a
// row model is that the second one costs a table entry rather than a file.

classify :: proc(
	size, align: u32,
	fields: []abi.Field,
	conv: ^abi.Convention,
	pos: abi.Position,
	shape: abi.Param_Shape,
	flags: abi.Param_Flags,
	buf: []abi.Piece, // caller-owned; size it with abi.pieces_needed
) -> abi.Location {
	// The two booleans this used to take, derived ONCE here so the body below
	// is unchanged and the caller can neither swap them nor forget one.
	is_aggregate := shape != .SCALAR
	is_union     := shape == .UNION
	_, _ = is_aggregate, is_union
	// A nil or zero convention is not one. `classify_signature` refuses it
	// up front; this is the direct-call path, where the first thing below
	// would divide by `word_size` or read `conv.max_by_value` through nil.
	if conv == nil || conv.word_size == 0 { return nil }
	// ... and an UNSET Param is not one either.
	//
	// `check_param` catches `Param_Shape.INVALID`, but only inside
	// `classify_signature`. These four entry points are public and are the path
	// a backend driving classify+assign itself takes -- and `.INVALID` fell into
	// the aggregate branch, so a completely unset Param produced a confident
	// answer. Measured: passing `.INVALID` for every type in the sweep gave
	// aarch64 and riscv64 1434/1434 AGREEING, zero refusals. The enum exists so
	// the unclaimed case is loud; it was silent here.
	if shape == .INVALID { return nil }
	if size == 0 {
		return abi.Direct{}
	}
	xlen := conv.word_size
	flen := conv.float_size

	// The floating-point rules come BEFORE the size test, and they ignore
	// padding entirely.
	//
	// `struct #align(32){f32, f32}` is THIRTY-TWO bytes -- twice the by-value
	// limit, with 24 bytes of padding -- and is still passed in two FP
	// registers. Testing size first sends it indirect. This is the same
	// ordering trap as AAPCS64's HFA rule, and it was got wrong here anyway
	// after being written down there; the sweep caught it in one run.
	//
	// It differs from AAPCS64 in the other direction, though: an HFA must TILE
	// its aggregate with no padding, and this rule does not care.
	//
	// The rules apply to structs, not to overlapping members: every union in
	// the corpus goes to integer registers, including `union{f32, f32}`, which
	// is four bytes and one register where the same two members as a STRUCT are
	// eight bytes and two FP registers.
	// A union never takes the FP rules, and neither does anything CONTAINING
	// one. Three tests, because each sees a case the others cannot:
	//
	//   overlapping()    a union with two or more members, by offset
	//   is_union         a one-member union at the TOP level
	//   any_in_union()   a one-member union NESTED at any depth
	//
	// Measured: clang and gcc 15.1 pass `union{float}` in a0 and `struct{float}`
	// in fa0 -- same field list, different register file -- and
	// `struct{float, union{int}}` in ONE integer register where the FP rule
	// would have said (fa0, a0), wrong file AND wrong count, so every argument
	// after it shifted too.
	// The cheap tests FIRST. `overlapping` is O(n^2) over the leaves, and it ran
	// before anything that could rule the type out: 40,000 leaves cost 303ms for
	// an aggregate that the size rule then sends indirect in one comparison. The
	// FP rule takes at most two members anyway, so a longer list cannot satisfy
	// it and the quadratic scan was never going to change the answer.
	if len(fields) <= 2 && !is_union && !overlapping(fields) && !any_in_union(fields) {
		if d, ok := fp_rule(fields, xlen, flen, buf); ok {
			return d
		}
	}

	limit := conv.max_by_value
	if pos == .RETURN && is_aggregate {
		if r, has := conv.max_by_value_ret.?; has { limit = r }
	}
	if size > limit {
		al := align
		if al < xlen { al = xlen }
		// Honour the row's `over_max` rather than hardcoding INDIRECT.
		//
		// This returned `Indirect` unconditionally, so the field was read by ONE
		// classifier of three -- which the x86 classifier's own comment names as
		// worse than an unread field, because it LOOKS live. Two consequences
		// were latent: AAPCS32's `over_max = .STACK_COPY` was dead (AAPCS32 runs
		// this classifier, and its row documents "arguments are never passed
		// indirectly at any size"), and `lang_odin`'s INDIRECT override took
		// effect only on x86-64 -- correct elsewhere by coincidence, since those
		// platforms are already INDIRECT.
		if pos == .RETURN {
			return abi.Sret{align = al}
		}
		switch conv.over_max {
		case .INDIRECT:   return abi.Indirect{align = al}
		case .STACK_COPY: return abi.Stack{size = size, align = al}
		}
		return abi.Indirect{align = al}
	}

	// Otherwise ceil(size / XLEN) integer registers.
	n := (size + xlen - 1) / xlen
	ps := buf[:n]
	for i in 0 ..< n {
		w := size - i * xlen
		if w > xlen { w = xlen }
		ps[i] = abi.make_piece(.INTEGER, i * xlen, w)
	}
	return abi.Direct{pieces = ps}
}

// fp_rule covers the two shapes the hardware floating-point convention accepts.
fp_rule :: proc(fields: []abi.Field, xlen, flen: u32, buf: []abi.Piece) -> (d: abi.Direct, ok: bool) {
	if len(fields) == 1 {
		f := fields[0]
		if f.class == .FLOAT && f.size <= flen {
			d.pieces = buf[:1]
			d.pieces[0] = abi.make_piece(.FLOAT, f.offset, f.size)
			return d, true
		}
		return d, false
	}
	if len(fields) != 2 {
		return d, false
	}
	a, b := fields[0], fields[1]

	// Two floats, widths INDEPENDENT of each other.
	if a.class == .FLOAT && b.class == .FLOAT && a.size <= flen && b.size <= flen {
		d.pieces = buf[:2]
		d.pieces[0] = abi.make_piece(.FLOAT, a.offset, a.size)
		d.pieces[1] = abi.make_piece(.FLOAT, b.offset, b.size)
		return d, true
	}
	// One float and one integer, in either order, preserving declared order.
	if a.class == .FLOAT && a.size <= flen && int_eligible(b, xlen) {
		d.pieces = buf[:2]
		d.pieces[0] = abi.make_piece(.FLOAT, a.offset, a.size)
		d.pieces[1] = abi.make_piece(.INTEGER, b.offset, b.size)
		return d, true
	}
	if b.class == .FLOAT && b.size <= flen && int_eligible(a, xlen) {
		d.pieces = buf[:2]
		d.pieces[0] = abi.make_piece(.INTEGER, a.offset, a.size)
		d.pieces[1] = abi.make_piece(.FLOAT, b.offset, b.size)
		return d, true
	}
	return d, false
}

// int_eligible is the "integer (or bitfield)" half of the psABI rule.
//
// A POINTER is excluded, which is the one place this classifier follows clang
// against the other available implementation. Odin's own `lbAbiRiscv64` tests
// with `is_register()`, which admits `LLVMPointerTypeKind`, and therefore passes
// `struct{f32, rawptr}` as (fa0, a0) where clang passes it as (a0, a1) --
// verified by disassembling both. The psABI says "integer", and a pointer is
// not an integer type in C, so clang is followed here; the disagreement is
// recorded in COMPILER_ISSUES rather than silently resolved.
int_eligible :: proc(f: abi.Field, xlen: u32) -> bool {
	return f.class == .INTEGER && !f.is_pointer && f.size <= xlen
}

// overlapping reports whether any two leaves share a byte, which is how a union
// is recognised from a flattened field list.
// any_in_union reports whether any leaf was reached through a union.
//
// The flattener sets the flag; this only reads it. Deriving it here is not
// possible -- that is the whole reason the flag exists.
@(private)
any_in_union :: proc(fields: []abi.Field) -> bool {
	for f in fields { if f.in_union { return true } }
	return false
}

overlapping :: proc(fields: []abi.Field) -> bool {
	for i in 0 ..< len(fields) {
		for j in i + 1 ..< len(fields) {
			a, b := fields[i], fields[j]
			if a.size == 0 || b.size == 0 { continue }
			if a.offset < b.offset + b.size && b.offset < a.offset + a.size {
				return true
			}
		}
	}
	return false
}

// ---------------------------------------------------------------------------
// Convention rows
//
// LP64D and ILP32D name the SAME registers -- `isa/riscv` has one file and the
// width lives in the Convention, not the register.

RV_A := [?]u16{
	u16(riscv.A0), u16(riscv.A1), u16(riscv.A2), u16(riscv.A3),
	u16(riscv.A4), u16(riscv.A5), u16(riscv.A6), u16(riscv.A7),
}
RV_RET_A  := [?]u16{u16(riscv.A0), u16(riscv.A1)}
RV_RET_FA := [?]u16{u16(riscv.FA0), u16(riscv.FA1)}

RV_FA := [?]u16{
	u16(riscv.FA0), u16(riscv.FA1), u16(riscv.FA2), u16(riscv.FA3),
	u16(riscv.FA4), u16(riscv.FA5), u16(riscv.FA6), u16(riscv.FA7),
}

LP64D := abi.Convention{
	name         = "lp64d",
	varargs      = .INT_REGS,
	// Measured: `-> (i64, i64)` comes back as `{ i64, i64 }` in a0:a1, and
	// `-> (i8, f64)` as `{ i8, double }` -- the float-plus-integer rule applied
	// to the TUPLE, which is the clearest evidence that it really is classified
	// as one ordinary struct and not special-cased.
	multi_return = .TUPLE_ELSE_POINTERS,
	// RISC-V splits a 2*XLEN argument when exactly one register remains: the
	// low XLEN bits go in it and the high bits on the stack. Measured --
	// f(long x7, struct{long,long}) puts s.a in a7 and s.b at sp+0, and the
	// callee reads `ld a0, 0(sp)`. Applies to SCALARS too (__int128), which is
	// wider than AAPCS32's composite-only rule.
	// Measured, not left at zero. A stacked 2*XLEN value is 2*XLEN-aligned:
	// clang AND gcc both put an `__int128` at sp+16 after nine longs, leaving
	// sp+8 as padding, and the same on ilp32d with `long long` at sp+8.
	// Confirmed by execution under qemu, not only by reading asm.
	stack_arg_align_max = 16,
	splits_aggregates = true,
	int_regs     = RV_A[:],
	float_regs   = RV_FA[:],
	ret_int_regs   = RV_RET_A[:],
	ret_float_regs = RV_RET_FA[:],
	word_size    = 8,
	float_size   = 8,
	max_by_value = 16,
	over_max     = .INDIRECT,
	stack_align  = 8,
	float_spills_to_int = true,
}

LP64D_ODIN:  abi.Convention
ILP32D_ODIN: abi.Convention

@(init)
init_riscv_conventions :: proc "contextless" () {
	LP64D_ODIN  = abi.compose(LP64D,  abi.lang_odin())
	ILP32D_ODIN = abi.compose(ILP32D, abi.lang_odin())
	LP64D       = abi.compose(LP64D,  abi.lang_c())
	ILP32D      = abi.compose(ILP32D, abi.lang_c())
}

// ILP32D is the same rules over a four-byte word. One row, no new code -- which
// is the claim being tested, not an assumption being made.
ILP32D := abi.Convention{
	name         = "ilp32d",
	// Inherited from LP64D, not measured: Odin has no linux_riscv32 target, so
	// no caller can be built for it. Recorded as an inheritance rather than a
	// measurement -- see the ILP32D note in the oracle's blocker list.
	multi_return = .TUPLE_ELSE_POINTERS,
	varargs      = .INT_REGS,
	// Measured, not left at zero. A stacked 2*XLEN value is 2*XLEN-aligned:
	// clang AND gcc both put an `__int128` at sp+16 after nine longs, leaving
	// sp+8 as padding, and the same on ilp32d with `long long` at sp+8.
	// Confirmed by execution under qemu, not only by reading asm.
	stack_arg_align_max = 16,
	splits_aggregates = true, // as LP64D; the rule is stated in XLEN units
	int_regs     = RV_A[:],
	float_regs   = RV_FA[:],
	ret_int_regs   = RV_RET_A[:],
	ret_float_regs = RV_RET_FA[:],
	word_size    = 4,
	float_size   = 8, // the D extension keeps 64-bit FP registers on ILP32
	max_by_value = 8, // 2 * XLEN
	over_max     = .INDIRECT,
	stack_align  = 4,
	float_spills_to_int = true,
}

// ---------------------------------------------------------------------------
// Typed seams

reg :: proc(p: abi.Piece) -> riscv.Register { return riscv.Register(p.reg) }

// `n_fixed` is FORWARDED, and was not.
//
// These four wrappers are the typed seam a backend is meant to call, and they
// dropped the varargs parameter on the floor -- so a caller reaching the library
// this way could not describe a variadic call AT ALL. Every argument was treated
// as named, the convention's `varargs` rule never applied, and SysV's
// `varargs_sse_count` came back 0 for every signature.
//
// It survived because every probe here calls `classify_signature` directly, so
// the whole varargs axis was exercised through the shared entry point and dead
// through the one with the arch's name on it. A default argument that silently
// discards a caller's intent is worse than not having the parameter.
layout :: proc(params, results: []abi.Param, conv: ^abi.Convention,
               allocator := context.allocator, n_fixed := -1) -> (abi.Call_Layout, bool) {
	return abi.classify_signature(classify, params, results, conv, allocator, n_fixed)
}
