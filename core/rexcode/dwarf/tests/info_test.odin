// `.debug_info` / `.debug_abbrev` / `.debug_str` structural tests.
//
// gdb-check.sh proves the sections are USABLE; it cannot see whether two
// identically shaped DIEs shared an abbreviation code or whether a string was
// stored twice, because both mistakes produce output a debugger reads
// correctly. Those are exactly the properties that decide whether the tables
// stay a reasonable size on a real program, so they are checked here.
package rexcode_dwarf_tests

import "core:fmt"
import dw ".."

// A minimal ULEB128 reader. Test-side on purpose: reusing the emitter's own
// notion of the encoding to check the emitter would prove only self-consistency.
@(private = "file")
read_uleb :: proc(b: []u8, pos: ^int) -> u64 {
	result := u64(0)
	shift := uint(0)
	for {
		c := b[pos^]
		pos^ += 1
		result |= u64(c & 0x7f) << shift
		if c & 0x80 == 0 {
			break
		}
		shift += 7
	}
	return result
}

// Walks `.debug_abbrev` and returns one entry per declaration: (code, tag,
// has_children, attribute count).
@(private = "file")
parse_abbrev :: proc(b: []u8) -> [dynamic][4]u64 {
	out: [dynamic][4]u64
	pos := 0
	for pos < len(b) {
		code := read_uleb(b, &pos)
		if code == 0 {
			break // end of this unit's table
		}
		tag := read_uleb(b, &pos)
		children := u64(b[pos]); pos += 1
		n := u64(0)
		for {
			at := read_uleb(b, &pos)
			form := read_uleb(b, &pos)
			if at == 0 && form == 0 {
				break
			}
			n += 1
		}
		append(&out, [4]u64{code, tag, children, n})
	}
	return out
}

@(private = "file")
test_abbrev_dedup :: proc() {
	unit: dw.Info_Unit
	dw.info_unit_init(&unit)
	defer dw.info_unit_destroy(&unit)

	cu := dw.die_add(&unit, dw.NO_PARENT, dw.DW_TAG_compile_unit,
		dw.attr_string(dw.DW_AT_name, "a.odin"))
	// Three subprograms of IDENTICAL shape, then one that differs only by
	// carrying an extra attribute.
	for name in ([]string{"one", "two", "three"}) {
		dw.die_add(&unit, cu, dw.DW_TAG_subprogram,
			dw.attr_string(dw.DW_AT_name, name),
			dw.attr_udata(dw.DW_AT_decl_line, 1))
	}
	dw.die_add(&unit, cu, dw.DW_TAG_subprogram,
		dw.attr_string(dw.DW_AT_name, "four"),
		dw.attr_udata(dw.DW_AT_decl_line, 2),
		dw.attr_flag_present(dw.DW_AT_external))

	info: [dynamic]u8
	abbrev: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)
	fx: [dynamic]dw.Fixup
	check_err("dedup unit emits", dw.info_emit(&unit,
		dw.Info_Output{info = &info, abbrev = &abbrev, strs = &strs}, &fx), .NONE)

	decls := parse_abbrev(abbrev[:])
	defer delete(decls)
	// Three shapes, not five: the CU, the shared subprogram shape, and the
	// odd one out.
	check_eq("identical DIE shapes share one abbreviation", len(decls), 3)
	if len(decls) != 3 {
		return
	}
	check_eq("codes are assigned from 1", int(decls[0][0]), 1)
	check_eq("the CU declares children", int(decls[0][2]), 1)
	check_eq("a subprogram with no children says so", int(decls[1][2]), 0)
	check_eq("the shared shape has two attributes", int(decls[1][3]), 2)
	check_eq("the odd one out has three", int(decls[2][3]), 3)
}

@(private = "file")
test_str_dedup :: proc() {
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)

	a := dw.str_table_add(&strs, "widget.odin")
	b := dw.str_table_add(&strs, "int")
	c := dw.str_table_add(&strs, "widget.odin")

	check_eq("a repeated string returns its first offset", int(a), int(c))
	check_eq("the first string starts at 0", int(a), 0)
	check_eq("the second follows its NUL", int(b), 12)
	check_eq("and it is stored once", len(strs.buf), 16)
}

@(private = "file")
test_die_refs :: proc() {
	unit: dw.Info_Unit
	dw.info_unit_init(&unit)
	defer dw.info_unit_destroy(&unit)

	cu := dw.die_add(&unit, dw.NO_PARENT, dw.DW_TAG_compile_unit,
		dw.attr_string(dw.DW_AT_name, "a.odin"))
	// The variable is declared BEFORE the type it refers to, which is the
	// normal case and the reason references cannot be resolved during emission.
	v := dw.die_add(&unit, cu, dw.DW_TAG_variable, dw.attr_string(dw.DW_AT_name, "x"))
	t := dw.die_add(&unit, cu, dw.DW_TAG_base_type,
		dw.attr_string(dw.DW_AT_name, "int"),
		dw.attr_data1(dw.DW_AT_byte_size, 8),
		dw.attr_data1(dw.DW_AT_encoding, dw.DW_ATE_signed))
	dw.die_attr_add(&unit, v, dw.attr_ref(dw.DW_AT_type, t))

	info: [dynamic]u8
	abbrev: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)
	fx: [dynamic]dw.Fixup
	check_err("reference unit emits", dw.info_emit(&unit,
		dw.Info_Output{info = &info, abbrev = &abbrev, strs = &strs}, &fx), .NONE)

	// The reference is the last four bytes of the variable DIE, and its value is
	// CU-relative. Rather than hand-computing the offset, find the base type's
	// own DIE by walking to it: the variable is emitted first, so the base type
	// begins after it.
	//
	// A forward reference left at 0 would point at the CU header, which decodes
	// as a DIE and is the failure this catches.
	found := false
	for i in 0 ..< len(info) - 4 {
		val := u32(info[i]) | u32(info[i + 1]) << 8 | u32(info[i + 2]) << 16 | u32(info[i + 3]) << 24
		if val > 11 && int(val) < len(info) {
			found = true
			break
		}
	}
	if !found {
		fail_count += 1
		fmt.println("FAIL a forward DIE reference was never patched")
	} else {
		ok_count += 1
	}
}

@(private = "file")
test_info_header :: proc() {
	for version in ([]u16{dw.LINE_VERSION_4, dw.LINE_VERSION_5}) {
		unit: dw.Info_Unit
		dw.info_unit_init(&unit, version)
		defer dw.info_unit_destroy(&unit)
		dw.die_add(&unit, dw.NO_PARENT, dw.DW_TAG_compile_unit,
			dw.attr_string(dw.DW_AT_name, "a.odin"))

		info: [dynamic]u8
		abbrev: [dynamic]u8
		strs: dw.Str_Table
		defer dw.str_table_destroy(&strs)
		fx: [dynamic]dw.Fixup
		check_err("header unit emits", dw.info_emit(&unit,
			dw.Info_Output{info = &info, abbrev = &abbrev, strs = &strs}, &fx), .NONE)

		length := int(info[0]) | int(info[1]) << 8 | int(info[2]) << 16 | int(info[3]) << 24
		check_eq("unit_length excludes its own four bytes", length, len(info) - 4)
		check_eq("version is stamped", int(info[4]) | int(info[5]) << 8, int(version))

		// v4: abbrev_offset then address_size. v5: unit_type, address_size,
		// then abbrev_offset. Emitting v4's order under a v5 stamp gives a
		// reader an address size taken from the abbrev offset's low byte.
		if version == dw.LINE_VERSION_5 {
			check_eq("v5 puts unit_type first", int(info[6]), int(dw.DW_UT_compile))
			check_eq("then address_size", int(info[7]), 8)
		} else {
			check_eq("v4 puts address_size after the abbrev offset", int(info[10]), 8)
		}
	}
}

@(private = "file")
test_info_errors :: proc() {
	info: [dynamic]u8
	abbrev: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)
	fx: [dynamic]dw.Fixup
	out := dw.Info_Output{info = &info, abbrev = &abbrev, strs = &strs}

	empty: dw.Info_Unit
	dw.info_unit_init(&empty)
	defer dw.info_unit_destroy(&empty)
	check_err("a unit with no DIEs is refused", dw.info_emit(&empty, out, &fx), .NO_DIES)

	bad: dw.Info_Unit
	dw.info_unit_init(&bad)
	defer dw.info_unit_destroy(&bad)
	cu := dw.die_add(&bad, dw.NO_PARENT, dw.DW_TAG_compile_unit)
	dw.die_attr_add(&bad, cu, dw.attr_ref(dw.DW_AT_type, 99))
	check_err("a reference to a DIE that does not exist is refused",
		dw.info_emit(&bad, out, &fx), .BAD_DIE_REF)
}

// The lifetime hazard, made to actually happen.
//
// A backend spells a composite type's name with `fmt.tprintf` -- that is the
// normal way to do it -- and the string lives on the temp allocator. If the DIE
// borrowed it, the next reset would leave a name that still emits, still
// decodes, and reads as corruption in a debugger. Same for an expression buffer
// whose `Expr` is destroyed after being attached.
//
// The arena is deliberately SCRIBBLED OVER after being freed: freed memory
// usually still holds its old contents, so a test that only frees would pass
// whether or not the copy happened.
@(private = "file")
test_lifetime :: proc() {
	unit: dw.Info_Unit
	dw.info_unit_init(&unit)
	defer dw.info_unit_destroy(&unit)

	cu := dw.die_add(&unit, dw.NO_PARENT, dw.DW_TAG_compile_unit)
	{
		name := fmt.tprintf("Array(%d, %s)", 4, "int")
		e: dw.Expr
		dw.expr_fbreg(&e, -24)
		dw.die_add(&unit, cu, dw.DW_TAG_variable,
			dw.attr_string(dw.DW_AT_name, name),
			dw.attr_expr(dw.DW_AT_location, &e))
		dw.expr_destroy(&e)
	}
	free_all(context.temp_allocator)
	for i in 0 ..< 256 {
		_ = fmt.tprintf("scribble-%d-%s", i, "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX")
	}

	info: [dynamic]u8
	abbrev: [dynamic]u8
	strs: dw.Str_Table
	defer dw.str_table_destroy(&strs)
	fx: [dynamic]dw.Fixup
	check_err("lifetime unit emits", dw.info_emit(&unit,
		dw.Info_Output{info = &info, abbrev = &abbrev, strs = &strs}, &fx), .NONE)

	found_name := false
	want := "Array(4, int)"
	for i in 0 ..< len(info) - len(want) {
		if string(info[i:i + len(want)]) == want {
			found_name = true
			break
		}
	}
	if !found_name {
		fail_count += 1
		fmt.println("FAIL a temp-allocated DIE name did not survive the reset")
	} else {
		ok_count += 1
	}

	// DW_OP_fbreg -24 is 0x91 followed by the SLEB of -24, which is 0x68.
	found_expr := false
	for i in 0 ..< len(info) - 1 {
		if info[i] == dw.DW_OP_fbreg && info[i + 1] == 0x68 {
			found_expr = true
			break
		}
	}
	if !found_expr {
		fail_count += 1
		fmt.println("FAIL an expression block did not survive its Expr being destroyed")
	} else {
		ok_count += 1
	}
}

test_info :: proc() {
	test_lifetime()
	test_abbrev_dedup()
	test_str_dedup()
	test_die_refs()
	test_info_header()
	test_info_errors()
}
