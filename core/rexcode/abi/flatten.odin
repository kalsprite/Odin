package rexcode_abi

// Flattening: the error-prone half, and the rules that make it so.
//
// `classify` takes `[]Field` -- one entry per scalar LEAF -- and review's point
// is fair: leaving every consumer to produce that list re-opens the divergence
// this package exists to close, and padding is where the bugs have actually
// been. Four rules are easy to state and easy to get wrong:
//
//   * padding contributes NOTHING. A gap is not a field, and a field list that
//     includes one classifies as INTEGER where the ABI says NO_CLASS;
//   * a UNION's members all sit at the SAME offset. A walk that assumes
//     increasing offsets produces a struct's answer for a union, which on
//     AArch64 is the difference between one register and two;
//   * an ARRAY's elements stride by element size, and each is a leaf;
//   * a NESTED aggregate contributes its leaves at base + inner offset, not as
//     one field of its own size.
//
// Two entry points. `flatten` takes a shallow description and applies the rules;
// `validate_fields` checks a list a caller produced some other way. Use either,
// but do not hand-roll the walk and hope.

Agg_Kind :: enum u8 {
	SCALAR,
	STRUCT,
	UNION,
	ARRAY,
}

// Type_Desc is a shallow, borrowed view of one type. It is not a type system --
// it holds only what classification needs, so a frontend can build one on the
// stack from whatever it already has.
Type_Desc :: struct {
	kind:       Agg_Kind,
	size:       u32,
	align:      u32,
	class:      Reg_Class, // SCALAR
	is_pointer: bool,      // SCALAR; only RISC-V distinguishes it
	members:    []Member,  // STRUCT, UNION
	elem:       ^Type_Desc, // ARRAY
	count:      u32,       // ARRAY
	// Whether this type is a COMPLEX -- C's `_Complex T`, Odin's `complex64` /
	// `complex128`.
	//
	// Here because without it `param_from_desc` -- the entry point this package
	// tells a front end to use -- CANNOT produce a correct Param for one, and
	// says nothing about that. `Param_Flag.IS_COMPLEX` explains at length that
	// the fact cannot be inferred from the leaves; `desc_flags` derives every
	// other flag from the tree; and the tree had no way to state this one. So
	// the recommended route silently gave `_Complex float` the answer for
	// `struct{float,float}`, which on i386 is the difference between eax:edx and
	// an sret pointer. Measured through `param_from_desc` on `i386-unknown-linux-gnu`:
	//
	//     flags {}             -> Sret
	//     flags {IS_COMPLEX}   -> Direct[INTEGER eax, INTEGER edx]
	//
	// A field on the tree rather than a `flags` parameter on `param_from_desc`,
	// because a parameter reopens exactly the join that lost
	// `HAS_EMPTY_MEMBER`: the leaves and the flags have to come from one walk,
	// or a caller can supply one without the other.
	//
	// Read at the TOP LEVEL ONLY -- see `desc_flags`. Raised from outside by a
	// consuming backend, which found it from its own side: its lowered type had
	// already dropped complex-ness before a Param was built.
	is_complex: bool,
}

Member :: struct {
	// Absolute within the ENCLOSING type -- `flatten` adds it to the base it
	// was called with, so a member's offset is relative to the aggregate that
	// declares it, not to the outermost one.
	//
	// A `UNION`'s members all carry 0, because that is what a union IS. That is
	// a consequence of the kind, NOT a restriction on this field: a consumer
	// read it as "members of a union may only be at 0" and was about to model
	// Odin's tagged union -- payload plus a trailing tag -- as a `UNION` to
	// obey it. The tag is a real leaf at a real offset and every classifier has
	// to see it there, so that type is `STRUCT{payload: UNION{...}, tag}` and
	// only the payload is the union. `flatten` OR-s `in_union` down the walk,
	// so the payload's leaves come out marked and the tag's do not.
	offset: u32,
	type:   ^Type_Desc,
}

// flatten appends one Field per scalar leaf, in declaration order.
//
// Declaration ORDER matters and is not incidental: RISC-V's float-plus-integer
// rule passes them in the order declared, so `struct{i8, f32}` and
// `struct{f32, i8}` differ.
flatten :: proc(t: ^Type_Desc, out: ^[dynamic]Field, base: u32 = 0, in_union := false) {
	switch t.kind {
	case .SCALAR:
		append(out, Field{
			offset     = base,
			size       = t.size,
			align      = t.align,
			class      = t.class,
			is_pointer = t.is_pointer,
			in_union   = in_union,
		})
	case .STRUCT, .UNION:
		// Still identical code for the OFFSETS -- a union's members carry
		// offset 0, so the same walk produces overlapping leaves. The one thing
		// that does branch is the flag: once inside a union every leaf below is
		// inside it, so the parameter is OR-ed rather than assigned, and a
		// struct nested in a union stays marked.
		for m in t.members {
			flatten(m.type, out, base + m.offset, in_union || t.kind == .UNION)
		}
	case .ARRAY:
		if t.elem == nil { return }
		for i in 0 ..< t.count {
			flatten(t.elem, out, base + i * t.elem.size, in_union)
		}
	}
}

// desc_flags reports the facts a flattened field list cannot carry.
//
// `flatten` produces one Field per scalar LEAF, and a zero-length array member
// produces none -- so a caller building a Param from a Type_Desc has no way to
// notice one, and neither does any classifier downstream. This walks the same
// tree for the things the leaves drop.
//
// Separate from `flatten` rather than an out-parameter: the two answer different
// questions, and a caller that only needs one should not be made to thread the
// other.
desc_flags :: proc(t: ^Type_Desc) -> Param_Flags {
	out := desc_flags_rec(t)
	// `is_complex` is read HERE and not inside the recursion, and the asymmetry
	// with `HAS_EMPTY_MEMBER` is the whole point: an empty member anywhere
	// disqualifies the aggregate that contains it, so that flag propagates
	// upward, while a complex NESTED in a struct is an ordinary aggregate to
	// every ABI surveyed. `struct{_Complex float}` is not a complex, and
	// OR-ing this down the walk would say it is.
	if t.is_complex { out += {.IS_COMPLEX} }
	return out
}

@(private)
desc_flags_rec :: proc(t: ^Type_Desc) -> Param_Flags {
	out: Param_Flags
	switch t.kind {
	case .SCALAR:
	case .ARRAY:
		// The member itself, then its element type.
		if t.count == 0 { out += {.HAS_EMPTY_MEMBER} }
		if t.elem != nil { out += desc_flags_rec(t.elem) }
	case .STRUCT, .UNION:
		for m in t.members { if m.type != nil { out += desc_flags_rec(m.type) } }
	}
	return out
}

Field_Problem :: enum u8 {
	NONE,
	OUT_OF_RANGE,   // a leaf extends past the type's size
	ZERO_SIZED,     // a leaf of no width; padding leaked into the list
	BAD_ALIGN,      // align is zero or not a power of two
	UNEXPECTED_GAP, // the leaves leave a hole, in a type declared gapless
	// The leaves are not in ascending offset order, so the coverage total this
	// procedure computes is not meaningful. Reported rather than turned into a
	// bogus UNEXPECTED_GAP, which blames the layout for an ordering problem.
	UNSORTED,
}

// validate_fields checks a field list a caller produced some other way.
//
// It cannot tell a correct list from a plausible one -- overlap is legal (that
// is a union) and gaps are legal (that is padding) -- so it checks the things
// that are never right: a leaf past the end, a zero-width leaf, a nonsense
// alignment. `expect_gapless` additionally asserts the leaves tile the type,
// which is true of any struct the caller believes has no padding, and is worth
// asserting precisely because a stray padding leaf is invisible otherwise.
//
// Cheap enough to call from a debug build on every signature.
validate_fields :: proc(size: u32, fields: []Field, expect_gapless := false) -> (Field_Problem, int) {
	covered := u32(0)
	hi := u32(0)
	for f, i in fields {
		if f.size == 0 { return .ZERO_SIZED, i }
		if f.align == 0 || (f.align & (f.align - 1)) != 0 { return .BAD_ALIGN, i }
		// The range test in 64 bits. `f.offset + f.size` is u32 arithmetic and
		// WRAPS: a leaf at offset 0xFFFFFFF8 of size 16 computes to 8, which is
		// inside any type, so the bound it exists to enforce was bypassable by
		// the one input most likely to be garbage.
		if u64(f.offset) + u64(f.size) > u64(size) { return .OUT_OF_RANGE, i }
		if f.offset + f.size > hi {
			// `covered` is only correct for leaves in ASCENDING offset order.
			// Out of order, a later leaf below `hi` adds nothing and the total
			// under-counts, so a gapless type reports UNEXPECTED_GAP -- a
			// refusal caused by the caller's ORDERING rather than by its
			// layout. Detected rather than silently miscounted; the walk stays
			// single-pass, since sorting would allocate.
			if f.offset < hi && hi > 0 && covered != hi {
				return .UNSORTED, i
			}
			covered += (f.offset + f.size) - max(hi, f.offset)
			hi = f.offset + f.size
		} else if f.offset < hi && expect_gapless {
			// Overlapping or out-of-order below the high-water mark. Legal for
			// a union, so it is only a problem when the caller asked for a
			// gapless tiling.
			if f.offset + f.size <= hi && covered == hi { continue }
			return .UNSORTED, i
		}
	}
	if expect_gapless && covered != size { return .UNEXPECTED_GAP, -1 }
	return .NONE, -1
}
