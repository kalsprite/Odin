package Security

import CF "core:sys/darwin/CoreFoundation"

foreign import Security "system:Security.framework"

PolicyRef :: distinct rawptr

@(link_prefix="Sec", default_calling_convention="c")
foreign Security {
	// The dictionary key, in a policy's properties, whose value is the
	// policy's OID.
	@(link_name="kSecPolicyOid")
	kSecPolicyOid: CF.String

	// The OID of the policy used to evaluate SSL/TLS certificate chains.
	@(link_name="kSecPolicyAppleSSL")
	kSecPolicyAppleSSL: CF.String

	// The OID of the policy used to evaluate S/MIME certificate chains.
	@(link_name="kSecPolicyAppleSMIME")
	kSecPolicyAppleSMIME: CF.String

	// Returns the type identifier for SecPolicy instances.
	PolicyGetTypeID :: proc() -> CF.TypeID ---

	// Returns a dictionary of a policy's properties, keyed by the
	// `kSecPolicy*` constants above.
	//
	// The result is owned by the caller and must be released with
	// `CF.Release`.
	PolicyCopyProperties :: proc(policyRef: PolicyRef) -> CF.Dictionary ---
}
