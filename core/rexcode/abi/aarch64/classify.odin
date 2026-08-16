package abi_aarch64

import abi "core:rexcode/abi"
import arm64 "core:rexcode/isa/arm64"

// AAPCS64 classification.
//
// The second architecture, and the reason `Location` was designed against a
// measurement instead of generalised from SysV. AArch64 has no eightbyte: a
// homogeneous float aggregate goes in up to four SIMD registers, one member
// each, and `struct{f32 x 4}` is four S-registers rather than two 8-byte
// chunks. A `[2]Class` model cannot say that, and 980 argument positions in the
// survey need it said.
//
// Three rules, in order. Order matters -- the HFA test comes FIRST, before the
// size test, because a 16-byte HFA of four floats is registers while a 16-byte
// mixed struct is also registers but integer ones, and a 32-byte HFA of four
// doubles is STILL four registers despite being twice the by-value limit.

MAX_HFA :: 4

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

	// RULE 1: Homogeneous Floating-point Aggregate.
	//
	// Deliberately before the size check: `struct{f64 x 4}` is 32 bytes, twice
	// `max_by_value`, and is still passed in four D registers. A classifier
	// that tests size first sends it indirect and is wrong about the largest
	// aggregates AArch64 passes in registers at all.
	// A member occupying NO BYTES disqualifies it. AAPCS64 §5.9.5 and AAPCS32
	// alike: the eligibility rule is over the aggregate's MEMBERS, and a
	// zero-length array is a member that is not a floating-point type.
	//
	// The leaves cannot say so -- such a member produces none -- which is why
	// `HAS_EMPTY_MEMBER` is carried on the Param rather than inferred. Measured,
	// and the position and element type make no difference:
	//
	//                          struct{f32 a,b,c,d}   struct{f32 z[0]; f32 a,b,c,d}
	//   aarch64-linux-gnu      [4 x float]           [2 x i64]
	//   armv7-linux-gnueabihf  %struct.H4            [4 x i32]
	//
	// Odin's own backend agrees on linux_arm64, for `proc "c"` and `proc "odin"`
	// alike. It is NOT universal -- riscv64 and x86-64 ignore the member
	// entirely -- so it belongs here, in the convention that cares, and not in
	// the shared field list where every walk would see it.
	hfa_eligible := .HAS_EMPTY_MEMBER not_in flags
	// A BARE FLOAT SCALAR is not an aggregate, and the homogeneous rule's width
	// list does not govern it.
	//
	// `hfa` is how a one-member float reaches the FP file, so a scalar was being
	// asked a question about AGGREGATES -- and on AAPCS32, whose list is
	// {4,8,16}, a two-byte one failed it and went to a core register. Measured
	// on armv7-hf, and the two cases really do differ:
	//
	//     _Float16              clang SSE    the VFP file
	//     struct{f16}           clang INT    NOT a homogeneous aggregate
	//     struct{f16,f16,f16}   clang INT,INT
	//
	// so adding `.W2` to the row would have been the wrong fix in the other
	// direction -- it turned all twelve aggregate rows red, which is how the
	// distinction was found. Only the SCALAR bypasses the list, and only where
	// the row has a float file to bypass it into: arm32's soft-float row has
	// none, and a bare float there is core-passed like everything else.
	if !is_aggregate && len(fields) == 1 && fields[0].class == .FLOAT &&
	   len(conv.float_regs) > 0 && len(buf) >= 1 {
		buf[0] = abi.make_piece(.FLOAT, 0, size)
		return abi.Direct{pieces = buf[:1]}
	}
	if n, w, ok := hfa(size, fields, conv.homogeneous, conv, pos, shape); ok && hfa_eligible {
		hcls := fields[0].class
		ps := buf[:n]
		for i in 0 ..< n {
			ps[i] = abi.make_piece(hcls, u32(i) * w, w)
		}
		return abi.Direct{pieces = ps}
	}

	// The limit differs by position on AAPCS32; on AAPCS64 the two coincide.
	limit := conv.max_by_value
	// The narrower return limit applies to AGGREGATES only. A bare 64-bit
	// scalar comes back in r0:r1 on AAPCS32, not through `sret` -- the rule is
	// about composite types, and applying it to scalars sent every `long long`
	// return to memory.
	if pos == .RETURN && is_aggregate {
		if r, has := conv.max_by_value_ret.?; has { limit = r }
	}
	// A bare VECTOR wider than one register is SEVERAL, in the vector file.
	//
	// AAPCS32's container for a 128-bit vector is a Q register, and clang
	// splits a 256-bit one across two: `vld1.64 {d0,d1}` then `{d2,d3}`, which
	// is q0:q1. The classifier gave eight INTEGER pieces -- the core-register
	// answer -- because nothing here looked at the VECTOR class.
	//
	// ARGUMENTS only. A 32-byte vector RESULT is memory on this ABI
	// (`max_by_value_ret` is 4), and clang agrees, so the return path is left
	// to the size rule below.
	// A bare VECTOR RESULT wider than one container is MEMORY.
	//
	// `max_by_value_ret` is consulted only for aggregates, and a bare vector is
	// not one, so a 32-byte vector return fell through to the ordinary path and
	// came back as eight INTEGER pieces. AAPCS32 has no container wider than a
	// Q register, and clang agrees: sret.
	if pos == .RETURN && !is_aggregate && len(fields) == 1 &&
	   abi.eff_class(conv, fields[0], pos, shape) == .VECTOR && conv.max_vector_bytes > 0 &&
	   size > conv.max_vector_bytes {
		al := align
		if al < conv.word_size { al = conv.word_size }
		return abi.Sret{align = al}
	}
	if pos == .ARGUMENT && !is_aggregate && len(fields) == 1 &&
	   abi.eff_class(conv, fields[0], pos, shape) == .VECTOR && conv.max_vector_bytes > 0 &&
	   size > conv.max_vector_bytes {
		n := (size + conv.max_vector_bytes - 1) / conv.max_vector_bytes
		if int(n) <= len(buf) {
			for i in 0 ..< n {
				w := size - i * conv.max_vector_bytes
				if w > conv.max_vector_bytes { w = conv.max_vector_bytes }
				buf[i] = abi.make_piece(.VECTOR, i * conv.max_vector_bytes, w)
			}
			return abi.Direct{pieces = buf[:n]}
		}
	}
	if size > limit {
		al := align
		if al < conv.word_size { al = conv.word_size }
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

	// RULE 3: everything else goes in ceil(size/8) general registers.
	//
	// No per-eightbyte merge, and no float/integer split. AArch64 does not ask
	// what is inside a non-homogeneous aggregate -- `struct{i64, f32}` is two X
	// registers, where SysV would give one GPR and one xmm. Porting SysV's merge
	// here would be wrong in a way that only shows at a C boundary.
	// Core-register words, of the target's width. AAPCS32 puts a 40-byte
	// aggregate in ten of them (spilling to the stack once r0-r3 are gone),
	// which is why there is no size cap on this path.
	// No cap. The bound used to be a compile-time MAX_PIECES sized for this
	// very case -- AAPCS32 puts a 40-byte aggregate in ten words -- and
	// clamping there would have silently dropped pieces.
	wd := conv.word_size
	nregs := (size + wd - 1) / wd
	ps := buf[:nregs]
	for i in 0 ..< nregs {
		w := size - i * wd
		if w > wd { w = wd }
		ps[i] = abi.make_piece(.INTEGER, i * wd, w)
	}
	return abi.Direct{pieces = ps}
}

// hfa reports whether the aggregate is homogeneous, and in how many registers.
//
// The leaves are already flattened, so a nested struct and an array of the same
// members answer alike -- which is what AAPCS64 requires and is why `nested` and
// `array` are separate families in the universe.
//
// Same class AND same size is sufficient to mean "the same fundamental type":
// the float widths are distinguished by size, and nothing else is class FLOAT.
// `conv`, `pos` and `shape` are here only so the homogeneity test can ask
// `abi.eff_class` rather than reading `.class` directly: a vector narrower
// than `min_vector_bytes` is not an HVA base, and having the demotion in one
// place is what keeps this test and the eightbyte walk from disagreeing.
hfa :: proc(size: u32, fields: []abi.Field, rule: Maybe(abi.Homogeneous_Rule) = nil,
            conv: ^abi.Convention = nil, pos := abi.Position.ARGUMENT,
            shape := abi.Param_Shape.AGGREGATE) -> (n: int, width: u32, ok: bool) {
	// No cap on the LEAF count -- the cap belongs on the register count, and it
	// is applied below as `count > MAX_HFA`.
	//
	// A union's members overlap, so a homogeneous union of five floats has five
	// leaves and occupies ONE register. Rejecting on leaf count sent it to the
	// integer file -- the wrong register FILE, not merely the wrong register --
	// and did the same to `union{f32, struct{f32 x4}}`, which clang passes in
	// s0-s3. The register count is size/width and the tiling check below
	// already rejects anything that does not fill its slots.
	if len(fields) == 0 {
		return 0, 0, false
	}
	w := fields[0].size
	if w == 0 {
		return 0, 0, false
	}
	// ABSENT means the convention has NO homogeneous aggregates, not "any width
	// goes". Reading it the permissive way meant a soft-float ARM target --
	// which has no FP registers at all -- still formed HFAs, and 63 shapes came
	// out in float registers that do not exist. Absent-as-unrestricted is the
	// same defaulting hazard as a zero-valued enum meaning SCALAR.
	r, has := rule.?
	if !has { return 0, 0, false }
	// The member must also FIT a register of the float file. That check was
	// declared in `Homogeneous_Rule.widths` and read by nothing, so a 32-byte
	// vector was accepted as a one-member HVA where no Q register holds it.
	fits := false
	switch w {
	case 2:  fits = .W2  in r.widths
	case 4:  fits = .W4  in r.widths
	case 8:  fits = .W8  in r.widths
	case 16: fits = .W16 in r.widths
	}
	if !fits { return 0, 0, false }
	// FLOAT or VECTOR: AAPCS64's rule covers Homogeneous Vector Aggregates as
	// well as floating-point ones, and `struct{v4f, v4f}` is measured as
	// `[2 x <4 x float>]` -- two Q registers, exactly like two doubles are two
	// D registers.
	base := abi.eff_class(conv, fields[0], pos, shape)
	if base != .FLOAT && base != .VECTOR { return 0, 0, false }
	for f in fields {
		if abi.eff_class(conv, f, pos, shape) != base || f.size != w {
			return 0, 0, false
		}
	}

	// The register count is size/w, NOT the number of members.
	//
	// A union's members OVERLAP: `union{f32,f32}` is four bytes and is a
	// one-register HFA, while `struct{f32,f32}` is eight bytes and is a
	// two-register one. Identical field lists, different answers, and counting
	// members gets the union wrong in the direction that reads as a defect in
	// the reference compiler rather than in the classifier.
	if size % w != 0 { return 0, 0, false }
	count := int(size / w)
	// Capped on the ROW's own limit, not the package constant.
	//
	// `pieces_needed` derives its buffer bound from `max_members`, and this
	// clamped against MAX_HFA instead -- so a row setting `max_members = 2`
	// made the bound SMALLER than what this writes, and with bounds checking
	// off that is a write past the caller's buffer. No shipped row differs from
	// 4, which is exactly why it had to be found by reading rather than by
	// running.
	// `max_members == 0` means NO homogeneous rule, which is how
	// `pieces_needed` reads it -- it contributes nothing to the bound. Falling
	// back to MAX_HFA here made the two disagree for exactly the value the
	// bound treats as absent: a row that sets `widths` and omits `max_members`
	// got a 2-piece buffer and a 4-piece answer, which is a write past the
	// caller's allocation. The previous version of this cap was the same bug
	// with the constant on the other side.
	cap := int(r.max_members)
	if cap <= 0 { return 0, 0, false }
	if count < 1 || count > cap { return 0, 0, false }

	// The members must TILE the aggregate with no padding. Every slot
	// 0, w, 2w ... must be occupied by one of them.
	//
	// This is what separates `struct{f32,f32}` from `struct #align(16){f32,f32}`:
	// same two fields, but the second is 16 bytes, so slots 8 and 12 are padding
	// and it is not homogeneous. Checking `size == len(fields)*w` used to cover
	// this and stopped working the moment unions became real.
	for i in 0 ..< count {
		want := u32(i) * w
		found := false
		for f in fields {
			if f.offset == want { found = true; break }
		}
		if !found { return 0, 0, false }
	}
	return count, w, true
}

// ---------------------------------------------------------------------------
// Convention rows
//
// Registers come from `core:rexcode/isa/arm64`. It names X0..X30 but not the
// D-view of the vector file, so those are built from its own REG_D class
// constant rather than from a number invented here.

A64_X := [?]u16{
	u16(arm64.X0), u16(arm64.X1), u16(arm64.X2), u16(arm64.X3),
	u16(arm64.X4), u16(arm64.X5), u16(arm64.X6), u16(arm64.X7),
}
A64_RET_X := [?]u16{u16(arm64.X0), u16(arm64.X1)}
A64_RET_D := [?]u16{
	u16(arm64.REG_D | 0), u16(arm64.REG_D | 1), u16(arm64.REG_D | 2), u16(arm64.REG_D | 3),
}

A64_D := [?]u16{
	u16(arm64.REG_D | 0), u16(arm64.REG_D | 1), u16(arm64.REG_D | 2), u16(arm64.REG_D | 3),
	u16(arm64.REG_D | 4), u16(arm64.REG_D | 5), u16(arm64.REG_D | 6), u16(arm64.REG_D | 7),
}

// The SAME eight physical registers, in their other two views.
//
// v0-v7 are one file with three spellings, and which spelling a piece gets is
// decided by the piece's WIDTH -- exactly as AAPCS32 already does with
// s0-s15 / d0-d7 / q0-q3. AAPCS64 had only the D view, so every float piece was
// named `dN` whatever its width: a 4-byte HFA member came out d0 where it is
// s0, and a 16-byte `long double` came out d0 where it is q0. The second is the
// damaging one -- a consumer emitting a 16-byte store from `d0` writes half the
// value -- and the row's own comment already said "an HFA of four floats
// returns in s0-s3" while pointing at the D table.
//
// The placement was never wrong. Only the name was, which is why no
// register-ALLOCATION test could see it.
A64_S := [?]u16{
	u16(arm64.REG_S | 0), u16(arm64.REG_S | 1), u16(arm64.REG_S | 2), u16(arm64.REG_S | 3),
	u16(arm64.REG_S | 4), u16(arm64.REG_S | 5), u16(arm64.REG_S | 6), u16(arm64.REG_S | 7),
}
A64_Q := [?]u16{
	u16(arm64.REG_Q | 0), u16(arm64.REG_Q | 1), u16(arm64.REG_Q | 2), u16(arm64.REG_Q | 3),
	u16(arm64.REG_Q | 4), u16(arm64.REG_Q | 5), u16(arm64.REG_Q | 6), u16(arm64.REG_Q | 7),
}
A64_RET_S := [?]u16{
	u16(arm64.REG_S | 0), u16(arm64.REG_S | 1), u16(arm64.REG_S | 2), u16(arm64.REG_S | 3),
}
A64_RET_Q := [?]u16{
	u16(arm64.REG_Q | 0), u16(arm64.REG_Q | 1), u16(arm64.REG_Q | 2), u16(arm64.REG_Q | 3),
}

@(private) AAPCS64_BASE := abi.Convention{
	id = .AAPCS64,
	// A vector under one eightbyte is INTEGER here -- EXCEPT as a bare result.
	// Measured: `void a(v4i8 x, int t)` leaves `t` in w1, so the vector took
	// x0; `struct{v4i8} r(void)` is `ldr w0`; and `v4i8 r(void)` is `ldr s0`.
	// The same four bytes, three positions, two register files.
	min_vector_bytes = 8,
	bare_vector_return_keeps_file = true,
	name         = "aapcs64",
	varargs      = .SAME_AS_NAMED,
	// AAPCS64 §6.9: the address of an indirectly-returned result travels in x8,
	// which is NOT an argument register -- the declared arguments still start at
	// x0. Measured on both clang and Odin: `BIG f(long,long)` emits
	// `mov x8, sp` alongside `mov w0, #11` / `mov w1, #22`, where x86-64 emits
	// `leaq 8(%rsp), %rdi` and pushes its arguments to rsi and rdx.
	sret_reg     = u16(arm64.X8),
	multi_return = .TUPLE_ELSE_POINTERS,
	spill_retires_files = true, // §5.4.2: NGRN/NSRN are set to 8 on a spill
	// §5.4.2 C.10: a 16-byte-aligned argument rounds NGRN up to an even
	// register. C.14: the NSAA is rounded to the same. Both keyed on NATURAL
	// alignment -- see `natural_align` in signature.odin.
	int_pair_alignment  = true,
	// AAPCS64 C.10 rounds a 16-aligned argument to an even NGRN; nothing on
	// this row is more aligned than that.
	int_pair_align_max  = 16,
	stack_arg_align_max = 16,

	int_regs     = A64_X[:],
	// Narrow, wide and quad views of the SAME file; `assign` picks by width.
	float_regs        = A64_S[:],
	float_regs_wide   = A64_D[:],
	float_regs_quad   = A64_Q[:],
	ret_int_regs      = A64_RET_X[:],
	ret_float_regs      = A64_RET_S[:], // an HFA of four floats returns in s0-s3
	ret_float_regs_wide = A64_RET_D[:],
	ret_float_regs_quad = A64_RET_Q[:],
	word_size    = 8,
	// `float_size` is RISC-V's FLEN and is LEFT UNSET here.
	//
	// It read 8 on this row and had exactly one reader in the package --
	// `riscv64/classify.odin`, where FLEN decides whether a float member fits
	// an f-register. Setting it to 999 on all five non-RISC-V rows changes no
	// answer anywhere: 1900 sequencing predictions and five sweeps stay
	// identical. A number no mutation can falsify is the thing this project
	// keeps finding, and on AAPCS32 the 8 was arguably wrong as well -- its
	// registers are 4-byte s-regs with an 8-byte d view, so "FLEN" names
	// nothing there.
	max_by_value = 16,
	over_max     = .INDIRECT,
	homogeneous  = abi.Homogeneous_Rule{max_members = MAX_HFA, widths = {.W2, .W4, .W8, .W16}},
	stack_align  = 8,
	// A note, not a field. AArch64 Linux tags a register-passed HOMOGENEOUS
	// aggregate with `alignstack(N)` where N is the aggregate's own alignment
	// -- 8 for a 4-float HFA, 16 for a 2-vector HVA -- and Darwin tags nothing.
	// A non-homogeneous aggregate gets no attribute on either. See the deleted
	// `align_stack` in abi.odin for why this is recorded here rather than
	// carried: it constrains where LLVM may place a spilled copy, and this
	// package's answer is a register or a stack offset.
	//
	// It is NOT the only difference between the two rows -- `stack_align` is,
	// and Darwin sets 1 -- which is what the previous wording claimed.
}

// The rows, as PROCEDURES over private RAW rows. See the long note in
// `x86_64/classify.odin`: an exported `:=` row is process-wide mutable state,
// and composing rows in an `@(init)` makes that block responsible for its own
// ordering. Composing on demand answers both, and `compose` is `contextless`
// and allocation-free.

aapcs64      :: proc "contextless" () -> abi.Convention { return abi.compose(AAPCS64_BASE, abi.lang_c())    }
// The Odin convention on THIS platform, which could not exist while a
// convention was one flat row: there was a single `ODIN` and it was x86-64's,
// so the sweep's Odin column had to be switched off everywhere else. Composing
// a language delta onto a platform is what makes it a one-liner.
aapcs64_odin :: proc "contextless" () -> abi.Convention { return abi.compose(AAPCS64_BASE, abi.lang_odin()) }

darwin       :: proc "contextless" () -> abi.Convention { return abi.compose(DARWIN_BASE,  abi.lang_c())    }
// Odin on Darwin. Its probes cannot be EXECUTED here -- a Mach-O binary needs
// macOS -- but `-build-mode:llvm-ir` needs neither a linker nor a Mac, and the
// sweep has always read this target's second oracle that way. Without the row
// the "which convention does the classifier implement?" question was never put
// on 1147 Darwin rows, for want of a convention rather than for want of a
// runner.
darwin_odin  :: proc "contextless" () -> abi.Convention { return abi.compose(DARWIN_BASE,  abi.lang_odin()) }

@(private) DARWIN_BASE := abi.Convention{
	id = .DARWIN_ARM64,
	// A vector under one eightbyte is INTEGER here -- EXCEPT as a bare result.
	// Measured: `void a(v4i8 x, int t)` leaves `t` in w1, so the vector took
	// x0; `struct{v4i8} r(void)` is `ldr w0`; and `v4i8 r(void)` is `ldr s0`.
	// The same four bytes, three positions, two register files.
	min_vector_bytes = 8,
	bare_vector_return_keeps_file = true,
	name         = "darwin_aapcs64",
	varargs      = .ALL_STACK,
	sret_reg     = u16(arm64.X8), // as AAPCS64; measured on aarch64-apple-darwin
	spill_retires_files = true,
	// FALSE here, and AAPCS64 has it TRUE. Measured, with a value returned from
	// a call so nothing can be folded:
	//
	//   q(1, mk(), 3)      an __int128 from a call, then an int
	//     aarch64-linux    x2:x3 holds the i128, w4 holds the 3   C.10 applies
	//     arm64-darwin     x1:x2 holds the i128, w3 holds the 3   it does NOT
	//
	// A 16-aligned STRUCT is x1:x2 on BOTH rows, which is the control that keeps
	// this about C.10 rather than about alignment in general: AAPCS64 allocates
	// a composite to consecutive registers with no even requirement, and the
	// two agree there. So the divergence is Darwin's and is confined to a
	// FUNDAMENTAL 16-aligned type.
	//
	// It read `true` -- inherited from AAPCS64 -- and nothing could say
	// otherwise: the sweep compares CLASSES and this is a register NUMBER, and
	// `--assign`, which would catch it, needs a runner Darwin does not have.
	// Found by building the asm read that makes the field falsifiable, which is
	// the whole argument for insisting every row value have one.
	int_pair_alignment  = false,
	// The cap still applies to a COMPOSITE, which does take pair alignment on
	// this row; only the C.10 rule above is absent.
	int_pair_align_max  = 16,
	stack_arg_align_max = 16,
	// MEASURED, not inherited. This was left SINGLE under the reasoning that
	// "a Mach-O binary cannot be run here, so Darwin's protocol has never been
	// measured" -- true about EXECUTION and false about the protocol, which is
	// visible in the signature and needs no runner at all:
	//
	//     darwin_arm64   two()   [2 x i64] @two(ptr context)
	//                    three() i64 @three(ptr, ptr, ptr context)
	//     linux_arm64    byte-for-byte identical
	//
	// A two-value return comes back as a tuple in registers and a three-value
	// one takes a trailing pointer per earlier result, which is exactly
	// TUPLE_ELSE_POINTERS. `-build-mode:llvm-ir` needs neither a linker nor
	// macOS, and the sweep has always used it for this target's second oracle;
	// the refusal was costing a real capability for a reason that did not hold.
	multi_return = .TUPLE_ELSE_POINTERS,
	int_regs     = A64_X[:],
	// Narrow, wide and quad views of the SAME file; `assign` picks by width.
	float_regs        = A64_S[:],
	float_regs_wide   = A64_D[:],
	float_regs_quad   = A64_Q[:],
	ret_int_regs      = A64_RET_X[:],
	ret_float_regs      = A64_RET_S[:], // an HFA of four floats returns in s0-s3
	ret_float_regs_wide = A64_RET_D[:],
	ret_float_regs_quad = A64_RET_Q[:],
	word_size    = 8,
	max_by_value = 16,
	over_max     = .INDIRECT,
	homogeneous  = abi.Homogeneous_Rule{max_members = MAX_HFA, widths = {.W2, .W4, .W8, .W16}},
	// ONE, not eight: Darwin packs named stack arguments at their natural
	// alignment rather than giving each a word. Measured -- four arguments
	// (char, char, short, int) land at sp+0, +1, +2, +4 and clang writes all
	// four with a single 8-byte store, where aarch64-linux uses four stores at
	// +0, +8, +16, +24.
	stack_align  = 1,
}

// ---------------------------------------------------------------------------
// Typed seams

reg :: proc(p: abi.Piece) -> arm64.Register { return arm64.Register(p.reg) }

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
               allocator := context.temp_allocator, n_fixed := -1) -> (abi.Call_Layout, bool) {
	return abi.classify_signature(classify, params, results, conv, allocator, n_fixed)
}
