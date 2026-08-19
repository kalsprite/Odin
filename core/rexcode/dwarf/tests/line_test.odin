// `.debug_line` emitter tests.
//
// The golden byte string in `test_golden_program` is not hand-derived: it is the
// output that llvm-dwarfdump, binutils readelf and elfutils eu-readelf were all
// made to decode, and all three agreed row-for-row with what the emitter was
// asked for (2026-08-18). Locking the bytes here is what keeps that measurement
// worth something afterwards -- the external check is the oracle, and this is
// the ratchet that says the encoder has not moved since it was run.
package rexcode_dwarf_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import dw ".."

ok_count:   int
fail_count: int

// Shared with the other test files in this package.
check_bytes :: proc(name: string, got: []u8, want: []u8) {
	if slice.equal(got, want) {
		ok_count += 1
		return
	}
	fail_count += 1
	fmt.printfln("FAIL %s", name)
	fmt.printfln("  want % x", want)
	fmt.printfln("  got  % x", got)
}

// Shared with the other test files in this package.
check_err :: proc(name: string, got: dw.Error, want: dw.Error) {
	if got == want {
		ok_count += 1
		return
	}
	fail_count += 1
	fmt.printfln("FAIL %s: want %v, got %v", name, want, got)
}

// Shared with the other test files in this package.
check_eq :: proc(name: string, got: int, want: int) {
	if got == want {
		ok_count += 1
		return
	}
	fail_count += 1
	fmt.printfln("FAIL %s: want %d, got %d", name, want, got)
}

// -----------------------------------------------------------------------------
// LEB128
// -----------------------------------------------------------------------------

@(private = "file")
uleb :: proc(v: u64) -> []u8 {
	b: [dynamic]u8
	dw.put_uleb128(&b, v)
	return b[:]
}

@(private = "file")
sleb :: proc(v: i64) -> []u8 {
	b: [dynamic]u8
	dw.put_sleb128(&b, v)
	return b[:]
}

@(private = "file")
test_leb128 :: proc() {
	check_bytes("uleb 0", uleb(0), {0x00})
	check_bytes("uleb 127", uleb(127), {0x7f})
	check_bytes("uleb 128", uleb(128), {0x80, 0x01})
	check_bytes("uleb 624485", uleb(624485), {0xe5, 0x8e, 0x26})

	check_bytes("sleb 0", sleb(0), {0x00})
	check_bytes("sleb 63", sleb(63), {0x3f})
	// The pair that catches a missing bit-6 check: 64 needs two bytes precisely
	// because the one-byte form 0x40 already means -64.
	check_bytes("sleb 64", sleb(64), {0xc0, 0x00})
	check_bytes("sleb -64", sleb(-64), {0x40})
	check_bytes("sleb -1", sleb(-1), {0x7f})
	check_bytes("sleb -65", sleb(-65), {0xbf, 0x7f})
	check_bytes("sleb -123456", sleb(-123456), {0xc0, 0xbb, 0x78})
}

// -----------------------------------------------------------------------------
// The line program
// -----------------------------------------------------------------------------

@(private = "file")
emit_rows :: proc(rows: []dw.Row) -> (unit: []u8, fixups: []dw.Fixup, err: dw.Error) {
	p := dw.line_program_default()
	p.files = []dw.File{{name = "a.odin", dir = dw.DIR_COMP_DIR}}
	p.sequences = []dw.Sequence{{base_sym = 1, rows = rows}}

	out: [dynamic]u8
	fx: [dynamic]dw.Fixup
	err = dw.line_emit(&p, &out, &fx)
	return out[:], fx[:], err
}

// The opcode stream, with the header cut off by the header's own length field --
// which incidentally checks that field, since a wrong `header_length` makes
// every one of these tests fail on its first byte.
@(private = "file")
program_of :: proc(unit: []u8) -> []u8 {
	header_length := u32(unit[6]) | u32(unit[7]) << 8 | u32(unit[8]) << 16 | u32(unit[9]) << 24
	return unit[10 + int(header_length):]
}

@(private = "file")
test_special_opcode_boundary :: proc() {
	// A special opcode carries both deltas in ONE byte, and the two share the
	// same 256 values: the address advance a special opcode can reach depends on
	// how much of the byte the line advance already spent. These two cases
	// differ only in the line delta and take different paths because of it.

	// line -5 (the smallest a special opcode encodes) leaves the most room:
	// 17 units of address still fit in the single byte 0xfb.
	rows_a := []dw.Row{
		{address = 0, line = 10, is_stmt = true},
		{address = 17, line = 5, is_stmt = true},
		{address = 17, end_sequence = true},
	}
	unit_a, _, err_a := emit_rows(rows_a)
	check_err("boundary a emits", err_a, .NONE)
	check_bytes("special opcode absorbs addr 17 at line -5", program_of(unit_a), {
		0x00, 0x09, 0x02, 0, 0, 0, 0, 0, 0, 0, 0, // DW_LNE_set_address
		0x03, 0x09, // advance_line +9 (out of special range)
		0x01,       // copy
		0xfb,       // special: line -5, addr +17
		0x00, 0x01, 0x01, // end_sequence
	})

	// line +1 costs six more of those values, so the same address advance no
	// longer fits and DW_LNS_const_add_pc has to buy it back.
	rows_b := []dw.Row{
		{address = 0, line = 10, is_stmt = true},
		{address = 17, line = 11, is_stmt = true},
		{address = 17, end_sequence = true},
	}
	unit_b, _, err_b := emit_rows(rows_b)
	check_err("boundary b emits", err_b, .NONE)
	check_bytes("const_add_pc buys back the range at line +1", program_of(unit_b), {
		0x00, 0x09, 0x02, 0, 0, 0, 0, 0, 0, 0, 0,
		0x03, 0x09,
		0x01,
		0x08, 0x13, // const_add_pc, then special: line +1, addr +0
		0x00, 0x01, 0x01,
	})
}

@(private = "file")
test_fixup :: proc() {
	rows := []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 4, end_sequence = true},
	}
	unit, fixups, err := emit_rows(rows)
	check_err("fixup case emits", err, .NONE)
	check_eq("one fixup per sequence", len(fixups), 1)
	if len(fixups) != 1 {
		return
	}
	f := fixups[0]
	if f.kind != .ABS64_SYM || f.section != .DEBUG_LINE || f.sym != 1 || f.addend != 0 {
		fail_count += 1
		fmt.printfln("FAIL fixup shape: %v", f)
	} else {
		ok_count += 1
	}
	// It must point at the operand, not at the opcode: the eight bytes the
	// linker overwrites start three bytes into the extended opcode.
	prog_start := int(f.offset) - 3
	check_bytes("fixup points at the set_address operand",
		unit[prog_start:prog_start + 3], {0x00, 0x09, 0x02})
	all_zero := true
	for b in unit[f.offset:f.offset + 8] {
		if b != 0 {
			all_zero = false
		}
	}
	if !all_zero {
		fail_count += 1
		fmt.printfln("FAIL fixup site is not zero-filled")
	} else {
		ok_count += 1
	}
}

// Several units emitted into ONE section buffer.
//
// The trap this locks down: a unit's internal offsets are relative to the unit,
// and a fixup's offset is relative to the SECTION. Those two are equal for the
// first unit and never again. Getting it wrong puts the second unit's
// DW_LNE_set_address patch somewhere in the first unit's opcode stream, which
// does not fail to link and does not fail to decode -- it just moves rows to
// addresses that belong to another function.
@(private = "file")
test_multi_unit :: proc() {
	rows_a := []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 4, end_sequence = true},
	}
	rows_b := []dw.Row{
		{address = 0, line = 90, is_stmt = true},
		{address = 8, line = 91, is_stmt = true},
		{address = 16, end_sequence = true},
	}
	files := []dw.File{{name = "a.odin", dir = dw.DIR_COMP_DIR}}

	out: [dynamic]u8
	fx: [dynamic]dw.Fixup

	pa := dw.line_program_default()
	pa.files = files
	pa.sequences = []dw.Sequence{{base_sym = 3, rows = rows_a}}
	check_err("first unit emits", dw.line_emit(&pa, &out, &fx), .NONE)
	first_len := len(out)

	pb := dw.line_program_default()
	pb.files = files
	pb.sequences = []dw.Sequence{
		{base_sym = 4, rows = rows_b},
		{base_sym = 5, rows = rows_a},
	}
	check_err("second unit emits", dw.line_emit(&pb, &out, &fx), .NONE)

	check_eq("one fixup per sequence across both units", len(fx), 3)
	if len(fx) != 3 {
		return
	}
	check_eq("first unit's fixup is inside the first unit", int(fx[0].offset) < first_len ? 1 : 0, 1)
	check_eq("second unit's fixups are past it",
		int(fx[1].offset) >= first_len && int(fx[2].offset) >= first_len ? 1 : 0, 1)

	// Every fixup must sit three bytes into an extended DW_LNE_set_address, and
	// the eight bytes it names must still be zero. Checked against the SECTION
	// buffer, which is the whole point.
	for f, i in fx {
		site := int(f.offset)
		if site < 3 || site + 8 > len(out) {
			fail_count += 1
			fmt.printfln("FAIL fixup %d offset %d is outside the section", i, site)
			continue
		}
		if out[site - 3] != 0x00 || out[site - 2] != 0x09 || out[site - 1] != 0x02 {
			fail_count += 1
			fmt.printfln("FAIL fixup %d does not point at a set_address operand", i)
			continue
		}
		zero := true
		for b in out[site:site + 8] {
			if b != 0 {
				zero = false
			}
		}
		if !zero {
			fail_count += 1
			fmt.printfln("FAIL fixup %d site is not zero-filled", i)
			continue
		}
		ok_count += 1
	}
	check_eq("expected symbols, in emission order",
		int(fx[0].sym) * 100 + int(fx[1].sym) * 10 + int(fx[2].sym), 345)

	// The units must tile the buffer exactly: walk them by their own length
	// fields and land on the end. A unit_length that is short by one leaves a
	// consumer parsing the next unit's header from the middle of this one.
	pos := 0
	units := 0
	for pos + 4 <= len(out) {
		ul := int(out[pos]) | int(out[pos + 1]) << 8 | int(out[pos + 2]) << 16 | int(out[pos + 3]) << 24
		pos += 4 + ul
		units += 1
	}
	check_eq("units tile the section exactly", pos, len(out))
	check_eq("two units", units, 2)
}

// `default_is_stmt` is the INITIAL value of the register, and the only way to
// change it mid-sequence is DW_LNS_negate_stmt -- there is no "set". So a row's
// is_stmt is encoded relative to what the header declared, and getting the
// header wrong inverts every row in the unit.
@(private = "file")
test_default_is_stmt :: proc() {
	rows := []dw.Row{
		{address = 0, line = 1, is_stmt = false},
		{address = 4, end_sequence = true},
	}
	files := []dw.File{{name = "a.odin", dir = dw.DIR_COMP_DIR}}

	// Header says false, row is false: nothing to negate.
	out_f: [dynamic]u8
	fx_f: [dynamic]dw.Fixup
	pf := dw.line_program_default()
	pf.default_is_stmt = false
	pf.files = files
	pf.sequences = []dw.Sequence{{base_sym = 1, rows = rows}}
	check_err("default_is_stmt=false emits", dw.line_emit(&pf, &out_f, &fx_f), .NONE)
	check_bytes("a non-stmt row costs nothing when the header says false", program_of(out_f[:]), {
		0x00, 0x09, 0x02, 0, 0, 0, 0, 0, 0, 0, 0,
		0x01,             // copy
		0x02, 0x04,       // advance_pc 4
		0x00, 0x01, 0x01, // end_sequence
	})

	// Header says true, same row: now it has to be negated.
	out_t: [dynamic]u8
	fx_t: [dynamic]dw.Fixup
	pt := dw.line_program_default()
	pt.files = files
	pt.sequences = []dw.Sequence{{base_sym = 1, rows = rows}}
	check_err("default_is_stmt=true emits", dw.line_emit(&pt, &out_t, &fx_t), .NONE)
	check_bytes("the same row needs negate_stmt when the header says true", program_of(out_t[:]), {
		0x00, 0x09, 0x02, 0, 0, 0, 0, 0, 0, 0, 0,
		0x06,             // negate_stmt
		0x01,             // copy
		0x02, 0x04,
		0x00, 0x01, 0x01,
	})
}

// Address advances are measured in INSTRUCTION units. On a fixed-width target
// the division that converts bytes to units truncates, so an address that is
// not a whole number of instructions from the base would silently move the row
// backwards rather than fail.
@(private = "file")
test_min_inst_len :: proc() {
	files := []dw.File{{name = "a.odin", dir = dw.DIR_COMP_DIR}}

	p := dw.line_program_default()
	p.min_inst_len = 4
	p.files = files
	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 8, line = 2, is_stmt = true},
		{address = 12, end_sequence = true},
	}}}
	check_err("aligned addresses validate at min_inst_len 4", dw.line_validate(&p), .NONE)

	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 6, line = 2, is_stmt = true}, // not a multiple of 4
		{address = 12, end_sequence = true},
	}}}
	check_err("a misaligned address is refused, not truncated",
		dw.line_validate(&p), .MISALIGNED_ADDRESS)

	p.min_inst_len = 0
	check_err("min_inst_len 0 is refused", dw.line_validate(&p), .MISALIGNED_ADDRESS)
}

@(private = "file")
test_unit_length :: proc() {
	rows := []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 4, end_sequence = true},
	}
	unit, _, err := emit_rows(rows)
	check_err("length case emits", err, .NONE)
	unit_length := int(unit[0]) | int(unit[1]) << 8 | int(unit[2]) << 16 | int(unit[3]) << 24
	// `unit_length` counts everything after itself. Off by four here and a
	// consumer reading a second unit starts inside this one.
	check_eq("unit_length excludes its own four bytes", unit_length, len(unit) - 4)
	check_eq("version is 4", int(unit[4]) | int(unit[5]) << 8, 4)
}

@(private = "file")
test_validation :: proc() {
	good := []dw.Row{
		{address = 0, line = 1, is_stmt = true},
		{address = 4, end_sequence = true},
	}

	p := dw.line_program_default()
	p.files = []dw.File{{name = "a.odin", dir = dw.DIR_COMP_DIR}}
	p.sequences = []dw.Sequence{{base_sym = 1, rows = good}}
	check_err("a well-formed program validates", dw.line_validate(&p), .NONE)

	p.version = dw.LINE_VERSION_5
	check_err("version 5 validates", dw.line_validate(&p), .NONE)
	p.version = 6
	check_err("an unimplemented version is refused rather than mis-emitted",
		dw.line_validate(&p), .UNSUPPORTED_VERSION)
	p.version = dw.LINE_VERSION_4

	// The file-number bias is the whole v4/v5 difference and it is checked here
	// rather than only through a decoder, because a decoder disagreeing tells
	// you the table is wrong and this tells you which direction.
	check_eq("v4 numbers files from 1", int(dw.line_file_number(&p, 0)), 1)
	p.version = dw.LINE_VERSION_5
	check_eq("v5 numbers files from 0", int(dw.line_file_number(&p, 0)), 0)
	p.version = dw.LINE_VERSION_4

	files_saved := p.files
	p.files = {}
	check_err("no files", dw.line_validate(&p), .NO_FILES)
	p.files = files_saved

	p.files = []dw.File{{name = "a.odin", dir = 3}}
	check_err("directory index out of range", dw.line_validate(&p), .DIR_INDEX_OUT_OF_RANGE)
	p.files = files_saved

	p.sequences = []dw.Sequence{{base_sym = 1, rows = {}}}
	check_err("empty sequence", dw.line_validate(&p), .EMPTY_SEQUENCE)

	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{{address = 0, line = 1}}}}
	check_err("missing end_sequence", dw.line_validate(&p), .MISSING_END_SEQUENCE)

	// Two sequences crammed into one: properly terminated at the end, but with
	// a terminator in the middle that silently ends the table early.
	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{
		{address = 0, end_sequence = true},
		{address = 4, line = 1},
		{address = 8, end_sequence = true},
	}}}
	check_err("end_sequence not last", dw.line_validate(&p), .END_SEQUENCE_NOT_LAST)

	// Descending addresses would encode as an enormous unsigned advance, so the
	// rows do not go missing -- they land somewhere else entirely.
	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{
		{address = 8, line = 1},
		{address = 4, line = 2},
		{address = 12, end_sequence = true},
	}}}
	check_err("rows out of order", dw.line_validate(&p), .ROWS_OUT_OF_ORDER)

	p.sequences = []dw.Sequence{{base_sym = 1, rows = []dw.Row{
		{address = 0, line = 1, file = 9},
		{address = 4, end_sequence = true},
	}}}
	check_err("file index out of range", dw.line_validate(&p), .FILE_INDEX_OUT_OF_RANGE)
}

// -----------------------------------------------------------------------------
// The externally verified golden unit
// -----------------------------------------------------------------------------

// The golden program, shared by the byte test below and by `-emit` -- the two
// must be the SAME bytes or the external check is measuring something the unit
// test does not lock.
//
// The three slices are file-scope rather than literals inside the proc on
// purpose: a slice literal in a procedure body is backed by that CALL's stack,
// so returning a `Line_Program` holding one hands back a dangling slice. It
// surfaced here as DIR_INDEX_OUT_OF_RANGE -- validation reading a `dirs` that
// had already gone -- which is a good deal politer than what it does in a
// backend that emits from it.
@(private = "file")
golden_dirs := []string{"/src/pkg"}

@(private = "file")
golden_files := []dw.File{
	{name = "main.odin", dir = dw.DIR_COMP_DIR},
	{name = "other.odin", dir = 0},
}

@(private = "file")
golden_rows := []dw.Row{
	{address = 0, file = 0, line = 10, column = 1, is_stmt = true},
	{address = 4, file = 0, line = 10, column = 9},
	{address = 9, file = 0, line = 11, column = 5, is_stmt = true, prologue_end = true},
	{address = 13, file = 0, line = 200, column = 1, is_stmt = true},
	{address = 17, file = 0, line = 199, column = 1, is_stmt = true},
	{address = 21, file = 1, line = 3, column = 1, is_stmt = true},
	{address = 400, file = 0, line = 12, column = 1, is_stmt = true},
	{address = 404, file = 0, line = 12, column = 7},
	{address = 404, file = 0, line = 12, column = 8, epilogue_begin = true},
	{address = 512, end_sequence = true},
}

@(private = "file")
golden_sequences: [1]dw.Sequence

@(private = "file")
golden_program :: proc() -> (dw.Line_Program, []dw.Row) {
	golden_sequences[0] = dw.Sequence{base_sym = 7, rows = golden_rows}
	p := dw.line_program_default()
	p.dirs = golden_dirs
	p.files = golden_files
	p.sequences = golden_sequences[:]
	return p, golden_rows
}

@(private = "file")
test_golden_program :: proc() {
	p, _ := golden_program()
	out: [dynamic]u8
	fx: [dynamic]dw.Fixup
	check_err("golden emits", dw.line_emit(&p, &out, &fx), .NONE)

	check_bytes("golden unit", out[:], {
		0x79, 0x00, 0x00, 0x00, 0x04, 0x00, 0x38, 0x00,
		0x00, 0x00, 0x01, 0x01, 0x01, 0xfb, 0x0e, 0x0d,
		0x00, 0x01, 0x01, 0x01, 0x01, 0x00, 0x00, 0x00,
		0x01, 0x00, 0x00, 0x01, 0x2f, 0x73, 0x72, 0x63,
		0x2f, 0x70, 0x6b, 0x67, 0x00, 0x00, 0x6d, 0x61,
		0x69, 0x6e, 0x2e, 0x6f, 0x64, 0x69, 0x6e, 0x00,
		0x00, 0x00, 0x00, 0x6f, 0x74, 0x68, 0x65, 0x72,
		0x2e, 0x6f, 0x64, 0x69, 0x6e, 0x00, 0x01, 0x00,
		0x00, 0x00, 0x00, 0x09, 0x02, 0x00, 0x00, 0x00,
		0x00, 0x00, 0x00, 0x00, 0x00, 0x05, 0x01, 0x03,
		0x09, 0x01, 0x05, 0x09, 0x06, 0x4a, 0x05, 0x05,
		0x06, 0x0a, 0x59, 0x05, 0x01, 0x03, 0xbd, 0x01,
		0x4a, 0x49, 0x04, 0x02, 0x03, 0xbc, 0x7e, 0x4a,
		0x04, 0x01, 0x03, 0x09, 0x02, 0xfb, 0x02, 0x01,
		0x05, 0x07, 0x06, 0x4a, 0x05, 0x08, 0x0b, 0x01,
		0x02, 0x6c, 0x00, 0x01, 0x01,
	})
}

// The canonical row line every instrument compares on:
//
//	0x<16-hex addr> <line> <col> <file> <discriminator> <flags>
//	0x<16-hex addr> END
//
// `<flags>` is `-`, or some of `s` (is_stmt), `p` (prologue_end), `e`
// (epilogue_begin), `b` (basic_block), always in that order so the string
// compares directly. `<file>` is DWARF's 1-based number -- what a decoder
// prints -- rather than the 0-based index the API takes, so a wrong bias in the
// emitter disagrees with this line rather than hiding behind it.
row_flags :: proc(r: dw.Row) -> string {
	buf: [4]u8
	n := 0
	if r.is_stmt        { buf[n] = 's'; n += 1 }
	if r.prologue_end   { buf[n] = 'p'; n += 1 }
	if r.epilogue_begin { buf[n] = 'e'; n += 1 }
	if r.basic_block    { buf[n] = 'b'; n += 1 }
	if n == 0 {
		return "-"
	}
	return strings.clone(string(buf[:n]), context.temp_allocator)
}

// `-emit <base-hex> <path>`: write the golden unit with its fixup applied as an
// object writer would, and print the rows it is SUPPOSED to decode to. This is
// the producer half of decode-check.sh; the consumer half is an external reader,
// deliberately not one of ours.
@(private = "file")
emit_mode :: proc(base_hex: string, path: string, version: u16) {
	base, base_ok := strconv.parse_u64(base_hex, 16)
	if !base_ok {
		fmt.eprintfln("-emit: %q is not a hex address", base_hex)
		os.exit(2)
	}

	p, rows := golden_program()
	p.version = version
	p.comp_dir = "/src" // v5 writes directory 0; v4 takes it from the CU DIE
	out: [dynamic]u8
	fx: [dynamic]dw.Fixup
	if err := dw.line_emit(&p, &out, &fx); err != .NONE {
		fmt.eprintfln("-emit: %v", err)
		os.exit(1)
	}
	// The object writer's job, done here so the fixup contract is exercised
	// rather than described: symbol 7 was placed at `base`.
	for f in fx {
		if f.kind != .ABS64_SYM {
			continue
		}
		addr := base + u64(f.addend)
		for i in u64(0) ..< 8 {
			out[f.offset + i] = u8(addr >> (8 * i))
		}
	}
	if werr := os.write_entire_file(path, out[:]); werr != nil {
		fmt.eprintfln("-emit: could not write %s: %v", path, werr)
		os.exit(1)
	}
	for r in rows {
		if r.end_sequence {
			fmt.printfln("0x%016x END", base + r.address)
		} else {
			fmt.printfln("0x%016x %d %d %d %d %s", base + r.address, r.line, r.column,
				dw.line_file_number(&p, r.file), r.discriminator, row_flags(r))
		}
	}
}

// `-emit-files <version>`: the file table this emitter INTENDS, as
// `<number><tab><resolved path>`, one per entry.
//
// This exists because every other check compares the file NUMBER a row names
// and never the path that number resolves to. A wrong name, or a right name
// under the wrong directory index, produces a table that decodes cleanly and
// sends the debugger to a file that may not exist. Measured 2026-08-18: a
// corrupted filename byte was injected into a line table and no instrument
// noticed.
//
// Resolution follows what a decoder's table yields, which differs by version:
// v4's directory list has no entry for the compilation directory, so dir_index
// 0 leaves the name bare; v5 writes comp_dir as directory 0, so the same index
// resolves through it.
@(private = "file")
emit_files_mode :: proc(version: u16) {
	p, _ := golden_program()
	p.version = version
	p.comp_dir = "/src"
	for f, i in p.files {
		path: string
		if f.dir == dw.DIR_COMP_DIR {
			path = f.name if version == dw.LINE_VERSION_4 else \
				fmt.tprintf("%s/%s", p.comp_dir, f.name)
		} else {
			path = fmt.tprintf("%s/%s", p.dirs[f.dir], f.name)
		}
		fmt.printfln("%d\t%s", dw.line_file_number(&p, u32(i)), path)
	}
}

main :: proc() {
	if len(os.args) == 3 && os.args[1] == "-emit-files" {
		v, ok := strconv.parse_u64(os.args[2])
		if !ok {
			fmt.eprintfln("-emit-files: bad version %q", os.args[2])
			os.exit(2)
		}
		emit_files_mode(u16(v))
		return
	}
	if len(os.args) >= 2 && os.args[1] == "-emit" {
		if len(os.args) != 4 && len(os.args) != 5 {
			fmt.eprintln("usage: tester -emit <base-hex> <path> [version]")
			os.exit(2)
		}
		version := u16(dw.LINE_VERSION_4)
		if len(os.args) == 5 {
			v, ok := strconv.parse_u64(os.args[4])
			if !ok {
				fmt.eprintfln("-emit: bad version %q", os.args[4])
				os.exit(2)
			}
			version = u16(v)
		}
		emit_mode(os.args[2], os.args[3], version)
		return
	}
	if len(os.args) >= 2 && os.args[1] == "-fuzz" {
		fuzz_main(os.args[2:])
		return
	}
	if len(os.args) >= 2 && os.args[1] == "-reinfo" {
		reinfo_main(os.args[2:])
		return
	}
	if len(os.args) >= 2 && os.args[1] == "-emit-cu" {
		emit_cu_main(os.args[2:])
		return
	}
	if len(os.args) >= 2 && os.args[1] == "-reencode" {
		reencode_main(os.args[2:])
		return
	}

	test_leb128()
	test_special_opcode_boundary()
	test_fixup()
	test_multi_unit()
	test_default_is_stmt()
	test_min_inst_len()
	test_unit_length()
	test_validation()
	test_golden_program()
	test_info()

	fmt.printfln("\n%d passed, %d failed", ok_count, fail_count)
	if fail_count > 0 {
		os.exit(1)
	}
}
