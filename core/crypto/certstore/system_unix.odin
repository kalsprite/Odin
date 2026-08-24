#+build linux, freebsd, openbsd, netbsd
package certstore

import "core:mem/virtual"
import "core:os"

// SYSTEM_STORE_SUPPORTED reports whether load_system_roots and
// load_system_personal can do anything on this platform. Test it with
// `when`, not with a runtime branch.
SYSTEM_STORE_SUPPORTED :: true

// Tried in order. The FIRST bundle that yields a certificate wins; the
// directory scan below is a fallback, not an addition. That ordering
// matters on distributions that ship both, which would otherwise be read
// twice.
@(rodata, private)
_CERT_FILES := []string {
	"/etc/ssl/certs/ca-certificates.crt", // Debian, Ubuntu, Arch, Gentoo
	"/etc/pki/tls/certs/ca-bundle.crt", // Fedora, RHEL 6
	"/etc/ssl/ca-bundle.pem", // openSUSE
	"/etc/pki/tls/cacert.pem", // OpenELEC
	"/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem", // RHEL 7, CentOS
	"/etc/ssl/cert.pem", // Alpine, *BSD
}

// Fallback only, if no bundle above produced anything.
@(rodata, private)
_CERT_DIRS := []string {
	"/etc/ssl/certs",
	"/etc/pki/tls/certs",
	"/system/etc/security/cacerts", // Android
}

// load_system_roots fills the pool from this system's CA bundle.
//
// Unix has no certificate store API: this is a search of well-known
// paths, and `r.source` reports which one was actually used.
//
// Anchor screening applies. Go's Unix path reads these same directories
// and, because a CertPool accepts anything, will happily anchor
// /etc/pki/tls/certs/localhost.crt. This is the one place the package is
// deliberately stricter than the implementation it is modelled on.
load_system_roots :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_roots: nil pool")
	ensure(p.initialized, "certstore.load_system_roots: pool is not initialized")

	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch, _SCRATCH_BLOCK) or_return
	defer virtual.arena_destroy(&scratch)

	for path in _CERT_FILES {
		sub: Load_Report
		if ferr := _add_file(p, path, .Anchor, .System_Root, .CA_Anchor, &sub, &scratch);
		   ferr != nil {
			// Not present on this distribution, or not a certificate
			// bundle. Either way, try the next candidate. An allocation
			// failure is a different matter and stops the search.
			if _unreadable(ferr) {
				continue
			}
			return r, ferr
		}
		// The test is `seen`, not `added`. A bundle whose certificates
		// this pool already holds is still the bundle: testing `added`
		// would make a second load_system_roots on the same pool walk
		// past every candidate and end in .No_System_Store.
		if sub.seen > 0 {
			r = sub
			r.source = path
			p.from_system = true
			return r, nil
		}
	}

	for dir in _CERT_DIRS {
		sub: Load_Report
		if derr := _scan_dir(p, dir, &sub, &scratch); derr != nil {
			if _unreadable(derr) {
				continue
			}
			return r, derr
		}
		if sub.seen > 0 {
			r = sub
			r.source = dir
			p.from_system = true
			return r, nil
		}
	}

	return r, Store_Error.No_System_Store
}

// load_system_personal always fails here.
//
// Unix has no per-user certificate store analogous to Windows' MY or the
// macOS login keychain. Reported honestly rather than faked.
load_system_personal :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_personal: nil pool")
	ensure(p.initialized, "certstore.load_system_personal: pool is not initialized")
	return r, Store_Error.No_System_Store
}

// _unreadable reports whether an error means "this candidate path is not
// the one" rather than "the load failed".
@(private)
_unreadable :: proc(err: Error) -> bool {
	return _is(err, .Path_Error) || _is(err, .Bad_PEM)
}

@(private)
_scan_dir :: proc(p: ^Pool, dir: string, r: ^Load_Report, scratch: ^virtual.Arena) -> Error {
	d, oerr := os.open(dir)
	if oerr != nil {
		return Store_Error.Path_Error
	}
	defer os.close(d)

	it := os.read_directory_iterator_create(d)
	defer os.read_directory_iterator_destroy(&it)

	for info in os.read_directory_iterator(&it) {
		ft := info.type

		// /etc/ssl/certs is mostly SYMLINKS: c_rehash fills it with
		// <subject-hash>.0 links back into the bundle directory, so
		// filtering symlinks out would empty the scan on Debian and Arch.
		// Resolve them instead -- os.stat follows, os.lstat would not --
		// and judge the target.
		if ft == .Symlink {
			mark := virtual.arena_temp_begin(scratch)
			target, serr := os.stat(info.fullpath, virtual.arena_allocator(scratch))
			if serr == nil {
				ft = target.type
			}
			virtual.arena_temp_end(mark)
			if serr != nil {
				continue
			}
		}

		// Only regular files. The exclusions that actually bite:
		//
		//   .Directory  -- /etc/ssl/certs/java is a REAL DIRECTORY on
		//                  Debian-family systems; it holds the JVM
		//                  keystore. Reading it as a file is an error at
		//                  best.
		//   .Named_Pipe -- reading a FIFO blocks until a writer appears. A
		//                  directory scan must never be able to hang the
		//                  process, and that is why the type check happens
		//                  BEFORE the open rather than after it.
		if ft != .Regular {
			continue
		}

		// A file that does not parse is skipped, never fatal. An
		// allocation failure still is.
		if ferr := _add_file(p, info.fullpath, .Anchor, .System_Root, .CA_Anchor, r, scratch);
		   ferr != nil && !_unreadable(ferr) {
			return ferr
		}
	}

	// The iterator records an I/O failure rather than raising it, so
	// ignoring it here would mean a truncated directory read reported as a
	// complete one -- an anchor set that is quietly short. Report it as
	// unreadable, which sends the search on to the next candidate; the
	// certificates already stored stay stored, and this scan's counts are
	// discarded with the error.
	if _, ierr := os.read_directory_iterator_error(&it); ierr != nil {
		return Store_Error.Path_Error
	}
	return nil
}
