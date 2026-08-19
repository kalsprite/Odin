// Randomised `.debug_line` generation, for the external-decoder oracle to chew
// on at a scale hand-written cases do not reach.
//
// The hand-written tests cover the shapes someone thought of. What they cannot
// cover is the INTERACTION between them -- a file switch on the same row as a
// negative line advance that also crosses the special-opcode address boundary --
// and a line program is a state machine, so interactions are exactly where it
// breaks. Every generated program is emitted, decoded by a reader that is not
// ours, and required to equal what the generator intended.
//
// Deterministic by construction: the PRNG is written out here rather than taken
// from `core:math/rand`, so a seed reproduces a failure exactly regardless of
// what the standard library's generator does between versions. A failing seed is
// the whole bug report.
package rexcode_dwarf_tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import dw ".."

// splitmix64. Chosen because it is eight lines, has no state beyond a u64, and
// is not going to be the thing that is wrong.
@(private = "file")
rng_state: u64

@(private = "file")
rng_next :: proc() -> u64 {
	rng_state += 0x9e3779b97f4a7c15
	z := rng_state
	z = (z ~ (z >> 30)) * 0xbf58476d1ce4e5b9
	z = (z ~ (z >> 27)) * 0x94d049bb133111eb
	return z ~ (z >> 31)
}

@(private = "file")
rng_below :: proc(n: u64) -> u64 {
	return rng_next() % n
}

// The file and directory tables every generated unit draws from. File-scope
// because a slice literal in a procedure body dies with the call.
@(private = "file")
fuzz_names := []string{"alpha.odin", "beta.odin", "gamma.odin", "delta.odin"}

@(private = "file")
fuzz_dirs := []string{"/src/one", "/src/two"}

// One sequence's rows. Returns the end address, so the caller can lay the next
// sequence out past this one.
@(private = "file")
gen_sequence :: proc(rows: ^[dynamic]dw.Row, n_files: u32, min_inst_len: u64) -> u64 {
	n := 1 + rng_below(40)
	addr := u64(0)
	line := u32(1 + rng_below(200))

	for _ in 0 ..< n {
		// Address advance, weighted to straddle the boundaries that select
		// between a special opcode, DW_LNS_const_add_pc and DW_LNS_advance_pc.
		// Deltas are whole instruction units: a fixed-width target advances the
		// program counter in multiples of min_inst_len and nothing else is
		// representable.
		switch rng_below(10) {
		case 0:
			// No advance: a second row at the same address, which is what
			// DW_LNS_copy exists for.
		case 1 ..= 6:
			addr += (1 + rng_below(20)) * min_inst_len
		case 7, 8:
			addr += (21 + rng_below(300)) * min_inst_len
		case:
			addr += (1000 + rng_below(100_000)) * min_inst_len
		}

		// Line advance, weighted the same way: mostly small deltas a special
		// opcode can carry, sometimes a jump that forces DW_LNS_advance_line,
		// sometimes line 0 which means "no source line here".
		switch rng_below(10) {
		case 0:
			line = 0
		case 1 ..= 7:
			delta := i64(rng_below(21)) - 10
			next := i64(line) + delta
			if next < 0 {
				next = 0
			}
			line = u32(next)
		case:
			line = u32(1 + rng_below(1_000_000))
		}

		// Discriminators are mostly absent, as they are in real tables, but
		// present often enough to exercise the extended opcode and its ULEB
		// operand at more than one width.
		disc := u32(0)
		switch rng_below(12) {
		case 0:
			disc = u32(1 + rng_below(6))
		case 1:
			disc = u32(200 + rng_below(100_000))
		}

		append(rows, dw.Row{
			address        = addr,
			file           = u32(rng_below(u64(n_files))),
			line           = line,
			column         = u32(rng_below(200)),
			is_stmt        = rng_below(3) != 0,
			prologue_end   = rng_below(8) == 0,
			epilogue_begin = rng_below(8) == 0,
			basic_block    = rng_below(6) == 0,
			discriminator  = disc,
		})
	}

	addr += (1 + rng_below(64)) * min_inst_len
	append(rows, dw.Row{address = addr, end_sequence = true})
	return addr
}

// `-fuzz <seed> <units> <out.bin> <out.intent>`
//
// Emits `units` line-table units into ONE buffer, which is also what makes this
// the instrument for several units sharing a section: fixup offsets are absolute
// within the section, so a unit after the first has unit-relative offsets that
// no longer equal its section-relative ones. If that is wrong, every sequence
// after the first lands at the wrong address and the diff says so.
@(private = "file")
fuzz_mode :: proc(seed_s: string, units_s: string, bin_path: string, intent_path: string, version: u16) {
	seed, seed_ok := strconv.parse_u64(seed_s)
	units, units_ok := strconv.parse_int(units_s)
	if !seed_ok || !units_ok || units <= 0 {
		fmt.eprintfln("-fuzz: bad seed %q or unit count %q", seed_s, units_s)
		os.exit(2)
	}
	rng_state = seed

	out: [dynamic]u8
	fixups: [dynamic]dw.Fixup
	intent := strings.builder_make()

	// Sequence bases are handed out in emission order and spaced past each
	// sequence's own span, so no two sequences overlap and a row decoded at the
	// wrong address cannot coincidentally land on a right one.
	sym_addr: [dynamic]u64
	next_base := u64(0x400000)
	total_sequences := 0

	for _ in 0 ..< units {
		n_files := u32(1 + rng_below(u64(len(fuzz_names))))
		n_dirs := int(rng_below(u64(len(fuzz_dirs)) + 1))
		n_seqs := int(1 + rng_below(8))
		// A fixed-width ISA reports 2 or 4 here; x86 reports 1. It changes the
		// unit every address advance is measured in.
		min_inst_len := u64(1)
		switch rng_below(4) {
		case 1: min_inst_len = 2
		case 2: min_inst_len = 4
		}
		// The initial value of the `is_stmt` register. A unit that starts false
		// exercises the rows that rely on the initial value rather than on a
		// DW_LNS_negate_stmt having already run.
		default_is_stmt := rng_below(4) != 0

		files := make([]dw.File, n_files)
		for i in 0 ..< int(n_files) {
			dir := dw.DIR_COMP_DIR
			if n_dirs > 0 && rng_below(2) == 0 {
				dir = u32(rng_below(u64(n_dirs)))
			}
			files[i] = dw.File{name = fuzz_names[i], dir = dir}
		}

		row_sets := make([][dynamic]dw.Row, n_seqs)
		spans := make([]u64, n_seqs)
		for i in 0 ..< n_seqs {
			spans[i] = gen_sequence(&row_sets[i], n_files, min_inst_len)
		}

		seqs := make([]dw.Sequence, n_seqs)
		for i in 0 ..< n_seqs {
			seqs[i] = dw.Sequence{base_sym = u32(len(sym_addr)), rows = row_sets[i][:]}
			append(&sym_addr, next_base)
			next_base += spans[i] + 0x1000
			total_sequences += 1
		}

		p := dw.line_program_default()
		p.version = version
		p.min_inst_len = u8(min_inst_len)
		p.default_is_stmt = default_is_stmt
		p.comp_dir = "/fuzz"
		p.dirs = fuzz_dirs[:n_dirs]
		p.files = files
		p.sequences = seqs
		if err := dw.line_emit(&p, &out, &fixups); err != .NONE {
			fmt.eprintfln("-fuzz: emit failed with seed %d: %v", seed, err)
			os.exit(1)
		}

		// The intent, in the order a decoder will report it.
		for i in 0 ..< n_seqs {
			base := sym_addr[len(sym_addr) - n_seqs + i]
			for r in row_sets[i] {
				if r.end_sequence {
					fmt.sbprintfln(&intent, "0x%016x END", base + r.address)
				} else {
					// `r.file + 1` is the number a DECODER reports: `Row.file` is
					// a 0-based index into our table and DWARF 4 numbers files
					// from 1. Writing the expected number here rather than the
					// index is what makes the bias checkable -- an emitter that
					// biased by 0 or by 2 disagrees with this line.
					fmt.sbprintfln(&intent, "0x%016x %d %d %d %d %s", base + r.address,
						r.line, r.column, dw.line_file_number(&p, r.file), r.discriminator,
						row_flags(r))
				}
			}
		}
	}

	// The object writer's half of the contract.
	for f in fixups {
		if f.kind != .ABS64_SYM {
			continue
		}
		addr := sym_addr[f.sym] + u64(f.addend)
		for i in u64(0) ..< 8 {
			out[f.offset + i] = u8(addr >> (8 * i))
		}
	}

	if werr := os.write_entire_file(bin_path, out[:]); werr != nil {
		fmt.eprintfln("-fuzz: could not write %s: %v", bin_path, werr)
		os.exit(1)
	}
	if werr := os.write_entire_file(intent_path, strings.to_string(intent)); werr != nil {
		fmt.eprintfln("-fuzz: could not write %s: %v", intent_path, werr)
		os.exit(1)
	}
	fmt.printfln("%d", total_sequences)
}

// Dispatched from main in line_test.odin.
fuzz_main :: proc(args: []string) {
	if len(args) != 4 && len(args) != 5 {
		fmt.eprintln("usage: tester -fuzz <seed> <units> <out.bin> <out.intent> [version]")
		os.exit(2)
	}
	version := u16(dw.LINE_VERSION_4)
	if len(args) == 5 {
		v, ok := strconv.parse_u64(args[4])
		if !ok {
			fmt.eprintfln("-fuzz: bad version %q", args[4])
			os.exit(2)
		}
		version = u16(v)
	}
	fuzz_mode(args[0], args[1], args[2], args[3], version)
}
