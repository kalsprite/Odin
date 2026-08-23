package Security

import CF "core:sys/darwin/CoreFoundation"

foreign import Security "system:Security.framework"

// TrustSettingsDomain names one of the three stores trust settings are
// kept in. They are consulted most-specific first: a User setting overrides
// an Admin one, which overrides the System one.
TrustSettingsDomain :: enum u32 {
	User   = 0, // The current user's keychain.
	Admin  = 1, // The machine-wide administrator keychain.
	System = 2, // The read-only store of certificates shipped by Apple.
}

// TrustSettingsResult is the verdict recorded for one certificate by one
// trust settings entry.
//
// It is stored in a trust settings dictionary as a CFNumber under the
// `kSecTrustSettingsResult` key. An entry with no such key means
// `.TrustRoot`.
TrustSettingsResult :: enum i32 {
	Invalid     = 0, // Never valid in a trust settings dictionary.
	TrustRoot   = 1, // Trusted, and only valid for a root (self-signed) certificate.
	TrustAsRoot = 2, // Trusted, and only valid for a non-root certificate.
	Deny        = 3, // Explicitly distrusted.
	Unspecified = 4, // No verdict here; defer to the next domain out.
}

// TrustSettingsKeyUsage constrains a trust settings entry to certificates
// whose key usage matches, as a bit field under the
// `kSecTrustSettingsKeyUsage` key.
TrustSettingsKeyUsage :: distinct u32

TRUST_SETTINGS_KEY_USE_SIGNATURE       :: TrustSettingsKeyUsage(0x00000001)
TRUST_SETTINGS_KEY_USE_ENDECRYPT_DATA  :: TrustSettingsKeyUsage(0x00000002)
TRUST_SETTINGS_KEY_USE_ENDECRYPT_KEY   :: TrustSettingsKeyUsage(0x00000004)
TRUST_SETTINGS_KEY_USE_SIGN_CERT       :: TrustSettingsKeyUsage(0x00000008)
TRUST_SETTINGS_KEY_USE_SIGN_REVOCATION :: TrustSettingsKeyUsage(0x00000010)
TRUST_SETTINGS_KEY_USE_KEY_EXCHANGE    :: TrustSettingsKeyUsage(0x00000020)
TRUST_SETTINGS_KEY_USE_ANY             :: TrustSettingsKeyUsage(0xffffffff)

@(link_prefix="Sec", default_calling_convention="c")
foreign Security {
	// Key whose value is the SecPolicyRef a trust settings entry applies
	// to. An entry with no policy applies to every policy.
	@(link_name="kSecTrustSettingsPolicy")
	kSecTrustSettingsPolicy: CF.String

	// Key whose value is a CFString naming the policy a trust settings
	// entry applies to.
	@(link_name="kSecTrustSettingsPolicyName")
	kSecTrustSettingsPolicyName: CF.String

	// Key whose value is the application a trust settings entry is
	// restricted to. An entry with no application applies to every one.
	@(link_name="kSecTrustSettingsApplication")
	kSecTrustSettingsApplication: CF.String

	// Key whose value is a CFString the policy interprets: for the SSL
	// policy, the hostname the entry is restricted to.
	@(link_name="kSecTrustSettingsPolicyString")
	kSecTrustSettingsPolicyString: CF.String

	// Key whose value is a CFNumber of TrustSettingsKeyUsage flags.
	@(link_name="kSecTrustSettingsKeyUsage")
	kSecTrustSettingsKeyUsage: CF.String

	// Key whose value is a CFNumber holding the errSec code this entry
	// tells the evaluator to ignore.
	@(link_name="kSecTrustSettingsAllowedError")
	kSecTrustSettingsAllowedError: CF.String

	// Key whose value is a CFNumber holding a TrustSettingsResult. An
	// entry with no such key means `.TrustRoot`.
	@(link_name="kSecTrustSettingsResult")
	kSecTrustSettingsResult: CF.String

	// Obtains every certificate that has trust settings in a domain.
	//
	// On success `certArray` is set to a CFArray of SecCertificateRef
	// owned by the caller, which must be released with `CF.Release`.
	// Returns `.ItemNotFound` when the domain holds no trust settings at
	// all, in which case `certArray` is not written.
	TrustSettingsCopyCertificates :: proc(domain: TrustSettingsDomain, certArray: ^CF.Array) -> errSec ---

	// Obtains the trust settings recorded for one certificate in one
	// domain.
	//
	// On success `trustSettings` is set to a CFArray of CFDictionary owned
	// by the caller, which must be released with `CF.Release`. An EMPTY
	// array is meaningful and is not an error: it means the certificate is
	// unconditionally trusted as a root in this domain.
	//
	// Returns `.ItemNotFound` when this certificate has no trust settings
	// in this domain, in which case `trustSettings` is not written.
	TrustSettingsCopyTrustSettings :: proc(certRef: CertificateRef, domain: TrustSettingsDomain, trustSettings: ^CF.Array) -> errSec ---
}
