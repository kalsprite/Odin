package certstore

import "core:bytes"
import "core:crypto/x509"

// _Screen selects what a candidate must prove before it is stored.
//
// It is a parameter of the single write path rather than a flag on the
// public adders, so that every relaxation of the anchor rules is a
// distinct procedure name at the call site.
@(private)
_Screen :: enum u8 {
	None = 0, // intermediates: verify_chain screens them per-candidate
	CA_Anchor, // add_anchor_*
	Self_Signed, // add_self_signed_anchor_*
}

// _screen_anchor decides whether a certificate may become a trust anchor.
//
// This is deliberately stricter than what verify_chain later requires of
// an anchor, and stricter than Go, which accepts anything into a
// CertPool. Go gets away with it because its darwin and windows paths
// hand the whole problem to the platform verifier; the Unix path here is
// a directory scan over whatever happens to be on disk, which is a
// different threat model.
//
// x509 checks exactly two things about an anchor -- no unhandled critical
// extension, and valid at the reference time -- and its reasoning is
// right: an anchor is trusted input, and re-deriving CA authority from
// something already decided to be trustworthy is theatre. But that shifts
// the question rather than answering it. Somebody has to decide whether
// this thing should have been trusted input, and x509 has explicitly
// declined to be that somebody.
//
// A rejection is not fatal to a bulk load: the certificate is skipped and
// counted in Load_Report.rejected, so the omission is visible.
@(private)
_screen_anchor :: proc(cert: ^x509.Certificate) -> Error {
	// RFC 5280 4.2.1.9 requires a CA certificate to assert
	// basicConstraints. Absent means "not a CA".
	if !cert.basic_constraints_valid {
		return Store_Error.Not_An_Anchor
	}
	if !cert.is_ca {
		return Store_Error.Not_An_Anchor
	}

	// If it bothers to declare KeyUsage, it must include keyCertSign.
	// Not declaring KeyUsage at all is unrestricted, per RFC 5280.
	if cert.has_key_usage && .Key_Cert_Sign not_in cert.key_usage {
		return Store_Error.Not_An_Anchor
	}

	return _screen_common(cert)
}

// _screen_self_signed_anchor is the door for a local development CA.
//
// It drops the CA requirements -- basicConstraints, is_ca, keyCertSign --
// and replaces them with proof that the certificate really is what it
// claims: its issuer Name equals its subject Name byte for byte, and its
// signature verifies under its own public key.
//
// That cryptographic check is the whole point. Without it this procedure
// would be a general bypass of _screen_anchor reachable by anyone who
// could get a certificate in front of it, which is exactly the
// /etc/pki/tls/certs/localhost.crt case the screen exists to stop. With
// it, the caller is asserting trust in a specific key they hold, which
// is what a development CA actually is.
//
// Note what is still enforced: an unhandled critical extension is a
// rejection here too. A certificate whose issuer stated a policy this
// package cannot read is one verify_chain would fail closed anyway.
@(private)
_screen_self_signed_anchor :: proc(cert: ^x509.Certificate) -> Error {
	if !bytes.equal(cert.raw_subject, cert.raw_issuer) {
		return Store_Error.Not_Self_Signed
	}
	// verify_signature returns .Unsupported_Algorithm for a key or digest
	// this build cannot check. That is reported as-is rather than folded
	// into .Not_Self_Signed: "I cannot check this" and "this is not
	// self-signed" are different answers and the caller can act on them
	// differently.
	#partial switch err := x509.verify_signature(cert, cert); err {
	case .None:
	case .Signature_Invalid:
		return Store_Error.Not_Self_Signed
	case:
		return err
	}

	return _screen_common(cert)
}

// _screen_common holds the checks every anchor must pass regardless of
// which door it came through.
@(private)
_screen_common :: proc(cert: ^x509.Certificate) -> Error {
	// A critical extension nobody here understands means the relying
	// party cannot honour the issuer's stated policy. verify_chain already
	// fails such a certificate closed at validation time; this declines to
	// store it as an anchor in the first place.
	if cert.unhandled_critical {
		return Store_Error.Not_An_Anchor
	}
	return nil
}

// _screen applies the selected screen.
//
// Intermediates are not screened at all. They go into the intermediate
// view, where x509 already applies the full RFC 5280 6.1.4 battery -- CA,
// keyCertSign, path length, validity, critical extensions -- to every
// candidate at verification time. Screening them at ingest would
// duplicate that check while making the pool refuse to hold a
// certificate it merely refuses to use, which is worse: a peer-supplied
// intermediate would then be silently absent rather than visibly
// rejected.
@(private)
_screen :: proc(cert: ^x509.Certificate, how: _Screen) -> Error {
	switch how {
	case .None:
		return nil
	case .CA_Anchor:
		return _screen_anchor(cert)
	case .Self_Signed:
		return _screen_self_signed_anchor(cert)
	}
	return nil
}
