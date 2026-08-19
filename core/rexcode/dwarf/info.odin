package rexcode_dwarf

// `.debug_info`, `.debug_abbrev` and `.debug_str`.
//
// A DIE tree is a flat array here, not a pointer graph: children are indices
// into `Info_Unit.dies`, and a reference attribute names an index too. That is
// deliberate rather than incidental -- the tree is built incrementally by a
// consumer that does not know its final size, and a `[dynamic]Die` reallocates,
// which would leave any `^Die` a caller had kept pointing into freed memory.
// The `abi` package's own review found the same class of bug in a returned
// slice; indices cannot have it.
//
// Abbreviations are DERIVED, never authored. Every DIE names an abbreviation
// code that says which tag it has and which attributes follow in which form,
// and the table of those is what makes `.debug_info` compact. Two DIEs with the
// same shape must share one code -- not for size alone, but because a consumer
// that emits a fresh abbreviation per DIE produces a table that grows with the
// program and reads as though every function were structurally unique.

import "core:strings"

NO_PARENT :: u32(0xffff_ffff)

// One attribute. Explicit fields per form rather than a union: an attribute is
// written far more often than it is read, and a constructor per form (below)
// keeps the call sites honest about which field the form actually uses.
Attr :: struct {
	at:    u64,
	form:  u64,
	num:   u64,     // data1/2/4/8, udata, flag, and the addend for strp
	snum:  i64,     // sdata
	str:   string,  // string, strp
	sym:   u32,     // addr
	sec:   Section, // sec_offset
	ref:   u32,     // ref4: an index into Info_Unit.dies
	block: []u8,    // exprloc, block1
	// An expression block may embed one link-time address (DW_OP_addr). The
	// fixup for it cannot be made by the expression builder, which does not know
	// where in `.debug_info` the block will land, so the offset travels here and
	// `emit_die` adds the block's own position to it.
	block_sym:     bool,
	block_sym_off: u32,
}

attr_string       :: proc(at: u64, s: string) -> Attr { return {at = at, form = DW_FORM_string, str = s} }
attr_strp         :: proc(at: u64, s: string) -> Attr { return {at = at, form = DW_FORM_strp, str = s} }
attr_udata        :: proc(at: u64, v: u64) -> Attr    { return {at = at, form = DW_FORM_udata, num = v} }
attr_sdata        :: proc(at: u64, v: i64) -> Attr    { return {at = at, form = DW_FORM_sdata, snum = v} }
attr_data1        :: proc(at: u64, v: u64) -> Attr    { return {at = at, form = DW_FORM_data1, num = v} }
attr_data2        :: proc(at: u64, v: u64) -> Attr    { return {at = at, form = DW_FORM_data2, num = v} }
attr_data4        :: proc(at: u64, v: u64) -> Attr    { return {at = at, form = DW_FORM_data4, num = v} }
attr_data8        :: proc(at: u64, v: u64) -> Attr    { return {at = at, form = DW_FORM_data8, num = v} }
attr_addr         :: proc(at: u64, sym: u32) -> Attr  { return {at = at, form = DW_FORM_addr, sym = sym} }
attr_sec_offset   :: proc(at: u64, sec: Section) -> Attr { return {at = at, form = DW_FORM_sec_offset, sec = sec} }
attr_flag_present :: proc(at: u64) -> Attr            { return {at = at, form = DW_FORM_flag_present} }
attr_flag         :: proc(at: u64, v: bool) -> Attr   { return {at = at, form = DW_FORM_flag, num = v ? 1 : 0} }
attr_ref          :: proc(at: u64, die: u32) -> Attr  { return {at = at, form = DW_FORM_ref4, ref = die} }
attr_exprloc      :: proc(at: u64, expr: []u8) -> Attr { return {at = at, form = DW_FORM_exprloc, block = expr} }

Die :: struct {
	tag:      u64,
	attrs:    [dynamic]Attr,
	children: [dynamic]u32,
}

Info_Unit :: struct {
	version:      u16,
	address_size: u8,
	dies:         [dynamic]Die, // dies[0] is the CU DIE
	// Copies of every string and expression block an attribute names, owned by
	// the unit. See `die_add` for why this exists rather than borrowing.
	owned:        [dynamic][]u8,
}

info_unit_init :: proc(u: ^Info_Unit, version: u16 = LINE_VERSION_4) {
	u.version = version
	u.address_size = 8
}

info_unit_destroy :: proc(u: ^Info_Unit) {
	for &d in u.dies {
		delete(d.attrs)
		delete(d.children)
	}
	delete(u.dies)
	for b in u.owned {
		delete(b)
	}
	delete(u.owned)
	u.dies = nil
	u.owned = nil
}

// Take a private copy of bytes an attribute would otherwise borrow.
@(private)
intern_bytes :: proc(u: ^Info_Unit, b: []u8) -> []u8 {
	if len(b) == 0 {
		return nil
	}
	copy_of := make([]u8, len(b))
	copy(copy_of, b)
	append(&u.owned, copy_of)
	return copy_of
}

@(private)
intern_string :: proc(u: ^Info_Unit, s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	return string(intern_bytes(u, transmute([]u8)s))
}

// Copy anything an attribute merely points at into the unit.
//
// This is the API's answer to the lifetime problem, and it is not theoretical.
// Two ways a consumer loses:
//
//   * a name built with `fmt.tprintf` -- which is exactly how a backend spells a
//     generic or composite type -- lives on the temp allocator, and the next
//     `free_all(context.temp_allocator)` turns every such DIE name into garbage
//     that still emits, still decodes, and reads as memory corruption in a
//     debugger rather than as a bug here;
//   * an `Expr` appended to after `attr_expr` was called reallocates its
//     buffer, leaving the attribute pointing at freed memory.
//
// Both cost one small copy to remove permanently, so the API takes the copy
// rather than documenting the hazard. The `abi` package's review found the same
// class of bug in a returned slice; a library that hands this problem to its
// consumer has not finished the job.
@(private)
intern_attr :: proc(u: ^Info_Unit, a: Attr) -> Attr {
	out := a
	switch a.form {
	case DW_FORM_string, DW_FORM_strp:
		out.str = intern_string(u, a.str)
	case DW_FORM_exprloc, DW_FORM_block1:
		out.block = intern_bytes(u, a.block)
	}
	return out
}

// Adds a DIE and returns its index. `parent` is NO_PARENT for the CU DIE, which
// must be added first.
die_add :: proc(u: ^Info_Unit, parent: u32, tag: u64, attrs: ..Attr) -> u32 {
	idx := u32(len(u.dies))
	d := Die{tag = tag}
	for a in attrs {
		append(&d.attrs, intern_attr(u, a))
	}
	append(&u.dies, d)
	if parent != NO_PARENT {
		append(&u.dies[parent].children, idx)
	}
	return idx
}

// Add an attribute to a DIE that already exists.
//
// The supported way to attach a forward reference -- a variable's type is
// usually declared after it. Appending to `dies[i].attrs` directly works but
// skips the copy `die_add` takes, which is the difference between a name that
// survives the next temp-allocator reset and one that does not.
die_attr_add :: proc(u: ^Info_Unit, die: u32, attr: Attr) {
	append(&u.dies[die].attrs, intern_attr(u, attr))
}

// -----------------------------------------------------------------------------
// `.debug_str`
// -----------------------------------------------------------------------------

// A deduplicating string table. Held by the caller and shared across units,
// because the point of `.debug_str` is that "int" is stored once for a whole
// program rather than once per compilation unit.
Str_Table :: struct {
	buf: [dynamic]u8,
	off: map[string]u32,
}

str_table_destroy :: proc(t: ^Str_Table) {
	delete(t.buf)
	for k in t.off {
		delete(k)
	}
	delete(t.off)
	t.off = nil
}

// Returns the byte offset of `s` within `.debug_str`, adding it if new.
str_table_add :: proc(t: ^Str_Table, s: string) -> u32 {
	if existing, found := t.off[s]; found {
		return existing
	}
	offset := u32(len(t.buf))
	append(&t.buf, s)
	append(&t.buf, 0)
	// The key is cloned: the caller's string may be a temporary, and a map key
	// that outlives its backing memory is a lookup that starts returning wrong
	// answers rather than crashing.
	t.off[strings.clone(s)] = offset
	return offset
}

// -----------------------------------------------------------------------------
// Abbreviations
// -----------------------------------------------------------------------------

@(private)
Abbrev :: struct {
	code:         u64,
	tag:          u64,
	has_children: bool,
	pairs:        [dynamic]u64, // flattened (attribute, form) pairs
}

@(private)
abbrev_key :: proc(d: ^Die, has_children: bool, allocator := context.temp_allocator) -> string {
	b := strings.builder_make(allocator)
	strings.write_u64(&b, d.tag)
	strings.write_string(&b, has_children ? "|y" : "|n")
	for a in d.attrs {
		strings.write_string(&b, "|")
		strings.write_u64(&b, a.at)
		strings.write_string(&b, ":")
		strings.write_u64(&b, a.form)
	}
	return strings.to_string(b)
}

// -----------------------------------------------------------------------------
// Emission
// -----------------------------------------------------------------------------

// Where each section's bytes go. Separate pointers rather than one struct of
// buffers so a caller can emit several units into the same three sections,
// which is what a whole-program build does.
Info_Output :: struct {
	info:   ^[dynamic]u8,
	abbrev: ^[dynamic]u8,
	strs:   ^Str_Table,
}

// info_emit appends one compilation unit to `.debug_info`, its abbreviation
// table to `.debug_abbrev`, and any `DW_FORM_strp` strings to the string table.
//
// Fixup offsets are absolute within their section, so several units may share
// one buffer.
info_emit :: proc(u: ^Info_Unit, out: Info_Output, fixups: ^[dynamic]Fixup) -> Error {
	if u.version != LINE_VERSION_4 && u.version != LINE_VERSION_5 {
		return .UNSUPPORTED_VERSION
	}
	if len(u.dies) == 0 {
		return .NO_DIES
	}
	for d in u.dies {
		for c in d.children {
			if int(c) >= len(u.dies) {
				return .BAD_DIE_REF
			}
		}
		for a in d.attrs {
			if a.form == DW_FORM_ref4 && int(a.ref) >= len(u.dies) {
				return .BAD_DIE_REF
			}
		}
	}

	// --- 1. assign abbreviation codes, deduplicating by shape ---------------
	codes := make([]u64, len(u.dies), context.temp_allocator)
	abbrevs: [dynamic]Abbrev
	defer {
		for &a in abbrevs {
			delete(a.pairs)
		}
		delete(abbrevs)
	}
	seen := make(map[string]u64, 0, context.temp_allocator)
	defer delete(seen)

	for &d, i in u.dies {
		has_children := len(d.children) > 0
		key := abbrev_key(&d, has_children)
		if code, found := seen[key]; found {
			codes[i] = code
			continue
		}
		// Codes start at 1: 0 terminates a DIE's sibling chain, so it can never
		// be an abbreviation code.
		code := u64(len(abbrevs)) + 1
		a := Abbrev{code = code, tag = d.tag, has_children = has_children}
		for at in d.attrs {
			append(&a.pairs, at.at, at.form)
		}
		append(&abbrevs, a)
		seen[strings.clone(key, context.temp_allocator)] = code
		codes[i] = code
	}

	// --- 2. `.debug_abbrev` -------------------------------------------------
	abbrev_table_start := u64(len(out.abbrev))
	for a in abbrevs {
		put_uleb128(out.abbrev, a.code)
		put_uleb128(out.abbrev, a.tag)
		put_u8(out.abbrev, a.has_children ? DW_CHILDREN_yes : DW_CHILDREN_no)
		for j := 0; j < len(a.pairs); j += 2 {
			put_uleb128(out.abbrev, a.pairs[j])
			put_uleb128(out.abbrev, a.pairs[j + 1])
		}
		put_uleb128(out.abbrev, 0)
		put_uleb128(out.abbrev, 0)
	}
	put_uleb128(out.abbrev, 0) // end of this unit's table

	// --- 3. `.debug_info` ---------------------------------------------------
	unit_start := len(out.info)
	put_u32(out.info, 0) // unit_length, patched below
	put_u16(out.info, u.version)

	// The header field order CHANGED in version 5: v4 is
	// (abbrev_offset, address_size) and v5 is (unit_type, address_size,
	// abbrev_offset). Emitting v4's order under a v5 stamp gives a reader an
	// address size of whatever the abbrev offset's low byte happened to be.
	emit_abbrev_ref :: proc(out: ^[dynamic]u8, fixups: ^[dynamic]Fixup, table_start: u64) {
		append(fixups, Fixup{
			section = .DEBUG_INFO,
			offset  = u64(len(out)),
			kind    = .SECOFF32,
			target  = .DEBUG_ABBREV,
			addend  = i64(table_start),
		})
		put_u32(out, 0)
	}
	if u.version == LINE_VERSION_5 {
		put_u8(out.info, DW_UT_compile)
		put_u8(out.info, u.address_size)
		emit_abbrev_ref(out.info, fixups, abbrev_table_start)
	} else {
		emit_abbrev_ref(out.info, fixups, abbrev_table_start)
		put_u8(out.info, u.address_size)
	}

	die_offsets := make([]u32, len(u.dies), context.temp_allocator)
	ref_sites: [dynamic][2]u32 // (absolute patch offset, target DIE index)
	defer delete(ref_sites)

	err := emit_die(u, 0, codes, out, fixups, unit_start, die_offsets, &ref_sites)
	if err != .NONE {
		return err
	}

	// DIE references are CU-RELATIVE, which is why they can only be filled in
	// once every DIE has an offset -- a forward reference to a type declared
	// after its use is the normal case, not the exception.
	for site in ref_sites {
		patch_u32(out.info, int(site[0]), die_offsets[site[1]])
	}

	patch_u32(out.info, unit_start, u32(len(out.info) - unit_start - 4))
	return .NONE
}

@(private)
emit_die :: proc(
	u: ^Info_Unit, idx: u32, codes: []u64, out: Info_Output, fixups: ^[dynamic]Fixup,
	unit_start: int, die_offsets: []u32, ref_sites: ^[dynamic][2]u32,
) -> Error {
	d := &u.dies[idx]
	die_offsets[idx] = u32(len(out.info) - unit_start)
	put_uleb128(out.info, codes[idx])

	for a in d.attrs {
		switch a.form {
		case DW_FORM_string:
			put_string_z(out.info, a.str)
		case DW_FORM_strp:
			// Four bytes naming a place in another section: the string's own
			// offset is known now, but where `.debug_str` lands is not.
			offset := str_table_add(out.strs, a.str)
			append(fixups, Fixup{
				section = .DEBUG_INFO,
				offset  = u64(len(out.info)),
				kind    = .SECOFF32,
				target  = .DEBUG_STR,
				addend  = i64(offset),
			})
			put_u32(out.info, 0)
		case DW_FORM_udata:
			put_uleb128(out.info, a.num)
		case DW_FORM_sdata:
			put_sleb128(out.info, a.snum)
		case DW_FORM_data1:
			put_u8(out.info, u8(a.num))
		case DW_FORM_data2:
			put_u16(out.info, u16(a.num))
		case DW_FORM_data4:
			put_u32(out.info, u32(a.num))
		case DW_FORM_data8:
			put_u64(out.info, a.num)
		case DW_FORM_flag:
			put_u8(out.info, u8(a.num))
		case DW_FORM_flag_present:
			// Zero bytes. The abbreviation carrying the form IS the value, which
			// is why a flag that is sometimes absent needs DW_FORM_flag instead.
		case DW_FORM_addr:
			append(fixups, Fixup{
				section = .DEBUG_INFO,
				offset  = u64(len(out.info)),
				kind    = .ABS64_SYM,
				sym     = a.sym,
				addend  = i64(a.num),
			})
			put_u64(out.info, 0)
		case DW_FORM_sec_offset:
			append(fixups, Fixup{
				section = .DEBUG_INFO,
				offset  = u64(len(out.info)),
				kind    = .SECOFF32,
				target  = a.sec,
				addend  = i64(a.num),
			})
			put_u32(out.info, 0)
		case DW_FORM_ref4:
			append(ref_sites, [2]u32{u32(len(out.info)), a.ref})
			put_u32(out.info, 0)
		case DW_FORM_exprloc:
			put_uleb128(out.info, u64(len(a.block)))
			if a.block_sym {
				append(fixups, Fixup{
					section = .DEBUG_INFO,
					offset  = u64(len(out.info)) + u64(a.block_sym_off),
					kind    = .ABS64_SYM,
					sym     = a.sym,
					addend  = 0,
				})
			}
			append(out.info, ..a.block)
		case DW_FORM_block1:
			put_u8(out.info, u8(len(a.block)))
			append(out.info, ..a.block)
		case:
			return .UNSUPPORTED_FORM
		}
	}

	if len(d.children) > 0 {
		for c in d.children {
			emit_die(u, c, codes, out, fixups, unit_start, die_offsets, ref_sites) or_return
		}
		put_u8(out.info, 0) // end of this DIE's children
	}
	return .NONE
}
