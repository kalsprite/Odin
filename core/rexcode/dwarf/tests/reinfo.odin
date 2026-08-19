// Re-encode a decoded DIE tree with this library.
//
// The `.debug_info` counterpart of reencode.odin, and the same argument for
// existing: the trees come from the REFERENCE compiler, so they have the shape
// real Odin code produces -- hundreds of members, enumerators with negative
// constants, nested aggregates, type references pointing forwards and backwards
// -- rather than a shape someone invented. If the tree survives a round trip
// through this library unchanged, the library can express what the reference
// expresses.
package rexcode_dwarf_tests

import "core:fmt"
import "core:os"
import "core:strconv"
import "core:strings"
import dw ".."

// Input: one line per DIE in pre-order, tab-separated.
//
//	<depth>\t<TAG name>\t<attr>=<value>\t...
//
// `type=<n>` names another DIE by its pre-order INDEX, not by its offset --
// offsets are what a decoder prints and indices are what a builder needs, and
// doing that translation on the reading side is what lets this compare trees
// rather than encodings.
@(private = "file")
tag_of :: proc(name: string) -> (u64, bool) {
	switch name {
	case "DW_TAG_compile_unit":     return dw.DW_TAG_compile_unit, true
	case "DW_TAG_subprogram":       return dw.DW_TAG_subprogram, true
	case "DW_TAG_formal_parameter": return dw.DW_TAG_formal_parameter, true
	case "DW_TAG_variable":         return dw.DW_TAG_variable, true
	case "DW_TAG_lexical_block":    return dw.DW_TAG_lexical_block, true
	case "DW_TAG_base_type":        return dw.DW_TAG_base_type, true
	case "DW_TAG_structure_type":   return dw.DW_TAG_structure_type, true
	case "DW_TAG_union_type":       return dw.DW_TAG_union_type, true
	case "DW_TAG_member":           return dw.DW_TAG_member, true
	case "DW_TAG_pointer_type":     return dw.DW_TAG_pointer_type, true
	case "DW_TAG_array_type":       return dw.DW_TAG_array_type, true
	case "DW_TAG_subrange_type":    return dw.DW_TAG_subrange_type, true
	case "DW_TAG_enumeration_type": return dw.DW_TAG_enumeration_type, true
	case "DW_TAG_enumerator":       return dw.DW_TAG_enumerator, true
	case "DW_TAG_typedef":          return dw.DW_TAG_typedef, true
	case "DW_TAG_const_type":       return dw.DW_TAG_const_type, true
	case "DW_TAG_subroutine_type":  return dw.DW_TAG_subroutine_type, true
	case "DW_TAG_unspecified_parameters": return dw.DW_TAG_unspecified_parameters, true
	}
	return 0, false
}

// Which form each attribute is written in. The comparison is on VALUES, so the
// form is this emitter's choice: a byte size the reference wrote as `data1` and
// we write as `udata` decodes to the same number, and requiring the same form
// would measure encoding taste rather than expressiveness.
@(private = "file")
attr_of :: proc(name: string, value: string, dies: []u32) -> (dw.Attr, bool) {
	num :: proc(v: string) -> u64 { n, _ := strconv.parse_u64(v); return n }
	snum :: proc(v: string) -> i64 { n, _ := strconv.parse_i64(v); return n }

	switch name {
	case "name":         return dw.attr_strp(dw.DW_AT_name, value), true
	case "linkage_name": return dw.attr_strp(dw.DW_AT_linkage_name, value), true
	case "producer":     return dw.attr_strp(dw.DW_AT_producer, value), true
	case "comp_dir":     return dw.attr_strp(dw.DW_AT_comp_dir, value), true
	case "byte_size":    return dw.attr_udata(dw.DW_AT_byte_size, num(value)), true
	case "alignment":    return dw.attr_udata(dw.DW_AT_alignment, num(value)), true
	case "encoding":     return dw.attr_udata(dw.DW_AT_encoding, num(value)), true
	case "decl_line":    return dw.attr_udata(dw.DW_AT_decl_line, num(value)), true
	case "decl_file":    return dw.attr_udata(dw.DW_AT_decl_file, num(value)), true
	case "language":     return dw.attr_udata(dw.DW_AT_language, num(value)), true
	case "bit_size":     return dw.attr_udata(dw.DW_AT_bit_size, num(value)), true
	case "data_bit_offset": return dw.attr_udata(dw.DW_AT_data_bit_offset, num(value)), true
	case "address_class":   return dw.attr_udata(dw.DW_AT_address_class, num(value)), true
	case "data_member_location": return dw.attr_udata(dw.DW_AT_data_member_location, num(value)), true
	case "count":        return dw.attr_udata(dw.DW_AT_count, num(value)), true
	case "upper_bound":  return dw.attr_udata(dw.DW_AT_upper_bound, num(value)), true
	case "high_pc":      return dw.attr_udata(dw.DW_AT_high_pc, num(value)), true
	case "const_value":  return dw.attr_sdata(dw.DW_AT_const_value, snum(value)), true
	case "external":     return dw.attr_flag_present(dw.DW_AT_external), true
	case "prototyped":   return dw.attr_flag_present(dw.DW_AT_prototyped), true
	case "declaration":  return dw.attr_flag_present(dw.DW_AT_declaration), true
	case "type":
		idx := num(value)
		if int(idx) >= len(dies) {
			return {}, false
		}
		return dw.attr_ref(dw.DW_AT_type, dies[idx]), true
	}
	return {}, false
}

// `-reinfo <version> <canon.txt> <outdir>`
//
// Exits 3 -- distinct from a hard failure -- when the input holds a tag or
// attribute this emitter does not write, so the caller counts it as SKIPPED
// rather than as agreement.
@(private = "file")
reinfo_mode :: proc(version_s: string, canon_path: string, outdir: string) {
	v, v_ok := strconv.parse_u64(version_s)
	if !v_ok {
		fmt.eprintfln("-reinfo: bad version %q", version_s)
		os.exit(2)
	}

	data, rerr := os.read_entire_file(canon_path, context.allocator)
	if rerr != nil {
		fmt.eprintfln("-reinfo: could not read %s: %v", canon_path, rerr)
		os.exit(1)
	}
	text := string(data)

	unit: dw.Info_Unit
	dw.info_unit_init(&unit, u16(v))
	defer dw.info_unit_destroy(&unit)

	// A type reference may point FORWARD, so attributes cannot be attached
	// while the tree is being built. Two passes: create every DIE, then attach.
	Pending :: struct {
		die:   u32,
		attrs: []string,
	}
	pending: [dynamic]Pending
	defer {
		for p in pending {
			delete(p.attrs)
		}
		delete(pending)
	}
	dies: [dynamic]u32       // pre-order index -> DIE handle
	stack: [dynamic]u32      // depth -> parent DIE handle
	n_lines := 0

	for raw in strings.split_lines_iterator(&text) {
		line := strings.trim_right_space(raw)
		if line == "" {
			continue
		}
		f := strings.split(line, "\t")
		if len(f) < 2 {
			fmt.eprintfln("-reinfo: malformed line %q", line)
			os.exit(3)
		}
		depth, depth_ok := strconv.parse_int(f[0])
		if !depth_ok {
			fmt.eprintfln("-reinfo: malformed depth in %q", line)
			os.exit(3)
		}
		tag, tag_ok := tag_of(f[1])
		if !tag_ok {
			fmt.eprintfln("-reinfo: unsupported tag %s", f[1])
			os.exit(3)
		}

		parent := dw.NO_PARENT
		if depth > 0 {
			if depth > len(stack) {
				fmt.eprintfln("-reinfo: depth %d with no parent", depth)
				os.exit(3)
			}
			parent = stack[depth - 1]
		}
		die := dw.die_add(&unit, parent, tag)
		append(&dies, die)

		resize(&stack, depth + 1)
		stack[depth] = die

		attrs := make([]string, len(f) - 2)
		copy(attrs, f[2:])
		append(&pending, Pending{die = die, attrs = attrs})
		n_lines += 1
		delete(f)
	}

	if len(dies) == 0 {
		fmt.eprintln("-reinfo: no DIEs in input")
		os.exit(3)
	}

	for p in pending {
		for kv in p.attrs {
			eq := strings.index_byte(kv, '=')
			if eq < 0 {
				fmt.eprintfln("-reinfo: malformed attribute %q", kv)
				os.exit(3)
			}
			a, ok := attr_of(kv[:eq], kv[eq + 1:], dies[:])
			if !ok {
				fmt.eprintfln("-reinfo: unsupported attribute %s", kv[:eq])
				os.exit(3)
			}
			dw.die_attr_add(&unit, p.die, a)
		}
	}

	info_out: [dynamic]u8
	abbrev_out: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)
	fixups: [dynamic]dw.Fixup

	if err := dw.info_emit(&unit, dw.Info_Output{
		info = &info_out, abbrev = &abbrev_out, strs = &strs,
	}, &fixups); err != .NONE {
		fmt.eprintfln("-reinfo: info_emit: %v", err)
		os.exit(3)
	}
	// Only section-relative references can appear here: this tree carries no
	// addresses, by construction of the canonical form.
	for fx in fixups {
		if fx.kind != .SECOFF32 {
			fmt.eprintfln("-reinfo: unexpected fixup kind %v", fx.kind)
			os.exit(1)
		}
		buf := &info_out if fx.section == .DEBUG_INFO else &abbrev_out
		value := u32(fx.addend)
		for i in u64(0) ..< 4 {
			buf[fx.offset + i] = u8(value >> (8 * i))
		}
	}

	write :: proc(dir: string, name: string, bytes: []u8) {
		path := fmt.tprintf("%s/%s", dir, name)
		if werr := os.write_entire_file(path, bytes); werr != nil {
			fmt.eprintfln("-reinfo: could not write %s: %v", path, werr)
			os.exit(1)
		}
	}
	write(outdir, "info.bin", info_out[:])
	write(outdir, "abbrev.bin", abbrev_out[:])
	write(outdir, "str.bin", strs.buf[:])
	fmt.printfln("%d", n_lines)
}

// Dispatched from main in line_test.odin.
reinfo_main :: proc(args: []string) {
	if len(args) != 3 {
		fmt.eprintln("usage: tester -reinfo <version> <canon.txt> <outdir>")
		os.exit(2)
	}
	reinfo_mode(args[0], args[1], args[2])
}
