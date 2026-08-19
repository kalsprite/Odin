package rexcode_dwarf

// The DWARF 4 line-number program (§6.2).
//
// A line table is not a list of (address, line) pairs on disk -- it is a
// PROGRAM for a small state machine whose output is that list. That indirection
// is the whole of the encoding difficulty, and it is worth stating plainly
// because it explains what can go wrong: the bytes are deltas against a running
// state, so a single wrong opcode does not corrupt one row, it shifts every row
// after it. This is why the verification story in doc.odin compares whole
// decoded tables and not spot checks.

LINE_VERSION_4 :: u16(4)
LINE_VERSION_5 :: u16(5)

// The tunable constants in the header. These particular values are what GCC and
// Clang emit, which matters more than it looks: they set how many rows fit in a
// one-byte special opcode, so an unusual choice is not wrong but does produce a
// line program that no other producer's output resembles when the two are put
// side by side.
DEFAULT_MIN_INST_LEN :: u8(1)
DEFAULT_LINE_BASE    :: i8(-5)
DEFAULT_LINE_RANGE   :: u8(14)
DEFAULT_OPCODE_BASE  :: u8(13)

// `File.dir` for a file that sits directly in the compilation directory. DWARF
// spells this 0, and its directory table is 1-based -- but so is its FILE table,
// and `Row.file` here is a plain 0-based index into `Line_Program.files`. Rather
// than have one field 0-based and its neighbour 1-based, both are indices into
// the slices on `Line_Program` and this sentinel carries the one case an index
// cannot express. `line_emit` does the biasing.
DIR_COMP_DIR :: u32(0xffff_ffff)

File :: struct {
	name: string,
	dir:  u32, // index into Line_Program.dirs, or DIR_COMP_DIR
}

// One row of the decoded table: an address, and what source position the
// debugger should report for it.
//
// `address` is an offset from the START OF THE SEQUENCE's base symbol, not a
// link-time address -- this package cannot know one and does not want to. The
// sequence's `base_sym` becomes a relocation and the offsets ride on top.
Row :: struct {
	address:        u64,
	file:           u32, // index into Line_Program.files
	line:           u32, // 1-based, as in the source; 0 means "no source line"
	column:         u32, // 1-based; 0 means "the whole line"
	is_stmt:        bool, // a recommended breakpoint location for this line
	prologue_end:   bool, // where a breakpoint on the FUNCTION should land
	epilogue_begin: bool,
	// The start of a basic block. Emitted by the reference compiler and cheap to
	// carry; a consumer that does not want it simply leaves it false.
	basic_block:    bool,
	// Distinguishes several rows that share a (file, line, column) but come from
	// different places -- inlined copies, or the two halves of a short-circuit.
	// Zero means "not distinguished", which is why it resets after every row
	// rather than persisting like `file`.
	discriminator:  u32,
	// The terminator. Its `address` is the END of the sequence -- one past the
	// last byte -- and it carries no source position: a row at the same address
	// in another sequence is what the debugger should find instead.
	end_sequence:   bool,
}

// A contiguous run of code with a single base symbol -- in practice one
// function. Separate sequences rather than one table because the linker may
// place functions in any order and may discard some entirely; a sequence that
// spanned two functions would claim the bytes between them.
Sequence :: struct {
	base_sym: u32,   // the caller's symbol index; becomes an ABS64_SYM fixup
	rows:     []Row, // ascending `address`, last one `end_sequence`
}

Line_Program :: struct {
	version:         u16,
	// DWARF 5 only: the header carries the address size, and directory 0 is the
	// compilation directory. Version 4's header has neither -- an address is
	// however wide `DW_LNE_set_address`'s operand is, and comp_dir lives on the
	// CU DIE.
	address_size:    u8,
	comp_dir:        string,
	min_inst_len:    u8,
	line_base:       i8,
	line_range:      u8,
	opcode_base:     u8,
	default_is_stmt: bool,
	dirs:            []string,
	files:           []File,
	sequences:       []Sequence,
}

// A `Line_Program` with the header constants filled in. The three slices are
// still the caller's to set.
line_program_default :: proc() -> Line_Program {
	return Line_Program{
		version         = LINE_VERSION_4,
		address_size    = 8,
		min_inst_len    = DEFAULT_MIN_INST_LEN,
		line_base       = DEFAULT_LINE_BASE,
		line_range      = DEFAULT_LINE_RANGE,
		opcode_base     = DEFAULT_OPCODE_BASE,
		default_is_stmt = true,
	}
}

// -----------------------------------------------------------------------------
// Validation
//
// Separate from emission and run first, because every one of these produces a
// FILE THAT DECODES -- garbage rows, or rows attributed to the wrong file, not a
// reader error. A malformed line table is not caught downstream by anything: the
// linker does not look inside `.debug_line`, and `llvm-dwarfdump --verify` is
// documented in doc.odin as not catching it either.
// -----------------------------------------------------------------------------

line_validate :: proc(p: ^Line_Program) -> Error {
	if p.version != LINE_VERSION_4 && p.version != LINE_VERSION_5 {
		return .UNSUPPORTED_VERSION
	}
	if p.min_inst_len == 0 {
		return .MISALIGNED_ADDRESS
	}
	if len(p.files) == 0 {
		return .NO_FILES
	}
	for f in p.files {
		if f.dir != DIR_COMP_DIR && int(f.dir) >= len(p.dirs) {
			return .DIR_INDEX_OUT_OF_RANGE
		}
	}
	for seq in p.sequences {
		if len(seq.rows) == 0 {
			return .EMPTY_SEQUENCE
		}
		if !seq.rows[len(seq.rows) - 1].end_sequence {
			return .MISSING_END_SEQUENCE
		}
		prev_addr := u64(0)
		for row, i in seq.rows {
			if row.end_sequence && i != len(seq.rows) - 1 {
				return .END_SEQUENCE_NOT_LAST
			}
			if i > 0 && row.address < prev_addr {
				return .ROWS_OUT_OF_ORDER
			}
			// Addresses advance in units of `min_inst_len`, so every address in
			// the sequence must be a whole number of them from the base. On a
			// fixed-width target -- min_inst_len 4 -- a caller handing over a
			// byte offset that is not instruction-aligned has a bug this can
			// see and a debugger cannot.
			if row.address % u64(p.min_inst_len) != 0 {
				return .MISALIGNED_ADDRESS
			}
			prev_addr = row.address
			if !row.end_sequence {
				if int(row.file) >= len(p.files) {
					return .FILE_INDEX_OUT_OF_RANGE
				}
				if row.line > 0x7fff_ffff {
					return .LINE_TOO_LARGE
				}
			}
		}
	}
	return .NONE
}

// The number a DECODER will report for a row that names `index`.
//
// This is the whole of the v4/v5 file-table difference and it lives in exactly
// one place on purpose. Version 4 numbers the file table from 1 and treats 0 as
// invalid. Version 5 numbers it from 0, and entry 0 is the CU's own primary
// source file. `Row.file` is a 0-based index into `Line_Program.files` under
// both, so the API does not change shape when the version does.
//
// Public because a consumer needs the same number elsewhere: `DW_AT_decl_file`
// in `.debug_info` indexes THIS table, and a CU whose decl_file numbering
// disagrees with its line table sends a debugger to the wrong source file for
// every declaration it describes.
line_file_number :: proc(p: ^Line_Program, index: u32) -> u64 {
	return u64(index) if p.version == LINE_VERSION_5 else u64(index) + 1
}

// -----------------------------------------------------------------------------
// Emission
// -----------------------------------------------------------------------------

// line_emit appends a complete `.debug_line` unit to `out` and records into
// `fixups` every address this package could not resolve.
//
// `out` may already hold bytes -- fixup offsets are absolute within the section,
// so a caller emitting several units into one section gets correct offsets
// without adjusting them. The unit's own internal offsets are relative to the
// unit, as DWARF requires, and the two are only equal for the first unit.
line_emit :: proc(p: ^Line_Program, out: ^[dynamic]u8, fixups: ^[dynamic]Fixup) -> Error {
	if err := line_validate(p); err != .NONE {
		return err
	}

	unit_start := len(out)

	// `unit_length` counts the bytes AFTER itself, so it is written last. The
	// 32-bit form: a value below 0xfffffff0 is the length, and the reserved
	// values above it introduce the 64-bit form this package does not emit.
	put_u32(out, 0)
	put_u16(out, p.version)
	if p.version == LINE_VERSION_5 {
		// New in v5, and BEFORE header_length rather than after it: a reader
		// that emits these in the v4 position shifts the whole header by two.
		put_u8(out, p.address_size)
		put_u8(out, 0) // segment_selector_size; no segmented target here
	}

	// `header_length` counts from after ITS OWN four bytes to the first opcode,
	// which is how a consumer skips a header containing file entries it does
	// not care about.
	header_length_at := len(out)
	put_u32(out, 0)
	header_after_len := len(out)

	put_u8(out, p.min_inst_len)
	// maximum_operations_per_instruction. New in version 4 and 1 on every
	// architecture without VLIW bundles; emitting it under a version 2 or 3
	// header would shift every following field by one byte.
	put_u8(out, 1)
	put_u8(out, p.default_is_stmt ? 1 : 0)
	put_u8(out, u8(p.line_base))
	put_u8(out, p.line_range)
	put_u8(out, p.opcode_base)

	// standard_opcode_lengths: one ULEB operand count per standard opcode, so a
	// consumer can skip an opcode it does not implement. There are
	// `opcode_base - 1` of them, and the array is what makes `opcode_base` a
	// negotiable boundary rather than a constant.
	std_lengths := [12]u8{
		0, // DW_LNS_copy
		1, // DW_LNS_advance_pc
		1, // DW_LNS_advance_line
		1, // DW_LNS_set_file
		1, // DW_LNS_set_column
		0, // DW_LNS_negate_stmt
		0, // DW_LNS_set_basic_block
		0, // DW_LNS_const_add_pc
		1, // DW_LNS_fixed_advance_pc
		0, // DW_LNS_set_prologue_end
		0, // DW_LNS_set_epilogue_begin
		1, // DW_LNS_set_isa
	}
	for i in 0 ..< int(p.opcode_base) - 1 {
		put_u8(out, i < len(std_lengths) ? std_lengths[i] : 0)
	}

	if p.version == LINE_VERSION_5 {
		emit_tables_v5(p, out)
	} else {
		emit_tables_v4(p, out)
	}

	patch_u32(out, header_length_at, u32(len(out) - header_after_len))

	for seq in p.sequences {
		emit_sequence(p, seq, out, fixups)
	}

	patch_u32(out, unit_start, u32(len(out) - unit_start - 4))
	return .NONE
}

// Version 4: two lists of NUL-terminated strings, each ended by a lone NUL.
@(private)
emit_tables_v4 :: proc(p: ^Line_Program, out: ^[dynamic]u8) {
	// include_directories. Directory 0 is the CU's comp_dir and is NOT written
	// here -- it is implied, and comes from the CU DIE.
	for d in p.dirs {
		put_string_z(out, d)
	}
	put_u8(out, 0)

	// file_names: a name, a directory index, an mtime and a length. The last two
	// are 0 for "not known", which is what every producer that is not doing
	// dependency checking emits.
	for f in p.files {
		put_string_z(out, f.name)
		put_uleb128(out, f.dir == DIR_COMP_DIR ? 0 : u64(f.dir) + 1)
		put_uleb128(out, 0) // mtime
		put_uleb128(out, 0) // length
	}
	put_u8(out, 0)
}

// Version 5: a format descriptor, then a count, then entries in that format.
//
// Paths go inline as DW_FORM_string rather than as offsets into
// `.debug_line_str`. Both are legal and every reader takes either; inline needs
// no second section, which keeps this emitter self-contained until the string
// table exists. Switching to DW_FORM_line_strp later changes the two format
// pairs and nothing else about the shape.
@(private)
emit_tables_v5 :: proc(p: ^Line_Program, out: ^[dynamic]u8) {
	// Directories. Entry 0 is the compilation directory -- in v4 that entry is
	// implied and unwritten, and in v5 it is written like any other, which is
	// why `File.dir`'s DIR_COMP_DIR sentinel maps onto index 0 under both.
	put_u8(out, 1) // directory_entry_format_count
	put_uleb128(out, DW_LNCT_path)
	put_uleb128(out, DW_FORM_string)
	put_uleb128(out, u64(len(p.dirs)) + 1)
	put_string_z(out, p.comp_dir)
	for d in p.dirs {
		put_string_z(out, d)
	}

	// Files. Entry 0 is the CU's primary source file, which is the caller's
	// `files[0]`.
	put_u8(out, 2) // file_name_entry_format_count
	put_uleb128(out, DW_LNCT_path)
	put_uleb128(out, DW_FORM_string)
	put_uleb128(out, DW_LNCT_directory_index)
	put_uleb128(out, DW_FORM_udata)
	put_uleb128(out, u64(len(p.files)))
	for f in p.files {
		put_string_z(out, f.name)
		put_uleb128(out, f.dir == DIR_COMP_DIR ? 0 : u64(f.dir) + 1)
	}
}

@(private)
emit_sequence :: proc(p: ^Line_Program, seq: Sequence, out: ^[dynamic]u8, fixups: ^[dynamic]Fixup) {
	// The state machine's initial state (§6.2.2). Every delta below is measured
	// against this, so the registers we track must start where the CONSUMER's
	// will.
	addr := u64(0)
	// The machine's `file` register starts at 1 in BOTH versions. Version 5 made
	// index 0 legal and did NOT change this initial value, so under v5 a row
	// naming file 1 needs no `DW_LNS_set_file` and a row naming file 0 does --
	// the opposite of the intuition that "0 is the default now".
	file_no := u64(1)
	line := u32(1)
	column := u32(0)
	is_stmt := p.default_is_stmt

	// DW_LNE_set_address is the only way to load an absolute address, and its
	// operand is the one thing in a relocatable object that cannot be computed
	// here. Emitted as eight zero bytes with a fixup; the linker writes the
	// function's final address over them.
	put_u8(out, 0) // extended-opcode introducer
	put_uleb128(out, 9) // 1 opcode byte + 8 address bytes
	put_u8(out, DW_LNE_set_address)
	append(fixups, Fixup{
		section = .DEBUG_LINE,
		offset  = u64(len(out)),
		kind    = .ABS64_SYM,
		sym     = seq.base_sym,
		addend  = 0,
	})
	put_u64(out, 0)

	for row in seq.rows {
		if row.end_sequence {
			// The terminator takes the address and nothing else: no special
			// opcode, because a special opcode would also commit a ROW at that
			// address, and the end address belongs to whatever comes next.
			delta := (row.address - addr) / u64(p.min_inst_len)
			if delta == special_addr_max(p) {
				put_u8(out, DW_LNS_const_add_pc)
			} else if delta != 0 {
				put_u8(out, DW_LNS_advance_pc)
				put_uleb128(out, delta)
			}
			put_u8(out, 0)
			put_uleb128(out, 1)
			put_u8(out, DW_LNE_end_sequence)
			break
		}

		// Flags first, then the opcode that commits the row: the committing
		// opcode is what samples the state, and `prologue_end`,
		// `epilogue_begin`, `basic_block` and `discriminator` are all reset by
		// it, so they must be set for the row they describe and cannot be
		// carried over from the previous one.
		if want_file := line_file_number(p, row.file); want_file != file_no {
			put_u8(out, DW_LNS_set_file)
			put_uleb128(out, want_file)
			file_no = want_file
		}
		if row.column != column {
			put_u8(out, DW_LNS_set_column)
			put_uleb128(out, u64(row.column))
			column = row.column
		}
		if row.is_stmt != is_stmt {
			put_u8(out, DW_LNS_negate_stmt)
			is_stmt = row.is_stmt
		}
		if row.prologue_end {
			put_u8(out, DW_LNS_set_prologue_end)
		}
		if row.epilogue_begin {
			put_u8(out, DW_LNS_set_epilogue_begin)
		}
		if row.basic_block {
			put_u8(out, DW_LNS_set_basic_block)
		}
		if row.discriminator != 0 {
			// Extended, because its operand is a ULEB of unbounded width and the
			// standard opcode space was already spent when it was added.
			disc: [dynamic]u8
			defer delete(disc)
			put_uleb128(&disc, u64(row.discriminator))
			put_u8(out, 0)
			put_uleb128(out, u64(len(disc)) + 1)
			put_u8(out, DW_LNE_set_discriminator)
			append(out, ..disc[:])
		}

		line_delta := i64(row.line) - i64(line)
		addr_delta := (row.address - addr) / u64(p.min_inst_len)
		emit_advance(p, out, line_delta, addr_delta)

		line = row.line
		addr = row.address
	}
}

// The largest address advance a special opcode can carry on its own.
@(private)
special_addr_max :: proc(p: ^Line_Program) -> u64 {
	return u64((255 - p.opcode_base) / p.line_range)
}

// Encode one (line, address) advance and commit a row.
//
// A special opcode is a single byte that does all three of "advance the address",
// "advance the line" and "emit a row", which is why line tables are as small as
// they are:
//
//	opcode = (line_delta - line_base) + line_range * addr_delta + opcode_base
//
// It only exists when both deltas fit. This follows the standard's own worked
// algorithm (§6.2.5.1, and the same shape LLVM's MCDwarf uses): reduce whichever
// delta does not fit with a standard opcode, then take the special opcode if
// what remains fits, and TEST the result rather than assuming -- the two deltas
// share one byte, so a line advance that fits on its own can still push the
// opcode past 255 once an address advance is added.
@(private)
emit_advance :: proc(p: ^Line_Program, out: ^[dynamic]u8, line_delta_in: i64, addr_delta_in: u64) {
	line_delta := line_delta_in
	addr_delta := addr_delta_in

	// True once the line advance has been paid for separately, which means the
	// byte that commits the row can no longer carry it.
	line_paid := false

	temp := line_delta - i64(p.line_base)
	if temp < 0 || temp >= i64(p.line_range) || temp + i64(p.opcode_base) > 255 {
		put_u8(out, DW_LNS_advance_line)
		put_sleb128(out, line_delta)
		line_delta = 0
		line_paid = true
		temp = -i64(p.line_base)
	}

	// A row at the same address and line as the previous one -- the second of
	// two rows that differ only in column, say. DW_LNS_copy exists for exactly
	// this and is one byte, same as the special opcode would be, but does not
	// depend on (0, 0) being encodable.
	if line_delta == 0 && addr_delta == 0 {
		put_u8(out, DW_LNS_copy)
		return
	}

	temp += i64(p.opcode_base)
	addr_max := special_addr_max(p)

	// Guarded so the multiplication below cannot wrap on a large delta.
	if addr_delta < 256 + addr_max {
		opcode := temp + i64(addr_delta) * i64(p.line_range)
		if opcode <= 255 {
			put_u8(out, u8(opcode))
			return
		}
		// DW_LNS_const_add_pc advances by `addr_max` in one byte without
		// emitting a row, which buys back exactly the range a special opcode
		// then needs.
		if addr_delta >= addr_max {
			opcode = temp + i64(addr_delta - addr_max) * i64(p.line_range)
			if opcode <= 255 {
				put_u8(out, DW_LNS_const_add_pc)
				put_u8(out, u8(opcode))
				return
			}
		}
	}

	put_u8(out, DW_LNS_advance_pc)
	put_uleb128(out, addr_delta)
	if line_paid {
		put_u8(out, DW_LNS_copy)
	} else {
		put_u8(out, u8(temp))
	}
}
