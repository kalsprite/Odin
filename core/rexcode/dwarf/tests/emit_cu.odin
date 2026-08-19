// Build a complete, synthesised compilation unit -- line table, abbreviations,
// DIEs, types, locations and strings -- describing code that really exists in a
// host binary.
//
// This is the producer half of gdb-check.sh. The file name and line numbers it
// invents appear nowhere in the host's own debug info, which is what makes the
// check meaningful: if gdb answers `break widget.odin:41` with the right
// address, or prints the right value for a local, the only place it can have
// learned that from is the sections this package emitted.
//
// The LOCATIONS are not invented -- they are read out of the host's own debug
// info by the caller and handed here. That is the point: a synthesiser that
// guessed stack offsets would be testing the guess. Reproducing the reference's
// own answer tests the encoding.
package rexcode_dwarf_tests

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strconv"
import "core:strings"
import dw ".."

@(private = "file")
SRC_FILE :: "widget.odin"
@(private = "file")
COMP_DIR :: "/synth"

@(private = "file")
Var :: struct {
	name:    string,
	offset:  i64,    // from the frame base
	type_id: string, // "int", "long" or "pair"
	param:   bool,
	in_block: bool,
}

@(private = "file")
Func :: struct {
	name:      string,
	sym:       u32,
	size:      u64,
	line:      u32,
	frame_reg: u8,
	has_frame: bool,
	block_lo:  u64,
	block_hi:  u64,
	has_block: bool,
	vars:      [dynamic]Var,
	rows:      [dynamic][2]u64, // (offset within the function, our line)
}

@(private = "file")
Global :: struct {
	name:    string,
	sym:     u32,
	type_id: string,
}

@(private = "file")
Spec :: struct {
	syms:    [dynamic]u64, // symbol index -> address
	funcs:   [dynamic]Func,
	globals: [dynamic]Global,
}

@(private = "file")
spec_sym :: proc(s: ^Spec, addr: u64) -> u32 {
	append(&s.syms, addr)
	return u32(len(s.syms) - 1)
}

// The spec language. Keyword-led lines, applied to the most recently declared
// function where that makes sense:
//
//	func     <name> <addr-hex> <size> <our-line>
//	fb       reg <dwarf-register>
//	param    <name> <frame-offset> <int|long|pair>
//	var      <name> <frame-offset> <int|long|pair>
//	block    <low-hex> <high-hex>
//	blockvar <name> <frame-offset> <int|long|pair>
//	row      <addr-hex> <our-line>
//	global   <name> <addr-hex> <int|long|pair>
@(private = "file")
parse_spec :: proc(text_in: string) -> Spec {
	s: Spec
	text := text_in
	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_space(raw)
		if line == "" || strings.has_prefix(line, "#") {
			continue
		}
		f := strings.fields(line)
		defer delete(f)
		cur := len(s.funcs) - 1

		switch f[0] {
		case "func":
			addr, _ := strconv.parse_u64(f[2], 16)
			size, _ := strconv.parse_u64(f[3])
			ln, _ := strconv.parse_u64(f[4])
			append(&s.funcs, Func{
				name = strings.clone(f[1]),
				sym  = spec_sym(&s, addr),
				size = size,
				line = u32(ln),
			})
		case "fb":
			reg, _ := strconv.parse_u64(f[2])
			s.funcs[cur].frame_reg = u8(reg)
			s.funcs[cur].has_frame = true
		case "param", "var", "blockvar":
			off, _ := strconv.parse_i64(f[2])
			append(&s.funcs[cur].vars, Var{
				name     = strings.clone(f[1]),
				offset   = off,
				type_id  = strings.clone(f[3]),
				param    = f[0] == "param",
				in_block = f[0] == "blockvar",
			})
		case "block":
			lo, _ := strconv.parse_u64(f[1], 16)
			hi, _ := strconv.parse_u64(f[2], 16)
			s.funcs[cur].block_lo = lo
			s.funcs[cur].block_hi = hi
			s.funcs[cur].has_block = true
		case "row":
			addr, _ := strconv.parse_u64(f[1], 16)
			ln, _ := strconv.parse_u64(f[2])
			// Attach to whichever function contains the address, which is what
			// lets the caller name a breakpoint by address without tracking
			// which function it fell in.
			for &fn, i in s.funcs {
				base := s.syms[fn.sym]
				if addr >= base && addr < base + fn.size {
					append(&s.funcs[i].rows, [2]u64{addr - base, ln})
					break
				}
			}
		case "global":
			addr, _ := strconv.parse_u64(f[2], 16)
			append(&s.globals, Global{
				name = strings.clone(f[1]),
				sym  = spec_sym(&s, addr),
				type_id = strings.clone(f[3]),
			})
		case:
			fmt.eprintfln("-emit-cu: unknown spec keyword %q", f[0])
			os.exit(2)
		}
	}
	return s
}

// `-emit-cu <version> <spec.txt> <outdir>`
@(private = "file")
emit_cu_mode :: proc(version_s: string, spec_path: string, outdir: string) {
	v, v_ok := strconv.parse_u64(version_s)
	if !v_ok {
		fmt.eprintfln("-emit-cu: bad version %q", version_s)
		os.exit(2)
	}
	version := u16(v)

	data, rerr := os.read_entire_file(spec_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("-emit-cu: could not read %s: %v", spec_path, rerr)
		os.exit(1)
	}
	spec := parse_spec(string(data))
	if len(spec.funcs) == 0 {
		fmt.eprintln("-emit-cu: empty spec")
		os.exit(2)
	}

	// --- the line table ------------------------------------------------------
	//
	// Every row address comes from the caller, which read it out of the host's
	// own line table, so every one lands on an instruction boundary. A row at an
	// address that is not a boundary does not fail -- it puts a breakpoint in
	// the middle of an instruction and corrupts the process.
	files := []dw.File{{name = SRC_FILE, dir = dw.DIR_COMP_DIR}}
	row_sets := make([][dynamic]dw.Row, len(spec.funcs))
	seqs := make([]dw.Sequence, len(spec.funcs))
	for f, i in spec.funcs {
		append(&row_sets[i], dw.Row{
			address = 0, file = 0, line = f.line, column = 1,
			is_stmt = true, prologue_end = true,
		})
		extra := f.rows[:]
		slice.sort_by(extra, proc(a, b: [2]u64) -> bool { return a[0] < b[0] })
		for r in extra {
			append(&row_sets[i], dw.Row{
				address = r[0], file = 0, line = u32(r[1]), column = 1, is_stmt = true,
			})
		}
		append(&row_sets[i], dw.Row{address = f.size, end_sequence = true})
		seqs[i] = dw.Sequence{base_sym = f.sym, rows = row_sets[i][:]}
	}

	lp := dw.line_program_default()
	lp.version = version
	lp.comp_dir = COMP_DIR
	lp.files = files
	lp.sequences = seqs

	line_out: [dynamic]u8
	fixups: [dynamic]dw.Fixup
	if err := dw.line_emit(&lp, &line_out, &fixups); err != .NONE {
		fmt.eprintfln("-emit-cu: line_emit: %v", err)
		os.exit(1)
	}

	// --- the DIE tree --------------------------------------------------------
	unit: dw.Info_Unit
	dw.info_unit_init(&unit, version)
	defer dw.info_unit_destroy(&unit)

	cu := dw.die_add(&unit, dw.NO_PARENT, dw.DW_TAG_compile_unit,
		dw.attr_strp(dw.DW_AT_producer, "rexcode/dwarf"),
		dw.attr_data2(dw.DW_AT_language, dw.DW_LANG_C99),
		dw.attr_strp(dw.DW_AT_name, SRC_FILE),
		dw.attr_strp(dw.DW_AT_comp_dir, COMP_DIR),
		dw.attr_sec_offset(dw.DW_AT_stmt_list, .DEBUG_LINE),
	)

	// Base types. A debugger formats a value entirely from these -- byte size
	// says how much to read and the encoding says how to read it, so a `long`
	// declared with DW_ATE_unsigned prints 18446744073709551574 for -42.
	t_int := dw.die_add(&unit, cu, dw.DW_TAG_base_type,
		dw.attr_strp(dw.DW_AT_name, "int"),
		dw.attr_data1(dw.DW_AT_byte_size, 4),
		dw.attr_data1(dw.DW_AT_encoding, dw.DW_ATE_signed))
	t_long := dw.die_add(&unit, cu, dw.DW_TAG_base_type,
		dw.attr_strp(dw.DW_AT_name, "long"),
		dw.attr_data1(dw.DW_AT_byte_size, 8),
		dw.attr_data1(dw.DW_AT_encoding, dw.DW_ATE_signed))

	// An aggregate: members carry their own offset, so the debugger needs no
	// layout rules of its own.
	t_pair := dw.die_add(&unit, cu, dw.DW_TAG_structure_type,
		dw.attr_strp(dw.DW_AT_name, "widget_pair"),
		dw.attr_data1(dw.DW_AT_byte_size, 16))
	dw.die_add(&unit, t_pair, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "a"),
		dw.attr_ref(dw.DW_AT_type, t_int),
		dw.attr_data1(dw.DW_AT_data_member_location, 0))
	dw.die_add(&unit, t_pair, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "b"),
		dw.attr_ref(dw.DW_AT_type, t_long),
		dw.attr_data1(dw.DW_AT_data_member_location, 8))

	// A typedef over the struct, which is what the reference emits for the C
	// typedef in the host -- and what a producer must emit for a language whose
	// type names are not C tags. Under DW_LANG_C99 a DW_TAG_structure_type's
	// name is a TAG: gdb answers `ptype widget_pair` with "No symbol
	// widget_pair in current context" unless a typedef puts the name in the
	// ordinary namespace too. Measured 2026-08-18; see doc.odin.
	dw.die_add(&unit, cu, dw.DW_TAG_typedef,
		dw.attr_strp(dw.DW_AT_name, "widget_pair"),
		dw.attr_ref(dw.DW_AT_type, t_pair))

	// The rest of the aggregate vocabulary. Each is here because a debugger
	// formats it differently and therefore proves a different part of the DIE
	// tree -- an array needs a subrange to have a length at all, a pointer needs
	// a target type before it can be dereferenced, an enumeration needs its
	// enumerators before a value can be shown as a name.
	t_char := dw.die_add(&unit, cu, dw.DW_TAG_base_type,
		dw.attr_strp(dw.DW_AT_name, "char"),
		dw.attr_data1(dw.DW_AT_byte_size, 1),
		dw.attr_data1(dw.DW_AT_encoding, dw.DW_ATE_signed_char))
	t_charp := dw.die_add(&unit, cu, dw.DW_TAG_pointer_type,
		dw.attr_data1(dw.DW_AT_byte_size, 8),
		dw.attr_ref(dw.DW_AT_type, t_char))
	t_intp := dw.die_add(&unit, cu, dw.DW_TAG_pointer_type,
		dw.attr_data1(dw.DW_AT_byte_size, 8),
		dw.attr_ref(dw.DW_AT_type, t_int))

	// An array's length lives in a child subrange, not on the array itself.
	t_arr4 := dw.die_add(&unit, cu, dw.DW_TAG_array_type,
		dw.attr_ref(dw.DW_AT_type, t_int))
	dw.die_add(&unit, t_arr4, dw.DW_TAG_subrange_type,
		dw.attr_udata(dw.DW_AT_count, 4))

	// A union is a struct whose members all sit at offset 0 -- which is exactly
	// how it is spelled, and exactly the shape Odin's tagged union wraps.
	t_uni := dw.die_add(&unit, cu, dw.DW_TAG_union_type,
		dw.attr_strp(dw.DW_AT_name, "widget_union"),
		dw.attr_data1(dw.DW_AT_byte_size, 8))
	dw.die_add(&unit, t_uni, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "i"), dw.attr_ref(dw.DW_AT_type, t_int),
		dw.attr_data1(dw.DW_AT_data_member_location, 0))
	dw.die_add(&unit, t_uni, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "l"), dw.attr_ref(dw.DW_AT_type, t_long),
		dw.attr_data1(dw.DW_AT_data_member_location, 0))
	dw.die_add(&unit, cu, dw.DW_TAG_typedef,
		dw.attr_strp(dw.DW_AT_name, "widget_union"), dw.attr_ref(dw.DW_AT_type, t_uni))

	t_enum := dw.die_add(&unit, cu, dw.DW_TAG_enumeration_type,
		dw.attr_strp(dw.DW_AT_name, "widget_colour"),
		dw.attr_data1(dw.DW_AT_byte_size, 4),
		dw.attr_ref(dw.DW_AT_type, t_int))
	dw.die_add(&unit, t_enum, dw.DW_TAG_enumerator,
		dw.attr_strp(dw.DW_AT_name, "W_RED"), dw.attr_sdata(dw.DW_AT_const_value, 0))
	dw.die_add(&unit, t_enum, dw.DW_TAG_enumerator,
		dw.attr_strp(dw.DW_AT_name, "W_GREEN"), dw.attr_sdata(dw.DW_AT_const_value, 7))
	dw.die_add(&unit, cu, dw.DW_TAG_typedef,
		dw.attr_strp(dw.DW_AT_name, "widget_colour"), dw.attr_ref(dw.DW_AT_type, t_enum))

	// Odin's `string` and `[]T` are both a pointer and a length, two words, and
	// this is the DIE shape they need: an ordinary struct. Nothing about them
	// requires a language extension -- which is the useful thing to know.
	t_str := dw.die_add(&unit, cu, dw.DW_TAG_structure_type,
		dw.attr_strp(dw.DW_AT_name, "widget_string"),
		dw.attr_data1(dw.DW_AT_byte_size, 16))
	dw.die_add(&unit, t_str, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "data"), dw.attr_ref(dw.DW_AT_type, t_charp),
		dw.attr_data1(dw.DW_AT_data_member_location, 0))
	dw.die_add(&unit, t_str, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "len"), dw.attr_ref(dw.DW_AT_type, t_long),
		dw.attr_data1(dw.DW_AT_data_member_location, 8))
	dw.die_add(&unit, cu, dw.DW_TAG_typedef,
		dw.attr_strp(dw.DW_AT_name, "widget_string"), dw.attr_ref(dw.DW_AT_type, t_str))

	// Odin's tagged union is `struct { payload: union{...}, tag }`, so its DIE
	// is a struct with a MEMBER WHOSE TYPE IS ANOTHER AGGREGATE. That is the one
	// structural thing the shapes above do not exercise: every member so far has
	// pointed at a base type or a pointer.
	t_tagged := dw.die_add(&unit, cu, dw.DW_TAG_structure_type,
		dw.attr_strp(dw.DW_AT_name, "widget_tagged"),
		dw.attr_data1(dw.DW_AT_byte_size, 16))
	dw.die_add(&unit, t_tagged, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "u"), dw.attr_ref(dw.DW_AT_type, t_uni),
		dw.attr_data1(dw.DW_AT_data_member_location, 0))
	dw.die_add(&unit, t_tagged, dw.DW_TAG_member,
		dw.attr_strp(dw.DW_AT_name, "tag"), dw.attr_ref(dw.DW_AT_type, t_int),
		dw.attr_data1(dw.DW_AT_data_member_location, 8))
	dw.die_add(&unit, cu, dw.DW_TAG_typedef,
		dw.attr_strp(dw.DW_AT_name, "widget_tagged"), dw.attr_ref(dw.DW_AT_type, t_tagged))

	Types :: struct {
		int_, long_, pair, arr4, intp, uni, enum_, str, tagged: u32,
	}
	types := Types{
		int_ = t_int, long_ = t_long, pair = t_pair, arr4 = t_arr4,
		intp = t_intp, uni = t_uni, enum_ = t_enum, str = t_str, tagged = t_tagged,
	}
	type_of :: proc(id: string, t: Types) -> u32 {
		switch id {
		case "long": return t.long_
		case "pair": return t.pair
		case "arr4": return t.arr4
		case "intp": return t.intp
		case "uni":  return t.uni
		case "enum": return t.enum_
		case "str":  return t.str
		case "tagged": return t.tagged
		}
		return t.int_
	}

	// Expressions are borrowed by the attributes that reference them, so they
	// must outlive info_emit -- hence one arena-ish list rather than locals.
	exprs: [dynamic]^dw.Expr
	defer {
		for e in exprs {
			dw.expr_destroy(e)
			free(e)
		}
		delete(exprs)
	}
	new_expr :: proc(exprs: ^[dynamic]^dw.Expr) -> ^dw.Expr {
		e := new(dw.Expr)
		append(exprs, e)
		return e
	}

	for f in spec.funcs {
		attrs: [dynamic]dw.Attr
		defer delete(attrs)
		append(&attrs,
			dw.attr_strp(dw.DW_AT_name, f.name),
			dw.attr_addr(dw.DW_AT_low_pc, f.sym),
			dw.attr_data8(dw.DW_AT_high_pc, f.size),
			dw.attr_ref(dw.DW_AT_type, t_int),
			dw.attr_udata(dw.DW_AT_decl_file, dw.line_file_number(&lp, 0)),
			dw.attr_udata(dw.DW_AT_decl_line, u64(f.line)),
			dw.attr_flag_present(dw.DW_AT_external),
			dw.attr_flag_present(dw.DW_AT_prototyped))
		if f.has_frame {
			// DW_OP_reg6 -- "the frame base IS the value in RBP". This needs no
			// unwind tables, which is why it is the right shape for a backend
			// that keeps a frame pointer and emits no CFI.
			fb := new_expr(&exprs)
			dw.expr_reg(fb, f.frame_reg)
			append(&attrs, dw.attr_expr(dw.DW_AT_frame_base, fb))
		}
		sp := dw.die_add(&unit, cu, dw.DW_TAG_subprogram, ..attrs[:])

		block := u32(0)
		if f.has_block {
			blo := new_expr(&exprs) // unused, but keeps the pattern uniform
			_ = blo
			block = dw.die_add(&unit, sp, dw.DW_TAG_lexical_block,
				dw.attr_addr(dw.DW_AT_low_pc, spec_sym(&spec, f.block_lo)),
				dw.attr_data8(dw.DW_AT_high_pc, f.block_hi - f.block_lo))
		}

		for v in f.vars {
			loc := new_expr(&exprs)
			dw.expr_fbreg(loc, v.offset)
			parent := block if v.in_block && f.has_block else sp
			tag := v.param ? dw.DW_TAG_formal_parameter : dw.DW_TAG_variable
			dw.die_add(&unit, parent, tag,
				dw.attr_strp(dw.DW_AT_name, v.name),
				dw.attr_ref(dw.DW_AT_type, type_of(v.type_id, types)),
				dw.attr_expr(dw.DW_AT_location, loc))
		}
	}

	for g in spec.globals {
		loc := new_expr(&exprs)
		dw.expr_addr(loc, g.sym)
		dw.die_add(&unit, cu, dw.DW_TAG_variable,
			dw.attr_strp(dw.DW_AT_name, g.name),
			dw.attr_ref(dw.DW_AT_type, type_of(g.type_id, types)),
			dw.attr_expr(dw.DW_AT_location, loc),
			dw.attr_flag_present(dw.DW_AT_external))
	}

	info_out: [dynamic]u8
	abbrev_out: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)

	if err := dw.info_emit(&unit, dw.Info_Output{
		info = &info_out, abbrev = &abbrev_out, strs = &strs,
	}, &fixups); err != .NONE {
		fmt.eprintfln("-emit-cu: info_emit: %v", err)
		os.exit(1)
	}

	// --- the object writer's half -------------------------------------------
	for fx in fixups {
		buf: ^[dynamic]u8
		switch fx.section {
		case .DEBUG_LINE:   buf = &line_out
		case .DEBUG_INFO:   buf = &info_out
		case .DEBUG_ABBREV: buf = &abbrev_out
		case .DEBUG_STR, .TEXT:
			fmt.eprintfln("-emit-cu: unexpected fixup in %v", fx.section)
			os.exit(1)
		}
		switch fx.kind {
		case .ABS64_SYM:
			addr := spec.syms[fx.sym] + u64(fx.addend)
			for i in u64(0) ..< 8 {
				buf[fx.offset + i] = u8(addr >> (8 * i))
			}
		case .SECOFF32:
			// Each section is injected whole and starts at offset 0 of itself,
			// so a section-relative reference resolves to its own addend.
			value := u32(fx.addend)
			for i in u64(0) ..< 4 {
				buf[fx.offset + i] = u8(value >> (8 * i))
			}
		}
	}

	write :: proc(dir: string, name: string, bytes: []u8) {
		path := fmt.tprintf("%s/%s", dir, name)
		if werr := os.write_entire_file(path, bytes); werr != nil {
			fmt.eprintfln("-emit-cu: could not write %s: %v", path, werr)
			os.exit(1)
		}
	}
	write(outdir, "line.bin", line_out[:])
	write(outdir, "info.bin", info_out[:])
	write(outdir, "abbrev.bin", abbrev_out[:])
	write(outdir, "str.bin", strs.buf[:])

	fmt.printfln("%s %d %d %d %d", SRC_FILE, len(line_out), len(info_out), len(abbrev_out),
		len(strs.buf))
}

// Dispatched from main in line_test.odin.
emit_cu_main :: proc(args: []string) {
	if len(args) != 3 {
		fmt.eprintln("usage: tester -emit-cu <version> <spec.txt> <outdir>")
		os.exit(2)
	}
	emit_cu_mode(args[0], args[1], args[2])
}
