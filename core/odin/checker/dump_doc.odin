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

		// #1195. A SECOND LINE TYPE carrying the entity's DOC COMMENT TEXT, emitted only when there
		// is any. The `doc` line above carries names and flag bits and NOTHING ELSE, which is why it
		// could not verify #1177 (the struct-field / enum-member docs+comment WRITER in
		// check_type.odin) or #1178 (the entity-level READER fallback in docs_writer.odin): those
		// fixes populate Doc_Entity.docs / .comment, and no instrument in this tree ever printed
		// them. Both fixes have been unverifiable since they landed.
		//
		// DELIBERATELY A NEW LINE TYPE, not extra fields on `doc`. The recorded design for this
		// (LEDGER, the triage_doc DOCCOMMENT note) says the same thing for the same reason: the
		// existing consumers field-split the line they know, so widening it breaks them silently.
		// Here that is pre757_docflag.sh / pre759_docflag.sh, which read `doc` lines.
		//
		// The oracle's comparable artifact is the BINARY `odindoc` file from `odin doc -doc-format`,
		// which stores comment text as plain bytes -- so `strings -a` on it yields the same texts
		// this line prints, and the two can be compared without a binary-format reader.
		// #1198. A THIRD line type, for the entity's ATTRIBUTES. Same gap #1195 closed for doc
		// comments: docs_writer.odin:1417 writes `doc_entity.attributes = doc_write_attributes(...)`,
		// mirroring docs_writer.cpp:977 -- and nothing in this tree ever printed them, so the whole
		// attribute surface of the doc output was unverified. `flags=` on the `doc` line above is a
		// DIFFERENT thing (Doc_Entity_Flags bits, not the source attributes).
		//
		// Again a NEW line type rather than widening `doc`: pre757_docflag.sh / pre759_docflag.sh
		// field-split that line.
		//
		// Doc_Array(T) is {offset, length} into w.data (docs_writer.odin:44-47), and the attribute
		// items sit contiguously from `offset`, so the i'th is read by offsetting a typed pointer --
		// exactly how doc_get_item indexes the entity array.
		if de.attributes.length > 0 {
			alo := int(de.attributes.offset)
			need := int(de.attributes.length) * size_of(Doc_Attribute)
			if alo >= 0 && alo + need <= len(w.data) {
				attrs := (cast([^]Doc_Attribute)&w.data[alo])[:de.attributes.length]
				sb3 := strings.builder_make()
				fmt.sbprintf(&sb3, "docattrs\t%s", dump_doc_str(&w, de.name))
				for a in attrs {
					fmt.sbprintf(&sb3, "\t%s=%q", dump_doc_str(&w, a.name), dump_doc_str(&w, a.value))
				}
				fmt.sbprintf(&sb3, "\n")
				append(&lines, strings.to_string(sb3))
			} else {
				// Bounds-checked, not asserted: this is an instrument, and a malformed span should
				// show as a visible marker rather than take down the run it is measuring.
				sb3 := strings.builder_make()
				fmt.sbprintf(&sb3, "docattrs\t%s\t<bad-span>\n", dump_doc_str(&w, de.name))
				append(&lines, strings.to_string(sb3))
			}
		}

		// #1199. A FOURTH line type. Auditing EVERY Doc_Entity field against what this dump printed
		// found TEN never printed: reserved, pos, type, init_string, reserved_for_init,
		// field_group_index, foreign_library, link_name, grouped_entities, where_clauses.
		// Of those, THREE are string-valued and therefore comparable against the oracle's binary
		// odindoc via `strings -a` with no format reader:
		//     init_string    the declaration's initialiser text
		//     link_name      @(link_name=...) as recorded in the doc
		//     where_clauses  each `where` clause's text (a Doc_Array of Doc_String)
		// The other seven are numeric indices or padding (pos, type, field_group_index,
		// foreign_library, grouped_entities, and the two reserved words); comparing those needs the
		// type/entity tables and is a separate job, deliberately not started here.
		// All three of these cover ground with prior fixes -- link_name alone had #1181 and #1188 --
		// and none of them was verifiable before this line existed.
		init_s := dump_doc_str(&w, de.init_string)
		link_s := dump_doc_str(&w, de.link_name)
		if init_s != "<blank>" || link_s != "<blank>" || de.where_clauses.length > 0 {
			sb4 := strings.builder_make()
			fmt.sbprintf(&sb4, "docextra\t%s\tinit=%q\tlink=%q", dump_doc_str(&w, de.name), init_s, link_s)
			if de.where_clauses.length > 0 {
				wlo := int(de.where_clauses.offset)
				need := int(de.where_clauses.length) * size_of(Doc_String)
				if wlo >= 0 && wlo + need <= len(w.data) {
					wcs := (cast([^]Doc_String)&w.data[wlo])[:de.where_clauses.length]
					for wc in wcs {
						fmt.sbprintf(&sb4, "\twhere=%q", dump_doc_str(&w, wc))
					}
				} else {
					fmt.sbprintf(&sb4, "\twhere=<bad-span>")
				}
			}
			fmt.sbprintf(&sb4, "\n")
			append(&lines, strings.to_string(sb4))
		}

		docs_s := dump_doc_str(&w, de.docs)
		comment_s := dump_doc_str(&w, de.comment)
		if docs_s != "<blank>" || comment_s != "<blank>" {
			sb2 := strings.builder_make()
			fmt.sbprintf(&sb2, "doccomment\t%s\tdocs=%q\tcomment=%q\n",
				dump_doc_str(&w, de.name), docs_s, comment_s)
			append(&lines, strings.to_string(sb2))
		}
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
