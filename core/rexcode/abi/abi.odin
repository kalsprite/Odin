package rexcode_abi

// The architecture-independent ABI vocabulary.
//
// Destined for `core:rexcode/abi`, alongside the ten ISAs already in
// `core:rexcode/isa`. Those are OS-independent by nature -- an x86 encoder is
// the same on Linux and Windows -- which is why ten of them exist and no
// calling convention does. This package is where the vendor-os half of a target
// triple lives.
//
// Every form below was MEASURED, not chosen. `oracle --survey` asks clang the
// same ~1,100 typed questions for five triples and reports the distinct answer
// shapes; the union is what appears here, and nothing that was not observed is
// designed for. Counts in the comments are argument positions from that run:
//
//   x86_64-linux-gnu  x86_64-windows-msvc  aarch64-linux-gnu
//   aarch64-apple-darwin  riscv64-linux-gnu
//
// Re-run it before extending this file. A vocabulary is a claim about what
// exists, and that claim goes stale.

// Reg_Class is which register FILE a piece travels in, not which register.
//
// Deliberately not "INTEGER | SSE": SSE is x86's name. AArch64's is the FP/SIMD
// file and RISC-V's is `f`, and calling the concept SSE is how an x86 accident
// becomes a cross-architecture interface.
Reg_Class :: enum u8 {
	NONE,
	INTEGER, // GPR file
	FLOAT,   // scalar float register (x86 xmm, AArch64 Sn/Dn, RISC-V fN)
	VECTOR,  // a PACKED vector occupying one register: `<2 x float>`, `<2 x i64>`
	X87,     // x86 80-bit stack register; no equivalent elsewhere
}

// Piece is one register's worth of an argument.
//
// `width` exists because the eightbyte does not generalize. SysV always splits
// into 8-byte pieces, so a fixed `[2]Class` is enough for it -- but AAPCS64
// passes `struct{f32 x 4}` as FOUR 4-byte pieces in four S registers, and no
// eightbyte model can say that. Measured: 980 argument positions across the
// three targets that have homogeneous aggregates.
//
// `offset` is the byte offset within the aggregate this piece carries, which is
// what a lowering pass needs to emit the load or store. SysV can recompute it
// as `index * 8`; AAPCS64 cannot.
// Field order is chosen for SIZE, not for reading. Declared class-first this was
// 16 bytes, which made `Direct` 260 and `Location` 264 -- returned by value from
// both classify and assign, twice per argument, in a compiler's hot path.
// Packing it to 8 halves the layout.
Piece :: struct {
	offset: u32,       // byte offset within the aggregate this piece carries
	reg:    u16,       // filled by assign; use the arch's reg_* accessor to read
	class:  Reg_Class, // which register FILE
	flags:  Piece_Flags,
}

Piece_Flag :: enum u8 {
	// The piece is a FLOAT that was placed in an INTEGER register because the
	// float file was exhausted (RISC-V). The class still says what the value
	// is; this says where it ended up, and a lowering needs both.
	Borrowed,
	// The piece has NO register: nothing in the convention can name a value of
	// this width. A consumer must treat the location as unusable rather than
	// reading `reg`, which is 0 and is not a valid register on any of these
	// ISAs.
	Unplaced,
	// A variadic FLOAT that is ALSO present in the integer register of the
	// same slot (Win64), because the callee has no prototype to know which
	// file to read.
	Also_Integer,
	// Width, in bytes, minus one -- encoded rather than stored, because a
	// separate u8 costs four bytes of padding and the widths in play are 1..16.
	W_BIT0, W_BIT1, W_BIT2, W_BIT3, W_BIT4,
}

Piece_Flags :: bit_set[Piece_Flag; u8]

// eff_class is a field's class AFTER the narrow-vector rule -- the one place
// that rule is implemented.
//
// Every classifier reads a field's class in several spots (the eightbyte merge,
// the homogeneous-aggregate base, the bare-vector branch), and applying a
// demotion at some of them and not others is an inconsistency the sweep would
// show and a reader would not. So the rule lives here and the read sites call
// this instead of touching `.class`.
//
// `pos` and `shape` are both load-bearing: on AAPCS64 a 4-byte vector is
// INTEGER as an argument and VECTOR as a BARE result, and INTEGER as a wrapped
// result. See `Convention.bare_vector_return_keeps_file`.
eff_class :: proc(conv: ^Convention, f: Field, pos: Position, shape: Param_Shape) -> Reg_Class {
	if conv == nil || f.class != .VECTOR { return f.class }
	if conv.min_vector_bytes == 0 || f.size >= conv.min_vector_bytes { return f.class }
	if pos == .RETURN && shape == .SCALAR && conv.bare_vector_return_keeps_file {
		if conv.narrow_float_vector_returns_int && f.vec_is_float { return .INTEGER }
		return .VECTOR
	}
	return .INTEGER
}

piece_width :: proc(p: Piece) -> u8 {
	w := u8(0)
	if .W_BIT0 in p.flags { w |= 1 }
	if .W_BIT1 in p.flags { w |= 2 }
	if .W_BIT2 in p.flags { w |= 4 }
	if .W_BIT3 in p.flags { w |= 8 }
	if .W_BIT4 in p.flags { w |= 16 }
	return w + 1
}

// The widest piece the five-bit encoding can hold.
MAX_PIECE_WIDTH :: 32

// piece_width_ok is the bound, as a QUESTION a caller can ask.
//
// The bound used to exist only as an `assert` inside the setter, and this
// project's own note two screens up says an assertion the consumer can compile
// out with `-disable-assert` is not a bound. Worse, the assert could not see
// the value that mattered: every call site wrote `u8(size)`, so a 300-byte
// scalar arrived as 44 and passed, and a 256-byte one arrived as 0.
//
// A classifier that cannot represent a width REFUSES -- `Location`'s nil is
// already how a classifier declines -- rather than encoding a wrong number.
piece_width_ok :: proc "contextless" (w: u32) -> bool {
	return w >= 1 && w <= MAX_PIECE_WIDTH
}

piece_set_width :: proc(p: ^Piece, w: u32) {
	// The width lives in five flag bits, so only 1..32 round-trip. `w = 0`
	// underflowed to 255 and read back as 32; `w > 32` wrapped modulo 32, so a
	// 33-byte piece silently became a 1-byte one. Both were reachable -- the
	// x87 return path computed `u8(size - EIGHTBYTE)` before any size check.
	//
	// The parameter is u32 so the TRUNCATION cannot happen at the call site
	// before this ever runs. The assert stays as a development backstop; the
	// clamp below is what holds in a build without it, and it clamps to the
	// bound rather than wrapping, so a wrong answer is at least a bounded one
	// and `Unplaced` marks it.
	assert(w >= 1 && w <= MAX_PIECE_WIDTH, "piece width must be 1..32; the encoding has five bits")
	if w < 1 || w > MAX_PIECE_WIDTH {
		p.flags += {.Unplaced}
		p.flags -= {.W_BIT0, .W_BIT1, .W_BIT2, .W_BIT3, .W_BIT4}
		p.flags += {.W_BIT0, .W_BIT1, .W_BIT2, .W_BIT3, .W_BIT4} // = 32
		return
	}
	v := u8(w) - 1
	p.flags -= {.W_BIT0, .W_BIT1, .W_BIT2, .W_BIT3, .W_BIT4}
	if v & 1  != 0 { p.flags += {.W_BIT0} }
	if v & 2  != 0 { p.flags += {.W_BIT1} }
	if v & 4  != 0 { p.flags += {.W_BIT2} }
	if v & 8  != 0 { p.flags += {.W_BIT3} }
	if v & 16 != 0 { p.flags += {.W_BIT4} }
}

// make_piece is the constructor to use; it keeps the width encoding in one
// place rather than at every site that builds a piece.
make_piece :: proc(class: Reg_Class, offset: u32, width: u32) -> (p: Piece) {
	p.class = class
	p.offset = offset
	piece_set_width(&p, width)
	return
}

// pieces_needed is the worst-case piece count for a type of this size under
// this convention -- the bound a caller sizes a scratch buffer with.
//
// There is deliberately no MAX_PIECES constant any more. A compile-time bound
// would have to cover every target the compiler can EMIT for, not the one it
// runs on, so it could never shrink for a single-target build; and sized for
// the worst case it cost every target. AAPCS32 sets that worst case at ten
// four-byte words for a 40-byte aggregate, which made `Direct` 132 bytes.
//
// A runtime bound threaded from the convention is both smaller and honest.
pieces_needed :: proc(conv: ^Convention, size: u32) -> int {
	// A zero-valued Convention is not a convention. Without this the division
	// below is a SIGFPE with no message -- `Convention` has no valid zero, and
	// unlike `Param_Shape` nothing said so.
	// A bad convention returns the FLOOR, not zero.
	//
	// Returning 0 handed every classifier a zero-length buffer that it then
	// wrote into -- a heap corruption two hundred lines from the actual mistake.
	// The floor keeps the buffer valid; `classify_signature` refuses the nil
	// convention up front, which is where the error belongs and where it can
	// carry a reason.
	if conv == nil || conv.word_size == 0 { return 2 }
	n := int((size + conv.word_size - 1) / conv.word_size)
	// A homogeneous aggregate can hold more pieces than words when the member
	// is narrower than a word -- four S-registers for a 16-byte AAPCS64 HFA.
	if h, has := conv.homogeneous.?; has && int(h.max_members) > n {
		n = int(h.max_members)
	}
	// Floor of two, because a piece count is not always bounded by the word
	// count: RISC-V's float-plus-integer rule turns an EIGHT-byte
	// `struct{i8, f32}` into two pieces, (a0, fa0), on a target whose word is
	// also eight bytes. Sizing from `size` alone under-allocated it.
	//
	// Over-allocating is harmless -- every classifier trims to what it
	// produced -- and under-allocating is a bounds fault, so the asymmetry
	// says which way to err.
	return max(n, 2)
}

// Location is how one argument or result travels. The four cases are the four
// observed kinds, and they are genuinely distinct mechanisms -- collapsing
// Indirect into Stack is the bug `mir_design.md:1373` records as a segfault.
Location :: union {
	Direct,
	Indirect,
	Stack,
	Sret,
}

// Direct: in registers, as a sequence of pieces.
// Covers INT, FLOAT, MIXED, VECTOR, X87 and homogeneous aggregates alike --
// they differ in the pieces, not in the mechanism.
Direct :: struct {
	// Borrowed, never owned. `classify` writes into a buffer the CALLER
	// supplies and returns a sub-slice of it; it allocates nothing.
	// `classify_signature` carves every argument's pieces out of ONE block, so
	// a whole call layout costs one allocation rather than one per argument.
	//
	// Size a buffer with `pieces_needed`. Slicing instead of inlining a
	// worst-case array took `Direct` from 132 bytes to 24.
	pieces: []Piece,
	// How many leading pieces are in REGISTERS. The rest, if any, sit on the
	// stack at `stack_offset` and follow contiguously one word apart.
	//
	// `n_reg == count` is the ordinary all-register case. A smaller value means
	// the argument was SPLIT, which AAPCS32 does and nothing else surveyed
	// does: a 24-byte struct after two integer arguments puts two words in
	// r2-r3 and the remaining four on the stack. Measured --
	//
	//     f(int, int, S24 s) { return s.f; }   ->   ldr r0, [sp, #12]
	//
	// s.f is word 5; reading it at sp+12 means words 2..5 are on the stack and
	// 0..1 are not. There is no way to say that with an all-or-nothing
	// Location, so a model without this field cannot describe AAPCS32 at all.
	n_reg:        u8,
	stack_offset: u32,
	// The OBJECT's size in bytes -- NOT the sum of the piece widths.
	//
	// Padding is represented by absence, which is what makes classification
	// right: `struct #align(16){i8,i8}` is sixteen bytes whose second eightbyte
	// is pure padding, and SysV does not pass a NO_CLASS eightbyte at all, so
	// the pieces come to eight. Every consumer that needs a FOOTPRINT -- how
	// much stack to reserve, how many bytes to copy -- needs the other number,
	// and summing the pieces silently gives the wrong one.
	//
	// It lives here so a `Location` answers the question by itself. The
	// alternative is a consumer keeping `params[i].size` in step with
	// `layout.args[i]` and remembering which of the two to use, which is the
	// kind of bookkeeping an ABI layer exists to remove.
	//
	// Stamped by `classify_signature` for every Location it produces. A
	// hand-built call that uses `classify` directly gets 0, and `assign` then
	// falls back to the piece sum -- exact whenever the pieces tile the object,
	// which is every shape but a trailing-padding one.
	size:         u32,
}

// `direct_count` was here, and is DELETED: no callers, and `len(d.pieces)` is
// shorter than the call would have been.

// Indirect: a POINTER to a copy the caller owns.
//
// The dominant form: 2502 argument positions, against 627 for Stack. Every
// target surveyed except x86-64 SysV uses it for large aggregates, and it is
// also what Odin's own convention does on x86-64. `dead_on_return` in clang's
// IR -- the callee must not write through it.
Indirect :: struct {
	align: u32,
	// Where the POINTER travels.
	//
	// An indirect argument still consumes an argument slot: the pointer has to
	// go somewhere. `assign` used to return Indirect untouched, consuming
	// nothing, so on Win64 -- where a 16-byte struct is indirect -- every
	// argument after one shifted by a register. Found by the first sequencing
	// case that put a scalar after an aggregate.
	reg:    u16,
	in_reg: bool,
	offset: u32, // when the pointer itself is on the stack
	// The size of the COPY the caller owns. Same reason as `Direct.size`: the
	// callee is handed a pointer, and somebody has to allocate and fill the
	// thing it points at.
	size:   u32,
}

// Stack: a COPY in the caller's outgoing argument area.
//
// SysV's MEMORY class, and x86-64 SysV is the only surveyed target that uses
// it. Distinct from Indirect: the bytes are in the outgoing area rather than
// behind a pointer, so the callee addresses them off the frame.
Stack :: struct {
	size:   u32,
	align:  u32,
	// Byte offset within the caller's outgoing argument area, filled by
	// `assign`. Absent in the first draft, which recorded the size and
	// alignment of a stack argument but not WHERE it went -- enough to say an
	// argument was on the stack and not enough to emit the store. The
	// sequencing instrument could not be written against it, which is how the
	// omission surfaced.
	offset: u32,
	// Whether `align` must survive the convention's over-alignment CAP.
	//
	// i386 is the only row that caps, and it caps to model a real rule: the
	// outgoing slot is a four-byte slot and an over-aligned STRUCT does not
	// widen it. A bare VECTOR does. Measured, one compile, both shapes:
	//
	//   g(v4f,v4f,v4f, int, v4f, int)     movaps %xmm3, 16(%esp)   vector @ 16
	//   h(int, struct #align(16), int)    movups %xmm0,  4(%esp)   struct  @ 4
	//
	// `movaps` against `movups` is clang saying the same thing twice: the
	// vector slot is aligned and the struct slot is not.
	//
	// The CLASSIFIER knows the class and the assigner does not -- a `Stack`
	// carries no pieces -- so the fact travels here rather than being
	// re-derived. What the flag then BUYS is the convention's business --
	// `vector_stack_align_max` -- because the answer is not the same
	// everywhere. Measured, all three at a shifted offset so a cap is visible:
	//
	//   i386     g(v4f x3, int, v4f, int)              vector @ esp+16   natural
	//   x86-64   g(v8f x8, 6 longs, int, v8f, int)     vector @ rsp+32   natural
	//   armv7-hf ga(8 doubles, 5 ints, v4f, int)       str r0,[r1],#8    CAPPED at 8
	//
	// so a flag that meant "keep the natural alignment" outright would be
	// right on two rows and wrong on the third.
	is_vector: bool,
}

// Sret: returned through a hidden pointer, passed as an argument.
// Universal -- 3126 return positions, present on all five targets.
Sret :: struct {
	align: u32,
}

// ---------------------------------------------------------------------------
// Conventions

// Over_Max is what happens to an aggregate too large for registers. This single
// field is the entire difference between `proc "c"` and `odin` on x86-64.
Over_Max :: enum u8 {
	STACK_COPY, // x86-64 SysV
	INDIRECT,   // AAPCS64, Darwin, RISC-V, Win64, and Odin's own convention
}

// Homogeneous_Rule describes AAPCS64's HFA/HVA: up to N members of identical
// float type go in N registers of the float file rather than being packed into
// integer-sized pieces. Absent on x86-64 and Win64.
Homogeneous_Rule :: struct {
	max_members: u8, // 4 under AAPCS64
	widths:      bit_set[Float_Width],
}

Float_Width :: enum u8 { W2, W4, W8, W16 }

// Implicit_Arg is a parameter the language adds that the source does not name.
//
// Odin appends `^Context` LAST -- after the return pointers, established by
// disassembly (mir_design.md:447, :474) and now checkable in bulk: the survey's
// sibling mode confirms 890/890 `odin` procedures carry one and 0/890 `proc "c"`
// procedures do.
Implicit_Arg :: struct {
	name:     string,
	class:    Reg_Class,
	position: enum u8 { FIRST, LAST },
}

// Convention is a ROW, keyed on (arch, os, convention name).
//
// Win64 and SysV share the entire x86 ISA and differ only here: 4 argument
// registers against 6, and 848 of 1093 surveyed types indirect against 627
// stack-copied. Two rows, one ISA, one classifier family.
// Assign_Mode is how argument positions map to register slots.
//
// A fourth model, and the one that broke the assumption that two independent
// counters is universal. Measured: Win64 compiling `f(double, long long,
// double)` puts the third argument in xmm2, not xmm1 -- the slot index is the
// ARGUMENT position, and an integer argument consumes the float slot beside it.
Assign_Mode :: enum u8 {
	INDEPENDENT, // SysV, AAPCS64, RISC-V: the two files count separately
	POSITIONAL,  // Win64: argument N takes slot N in whichever file it needs
}

// KNOWN LIMIT: every row is a package-level `var` and the whole API takes
// `^Convention`, so `c := &x64.SYSV; c.max_by_value = 1` mutates the shared
// table for every later call, and two threads laying out two functions share it.
// A compiler is the obvious place for that to matter.
//
// Not fixed here because the fix is an API change -- accessors returning copies,
// or `#no_copy` plus per-target snapshots -- and the composed rows are built by
// `@(init)` precisely so they can be shared. Recorded so it is a decision rather
// than an oversight; the instrument's own mutation controls rely on COPYING a
// row before perturbing it, which is the pattern a consumer should follow too.
Convention :: struct {
	// Diagnostics only -- see `tprint_name` for why this is not an identity.
	name:         string,
	assign_mode:  Assign_Mode,
	int_regs:     []u16,  // in assignment order; isa Register values
	float_regs:   []u16,
	// The RETURN register files, which are not the argument ones. x86-64
	// returns in RAX:RDX and XMM0:XMM1, not RDI:RSI and XMM0..7.
	//
	// Absent at first, so `classify_signature` computed a result's CLASSES and
	// left every `reg` zero -- handing back the easy half of the return path
	// and keeping the error-prone half with the caller. That is on record as a
	// real consumer defect: per-eightbyte classification on the argument path,
	// size-based on the return path, `struct{f64,f64}` coming back in RAX:RDX,
	// and 950 differential cases blind to it because both sides agreed.
	// Whether a FLOATING-POINT result comes back on the x87 stack.
	//
	// True on 32-bit x86 and nowhere else: i386 returns both `float` and
	// `double` in ST0. Measured -- clang emits `flds (%esp)` before `retl` for
	// a float-returning function.
	//
	// A row FACT, not something to derive. "No float return file implies x87"
	// is false: a soft-float ARM or RISC-V row also has no float return file
	// and returns a float in an INTEGER register. Only 32-bit x86 uses the x87
	// stack, so only its row says so.
	// The widest VECTOR that travels in one register, in bytes.
	//
	// A TARGET property, not an optimiser choice, because it changes the
	// CONTRACT and the callee across the link was compiled at some fixed level.
	// Measured on x86-64 with the same source:
	//
	//     baseline   declare void @a8(ptr noundef byval(<8 x float>))   stack
	//     -mavx      declare void @a8(<8 x float> noundef)              ymm0
	//
	// So 16 baseline, 32 with AVX, 64 with AVX-512. Only the WIDTH varies:
	// AVX-512 adds zmm16-31 but those are not argument registers, so the COUNT
	// never changes and a single number says everything the ABI rule keys on.
	//
	// It deliberately does NOT name a register. xmm0 / ymm0 / zmm0 are one
	// physical register at three widths -- the same shape as AAPCS64's
	// s0/d0/q0 -- so the classifier emits a vector piece of width N and
	// `float_view` picks the spelling. A backend cannot get the name wrong and
	// needs no feature knowledge at that step.
	//
	// Zero means "this convention has no vector registers", which is different
	// from 16: i386 needs `vector_regs` to say where they are.
	max_vector_bytes: u32,
	// The NARROWEST vector still carried in the vector file. Below this a
	// vector is classified as the integer of its size.
	//
	// `max_vector_bytes` has bounded the top since this file was written; the
	// bottom went unqualified because the corpus held nothing under 8 bytes.
	// Adding 4-byte rows disagreed with clang on six rows at once. Measured
	// from the ASSEMBLY, because the IR is not the classification:
	//
	//     x86-64   void a(v4i8 x, int t)   t in %esi -> x took %edi   INTEGER
	//              v4i8 r(void)            movl g, %eax               INTEGER
	//     aarch64  void a(v4i8 x, int t)   t in w1   -> x took x0     INTEGER
	//              struct{v4i8} r(void)    ldr w0                     INTEGER
	//
	// Zero -- the default -- keeps every vector vector-classed, so a convention
	// nobody has measured is not handed a threshold it was never checked for.
	min_vector_bytes: u32,
	// The widest COMPLEX returned in the integer return registers rather than
	// through a hidden pointer. Zero -- the default -- means this convention
	// has no such rule and a complex is placed like any other aggregate.
	//
	// i386 alone, and a BYTE COUNT rather than a boolean because the rule has
	// a bound and the measurement says where it is:
	//
	//     _Complex float   (8)   movl gcf,%eax / movl gcf+4,%edx   eax:edx
	//     _Complex int     (8)   movl gci,%eax / movl gci+4,%edx   eax:edx
	//     _Complex short   (4)   movl gcs,%eax                     eax
	//     _Complex double  (16)  movl 4(%esp),%eax / ... retl $4   SRET
	//
	// Upstream reached the same bound independently -- Odin's commit for this
	// reads "return a complex of eight bytes or fewer in EAX:EDX".
	//
	// It needs `Param_Flags.IS_COMPLEX`, because a struct of two floats of the
	// same size is byte-for-byte identical and goes to SRET at every width.
	complex_ret_int_max: u32,
	// Whether a BARE vector's RETURN stays in the vector file even below
	// `min_vector_bytes`. This is the axis that makes the rule more than a
	// byte count, and it is not a tidy-up: on AAPCS64 the same 4-byte vector
	// is INTEGER as an argument and in `s0` as a bare result, while a struct
	// wrapping it is INTEGER in both positions.
	//
	//     aarch64  v4i8 r(void)          ldr s0        VECTOR
	//              struct{v4i8} r(void)  ldr w0        INTEGER
	//     x86-64   v4i8 r(void)          movl %eax     INTEGER -- no exception
	//
	// False on SysV, true on AAPCS64/Darwin/AAPCS32-hard.
	bare_vector_return_keeps_file: bool,
	// ... EXCEPT when the vector's elements are floating-point.
	//
	// AAPCS32 only, and measured rather than reasoned. A bare 4-byte vector
	// returns in the VFP file for integer elements and in a CORE register for
	// halves:
	//
	//     v4i8  (4)   vld1.32 {d16[0]} ; vmovl.u8  q0     VFP
	//     v2i16 (4)   vld1.32 {d16[0]} ; vmovl.u16 q0     VFP
	//     v2f16 (4)   ldr r0, [r0]                        CORE
	//     v4f16 (8)   vldr                                VFP  <- 8 bytes is fine
	//     v8f16 (16)  vld1.64                             VFP
	//
	// So it is not the element type alone and not the size alone: it is the
	// 4-byte case with float elements. There is no 32-bit NEON container, so
	// clang synthesises one by WIDENING (`vmovl`) -- which works for integer
	// elements and has no float equivalent, leaving a core register.
	//
	// Modelled rather than declined even though its origin is a codegen
	// limitation: a caller genuinely has to read r0 here, it is reproducible,
	// and it does NOT move with the ISA level -- `-mfpu=neon-fp16`,
	// `-mfpu=neon-vfpv4` and `-march=armv8-a+fp16` all still give `ldr r0`.
	// That is what separates it from the one-element-vector case this package
	// declines, where clang contradicts ITSELF at the same size and count.
	narrow_float_vector_returns_int: bool,
	// Where a VECTOR-class piece goes, when that is not the float file.
	//
	// Empty on every convention but one, and falls back to `float_regs`. i386
	// is the exception and needs its own: a bare `float` argument goes on the
	// STACK there while a bare `__m128` goes in xmm0, so floats and vectors use
	// different files and sharing one would put every float in xmm0.
	vector_regs: []u16,
	// Where a VECTOR-class RESULT comes back, when that is not the float
	// return file. Measured rather than derived, because it coincides with
	// neither neighbour:
	//
	//   i386   `ret_float_regs` is EMPTY (scalar floats return in st0) and a
	//          vector still returns in xmm0.
	//   Win64  `ret_float_regs` is xmm0 alone, and a 32-byte vector returns in
	//          xmm0:xmm1.
	//
	// Empty falls back to `ret_float_regs`, which is right wherever the two
	// files coincide.
	ret_vector_regs: []u16,
	float_returns_x87: bool,
	ret_int_regs:   []u16,
	// The return float file, in up to three VIEWS of the same registers -- the
	// same idea as `float_regs_wide`/`float_regs_quad` on the argument side, and
	// for the same reason: on AArch64 v0-v7 are one file spelled s/d/q, and
	// which spelling a piece takes is decided by its WIDTH.
	//
	// Empty means "this convention has one view", which is true of x86-64 and
	// RISC-V; `float_view` falls back to `ret_float_regs` then.
	ret_float_regs:      []u16,
	ret_float_regs_wide: []u16,
	ret_float_regs_quad: []u16,
	// The DEDICATED indirect-result register, where the platform has one.
	//
	// AAPCS64 §6.9 passes the address of a memory-class result in x8, and x8 is
	// NOT an argument register: the declared arguments still begin at x0. Every
	// other convention here passes that address as a hidden FIRST argument,
	// which does consume the first integer slot and does push every declared
	// argument along one.
	//
	// A Maybe rather than a register number with a sentinel, because the two
	// behaviours differ in what they CONSUME and not merely in which register
	// gets named. Modelling x8 as "argument register zero" would have produced
	// the right name for the pointer and the wrong register for every argument
	// after it.
	//
	// Absent until an Odin caller was first run on AArch64. The type sweep
	// cannot see it -- it asks what CLASS a result is, and both models agree
	// that a 24-byte struct is memory -- and `--multi` was x86-64 only, where
	// the hidden-first-argument model happens to be correct. Verified now by
	// `--multi --arch=aarch64`, whose `sret_arg2` case exists precisely to tell
	// the two models apart.
	sret_reg:       Maybe(u16),
	// Must the CALLEE remove the hidden result pointer from the stack before
	// returning -- `ret $4` rather than `ret`?
	//
	// i386 System V requires it ("the called function must remove this address
	// from the stack before returning"); every other convention here leaves
	// argument cleanup entirely to the caller. It is the one piece of the
	// calling sequence that is neither a register nor an offset, and omitting it
	// does not misplace a value -- it corrupts the stack pointer, so the CALLER
	// crashes some time after a correct-looking return.
	//
	// Found by running the multi-value probe on i386: every placement was right
	// and the process still died with SIGSEGV.
	sret_callee_pops: bool,
	// Register widths. Present so one classifier serves a 64- and a 32-bit
	// variant of the same ABI: RISC-V's LP64D and ILP32D differ in these two
	// numbers and nothing else, which is the row model's strongest claim and
	// is tested rather than asserted.
	word_size:    u32,        // XLEN in bytes
	// FLEN in bytes -- RISC-V's, and RISC-V's ONLY. `riscv64/classify.odin` is
	// the single reader, where it decides whether a float member fits an
	// f-register.
	//
	// Left 0 on the other five rows. It read 8 on all of them and setting it to
	// 999 changed no answer anywhere -- 1900 sequencing predictions and five
	// sweeps identical -- so it was a number no mutation could falsify. On
	// AAPCS32 the 8 was arguably wrong as well: those are 4-byte s-registers
	// with an 8-byte d view, and "FLEN" names nothing there.
	float_size:   u32,
	max_by_value: u32,
	// The by-value limit in RETURN position, when it differs. AAPCS32 never
	// passes an argument indirectly -- a 40-byte struct still goes in core
	// registers and stack -- but returns anything over four bytes through
	// `sret`. One limit could not say both.
	//
	// A Maybe, not a 0 sentinel. Review found this package using three
	// different spellings of "absent" -- a 0 here, a documented-but-nonexistent
	// 0 on `float_size`, and a proper Maybe on `homogeneous`. The Maybe is the
	// right one and now the only one.
	max_by_value_ret: Maybe(u32),
	over_max:     Over_Max,
	homogeneous:  Maybe(Homogeneous_Rule),
	implicit:     []Implicit_Arg,
	stack_align:  u32,
	// The largest alignment a STACKED argument is given, or 0 for "a stack slot
	// and nothing more".
	//
	// The two behaviours are both real and they differ on targets that
	// otherwise look alike. AAPCS32 puts a stacked 64-bit argument on an 8-byte
	// boundary even though its slot is 4, so `v(int, int, double, int, double)`
	// on armv7 leaves sp+4 as padding and lands the trailing double at sp+8.
	// i386 cdecl does no such thing: every argument is pushed at 4, `double`
	// included, and giving it natural alignment moved a `float` argument that
	// clang had placed at 4.
	//
	// Left 0 wherever it has not been MEASURED -- x86-64 does align an
	// over-aligned stacked argument, but no case in this corpus stacks one, and
	// a number nothing exercises is the failure mode this package keeps finding.
	stack_arg_align_max: u32,
	// Whether a BARE VECTOR needing more vector registers than remain is SPLIT
	// -- what fits in the file, the rest on the stack -- rather than spilled
	// whole.
	//
	// A field rather than `len(vector_regs) > 0`, so the rule can be turned off
	// and the probe must notice: `--mutate=no-vec-split` clears it and i386 goes
	// red on `vec_wide_split`. Deliberately NOT `splits_aggregates`, which is
	// about aggregates and carries AAPCS32's "NSAA equals SP" precondition; a
	// bare vector is not an aggregate and i386 splits with the stack already in
	// use. Measured on cdecl across six register-pressure configurations.
	splits_vectors: bool,
	// The same cap for a BARE VECTOR, which several rows align differently from
	// an ordinary over-aligned argument. 0 means "no separate rule": fall back
	// to `stack_arg_align_max`.
	//
	// i386 is why the field exists. `stack_arg_align_max = 0` there is correct
	// and measured -- an `aligned(16)` struct really does go at esp+4 -- but a
	// `__m128` in the same position goes at esp+16, which the i386 psABI states
	// separately (§2.2.3: "__m128 ... are 16-byte aligned"). One field could not
	// say both. AAPCS32 is the other end: its B.5 marshalling cap of 8 applies
	// to vectors too, measured as `str r0,[r1],#8` before a stacked `v4f`, so
	// this row is 8 rather than natural.
	vector_stack_align_max: u32,
	// Bytes the CALLER reserves above the return address before the first
	// stack argument. Win64 requires 32 ("home space") whether or not the
	// callee uses it; SysV has none. Measured: with six integer arguments,
	// Win64 reads the fifth at 40(%rsp) -- 8 for the return address plus 32 --
	// where SysV passes all six in registers and touches the stack not at all.
	//
	// Distinct from `red_zone`, which is space BELOW rsp that a leaf function
	// may use without adjusting it. SysV has 128 bytes of that and Win64 none,
	// so the two conventions differ in both directions.
	shadow_space: u32,
	// AAPCS32's float file is SIXTEEN single-precision registers that alias
	// eight double ones: d1 IS s2:s3. So a `double` consumes two adjacent
	// slots, must start on an even one, and a later `float` BACKFILLS the slot
	// the alignment skipped. Measured:
	//
	//     f(float a, double b, float c) -> a=s0, b=d1(s2:s3), c=s1
	//
	// `float_used` as a counter cannot say that, so a convention with a slot
	// size narrower than its widest float allocates from a free-slot MASK
	// instead. `float_regs` names the one-slot view (s0-s15) and
	// `float_regs_wide` the two-slot view (d0-d7); a piece is named from
	// whichever it occupies, so `reg` stays a real register rather than an
	// index meaning different things per convention.
	float_slot_size: u32, // 0 = one slot per register, the counter model
	float_regs_wide: []u16, // two slots each: AAPCS32's d0-d7
	float_regs_quad: []u16, // four slots each: AAPCS32's q0-q3
	// May a single aggregate be split between registers and the stack?
	//
	// AAPCS32 does; SysV, AAPCS64, RISC-V and Win64 all refuse, sending the
	// whole argument to memory instead. Getting this wrong in the permissive
	// direction is the failure mode where the first half of a struct arrives
	// and the second does not, so it is opt-IN.
	// The platform's multi-value return protocol, zeroed to SINGLE by `compose`
	// for a language that has none. Platform-supplied, exactly like `varargs`
	// below and for the same measured reason -- see `Multi_Return`.
	multi_return: Multi_Return,
	// The platform's varargs rule, zeroed by `compose` for a language that has
	// no varargs.
	varargs:      Varargs_Kind,
	// Once an argument goes to the STACK, are the register files closed to
	// every argument after it?
	//
	// AAPCS64 §5.4.2 says yes -- NGRN and NSRN are set to 8 -- and SysV says no.
	// Measured, and the two really do differ:
	//
	//   x86-64   f(long x5, struct{long,long,long}, long g)
	//            the struct goes to memory and g still BACKFILLS r9
	//   aarch64  f(long x7, struct{long,long}, long i)
	//            the struct goes to sp+0 and i goes to sp+16, x7 left unused
	//
	// So it cannot be a rule in `assign`; it is a property of the row. Without
	// it every argument after the first spill was predicted one register too
	// early on AAPCS64 and AAPCS32 -- the whole tail of the call.
	//
	// Not observable on RISC-V: an aggregate there either fits, splits, or (over
	// 2*XLEN) goes by reference in a single register, so "spilled whole with
	// registers still free" is a state that cannot be reached. Left false there
	// rather than guessed.
	spill_retires_files: bool,
	// Must an argument whose ALIGNMENT exceeds one word start on an even
	// register? AAPCS32 says yes for core registers, and does NOT backfill the
	// register it skipped -- the opposite of its VFP file, which does.
	//
	// Driven by alignment, not size, and measured both ways:
	//   f(int, long long, int)      -> a=r0, b=r2:r3, c=STACK   (align 8)
	//   f(int, struct{int,int}, int)-> a=r0, b=r1:r2, c=r3      (align 4)
	int_pair_alignment: bool,
	// The widest alignment the register-pair round-up honours, in BYTES.
	//
	// AAPCS32 caps the marshalling alignment of a copy at 8 (§6.1.2 B.5), so a
	// 16- or 32-aligned argument still only rounds the NCRN up to an EVEN
	// register. AAPCS64's C.10 rounds a 16-aligned argument to an even NGRN and
	// nothing is more aligned than that there, so the two rows differ and the
	// value is per-row rather than derived.
	//
	// Zero means "no cap": the type's own alignment is used, bounded only by
	// the register file. Left zero on every row that does not round up at all.
	int_pair_align_max: u32,
	splits_aggregates: bool,
	// When the float file is exhausted, do floats take INTEGER registers before
	// the stack? RISC-V does; SysV and AAPCS64 spill straight to the stack.
	//
	// Measured, and by the sequencing probe rather than by reading: eleven
	// consecutive doubles on riscv64 put the ninth in a0 (`fmv.d.x fa0, a0`),
	// not on the stack. Nothing in the type sweep can see this -- it only
	// appears once a file has been exhausted, and every type probe passes one
	// argument.
	float_spills_to_int: bool,
	red_zone:     u32,
	// `align_stack` was here and is DELETED -- but NOT for the reason first
	// recorded here, which was itself a bad measurement and is corrected below.
	//
	// The claim it was deleted on was "clang 22 emits no `alignstack` attribute
	// on either target". That is false, and re-measuring says so plainly:
	//
	//   aarch64-linux-gnu     declare void @f1([4 x float] alignstack(8))
	//                         declare void @f2([2 x <4 x float>] alignstack(16))
	//                         declare void @f3([2 x i64])          <- nothing
	//   arm64-apple-darwin    no attribute on any of the three
	//
	// So the ORIGINAL comment was right: Linux tags a register-passed aggregate
	// and Darwin does not. What emits nothing on both is a NON-homogeneous
	// aggregate -- which is evidently what got measured, and the conclusion was
	// then generalised from it. A field deleted on a false measurement is the
	// same error as a field kept on an unverified one.
	//
	// It stays deleted on the honest ground: `alignstack` constrains where LLVM
	// may place a spilled copy, and this package's answer is a register or a
	// stack OFFSET. Nothing a consumer of `Location` does depends on it, and the
	// old `u32` could not have expressed it anyway -- the value tracks the
	// aggregate's own alignment (8 here, 16 there), not the constant 8 the field
	// held. If a backend ever needs it, it is a per-argument fact derived from
	// the type, not a row constant.
	//
	// The real Linux/Darwin difference in ARGUMENT PLACEMENT is separate and is
	// modelled: Darwin packs named stack arguments at their natural alignment
	// where Linux gives each a word. That is `stack_align`, which is read.
}

// ---------------------------------------------------------------------------
// Assignment

// Assign_State is the register-counter machine every ABI turns out to be, once
// classification is separated from it. SysV counts INTEGER and SSE
// independently; AAPCS64 calls the same two counters NGRN and NSRN.
//
// This is shared. Only `classify` is per-arch.
// The width of `Assign_State.float_mask`, named so the bound and the field
// cannot drift apart.
FLOAT_MASK_BITS :: 32

Assign_State :: struct {
	int_used:   u32,
	float_used: u32,
	// Free-slot mask for an aliasing float file; bit i set means slot i is
	// taken. Only used when `float_slot_size` says the slots alias.
	// One bit per SLOT of an aliasing float file. `FLOAT_MASK_BITS` is its
	// width, and the takers refuse a file wider than that rather than shifting
	// past the end.
	float_mask: u32,
	// The separate VECTOR file's counter, where a convention has one.
	vec_used:   u32,
	slot:       u32, // POSITIONAL mode: one slot per argument, either file
	stack_off:  u32,
	// Whether ANYTHING has been placed on the stack yet -- AAPCS32's
	// `NSAA == SP`, and the gate on splitting an aggregate between the core
	// registers and the stack (AAPCS §6.5.5 C.8).
	//
	// Not `stack_off > 0`: Win64 seeds `stack_off` to the shadow space, which
	// is reserved and not written by any argument, and a zero-size stack
	// argument advances nothing. The question is "has an argument gone to
	// memory", so that is what is recorded.
	stack_used: bool,
}

// assign_begin seeds the state for one call's argument list.
//
// Required rather than optional: a zero-initialised Assign_State puts Win64's
// first stack argument at the return address instead of 32 bytes above it. The
// shadow space belongs to the sequence, not to any one argument, so it has to
// be established before the first assign rather than added by each.
// slot_align is the granularity of the outgoing argument area.
//
// It was `max(stack_align, word_size)`, which is a no-op on eight of the nine
// rows -- every one sets `stack_align` equal to its word -- and actively wrong
// on the ninth. Darwin AArch64 PACKS named stack arguments at their natural
// alignment where Linux gives each a full 8-byte slot:
//
//   h(int x8, char a, char b, short c, int d)
//     aarch64-linux   strb w10,[sp]  strb w8,[sp,#8]  strh w9,[sp,#16]  str w8,[sp,#24]
//     aarch64-darwin  a@0  b@1  c@2  d@4          -- one 8-byte store for all four
//
// The floor made that inexpressible: a row could not ask for a slot smaller
// than a word. With it gone, `stack_align` means what it says and Darwin sets 1.
slot_align :: proc(conv: ^Convention) -> u32 {
	if conv.stack_align > 0 { return conv.stack_align }
	return conv.word_size
}

// The alignment of ONE stacked argument's slot: the type's own alignment,
// capped by the row's rule, floored at the row's slot.
//
// Both ways an argument reaches the stack -- classified MEMORY and spilled from
// a full register file -- go through here, because they are the same object and
// they had drifted apart. `is_vector` selects which cap applies; see
// `Convention.vector_stack_align_max`.
stack_slot_align :: proc(conv: ^Convention, align: u32, is_vector := false) -> u32 {
	if conv == nil { return align }
	floor := slot_align(conv)
	cap := conv.stack_arg_align_max
	if is_vector && conv.vector_stack_align_max > 0 { cap = conv.vector_stack_align_max }
	// 0 means "a stack slot and nothing more" -- i386 cdecl for an aggregate.
	if cap == 0 { return floor }
	return max(min(align, cap), floor)
}

assign_begin :: proc(conv: ^Convention) -> Assign_State {
	// A nil convention has no shadow space and no anything else.
	// `classify_signature` refuses it up front, which is where the error
	// belongs and where it can carry a reason -- but these three are PUBLIC,
	// and a caller driving classify+assign itself reaches them directly. A nil
	// deref two hundred lines from the mistake is what `pieces_needed`'s own
	// guard exists to prevent, and it was the only one of the four that had it.
	if conv == nil { return Assign_State{} }
	return Assign_State{stack_off = conv.shadow_space}
}

// assign_result places a value-returned result in the RETURN register files.
//
// Separate from `assign` because returns do not share the argument counters and
// never spill: a result that does not fit was already turned into `Sret` by
// classify, and the pointer for it is what consumes an argument slot.
assign_result :: proc(loc: ^Location, conv: ^Convention) {
	if conv == nil { return } // see assign_begin
	d, is_direct := loc.(Direct)
	if !is_direct { return }
	ints, flts := u32(0), u32(0)
	// Count what was actually PLACED, not what was asked for.
	placed := 0
	for i in 0 ..< len(d.pieces) {
		switch d.pieces[i].class {
		case .INTEGER:
			if int(ints) < len(conv.ret_int_regs) {
				d.pieces[i].reg = conv.ret_int_regs[ints]
				ints += 1
				placed += 1
			}
		case .FLOAT, .VECTOR:
			// A VECTOR result uses the vector return file where the row has a
			// separate one. This read was missing: `ret_vector_regs` was added
			// for exactly this case and then consulted only for a `len()` inside
			// the classifiers, so i386 (whose `ret_float_regs` is empty, scalar
			// floats returning in st0) and Win64 (one entry, but a 32-byte
			// vector needs two) both fell through `placed < len(pieces)` and
			// were rewritten to Sret. The caller then passes a hidden pointer to
			// a callee that returns in xmm and never writes it.
			tbl := float_view(conv.ret_float_regs, conv.ret_float_regs_wide,
				conv.ret_float_regs_quad, piece_width(d.pieces[i]))
			if d.pieces[i].class == .VECTOR && len(conv.ret_vector_regs) > 0 {
				tbl = conv.ret_vector_regs
			}
			if int(flts) < len(tbl) {
				d.pieces[i].reg = tbl[flts]
				flts += 1
				placed += 1
			}
		case .X87, .NONE:
			// x87 comes back in st0, which this model has no register for. The
			// CLASS is the answer; there is no register to name.
			placed += 1
		}
	}
	// `n_reg` used to be `len(d.pieces)` unconditionally -- so a piece the loop
	// above declined to place, because the return file was empty or exhausted,
	// was still counted as being in a register, with `reg` left at 0. Zero is
	// not a valid register on any of these ISAs (x86.RAX is REG_GPR64|0, i.e.
	// 0x100), so the layout claimed N registers and named none of them.
	//
	// Measured through the shipped API: an i386 `f32` return gave n_reg = 1 with
	// reg = 0, on a row whose float return file is deliberately empty, and the
	// comment there claimed "an unset file is visibly unset". It was not.
	//
	// Nothing reads `n_reg` on the result today, which is why the false claim
	// survived; `placed < len(pieces)` is now the honest signal, and it uses the
	// meaning `n_reg` already has on the argument path.
	// A result that does not FIT is not a half-placed Direct.
	//
	// `Direct`'s contract is that pieces past `n_reg` sit on the stack at
	// `stack_offset` -- and a RETURN has no outgoing stack area, so that
	// sentence has no meaning here and `stack_offset` stays 0. A 24-byte
	// INTEGER result under SysV therefore came back as three pieces with
	// n_reg = 2, the third naming register 0, and ok = true: an answer that
	// cannot be executed, presented as one that can.
	//
	// The mechanism for a result that does not fit the return registers already
	// exists and is `Sret`. Classification normally produces it from the size
	// rule; this is the backstop for a piece list that got past that -- an
	// inconsistent convention, or a caller assembling a Location by hand.
	if placed < len(d.pieces) {
		al := u32(0)
		for i in 0 ..< len(d.pieces) { al = max(al, u32(piece_width(d.pieces[i]))) }
		if al == 0 { al = conv.word_size }
		loc^ = Sret{align = al}
		return
	}
	d.n_reg = u8(min(placed, 255))
	loc^ = d
}

// take_float_slots reserves `n` adjacent, n-aligned float slots and returns the
// first index. Alignment and backfill are the whole point: a two-slot value
// must start even, and the odd slot it skipped stays available for a one-slot
// value that comes later.
// take_float_block reserves ONE run of `count` consecutive slots, starting at a
// multiple of `align`.
//
// The two numbers are different, and conflating them is AAPCS §6.1.2.1 C.1.cp
// got wrong: a VFP co-processor register candidate occupies CONSECUTIVE
// registers, and the first must be aligned for the ELEMENT type -- not for the
// whole run. Measured on clang armv7-hf:
//
//     f(float, struct{4 x float})    s0 used -> the HFA takes s1,s2,s3,s4
//     f(float, struct{2 x double})   s0 used -> the HFA takes d1,d2 (s2..s5)
//
// The 4-float HFA starts at an ODD index, so the run is not 4-aligned; the
// 2-double HFA starts at an even one, because a `d` register is. `align` is
// therefore the per-element slot count and `count` is the sum.
//
// `take_float_slots` is this with count == align, which is right for a single
// piece and is why it was never wrong until a multi-piece CPRC was allocated
// one piece at a time.
// float_view picks the register spelling that matches a piece's WIDTH.
//
// A convention whose float file has one view leaves `wide` and `quad` empty and
// always gets `narrow` back, which is what x86-64 and RISC-V want. AArch64 fills
// all three: v0-v7 spelled s, d or q. Naming a 16-byte piece from the D view is
// not a placement error -- the register is right -- but a consumer emitting a
// 16-byte store from `d0` writes eight bytes and drops the rest.
float_view :: proc(narrow, wide, quad: []u16, width: u8) -> []u16 {
	if width > 8 && len(quad) > 0 { return quad }
	if width > 4 && len(wide) > 0 { return wide }
	return narrow
}

take_float_block :: proc(conv: ^Convention, st: ^Assign_State, count, align: u32) -> (u32, bool) {
	total := u32(len(conv.float_regs))
	if count == 0 || align == 0 { return 0, false }
	// The mask is a fixed-width bitset, so a file wider than it cannot be
	// tracked. `1 << i` for i >= 32 is undefined-ish and would silently alias
	// slot i-32, handing out a register already in use. AAPCS32's sixteen
	// s-registers are the only aliasing file today, so this cannot fire now --
	// which is exactly why it needs saying: the next such convention would get
	// a wrong answer rather than a refusal.
	if total > FLOAT_MASK_BITS { return 0, false }
	for i := u32(0); i + count <= total; i += align {
		free := true
		for k in 0 ..< count {
			if st.float_mask & (1 << (i + k)) != 0 { free = false; break }
		}
		if free {
			for k in 0 ..< count { st.float_mask |= 1 << (i + k) }
			return i, true
		}
	}
	return 0, false
}

// `take_float_slots` was here, and is DELETED rather than kept for symmetry.
//
// It was `take_float_block` with `count == align`, which is the right rule for a
// single value and the wrong one for a run: AAPCS §6.1.2.1 C.1.cp wants
// consecutive registers aligned to the MEMBER, not to the run length, and
// getting that wrong is what let a four-float CPRC straddle a hole. Nothing has
// called it since `take_float_block` replaced it.
//
// Deleted on this project's own standing rule -- a declared thing nobody
// consumes has been wrong eight times out of eight -- and a near-duplicate of a
// procedure with subtly different semantics is the worst case of it: the next
// caller picks whichever name reads better.

// float_slots_for is how many slots a piece of this width occupies.
float_slots_for :: proc(conv: ^Convention, width: u8) -> u32 {
	if conv.float_slot_size == 0 { return 1 }
	return (u32(width) + conv.float_slot_size - 1) / conv.float_slot_size
}

// take_int_slot reserves the next integer argument slot, honouring the
// convention's assignment model. Shared by the Indirect path and nothing else
// yet; the Direct path needs the per-piece form below.
take_int_slot :: proc(conv: ^Convention, st: ^Assign_State) -> (int, bool) {
	if conv.assign_mode == .POSITIONAL {
		n := st.slot
		st.slot += 1
		if n < u32(len(conv.int_regs)) { return int(n), true }
		return 0, false
	}
	if st.int_used < u32(len(conv.int_regs)) {
		n := st.int_used
		st.int_used += 1
		return int(n), true
	}
	return 0, false
}

// assign places an already-classified argument, consuming registers in order
// and falling back to the stack when a file is exhausted.
//
// Split from classify deliberately. They are different functions with different
// failure modes -- the x86-64 sweep verified classification over ~1,100 types
// and could not see argument SEQUENCING at all, because every probe procedure
// took exactly one parameter. Keeping them separate is what lets the second one
// get its own instrument rather than being tested incidentally.
// assign places an argument IN PLACE.
//
// A pointer rather than a value-in/value-out pair for two reasons review named:
// `loc = assign(loc, ...)` is easy to misuse by dropping the reassignment, and
// `Location` is large enough that copying it twice per argument is not free in a
// compiler's inner loop.
// `buf` is the argument's OWN piece carve, not just the classified sub-slice.
//
// RISC-V needs it: when the float file cannot take an FP-classified aggregate,
// the aggregate reverts to the integer convention and is re-laid-out as
// ceil(size/XLEN) word-sized pieces -- a count that can EXCEED the classified
// one. `struct{double}` on ILP32D is one 8-byte FP piece and becomes an a0:a1
// pair, and `Direct.pieces` is borrowed, so there is nowhere to grow into
// without it.
//
// `classify_signature` already carves `pieces_needed(conv, size)` per argument
// and `pieces_needed` is already at least ceil(size/word), so the room exists;
// only the LENGTH was short. Passing the carve hands back the room that was
// always reserved. Callers with no carve pass nothing and get the old
// behaviour, which is correct for every convention that does not revert.
assign :: proc(loc: ^Location, conv: ^Convention, st: ^Assign_State, align: u32 = 0, force_pair_align := false, buf: []Piece = nil, is_aggregate := false) {
	// See `assign_begin`. `word_size == 0` too: every alignment and slot
	// computation below divides by it.
	if conv == nil || st == nil || conv.word_size == 0 { return }
	// An INDIRECT argument consumes one integer slot for its pointer.
	if ind, is_ind := loc.(Indirect); is_ind {
		if n, ok := take_int_slot(conv, st); ok {
			ind.in_reg, ind.reg = true, conv.int_regs[n]
			loc^ = ind
			return
		}
		// A POINTER's slot: `word_size` bytes, at a pointer's own alignment.
		//
		// This used `slot_align`, which is the granularity of the outgoing area
		// and NOT the size of the thing being put in it. Once Darwin set
		// `stack_align = 1` -- correct, it packs named arguments at their own
		// alignment -- every stacked pointer got a ONE-BYTE slot: two indirect
		// arguments landed at sp+0 and sp+1, and the next argument at sp+8
		// overlapped the second pointer. Darwin's packing rule is about an
		// argument's own size and alignment, and a pointer is eight bytes there
		// too.
		al := max(slot_align(conv), conv.word_size)
		st.stack_off = (st.stack_off + al - 1) / al * al
		ind.offset = st.stack_off
		st.stack_off += conv.word_size
		st.stack_used = true
		loc^ = ind
		return
	}

	spill_align :: proc(conv: ^Convention) -> u32 {
		return slot_align(conv)
	}

	// A STACK argument -- SysV's MEMORY class, produced by classify rather than
	// by running out of registers -- still needs an OFFSET, and this returned
	// without assigning one. Every such argument sat at offset 0.
	//
	// It survived on x86-64 only by coincidence: in both corpus cases the
	// memory-class aggregate happened to be the first thing on the stack. i386
	// puts two integers there first and the coincidence broke. "What would
	// still pass this case" was: any implementation that ignores the offset.
	if stk, is_stk := loc.(Stack); is_stk {
		// The over-alignment CAP applies here too. This path took the type's
		// alignment unbounded while the Direct-spill path below capped it by
		// `stack_arg_align_max` -- two spill paths in one procedure with two
		// different rules.
		//
		// cdecl is where they visibly part: `stack_arg_align_max = 0` means "a
		// stack slot and nothing more", and clang and gcc both put an
		// `aligned(16)` struct at esp+4 with `byval align 4`. We gave it a
		// 16-aligned slot at esp+16 and pushed the next argument to esp+32.
		al := stack_slot_align(conv, stk.align, stk.is_vector)
		st.stack_off = (st.stack_off + al - 1) / al * al
		stk.offset = st.stack_off
		sz := (stk.size + al - 1) / al * al
		st.stack_off += sz
		// The EFFECTIVE alignment, not the type's. The Location carried the
		// classifier's uncapped `align` while sitting at an offset computed
		// from the capped one, so it described a 32-aligned object at offset
		// 16 -- self-inconsistent, and a consumer laying out a frame from it
		// would disagree with the very offset beside it.
		stk.align = al
		st.stack_used = true
		loc^ = stk
		return
	}

	d, is_direct := loc.(Direct)
	if !is_direct {
		return // Sret consumes caller storage, not an argument slot
	}

	// Retire only the file(s) the spilled argument was competing for.
	//
	// AAPCS64 states the two separately -- C.3 sets NSRN to 8 when an HFA does
	// not fit the FP file, C.12 sets NGRN to 8 when a composite does not fit the
	// integer one -- and closing both together is wrong in the case where one
	// file is exhausted and the other is not. Measured by
	// `flt_exhausted_ints_free`: after the FP file is full, an INTEGER argument
	// still takes x-registers.
	retire :: proc(conv: ^Convention, st: ^Assign_State, want_int, want_flt: bool) {
		if !conv.spill_retires_files { return }
		if want_int {
			st.int_used = u32(len(conv.int_regs))
		}
		if want_flt {
			st.float_used = u32(len(conv.float_regs))
			// The aliasing file is tracked by a mask, so "all used" is every bit.
			if conv.float_slot_size != 0 {
				for i in 0 ..< u32(len(conv.float_regs)) { st.float_mask |= 1 << i }
			}
		}
	}

	spill :: proc(size, al: u32, st: ^Assign_State) -> Stack {
		// Every stack argument occupies a whole number of slots, so rounding
		// the SIZE matters as much as aligning the offset -- without it the
		// second stack argument lands wherever the first happened to end. The
		// slot is a WORD, and a word is not always eight bytes: assuming so
		// made every i386 stack argument consume eight instead of four.
		sz := (size + al - 1) / al * al
		st.stack_off = (st.stack_off + al - 1) / al * al
		out := Stack{size = sz, align = al, offset = st.stack_off}
		st.stack_off += sz
		st.stack_used = true
		return out
	}
	// A stacked argument sits at its OWN alignment, floored at the convention's
	// slot size -- not at the slot size alone.
	//
	// AAPCS32 is where that shows: `stack_align` is 4, but a stacked 64-bit
	// argument is 8-aligned, so `v(int, int, double, int, double)` on armv7 puts
	// the trailing double at sp+8 with sp+4 left as padding. Predicting sp+4 got
	// the low word from padding and the high word from the low half.
	//
	// It went unseen because the varargs probe read only the FIRST piece of a
	// multi-piece argument, and because the sentinel ended `.25` -- whose low 32
	// mantissa bits are all zero, so reading zeroed padding compared EQUAL. Two
	// independent reasons a wrong answer looked right.
	// A BARE VECTOR that runs out of registers is stacked by the same rule as
	// one the classifier sent to memory outright -- the two paths reach the
	// stack differently and the slot is the same object. i386 is where they
	// visibly parted: `memory()` set `is_vector` and the register-spill path
	// did not, so the FOURTH `v4f` of a call (the first to miss xmm0-2) landed
	// at esp+4 where clang puts it at esp+16, and every argument after it was
	// twelve bytes out.
	bare_vec := !is_aggregate && len(d.pieces) > 0
	if bare_vec {
		for i in 0 ..< len(d.pieces) {
			if d.pieces[i].class != .VECTOR { bare_vec = false; break }
		}
	}
	al := stack_slot_align(conv, align, bare_vec)

	if conv.assign_mode == .POSITIONAL {
		// One slot per argument. A multi-piece Direct cannot occur here --
		// Win64 puts anything that does not fit one register behind a pointer.
		n := st.slot
		st.slot += 1
		// Guarded on the file the piece will actually use. The test was
		// `n < len(conv.int_regs)` for BOTH branches, so a positional row with
		// an empty float file indexed `float_regs[n]` out of bounds. Win64
		// survives only because its two files happen to be the same length.
		// The length check comes FIRST. Reading `pieces[0]` to pick the file
		// happened before it, so a zero-sized argument -- `struct{}` or `[0]T`,
		// both ordinary in Odin, and both classified as `Direct{}` with no
		// pieces -- indexed an empty slice. Bounds-checked that aborts the
		// compiler; without bounds checking it reads uninitialised memory and
		// then consumes a stack slot for an argument with no bytes.
		// A ZERO-SIZE argument consumes the SLOT and nothing else.
		//
		// The bounds check above stopped the crash and then dropped through to
		// the spill, so `struct{}` -- ordinary in Odin -- took eight bytes of
		// outgoing stack at rsp+32. The comment above already says that is
		// wrong; the code did it anyway.
		//
		// What the slot costs is measured, and all THREE oracles agree that it
		// costs a REGISTER and no memory. `zf(struct{}, 11, 22)`:
		//
		//   clang x86_64-pc-windows-msvc  movl $11,%edx ; movl $22,%r8d ; call
		//                                 -- rcx never written, and consumed
		//   clang x86_64-pc-windows-gnu   zf(ptr dead_on_return, i32, i32)
		//   odin  -target:windows_amd64   zf(ptr, i32, i32)
		//
		// against every SysV-family target, where the argument VANISHES and the
		// first integer lands in the first register. So this is Win64's alone,
		// and it follows from the size rule rather than being an exception to
		// it: zero is not one of {1,2,4,8}, so the argument goes by reference,
		// and a reference lives in a register.
		//
		// `st.slot` has already advanced, which is the whole effect. An empty
		// Direct with `n_reg = 0` is the honest shape: the callee can read no
		// bytes of a zero-size object, and msvc leaves the register undefined,
		// so there is no content to name.
		if len(d.pieces) == 0 {
			d.n_reg = 0
			loc^ = d
			return
		}
		want_flt := len(d.pieces) == 1 && d.pieces[0].class != .INTEGER
		nregs := want_flt ? u32(len(conv.float_regs)) : u32(len(conv.int_regs))
		if len(d.pieces) == 1 && n < nregs {
			if !want_flt {
				d.pieces[0].reg = conv.int_regs[n]
			} else {
				d.pieces[0].reg = conv.float_regs[n]
			}
			d.n_reg = 1
			loc^ = d
			return
		}
		loc^ = spill(al, al, st)
		return
	}

	// Round the integer file up before allocating, where the convention asks.
	// `force_pair_align` is for VARIADIC arguments, where the rule differs from
	// the named one. Measured on riscv32:
	//
	//   f(int, long long, int)   named     -> b in a1:a2, UNALIGNED
	//   v(int, 2.5)              variadic  -> the double in a2:a3, ALIGNED
	//
	// AAPCS32 aligns both. One flag could not say that, so the caller passes
	// which case this is rather than the convention guessing.
	// VECTOR pieces are counted SEPARATELY where the row has a dedicated
	// vector file, because on that row they do not compete for the float file
	// at all.
	//
	// i386 is the case: `float_regs` is empty by design (a bare float argument
	// goes on the stack there) so `avail_flt` is always 0, and the spill gate
	// below fired before the naming loop could ever reach the vector branch.
	// `vector_regs` and `Assign_State.vec_used` were unreachable code and every
	// bare vector went to the stack, where clang puts it in xmm0.
	need_int, need_float, need_vec := u32(0), u32(0), u32(0)
	sep_vec := len(conv.vector_regs) > 0
	for i in 0 ..< len(d.pieces) {
		switch d.pieces[i].class {
		case .INTEGER:        need_int += 1
		case .VECTOR:
			if sep_vec { need_vec += 1 } else { need_float += 1 }
		case .FLOAT:          need_float += 1
		case .X87, .NONE:     // x87 is never register-passed as an argument
		}
	}

	// Round the integer file up before allocating, where the convention asks --
	// but ONLY for an argument that actually takes integer registers.
	//
	// This ran before the piece classes were counted, so a `double` (align 8 on
	// a four-byte word) rounded `int_used` up on its way to d0, consuming a core
	// register it never touched. Measured: `f(int a, double b, int c)` on
	// armv7-hf puts c in r1, and the model said r2. The same round-up IS correct
	// for a core-passed pair -- `f(int, long long, int)` puts the trailing int on
	// the stack, which the model already got right -- so the rule is not wrong,
	// its scope was.
	//
	// `force_pair_align` still reaches it: a variadic float under INT_REGS has
	// already been re-classified into INTEGER pieces by then, so need_int > 0.
	if need_int > 0 && (conv.int_pair_alignment || force_pair_align) &&
	   align > conv.word_size && conv.word_size > 0 {
		// The round-up is BOUNDED, twice, and both bounds are load-bearing.
		//
		// FIRST by the convention's own marshalling cap. AAPCS32 §6.1.2 B.5:
		// "the alignment of the copy will have 4-byte alignment if its natural
		// alignment is <= 4 and 8-byte alignment if its natural alignment is
		// >= 8". So on that row the step is 1 or 2 and never more, whatever the
		// type's own alignment is. Measured on armv7 -- `g(int, v4f, int)` puts
		// the vector's first two words in r2:r3 and the rest on the stack,
		// which is NCRN rounded to EVEN, not to four.
		//
		// SECOND by the register file, because the first bound is a per-row
		// value and an unbounded step UNDERFLOWS shared code: `st.int_used`
		// driven past `len(int_regs)` makes `avail_int` below wrap to about
		// four billion, the spill gate never fires, and the naming loop indexes
		// the file out of range. That is an abort inside the compiler, and it
		// was reachable from Odin today -- `align_of(#simd[8]f32)` is 32, which
		// on a four-register file gives step 8.
		cap := conv.int_pair_align_max
		if cap == 0 { cap = align } // unset: no per-row cap, only the file bound
		eff := min(align, cap)
		step := eff / conv.word_size
		if step > u32(len(conv.int_regs)) { step = u32(len(conv.int_regs)) }
		if step > 1 && st.int_used % step != 0 {
			st.int_used += step - (st.int_used % step)
		}
		if st.int_used > u32(len(conv.int_regs)) { st.int_used = u32(len(conv.int_regs)) }
	}

	avail_int := u32(len(conv.int_regs)) - st.int_used
	avail_flt := u32(len(conv.float_regs)) - st.float_used
	if conv.float_slot_size != 0 {
		// Count FREE slots, not "registers minus a counter": backfill means
		// used slots are not a prefix.
		avail_flt = 0
		for i in 0 ..< u32(len(conv.float_regs)) {
			if st.float_mask & (1 << i) == 0 { avail_flt += 1 }
		}
	}

	// An ALIASING file needs a trial allocation, not a count.
	//
	// `avail_flt` above counts free SLOTS; `need_float` counts PIECES, and a
	// double is one piece but two slots. Worse, `take_float_slots` needs `n`
	// ADJACENT, `n`-ALIGNED slots, so a count can say yes where the alignment
	// says no: after fifteen singles the only free slot is s15, and a double
	// needs an even pair. The comparison passed, allocation then failed
	// mid-loop, and control fell through to `float_regs[st.float_used]` -- which
	// the slot path never increments, so it handed out s0, already holding
	// argument zero. Two arguments in one register, silently.
	//
	// Simulating the allocation on a COPY answers both questions exactly, and
	// costs a few iterations on a path that already loops over the pieces.
	// The whole CPRC is ONE run, so the trial reserves one run too.
	//
	// This looped per PIECE, which is the C.1.cp defect: three separate
	// single-slot reservations happily fill a one-wide hole that backfill left,
	// and a candidate that must be consecutive ends up scattered. Measured on
	// clang armv7-hf, with s0 taken by a float and s2:s3 by a double:
	//
	//     f(float, double, struct{float,float,float})  ->  s4, s5, s6
	//
	// and the per-piece walk gave s1, s4, s5 -- it took the hole. A single
	// float argument in the same position DOES backfill into s1, which is why
	// the rule is about the run and not about the hole.
	cprc_slots, cprc_align := u32(0), u32(0)
	cprc_base, cprc_off := u32(0), u32(0)
	cprc_taken := false
	if conv.float_slot_size != 0 {
		for i in 0 ..< len(d.pieces) {
			#partial switch d.pieces[i].class {
			case .FLOAT, .VECTOR:
				n := float_slots_for(conv, piece_width(d.pieces[i]))
				cprc_slots += n
				// The ELEMENT's alignment, taken from the widest member. An HFA
				// is homogeneous so they agree; `max` keeps a mixed list from
				// under-aligning rather than silently picking the first.
				if n > cprc_align { cprc_align = n }
			}
		}
	}
	if conv.float_slot_size != 0 && need_float > 0 {
		trial := st^
		if _, got := take_float_block(conv, &trial, cprc_slots, cprc_align); !got {
			// Force the all-or-nothing path below. AAPCS32 splits only
			// integer aggregates, so this spills whole and retires the
			// float file, which is what the ABI says.
			avail_flt = 0
		}
	}

	// RISC-V: an AGGREGATE the float file cannot take reverts WHOLE to the
	// integer convention, re-laid-out as ceil(size/XLEN) word-sized pieces.
	//
	// Not "each FP piece borrows an integer register" -- that is the rule for a
	// bare scalar, and applying it to an aggregate gets the COUNT wrong, which
	// shifts every argument after it. Measured on riscv64 with fa0-fa7 full:
	//
	//     struct{float,float}    8B  -> i64          ONE integer register
	//     struct{double,double} 16B  -> [2 x i64]    two, and SPLITTABLE
	//     struct{double,float}  16B  -> [2 x i64]
	//     struct{float}          4B  -> i64          a whole word
	//     double (bare scalar)       -> double       one piece, borrows
	//
	// and on ilp32d, where a double is wider than a word:
	//
	//     struct{float,float}    8B  -> [2 x i32]
	//     struct{double}         8B  -> i64          an a0:a1 PAIR, so 1 -> 2
	//     struct{double,double} 16B  -> by reference, and never reaches here
	//
	// Only aggregates revert. A bare scalar keeps its FLOAT class and borrows,
	// which is what `.Borrowed` records and what clang's IR shows by keeping the
	// parameter typed `double`.
	// Two ways in. An AGGREGATE the float file cannot take always reverts. A
	// SCALAR reverts only when the borrow does not FIT, because that is the
	// only case where word granularity is observable:
	//
	//   fits      clang keeps the parameter typed `double` and it travels whole
	//             in one register (or an aligned pair) -- one FLOAT piece,
	//             `.Borrowed`, which is what a consumer wants to know.
	//   does not  RISC-V SPLITS it. Measured on ilp32d with fa0-fa7 and a0-a6
	//             taken, passing a double as the 16th argument:
	//                 addi a7, t1, -1638   ;  sw t2, 0(sp)
	//             one word in the last free register, one on the stack. A model
	//             that spills the whole value leaves a7 unused and puts both
	//             words where the callee reads only one.
	revert_scalar := false
	if conv.float_spills_to_int && conv.splits_aggregates && !is_aggregate &&
	   need_float > avail_flt && conv.word_size > 0 {
		want := u32(0)
		for i in 0 ..< len(d.pieces) {
			#partial switch d.pieces[i].class {
			case .FLOAT, .VECTOR:
				want += (u32(piece_width(d.pieces[i])) + conv.word_size - 1) / conv.word_size
			}
		}
		revert_scalar = want > u32(len(conv.int_regs)) - st.int_used
	}
	if conv.float_spills_to_int && need_float > 0 && need_float > avail_flt &&
	   (is_aggregate || revert_scalar) && conv.word_size > 0 {
		total := u32(0)
		for i in 0 ..< len(d.pieces) { total += u32(piece_width(d.pieces[i])) }
		// Reverting means adopting the integer convention WHOLE, including its
		// size rule: RISC-V passes an aggregate larger than two XLEN by
		// REFERENCE. That is invisible on LP64D, where a 16-byte struct is
		// exactly two words and fits, and decisive on ILP32D, where the same
		// struct is four words. Measured with the float file full:
		//
		//     lp64d   struct{double,double}  ->  [2 x i64]
		//     ilp32d  struct{double,double}  ->  ptr dead_on_return
		//
		// Taking only the register-count half of the rule put a VALUE in a0
		// where the callee expects a POINTER.
		if total > 2 * conv.word_size {
			// `size` carried across the revert. It is the OBJECT's size, and a
			// fresh Indirect here would drop it back to 0 -- the same
			// footprint trap this field exists to close.
			loc^ = Indirect{align = al, size = max(d.size, total)}
			assign(loc, conv, st, align, force_pair_align, buf, is_aggregate)
			return
		}
		n_words := int((total + conv.word_size - 1) / conv.word_size)
		if n_words <= len(buf) || n_words <= len(d.pieces) {
			room := buf if n_words <= len(buf) else d.pieces
			for i in 0 ..< n_words {
				// The OFFSET matters as much as the class. A piece carries
				// "byte offset within the aggregate this piece carries", and a
				// reverted layout is a NEW carve of the same bytes: word i
				// covers offset i*word. Leaving it zero made both halves of a
				// `struct{double,double}` claim offset 0, so a consumer copying
				// by piece would write the first double twice -- and the probe,
				// which reads each piece at the offset the prediction gives,
				// compared a1 against the FIRST member and called a correct
				// register assignment wrong.
				room[i] = Piece{class = .INTEGER, offset = u32(i) * conv.word_size}
				piece_set_width(&room[i], conv.word_size)
				// A reverted SCALAR is still a float value in integer
				// registers, and `.Borrowed` is how a consumer is told. An
				// aggregate is not: it genuinely adopts the integer convention.
				if !is_aggregate { room[i].flags += {.Borrowed} }
			}
			d.pieces = room[:n_words]
			need_int, need_float = u32(n_words), 0
			avail_flt = u32(len(conv.float_regs)) - st.float_used
		}
		// If neither the carve nor the classified slice has room, the pieces are
		// left alone and the all-or-nothing path below spills the aggregate
		// whole. That is a WRONG answer, not a refusal -- but it is the answer
		// this code gave before the reversion existed, and `assign` has no
		// channel to refuse through. A caller that goes through
		// `classify_signature` always has the room, because the carve is
		// `pieces_needed`, so the only way here is a hand-built call that passed
		// no buf and a short slice.
	}

	// RISC-V lets floats borrow integer registers once the float file is gone.
	//
	// Counted in WORDS, not pieces. A double is one piece and TWO words on
	// ILP32D, so a piece count said "one integer register will do" for a value
	// needing an aligned pair. The availability test below then passed with one
	// register free, and the naming loop had nowhere to put the second half --
	// it exhausted the counter and left the piece unnamed, producing a Direct
	// with no register, which the probe could only abstain on. Two silent
	// abstentions on riscv32, visible only once abstentions started counting.
	borrow := u32(0)
	if conv.float_spills_to_int && need_float > avail_flt && conv.word_size > 0 {
		// The pieces that must borrow are the LAST (need_float - avail_flt)
		// float pieces; sum their widths in words.
		nb := need_float - avail_flt
		seen := u32(0)
		for i := len(d.pieces) - 1; i >= 0 && seen < nb; i -= 1 {
			#partial switch d.pieces[i].class {
			case .FLOAT, .VECTOR:
				w := u32(piece_width(d.pieces[i]))
				borrow += (w + conv.word_size - 1) / conv.word_size
				seen += 1
			}
		}
	}

	avail_vec := u32(0)
	if sep_vec && u32(len(conv.vector_regs)) > st.vec_used {
		avail_vec = u32(len(conv.vector_regs)) - st.vec_used
	}
	if avail_int < need_int + borrow || (borrow == 0 && avail_flt < need_float) ||
	   avail_vec < need_vec {
		// AAPCS32 fills what registers remain and continues on the stack, and
		// RISC-V does the same for an aggregate that reverted to the integer
		// convention just above -- which is why that reversion sets
		// `need_float = 0` rather than carrying a separate flag. Measured:
		// `f(8 doubles, 7 longs, struct{double,double})` puts the first
		// eightbyte in a7 and the second on the stack, on clang AND gcc 15.1.
		// This gate read `need_float == 0` on the CLASSIFIED pieces, which for
		// an FP-classified aggregate is never true, so the whole 16 bytes went
		// to the stack and a7 was left unused.
		// ... and only while NOTHING has yet gone to the stack.
		//
		// AAPCS §6.5.5 C.8 splits an aggregate between the core registers and
		// memory "if NCRN < r4 AND the NSAA is equal to the SP". The second
		// clause looks redundant -- stacking an argument sets NCRN to r4 (C.9),
		// so NCRN < r4 seemed to imply nothing had stacked -- and it was
		// omitted on that reasoning. It is not redundant, because ONE rule
		// advances the NSAA without touching the NCRN:
		//
		//     C.2.cp  a VFP CPRC that does not fit the co-processor file is
		//             copied to the stack THERE, and never reaches C.3-C.9.
		//
		// So after a homogeneous float aggregate spills, the core file is still
		// wide open and the stack is no longer empty. Measured on
		// armv7-linux-gnueabihf, `f(8 doubles, struct{double,double} h, ...)`:
		//
		//     ..., h, int, int          h@sp+0, then movw r0 / movw r1
		//                               -- the NCRN really did survive
		//     ..., h, struct{int[5]} s  h@sp+0, s@sp+16..32 ENTIRELY
		//                               -- r0-r3 free and DELIBERATELY unused
		//
		// Without this clause the second case split s into r0-r3 plus one stack
		// word: four registers of garbage and every following argument at the
		// wrong offset. The first case is what proves the clause is load-bearing
		// rather than the NCRN merely having been retired.
		// A BARE VECTOR on a row with its own vector file fills what registers
		// remain and continues on the stack.
		//
		// Measured on i386 across six configurations (see the piece-emitting
		// site in `x86_64/classify.odin`): the file is filled greedily and the
		// remainder is spilled contiguously, at the VECTOR's own alignment
		// rather than the slot's. Two things this rule does NOT share with the
		// integer split beside it:
		//
		//   no NSAA==SP clause  `k(int, v16f, int)` splits with the integer
		//                       already at esp+0. AAPCS32 §6.5.5 C.8 would
		//                       forbid that, and i386 is not AAPCS32.
		//   no `splits_aggregates`  that flag is about AGGREGATES, and a bare
		//                       vector is not one. Gating on it would tie two
		//                       unrelated rules to one row field.
		//
		// `avail_vec == 0` deliberately falls through to the all-or-nothing
		// path below, which spills the whole value at the same alignment --
		// measured as the same answer, and one branch fewer.
		if bare_vec && sep_vec && conv.splits_vectors && avail_vec > 0 && avail_vec < need_vec &&
		   int(avail_vec) <= len(d.pieces) {
			d.n_reg = u8(avail_vec)
			for i in 0 ..< int(avail_vec) {
				d.pieces[i].reg = conv.vector_regs[st.vec_used]
				st.vec_used += 1
			}
			rest := u32(0)
			for i in int(avail_vec) ..< len(d.pieces) { rest += u32(piece_width(d.pieces[i])) }
			// The tail is aligned and SIZED by the PIECE, not by the object.
			//
			// Using the object's own alignment got all three split cases wrong
			// in the same way: a 64-byte vector's tail is one 16-byte quarter,
			// and rounding it to 64 put it at esp+64 where clang puts it at
			// esp+16, then padded it to 64 bytes and pushed the next argument
			// from esp+32 to esp+128. The tail is a run of whole REGISTER-sized
			// pieces resuming where the file ran out; its granularity is a
			// register. Same lesson as the integer split beside it -- a tail is
			// not a freshly stacked argument.
			tail_al := max(conv.max_vector_bytes, slot_align(conv))
			tail := spill(rest, tail_al, st)
			d.stack_offset = tail.offset
			loc^ = d
			return
		}
		if conv.splits_aggregates && need_float == 0 && avail_int > 0 && !st.stack_used {
			d.n_reg = u8(avail_int)
			for i in 0 ..< int(avail_int) {
				d.pieces[i].reg = conv.int_regs[st.int_used]
				st.int_used += 1
			}
			rest := u32(0)
			for i in int(avail_int) ..< len(d.pieces) { rest += u32(piece_width(d.pieces[i])) }
			// The TAIL of a split argument resumes where the registers left
			// off; it is not a fresh stacked argument and does not take the
			// over-alignment cap. Measured on riscv64 -- `g(7 longs, __int128,
			// long)` puts the i128's low half in a7, its high half at sp+0 and
			// the trailing long at sp+8, so the tail is word-aligned and the
			// next argument follows immediately. Applying
			// `stack_arg_align_max` here would push both to 16.
			tail := spill(rest, slot_align(conv), st)
			retire(conv, st, true, false) // the split path is integer-only
			d.stack_offset = tail.offset
			loc^ = d
			return
		}
		// All-or-nothing everywhere else. A partial placement is the failure
		// mode where the first half of a struct arrives and the second does not.
		//
		// The footprint is the OBJECT's size, padding included -- see `size`.
		// `max` rather than a plain choice so a caller that supplies nothing
		// keeps the old, tiling-exact behaviour and one that supplies a short
		// value cannot shrink the slot below what the pieces need.
		psum := u32(0)
		for i in 0 ..< len(d.pieces) { psum += u32(piece_width(d.pieces[i])) }
		loc^ = spill(max(d.size, psum), al, st)
		retire(conv, st, need_int > 0, need_float > 0)
		return
	}

	d.n_reg = u8(len(d.pieces))
	for i in 0 ..< len(d.pieces) {
		switch d.pieces[i].class {
		case .INTEGER:
			d.pieces[i].reg = conv.int_regs[st.int_used]
			st.int_used += 1
		case .FLOAT, .VECTOR:
			// A convention with a SEPARATE vector file uses it for VECTOR
			// pieces. Only i386 has one; everywhere else `vector_regs` is empty
			// and vectors share the float file, which is the physical truth on
			// x86-64 (xmm), AAPCS64 (v) and arm32 (d/q).
			if d.pieces[i].class == .VECTOR && len(conv.vector_regs) > 0 {
				if st.vec_used < u32(len(conv.vector_regs)) {
					d.pieces[i].reg = conv.vector_regs[st.vec_used]
					st.vec_used += 1
					continue
				}
			}
			if conv.float_slot_size != 0 {
				n := float_slots_for(conv, piece_width(d.pieces[i]))
				// The run is reserved ONCE, on the first float piece; later
				// pieces read their register out of it. Reserving per piece is
				// what let a multi-slot CPRC straddle a hole.
				if !cprc_taken {
					if b, got := take_float_block(conv, st, cprc_slots, cprc_align); got {
						cprc_base, cprc_taken = b, true
					}
				}
				if idx, got := cprc_base + cprc_off, cprc_taken; got {
					cprc_off += n
					// Name the piece from the view matching how many slots it
					// took. s0-s15 ARE d0-d7 ARE q0-q3, so the same physical
					// file has three spellings and the width picks one.
					// BOUNDS-CHECKED against the VIEW being read, not against the
					// narrow file the slot count came from.
					//
					// A row can legitimately have a narrow file and no wide or
					// quad one -- a hard-float ARM without NEON is exactly that --
					// and this indexed whichever view the width selected without
					// checking it existed. Setting `AAPCS32.float_regs_quad = {}`
					// aborted the compiler with `Index 0 is out of range 0..<0`,
					// two hundred lines from the convention that caused it.
					//
					// An unreachable view means the piece has no register, which
					// `Unplaced` already says. Found by the mutation control for
					// this very field, the first time a case could reach it.
					view := conv.float_regs
					vidx := idx
					switch n {
					case 2: view, vidx = conv.float_regs_wide, idx / n
					case 4: view, vidx = conv.float_regs_quad, idx / n
					}
					if (n == 1 || n == 2 || n == 4) && int(vidx) >= len(view) {
						d.pieces[i].reg = 0
						d.pieces[i].flags += {.Unplaced}
						continue
					}
					switch n {
					case 1, 2, 4: d.pieces[i].reg = view[vidx]
					case:
						// No view spells a 3-slot value, and naming it from the
						// SINGLE view -- which is what this case did -- claims
						// s{idx} for something twelve bytes wide, so a consumer
						// writing it would run over the next two registers.
						// There is no such float type on any surveyed target;
						// the honest answer is that the piece has no register.
						d.pieces[i].reg = 0
						d.pieces[i].flags += {.Unplaced}
					}
					continue
				}
			}
			tbl := float_view(conv.float_regs, conv.float_regs_wide,
				conv.float_regs_quad, piece_width(d.pieces[i]))
			if st.float_used < u32(len(tbl)) {
				d.pieces[i].reg = tbl[st.float_used]
				st.float_used += 1
			} else {
				// Borrowed from the integer file. The piece keeps class FLOAT
				// because that is what the VALUE is; only the register it
				// travels in changed, and a consumer needs both facts.
				//
				// It consumes ceil(width/word) registers, not one. A double on
				// ILP32D is eight bytes over a four-byte word and travels in an
				// aligned PAIR -- measured with fa0-fa7 full:
				//
				//     h(8 doubles, 9.5)  ->  li a0, 0 ; lui a1, 262704
				//
				// so a0 holds the low word and a1 the high. Consuming one
				// register left a1 free for the NEXT argument, which then
				// overlapped the double's high half. Invisible until the probe
				// started reading a piece at every word rather than once.
				nw := u32(1)
				if conv.word_size > 0 {
					nw = (u32(piece_width(d.pieces[i])) + conv.word_size - 1) / conv.word_size
					if nw < 1 { nw = 1 }
				}
				// The pair is ALIGNED where the convention says so, the same
				// rule the declared integer arguments already follow.
				if nw > 1 && conv.int_pair_alignment && st.int_used % nw != 0 {
					st.int_used += nw - (st.int_used % nw)
				}
				if st.int_used + nw <= u32(len(conv.int_regs)) {
					d.pieces[i].reg = conv.int_regs[st.int_used]
					d.pieces[i].flags += {.Borrowed}
					st.int_used += nw
				} else {
					// Not enough left for the whole value. Falling through with
					// a register named would be a partial placement, which is
					// the failure this package refuses everywhere else.
					st.int_used = u32(len(conv.int_regs))
				}
			}
		case .X87, .NONE:
		}
	}
	loc^ = d
}

// `assign_implicit` was here, and is DELETED.
//
// It had no callers, and it was a second copy of the implicit-argument walk in
// `classify_signature` -- the duplicated walk this project has been bitten by
// repeatedly, shipped in the library rather than in the harness. Its doc said
// it was "retained for callers that build a call by hand", and the tool's own
// help text advertised `--context` as verifying it; `--context` verifies
// `classify_signature`. So the copy was untested AND described as tested.
//
// It also allocated from `context.temp_allocator`, hard-coded and undocumented,
// so its result dangled after a `free_all` -- contradicting `Direct.pieces`'
// "Borrowed, never owned ... allocates nothing" two hundred lines above.
//
// A caller building a call by hand should use `classify_signature` with no
// params and no results, which places the implicit arguments and nothing else.

// ---------------------------------------------------------------------------
// Classifier input

// Position matters because SysV is not symmetric. An X87 aggregate is MEMORY as
// an argument and comes back in st0 as a return; a memory argument is a stack
// copy or a pointer while a memory return is always `sret`. The x86-64 sweep
// found the asymmetry by measurement -- `struct{long double}` is `byval` in and
// `x86_fp80` out.
Position :: enum u8 {
	ARGUMENT,
	RETURN,
}

// Field is one scalar leaf of an aggregate, already laid out.
//
// Two fields here exist because their absence was a defect:
//
//   `align`  SysV §3.2.3 makes an aggregate MEMORY if it "contains unaligned
//            fields", at ANY size. The previous classifier had no alignment to
//            test and instead refused only fields STRADDLING an eightbyte,
//            which is strictly narrower -- a 5-byte packed `{i8, i32}` was
//            given INTEGER where clang gives `byval`.
//
//   `class`  was a `bool is_float`, which cannot tell an 80-bit x87 float from
//            an f64. `struct{long double}` was answered `[SSE, INTEGER]` rather
//            than refused, despite a header comment claiming x87 was refused.
Field :: struct {
	offset: u32,
	size:   u32,
	align:  u32,
	class:  Reg_Class,
	// Whether the leaf is a POINTER, as distinct from an integer of the same
	// width. No machine class distinguishes them -- both travel in a GPR -- but
	// RISC-V's hardware floating-point rule is written in terms of C types
	// ("one floating-point real and one integer"), and clang excludes pointers
	// from it while admitting every integer type. Measured: `struct{f32, long}`
	// is passed (fa0, a0) and `struct{f32, void*}` is passed (a0, a1), with
	// byte-identical layout.
	//
	// Only the RISC-V classifier reads this. It is here rather than as a
	// Reg_Class member because a pointer is not a different register file, and
	// making it one would ripple into every other classifier's merge rule.
	is_pointer: bool,
	// For a VECTOR leaf, whether its ELEMENTS are floating-point.
	//
	// Same shape of fact as `is_pointer`: no register class distinguishes a
	// vector of halves from a vector of shorts, and one convention's rule is
	// written in terms of the element type. AAPCS32 returns a bare 4-byte
	// vector in the VFP file for integer elements and in a core register for
	// float ones -- measured, and stable across ISA levels. Meaningless when
	// `class` is not `.VECTOR`.
	vec_is_float: bool,
	// Whether the leaf was reached THROUGH a union, at any depth.
	//
	// Same shape of fact as `is_pointer`, and read by the same one classifier.
	// RISC-V's FP rule does not apply to any aggregate containing a union, and
	// after flattening there is no other way to know: a union's members carry
	// their enclosing offset, so a SINGLE-member union leaves no overlap to
	// detect. Measured on clang and gcc 15.1, riscv64:
	//
	//     struct{float,float}          -> (fa0, fa1)   the FP rule applies
	//     struct{union{float}}         -> a0           it does not
	//     struct{float, union{int}}    -> a0, ONE reg  nor here
	//     struct{struct{union{float}}} -> a0           nor at depth
	//
	// `overlapping()` catches a union with two or more members and the caller's
	// `is_union` catches a one-member union at the TOP level. Neither can see a
	// one-member union nested inside a struct, which is the shape above.
	in_union: bool,
}
