// entryprobe -- print the entry point and root package a Session resolves, for a given package.
//
// WHY A STATE HARNESS AND NOT A DIAGNOSTIC PROBE. The entry-point fix has two independent halves
// (#589): the `.Init` kind stamped on the loader's root seed, and the unconditional
// `info.init_fullpath` write. Diagnostic probes can only see the first. The second matters solely
// when the REQUESTED package is base/runtime -- the runtime seed is dequeued first, the root entry
// is skipped by the already-loaded guard, so the package keeps kind `.Runtime` and only the
// fullpath comparison in create_scope_from_package (C++ checker.cpp:268) can identify it as the
// init package. On that input BOTH compilers emit zero diagnostics, so a diagnostic probe would
// report MATCH while entry_point silently went nil: vacuous, in the sense of #483.
//
// THERE IS NO ORACLE FOR THIS. C++ has no flag that prints its resolved entry point, so this
// cannot be an oracle comparison like every other gate here. entrypoint.sh therefore scores it
// against an EXPECTATION TABLE, and that difference is stated at the call site rather than
// papered over -- an expectation is only as good as the reasoning behind it, whereas the oracle is
// evidence. The expectations here are the ones the C++ rules require, derived by reading
// checker.cpp:268 and :7790, not by recording current behaviour.
//
// It also happens to be the only automated exercise of Session.root (#588) and
// Session.checker.info.entry_point, the two things a backend actually needs to consume.
package entryprobe

import "core:fmt"
import "core:os"
import "core:odin/checker"

main :: proc() {
	if len(os.args) < 2 {
		fmt.eprintln("usage: entryprobe <package-path> [-no-entry-point]")
		os.exit(2)
	}

	checker.ensure_build_context_initialized()

	// The entry-point surface is gated on build_mode == .Executable && !no_entry_point
	// (C++ checker.cpp:7790), so both must be set deliberately or this measures nothing.
	checker.build_context.build_mode = .Executable

	// no_entry_point goes through Session_Options (#590), NOT by assigning the global. Since
	// session_check_package now saves the global, applies the option and restores it, a direct
	// assignment here would simply be overwritten by the option's default -- which is precisely
	// the leak the save/restore exists to prevent, observed from the caller's side.
	opts: checker.Session_Options
	for a in os.args[2:] {
		if a == "-no-entry-point" {
			opts.no_entry_point = true
		}
	}

	s, ok := checker.session_check_package(os.args[1], opts)
	if !ok || s == nil {
		fmt.eprintln("entryprobe: session_check_package failed")
		os.exit(2)
	}
	defer checker.session_destroy(s)

	// One machine-readable line per fact, so a comparator can assert on them individually and a
	// failure names which one moved.
	root_name := "<nil>"
	if s.root != nil {
		root_name = s.root.name
	}
	ep_name := "<nil>"
	if ep := s.checker.info.entry_point; ep != nil {
		ep_name = ep.token.text
	}
	fmt.printf("root=%s\n", root_name)
	fmt.printf("entry_point=%s\n", ep_name)
	fmt.printf("packages=%d\n", len(s.packages))
	// The error count is what encodes the LIBRARY case (#590): a package with no `main`, checked
	// with no_entry_point, must produce ZERO errors. Asserting only entry_point==<nil> there would
	// pass trivially -- it is nil whether or not the diagnostic fired.
	fmt.printf("errors=%d\n", s.result.check_errors)
}
