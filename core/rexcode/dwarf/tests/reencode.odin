// Re-encode mode: read a decoded line table and emit it again with this library.
//
// This is the producer half of parity-check.sh, and the reason that instrument
// is worth more than the fuzzer: the rows come from the REFERENCE compiler's own
// debug info, so they are real row sequences with the distribution real code
// produces -- prologues, epilogues, line-0 compiler-generated ranges, basic
// blocks, tight clusters at the same address -- rather than a distribution
// someone invented. If decode(re-encode(reference rows)) equals the reference
// rows, this encoder expresses everything the reference expresses.
package rexcode_dwarf_tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import dw ".."

// Input format, one row per line, sequences terminated by an END row:
//
//	0x<addr> END
//	0x<addr> <line> <col> <file> <disc> <flags>
//
// `<flags>` is `-` or some of `s` (is_stmt), `p` (prologue_end),
// `e` (epilogue_begin), `b` (basic_block). `<file>` is DWARF's own 1-based
// number, which is what a decoder prints; it is biased back to a 0-based index
// here, and biasing it wrong is exactly what parity-check would catch.
// The version being re-encoded into. Set once by `reencode_mode` before any
// parsing, because it changes how a decoder's file NUMBER maps onto our index.
@(private = "file")
reencode_version: u16 = dw.LINE_VERSION_4

@(private = "file")
parse_row :: proc(line: string) -> (row: dw.Row, ok: bool) {
	f := strings.fields(line)
	defer delete(f)
	if len(f) == 0 {
		return {}, false
	}
	addr := strconv.parse_u64(f[0][2:], 16) or_return
	if len(f) == 2 && f[1] == "END" {
		return dw.Row{address = addr, end_sequence = true}, true
	}
	if len(f) != 6 {
		return {}, false
	}
	line_no := strconv.parse_u64(f[1]) or_return
	col := strconv.parse_u64(f[2]) or_return
	file_no := strconv.parse_u64(f[3]) or_return
	disc := strconv.parse_u64(f[4]) or_return
	if file_no == 0 && reencode_version == dw.LINE_VERSION_4 {
		// DWARF 4 treats file 0 as invalid. Silently shifting it by one would
		// produce a table that decodes cleanly and attributes every row to the
		// wrong file, so refuse instead and let the caller count it as skipped.
		return {}, false
	}
	// The number the reference reported has to come back out of OUR table as the
	// same number, so the index it maps to depends on the version being emitted:
	// v4 numbers from 1, v5 from 0.
	index := file_no if reencode_version == dw.LINE_VERSION_5 else file_no - 1
	flags := f[5]
	return dw.Row{
		address        = addr,
		line           = u32(line_no),
		column         = u32(col),
		file           = u32(index),
		discriminator  = u32(disc),
		is_stmt        = strings.contains(flags, "s"),
		prologue_end   = strings.contains(flags, "p"),
		epilogue_begin = strings.contains(flags, "e"),
		basic_block    = strings.contains(flags, "b"),
	}, true
}

// `-reencode <rows.txt> <out.bin>`
//
// Prints a one-line summary to stdout: rows read, sequences built, and the
// highest file number seen. Exits 3 -- distinct from a hard failure -- when the
// input holds something this emitter cannot express, so the caller can count it
// as SKIPPED rather than as agreement.
@(private = "file")
reencode_mode :: proc(rows_path: string, bin_path: string, version: u16) {
	reencode_version = version
	data, rerr := os.read_entire_file(rows_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("-reencode: could not read %s: %v", rows_path, rerr)
		os.exit(1)
	}
	defer delete(data)
	text := string(data)

	all_rows: [dynamic][dynamic]dw.Row
	current: [dynamic]dw.Row
	max_file := u32(0)
	n_rows := 0

	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" {
			continue
		}
		row, ok := parse_row(line)
		if !ok {
			fmt.eprintfln("-reencode: unparsable or inexpressible row: %s", line)
			os.exit(3)
		}
		n_rows += 1
		if !row.end_sequence && row.file + 1 > max_file {
			max_file = row.file + 1
		}
		append(&current, row)
		if row.end_sequence {
			append(&all_rows, current)
			current = nil
		}
	}
	if len(current) > 0 {
		// A trailing run with no terminator. The reference always terminates, so
		// this means the dump was truncated; refusing beats inventing an end.
		fmt.eprintln("-reencode: input ends without an end_sequence row")
		os.exit(3)
	}
	if len(all_rows) == 0 {
		fmt.eprintln("-reencode: no sequences in input")
		os.exit(3)
	}
	if max_file == 0 {
		max_file = 1
	}

	// Names do not matter -- the comparison is on file NUMBERS, which is what a
	// decoder reports per row. The table just has to be long enough that every
	// number the reference used is in range.
	files := make([]dw.File, max_file)
	for i in 0 ..< int(max_file) {
		files[i] = dw.File{name = fmt.aprintf("f%d.odin", i + 1), dir = dw.DIR_COMP_DIR}
	}

	// Each sequence keeps the reference's own absolute addresses: its base is
	// its first row's address and the rest become offsets from that. Sequences
	// in a relocatable object all start at 0, which is fine -- overlapping
	// sequences are legal and the comparison is order-sensitive.
	seqs := make([]dw.Sequence, len(all_rows))
	bases := make([]u64, len(all_rows))
	for i in 0 ..< len(all_rows) {
		rows := all_rows[i]
		base := rows[0].address
		bases[i] = base
		for &r in rows {
			if r.address < base {
				fmt.eprintfln("-reencode: sequence %d is not ascending", i)
				os.exit(3)
			}
			r.address -= base
		}
		seqs[i] = dw.Sequence{base_sym = u32(i), rows = rows[:]}
	}

	p := dw.line_program_default()
	p.version = version
	p.comp_dir = "/reencode"
	p.files = files
	p.sequences = seqs

	out: [dynamic]u8
	fx: [dynamic]dw.Fixup
	if err := dw.line_emit(&p, &out, &fx); err != .NONE {
		fmt.eprintfln("-reencode: emit failed: %v", err)
		os.exit(3)
	}
	for f in fx {
		if f.kind != .ABS64_SYM {
			continue
		}
		addr := bases[f.sym] + u64(f.addend)
		for i in u64(0) ..< 8 {
			out[f.offset + i] = u8(addr >> (8 * i))
		}
	}
	if werr := os.write_entire_file(bin_path, out[:]); werr != nil {
		fmt.eprintfln("-reencode: could not write %s: %v", bin_path, werr)
		os.exit(1)
	}
	fmt.printfln("%d %d %d", n_rows, len(all_rows), max_file)
}

// Dispatched from main in line_test.odin.
reencode_main :: proc(args: []string) {
	if len(args) != 2 && len(args) != 3 {
		fmt.eprintln("usage: tester -reencode <rows.txt> <out.bin> [version]")
		os.exit(2)
	}
	version := u16(dw.LINE_VERSION_4)
	if len(args) == 3 {
		v, ok := strconv.parse_u64(args[2])
		if !ok {
			fmt.eprintfln("-reencode: bad version %q", args[2])
			os.exit(2)
		}
		version = u16(v)
	}
	reencode_mode(args[0], args[1], version)
}
