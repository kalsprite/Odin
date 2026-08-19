package rexcode_dwarf

// -----------------------------------------------------------------------------
// Sections, fixups and errors -- the format-neutral boundary
// -----------------------------------------------------------------------------

// The sections this package can emit into or refer to. A `Section` is an
// IDENTITY, not an index: the object writer maps it onto whatever its own
// section table calls that thing.
Section :: enum u8 {
	TEXT,
	DEBUG_LINE,
	DEBUG_INFO,
	DEBUG_ABBREV,
	DEBUG_STR,
}

// What a patch site refers to.
//
// Deliberately not spelled as relocation types. `R_X86_64_64` is one format's
// name for ABS64_SYM on one architecture; COFF calls it `IMAGE_REL_AMD64_ADDR64`
// and AArch64 ELF calls it `R_AARCH64_ABS64`. The emitter knows the WIDTH and
// the MEANING, which are the same everywhere; the writer knows the name.
Fixup_Kind :: enum u8 {
	// 8 bytes: the run-time address of symbol `sym`, plus `addend`.
	ABS64_SYM,
	// 4 bytes: the offset at which section `target` was placed in the linked
	// output, plus `addend`. This is what `DW_AT_stmt_list` needs -- a CU's
	// line program sits at offset 0 of ITS object's `.debug_line`, and the
	// linker concatenates every object's, so the final offset is not knowable
	// here even for a single-CU object.
	SECOFF32,
}

// A place in an emitted section whose bytes this package could not compute.
// Emitted as zeroes; the object writer overwrites them or records a relocation.
Fixup :: struct {
	section: Section,    // the section the PATCH SITE is in
	offset:  u64,        // byte offset of the patch site within `section`
	kind:    Fixup_Kind,
	sym:     u32,        // ABS64_SYM: the caller's own symbol index
	target:  Section,    // SECOFF32: the section referred TO
	addend:  i64,
}

Error :: enum u8 {
	NONE = 0,
	UNSUPPORTED_VERSION,     // a version this package does not implement
	NO_FILES,                // the file table is empty; every row would be unattributable
	EMPTY_SEQUENCE,          // a sequence with no rows emits a header and no program
	MISSING_END_SEQUENCE,    // the last row of a sequence is not `end_sequence`
	END_SEQUENCE_NOT_LAST,   // an `end_sequence` row with rows after it
	ROWS_OUT_OF_ORDER,       // addresses within a sequence must be non-decreasing
	FILE_INDEX_OUT_OF_RANGE, // a row names a file the table does not have
	DIR_INDEX_OUT_OF_RANGE,  // a file names a directory the table does not have
	LINE_TOO_LARGE,          // a line number that does not fit the encoding
	// A row address that is not a multiple of `min_inst_len`. The line program
	// encodes address advances in INSTRUCTION units, so a delta that is not a
	// whole number of them cannot be represented -- and the division that
	// converts it truncates, which would place the row at a lower address
	// rather than fail.
	MISALIGNED_ADDRESS,
	NO_DIES,          // an information unit with no DIEs at all, not even a CU
	BAD_DIE_REF,      // a child or reference index with no DIE behind it
	UNSUPPORTED_FORM, // an attribute form this emitter does not write
}

// -----------------------------------------------------------------------------
// DWARF 4 line-number program opcodes (§6.2.5)
// -----------------------------------------------------------------------------

DW_LNS_copy               :: u8(0x01)
DW_LNS_advance_pc         :: u8(0x02)
DW_LNS_advance_line       :: u8(0x03)
DW_LNS_set_file           :: u8(0x04)
DW_LNS_set_column         :: u8(0x05)
DW_LNS_negate_stmt        :: u8(0x06)
DW_LNS_set_basic_block    :: u8(0x07)
DW_LNS_const_add_pc       :: u8(0x08)
DW_LNS_fixed_advance_pc   :: u8(0x09)
DW_LNS_set_prologue_end   :: u8(0x0a)
DW_LNS_set_epilogue_begin :: u8(0x0b)
DW_LNS_set_isa            :: u8(0x0c)

// Extended opcodes. Introduced by a 0x00 byte and a ULEB length, so a consumer
// can skip one it does not know -- which is why an unknown EXTENDED opcode is
// survivable and an unknown STANDARD one is not.
DW_LNE_end_sequence      :: u8(0x01)
DW_LNE_set_address       :: u8(0x02)
DW_LNE_set_discriminator :: u8(0x04)

// -----------------------------------------------------------------------------
// DWARF 5 line-header content types and forms (§6.2.4.1, §7.5.6)
//
// Version 5 replaced version 4's two lists of NUL-terminated strings with a
// SELF-DESCRIBING table: a format array says which content types each entry
// carries and in which form, then the entries follow. It is more work to emit
// and it is why a v5 reader can skip a producer's MD5 hashes without knowing
// what they are.
// -----------------------------------------------------------------------------

DW_LNCT_path            :: u64(0x1)
DW_LNCT_directory_index :: u64(0x2)
DW_LNCT_timestamp       :: u64(0x3)
DW_LNCT_size            :: u64(0x4)
DW_LNCT_MD5             :: u64(0x5)

// An inline NUL-terminated string, right there in the entry.
DW_FORM_string    :: u64(0x08)
// An offset into `.debug_str`, and into `.debug_line_str` for the line header's
// own strings. Not emitted yet -- see doc.odin.
DW_FORM_strp      :: u64(0x0e)
DW_FORM_line_strp :: u64(0x1f)
DW_FORM_udata     :: u64(0x0f)
DW_FORM_data16    :: u64(0x1e)

// -----------------------------------------------------------------------------
// Little-endian byte helpers
//
// Written out rather than reinterpreting structs, for the same reason the ELF
// writer does it: a struct cast silently produces a wrong file on a big-endian
// host, and the failure surfaces as "your debug info is corrupt" a long way from
// here. DWARF is emitted in the TARGET's byte order; every target this package
// is used for today is little-endian, and a big-endian one needs these to take
// the order as a parameter rather than needing the callers audited.
// -----------------------------------------------------------------------------

@(private)
put_u8 :: proc(b: ^[dynamic]u8, v: u8) {
	append(b, v)
}

@(private)
put_u16 :: proc(b: ^[dynamic]u8, v: u16) {
	append(b, u8(v), u8(v >> 8))
}

@(private)
put_u32 :: proc(b: ^[dynamic]u8, v: u32) {
	append(b, u8(v), u8(v >> 8), u8(v >> 16), u8(v >> 24))
}

@(private)
put_u64 :: proc(b: ^[dynamic]u8, v: u64) {
	for i in u64(0) ..< 8 {
		append(b, u8(v >> (8 * i)))
	}
}

// Patch a u32 already written. Used for the two length fields a DWARF unit
// header carries, both of which count bytes that are not written yet when the
// field itself is.
@(private)
patch_u32 :: proc(b: ^[dynamic]u8, at: int, v: u32) {
	b[at + 0] = u8(v)
	b[at + 1] = u8(v >> 8)
	b[at + 2] = u8(v >> 16)
	b[at + 3] = u8(v >> 24)
}

// Unsigned LEB128. Seven bits per byte, low group first, high bit set on every
// byte but the last. Zero encodes as a single 0x00 rather than as nothing.
put_uleb128 :: proc(b: ^[dynamic]u8, value: u64) {
	v := value
	for {
		chunk := u8(v & 0x7f)
		v >>= 7
		if v != 0 {
			chunk |= 0x80
		}
		append(b, chunk)
		if v == 0 {
			break
		}
	}
}

// Signed LEB128. The termination rule is NOT "the value went to zero": it is
// that the remaining bits are all copies of the sign bit AND the last byte
// written carries that sign in bit 6. Drop the second half of that condition and
// +64 comes out as the single byte 0x40 -- which reads back as -64, because in
// a one-byte SLEB128 bit 6 IS the sign. It costs two bytes (0xc0 0x00) and the
// line-advance operand is exactly where it would bite.
put_sleb128 :: proc(b: ^[dynamic]u8, value: i64) {
	v := value
	for {
		chunk := u8(u64(v) & 0x7f)
		// Arithmetic shift: the sign must propagate, or a negative value
		// terminates on the wrong byte.
		v >>= 7
		done := (v == 0 && (chunk & 0x40) == 0) || (v == -1 && (chunk & 0x40) != 0)
		if !done {
			chunk |= 0x80
		}
		append(b, chunk)
		if done {
			break
		}
	}
}

// A NUL-terminated string, as every DWARF 4 in-section string is.
@(private)
put_string_z :: proc(b: ^[dynamic]u8, s: string) {
	append(b, s)
	append(b, 0)
}
