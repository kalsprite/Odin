// triage_docbin -- gate the BINARY .odin-doc writer (docs_writer.odin) against the reference.
//
// WHY THIS EXISTS. After tick 227 the plain-text doc printer finally has a gate (doctext.sh), but
// the BINARY writer -- 1776 lines, the whole of docs_writer.odin -- still has none that can see the
// reference side:
//   doccmp.sh   compares which ENTITIES a package scope holds; it never touches the writer.
//   docflag.sh  gates Doc_Entity_Flag BITS and is explicitly PORT-SIDE ONLY, because `odin doc`
//               prints text rather than a bit field.
//   dump_doc    drives the two-pass writer and prints per-ENTITY lines -- also port-side only, and
//               it never prints a single Doc_Type. The entire TYPE table was unobserved.
// `odin doc <pkg> -doc-format` writes exactly the artifact the port's odin_doc_write produces, so
// the two are directly comparable and always should have been.
//
// WHY A STRUCTURAL DUMP AND NOT A BYTE DIFF. The format is index-based: Doc_Type_Index and
// Doc_Entity_Index are positions in a table whose order is the order of first visit. One extra or
// missing type shifts every later index, so a byte diff (or an index-keyed text diff) reports the
// whole file as different and says nothing about what actually changed. So this decodes both files
// and prints ORDER-INDEPENDENT records:
//   * entities are keyed by name + source position and sorted, so index numbering cannot matter;
//   * every type is rendered STRUCTURALLY (children expanded, stopping at Named types, which is
//     where the cycles are), then the renders are sorted and counted -- `typeset 3x Slice(u8)`.
// A missing writer arm shows up as a kind that stops appearing and an `Invalid()` that starts.
//
// ONE READER, BOTH FILES. The decoder is built out of the port's own Doc_* structs, so the oracle's
// file is read through the port's layout declarations. That is deliberate: a layout divergence
// (a field of the wrong width, a missing enumerator) shows up as garbage in the dump rather than
// being silently normalised away by two separate readers.
//
// NORMALISATIONS, NAMED RATHER THAN HIDDEN:
//   * fullpath/file names print as BASENAMES. The two runs resolve the package root differently
//     (the harness takes a path argument; `odin doc` takes a command target) and an absolute path
//     is not a property of the documentation.
//   * The target package is stamped `kind = .Init`. `odin doc <pkg>` documents its INIT package,
//     and the checker library has no command-target notion, so without this the port documents
//     nothing and the diff would be "empty vs full" -- which reads as a defect but is a harness
//     configuration difference. dump_doc.odin forces `-all-packages` for the same reason; stamping
//     .Init is the closer mirror because it also reproduces the Init pkg flag the oracle sets.
//
// USAGE:
//   triage_docbin write <package-path> <out.odin-doc>   -- check the package, run odin_doc_write
//   triage_docbin dump  <file.odin-doc>                 -- decode and print the canonical dump
package triage_docbin

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:odin/ast"
import "core:odin/checker"

main :: proc() {
	args := os.args
	if len(args) < 3 {
		fmt.eprintln("usage: triage_docbin write <package-path> <out.odin-doc> [-internal-ignore-panic]")
		fmt.eprintln("       triage_docbin dump  <file.odin-doc>")
		os.exit(2)
	}
	switch args[1] {
	case "write":
		// #1293. The optional trailing flag mirrors the reference's `-internal-ignore-panic`, and
		// exists because three real packages in the sweep list -- core/path, core/odin/format,
		// core/odin/printer -- are `#panic` stubs. Without it the ORACLE cannot document them
		// either, so docbin.sh counted them REF-NODOC and graded nothing. They are not a limit of
		// the reference, they are a limit of the harness. Accepted as a positional flag rather
		// than parsed generally: this tool has exactly two subcommands and one flag, and a real
		// flag parser here would be more code than the thing it configures.
		ignore_panic := false
		switch len(args) {
		case 4:
		case 5:
			if args[4] != "-internal-ignore-panic" {
				fmt.eprintfln("triage_docbin: write: unknown flag %s", args[4])
				os.exit(2)
			}
			ignore_panic = true
		case:
			fmt.eprintln("triage_docbin: write takes <package-path> <out.odin-doc> [-internal-ignore-panic]")
			os.exit(2)
		}
		write_doc(args[2], args[3], ignore_panic)
	case "dump":
		if len(args) != 3 {
			fmt.eprintln("triage_docbin: dump takes <file.odin-doc>")
			os.exit(2)
		}
		dump_doc_file(args[2])
	case:
		fmt.eprintfln("triage_docbin: unknown subcommand %s", args[1])
		os.exit(2)
	}
}

// ======================================================================================
// WRITE SIDE
// ======================================================================================

write_doc :: proc(path: string, out: string, ignore_panic := false) {
	checker.ensure_build_context_initialized()
	checker.build_context.no_entry_point = true
	checker.build_context.command_kind = {.Doc}
	checker.build_context.cmd_doc_flags = {.Doc_Format}
	checker.build_context.ignore_panic = ignore_panic

	checker.init_odin_root_from_env()

	checker.init_error_collector(1000)
	defer checker.destroy_error_collector()

	// filepath.abs returns an os.Error, not a bool (triage_doc:62 and triage_doctext:95 record the
	// same trap). Checked before the loader runs so an unresolvable path reports ABS-FAILED rather
	// than producing an EMPTY doc file, which would decode clean against a failed oracle run --
	// the #405 false-green shape.
	abs, abs_err := filepath.abs(path)
	if abs_err != nil {
		fmt.println("### ABS-FAILED")
		os.exit(1)
	}
	defer delete(abs)

	c := &checker.Checker{}
	checker.init_checker(c, context.allocator)
	defer checker.destroy_checker(c)

	load_result, loader_ok := checker.load_package_with_dependencies(path, &c.info, context.allocator)
	if !loader_ok {
		fmt.println("### LOAD-FAILED")
		os.exit(1)
	}

	files: [dynamic]^ast.File
	defer delete(files)
	for pkg in load_result.packages {
		if pkg == nil {
			continue
		}
		for file in checker.sorted_files(pkg.files) {
			append(&files, file)
		}
	}
	if len(files) == 0 {
		fmt.println("### LOAD-FAILED")
		os.exit(1)
	}

	checker.check_files(c, files[:])

	// Stamp the target as the INIT package -- see the header note. Matched on fullpath, which is
	// what the loader stores, rather than on name: twelve packages in pkglist are named `tools`
	// (#760) and a name match would pick an arbitrary one.
	stamped := false
	for _, pkg in c.info.packages {
		if pkg == nil {
			continue
		}
		if pkg.fullpath == abs {
			// ONLY a Normal package is promoted. odin_doc_write_docs selects packages with
			// `pkg->kind == Package_Init || pkg->is_extra` (docs_writer.cpp:1119-1130), and a
			// package the loader has already classified -- Runtime, Builtin -- keeps that
			// classification in the reference too. `odin doc base/runtime -doc-format` duly
			// writes a 384-byte stub: base/runtime is Package_Runtime, so NOTHING is selected.
			// Stamping .Init over that made the port document 1747 entities against the oracle's
			// one, which is the HARNESS disagreeing with the reference, not the writer. The
			// stamp stands in for the build driver's init-package assignment; it is not a licence
			// to reclassify a package the driver would never have handed over.
			if pkg.kind == .Normal {
				pkg.kind = .Init
			}
			stamped = true
		}
	}
	if !stamped {
		// A LOUD failure. If the target is not among the loaded packages the port documents nothing
		// and the dump would be empty -- indistinguishable from "the writer produced nothing".
		fmt.printfln("### NO-TARGET-PKG %s", abs)
		os.exit(1)
	}

	if !checker.odin_doc_write(&c.info, out) {
		fmt.println("### WRITE-FAILED")
		os.exit(1)
	}
}

// ======================================================================================
// DUMP SIDE
// ======================================================================================

Doc :: struct {
	data:     []u8,
	header:   ^checker.Doc_Header,
	files:    []checker.Doc_File,
	pkgs:     []checker.Doc_Pkg,
	entities: []checker.Doc_Entity,
	types:    []checker.Doc_Type,
}

// arr_slice resolves a Doc_Array(T) into a slice of the file's bytes. Bounds are CHECKED, not
// asserted: this decoder is pointed at a file produced by the thing under test, so a malformed span
// must degrade to a visible marker instead of crashing the gate that would have reported it.
arr_slice :: proc(d: ^Doc, $T: typeid, offset: u32, length: u32) -> []T {
	if length == 0 {
		return nil
	}
	lo := int(offset)
	hi := lo + int(length) * size_of(T)
	if lo < 0 || hi > len(d.data) {
		return nil
	}
	return (cast([^]T)&d.data[lo])[:length]
}

doc_str :: proc(d: ^Doc, s: checker.Doc_String) -> string {
	if s.length == 0 {
		return ""
	}
	lo := int(s.offset)
	hi := lo + int(s.length)
	if lo < 0 || hi > len(d.data) {
		return "<bad-span>"
	}
	return string(d.data[lo:hi])
}

dump_doc_file :: proc(path: string) {
	// This core:os build's read_entire_file group takes an explicit allocator and returns an
	// os.Error, not a bool -- the same shape trap as filepath.abs above.
	data, read_err := os.read_entire_file_from_path(path, context.allocator)
	if read_err != nil {
		fmt.printfln("### READ-FAILED %s (%v)", path, read_err)
		os.exit(1)
	}
	if len(data) < size_of(checker.Doc_Header) {
		fmt.printfln("### TOO-SMALL %d", len(data))
		os.exit(1)
	}

	d: Doc
	d.data = data
	d.header = cast(^checker.Doc_Header)raw_data(data)
	h := d.header

	magic := string(h.base.magic[:7])
	if magic != "odindoc" {
		fmt.printfln("### BAD-MAGIC %q", magic)
		os.exit(1)
	}

	d.files    = arr_slice(&d, checker.Doc_File,   h.files.offset,    h.files.length)
	d.pkgs     = arr_slice(&d, checker.Doc_Pkg,    h.pkgs.offset,     h.pkgs.length)
	d.entities = arr_slice(&d, checker.Doc_Entity, h.entities.offset, h.entities.length)
	d.types    = arr_slice(&d, checker.Doc_Type,   h.types.offset,    h.types.length)

	// The header is printed WITHOUT total_size or hash: both are byte-level properties that change
	// with any capacity difference, so they would mask every structural finding behind one noisy
	// line. header_size and the VERSION are printed -- a version skew is exactly the kind of thing
	// this gate exists to catch, and header_size is a layout property of the shared struct.
	fmt.printfln("header version=%d.%d.%d header_size=%d files=%d pkgs=%d entities=%d types=%d",
		h.base.version.major, h.base.version.minor, h.base.version.patch,
		h.base.header_size, h.files.length, h.pkgs.length, h.entities.length, h.types.length)

	lines: [dynamic]string
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}

	// --- packages ---------------------------------------------------------------------
	for pkg, i in d.pkgs {
		if i == 0 {
			continue // index 0 is the reserved null item on both sides
		}
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "pkg\t%s\tpath=%s\tflags=%s\tdocs=%q\tnfiles=%d\tnentries=%d\n",
			doc_str(&d, pkg.name), base_of(doc_str(&d, pkg.fullpath)),
			pkg_flags_str(pkg.flags), doc_str(&d, pkg.docs),
			pkg.files.length, pkg.entries.length)
		append(&lines, strings.to_string(sb))

		for fi in arr_slice(&d, checker.Doc_File_Index, pkg.files.offset, pkg.files.length) {
			if int(fi) >= len(d.files) {
				continue
			}
			sb2 := strings.builder_make()
			fmt.sbprintf(&sb2, "pkgfile\t%s\t%s\n",
				doc_str(&d, pkg.name), base_of(doc_str(&d, d.files[fi].name)))
			append(&lines, strings.to_string(sb2))
		}

		for entry in arr_slice(&d, checker.Doc_Scope_Entry, pkg.entries.offset, pkg.entries.length) {
			sb3 := strings.builder_make()
			fmt.sbprintf(&sb3, "entry\t%s.%s\t%s\n",
				doc_str(&d, pkg.name), doc_str(&d, entry.name), entity_key(&d, entry.entity))
			append(&lines, strings.to_string(sb3))
		}
	}

	// --- entities ---------------------------------------------------------------------
	for e, i in d.entities {
		if i == 0 {
			continue
		}
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "entity\t%s\tkind=%v\tflags=%s\ttype=%s\tinit=%q\tlink=%q\tfgi=%d",
			entity_key(&d, u32(i)), e.kind, entity_flags_str(e.flags),
			render_type(&d, e.type, false), doc_str(&d, e.init_string),
			doc_str(&d, e.link_name), e.field_group_index)
		fmt.sbprintf(&sb, "\tdocs=%q\tcomment=%q", doc_str(&d, e.docs), doc_str(&d, e.comment))
		if e.foreign_library != 0 {
			fmt.sbprintf(&sb, "\tforeign=%s", entity_key(&d, e.foreign_library))
		}
		for a in arr_slice(&d, checker.Doc_Attribute, e.attributes.offset, e.attributes.length) {
			fmt.sbprintf(&sb, "\tattr=%s=%q", doc_str(&d, a.name), doc_str(&d, a.value))
		}
		for wc in arr_slice(&d, checker.Doc_String, e.where_clauses.offset, e.where_clauses.length) {
			fmt.sbprintf(&sb, "\twhere=%q", doc_str(&d, wc))
		}
		for gi in arr_slice(&d, checker.Doc_Entity_Index, e.grouped_entities.offset, e.grouped_entities.length) {
			fmt.sbprintf(&sb, "\tgrouped=%s", entity_key(&d, gi))
		}
		fmt.sbprintf(&sb, "\n")
		append(&lines, strings.to_string(sb))
	}

	// --- types ------------------------------------------------------------------------
	// Rendered, then SORTED AND COUNTED. The type table's ORDER is an artifact of visit order and
	// carries no documentation meaning, but its CONTENTS do: a missing writer arm shows up here as a
	// kind that stopped appearing and an `Invalid()` that started.
	renders := make([dynamic]string, 0, len(d.types))
	defer delete(renders)
	for _, i in d.types {
		if i == 0 {
			continue
		}
		append(&renders, render_type(&d, u32(i), true))
	}
	slice.sort(renders[:])
	i := 0
	for i < len(renders) {
		j := i
		for j < len(renders) && renders[j] == renders[i] {
			j += 1
		}
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "typeset\t%dx\t%s\n", j - i, renders[i])
		append(&lines, strings.to_string(sb))
		i = j
	}

	slice.sort(lines[:])
	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	for l in lines {
		strings.write_string(&out, l)
	}
	fmt.printfln("records %d", len(lines))
	fmt.print(strings.to_string(out))
}

base_of :: proc(p: string) -> string {
	if p == "" {
		return ""
	}
	return filepath.base(p)
}

// entity_key names an entity by NAME plus source position rather than by index. Struct fields and
// procedure parameters routinely share a name, so the name alone is not unique; the index would be
// unique but is exactly the order-dependent thing this dump is designed not to depend on.
entity_key :: proc(d: ^Doc, idx: u32) -> string {
	if idx == 0 || int(idx) >= len(d.entities) {
		return "<none>"
	}
	e := d.entities[idx]
	file := "?"
	if int(e.pos.file) < len(d.files) && e.pos.file != 0 {
		file = base_of(doc_str(d, d.files[e.pos.file].name))
	}
	return fmt.tprintf("%s@%s:%d:%d", doc_str(d, e.name), file, e.pos.line, e.pos.column)
}

pkg_flags_str :: proc(flags: u32) -> string {
	if flags == 0 {
		return "-"
	}
	names: [dynamic]string
	defer delete(names)
	for f in checker.Doc_Pkg_Flag {
		if flags & (1 << u32(f)) != 0 {
			append(&names, fmt.tprintf("%v", f))
		}
	}
	slice.sort(names[:])
	return strings.join(names[:], "|", context.temp_allocator)
}

entity_flags_str :: proc(flags: u64) -> string {
	if flags == 0 {
		return "-"
	}
	names: [dynamic]string
	defer delete(names)
	for f in checker.Doc_Entity_Flag {
		if flags & (1 << u64(f)) != 0 {
			append(&names, fmt.tprintf("%v", f))
		}
	}
	slice.sort(names[:])
	return strings.join(names[:], "|", context.temp_allocator)
}

// type_flags_str renders the KIND-SPECIFIC flag word. docs_format.cpp gives each kind its own flag
// enum over the same u32, so the same bit means different things per kind -- rendering it with one
// shared table would print confident nonsense.
type_flags_str :: proc(kind: checker.Doc_Type_Kind, flags: u32) -> string {
	if flags == 0 {
		return ""
	}
	names: [dynamic]string
	defer delete(names)
	#partial switch kind {
	case .Basic:
		for f in checker.Doc_Type_Flag_Basic {
			if flags & u32(f) != 0 {
				append(&names, fmt.tprintf("%v", f))
			}
		}
	case .Struct, .SOA_Struct_Fixed, .SOA_Struct_Slice, .SOA_Struct_Dynamic:
		for f in checker.Doc_Type_Flag_Struct {
			if flags & u32(f) != 0 {
				append(&names, fmt.tprintf("%v", f))
			}
		}
	case .Union:
		for f in checker.Doc_Type_Flag_Union {
			if flags & u32(f) != 0 {
				append(&names, fmt.tprintf("%v", f))
			}
		}
	case .Proc:
		for f in checker.Doc_Type_Flag_Proc {
			if flags & u32(f) != 0 {
				append(&names, fmt.tprintf("%v", f))
			}
		}
	case .Bit_Set:
		for f in checker.Doc_Type_Flag_BitSet {
			if flags & u32(f) != 0 {
				append(&names, fmt.tprintf("%v", f))
			}
		}
	case:
		// An unknown-kind flag word is still printed, as a number: silently dropping it would hide
		// a writer that sets flags on a kind that is not supposed to have any.
		return fmt.tprintf("0x%x", flags)
	}
	slice.sort(names[:])
	return strings.join(names[:], "|", context.temp_allocator)
}

// render_type prints a type STRUCTURALLY. Recursion stops at Named types unless `expand` is set for
// this one node, which is what makes the render finite: every cycle in the type graph passes
// through a Named type (that is what a recursive declaration IS), so cutting there is sufficient
// and no depth limit or visited set is needed.
render_type :: proc(d: ^Doc, idx: u32, expand: bool) -> string {
	if idx == 0 || int(idx) >= len(d.types) {
		return "<none>"
	}
	t := d.types[idx]

	if t.kind == .Named && !expand {
		return fmt.tprintf("@%s", doc_str(d, t.name))
	}

	sb := strings.builder_make(context.temp_allocator)
	fmt.sbprintf(&sb, "%v(", t.kind)
	first := true
	sep :: proc(sb: ^strings.Builder, first: ^bool) {
		if !first^ {
			strings.write_string(sb, " ")
		}
		first^ = false
	}

	if name := doc_str(d, t.name); name != "" {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "name=%s", name)
	}
	if fs := type_flags_str(t.kind, t.flags); fs != "" {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "flags=%s", fs)
	}
	if ca := doc_str(d, t.custom_align); ca != "" {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "align=%s", ca)
	}
	if cc := doc_str(d, t.calling_convention); cc != "" {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "cc=%s", cc)
	}
	if t.elem_count_len > 0 {
		sep(&sb, &first)
		strings.write_string(&sb, "counts=[")
		n := min(int(t.elem_count_len), len(t.elem_counts))
		for k in 0 ..< n {
			if k > 0 {
				strings.write_string(&sb, ",")
			}
			fmt.sbprintf(&sb, "%d", t.elem_counts[k])
		}
		strings.write_string(&sb, "]")
	}
	if t.types.length > 0 {
		sep(&sb, &first)
		strings.write_string(&sb, "types=[")
		for ti, k in arr_slice(d, checker.Doc_Type_Index, t.types.offset, t.types.length) {
			if k > 0 {
				strings.write_string(&sb, ",")
			}
			strings.write_string(&sb, render_type(d, ti, false))
		}
		strings.write_string(&sb, "]")
	}
	if t.entities.length > 0 {
		sep(&sb, &first)
		strings.write_string(&sb, "entities=[")
		for ei, k in arr_slice(d, checker.Doc_Entity_Index, t.entities.offset, t.entities.length) {
			if k > 0 {
				strings.write_string(&sb, ",")
			}
			strings.write_string(&sb, entity_key(d, ei))
		}
		strings.write_string(&sb, "]")
	}
	if t.polymorphic_params != 0 {
		sep(&sb, &first)
		fmt.sbprintf(&sb, "poly=%s", render_type(d, t.polymorphic_params, false))
	}
	if t.where_clauses.length > 0 {
		sep(&sb, &first)
		strings.write_string(&sb, "where=[")
		for wc, k in arr_slice(d, checker.Doc_String, t.where_clauses.offset, t.where_clauses.length) {
			if k > 0 {
				strings.write_string(&sb, ",")
			}
			fmt.sbprintf(&sb, "%q", doc_str(d, wc))
		}
		strings.write_string(&sb, "]")
	}
	if t.tags.length > 0 {
		sep(&sb, &first)
		strings.write_string(&sb, "tags=[")
		for tag, k in arr_slice(d, checker.Doc_String, t.tags.offset, t.tags.length) {
			if k > 0 {
				strings.write_string(&sb, ",")
			}
			fmt.sbprintf(&sb, "%q", doc_str(d, tag))
		}
		strings.write_string(&sb, "]")
	}
	strings.write_string(&sb, ")")
	return strings.to_string(sb)
}
