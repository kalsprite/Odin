package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

Array :: distinct TypeRef // same as CFArrayRef

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	// Returns the type identifier for the CFArray opaque type.
	ArrayGetTypeID :: proc() -> TypeID ---

	// Returns the number of values currently in an array.
	ArrayGetCount :: proc(theArray: Array) -> Index ---

	// Retrieves the value at a given index.
	//
	// The returned value is NOT retained: it is owned by the array and is
	// valid only for as long as the array is.
	ArrayGetValueAtIndex :: proc(theArray: Array, idx: Index) -> rawptr ---
}

// Releases a Core Foundation array.
ReleaseArray :: #force_inline proc(theArray: Array) {
	CFRelease(TypeRef(theArray))
}
