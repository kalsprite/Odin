package triage_vet

import "core:fmt"
import "core:os"
import "core:odin/checker"

// Mirrors C++ VetFlag_All (src/build_settings.cpp:323):
//   VetFlag_Unused(UnusedVariables|UnusedImports) | Shadowing | UsingStmt | Deprecated | Cast
// This is exactly what a bare `-vet` on the oracle enables -- NOT every Vet_Flag_Bit.
VET_ALL :: checker.Vet_Flag{
	.Unused_Variables,
	.Unused_Imports,
	.Shadowing,
	.Using_Stmt,
	.Deprecated,
	.Cast,
}

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: triage_vet <package-path>...")
		os.exit(2)
	}
	checker.build_context.vet_flags = VET_ALL
	// LEDGER #329. Both sweeps invoke the reference with -no-entry-point:
	//     parity.sh:59      ./odin check "$p" -no-entry-point
	//     parity_vet.sh:96  ./odin check "$p" -vet -no-entry-point
	// Until #329 the port ignored this flag entirely, because Checker_Info.build_context was nil and
	// the whole entry-point block was unreachable. Now that it is wired, the port WOULD run those
	// checks while the oracle does not, and every package declaring `main` would report diagnostics
	// the reference never emits -- a harness mismatch masquerading as a regression (cf. #45, #275).
	// Set the flag here so the two sides are measured under the same configuration.
	checker.ensure_build_context_initialized()
	checker.build_context.no_entry_point = true
	// The sweeps run `odin check`, and C++ keys several exemptions off command_kind -- notably
	// the "only works on darwin" objc suppression (check_builtin.cpp:283-287). Mirror the command
	// the oracle is given, or those exemptions cannot fire.
	checker.build_context.command_kind = {.Check}

	paths: [dynamic]string
	defer delete(paths)
	for a in args[1:] {
		switch a {
		case "-no-rtti":
			// The harness silently IGNORED this flag until tick 191, so every -no-rtti witness
			// measured a port with no_rtti UNSET -- three cells "matched" or "diverged" for
			// reasons that had nothing to do with the checker. The oracle additionally REFUSES
			// -no-rtti unless the target is freestanding or -bedrock is given; that validation
			// lives in the driver, not the checker library, so it is deliberately not modelled
			// here -- the harness's job is to be able to express what the oracle accepts.
			checker.build_context.no_rtti = true
		case "-bedrock":
			// main.cpp:1669-1673 -- `-bedrock` is a COMPOSITE, not a single bool. Setting only
			// .bedrock here would make the harness disagree with the oracle about init/fini.
			checker.build_context.bedrock = true
			checker.build_context.no_rtti = true
			checker.build_context.disable_init_fini = true
			// main.cpp:3974 calls setup_bedrock_mode (main.cpp:3644-3668), which additionally
			// sets this. It is not cosmetic: base/runtime/default_temporary_allocator.odin:4
			// gates NO_DEFAULT_TEMP_ALLOCATOR on it, so leaving it false keeps that file's
			// @(fini) live and the port reports it under -disable-init-fini where the oracle
			// does not. The collection-dropping half of setup_bedrock_mode is not modelled --
			// it only removes the core/vendor search paths, which a probe that imports nothing
			// never consults.
			checker.build_context.ODIN_DEFAULT_TO_NIL_ALLOCATOR = true
		case "-disable-init-fini":
			checker.build_context.disable_init_fini = true
		case "-no-threads":
			// LEDGER #426/#344, and triage_st/main.odin has carried this since then. It was MISSING
			// here, and portwrap.sh passes -no-threads UNCONDITIONALLY, so every invocation of this
			// harness through the wrapper fell into the default arm below and appended it to
			// `paths` -- a PHANTOM PACKAGE (#938), printing `### -no-threads files=0`. Two effects:
			// the flag did nothing, so this harness graded vet cells THREADED while the plain one
			// pins them single-threaded, and the per-cell answer was therefore not reproducible in
			// the way #344 requires. checker_lifecycle.odin:193 gates pool creation on this flag.
			// Not caught earlier because portwrap reads `errors=` from the FIRST summary line, so
			// the phantom's trailing `errors=0` never changed a verdict -- it hid instead of failing.
			checker.build_context.no_threaded_checker = true
		case "-entry-point":
			// Undoes the default above. C++ checks `main` unless -no-entry-point is passed, and
			// the bedrock calling-convention rule lives INSIDE that block -- so without this the
			// check cannot fire at all.
			checker.build_context.no_entry_point = false
		case:
			append(&paths, a)
		}
	}

	for path in paths {

		res := checker.check_package_from_path(path, checker.Session_Options{
			// PASS the harness's decision explicitly. check_package_from_path now APPLIES its
			// opts to the process-global build_context (#593), so calling it with default
			// options would silently overwrite the -no-entry-point set above and undo the
			// whole point of matching the oracle's configuration. Measured the hard way:
			// leaving this as the default put parity at 272 count mismatches.
			no_entry_point = checker.build_context.no_entry_point,
		})
		defer checker.destroy_package_check_result(&res)
		fmt.printf(
			"### %s files=%d errors=%d warnings=%d limit=%v raw_diags=%d\n",
			path, res.total_files, res.check_errors, res.check_warnings,
			res.limit_reached, len(res.diagnostics),
		)
		checker.print_package_diagnostics(&res)
	}
}
