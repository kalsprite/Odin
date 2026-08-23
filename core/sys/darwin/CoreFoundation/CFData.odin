package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

Data :: distinct TypeRef // same as CFDataRef

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	// Returns the type identifier for the CFData opaque type.
	DataGetTypeID :: proc() -> TypeID ---

	// Returns the number of bytes contained by a CFData object.
	DataGetLength :: proc(theData: Data) -> Index ---

	// Returns a read-only pointer to the bytes of a CFData object.
	//
	// The bytes are owned by the CFData and are valid only for as long as
	// it is; copy them before releasing it.
	DataGetBytePtr :: proc(theData: Data) -> [^]byte ---

	// Copies the byte contents of a CFData object to an external buffer.
	DataGetBytes :: proc(theData: Data, range: Range, buffer: [^]byte) ---

	// Creates an immutable CFData object using data copied from a supplied buffer.
	DataCreate :: proc(allocator: Allocator, bytes: [^]byte, length: Index) -> Data ---
}

// Returns the bytes of a CFData object as an Odin slice.
//
// The slice VIEWS the CFData's storage rather than owning it, and is
// invalidated when the CFData is released. Clone it if it has to outlive
// that.
DataAsSlice :: proc "contextless" (theData: Data) -> []byte {
	if theData == nil {
		return nil
	}
	n := DataGetLength(theData)
	if n <= 0 {
		return nil
	}
	return DataGetBytePtr(theData)[:n]
}

// Releases a Core Foundation data object.
ReleaseData :: #force_inline proc(theData: Data) {
	CFRelease(TypeRef(theData))
}
