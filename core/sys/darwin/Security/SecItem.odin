package Security

import CF "core:sys/darwin/CoreFoundation"

foreign import Security "system:Security.framework"

@(link_prefix="Sec", default_calling_convention="c")
foreign Security {
	// Query key whose value names the class of item to search for, e.g.
	// `kSecClassCertificate`.
	@(link_name="kSecClass")
	kSecClass: CF.String

	// The certificate item class.
	@(link_name="kSecClassCertificate")
	kSecClassCertificate: CF.String

	// The identity item class: a certificate paired with its private key.
	@(link_name="kSecClassIdentity")
	kSecClassIdentity: CF.String

	// Query key whose value caps the number of results.
	@(link_name="kSecMatchLimit")
	kSecMatchLimit: CF.String

	// Value for `kSecMatchLimit` meaning "every match".
	@(link_name="kSecMatchLimitAll")
	kSecMatchLimitAll: CF.String

	// Value for `kSecMatchLimit` meaning "the first match only".
	@(link_name="kSecMatchLimitOne")
	kSecMatchLimitOne: CF.String

	// Query key whose value asks for the results as object references
	// (a SecCertificateRef and so on). Pass `CF.kCFBooleanTrue`.
	@(link_name="kSecReturnRef")
	kSecReturnRef: CF.String

	// Query key whose value asks for the results as data (the DER, for a
	// certificate). Pass `CF.kCFBooleanTrue`.
	@(link_name="kSecReturnData")
	kSecReturnData: CF.String

	// Searches the keychain for items matching `query`.
	//
	// With `kSecMatchLimit` set to `kSecMatchLimitAll`, `result` is a
	// CFArray; with the default limit of one it is a single object. Either
	// way the result is owned by the caller and must be released with
	// `CF.Release`.
	//
	// Returns `.ItemNotFound` when nothing matched, which is not an error
	// so much as an empty answer.
	ItemCopyMatching :: proc(query: CF.Dictionary, result: ^CF.TypeRef) -> errSec ---
}
