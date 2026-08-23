package certstore

import "base:runtime"
import "core:crypto/x509"
import "core:mem/virtual"
import "core:slice"
import "core:time"

// Verify_Options is what this pool needs on top of what
// x509.Verify_Options already covers. The roots and intermediates are
// not among them: supplying those is the pool's entire job.
Verify_Options :: struct {
	// Reference time for every certificate's validity window.
	current_time: time.Time,

	// If non-empty, the leaf must present this name.
	dns_name:     string,

	// If set, the leaf and every intermediate must permit this purpose.
	// TLS clients pass .Server_Auth.
	required_eku: Maybe(x509.EKU_Bit),

	// Untrusted certificates the peer supplied, in the order they were
	// sent. NEVER treated as anchors, whatever they claim about
	// themselves.
	peer_chain:   []^x509.Certificate,

	// Optional final gate over the completed, otherwise-valid chain.
	// Return anything but .None to reject it. This is where a CRL check
	// or a pinning policy plugs in, and it is the analogue of Go's
	// CertPool constraint hook.
	constraint:   proc(chain: []^x509.Certificate) -> x509.Error,
}

// verify builds and validates a path from `leaf` to one of the pool's
// trust anchors.
//
// On success the returned chain is leaf-first: chain[0] == leaf and
// chain[len-1] is the anchor. It is allocated with `allocator` and the
// caller owns it; the certificates it points at are not owned by it.
//
// The peer's own certificates go into the intermediates and only there.
// A peer that ships a self-signed CA:TRUE certificate in its Certificate
// message must still chain to something this pool already trusted.
// Appending peer_chain to the anchors, under any condition, for any
// reason, is the one change to this package that would turn it from a
// trust store into a decoration.
@(require_results)
verify :: proc(
	p: ^Pool,
	leaf: ^x509.Certificate,
	opts: Verify_Options,
	allocator := context.allocator,
) -> (
	chain: []^x509.Certificate,
	err: Error,
) {
	ensure(p != nil, "certstore.verify: nil pool")
	ensure(p.initialized, "certstore.verify: pool is not initialized")
	ensure(leaf != nil, "certstore.verify: nil leaf")

	_refresh_views(p) or_return

	inters := make(
		[dynamic]^x509.Certificate,
		0,
		len(p.inter_view) + len(opts.peer_chain),
		allocator,
	) or_return
	defer delete(inters)

	append(&inters, ..p.inter_view[:]) or_return
	for c in opts.peer_chain {
		if c == leaf {
			continue
		}
		append(&inters, c) or_return
	}

	xopts := x509.Verify_Options {
		roots         = p.anchor_view[:],
		intermediates = inters[:],
		current_time  = opts.current_time,
		dns_name      = opts.dns_name,
		required_eku  = opts.required_eku,
	}

	built := x509.verify_chain(leaf, xopts, allocator) or_return

	// The second half of deny enforcement. Denied pool entries never
	// reached xopts at all, but the leaf and the peer's intermediates
	// were never pool entries, so this is the only place they are checked.
	if _chain_denied(p, built) {
		delete(built, allocator)
		return nil, Store_Error.Denied
	}

	if opts.constraint != nil {
		if cerr := opts.constraint(built); cerr != .None {
			delete(built, allocator)
			return nil, cerr
		}
	}

	return built, nil
}

// Verified_Chain owns the storage for the peer-supplied certificates in
// a chain, so the chain stays valid after verify_tls returns.
//
// Pool-held entries in `chain` are NOT owned here: they belong to the
// pool and outlive this.
Verified_Chain :: struct {
	chain:      []^x509.Certificate, // leaf first, anchor last
	_arena:     virtual.Arena,
	_allocator: runtime.Allocator,
}

// verify_tls is the TLS client entry point: parse the peer's Certificate
// message, then verify its leaf for `host` at `now` with .Server_Auth
// required.
//
// `peer_der` is the message as sent, leaf first. The peer's certificates
// are parsed into an arena owned by the returned Verified_Chain, NOT into
// the pool: they are untrusted input, they must not accumulate in a
// process-wide store, and an append-only pool has no way to evict them
// afterwards.
//
// On failure the returned Verified_Chain is zeroed and owns nothing;
// calling chain_destroy on it anyway is harmless.
//
// Release the result with chain_destroy.
@(require_results)
verify_tls :: proc(
	p: ^Pool,
	peer_der: [][]byte,
	host: string,
	now: time.Time,
	allocator := context.allocator,
) -> (
	vc: Verified_Chain,
	err: Error,
) {
	ensure(p != nil, "certstore.verify_tls: nil pool")
	ensure(p.initialized, "certstore.verify_tls: pool is not initialized")

	// The chain is built into a local and handed over only once it is
	// whole, and the cleanup is written out rather than deferred.
	//
	// The obvious shape -- build into the named result `vc` under a
	// `defer if !ok { chain_destroy(&vc) }` -- does not work: this
	// compiler copies the result values at the `return` and runs the
	// deferred statements afterwards, so a deferred write to a named
	// result never reaches the caller. That shape would free the arena
	// and still hand back a Verified_Chain pointing at it, and the
	// caller's own chain_destroy would then walk a freed memory block.
	built: Verified_Chain
	if err = _build_verified_chain(p, peer_der, host, now, allocator, &built); err != nil {
		chain_destroy(&built)
		return {}, err
	}
	return built, nil
}

// _build_verified_chain is the body of verify_tls, taking its result by
// pointer so that a partially built chain is visible to the cleanup
// above whichever step failed.
@(private)
_build_verified_chain :: proc(
	p: ^Pool,
	peer_der: [][]byte,
	host: string,
	now: time.Time,
	allocator: runtime.Allocator,
	vc: ^Verified_Chain,
) -> (
	err: Error,
) {
	if len(peer_der) == 0 {
		return x509.Error.Malformed
	}

	virtual.arena_init_growing(&vc._arena, 64 * 1024) or_return
	vc._allocator = allocator

	parena := virtual.arena_allocator(&vc._arena)
	peer := make([dynamic]^x509.Certificate, 0, len(peer_der), parena) or_return
	for der in peer_der {
		owned := slice.clone(der, parena) or_return
		c := x509.parse(owned, parena) or_return
		append(&peer, new_clone(c, parena) or_return) or_return
	}

	// Verified against p itself, so p's deny lists are the real ones. An
	// earlier revision built a scratch Pool here to hold the peer's
	// certificates; that scratch pool had its own empty deny maps, so a
	// distrusted peer certificate sailed straight through. There is now
	// exactly one pool in play.
	vc.chain = verify(
		p,
		peer[0],
		Verify_Options {
			current_time = now,
			dns_name = host,
			required_eku = x509.EKU_Bit.Server_Auth,
			peer_chain = peer[:],
		},
		allocator,
	) or_return

	return nil
}

// chain_destroy releases a Verified_Chain.
//
// Idempotent, and a no-op on a zeroed value, which is what verify_tls
// returns when it fails. What it cannot survive is being called twice on
// two COPIES of the same chain: the second call would walk the memory
// block the first one freed. Verified_Chain owns an arena; treat it as a
// handle with one owner.
chain_destroy :: proc(vc: ^Verified_Chain) {
	if vc == nil {
		return
	}
	delete(vc.chain, vc._allocator)
	virtual.arena_destroy(&vc._arena)
	vc^ = {}
}

// _refresh_views rebuilds the two slices handed to x509.verify_chain.
//
// This is where a deny is applied to the pool's own contents, which is
// what makes it retroactive: a certificate added before the deny arrived
// is still excluded from every verification afterwards.
//
// `clear` keeps capacity, so a steady-state rebuild does not allocate.
@(private)
_refresh_views :: proc(p: ^Pool) -> Error {
	if !p.views_dirty {
		return nil
	}

	clear(&p.anchor_view)
	clear(&p.inter_view)

	for e in p.entries {
		if _entry_denied(p, e) {
			continue
		}
		dst := &p.inter_view if e.trust == .Intermediate else &p.anchor_view
		append(dst, e.cert) or_return
	}

	p.views_dirty = false
	return nil
}
