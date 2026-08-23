package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

TypeID      :: distinct uint
OptionFlags :: distinct uint
HashCode    :: distinct uint
Index       :: distinct int
TypeRef     :: distinct rawptr

// Allocator is a CFAllocatorRef.
//
// Passing nil where one is expected selects the default system allocator,
// which is what every allocating binding in this package defaults to.
Allocator :: distinct TypeRef // same as CFAllocatorRef

Range :: struct {
	location: Index,
	length:   Index,
}

foreign CoreFoundation {
	// Releases a Core Foundation object.
	CFRelease :: proc(cf: TypeRef) ---
}

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	// The default system allocator.
	@(link_name="kCFAllocatorDefault")
	kCFAllocatorDefault: Allocator

	// Returns the unique identifier of the opaque type a Core Foundation
	// object belongs to.
	GetTypeID :: proc(cf: TypeRef) -> TypeID ---

	// Retains a Core Foundation object, incrementing its reference count,
	// and returns the object that was passed in.
	Retain :: proc(cf: TypeRef) -> TypeRef ---

	// Determines whether two Core Foundation objects are considered equal.
	Equal :: proc(cf1: TypeRef, cf2: TypeRef) -> b8 ---
}

// Releases a Core Foundation object.
Release :: proc {
	ReleaseObject,
	ReleaseString,
	ReleaseArray,
	ReleaseData,
	ReleaseDictionary,
	ReleaseNumber,
}

ReleaseObject :: #force_inline proc(cf: TypeRef) {
	CFRelease(cf)
}

// Releases a Core Foundation string.
ReleaseString :: #force_inline proc(theString: String) {
	CFRelease(TypeRef(theString))
}
