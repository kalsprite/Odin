#+build !windows
#+build !darwin
#+build !linux
#+build !freebsd
#+build !openbsd
#+build !netbsd
package certstore

// SYSTEM_STORE_SUPPORTED reports whether load_system_roots and
// load_system_personal can do anything on this platform. Test it with
// `when`, not with a runtime branch.
//
// This platform has no certificate store this package knows how to read.
// Everything else in the package still works: build the pool yourself,
// typically from a bundle compiled in with `#load`.
//
//	when certstore.SYSTEM_STORE_SUPPORTED {
//		certstore.load_system_roots(&pool) or_return
//	} else {
//		certstore.add_anchors_pem(&pool, #load("roots.pem")) or_return
//	}
SYSTEM_STORE_SUPPORTED :: false

load_system_roots :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_roots: nil pool")
	ensure(p.initialized, "certstore.load_system_roots: pool is not initialized")
	return r, Store_Error.Unsupported_Platform
}

load_system_personal :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_personal: nil pool")
	ensure(p.initialized, "certstore.load_system_personal: pool is not initialized")
	return r, Store_Error.Unsupported_Platform
}
