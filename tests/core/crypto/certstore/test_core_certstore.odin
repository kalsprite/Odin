package test_core_certstore

// Fixtures are shared with the x509 tests rather than duplicated; see
// tests/core/crypto/x509/testdata/gen_chains.sh for how they are made.
//
//	P-256:    chain_ec_root -> chain_ec_inter (pathlen:0) -> chain_ec_leaf
//	          (CN=leaf.example.com, EKU serverAuth); chain_ec_other_root
//	          is an unrelated anchor.
//	Ed25519:  chain_ed_root -> chain_ed_leaf.
//	ec.der:   self-signed, CA:FALSE, CN=example.com. This is the shape of
//	          the localhost.crt that anchor screening exists to refuse,
//	          and equally the shape of a local development CA.

import "core:crypto/certstore"
import "core:crypto/x509"
import "core:encoding/pem"
import "core:log"
import "core:slice"
import "core:testing"
import "core:time"

EC_ROOT := #load("../x509/testdata/chain_ec_root.der")
EC_INTER := #load("../x509/testdata/chain_ec_inter.der")
EC_LEAF := #load("../x509/testdata/chain_ec_leaf.der")
EC_OTHER_ROOT := #load("../x509/testdata/chain_ec_other_root.der")
ED_ROOT := #load("../x509/testdata/chain_ed_root.der")
SELF_SIGNED_EE := #load("../x509/testdata/ec.der")
// A root whose own validity window ran out in 2015, and a leaf it signed
// that is still valid.
EC_EXPIRED_ROOT := #load("../x509/testdata/chain_ec_expired_root.der")
EC_EXP_LEAF := #load("../x509/testdata/chain_ec_expleaf.der")

// 2027-01-01Z: inside every fixture's validity window.
CHAIN_NOW :: i64(1798761600)

@(private = "file")
_now :: proc() -> time.Time {
	return time.unix(CHAIN_NOW, 0)
}

// _x and _s lift a bare variant into certstore.Error, so that
// expect_value's two arguments have the one type it infers.
@(private = "file")
_x :: proc(e: x509.Error) -> certstore.Error {
	return e
}

@(private = "file")
_s :: proc(e: certstore.Store_Error) -> certstore.Error {
	return e
}

// _init is the preamble every test shares. Pair it with a
// `defer certstore.destroy(&p)` placed BEFORE the call: destroy is a
// no-op on a pool that was never initialised, which is what makes that
// ordering correct.
@(private = "file")
_init :: proc(t: ^testing.T, p: ^certstore.Pool) -> bool {
	err := certstore.init(p, context.allocator)
	testing.expect_value(t, err, nil)
	return err == nil
}

@(test)
test_lifecycle :: proc(t: ^testing.T) {
	p: certstore.Pool
	if !_init(t, &p) {
		return
	}

	testing.expect_value(t, certstore.count(&p), 0)
	testing.expect_value(t, certstore.anchor_count(&p), 0)
	testing.expect(t, !certstore.from_system_store(&p), "a fresh pool is not from the system")

	certstore.destroy(&p)
	// Idempotent, and safe on a pool that was never initialised. Both
	// matter: `defer destroy` sits above an init that can fail.
	certstore.destroy(&p)

	never_initialised: certstore.Pool
	certstore.destroy(&never_initialised)
}

@(test)
test_anchor_screening :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	// A proper CA root is an anchor.
	_, added, err := certstore.add_anchor_der(&p, EC_ROOT)
	testing.expect_value(t, err, nil)
	testing.expect(t, added, "the CA root was stored")
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// A self-signed end-entity certificate -- CA:FALSE, no authority to
	// issue anything -- is not. This is the /etc/pki/tls/certs/localhost.crt
	// case, which Go's CertPool accepts.
	_, ee_added, ee_err := certstore.add_anchor_der(&p, SELF_SIGNED_EE)
	testing.expect_value(t, ee_err, _s(.Not_An_Anchor))
	testing.expect(t, !ee_added, "the end-entity certificate was refused")
	testing.expect_value(t, certstore.count(&p), 1)

	// The same certificate is perfectly good chain-building material,
	// though: intermediates are screened per-candidate at verification
	// time, not at ingest.
	_, i_added, i_err := certstore.add_intermediate_der(&p, SELF_SIGNED_EE)
	testing.expect_value(t, i_err, nil)
	testing.expect(t, i_added, "the end-entity certificate was stored as an intermediate")
	testing.expect_value(t, certstore.count(&p), 2)
	testing.expect_value(t, certstore.anchor_count(&p), 1)
}

@(test)
test_self_signed_anchor :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	// The local development CA case: a self-signed certificate that never
	// claimed to be a CA, admitted through the explicit door.
	_, added, err := certstore.add_self_signed_anchor_der(&p, SELF_SIGNED_EE)
	testing.expect_value(t, err, nil)
	testing.expect(t, added, "the self-signed certificate was anchored")
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// Not self-signed: the EC leaf was issued by the intermediate. The
	// door does not open just because someone knocked on it.
	_, l_added, l_err := certstore.add_self_signed_anchor_der(&p, EC_LEAF)
	testing.expect_value(t, l_err, _s(.Not_Self_Signed))
	testing.expect(t, !l_added, "a leaf is not a self-signed anchor")
	testing.expect_value(t, certstore.count(&p), 1)
}

@(test)
test_self_signed_anchor_checks_the_signature :: proc(t: ^testing.T) {
	// The property that makes add_self_signed_anchor_* something other
	// than a bypass of anchor screening: the self-signature is verified,
	// not merely asserted by the subject and issuer names matching.
	//
	// ED_ROOT's signature is a bare 64-byte Ed25519 value at the end of
	// the DER, so flipping its last byte breaks the signature while
	// leaving a structurally valid certificate that still names itself as
	// its own issuer.
	forged := slice.clone(ED_ROOT)
	defer delete(forged)
	forged[len(forged) - 1] ~= 0x01

	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	cert, perr := x509.parse(forged)
	defer x509.destroy(&cert)
	testing.expect_value(t, perr, x509.Error.None)
	testing.expect(
		t,
		slice.equal(cert.raw_subject, cert.raw_issuer),
		"the forgery still names itself as its own issuer",
	)

	_, added, err := certstore.add_self_signed_anchor_der(&p, forged)
	testing.expect_value(t, err, _s(.Not_Self_Signed))
	testing.expect(t, !added, "a broken self-signature is not an anchor")
	testing.expect_value(t, certstore.count(&p), 0)

	// The unmodified certificate goes in, so the test above failed on the
	// forgery and not on something incidental to the fixture.
	_, ok_added, ok_err := certstore.add_self_signed_anchor_der(&p, ED_ROOT)
	testing.expect_value(t, ok_err, nil)
	testing.expect(t, ok_added, "the intact Ed25519 root is a self-signed anchor")
}

@(test)
test_dedup_and_promotion :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	i0, a0, e0 := certstore.add_intermediate_der(&p, EC_ROOT)
	testing.expect_value(t, e0, nil)
	testing.expect(t, a0, "the first add stores")

	// The same bytes again: reported as already present, not as an error,
	// and not stored twice.
	i1, a1, e1 := certstore.add_intermediate_der(&p, EC_ROOT)
	testing.expect_value(t, e1, nil)
	testing.expect(t, !a1, "the second add is a duplicate")
	testing.expect_value(t, i1, i0)
	testing.expect_value(t, certstore.count(&p), 1)

	// Promotion: asking for an anchor when the pool holds the certificate
	// as an intermediate grants the trust, rather than silently declining
	// to.
	testing.expect_value(t, certstore.anchor_count(&p), 0)
	i2, a2, e2 := certstore.add_anchor_der(&p, EC_ROOT)
	testing.expect_value(t, e2, nil)
	testing.expect(t, !a2, "a promotion is not a new entry")
	testing.expect_value(t, i2, i0)
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// Demotion never happens: a later add does not take trust away.
	certstore.add_intermediate_der(&p, EC_ROOT)
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// A promotion still has to pass the screen it would have faced on the
	// way in.
	certstore.add_intermediate_der(&p, SELF_SIGNED_EE)
	_, _, e3 := certstore.add_anchor_der(&p, SELF_SIGNED_EE)
	testing.expect_value(t, e3, _s(.Not_An_Anchor))
	testing.expect_value(t, certstore.anchor_count(&p), 1)
}

@(test)
test_contains_and_find_by_subject :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	_, ok0 := certstore.contains(&p, EC_ROOT)
	testing.expect(t, !ok0, "an empty pool contains nothing")

	idx, _, err := certstore.add_anchor_der(&p, EC_ROOT)
	testing.expect_value(t, err, nil)

	found, ok1 := certstore.contains(&p, EC_ROOT)
	testing.expect(t, ok1, "the stored certificate is found")
	testing.expect_value(t, found, idx)

	e := certstore.entry(&p, idx)
	testing.expect(t, e != nil, "entry(idx) is the stored entry")
	testing.expect(t, certstore.entry(&p, 99) == nil, "entry out of range is nil")
	testing.expect(t, certstore.entry(&p, -1) == nil, "entry below range is nil")
	if e == nil {
		return
	}

	// The intermediate names the root as its issuer, so looking that
	// issuer Name up finds the root.
	inter, perr := x509.parse(EC_INTER)
	defer x509.destroy(&inter)
	testing.expect_value(t, perr, x509.Error.None)

	hits := make([dynamic]^certstore.Entry)
	defer delete(hits)
	testing.expect_value(t, certstore.find_by_subject(&p, inter.raw_issuer, &hits), nil)
	testing.expect_value(t, len(hits), 1)
	if len(hits) == 1 {
		testing.expect(t, hits[0] == e, "the root is the issuer of the intermediate")
	}

	// Nothing in the pool has the intermediate's own subject.
	clear(&hits)
	testing.expect_value(t, certstore.find_by_subject(&p, inter.raw_subject, &hits), nil)
	testing.expect_value(t, len(hits), 0)
}

@(test)
test_verify :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)

	leaf, perr := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)
	testing.expect_value(t, perr, x509.Error.None)

	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options {
			current_time = _now(),
			dns_name = "leaf.example.com",
			required_eku = x509.EKU_Bit.Server_Auth,
		},
	)
	defer delete(chain)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(chain), 3)
	if len(chain) == 3 {
		testing.expect(t, chain[0] == &leaf, "chain[0] is the leaf")
	}
}

@(test)
test_verify_peer_intermediate :: proc(t: ^testing.T) {
	// The topology the whole web runs on: the pool holds only the root,
	// and the peer supplies the intermediate. An implementation that
	// gathers candidates from the pool alone fails every real handshake.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)
	inter, _ := x509.parse(EC_INTER)
	defer x509.destroy(&inter)

	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options {
			current_time = _now(),
			dns_name = "leaf.example.com",
			peer_chain = {&leaf, &inter},
		},
	)
	defer delete(chain)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(chain), 3)
}

@(test)
test_peer_chain_is_never_an_anchor :: proc(t: ^testing.T) {
	// A peer that ships its own self-signed CA:TRUE root must still chain
	// to something the pool already trusted.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	// The pool trusts an unrelated root, so it is not simply empty.
	certstore.add_anchor_der(&p, EC_OTHER_ROOT)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)
	inter, _ := x509.parse(EC_INTER)
	defer x509.destroy(&inter)
	root, _ := x509.parse(EC_ROOT)
	defer x509.destroy(&root)

	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options {
			current_time = _now(),
			dns_name = "leaf.example.com",
			peer_chain = {&leaf, &inter, &root},
		},
	)
	delete(chain)
	testing.expect_value(t, err, _x(.Unknown_Authority))
}

@(test)
test_deny_is_retroactive :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)

	opts := certstore.Verify_Options {
		current_time = _now(),
		dns_name     = "leaf.example.com",
	}

	chain, err := certstore.verify(&p, &leaf, opts)
	delete(chain)
	testing.expect_value(t, err, nil)

	// The deny arrives after the certificate did, and still takes effect:
	// it is applied when the anchor view is rebuilt.
	testing.expect_value(t, certstore.deny_cert(&p, EC_ROOT), nil)

	chain2, err2 := certstore.verify(&p, &leaf, opts)
	delete(chain2)
	testing.expect_value(t, err2, _x(.Unknown_Authority))
}

@(test)
test_deny_by_key :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)

	root, _ := x509.parse(EC_ROOT)
	defer x509.destroy(&root)
	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)

	testing.expect_value(t, certstore.deny_key_id(&p, certstore.key_id(&root)), nil)
	testing.expect(t, certstore.is_denied(&p, &root), "the root's key is denied")

	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options{current_time = _now(), dns_name = "leaf.example.com"},
	)
	delete(chain)
	testing.expect_value(t, err, _x(.Unknown_Authority))
}

@(test)
test_deny_reaches_the_leaf :: proc(t: ^testing.T) {
	// The leaf was never a pool entry, so filtering the views cannot
	// touch it. Only the scan over the completed chain can.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)
	testing.expect_value(t, certstore.deny_cert(&p, EC_LEAF), nil)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)

	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options{current_time = _now(), dns_name = "leaf.example.com"},
	)
	delete(chain)
	testing.expect_value(t, err, _s(.Denied))
}

@(test)
test_deny_before_add :: proc(t: ^testing.T) {
	// A deny recorded first refuses the certificate at the door, so a
	// later bulk load cannot smuggle it back in.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	testing.expect_value(t, certstore.deny_cert(&p, EC_ROOT), nil)
	_, added, err := certstore.add_anchor_der(&p, EC_ROOT)
	testing.expect_value(t, err, _s(.Denied))
	testing.expect(t, !added, "a denied certificate is not stored")
	testing.expect_value(t, certstore.count(&p), 0)
}

@(test)
test_verify_tls :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)

	// The TLS Certificate message as sent: the leaf first, then the
	// intermediate the server was configured with.
	peer := [][]byte{EC_LEAF, EC_INTER}

	vc, err := certstore.verify_tls(&p, peer, "leaf.example.com", _now())
	defer certstore.chain_destroy(&vc)
	testing.expect_value(t, err, nil)
	testing.expect_value(t, len(vc.chain), 3)

	// The wrong name fails, and it fails on the name.
	vc2, err2 := certstore.verify_tls(&p, peer, "wrong.example.com", _now())
	certstore.chain_destroy(&vc2)
	testing.expect_value(t, err2, _x(.Hostname_Mismatch))
}

@(test)
test_add_anchors_pem :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	// A two-certificate bundle, one of which anchor screening refuses.
	// The refusal is counted, not fatal: one bad certificate in
	// /etc/ssl/certs must not cost the machine its whole root set.
	root_pem := pem.encode(pem.LABEL_CERTIFICATE, EC_ROOT)
	defer delete(root_pem)
	ee_pem := pem.encode(pem.LABEL_CERTIFICATE, SELF_SIGNED_EE)
	defer delete(ee_pem)

	bundle := make([dynamic]byte)
	defer delete(bundle)
	append(&bundle, ..root_pem)
	append(&bundle, '\n')
	append(&bundle, ..ee_pem)

	r, err := certstore.add_anchors_pem(&p, bundle[:])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, r.seen, 2)
	testing.expect_value(t, r.added, 1)
	testing.expect_value(t, r.rejected, 1)
	testing.expect_value(t, r.added + r.duplicate + r.rejected + r.unparsable + r.denied, r.seen)
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// The same bundle read as intermediates: no screening, both stored,
	// and the root is recognised as the duplicate it is.
	r2, err2 := certstore.add_intermediates_pem(&p, bundle[:])
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, r2.added, 1)
	testing.expect_value(t, r2.duplicate, 1)

	// Bytes that are neither DER nor PEM.
	junk := transmute([]byte)string("this is not a certificate\n")
	_, jerr := certstore.add_anchors_pem(&p, junk)
	testing.expect_value(t, jerr, _s(.Bad_PEM))
}

@(test)
test_system_roots :: proc(t: ^testing.T) {
	when !certstore.SYSTEM_STORE_SUPPORTED {
		log.info("no system certificate store on this platform")
	} else {
		p: certstore.Pool
		defer certstore.destroy(&p)
		if !_init(t, &p) {
			return
		}

		r, err := certstore.load_system_roots(&p)
		if serr, is_store := err.(certstore.Store_Error); is_store && serr == .No_System_Store {
			log.info("this machine has no system certificate store")
			return
		}
		testing.expect_value(t, err, nil)
		testing.expect(t, r.added > 0, "the system store yielded at least one anchor")
		testing.expect(t, certstore.from_system_store(&p), "the pool is marked as from-system")
		testing.expect_value(
			t,
			r.added + r.duplicate + r.rejected + r.unparsable + r.denied,
			r.seen,
		)
		log.infof(
			"%s: seen=%d added=%d duplicate=%d rejected=%d unparsable=%d denied=%d",
			r.source,
			r.seen,
			r.added,
			r.duplicate,
			r.rejected,
			r.unparsable,
			r.denied,
		)

		// Every anchor the pool would actually offer survived screening.
		as, aerr := certstore.anchors(&p)
		testing.expect_value(t, aerr, nil)
		testing.expect(t, len(as) > 0, "the anchor view is non-empty")
		for c in as {
			testing.expect(t, c.basic_constraints_valid && c.is_ca, "every anchor is a CA")
			testing.expect(
				t,
				!c.unhandled_critical,
				"no anchor carries an uninterpreted critical extension",
			)
		}
	}
}

// ---- file adders -----------------------------------------------------
//
// ODIN_ROOT is a compile-time constant with a trailing separator, so the
// fixtures the rest of this file #loads can also be reached by path
// without the test needing to know its own working directory.

TESTDATA :: ODIN_ROOT + "tests/core/crypto/x509/testdata/"

@(test)
test_add_anchor_file :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	// A bare DER file, recognised by its leading 0x30 rather than by its
	// extension.
	r, err := certstore.add_anchor_file(&p, TESTDATA + "chain_ec_root.der")
	testing.expect_value(t, err, nil)
	testing.expect_value(t, r.seen, 1)
	testing.expect_value(t, r.added, 1)
	testing.expect_value(t, r.source, TESTDATA + "chain_ec_root.der")
	testing.expect_value(t, certstore.anchor_count(&p), 1)

	// Screening applies on this path too.
	r2, err2 := certstore.add_anchor_file(&p, TESTDATA + "ec.der")
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, r2.rejected, 1)
	testing.expect_value(t, r2.added, 0)

	// And the same file through the explicit door is accepted.
	r3, err3 := certstore.add_self_signed_anchor_file(&p, TESTDATA + "ec.der")
	testing.expect_value(t, err3, nil)
	testing.expect_value(t, r3.added, 1)
	testing.expect_value(t, certstore.anchor_count(&p), 2)

	// A path that is not there is an error rather than an empty report:
	// a caller who named a file deserves to be told it was not read.
	_, nerr := certstore.add_anchor_file(&p, TESTDATA + "does_not_exist.der")
	testing.expect_value(t, nerr, _s(.Path_Error))
}

// ---- verification options --------------------------------------------

@(test)
test_required_eku :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)

	// The leaf carries serverAuth only.
	chain, err := certstore.verify(
		&p,
		&leaf,
		certstore.Verify_Options {
			current_time = _now(),
			dns_name = "leaf.example.com",
			required_eku = x509.EKU_Bit.Client_Auth,
		},
	)
	delete(chain)
	testing.expect_value(t, err, _x(.Incompatible_Usage))
}

@(private = "file")
_reject_everything :: proc(chain: []^x509.Certificate) -> x509.Error {
	return .Unknown_Authority if len(chain) > 0 else .None
}

@(private = "file")
_accept :: proc(chain: []^x509.Certificate) -> x509.Error {
	return .None
}

@(test)
test_constraint_hook :: proc(t: ^testing.T) {
	// The hook a CRL check or a pinning policy plugs into. A rejection
	// here has to free the chain it was handed, which the test runner's
	// allocator tracking is what actually checks.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)

	leaf, _ := x509.parse(EC_LEAF)
	defer x509.destroy(&leaf)

	opts := certstore.Verify_Options {
		current_time = _now(),
		dns_name     = "leaf.example.com",
		constraint   = _reject_everything,
	}
	chain, err := certstore.verify(&p, &leaf, opts)
	delete(chain)
	testing.expect_value(t, err, _x(.Unknown_Authority))

	opts.constraint = _accept
	chain2, err2 := certstore.verify(&p, &leaf, opts)
	defer delete(chain2)
	testing.expect_value(t, err2, nil)
	testing.expect_value(t, len(chain2), 3)
}

@(test)
test_views :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	certstore.add_intermediate_der(&p, EC_INTER)
	certstore.add_intermediate_der(&p, EC_LEAF)

	as, aerr := certstore.anchors(&p)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, len(as), 1)

	is, ierr := certstore.intermediates(&p)
	testing.expect_value(t, ierr, nil)
	testing.expect_value(t, len(is), 2)

	// A deny removes an entry from the view without removing it from the
	// pool: count is unchanged, the view shrinks.
	testing.expect_value(t, certstore.deny_cert(&p, EC_LEAF), nil)
	is2, ierr2 := certstore.intermediates(&p)
	testing.expect_value(t, ierr2, nil)
	testing.expect_value(t, len(is2), 1)
	testing.expect_value(t, certstore.count(&p), 3)
}

@(test)
test_deny_cert_id :: proc(t: ^testing.T) {
	// Denying by identifier, for a caller holding a pin rather than the
	// certificate itself.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	certstore.add_anchor_der(&p, EC_ROOT)
	testing.expect_value(t, certstore.deny_cert_id(&p, certstore.cert_id(EC_ROOT)), nil)

	as, aerr := certstore.anchors(&p)
	testing.expect_value(t, aerr, nil)
	testing.expect_value(t, len(as), 0)
	testing.expect_value(t, certstore.anchor_count(&p), 1) // still stored
}

@(test)
test_expired_anchor_stores_but_does_not_verify :: proc(t: ^testing.T) {
	// Two separate questions, deliberately answered in two places.
	// Screening asks whether a certificate is the KIND of thing that may
	// be an anchor, and says nothing about time; x509 validates the
	// anchor's own validity window during the search, matching Go and
	// OpenSSL. So an expired root goes into the pool and then fails to
	// terminate a chain.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	_, added, err := certstore.add_anchor_der(&p, EC_EXPIRED_ROOT)
	testing.expect_value(t, err, nil)
	testing.expect(t, added, "an expired CA is still a CA")

	leaf, _ := x509.parse(EC_EXP_LEAF)
	defer x509.destroy(&leaf)

	chain, verr := certstore.verify(&p, &leaf, certstore.Verify_Options{current_time = _now()})
	delete(chain)
	testing.expect_value(t, verr, _x(.Unknown_Authority))
}

@(test)
test_verify_tls_empty_peer :: proc(t: ^testing.T) {
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}
	certstore.add_anchor_der(&p, EC_ROOT)

	vc, err := certstore.verify_tls(&p, nil, "leaf.example.com", _now())
	certstore.chain_destroy(&vc)
	testing.expect_value(t, err, _x(.Malformed))
	testing.expect_value(t, len(vc.chain), 0)
}

@(test)
test_pem_bundle_skips_other_blocks :: proc(t: ^testing.T) {
	// A real bundle carries more than certificates. Anything that is not
	// a CERTIFICATE block is skipped without being counted, because it
	// was never a candidate.
	p: certstore.Pool
	defer certstore.destroy(&p)
	if !_init(t, &p) {
		return
	}

	key_pem := pem.encode(pem.LABEL_PRIVATE_KEY, []byte{0x01, 0x02, 0x03, 0x04})
	defer delete(key_pem)
	root_pem := pem.encode(pem.LABEL_CERTIFICATE, EC_ROOT)
	defer delete(root_pem)

	bundle := make([dynamic]byte)
	defer delete(bundle)
	append(&bundle, ..key_pem)
	append(&bundle, '\n')
	append(&bundle, ..root_pem)

	r, err := certstore.add_anchors_pem(&p, bundle[:])
	testing.expect_value(t, err, nil)
	testing.expect_value(t, r.seen, 1)
	testing.expect_value(t, r.added, 1)
}
