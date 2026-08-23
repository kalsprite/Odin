package certstore

import "core:crypto/x509"

// Distrust is a separate concept from Trust rather than a third enum
// member, and a runtime map rather than a compile-time branch. Both are
// deliberate.
//
// A Trust.Distrusted member would put a security decision in a field
// reachable by forgetting to assign it. Keeping it separate means the
// only way to distrust something is to call deny_*, and the only way to
// un-distrust something is to build a different pool.
//
// Two lists, because they answer different questions:
//
//	denied_certs  Cert_ID  exactly this certificate      the Windows Disallowed
//	                                                     store, Darwin's
//	                                                     kSecTrustSettingsResultDeny,
//	                                                     an admin blocklist
//
//	denied_keys   Key_ID   every certificate bearing     a compromised
//	                       that public key               intermediate; a re-issue
//	                                                     with a fresh serial and
//	                                                     validity window does not
//	                                                     escape it
//
// A deny is enforced twice, and once is not enough. The reason is a
// lifetime asymmetry, not defence in depth:
//
//  1. When the verification views are rebuilt. A denied pool entry is
//     skipped, so it never appears among the roots or intermediates. This
//     covers everything the pool holds -- and it applies retroactively,
//     which is how an append-only pool honours a deny that arrives after
//     the certificate did.
//
//  2. Over the completed chain. The leaf and the peer's intermediates
//     were never pool entries, so the view rebuild has nothing to say
//     about them. The post-chain scan is the only thing that does.

// deny_cert denies exactly these DER bytes.
//
// The certificate does not have to be in the pool, and denying one that
// is already stored is fine: it stays stored, but it can never appear in
// an accepted chain again.
deny_cert :: proc(p: ^Pool, der: []byte) -> Error {
	ensure(p != nil, "certstore.deny_cert: nil pool")
	ensure(p.initialized, "certstore.deny_cert: pool is not initialized")
	return deny_cert_id(p, _cert_id(der))
}

// deny_cert_id denies one certificate by its Cert_ID (see `cert_id`).
deny_cert_id :: proc(p: ^Pool, id: Cert_ID) -> Error {
	ensure(p != nil, "certstore.deny_cert_id: nil pool")
	ensure(p.initialized, "certstore.deny_cert_id: pool is not initialized")

	_, _, _, err := map_entry(&p.denied_certs, id)
	if err != nil {
		return err
	}
	p.views_dirty = true
	return nil
}

// deny_key_id denies every certificate carrying this public key (see
// `key_id`).
//
// This is the granularity a compromised intermediate needs: re-issuing
// the same key with a fresh serial and a fresh validity window does not
// escape it.
deny_key_id :: proc(p: ^Pool, id: Key_ID) -> Error {
	ensure(p != nil, "certstore.deny_key_id: nil pool")
	ensure(p.initialized, "certstore.deny_key_id: pool is not initialized")

	_, _, _, err := map_entry(&p.denied_keys, id)
	if err != nil {
		return err
	}
	p.views_dirty = true
	return nil
}

// is_denied reports whether this certificate is on either deny list. It
// does not have to be a pool entry.
@(require_results)
is_denied :: proc(p: ^Pool, cert: ^x509.Certificate) -> bool {
	ensure(p != nil, "certstore.is_denied: nil pool")
	ensure(p.initialized, "certstore.is_denied: pool is not initialized")
	ensure(cert != nil, "certstore.is_denied: nil certificate")
	return _cert_denied(p, cert)
}

// _cert_denied is the check for a certificate that may or may not be a
// pool entry: both digests have to be computed.
@(private, require_results)
_cert_denied :: proc(p: ^Pool, cert: ^x509.Certificate) -> bool {
	if len(p.denied_certs) > 0 {
		if _, hit := p.denied_certs[_cert_id(cert.raw)]; hit {
			return true
		}
	}
	if len(p.denied_keys) > 0 {
		if _, hit := p.denied_keys[_key_id(cert.raw_spki)]; hit {
			return true
		}
	}
	return false
}

// _entry_denied is the same check for a pool entry, which already knows
// both of its digests. Called once per entry per view rebuild.
@(private, require_results)
_entry_denied :: proc(p: ^Pool, e: ^Entry) -> bool {
	if _, hit := p.denied_certs[e.id]; hit {
		return true
	}
	if _, hit := p.denied_keys[e.key_id]; hit {
		return true
	}
	return false
}

// _chain_denied scans a completed chain. This is the half of the deny
// enforcement that covers the leaf and the peer-supplied intermediates,
// which were never pool entries and so were never filtered out of the
// views.
//
// It is also why the per-candidate predicate once proposed for
// core:crypto/x509 would not have been sufficient on its own: that hook
// would fire on anchor and intermediate candidates, and the leaf is
// neither.
@(private, require_results)
_chain_denied :: proc(p: ^Pool, chain: []^x509.Certificate) -> bool {
	if len(p.denied_certs) == 0 && len(p.denied_keys) == 0 {
		return false
	}
	for c in chain {
		if _cert_denied(p, c) {
			return true
		}
	}
	return false
}
