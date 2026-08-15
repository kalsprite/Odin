package checker

// dump_model -- serialise the checker's SEMANTIC MODEL to a canonical text file.
//
// PORT-ONLY. C++ has no equivalent; adding one there is an upstream change.
//
// WHY. parity.sh compares DIAGNOSTICS: what the checker says is wrong. Two checkers can agree on
// every diagnostic and still have built different types. modelcmp.sh reaches part of the model,
// but only by reading layout out of error messages, so it can express nothing that is not an
// array length -- entity sets and scopes are unreachable that way. #416 was exactly this blind
// spot: type_align_of had no Bit_Field arm, every bit_field reported align 8, and all 323 parity
// packages were green with it present because it produced no wrong message.
//
// TWO VIEWS, and both are needed for different questions:
//
//   SORTED    -- for SEMANTIC comparison. Order-independent, so iteration nondeterminism cannot
//                show up as a false difference. This is the view to diff between implementations.
//   INSERTION -- for ORDER defects. Emits info.entities in the order the checker actually built
//                it. #335 needs precisely this: it would show core/c/libc's entities interleaved
//                with vendor/libc-shim's, which LEDGER #400 previously had to establish by hand
//                from index bands.
//
// Diffing two SORTED dumps of the same input across runs is also a determinism gate on its own,
// with no second implementation involved.
//
// FORMAT: one fact per line, tab-separated, no trailing whitespace. Positions are made relative
// to ODIN_ROOT so two checkouts in different directories still compare equal.

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:odin/ast"

// dump_model_entity_line renders one entity as a single canonical line.
//
// Deliberately excluded: pointer values, ids, and anything else that is an allocation artefact
// rather than a semantic fact. Including them would make every run differ and the gate useless.
// DUMP_MODEL SCHEMA v2 (LEDGER #544).
//
// v1 emitted nine columns and modeldiff could only COMPARE four of them
// (name, kind, size, align, keyed by package). Everything else was either absent from the C++
// side entirely (flags, poly, pos) or deliberately excluded from comparison (the rendered type,
// because the two printers are independent). That is why #543's defect -- a constant whose VALUE
// was wrong -- reached this instrument only as a third-order presence side-effect: three body
// locals missing because a `when` took the wrong branch. The value itself was never emitted.
//
// v2 emits the full per-entity state. The shape is:
//
//     entity <TAB> pkg <TAB> name <TAB> kind <TAB> size=N <TAB> align=N <TAB> key=value ...
//
// The first six fields are POSITIONAL and unchanged from v1, so both sides' existing parsers keep
// working. Everything after is KEY=VALUE and OMITTED WHEN DEFAULT -- most entities have most
// variant fields at zero, so lines stay short instead of growing 3.5x.
//
// WHY NOT A BINARY STRUCT (the obvious alternative, considered and rejected):
//   - There is no shared layout to standardise on. C++ Entity and Odin Entity differ in field
//     order, padding, enum width and string representation, so a binary format needs a THIRD
//     serialisation struct plus a hand-written writer on each side -- the same field-by-field
//     enumeration as this, with endianness and padding added as new silent-divergence modes.
//   - Strings dominate the payload (names, types, link names, constant values), so the
//     fixed-width advantage evaporates exactly where the semantics live.
//   - Every finding this instrument has produced (#416, #514, #509, #542, #543) came from reading
//     or grepping these lines. #483's lesson is that a gate which is awkward to inspect stops
//     being inspected.
// The one property a shared struct WOULD have bought -- neither side able to quietly omit a field
// -- is instead enforced by DUMP_MODEL_SCHEMA below: both implementations emit it and modeldiff
// refuses to compare dumps whose schema lines disagree.
//
// DELIBERATELY EXCLUDED, and listed here so the omission is on the record rather than implied:
//   pointers and ids   allocation artefacts; they differ every run and would make the gate useless
//   mutexes, gen_procs caches      not semantic state
//   instantiation POSITIONS        #421: the winning call site varies with thread scheduling, so
//                                  instantiations carry <instantiation> instead of a position
//   Entity.min_dep_count           dependency-count convergence is scheduling-sensitive; including
//                                  it would reintroduce run-to-run noise this gate exists to avoid
DUMP_MODEL_SCHEMA :: "pkg,name,kind,size,align,state,flags,poly,value,cflags,fidx,fgidx,bitsize," +
	"tls,link,linkpfx,linksfx,linksec,foreign,export,global,static,rodata,optmode,entrypoint," +
	"memcpylike,anon,nosanaddr,nosanmem,instr,branchloc,objcimpl,objcclsmethod,objcsel,objcclass," +
	"alias,mangled,group,builtin,deprecated,warning,tidepn,tags,type,pos"

// dump_model_norm lowercases and strips underscores. EVERY enum-valued column goes through it,
// because the two implementations spell the same enum differently everywhere, not just in flags:
// port `In_Progress` / `Favor_Size` against C++ `InProgress` / `FavorSize`. One rule, applied to
// state, optmode, cflags and the flag set, is what makes those columns comparable at all.
@(private="file")
dump_model_norm :: proc(raw: string) -> string {
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for i in 0..<len(raw) {
		c := raw[i]
		if c == '_' {
			continue
		}
		if c >= 'A' && c <= 'Z' {
			c += 'a' - 'A'
		}
		strings.write_byte(&b, c)
	}
	return strings.to_string(b)
}

@(private="file")
// dump_model_sanitise makes a value safe for a TAB-separated line. Constant strings can contain
// tabs and newlines; without this a single such constant would silently corrupt the column
// structure for that line and the diff would blame the wrong field.
// (STRANDED above a different procedure until #734 -- another procedure was inserted between
//  this doc comment and the definition it documents.)
dump_model_sanitise :: proc(s: string) -> string {
	needs := false
	for i in 0..<len(s) {
		if s[i] == '\t' || s[i] == '\n' || s[i] == '\r' {
			needs = true
			break
		}
	}
	if !needs {
		return s
	}
	b: strings.Builder
	strings.builder_init(&b, context.temp_allocator)
	for i in 0..<len(s) {
		switch s[i] {
		case '\t': strings.write_string(&b, "\\t")
		case '\n': strings.write_string(&b, "\\n")
		case '\r': strings.write_string(&b, "\\r")
		case:      strings.write_byte(&b, s[i])
		}
	}
	return strings.to_string(b)
}

@(private="file")
dump_model_kv :: proc(sb: ^strings.Builder, key: string, val: string) {
	fmt.sbprintf(sb, "\t%s=%s", key, dump_model_sanitise(val))
}

@(private="file")
dump_model_kv_str :: proc(sb: ^strings.Builder, key: string, val: string) {
	if len(val) == 0 {
		return
	}
	dump_model_kv(sb, key, val)
}

// dump_model_emit_tags writes the `tags=` field for a struct or bit_field, or nothing when every
// tag is empty. See the call site for why this is emitted on the type-declaring entity and why it
// is safe to compare across implementations. SCHEMA v4.
@(private="file")
dump_model_emit_tags :: proc(sb: ^strings.Builder, tags: []string) {
	if len(tags) == 0 {
		return
	}
	any_set := false
	for t in tags {
		if len(t) != 0 {
			any_set = true
			break
		}
	}
	if !any_set {
		return
	}
	joined := strings.join(tags, "\x1f", context.temp_allocator)
	dump_model_kv(sb, "tags", joined)
}

@(private="file")
dump_model_kv_bool :: proc(sb: ^strings.Builder, key: string, val: bool) {
	if !val {
		return
	}
	fmt.sbprintf(sb, "\t%s=true", key)
}

@(private="file")
dump_model_kv_int :: proc(sb: ^strings.Builder, key: string, val: i64) {
	if val == 0 {
		return
	}
	fmt.sbprintf(sb, "\t%s=%d", key, val)
}

// dump_model_entity_line renders one entity as a single canonical line.
@(private="file")
dump_model_entity_line :: proc(sb: ^strings.Builder, e: ^ast.Entity, root: string) {
	if e == nil {
		return
	}
	name := e.token.text
	if len(name) == 0 {
		name = "<blank>"
	}

	// LEDGER #464. The package is rendered as `name#id` -- ast.Package.id is 1-based REGISTRATION
	// order (assigned in #452, made deterministic by #459), so it is a semantic fact rather than
	// an allocation artefact. modeldiff strips the `#id` before comparing against C++, which has
	// no equivalent column; it earns its place by discriminating "the same package" from "two
	// package objects sharing a name", which is what settled #344.
	pkg_name := "<none>"
	if e.pkg != nil && len(e.pkg.name) > 0 {
		// `name#id`, NOT just the name. The id disambiguates two same-named packages within
		// ONE dump, which is what dumpdet.sh's port-vs-port determinism check needs.
		//
		// READ THIS BEFORE COMPARING RAW DUMPS BY EYE: the C++ dump has no id, so the two sides'
		// pkg columns are NOT directly comparable. modeldiff.py strips /#\d+$/ before comparing
		// (its read_dump), so every gate is unaffected -- but a human grepping the two files will
		// see `_weierstrass#3` against `_weierstrass` and can easily read the suffix as an
		// instantiation marker. It is not. That misreading cost real time during #560.
		pkg_name = fmt.tprintf("%s#%d", e.pkg.name, e.pkg.id)
	}

	type_str := "<nil>"
	size := -1
	align := -1
	if e.type != nil {
		type_str = type_to_string(e.type)
		// LEDGER #509. INVALID types are excluded as well as untyped ones. is_type_typed returns
		// TRUE for t_invalid in BOTH implementations (#43), so guarding on it alone lets builtins
		// and proc-groups through and reports the alignment of an invalid type -- a value neither
		// compiler decides (C++ falls through its Basic switch to 8, the port to 1). That
		// manufactured 130 of the first 134 model divergences.
		bt := base_type(e.type)
		is_invalid := bt != nil && bt.kind == .Basic && bt.variant.(Type_Basic).kind == .Invalid
		if is_type_typed(e.type) && !is_invalid {
			size = type_size_of(e.type)
			align = type_align_of(e.type)
		}
	}

	fmt.sbprintf(sb, "entity\t%s\t%s\t%v\tsize=%d\talign=%d", pkg_name, name, e.kind, size, align)

	// ---- COMMON ENTITY STATE -----------------------------------------------------------
	dump_model_kv(sb, "state", dump_model_norm(fmt.tprintf("%v", e.state)))
	dump_model_kv(sb, "flags", dump_model_flags(e.flags, sync.atomic_load(&e.proc_body_checked)))

	// ---- PER-VARIANT STATE -------------------------------------------------------------
	is_inst := false
	switch v in e.variant {
	case ast.Entity_Constant:
		// THE #543 COLUMN. A constant's VALUE is the single most load-bearing fact this dump was
		// missing: has_target_feature returning a hardcoded `false` was a wrong value, and v1
		// could not see it at all.
		dump_model_kv(sb, "value", exact_value_to_string(v.value, 256))
		if v.flags != {} {
			dump_model_kv(sb, "cflags", dump_model_norm(fmt.tprintf("%v", v.flags)))
		}
		dump_model_kv_int(sb, "fgidx", i64(v.field_group_index))

	case ast.Entity_Variable:
		dump_model_kv_int(sb, "fidx", i64(v.field_index))
		dump_model_kv_int(sb, "fgidx", i64(v.field_group_index))
		dump_model_kv_int(sb, "bitsize", i64(v.bit_field_bit_size))
		dump_model_kv_str(sb, "tls", v.thread_local_model)
		dump_model_kv_str(sb, "link", v.link_name)
		dump_model_kv_str(sb, "linkpfx", v.link_prefix)
		dump_model_kv_str(sb, "linksfx", v.link_suffix)
		dump_model_kv_str(sb, "linksec", v.link_section)
		dump_model_kv_bool(sb, "foreign", v.is_foreign)
		dump_model_kv_bool(sb, "export", v.is_export)
		dump_model_kv_bool(sb, "global", v.is_global)
		dump_model_kv_bool(sb, "static", v.is_static)
		dump_model_kv_bool(sb, "rodata", v.is_rodata)

	case ast.Entity_Procedure:
		is_inst = v.generated_from_polymorphic
		if v.optimization_mode != .Default {
			dump_model_kv(sb, "optmode", dump_model_norm(fmt.tprintf("%v", v.optimization_mode)))
		}
		dump_model_kv_bool(sb, "foreign", v.is_foreign)
		dump_model_kv_bool(sb, "export", v.is_export)
		dump_model_kv_bool(sb, "entrypoint", v.entry_point_only)
		dump_model_kv_bool(sb, "instr", v.has_instrumentation)
		dump_model_kv_bool(sb, "memcpylike", v.is_memcpy_like)
		dump_model_kv_bool(sb, "branchloc", v.uses_branch_location)
		dump_model_kv_bool(sb, "anon", v.is_anonymous)
		dump_model_kv_bool(sb, "nosanaddr", v.no_sanitize_address)
		dump_model_kv_bool(sb, "nosanmem", v.no_sanitize_memory)
		dump_model_kv_bool(sb, "objcimpl", v.is_objc_impl_or_import)
		dump_model_kv_bool(sb, "objcclsmethod", v.is_objc_class_method)
		// `objcsel` was listed in DUMP_MODEL_SCHEMA from the start but never EMITTED here, so
		// every objc method read as ref=<selector> port=None -- 7680 phantom divergences across
		// the four darwin packages, and the largest apparent disagreement in the whole model.
		// The port stores the selector correctly (check_decl_helpers.odin:2210); only the dump
		// was missing. #509's shape again: suspect the instrument first. LEDGER #558.
		dump_model_kv_str(sb, "objcsel", v.objc_selector_name)

	case ast.Entity_Type_Name:
		dump_model_kv_bool(sb, "alias", v.is_type_alias)
		dump_model_kv_bool(sb, "objcimpl", v.objc_is_implementation)
		dump_model_kv_str(sb, "objcclass", v.objc_class_name)
		dump_model_kv_str(sb, "mangled", v.ir_mangled_name)

	case ast.Entity_Proc_Group:
		dump_model_kv_int(sb, "group", i64(len(v.procs)))

	case ast.Entity_Builtin:
		dump_model_kv(sb, "builtin", builtin_proc_infos[v.id].name)

	case ast.Entity_Label, ast.Entity_Package_Name, ast.Entity_Import_Name,
	     ast.Entity_Library_Name, i32:
		// No comparable payload beyond the common fields.
	}

	dump_model_kv_bool(sb, "poly", is_inst)
	dump_model_kv_str(sb, "deprecated", e.deprecated_message)
	dump_model_kv_str(sb, "warning", e.warning_message)

	// tidepn = |decl.type_info_deps|, the COUNT of type-info dependencies registered against this
	// entity's declaration. C++ Reference: `DeclInfo::type_info_deps` (checker.hpp:242), written by
	// add_type_info_dependency (checker.cpp:883-896) and drained by the min-dep walk.
	//
	// A COUNT rather than the type IDENTITIES, deliberately. The identities would have to be
	// compared as type STRINGS, and `type=` two lines below is excluded from comparison for exactly
	// that reason (modeldiff.py STATE_IGNORED) -- the two implementations render types through
	// independent printers, so a spelling difference would swamp the signal. A count is
	// printer-independent, and it is still sensitive to the thing that has no other instrument: a
	// call site that registers a dependency on one side and not the other moves the number.
	//
	// This is the ONLY differential coverage of the 51 add_type_info_type call sites, and of the
	// min-dep consumer wired in #638.
	//
	// STALENESS CORRECTED (#901): this said "It is NOT gated yet: modeldiff carries it in
	// STATE_IGNORED until a --repeat floor is measured". That was true when written and has been
	// false since #701 -- `modeldiff.py` now has `STATE_IGNORED = {"type"}` and nothing else, so
	// tidepn reaches state_packages/state_entities and IS a gate. The caution was right at the
	// time: the floor was measured first, and only then was it promoted.
	if e.decl_info != nil {
		sync.rw_mutex_shared_lock(&e.decl_info.type_info_deps_mutex)
		n := len(e.decl_info.type_info_deps)
		sync.rw_mutex_shared_unlock(&e.decl_info.type_info_deps_mutex)
		dump_model_kv_int(sb, "tidepn", i64(n))
	}

	// tags = the per-field TAG array of a struct or bit_field, joined with US (0x1f). SCHEMA v4.
	//
	// EMITTED ON THE TYPE-DECLARING ENTITY, not on the field entities, because that is where the
	// data lives on BOTH sides: C++ keeps `String *tags` on TypeStruct/TypeBitField with
	// `count == fields.count`, and so does this port. A field entity has no back-pointer to its
	// owning type, so a per-field emission would need a reverse map built for the dump alone.
	//
	// UNLIKE `type=` BELOW, THIS IS SAFE TO COMPARE ACROSS IMPLEMENTATIONS: a tag is a literal
	// taken from source, not something rendered by a type printer, so there is no independent
	// spelling to diverge. That is the whole reason it can be a gate at all.
	//
	// The joined form preserves POSITION, which matters: an empty slot means "this field has no
	// tag", and a tag landing on the wrong field is exactly the kind of off-by-one this is meant to
	// catch. 0x1f is used as the separator because dump_model_sanitise escapes \t, \n and \r --
	// the three bytes that would break the column structure -- and leaves 0x1f alone.
	//
	// Omitted entirely when every tag is empty, which is almost every struct in the tree; that
	// keeps the dump small and makes the common case agree trivially rather than by comparison.
	//
	// This exists to make LEDGER #899 measurable: the port drops bit_field tags on the floor
	// (Type_Bit_Field has no tags field at all), and the port's unquote_string lacks C++'s
	// `has_carriage_return` argument, so a raw-string tag keeps CRs the reference strips. Both are
	// invisible to every diagnostic gate, and were invisible to this one until v4.
	if e.type != nil {
		if bt := base_type(e.type); bt != nil {
			#partial switch v in bt.variant {
			case Type_Struct:
				dump_model_emit_tags(sb, v.tags[:])
			case Type_Bit_Field:
				// #904: only reachable since Type_Bit_Field gained a `tags` field. Before that
				// the port parsed bit_field tags and discarded them, and this arm would have had
				// nothing to read.
				dump_model_emit_tags(sb, v.tags[:])
			}
		}
	}

	// type= is emitted for GROUPING within one side (it separates "N copies of one type" from "N
	// distinct instantiations") but is NOT compared across implementations: the two printers are
	// independent, so a cosmetic spelling difference would swamp the signal.
	dump_model_kv(sb, "type", type_str)

	// LEDGER #421. A polymorphic instantiation is created by whichever call site demands it first
	// and stamped with THAT site's position; under parallel body checking the winner varies (e.g.
	// datetime's `divmod` at two different call sites across runs). That is call-site churn, not a
	// semantic difference, so instantiations get a canonical marker instead of a position.
	if is_inst {
		dump_model_kv(sb, "pos", "<instantiation>")
	} else {
		dump_model_kv(sb, "pos", fmt.tprintf("%s:%d:%d",
			dump_model_rel_pos(e.token.pos.file, root), e.token.pos.line, e.token.pos.column))
	}
	strings.write_byte(sb, '\n')
}

// dump_model_flags renders the flag set in a form BOTH implementations can produce.
//
// LEDGER #476 established the `|`-separated sorted-names form (a raw `%v` on the bit_set printed
// Odin-native syntax carrying the bit_set's own type and backing integer type, which C++ has no
// reason to emit). #544 adds the other half: the names are NORMALISED to lowercase with
// underscores removed, because the two enums agree on the 41 members but not on spelling --
// port `Array_Elem` / `Poly_Const` / `Custom_Linkage_Link_Once` against C++ `ArrayElem` /
// `PolyConst` / `CustomLinkage_LinkOnce`. Normalisation is injective over all 41 on both sides
// (checked), so nothing collides. Without it this column could never have been compared at all,
// which is why v1 emitted it on the port side only and C++ not at all.
@(private="file")
dump_model_flags :: proc(flags: ast.Entity_Flags, proc_body_checked: bool) -> string {
	names: [dynamic]string
	defer delete(names)
	// PROC_BODY_CHECKED IS NOT IN THE FLAG SET ON THIS SIDE. The port deliberately moved that bit
	// out to Entity.proc_body_checked (semantic_types.odin:282): publishing it into the shared word
	// with atomic_or raced with the ~108 non-atomic `flags +=` sites and produced the intermittent
	// `.Proc_Body_Checked in ...` assertion. C++ keeps it in `flags` (bit 21), so without folding
	// it back in here the column disagreed on 415 of 695 comparable entities in core/hash/xxhash --
	// a representational difference masquerading as 415 defects. The FACT is the same on both
	// sides; only the storage differs, and the dump reports facts.
	if proc_body_checked {
		append(&names, "procbodychecked")
	}
	if flags == {} && len(names) == 0 {
		return "-"
	}
	for f in ast.Entity_Flag {
		if f in flags {
			append(&names, dump_model_norm(fmt.tprintf("%v", f)))
		}
	}
	slice.sort(names[:])
	return strings.join(names[:], "|", context.temp_allocator)
}

// dump_model_rel_pos strips ODIN_ROOT so dumps from different checkouts compare equal.
@(private="file")
dump_model_rel_pos :: proc(file: string, root: string) -> string {
	if len(root) > 0 && strings.has_prefix(file, root) {
		s := file[len(root):]
		for len(s) > 0 && (s[0] == '/' || s[0] == '\\') {
			s = s[1:]
		}
		return s
	}
	return file
}

// dump_model writes the model to path. Called from check_package_from_path BEFORE the Checker is
// destroyed -- see the note on Build_Context.dump_model_path for why this cannot be an accessor
// handed back to the caller.
//
// Returns false and leaves a message on stderr if the file could not be written. It deliberately
// does NOT abort the check: a failed dump must not turn a passing check into a failing one, and
// a SILENT failure is worse still (an empty dump diffs clean against another empty dump, which is
// the #405 false-green shape).
dump_model :: proc(c: ^Checker, path: string) -> bool {
	if c == nil || len(path) == 0 {
		return false
	}
	info := &c.info

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	root := build_context.ODIN_ROOT

	// ---- INSERTION VIEW ----------------------------------------------------------------
	// info.entities in the order the checker built it. Do not sort this section.
	// SCHEMA LINE. Both implementations emit this and modeldiff REFUSES to compare dumps whose
	// schema lines disagree. This is the enforcement a shared binary struct would have given:
	// a field silently dropped on one side becomes a loud refusal instead of a silent agreement.
	fmt.sbprintf(&sb, "## schema v4 %s\n", DUMP_MODEL_SCHEMA)
	fmt.sbprintf(&sb, "## insertion-order entities=%d\n", len(info.entities))
	for e in info.entities {
		strings.write_string(&sb, "ins\t")
		dump_model_entity_line(&sb, e, root)
	}

	// ---- SORTED VIEW -------------------------------------------------------------------
	// Same set, canonically ordered, so a diff between implementations reflects CONTENT rather
	// than iteration order.
	lines: [dynamic]string
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}
	for e in info.entities {
		esb := strings.builder_make()
		dump_model_entity_line(&esb, e, root)
		append(&lines, strings.to_string(esb))
	}
	slice.sort(lines[:])

	fmt.sbprintf(&sb, "## sorted entities=%d\n", len(lines))
	for l in lines {
		strings.write_string(&sb, l)
	}

	fmt.sbprintf(&sb, "## end\n")

	// os.write_entire_file returns an Error, not a bool. Reporting loudly on failure is the
	// point: a dump that silently did not happen would diff clean against another absent dump,
	// which is the #405 false-green shape.
	if werr := os.write_entire_file(path, transmute([]byte)strings.to_string(sb)); werr != nil {
		fmt.eprintf("dump_model: FAILED to write '%s' (%v) -- the dump is MISSING, not empty\n",
			path, werr)
		return false
	}
	return true
}
