package certstore

import "base:runtime"
import "core:crypto/x509"
import "core:encoding/pem"
import "core:mem/virtual"
import "core:os"
import "core:slice"

// _SCRATCH_BLOCK is the first block of the throwaway arena the bundle
// readers decode into. Large enough that a system CA bundle -- a few
// hundred KiB of PEM -- is read and decoded without a second block.
@(private)
_SCRATCH_BLOCK :: 256 * 1024

// _add is the only procedure that mutates the pool's contents.
//
// It is a transaction. Everything that can fail happens before anything
// is committed, and every step that has already succeeded has an undo
// that cannot itself fail:
//
//   - arena allocations are undone by arena_temp_end;
//   - `append` is undone by `pop`, which only decrements a length;
//   - a map insert is undone by `delete_key`, which is "contextless" and
//     only writes a tombstone.
//
// The commit is arena_temp_ignore, which cannot fail either. Ordering it
// the other way round -- reserving container space up front and then
// filling it in -- is what a Go-shaped implementation would do, and it is
// not sound here: Odin's `reserve` grows on raw capacity while an insert
// grows on a 75% load factor, so `reserve(&m, len(m)+1)` does not make
// the next insert non-allocating.
//
// `added` is false with `err == nil` when the certificate was already
// stored, in which case `idx` is the existing entry.
@(private)
_add :: proc(
	p: ^Pool,
	der: []byte,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
) -> (
	idx: int,
	added: bool,
	err: Error,
) {
	ensure(p != nil, "certstore: nil pool")
	ensure(p.initialized, "certstore: pool is not initialized")

	// --- Phase 0: rejections that need only the input bytes -----------
	// A duplicate costs one SHA-256 and never touches the arena.

	id := _cert_id(der)
	if existing, dup := p.by_id[id]; dup {
		// Already stored. Promote it if this call grants strictly more
		// authority than the entry has -- otherwise `add_anchor_der` on a
		// certificate some earlier bulk load happened to store as an
		// intermediate would silently decline to make it an anchor.
		//
		// Promotion is not a bypass: the entry has to pass the same screen
		// it would have faced on the way in. Demotion is never performed;
		// nothing here takes trust away.
		e := p.entries[existing]
		if trust == .Anchor && e.trust == .Intermediate {
			_screen(e.cert, screen) or_return
			e.trust = .Anchor
			p.views_dirty = true
		}
		return existing, false, nil
	}
	if _, denied := p.denied_certs[id]; denied {
		return 0, false, Store_Error.Denied
	}

	// --- Phase 1: build, inside an arena mark --------------------------
	// Everything from here to the commit is undone by the defer.

	arena := virtual.arena_allocator(&p.arena)
	mark := virtual.arena_temp_begin(&p.arena)
	committed := false
	defer if !committed {
		virtual.arena_temp_end(mark)
	}

	// The pool owns its bytes. `der` may be a Windows CERT_CONTEXT that is
	// freed before this call returns, a CFDataRef about to be released, a
	// mapped file, or a caller's stack buffer. Never alias it.
	owned := slice.clone(der, arena) or_return

	// Parse into the arena too, so dns_names / ip_addresses / extensions
	// share the DER's lifetime and x509.destroy is never needed.
	parsed := x509.parse(owned, arena) or_return

	e := new(Entry, arena) or_return
	cert_box := new_clone(parsed, arena) or_return

	e.cert = cert_box
	e.der = owned
	e.id = id
	e.key_id = _key_id(parsed.raw_spki)
	e.subject = _subject_key(parsed.raw_subject)
	e.trust = trust
	e.origin = origin

	// --- Phase 2: screening. Pure reads, no side effects ---------------

	if _, denied := p.denied_keys[e.key_id]; denied {
		return 0, false, Store_Error.Denied
	}
	_screen(e.cert, screen) or_return

	// --- Phase 3: container mutation -----------------------------------
	// Each step is fallible; each undo below it is not.

	e.index = len(p.entries)
	if _, aerr := append(&p.entries, e); aerr != nil {
		return 0, false, aerr
	}

	// map_entry is the checked insert: it hands back an explicit
	// Allocator_Error and whether the key was newly created, which are
	// exactly the two facts the rollback needs. `map_insert` signals
	// failure only by returning nil, and a bare `m[k] = v` discards the
	// error entirely.
	_, id_slot, _, ierr := map_entry(&p.by_id, e.id)
	if ierr != nil {
		pop(&p.entries) // decrements a length. Infallible.
		return 0, false, ierr
	}
	id_slot^ = e.index

	_, head, fresh, serr := map_entry(&p.by_subject, e.subject)
	if serr != nil {
		delete_key(&p.by_id, e.id) // tombstone only. Infallible.
		pop(&p.entries)
		return 0, false, serr
	}
	// Prepend onto the intrusive list; -1 terminates it.
	e.next_by_subject = -1 if fresh else head^
	head^ = e.index

	// --- Phase 4: commit. Infallible by construction -------------------

	p.views_dirty = true
	committed = true
	virtual.arena_temp_ignore(mark)
	return e.index, true, nil
}

// ---- single-certificate adders ---------------------------------------
//
// `added` is false with `err == nil` when the certificate was already
// present, in which case `idx` is the existing entry. A screening failure
// IS reported here as .Not_An_Anchor: a caller adding one named
// certificate deserves to be told it was refused.

// add_anchor_der stores a DER-encoded certificate as a trust anchor.
//
// It must look like a CA: see _screen_anchor. For a self-signed
// development CA that is not a CA certificate, use
// add_self_signed_anchor_der instead.
add_anchor_der :: proc(p: ^Pool, der: []byte) -> (idx: int, added: bool, err: Error) {
	ensure(p != nil, "certstore.add_anchor_der: nil pool")
	ensure(p.initialized, "certstore.add_anchor_der: pool is not initialized")
	return _add(p, der, .Anchor, .Blob, .CA_Anchor)
}

// add_intermediate_der stores a DER-encoded certificate as chain-building
// material. It is never a chain terminus, whatever it claims about
// itself, and it is not screened: verify_chain applies the full RFC 5280
// 6.1.4 battery to every candidate at verification time.
add_intermediate_der :: proc(p: ^Pool, der: []byte) -> (idx: int, added: bool, err: Error) {
	ensure(p != nil, "certstore.add_intermediate_der: nil pool")
	ensure(p.initialized, "certstore.add_intermediate_der: pool is not initialized")
	return _add(p, der, .Intermediate, .Blob, .None)
}

// add_self_signed_anchor_der stores a DER-encoded self-signed certificate
// as a trust anchor, without requiring it to be a CA certificate.
//
// This is the local-development-CA door. The certificate's issuer Name
// must equal its subject Name byte for byte and its signature must verify
// under its own public key; a certificate that cannot prove that is
// rejected with .Not_Self_Signed.
//
// It is a separate procedure rather than a flag on add_anchor_der on
// purpose: granting trust to something that never claimed to be a CA
// should be visible in a diff, and greppable.
add_self_signed_anchor_der :: proc(p: ^Pool, der: []byte) -> (idx: int, added: bool, err: Error) {
	ensure(p != nil, "certstore.add_self_signed_anchor_der: nil pool")
	ensure(p.initialized, "certstore.add_self_signed_anchor_der: pool is not initialized")
	return _add(p, der, .Anchor, .Blob, .Self_Signed)
}

// ---- bulk adders -----------------------------------------------------
//
// Per-certificate rejections are tolerated and counted in the report
// rather than aborting the load; only an allocation failure, an
// unreadable source or undecodable PEM is an error.

// add_anchors_pem stores every CERTIFICATE block in `pem_bytes` as a
// trust anchor.
add_anchors_pem :: proc(p: ^Pool, pem_bytes: []byte) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_anchors_pem: nil pool")
	ensure(p.initialized, "certstore.add_anchors_pem: pool is not initialized")
	return _add_pem_solo(p, pem_bytes, .Anchor, .Blob, .CA_Anchor)
}

// add_intermediates_pem stores every CERTIFICATE block in `pem_bytes` as
// chain-building material.
add_intermediates_pem :: proc(p: ^Pool, pem_bytes: []byte) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_intermediates_pem: nil pool")
	ensure(p.initialized, "certstore.add_intermediates_pem: pool is not initialized")
	return _add_pem_solo(p, pem_bytes, .Intermediate, .Blob, .None)
}

// add_self_signed_anchor_pem stores every CERTIFICATE block in
// `pem_bytes` as a trust anchor, requiring each to prove its own
// self-signature rather than to be a CA certificate. See
// add_self_signed_anchor_der.
add_self_signed_anchor_pem :: proc(p: ^Pool, pem_bytes: []byte) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_self_signed_anchor_pem: nil pool")
	ensure(p.initialized, "certstore.add_self_signed_anchor_pem: pool is not initialized")
	return _add_pem_solo(p, pem_bytes, .Anchor, .Blob, .Self_Signed)
}

// add_anchor_file reads `path` and stores what it holds as trust anchors.
//
// The content is sniffed: a leading 0x30 (DER SEQUENCE) is read as a
// single DER certificate, anything else is run through
// core:encoding/pem, which also covers a bundle of many blocks.
add_anchor_file :: proc(p: ^Pool, path: string) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_anchor_file: nil pool")
	ensure(p.initialized, "certstore.add_anchor_file: pool is not initialized")
	return _add_file_solo(p, path, .Anchor, .File, .CA_Anchor)
}

// add_intermediate_file reads `path` and stores what it holds as
// chain-building material. See add_anchor_file for the format sniffing.
add_intermediate_file :: proc(p: ^Pool, path: string) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_intermediate_file: nil pool")
	ensure(p.initialized, "certstore.add_intermediate_file: pool is not initialized")
	return _add_file_solo(p, path, .Intermediate, .File, .None)
}

// add_self_signed_anchor_file reads `path` and stores what it holds as
// trust anchors, requiring each to prove its own self-signature rather
// than to be a CA certificate. See add_self_signed_anchor_der.
add_self_signed_anchor_file :: proc(p: ^Pool, path: string) -> (r: Load_Report, err: Error) {
	ensure(p != nil, "certstore.add_self_signed_anchor_file: nil pool")
	ensure(p.initialized, "certstore.add_self_signed_anchor_file: pool is not initialized")
	return _add_file_solo(p, path, .Anchor, .File, .Self_Signed)
}

// ---- bulk plumbing ---------------------------------------------------

// _bucket folds one _add result into the report, and decides whether it
// was fatal to the load. A per-certificate rejection never is; an
// allocation failure always is.
@(private)
_bucket :: proc(r: ^Load_Report, added: bool, err: Error) -> Error {
	switch {
	case err == nil && added:
		r.added += 1
	case err == nil:
		r.duplicate += 1
	case _is(err, .Not_An_Anchor), _is(err, .Not_Self_Signed):
		r.rejected += 1
	case _is(err, .Denied):
		r.denied += 1
	case _is_parse(err):
		r.unparsable += 1
	case:
		return err
	}
	return nil
}

// _add_file reads one file into `scratch` and stores what it holds.
//
// The scratch arena is a parameter rather than a local so that a
// directory scan can hand the same one to every file it visits: a
// growing arena reserves address space on init, and doing that per file
// across a 150-entry /etc/ssl/certs is a syscall per certificate for no
// reason. Each call still brackets itself with a temp mark, so the
// arena's high-water mark is one file, not the whole directory.
@(private)
_add_file :: proc(
	p: ^Pool,
	path: string,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
	r: ^Load_Report,
	scratch: ^virtual.Arena,
) -> Error {
	mark := virtual.arena_temp_begin(scratch)
	defer virtual.arena_temp_end(mark)
	sa := virtual.arena_allocator(scratch)

	data, oerr := os.read_entire_file_from_path(path, sa)
	if oerr != nil || len(data) == 0 {
		return Store_Error.Path_Error
	}

	// 0x30 is the DER SEQUENCE tag that opens every X.509 certificate,
	// and no PEM file can begin with it.
	if data[0] == 0x30 {
		r.seen += 1
		_, added, aerr := _add(p, data, trust, origin, screen)
		return _bucket(r, added, aerr)
	}
	return _add_pem_blocks(p, data, trust, origin, screen, r, sa)
}

// _add_file_solo is _add_file for a caller that is only reading one file
// and has no scratch arena of its own.
@(private)
_add_file_solo :: proc(
	p: ^Pool,
	path: string,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
) -> (
	r: Load_Report,
	err: Error,
) {
	r.source = path
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch, _SCRATCH_BLOCK) or_return
	defer virtual.arena_destroy(&scratch)
	err = _add_file(p, path, trust, origin, screen, &r, &scratch)
	return
}

@(private)
_add_pem_solo :: proc(
	p: ^Pool,
	pem_bytes: []byte,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
) -> (
	r: Load_Report,
	err: Error,
) {
	scratch: virtual.Arena
	virtual.arena_init_growing(&scratch, _SCRATCH_BLOCK) or_return
	defer virtual.arena_destroy(&scratch)
	err = _add_pem_blocks(
		p,
		pem_bytes,
		trust,
		origin,
		screen,
		&r,
		virtual.arena_allocator(&scratch),
	)
	return
}

@(private)
_add_pem_blocks :: proc(
	p: ^Pool,
	data: []byte,
	trust: Trust,
	origin: Origin,
	screen: _Screen,
	r: ^Load_Report,
	scratch: runtime.Allocator,
) -> Error {
	rest := data
	saw_block := false

	for {
		blk, remaining, perr := pem.decode(rest, scratch)
		if perr != nil {
			return Store_Error.Bad_PEM
		}
		// No further blocks. pem.decode reports that as all-nils rather
		// than as an error.
		if blk == nil {
			break
		}
		rest = remaining
		saw_block = true

		// A bundle legitimately carries other things -- a private key, a
		// CRL, a trust-anchor comment block. Only certificates are ours.
		if blk.label != pem.LABEL_CERTIFICATE {
			continue
		}

		r.seen += 1
		_, added, aerr := _add(p, pem.block_bytes(blk), trust, origin, screen)
		_bucket(r, added, aerr) or_return
	}

	// Nothing that even looked like PEM. The caller handed us something
	// that is neither DER nor PEM, which is worth reporting: a bundle
	// holding only non-certificate blocks is not an error, but a file of
	// arbitrary bytes is.
	if !saw_block {
		return Store_Error.Bad_PEM
	}
	return nil
}
