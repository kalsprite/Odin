// triage_doc -- the DOC_BIN harness doccmp.sh requires (LEDGER #520).
//
// WHY THIS EXISTS AGAIN. doccmp.sh compares the port's CHECKER STATE against the oracle's
// `odin doc`, and its header names this harness as its input. The harness was absent from the
// tree, so doccmp could not run at all -- and it did not fail quietly. It reported
// `STATE-DIFFER doc=N port=0 MISSING=N` for EVERY package, i.e. a loud claim that the port's
// package scope is empty for core/strings, core/os, core/math/linalg and the rest. A gate that
// cannot run is bad; a gate that cannot run while accusing the subject of a catastrophic
// regression is worse, because the natural response is to go hunting for the regression.
//
// WHY IT CANNOT JUST CALL check_package_from_path. That function creates the Checker as a STACK
// LOCAL and destroys it on the way out (package_resolver.odin:999-1000, with the comment there
// explaining that `c` therefore cannot be handed back on the result). The scope inventory has to
// be read while the checker is still alive, so this drives the same sequence itself and walks the
// state before tearing down.
//
// OUTPUT CONTRACT, dictated by doccmp.sh and not negotiable:
//   `ENTITY <Kind> <Name>`  -- doccmp greps `(?<=^ENTITY )\S+ \S+$` and takes FIELD 2 as the name,
//                              so exactly two whitespace-separated fields. A kind or name
//                              containing a space would silently corrupt the comparison, which is
//                              why both are emitted through %v/%s of already-space-free values.
//   `### LOAD-FAILED`       -- package did not load / produced no files
//   `### NO-ROOT-SCOPE`     -- loaded, but the root package has no scope (the #29 failure mode)
//   `### ABS-FAILED`        -- the path could not be made absolute
// doccmp greps for those three markers to distinguish "the port died" from "the port disagreed".
//
// THE COMPARISON IS ONE-DIRECTIONAL by design (doccmp.sh:13-18): `odin doc` lists only EXPORTED
// declarations, while this scope legitimately also holds imports, @(private) entities and
// file-scope names. Port-only entities are expected and counted, never failed. So this harness
// should over-report rather than filter -- any filtering here could only manufacture false
// MISSING lines, which is the one direction doccmp treats as a failure.
package triage_doc

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:strings"
import "core:odin/ast"
import "core:odin/checker"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: triage_doc <package-path>...")
		os.exit(2)
	}
	for path in args[1:] {
		dump_package(path)
	}
}

dump_package :: proc(path: string) {
	// Mirror triage_st's build_context setup. doccmp compares against `odin doc`, which is a
	// different COMMAND from `odin check`, but the entity inventory is produced by the same
	// checking run; what matters is that the port is not running entry-point checks the oracle
	// never runs (LEDGER #329) and that command-kind-gated exemptions can fire (#283).
	checker.ensure_build_context_initialized()
	checker.build_context.no_entry_point = true
	checker.build_context.command_kind = {.Check}

	// filepath.abs returns an os.Error, not a bool -- checked rather than assumed, because a
	// `!ok` on a non-boolean is a compile error here and would have been a silent truthiness bug
	// in a language that allowed it.
	abs, abs_err := filepath.abs(path)
	if abs_err != nil {
		fmt.println("### ABS-FAILED")
		return
	}
	defer delete(abs)

	checker.init_odin_root_from_env()

	// Order matters and is copied from check_package_from_path: the collector must exist before
	// the checker, because checker initialisation reports through it.
	checker.init_error_collector(1000)
	defer checker.destroy_error_collector()

	c := &checker.Checker{}
	checker.init_checker(c, context.allocator)
	defer checker.destroy_checker(c)

	load_result, loader_ok := checker.load_package_with_dependencies(path, &c.info, context.allocator)

	files: [dynamic]^ast.File
	defer delete(files)
	for pkg in load_result.packages {
		// sorted_files, not raw map order. package_resolver.odin:1052-1065 explains why: C++
		// sorts each package's files by basename before checking, and matching that ordering is
		// what makes the run reproducible. A harness that iterated the map raw would produce a
		// different inventory on different runs and read as a flaky gate.
		for file in checker.sorted_files(pkg.files) {
			append(&files, file)
		}
	}

	if !loader_ok || len(files) == 0 {
		fmt.println("### LOAD-FAILED")
		return
	}

	checker.check_files(c, files[:])

	// Find the ROOT package by absolute path rather than taking packages[0]. The loader returns
	// dependencies in the same slice, and which one lands first is not something this harness
	// should assume -- picking the wrong package would report a completely different inventory
	// and, because doccmp's failure direction is "doc lists something the port lacks", would
	// show up as hundreds of spurious MISSING lines.
	root: ^ast.Package
	for pkg in load_result.packages {
		if pkg == nil {
			continue
		}
		if paths_equal(pkg.fullpath, abs) {
			root = pkg
			break
		}
	}
	if root == nil {
		fmt.println("### LOAD-FAILED")
		return
	}
	if root.scope == nil {
		fmt.println("### NO-ROOT-SCOPE")
		return
	}

	lines: [dynamic]string
	defer {
		for l in lines {
			delete(l)
		}
		delete(lines)
	}

	for name, e in root.scope.elements {
		if e == nil || len(name) == 0 {
			continue
		}
		append(&lines, fmt.aprintf("ENTITY %v %s", e.kind, name))
	}

	// INIT/FINI rosters. These are emitted with distinct pseudo-kinds so they cannot be confused
	// with scope entities of the same name -- #286 was exactly a case where these arrays were
	// silently empty, and a roster entry that looked like an ordinary entity would have hidden it.
	for e in c.info.init_procedures {
		if e != nil {
			append(&lines, fmt.aprintf("ENTITY InitProc %s", e.token.text))
		}
	}
	for e in c.info.fini_procedures {
		if e != nil {
			append(&lines, fmt.aprintf("ENTITY FiniProc %s", e.token.text))
		}
	}

	// Sorted: the scope is a MAP, so emission order is otherwise address-dependent. doccmp sorts
	// its own side anyway, but an unsorted dump would make this harness useless for the
	// eyeball-the-diff workflow and would defeat dumpdet-style determinism checking.
	slice.sort(lines[:])
	for l in lines {
		fmt.println(l)
	}
}

// paths_equal compares two absolute paths after normalising separators and stripping any trailing
// separator. LEDGER #9 and #363 were both trailing-separator defects in path handling; the loader
// and filepath.abs need not agree on that detail, and a mismatch here would silently select no
// root package at all.
paths_equal :: proc(a, b: string) -> bool {
	ca, ca_err := filepath.clean(a)
	if ca_err != nil {
		return false
	}
	defer delete(ca)
	cb, cb_err := filepath.clean(b)
	if cb_err != nil {
		return false
	}
	defer delete(cb)
	return strings.trim_right(ca, "/\\") == strings.trim_right(cb, "/\\")
}
