package checker

/*
Runtime session -- load base:runtime ONCE and share it across many independent checks.

WHY THIS EXISTS. A caller that checks many small sources in one process (the spec test suite is
the motivating case: 432 tests) pays a full base:runtime load per check if it goes through
check_package_from_path. Measured: a package whose 36 tests ran in 15ms did not finish in 2
MINUTES that way. Without the load, runtime types simply do not exist -- t_type_info_ptr stays nil
and any test touching type_info_of trips a FAITHFUL assert (C++ has the same one at
check_builtin.cpp:3357), and #location() fails on sources both compilers accept. LEDGER #349.

THE OBSTACLE, and why it is an ownership problem rather than a caching one. The runtime type
globals (t_type_info and ~40 siblings) are resolved out of the loading checker's scopes, so they
are allocated from THAT checker's allocator. destroy_checker therefore calls
reset_runtime_type_globals to nil them -- without it "the next test would read freed memory".
The globals are already a process-wide cache; what dies is their backing memory.

THE SHAPE. Give the runtime its own checker, allocated from default_allocator, and NEVER destroy
it. Everything it owns then lives for the process, which is exactly the lifetime
init_basic_types already relies on for the basic type singletons (checker_lifecycle.odin:205-208,
guarded by `if t_int == nil` and pointedly using default_allocator "since they're global
singletons that must persist across test runs"). This is the same pattern applied one level up.

OPT-IN ON PURPOSE. Nothing changes unless a caller invokes acquire_runtime_session. The normal
one-shot path (check_package_from_path) is untouched, so the parity sweeps and corpus exercise
exactly the code they did before.
*/

import "base:runtime"
import "core:odin/ast"
import "core:slice"
import "core:sync"

@(private = "file")
session_mutex: sync.Mutex

// session_checker is deliberately NEVER destroyed. It owns the parsed base:runtime, its scopes and
// every type reachable from them; destroying it would invalidate the globals it published.
@(private = "file")
session_checker: ^Checker

@(private = "file")
session_pkg: ^ast.Package

@(private = "file")
session_scope: ^Scope

// There is deliberately NO runtime_session_active flag. #354 had one, read by
// reset_runtime_type_globals to suppress teardown while a session was live; suppressing that reset
// is what let one checker's types escape into the next check. See the note at the end of
// acquire_runtime_session. LEDGER #368.

// acquire_runtime_session loads base:runtime once and publishes its package and scope for later
// adopt_runtime_session calls. Idempotent and thread-safe; returns false if the
// runtime could not be located or produced no usable scope, in which case nothing is published and
// callers behave exactly as they did before.
acquire_runtime_session :: proc() -> bool {
	sync.mutex_lock(&session_mutex)
	defer sync.mutex_unlock(&session_mutex)

	if session_checker != nil {
		return session_scope != nil
	}

	init_odin_root_from_env()

	// default_allocator, not the caller's: everything reachable from this checker has to outlive
	// every per-check checker that will borrow it.
	alloc := runtime.default_allocator()

	// context.allocator, NOT just the explicit allocator arguments. The type constructors the
	// checker calls during a load -- alloc_type_pointer and friends -- take no allocator and
	// spend context.allocator. A test caller runs under `context.allocator = context.temp_allocator`
	// with a TEMP_GUARD, so without this line t_type_info_ptr is built in that test's temp arena and
	// is freed the moment the test returns. That is not a theory: it segfaulted at
	// type_info.odin:148 through the `.Any` arm of add_type_info_type_internal, which registers
	// t_type_info_ptr, on the first later test that assigned to an `any`. LEDGER #354.
	context.allocator = alloc

	c := new(Checker, alloc)
	init_checker(c, alloc)

	runtime_path, path_ok := resolve_import_path(RUNTIME_IMPORT_PATH, "", alloc)
	if !path_ok {
		return false
	}

	load_result, loader_ok := load_package_with_dependencies(runtime_path, &c.info, alloc)
	if !loader_ok {
		return false
	}

	files := make([dynamic]^ast.File, alloc)
	defer delete(files)
	for pkg in load_result.packages {
		pkg_files := make([dynamic]^ast.File, 0, len(pkg.files), alloc)
		defer delete(pkg_files)
		for _, f in pkg.files {
			append(&pkg_files, f)
		}
		// Files within a package sorted by fullpath, packages left in load order -- the same
		// shape check_package_from_path builds, so the session sees the runtime the way a normal
		// check would.
		slice.sort_by(pkg_files[:], proc(a, b: ^ast.File) -> bool { return a.fullpath < b.fullpath })
		for f in pkg_files {
			append(&files, f)
		}
	}

	check_files(c, files[:])

	if c.info.runtime_package == nil {
		return false
	}
	scope := get_package_scope(&c.info, c.info.runtime_package)
	if scope == nil {
		return false
	}

	session_checker = c
	session_pkg = c.info.runtime_package
	session_scope = scope

	// Hand the process back exactly as a normal teardown would leave it. Loading the runtime is a
	// real check, so it populates the runtime type globals as a side effect -- t_context,
	// t_atomic_memory_order and ~40 others, all resolved out of THIS checker's scopes. Leaving
	// them set is what #354 did, and the next independent check then inherited them: the lazy
	// "resolve once" guards saw non-nil and skipped, so the package was checked against another
	// checker's types. core/odin/parser went 0 errors -> 37, every one of them "Cannot determine
	// type for implicit selector expression". LEDGER #368.
	//
	// Only two things are meant to be shared, and adopt_runtime_session copies exactly those:
	// info.runtime_package and its scope. Nothing here needs the globals -- an adopting checker
	// re-resolves them from the session scope on demand through find_core_entity.
	reset_runtime_type_globals()
	return true
}

// adopt_runtime_session points an already-initialised checker at the session's base:runtime instead
// of loading its own. Returns false when no session has been acquired, leaving the checker alone.
//
// Only the two things find_core_entity actually reads are shared (type_info.odin:598-616):
// info.runtime_package, and the package_scopes entry for it. Nothing else is aliased, so a
// per-check checker keeps its own scopes, entities and diagnostics.
adopt_runtime_session :: proc(c: ^Checker) -> bool {
	sync.mutex_lock(&session_mutex)
	defer sync.mutex_unlock(&session_mutex)

	if session_pkg == nil || session_scope == nil {
		return false
	}
	c.info.runtime_package = session_pkg
	c.info.package_scopes[session_pkg] = session_scope
	return true
}
