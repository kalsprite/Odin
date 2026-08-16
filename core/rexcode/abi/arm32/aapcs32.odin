package abi_arm32

import abi "core:rexcode/abi"
import arm32 "core:rexcode/isa/arm32"

// AAPCS32 is a Convention ROW over the AArch64 classifier, and it lives in its
// own package for one reason: its registers belong to `isa/arm32`, not
// `isa/arm64`. Sharing the classifier across packages while keeping each row
// beside the ISA it names is the shape the layering is supposed to have --
// `abi/aarch64` exports `classify`, this package supplies the table.

// AAPCS32, hard-float. The same HFA-then-words shape as AAPCS64 over a
// four-byte word, so it is a ROW rather than a fourth classifier -- the second
// time that claim has paid, after riscv32.
//
// Two things it does NOT share: arguments are never passed indirectly at any
// size, and returns go through `sret` above four bytes.
A32_R := [?]u16{u16(arm32.R0), u16(arm32.R1), u16(arm32.R2), u16(arm32.R3)}
A32_D := [?]u16{
	u16(arm32.REG_DPR | 0), u16(arm32.REG_DPR | 1), u16(arm32.REG_DPR | 2), u16(arm32.REG_DPR | 3),
	u16(arm32.REG_DPR | 4), u16(arm32.REG_DPR | 5), u16(arm32.REG_DPR | 6), u16(arm32.REG_DPR | 7),
}
A32_Q := [?]u16{
	u16(arm32.REG_QPR | 0), u16(arm32.REG_QPR | 1),
	u16(arm32.REG_QPR | 2), u16(arm32.REG_QPR | 3),
}
A32_S := [?]u16{
	u16(arm32.REG_SPR |  0), u16(arm32.REG_SPR |  1), u16(arm32.REG_SPR |  2), u16(arm32.REG_SPR |  3),
	u16(arm32.REG_SPR |  4), u16(arm32.REG_SPR |  5), u16(arm32.REG_SPR |  6), u16(arm32.REG_SPR |  7),
	u16(arm32.REG_SPR |  8), u16(arm32.REG_SPR |  9), u16(arm32.REG_SPR | 10), u16(arm32.REG_SPR | 11),
	u16(arm32.REG_SPR | 12), u16(arm32.REG_SPR | 13), u16(arm32.REG_SPR | 14), u16(arm32.REG_SPR | 15),
}

@(private) AAPCS32_BASE := abi.Convention{
	id = .AAPCS32,
	name             = "aapcs32",
	// The only target that packs the tuple UNCONDITIONALLY: a result tuple too
	// wide for r0 comes back through an sret pointer as a whole, where AArch64
	// and RISC-V would split it into hidden pointers. Measured: `-> (i64, i64)`
	// is `void f(ptr sret({i64,i64}), ptr context)`.
	multi_return     = .TUPLE_ALWAYS,
	// Variadic arguments use the BASE standard even on a hard-float target:
	// `v(1, 2.5)` is `vmov r2, r3, d16` on gnueabihf -- the double moved into
	// CORE registers. Modelled as SAME_AS_NAMED, it predicted VFP.
	varargs          = .INT_REGS,
	int_regs         = A32_R[:],
	ret_int_regs     = A32_R[:], // r0-r3
	// The return file in all THREE views, chosen by piece width -- the same
	// fix AAPCS64 needed and the same reason. Naming a `double` result from the
	// S view is not a cosmetic slip: `s1` is the UPPER HALF of `d0`, so a
	// two-double HFA returned as "s0, s1" reads its second value out of the
	// middle of its first. Measured: `struct{double,double}` comes back in
	// d0:d1 (`vadd.f64 d0, d0, d16`).
	//
	// The ARGUMENT side was already right because it goes through the
	// `float_slot_size` mask path; only the return side fell back to narrow.
	ret_float_regs      = A32_S[:], // s0-s3 for a 4-float HFA
	ret_float_regs_wide = A32_D[:], // d0-d3 for a double or a double HFA
	ret_float_regs_quad = A32_Q[:], // q0-q3 for a 16-byte vector
	// SIXTEEN single-precision registers, s0-s15. They alias d0-d7, so a
	// double consumes two adjacent slots -- a fact this model does not yet
	// express, and the reason the sequencing probe passes f32 here. Named
	// rather than left implicit.
	float_regs       = A32_S[:],       // s0-s15, one slot each
	float_regs_wide  = A32_D[:],       // d0-d7, two slots each
	float_regs_quad  = A32_Q[:],       // q0-q3, four slots each
	float_slot_size  = 4,
	word_size        = 4,
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
	max_by_value     = 1 << 20, // effectively none: measured to 40 bytes and beyond
	max_by_value_ret = u32(4),
	over_max         = .STACK_COPY,
	// W16 too: AAPCS32 has Homogeneous VECTOR Aggregates in Q registers, and
	// `struct{v4f, v4f}` is measured as two of them. Omitting W16 sent every
	// 16-byte vector to the core registers instead.
	// NO `.W2`, and that is measured rather than inherited. AAPCS64 lists it;
	// this row must not, and the two really do differ:
	//
	//   armv7-hf   _Float16              clang SSE    a bare half IS VFP-passed
	//              struct{f16}           clang INT    but a struct of halves is
	//              struct{f16,f16}       clang INT    NOT a homogeneous
	//              struct{f16,f16,f16}   clang INT,INT   float aggregate
	//   aarch64    all four              HFA of halves throughout
	//
	// Adding `.W2` here to fix the BARE case turned all twelve aggregate rows
	// red in the other direction, which is how the distinction was found. A
	// half is a VFP CPRC on this row only as a scalar; it is not a container
	// type for the homogeneous rule.
	homogeneous      = abi.Homogeneous_Rule{max_members = 4, widths = {.W4, .W8, .W16}},
	stack_align      = 4,
	// Measured: `v(int, int, double, int, double)` on armv7 emits
	// `str r0, [sp]` then `strd r0, r1, [sp, #8]` -- the trailing double at
	// sp+8, with sp+4 padding.
	// B.5 caps a VECTOR too, which is why there is no separate
	// `vector_stack_align_max` on this row. Measured on armv7-hf, `ga(8
	// doubles, 5 ints, v4f, int)`: `str r0,[r1],#8` before the vector, so the
	// slot is 8 and not the type's own 16. A row that restated the same number
	// in the vector field could not be falsified -- zeroing it would change no
	// answer -- so the fallback carries it.
	stack_arg_align_max = 8,
	// A Q register is the container for a 128-bit vector; a 256-bit one takes
	// two. Hard-float only -- the soft-float EABI has no VFP calling
	// convention and passes vectors in core registers, which is measured and
	// is why that row leaves this at zero.
	max_vector_bytes = 16,
	// Same shape as AAPCS64: a sub-eightbyte vector is INTEGER as an argument
	// and as a wrapped result, and stays in the VFP file as a bare result --
	// EXCEPT when its elements are floating-point, which is what
	// `narrow_float_vector_returns_int` below carries.
	//
	// THE EARLIER NOTE HERE WAS WRONG and is worth recording rather than
	// quietly replacing. It said `bv4_f16` came back in r0 because a vector of
	// _Float16 is "not a supported NEON type on baseline armv7", i.e. an ISA
	// level artefact, and declined to model it on that basis. The claim does
	// not survive measurement: `-mfpu=neon-fp16`, `-mfpu=neon-vfpv4` and
	// `-march=armv8-a+fp16` ALL still give `ldr r0`, and f16 vectors are
	// perfectly VFP-eligible at other sizes --
	//
	//     v2f16  (4)   ldr r0                  CORE
	//     v4f16  (8)   vldr                    VFP
	//     v8f16  (16)  vld1.64                 VFP
	//     v4i8   (4)   vld1.32 + vmovl.u8      VFP
	//     v2i16  (4)   vld1.32 + vmovl.u16     VFP
	//
	// -- so it is neither the element type alone nor the size alone. There is
	// no 32-bit NEON container, so clang synthesises one by WIDENING, which
	// works for integer elements and has no float equivalent.
	//
	// Modelled anyway. The origin is a codegen limitation, but a caller has to
	// read r0 regardless of why, and it is stable across every ISA level
	// tried. That is the difference from the one-element-vector case this
	// package declines, where clang contradicts ITSELF at the same size and
	// element count.
	min_vector_bytes = 8,
	bare_vector_return_keeps_file = true,
	narrow_float_vector_returns_int = true,
	splits_aggregates = true,
	spill_retires_files = true, // AAPCS §5.5 C.2.cp: the files are marked unavailable
	int_pair_alignment = true,
	// AAPCS32 §6.1.2 B.5: a copy is 4-aligned if its natural alignment is <= 4
	// and 8-aligned if it is >= 8 -- never more. Without this a 16-aligned
	// argument rounded the NCRN up by four and a 32-aligned one by eight, on a
	// FOUR-register file.
	int_pair_align_max = 8,
}


// ---------------------------------------------------------------------------
// Typed seam. The CLASSIFIER lives in abi/aarch64 -- AAPCS32 is a row over it --
// but the registers are this ISA's, which is why this package exists.

reg :: proc(p: abi.Piece) -> arm32.Register { return arm32.Register(p.reg) }

// The rows, as PROCEDURES over a private RAW row. See the long note in
// `x86_64/classify.odin`: an exported `:=` row is process-wide mutable state,
// and composing rows in an `@(init)` makes that block responsible for its own
// ordering.
//
// This package is where that ordering hurt most. The block below used to be TWO
// `@(init)` procedures, and the soft-float one copied `AAPCS32` -- so it
// silently depended on the composing one having run first, which Odin does not
// guarantee. Merging them into one made the dependency a sequence of statements
// instead of a hope; deriving the soft row inside a PURE function removes the
// dependency altogether, because there is no longer a mutation to be ordered
// against.

aapcs32           :: proc "contextless" () -> abi.Convention { return abi.compose(AAPCS32_BASE,      abi.lang_c())    }
aapcs32_odin      :: proc "contextless" () -> abi.Convention { return abi.compose(AAPCS32_BASE,      abi.lang_odin()) }
aapcs32_soft      :: proc "contextless" () -> abi.Convention { return abi.compose(aapcs32_soft_base(), abi.lang_c())    }
// Odin's OWN arm32 ABI... except that it is NOT. `odin build -target:linux_arm32`
// emits `arm-unknown-linux-gnueabihf` with `.fpu vfpv2`, so the row an Odin
// caller on ARM actually uses is `aapcs32_odin`, the HARD-float one. This row is
// Odin over the soft EABI: correct for a freestanding target built that way, and
// not what Odin's own Linux target does.
//
// The old comment here claimed the opposite and the harness believed it, pairing
// hard-float Odin against soft-float clang in six places and filing a SIGSEGV
// that was entirely self-inflicted.
aapcs32_soft_odin :: proc "contextless" () -> abi.Convention { return abi.compose(aapcs32_soft_base(), abi.lang_odin()) }

// AAPCS32 SOFT-FLOAT (the base EABI), which is what most freestanding ARM
// targets use.
//
// The claim under test: a soft-float ABI needs no new machinery, only an EMPTY
// float file plus the fallback that already exists for RISC-V. Measured --
//
//     armv7-linux-gnueabihf   f(float,float)  ->  vmov.f32 s0, s1
//     armv7-linux-gnueabi     f(float,float)  ->  mov r0, r1
//
// so a float travels in a core register, which is exactly what
// `float_spills_to_int` does when there are no float registers left. Here there
// are none to begin with.
//
// This is also the shape a MICROCONTROLLER takes: no FPU is not a new kind of
// convention, it is a register file with nothing in it.
@(private)
aapcs32_soft_base :: proc "contextless" () -> abi.Convention {
	// Derived from the RAW platform row, before any language composes onto it.
	soft := AAPCS32_BASE
	soft.id = .AAPCS32_SOFT
	soft.name                = "aapcs32-soft"
	soft.float_regs          = {}
	soft.float_regs_wide     = {}
	soft.float_regs_quad     = {}
	soft.float_slot_size     = 0
	soft.homogeneous         = nil // no FP file, so no homogeneous FP aggregate
	// ALL THREE return views, and the vector width. Only the narrow view was
	// cleared, so this row carried `ret_float_regs_wide = d0-d3`,
	// `ret_float_regs_quad = q0-q3` and `max_vector_bytes = 16` on a target with
	// no VFP at all -- contradicting the sentence forty lines above that says
	// the soft row "leaves this at zero".
	//
	// CHECKED BEFORE CHANGING, and the checking is the point: none of the three
	// was reachable. A row with an empty float file reclassifies every FLOAT and
	// VECTOR piece as INTEGER before any view is consulted, so the predictions
	// were already right --
	//
	//     float  r0     double  r0:r1     <4 x float>  r0-r3
	//
	// argument and return alike, matching armv7-linux-gnueabi. So this is
	// HYGIENE, not a fix, and is recorded as such. It is still worth doing: the
	// standing rule here is that a field set and never read is untrustworthy,
	// and three fields holding wrong values with no reader are one dead branch
	// away from being read.
	soft.ret_float_regs      = {}
	soft.ret_float_regs_wide = {}
	soft.ret_float_regs_quad = {}
	soft.max_vector_bytes    = 0
	soft.float_spills_to_int = true
	return soft
}
