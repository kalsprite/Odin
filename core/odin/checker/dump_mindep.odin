package checker

import "core:fmt"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:odin/ast"

// dump_mindep writes the MINIMUM DEPENDENCY SET as a canonical, sorted text dump.
//
// WHY THIS IS A SEPARATE SINK AND NOT A dump_model COLUMN.
// dump_model.odin:76 deliberately EXCLUDES Entity.min_dep_count from the v4 schema, because
// dependency-count convergence is scheduling-sensitive. That exclusion is correct and stays.
// Adding the field to v4 would also change DUMP_MODEL_SCHEMA, and modeldiff_hybrid.py REFUSES
// to compare dumps whose schema lines disagree (by design, #405) -- so a new v4 column would
// break every modelsweep run against the C++ reference dumper wholesale, for every package.
// This sink therefore has its OWN schema line and its own file, and modelsweep never reads it.
//
// THE SCHEDULING SENSITIVITY IS REMOVED BY CONSTRUCTION, NOT TOLERATED. Callers must run the
// port with -no-threads. Under a single thread the walk order is fixed, so `min_dep_count` is
// a deterministic function of the source. The COUNT is still reported rather than just the
// boolean, because a count that moves while membership does not is itself a signal -- but
// MEMBERSHIP (`in=`) is the graded column, since that is what C++'s
// `ptr_set_exists(&c->info.minimum_dependency_set, e)` actually tests, and what
// type_info.odin:1427 (`if e.min_dep_count <= 0`) consumes.
//
// WHAT IT IS FOR. It is the only instrument that can grade a dependency-set fix. t243q (FIX 11)
// changed the @(init)/@(fini) gate from EntityFlag_Init to roster membership; a DISABLED @(init)
// is legal code (check_decl.odin:1955 warns, it does not error) that carries the flag and is
// deliberately absent from the roster. dump_model cannot see that difference at all -- the two
// binaries' dumps of $S/phase2/wit_disinit243/disinit are BYTE-IDENTICAL. This sink can.
//
// Failure is LOUD for the #405 reason: an absent dump diffs clean against another absent dump.
dump_mindep :: proc(c: ^Checker, path: string) -> bool {
	if c == nil || len(path) == 0 {
		return false
	}
	info := &c.info

	sb := strings.builder_make()
	defer strings.builder_destroy(&sb)

	root := build_context.ODIN_ROOT

	lines: [dynamic]string
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}

	in_set := 0
	for e in info.entities {
		if e == nil {
			continue
		}
		n := sync.atomic_load(&e.min_dep_count)
		if n > 0 {
			in_set += 1
		}

		// Same package spelling as dump_model: `name#id`, so two same-named packages within one
		// dump stay distinguishable (#344).
		pkg_name := "<none>"
		if e.pkg != nil && len(e.pkg.name) > 0 {
			pkg_name = fmt.tprintf("%s#%d", e.pkg.name, e.pkg.id)
		}

		// A polymorphic instantiation is stamped with whichever call site demanded it first, and
		// that winner varies run to run (#421). Give it a canonical marker instead of a position,
		// exactly as dump_model does, or the sort order itself becomes nondeterministic.
		is_inst := false
		if v, ok := e.variant.(ast.Entity_Procedure); ok {
			is_inst = v.generated_from_polymorphic
		}

		name := e.token.text
		if len(name) == 0 {
			name = "<blank>"
		}

		pos := "<instantiation>"
		if !is_inst {
			pos = fmt.tprintf("%s:%d:%d",
				dump_mindep_rel_pos(e.token.pos.file, root), e.token.pos.line, e.token.pos.column)
		}

		esb := strings.builder_make()
		// `flags` is rendered with a raw %v rather than dump_model's normalised, sorted,
		// `|`-separated form (#476/#544). That normalisation exists so C++ and the port can be
		// compared; THIS sink is PORT-vs-PORT ONLY -- there is no C++ mindep dumper to diff
		// against -- so both sides of every comparison are produced by this same printer and a
		// native spelling cannot manufacture a difference. It is here to make a readout legible
		// next to `in=`, not to be a gate.
		fmt.sbprintf(&esb, "mindep\t%s\t%s\t%v\tin=%d\tn=%d\tflags=%v\tpos=%s\n",
			pkg_name, name, e.kind, 1 if n > 0 else 0, i64(n), e.flags, pos)
		append(&lines, strings.to_string(esb))
	}
	slice.sort(lines[:])

	fmt.sbprintf(&sb, "## schema mindep v1 pkg,name,kind,in,n,flags,pos\n")
	fmt.sbprintf(&sb, "## entities=%d in_set=%d\n", len(info.entities), in_set)
	for l in lines {
		strings.write_string(&sb, l)
	}
	fmt.sbprintf(&sb, "## end\n")

	if werr := os.write_entire_file(path, transmute([]byte)strings.to_string(sb)); werr != nil {
		fmt.eprintf("dump_mindep: FAILED to write '%s' (%v) -- the dump is MISSING, not empty\n",
			path, werr)
		return false
	}
	return true
}

// Verbatim in behaviour with dump_model.odin:429 (which is @(private="file") and therefore not
// reachable from here). Duplicated rather than made package-visible: dump_model.odin is what every
// modelsweep run depends on, and widening a symbol's visibility there to serve a new instrument is
// a change to the load-bearing file for the benefit of the disposable one.
@(private="file")
dump_mindep_rel_pos :: proc(file: string, root: string) -> string {
	if len(root) > 0 && strings.has_prefix(file, root) {
		s := file[len(root):]
		for len(s) > 0 && (s[0] == '/' || s[0] == '\\') {
			s = s[1:]
		}
		return s
	}
	return file
}
