// triage_doctext -- emit the port's RENDERED DOCUMENTATION TEXT, so `odin doc` output can be
// diffed against it directly (LEDGER, tick 227).
//
// WHY THIS EXISTS. Three instruments already touch the doc subsystem and NONE of them can see its
// text:
//   doccmp.sh   compares which ENTITIES the port's package scope holds -- presence, not rendering
//               (its own header says so).
//   docflag.sh  gates the Doc_Entity_Flag BITS of the BINARY writer, and is explicitly port-side
//               only, because `odin doc` prints text rather than a bit field.
//   dump_doc    drives the binary writer's two-pass protocol; it never reaches print_doc_package.
// So `generate_documentation` -- the whole plain-text path, which is what a bare `odin doc` runs --
// had NO gate at all. That blind spot is what let four defects sit in docs.odin at once:
// the missing `-in-source-order` comparator AND its per-file grouping, `-short` not selecting
// shorthand expression rendering, and `-short` not suppressing doc comments. All four are
// flag-conditional, which is precisely why an unflagged instrument could never have caught them.
//
// THE COMPARISON IS TEXT-EXACT AND TWO-DIRECTIONAL, unlike doccmp's. `odin doc` and
// generate_documentation are meant to produce the same document, so any difference is a finding.
//
// KNOWN NON-DEFECT DIFFERENCES the caller must normalise (doctext.sh does this, not the harness --
// a harness that hid them would be deciding what counts as a defect):
//   * The oracle prints an absolute `fullpath:` for the package; so does this, but the two runs
//     may resolve symlinks differently.
//   * The oracle documents the packages its OWN loader reached. Point both at the same package.
//
// USAGE: triage_doctext [-short] [-in-source-order] [-all-packages] <package-path>
// Flags map one-for-one onto Cmd_Doc_Flag_Bit, which is the point: the flag surface is the thing
// under test, so it must be reachable from the command line.
package triage_doctext

import "core:fmt"
import "core:os"
import "core:path/filepath"
import "core:strings"
import "core:odin/ast"
import "core:odin/checker"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: triage_doctext [-short] [-in-source-order] [-all-packages] <package-path>")
		os.exit(2)
	}

	flags: checker.Cmd_Doc_Flag
	path: string
	for a in args[1:] {
		switch a {
		case "-short":
			flags += {.Short}
		case "-in-source-order":
			flags += {.In_Source_Order}
		case "-all-packages":
			flags += {.All_Packages}
		case:
			if len(a) > 0 && a[0] == '-' {
				// A DROPPED FLAG IS A FALSE GREEN: the run would compare the port's UNFLAGGED
				// output against the oracle's flagged output and either report a phantom defect or,
				// worse, agree by accident. portwrap.sh learned this the same way.
				fmt.eprintfln("triage_doctext: unknown flag %s", a)
				os.exit(2)
			}
			if path != "" {
				fmt.eprintln("triage_doctext: more than one package path given")
				os.exit(2)
			}
			path = a
		}
	}
	if path == "" {
		fmt.eprintln("triage_doctext: no package path given")
		os.exit(2)
	}

	dump_doc_text(path, flags)
}

dump_doc_text :: proc(path: string, flags: checker.Cmd_Doc_Flag) {
	// Mirror triage_doc's setup. `odin doc` is a different COMMAND from `odin check`, but the same
	// checking run produces the state the doc printer reads; what matters is that the port is not
	// running entry-point checks the oracle never runs (LEDGER #329).
	checker.ensure_build_context_initialized()
	checker.build_context.no_entry_point = true
	checker.build_context.command_kind = {.Doc}
	checker.build_context.cmd_doc_flags = flags

	checker.init_odin_root_from_env()

	checker.init_error_collector(1000)
	defer checker.destroy_error_collector()

	// filepath.abs returns an os.Error, not a bool (triage_doc:62 records the same trap). It is
	// checked before the loader runs so an unresolvable path is reported as ABS-FAILED rather than
	// as an empty document, which would diff clean against a failed oracle run.
	abs, abs_err := filepath.abs(path)
	if abs_err != nil {
		fmt.println("### ABS-FAILED")
		return
	}
	defer delete(abs)

	c := &checker.Checker{}
	checker.init_checker(c, context.allocator)
	defer checker.destroy_checker(c)

	load_result, loader_ok := checker.load_package_with_dependencies(path, &c.info, context.allocator)
	if !loader_ok {
		fmt.println("### LOAD-FAILED")
		return
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
		return
	}

	checker.check_files(c, files[:])

	// generate_documentation walks info.packages itself and applies the All_Packages filter, so
	// this drives the real entry point rather than calling print_doc_package per package -- the
	// #485 lesson: reconstructing a protocol instead of using the existing caller is how steps go
	// missing.
	b := strings.builder_make()
	defer strings.builder_destroy(&b)
	checker.generate_documentation(c, &b)
	fmt.print(strings.to_string(b))
}
