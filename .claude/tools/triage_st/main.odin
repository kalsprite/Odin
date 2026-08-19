package triage_st

import "core:fmt"
import "core:os"
import "core:odin/checker"
import "core:strconv"

main :: proc() {
	args := os.args
	if len(args) < 2 {
		fmt.eprintln("usage: triage_st <package-path>...")
		os.exit(2)
	}
	// LEDGER #329. Both sweeps invoke the reference with -no-entry-point:
	//     parity.sh:59      ./odin check "$p" -no-entry-point
	//     parity_vet.sh:96  ./odin check "$p" -vet -no-entry-point
	// Until #329 the port ignored this flag entirely, because Checker_Info.build_context was nil and
	// the whole entry-point block was unreachable. Now that it is wired, the port WOULD run those
	// checks while the oracle does not, and every package declaring `main` would report diagnostics
	// the reference never emits -- a harness mismatch masquerading as a regression (cf. #45, #275).
	// Set the flag here so the two sides are measured under the same configuration.
	// -target:<name> must be handled BEFORE ensure_build_context_initialized, which is a no-op once
	// a target is set (it guards on metrics.os != .Invalid). The oracle takes the same spelling:
	//     ./odin check <pkg> -no-entry-point -target:linux_i386
	// Without this the harness could only ever be run host-to-host, so every target-dependent rule
	// -- int/uint/uintptr/rawptr widths, string and slice sizes, `#+build` arch tags -- was
	// measured at exactly one point and any divergence away from it was invisible. LEDGER #572.
	for a in args[1:] {
		if len(a) > 8 && a[:8] == "-target:" {
			name := a[8:]
			metrics := checker.get_target_metrics_from_name(name)
			if metrics == nil {
				fmt.eprintf("triage_st: unknown target '%s'\n", name)
				os.exit(2)
			}
			checker.init_build_context(metrics)
		}
	}
	checker.ensure_build_context_initialized()
	// -microarch:<name> must be applied AFTER init_build_context, which does not set it, and it is
	// read lazily through get_final_microarchitecture, so ordering against the target loop above is
	// the only constraint. The oracle takes the same spelling:
	//     ./odin check <pkg> -no-entry-point -target:js_wasm32 -microarch:bleeding-edge
	// Added for #611: the wasm atomics gate answers differently under `generic` (no atomics) and
	// `bleeding-edge` (atomics), so without this the harness could only ever exercise one side of it
	// -- the same blind spot -target: had before #572. An unknown name is NOT rejected here because
	// the checker itself does not reject one either (microarch_default_features returns "" and
	// documents why it does not panic where C++ does); rejecting here would make the harness stricter
	// than the thing it measures.
	for a in args[1:] {
		if len(a) > 11 && a[:11] == "-microarch:" {
			checker.build_context.microarch = a[11:]
		}
	}
	checker.build_context.no_entry_point = true
	// The sweeps run `odin check`, and C++ keys several exemptions off command_kind -- notably
	// the "only works on darwin" objc suppression (check_builtin.cpp:283-287). Mirror the command
	// the oracle is given, or those exemptions cannot fire.
	checker.build_context.command_kind = {.Check}

	// LEDGER #340. Two C++ diagnostics are reachable ONLY under build flags this harness did not
	// set, so newdiag listed them as gaps that no instrument could confirm or refute. These flags
	// make them measurable. Defaults are unchanged, so corpus.sh / parity.sh / flake.sh are
	// unaffected -- every one of them passes package paths only.
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
		case "-dynamic-literals":
			// LEDGER #938. The spec corpus's `litarity` suite declares `-dynamic-literals` in its
			// flags.txt, and 21 of 137 suites declare flags at all. Without this case the flag fell
			// into the default arm and became a PHANTOM PACKAGE -- the harness printed
			// `### -dynamic-literals files=0` and checked the real cell with the feature OFF, so all
			// four `la.sdynamicint.*` cells looked like port defects when the CHECKER WAS ALREADY
			// CORRECT: build_settings.odin already parses "dynamic-literals" and
			// check_for_dynamic_literals reads build_context.dynamic_literals.
			//
			// Jon's ruling stands -- the harness conforms to the library, not the other way around.
			checker.build_context.dynamic_literals = true
		case "-no-threads":
			// LEDGER #426. The REAL control for #344, replacing a taskset attempt whose effect on
			// worker_count was never verified. checker_lifecycle.odin:193 gates thread-pool
			// creation on this flag, so setting it means there is no pool at all -- not merely
			// fewer cores to schedule one onto.
			checker.build_context.no_threaded_checker = true
		case "-vet-style":
			// t204. Added for the same reason as -no-rtti/-dynamic-literals above (LEDGER #340,
			// #938): a C++ diagnostic reachable ONLY under a build flag the harness could not
			// express. parser.cpp:1691's "No need for a trailing comma followed by a %s on the
			// same line" is gated on ast_file_vet_style, so with no case here the flag fell into
			// the default arm and became a PHANTOM PACKAGE -- the harness would have checked the
			// real cell with the feature OFF and reported a clean match for a diagnostic it never
			// asked for. portwrap's DROPPED FLAG guard caught exactly that and refused to let the
			// measurement look valid.
			checker.build_context.vet_flags |= {.Style}
		case "-vet-semicolon":
			// Sibling of the above: assign_removal_flag_to_semicolon gates "Found unneeded
			// semicolon" on `strict_style || .Semicolon in vet_flags`, and only the strict_style
			// half was reachable from this harness.
			checker.build_context.vet_flags |= {.Semicolon}
		case "-strict-style":
			checker.build_context.strict_style = true
		case "-json-errors":
			// t212. Same reason as -vet-style/-no-rtti above: print_errors_json is reachable ONLY
			// under this flag, so with no case here the flag fell into the default arm, became a
			// PHANTOM PACKAGE, and the JSON writer could not be graded against the oracle at all.
			checker.build_context.json_errors = true
		case "-entry-point":
			// Undoes the default above. C++ checks `main` unless -no-entry-point is passed, and
			// the bedrock calling-convention rule lives INSIDE that block -- so without this the
			// check cannot fire at all.
			checker.build_context.no_entry_point = false
		case:
			// LEDGER #418. -dump-model:<path> writes a canonical dump of the semantic model.
			// Handled in the default arm rather than as its own case because it carries a value.
			if len(a) > 8 && a[:8] == "-target:" {
				// Already consumed by the pre-scan above; swallow it so it is not read as a path.
			} else if len(a) > 14 && a[:14] == "-thread-count:" {
				// t211. C++ main.cpp:1076-1086 parses this into build_context.thread_count, which
				// init_build_context otherwise defaults to the logical core count. Carries a value,
				// so it lives in the default arm like -target:/-dump-model:.
				//
				// C++ clamps a non-positive count to 1 AFTER printing the error, and keeps going.
				n, ok := strconv.parse_int(a[14:])
				if !ok || n <= 0 {
					fmt.eprintf(
						"-thread-count expected a positive non-zero number, got %s\n",
						a[14:],
					)
					checker.build_context.thread_count = 1
				} else {
					checker.build_context.thread_count = n
				}
			} else if len(a) > 12 && a[:12] == "-dump-model:" {
				checker.build_context.dump_model_path = a[12:]
			} else if len(a) > 10 && a[:10] == "-dump-doc:" {
				// LEDGER #480. Doc FLAG BITS, which doccmp cannot see.
				checker.build_context.dump_doc_path = a[10:]
			} else if len(a) > 8 && a[:8] == "-define:" {
				// t243t. The checker implements the full six-validation add_defined_value
				// (build_settings.odin:1787), in C++'s observable order -- but NOTHING in this
				// harness ever reached it, so every corpus sweep to date has graded exactly ONE
				// configuration. Anything gated on a #config() value was unreachable from the port
				// side; core/encoding/cbor's `@(init, disabled=!INITIALIZE_DEFAULT_TAGS)`
				// (tags.odin:102) is the worked example, and on the REFERENCE it is the difference
				// between a 641KB and an 89KB binary. Same class as -vet-style/-no-rtti/-json-errors
				// above: without a case here the flag became a PHANTOM PACKAGE.
				if derr, detail := checker.add_defined_value(a[8:]); derr != .None {
					fmt.eprintf("triage_st: -define %v: %s\n", derr, detail)
					os.exit(2)
				}
			} else if len(a) > 13 && a[:13] == "-dump-mindep:" {
				// t243t. The minimum dependency set -- the only instrument that can grade a
				// dep-set fix. MUST be run with -no-threads to be deterministic.
				checker.build_context.dump_mindep_path = a[13:]
			} else {
				append(&paths, a)
			}
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

	// t213. C++ main.cpp:4310-4311 --
	//     init_global_thread_pool();
	//     defer (thread_pool_destroy(&global_thread_pool));
	// The pool is torn down at the end of main, and the port's destroy_global_thread_pool had ZERO
	// CALLERS: the checker is a library and cannot know when the process ends, so the DRIVER is the
	// right host, exactly as it is in the reference. Without this the worker threads are never
	// signalled or joined.
	//
	// This is also the first thing that ever exercises thread_pool_destroy, including the
	// lost-wakeup fix made while it was still unreachable. threadcheck.sh grades the result: a
	// deadlock here shows up as a timeout and a double-free as a crash, on all 323 packages.
	checker.destroy_global_thread_pool()
}
