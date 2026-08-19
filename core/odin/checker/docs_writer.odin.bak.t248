package checker

/*
Binary documentation format writer (.odin-doc files).

This module implements the binary .odin-doc format writer, which serializes
type information, entities, and documentation into a compact binary format
for use by documentation tools.

C++ References:
- docs_format.cpp (format definitions)
- docs_writer.cpp (writer implementation)

Format version: 0.3.2
Magic string: "odindoc\0"
*/

import "core:mem"
import "core:odin/ast"
import "core:os"
import "core:slice"
import "core:strings"

// ======================================================================================
// BINARY FORMAT CONSTANTS
// C++ Reference: docs_format.cpp:1-18
// ======================================================================================

ODIN_DOC_MAGIC_STRING :: "odindoc\x00"

ODIN_DOC_VERSION_MAJOR :: 0
ODIN_DOC_VERSION_MINOR :: 3
// C++ Reference: docs_format.cpp:18 -- `#define OdinDocVersionType_Patch 2`. The port was pinned at
// 1, so every .odin-doc it wrote announced a format one revision older than the one it actually
// encodes. A consumer that version-gates (odin-doc renderers do) would decode the file under the
// wrong schema, which is worse than refusing it. Bumped WITH the two schema additions this tick
// restores -- Doc_Type_Kind.Fixed_Capacity_Dynamic_Array and the Array generic-count pair -- which
// are what 0.3.2 IS (upstream commits "Add fixed capacity dynamic array to the doc-format" and
// "Add generic count of arrays to to doc-format").
ODIN_DOC_VERSION_PATCH :: 2

ODIN_DOC_TYPE_ELEMS_CAP :: 4

// ======================================================================================
// BINARY FORMAT STRUCTURES
// C++ Reference: docs_format.cpp:3-291
// ======================================================================================

// Doc_Array is a generic array reference in the binary format
// C++ Reference: OdinDocArray<T>
Doc_Array :: struct($T: typeid) {
	offset: u32,
	length: u32,
}

Doc_String :: Doc_Array(u8)

// Global flag indicating we're currently writing documentation
// C++ Reference: docs_writer.cpp:10-15 (g_in_doc_writer)
// Used by name_canonicalization to include default values in canonical strings
g_in_doc_writer: bool = false

// is_in_doc_writer returns true if we're currently in the doc writer
// C++ Reference: docs_writer.cpp:1179-1181
is_in_doc_writer :: proc() -> bool {
	return g_in_doc_writer
}

// Doc_Version stores format version information
// C++ Reference: OdinDocVersionType
Doc_Version :: struct {
	major: u8,
	minor: u8,
	patch: u8,
	pad0:  u8,
}

// Doc_Header_Base is the base header for .odin-doc files
// C++ Reference: OdinDocHeaderBase
Doc_Header_Base :: struct {
	magic:       [8]u8,
	padding0:    u32,
	version:     Doc_Version,
	total_size:  u32,
	header_size: u32,
	hash:        u32, // Hash of data after header
}

// Index types
Doc_File_Index :: u32
Doc_Pkg_Index :: u32
Doc_Entity_Index :: u32
Doc_Type_Index :: u32

// Doc_File represents a source file in the binary format
// C++ Reference: OdinDocFile
Doc_File :: struct {
	pkg:  Doc_Pkg_Index,
	name: Doc_String,
}

// Doc_Position represents a source position
// C++ Reference: OdinDocPosition
Doc_Position :: struct {
	file:   Doc_File_Index,
	line:   u32,
	column: u32,
	offset: u32,
}

// Doc_Type_Kind enumerates type kinds in the format
// C++ Reference: OdinDocTypeKind
Doc_Type_Kind :: enum u32 {
	Invalid           = 0,
	Basic             = 1,
	Named             = 2,
	Generic           = 3,
	Pointer           = 4,
	Array             = 5,
	Enumerated_Array  = 6,
	Slice             = 7,
	Dynamic_Array     = 8,
	Map               = 9,
	Struct            = 10,
	Union             = 11,
	Enum              = 12,
	Tuple             = 13,
	Proc              = 14,
	Bit_Set           = 15,
	Simd_Vector       = 16,
	SOA_Struct_Fixed  = 17,
	SOA_Struct_Slice  = 18,
	SOA_Struct_Dynamic = 19,
	Multi_Pointer     = 22,
	Matrix            = 23,
	Soa_Pointer       = 24,
	Bit_Field         = 25,
	// C++ Reference: docs_format.cpp:86 -- `OdinDocType_FixedCapacityDynamicArray = 26`. The port
	// had no enumerator, and doc_write_type had no arm, so `[dynamic; N]T` fell out of its
	// `#partial switch` and was written as kind 0 (Invalid) with no element type and no capacity.
	// The FOURTH time this type kind has turned out to be the blind spot (LEDGER #709
	// add_min_dep_type_info, #515 type_size_of/type_align_of, tick 226's init_core_type_info).
	Fixed_Capacity_Dynamic_Array = 26,
}

// Type-specific flags
// C++ Reference: OdinDocTypeFlag_*
Doc_Type_Flag_Basic :: enum u32 {
	Untyped = 1 << 1,
}

Doc_Type_Flag_Struct :: enum u32 {
	Polymorphic = 1 << 0,
	Packed      = 1 << 1,
	Raw_Union   = 1 << 2,
	All_Or_None = 1 << 3,
}

Doc_Type_Flag_Union :: enum u32 {
	Polymorphic = 1 << 0,
	No_Nil      = 1 << 1,
	Shared_Nil  = 1 << 3,
}

Doc_Type_Flag_Proc :: enum u32 {
	Polymorphic = 1 << 0,
	Diverging   = 1 << 1,
	Optional_Ok = 1 << 2,
	Variadic    = 1 << 3,
	C_Vararg    = 1 << 4,
}

Doc_Type_Flag_BitSet :: enum u32 {
	Range           = 1 << 1,
	Op_Lt           = 1 << 2,
	Op_Lt_Eq        = 1 << 3,
	Underlying_Type = 1 << 4,
}

// Doc_Type represents a type in the binary format
// C++ Reference: OdinDocType
Doc_Type :: struct {
	kind:               Doc_Type_Kind,
	flags:              u32,
	name:               Doc_String,
	custom_align:       Doc_String,
	elem_count_len:     u32,
	elem_counts:        [ODIN_DOC_TYPE_ELEMS_CAP]i64,
	calling_convention: Doc_String,
	types:              Doc_Array(Doc_Type_Index),
	entities:           Doc_Array(Doc_Entity_Index),
	polymorphic_params: Doc_Type_Index,
	where_clauses:      Doc_Array(Doc_String),
	tags:               Doc_Array(Doc_String),
}

// Doc_Attribute represents an entity attribute
// C++ Reference: OdinDocAttribute
Doc_Attribute :: struct {
	name:  Doc_String,
	value: Doc_String,
}

// Doc_Entity_Kind enumerates entity kinds
// C++ Reference: OdinDocEntityKind
Doc_Entity_Kind :: enum u32 {
	Invalid      = 0,
	Constant     = 1,
	Variable     = 2,
	Type_Name    = 3,
	Procedure    = 4,
	Proc_Group   = 5,
	Import_Name  = 6,
	Library_Name = 7,
	Builtin      = 8,
}

// Doc_Entity_Flag represents entity flags
// C++ Reference: OdinDocEntityFlag
Doc_Entity_Flags :: bit_set[Doc_Entity_Flag; u64]
Doc_Entity_Flag :: enum u64 {
	Foreign              = 0,
	Export               = 1,
	Param_Using          = 2,
	Param_Const          = 3,
	Param_Auto_Cast      = 4,
	Param_Ellipsis       = 5,
	Param_C_Vararg       = 6,
	Param_No_Alias       = 7,
	Param_Any_Int        = 8,
	Param_By_Ptr         = 9,
	Param_No_Broadcast   = 10,
	Bit_Field_Field      = 19,
	Type_Alias           = 20,
	Builtin_Pkg_Builtin  = 30,
	Builtin_Pkg_Intrinsics = 31,
	Var_Thread_Local     = 40,
	Var_Static           = 41,
	Private              = 50,
}

// Doc_Entity represents an entity in the binary format
// C++ Reference: OdinDocEntity
Doc_Entity :: struct {
	kind:              Doc_Entity_Kind,
	reserved:          u32,
	flags:             u64,
	pos:               Doc_Position,
	name:              Doc_String,
	type:              Doc_Type_Index,
	init_string:       Doc_String,
	reserved_for_init: u32,
	comment:           Doc_String,
	docs:              Doc_String,
	field_group_index: i32,
	foreign_library:   Doc_Entity_Index,
	link_name:         Doc_String,
	attributes:        Doc_Array(Doc_Attribute),
	grouped_entities:  Doc_Array(Doc_Entity_Index),
	where_clauses:     Doc_Array(Doc_String),
}

// Doc_Pkg_Flags represents package flags
// C++ Reference: OdinDocPkgFlags
Doc_Pkg_Flag :: enum u32 {
	Builtin = 0,
	Runtime = 1,
	Init    = 2,
}
Doc_Pkg_Flags :: bit_set[Doc_Pkg_Flag; u32]

// Doc_Scope_Entry represents an exported scope entry
// C++ Reference: OdinDocScopeEntry
Doc_Scope_Entry :: struct {
	name:   Doc_String,
	entity: Doc_Entity_Index,
}

// Doc_Pkg represents a package in the binary format
// C++ Reference: OdinDocPkg
Doc_Pkg :: struct {
	fullpath: Doc_String,
	name:     Doc_String,
	flags:    u32,
	docs:     Doc_String,
	files:    Doc_Array(Doc_File_Index),
	entries:  Doc_Array(Doc_Scope_Entry),
}

// Doc_Header is the complete header for .odin-doc files
// C++ Reference: OdinDocHeader
Doc_Header :: struct {
	base:     Doc_Header_Base,
	files:    Doc_Array(Doc_File),
	pkgs:     Doc_Array(Doc_Pkg),
	entities: Doc_Array(Doc_Entity),
	types:    Doc_Array(Doc_Type),
}

// ======================================================================================
// WRITER STATE AND TRACKING
// C++ Reference: docs_writer.cpp:1-45
// ======================================================================================

// Item_Tracker tracks size and offset for a category of items
// C++ Reference: OdinDocWriterItemTracker<T>
Item_Tracker :: struct($T: typeid) {
	len:    int,
	cap:    int,
	offset: int,
}

// Doc_Writer_State represents the current writing phase
// C++ Reference: OdinDocWriterState
Doc_Writer_State :: enum {
	Preparing, // First pass: calculate sizes
	Writing,   // Second pass: write data
}

// Doc_Writer is the main writer state
// C++ Reference: OdinDocWriter
Doc_Writer :: struct {
	info:   ^Checker_Info,
	state:  Doc_Writer_State,

	// Output buffer
	data:     []u8,
	header:   ^Doc_Header,

	// Caches for deduplication
	string_cache: map[string]Doc_String,
	file_cache:   map[^ast.File]Doc_File_Index,
	pkg_cache:    map[^ast.Package]Doc_Pkg_Index,
	entity_cache: map[^Entity]Doc_Entity_Index,

	// INSERTION ORDER for entity_cache. LEDGER #490.
	//
	// C++ Reference: docs_writer.cpp:30-33 -- file_cache, pkg_cache, entity_cache and type_cache
	// are all `OrderedInsertPtrMap`, i.e. iterating them yields INSERTION order. The port declared
	// them as plain Odin maps, whose iteration order is unordered (and address-seeded), so
	// iterating entity_cache gave a different order on the sizing pass than on the writing pass.
	//
	// That order decides which member of a canonical-hash COLLISION gets written: `untyped rune`
	// and `rune` hash identically by design (the canonical writer resolves through default_type),
	// so whichever is visited first wins and the other returns its index -- and the two write
	// different NAME strings. Different winner between passes => the strings section needs a
	// different byte count than was measured => overflow (#489).
	//
	// entity_cache is the only one of the four the port actually ITERATES, so it is the only one
	// that needs the ordering today. Kept beside the map rather than replacing it so lookups stay
	// O(1), which is what OrderedInsertPtrMap gives C++ too.
	entity_order: [dynamic]^Entity,
	type_cache:   map[u64]Doc_Type_Index, // Key is type hash

	// Item trackers
	files:    Item_Tracker(Doc_File),
	pkgs:     Item_Tracker(Doc_Pkg),
	entities: Item_Tracker(Doc_Entity),
	types:    Item_Tracker(Doc_Type),
	strings:  Item_Tracker(u8),
	blob:     Item_Tracker(u8),
}

// ======================================================================================
// WRITER INITIALIZATION AND CLEANUP
// C++ Reference: docs_writer.cpp:47-85
// ======================================================================================

// doc_writer_init initializes a Doc_Writer
doc_writer_init :: proc(w: ^Doc_Writer, info: ^Checker_Info) {
	w.info = info
	w.state = .Preparing

	w.string_cache = make(map[string]Doc_String)
	w.file_cache = make(map[^ast.File]Doc_File_Index)
	w.pkg_cache = make(map[^ast.Package]Doc_Pkg_Index)
	w.entity_cache = make(map[^Entity]Doc_Entity_Index)
	w.entity_order = make([dynamic]^Entity)
	w.type_cache = make(map[u64]Doc_Type_Index)

	// Initialize trackers with capacity 1
	w.files = Item_Tracker(Doc_File){len = 1, cap = 1}
	w.pkgs = Item_Tracker(Doc_Pkg){len = 1, cap = 1}
	w.entities = Item_Tracker(Doc_Entity){len = 1, cap = 1}
	w.types = Item_Tracker(Doc_Type){len = 1, cap = 1}
	w.strings = Item_Tracker(u8){len = 16, cap = 16}
	w.blob = Item_Tracker(u8){len = 16, cap = 16}
}

// doc_writer_destroy cleans up a Doc_Writer
doc_writer_destroy :: proc(w: ^Doc_Writer) {
	if w.data != nil {
		delete(w.data)
	}
	delete(w.string_cache)
	delete(w.file_cache)
	delete(w.pkg_cache)
	delete(w.entity_cache)
	delete(w.entity_order)
	delete(w.type_cache)
}

// ======================================================================================
// SIZE CALCULATION AND ALLOCATION
// C++ Reference: docs_writer.cpp:88-130
// ======================================================================================

// calc_tracker_size updates offset for a tracker and returns new offset
calc_tracker_size :: proc(offset: ^int, t: ^Item_Tracker($T), alignment := 1) {
	item_size := size_of(T)
	item_align := max(align_of(T), alignment)

	// Align offset
	offset^ = mem.align_forward_int(offset^, item_align)
	t.offset = offset^
	offset^ += t.cap * item_size
}

// doc_writer_calc_total_size calculates total buffer size needed
doc_writer_calc_total_size :: proc(w: ^Doc_Writer) -> int {
	total_size := size_of(Doc_Header)
	calc_tracker_size(&total_size, &w.files)
	calc_tracker_size(&total_size, &w.pkgs)
	calc_tracker_size(&total_size, &w.entities)
	calc_tracker_size(&total_size, &w.types)
	calc_tracker_size(&total_size, &w.strings, 16)
	calc_tracker_size(&total_size, &w.blob, 16)
	return total_size
}

// doc_writer_start_writing transitions to writing state and allocates buffer
doc_writer_start_writing :: proc(w: ^Doc_Writer) {
	w.state = .Writing

	// Clear caches for second pass
	clear(&w.string_cache)
	clear(&w.file_cache)
	clear(&w.pkg_cache)
	clear(&w.entity_cache)
	clear(&w.entity_order)
	clear(&w.type_cache)

	// Allocate output buffer
	total_size := doc_writer_calc_total_size(w)
	total_size = mem.align_forward_int(total_size, 8)
	w.data = make([]u8, total_size)
	w.header = cast(^Doc_Header)raw_data(w.data)
}

// hash_data_after_header computes FNV-1a hash of data after header
hash_data_after_header :: proc(data: []u8, header_size: u32) -> u32 {
	h: u32 = 0x811c9dc5
	for b in data[header_size:] {
		h = (h ~ u32(b)) * 0x01000193
	}
	return h
}

// doc_writer_end_writing finalizes the header
doc_writer_end_writing :: proc(w: ^Doc_Writer) {
	h := w.header

	// Write magic string
	copy(h.base.magic[:], ODIN_DOC_MAGIC_STRING)

	// Write version
	h.base.version = Doc_Version{
		major = ODIN_DOC_VERSION_MAJOR,
		minor = ODIN_DOC_VERSION_MINOR,
		patch = ODIN_DOC_VERSION_PATCH,
	}

	// Write sizes
	h.base.total_size = u32(len(w.data))
	h.base.header_size = u32(size_of(Doc_Header))

	// Compute hash
	h.base.hash = hash_data_after_header(w.data, h.base.header_size)

	// Write array offsets
	h.files = Doc_Array(Doc_File){offset = u32(w.files.offset), length = u32(w.files.len)}
	h.pkgs = Doc_Array(Doc_Pkg){offset = u32(w.pkgs.offset), length = u32(w.pkgs.len)}
	h.entities = Doc_Array(Doc_Entity){offset = u32(w.entities.offset), length = u32(w.entities.len)}
	h.types = Doc_Array(Doc_Type){offset = u32(w.types.offset), length = u32(w.types.len)}
}

// ======================================================================================
// ITEM WRITING HELPERS
// C++ Reference: docs_writer.cpp:163-230
// ======================================================================================

// doc_write_item writes an item and returns its index
doc_write_item :: proc(w: ^Doc_Writer, t: ^Item_Tracker($T), item: ^T) -> u32 {
	if w.state == .Preparing {
		t.cap += 1
		return 0
	}

	assert(t.len < t.cap, "Item tracker overflow")
	item_index := t.len
	t.len += 1

	if item != nil {
		dst := cast(^T)(raw_data(w.data[t.offset + size_of(T) * item_index:]))
		dst^ = item^
	}

	return u32(item_index)
}

// doc_get_item gets an item by index
doc_get_item :: proc(w: ^Doc_Writer, t: ^Item_Tracker($T), index: u32) -> ^T {
	if w.state != .Writing {
		return nil
	}
	assert(int(index) < t.len)
	return cast(^T)(raw_data(w.data[t.offset + size_of(T) * int(index):]))
}

// doc_write_string_without_cache writes a string and neither consults nor populates the cache.
// C++ Reference: docs_writer.cpp odin_doc_write_string_without_cache.
doc_write_string_without_cache :: proc(w: ^Doc_Writer, str: string) -> Doc_String {
	if w.state == .Preparing {
		w.strings.cap += len(str) + 1
		return {}
	}

	assert(w.strings.len + len(str) + 1 <= w.strings.cap)

	offset := w.strings.offset + w.strings.len
	copy(w.data[offset:], str)
	w.data[offset + len(str)] = 0
	w.strings.len += len(str) + 1

	return Doc_String{offset = u32(offset), length = u32(len(str))}
}

// doc_write_string writes a string with caching
// C++ Reference: docs_writer.cpp odin_doc_write_string
doc_write_string :: proc(w: ^Doc_Writer, str: string) -> Doc_String {
	// Check cache
	if cached, found := w.string_cache[str]; found {
		return cached
	}

	result := doc_write_string_without_cache(w, str)
	w.string_cache[str] = result
	return result
}

// doc_write_slice writes a slice to the blob section
doc_write_slice :: proc(w: ^Doc_Writer, data: []$T) -> Doc_Array(T) {
	if len(data) <= 0 {
		return {}
	}

	alignment :: 4

	if w.state == .Preparing {
		w.blob.cap = mem.align_forward_int(w.blob.cap, alignment)
		w.blob.cap += len(data) * size_of(T)
		return {}
	}

	w.blob.len = mem.align_forward_int(w.blob.len, alignment)
	offset := w.blob.offset + w.blob.len

	dst_bytes := w.data[offset:]
	src_bytes := slice.bytes_from_ptr(raw_data(data), len(data) * size_of(T))
	copy(dst_bytes, src_bytes)

	w.blob.len += len(data) * size_of(T)

	return Doc_Array(T){offset = u32(offset), length = u32(len(data))}
}

// doc_write_item_as_slice writes a single item as a slice
doc_write_item_as_slice :: proc(w: ^Doc_Writer, item: $T) -> Doc_Array(T) {
	items := [1]T{item}
	return doc_write_slice(w, items[:])
}

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// basic_type_name returns the name string for a basic type
// C++ Reference: docs_format.cpp basic type name handling
basic_type_name :: proc(type: ^Type) -> string {
	basic, is_basic := type.variant.(Type_Basic)
	if !is_basic {
		return ""
	}

	// Return the name based on the kind
	#partial switch basic.kind {
	case .Invalid:
		// C++ Reference: types.cpp:484 -- the basic-type table's entry for Basic_Invalid carries
		// `STR_LIT("invalid type")`, and odin_doc_type writes `type->Basic.name` unconditionally,
		// so the reference records that text rather than a blank. It is REACHED in ordinary code:
		// a PROC GROUP's entity type is t_invalid, so every `proc{...}` in a documented package
		// hits this arm. MEASURED on core/unicode/utf8, where the oracle documents decode_rune's
		// type as `invalid type` and the port left it empty.
		return "invalid type"
	case .Llvm_Bool:
		return "llvm bool"
	case .Bool:
		return "bool"
	case .B8:
		return "b8"
	case .B16:
		return "b16"
	case .B32:
		return "b32"
	case .B64:
		return "b64"
	case .I8:
		return "i8"
	case .U8:
		return "u8"
	case .I16:
		return "i16"
	case .U16:
		return "u16"
	case .I32:
		return "i32"
	case .U32:
		return "u32"
	case .I64:
		return "i64"
	case .U64:
		return "u64"
	case .I128:
		return "i128"
	case .U128:
		return "u128"
	case .Rune:
		return "rune"
	case .F16:
		return "f16"
	case .F32:
		return "f32"
	case .F64:
		return "f64"
	case .Complex32:
		return "complex32"
	case .Complex64:
		return "complex64"
	case .Complex128:
		return "complex128"
	case .Quaternion64:
		return "quaternion64"
	case .Quaternion128:
		return "quaternion128"
	case .Quaternion256:
		return "quaternion256"
	case .Int:
		return "int"
	case .Uint:
		return "uint"
	case .Uintptr:
		return "uintptr"
	case .Rawptr:
		return "rawptr"
	case .String:
		return "string"
	case .Cstring:
		return "cstring"
	case .String16:
		return "string16"
	case .Cstring16:
		return "cstring16"
	case .Any:
		return "any"
	case .Typeid:
		return "typeid"
	case .I16le:
		return "i16le"
	case .U16le:
		return "u16le"
	case .I32le:
		return "i32le"
	case .U32le:
		return "u32le"
	case .I64le:
		return "i64le"
	case .U64le:
		return "u64le"
	case .I128le:
		return "i128le"
	case .U128le:
		return "u128le"
	case .I16be:
		return "i16be"
	case .U16be:
		return "u16be"
	case .I32be:
		return "i32be"
	case .U32be:
		return "u32be"
	case .I64be:
		return "i64be"
	case .U64be:
		return "u64be"
	case .I128be:
		return "i128be"
	case .U128be:
		return "u128be"
	case .F16le:
		return "f16le"
	case .F32le:
		return "f32le"
	case .F64le:
		return "f64le"
	case .F16be:
		return "f16be"
	case .F32be:
		return "f32be"
	case .F64be:
		return "f64be"
	case .Untyped_Bool:
		return "untyped bool"
	case .Untyped_Integer:
		return "untyped integer"
	case .Untyped_Float:
		return "untyped float"
	case .Untyped_Complex:
		return "untyped complex"
	case .Untyped_Quaternion:
		return "untyped quaternion"
	case .Untyped_String:
		return "untyped string"
	case .Untyped_Rune:
		return "untyped rune"
	case .Untyped_Nil:
		return "untyped nil"
	case .Untyped_Uninit:
		return "---"
	}
	return ""
}

// get_calling_convention_name returns the string name for a calling convention
// C++ Reference: docs_format.cpp calling convention string handling
get_calling_convention_name :: proc(cc: Calling_Convention) -> string {
	switch cc {
	case .Preserve_None:
		return "preserve/none"
	case .Preserve_Most:
		return "preserve/most"
	case .Preserve_All:
		return "preserve/all"
	case .Invalid:
		return "invalid"
	case .Odin:
		return "odin"
	case .Contextless:
		return "contextless"
	case .C:
		return "cdecl"
	case .Std:
		return "stdcall"
	case .Fast:
		return "fastcall"
	case .None:
		return "none"
	case .Naked:
		return "naked"
	case .Inline_Asm:
		return "inlineasm"
	case .Win64:
		return "win64"
	case .SysV:
		return "system_v"
	}
	return ""
}

// is_type_alias checks if an entity is a type alias
// C++ Reference: Entity.TypeName.is_type_alias
is_type_alias :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}
	if type_name, is_type_name := e.variant.(Entity_Type_Name); is_type_name {
		return type_name.is_type_alias
	}
	return false
}

// doc_append_comment_group_string appends a rendered comment group to buf and reports whether it
// wrote anything.
//
// C++ Reference: docs_writer.cpp odin_doc_append_comment_group_string. Split out from
// doc_write_comment_group because the reference has the same split, and the PACKAGE doc string
// (odin_doc_pkg_doc_string) is the caller that needs the appending form: it concatenates the
// package-declaration comment of EVERY file in the package into one buffer.
doc_append_comment_group_string :: proc(buf: ^strings.Builder, g: ^ast.Comment_Group) -> bool {
	if g == nil {
		return false
	}

	// C++ Reference: docs_writer.cpp:290-297 -- the early bail. `len` is the sum of each comment's
	// length PLUS one newline each, so `len <= g->list.count` means every comment in the group is
	// empty text. The port had no such test and would emit a run of bare newlines for that group.
	total := 0
	for comment_token in g.list {
		total += len(comment_token.text)
		total += 1 // for \n
	}
	if total <= len(g.list) {
		return false
	}

	// `count` is the number of LINES actually emitted. C++ uses it twice: to suppress leading blank
	// lines inside a block comment, and to decide whether the group gets its trailing newline.
	count := 0

	for comment_token in g.list {
		comment := comment_token.text

		// Detect comment style and strip delimiters
		slash_slash := false
		if len(comment) >= 2 {
			if comment[1] == '/' {
				// //... style
				slash_slash = true
				comment = comment[2:]
			} else if comment[1] == '*' {
				// /*...*/ style
				comment = comment[2:]
				if len(comment) >= 2 {
					comment = comment[:len(comment) - 2]
				}
			}
		}

		// Ignore the first space
		if len(comment) > 0 && comment[0] == ' ' {
			comment = comment[1:]
		}

		// Skip special comment prefixes for // style
		if slash_slash {
			if strings.has_prefix(comment, "+") {
				continue
			}
			if strings.has_prefix(comment, "@(") {
				continue
			}
		}

		// Process content
		if slash_slash {
			// Single line comment
			strings.write_string(buf, comment)
			strings.write_byte(buf, '\n')
			count += 1
		} else {
			// Multi-line comment - process line by line
			pos := 0
			for pos < len(comment) {
				end := pos
				for end < len(comment) && comment[end] != '\n' {
					end += 1
				}

				line := comment[pos:end]
				pos = end + 1

				// C++ Reference: docs_writer.cpp:335-340 -- a WHITESPACE-ONLY line is dropped while
				// nothing has been emitted yet, which is what strips the leading blank line of the
				// customary `/*\n * text\n */` layout. Once any line has been written, later blank
				// lines are kept, because inside a doc comment they are paragraph breaks.
				if len(strings.trim_space(line)) == 0 && count == 0 {
					continue
				}

				// Remove "* " prefix from block comments
				if strings.has_prefix(line, "* ") {
					line = line[2:]
				}

				strings.write_string(buf, line)
				strings.write_byte(buf, '\n')
				count += 1
			}
		}
	}

	// C++ Reference: docs_writer.cpp:362-366 -- one EXTRA newline terminates a non-empty group, so
	// a one-line doc comment renders as "text\n\n". The port trimmed every trailing newline
	// instead, which is the opposite operation: MEASURED on core/unicode/utf8, the oracle records
	// LOCB's docs as "The default lowest and highest continuation byte.\n\n" and the port recorded
	// it with no terminator at all. It matters downstream because the paragraph separator is what
	// lets a renderer concatenate groups.
	if count > 0 {
		strings.write_byte(buf, '\n')
		return true
	}
	return false
}

// doc_write_pkg_doc_string renders a package's documentation: the package-declaration doc comment
// of every file in the package, concatenated.
//
// C++ Reference: docs_writer.cpp odin_doc_pkg_doc_string --
//     for_array(i, pkg->files) { if (f->pkg_decl) { odin_doc_append_comment_group_string(&buf,
//         f->pkg_decl->PackageDecl.docs); } }
//
// FILE ORDER IS OUTPUT ORDER here, so it uses sorted_files for the same reason doc_write_docs does:
// C++ walks pkg->files, which check_create_file_scopes has already sorted by basename, while the
// port's pkg.files is a map.
doc_write_pkg_doc_string :: proc(w: ^Doc_Writer, pkg: ^ast.Package) -> Doc_String {
	if pkg == nil {
		return {}
	}

	buf := strings.builder_make()
	defer strings.builder_destroy(&buf)

	for file in sorted_files(pkg.files) {
		if file.pkg_decl != nil {
			doc_append_comment_group_string(&buf, file.pkg_decl.docs)
		}
	}

	return doc_write_string_without_cache(w, strings.to_string(buf))
}

// doc_write_comment_group serializes a comment group to a Doc_String
// C++ Reference: docs_writer.cpp odin_doc_comment_group_string
doc_write_comment_group :: proc(w: ^Doc_Writer, g: ^ast.Comment_Group) -> Doc_String {
	if g == nil {
		return {}
	}

	buf := strings.builder_make()
	defer strings.builder_destroy(&buf)
	doc_append_comment_group_string(&buf, g)

	// WRITTEN WITHOUT THE CACHE, as C++ does (odin_doc_comment_group_string calls
	// odin_doc_write_string_without_cache). Two entities with identical doc text get two spans in
	// the reference's output; sharing one span here would make the port's strings section a
	// different size from the reference's for the same input. Uncached is also what makes freeing
	// the builder safe -- nothing retains the bytes past the call, unlike doc_write_string, which
	// keeps them as a map KEY.
	return doc_write_string_without_cache(w, strings.to_string(buf))
}

// doc_write_attributes serializes entity attributes
// C++ Reference: docs_writer.cpp:370-400
doc_write_attributes :: proc(w: ^Doc_Writer, attrs: []^ast.Attribute) -> Doc_Array(Doc_Attribute) {
	if len(attrs) == 0 {
		return {}
	}

	doc_attrs := make([dynamic]Doc_Attribute)
	defer delete(doc_attrs)

	for attr in attrs {
		if attr == nil {
			continue
		}

		// Each attribute element can be an identifier or a field value
		for elem in attr.elems {
			if elem == nil {
				continue
			}

			name_str := ""
			value_expr: ^ast.Expr

			#partial switch e in elem.derived {
			case ^ast.Ident:
				name_str = e.name
			case ^ast.Field_Value:
				// @(name=value)
				if field_ident, is_ident := e.field.derived.(^ast.Ident); is_ident {
					name_str = field_ident.name
				}
				value_expr = e.value
			}

			if len(name_str) > 0 {
				append(&doc_attrs, Doc_Attribute{
					name = doc_write_string(w, name_str),
					// C++ Reference: docs_writer.cpp:459 --
					//     doc_attrib.value = odin_doc_expr_string(w, value);
					// i.e. the same `-short`-aware renderer as an initialiser, not a bare
					// expr_to_string. It also handles a nil value (an attribute with no `=`),
					// which the previous `value_str := ""` spelled out separately.
					value = doc_write_expr_string(w, value_expr),
				})
			}
		}
	}

	return doc_write_slice(w, doc_attrs[:])
}

// doc_write_where_clauses serializes where clause expressions to strings
// C++ Reference: docs_writer.cpp:402-420
doc_write_where_clauses :: proc(w: ^Doc_Writer, clauses: []^ast.Expr) -> Doc_Array(Doc_String) {
	if len(clauses) == 0 {
		return {}
	}

	doc_clauses := make([dynamic]Doc_String, 0, len(clauses))
	defer delete(doc_clauses)

	for clause in clauses {
		if clause != nil {
			// C++ Reference: docs_writer.cpp:473 -- `clauses[i] = odin_doc_expr_string(w, ...)`,
			// the `-short`-aware renderer, not a bare expr_to_string.
			append(&doc_clauses, doc_write_expr_string(w, clause))
		}
	}

	return doc_write_slice(w, doc_clauses[:])
}

// doc_write_expr_string serializes an expression to a Doc_String.
//
// C++ Reference: docs_writer.cpp odin_doc_expr_string --
//     gbString s = write_expr_to_string(..., expr,
//         use_shorthand || (build_context.cmd_doc_flags & CmdDocFlag_Short));
//
// THE `-short` TERM WAS MISSING. This was `doc_write_init_string`, which always called the long
// renderer, so `odin doc -short -doc-format` produced the same expression text as an unflagged run
// for initialisers, attribute values and where clauses alike. That is the BINARY-writer half of the
// same defect tick 227 fixed in the plain-text printer (FIX 9): there the flag was a defaulted
// parameter no caller passed, here the flag was simply never consulted. Both existed because no
// instrument could see the flag's effect.
//
// `use_shorthand` is the caller's own override, ORed rather than substituted -- an oversized
// compound literal is rendered short whether or not the flag is set.
doc_write_expr_string :: proc(w: ^Doc_Writer, expr: ^ast.Node, use_shorthand := false) -> Doc_String {
	if expr == nil {
		return {}
	}
	short := use_shorthand || .Short in build_context.cmd_doc_flags
	s := short ? expr_to_string_shorthand(expr) : expr_to_string(expr)
	// NOT freed, deliberately: doc_write_string stores the string as a KEY in w.string_cache, so
	// the bytes must outlive this call. C++ interns for the same reason (string_intern_string).
	return doc_write_string(w, s)
}

// ======================================================================================
// TYPE SERIALIZATION
// C++ Reference: docs_writer.cpp:480-765
// ======================================================================================

// doc_type_as_slice writes a type and returns it as a slice reference
doc_type_as_slice :: proc(w: ^Doc_Writer, type: ^Type, use_cache := true) -> Doc_Array(Doc_Type_Index) {
	index := doc_write_type(w, type, use_cache)
	return doc_write_item_as_slice(w, index)
}

// doc_write_type serializes a type and returns its index
doc_write_type :: proc(w: ^Doc_Writer, type: ^Type, use_cache := true) -> Doc_Type_Index {
	if type == nil {
		return 0
	}

	// Handle type aliases - use local variable to avoid modifying parameter
	type := type
	if named, is_named := type.variant.(Type_Named); is_named {
		if named.type_name != nil && is_type_alias(named.type_name) {
			type = named.base
		}
	}

	// Check cache
	type_hash: u64
	if use_cache {
		type_hash = type_hash_canonical_type(type)
		if cached, found := w.type_cache[type_hash]; found {
			return cached
		}
	}

	// Write type
	doc_type: Doc_Type
	type_index := doc_write_item(w, &w.types, &doc_type)

	if use_cache {
		w.type_cache[type_hash] = type_index
	}

	// Populate type based on kind
	#partial switch v in type.variant {
	case Type_Basic:
		doc_type.kind = .Basic
		doc_type.name = doc_write_string(w, basic_type_name(type))
		if is_type_untyped(type) {
			doc_type.flags |= u32(Doc_Type_Flag_Basic.Untyped)
		}

	case Type_Named:
		doc_type.kind = .Named
		doc_type.name = doc_write_string(w, v.name)
		doc_type.types = doc_type_as_slice(w, base_type(type))
		doc_type.entities = doc_entity_as_slice(w, v.type_name)

	case Type_Generic:
		name := v.name
		if v.entity != nil {
			name = v.entity.token.text
		}
		doc_type.kind = .Generic
		doc_type.name = doc_write_string(w, name)
		if v.specialized != nil {
			doc_type.types = doc_type_as_slice(w, v.specialized, false)
		}

	case Type_Pointer:
		doc_type.kind = .Pointer
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Multi_Pointer:
		doc_type.kind = .Multi_Pointer
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Soa_Pointer:
		doc_type.kind = .Soa_Pointer
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Array:
		doc_type.kind = .Array
		doc_type.elem_count_len = 1
		doc_type.elem_counts[0] = v.count
		// C++ Reference: docs_writer.cpp:565-573 -- when the count is POLYMORPHIC (`[$N]T`) the
		// reference writes TWO types, element then generic count, and docs_format.cpp:166 documents
		// the slot ("1=generic index (if exists)"). The port always wrote one, so a polymorphic
		// array's count parameter was absent from the documentation. Upstream commit
		// "Add generic count of arrays to to doc-format", which is part of format 0.3.2.
		if v.generic_count != nil {
			types := [2]Doc_Type_Index{
				doc_write_type(w, v.elem),
				doc_write_type(w, v.generic_count),
			}
			doc_type.types = doc_write_slice(w, types[:])
		} else {
			doc_type.types = doc_type_as_slice(w, v.elem)
		}

	case Type_Fixed_Capacity_Dynamic_Array:
		// C++ Reference: docs_writer.cpp:596-608. Absent from the port entirely -- see the note on
		// Doc_Type_Kind.Fixed_Capacity_Dynamic_Array. Same shape as the Array arm above: the
		// capacity is elem_counts[0], and a polymorphic capacity (`[dynamic; $N]T`) adds itself as
		// a second type.
		doc_type.kind = .Fixed_Capacity_Dynamic_Array
		doc_type.elem_count_len = 1
		doc_type.elem_counts[0] = v.capacity
		if v.generic_capacity != nil {
			types := [2]Doc_Type_Index{
				doc_write_type(w, v.elem),
				doc_write_type(w, v.generic_capacity),
			}
			doc_type.types = doc_write_slice(w, types[:])
		} else {
			doc_type.types = doc_type_as_slice(w, v.elem)
		}

	case Type_Enumerated_Array:
		doc_type.kind = .Enumerated_Array
		doc_type.elem_count_len = 1
		doc_type.elem_counts[0] = v.count
		types := [2]Doc_Type_Index{
			doc_write_type(w, v.index),
			doc_write_type(w, v.elem),
		}
		doc_type.types = doc_write_slice(w, types[:])

	case Type_Slice:
		doc_type.kind = .Slice
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Dynamic_Array:
		doc_type.kind = .Dynamic_Array
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Map:
		doc_type.kind = .Map
		types := [2]Doc_Type_Index{
			doc_write_type(w, v.key),
			doc_write_type(w, v.value),
		}
		doc_type.types = doc_write_slice(w, types[:])

	case Type_Struct:
		if v.soa_kind != .None {
			#partial switch v.soa_kind {
			case .Fixed:
				doc_type.kind = .SOA_Struct_Fixed
				doc_type.elem_count_len = 1
				doc_type.elem_counts[0] = v.soa_count
			case .Slice:
				doc_type.kind = .SOA_Struct_Slice
			case .Dynamic:
				doc_type.kind = .SOA_Struct_Dynamic
			}
			doc_type.types = doc_type_as_slice(w, v.soa_elem)
		} else {
			doc_type.kind = .Struct
			if v.is_polymorphic {
				doc_type.flags |= u32(Doc_Type_Flag_Struct.Polymorphic)
			}
			if v.is_packed {
				doc_type.flags |= u32(Doc_Type_Flag_Struct.Packed)
			}
			if v.is_raw_union {
				doc_type.flags |= u32(Doc_Type_Flag_Struct.Raw_Union)
			}
			// C++ Reference: docs_writer.cpp:640 --
			//     if (type->Struct.is_all_or_none) { doc_type.flags |= ..._all_or_none; }
			// The bit is DECLARED on both sides (Doc_Type_Flag_Struct.All_Or_None) and was assigned
			// on neither here: the #479/#480 shape, a doc flag that no input could ever set.
			if v.is_all_or_none {
				doc_type.flags |= u32(Doc_Type_Flag_Struct.All_Or_None)
			}

			// C++ Reference: docs_writer.cpp:642-646 -- the custom field-alignment pair, which
			// docs_format.cpp:153 documents as `.Struct - <=2 count: 0=min_field_align,
			// 1=max_field_align`. The port never set elem_count_len for a struct at all, so
			// `#min_field_align`/`#max_field_align` were invisible in the documentation.
			// The guard is C++'s: the counts are written only when at least one is positive, so an
			// ordinary struct keeps elem_count_len == 0 rather than gaining a `[0,0]`.
			if v.custom_min_field_align > 0 || v.custom_max_field_align > 0 {
				doc_type.elem_count_len = 2
				doc_type.elem_counts[0] = max(v.custom_min_field_align, 0)
				doc_type.elem_counts[1] = max(v.custom_max_field_align, 0)
			}

			// Write fields
			fields := make([dynamic]Doc_Entity_Index, 0, len(v.fields))
			defer delete(fields)
			for field in v.fields {
				append(&fields, doc_write_entity(w, field))
			}
			doc_type.entities = doc_write_slice(w, fields[:])
			doc_type.polymorphic_params = doc_write_type(w, v.polymorphic_params)

			// Write where clauses from the AST node
			if v.node != nil {
				if struct_type, is_struct := v.node.derived.(^ast.Struct_Type); is_struct {
					// C++ Reference: docs_writer.cpp:657-659 -- `if (st->align) { doc_type
					// .custom_align = odin_doc_expr_string(w, st->align); }`, immediately before
					// the where clauses. The port wrote only the where clauses, so `#align(N)` on
					// a struct never reached the documentation even though Doc_Type.custom_align
					// exists for exactly this and docs_format.cpp:144 marks it "Used By: .Struct,
					// .Union".
					if struct_type.align != nil {
						doc_type.custom_align = doc_write_expr_string(w, struct_type.align)
					}
					doc_type.where_clauses = doc_write_where_clauses(w, struct_type.where_clauses)
				}
			}

			// C++ Reference: docs_writer.cpp:663-673 -- the tags array is sized to
			// `type->Struct.fields.count` and written UNCONDITIONALLY; when the struct carries no
			// tags at all the reference still emits one BLANK string per field. The port wrote the
			// array only when tags existed, so `tags.length` was 0 where the reference says N, and
			// a consumer indexing tags[i] alongside fields[i] would run off the end.
			// The port's `tags` is parallel to `fields` when populated, so the loop is over the
			// FIELD count either way, exactly as C++'s is.
			tag_strs := make([dynamic]Doc_String, 0, len(v.fields))
			defer delete(tag_strs)
			for i in 0 ..< len(v.fields) {
				tag := ""
				if i < len(v.tags) {
					tag = v.tags[i]
				}
				append(&tag_strs, doc_write_string(w, tag))
			}
			doc_type.tags = doc_write_slice(w, tag_strs[:])
		}

	case Type_Union:
		doc_type.kind = .Union
		if v.is_polymorphic {
			doc_type.flags |= u32(Doc_Type_Flag_Union.Polymorphic)
		}
		#partial switch v.kind {
		case .No_Nil:
			doc_type.flags |= u32(Doc_Type_Flag_Union.No_Nil)
		case .Shared_Nil:
			doc_type.flags |= u32(Doc_Type_Flag_Union.Shared_Nil)
		}

		variants := make([dynamic]Doc_Type_Index, 0, len(v.variants))
		defer delete(variants)
		for variant in v.variants {
			append(&variants, doc_write_type(w, variant))
		}
		doc_type.types = doc_write_slice(w, variants[:])
		doc_type.polymorphic_params = doc_write_type(w, v.polymorphic_params)

		// Write where clauses from the AST node
		if v.node != nil {
			if union_type, is_union := v.node.derived.(^ast.Union_Type); is_union {
				// C++ Reference: docs_writer.cpp:711-716 -- the union arm writes custom_align from
				// `ut->align` before its where clauses, the same pair the struct arm writes. Both
				// halves were missing here for the same reason.
				if union_type.align != nil {
					doc_type.custom_align = doc_write_expr_string(w, union_type.align)
				}
				doc_type.where_clauses = doc_write_where_clauses(w, union_type.where_clauses)
			}
		}

	case Type_Enum:
		doc_type.kind = .Enum
		fields := make([dynamic]Doc_Entity_Index, 0, len(v.fields))
		defer delete(fields)
		for field in v.fields {
			append(&fields, doc_write_entity(w, field))
		}
		doc_type.entities = doc_write_slice(w, fields[:])
		if v.base_type != nil {
			doc_type.types = doc_type_as_slice(w, v.base_type)
		}

	case Type_Tuple:
		doc_type.kind = .Tuple
		vars := make([dynamic]Doc_Entity_Index, 0, len(v.variables))
		defer delete(vars)
		for variable in v.variables {
			append(&vars, doc_write_entity(w, variable))
		}
		doc_type.entities = doc_write_slice(w, vars[:])

	case Type_Proc:
		doc_type.kind = .Proc
		if v.is_polymorphic {
			doc_type.flags |= u32(Doc_Type_Flag_Proc.Polymorphic)
		}
		if v.diverging {
			doc_type.flags |= u32(Doc_Type_Flag_Proc.Diverging)
		}
		if v.optional_ok {
			doc_type.flags |= u32(Doc_Type_Flag_Proc.Optional_Ok)
		}
		if v.variadic {
			doc_type.flags |= u32(Doc_Type_Flag_Proc.Variadic)
		}
		if v.c_vararg {
			doc_type.flags |= u32(Doc_Type_Flag_Proc.C_Vararg)
		}

		types := [2]Doc_Type_Index{
			doc_write_type(w, v.params),
			doc_write_type(w, v.results),
		}
		doc_type.types = doc_write_slice(w, types[:])
		doc_type.calling_convention = doc_write_string(w, get_calling_convention_name(v.calling_convention))
		// NO where_clauses HERE, DELIBERATELY. C++ Reference: docs_writer.cpp:745-761, the whole
		// Type_Proc arm -- it writes flags, the two types and the calling convention, and nothing
		// else. docs_format.cpp:197 scopes the field to ".Struct, .Union" and puts a procedure's
		// where clauses on the ENTITY instead. The port wrote them onto the TYPE from the Proc_Lit,
		// which put data in a slot no reader of this format looks at for a proc, and made the type
		// table disagree with the reference for every `where`-constrained procedure.

	case Type_Bit_Set:
		doc_type.kind = .Bit_Set
		type_count := 0
		types: [2]Doc_Type_Index
		if v.elem != nil {
			types[type_count] = doc_write_type(w, v.elem)
			type_count += 1
		}
		if v.underlying != nil {
			types[type_count] = doc_write_type(w, v.underlying)
			type_count += 1
			doc_type.flags |= u32(Doc_Type_Flag_BitSet.Underlying_Type)
		}
		doc_type.types = doc_write_slice(w, types[:type_count])
		doc_type.elem_count_len = 2
		doc_type.elem_counts[0] = v.lower
		doc_type.elem_counts[1] = v.upper

	case Type_Simd_Vector:
		doc_type.kind = .Simd_Vector
		doc_type.elem_count_len = 1
		doc_type.elem_counts[0] = v.count
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Matrix:
		doc_type.kind = .Matrix
		doc_type.elem_count_len = 2
		doc_type.elem_counts[0] = v.row_count
		doc_type.elem_counts[1] = v.column_count
		doc_type.types = doc_type_as_slice(w, v.elem)

	case Type_Bit_Field:
		doc_type.kind = .Bit_Field
		fields := make([dynamic]Doc_Entity_Index, 0, len(v.fields))
		defer delete(fields)
		for field in v.fields {
			append(&fields, doc_write_entity(w, field))
		}
		doc_type.entities = doc_write_slice(w, fields[:])
		doc_type.types = doc_type_as_slice(w, v.backing_type)
	}

	// Update the written item
	dst := doc_get_item(w, &w.types, type_index)
	if dst != nil {
		dst^ = doc_type
	}

	return type_index
}

// ======================================================================================
// ENTITY SERIALIZATION
// C++ Reference: docs_writer.cpp:767-940
// ======================================================================================

// doc_entity_as_slice writes an entity and returns it as a slice reference
doc_entity_as_slice :: proc(w: ^Doc_Writer, e: ^Entity) -> Doc_Array(Doc_Entity_Index) {
	index := doc_write_entity(w, e)
	return doc_write_item_as_slice(w, index)
}

// doc_write_entity serializes an entity and returns its index
doc_write_entity :: proc(w: ^Doc_Writer, e: ^Entity) -> Doc_Entity_Index {
	if e == nil {
		return 0
	}

	// Check cache
	if cached, found := w.entity_cache[e]; found {
		return cached
	}

	// Check if package is being documented
	if e.pkg != nil && e.pkg not_in w.pkg_cache {
		return 0
	}

	doc_entity: Doc_Entity
	entity_index := doc_write_item(w, &w.entities, &doc_entity)
	w.entity_cache[e] = entity_index
	append(&w.entity_order, e)

	// Determine entity kind
	kind: Doc_Entity_Kind
	flags: u64
	// C++ Reference: docs_writer.cpp:850 -- `i32 field_group_index = -1;`. The port had NO
	// assignment to doc_entity.field_group_index anywhere, so every entity in every .odin-doc file
	// carried 0 -- which is a MEANINGFUL value (the first field group), not a blank. MEASURED with
	// triage_docbin on core/unicode/utf8: the oracle emits -1 for entities that have no group and
	// 0/1/2/... for the ones that do; the port emitted 0 for all 158.
	field_group_index: i32 = -1
	// C++ zeroes pos for Entity_Builtin (docs_writer.cpp:897). Recorded here and applied below,
	// because the port computes pos AFTER the kind switch rather than inside it. The name is
	// carried out of the switch the same way, and for the same reason.
	is_builtin_entity := false
	builtin_name := ""
	#partial switch e.kind {
	case .Constant:
		kind = .Constant
		// C++ Reference: docs_writer.cpp:891 -- `field_group_index = e->Constant.field_group_index;`
		if const_v, const_ok := e.variant.(Entity_Constant); const_ok {
			field_group_index = const_v.field_group_index
		}
	case .Variable:
		kind = .Variable
		// C++ Reference: docs_writer.cpp:871-872 --
		//     if (e->Variable.is_foreign) { flags |= OdinDocEntityFlag_Foreign; }
		//     if (e->Variable.is_export)  { flags |= OdinDocEntityFlag_Export;  }
		// LEDGER #479. These were read from INVENTED entity FLAGS (.Foreign/.Export) in the
		// "common flags" block below, and nothing ever set them, so both doc bits were
		// unreachable. C++ keeps the fact on the VARIANT, and so does the port -- is_foreign is
		// set at check_collect.odin:1100, is_export at check_decl.odin:249. The data was there;
		// only the read was wrong. Note C++ does this PER VARIANT inside the kind switch, not as
		// a common flag, because only Variable and Procedure carry the fields.
		if var_v, var_ok := &e.variant.(ast.Entity_Variable); var_ok {
			if var_v.is_foreign {
				flags |= 1 << u64(Doc_Entity_Flag.Foreign)
			}
			if var_v.is_export {
				flags |= 1 << u64(Doc_Entity_Flag.Export)
			}
		}
		// C++ Reference: docs_writer.cpp:873-874 --
		//     if (e->Variable.thread_local_model != "") {
		//         flags |= OdinDocEntityFlag_Var_Thread_Local;
		//     }
		// LEDGER #480. Same shape as #479: the bit was DECLARED and never assigned anywhere in
		// the port, so it was unreachable. thread_local_model has always been on the variant
		// (ast.Entity_Variable), so this is a missing read, not missing data.
		if var_tl, tl_ok := &e.variant.(ast.Entity_Variable); tl_ok {
			if len(var_tl.thread_local_model) > 0 {
				flags |= 1 << u64(Doc_Entity_Flag.Var_Thread_Local)
			}
		}
		if .Static in e.flags {
			flags |= 1 << u64(Doc_Entity_Flag.Var_Static)
		}
		// C++ Reference: docs_writer.cpp:885-889 --
		//     if (e->flags & EntityFlag_BitFieldField) {
		//         field_group_index = -cast(i32)e->Variable.bit_field_bit_size;
		//     } else {
		//         field_group_index = e->Variable.field_group_index;
		//     }
		// A BIT-FIELD FIELD reuses this slot for its BIT SIZE, NEGATED -- docs_format.cpp:257 says
		// so on the field itself ("For `bit_field`s this is the \"bit_size\""). Writing the group
		// index there instead would not read as blank, it would read as a plausible wrong width.
		if var_fg, fg_ok := e.variant.(Entity_Variable); fg_ok {
			if .Bit_Field_Field in e.flags {
				field_group_index = -i32(var_fg.bit_field_bit_size)
			} else {
				field_group_index = var_fg.field_group_index
			}
		}
	case .Type_Name:
		kind = .Type_Name
		if is_type_alias(e) {
			flags |= 1 << u64(Doc_Entity_Flag.Type_Alias)
		}
	case .Procedure:
		kind = .Procedure
		// C++ Reference: docs_writer.cpp:892-893 -- same pair, from the Procedure variant.
		if proc_v, proc_ok := &e.variant.(ast.Entity_Procedure); proc_ok {
			if proc_v.is_foreign {
				flags |= 1 << u64(Doc_Entity_Flag.Foreign)
			}
			if proc_v.is_export {
				flags |= 1 << u64(Doc_Entity_Flag.Export)
			}
		}
	case .Proc_Group:
		kind = .Proc_Group
	case .Import_Name:
		kind = .Import_Name
	case .Library_Name:
		kind = .Library_Name
	case .Builtin:
		kind = .Builtin
		// C++ Reference: docs_writer.cpp:895-910. The WHOLE arm, not just the flag -- C++ also
		// zeroes the position and takes the name from the builtin PROC TABLE rather than the
		// entity token. Porting only the flag would leave the same arm half-done, which is how
		// #479 happened in the first place.
		//
		// LEDGER #480. Builtin_Pkg_Builtin and Builtin_Pkg_Intrinsics were both declared and
		// assigned NOWHERE in the port -- two more unreachable bits. C++ recovers the package by
		// looking up builtin_procs[e->Builtin.id]; the port's Entity_Builtin carries `pkg`
		// directly, so the lookup is unnecessary and the field is read straight off the variant.
		// The package must come from the TABLE, keyed by id, exactly as C++ does
		// (`builtin_procs[e->Builtin.id].pkg`).
		//
		// LEDGER #348 CORRECTS THIS COMMENT. It previously said Entity_Builtin's `pkg` field was
		// "never written, the sole constructor being entity.odin:102". Both halves were wrong:
		// alloc_entity_builtin DID write it from proc_info.pkg, and there were three other
		// construction sites. The field's real defect was that it was WRITE-ONLY (no reader made a
		// decision on it) and that one path built `Entity_Builtin{id = ...}` without it, leaving
		// the zero value `.Builtin` -- which is why reading it labelled intrinsics as Builtin.
		// The field has since been DELETED (#348); the table is the only authority, as in C++.
		if bi_v, bi_ok := &e.variant.(ast.Entity_Builtin); bi_ok {
			bp := builtin_proc_infos[bi_v.id]
			switch bp.pkg {
			case .Builtin:
				flags |= 1 << u64(Doc_Entity_Flag.Builtin_Pkg_Builtin)
			case .Intrinsics:
				flags |= 1 << u64(Doc_Entity_Flag.Builtin_Pkg_Intrinsics)
			}
			// C++ Reference: docs_writer.cpp:907 `name = bp.name;` -- the NAME comes from the
			// builtin proc table, not from e->token.string. The comment above has claimed this
			// since #479 and the code never did it; only `pos = {}` was ported. MEASURED with
			// docbin.sh on core/math/bits: intrinsics declares ALIASES onto the same builtin id,
			// so `leading_zeros` and `overflowing_add` are entity tokens whose table names are
			// `count_leading_zeros` and `overflow_add`. The oracle emits the table name for both
			// -- which is why its dump carries `count_leading_zeros` TWICE and the port's carried
			// one of each spelling.
			builtin_name = bp.name
			is_builtin_entity = true
		}
	}

	// Common flags
	// NOTE: Foreign/Export are NOT here -- C++ reads them from the Variable and Procedure
	// variants (docs_writer.cpp:871/892), which is where the port sets them too. See #479.
	// C++ Reference: docs_writer.cpp:930-932, verbatim --
	//     if (e->scope && (e->scope->flags & (ScopeFlag_File|ScopeFlag_Pkg)) && !is_entity_exported(e)) {
	//             flags |= OdinDocEntityFlag_Private;
	//     }
	// The port tested `.Not_Exported in e.flags`, which is only the FIRST of the four things
	// is_entity_exported answers. It also rejects a non-exported entity KIND (allow_builtin
	// defaults to false at this call site, so EVERY Entity_Builtin is non-exported), a file
	// carrying IsPrivatePkg/IsPrivateFile, and the single-underscore name. It also dropped the
	// scope guard entirely, so a parameter or struct field -- whose scope is neither File nor Pkg
	// -- could pick up the bit that C++ reserves for package-level declarations.
	// MEASURED with docbin.sh on core/math/bits: the oracle marks all ~30 intrinsics builtins
	// Private and the port marked none of them.
	if e.scope != nil && (.File in e.scope.flags || .Pkg in e.scope.flags) && !is_entity_exported(e) {
		flags |= 1 << u64(Doc_Entity_Flag.Private)
	}

	// Parameter flags
	if .Using in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_Using)
	}
	if .Const_Input in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_Const)
	}
	// LEDGER #477. No Param_Auto_Cast assignment here, and that MATCHES C++: src/ has no
	// EntityFlag_AutoCast and docs_writer.cpp has no corresponding `if` at all. The port had both
	// an invented entity flag and an invented read of it, so the bit could never be set anyway --
	// removing them changes no output and removes a divergence. The DOC bit itself stays declared,
	// because C++ declares it too (docs_format.cpp:225); it is simply written by neither.
	if .Ellipsis in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_Ellipsis)
	}
	// LEDGER B5-d. No Param_C_Vararg write here, and that MATCHES C++, which is the same shape as
	// the Param_Auto_Cast note above: the bit is DECLARED (docs_format.cpp:227
	// OdinDocEntityFlag_Param_CVararg) and the entity flag is declared AND set
	// (entity.cpp:62, check_type.cpp:2344) -- but docs_writer.cpp:922-928 writes exactly seven
	// param flags and CVararg is not one of them. Verified as a COMPLETE SET, not by deleting the
	// one arm that looked wrong: with this gone both sides write Using, Const, Ellipsis, NoAlias,
	// AnyInt, ByPtr, NoBroadcast -- same seven, same order.
	//
	// This is why the doc coverage counter must count `Proc(flags=C_Vararg` in the ORACLE dump and
	// never Param_C_Vararg: the doc bit is the port-only symptom, so it reads 0 in every reference
	// dump and a counter built on it reports "no coverage needed" for a corpus full of the input.
	if .No_Alias in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_No_Alias)
	}
	if .Any_Int in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_Any_Int)
	}
	if .By_Ptr in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_By_Ptr)
	}
	if .No_Broadcast in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Param_No_Broadcast)
	}
	if .Bit_Field_Field in e.flags {
		flags |= 1 << u64(Doc_Entity_Flag.Bit_Field_Field)
	}

	// Position
	pos: Doc_Position
	if file_index, found := w.file_cache[e.file]; found {
		pos.file = file_index
	}
	pos.line = u32(e.token.pos.line)
	pos.column = u32(e.token.pos.column)
	pos.offset = u32(e.token.pos.offset)
	// C++ Reference: docs_writer.cpp:897 `pos = {};` -- a builtin has no source location, so the
	// whole position (file index included) is cleared, not just the line/column.
	if is_builtin_entity {
		pos = {}
	}

	// Write entity basic fields
	doc_entity.kind = kind
	doc_entity.flags = flags
	doc_entity.pos = pos
	doc_entity.name = doc_write_string(w, is_builtin_entity ? builtin_name : e.token.text)
	doc_entity.type = 0 // Set later in update pass

	// C++ Reference: docs_writer.cpp:975 `doc_entity.link_name = odin_doc_write_string(w, link_name);`
	// sourced at :881 `link_name = e->Variable.link_name;` and :901
	// `link_name = e->Procedure.link_name;`.
	//
	// #1200. The port NEVER ASSIGNED THIS FIELD -- zero writes to doc_entity.link_name anywhere -- so
	// the doc output's link_name was always empty even though the checker records the value on the
	// entity (check_decl.odin:314 for a variable, :1544/:1564/:2368 for a procedure, fields declared
	// at ast/semantic_types.odin:528 and :577).
	// MEASURED with #1199's `docextra` line: for `@(link_name="LINKMARK_sym") lk :: proc() ---` the
	// oracle's doc contains that string TWICE (once as the attribute, once as this field) and the port
	// contained it ONCE. That second occurrence is this line.
	// Found by auditing EVERY Doc_Entity field against what the dump printed -- ten were unprinted, and
	// this is the one of them that turned out to be a real gap rather than a numeric index.
	#partial switch v in e.variant {
	case Entity_Variable:
		if len(v.link_name) > 0 {
			doc_entity.link_name = doc_write_string(w, v.link_name)
		}
	case Entity_Procedure:
		if len(v.link_name) > 0 {
			doc_entity.link_name = doc_write_string(w, v.link_name)
		}
	}

	// C++ Reference: docs_writer.cpp:825-841 plus the Variable/Constant arms of the kind switch.
	// decl_info supplies init_expr, comment and docs; the ENTITY VARIANT is the fallback for each.
	//
	// RESOLVED AS AST POINTERS FIRST, THEN WRITTEN ONCE, which is how C++ does it. The port used to
	// write from decl_info and then test the WRITTEN Doc_String against {} to decide whether to fall
	// back -- and that is not the same question. In the PREPARING pass doc_write_string returns a
	// ZERO Doc_String for every input, so the test was unconditionally true in pass 1 and
	// conditional in pass 2: the two passes sized and wrote different string sets. It only ever
	// OVER-counted (the capacity assert is `len <= cap`) so it never failed, but a sizing pass that
	// disagrees with the writing pass is exactly the #484/#489 shape and is not left standing.
	//
	// The entity-level fallback itself is #1178 / B3-f finding 7: a struct FIELD or enum MEMBER has
	// no decl_info, so without it neither its docs nor its comment were ever consulted. Precedence
	// is C++'s -- decl_info WINS, the variant fills only what decl_info left nil.
	init_expr: ^ast.Node
	comment_group: ^ast.Comment_Group
	docs_group: ^ast.Comment_Group
	if e.decl_info != nil {
		init_expr = e.decl_info.init_expr
		comment_group = e.decl_info.comment
		docs_group = e.decl_info.docs
		doc_entity.attributes = doc_write_attributes(w, e.decl_info.attributes)
	}
	#partial switch v in e.variant {
	case Entity_Variable:
		if comment_group == nil {
			comment_group = v.comment
		}
		if docs_group == nil {
			docs_group = v.docs
		}
		// C++ Reference: docs_writer.cpp:882-884 -- `if (init_expr == nullptr) { init_expr =
		// e->Variable.init_expr; }`. The port had this fallback for Constants only.
		if init_expr == nil {
			init_expr = v.init_expr
		}
	case Entity_Constant:
		if comment_group == nil {
			comment_group = v.comment
		}
		if docs_group == nil {
			docs_group = v.docs
		}
		// ENUM MEMBERS have no Decl_Info -- check_enum_type builds their entities by hand -- so
		// this is the only source of an initialiser for them. Upstream PR #7289 (merge b9bbcd33b),
		// #755.
		if init_expr == nil {
			init_expr = v.init_expr
		}
	}
	doc_entity.comment = doc_write_comment_group(w, comment_group)
	doc_entity.docs = doc_write_comment_group(w, docs_group)

	// C++ Reference: docs_writer.cpp:930-960, the init_string block IN FULL. The port had only the
	// first branch, so three sources of initialiser text were silently absent from every .odin-doc:
	//
	//   * an enum member with an explicit value, whose text comes from the CONSTANT VALUE rather
	//     than from any expression -- MEASURED on core/unicode/utf8, where the oracle records
	//     init="0".."4" for base:runtime's Allocator_Error members and the port recorded nothing;
	//   * a parameter's DEFAULT VALUE, which lives in param_value.original_ast_expr -- the oracle
	//     records init="context.allocator" for every `allocator := context.allocator` parameter;
	//   * an IMPLICIT enum value, which C++ deliberately blanks. That one is not a no-op: without
	//     it the exact-value branch below would invent `init="0"` for a member the user never gave
	//     a value to, which is worse than the omission it replaces.
	//
	// The oversized-compound-literal shorthand is C++'s too (docs_writer.cpp:934-941): a literal
	// with more than 512 elements renders short REGARDLESS of the -short flag, because the full
	// text would otherwise be unbounded.
	if init_expr != nil {
		use_shorthand := false
		if e.kind == .Variable {
			if cl, is_cl := init_expr.derived.(^ast.Comp_Lit); is_cl && len(cl.elems) > 512 {
				use_shorthand = true
			}
		}
		doc_entity.init_string = doc_write_expr_string(w, init_expr, use_shorthand)
	} else {
		#partial switch v in e.variant {
		case Entity_Constant:
			if .Implicit_Enum_Value in v.flags {
				doc_entity.init_string = {}
			} else if v.param_value.original_ast_expr != nil {
				doc_entity.init_string = doc_write_expr_string(w, v.param_value.original_ast_expr)
			} else {
				// NOT freed: doc_write_string keeps the bytes as a cache KEY. C++ interns the same
				// string for the same reason.
				doc_entity.init_string = doc_write_string(w, exact_value_to_string(v.value))
			}
		case Entity_Variable:
			if v.param_value.original_ast_expr != nil {
				doc_entity.init_string = doc_write_expr_string(w, v.param_value.original_ast_expr)
			}
		}
	}
	doc_entity.field_group_index = field_group_index

	// Update the written item
	dst := doc_get_item(w, &w.entities, entity_index)
	if dst != nil {
		dst^ = doc_entity
	}

	return entity_index
}

// doc_update_entities updates entity type references after all types are written
doc_update_entities :: proc(w: ^Doc_Writer) {
	// SNAPSHOT THE KEYS BEFORE ITERATING. LEDGER #487.
	//
	// C++ Reference: docs_writer.cpp:984-992 --
	//     // NOTE(bill): Double pass, just in case entities are created on odin_doc_type
	//     auto entities = array_make<Entity *>(heap_allocator(), 0, w->entity_cache.count);
	//     for (auto const &entry : w->entity_cache) { array_add(&entities, entry.key); }
	//     for (Entity *e : entities) { ... }
	//
	// The port used to iterate w.entity_cache LIVE, in both loops below. The second loop's body
	// calls doc_write_entity (for foreign_library and for grouped entities), and doc_write_entity
	// INSERTS into w.entity_cache -- so the map was being mutated while it was being iterated.
	// That is undefined behaviour: an insert can rehash, after which entries are revisited or
	// skipped, and the set actually walked stops being a function of the input.
	//
	// The visible cost was #484: the sizing pass and the writing pass walked DIFFERENT entity
	// sets, so the capacity computed by pass 1 did not fit what pass 2 wrote, and the item
	// tracker overflowed -- aborting ~80% of `-dump-doc` runs on core/c/libc. bill's comment
	// names the same hazard from the other direction ("just in case entities are created"), which
	// is why the reference implementation snapshots and the port must too.
	entities := make([dynamic]^Entity, 0, len(w.entity_order))
	defer delete(entities)
	append(&entities, ..w.entity_order[:])

	// First pass: ensure all entity types are written
	for e in entities {
		doc_write_type(w, e.type)
	}

	// SECOND PASS ITERATES THE LIVE CACHE, NOT THE SNAPSHOT. LEDGER #1201.
	//
	// C++ Reference: docs_writer.cpp:1006 --
	//     for (u32 i = 0; i < w->entity_cache.count; i++) {
	//         auto entry = w->entity_cache.entries[i];
	//
	// Only the FIRST loop snapshots (bill's "Double pass, just in case entities are created on
	// odin_doc_type"). The second walks the ordered map BY INDEX with `count` re-read every
	// iteration, so entities created DURING the loop are visited too -- and they always are: this
	// body calls doc_write_type, whose Enum / Struct / Tuple / Bit_Field arms call doc_write_entity
	// for every member, and it calls doc_write_entity directly for foreign_library and for each
	// member of a proc group.
	//
	// The port ran BOTH loops over the snapshot, so every entity created here kept `type = 0`.
	// MEASURED on core/unicode/utf8 with triage_docbin: the oracle writes 158 entities and 84 types,
	// the port 130 and 61, and every procedure parameter, result and enum member came out
	// `type=<none>` -- C++ asserts `type_index != 0` for exactly these (docs_writer.cpp:1046), which
	// is the reference calling this state impossible.
	//
	// Indexing rather than ranging is load-bearing: `for e in w.entity_order` evaluates the length
	// once, which is the snapshot behaviour under another spelling.
	for i := 0; i < len(w.entity_order); i += 1 {
		e := w.entity_order[i]
		entity_index := w.entity_cache[e]
		type_index := doc_write_type(w, e.type)

		foreign_library: Doc_Entity_Index
		grouped_entities: Doc_Array(Doc_Entity_Index)

		#partial switch e.kind {
		case .Variable:
			if v, is_var := e.variant.(Entity_Variable); is_var {
				foreign_library = doc_write_entity(w, v.foreign_library)
			}
		case .Procedure:
			if p, is_proc := e.variant.(Entity_Procedure); is_proc {
				foreign_library = doc_write_entity(w, p.foreign_library)
			}
		case .Proc_Group:
			if pg, is_pg := e.variant.(Entity_Proc_Group); is_pg {
				ents := make([dynamic]Doc_Entity_Index, 0, len(pg.procs))
				defer delete(ents)
				for proc_entity in pg.procs {
					append(&ents, doc_write_entity(w, proc_entity))
				}
				grouped_entities = doc_write_slice(w, ents[:])
			}
		}

		dst := doc_get_item(w, &w.entities, entity_index)
		if dst != nil {
			dst.type = type_index
			dst.foreign_library = foreign_library
			dst.grouped_entities = grouped_entities
		}
	}
}

// ======================================================================================
// PACKAGE AND SCOPE SERIALIZATION
// C++ Reference: docs_writer.cpp:1004-1053
// ======================================================================================

// doc_add_pkg_entries writes scope entries for a package
doc_add_pkg_entries :: proc(w: ^Doc_Writer, pkg: ^ast.Package) -> Doc_Array(Doc_Scope_Entry) {
	scope := get_package_scope(w.info, pkg)
	if scope == nil {
		return {}
	}

	if pkg not_in w.pkg_cache {
		return {}
	}

	entries := make([dynamic]Doc_Scope_Entry)
	defer delete(entries)

	// SLOT ORDER, not map order. LEDGER #494.
	//
	// C++ Reference: docs_writer.cpp odin_doc_add_pkg_entries --
	//     for (isize i = 0; i < pkg->scope->elements.cap; i++) {
	//         if (!pkg->scope->elements.slots[i].hash) continue;
	//         auto interned = pkg->scope->elements.keys[i];
	//         Entity *e = pkg->scope->elements.slots[i].value;
	//
	// C++ walks its ScopeMap by SLOT INDEX. This was a raw `for name, e in scope.elements`, i.e.
	// Odin map order, which is unordered and address-seeded. The order is OBSERVABLE: these
	// entries become a Doc_Array(Doc_Scope_Entry) in the output, so walk order is output order.
	// Measured before the fix, the first ten entry names differed on all four of four runs.
	//
	// scope_map_slot_order (scope.odin:965, from #214) reproduces C++'s slot layout, and three
	// sites already use it this way (check_proc.odin:944, error.odin:2010, check_stmt.odin:230).
	// The deterministic pre-sort is part of the pattern, not decoration: the slot simulation is
	// only reproducible if its INPUT order is, and map order is not.
	//
	// The name comes from the map KEY in C++ (elements.keys[i]), so it is carried alongside rather
	// than re-derived from e.token.text -- those are not guaranteed equal (see #31).
	//
	// IT WAS CARRIED IN A map[^Entity]string, WHICH CANNOT HOLD THE CASE IT EXISTS FOR. An alias
	// binds a SECOND name to an entity that already has one:
	//     core/slice/slice.odin:501  to_dynamic       :: clone_to_dynamic
	//     core/slice/sort.odin:387   is_sorted_by_cmp :: is_sorted_cmp
	// C++ has two SLOTS holding the same Entity *, reads each slot's own key, and emits two
	// entries under two names. Keyed by the entity, the port's second write replaced the first, so
	// both entries came out under whichever name the map happened to visit last -- MEASURED on
	// core/slice, where the oracle has `to_dynamic` and `is_sorted_by_cmp` and the port had
	// `clone_to_dynamic` and `is_sorted_cmp`. The slot SIMULATION had the same blind spot: it
	// hashed e.token.text, so an alias probed to the target's slot rather than its own.
	// Both are fixed by carrying (key, entity) as a pair -- scope_map_slot_order_keyed.
	// EVERY entity goes into the simulation, and the skips are applied to its OUTPUT below.
	// C++ walks the REAL table, which holds every entity in the package scope, and `continue`s past
	// the ones it does not want; the survivors therefore come out in their relative order within
	// the FULL table. Feeding only the survivors builds a different table -- different occupancy,
	// different collision chains, different growth history -- so their relative order is not the
	// same one. Filtering after the walk is what reproduces C++.
	Keyed_Entity :: struct {
		key: string,
		e:   ^Entity,
	}
	pairs := make([dynamic]Keyed_Entity, 0, len(scope.elements), context.temp_allocator)
	for name, e in scope.elements {
		if e == nil {
			continue
		}
		append(&pairs, Keyed_Entity{key = name, e = e})
	}
	// The KEY is the final tiebreak, not e.token.text: two bindings of one entity are identical in
	// every entity-derived field and would otherwise sort nondeterministically against each other.
	slice.sort_by(pairs[:], proc(a, b: Keyed_Entity) -> bool {
		if a.e.token.pos.file != b.e.token.pos.file {
			return a.e.token.pos.file < b.e.token.pos.file
		}
		if a.e.token.pos.offset != b.e.token.pos.offset {
			return a.e.token.pos.offset < b.e.token.pos.offset
		}
		if a.e.token.text != b.e.token.text {
			return a.e.token.text < b.e.token.text
		}
		return a.key < b.key
	})
	ordered := make([dynamic]^Entity, 0, len(pairs), context.temp_allocator)
	ordered_keys := make([dynamic]string, 0, len(pairs), context.temp_allocator)
	for p in pairs {
		append(&ordered, p.e)
		append(&ordered_keys, p.key)
	}

	// `scope` is a PACKAGE scope, which checker.cpp:261 reserves to `2*total_pkg_decl_count` before
	// the first insert; simulating from the 16-entry inline capacity replays the wrong growth
	// history and lays the table out differently.
	slot_keys, slot_entities := scope_map_slot_order_keyed(ordered_keys[:], ordered[:], context.temp_allocator, scope_map_initial_cap(scope))
	for e, slot_i in slot_entities {
		if e == nil {
			continue
		}

		// C++ Reference: the skips inside the slot walk, applied HERE rather than before it -- see
		// the note above the collection loop.
		#partial switch e.kind {
		case .Invalid, .Nil, .Label:
			continue
		}
		if e.pkg != pkg {
			continue
		}
		if !is_entity_exported(e, true) {
			continue
		}
		if len(e.token.text) == 0 {
			continue
		}

		entry := Doc_Scope_Entry{
			name = doc_write_string(w, slot_keys[slot_i]),
			entity = doc_write_entity(w, e),
		}
		append(&entries, entry)
	}

	return doc_write_slice(w, entries[:])
}

// ======================================================================================
// MAIN WRITE FUNCTIONS
// C++ Reference: docs_writer.cpp:1055-1175
// ======================================================================================

// doc_write_docs writes all documentation data
doc_write_docs :: proc(w: ^Doc_Writer) {
	// Collect packages to document
	pkgs := make([dynamic]^ast.Package)
	defer delete(pkgs)

	// Check if we should include all packages
	// C++ Reference: docs_writer.cpp:1065-1080
	all_packages := .All_Packages in build_context.cmd_doc_flags

	for _, pkg in w.info.packages {
		// Include package if:
		// 1. It's the init package or marked as extra (for documentation), OR
		// 2. CmdDocFlag_AllPackages is set (include all packages)
		if all_packages || pkg.kind == .Init || pkg.is_extra {
			append(&pkgs, pkg)
		}
	}

	// Sort packages by name
	slice.sort_by_cmp(pkgs[:], cmp_ast_package_by_name)

	// Write each package
	for pkg in pkgs {
		pkg_flags: u32
		#partial switch pkg.kind {
		case .Runtime:
			pkg_flags |= 1 << u32(Doc_Pkg_Flag.Runtime)
		case .Init:
			pkg_flags |= 1 << u32(Doc_Pkg_Flag.Init)
		}

		doc_pkg := Doc_Pkg{
			fullpath = doc_write_string(w, pkg.fullpath),
			name = doc_write_string(w, pkg.name),
			flags = pkg_flags,
			// C++ Reference: docs_writer.cpp -- `doc_pkg.docs = odin_doc_pkg_doc_string(w, pkg);`.
			// The port never assigned Doc_Pkg.docs at all, so the PACKAGE-LEVEL documentation
			// comment -- the paragraph above `package foo`, which is what a package's landing page
			// is built from -- was absent from every .odin-doc the port wrote. MEASURED on
			// core/unicode/utf8: the oracle records "Procedures and constants to support
			// text-encoding in the `UTF-8` character encoding.\n\n" and the port recorded "".
			docs = doc_write_pkg_doc_string(w, pkg),
		}

		pkg_index := doc_write_item(w, &w.pkgs, &doc_pkg)
		w.pkg_cache[pkg] = pkg_index

		// Write files.
		//
		// C++ Reference: docs_writer.cpp odin_doc_write_docs. C++ iterates pkg->files, the array sorted by
		// basename in check_create_file_scopes; doc writing runs after checking, so the sort has
		// happened. Map order here would decide the Doc_File_Index numbering, i.e. the order
		// entries land in the binary .odin-doc.
		//
		// NOTE: this writer is not currently reached -- generate_documentation always takes the
		// plain-text path (see the DEFERRED note there), so this change cannot be observed by
		// any instrument in the tree today. It is made because the C++ order is unambiguous, not
		// because a measurement moved.
		file_indices := make([dynamic]Doc_File_Index)
		defer delete(file_indices)

		for file in sorted_files(pkg.files) {
			doc_file := Doc_File{
				pkg = pkg_index,
				name = doc_write_string(w, file.fullpath),
			}
			file_index := doc_write_item(w, &w.files, &doc_file)
			w.file_cache[file] = file_index
			append(&file_indices, file_index)
		}

		doc_pkg.files = doc_write_slice(w, file_indices[:])
		doc_pkg.entries = doc_add_pkg_entries(w, pkg)

		// Update the written item
		dst := doc_get_item(w, &w.pkgs, pkg_index)
		if dst != nil {
			dst^ = doc_pkg
		}
	}

	// Update entity type references
	doc_update_entities(w)
}

// doc_write_to_file writes the buffer to a file
doc_write_to_file :: proc(w: ^Doc_Writer, filename: string) -> bool {
	return os.write_entire_file(filename, w.data) == nil
}

// odin_doc_write is the main entry point for writing .odin-doc files
// C++ Reference: docs_writer.cpp odin_doc_write_docs
odin_doc_write :: proc(info: ^Checker_Info, filename: string) -> bool {
	// Set doc writer mode for canonical string generation
	// C++ Reference: docs_writer.cpp odin_doc_write_docs
	g_in_doc_writer = true
	defer { g_in_doc_writer = false }

	w: Doc_Writer
	doc_writer_init(&w, info)
	defer doc_writer_destroy(&w)

	// First pass: calculate sizes
	doc_write_docs(&w)

	// Second pass: write data
	doc_writer_start_writing(&w)
	doc_write_docs(&w)
	doc_writer_end_writing(&w)

	// Write to file
	return doc_write_to_file(&w, filename)
}

