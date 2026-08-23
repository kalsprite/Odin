package certstore

import "base:runtime"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:mem/virtual"

// Cert_ID is SHA-256 over the whole outer DER Certificate element.
//
// It answers "is this exact byte sequence already here?" and "is this
// exact certificate denied?".
//
// Go's CertPool uses a truncated SHA-224 here (its `sum224`) purely to
// shrink an internal map key. That is not copied: the same value is
// load-bearing for a deny decision, and a digest that carries security
// weight should not be the one chosen for its size.
Cert_ID :: distinct [32]byte

// Key_ID is SHA-256 over `cert.raw_spki`, the SubjectPublicKeyInfo
// element.
//
// Denying a Key_ID denies every certificate carrying that public key: a
// re-issue with a fresh serial and a fresh validity window does not
// escape it. This is the granularity a compromised intermediate needs.
Key_ID :: distinct [32]byte

// Subject_Key is SHA-256 over `cert.raw_subject`, the DER subject Name
// element. It buckets entries by the distinguished name a child's issuer
// field would have to equal.
//
// A collision here is a performance question, not a security one: x509
// re-compares the full DN bytes before any signature is checked.
Subject_Key :: distinct [32]byte

// Trust is the authority a stored certificate carries.
//
// The zero value is `.Intermediate` on purpose. A certificate that
// reaches the pool without an explicit decision is chain-building
// material, never a chain terminus; anchor status is only ever set by
// someone who asked for it.
//
// There is no `.Distrusted` member: distrust lives in a separate pair of
// maps, so it cannot be reached by forgetting to assign a field.
Trust :: enum u8 {
	Intermediate = 0,
	Anchor,
}

// Origin records where a certificate came from. Diagnostics only: no
// verification decision anywhere in this package reads this field.
Origin :: enum u8 {
	Unknown = 0,
	System_Root,
	System_Personal,
	File,
	Blob,
}

// Entry is one stored certificate.
//
// Entries are allocated out of the pool's arena and never move, so an
// `^Entry`, or the `^x509.Certificate` inside it, stays valid for the
// whole life of the pool.
Entry :: struct {
	// cert points into the arena. Every []byte field of cert is a view
	// into `der` below, and the three slices x509.parse allocates
	// (dns_names, ip_addresses, extensions) are arena-allocated too, so
	// the whole certificate has exactly one lifetime.
	cert:            ^x509.Certificate,
	der:             []byte, // the pool's own copy of the input DER
	id:              Cert_ID,
	key_id:          Key_ID,
	subject:         Subject_Key,
	trust:           Trust,
	origin:          Origin,
	index:           int, // position in Pool.entries; entries[i].index == i

	// Intrusive singly-linked list of every entry sharing `subject`,
	// newest first, terminated by -1.
	//
	// This replaces a map[Subject_Key][dynamic]int, and not as a
	// micro-optimisation: a nested dynamic array would make the add
	// transaction's rollback fallible, whereas prepending onto an
	// intrusive list is undone by restoring one int.
	next_by_subject: int,
}

// Pool is a set of certificates plus the indexes needed to build a chain
// out of them.
//
// It is append-only. A certificate can be added and it can be denied;
// nothing is ever removed and a deny is never lifted.
//
// A Pool must not be copied after `init`: the entries, the maps and the
// arena all alias each other, so a shallow copy produces two owners of
// one arena. Every entry point in this package takes a `^Pool`, and no
// procedure anywhere returns a Pool by value.
Pool :: struct {
	// Sole owner of every byte of DER, every x509.Certificate, every
	// slice those certificates allocated, and every Entry. One owner,
	// one free.
	arena:        virtual.Arena,

	// Stable ^Entry values, in insertion order.
	entries:      [dynamic]^Entry,
	by_id:        map[Cert_ID]int, // dedup, and `contains`
	by_subject:   map[Subject_Key]int, // head of the next_by_subject list

	// Distrust. Consulted when the verification views are rebuilt AND
	// again over every completed chain. A denied certificate may still be
	// *stored* -- it can have been added before the deny arrived -- but it
	// can never appear in an accepted chain.
	denied_certs: map[Cert_ID]struct {},
	denied_keys:  map[Key_ID]struct {},

	// The two slices handed to x509.verify_chain, rebuilt on demand.
	// Deny is applied when these are built, which is what makes a deny
	// retroactive over certificates already in the pool.
	anchor_view:  [dynamic]^x509.Certificate,
	inter_view:   [dynamic]^x509.Certificate,
	views_dirty:  bool,

	// Allocator for the six containers above. They grow, and an Odin
	// container cannot free into an arena, so they get an ordinary
	// allocator instead.
	//
	// `init` make()s every one of them with this allocator, and that is
	// not cosmetic: a zero-initialised Odin map binds context.allocator on
	// its first insert, and a zero-initialised [dynamic] does the same. A
	// pool that outlives the context that created it -- the normal case
	// for a process-wide root pool -- would then be half-owned by an
	// allocator that no longer exists.
	containers:   runtime.Allocator,

	// True once load_system_roots or load_system_personal succeeded.
	// Diagnostic: it tells a caller that these anchors came from the OS
	// and may be subject to OS-level policy this package does not model.
	from_system:  bool,
	initialized:  bool,
}

// Store_Error is the certificate-store half of `Error`.
//
// Lifecycle misuse is deliberately absent from this enum. Calling into a
// pool that was never initialised, or initialising one twice, is a
// programmer error with no recovery: the pool is unusable either way, so
// those are `ensure`s rather than values a caller could ignore.
Store_Error :: enum {
	None = 0,
	Denied, // on a deny list
	Not_An_Anchor, // failed anchor screening
	Not_Self_Signed, // add_self_signed_anchor_*: subject/issuer or signature mismatch
	No_System_Store, // the platform has one, but nothing was found
	System_Store_Failed, // the OS refused to open or enumerate it
	Unsupported_Platform, // SYSTEM_STORE_SUPPORTED == false here
	Bad_PEM,
	Path_Error, // could not read the file or directory
}

// Error is what every fallible entry point returns.
//
// x509.Error and runtime.Allocator_Error are enums and nest fine.
// pem.Error and os.Error are themselves `union #shared_nil`, and Odin
// union nesting is not transitive, so putting one in here would give a
// member that is itself a union rather than a flattened set. They are
// destructured at the call site instead: a PEM failure becomes .Bad_PEM
// and an os failure becomes .Path_Error. A caller who needs the errno
// reads the file itself and calls add_anchor_der.
Error :: union #shared_nil {
	runtime.Allocator_Error,
	x509.Error,
	Store_Error,
}

// Load_Report accounts for a bulk load. Every certificate the loader saw
// lands in exactly one bucket, so
//
//	added + duplicate + rejected + unparsable + denied == seen
//
// A load returning `err == nil` with `rejected > 0` is normal rather than
// a warning: a real system root store contains certificates this package
// will not anchor. The point of the report is that skipping them is
// visible instead of silent.
Load_Report :: struct {
	seen:       int,
	added:      int,
	duplicate:  int,
	rejected:   int, // failed anchor screening
	unparsable: int, // x509.parse said no
	denied:     int, // already on a deny list at add time
	source:     string, // the bundle path or OS store name actually used
}

// init prepares an empty pool.
//
// `container_alloc` backs the indexes and the verification views. It is
// explicit and has no default because a pool routinely outlives the
// context that created it, and picking up whatever `context.allocator`
// happened to be in scope is exactly the mistake that produces a
// half-owned pool.
//
// `reserve` sizes the arena's first block. 1 MiB comfortably holds a
// full system root store -- 121 certificates from /etc/ssl/certs measure
// at 145,976 bytes of DER -- so the common case never grows a block.
@(require_results)
init :: proc(p: ^Pool, container_alloc: runtime.Allocator, reserve: uint = 1 << 20) -> (err: Error) {
	ensure(p != nil, "certstore.init: nil pool")
	ensure(!p.initialized, "certstore.init: pool is already initialized")

	p^ = {}
	p.containers = container_alloc

	// Odin has no goto, so unwinding a partial construction is a defer.
	// _release is safe on a half-built pool: every field is either still
	// zero -- delete on a nil map or dynamic array is a no-op, and
	// arena_destroy on a zeroed Arena sees kind == .Growing with no blocks
	// -- or fully constructed at the moment the next step can fail.
	ok := false
	defer if !ok {
		_release(p)
	}

	virtual.arena_init_growing(&p.arena, reserve) or_return

	// Every one of these is make()d rather than left zero, so that each
	// container's allocator is p.containers and not whatever context the
	// first insert happened to run under.
	p.entries = make([dynamic]^Entry, 0, 256, container_alloc) or_return
	p.by_id = make(map[Cert_ID]int, 256, container_alloc) or_return
	p.by_subject = make(map[Subject_Key]int, 256, container_alloc) or_return
	p.denied_certs = make(map[Cert_ID]struct {}, 8, container_alloc) or_return
	p.denied_keys = make(map[Key_ID]struct {}, 8, container_alloc) or_return
	p.anchor_view = make([dynamic]^x509.Certificate, 0, 192, container_alloc) or_return
	p.inter_view = make([dynamic]^x509.Certificate, 0, 32, container_alloc) or_return

	p.views_dirty = true
	p.initialized = true
	ok = true
	return nil
}

// destroy releases everything the pool owns and zeroes it.
//
// Idempotent: calling it twice, on a zeroed Pool, or in a defer after a
// failed init, is a no-op. That is why this one takes an uninitialised
// pool without complaint where the rest of the API does not -- a `defer
// destroy(&pool)` placed before `init` can fail is the correct way to
// write the call, and it has to work.
destroy :: proc(p: ^Pool) {
	ensure(p != nil, "certstore.destroy: nil pool")
	if !p.initialized {
		return
	}
	_release(p)
}

@(private)
_release :: proc(p: ^Pool) {
	// One arena free takes out every DER, every x509.Certificate, every
	// parse-allocated slice and every Entry. Note what is not here: no
	// loop calling x509.destroy.
	virtual.arena_destroy(&p.arena)

	delete(p.entries) // each container frees with its own stored
	delete(p.by_id) // allocator, which init set to p.containers.
	delete(p.by_subject)
	delete(p.denied_certs)
	delete(p.denied_keys)
	delete(p.anchor_view)
	delete(p.inter_view)

	p^ = {}
}

// count is the number of certificates in the pool, denied ones included.
@(require_results)
count :: proc(p: ^Pool) -> int {
	ensure(p != nil, "certstore.count: nil pool")
	ensure(p.initialized, "certstore.count: pool is not initialized")
	return len(p.entries)
}

// anchor_count is the number of certificates stored as trust anchors,
// denied ones included. Use `len(anchors(p))` for the number that would
// actually be offered to a verification.
@(require_results)
anchor_count :: proc(p: ^Pool) -> (n: int) {
	ensure(p != nil, "certstore.anchor_count: nil pool")
	ensure(p.initialized, "certstore.anchor_count: pool is not initialized")
	for e in p.entries {
		if e.trust == .Anchor {
			n += 1
		}
	}
	return
}

// entry returns the i'th stored certificate in insertion order, or nil
// when `i` is out of range. The returned pointer is stable for the life
// of the pool.
@(require_results)
entry :: proc(p: ^Pool, i: int) -> ^Entry {
	ensure(p != nil, "certstore.entry: nil pool")
	ensure(p.initialized, "certstore.entry: pool is not initialized")
	if i < 0 || i >= len(p.entries) {
		return nil
	}
	return p.entries[i]
}

// contains reports whether these exact DER bytes are already stored, and
// where.
@(require_results)
contains :: proc(p: ^Pool, der: []byte) -> (idx: int, ok: bool) {
	ensure(p != nil, "certstore.contains: nil pool")
	ensure(p.initialized, "certstore.contains: pool is not initialized")
	idx, ok = p.by_id[_cert_id(der)]
	return
}

// find_by_subject appends every stored entry whose subject Name element
// equals `subject_der` to `dst`, newest first.
//
// `subject_der` is a whole DER Name element, the same bytes an issuing
// certificate carries in `raw_issuer`. Denied entries are included:
// this is an index query, not a trust decision.
find_by_subject :: proc(p: ^Pool, subject_der: []byte, dst: ^[dynamic]^Entry) -> Error {
	ensure(p != nil, "certstore.find_by_subject: nil pool")
	ensure(p.initialized, "certstore.find_by_subject: pool is not initialized")
	ensure(dst != nil, "certstore.find_by_subject: nil destination")

	head, present := p.by_subject[_subject_key(subject_der)]
	if !present {
		return nil
	}
	for i := head; i >= 0; i = p.entries[i].next_by_subject {
		append(dst, p.entries[i]) or_return
	}
	return nil
}

// anchors is the pool's trust anchors with the denied ones removed: the
// exact slice a verification would be given as its roots.
//
// The slice is owned by the pool and is invalidated by the next add or
// deny.
@(require_results)
anchors :: proc(p: ^Pool) -> (certs: []^x509.Certificate, err: Error) {
	ensure(p != nil, "certstore.anchors: nil pool")
	ensure(p.initialized, "certstore.anchors: pool is not initialized")
	_refresh_views(p) or_return
	return p.anchor_view[:], nil
}

// intermediates is the pool's non-anchor certificates with the denied
// ones removed. A verification adds the peer's own certificates to these
// before searching; this is only the pool's contribution.
//
// The slice is owned by the pool and is invalidated by the next add or
// deny.
@(require_results)
intermediates :: proc(p: ^Pool) -> (certs: []^x509.Certificate, err: Error) {
	ensure(p != nil, "certstore.intermediates: nil pool")
	ensure(p.initialized, "certstore.intermediates: pool is not initialized")
	_refresh_views(p) or_return
	return p.inter_view[:], nil
}

// from_system_store reports whether any of this pool's contents came out
// of an operating system store.
@(require_results)
from_system_store :: proc(p: ^Pool) -> bool {
	ensure(p != nil, "certstore.from_system_store: nil pool")
	ensure(p.initialized, "certstore.from_system_store: pool is not initialized")
	return p.from_system
}

// ---- identity --------------------------------------------------------

// cert_id is the deny-list identifier for one exact certificate: SHA-256
// over the whole outer DER Certificate element.
@(require_results)
cert_id :: proc(der: []byte) -> Cert_ID {
	return _cert_id(der)
}

// key_id is the deny-list identifier for a public key: SHA-256 over the
// certificate's SubjectPublicKeyInfo element. Denying it denies every
// certificate that carries the same key.
@(require_results)
key_id :: proc(cert: ^x509.Certificate) -> Key_ID {
	ensure(cert != nil, "certstore.key_id: nil certificate")
	return _key_id(cert.raw_spki)
}

@(private, require_results)
_sha256 :: proc(data: []byte) -> (out: [32]byte) {
	hash.hash_bytes_to_buffer(.SHA256, data, out[:])
	return
}

@(private, require_results)
_cert_id :: proc(der: []byte) -> Cert_ID {
	return Cert_ID(_sha256(der))
}

@(private, require_results)
_key_id :: proc(spki: []byte) -> Key_ID {
	return Key_ID(_sha256(spki))
}

@(private, require_results)
_subject_key :: proc(subject: []byte) -> Subject_Key {
	return Subject_Key(_sha256(subject))
}

// ---- error helpers ---------------------------------------------------

// _is reports whether `err` is exactly this Store_Error. Used by the
// bulk loaders to bucket a per-certificate rejection without treating it
// as fatal.
@(private, require_results)
_is :: proc(err: Error, want: Store_Error) -> bool {
	e, ok := err.(Store_Error)
	return ok && e == want
}

// _is_parse reports whether `err` came from x509.parse rather than from
// the store or the allocator.
@(private, require_results)
_is_parse :: proc(err: Error) -> bool {
	_, ok := err.(x509.Error)
	return ok
}
