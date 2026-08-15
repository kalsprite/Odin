package abi_x86_64

import abi "core:rexcode/abi"
import x86 "core:rexcode/isa/x86"

// SysV AMD64 classification, ported onto the measured vocabulary.
//
// This replaces `rexcode-mir/abi/sysv.odin`. That version was 167 lines, checked
// by nine unit tests written by the same hand, and the oracle sweep found 11
// disagreements with clang across ~1,100 types. All three causes are fixed here
// rather than patched there, and each fix is marked with the rule it implements
// and the shape that exposed its absence.
//
// The convention is a PARAMETER, not a compile-time choice: `sysv` and `odin`
// differ only in `over_max`, and `win64` is a third row against the same code.

EIGHTBYTE :: 8

// classify answers how one type travels. A bare scalar is just a single-field
// aggregate, so there is one function rather than the previous two -- the split
// into `classify_aggregate` and `classify_scalar` was where `i128` and `f80`
// got inconsistent treatment.
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

	// A COMPLEX RESULT in the integer return registers.
	//
	// Before the memory rule, because that rule is what it overrides: on i386
	// every aggregate result goes through a hidden pointer, and a complex of
	// at most `complex_ret_int_max` bytes does not. It is placed as words in
	// the integer return file -- `eax`, then `edx`.
	//
	// Gated on the FLAG rather than on anything derivable, because nothing
	// about the fields distinguishes `_Complex float` from
	// `struct{float,float}`: same leaves, same size, same alignment, opposite
	// answers. See `Param_Flag.IS_COMPLEX`.
	//
	// ARGUMENTS are untouched. i386 passes a complex in memory like any other
	// aggregate; only the return differs.
	if pos == .RETURN && .IS_COMPLEX in flags && conv.complex_ret_int_max > 0 &&
	   size <= conv.complex_ret_int_max && size > 0 {
		n := (size + conv.word_size - 1) / conv.word_size
		if int(n) <= len(buf) && int(n) <= len(conv.ret_int_regs) {
			for i in 0 ..< n {
				w := size - i * conv.word_size
				if w > conv.word_size { w = conv.word_size }
				buf[i] = abi.make_piece(.INTEGER, i * conv.word_size, w)
			}
			return abi.Direct{pieces = buf[:n]}
		}
	}
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
		// A ZERO-SIZE AGGREGATE RESULT still goes through sret where the
		// convention returns NO aggregate by value.
		//
		// `max_by_value_ret = 0` on cdecl says exactly that, and the test it
		// feeds is `size > limit` -- which is true for every aggregate except
		// this one, because `0 > 0` is false. The one boundary case fell
		// through to "occupies nothing" and clang disagrees:
		//
		//     i386    void @rz(ptr ... sret(%struct.Zarr) align 4 ...)   SRET
		//     x86-64  void @rz()                                         nothing
		//
		// The difference between those two rows is precisely
		// `max_by_value_ret`: 0 on cdecl, 16 on SysV. So it is asked rather
		// than the size being special-cased per target.
		//
		// ARGUMENTS are untouched: a zero-size argument occupies nothing on
		// every target here, and clang emits no parameter for it at all.
		if pos == .RETURN && shape != .SCALAR {
			if r, has := conv.max_by_value_ret.?; has && r == 0 {
				return memory(size, align, conv, pos)
			}
		}
		return abi.Direct{}
	}

	// RULE 1 (SysV §3.2.3): "If the size of an object is larger than eight
	// eightbytes, or it CONTAINS UNALIGNED FIELDS, it has class MEMORY."
	//
	// The unaligned half was missing before, and it is unconditional -- it does
	// not care about size. A 5-byte `#packed{i8, i32}` has its i32 at offset 1
	// and is MEMORY; the previous classifier answered INTEGER because the field
	// does not cross an eightbyte boundary. Straddling is a strictly narrower
	// test than misalignment, and 6 of the 11 disagreements were this.
	for f in fields {
		if f.align > 1 && f.offset % f.align != 0 {
			return memory(size, align, conv, pos)
		}
	}

	// A SCALAR return is not bounded by a by-value limit, and on a four-byte
	// word it is not one eightbyte either.
	//
	// `max_by_value` is an ARGUMENT rule: it says when an object is too big to
	// hand over in registers and must be copied instead. A scalar result has no
	// such choice -- it comes back in the return registers or in st0, whatever
	// its width. Applying the limit to it made i386 answer MEMORY for
	// `long double`, which clang returns in st0, and the eightbyte assumption
	// made it answer ONE register for `long long`, which clang returns in
	// EAX:EDX.
	//
	// Handled here rather than by widening the chunk everywhere: chunking the
	// whole classifier by `word_size` was tried and reverted, because it splits
	// a `double` into two four-byte pieces on i386 and floats are not chunked.
	// The two cases below are the only ones a scalar return needs.
	if pos == .RETURN && !is_aggregate && len(fields) == 1 {
		f := fields[0]
		// A float result on 32-bit x86 comes back on the x87 stack, so its
		// CLASS is X87 -- which is this model's way of saying "no register to
		// name". It was FLOAT, and `CDECL` has no float return file, so
		// `assign_result` had nothing to name it from and the probe abstained.
		//
		// One piece, not the two the `long double` path below emits: st0 holds
		// one value whatever its width, and the two-piece form describes how an
		// 80-bit value READS OUT of the IR, not two registers.
		// SCALAR floats only. A packed VECTOR comes back in xmm0 on i386 like
		// everywhere else -- the x87 stack is for C's float and double, not for
		// SIMD -- and including `.VECTOR` here sent every bare vector return to
		// st0, which the sweep caught immediately.
		// FOUR bytes or wider. `float` and `double` come back on the x87
		// stack on i386; a `_Float16` does NOT -- clang returns it in xmm0,
		// measured the day the corpus gained the kind:
		//
		//     bare_f16   clang SSE      this rule answered X87
		//
		// The rule was written when every float in the corpus was 4 or 8 bytes,
		// so "is a float" and "is an x87 float" could not be told apart. A
		// narrower type made them two questions.
		if conv.float_returns_x87 && f.class == .FLOAT && size >= 4 &&
		   size <= 2 * EIGHTBYTE && len(buf) >= 1 {
			buf[0] = abi.make_piece(.X87, 0, size)
			return abi.Direct{pieces = buf[:1]}
		}
		if f.class == .X87 {
			// st0, as two pieces -- which is how an 80-bit value reads out of
			// the IR on both widths (12 bytes on i386, 16 on x86-64).
			//
			// The SIZE is checked here rather than left to `piece_set_width`'s
			// assertion. `u8(size - EIGHTBYTE)` ran before any test, so
			// `param_scalar(4, 4, [{size=4, class=X87}])` -- a caller's data,
			// not an internal invariant -- underflowed to 252 and tripped an
			// assert; built with -disable-assert the same input silently
			// produced a 28-byte width for a four-byte value, which is the
			// corruption the assert was added to stop. An assertion the
			// consumer can compile out is not a bound.
			//
			// An x87 value narrower than one eightbyte does not exist on either
			// target (12 bytes on i386, 16 on x86-64), so this is a REFUSAL of
			// impossible input rather than a clamp of plausible input: clamping
			// would answer confidently about a type that cannot occur.
			if size <= EIGHTBYTE || size > 2 * EIGHTBYTE || len(buf) < 2 {
				// A nil Location is this package's refusal: `Location` is a
				// union, so the caller distinguishes it with `loc == nil`.
				return nil
			}
			buf[0] = abi.make_piece(.X87, 0, EIGHTBYTE)
			buf[1] = abi.make_piece(.X87, EIGHTBYTE, size - EIGHTBYTE)
			return abi.Direct{pieces = buf[:2]}
		}
		if f.class == .INTEGER && size > conv.word_size && conv.word_size > 0 {
			n := (size + conv.word_size - 1) / conv.word_size
			if int(n) <= len(buf) {
				for i in 0 ..< n {
					w := size - i * conv.word_size
					if w > conv.word_size { w = conv.word_size }
					buf[i] = abi.make_piece(.INTEGER, i * conv.word_size, w)
				}
				return abi.Direct{pieces = buf[:n]}
			}
		}
	}

	// The RETURN limit, where it differs. This was read only by the AArch64
	// classifier, so i386 -- which returns EVERY aggregate through a hidden
	// pointer -- was told a 4-byte struct comes back in EAX. A field wired into
	// one of three classifiers is worse than an unread one: it looks live.
	limit := conv.max_by_value
	if pos == .RETURN && is_aggregate {
		if r, has := conv.max_by_value_ret.?; has { limit = r }
	}
	// A bare VECTOR is not bound by the by-value limit; it is bound by how wide
	// a vector register is.
	//
	// The two are different questions and cdecl is where they visibly part:
	// `max_by_value` is 8 there because nothing else travels in a register at
	// all, and a 16-byte __m128 still goes in xmm0. Measured, `-m32 -O1`:
	// `movaps .LCPI, %xmm0` then the call.
	//
	// `max_vector_bytes` is per-REGISTER, so a value wider than one register
	// takes several -- i386 puts a 32-byte vector in xmm0:xmm1 -- and only a
	// value needing more than the file has goes to memory.
	// The count differs by POSITION, and both halves are measured.
	//
	//   ARGUMENT  one vector register. A 32-byte vector is MEMORY at baseline
	//             -- `declare void @a8(ptr noundef byval(<8 x float>))` -- and
	//             becomes ymm0 only with -mavx, which is what `max_vector_bytes`
	//             is raised to. cdecl is the exception: it has THREE vector
	//             registers and puts a 32-byte value in xmm0:xmm1.
	//   RETURN    up to the return file. Both x86-64 and Win64 hand a 32-byte
	//             vector back in xmm0:xmm1 -- `shufps %xmm0; movaps %xmm0,
	//             %xmm1; retq` -- at baseline AND with -mavx, so this one is
	//             not feature-dependent at all.
	//
	// KNOWN DIVERGENCE from gcc, and CLANG WINS. On i386, for a vector wider
	// than one register, gcc 16 answers differently -- 32 bytes entirely on the
	// stack rather than xmm0:xmm1, with "note: the ABI for passing parameters
	// with 32-byte alignment has changed in GCC 4.6", and 64 bytes likewise.
	// They agree exactly at 16.
	//
	// This was briefly left unmodelled on the grounds that a split is a
	// commitment and the two compilers made it a coin toss. That reasoning does
	// not survive contact with the rest of this project: clang IS the oracle
	// here -- every classification in the sweep is judged against it -- so
	// declining to follow it above one register was inconsistent, not cautious.
	// The split is implemented and measured across six configurations below.
	// gcc's answer is recorded so a future reader knows the divergence is known
	// rather than unnoticed.
	//
	// Odin passes all three widths by pointer and is wrong against both -- filed
	// as `UPSTREAM-UNFILED-abi-i386-simd-vector-passed-by-pointer`.
	if !is_aggregate && len(fields) == 1 &&
	   abi.eff_class(conv, fields[0], pos, shape) == .VECTOR &&
	   conv.max_vector_bytes > 0 {
		file := len(conv.vector_regs) > 0 ? len(conv.vector_regs) : 1
		if pos == .RETURN {
			file = len(conv.ret_float_regs)
			if len(conv.ret_vector_regs) > 0 { file = len(conv.ret_vector_regs) }
		}
		n := (size + conv.max_vector_bytes - 1) / conv.max_vector_bytes
		// A row with a SEPARATE vector file SPLITS an argument that needs more
		// registers than the file has: what fits goes in registers and the rest
		// goes on the stack. So the piece list is emitted whatever `n` is, and
		// `assign` decides how much of it is register-resident.
		//
		// Only for ARGUMENTS, and only on a row with its own vector file --
		// i386. A RETURN cannot half-spill (that is what sret is for), and on a
		// row where vectors share the float file a value needing more than one
		// register is MEMORY whole, measured: x86-64 at baseline gives
		// `byval(<8 x float>)` for a 32-byte vector, not xmm0:xmm1.
		//
		// Measured on i386, SSE baseline, six configurations in one compile.
		// Reading `k(...)` as "N vector registers free, needs M":
		//
		//   3 free, needs 4   int@0  3 in xmm0-2, 1 quarter @esp+16, int@32
		//   1 free, needs 4   1 in xmm2, 3 quarters @esp+0..47, int@48
		//   0 free, needs 4   all four @esp+0..63, int@64
		//   2 free, needs 2   xmm1:xmm2, nothing on the stack
		//   1 free, needs 2   1 in xmm2, 1 half @esp+0, int@16
		//   0 free, needs 2   both halves @esp+0..31, int@32
		//
		// One rule covers all six: fill the file greedily, spill the remainder
		// contiguously. There is no all-or-nothing and -- note the first row,
		// where an integer has ALREADY stacked -- no AAPCS32-style "NSAA equals
		// SP" precondition.
		splits := pos != .RETURN && len(conv.vector_regs) > 0 && conv.splits_vectors
		if n >= 1 && int(n) <= len(buf) && (int(n) <= file || splits) {
			for i in 0 ..< n {
				w := size - i * conv.max_vector_bytes
				if w > conv.max_vector_bytes { w = conv.max_vector_bytes }
				buf[i] = abi.make_piece(.VECTOR, i * conv.max_vector_bytes, w)
			}
			return abi.Direct{pieces = buf[:n]}
		}
	}
	if size > limit {
		// A BARE VECTOR keeps its own stack alignment; an over-aligned
		// aggregate does not. Measured on i386 in one compile:
		//
		//   g(v4f,v4f,v4f, int, v4f, int)     movaps %xmm3, 16(%esp)
		//   h(int, struct #align(16), int)    movups %xmm0,  4(%esp)
		//
		// so the vector slot is 16-aligned and the struct slot is four. The
		// `movaps`/`movups` pair is clang saying it twice. Without this the
		// vector landed at esp+4 and every argument after it was 12 bytes out.
		bare_vec := !is_aggregate && len(fields) == 1 &&
			abi.eff_class(conv, fields[0], pos, shape) == .VECTOR
		return memory(size, align, conv, pos, bare_vec)
	}

	// RULE 2: merge the classes of every field overlapping each eightbyte.
	//
	// Untouched eightbytes stay NONE and are DROPPED below. Deriving the count
	// from `size` alone -- as the previous version did -- passes a register of
	// padding: `#align(16){a, b: i8}` is 16 bytes with two bytes of data, and
	// clang passes ONE register. Passing two shifts every later argument.
	n := (size + 7) / EIGHTBYTE
	// `classes` and `sseup` are two entries, and `n` is bounded only by
	// `conv.max_by_value`. A row with a larger limit -- AAPCS32 sets 1<<20, and
	// nothing in the type system stops it being handed to this classifier --
	// indexes past the end. Refuse rather than overrun.
	if n > 2 { return memory(size, align, conv, pos) }
	// SSEUP is a CLASS, not a flag beside the class.
	//
	// §3.2.3 lists SSEUP among the eightbyte classes and merges it like any
	// other -- (d) INTEGER wins over it, (f) SSE absorbs it -- and post-merger
	// (b) then fixes only what is STILL SSEUP. Modelling it as a parallel
	// `sseup: [2]bool` set from "a vector field spans this eightbyte" gets the
	// first question wrong, because a field fact is not a merged class, and the
	// flag survived merges that should have consumed it. Two rounds of patching
	// the symptom did not remove the mechanism:
	//
	//   union{v4f, long}                  eightbyte 0 merged to INTEGER -- the
	//                                     first patch cleared the orphan flag
	//   union{v4f, struct{double,long}}   eightbyte 0 STAYS SSE, eightbyte 1
	//                                     merged to INTEGER and kept the flag,
	//                                     so the piece was still deleted:
	//                                     clang gives (xmm0, rdi), we gave one
	//
	// Carrying SSEUP in the class array makes both fall out of the ordinary
	// merge, and the mapping back to `Reg_Class` happens once, at emit.
	Cls :: enum u8 { NONE, INTEGER, SSE, SSEUP, X87 }
	classes: [2]Cls

	// merge_cls is §3.2.3's post-merger, over the real class set.
	merge_cls :: proc(a, b: Cls) -> (Cls, bool) {
		if a == b        { return a, false }
		if a == .NONE    { return b, false }
		if b == .NONE    { return a, false }
		// (d) INTEGER wins -- before the x87 case, which is the ordering that
		// `union{i128, long double}` turns on.
		if a == .INTEGER || b == .INTEGER { return .INTEGER, false }
		// (e) x87 mixed with anything else is MEMORY.
		if a == .X87 || b == .X87 { return .NONE, true }
		// (f) everything left is SSE-family; SSE absorbs SSEUP.
		return .SSE, false
	}

	for f in fields {
		if f.size == 0 { continue }
		lo := f.offset / EIGHTBYTE
		hi := (f.offset + f.size - 1) / EIGHTBYTE
		if hi >= 2 {
			// Only reachable if the layout disagrees with `size`, which would
			// mean the caller's layout is wrong. Refusing beats guessing.
			return memory(size, align, conv, pos)
		}
		for eb := lo; eb <= hi; eb += 1 {
			fc: Cls
			switch abi.eff_class(conv, f, pos, shape) {
			case .INTEGER:        fc = .INTEGER
			case .FLOAT:          fc = .SSE
			case .X87:            fc = .X87
			case .VECTOR:         fc = eb > lo ? .SSEUP : .SSE
			case .NONE:           continue
			}
			c, mem := merge_cls(classes[eb], fc)
			if mem { return memory(size, align, conv, pos) }
			classes[eb] = c
		}
	}

	// Post-merger (b): an SSEUP not preceded by SSE or SSEUP becomes SSE.
	for i in 1 ..< n {
		if classes[i] == .SSEUP && classes[i - 1] != .SSE && classes[i - 1] != .SSEUP {
			classes[i] = .SSE
		}
	}

	// RULE 3: x87, which is asymmetric AND fragile.
	//
	// An 80-bit float occupies X87 followed by X87UP. SysV's post-merge fixup:
	// "if X87UP is not preceded by X87, the whole argument is passed in
	// memory." A union can produce exactly that -- `union{i8, long double}`
	// merges eightbyte 0 to INTEGER (rule d above) and leaves eightbyte 1 as a
	// bare X87UP, so the whole thing goes to memory even though half of it
	// classified cleanly.
	//
	// Only a PURE x87 aggregate survives, and then only in return position: as
	// an argument the X87 class goes on the stack, as a return it comes back in
	// st0. `struct{long double}` is `byval` in and `x86_fp80` out.
	// Read the MERGED classes, not "an x87 field was present". `union{i128,
	// long double}` has an x87 field in both eightbytes and merges to INTEGER
	// in both, because INTEGER wins -- it is passed in two integer registers
	// and testing the field would send it to memory.
	has_x87 := false
	for i in 0 ..< n {
		if classes[i] == .X87 { has_x87 = true }
	}
	if has_x87 {
		// X87UP must be preceded by X87. `union{i8, long double}` merges
		// eightbyte 0 to INTEGER and leaves eightbyte 1 a bare X87UP.
		if classes[0] != .X87 || (n > 1 && classes[1] != .X87) {
			return memory(size, align, conv, pos)
		}
		if pos == .ARGUMENT {
			return memory(size, align, conv, pos)
		}
	}

	np := 0
	// NO_CLASS is skipped WHEREVER it sits, not popped off the end.
	//
	// §3.2.3: an eightbyte that ends up NO_CLASS is not passed at all. Dropping
	// only TRAILING ones is enough for a source-level type, because a non-empty
	// aggregate always has a member at offset 0 and two eightbytes cannot have
	// an interior hole. It is NOT enough in general, and Odin can build the
	// counterexample:
	//
	//     struct #min_field_align(16) { a: i8, b: f32 }
	//         size 32, a@0, b@16   -- eightbyte 1 empty, eightbyte 2 occupied
	//
	// That one is MEMORY here anyway: `size > max_by_value` is applied BEFORE
	// any of this, so it never reaches the walk. But that ordering -- chosen
	// because deciding MEMORY after dropping padding makes `#align(32){f32}`
	// look like a single SSE eightbyte -- also means there is no later
	// demotion to catch an interior hole. Skipping by index rather than popping
	// from the end is what makes the walk correct on its own terms instead of
	// correct because something upstream happened to filter the input.
	//
	// Each emitted piece carries its own `offset`, so the absence lands in the
	// right place. Checked through the public API, which accepts field lists no
	// source type produces:
	//
	//     {i8@0, i8@1}  size 16  ->  INTEGER(w8@0)     trailing hole
	//     {i64@8}       size 16  ->  INTEGER(w8@8)     leading hole, offset 8
	//     {}            size 16  ->  no pieces at all
	for i in 0 ..< n {
		if classes[i] == .NONE {
			continue // padding-only eightbyte: NO_CLASS, not passed
		}
		if classes[i] == .SSEUP {
			continue // absorbed by the SSE piece that precedes it
		}
		w := size - i * EIGHTBYTE
		if w > EIGHTBYTE { w = EIGHTBYTE }
		rc: abi.Reg_Class = .INTEGER
		switch classes[i] {
		case .INTEGER: rc = .INTEGER
		case .X87:     rc = .X87
		case .SSE:
			// SSE plus its SSEUPs is ONE register, so widen to cover them and
			// call it a vector; a lone SSE eightbyte is a scalar float.
			rc = .FLOAT
			for k := i + 1; k < n && classes[k] == .SSEUP; k += 1 {
				add := size - k * EIGHTBYTE
				if add > EIGHTBYTE { add = EIGHTBYTE }
				w += add
				rc = .VECTOR
			}
		case .SSEUP, .NONE:
		}
		buf[np] = abi.make_piece(rc, i * EIGHTBYTE, w)
		np += 1
	}
	// TRIMMED to the pieces actually produced. The buffer is sized for the
	// worst case; the slice is the answer, and leaving it at full length would
	// report padding eightbytes as real ones.
	d: abi.Direct
	d.pieces = buf[:np]
	// An aggregate of nothing but padding is passed in nothing at all.
	return d
}

// merge is the SysV post-merger rule for one eightbyte.
//
// INTEGER beats FLOAT: an eightbyte is SSE only when EVERY field touching it is
// floating point. `{i32, f32}` sharing an eightbyte is INTEGER, which is what
// caused an earlier version of the mir classifier to refuse a case its own live
// path handled correctly (mir_design.md:705).
merge :: proc(a, b: abi.Reg_Class) -> (cls: abi.Reg_Class, mem: bool) {
	if a == b        { return a, false }
	if a == .NONE    { return b, false }
	if b == .NONE    { return a, false }
	// ORDER MATTERS, and it is the ABI's order, not an arbitrary one. SysV
	// §3.2.3 lists the merge cases and INTEGER (case d) comes BEFORE the X87
	// case (e):
	//
	//     (d) If one of the classes is INTEGER, the result is INTEGER.
	//     (e) If one of the classes is X87, X87UP or COMPLEX_X87, MEMORY is used.
	//
	// Testing X87 first sends `union{i128, long double}` to memory where clang
	// passes it in two integer registers. Nothing in the corpus reached this
	// until the `rawunion` family started generating actual unions -- with
	// overlapping members, an eightbyte can hold X87 AND INTEGER at once, and
	// no struct can produce that.
	// A vector merged with a float stays a vector; nothing else in the corpus
	// shares an eightbyte with one.
	if a == .VECTOR || b == .VECTOR {
		if a == .INTEGER || b == .INTEGER { return .INTEGER, false }
		return .VECTOR, false
	}
	if a == .INTEGER || b == .INTEGER { return .INTEGER, false }
	// Rule (e) proper: x87 merged with anything that is not INTEGER or itself
	// yields MEMORY -- it does not yield X87. `union{f32, long double}` is a
	// stack copy, and returning X87 here made it come back in st0 instead.
	if a == .X87 || b == .X87 { return .NONE, true }
	return .FLOAT, false
}

// memory routes a MEMORY-class type to the right mechanism.
//
// Three outcomes from one classification, and conflating the first two is the
// defect at mir_design.md:1373 -- a stack copy and a pointer to a caller copy
// are different things, and the differential could not tell them apart because
// both sides of it were mirc.
// `is_vector` marks a class whose stack slot is aligned by the row's VECTOR
// rule rather than its ordinary one. See `abi.Convention.vector_stack_align_max`.
memory :: proc(size, align: u32, conv: ^abi.Convention, pos: abi.Position,
               is_vector := false) -> abi.Location {
	// The floor is a WORD, not eight bytes. Hardcoding 8 over-aligned every
	// i386 memory-class argument.
	al := align
	if al < conv.word_size { al = conv.word_size }
	if pos == .RETURN {
		return abi.Sret{align = al}
	}
	switch conv.over_max {
	case .INDIRECT:   return abi.Indirect{align = al}
	case .STACK_COPY: return abi.Stack{size = size, align = al, is_vector = is_vector}
	}
	return abi.Stack{size = size, align = al, is_vector = is_vector}
}

// ---------------------------------------------------------------------------
// Convention rows
//
// Register values come from `core:rexcode/isa/x86`, which already defines them
// with their class bits encoded (`RDI` is `REG_GPR64 | 7`, not `7`). The ABI
// package must not invent a second numbering: a row that says `7` is ambiguous
// between RDI and a GPR32, and the ISA package is the one that gets to say.
//
// The dependency points DOWNWARD -- abi imports isa, never the reverse -- which
// is what keeps `isa/` usable by a backend that wants nothing else here.

// The argument registers, in assignment order.
SYSV_INT  := [?]u16{u16(x86.RDI), u16(x86.RSI), u16(x86.RDX), u16(x86.RCX), u16(x86.R8), u16(x86.R9)}
WIN64_INT := [?]u16{u16(x86.RCX), u16(x86.RDX), u16(x86.R8),  u16(x86.R9)}
SYSV_RET_INT := [?]u16{u16(x86.RAX), u16(x86.RDX)}
CDECL_RET_INT := [?]u16{u16(x86.EAX), u16(x86.EDX)}

// i386 passes the first three __m128 in xmm0-xmm2, and NOTHING else in a
// register. Measured with -m32 -fno-pic -O1:
//
//     v2f  (8 bytes)   movsd  .LCPI, %xmm0
//     v4f  (16 bytes)  movaps .LCPI, %xmm0
//     v4i  (16 bytes)  movaps .LCPI, %xmm0
//     v8f  (32 bytes)  movaps %xmm0 + movaps %xmm1      one per 16 bytes
CDECL_VEC := [?]u16{u16(x86.XMM0), u16(x86.XMM1), u16(x86.XMM2)}
// A vector RESULT comes back in xmm, even on i386 where a scalar float comes
// back on the x87 stack. Two registers for a 32-byte value.
// FOUR, not two, and the difference is the whole content of the wide-vector
// return rule. Measured, clang 22.1.8, both x86-64 and i386:
//
//     64-byte vector   movaps into xmm0, xmm1, xmm2, xmm3; retq   IN REGISTERS
//     128-byte vector  movq %rdi,%rax ... movaps %xmm7,112(%rdi)  SRET
//
// So the file is BOUNDED at four and a result needing five goes to memory.
// `{xmm0, xmm1}` sent every 64-byte vector return to memory.
X86_RET_VEC := [?]u16{u16(x86.XMM0), u16(x86.XMM1), u16(x86.XMM2), u16(x86.XMM3)}
SYSV_RET_SSE := [?]u16{u16(x86.XMM0), u16(x86.XMM1)}
WIN64_RET_INT := [?]u16{u16(x86.RAX)}
WIN64_RET_SSE := [?]u16{u16(x86.XMM0)}

SSE_ARGS  := [?]u16{
	u16(x86.XMM0), u16(x86.XMM1), u16(x86.XMM2), u16(x86.XMM3),
	u16(x86.XMM4), u16(x86.XMM5), u16(x86.XMM6), u16(x86.XMM7),
}
WIN64_SSE := [?]u16{u16(x86.XMM0), u16(x86.XMM1), u16(x86.XMM2), u16(x86.XMM3)}

SYSV := abi.Convention{
	name         = "sysv",
	varargs      = .SYSV_AL,
	// x86-64 is the one target that NEVER packs a result tuple: Odin gives
	// `-> (i8, i8)` a hidden pointer even though two bytes would fit AL alone.
	// Measured; the other four targets all pack a tuple that fits.
	multi_return = .TRAILING_POINTERS,
	// SysV aligns a stacked argument to its natural alignment. Measured:
	// f(long x7, __int128, long) puts the __int128 at sp+16 with sp+8 padding.
	// EFFECTIVELY NO CAP. x86-64 is the only row here whose `over_max` is
	// STACK_COPY, so an over-aligned aggregate really does land in the outgoing
	// area -- and clang AND gcc realign the area and honour the full alignment:
	//
	//   h(7 longs, struct{long a,b,c,d;} aligned(32), long)
	//     andq $-32,%rsp ; 7@sp+0 ; struct@sp+32..63 ; 8@sp+64   both compilers
	//
	// This was 16, which was measured at alignment 16 and assumed to be the
	// ceiling. It is not: at 32 the model put the struct at sp+16 and the
	// trailing argument at sp+48 where both compilers say 32 and 64. Spelled as
	// a huge number rather than 0 because 0 means the opposite here -- "ignore
	// the type's alignment entirely", which is i386's rule.
	// A stacked VECTOR follows the same rule here: measured, `g(v8f x8, 6
	// longs, int, v8f, int)` puts the 32-byte vector at rsp+32, its own
	// alignment. `vector_stack_align_max` is left 0 -- setting it to the same
	// number would be a value nothing could falsify, since zeroing it changes
	// no answer.
	stack_arg_align_max = 1 << 20,
	// Baseline. -mavx would make this 32 and -mavx512f 64; the register FILE
	// is unchanged, only the width, which is why one number says it all.
	max_vector_bytes = 16,
	// Below one eightbyte a vector is INTEGER here, with NO exception for the
	// bare form -- which is what distinguishes this row from AAPCS64's.
	// Measured: `v4i8 r(void)` is `movl g4(%rip), %eax`, and
	// `void a(v4i8 x, int t)` leaves `t` in %esi, so the vector took %edi.
	min_vector_bytes = 8,
	// `ret_vector_regs` IS SET HERE NOW, and the note it replaces is a good
	// record of why a field can stop being redundant.
	//
	// It used to be left unset, measured: on this row it was `{XMM0, XMM1}` --
	// byte-for-byte `SYSV_RET_SSE`, the float return file it falls back to --
	// so emptying it changed no answer anywhere and a restatement no mutation
	// can falsify is exactly what this project deletes.
	//
	// The 64-byte vector row made the two files DIFFER. A vector result splits
	// across four registers (xmm0-xmm3) where a float result uses two, so the
	// fallback now gives the wrong bound and sends a 64-byte vector to memory.
	// The field is load-bearing again, and `--mutate=ret-vec-off` says so.
	ret_vector_regs  = X86_RET_VEC[:],
	//
	// A restatement no mutation can falsify is the thing this project keeps
	// finding; `float_size` on five rows went the same way.
	int_regs     = SYSV_INT[:],
	float_regs   = SSE_ARGS[:],
	ret_int_regs   = SYSV_RET_INT[:],
	ret_float_regs = SYSV_RET_SSE[:],
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
	over_max     = .STACK_COPY,
	stack_align  = 8,
	red_zone     = 128,
}

// ODIN and CONTEXTLESS are SYSV COMPOSED with a language, not rows of their own.
//
// They used to be hand-written copies differing in two fields, and the copy
// silently fell out of step: it never carried `multi_return`, so once that
// field became load-bearing the hidden-pointer protocol vanished for x86-64
// while every composed platform kept it. A duplicated row drifting from its
// original, in the package whose entire argument is that duplication is what
// goes wrong.
ODIN:        abi.Convention
CONTEXTLESS: abi.Convention

// Odin on i386. Worth having as more than completeness: cdecl has NO argument
// registers, so the implicit context is a stack slot at every arity -- the only
// target where `--context` exercises that branch at all.
CDECL_ODIN:  abi.Convention
// Odin on Windows, which is a PRIMARY target. Win64 already makes any aggregate
// that is not 1/2/4/8 bytes indirect, so Odin's own by-pointer rule coincides
// with the platform's rather than overriding it -- but the implicit `^Context`
// and the multi-value protocol are language deltas that exist here and nowhere
// in the C row.
WIN64_ODIN:  abi.Convention

@(init)
init_x86_64_conventions :: proc "contextless" () {
	ODIN        = abi.compose(SYSV, abi.lang_odin())
	CONTEXTLESS = abi.compose(SYSV, abi.lang_contextless())
	CDECL_ODIN  = abi.compose(CDECL, abi.lang_odin())
	// Composed BEFORE the C row overwrites `WIN64`, for the same
	// initialisation-order reason the others are.
	WIN64_ODIN  = abi.compose(WIN64, abi.lang_odin())
	WIN64       = abi.compose(WIN64, abi.lang_c())
	CDECL       = abi.compose(CDECL, abi.lang_c())
	SYSV        = abi.compose(SYSV, abi.lang_c())
}

// ---------------------------------------------------------------------------
// Win64
//
// Same ISA, same package, and almost none of the same rules. Kept beside SysV
// rather than in its own architecture directory because the register NAMES and
// the encoder are shared and only the convention differs -- which is the claim
// the row model makes, tested here.

// classify_win64 is far simpler than SysV, and simple in a way that surprises.
//
//   * An aggregate of exactly 1, 2, 4 or 8 bytes goes in ONE integer register.
//     Not "up to 8 bytes" -- a THREE-byte struct goes by reference.
//   * The register is an INTEGER one whatever the content: `struct{f32}` is
//     `i32` and `struct{f32,f32}` is `i64`. There is no per-eightbyte merge and
//     no SSE class for aggregates at all.
//   * A BARE float still uses xmm. That distinction does not exist under SysV,
//     AAPCS64 or RISC-V, where `f32` and `struct{f32}` classify alike, and it is
//     why `classify` takes `is_aggregate`.
//   * Everything else is passed as a pointer to a caller copy.
classify_win64 :: proc(
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

	if !is_aggregate {
		// A bare scalar keeps its own register file.
		cls := len(fields) == 1 ? fields[0].class : abi.Reg_Class.INTEGER
		if cls == .X87 {
			// Windows has no 80-bit long double; nothing should reach this.
			return memory(size, align, conv, pos)
		}
		// A RETURN is direct at every size, and the register is XMM0.
		//
		// The size rule below is an ARGUMENT rule. Applied to returns it made
		// every 16-byte scalar an Sret, and the callee side says otherwise --
		// measured on clang for x86_64-windows-msvc, reading the instruction
		// that sets up the result before `retq`:
		//
		//     v4f      f(...)   shufps $0, %xmm0, %xmm0 ; retq
		//     __int128 f(...)   punpcklqdq %xmm1, %xmm0 ; retq
		//
		// So `__int128` comes back in XMM0, not RAX:RDX, which is why the piece
		// is VECTOR rather than INTEGER: the class is what names the file, and
		// calling it INTEGER would send a consumer to the wrong register with
		// the right offset.
		if pos == .RETURN {
			// A vector wider than one register is several. Measured: a 32-byte
			// vector result is `shufps %xmm0; movaps %xmm0, %xmm1; retq`.
			if cls == .VECTOR && conv.max_vector_bytes > 0 && size > conv.max_vector_bytes {
				n := (size + conv.max_vector_bytes - 1) / conv.max_vector_bytes
				file := len(conv.ret_float_regs)
				if len(conv.ret_vector_regs) > 0 { file = len(conv.ret_vector_regs) }
				if int(n) <= len(buf) && int(n) <= file {
					for i in 0 ..< n {
						w := size - i * conv.max_vector_bytes
						if w > conv.max_vector_bytes { w = conv.max_vector_bytes }
						buf[i] = abi.make_piece(.VECTOR, i * conv.max_vector_bytes, w)
					}
					return abi.Direct{pieces = buf[:n]}
				}
			}
			// REFUSE a width the encoding cannot hold, rather than
			// truncating into it.
			//
			// This read `u8(size)`, so a 64-byte scalar became 64 (which the
			// assert caught in a debug build and nothing caught otherwise) and
			// a 256-byte one became 0, encoding as a 32-byte piece. Reachable
			// on any row whose `max_vector_bytes` is unset, where the splitting
			// branch above does not fire and everything falls through to here.
			if !abi.piece_width_ok(size) { return nil }
			ps := buf[:1]
			rc := cls
			if size > 8 { rc = .VECTOR }
			ps[0] = abi.make_piece(rc, 0, size)
			return abi.Direct{pieces = ps}
		}
		// A VECTOR argument is passed by reference at EVERY size.
		//
		// MSDN: "__m128 types, arrays, and strings are never passed by immediate
		// value" -- and unlike most of this package, the IR cannot adjudicate
		// it. clang's Win64 IR types the parameter `<4 x float>`, which reads
		// like a register, and the backend then lowers it by pointer anyway.
		// This is one of the three documented places where clang's IR is NOT its
		// classification, so the ASM is the oracle:
		//
		//     v4c (4 bytes)   leaq 32(%rsp), %rcx
		//     v2f (8 bytes)   leaq 32(%rsp), %rcx
		//     v4f (16 bytes)  leaq 32(%rsp), %rcx
		//
		// The `size > 8` test alone got the last of those right and the first
		// two wrong, and no corpus row could tell: every `vector` row is a
		// STRUCT wrapping a vector, so `is_aggregate` was true and this branch
		// was unreachable. The `barevec` family exists to reach it.
		if cls == .VECTOR {
			// A vector WIDER than one vector register is REFUSED here, not
			// answered.
			//
			// Win64 passes anything that is not 1, 2, 4 or 8 bytes by
			// reference, and it applies that PER REGISTER-WIDTH. Measured,
			// `g(int, v8i, int)` on x86_64-windows-gnu, one compile per level:
			//
			//   baseline  movl $7,%ecx  leaq %rdx  leaq %r8  movl $9,%r9d
			//   -mavx     movl $7,%ecx  leaq %rdx           movl $9,%r8d
			//
			// TWO pointers for one argument at the level where the value takes
			// two registers, and one where it takes one. So it is not a
			// legalisation artefact to be waved away -- it tracks
			// `max_vector_bytes`, which is exactly the model this row already
			// uses everywhere else.
			//
			// `Location` cannot express it: `Indirect` is ONE pointer, and an
			// argument occupying two integer slots through two pointers has no
			// spelling. Answering `Indirect` anyway is what the model did, and
			// it is wrong in a way that moves every later argument -- clang puts
			// the trailing int in r9 and the model said r8. A nil refusal is
			// counted as "outside the model", which is what this is.
			//
			// Found the day `VEC32` entered the corpus, by the first case that
			// passed a vector needing two registers.
			if conv.max_vector_bytes > 0 && size > conv.max_vector_bytes {
				return nil
			}
			return memory(size, align, conv, pos)
		}
		// "Any argument that doesn't fit in 8 bytes ... must be passed by
		// reference" -- `__int128`, and any other oversized scalar. This branch
		// used to emit one register piece of min(size,8) for any scalar, which
		// silently dropped the upper half.
		if size > 8 {
			return memory(size, align, conv, pos)
		}
		ps := buf[:1]
		ps[0] = abi.make_piece(cls, 0, size)
		return abi.Direct{pieces = ps}
	}

	// "Structs and unions of size 1, 2, 4, or 8 bytes ... are passed as if they
	// were integers of the same size" (MSDN, x64 calling convention).
	//
	// Read off the ROW rather than written as the literal set `{1,2,4,8}`. It
	// WAS the literal set, and `WIN64.max_by_value = 8` sat beside it being
	// cited by the row's own comment as the rule while nothing read it -- the
	// field could be set to any number at all and no answer moved. Powers of two
	// up to the limit is exactly the same set at 8, and it is now the row that
	// says 8: dropping the limit to 4 sends an eight-byte aggregate to memory
	// and turns the probe red.
	//
	// The POWER-OF-TWO half stays in code, because it is not a limit and no row
	// field expresses it. Win64 really does put a THREE-byte struct in memory
	// while three is below the limit, which is what makes this a set and not a
	// bound.
	if size <= conv.max_by_value && size & (size - 1) == 0 {
		ps := buf[:1]
		ps[0] = abi.make_piece(.INTEGER, 0, size)
		return abi.Direct{pieces = ps}
	}
	return memory(size, align, conv, pos)
}

// CDECL is the 32-bit System V convention, and it has NO argument registers:
// everything goes on the stack, in declaration order, in four-byte slots.
//
// Used by the sequencing probe, which is where i386's semantic content lives.
// There is deliberately no i386 `classify` beside it: with no argument
// registers, clang's choice between a `direct` coercion and `byval` has no ABI
// consequence -- both put the same bytes in the same slot -- so a classifier
// matching the IR would be encoding a codegen heuristic as if it were the ABI.
// `max_by_value` here therefore only ever sees the scalars the probe passes.
CDECL := abi.Convention{
	// A complex of at most two words comes back in EAX:EDX. Measured, and
	// upstream reached the same bound: "return a complex of eight bytes or
	// fewer in EAX:EDX". `_Complex double` at 16 bytes uses sret, and a
	// struct of two floats uses sret at every width -- see
	// `Param_Flag.IS_COMPLEX` for why the fields cannot tell them apart.
	complex_ret_int_max = 8,
	name         = "cdecl",
	varargs      = .SAME_AS_NAMED,
	sret_callee_pops = true,
	// Left SINGLE, and NOT because it was never measured.
	//
	// Odin does pack an i386 result tuple -- `-> (i32, i32)` comes back as one
	// i64 in EAX:EDX -- but it gets there through a struct-return rule that
	// contradicts the psABI: Odin returns `struct{i32,i32}` from a plain
	// `proc "c"` in EAX:EDX where the i386 System V ABI, and clang, return
	// every struct through a hidden pointer. See
	// COMPILER_ISSUES/UPSTREAM-UNFILED-i386-small-struct-returned-in-registers.md.
	//
	// So there are two answers on i386 and they disagree: the psABI's, which
	// this row models everywhere else, and Odin's, which is defective. Modelling
	// Odin's would bake a bug into the table and break interoperation with C on
	// the same target. SINGLE makes `classify_signature` refuse a multi-value
	// i386 signature until the upstream rule is fixed, which is the one answer
	// that is not wrong.
	multi_return = .SINGLE,
	// i386 returns EVERY aggregate through a hidden pointer -- the survey
	// measured 995 sret returns against 10 direct, and the direct ones are
	// bare scalars. Zero, not absent: absent would mean "same as arguments".
	max_by_value_ret = u32(0),
	int_regs     = {},
	float_regs   = {},
	// i386 returns integers in EAX:EDX; floats come back in x87's ST0, which
	// this model has no register for. Left empty rather than guessed -- an
	// unset file is visibly unset, a wrong one is not.
	// EAX:EDX, not RAX:RDX. This named the SIXTY-FOUR-bit registers on a
	// four-byte-word row, so the typed seam handed a backend `x86.RAX` for an
	// i386 `long long` return.
	float_returns_x87 = true, // both `float` and `double` come back in ST0
	// cdecl has no INTEGER or FLOAT argument registers and three VECTOR ones.
	max_vector_bytes = 16,
	vector_regs      = CDECL_VEC[:],
	ret_vector_regs  = X86_RET_VEC[:],
	ret_int_regs   = CDECL_RET_INT[:],
	word_size    = 4,
	max_by_value = 8,
	over_max     = .STACK_COPY,
	stack_align  = 4,
	// `stack_arg_align_max` stays 0 -- an `aligned(16)` struct really does go
	// at esp+4 on cdecl, measured -- and a VECTOR does not follow it. i386
	// psABI §2.2.3: `__m128` and wider are 16/32/64-byte aligned on the stack.
	// Measured in one compile, which is what makes the pair decisive:
	//
	//   g(v4f x3, int, v4f, int)      movl $7,(%esp)  movaps %xmm,16(%esp)  movl $9,32(%esp)
	//   k(v16f x3, int, v16f, int)    movl $7,(%esp)  vmovaps %zmm,64(%esp) movl $9,128(%esp)
	//   h(int, struct #align(16), int) movl $7,(%esp) movups %xmm, 4(%esp)  ... 20(%esp)
	vector_stack_align_max = 1 << 20,
	// The only row measured to SPLIT a bare vector across the file and the
	// stack. See `abi.Convention.splits_vectors`.
	splits_vectors = true,
}

WIN64 := abi.Convention{
	name         = "win64",
	varargs      = .WIN64_DUPLICATE,
	// MEASURED. This said "never measured: there is no Win64 odin row to
	// drive" -- true when written and false since `WIN64_ODIN` was added, and
	// the measurement needs no runner anyway:
	//
	//     windows_amd64  -> (i64, f64)  double @g2(ptr, ptr context)
	//                    -> (i64,i64,i64) i64  @g4(ptr, ptr, ptr context)
	//     linux_amd64    byte-for-byte identical
	//
	// A hidden pointer per earlier result with the last in the return
	// register: TRAILING_POINTERS. SINGLE was refusing 5 of 7 `--multi` cases
	// on a primary target for a reason that had stopped being true.
	multi_return = .TRAILING_POINTERS,
	assign_mode  = .POSITIONAL,
	shadow_space = 32,
	int_regs     = WIN64_INT[:],
	float_regs   = WIN64_SSE[:],
	ret_int_regs   = WIN64_RET_INT[:],
	ret_float_regs = WIN64_RET_SSE[:],
	// A 32-byte vector RESULT comes back in xmm0:xmm1 even though a scalar
	// float uses xmm0 alone. Arguments are untouched -- they stay indirect at
	// every width, which is the MSDN rule and the asm.
	max_vector_bytes = 16,
	ret_vector_regs  = X86_RET_VEC[:],
	word_size    = 8,
	max_by_value = 8,
	over_max     = .INDIRECT,
	stack_align  = 8,
}

// ---------------------------------------------------------------------------
// Typed seams
//
// `Piece.reg` is a `u16` because the shared vocabulary cannot name a per-arch
// type. Reading it through these keeps the cast in ONE place per architecture
// instead of at every call site -- review's point that an untyped seam between
// two correct components is this project's recurring failure mode.

reg :: proc(p: abi.Piece) -> x86.Register { return x86.Register(p.reg) }

// layout supplies this architecture's classifier to the shared signature loop.
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

// layout_win64 is the same for the Windows row, which has its own classifier.
layout_win64 :: proc(params, results: []abi.Param, conv: ^abi.Convention,
                     allocator := context.allocator, n_fixed := -1) -> (abi.Call_Layout, bool) {
	return abi.classify_signature(classify_win64, params, results, conv, allocator, n_fixed)
}
