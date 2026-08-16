package rexcode_abi

import "base:runtime"


// Signature-level layout: the loop, inside the library.
//
// Every consumer of `classify` + `assign` writes the same sequence -- classify
// each parameter, assign each, place the hidden return pointer, thread the
// implicit context, track the state across all of it. That loop is exactly
// where sequencing bugs live, and this package's own history says so: the type
// sweep could not see sequencing at all, and it took a separate instrument with
// its own controls to find that RISC-V spills floats into the integer file and
// that an indirect argument's pointer consumes a slot.
//
// Writing that loop once per backend re-opens the divergence the package exists
// to close. So it lives here, and the instruments drive it rather than a
// hand-rolled copy.
//
// `classify` is taken as a PROCEDURE rather than imported, which keeps this file
// independent of the per-arch packages -- `abi` must not depend on `abi/x86_64`,
// or the layering that lets a backend take `isa/` alone stops holding. Each arch
// package exports a one-line wrapper that supplies its own.
//
//
// TWO ROUTES TO A `Param`, and the shorter one is not the one documented first.
//
// Reported from outside: `param_from_desc` builds a `Type_Desc` TREE, it is the
// heavier route, and it is what the file leads with -- so a backend that already
// has a flat type table may not notice it can skip `Type_Desc` entirely. Stated
// here, before either:
//
//   FLAT LEAVES -- you already know the offsets, sizes and classes.
//       p := param_aggregate(size, align, my_fields)
//       p := param_scalar(size, align, Reg_Class.INTEGER)
//   Nothing walks a tree; `Field` is the whole vocabulary. Most backends with a
//   lowered type table are here.
//
//   A TYPE TREE -- you have nested source types and want the leaves derived.
//       p := param_from_desc(&desc)
//   This is the route that also derives the FLAGS from the same walk, which is
//   why it is recommended for a front end: `HAS_EMPTY_MEMBER` cannot be read off
//   the leaves (a zero-length member produces none), and building a Param from
//   `flatten` alone once left that flag unreachable through this entry point --
//   see the note on `param_scalar`'s `flags` below.
//
// So: flat table, use the constructors and set `flags` yourself if a member can
// be empty. Type tree, use `param_from_desc` and the flags come with it.

// Param_Shape has NO valid zero.
//
// This was `is_aggregate: bool`, so a zero-initialised Param claimed SCALAR --
// and scalar-vs-aggregate is precisely the distinction the field exists for:
// `f32` goes in xmm0 on Win64 and `struct{f32}` goes in an integer register.
// The silent default was wrong for the only case that needs the field.
//
// That is the unclaimed-default hazard, and it is on record twice in this
// project's consumer: procedure values and typeids fell into the aggregate
// branch because nothing claimed them, and the refusal then described what the
// compiler believed rather than what was missing. An enum whose zero is INVALID
// makes the unclaimed case loud instead of plausible.
Param_Shape :: enum u8 {
	INVALID,
	SCALAR,
	AGGREGATE,
	// An aggregate whose members OVERLAP.
	//
	// Distinct from AGGREGATE because one ABI asks: RISC-V never applies its
	// hardware floating-point rules to a union. The classifier used to infer it
	// by looking for overlapping leaves, which works for two members and cannot
	// work for one -- `union{f32}` and `struct{f32}` have byte-identical field
	// lists, and clang passes the first in a0 and the second in fa0. Inference
	// had no way to tell them apart, so the fact has to be carried.
	UNION,
}

// Param describes one declared parameter or result, already laid out.
//
// Prefer `param_scalar` / `param_aggregate` to building this literally.
Param :: struct {
	size:   u32,
	align:  u32,
	fields: []Field, // flattened leaves; see flatten.odin
	shape:  Param_Shape,
	// Facts the leaves cannot carry. See `Param_Flag`.
	flags:  Param_Flags,
}

// natural_align is the alignment the ABIs' alignment rules key on, which is
// NOT the type's declared alignment.
//
// AAPCS64 §4.3 and AAPCS32 both say the register-pair and stack-slot rules use
// a type's *unadjusted* alignment -- what its members require -- so
// `__attribute__((aligned(16))) struct{long,long}` is NOT even-aligned even
// though it declares 16, while a bare `__int128` is. Measured on both:
//
//     f(int a, __int128 b, int c)                 aarch64 -> w0, x2:x3, w4
//     f(int a, aligned(16) struct{long,long}, int) aarch64 -> w0, x1:x2, w3
//
// It needs no new field: the leaves already carry their own alignment, and the
// widest of them IS the unadjusted alignment. Deriving it beats adding a second
// alignment to `Param` that a caller could set inconsistently with the first.
// stamp_size records the object's size on whichever Location variant carries
// one. `Stack` already has a size, set by the classifier from the same number.
@(private)
stamp_size :: proc(loc: ^Location, size: u32) {
	// `v` is a copy in a value switch and immutable; take it, edit it, put it
	// back.
	if d, is_d := loc.(Direct); is_d {
		d.size = size
		loc^ = d
		return
	}
	if n, is_n := loc.(Indirect); is_n {
		n.size = size
		loc^ = n
	}
}

// Layout_Problem says WHY a signature was refused.
//
// `classify_signature` returned a bare `false`, so a backend could not tell
// "this shape is INVALID" from "field 7 has align 0" -- and the second is
// usually the caller's bug in building the Param, which a reason turns from a
// mystery into a one-line fix. The exit is the same; only the diagnosis differs.
Layout_Problem :: enum u8 {
	NONE,
	NO_CONVENTION,   // nil, or a convention with no word size
	INVALID_SHAPE,   // Param_Shape.INVALID -- an unset Param
	EMPTY_FIELDS,    // size > 0 with no leaves at all
	BAD_FIELDS,      // validate_fields refused; see `field_problem`
	MULTI_UNSUPPORTED, // several results on a platform with no protocol
	POOL_FAILED,     // the piece pool could not be allocated
	// Any OTHER allocation failed -- the `args`, `implicit` or `ret_ptrs`
	// slice. Only the piece pool was checked, and its own comment says why
	// ("an OOM that reports success is worse than one that crashes") while the
	// four beside it went unchecked: a failed `make` yields a nil slice, and
	// the very next line indexes it. Same reasoning, four sites over.
	ALLOC_FAILED,
	// A classifier DECLINED. `Location` is a union whose nil has no variant,
	// and `Call_Layout.result` is nil for a void procedure too -- so without
	// this the two are indistinguishable and a backend that switches on the
	// union without a `case nil` compiles clean and drops the result.
	CLASSIFIER_REFUSED,
	BAD_ALIGN,       // a Param's own align is zero or not a power of two
}

// check_param is the per-Param half, kept separate so both loops read the same.
@(private)
check_param :: proc(p: Param) -> Layout_Problem {
	if p.shape == .INVALID { return .INVALID_SHAPE }
	// A Param with SIZE and no FIELDS classifies as nothing at all: SysV
	// answers `Direct{pieces = []}` with ok = true, so an eight-byte argument
	// occupies no register and no stack, and the next argument still takes the
	// first register. The three classifiers do not even agree on it -- AArch64
	// and RISC-V return ceil(size/word) pieces, because their size rule never
	// consults the fields. Same hazard as `Param_Shape.INVALID`, and it had no
	// guard.
	if p.size > 0 && len(p.fields) == 0 { return .EMPTY_FIELDS }
	// The PARAM's own align, not just its leaves'. `validate_fields` checks
	// every Field and never looked at this one, and `natural_align` returns
	// `min(max leaf align, p.align)` -- so a forgotten `align` silently yields
	// 0 and every alignment rule in `assign` is skipped. On AAPCS64 that moves
	// an `__int128` from x2:x3 to x1:x2 and shifts every argument after it,
	// with ok = true. Exactly the hazard `Param_Shape.INVALID` exists to stop,
	// one field over.
	if p.size > 0 && (p.align == 0 || (p.align & (p.align - 1)) != 0) { return .BAD_ALIGN }
	if prob, _ := validate_fields(p.size, p.fields); prob != .NONE { return .BAD_FIELDS }
	return .NONE
}

natural_align :: proc(p: Param) -> u32 {
	n := u32(0)
	for f in p.fields { n = max(n, f.align) }
	if n == 0 { return p.align }
	return min(n, p.align)
}

// The `flags` parameter is OPTIONAL and defaults to none -- and that default is
// the hazard this comment exists for.
//
// `Param.flags` was added, read at four sites, and assigned by NOTHING. Every
// constructor left it `{}`, whose meaning is "no empty member" = "eligible to be
// a homogeneous aggregate". So the zero-length-array rule reached the classifier
// on the sweep's direct-call path -- which sets it by hand -- and could not
// reach it through `classify_signature` at all. A backend laying out
// `struct{z: [0]f32, a,b,c,d: f32}` the intended way got four S-registers on
// AAPCS64 where the ABI says two X-registers, silently.
//
// That is this project's own standing rule -- a field declared and not consumed
// has turned out wrong, now nine times out of nine -- broken by the change that
// cited it. `param_from_desc` below is the fix that matters: it connects the
// procedure that COMPUTES the fact to the one that carries it, so a caller
// cannot forget.
// TWO forms, chosen by the third argument, because a scalar has exactly one
// field and spelling that as a slice is both noise and a hazard.
//
// Raised from outside as ergonomics -- "`param_scalar(size, align, class)` would
// remove a slice literal from the hottest call in a backend" -- and the
// ergonomic complaint is the smaller half. A slice literal borrows the CURRENT
// FRAME, so one handed to a constructor whose result outlives the expression
// dangles, and Odin diagnoses that on a `return` and not at the call. This
// project has hit it three times in its own code (the type universe's member
// lists, the return-register name tables, the return-case list) and wrote a
// helper each time. A consumer writing
//
//     p := abi.param_scalar(8, 8, {{size = 8, align = 8, class = .INTEGER}})
//
// has written the same bug, in the API's own documented shape.
//
// The class form takes an allocator for the one-element list, which is what the
// package already is: `param_from_desc` allocates the same way, and §1 of the
// doc comment says this is an ARENA API. One bump allocation per scalar.
//
// The slice form stays for a caller that already HAS its leaves -- a backend
// with a flat type table hands over a subslice and allocates nothing -- and for
// regularity with `param_aggregate`.
param_scalar :: proc{param_scalar_fields, param_scalar_class}

param_scalar_fields :: proc(size, align: u32, fields: []Field, flags := Param_Flags{}) -> Param {
	return Param{size = size, align = align, fields = fields, shape = .SCALAR, flags = flags}
}

param_scalar_class :: proc(
	size, align: u32,
	class: Reg_Class,
	flags := Param_Flags{},
	allocator := context.temp_allocator,
) -> Param {
	fs := make([]Field, 1, allocator)
	fs[0] = Field{offset = 0, size = size, align = align, class = class}
	return Param{size = size, align = align, fields = fs, shape = .SCALAR, flags = flags}
}

param_aggregate :: proc(size, align: u32, fields: []Field, flags := Param_Flags{}) -> Param {
	return Param{size = size, align = align, fields = fields, shape = .AGGREGATE, flags = flags}
}

// param_from_desc builds a Param from a Type_Desc, flattening the leaves AND
// deriving the flags from the SAME walk.
//
// This is the entry point a front end should use. Building a Param by hand from
// `flatten` alone is how `HAS_EMPTY_MEMBER` came to be unreachable: the leaves
// cannot carry it, `desc_flags` computes it, and nothing joined the two. Here
// they cannot come apart.
param_from_desc :: proc(t: ^Type_Desc, allocator := context.temp_allocator) -> Param {
	fs := make([dynamic]Field, allocator)
	flatten(t, &fs)
	shape := Param_Shape.AGGREGATE
	#partial switch t.kind {
	case .SCALAR: shape = .SCALAR
	case .UNION:  shape = .UNION
	}
	return Param{
		size = t.size, align = t.align, fields = fs[:],
		shape = shape, flags = desc_flags(t),
	}
}

// param_union is an aggregate whose members overlap. See Param_Shape.UNION.
param_union :: proc(size, align: u32, fields: []Field, flags := Param_Flags{}) -> Param {
	return Param{size = size, align = align, fields = fields, shape = .UNION, flags = flags}
}

// tuple_param lays several results out as ONE anonymous struct.
//
// This is the object the tuple-packing protocols actually return, so it is
// built by the ordinary struct rules and then handed to the ordinary
// classifier: fields in declaration order, each at its natural alignment, the
// whole rounded up to the widest member's alignment. Nothing here is
// Odin-specific -- it is what any language's result tuple is.
//
// Measured against the reference compiler on three targets: `(i8, f64)` comes
// out 16 bytes aligned 8 (riscv64 emits `{i8, double}`, AArch64 the coerced
// `[2 x i64]`), and `(i32, i32, i32)` comes out 12 aligned 4.
@(private)
tuple_param :: proc(results: []Param, allocator := context.temp_allocator) -> Param {
	n := 0
	align := u32(1)
	for r in results {
		n += len(r.fields)
		align = max(align, r.align)
	}
	fields, ferr := make([]Field, n, allocator)
	// A failed tuple allocation yielded a nil field slice, and the loop below
	// wrote into it. Reported as an INVALID shape, which is what the caller
	// then sees and refuses on -- `tuple_param` has no error channel of its
	// own, and inventing one for an OOM path is more surface than the case
	// deserves.
	if ferr != nil { return Param{} }
	off := u32(0)
	k := 0
	for r in results {
		if r.align > 0 { off = (off + r.align - 1) / r.align * r.align }
		for f in r.fields {
			fields[k] = f
			fields[k].offset = off + f.offset
			k += 1
		}
		off += r.size
	}
	size := (off + align - 1) / align * align
	return param_aggregate(size, align, fields)
}

// Facts about a Param that its SIZE, ALIGNMENT and LEAVES cannot express.
//
// A bit set rather than more bools. `classify` took `is_aggregate: bool,
// is_union: bool` adjacent and positional, and the sweep passed them as two
// derived expressions in a row -- a caller that swaps them compiles clean and
// gets Win64 and RISC-V both wrong. That is the footgun shape this package is
// supposed to be free of, and the next fact would have made it three.
Param_Flag :: enum u8 {
	// The aggregate has a member occupying NO BYTES -- Odin's `[0]T`, C's
	// zero-length array extension.
	//
	// Cannot be inferred from the leaves, because such a member produces none:
	// `struct{z: [0]f32, a,b,c,d: f32}` and `struct{a,b,c,d: f32}` have
	// identical field lists, identical size and identical alignment. The fact
	// has to be CARRIED, for the same reason `UNION` does.
	//
	// It matters on AAPCS64 and AAPCS32, where such a member disqualifies a
	// homogeneous aggregate, and NOWHERE ELSE -- RISC-V and SysV ignore it. So
	// it is a property of the type that each convention decides what to do
	// with, not a classification.
	HAS_EMPTY_MEMBER,
	// The parameter is a COMPLEX -- C's `_Complex T`, Odin's `complex64` /
	// `complex128`.
	//
	// Here for exactly the reason the flag above is: it cannot be inferred
	// from the leaves. A complex and a struct of two same-typed floats have
	// identical field lists, identical size and identical alignment, and at
	// least one ABI gives them DIFFERENT answers. Measured on i386, clang
	// 22.1.8:
	//
	//     _Complex float      (8)   movl gcf,%eax / movl gcf+4,%edx   eax:edx
	//     struct{float,float} (8)   movl 4(%esp),%eax / ... retl $4   SRET
	//
	// So no amount of looking at the fields can tell them apart, and the fact
	// has to be carried. `Convention.complex_ret_int_max` is what reads it.
	IS_COMPLEX,
}
Param_Flags :: bit_set[Param_Flag; u8]

Classify_Proc :: #type proc(
	size, align: u32,
	fields: []Field,
	conv: ^Convention,
	pos: Position,
	// The SHAPE, not two booleans derived from it. `is_aggregate` was
	// `shape != .SCALAR` and `is_union` was `shape == .UNION` at every call
	// site, so passing the enum removes a derivation the caller could get
	// wrong and an ordering it could swap.
	shape: Param_Shape,
	flags: Param_Flags,
	buf: []Piece, // caller-owned scratch; classify allocates nothing
) -> Location

// Call_Layout is the whole calling sequence, in the order the ABI builds it.
//
// The field order here IS the argument order, which is the part a backend most
// needs and most easily gets wrong. For Odin on x86-64 that order is established
// at mir_design.md:474 by disassembling `mv::three`:
//
//     [sret]  declared args  ret_ptrs(0..n-2)  context
//
// with the LAST declared result coming back in registers. Two things that
// ordering pins down which guessing does not: the context comes after the return
// pointers, not before them, and it is the last result in RAX rather than the
// first.
Call_Layout :: struct {
	// Why the layout was refused, when `ok` is false. `.NONE` on success.
	//
	// Carried on the struct rather than as a third return value so existing
	// call sites keep compiling: a caller that only wants "did it work" still
	// reads `ok`, and one that wants to fix its input reads this.
	problem:    Layout_Problem,
	problem_at: int, // index of the offending param or result

	// The hidden pointer for a memory-class result, when there is one. It is
	// assigned FIRST and so consumes the first integer slot.
	sret: Maybe(Location),

	// One per declared parameter, in source order.
	args: []Location,

	// Odin returns several values by putting the LAST in registers and passing
	// a hidden pointer for each earlier one, appended after the declared
	// arguments. `ret_ptrs[i]` is where the pointer to result `i` travels.
	//
	// Modelled here rather than in a frontend because it is
	// CONVENTION-determined: `proc "c"` has no such thing, and a backend that
	// hardcodes the Odin order cannot then emit a C call. That was an open
	// question in review and this is the answer to it.
	ret_ptrs: []Location,

	// The language's own hidden arguments -- Odin's `^Context` -- placed last.
	implicit: []Location,

	// How the result comes back. `Sret` here means the caller supplies storage
	// and `sret` above says where the pointer goes.
	//
	// WHICH result this describes depends on `result_is_tuple`.
	result: Location,

	// Whether `result` describes ALL the results packed into one anonymous
	// struct, rather than just the last one.
	//
	// True only for a multi-value call on a platform whose `Multi_Return` packs
	// the tuple -- see that enum for the three protocols and where each was
	// measured. When true, `ret_ptrs` is empty and `result`'s pieces carry the
	// whole tuple at its struct offsets; when false, `result` is the LAST
	// result and every earlier one travels through `ret_ptrs`.
	//
	// A flag rather than something a consumer infers from `len(ret_ptrs) == 0`,
	// because that test is also true of an ordinary single-result call and the
	// two need different code.
	result_is_tuple: bool,

	// Bytes of outgoing argument area the caller must reserve, shadow space
	// included.
	stack_size: u32,

	// Vector registers used by the VARIADIC part, which x86-64 SysV requires
	// the caller to place in AL before the call so `va_start` knows whether to
	// spill them. Zero on every other platform. Measured: `v(1, 2, 3.5, 4,
	// 5.5)` emits `movb $2, %al`.
	varargs_sse_count: u8,
}

// classify_signature lays out one call.
//
// `results` may be empty (a procedure returning nothing), one (the ordinary
// case), or several (Odin multi-value).
//
// ALLOCATION. The allocator owns FIVE blocks, not the three a caller can reach:
// `args`, `ret_ptrs` and `implicit` have handles in the returned layout, and the
// piece pool and (for a packed tuple) the tuple's field list do NOT. Every
// `Direct.pieces` in the layout is a slice of that pool, so freeing the three
// reachable slices leaks the other two.
//
// This is therefore an ARENA API, not merely arena-friendly: pass a per-function
// arena and the whole layout dies with the function, which is what
// mir_design.md §6 asks of everything in the pipeline. Passing a general-purpose
// allocator and freeing the visible slices is a leak, and the doc used to say
// "three slices" as though it were not.
// Returns ok = false if any Param is malformed -- shape INVALID, meaning the
// caller built it literally and never said what it is. Refusing beats guessing:
// guessing is what makes a wrong answer look like a considered one.
// `n_fixed` is how many leading params are NAMED. Anything after is variadic and
// the convention's `varargs` rule applies to it. Pass `len(params)` -- or leave
// it negative, which means the same -- for a non-variadic call.
classify_signature :: proc(
	cls: Classify_Proc,
	params: []Param,
	results: []Param,
	conv: ^Convention,
	// DEFAULTS TO THE TEMP ALLOCATOR, and the default used to be
	// `context.allocator` -- the one mode this package's own documentation says is
	// wrong.
	//
	// A consuming backend measured it cold: 100 layouts against a tracking
	// allocator left 200 live allocations and 19200 bytes held, silently, with
	// correct answers throughout. Nothing here frees a `Call_Layout` and there is
	// no `layout_destroy`, because the visible slices are not the whole
	// allocation -- so a caller cannot hand-free it correctly either.
	//
	// A per-call layout is exactly what a temp allocator is for. A caller wanting
	// an arena still passes one, and now the EASY thing is a correct thing rather
	// than the documented mistake.
	allocator := context.temp_allocator,
	n_fixed := -1,
) -> (out: Call_Layout, ok: bool) {
	fixed := n_fixed < 0 ? len(params) : n_fixed
	// Refuse a malformed Param before classifying it.
	//
	// `validate_fields` was exported, documented as "cheap enough to call from a
	// debug build on every signature", and called by NOTHING in this package --
	// the classifiers took whatever field list they were given. A list
	// inconsistent with `size` was silently truncated instead of refused:
	// `classify(size = 8, fields = [{0,8},{8,8}])` under SysV returned one piece
	// and dropped the second field.
	//
	// It checks only what is never right -- a leaf past the end, a zero-width
	// leaf, a nonsense alignment -- so overlap (a union) and gaps (padding)
	// still pass.
	// A NIL convention is refused HERE, where the reason can be said.
	//
	// `pieces_needed` used to return 0 for it, handing every classifier a
	// zero-length buffer to write into -- a heap fault two hundred lines from
	// the mistake -- and `assign_begin` then dereferenced the nil anyway. The
	// buffer now gets the floor of two and the error is reported at the entry
	// point instead of crashing inside one.
	if conv == nil || conv.word_size == 0 {
		out.problem = .NO_CONVENTION
		return
	}
	for p, i in params {
		if pr := check_param(p); pr != .NONE {
			out.problem, out.problem_at = pr, i
			return
		}
	}
	for r, i in results {
		if pr := check_param(r); pr != .NONE {
			out.problem, out.problem_at = pr, i
			return
		}
	}

	st := assign_begin(conv)

	// ONE block for every piece in the call, carved below. This is what the
	// per-argument allocation it replaced could not offer, and what
	// `Direct.pieces` documents.
	// The multi-value refusal comes BEFORE the pool is allocated. It used to sit
	// after, so a convention with no multi-value protocol leaked the pool on
	// every refusal.
	if len(results) > 1 && conv.multi_return == .SINGLE {
		out.problem = .MULTI_UNSUPPORTED
		return
	}

	multi := len(results) > 1
	// The packed tuple is a further object needing pieces of its own, so it is
	// counted here rather than assumed to fit inside what the results reserved.
	tup: Param
	if multi && (conv.multi_return == .TUPLE_ELSE_POINTERS || conv.multi_return == .TUPLE_ALWAYS) {
		tup = tuple_param(results, allocator)
	}

	total := 0
	for p in params  { total += pieces_needed(conv, p.size) }
	for r in results { total += pieces_needed(conv, r.size) }
	if tup.shape != .INVALID { total += pieces_needed(conv, tup.size) }
	// ALLOCATION FAILURE is checked. `make` returns an runtime.Allocator_Error that was
	// being dropped, and on failure `pool` is nil -- whereupon `take` slices a
	// nil slice, every argument gets an empty piece buffer, and the layout comes
	// back `ok = true` describing a call in no registers at all. An OOM that
	// reports success is worse than one that crashes.
	pool, perr := make([]Piece, total + len(conv.implicit) + len(results), allocator)
	if perr != nil {
		out.problem = .POOL_FAILED
		return
	}
	// `take` bounds itself. It sliced `pool^[:n]` with no check, so any
	// arithmetic error in `total` above became an out-of-range slice rather than
	// a diagnosable refusal -- and `total` is a sum over four different
	// `pieces_needed` calls.
	// `pool_take` bounds itself. It sliced `pool^[:n]` with no check, so any
	// arithmetic error in `total` above became an out-of-range slice rather
	// than a diagnosable failure -- and `total` is a sum over four separate
	// `pieces_needed` calls. Exhaustion sets `overran`, which the caller turns
	// into POOL_FAILED; returning a short slice would let a classifier write a
	// truncated answer and call it complete.
	overran := false
	pool_take :: proc(pool: ^[]Piece, n: int, overran: ^bool) -> []Piece {
		if n < 0 || n > len(pool^) { overran^ = true; return nil }
		s := pool^[:n]
		pool^ = pool^[n:]
		return s
	}

	// 1. The result, first, because a memory-class one consumes the first
	//    integer slot before any declared argument sees the register file.
	// A convention with no multi-value protocol cannot describe more than one
	// result; refusing beats silently classifying only the last.
	// A tuple-packing platform classifies all the results as ONE struct. It
	// keeps that answer unless the struct came back memory-class AND the
	// platform has the pointer fallback, in which case this is discarded and
	// the ordinary last-result path below runs instead.
	if tup.shape != .INVALID {
		loc := cls(tup.size, tup.align, tup.fields, conv, .RETURN, tup.shape, tup.flags,
			pool_take(&pool, pieces_needed(conv, tup.size), &overran))
		assign_result(&loc, conv)
		mem := false
		#partial switch _ in loc {
		case Sret, Stack, Indirect: mem = true
		}
		if mem && conv.multi_return == .TUPLE_ELSE_POINTERS {
			tup = Param{} // shape INVALID: fall back to trailing pointers
		} else {
			out.result = loc
			stamp_size(&out.result, tup.size)
			out.result_is_tuple = true
		}
	}

	if tup.shape != .INVALID {
		// The packed tuple stands. Only a hidden pointer may still be needed.
		#partial switch _ in out.result {
		case Sret, Stack, Indirect:
			al := max(tup.align, conv.word_size)
			if dedicated, has := conv.sret_reg.?; has {
				out.sret = Location(Indirect{reg = dedicated, in_reg = true, align = al, size = tup.size})
			} else {
				loc := Location(Indirect{align = al, size = tup.size})
				assign(&loc, conv, &st)
				out.sret = loc
			}
		}
	} else if len(results) > 0 {
		last := results[len(results) - 1]
		out.result = cls(last.size, last.align, last.fields, conv, .RETURN,
			last.shape, last.flags,
			pool_take(&pool, pieces_needed(conv, last.size), &overran))
		// Registers for a value-returned result, from the RETURN files.
		if out.result == nil {
			// The classifier declined. Reported, not returned as a layout that
			// looks like a void procedure's.
			out.problem = .CLASSIFIER_REFUSED
			out.problem_at = len(results) - 1
			return out, false
		}
		assign_result(&out.result, conv)
		stamp_size(&out.result, last.size)
		#partial switch _ in out.result {
		case Sret, Stack, Indirect:
			al := max(last.align, conv.word_size)
			if dedicated, has := conv.sret_reg.?; has {
				// A dedicated register (AAPCS64's x8). It is outside the
				// argument file, so `assign` is deliberately NOT called: the
				// pointer consumes no slot and the declared arguments below
				// still start at the first integer register.
				out.sret = Location(Indirect{reg = dedicated, in_reg = true, align = al, size = last.size})
			} else {
				loc := Location(Indirect{align = al, size = last.size})
				assign(&loc, conv, &st)
				out.sret = loc
			}
		}
	}

	// 1b. Implicit arguments the language wants FIRST, before any declared one.
	if len(conv.implicit) > 0 {
		ierr: runtime.Allocator_Error
		out.implicit, ierr = make([]Location, len(conv.implicit), allocator)
		if ierr != nil { out.problem = .ALLOC_FAILED; return }
		for im, i in conv.implicit {
			if im.position != .FIRST { continue }
			ps := pool_take(&pool, 1, &overran)
			ps[0] = make_piece(im.class, 0, conv.word_size)
			out.implicit[i] = Location(Direct{pieces = ps, size = conv.word_size})
			assign(&out.implicit[i], conv, &st)
		}
	}

	// 2. Declared arguments, in source order.
	if len(params) > 0 {
		aerr: runtime.Allocator_Error
		out.args, aerr = make([]Location, len(params), allocator)
		if aerr != nil { out.problem = .ALLOC_FAILED; return }
		for p, i in params {
			variadic := i >= fixed && conv.varargs != .NONE
			pbuf := pool_take(&pool, pieces_needed(conv, p.size), &overran)
			out.args[i] = cls(p.size, p.align, p.fields, conv, .ARGUMENT,
				p.shape, p.flags, pbuf)
			// Stamp the OBJECT size onto the Location, in ONE place.
			//
			// Every classifier would otherwise have to remember to set it on
			// every construction site, and a site that forgot would leave 0 --
			// a value that reads as valid. Doing it here means every Location
			// this package hands out is complete, and there is exactly one line
			// to get wrong instead of a dozen.
			if out.args[i] == nil {
				out.problem, out.problem_at = .CLASSIFIER_REFUSED, i
				return out, false
			}
			stamp_size(&out.args[i], p.size)

			// Darwin AArch64 puts every variadic argument on the stack, so the
			// register files are never consulted for them.
			if variadic && conv.varargs == .ALL_STACK {
				// A VARIADIC stack slot is a whole WORD, even where named
				// arguments pack. Darwin has both rules at once and they are
				// not the same rule:
				//
				//   named     add x0, sp, #1        packed, stack_align = 1
				//   variadic  stp x9, x8, [sp]      offsets 0,8,16,24,32,40
				//             stp x9, x8, [sp,#16]
				//
				// `slot_align` is 1 on this row -- correct, and measured, for
				// NAMED arguments -- so reusing it here packed the variadics
				// too and put five of six at the wrong offset. Nothing caught
				// it because this path is Darwin-only and Darwin is not
				// executed.
				// The ARGUMENT'S OWN alignment, not a flat word.
				//
				// This was `max(slot_align, word_size)` for every variadic
				// argument, so a 16-aligned one got an 8-byte slot. Measured on
				// arm64-apple-darwin, `v(1, (char)2, (__int128)3, (char)4)`:
				//
				//     str  x8, [sp]        char  @ sp+0
				//     str  x8, [sp, #16]   i128  @ sp+16   -- sp+8 is PADDING
				//     stp xzr, x8, [sp,#24] i128 high @24, char @ sp+32
				//
				// The model put the i128 at sp+8 and the trailing char at
				// sp+24, so every argument after a 16-aligned one was eight
				// bytes out. Darwin's variadic area packs SMALL arguments -- the
				// char really is one byte -- and still honours a large
				// alignment, which is why the floor and the type's own value
				// are both needed.
				//
				// `stack_arg_align_max` caps it for the same reason it caps the
				// named path: a row that never over-aligns says so there.
				al := max(slot_align(conv), conv.word_size)
				if na := natural_align(p); na > al {
					al = na
					if conv.stack_arg_align_max > 0 && al > conv.stack_arg_align_max {
						al = conv.stack_arg_align_max
					}
				}
				// An INDIRECT argument stays indirect. Only its POINTER moves
				// to the stack.
				//
				// The else-branch below used to swallow it and emit a
				// `Stack{size = p.size}` -- a by-value copy of the whole object
				// where the classifier said pointer. Measured on
				// arm64-apple-darwin, passing a 32-byte struct variadically:
				//
				//     add x9, sp, #16     ; the address of the copy
				//     stp x9, x8, [sp]    ; the POINTER at sp+0, next arg sp+8
				//
				// so it occupies ONE word. Treating it as 32 bytes put every
				// later variadic argument 24 bytes along, and handed the callee
				// a struct where it expects a pointer to one.
				if ind, is_ind := out.args[i].(Indirect); is_ind {
					pa := max(al, conv.word_size)
					st.stack_off = (st.stack_off + pa - 1) / pa * pa
					ind.in_reg = false
					ind.offset = st.stack_off
					out.args[i] = ind
					st.stack_off += conv.word_size
					continue
				}
				sz := u32(0)
				if d, is_d := out.args[i].(Direct); is_d {
					for k in 0 ..< len(d.pieces) { sz += u32(piece_width(d.pieces[k])) }
					// Padding is absent from the pieces; the FOOTPRINT is the
					// object. Same trap as `assign`'s spill path.
					if d.size > sz { sz = d.size }
				} else {
					sz = p.size
				}
				st.stack_off = (st.stack_off + al - 1) / al * al
				sz = (sz + al - 1) / al * al
				out.args[i] = Stack{size = sz, align = al, offset = st.stack_off}
				st.stack_off += sz
				continue
			}

			// RISC-V and AAPCS32 pass variadic floats in INTEGER registers,
			// which means the value is passed AS IF it were an integer object
			// of the same size -- not the same pieces relabelled.
			//
			// The difference is the whole bug: a variadic `double` is ONE piece
			// of width 8, and relabelling it INTEGER predicted one register.
			// On a four-byte word it needs TWO, so `v(1, 2, 3.25, ...)` on
			// armv7 is `vmov r2, r3, d16` -- a pair. Re-classifying by words
			// gets that; recolouring the class does not.
			//
			// `Borrowed` still records that the VALUE is a float, which a
			// consumer needs in order to move the bits correctly.
			if variadic && conv.varargs == .INT_REGS {
				if d, is_d := out.args[i].(Direct); is_d {
					has_float := false
					for k in 0 ..< len(d.pieces) {
						if d.pieces[k].class == .FLOAT || d.pieces[k].class == .VECTOR {
							has_float = true
						}
					}
					if has_float {
						// ADOPTING the integer convention means adopting its
						// SIZE RULE too, not only its register file.
						//
						// RISC-V passes an aggregate above two XLEN by
						// reference. On LP64D a 16-byte struct is exactly two
						// words and fits, which is why this was invisible; on
						// ILP32D it is FOUR, and the model put it in a0-a3.
						// Measured -- `v(1, 2, struct{double,double}, 9)`:
						//
						//   riscv32 ilp32d   ptr dead_on_return   BY REFERENCE
						//   riscv64 lp64d    [2 x i64]            in registers
						//
						// so the trailing 9 went to a6 where clang puts it in
						// a3. This is the same half-adopted reversion the NAMED
						// path already fixed once (`assign`'s revert branch
						// carries the by-reference rule); the variadic path
						// relabelled the pieces and skipped it.
						if conv.over_max == .INDIRECT || conv.max_by_value > 0 {
							lim := conv.max_by_value
							if lim > 0 && p.size > lim {
								out.args[i] = Indirect{align = max(natural_align(p), conv.word_size),
									size = p.size}
								assign(&out.args[i], conv, &st)
								stamp_size(&out.args[i], p.size)
								continue
							}
						}
						nw := (p.size + conv.word_size - 1) / conv.word_size
						if int(nw) <= len(pbuf) {
							for k in 0 ..< nw {
								w := p.size - k * conv.word_size
								if w > conv.word_size { w = conv.word_size }
								pbuf[k] = make_piece(.INTEGER, k * conv.word_size, w)
								pbuf[k].flags += {.Borrowed}
							}
							out.args[i] = Direct{pieces = pbuf[:nw], size = p.size}
						}
					}
				}
			}

			// A variadic argument in the INTEGER file is pair-aligned on both
			// conventions that use that rule.
			assign(&out.args[i], conv, &st, natural_align(p),
				variadic && conv.varargs == .INT_REGS, pbuf, p.shape != .SCALAR)

			if !variadic { continue }
			if d, is_d := out.args[i].(Direct); is_d {
				for k in 0 ..< len(d.pieces) {
					if d.pieces[k].class != .FLOAT && d.pieces[k].class != .VECTOR { continue }
					if conv.varargs == .SYSV_AL {
						out.varargs_sse_count += 1
					}
					if conv.varargs == .WIN64_DUPLICATE {
						// Also present in the integer register of the SAME
						// slot; the consumer recovers which from the slot, as
						// the float and integer files are positional here.
						d.pieces[k].flags += {.Also_Integer}
					}
				}
				out.args[i] = d
			}
		}
	}

	// 3. Hidden pointers for every result but the last, AFTER the declared
	//    arguments and BEFORE the context.
	//
	// Gated on the CONVENTION, not merely on the result count. This read
	// `len(results) > 1` alone, so it would have applied Odin's hidden-pointer
	// protocol to a C signature -- harmless only because C cannot return two
	// values, which makes it a rule that happened never to be asked rather than
	// a rule that was right. `multi_return` existed to say this and nothing
	// read it.
	// `result_is_tuple` excludes the packing platforms: they returned every
	// result in `result` and have nothing left to point at.
	if !out.result_is_tuple && conv.multi_return != .SINGLE && len(results) > 1 {
		n := len(results) - 1
		rerr: runtime.Allocator_Error
		out.ret_ptrs, rerr = make([]Location, n, allocator)
		if rerr != nil { out.problem = .ALLOC_FAILED; return }
		for i in 0 ..< n {
			ptr := Indirect{align = max(results[i].align, conv.word_size), size = results[i].size}
			out.ret_ptrs[i] = Location(ptr)
			assign(&out.ret_ptrs[i], conv, &st)
		}
	}

	// 4. The implicit arguments, at the position the LANGUAGE asks for.
	//
	// `Implicit_Arg.position` used to be written and never read: this step
	// appended unconditionally, so a `.FIRST` implicit argument -- the only case
	// the enum exists for -- would have been placed last without complaint. The
	// `context-first` control even implemented "prepend" in the HARNESS,
	// bypassing the one field that could have carried it, so the field's only
	// possible consumer was the thing that tested it.
	//
	// FIRST is placed before the declared arguments, which means its slot has
	// to be taken before step 2 runs; that is done above.
	if len(conv.implicit) > 0 {
		if out.implicit == nil {
			jerr: runtime.Allocator_Error
			out.implicit, jerr = make([]Location, len(conv.implicit), allocator)
			if jerr != nil { out.problem = .ALLOC_FAILED; return }
		}
		for im, i in conv.implicit {
			if im.position != .LAST { continue } // already placed, see step 1b
			ps := pool_take(&pool, 1, &overran)
			ps[0] = make_piece(im.class, 0, conv.word_size)
			out.implicit[i] = Location(Direct{pieces = ps, size = conv.word_size})
			assign(&out.implicit[i], conv, &st)
		}
	}

	out.stack_size = st.stack_off
	// An overrun means some argument got a nil buffer and was classified into
	// nothing. Reported rather than returned as a layout.
	if overran {
		out = Call_Layout{problem = .POOL_FAILED}
		return out, false
	}
	return out, true
}
