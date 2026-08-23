#+build darwin
package certstore

import CF "core:sys/darwin/CoreFoundation"
import SEC "core:sys/darwin/Security"

// SYSTEM_STORE_SUPPORTED reports whether load_system_roots and
// load_system_personal can do anything on this platform. Test it with
// `when`, not with a runtime branch.
SYSTEM_STORE_SUPPORTED :: true

// The three trust settings domains, least specific first.
//
// Order does not decide anything here, and that is deliberate. macOS
// lets each domain hold an opinion about the same certificate, and this
// package resolves a disagreement the way Go does: a Deny anywhere wins
// over a trust anywhere. That falls out for free, because a deny is
// evaluated when the anchor view is built, so it applies to a
// certificate that was already stored as an anchor by an earlier domain.
@(rodata, private)
_DOMAINS := []SEC.TrustSettingsDomain{.System, .Admin, .User}

// load_system_roots fills the pool from the macOS trust settings.
//
// Each of the three domains is asked for the certificates it has an
// opinion about, and each of those certificates is asked what that
// opinion is. `kSecTrustSettingsResult` is the user trust metric this
// package set out to honour, and it maps onto both halves of the store:
// TrustRoot / TrustAsRoot become anchors, Deny goes on the deny list.
load_system_roots :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_roots: nil pool")
	ensure(p.initialized, "certstore.load_system_roots: pool is not initialized")

	r.source = "SecTrustSettings"
	any_domain := false

	for domain in _DOMAINS {
		certs: CF.Array
		status := SEC.TrustSettingsCopyCertificates(domain, &certs)
		// This domain has no trust settings at all. Not an error, and
		// `certs` was not written.
		if status == .NoTrustSettings || status == .ItemNotFound {
			continue
		}
		if status != .Success {
			return r, Store_Error.System_Store_Failed
		}
		defer CF.Release(certs)
		any_domain = true

		n := CF.ArrayGetCount(certs)
		for i in 0 ..< n {
			cert := SEC.CertificateRef(CF.ArrayGetValueAtIndex(certs, i))
			if cert == nil {
				continue
			}
			_load_trust_setting(p, cert, domain, &r) or_return
		}
	}

	if !any_domain {
		return r, Store_Error.No_System_Store
	}
	p.from_system = true
	return r, nil
}

// load_system_personal loads the login keychain, for its CERTIFICATES
// only.
//
// The query asks for `kSecClassCertificate` rather than
// `kSecClassIdentity`: an identity is a certificate paired with its
// private key, and this package never reads, stores or exposes private
// key material. Everything found is stored as chain-building material,
// never as an anchor -- a certificate sitting in a user's keychain has
// said nothing about being trusted to issue anything.
load_system_personal :: proc(p: ^Pool) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.load_system_personal: nil pool")
	ensure(p.initialized, "certstore.load_system_personal: pool is not initialized")

	r.source = "keychain"

	keys := [?]rawptr{rawptr(SEC.kSecClass), rawptr(SEC.kSecMatchLimit), rawptr(SEC.kSecReturnRef)}
	values := [?]rawptr {
		rawptr(SEC.kSecClassCertificate),
		rawptr(SEC.kSecMatchLimitAll),
		rawptr(CF.kCFBooleanTrue),
	}

	query := CF.DictionaryCreate(
		nil,
		&keys[0],
		&values[0],
		len(keys),
		&CF.kCFTypeDictionaryKeyCallBacks,
		&CF.kCFTypeDictionaryValueCallBacks,
	)
	if query == nil {
		return r, Store_Error.System_Store_Failed
	}
	defer CF.Release(query)

	found: CF.TypeRef
	status := SEC.ItemCopyMatching(query, &found)
	if status == .ItemNotFound {
		return r, Store_Error.No_System_Store
	}
	if status != .Success {
		return r, Store_Error.System_Store_Failed
	}
	defer CF.Release(found)

	// kSecMatchLimitAll makes the result an array. Check rather than
	// assume: a single-object result released as an array would be a
	// type confusion at the CF layer.
	if CF.GetTypeID(found) != CF.ArrayGetTypeID() {
		return r, Store_Error.System_Store_Failed
	}
	certs := CF.Array(found)

	n := CF.ArrayGetCount(certs)
	for i in 0 ..< n {
		cert := SEC.CertificateRef(CF.ArrayGetValueAtIndex(certs, i))
		if cert == nil {
			continue
		}
		_add_sec_certificate(p, cert, .Intermediate, .System_Personal, .None, &r) or_return
	}

	p.from_system = true
	return r, nil
}

// _load_trust_setting reads one certificate's verdict in one domain and
// acts on it.
@(private)
_load_trust_setting :: proc(
	p: ^Pool,
	cert: SEC.CertificateRef,
	domain: SEC.TrustSettingsDomain,
	r: ^Load_Report,
) -> Error {
	settings: CF.Array
	status := SEC.TrustSettingsCopyTrustSettings(cert, domain, &settings)
	// This domain listed the certificate but holds no settings for it.
	// Nothing to honour, and `settings` was not written.
	if status == .ItemNotFound || status == .NoTrustSettings {
		return nil
	}
	if status != .Success {
		return Store_Error.System_Store_Failed
	}
	defer CF.Release(settings)

	switch _evaluate(settings) {
	case .Trust:
		return _add_sec_certificate(p, cert, .Anchor, .System_Root, .CA_Anchor, r)
	case .Deny:
		return _deny_sec_certificate(p, cert, r)
	case .No_Opinion:
		return nil
	}
	return nil
}

// _Verdict is what this package could make of a certificate's trust
// settings, as opposed to the raw kSecTrustSettingsResult, which it may
// hold several of.
@(private)
_Verdict :: enum u8 {
	No_Opinion = 0,
	Trust,
	Deny,
}

// _evaluate reduces a trust settings array to one verdict.
//
// A Deny anywhere in the array wins, unconditionally: fail closed on the
// one answer where being wrong grants trust.
//
// A trust verdict, by contrast, has to survive every constraint in its
// entry. An entry carrying a constraint this package cannot evaluate
// grants nothing, because honouring a restricted grant as an unrestricted
// one is exactly the mistake that matters here.
@(private)
_evaluate :: proc(settings: CF.Array) -> _Verdict {
	n := CF.ArrayGetCount(settings)

	// An EMPTY array is meaningful and is not the same as no array: per
	// Apple's own documentation it means "always trust this certificate,
	// with a resulting kSecTrustSettingsResult of
	// kSecTrustSettingsResultTrustRoot". It is the default for the root
	// set macOS ships.
	if n == 0 {
		return .Trust
	}

	verdict := _Verdict.No_Opinion
	for i in 0 ..< n {
		dict := CF.Dictionary(CF.ArrayGetValueAtIndex(settings, i))
		if dict == nil {
			continue
		}

		// An entry with no kSecTrustSettingsResult key means TrustRoot.
		result := SEC.TrustSettingsResult.TrustRoot
		if v := CF.DictionaryGetValue(dict, rawptr(SEC.kSecTrustSettingsResult)); v != nil {
			num, ok := CF.NumberAsI64(CF.Number(v))
			if !ok {
				continue
			}
			result = SEC.TrustSettingsResult(num)
		}

		#partial switch result {
		case .Deny:
			return .Deny
		case .TrustRoot, .TrustAsRoot:
			if _entry_applies(dict) {
				verdict = .Trust
			}
		case:
		// .Unspecified defers to another domain; .Invalid is not a
		// verdict at all.
		}
	}
	return verdict
}

// _entry_applies reports whether a trust settings entry grants trust for
// TLS server verification, unconditionally enough for this package to
// act on it.
@(private)
_entry_applies :: proc(dict: CF.Dictionary) -> bool {
	// A policy restricts the entry to one purpose. Absent means every
	// purpose; present means it has to be the SSL policy. This is the
	// same test Go makes.
	if pv := CF.DictionaryGetValue(dict, rawptr(SEC.kSecTrustSettingsPolicy)); pv != nil {
		props := SEC.PolicyCopyProperties(SEC.PolicyRef(pv))
		if props == nil {
			return false
		}
		defer CF.Release(props)

		oid := CF.DictionaryGetValue(props, rawptr(SEC.kSecPolicyOid))
		if oid == nil {
			return false
		}
		if !CF.Equal(CF.TypeRef(oid), CF.TypeRef(SEC.kSecPolicyAppleSSL)) {
			return false
		}
	}

	// An application constraint restricts the entry to one binary, and a
	// policy string restricts it to one hostname. Neither is something
	// this package can evaluate at load time, and neither can be ignored
	// safely: ignoring them would widen the grant.
	if CF.DictionaryContainsKey(dict, rawptr(SEC.kSecTrustSettingsApplication)) {
		return false
	}
	if CF.DictionaryContainsKey(dict, rawptr(SEC.kSecTrustSettingsPolicyString)) {
		return false
	}

	// A key usage constraint IS evaluable, and for an anchor the question
	// is only whether it may sign certificates.
	if kv := CF.DictionaryGetValue(dict, rawptr(SEC.kSecTrustSettingsKeyUsage)); kv != nil {
		num, ok := CF.NumberAsI64(CF.Number(kv))
		if !ok {
			return false
		}
		usage := SEC.TrustSettingsKeyUsage(u32(num))
		if usage != SEC.TRUST_SETTINGS_KEY_USE_ANY &&
		   usage & SEC.TRUST_SETTINGS_KEY_USE_SIGN_CERT == 0 {
			return false
		}
	}

	// kSecTrustSettingsAllowedError and kSecTrustSettingsPolicyName are
	// deliberately not consulted. AllowedError only ever tells the
	// evaluator to overlook a failure, so declining to honour it can make
	// this package stricter but never laxer; PolicyName duplicates, in
	// display form, what the policy OID above already decided.
	return true
}

// _add_sec_certificate copies one SecCertificateRef's DER into the pool.
@(private)
_add_sec_certificate :: proc(
	p: ^Pool,
	cert: SEC.CertificateRef,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
	r: ^Load_Report,
) -> Error {
	data := SEC.CertificateCopyData(cert)
	if data == nil {
		r.seen += 1
		r.unparsable += 1
		return nil
	}
	// _add clones the bytes into the arena before it returns, so the
	// certificate outlives the CFData we are about to release.
	defer CF.Release(data)

	der := CF.DataAsSlice(data)
	if len(der) == 0 {
		r.seen += 1
		r.unparsable += 1
		return nil
	}

	r.seen += 1
	_, added, aerr := _add(p, der, trust, origin, screen)
	return _bucket(r, added, aerr)
}

@(private)
_deny_sec_certificate :: proc(p: ^Pool, cert: SEC.CertificateRef, r: ^Load_Report) -> Error {
	data := SEC.CertificateCopyData(cert)
	if data == nil {
		return nil
	}
	defer CF.Release(data)

	der := CF.DataAsSlice(data)
	if len(der) == 0 {
		return nil
	}

	r.seen += 1
	r.denied += 1
	return deny_cert(p, der)
}
