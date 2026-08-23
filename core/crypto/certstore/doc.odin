/*
package certstore implements a certificate store: a set of certificates,
plus the indexes needed to build and validate a chain out of them.

It is modelled on Go's `crypto/x509.CertPool`, with two deliberate
departures documented below, and it does the verification itself rather
than delegating to the platform verifier the way Go does on macOS and
Windows.

**Loading the system store**

	pool: certstore.Pool
	certstore.init(&pool, context.allocator) or_return
	defer certstore.destroy(&pool)

	when certstore.SYSTEM_STORE_SUPPORTED {
		rep := certstore.load_system_roots(&pool) or_return
		// rep.rejected > 0 is normal: a real system root store holds
		// certificates this package will not anchor. rep.source names
		// the store that was actually used.
	}

	// peer_der is the TLS Certificate message, leaf first.
	vc := certstore.verify_tls(&pool, peer_der, "example.com", time.now()) or_return
	defer certstore.chain_destroy(&vc)

	// vc.chain[0] is the leaf, vc.chain[len-1] is the anchor from the pool.

**A private CA, with nothing from the system**

	pool: certstore.Pool
	certstore.init(&pool, context.allocator) or_return
	defer certstore.destroy(&pool)

	certstore.add_anchor_file(&pool, "ca/root.pem")       or_return
	certstore.add_intermediate_file(&pool, "ca/sub.pem")  or_return

	// A key the private CA has revoked out of band.
	certstore.deny_key_id(&pool, compromised_spki_sha256)

**Append-only**

A certificate can be added, and a certificate can be denied. Nothing is
ever removed and a deny is never lifted. The way to un-trust something is
to build a different pool.

That is not a limitation that was worked around, it is the property that
makes every `^Entry` and every `^x509.Certificate` this package hands out
valid for the entire life of the pool. Storage lives in a single arena
that only ever grows.

**Trust is granted explicitly**

`Trust` has no `.Distrusted` member and the adders are role-typed rather
than taking a trust parameter: `add_anchor_der` says at the call site
what it does. Distrust lives in its own pair of maps, reachable only
through `deny_*`, so it cannot be reached by forgetting to assign a
field. Grep for `add_anchor` to find every place a program grants trust.

**Anchor screening**

Anything added as an anchor must look like a CA: basicConstraints
present and asserting `CA:TRUE`, `keyCertSign` permitted if it declares
KeyUsage at all, and no critical extension this package cannot
interpret. `core:crypto/x509` deliberately does not re-derive CA
authority from an anchor (an anchor is trusted input), which leaves the
store as the only place the question can be asked.

This matters most on the Unix path, which is a scan of whatever is on
disk. A stock Fedora box ships `/etc/pki/tls/certs/localhost.crt`:
self-signed, `CA:FALSE`, an ordinary end-entity certificate, sitting in
a directory that appears in every implementation's fallback list. Go
will anchor it. This package will not.

A local development CA that is not a CA certificate is a real and
legitimate case, and it has its own door: `add_self_signed_anchor_der`
and friends accept a self-signed certificate as an anchor, but only
after verifying the self-signature cryptographically. It is a separate
procedure rather than a flag so that it is visible in a diff.
*/
package certstore
