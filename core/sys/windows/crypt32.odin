#+build windows
package sys_windows

foreign import crypt32 "system:crypt32.lib"

// GetLastError value meaning "the enumeration reached the end of the
// store", as opposed to "the enumeration failed".
//
// CertEnumCertificatesInStore returns nil for both, so this is the only
// thing that distinguishes a finished store from a broken one.
CRYPT_E_NOT_FOUND :: DWORD(0x80092004)

@(default_calling_convention="system")
foreign crypt32 {
	CertOpenSystemStoreW        :: proc(hProv: HCRYPTPROV_LEGACY, szSubsystemProtocol: LPCWSTR) -> HCERTSTORE ---
	CertCloseStore              :: proc(hCertStore: HCERTSTORE, dwFlags: DWORD) -> BOOL ---
	CertEnumCertificatesInStore :: proc(hCertStore: HCERTSTORE, pPrevCertContext: ^CERT_CONTEXT) -> ^CERT_CONTEXT ---
	CertFreeCertificateContext  :: proc(pCertContext: ^CERT_CONTEXT) -> BOOL ---
}