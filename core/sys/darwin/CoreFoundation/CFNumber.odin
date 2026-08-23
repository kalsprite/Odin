package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

Number :: distinct TypeRef // same as CFNumberRef

// BooleanRef is a CFBooleanRef: the boxed object, not CFBoolean, which
// is the plain `unsigned char` this package spells `b8`.
BooleanRef :: distinct TypeRef

// NumberType identifies the C type a CFNumber's value is read as.
NumberType :: enum Index {
	SInt8     = 1,
	SInt16    = 2,
	SInt32    = 3,
	SInt64    = 4,
	Float32   = 5,
	Float64   = 6,
	Char      = 7,
	Short     = 8,
	Int       = 9,
	Long      = 10,
	LongLong  = 11,
	Float     = 12,
	Double    = 13,
	CFIndex   = 14,
	NSInteger = 15,
	CGFloat   = 16,
}

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	// Returns the type identifier for the CFNumber opaque type.
	NumberGetTypeID :: proc() -> TypeID ---

	// Returns the type used by a CFNumber to store its value.
	NumberGetType :: proc(number: Number) -> NumberType ---

	// Returns the size in bytes of the type of a CFNumber.
	NumberGetByteSize :: proc(number: Number) -> Index ---

	// Obtains the value of a CFNumber, converted to a given type.
	//
	// Returns false if the conversion was lossy or the value was out of
	// range for `theType`. `valuePtr` is written in either case, so a
	// false result must not be ignored.
	NumberGetValue :: proc(number: Number, theType: NumberType, valuePtr: rawptr) -> b8 ---

	// The two CFBoolean singletons.
	@(link_name="kCFBooleanTrue")
	kCFBooleanTrue: BooleanRef
	@(link_name="kCFBooleanFalse")
	kCFBooleanFalse: BooleanRef

	// Returns the type identifier for the CFBoolean opaque type.
	BooleanGetTypeID :: proc() -> TypeID ---

	// Returns the value of a CFBoolean object.
	BooleanGetValue :: proc(boolean: BooleanRef) -> b8 ---
}

// Reads a CFNumber as an i64.
//
// `ok` is false when the CFNumber is nil or the stored value does not
// convert to an i64 without loss.
NumberAsI64 :: proc "contextless" (number: Number) -> (value: i64, ok: bool) {
	if number == nil {
		return 0, false
	}
	v: i64
	if !NumberGetValue(number, .SInt64, &v) {
		return 0, false
	}
	return v, true
}

// Releases a Core Foundation number.
ReleaseNumber :: #force_inline proc(number: Number) {
	CFRelease(TypeRef(number))
}
