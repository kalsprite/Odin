package Security

import CF "core:sys/darwin/CoreFoundation"

foreign import Security "system:Security.framework"

CertificateRef :: distinct rawptr

@(link_prefix="Sec", default_calling_convention="c")
foreign Security {
	// Returns the type identifier for SecCertificate instances.
	CertificateGetTypeID :: proc() -> CF.TypeID ---

	// Creates a certificate object from a DER-encoded certificate.
	//
	// Returns nil if the data is not a valid DER-encoded X.509 certificate.
	// The result is owned by the caller and must be released with
	// `CF.Release`.
	CertificateCreateWithData :: proc(allocator: CF.Allocator = nil, data: CF.Data) -> CertificateRef ---

	// Returns the DER representation of an X.509 certificate.
	//
	// The result is owned by the caller and must be released with
	// `CF.Release`. Its bytes are only valid for as long as it is: copy
	// them if they have to outlive it.
	CertificateCopyData :: proc(certificate: CertificateRef) -> CF.Data ---

	// Returns a human-readable summary of a certificate, derived from its
	// subject.
	//
	// The result is owned by the caller and must be released with
	// `CF.Release`. This is a display string, not an identifier: do not
	// make trust decisions with it.
	CertificateCopySubjectSummary :: proc(certificate: CertificateRef) -> CF.String ---
}
