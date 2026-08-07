package checker

// dump_doc -- serialise the DOC-OUTPUT FLAG BITS for every entity the doc writer emits.
//
// WHY THIS EXISTS (LEDGER #480). doccmp.sh compares which ENTITIES the port's package scope holds
// against `odin doc`'s output. It does not compare, and cannot compare, the Doc_Entity_Flag BITS
// attached to them -- its own header says it checks presence. That left the whole flag surface
// ungated, and #479 is what the gap costs: docs_writer read `.Foreign`/`.Export` from ENTITY flags
// that nothing ever sets, so two doc bits were permanently unreachable and every gate stayed green.
//
// THE DOC WRITER IS TWO-PASS, and the first version of this file did not know that (LEDGER #482/#483).
// The protocol, from doc_writer_init/doc_writer_start_writing:
//
//     doc_writer_init(&w, info)      // state = .Preparing
//     doc_write_docs(&w)             // PASS 1: sizing only -- every doc_write_item returns 0 and
//                                    //         merely bumps t.cap; doc_get_item returns nil
//     doc_writer_start_writing(&w)   // state = .Writing, CLEARS every cache, allocates w.data
//     doc_write_docs(&w)             // PASS 2: the one that actually writes
//
// The original code called doc_write_docs ONCE and then re-drove doc_write_entity per entity. That
// left the writer in .Preparing forever, so every index came back 0 and the dump was empty --
// `## doc-entities=0` on every target, which read as "nothing to report" rather than "this
// instrument does not work". Both passes are required; there is no single-pass shortcut.
//
// So this no longer calls doc_write_entity at all. It runs the protocol and then ENUMERATES what
// the writer actually produced, walking w.entities by index. That is strictly better as a gate:
// it reports the real output rather than a re-derivation of it, and it cannot silently disagree
// with what a real `odin doc` run would emit.
//
// WHAT IT CANNOT DO ON ITS OWN: `odin doc` prints rendered documentation, not a bit field, so this
// is not directly diffable against the oracle. It is a PORT-SIDE gate -- it makes the bits visible
// and diffable across port revisions, which is what #479 needed and did not have. Comparing bits
// against C++ needs the reference side to expose them too (#475's territory).
//
// A NOTE ON ONE BIT: Param_Auto_Cast is declared in both implementations and set in NEITHER
// (C++ docs_format.cpp:225 declares OdinDocEntityFlag_Param_AutoCast; nothing in src/ assigns it).
// It is expected absent, and a comparison that flags it would be reporting a shared non-feature.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"

// dump_doc_flags renders the set bits by name, sorted, `-` when none.
@(private="file")
dump_doc_flags :: proc(flags: u64) -> string {
	if flags == 0 {
		return "-"
	}
	names: [dynamic]string
	defer delete(names)
	for f in Doc_Entity_Flag {
		if flags & (1 << u64(f)) != 0 {
			append(&names, fmt.tprintf("%v", f))
		}
	}
	slice.sort(names[:])
	return strings.join(names[:], "|", context.temp_allocator)
}

// dump_doc_str resolves a Doc_String back to text. Doc_String is {offset, length} into w.data, an
// ABSOLUTE offset (doc_write_string stores w.strings.offset + w.strings.len), so it indexes w.data
// directly. Bounds are checked rather than asserted: this is an instrument, and a malformed span
// should degrade to a visible marker instead of taking down the run it is measuring.
@(private="file")
dump_doc_str :: proc(w: ^Doc_Writer, s: Doc_String) -> string {
	if s.length == 0 {
		return "<blank>"
	}
	lo := int(s.offset)
	hi := lo + int(s.length)
	if lo < 0 || hi > len(w.data) {
		return "<bad-span>"
	}
	return string(w.data[lo:hi])
}

// dump_doc writes the per-entity doc flag bits to path. Returns false and reports on stderr if the
// file could not be written -- a SILENT failure would diff clean against another absent dump, which
// is the #405 false-green shape.
dump_doc :: proc(c: ^Checker, path: string) -> bool {
	if c == nil || len(path) == 0 {
		return false
	}

	// ALL_PACKAGES must be on, or doc_write_docs collects only .Init-kind and is_extra packages
	// (docs_writer.odin:1466) -- and a package named as the check TARGET is neither, so the dump
	// came out empty. Set before pass 1: the sizing pass must see the same package set as the
	// writing pass, or the capacities it computes will not fit what pass 2 tries to write.
	// Restored after, so this cannot leak into a later phase.
	prev_doc_flags := build_context.cmd_doc_flags
	defer build_context.cmd_doc_flags = prev_doc_flags
	build_context.cmd_doc_flags += {.All_Packages}

	// MIRROR odin_doc_write (docs_writer.odin:1540) EXACTLY. LEDGER #485: the first version of this
	// reconstructed the protocol by reading doc_writer_init/doc_writer_start_writing, and missed two
	// steps that only the real entry point has:
	//
	//   g_in_doc_writer  -- read by is_in_doc_writer(), which decides whether canonical names
	//                       include default values. With it unset, this dump was NOT exercising the
	//                       doc-mode name path at all, i.e. it measured a configuration `odin doc`
	//                       never runs.
	//   doc_writer_end_writing -- the tail of the writing pass.
	//
	// The lesson is the cheaper one: there was already a caller implementing this sequence, and
	// reading the pieces instead of looking for the existing caller is how both steps went missing.
	g_in_doc_writer = true
	defer { g_in_doc_writer = false }

	w: Doc_Writer
	doc_writer_init(&w, &c.info)
	defer doc_writer_destroy(&w)

	doc_write_docs(&w)
	doc_writer_start_writing(&w)
	doc_write_docs(&w)
	doc_writer_end_writing(&w)

	lines: [dynamic]string
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}

	// Enumerate what the writer PRODUCED. Index 0 is a legitimate entity index, so this is a plain
	// range over the tracker's length -- the previous version's `if idx == 0 { continue }` test
	// would have dropped the first entity even once the state machine was correct.
	for i in 0 ..< w.entities.len {
		de := doc_get_item(&w, &w.entities, u32(i))
		if de == nil {
			continue
		}
		sb := strings.builder_make()
		fmt.sbprintf(&sb, "doc\t%s\t%v\tflags=%s\n", dump_doc_str(&w, de.name), de.kind,
			dump_doc_flags(de.flags))
		append(&lines, strings.to_string(sb))
	}
	slice.sort(lines[:])

	out := strings.builder_make()
	defer strings.builder_destroy(&out)
	fmt.sbprintf(&out, "## doc-entities=%d\n", len(lines))
	for l in lines {
		strings.write_string(&out, l)
	}
	fmt.sbprintf(&out, "## end\n")

	if werr := os.write_entire_file(path, transmute([]byte)strings.to_string(out)); werr != nil {
		fmt.eprintf("dump_doc: FAILED to write '%s' (%v) -- the dump is MISSING, not empty\n",
			path, werr)
		return false
	}
	return true
}
