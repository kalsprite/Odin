package checker

import "core:fmt"
import "core:slice"
import "core:strings"
import "core:unicode/utf16"

/*
Name canonicalization and type hashing infrastructure.

This module provides canonical string representation and hashing for types and entities,
used for type deduplication, RTTI generation, and name mangling.

C++ Reference: /mnt/c/odin/src/name_canonicalization.cpp
               /mnt/c/odin/src/name_canonicalization.hpp

Architecture:
- TypeWriter: Abstraction for writing canonical strings (to string or hash)
- write_type_to_canonical_string: Serializes a type to canonical form
- write_canonical_entity_name: Serializes an entity name to canonical form
- type_hash_canonical_type: Computes FNV-1a hash of canonical type representation
- type_to_canonical_string: Generates human-readable canonical type string

Canonical Name Format Rules (from name_canonicalization.hpp:1-22):
- No spaces between any values
- Normal declarations: pkg::name
- Builtin names: just their normal name (e.g., `i32` or `string`)
- Nested (zero level): pkg::parent1::parent2::name
- Nested (more scopes): pkg::parent1::parent2::name[4] (4th scope in depth-first order)
- File private: pkg::[file_name]::name
- Polymorphic procedure/type: pkg::foo:TYPE
- Anonymous procedures: pkg::foo::$anon[file.odin:123] (123 is file offset in bytes)
*/


// ======================================================================================
// CANONICAL NAME SEPARATORS AND CONSTANTS
// C++ Reference: /mnt/c/odin/src/name_canonicalization.hpp:24-44
// ======================================================================================

CANONICAL_TYPE_SEPARATOR :: ":"
CANONICAL_NAME_SEPARATOR :: "::"
CANONICAL_BIT_FIELD_SEPARATOR :: "|"
CANONICAL_PARAM_SEPARATOR :: ","
CANONICAL_PARAM_TYPEID :: "$"
CANONICAL_PARAM_CONST :: "$$"
CANONICAL_PARAM_C_VARARG :: "#c_vararg"
CANONICAL_PARAM_VARARG :: ".."
CANONICAL_FIELD_SEPARATOR :: ","
CANONICAL_ANON_PREFIX :: "$anon"
CANONICAL_NONE_TYPE :: "<>"
CANONICAL_RANGE_OPERATOR :: "..="

// TYPE_SET_TOMBSTONE marks deleted entries in TypeSet hash table
// C++ Reference: /mnt/c/odin/src/name_canonicalization.hpp:69
TYPE_SET_TOMBSTONE :: max(u64)

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// filename_without_directory extracts just the filename from a full path
// Used for file-private entities and anonymous procedure names
filename_without_directory :: proc(path: string) -> string {
	for i := len(path) - 1; i >= 0; i -= 1 {
		if path[i] == '/' || path[i] == '\\' {
			return path[i + 1:]
		}
	}
	return path
}

// default_calling_convention returns the default calling convention for procedures
// C++ Reference: parser.hpp:319-321
default_calling_convention :: proc() -> Calling_Convention {
	return .Odin
}

// proc_calling_convention_strings maps Calling_Convention to canonical string representation
// C++ Reference: parser.cpp (calling convention string table)
proc_calling_convention_strings := [Calling_Convention]string {
	.Odin        = "odin",
	.Contextless = "contextless",
	.C           = "cdecl",
	.Std         = "std",
	.Fast        = "fast",
	.None        = "none",
	.Naked       = "naked",
	.Inline_Asm  = "inline_asm",
	.Win64       = "win64",
	.SysV        = "sysv",
}

// quote_to_ascii escapes special characters in strings for canonical representation
// C++ Reference: string.cpp:772-842 (quote_to_ascii for String)
quote_to_ascii :: proc {
	quote_to_ascii_string,
	quote_to_ascii_string16,
}

// quote_to_ascii_string escapes UTF-8 strings
// C++ Reference: string.cpp:772-842
quote_to_ascii_string :: proc(s: string, allocator := context.allocator) -> string {
	// Quick check if escaping is needed
	needs_escape := false
	for c in s {
		if c == '"' || c == '\\' || c < 32 || c >= 127 {
			needs_escape = true
			break
		}
	}

	if !needs_escape {
		return s
	}

	// Build escaped string
	sb := strings.builder_make(0, len(s) * 2, allocator)
	for c in s {
		switch c {
		case '"':
			strings.write_string(&sb, "\\\"")
		case '\\':
			strings.write_string(&sb, "\\\\")
		case '\n':
			strings.write_string(&sb, "\\n")
		case '\r':
			strings.write_string(&sb, "\\r")
		case '\t':
			strings.write_string(&sb, "\\t")
		case:
			if c < 32 || c >= 127 {
				// Non-printable ASCII - use hex escape
				strings.write_string(&sb, fmt.tprintf("\\x%02x", c))
			} else {
				strings.write_byte(&sb, byte(c))
			}
		}
	}
	return strings.to_string(sb)
}

// quote_to_ascii_string16 converts and escapes UTF-16 strings to ASCII
// C++ Reference: string.cpp:856-885
quote_to_ascii_string16 :: proc(val: Exact_Value_String16, allocator := context.allocator) -> string {
	if val.text == nil || val.len == 0 {
		return "\"\""
	}

	// Convert UTF-16 to []u16 slice for processing
	utf16_slice := val.text[:val.len]

	// Build escaped string with quote marks
	sb := strings.builder_make(0, val.len * 2, allocator)
	strings.write_byte(&sb, '"')

	// Process each UTF-16 code unit
	i := 0
	for i < val.len {
		r := rune(utf16.REPLACEMENT_CHAR)
		width := 1

		// Decode UTF-16 code unit (handling surrogates)
		// C++ Reference: string.cpp:869-880
		c := utf16_slice[i]
		if c < 0xd800 || 0xe000 <= c {
			// Not a surrogate
			r = rune(c)
		} else if 0xd800 <= c && c < 0xdc00 {
			// High surrogate - check for low surrogate
			if i + 1 < val.len {
				c2 := utf16_slice[i + 1]
				if 0xdc00 <= c2 && c2 < 0xe000 {
					r = utf16.decode_surrogate_pair(rune(c), rune(c2))
					width = 2
				}
			}
		}

		// Handle invalid UTF-16 sequences
		// C++ Reference: string.cpp:881-887
		if width == 1 && r == utf16.REPLACEMENT_CHAR {
			fmt.sbprintf(&sb, "\\x%02x", c & 0xff)
			i += 1
			continue
		}

		// Handle quote and backslash escaping
		// C++ Reference: string.cpp:889-893
		if r == '"' || r == '\\' {
			strings.write_byte(&sb, '\\')
			strings.write_rune(&sb, r)
			i += width
			continue
		}

		// Handle printable ASCII
		// C++ Reference: string.cpp:894-897
		if r < 0x80 && is_printable_ascii(r) {
			strings.write_byte(&sb, byte(r))
			i += width
			continue
		}

		// Handle special escapes and Unicode
		// C++ Reference: string.cpp:898-932
		if r < ' ' {
			// Control characters (includes '\a', '\b', '\f', '\n', '\r', '\t', '\v')
			fmt.sbprintf(&sb, "\\x%02x", byte(r))
		} else if r > 0x10FFFF {
			// Invalid rune - normalize to replacement character
			fmt.sbprintf(&sb, "\\u%04x", 0xFFFD)
		} else if r < 0x10000 {
			// BMP character - use \uXXXX
			fmt.sbprintf(&sb, "\\u%04x", r)
		} else {
			// Supplementary character - use \UXXXXXXXX
			fmt.sbprintf(&sb, "\\U%08x", r)
		}

		i += width
	}

	strings.write_byte(&sb, '"')
	return strings.to_string(sb)
}

// is_printable_ascii checks if a rune is printable ASCII
// C++ Reference: string.cpp:757-768
is_printable_ascii :: proc(r: rune) -> bool {
	if r <= 0xff {
		if 0x20 <= r && r <= 0x7e {
			return true
		}
		if 0xa1 <= r && r <= 0xff {
			return r != 0xad
		}
		return false
	}
	return false
}

// ======================================================================================
// TYPE WRITER INFRASTRUCTURE
// C++ Reference: /mnt/c/odin/src/name_canonicalization.cpp:241-300
// ======================================================================================

// Type_Writer_Proc is the callback for writing data
// Returns true on success
// C++ Reference: name_canonicalization.cpp:241-242
Type_Writer_Proc :: #type proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool

// Type_Writer abstracts writing canonical strings to different backends
// C++ Reference: name_canonicalization.cpp:245-248
Type_Writer :: struct {
	proc_:     Type_Writer_Proc,
	user_data: rawptr,
}

// C++ Reference: name_canonicalization.cpp:250-252
type_writer_append :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	return w.proc_(w, ptr, len)
}

// C++ Reference: name_canonicalization.cpp:254-256
type_writer_appendb :: proc(w: ^Type_Writer, b: byte) -> bool {
	temp := b
	return w.proc_(w, &temp, 1)
}

// C++ Reference: name_canonicalization.cpp:258-261
type_writer_appendc :: proc(w: ^Type_Writer, str: string) -> bool {
	return w.proc_(w, raw_data(str), len(str))
}

// C++ Reference: name_canonicalization.cpp:263-271
type_writer_append_fmt :: proc(w: ^Type_Writer, format: string, args: ..any) -> bool {
	// Use temp allocator for formatting (equivalent to C++ gb_bprintf)
	str := fmt.tprintf(format, ..args)
	return type_writer_appendc(w, str)
}

// ======================================================================================
// STRING WRITER BACKEND
// C++ Reference: name_canonicalization.cpp:275-288
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:275-279
type_writer_string_writer_proc :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	builder := cast(^strings.Builder)w.user_data
	bytes := slice.bytes_from_ptr(cast(^byte)ptr, len)
	strings.write_bytes(builder, bytes)
	return true
}

// C++ Reference: name_canonicalization.cpp:281-284
type_writer_make_string :: proc(w: ^Type_Writer, builder: ^strings.Builder) {
	w.user_data = builder
	w.proc_ = type_writer_string_writer_proc
}

// C++ Reference: name_canonicalization.cpp:286-288
type_writer_destroy_string :: proc(w: ^Type_Writer) {
	// In Odin, caller manages builder lifetime
	w.user_data = nil
	w.proc_ = nil
}

// ======================================================================================
// HASHER WRITER BACKEND
// C++ Reference: name_canonicalization.cpp:291-300
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:291-295
type_writer_hasher_writer_proc :: proc(w: ^Type_Writer, ptr: rawptr, len: int) -> bool {
	seed := cast(^u64)w.user_data
	seed^ = fnv64a(ptr, len, seed^)
	return true
}

// C++ Reference: name_canonicalization.cpp:297-300
type_writer_make_hasher :: proc(w: ^Type_Writer, hash: ^u64) {
	w.user_data = hash
	w.proc_ = type_writer_hasher_writer_proc
}

// ======================================================================================
// FNV-1a HASH FUNCTION
// C++ Reference: /mnt/c/odin/src/gb/gb.h:4804-4814
// ======================================================================================

// fnv64a computes FNV-1a 64-bit hash
// C++ Reference: gb.h:4804-4814
fnv64a :: proc(data: rawptr, len: int, seed: u64 = 0xcbf29ce484222325) -> u64 {
	h := seed
	bytes := slice.bytes_from_ptr(cast(^byte)data, len)

	for i in 0 ..< len {
		h = (h ~ u64(bytes[i])) * 0x100000001b3
	}

	return h
}

// ======================================================================================
// CANONICAL PARAMETER WRITING
// C++ Reference: name_canonicalization.cpp:305-370
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:305-370
write_canonical_params :: proc(w: ^Type_Writer, params: ^Type) {
	type_writer_appendc(w, "(")
	defer type_writer_appendc(w, ")")

	if params == nil {
		return
	}

	assert(params.kind == .Tuple, "write_canonical_params: params must be a Tuple")
	tuple := params.variant.(Type_Tuple)

	for v, i in tuple.variables {
		if i > 0 {
			type_writer_appendc(w, CANONICAL_PARAM_SEPARATOR)
		}

		type_writer_append(w, raw_data(v.token.text), len(v.token.text))
		type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)

		#partial switch v.kind {
		case .Variable:
			if .C_Var_Arg in v.flags {
				type_writer_appendc(w, CANONICAL_PARAM_C_VARARG)
			}
			if .Ellipsis in v.flags {
				slice_type := base_type(v.type)
				type_writer_appendc(w, CANONICAL_PARAM_VARARG)
				assert(v.type.kind == .Slice, "Ellipsis parameter must have slice type")
				slice_variant := slice_type.variant.(Type_Slice)
				write_type_to_canonical_string(w, slice_variant.elem)
			} else {
				write_type_to_canonical_string(w, v.type)
			}

			// Handle default values for doc writer
			// C++ Reference: name_canonicalization.cpp:472-488
			if is_in_doc_writer() {
				var_ent := v.variant.(Entity_Variable)
				// Get default value expression - try init_expr first, then param_value
				expr := var_ent.init_expr
				if expr == nil {
					expr = var_ent.param_value.original_ast_expr
				}
				if expr != nil {
					type_writer_appendc(w, "=")
					shorthand := .Short in build_context.cmd_doc_flags
					s := shorthand ? expr_to_string_shorthand(expr) : expr_to_string(expr)
					defer delete(s)
					type_writer_append(w, raw_data(s), len(s))
				}
			}

		case .Type_Name:
			type_writer_appendc(w, CANONICAL_PARAM_TYPEID)
			write_type_to_canonical_string(w, v.type)

		case .Constant:
			const_ent := v.variant.(Entity_Constant)
			type_writer_appendc(w, CANONICAL_PARAM_CONST)
			s := exact_value_to_string(const_ent.value)
			defer delete(s)
			type_writer_append(w, raw_data(s), len(s))

		case:
			panic("write_canonical_params: Unsupported parameter entity kind")
		}
	}
}

// ======================================================================================
// TYPE HASHING
// C++ Reference: name_canonicalization.cpp:372-390
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:372-390
type_hash_canonical_type :: proc(type: ^Type) -> u64 {
	if type == nil {
		return 0
	}

	// Check cached hash (C++ uses atomic load)
	// C++ Reference: line 376-379
	prev_hash := type.canonical_hash
	if prev_hash != 0 {
		return prev_hash
	}

	// Compute hash using TypeWriter hasher backend
	// C++ Reference: line 381-385
	hash: u64 = fnv64a(nil, 0) // Initialize with FNV offset basis

	w: Type_Writer
	type_writer_make_hasher(&w, &hash)
	write_type_to_canonical_string(&w, type)

	// Ensure hash is non-zero (C++ line 385)
	hash = hash != 0 ? hash : 1

	// Cache the hash (single-threaded, no atomics needed)
	// C++ Reference: line 387
	type.canonical_hash = hash

	return hash
}

// ======================================================================================
// CANONICAL STRING GENERATION
// C++ Reference: name_canonicalization.cpp:392-407
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:392-399
type_to_canonical_string :: proc(type: ^Type, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)

	w: Type_Writer
	type_writer_make_string(&w, &builder)
	write_type_to_canonical_string(&w, type)

	return strings.clone(strings.to_string(builder), allocator)
}

// C++ Reference: name_canonicalization.cpp:401-407
temp_canonical_string :: proc(type: ^Type) -> string {
	return type_to_canonical_string(type, context.temp_allocator)
}

// C++ Reference: name_canonicalization.cpp:409-414
string_canonical_entity_name :: proc(e: ^Entity, allocator := context.allocator) -> string {
	builder: strings.Builder
	strings.builder_init(&builder, allocator)
	defer strings.builder_destroy(&builder)

	w: Type_Writer
	type_writer_make_string(&w, &builder)
	write_canonical_entity_name(&w, e)

	return strings.clone(strings.to_string(builder), allocator)
}

// ======================================================================================
// CANONICAL PARENT PREFIX WRITING
// C++ Reference: name_canonicalization.cpp:418-466
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:418-466
write_canonical_parent_prefix :: proc(w: ^Type_Writer, e: ^Entity) {
	assert(e != nil, "write_canonical_parent_prefix: entity is nil")

	if e.kind == .Procedure || e.kind == .Type_Name {
		// C++ Reference: line 421-424
		if e.kind == .Procedure {
			proc_ent := e.variant.(Entity_Procedure)
			if proc_ent.is_export || proc_ent.is_foreign {
				// No prefix for exported/foreign procedures
				return
			}
		}

		// C++ Reference: line 425-434
		if e.parent_proc_decl != nil {
			p := e.parent_proc_decl.entity
			write_canonical_parent_prefix(w, p)
			type_writer_append(w, raw_data(p.token.text), len(p.token.text))
			if is_type_polymorphic(p.type) {
				type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
				write_type_to_canonical_string(w, p.type)
			}
			type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)

			// C++ Reference: line 435-441
			// Check if entity is in package-level scope (not file-private)
		} else if e.pkg != nil && e.pkg.scope != nil {
			// NOTE: checker.Scope is an alias to ast.Scope, so e.pkg.scope can be used directly
			if scope_lookup_current(e.pkg.scope, e.token.text) == e {
				// Entity is at package level - use simple package::name format
				type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
				if e.pkg.name == "llvm" {
					type_writer_appendc(w, "$")
				}
				type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
				// Don't add file name prefix - fall through to write_base_name
			} else {
				// Entity not in package scope or lookup failed, treat as file-private
				file_name := filename_without_directory(e.file.fullpath)

				type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
				if e.pkg.name == "llvm" {
					type_writer_appendc(w, "$")
				}
				type_writer_append_fmt(w, "%s[%s]%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR)
			}
		} else {
			// C++ Reference: line 442-448
			file_name := filename_without_directory(e.file.fullpath)

			type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
			if e.pkg.name == "llvm" {
				type_writer_appendc(w, "$")
			}
			type_writer_append_fmt(w, "%s%s%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR)
		}
	} else {
		panic(fmt.tprintf("write_canonical_parent_prefix: Unsupported entity kind %v", e.kind))
	}

	// C++ Reference: line 452-457
	if e.kind == .Procedure {
		proc_ent := e.variant.(Entity_Procedure)
		if proc_ent.is_anonymous {
			file_name := filename_without_directory(e.file.fullpath)
			type_writer_append_fmt(w, "%s_%s:%d", CANONICAL_ANON_PREFIX, file_name, e.token.pos.offset)
		} else {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		}
	} else {
		type_writer_append(w, raw_data(e.token.text), len(e.token.text))
	}

	// C++ Reference: line 459-463
	if is_type_polymorphic(e.type) {
		type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
		write_type_to_canonical_string(w, e.type)
	}
	type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
}

// ======================================================================================
// CANONICAL ENTITY NAME WRITING
// C++ Reference: name_canonicalization.cpp:468-599
// ======================================================================================

// C++ Reference: name_canonicalization.cpp:468-599
write_canonical_entity_name :: proc(w: ^Type_Writer, e: ^Entity) {
	assert(e != nil, "write_canonical_entity_name: entity is nil")

	// C++ Reference: line 471-476
	if e.token.text == "_" {
		panic("write_canonical_entity_name: _ entity")
	}
	if len(e.token.text) == 0 {
		panic("write_canonical_entity_name: empty string entity")
	}

	// C++ Reference: line 478-494
	if e.kind == .Variable {
		var_ent := e.variant.(Entity_Variable)
		is_foreign := var_ent.is_foreign
		is_export := var_ent.is_export

		if len(var_ent.link_name) > 0 {
			type_writer_append(w, raw_data(var_ent.link_name), len(var_ent.link_name))
			return
		} else if is_foreign || is_export {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
			return
		}
	} else if e.kind == .Procedure {
		proc_ent := e.variant.(Entity_Procedure)
		if len(proc_ent.link_name) > 0 {
			type_writer_append(w, raw_data(proc_ent.link_name), len(proc_ent.link_name))
			return
		} else if proc_ent.is_export {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
			return
		}
	}

	write_scope_index_suffix := false

	// C++ Reference: line 498-547
	if .Builtin in e.scope.flags {
		// Jump to write_base_name
	} else if (.File not_in e.scope.flags && .Pkg not_in e.scope.flags) || .Not_Exported in e.flags {
		s := e.scope

		// Find parent scope with decl_info or procedure/file flags
		// C++ Reference: line 504-509
		for (.Proc not_in s.flags && .File not_in s.flags) && s.decl_info == nil {
			if s.parent == nil {
				break
			}
			s = s.parent
		}

		// C++ Reference: line 511-517
		if s.decl_info != nil && s.decl_info.entity != nil {
			parent := s.decl_info.entity
			write_canonical_parent_prefix(w, parent)
			if e.scope.index > 0 {
				write_scope_index_suffix = true
			}
			// Jump to write_base_name
		} else if (.File in s.flags) && s.file != nil {
			// C++ Reference: line 519-526
			file_name := filename_without_directory(s.file.fullpath)

			type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
			if e.pkg.name == "llvm" {
				type_writer_appendc(w, "$")
			}
			type_writer_appendc(w, fmt.tprintf("%s[%s]%s", CANONICAL_NAME_SEPARATOR, file_name, CANONICAL_NAME_SEPARATOR))
			// Jump to write_base_name
		} else if .Builtin in s.flags {
			// Jump to write_base_name
		} else {
			// C++ Reference: line 530-546
			// This is an error case in C++ - print diagnostic and panic
			panic(fmt.tprintf("write_canonical_entity_name: Weird entity %s", e.token.text))
		}
	}

	// C++ Reference: line 548-551
	if e.pkg != nil {
		type_writer_append(w, raw_data(e.pkg.name), len(e.pkg.name))
		type_writer_appendc(w, CANONICAL_NAME_SEPARATOR)
	}

	// write_base_name: (C++ Reference: line 553)

	// C++ Reference: line 555-592
	#partial switch e.kind {
	case .Type_Name:
		// C++ Reference: line 557-573
		params: ^Type = nil
		parent := type_get_polymorphic_parent(e.type, &params)

		if parent != nil && e.token.text == parent.token.text {
			// Check for `distinct` forms (C++ line 561-564)
			type_writer_append(w, raw_data(parent.token.text), len(parent.token.text))
			write_canonical_params(w, params)
		} else if parent != nil && strings.has_prefix(e.token.text, parent.token.text) && strings.contains_rune(e.token.text, '(') {
			// Check for named specialization forms (C++ line 565-569)
			type_writer_append(w, raw_data(parent.token.text), len(parent.token.text))
			write_canonical_params(w, params)
		} else {
			type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		}

	case .Constant:
		// For debug symbols only (C++ line 576-578)
		fallthrough

	case .Procedure, .Variable:
		type_writer_append(w, raw_data(e.token.text), len(e.token.text))
		if is_type_polymorphic(e.type) {
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, e.type)
		}

	case:
		panic(fmt.tprintf("write_canonical_entity_name: Unsupported entity kind %v", e.kind))
	}

	// C++ Reference: line 593-596
	if write_scope_index_suffix {
		assert(e != nil && e.scope != nil)
		type_writer_append_fmt(w, "%s$%d", CANONICAL_NAME_SEPARATOR, e.scope.index)
	}
}

// ======================================================================================
// CANONICAL TYPE STRING WRITING
// C++ Reference: name_canonicalization.cpp:602-844
// ======================================================================================

// write_type_to_canonical_string serializes a type to canonical form
// This is the core function for type identity and hashing
// C++ Reference: name_canonicalization.cpp:602-844
write_type_to_canonical_string :: proc(w: ^Type_Writer, type: ^Type) {
	if type == nil {
		type_writer_appendc(w, CANONICAL_NONE_TYPE)
		return
	}

	// C++ Reference: line 609
	// NOTE: Cannot reassign parameter in Odin, so use a new variable
	actual_type := default_type(type)
	assert(!is_type_untyped(actual_type), "write_type_to_canonical_string: untyped type")

	#partial switch actual_type.kind {
	case .Basic:
		// C++ Reference: line 613-615
		basic := actual_type.variant.(Type_Basic)
		name := basic_kind_to_string(basic.kind)
		type_writer_append(w, raw_data(name), len(name))

	case .Pointer:
		// C++ Reference: line 616-619
		type_writer_appendb(w, '^')
		ptr := actual_type.variant.(Type_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Multi_Pointer:
		// C++ Reference: line 620-623
		type_writer_appendc(w, "[^]")
		ptr := actual_type.variant.(Type_Multi_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Soa_Pointer:
		// C++ Reference: line 624-627
		type_writer_appendc(w, "#soa^")
		ptr := actual_type.variant.(Type_Soa_Pointer)
		write_type_to_canonical_string(w, ptr.elem)

	case .Enumerated_Array:
		// C++ Reference: line 628-636
		ea := actual_type.variant.(Type_Enumerated_Array)
		// C++ Reference: line 629-631
		if ea.is_sparse {
			type_writer_appendc(w, "#sparse")
		}
		type_writer_appendb(w, '[')
		write_type_to_canonical_string(w, ea.index)
		type_writer_appendb(w, ']')
		write_type_to_canonical_string(w, ea.elem)

	case .Array:
		// C++ Reference: line 637-640
		arr := actual_type.variant.(Type_Array)
		type_writer_append_fmt(w, "[%d]", arr.count)
		write_type_to_canonical_string(w, arr.elem)

	case .Slice:
		// C++ Reference: line 641-644
		slice := actual_type.variant.(Type_Slice)
		type_writer_appendc(w, "[]")
		write_type_to_canonical_string(w, slice.elem)

	case .Dynamic_Array:
		// C++ Reference: line 645-648
		dyn := actual_type.variant.(Type_Dynamic_Array)
		type_writer_appendc(w, "[dynamic]")
		write_type_to_canonical_string(w, dyn.elem)

	case .Simd_Vector:
		// C++ Reference: line 649-652
		simd := actual_type.variant.(Type_Simd_Vector)
		type_writer_append_fmt(w, "#simd[%d]", simd.count)
		write_type_to_canonical_string(w, simd.elem)

	case .Matrix:
		// C++ Reference: line 653-659
		mat := actual_type.variant.(Type_Matrix)
		if mat.is_row_major {
			type_writer_appendc(w, "#row_major ")
		}
		type_writer_append_fmt(w, "matrix[%d, %d]", mat.row_count, mat.column_count)
		write_type_to_canonical_string(w, mat.elem)

	case .Map:
		// C++ Reference: line 660-665
		map_type := actual_type.variant.(Type_Map)
		type_writer_appendc(w, "map[")
		write_type_to_canonical_string(w, map_type.key)
		type_writer_appendc(w, "]")
		write_type_to_canonical_string(w, map_type.value)

	case .Enum:
		// C++ Reference: line 667-689
		enum_type := actual_type.variant.(Type_Enum)
		type_writer_appendc(w, "enum")
		if enum_type.base_type != nil {
			type_writer_appendb(w, ' ')
			write_type_to_canonical_string(w, enum_type.base_type)
			type_writer_appendb(w, ' ')
		}
		type_writer_appendb(w, '{')
		for f, i in enum_type.fields {
			assert(f.kind == .Constant, "Enum field must be constant")
			const_ent := f.variant.(Entity_Constant)
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, "=")

			s := exact_value_to_string(const_ent.value)
			defer delete(s)
			type_writer_append(w, raw_data(s), len(s))
		}
		type_writer_appendb(w, '}')

	case .Bit_Set:
		// C++ Reference: line 690-706
		bs := actual_type.variant.(Type_Bit_Set)
		type_writer_appendc(w, "bit_set[")
		if bs.elem == nil {
			type_writer_appendc(w, CANONICAL_NONE_TYPE)
		} else if is_type_enum(bs.elem) {
			write_type_to_canonical_string(w, bs.elem)
		} else {
			type_writer_append_fmt(w, "%d", bs.lower)
			type_writer_appendc(w, CANONICAL_RANGE_OPERATOR)
			type_writer_append_fmt(w, "%d", bs.upper)
		}
		if bs.underlying != nil {
			type_writer_appendc(w, ";")
			write_type_to_canonical_string(w, bs.underlying)
		}
		type_writer_appendc(w, "]")

	case .Union:
		// C++ Reference: line 708-729
		union_type := actual_type.variant.(Type_Union)
		type_writer_appendc(w, "union")

		// Handle polymorphic_params for doc writer
		// C++ Reference: name_canonicalization.cpp:853-855
		if is_in_doc_writer() && union_type.polymorphic_params != nil {
			write_canonical_params(w, union_type.polymorphic_params)
		}

		switch union_type.kind {
		case .No_Nil:
			type_writer_appendc(w, "#no_nil")
		case .Maybe:
			// Maybe was merged with normal unions - nothing to print
		case .Shared_Nil:
			type_writer_appendc(w, "#shared_nil")
		case .Normal: // No suffix
		}

		if union_type.custom_align != 0 {
			type_writer_append_fmt(w, "#align(%d)", union_type.custom_align)
		}

		type_writer_appendc(w, "{")
		for variant, i in union_type.variants {
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			write_type_to_canonical_string(w, variant)
		}
		type_writer_appendc(w, "}")

	case .Struct:
		// C++ Reference: line 730-773
		struct_type := actual_type.variant.(Type_Struct)

		// Handle SOA types (C++ line 731-739)
		if struct_type.soa_kind != .None {
			#partial switch struct_type.soa_kind {
			case .Fixed:
				type_writer_append_fmt(w, "#soa[%d]", struct_type.soa_count)
			case .Slice:
				type_writer_appendc(w, "#soa[]")
			case .Dynamic:
				type_writer_appendc(w, "#soa[dynamic]")
			}
			write_type_to_canonical_string(w, struct_type.soa_elem)
			return
		}

		type_writer_appendc(w, "struct")

		// Handle polymorphic_params for doc writer
		// C++ Reference: name_canonicalization.cpp:885-887
		if is_in_doc_writer() && struct_type.polymorphic_params != nil {
			write_canonical_params(w, struct_type.polymorphic_params)
		}

		if struct_type.is_packed {
			type_writer_appendc(w, "#packed")
		}
		if struct_type.is_raw_union {
			type_writer_appendc(w, "#raw_union")
		}
		if struct_type.custom_min_field_align != 0 {
			type_writer_append_fmt(w, "#min_field_align(%d)", struct_type.custom_min_field_align)
		}
		if struct_type.custom_max_field_align != 0 {
			type_writer_append_fmt(w, "#max_field_align(%d)", struct_type.custom_max_field_align)
		}
		if struct_type.custom_align != 0 {
			type_writer_append_fmt(w, "#align(%d)", struct_type.custom_align)
		}

		type_writer_appendb(w, '{')
		for f, i in struct_type.fields {
			assert(f.kind == .Variable, "Struct field must be variable")
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, f.type)

			// Handle struct tags (C++ line 762-770)
			tag := ""
			if i < len(struct_type.tags) {
				tag = struct_type.tags[i]
			}
			if len(tag) != 0 {
				escaped_tag := quote_to_ascii(tag, context.temp_allocator)
				type_writer_append(w, raw_data(escaped_tag), len(escaped_tag))
			}
		}
		type_writer_appendb(w, '}')

	case .Bit_Field:
		// C++ Reference: line 775-791
		bf := actual_type.variant.(Type_Bit_Field)
		type_writer_appendc(w, "bit_field")
		write_type_to_canonical_string(w, bf.backing_type)
		type_writer_appendc(w, " {")
		for f, i in bf.fields {
			if i > 0 {
				type_writer_appendc(w, CANONICAL_FIELD_SEPARATOR)
			}
			type_writer_append(w, raw_data(f.token.text), len(f.token.text))
			type_writer_appendc(w, CANONICAL_TYPE_SEPARATOR)
			write_type_to_canonical_string(w, f.type)
			type_writer_appendc(w, CANONICAL_BIT_FIELD_SEPARATOR)
			// C++ Reference: line 786-787
			type_writer_append_fmt(w, "%d", bf.bit_sizes[i])
		}
		type_writer_appendc(w, " }")

	case .Proc:
		// C++ Reference: line 793-806
		proc_type := actual_type.variant.(Type_Proc)
		type_writer_appendc(w, "proc")

		// C++ Reference: line 795-799
		if default_calling_convention() != proc_type.calling_convention {
			type_writer_appendc(w, "\"")
			type_writer_appendc(w, proc_calling_convention_strings[proc_type.calling_convention])
			type_writer_appendc(w, "\"")
		}

		write_canonical_params(w, proc_type.params)
		if proc_type.result_count > 0 {
			type_writer_appendc(w, "->")
			write_canonical_params(w, proc_type.results)
		}

	case .Generic:
		// C++ Reference: line 808-824
		// NOTE: The C++ implementation has two modes:
		// 1. Doc writer mode: Outputs "$name-id" with optional "/specialized_type"
		// 2. Normal mode (RTTI/hashing): Outputs either the specialized type or "rawptr" placeholder
		//
		// We currently only implement normal mode for RTTI generation and type hashing.
		// The doc writer mode is used for documentation generation and would require
		// additional infrastructure (is_in_doc_writer() check).
		generic := actual_type.variant.(Type_Generic)
		if generic.specialized != nil {
			// If we have a specialized type, use that instead
			// C++ Reference: line 819-820
			write_type_to_canonical_string(w, generic.specialized)
		} else {
			// For unspecialized generics, use "rawptr" as a generic placeholder
			// C++ Reference: line 822-823
			// ARCHITECTURAL NOTE: This matches the C++ behavior exactly.
			// Using "rawptr" ensures all unspecialized generic types hash to the same value,
			// which is correct since they're all treated as pointer-sized opaque types until specialized.
			type_writer_appendc(w, "rawptr")
		}

	case .Named:
		// C++ Reference: line 826-832
		named := actual_type.variant.(Type_Named)
		if named.type_name != nil {
			write_canonical_entity_name(w, named.type_name)
		} else {
			type_writer_append(w, raw_data(named.name), len(named.name))
		}

	case .Tuple:
		// C++ Reference: line 834-837
		type_writer_appendc(w, "params")
		write_canonical_params(w, type)

	case:
		panic(fmt.tprintf("write_type_to_canonical_string: Unknown type kind %v", type.kind))
	}
}
