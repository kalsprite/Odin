package CoreFoundation

foreign import CoreFoundation "system:CoreFoundation.framework"

Dictionary :: distinct TypeRef // same as CFDictionaryRef

DictionaryRetainCallBack :: #type proc "c" (allocator: Allocator, value: rawptr) -> rawptr
DictionaryReleaseCallBack :: #type proc "c" (allocator: Allocator, value: rawptr)
DictionaryCopyDescriptionCallBack :: #type proc "c" (value: rawptr) -> String
DictionaryEqualCallBack :: #type proc "c" (value1: rawptr, value2: rawptr) -> b8
DictionaryHashCallBack :: #type proc "c" (value: rawptr) -> HashCode

// Callbacks a dictionary uses to manage its keys. Pass
// `&kCFTypeDictionaryKeyCallBacks` for keys that are Core Foundation
// objects, which is the usual case.
DictionaryKeyCallBacks :: struct {
	version:         Index,
	retain:          DictionaryRetainCallBack,
	release:         DictionaryReleaseCallBack,
	copyDescription: DictionaryCopyDescriptionCallBack,
	equal:           DictionaryEqualCallBack,
	hash:            DictionaryHashCallBack,
}

// Callbacks a dictionary uses to manage its values. Pass
// `&kCFTypeDictionaryValueCallBacks` for values that are Core Foundation
// objects.
//
// Note the missing `hash`: values are not hashed.
DictionaryValueCallBacks :: struct {
	version:         Index,
	retain:          DictionaryRetainCallBack,
	release:         DictionaryReleaseCallBack,
	copyDescription: DictionaryCopyDescriptionCallBack,
	equal:           DictionaryEqualCallBack,
}

@(link_prefix="CF", default_calling_convention="c")
foreign CoreFoundation {
	// Predefined callbacks for keys and values that are Core Foundation
	// objects: retain/release them, and compare them with CFEqual.
	@(link_name="kCFTypeDictionaryKeyCallBacks")
	kCFTypeDictionaryKeyCallBacks: DictionaryKeyCallBacks
	@(link_name="kCFTypeDictionaryValueCallBacks")
	kCFTypeDictionaryValueCallBacks: DictionaryValueCallBacks

	// Creates an immutable dictionary from `numValues` parallel key and
	// value arrays.
	//
	// The result is owned by the caller and must be released with
	// `Release`.
	DictionaryCreate :: proc(allocator: Allocator = nil, keys: [^]rawptr, values: [^]rawptr, numValues: Index, keyCallBacks: ^DictionaryKeyCallBacks, valueCallBacks: ^DictionaryValueCallBacks) -> Dictionary ---

	// Returns the type identifier for the CFDictionary opaque type.
	DictionaryGetTypeID :: proc() -> TypeID ---

	// Returns the number of key-value pairs in a dictionary.
	DictionaryGetCount :: proc(theDict: Dictionary) -> Index ---

	// Reports whether a given key is in a dictionary.
	DictionaryContainsKey :: proc(theDict: Dictionary, key: rawptr) -> b8 ---

	// Returns the value associated with a given key, or nil if the key is
	// not present.
	//
	// The returned value is NOT retained: it is owned by the dictionary and
	// is valid only for as long as the dictionary is.
	DictionaryGetValue :: proc(theDict: Dictionary, key: rawptr) -> rawptr ---
}

// Releases a Core Foundation dictionary.
ReleaseDictionary :: #force_inline proc(theDict: Dictionary) {
	CFRelease(TypeRef(theDict))
}
