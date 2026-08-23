#+build windows
package certstore

import win "core:sys/windows"

// SYSTEM_STORE_SUPPORTED reports whether load_system_roots and
// load_system_personal can do anything on this platform. Test it with
// `when`, not with a runtime branch.
SYSTEM_STORE_SUPPORTED :: true

// _load_store copies one named system store into the pool.
//
// `name` is win.LPCWSTR, and that detail matters. win.L is
// intrinsics.constant_utf16_cstring: a COMPILE-TIME constant that
// converts implicitly to cstring16 at the call site, and LPCWSTR is
// wstring is cstring16, so `win.L("ROOT")` passes cleanly. A `[^]u16`
// parameter does not:
//
//	Cannot assign value 'name' of type '[^]u16' to 'cstring16'
//	in a procedure argument
//
// Worth writing down because the failure presents as "win.L is unusable
// here" when the actual fault is the helper's parameter type. Declare it
// as the type the binding declares.
@(private)
_load_store :: proc(
	p: ^Pool,
	name: win.LPCWSTR,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
	r: ^Load_Report,
) -> Error {
	h := win.CertOpenSystemStoreW(nil, name)
	if h == nil {
		return Store_Error.System_Store_Failed
	}
	defer win.CertCloseStore(h, 0)

	// CertEnumCertificatesInStore FREES the context it is handed and
	// returns the next one, so the loop must never free ctx itself. The
	// final call returns nil having already freed the last context -- so
	// there is nothing to release on normal exit, and exactly one context
	// to release on an early return.
	ctx: ^win.CERT_CONTEXT
	for {
		ctx = win.CertEnumCertificatesInStore(h, ctx)
		if ctx == nil {
			break
		}

		r.seen += 1

		// _add clones this into the arena before it returns, so the
		// certificate outlives the context we are about to lose.
		der := ctx.pbCertEncoded[:ctx.cbCertEncoded]
		_, added, aerr := _add(p, der, trust, origin, screen)
		if berr := _bucket(r, added, aerr); berr != nil {
			win.CertFreeCertificateContext(ctx)
			return berr
		}
	}
	return nil
}

// _deny_store puts every certificate in a named store onto the deny list
// without storing any of it.
@(private)
_deny_store :: proc(p: ^Pool, name: win.LPCWSTR) -> Error {
	h := win.CertOpenSystemStoreW(nil, name)
	if h == nil {
		// A machine with no Disallowed store is not an error: it means
		// nothing has been distrusted.
		return nil
	}
	defer win.CertCloseStore(h, 0)

	ctx: ^win.CERT_CONTEXT
	for {
		ctx = win.CertEnumCertificatesInStore(h, ctx)
		if ctx == nil {
			break
		}
		der := ctx.pbCertEncoded[:ctx.cbCertEncoded]
		if derr := deny_cert(p, der); derr != nil {
			win.CertFreeCertificateContext(ctx)
			return derr
		}
	}
	return nil
}

// load_system_roots fills the pool from the machine's ROOT and CA
// stores, honouring the Disallowed store as distrust.
load_system_roots :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_roots: nil pool")
	ensure(p.initialized, "certstore.load_system_roots: pool is not initialized")

	// Disallowed FIRST. Windows expresses distrust as a separate store --
	// "Untrusted Certificates" in certmgr -- which is precisely the user
	// trust metric this package set out to honour, and it maps one-to-one
	// onto the deny list.
	//
	// Correctness does not depend on the ordering: a deny is evaluated
	// when the anchor view is built, so a root loaded before its deny
	// arrives is still excluded from every verification. Loading
	// Disallowed first simply avoids storing DER that will never be used.
	_deny_store(p, win.L("Disallowed")) or_return

	r.source = "ROOT + CA"
	_load_store(p, win.L("ROOT"), .Anchor, .System_Root, .CA_Anchor, &r) or_return
	_load_store(p, win.L("CA"), .Intermediate, .System_Root, .None, &r) or_return

	p.from_system = true
	return r, nil
}

// load_system_personal loads the MY store, for its CERTIFICATES only.
//
// This package never reads, stores or exposes private key material; a
// certificate in MY is chain-building material, not an anchor.
load_system_personal :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_personal: nil pool")
	ensure(p.initialized, "certstore.load_system_personal: pool is not initialized")

	r.source = "MY"
	_load_store(p, win.L("MY"), .Intermediate, .System_Personal, .None, &r) or_return

	p.from_system = true
	return r, nil
}
