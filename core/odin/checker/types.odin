package checker

/*
Type system implementation.

This module provides type construction, comparison, and validation utilities
following the Odin compiler's type system design.
*/

import "base:intrinsics"
import "base:runtime"
import "core:odin/tokenizer"
import "core:sync"

// blank_token is a global token representing the blank identifier "_"
// C++ Reference: /mnt/c/odin/src/tokenizer.cpp:249
// Used for synthetic entities that don't have a source name (tuple fields, etc.)
blank_token := tokenizer.Token {
	kind = .Ident,
	pos  = tokenizer.Pos{},
	text = "_",
}

// alloc_type allocates and initializes a new Type with the given variant
// Automatically sets t.kind based on the variant type T
alloc_type :: proc($T: typeid) -> ^Type {
	t := new(Type)
	t.variant = T{}

	// Automatically set t.kind based on variant type
	// C++ sets this manually during type construction
	#partial switch _ in t.variant {
	case Type_Basic:
		t.kind = .Basic
	case Type_Named:
		t.kind = .Named
	case Type_Generic:
		t.kind = .Generic
	case Type_Pointer:
		t.kind = .Pointer
	case Type_Multi_Pointer:
		t.kind = .Multi_Pointer
	case Type_Soa_Pointer:
		t.kind = .Soa_Pointer
	case Type_Array:
		t.kind = .Array
	case Type_Enumerated_Array:
		t.kind = .Enumerated_Array
	case Type_Slice:
		t.kind = .Slice
	case Type_Dynamic_Array:
		t.kind = .Dynamic_Array
	case Type_Map:
		t.kind = .Map
	case Type_Struct:
		t.kind = .Struct
	case Type_Union:
		t.kind = .Union
	case Type_Enum:
		t.kind = .Enum
	case Type_Tuple:
		t.kind = .Tuple
	case Type_Proc:
		t.kind = .Proc
	case Type_Bit_Set:
		t.kind = .Bit_Set
	case Type_Bit_Field:
		t.kind = .Bit_Field
	case Type_Simd_Vector:
		t.kind = .Simd_Vector
	case Type_Matrix:
		t.kind = .Matrix
	case:
		t.kind = .Invalid
	}

	return t
}

// Endianness represents the byte order of a type
// C++ Reference: Derived from BasicFlag_EndianLittle/Big in /mnt/c/odin/src/types.cpp:112-113
Endianness :: enum {
	Platform, // Native platform endianness (no explicit endian variant)
	Little, // Little-endian (le suffix types: i16le, f32le, etc.)
	Big, // Big-endian (be suffix types: i16be, f32be, etc.)
}

// Basic type singletons (to be initialized)
t_invalid: ^Type
t_bool: ^Type
t_i8, t_i16, t_i32, t_i64, t_i128: ^Type
t_u8, t_u16, t_u32, t_u64, t_u128: ^Type
t_int, t_uint, t_uintptr: ^Type // Platform-dependent
t_u8_ptr: ^Type // ^u8 (helper for string/cstring internals)
t_u8_slice: ^Type // []u8 (helper for #load return type)
t_f16, t_f32, t_f64: ^Type
t_complex64, t_complex128: ^Type
t_string, t_cstring: ^Type
t_rawptr: ^Type
t_typeid: ^Type
t_any: ^Type

// Rune type (distinct from i32)
// C++ Reference: /mnt/c/odin/src/types.cpp:582
t_rune: ^Type

// Boolean variants
// C++ Reference: /mnt/c/odin/src/types.cpp:569
t_llvm_bool: ^Type
t_b8, t_b16, t_b32, t_b64: ^Type

// Complex32 (two f16)
// C++ Reference: /mnt/c/odin/src/types.cpp:596
t_complex32: ^Type

// Quaternion types
// C++ Reference: /mnt/c/odin/src/types.cpp:600-602
t_quaternion64: ^Type
t_quaternion128: ^Type
t_quaternion256: ^Type

// UTF-16 string types
// C++ Reference: /mnt/c/odin/src/types.cpp:612-613
t_string16: ^Type
t_cstring16: ^Type

// Explicitly-endian integer and float types.
// These are entries of the C++ `basic_types` table (src/types.cpp:538-562) and, like every
// other entry of that table, are registered into the universe scope by init_universal
// (src/checker.cpp:1122-1131). The port had the Basic_Kind values and the basic_flags_table
// rows but no singletons, so `x: i32be` could never resolve.
t_i16le, t_u16le, t_i32le, t_u32le, t_i64le, t_u64le, t_i128le, t_u128le: ^Type
t_i16be, t_u16be, t_i32be, t_u32be, t_i64be, t_u64be, t_i128be, t_u128be: ^Type
t_f16le, t_f32le, t_f64le: ^Type
t_f16be, t_f32be, t_f64be: ^Type

// Untyped type singletons
t_untyped_bool: ^Type
t_untyped_integer: ^Type
t_untyped_float: ^Type
t_untyped_complex: ^Type
t_untyped_string: ^Type
t_untyped_rune: ^Type
t_untyped_nil: ^Type
t_untyped_uninit: ^Type

// Untyped quaternion
// C++ Reference: /mnt/c/odin/src/types.cpp:642
t_untyped_quaternion: ^Type

// Objective-C runtime types
// C++ Reference: /mnt/c/odin/src/checker.cpp:1408-1419
t_objc_object: ^Type // intrinsics.objc_object (struct)
t_objc_selector: ^Type // intrinsics.objc_selector (struct)
t_objc_class: ^Type // intrinsics.objc_class (struct)
t_objc_id: ^Type // ^objc_object
t_objc_SEL: ^Type // ^objc_selector
t_objc_Class: ^Type // ^objc_class

// C variadic types
// C++ Reference: /mnt/c/odin/src/checker.cpp:1589-1590
t_c_va_list: ^Type // intrinsics.c_va_list (struct)
t_c_va_list_ptr: ^Type // ^c_va_list

// intrinsics.Odin_Calling_Convention, the result type of type_proc_calling_convention
// C++ Reference: /mnt/c/odin/src/checker.cpp:1338
t_odin_calling_convention: ^Type

// RTTI (Runtime Type Information) types
// C++ Reference: /mnt/c/odin/src/checker.cpp:3253-3319
t_type_info: ^Type // core:runtime.Type_Info
t_type_info_ptr: ^Type // ^Type_Info
t_type_info_enum_value: ^Type // Type_Info_Enum_Value
t_type_info_enum_value_ptr: ^Type // ^Type_Info_Enum_Value
t_type_info_string_encoding_kind: ^Type // Type_Info_String_Encoding_Kind

// Type_Info variant types (from core:runtime)
t_type_info_named: ^Type // Type_Info_Named
t_type_info_integer: ^Type // Type_Info_Integer
t_type_info_rune: ^Type // Type_Info_Rune
t_type_info_float: ^Type // Type_Info_Float
t_type_info_quaternion: ^Type // Type_Info_Quaternion
t_type_info_complex: ^Type // Type_Info_Complex
t_type_info_string: ^Type // Type_Info_String
t_type_info_boolean: ^Type // Type_Info_Boolean
t_type_info_any: ^Type // Type_Info_Any
t_type_info_typeid: ^Type // Type_Info_Type_Id
t_type_info_pointer: ^Type // Type_Info_Pointer
t_type_info_multi_pointer: ^Type // Type_Info_Multi_Pointer
t_type_info_procedure: ^Type // Type_Info_Procedure
t_type_info_array: ^Type // Type_Info_Array
t_type_info_enumerated_array: ^Type // Type_Info_Enumerated_Array
t_type_info_dynamic_array: ^Type // Type_Info_Dynamic_Array
t_type_info_slice: ^Type // Type_Info_Slice
t_type_info_parameters: ^Type // Type_Info_Parameters
t_type_info_struct: ^Type // Type_Info_Struct
t_type_info_union: ^Type // Type_Info_Union
t_type_info_enum: ^Type // Type_Info_Enum
t_type_info_map: ^Type // Type_Info_Map
t_type_info_bit_set: ^Type // Type_Info_Bit_Set
t_type_info_simd_vector: ^Type // Type_Info_Simd_Vector
t_type_info_matrix: ^Type // Type_Info_Matrix
t_type_info_soa_pointer: ^Type // Type_Info_Soa_Pointer
t_type_info_bit_field: ^Type // Type_Info_Bit_Field

// Pointer types for Type_Info variants
// C++ Reference: /mnt/c/odin/src/types.cpp:697-723
t_type_info_named_ptr: ^Type // ^Type_Info_Named
t_type_info_integer_ptr: ^Type // ^Type_Info_Integer
t_type_info_rune_ptr: ^Type // ^Type_Info_Rune
t_type_info_float_ptr: ^Type // ^Type_Info_Float
t_type_info_quaternion_ptr: ^Type // ^Type_Info_Quaternion
t_type_info_complex_ptr: ^Type // ^Type_Info_Complex
t_type_info_string_ptr: ^Type // ^Type_Info_String
t_type_info_boolean_ptr: ^Type // ^Type_Info_Boolean
t_type_info_any_ptr: ^Type // ^Type_Info_Any
t_type_info_typeid_ptr: ^Type // ^Type_Info_Type_Id
t_type_info_pointer_ptr: ^Type // ^Type_Info_Pointer
t_type_info_multi_pointer_ptr: ^Type // ^Type_Info_Multi_Pointer
t_type_info_procedure_ptr: ^Type // ^Type_Info_Procedure
t_type_info_array_ptr: ^Type // ^Type_Info_Array
t_type_info_enumerated_array_ptr: ^Type // ^Type_Info_Enumerated_Array
t_type_info_dynamic_array_ptr: ^Type // ^Type_Info_Dynamic_Array
t_type_info_slice_ptr: ^Type // ^Type_Info_Slice
t_type_info_parameters_ptr: ^Type // ^Type_Info_Parameters
t_type_info_struct_ptr: ^Type // ^Type_Info_Struct
t_type_info_union_ptr: ^Type // ^Type_Info_Union
t_type_info_enum_ptr: ^Type // ^Type_Info_Enum
t_type_info_map_ptr: ^Type // ^Type_Info_Map
t_type_info_bit_set_ptr: ^Type // ^Type_Info_Bit_Set
t_type_info_simd_vector_ptr: ^Type // ^Type_Info_Simd_Vector
t_type_info_matrix_ptr: ^Type // ^Type_Info_Matrix
t_type_info_soa_pointer_ptr: ^Type // ^Type_Info_Soa_Pointer
t_type_info_bit_field_ptr: ^Type // ^Type_Info_Bit_Field

// Core runtime types
// C++ Reference: /mnt/c/odin/src/types.cpp:725-732
t_allocator: ^Type // core:runtime.Allocator
t_allocator_ptr: ^Type // ^Allocator
t_allocator_error: ^Type // core:runtime.Allocator_Error
t_context: ^Type // core:runtime.Context
t_context_ptr: ^Type // ^Context
t_source_code_location: ^Type // core:runtime.Source_Code_Location
t_source_code_location_ptr: ^Type // ^Source_Code_Location
t_atomic_memory_order: ^Type // core:runtime.Atomic_Memory_Order

// Load directory file types
// C++ Reference: /mnt/c/odin/src/types.cpp:734-736
t_load_directory_file: ^Type // core:runtime.Load_Directory_File
t_load_directory_file_ptr: ^Type // ^Load_Directory_File
t_load_directory_file_slice: ^Type // []Load_Directory_File

// Map runtime types
// C++ Reference: /mnt/c/odin/src/types.cpp:738-743
t_map_info: ^Type // core:runtime.Map_Info
t_map_cell_info: ^Type // core:runtime.Map_Cell_Info
t_raw_map: ^Type // core:runtime.Raw_Map
t_map_info_ptr: ^Type // ^Map_Info
t_map_cell_info_ptr: ^Type // ^Map_Cell_Info
t_raw_map_ptr: ^Type // ^Raw_Map

// Comparison/hashing procedure types for maps
// C++ Reference: /mnt/c/odin/src/types.cpp:750-751
t_equal_proc: ^Type // proc(rawptr, rawptr) -> bool {contextless}
t_hasher_proc: ^Type // proc(rawptr, uintptr) -> uintptr {contextless}

// Mutex to protect runtime type globals during reset
// This is needed because tests may run in parallel, creating/destroying multiple checkers
runtime_type_globals_mutex: sync.Mutex

// reset_runtime_type_globals clears all runtime-dependent type globals
// This MUST be called in destroy_checker to prevent stale pointers when
// tests use temp_allocator. Without this, the next test would read freed memory.
reset_runtime_type_globals :: proc() {
	sync.mutex_lock(&runtime_type_globals_mutex)
	defer sync.mutex_unlock(&runtime_type_globals_mutex)

	// Reset Objective-C runtime types
	// These are resolved out of the owning Checker's base:intrinsics scope
	// (init_objc_types), so they are owned by that checker's allocator and must not
	// survive it -- see t_objc_* usage in check_builtin.odin.
	t_objc_object = nil
	t_objc_selector = nil
	t_objc_class = nil
	t_objc_id = nil
	t_objc_SEL = nil
	t_objc_Class = nil

	// Reset C variadic types (resolved out of the owning checker's base:intrinsics scope)
	t_c_va_list = nil
	t_c_va_list_ptr = nil

	// Reset the calling-convention enum (owned by the universe scope's allocator)
	t_odin_calling_convention = nil

	// Reset RTTI types
	t_type_info = nil
	t_type_info_ptr = nil
	t_type_info_enum_value = nil
	t_type_info_enum_value_ptr = nil
	t_type_info_string_encoding_kind = nil

	// Reset Type_Info variant types
	t_type_info_named = nil
	t_type_info_integer = nil
	t_type_info_rune = nil
	t_type_info_float = nil
	t_type_info_quaternion = nil
	t_type_info_complex = nil
	t_type_info_string = nil
	t_type_info_boolean = nil
	t_type_info_any = nil
	t_type_info_typeid = nil
	t_type_info_pointer = nil
	t_type_info_multi_pointer = nil
	t_type_info_procedure = nil
	t_type_info_array = nil
	t_type_info_enumerated_array = nil
	t_type_info_dynamic_array = nil
	t_type_info_slice = nil
	t_type_info_parameters = nil
	t_type_info_struct = nil
	t_type_info_union = nil
	t_type_info_enum = nil
	t_type_info_map = nil
	t_type_info_bit_set = nil
	t_type_info_simd_vector = nil
	t_type_info_matrix = nil
	t_type_info_soa_pointer = nil
	t_type_info_bit_field = nil

	// Reset pointer types for Type_Info variants
	t_type_info_named_ptr = nil
	t_type_info_integer_ptr = nil
	t_type_info_rune_ptr = nil
	t_type_info_float_ptr = nil
	t_type_info_quaternion_ptr = nil
	t_type_info_complex_ptr = nil
	t_type_info_string_ptr = nil
	t_type_info_boolean_ptr = nil
	t_type_info_any_ptr = nil
	t_type_info_typeid_ptr = nil
	t_type_info_pointer_ptr = nil
	t_type_info_multi_pointer_ptr = nil
	t_type_info_procedure_ptr = nil
	t_type_info_array_ptr = nil
	t_type_info_enumerated_array_ptr = nil
	t_type_info_dynamic_array_ptr = nil
	t_type_info_slice_ptr = nil
	t_type_info_parameters_ptr = nil
	t_type_info_struct_ptr = nil
	t_type_info_union_ptr = nil
	t_type_info_enum_ptr = nil
	t_type_info_map_ptr = nil
	t_type_info_bit_set_ptr = nil
	t_type_info_simd_vector_ptr = nil
	t_type_info_matrix_ptr = nil
	t_type_info_soa_pointer_ptr = nil
	t_type_info_bit_field_ptr = nil

	// Reset core runtime types
	t_allocator = nil
	t_allocator_ptr = nil
	t_allocator_error = nil
	t_context = nil
	t_context_ptr = nil
	t_source_code_location = nil
	t_source_code_location_ptr = nil
	t_atomic_memory_order = nil

	// Reset load directory file types
	t_load_directory_file = nil
	t_load_directory_file_ptr = nil
	t_load_directory_file_slice = nil

	// Reset map runtime types
	t_map_info = nil
	t_map_cell_info = nil
	t_raw_map = nil
	t_map_info_ptr = nil
	t_map_cell_info_ptr = nil
	t_raw_map_ptr = nil

	// Reset comparison/hashing procedure types
	t_equal_proc = nil
	t_hasher_proc = nil
}

// init_basic_types initializes the basic type singletons
init_basic_types :: proc(allocator := context.allocator) {
	make_basic :: proc(kind: Basic_Kind, size: int, allocator: runtime.Allocator) -> ^Type {
		t := new(Type, allocator)
		t.kind = .Basic
		t.variant = Type_Basic {
			kind  = kind,
			flags = basic_flags_table[kind],
			size  = size,
		}
		return t
	}

	t_invalid = make_basic(.Invalid, 0, allocator)
	t_bool = make_basic(.Bool, 1, allocator)

	t_i8 = make_basic(.I8, 1, allocator)
	t_i16 = make_basic(.I16, 2, allocator)
	t_i32 = make_basic(.I32, 4, allocator)
	t_i64 = make_basic(.I64, 8, allocator)
	t_i128 = make_basic(.I128, 16, allocator)

	t_u8 = make_basic(.U8, 1, allocator)
	t_u16 = make_basic(.U16, 2, allocator)
	t_u32 = make_basic(.U32, 4, allocator)
	t_u64 = make_basic(.U64, 8, allocator)
	t_u128 = make_basic(.U128, 16, allocator)

	// Helper pointer types
	// NOTE: These MUST be allocated from `allocator` (the process-lifetime allocator),
	// not from the ambient `context.allocator`. They are basic-type singletons with the
	// same lifetime as t_u8/t_int above: they are never cleared by
	// reset_runtime_type_globals and are re-used by every subsequent Checker.
	// Leaving them on context.allocator made them outlive their backing memory whenever
	// a caller ran init_checker under a temp/arena allocator (as the tests do), and
	// add_type_info_type_internal then read a freed t_u8_ptr for every string/cstring.
	t_u8_ptr = alloc_type_pointer(t_u8, allocator)
	t_u8_slice = alloc_type_slice(t_u8, allocator)

	// Platform-dependent types
	when size_of(int) == 8 {
		t_int = make_basic(.Int, 8, allocator)
		t_uint = make_basic(.Uint, 8, allocator)
	} else {
		t_int = make_basic(.Int, 4, allocator)
		t_uint = make_basic(.Uint, 4, allocator)
	}
	t_uintptr = make_basic(.Uintptr, size_of(uintptr), allocator)

	t_f16 = make_basic(.F16, 2, allocator)
	t_f32 = make_basic(.F32, 4, allocator)
	t_f64 = make_basic(.F64, 8, allocator)

	// Rune type (distinct from i32)
	t_rune = make_basic(.Rune, 4, allocator)

	// Boolean size variants
	t_llvm_bool = make_basic(.Llvm_Bool, 1, allocator)
	t_b8 = make_basic(.B8, 1, allocator)
	t_b16 = make_basic(.B16, 2, allocator)
	t_b32 = make_basic(.B32, 4, allocator)
	t_b64 = make_basic(.B64, 8, allocator)

	// Complex types
	t_complex32 = make_basic(.Complex32, 4, allocator) // two f16
	t_complex64 = make_basic(.Complex64, 8, allocator)
	t_complex128 = make_basic(.Complex128, 16, allocator)

	// Quaternion types
	t_quaternion64 = make_basic(.Quaternion64, 8, allocator) // four f16
	t_quaternion128 = make_basic(.Quaternion128, 16, allocator) // four f32
	t_quaternion256 = make_basic(.Quaternion256, 32, allocator) // four f64

	// String types
	t_string = make_basic(.String, 16, allocator) // ptr + len (UTF-8)
	t_cstring = make_basic(.Cstring, 8, allocator) // ptr only (UTF-8)
	t_string16 = make_basic(.String16, 16, allocator) // ptr + len (UTF-16)
	t_cstring16 = make_basic(.Cstring16, 8, allocator) // ptr only (UTF-16)

	// Explicitly-endian types
	// C++ Reference: /mnt/c/odin/src/types.cpp:537-562 (the "// Endian" block of basic_types)
	t_i16le = make_basic(.I16le, 2, allocator)
	t_u16le = make_basic(.U16le, 2, allocator)
	t_i32le = make_basic(.I32le, 4, allocator)
	t_u32le = make_basic(.U32le, 4, allocator)
	t_i64le = make_basic(.I64le, 8, allocator)
	t_u64le = make_basic(.U64le, 8, allocator)
	t_i128le = make_basic(.I128le, 16, allocator)
	t_u128le = make_basic(.U128le, 16, allocator)

	t_i16be = make_basic(.I16be, 2, allocator)
	t_u16be = make_basic(.U16be, 2, allocator)
	t_i32be = make_basic(.I32be, 4, allocator)
	t_u32be = make_basic(.U32be, 4, allocator)
	t_i64be = make_basic(.I64be, 8, allocator)
	t_u64be = make_basic(.U64be, 8, allocator)
	t_i128be = make_basic(.I128be, 16, allocator)
	t_u128be = make_basic(.U128be, 16, allocator)

	t_f16le = make_basic(.F16le, 2, allocator)
	t_f32le = make_basic(.F32le, 4, allocator)
	t_f64le = make_basic(.F64le, 8, allocator)

	t_f16be = make_basic(.F16be, 2, allocator)
	t_f32be = make_basic(.F32be, 4, allocator)
	t_f64be = make_basic(.F64be, 8, allocator)

	t_rawptr = make_basic(.Rawptr, 8, allocator)
	t_typeid = make_basic(.Typeid, 8, allocator)
	t_any = make_basic(.Any, 16, allocator) // data + typeid

	// Untyped types
	t_untyped_bool = make_basic(.Untyped_Bool, 0, allocator)
	t_untyped_integer = make_basic(.Untyped_Integer, 0, allocator)
	t_untyped_float = make_basic(.Untyped_Float, 0, allocator)
	t_untyped_complex = make_basic(.Untyped_Complex, 0, allocator)
	t_untyped_quaternion = make_basic(.Untyped_Quaternion, 0, allocator)
	t_untyped_string = make_basic(.Untyped_String, 0, allocator)
	t_untyped_rune = make_basic(.Untyped_Rune, 0, allocator)
	t_untyped_nil = make_basic(.Untyped_Nil, 0, allocator)
	t_untyped_uninit = make_basic(.Untyped_Uninit, 0, allocator)
}

// Type checking utilities

// base_type is defined in check_type.odin

// is_type_untyped checks if type is an untyped constant type
// C++ Reference: /mnt/c/odin/src/types.cpp:2100-2109
is_type_untyped :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .Untyped in basic.flags
}

// is_type_typed checks if type is a concrete type
is_type_typed :: proc(t: ^Type) -> bool {
	// C++ Reference: types.cpp:1419-1426
	//   t = base_type(t); if (t == nullptr) return false;
	//   if (t->kind == Type_Basic) return (t->Basic.flags & BasicFlag_Untyped) == 0;
	//   return true;
	//
	// NOTE: this returns TRUE for t_invalid, which is a Basic type carrying no flags and so is
	// not "untyped". The previous implementation added `&& t != t_invalid`, which had no C++
	// counterpart and made callers diverge: internal_check_is_assignable_to would trip its
	// `c == nil` assert on an invalid type where C++ simply falls through
	// check_distance_between_types and answers -1, i.e. "not assignable".
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Basic {
		basic := bt.variant.(Type_Basic)
		return .Untyped not_in basic.flags
	}
	return true
}

// is_type_boolean checks if type is a boolean
// C++ Reference: /mnt/c/odin/src/types.cpp:1927-1942
is_type_boolean :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .Boolean in basic.flags
}

// is_type_integer checks if type is an integer
// C++ Reference: /mnt/c/odin/src/types.cpp:1944-1985
is_type_integer :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .Integer in basic.flags
}

// is_type_unsigned checks if type is an unsigned integer
// C++ Reference: /mnt/c/odin/src/types.cpp:1266-1276
is_type_unsigned :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Basic {
		basic := bt.variant.(Type_Basic)
		return .Unsigned in basic.flags
	}
	if bt.kind == .Enum {
		enum_type := bt.variant.(Type_Enum)
		return is_type_unsigned(enum_type.base_type)
	}
	return false
}

// is_type_float checks if type is a floating point
// C++ Reference: /mnt/c/odin/src/types.cpp:2019-2053
is_type_float :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .Float in basic.flags
}

// is_type_complex checks if type is complex
// C++ Reference: /mnt/c/odin/src/types.cpp:2055-2086
is_type_complex :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .Complex in basic.flags
}

// is_type_numeric checks if type is numeric
// C++ Reference: /mnt/c/odin/src/types.cpp:2094-2098
// C++ Reference: /mnt/c/odin/src/types.cpp:1373-1386
//
// The Enum and Array arms are not decoration: `+` and `-` test
// is_type_numeric on the operand type directly (check_expr.cpp:2182, 2197), so
// without the Enum arm an enum member defined from an earlier one -
// `Custom_Begin = COUNT + 1` - is rejected as non-numeric.
is_type_numeric :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		// Any numeric flag (Integer, Float, Complex, or Quaternion)
		return (basic.flags & BASIC_FLAG_NUMERIC) != {}
	case .Enum:
		e := &bt.variant.(Type_Enum)
		return is_type_numeric(e.base_type)
	case .Array:
		// NOTE(bill) in C++: "TODO(bill): Should this be here?" - kept for parity.
		a := &bt.variant.(Type_Array)
		return is_type_numeric(a.elem)
	}

	return false
}

// is_type_string checks if type is a string
is_type_string :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}

	basic := bt.variant.(Type_Basic)
	return .String in basic.flags
}

// is_type_pointer checks if type is a pointer
// Ported from types.cpp:1513-1520
// NOTE: this includes `rawptr`, which is a Basic type carrying Basic_Flag.Pointer,
// not a Type_Pointer. C++ dispatches on the flag for exactly this reason.
is_type_pointer :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Basic {
		basic := bt.variant.(Type_Basic)
		return .Pointer in basic.flags
	}
	return bt.kind == .Pointer
}

// is_type_proc is defined in check_type.odin

// is_type_rune checks if a type is a rune type
// Ported from types.cpp:1285-1292
// Uses Basic_Flag.Rune to check for both typed (.Rune) and untyped (.Untyped_Rune) runes
is_type_rune :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Basic {
		basic := bt.variant.(Type_Basic)
		return .Rune in basic.flags
	}
	return false
}

// is_type_rawptr checks if a type is rawptr
// Ported from types.cpp:1463-1469
is_type_rawptr :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	if t.kind == .Basic {
		basic := t.variant.(Type_Basic)
		return basic.kind == .Rawptr
	}
	return false
}

// is_type_typeid checks if a type is typeid
// Ported from types.cpp:2093-2097
is_type_typeid :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Basic {
		basic := bt.variant.(Type_Basic)
		return basic.kind == .Typeid
	}
	return false
}

// is_type_quaternion checks if a type is a quaternion type
// Ported from types.cpp:1413-1420
is_type_quaternion :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == nil {
		return false
	}
	if ct.kind == .Basic {
		basic := ct.variant.(Type_Basic)
		return .Quaternion in basic.flags
	}
	return false
}

// is_type_matrix checks if a type is a matrix type
// Ported from types.cpp:1494-1498
is_type_matrix :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Matrix
}

// is_type_bit_set checks if a type is a bit_set type
// Ported from types.cpp:1877-1881
// is_type_fixed_capacity_dynamic_array reports whether a type is `[dynamic; N]T`.
// C++ Reference: types.cpp:1731.
is_type_fixed_capacity_dynamic_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Fixed_Capacity_Dynamic_Array
}

is_type_bit_set :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Bit_Set
}

// is_type_bit_field checks if a type is a bit_field type
// Ported from types.cpp:1882-1886
is_type_bit_field :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Bit_Field
}

// ============================================================================
// Type Predicates - Critical Infrastructure (Week 1 Group 1)
// C++ Reference: /mnt/c/odin/src/types.cpp:1484-2119, 2333-2372
// ============================================================================

// is_type_array checks if a type is a fixed-size array
// C++ Reference: /mnt/c/odin/src/types.cpp:1484-1488
is_type_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Array
}

// is_type_enum is defined in check_type.odin

// is_type_union is defined in check_type.odin

// is_type_raw_union checks if type is a #raw_union (no tag field)
// C++ Reference: /mnt/c/odin/src/types.cpp:1867-1871
// Note: In the C++ codebase, raw unions are represented as Type_Struct with is_raw_union flag,
// not as Type_Union. This follows that architecture.
is_type_raw_union :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind != .Struct {
		return false
	}
	s := bt.variant.(Type_Struct)
	return s.is_raw_union
}

// is_type_union_constantable checks if union can appear in constant expressions
// C++ Reference: /mnt/c/odin/src/types.cpp:2516-2532
is_type_union_constantable :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Union {
		return false
	}

	u := bt.variant.(Type_Union)

	// Empty unions are constantable
	if len(u.variants) == 0 {
		return true
	}

	// Single-variant unions are constantable if the variant is constantable
	if len(u.variants) == 1 {
		return is_type_constant_type(u.variants[0])
	}

	// Multi-variant unions are constantable if all variants are constantable
	for v in u.variants {
		if !is_type_constant_type(v) {
			return false
		}
	}
	return true
}

// is_type_raw_union_constantable combines raw union and constantable checks
// C++ Reference: /mnt/c/odin/src/types.cpp:2534-2545
is_type_raw_union_constantable :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Struct {
		return false
	}

	s := bt.variant.(Type_Struct)
	if !s.is_raw_union {
		return false
	}

	// All fields must be constantable
	for field in s.fields {
		if !is_type_constant_type(field.type) {
			return false
		}
	}
	// return true
	return false // Disable raw union constants for the time being
}

// is_type_any is defined in check_expr.odin

// is_type_empty_union is defined in check_equivalence.odin

// is_type_polymorphic is defined in check_equivalence.odin

// type_get_polymorphic_parent retrieves the parent entity of a polymorphic type
// C++ Reference: /mnt/c/odin/src/types.cpp:2249-2268
// Returns the parent type's entity and optionally the polymorphic parameters
type_get_polymorphic_parent :: proc(t: ^Type, params: ^^Type = nil) -> ^Entity {
	bt := base_type(t)
	if bt == nil {
		return nil
	}

	parent: ^Type = nil

	// Check for polymorphic parent based on type kind
	#partial switch bt.kind {
	case .Struct:
		s := &bt.variant.(Type_Struct)
		parent = s.polymorphic_parent
		if params != nil {
			params^ = s.polymorphic_params
		}
	case .Union:
		u := &bt.variant.(Type_Union)
		parent = u.polymorphic_parent
		if params != nil {
			params^ = u.polymorphic_params
		}
	}

	// Extract the entity from the parent type
	if parent != nil {
		assert(parent.kind == .Named, "Polymorphic parent must be a named type")
		named := &parent.variant.(Type_Named)
		return named.type_name
	}

	return nil
}

// is_type_polymorphic_record checks if type is a polymorphic struct or union
// C++ Reference: /mnt/c/odin/src/types.cpp:2270-2278
is_type_polymorphic_record :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Struct:
		s := &bt.variant.(Type_Struct)
		return s.is_polymorphic
	case .Union:
		u := &bt.variant.(Type_Union)
		return u.is_polymorphic
	}

	return false
}

// is_type_polymorphic_record_specialized checks if polymorphic record has been specialized
// C++ Reference: /mnt/c/odin/src/types.cpp:2292-2300
// polymorphic_record_parent_scope returns the scope a polymorphic record was
// DECLARED in, which is where its field types must be looked up.
//
// C++ Reference: /mnt/c/odin/src/types.cpp:2420-2430
polymorphic_record_parent_scope :: proc(t: ^Type) -> ^Scope {
	bt := base_type(t)
	if bt != nil && is_type_polymorphic_record(bt) {
		#partial switch bt.kind {
		case .Struct:
			st := &bt.variant.(Type_Struct)
			if st.scope != nil {
				return st.scope.parent
			}
		case .Union:
			ut := &bt.variant.(Type_Union)
			if ut.scope != nil {
				return ut.scope.parent
			}
		}
	}
	return nil
}

is_type_polymorphic_record_specialized :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Struct:
		s := &bt.variant.(Type_Struct)
		return s.is_poly_specialized
	case .Union:
		u := &bt.variant.(Type_Union)
		return u.is_poly_specialized
	}

	return false
}

// is_type_polymorphic_record_unspecialized checks if polymorphic record is NOT specialized
// C++ Reference: /mnt/c/odin/src/types.cpp:2302-2310
is_type_polymorphic_record_unspecialized :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Struct:
		s := &bt.variant.(Type_Struct)
		return s.is_polymorphic && !s.is_poly_specialized
	case .Union:
		u := &bt.variant.(Type_Union)
		return u.is_polymorphic && !u.is_poly_specialized
	}

	return false
}

// Array-related type predicates needed for index expression support
// Note: is_type_slice exists in check_expr.odin:2744
// Note: base_array_type exists in check_expr.odin:1233

// is_type_enumerated_array checks if a type is an enumerated array
// Reference: Used throughout C++ codebase
is_type_enumerated_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Enumerated_Array
}

// is_type_dynamic_array checks if a type is a dynamic array
// Reference: Used throughout C++ codebase
is_type_dynamic_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Dynamic_Array
}

// is_type_map checks if a type is a map
// Reference: Used throughout C++ codebase
is_type_map :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Map
}

// is_type_multi_pointer checks if a type is a multi-pointer ([^]T)
// Reference: Used throughout C++ codebase
is_type_multi_pointer :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Multi_Pointer
}

// is_type_soa_pointer is defined in check_type.odin

// is_type_internally_pointer_like checks if a type behaves like a pointer internally
// C++ Reference: /mnt/c/odin/src/types.cpp:1447-1449
is_type_internally_pointer_like :: proc(t: ^Type) -> bool {
	return is_type_pointer(t) || is_type_multi_pointer(t) || is_type_cstring(t) || is_type_proc(t)
}

// is_type_dereferenceable checks if a type can be dereferenced with ^
// C++ Reference: /mnt/c/odin/src/types.cpp:2029-2034
is_type_dereferenceable :: proc(t: ^Type) -> bool {
	if is_type_rawptr(t) {
		return false
	}
	return is_type_pointer(t) || is_type_soa_pointer(t)
}

// is_type_uintptr checks if a type is uintptr
// Ported from types.cpp:1456-1462
is_type_uintptr :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	if t.kind == .Basic {
		basic := t.variant.(Type_Basic)
		return basic.kind == .Uintptr
	}
	return false
}

// is_type_u8 checks if a type is u8
// Helper function for pointer/slice predicates
// Ported from types.cpp:1470-1476
is_type_u8 :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	if t.kind == .Basic {
		basic := t.variant.(Type_Basic)
		return basic.kind == .U8
	}
	return false
}

// is_type_u16 checks if a type is u16
// Helper function for pointer/slice predicates
// Ported from types.cpp:1477-1483
is_type_u16 :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	if t.kind == .Basic {
		basic := t.variant.(Type_Basic)
		return basic.kind == .U16
	}
	return false
}

// is_type_u8_slice checks if a type is []u8
// Ported from types.cpp:1705-1712
is_type_u8_slice :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Slice {
		slice := bt.variant.(Type_Slice)
		return is_type_u8(slice.elem)
	}
	return false
}

// is_type_u16_slice checks if a type is []u16
// Ported from types.cpp:1746-1753
is_type_u16_slice :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Slice {
		slice := bt.variant.(Type_Slice)
		return is_type_u16(slice.elem)
	}
	return false
}

// is_type_u8_ptr checks if a type is ^u8
// Ported from types.cpp:1721-1728
is_type_u8_ptr :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Pointer {
		ptr := bt.variant.(Type_Pointer)
		return is_type_u8(ptr.elem)
	}
	return false
}

// is_type_u16_ptr checks if a type is ^u16
// Ported from types.cpp:1762-1769
is_type_u16_ptr :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Pointer {
		ptr := bt.variant.(Type_Pointer)
		return is_type_u16(ptr.elem)
	}
	return false
}

// is_type_u8_multi_ptr checks if a type is [^]u8
// Ported from types.cpp:1729-1736
is_type_u8_multi_ptr :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Multi_Pointer {
		mp := bt.variant.(Type_Multi_Pointer)
		return is_type_u8(mp.elem)
	}
	return false
}

// is_type_u16_multi_ptr checks if a type is [^]u16
// Ported from types.cpp:1770-1777
is_type_u16_multi_ptr :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind == .Multi_Pointer {
		mp := bt.variant.(Type_Multi_Pointer)
		return is_type_u16(mp.elem)
	}
	return false
}

// is_type_simd_vector checks if a type is a SIMD vector
// Reference: Used throughout C++ codebase
is_type_simd_vector :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Simd_Vector
}

// is_type_indexable checks if a type supports indexing operations (x[i])
// Returns true for: string, string16, Array, Slice, Dynamic_Array, Map,
// Multi_Pointer, Enumerated_Array, Matrix
// C++ Reference: types.cpp:2212-2230
is_type_indexable :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		// Reference: types.cpp:2216
		return basic.kind == .String || basic.kind == .String16
	case .Array, .Slice, .Dynamic_Array, .Map, .Multi_Pointer, .Enumerated_Array, .Matrix:
		return true
	}

	return false
}

// is_type_sliceable checks if a type supports slicing operations (x[i:j])
// C++ Reference: /mnt/c/odin/src/types.cpp:2232-2247
// Note: EnumeratedArray is NOT sliceable, Matrix is NOT sliceable (unlike indexable)
is_type_sliceable :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		// String and String16 are sliceable
		return basic.kind == .String || basic.kind == .String16

	case .Array, .Slice, .Dynamic_Array:
		return true

	case .Enumerated_Array:
		// Enumerated arrays are NOT sliceable (C++ line 2241-2242)
		return false

	case .Matrix:
		// Matrices are NOT sliceable (C++ line 2243-2244)
		return false
	}

	return false
}

// ============================================================================
// Type Predicates - Tier 2 Infrastructure (Week 2 Group 1)
// C++ Reference: /mnt/c/odin/src/types.cpp:1644-1663, 1323-1330, 1451-1455, 1851-1855
// ============================================================================

// is_type_slice is defined in check_builtin_simd.odin

// is_type_cstring is defined in check_expr.odin

// is_type_tuple checks if a type is a tuple
// C++ Reference: /mnt/c/odin/src/types.cpp:1451-1455
is_type_tuple :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	return bt.kind == .Tuple
}

// is_type_struct is defined in check_equivalence.odin

// ============================================================================
// Type Helper Functions - Critical Infrastructure (Week 1 Group 2)
// C++ Reference: /mnt/c/odin/src/types.cpp:931-954, 1202-1225, 1665-1677, 1798-1811
// ============================================================================

// core_type unwraps named types, enums, and bit fields to get the core type
// Unlike base_type which only unwraps Named, this also unwraps Enum and Bit_Field
// C++ Reference: /mnt/c/odin/src/types.cpp:931-954
// base_enum_type returns an enum's backing type, or the type unchanged if it is
// not an enum.
//
// C++ Reference: /mnt/c/odin/src/types.cpp:976-983
base_enum_type :: proc(t: ^Type) -> ^Type {
	bt := base_type(t)
	if bt != nil && bt.kind == .Enum {
		e := &bt.variant.(Type_Enum)
		return e.base_type
	}
	return t
}

core_type :: proc(t: ^Type) -> ^Type {
	if t == nil {
		return nil
	}

	result := t
	for {
		if result == nil {
			break
		}

		#partial switch result.kind {
		case .Named:
			named := result.variant.(Type_Named)
			// Guard against circular reference
			if result == named.base {
				return t_invalid
			}
			result = named.base
			continue

		case .Enum:
			enum_type := result.variant.(Type_Enum)
			result = enum_type.base_type
			continue

		case .Bit_Field:
			bf := result.variant.(Type_Bit_Field)
			result = bf.backing_type
			continue
		}
		break
	}

	return result
}

// type_deref is defined in check_equivalence.odin

// base_array_type is defined in check_builtin_simd.odin

// core_array_type combines core_type and base_array_type in a loop
// Unwraps nested array-like types until reaching the core element
// C++ Reference: /mnt/c/odin/src/types.cpp:1798-1811
core_array_type :: proc(t: ^Type) -> ^Type {
	result := t
	for {
		result = base_array_type(result)

		// Continue unwrapping if still an array-like type
		#partial switch result.kind {
		case .Array, .Enumerated_Array, .Simd_Vector, .Matrix:
			continue
		}

		// Reached non-array type
		break
	}

	return result
}

// Selection Infrastructure
// These types and functions support selector expressions (x.y)
// Reference: /mnt/c/odin/src/types.cpp:421-450

// Selection represents a field/member access path
// Used by selector expressions to track which field was selected
// and how to access it (including pointer indirection)
// Ported from types.cpp:421-429
Selection :: struct {
	entity:          ^Entity, // The selected field, enum value, or member
	index:           [dynamic]i32, // Path indices for nested field access (e.g., [0, 2] for field 0, subfield 2)
	indirect:        bool, // True if pointer dereference occurred anywhere in the path
	swizzle_count:   u8, // Number of swizzle components (max 4, for .xyzw)
	swizzle_indices: u8, // Packed swizzle indices (2 bits per component)
	is_bit_field:    bool, // True if this is a bit field access
	pseudo_field:    bool, // True for synthetic fields (ObjC, compiler-generated)
}

// Global empty selection constant
// Reference: types.cpp:430
empty_selection := Selection{}

// make_selection creates a new Selection with the given entity and index path
// Ported from types.cpp:432-435
make_selection :: proc(entity: ^Entity, index: [dynamic]i32, indirect: bool) -> Selection {
	return Selection{entity = entity, index = index, indirect = indirect}
}

// selection_add_index appends an index to the selection path
// Ported from types.cpp:437-442
selection_add_index :: proc(sel: ^Selection, index: int) {
	append(&sel.index, i32(index))
}

// selection_combine merges two selections, combining their index paths
// Used for nested field access through 'using' fields
// Ported from types.cpp:444-450
selection_combine :: proc(lhs: Selection, rhs: Selection) -> Selection {
	new_sel := lhs
	new_sel.indirect = lhs.indirect || rhs.indirect

	// Combine index arrays
	new_sel.index = make([dynamic]i32, len(lhs.index) + len(rhs.index))
	copy(new_sel.index[:], lhs.index[:])
	copy(new_sel.index[len(lhs.index):], rhs.index[:])

	return new_sel
}

// are_types_identical is defined in check_equivalence.odin

// Type construction

// make_pointer_type creates a pointer type
make_pointer_type :: proc(elem: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Pointer
	t.variant = Type_Pointer {
		elem = elem,
	}
	return t
}

// make_array_type creates an array type
// C++ Reference: types.cpp:1076-1085 (alloc_type_array). The generic_count parameter records the
// `$N` of `[$N]T`; without it polymorphic_assign_index is never reached and `[$N]$E` cannot bind.
make_array_type :: proc(elem: ^Type, count: i64, generic_count: ^Type = nil, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Array
	t.variant = Type_Array {
		elem          = elem,
		count         = count,
		generic_count = generic_count,
	}
	return t
}

// make_slice_type creates a slice type
make_slice_type :: proc(elem: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Slice
	t.variant = Type_Slice {
		elem = elem,
	}
	return t
}

// make_dynamic_array_type creates a dynamic array type
make_dynamic_array_type :: proc(elem: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Dynamic_Array
	t.variant = Type_Dynamic_Array {
		elem = elem,
	}
	return t
}

// make_fixed_capacity_dynamic_array_type creates a `[dynamic; N]T` type.
// C++ Reference: types.cpp:1141-1155 (alloc_type_fixed_capacity_dynamic_array). The two C++ branches
// are identical apart from assigning generic_capacity, so this is a single path.
make_fixed_capacity_dynamic_array_type :: proc(
	elem: ^Type,
	capacity: i64,
	generic_capacity: ^Type = nil,
	allocator := context.allocator,
) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Fixed_Capacity_Dynamic_Array
	t.variant = Type_Fixed_Capacity_Dynamic_Array {
		elem             = elem,
		capacity         = capacity,
		generic_capacity = generic_capacity,
		padding_needed   = -1, // C++ initialises to -1, meaning "not yet computed"
	}
	return t
}

// make_map_type creates a map type
make_map_type :: proc(key, value: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Map
	t.variant = Type_Map {
		key   = key,
		value = value,
	}
	return t
}

// make_named_type creates a named type
make_named_type :: proc(name: string, base: ^Type, type_name: ^Entity = nil, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Named
	t.variant = Type_Named {
		name      = name,
		base      = base,
		type_name = type_name,
	}
	return t
}

// make_type_generic creates a generic/polymorphic type parameter ($T)
// Reference: /mnt/c/odin/src/types.cpp alloc_type_generic
// Used for polymorphic procedure type parameters like $T: typeid
make_type_generic :: proc(scope: ^Scope, name: string, specialized: ^Type = nil, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Generic
	t.variant = Type_Generic {
		name        = name,
		specialized = specialized,
		scope       = scope,
		entity      = nil, // Set later when entity is created
	}
	return t
}

// default_type is defined in check_decl_helpers.odin

// bit_set_to_int converts a bit_set type to its underlying integer type
// C++ Reference: /mnt/c/odin/src/types.cpp:2162-2184
bit_set_to_int :: proc(t: ^Type) -> ^Type {
	assert(is_type_bit_set(t), "bit_set_to_int: type must be a bit_set")

	bt := base_type(t)
	bs := bt.variant.(Type_Bit_Set)

	// If there's an explicit underlying type, use it
	if bs.underlying != nil && is_type_integer(bs.underlying) {
		return bs.underlying
	}

	// Calculate size based on bit range
	// C++ Reference: /mnt/c/odin/src/types.cpp:4500-4509
	bits := bs.upper - bs.lower + 1
	sz: int
	if bits <= 8 {
		sz = 1
	} else if bits <= 16 {
		sz = 2
	} else if bits <= 32 {
		sz = 4
	} else if bits <= 64 {
		sz = 8
	} else if bits <= 128 {
		sz = 16
	} else {
		sz = 8 // Invalid range, limit to 8 bytes
	}

	// Map size to integer type
	switch sz {
	case 0:
		return t_u8
	case 1:
		return t_u8
	case 2:
		return t_u16
	case 4:
		return t_u32
	case 8:
		return t_u64
	case 16:
		return t_u128
	}

	panic("bit_set_to_int: unknown bit_set size")
}

// Type size and alignment

// type_size_of returns the size of a type in bytes
// matrix_type_stride_in_bytes calculates the stride between matrix rows/columns in bytes
// C++ Reference: /mnt/c/odin/src/types.cpp:1537-1567
matrix_type_stride_in_bytes :: proc(t: ^Type) -> int {
	bt := base_type(t)
	assert(bt.kind == .Matrix)

	mat := bt.variant.(Type_Matrix)

	// Return cached value if available
	if mat.stride_in_bytes != 0 {
		return mat.stride_in_bytes
	}

	if mat.row_count == 0 {
		return 0
	}

	elem_size := type_size_of(mat.elem)

	// C++ Reference: types.cpp:1555-1564
	// NOTE(bill, 2021-10-25): The alignment strategy here is to have zero padding
	// It would be better for performance to pad each column/row so that each column/row
	// could be maximally aligned but as a compromise, having no padding will be
	// beneficial to third libraries that assume no padding

	stride_in_bytes: int
	if mat.is_row_major {
		stride_in_bytes = elem_size * int(mat.column_count)
	} else {
		stride_in_bytes = elem_size * int(mat.row_count)
	}

	// Cache the result
	mut_mat := &bt.variant.(Type_Matrix)
	mut_mat.stride_in_bytes = stride_in_bytes

	return stride_in_bytes
}

// matrix_type_stride_in_elems calculates the stride between matrix rows/columns in elements
// C++ Reference: /mnt/c/odin/src/types.cpp:1569-1574
matrix_type_stride_in_elems :: proc(t: ^Type) -> int {
	bt := base_type(t)
	assert(bt.kind == .Matrix)

	mat := bt.variant.(Type_Matrix)
	stride := matrix_type_stride_in_bytes(t)
	elem_size := max(1, type_size_of(mat.elem))

	return stride / elem_size
}

type_size_of :: proc(t: ^Type) -> int {
	bt := base_type(t)
	if bt == nil {
		return 0
	}

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		return basic.size

	case .Pointer, .Multi_Pointer, .Soa_Pointer:
		return 8 // Assuming 64-bit

	case .Array:
		arr := bt.variant.(Type_Array)
		return int(arr.count) * type_size_of(arr.elem)

	case .Slice:
		return 16 // ptr + len

	case .Dynamic_Array:
		// C++ Reference: types.cpp type_size_of_internal, `3*int_size + 2*ptr_size`.
		//   struct { data: rawptr, len: int, cap: int, allocator: runtime.Allocator }
		// The allocator is TWO words (procedure + data); the port's hardcoded 24 counted
		// only data/len/cap, so every `[dynamic]T` measured 24 where the matching
		// runtime.Raw_Dynamic_Array measured 40 — and every transmute between the two
		// (the standard idiom for reaching a dynamic array's internals) failed.
		return 3 * int(build_context.int_size) + 2 * int(build_context.ptr_size)

	case .Map:
		// C++ Reference: types.cpp type_size_of_internal, `(1 + 1 + 2)*ptr_size`.
		//   struct { data: uintptr, size: uintptr, allocator: runtime.Allocator }
		// The port returned a single word, so `map[K]V` measured 8 against
		// runtime.Raw_Map's 32.
		return 4 * int(build_context.ptr_size)

	case .Struct:
		// C++ Reference: types.cpp:4436-4474
		struc := bt.variant.(Type_Struct)

		// Handle raw_union case
		// C++ Reference: types.cpp:4437-4450
		if struc.is_raw_union {
			count := len(struc.fields)
			align := type_align_of(bt)
			max_size := 0
			for i in 0 ..< count {
				// Read the field type via entity_type(), NOT Entity.type.
				// For struct field entities in this port only the VARIANT carries the type;
				// Entity.type is nil (verified by instrumentation: f0.type=<nil> while
				// f0.variant.(Entity_Variable).type=int). type_offset_of already goes through
				// the variant, which is why it returned the correct offset 8 while this
				// returned size 0 — `struct { a: int, b: int }` measured 8 instead of 16.
				field_size := type_size_of(entity_type(struc.fields[i]))
				if max_size < field_size {
					max_size = field_size
				}
			}
			// align_formula: align size to alignment
			result := max_size + align - 1
			return result - (result % align)
		}

		// Handle regular struct case
		// C++ Reference: types.cpp:4451-4473
		count := len(struc.fields)
		if count == 0 {
			return 0
		}

		align := type_align_of(bt)

		// Calculate offset of last field + its size
		// C++ Reference: types.cpp:4471
		last_field_offset := type_offset_of(bt, i64(count - 1))
		// See the note in the raw_union arm above: struct field types live on the variant,
		// so read them through entity_type().
		last_field_size := type_size_of(entity_type(struc.fields[count - 1]))
		size := int(last_field_offset) + last_field_size

		// Align final struct size to struct alignment
		// C++ Reference: types.cpp:4472
		result := size + align - 1
		return result - (result % align)

	case .Matrix:
		// C++ Reference: types.cpp:4495-4502
		mat := bt.variant.(Type_Matrix)
		stride_in_bytes := matrix_type_stride_in_bytes(t)
		if mat.is_row_major {
			return stride_in_bytes * int(mat.row_count)
		} else {
			return stride_in_bytes * int(mat.column_count)
		}

	// C++ Reference: types.cpp type_size_of_internal, case Type_Enum.
	case .Enum:
		en := bt.variant.(Type_Enum)
		return type_size_of(en.base_type)

	// C++ Reference: types.cpp type_size_of_internal, case Type_BitSet.
	case .Bit_Set:
		bs := bt.variant.(Type_Bit_Set)
		if bs.underlying != nil {
			return type_size_of(bs.underlying)
		}
		bits := bs.upper - bs.lower + 1
		switch {
		case bits <= 8:   return 1
		case bits <= 16:  return 2
		case bits <= 32:  return 4
		case bits <= 64:  return 8
		case bits <= 128: return 16
		}
		// C++: "Could be an invalid range so limit it for now"
		return 8

	// C++ Reference: types.cpp type_size_of_internal, case Type_SimdVector.
	case .Simd_Vector:
		sv := bt.variant.(Type_Simd_Vector)
		return int(sv.count) * type_size_of(sv.elem)

	// C++ Reference: types.cpp type_size_of_internal, case Type_Union.
	case .Union:
		un := bt.variant.(Type_Union)
		if len(un.variants) == 0 {
			return 0
		}
		align := type_align_of(bt)

		max_variant := 0
		for variant_type in un.variants {
			vs := type_size_of(variant_type)
			if max_variant < vs {
				max_variant = vs
			}
		}

		size := 0
		if is_type_union_maybe_pointer(bt) {
			// A #maybe-pointer union needs no tag: the pointer's nil state IS the tag.
			size = max_variant
			set_union_variant_block_size(bt, i64(size))
		} else {
			tag_size := union_tag_size(bt)
			// Align the variant block to the tag, then append the tag.
			if tag_size > 0 {
				size = (max_variant + tag_size - 1) - ((max_variant + tag_size - 1) % tag_size)
			} else {
				size = max_variant
			}
			// C++ Reference: types.cpp:4773 — record the block size BEFORE the tag is
			// appended and before the final alignment. This is the tag's offset within
			// the union, and it was never stored: `type_offset_of` (index -1) and
			// `intrinsics.type_union_tag_offset` read the field, so every tagged union
			// reported a tag offset of 0, overlapping the variant block.
			set_union_variant_block_size(bt, i64(size))
			size += tag_size
		}
		if align > 0 {
			size = (size + align - 1) - ((size + align - 1) % align)
		}
		return size

	// C++ Reference: types.cpp type_size_of_internal, case Type_BitField.
	case .Bit_Field:
		bf := bt.variant.(Type_Bit_Field)
		return type_size_of(bf.backing_type)

	// C++ Reference: types.cpp type_size_of_internal, case Type_Proc — a procedure VALUE
	// is a pointer.
	case .Proc:
		return int(build_context.ptr_size)

	// C++ Reference: types.cpp type_size_of_internal, case Type_Tuple.
	case .Tuple:
		tup := bt.variant.(Type_Tuple)
		count := len(tup.variables)
		if count == 0 {
			return 0
		}
		align := type_align_of(bt)
		last_offset := type_offset_of(bt, i64(count - 1))
		size := int(last_offset) + type_size_of(entity_type(tup.variables[count - 1]))
		if align > 0 {
			size = (size + align - 1) - ((size + align - 1) % align)
		}
		return size

	case:
		// NOTE: reaching here means the kind has no size rule and silently measures 0,
		// which then surfaces as "Cannot transmute to 'X', N vs 0 bytes" and as
		// size-0 comparisons far from the real cause. Every kind C++ gives a size rule in
		// types.cpp type_size_of_internal is now handled above; anything reaching here is a
		// kind neither compiler sizes, or a genuinely new one.
		return 0
	}
}

// type_align_of is defined in check_type.odin

// is_type_comparable checks if a type can be used with == and != operators
// C++ Reference: /mnt/c/odin/src/types.cpp:2592-2662
is_type_comparable :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	bt := base_type(t)

	#partial switch bt.kind {
	case .Basic:
		// Most basic types are comparable except UntypedNil and any
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .Untyped_Nil, .Any:
			return false
		case .Untyped_Rune:
			return true
		// C++ Reference: types.cpp:2618-2622
		// String types including UTF-16 variants are comparable
		case .String, .Cstring, .Untyped_String, .String16, .Cstring16:
			return true
		case .Typeid:
			return true
		}
		// All other basic types (bool, integers, floats, complex, rawptr) are comparable
		return true

	case .Pointer:
		return true

	case .Soa_Pointer:
		return true

	case .Multi_Pointer:
		return true

	case .Enum:
		// Enums delegate to their core type
		return is_type_comparable(core_type(bt))

	case .Enumerated_Array:
		// Enumerated arrays are comparable if their elements are
		enum_arr := bt.variant.(Type_Enumerated_Array)
		return is_type_comparable(enum_arr.elem)

	case .Array:
		// Arrays are comparable if their elements are
		arr := bt.variant.(Type_Array)
		return is_type_comparable(arr.elem)

	case .Proc:
		return true

	case .Matrix:
		// Matrices are comparable if their elements are
		mat := bt.variant.(Type_Matrix)
		return is_type_comparable(mat.elem)

	case .Bit_Set:
		return true

	case .Struct:
		struc := bt.variant.(Type_Struct)
		// SOA structs are not comparable
		if struc.soa_kind != .None {
			return false
		}
		// Raw unions delegate to is_type_simple_compare
		if struc.is_raw_union {
			return is_type_simple_compare(bt)
		}
		// Regular structs are comparable if all fields are comparable
		// C++ Reference: types.cpp:2654-2658 - uses entity type directly
		for field in struc.fields {
			if field.kind == .Variable {
				field_type := entity_type(field)
				if field_type != nil && !is_type_comparable(field_type) {
					return false
				}
			}
		}
		return true

	case .Union:
		// Unions are comparable if all variants are comparable
		union_type := bt.variant.(Type_Union)
		for variant in union_type.variants {
			if !is_type_comparable(variant) {
				return false
			}
		}
		return true

	case .Simd_Vector:
		return true

	case .Bit_Field:
		// Bit fields delegate to their backing type
		bf := bt.variant.(Type_Bit_Field)
		return is_type_comparable(bf.backing_type)
	}

	return false
}

// is_type_simple_compare checks if a type can be compared using memcmp
// C++ Reference: /mnt/c/odin/src/types.cpp:2665-2718
// Simple compare means the type has no padding bytes and all bits participate in equality
is_type_simple_compare :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == nil {
		return false
	}

	#partial switch ct.kind {
	case .Array:
		// Arrays are simple compare if their elements are
		arr := ct.variant.(Type_Array)
		return is_type_simple_compare(arr.elem)

	case .Enumerated_Array:
		// Enumerated arrays are simple compare if their elements are
		enum_arr := ct.variant.(Type_Enumerated_Array)
		return is_type_simple_compare(enum_arr.elem)

	case .Basic:
		// Basic types with SimpleCompare flag, or typeid
		// C++ Reference: types.cpp:2673-2677
		basic := ct.variant.(Type_Basic)
		if basic.kind == .Typeid {
			return true
		}
		// Check using BASIC_FLAG_SIMPLE_COMPARE composite flag
		// SIMPLE_COMPARE = Boolean | Integer | Pointer | Rune
		// Note: String types are NOT simple compare (have length field)
		return (basic.flags & BASIC_FLAG_SIMPLE_COMPARE) != {}

	case .Pointer, .Multi_Pointer, .Soa_Pointer:
		// Pointers are simple compare (just compare the address)
		return true

	case .Proc:
		// Procedures are simple compare (compare function pointer)
		return true

	case .Bit_Set:
		// Bit sets are simple compare (backed by integer)
		return true

	case .Matrix:
		// Matrices are simple compare if their elements are
		mat := ct.variant.(Type_Matrix)
		return is_type_simple_compare(mat.elem)

	case .Struct:
		// Structs are simple compare if:
		// 1. All fields are simple compare
		// 2. There's no padding between fields (C++ Reference: types.cpp:2665-2718)
		struc := ct.variant.(Type_Struct)

		// Packed structs have no padding
		if struc.is_packed {
			for field in struc.fields {
				if field.kind == .Variable {
					field_type := entity_type(field)
					if field_type != nil && !is_type_simple_compare(field_type) {
						return false
					}
				}
			}
			return true
		}

		// For non-packed structs, check for padding by comparing
		// sum of field sizes vs total struct size
		total_field_size := 0
		for field in struc.fields {
			if field.kind == .Variable {
				field_type := entity_type(field)
				if field_type != nil {
					if !is_type_simple_compare(field_type) {
						return false
					}
					total_field_size += type_size_of(field_type)
				}
			}
		}

		// If struct size != sum of field sizes, there's padding
		struct_size := type_size_of(ct)
		if struct_size != total_field_size {
			return false // Has padding, can't use memcmp
		}

		return true

	case .Union:
		// Unions are simple compare only if they have exactly one variant
		// and that variant is simple compare (C++ line 2710)
		union_type := ct.variant.(Type_Union)
		if len(union_type.variants) != 1 {
			return false
		}
		for variant in union_type.variants {
			if !is_type_simple_compare(variant) {
				return false
			}
		}
		return true

	case .Simd_Vector:
		// SIMD vectors are simple compare if their elements are
		simd := ct.variant.(Type_Simd_Vector)
		return is_type_simple_compare(simd.elem)
	}

	return false
}

// is_type_nearly_simple_compare checks if type can be easily compared using memcmp or contains a float
// NOTE: This is less strict than is_type_simple_compare - it allows numeric types including floats
// C++ Reference: /mnt/c/odin/src/types.cpp:2720-2773
is_type_nearly_simple_compare :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == nil {
		return false
	}

	#partial switch ct.kind {
	case .Array:
		arr := ct.variant.(Type_Array)
		return is_type_nearly_simple_compare(arr.elem)

	case .Enumerated_Array:
		enum_arr := ct.variant.(Type_Enumerated_Array)
		return is_type_nearly_simple_compare(enum_arr.elem)

	case .Basic:
		// C++ checks: BasicFlag_SimpleCompare | BasicFlag_Numeric
		basic := ct.variant.(Type_Basic)
		#partial switch basic.kind {
		case .Typeid:
			return true
		// All numeric types (integers, floats, complex)
		case .I8, .I16, .I32, .I64, .I128, .Int:
			return true
		case .U8, .U16, .U32, .U64, .U128, .Uint, .Uintptr:
			return true
		case .Bool:
			return true
		case .F16, .F32, .F64:
			return true
		case .Complex64, .Complex128:
			return true
		case .Quaternion128, .Quaternion256:
			return true
		case .Rawptr:
			return true
		case .Untyped_Integer, .Untyped_Float, .Untyped_Complex:
			return true
		case .Untyped_Bool:
			return true
		}
		return false

	case .Pointer, .Multi_Pointer, .Soa_Pointer:
		return true

	case .Proc:
		return true

	case .Bit_Set:
		return true

	case .Matrix:
		mat := ct.variant.(Type_Matrix)
		return is_type_nearly_simple_compare(mat.elem)

	case .Struct:
		// All fields must be nearly simple compare
		struc := ct.variant.(Type_Struct)
		for field in struc.fields {
			if field.kind == .Variable {
				var_field := field.variant.(Entity_Variable)
				if !is_type_nearly_simple_compare(var_field.type) {
					return false
				}
			}
		}
		return true

	case .Union:
		// Check all variants are nearly simple compare
		union_type := ct.variant.(Type_Union)
		for variant in union_type.variants {
			if !is_type_nearly_simple_compare(variant) {
				return false
			}
		}
		// C++ comment: "make it dumb on purpose" - only true for single-variant unions
		return len(union_type.variants) == 1

	case .Simd_Vector:
		simd := ct.variant.(Type_Simd_Vector)
		return is_type_nearly_simple_compare(simd.elem)
	}

	return false
}

// check_is_assignable_to_using_subtype checks if src can be assigned to dst through subtype relationships
// Returns the nesting level (> 0) if assignable, 0 otherwise
// C++ Reference: /mnt/c/odin/src/types.cpp:4666-4709
check_is_assignable_to_using_subtype :: proc(src_param: ^Type, dst: ^Type, level: int = 0, src_is_ptr_param: bool = false, allow_polymorphic: bool = false) -> int {
	// C++ Reference: types.cpp:4667-4671
	prev_src := src_param
	src := type_deref(src_param)
	src_is_ptr := src_is_ptr_param
	if !src_is_ptr {
		src_is_ptr = src != prev_src
	}
	src = base_type(src)

	// C++ Reference: types.cpp:4674-4676
	if !is_type_struct(src) {
		return 0
	}

	// C++ Reference: types.cpp:4678
	dst_is_polymorphic := is_type_polymorphic(dst)

	// C++ Reference: types.cpp:4680-4706
	struct_type := src.variant.(Type_Struct)
	for field in struct_type.fields {
		// C++ Reference: types.cpp:4682-4684, and entity.cpp:92
		//     EntityFlags_IsSubtype = EntityFlag_Using|EntityFlag_Subtype
		// C++ tests `f->flags & EntityFlags_IsSubtype`, i.e. EITHER bit — it is a MASK,
		// not a required pair. The port required BOTH flags to be present, so a plain
		// `using d: D` field (which sets only .Using; .Subtype comes from the separate
		// `#subtype` directive) was skipped and `using`-based subtyping was never accepted
		// at a call site. Passing a DateTime where a Date is expected — core/time/datetime
		// does this throughout — reported "Cannot pass argument of type 'DateTime' to
		// parameter of type 'Date'".
		//
		// Field ACCESS through a `using` field went through a different lookup and worked,
		// which is what made this look like a call-site problem.
		if field.kind != .Variable || (field.flags & Entity_Flags_Is_Subtype) == {} {
			continue
		}

		// Read the field's type via entity_type(), NOT field.type. For struct field
		// entities in this port only the VARIANT carries the type; Entity.type is nil
		// (see task 82, where the same split made every struct measure 0 bytes). With
		// field.type nil, every are_types_identical below compared against nil and this
		// walk always returned 0 — so `using`-based subtyping was never accepted at a call
		// site. `x.y` through a `using` field worked (that is a different lookup), which is
		// why it looked like a call-site problem rather than a field-type problem.
		field_type := entity_type(field)

		// C++ Reference: types.cpp:4685-4692
		// Special handling for polymorphic types
		if allow_polymorphic && dst_is_polymorphic {
			fb := base_type(type_deref(field_type))
			if fb.kind == .Struct {
				fb_struct := fb.variant.(Type_Struct)
				if fb_struct.polymorphic_parent == dst {
					return level + 1
				}
			}
		}

		// C++ Reference: types.cpp:4694-4696
		if are_types_identical(field_type, dst) {
			return level + 1
		}

		// C++ Reference: types.cpp:4697-4701
		if src_is_ptr && is_type_pointer(dst) {
			if are_types_identical(field_type, type_deref(dst)) {
				return level + 1
			}
		}

		// C++ Reference: types.cpp:4702-4705
		// Recursively check nested fields
		nested_level := check_is_assignable_to_using_subtype(field_type, dst, level + 1, src_is_ptr, allow_polymorphic)
		if nested_level > 0 {
			return nested_level
		}
	}

	// C++ Reference: types.cpp:4708
	return 0
}

// is_type_subtype_of checks if src is a subtype of dst
// C++ Reference: /mnt/c/odin/src/types.cpp:4711-4717
is_type_subtype_of :: proc(src: ^Type, dst: ^Type) -> bool {
	// C++ Reference: types.cpp:4712-4713
	if are_types_identical(src, dst) {
		return true
	}

	// C++ Reference: types.cpp:4716
	return 0 < check_is_assignable_to_using_subtype(src, dst, 0, is_type_pointer(src))
}

// is_type_subtype_of_and_allow_polymorphic checks if src is a subtype of dst, allowing polymorphic types
// C++ Reference: /mnt/c/odin/src/types.cpp:4718-4724
is_type_subtype_of_and_allow_polymorphic :: proc(src: ^Type, dst: ^Type) -> bool {
	// C++ Reference: types.cpp:4719-4720
	if are_types_identical(src, dst) {
		return true
	}

	// C++ Reference: types.cpp:4723
	return 0 < check_is_assignable_to_using_subtype(src, dst, 0, is_type_pointer(src), true)
}

// is_type_load_safe checks if type is safe to load from memory
// C++ Reference: /mnt/c/odin/src/types.cpp:2776-2821
is_type_load_safe :: proc(t: ^Type) -> bool {
	// Check if type is safe to load from arbitrary memory
	// C++ Reference: /mnt/c/odin/src/types.cpp:2776-2821
	if t == nil {
		return false
	}

	ct := core_type(core_array_type(t))

	#partial switch ct.kind {
	// Pointers and reference types are explicitly NOT load safe
	case .Pointer, .Multi_Pointer, .Soa_Pointer, .Slice, .Dynamic_Array, .Proc:
		return false

	// Basic types that ARE load safe
	case .Basic:
		basic := ct.variant.(Type_Basic)
		#partial switch basic.kind {
		// Boolean and numeric types are load safe
		case .Bool, .I8, .I16, .I32, .I64, .I128, .Int, .U8, .U16, .U32, .U64, .U128, .Uint, .Uintptr, .F16, .F32, .F64, .Complex64, .Complex128, .Untyped_Bool, .Untyped_Integer, .Untyped_Float, .Untyped_Complex, .Untyped_Rune:
			return true
		}
		// String, Cstring, Any, Typeid, Rawptr are NOT load safe (contain pointers/metadata)
		return false

	case .Bit_Set:
		// C++ Reference: types.cpp:2784-2787
		bs := ct.variant.(Type_Bit_Set)
		if bs.underlying != nil {
			return is_type_load_safe(bs.underlying)
		}
		return true

	case .Enum, .Enumerated_Array, .Array, .Simd_Vector, .Matrix:
		// C++ Reference: types.cpp:2795-2802
		// These should never be hit because core_array_type unwraps them
		panic("is_type_load_safe: Array-like types should be unwrapped by core_array_type")

	case .Struct:
		// C++ Reference: types.cpp:2804-2810
		// All fields must be load_safe
		struct_type := ct.variant.(Type_Struct)
		for field in struct_type.fields {
			if !is_type_load_safe(field.type) {
				return false
			}
		}
		// Struct must have non-zero size
		return type_size_of(ct) > 0

	case .Union:
		// C++ Reference: types.cpp:2811-2817
		// All variants must be load_safe
		union_type := ct.variant.(Type_Union)
		for variant in union_type.variants {
			if !is_type_load_safe(variant) {
				return false
			}
		}
		// Union must have non-zero size
		return type_size_of(ct) > 0
	}

	// C++ Reference: types.cpp:2819
	return false
}

// is_type_lock_free checks if type has atomic lock-free guarantee
// C++ Reference: /mnt/c/odin/src/types.cpp:2580-2588
// Lock-free guarantee depends on type size and platform capabilities:
// - Most platforms: sizes 1, 2, 4, 8 bytes are lock-free
// - 32-bit platforms: only 1, 2, 4 bytes guaranteed
// - Some platforms support 16-byte lock-free (e.g., x86-64 with cmpxchg16b)
is_type_lock_free :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == t_invalid {
		return false
	}
	sz := type_size_of(ct)

	// Common lock-free sizes on most platforms
	// Uses max_align as upper bound (typically 8 on 64-bit, 4 on 32-bit)
	if sz <= 0 {
		return false
	}
	// Must be power of 2 for atomic operations
	if sz & (sz - 1) != 0 {
		return false
	}
	return sz <= int(build_context.max_align)
}

// is_type_ordered checks if a type can be used with <, >, <=, >= operators
// Reference: /mnt/c/odin/src/types.cpp
is_type_ordered :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	bt := base_type(t)

	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		// Check using BASIC_FLAG_ORDERED composite flag
		// ORDERED = Integer | Float | String | Pointer | Rune
		return (basic.flags & BASIC_FLAG_ORDERED) != {}

	case .Pointer, .Multi_Pointer:
		return true // Pointers are ordered

	case .Enum:
		return true // Enums are ordered

	case:
		return false
	}
}

// ============================================================================
// Endianness Type Predicates
// C++ Reference: /mnt/c/odin/src/types.cpp:1939-1972, 2038-2046
// ============================================================================

// get_basic_kind_endianness returns the endianness of a Basic_Kind
// C++ Reference: Derived from BasicFlag_EndianLittle/Big checks in /mnt/c/odin/src/types.cpp
// This helper is used by the endian predicate functions below
get_basic_kind_endianness :: proc(kind: Basic_Kind) -> Endianness {
	flags := basic_flags_table[kind]

	if .Endian_Little in flags {
		return .Little
	}
	if .Endian_Big in flags {
		return .Big
	}

	// All other types are platform-endian
	return .Platform
}

// is_type_endian_specific checks if a type is an endian-specific variant
// C++ Reference: /mnt/c/odin/src/types.cpp:1990-2027
is_type_endian_specific :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	// Use core_type to strip Named wrappers, as C++ does
	ct := core_type(t)
	if ct == nil {
		return false
	}

	// Handle BitSet by checking its backing integer type
	// C++ Reference: types.cpp:1993-1995
	if ct.kind == .Bit_Set {
		ct = bit_set_to_int(t)
		return is_type_endian_specific(t)
	}

	// Check if Basic type is endian-specific
	if ct.kind == .Basic {
		basic := ct.variant.(Type_Basic)
		endian := get_basic_kind_endianness(basic.kind)
		return endian == .Little || endian == .Big
	}

	return false
}

// is_type_endian_platform checks if a type is platform-endian (not le/be specific)
// C++ Reference: /mnt/c/odin/src/types.cpp:1974-1985
is_type_endian_platform :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	// Use core_type to strip Named wrappers
	ct := core_type(t)
	if ct == nil {
		return false
	}

	// Handle BitSet by checking its backing integer type
	// C++ Reference: types.cpp:1979-1981
	if ct.kind == .Bit_Set {
		ct = bit_set_to_int(ct)
		return is_type_endian_platform(ct)
	}

	// Handle Pointer by checking uintptr
	// C++ Reference: types.cpp:1981-1983
	if ct.kind == .Pointer || ct.kind == .Multi_Pointer {
		// uintptr is always platform-endian
		return true
	}

	// Check if Basic type is platform-endian
	// C++ checks: (t->Basic.flags & (BasicFlag_EndianLittle|BasicFlag_EndianBig)) == 0
	if ct.kind == .Basic {
		basic := ct.variant.(Type_Basic)
		return get_basic_kind_endianness(basic.kind) == .Platform
	}

	return false
}

// is_type_endian_little checks if a type is little-endian
// C++ Reference: /mnt/c/odin/src/types.cpp:1956-1972
is_type_endian_little :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	// Use core_type to strip Named wrappers, as C++ does
	ct := core_type(t)
	if ct == nil {
		return false
	}

	// Check Basic types for explicit endianness
	// C++ Reference: types.cpp:1960-1965
	if ct.kind == .Basic {
		basic := ct.variant.(Type_Basic)
		endian := get_basic_kind_endianness(basic.kind)

		// Explicitly little-endian types
		if endian == .Little {
			return true
		}
		// Explicitly big-endian types
		if endian == .Big {
			return false
		}

		// Platform-endian types: check build_context.endian_kind
		// C++ Reference: types.cpp:1965
		return build_context.endian_kind == .Little
	}

	// Handle BitSet by checking its backing integer type
	// C++ Reference: types.cpp:1966-1968
	if ct.kind == .Bit_Set {
		return is_type_endian_little(bit_set_to_int(ct))
	}

	// Handle Pointer by checking uintptr
	// C++ Reference: types.cpp:1968-1970
	if ct.kind == .Pointer || ct.kind == .Multi_Pointer {
		return is_type_endian_little(t_uintptr)
	}

	// Other types default to platform endianness
	// C++ Reference: types.cpp:1971
	return build_context.endian_kind == .Little
}

// is_type_endian_big checks if a type is big-endian
// C++ Reference: /mnt/c/odin/src/types.cpp:1939-1955
is_type_endian_big :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	// Use core_type to strip Named wrappers, as C++ does
	ct := core_type(t)
	if ct == nil {
		return false
	}

	// Check Basic types for explicit endianness
	// C++ Reference: types.cpp:1943-1948
	if ct.kind == .Basic {
		basic := ct.variant.(Type_Basic)
		endian := get_basic_kind_endianness(basic.kind)

		// Explicitly big-endian types
		if endian == .Big {
			return true
		}
		// Explicitly little-endian types
		if endian == .Little {
			return false
		}

		// Platform-endian types: check build_context.endian_kind
		// C++ Reference: types.cpp:1948
		return build_context.endian_kind == .Big
	}

	// Handle BitSet by checking its backing integer type
	// C++ Reference: types.cpp:1949-1951
	if ct.kind == .Bit_Set {
		return is_type_endian_big(bit_set_to_int(t))
	}

	// Handle Pointer by checking uintptr
	// C++ Reference: types.cpp:1951-1953
	if ct.kind == .Pointer || ct.kind == .Multi_Pointer {
		return is_type_endian_big(t_uintptr)
	}

	// Other types default to platform endianness
	// C++ Reference: types.cpp:1954
	return build_context.endian_kind == .Big
}

// is_type_different_to_arch_endianness checks if type endianness differs from target architecture
// C++ Reference: /mnt/c/odin/src/types.cpp:2038-2046
is_type_different_to_arch_endianness :: proc(t: ^Type) -> bool {
	// C++ implementation checks against build_context.endian_kind
	#partial switch build_context.endian_kind {
	case .Little:
		return !is_type_endian_little(t)
	case .Big:
		return !is_type_endian_big(t)
	}
	return false
}

// is_type_constant_type checks if a type can appear in constant expressions
// C++ Reference: types.cpp:1377-1396
is_type_constant_type :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}

	// Use core_type to unwrap Named, Enum, BitField
	// C++ Reference: types.cpp:1378
	ct := core_type(t)
	if ct == nil {
		return false
	}

	#partial switch ct.kind {
	case .Basic:
		// C++ Reference: types.cpp:1380-1384
		basic := ct.variant.(Type_Basic)

		// Typeid is always a constant type
		if basic.kind == .Typeid {
			return true
		}

		// C++ Reference: types.cpp:1385 - (t->Basic.flags & BasicFlag_ConstantType) != 0
		// BasicFlag_ConstantType = Boolean | Numeric | String | Pointer | Rune
		return (basic.flags & BASIC_FLAG_CONSTANT_TYPE) != {}

	case .Bit_Set:
		// C++ Reference: types.cpp:1385-1386
		// Bit sets are compile-time constant types
		return true

	case .Proc:
		// C++ Reference: types.cpp:1387-1388
		// Procedure values are compile-time constants
		return true

	case .Array:
		// C++ Reference: types.cpp:1389-1390
		// Arrays are constant if their elements are constant
		arr := ct.variant.(Type_Array)
		return is_type_constant_type(arr.elem)

	case .Enumerated_Array:
		// C++ Reference: types.cpp:1391-1392
		// Enumerated arrays are constant if their elements are constant
		enum_arr := ct.variant.(Type_Enumerated_Array)
		return is_type_constant_type(enum_arr.elem)

	case:
		return false
	}
}

// alloc_type_pointer creates a pointer type
// Reference: /mnt/c/odin/src/types.cpp
alloc_type_pointer :: proc(elem: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Pointer
	t.variant = Type_Pointer {
		elem = elem,
	}
	return t
}

// alloc_type_slice creates a slice type
// Reference: /mnt/c/odin/src/types.cpp:1077-1081
alloc_type_slice :: proc(elem: ^Type, allocator := context.allocator) -> ^Type {
	t := new(Type, allocator)
	t.kind = .Slice
	t.variant = Type_Slice {
		elem = elem,
	}
	return t
}

// ============================================================================
// Type Constructors - Critical Infrastructure (Week 1 Group 3)
// C++ Reference: /mnt/c/odin/src/types.cpp:655-1151
// ============================================================================

// alloc_type_tuple creates a tuple type
// C++ Reference: /mnt/c/odin/src/types.cpp:655-665
alloc_type_tuple :: proc(variables: []^Entity) -> ^Type {
	t := new(Type)
	t.kind = .Tuple
	// Convert slice to dynamic array for storage
	vars := make([dynamic]^Entity, len(variables))
	copy(vars[:], variables)
	t.variant = Type_Tuple {
		variables = vars,
	}
	return t
}

// make_optional_ok_type creates a tuple type for optional-ok results
// C++ Reference: /mnt/c/odin/src/check_type.cpp:2668-2675
//
// Creates a (T, bool) or (T, untyped_bool) tuple type used for:
// - Map lookups: value, ok := map[key]
// - Type assertions: value, ok := x.(T)
// - Channel receives: value, ok := <-chan
make_optional_ok_type :: proc(value: ^Type, typed := true) -> ^Type {
	t := new(Type)
	t.kind = .Tuple
	// Initialize with 2 entity fields
	vars := make([dynamic]^Entity, 2)
	vars[0] = alloc_entity_field(nil, blank_token, value, false, 0)
	vars[1] = alloc_entity_field(nil, blank_token, typed ? t_bool : t_untyped_bool, false, 1)
	t.variant = Type_Tuple {
		variables = vars,
	}
	return t
}

// init_map_internal_types initializes internal types for map operations
// C++ Reference: /mnt/c/odin/src/check_type.cpp:2768-2778
//
// This function creates the lookup_result_type for a map, which is the tuple
// type returned by map indexing: (value, bool). It's lazily initialized on
// first access to avoid circular dependencies during type construction.
init_map_internal_types :: proc(type: ^Type) {
	assert(type.kind == .Map, "init_map_internal_types requires a Map type")
	assert(t_allocator != nil, "t_allocator must be initialized")

	map_type := &type.variant.(Type_Map)

	// Already initialized - nothing to do (C++ line 2771)
	if map_type.lookup_result_type != nil {
		return
	}

	// Validate that key and value types are set (C++ lines 2773-2776)
	assert(map_type.key != nil, "Map key type must be set")
	assert(map_type.value != nil, "Map value type must be set")

	// Create the (value, bool) tuple type for map lookups (C++ line 2778)
	map_type.lookup_result_type = make_optional_ok_type(map_type.value)
}

// map_cell_size_and_len calculates the cell size and length for a map type
// C++ Reference: check_type.cpp (map internal calculations)
// Returns (cell_size, cell_len)
map_cell_size_and_len :: proc(key_type, value_type: ^Type) -> (cell_size: i64, cell_len: i64) {
	// Map cells store key-value pairs with alignment padding
	// This is used for map memory layout calculations
	if key_type == nil || value_type == nil {
		return 0, 0
	}

	key_size := i64(type_size_of(key_type))
	value_size := i64(type_size_of(value_type))
	value_align := i64(type_align_of(value_type))
	cell_align := i64(max(type_align_of(key_type), type_align_of(value_type)))

	// Align key_size to value_align, then add value_size
	// align_formula: result = size + align - 1; result = result - (result % align)
	aligned_key := key_size + value_align - 1
	aligned_key = aligned_key - (aligned_key % value_align)
	cell_size = aligned_key + value_size

	// Align cell_size to cell_align
	cell_size = cell_size + cell_align - 1
	cell_size = cell_size - (cell_size % cell_align)

	// Cell length is typically 1 for simple maps
	cell_len = 1

	return cell_size, cell_len
}

// get_map_cell_type returns the internal cell type for a map
// C++ Reference: check_type.cpp (map cell type generation)
// Map cells are internally represented as a struct with key and value fields
// This is used for type_info generation and debug info
get_map_cell_type :: proc(key_type, value_type: ^Type) -> ^Type {
	if key_type == nil || value_type == nil {
		return nil
	}

	// Create a synthetic struct type representing the map cell
	// C++ creates: struct { key: Key_Type, value: Value_Type }
	t := alloc_type(Type_Struct)
	set_base_type(t, t)

	st := &t.variant.(Type_Struct)
	st.is_raw_union = false
	st.is_packed = false

	// The struct has two fields: key and value
	// These are synthetic entities for debug/type_info purposes
	// NOTE: Full implementation would create proper Entity fields,
	// but for type_info purposes, we just need the struct shell
	// with correct size/alignment characteristics

	return t
}

// init_map_internal_debug_types initializes debug type information for maps
// C++ Reference: check_type.cpp (debug type initialization)
init_map_internal_debug_types :: proc(type: ^Type) {
	// This function initializes debug-specific type information for maps
	// It's primarily used for debugger integration
	if type == nil || type.kind != .Map {
		return
	}

	// Debug type initialization is a P3 feature
	// For semantic analysis, the map type itself is sufficient
}

// alloc_type_proc creates a procedure type
// C++ Reference: /mnt/c/odin/src/types.cpp:667-690
alloc_type_proc :: proc(scope: ^Scope, params: ^Type, results: ^Type, param_count: int, result_count: int, variadic := false, calling_convention := Calling_Convention.Odin) -> ^Type {
	// Variadic validation (C++ Reference: types.cpp:1157-1167)
	if variadic {
		assert(param_count > 0, "Variadic procedures must have at least one parameter")
		// Note: The C++ version also validates that the last parameter is a slice type,
		// but that requires accessing the tuple's variables which may not be set yet.
		// This validation should happen during semantic analysis.
	}

	t := new(Type)
	t.kind = .Proc
	t.variant = Type_Proc {
		scope              = scope,
		params             = params,
		results            = results,
		param_count        = param_count,
		result_count       = result_count,
		variadic           = variadic,
		calling_convention = calling_convention,
	}
	return t
}

// alloc_type_array creates a fixed-size array type
// C++ Reference: /mnt/c/odin/src/types.cpp:1024-1036
alloc_type_array :: proc(elem: ^Type, count: i64, generic_count: ^Type = nil) -> ^Type {
	// If generic count is specified, include it in the type
	// C++ lines 1025-1031
	if generic_count != nil {
		t := new(Type)
		t.kind = .Array
		t.variant = Type_Array {
			elem          = elem,
			count         = count,
			generic_count = generic_count,
		}
		return t
	}

	// Non-generic case (C++ lines 1032-1035)
	t := new(Type)
	t.kind = .Array
	t.variant = Type_Array {
		elem  = elem,
		count = count,
	}
	return t
}

// alloc_type_enumerated_array creates an enumerated array type
// C++ Reference: /mnt/c/odin/src/types.cpp:1058-1074
alloc_type_enumerated_array :: proc(elem: ^Type, index: ^Type, min_value: ^Exact_Value, max_value: ^Exact_Value, count: i64, op: tokenizer.Token_Kind) -> ^Type {
	t := new(Type)
	t.kind = .Enumerated_Array

	// Allocate and copy min/max values (C++ lines 1062-1065)
	min_val_copy := new(Exact_Value)
	max_val_copy := new(Exact_Value)
	min_val_copy^ = min_value^
	max_val_copy^ = max_value^

	// Calculate count if not provided (C++ lines 1068-1072)
	final_count := count
	if count == 0 {
		final_count = 0
	} else {
		// count = 1 + exact_value_to_i64(exact_value_sub(*max_value, *min_value))
		diff := exact_value_sub(max_value^, min_value^)
		final_count = 1 + exact_value_to_i64(diff)
	}

	t.variant = Type_Enumerated_Array {
		elem      = elem,
		index     = index,
		count     = final_count,
		min_value = min_val_copy,
		max_value = max_val_copy,
		op        = op,
	}
	return t
}

// alloc_type_dynamic_array creates a dynamic array type
// C++ Reference: /mnt/c/odin/src/types.cpp:803-811
alloc_type_dynamic_array :: proc(elem: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Dynamic_Array
	t.variant = Type_Dynamic_Array {
		elem = elem,
	}
	return t
}

// alloc_type_multi_pointer creates a multi-pointer type ([^]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:720-725
alloc_type_multi_pointer :: proc(elem: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Multi_Pointer
	t.variant = Type_Multi_Pointer {
		elem = elem,
	}
	return t
}

// alloc_type_soa_pointer creates an SOA pointer type (#soa [^]T)
// C++ Reference: /mnt/c/odin/src/types.cpp:740-745
alloc_type_soa_pointer :: proc(elem: ^Type) -> ^Type {
	t := new(Type)
	t.kind = .Soa_Pointer
	t.variant = Type_Soa_Pointer {
		elem = elem,
	}
	return t
}

// alloc_type_simd_vector creates a SIMD vector type
// C++ Reference: /mnt/c/odin/src/types.cpp:1189-1199
alloc_type_simd_vector :: proc(count: i64, elem: ^Type, generic_count: ^Type = nil) -> ^Type {
	t := new(Type)
	t.kind = .Simd_Vector
	t.variant = Type_Simd_Vector {
		elem          = elem,
		count         = count,
		generic_count = generic_count,
	}
	return t
}

// type_unsigned_equivalent returns the unsigned integer type of the same size as
// `t`, recursing through #simd vectors element-wise.
//
// C++ Reference: /mnt/c/odin/src/types.cpp:1755-1775
type_unsigned_equivalent :: proc(t: ^Type) -> ^Type {
	original_type := t
	bt := base_type(t)
	if is_type_simd_vector(bt) {
		sv := &bt.variant.(Type_Simd_Vector)
		if is_type_unsigned(sv.elem) {
			return original_type
		}
		return alloc_type_simd_vector(sv.count, type_unsigned_equivalent(sv.elem))
	}

	switch type_size_of(bt) {
	case 1:
		return t_u8
	case 2:
		return t_u16
	case 4:
		return t_u32
	case 8:
		return t_u64
	case 16:
		return t_u128
	}

	// C++ panics here. The port is used as a library, so return the original
	// type and let the caller's own validation produce the diagnostic.
	return original_type
}

// determine_swizzle_array_type determines the result type for a swizzle operation
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:5331-5355
//
// Given an original array/SIMD vector type and a new element count, determines
// the appropriate result type for a swizzle operation. Attempts to reuse existing
// types when possible (type_hint or original_type) to preserve type identity.
determine_swizzle_array_type :: proc(original_type: ^Type, type_hint: ^Type, new_count: i64) -> ^Type {
	array_type := base_type(type_deref(original_type))
	assert(array_type.kind == .Array || array_type.kind == .Simd_Vector)

	// SIMD vectors always create a new type with the new count
	if array_type.kind == .Simd_Vector {
		simd := array_type.variant.(Type_Simd_Vector)
		elem_type := simd.elem
		return alloc_type_simd_vector(new_count, elem_type)
	}

	// For arrays, try to reuse existing types when possible
	arr := array_type.variant.(Type_Array)
	elem_type := arr.elem

	swizzle_array_type: ^Type = nil

	// If type_hint is provided and matches what we need, use it
	bth := type_hint != nil ? base_type(type_deref(type_hint)) : nil
	if bth != nil && bth.kind == .Array {
		hint_arr := bth.variant.(Type_Array)
		if hint_arr.count == new_count && are_types_identical(hint_arr.elem, elem_type) {
			swizzle_array_type = type_hint
		}
	}

	// If no suitable type_hint, check if we can reuse original_type
	if swizzle_array_type == nil {
		max_count := arr.count
		if new_count == max_count {
			swizzle_array_type = original_type
		} else {
			swizzle_array_type = alloc_type_array(elem_type, new_count)
		}
	}

	return swizzle_array_type
}

// alloc_type_matrix creates a matrix type
// C++ Reference: /mnt/c/odin/src/types.cpp:1038-1055
alloc_type_matrix :: proc(elem: ^Type, row_count: i64, column_count: i64, generic_row_count: ^Type, generic_column_count: ^Type, is_row_major: bool) -> ^Type {
	// C++ Reference: types.cpp:1039-1048
	// If generic dimensions are specified, include them in the type
	if generic_row_count != nil || generic_column_count != nil {
		t := new(Type)
		t.kind = .Matrix
		t.variant = Type_Matrix {
			elem                 = elem,
			row_count            = row_count,
			column_count         = column_count,
			generic_row_count    = generic_row_count,
			generic_column_count = generic_column_count,
			is_row_major         = is_row_major,
		}
		return t
	}

	// C++ Reference: types.cpp:1049-1055
	// Non-generic case (stride_in_bytes is computed later)
	t := new(Type)
	t.kind = .Matrix
	t.variant = Type_Matrix {
		elem         = elem,
		row_count    = row_count,
		column_count = column_count,
		is_row_major = is_row_major,
	}
	return t
}

// Field Lookup Functions
// These functions resolve field names to Selection paths
// Reference: /mnt/c/odin/src/types.cpp:3444-3850

// lookup_field looks up a field by name in a type
// Wrapper around lookup_field_with_selection
// Ported from types.cpp:3444-3446
lookup_field :: proc(type: ^Type, field_name: string, is_type: bool, allow_blank_ident := false) -> Selection {
	return lookup_field_with_selection(type, field_name, is_type, empty_selection, allow_blank_ident)
}

// lookup_field_with_selection recursively looks up a field in a type
// Handles struct fields, enum values, union variants, and 'using' fields
// lookup_field_with_selection finds a field by name in a type and returns the selection path
// C++ Reference: /mnt/c/odin/src/types.cpp:3500-3850
lookup_field_with_selection :: proc(type_: ^Type, field_name: string, is_type: bool, sel: Selection, allow_blank_ident := false) -> Selection {
	if type_ == nil {
		return empty_selection
	}

	// Don't allow blank identifier unless explicitly allowed
	if !allow_blank_ident && is_blank_ident_string(field_name) {
		return empty_selection
	}

	// Dereference pointers
	type := type_deref(type_)
	is_ptr := type != type_
	sel := sel
	sel.indirect = sel.indirect || is_ptr

	// C++ Reference: types.cpp:3511
	original_type := type
	type = base_type(type)

	// Handle type-level access (Type.field syntax)
	if is_type {
		// ObjC class type-level metadata lookup
		// C++ Reference: types.cpp:3516-3531
		if has_type_got_objc_class_attribute(original_type) && original_type.kind == .Named {
			e := original_type.variant.(Type_Named).type_name
			assert(e.kind == .Type_Name)
			type_name_entity := e.variant.(Entity_Type_Name)

			if type_name_entity.objc_metadata != nil {
				md := type_name_entity.objc_metadata
				sync.mutex_lock(&md.mutex)
				defer sync.mutex_unlock(&md.mutex)

				for entry in md.type_entries {
					assert(entry.entity.kind == .Procedure || entry.entity.kind == .Proc_Group)
					if entry.name == field_name {
						sel.entity = entry.entity
						sel.pseudo_field = true
						return sel
					}
				}
			}
		}

		// Enum value lookup
		if type.kind == .Enum {
			enum_type := type.variant.(Type_Enum)
			for field in enum_type.fields {
				if _, ok := field.variant.(Entity_Constant); ok {
					if field.token.text == field_name {
						sel.entity = field
						// Note: C++ doesn't add index for enum values
						return sel
					}
				}
			}
		}

		// Struct scope lookup for type-level members (constants, types, etc.)
		if type.kind == .Struct {
			struct_type := type.variant.(Type_Struct)
			if struct_type.scope != nil {
				// Look up in struct scope
				found := scope_lookup_current(struct_type.scope, field_name)
				if found != nil && found.kind != .Variable {
					sel.entity = found
					return sel
				}
			}
		} else if type.kind == .Union {
			union_type := type.variant.(Type_Union)
			if union_type.scope != nil {
				found := scope_lookup_current(union_type.scope, field_name)
				if found != nil && found.kind != .Variable {
					sel.entity = found
					return sel
				}
			}
		}

		// Bit_Set type-level field lookup: delegates to elem type (typically enum)
		// C++ ref: types.cpp:3540-3542
		if type.kind == .Bit_Set {
			bitset := type.variant.(Type_Bit_Set)
			// For bit sets, lookup in the element type (e.g., enum values)
			return lookup_field_with_selection(bitset.elem, field_name, true, sel, allow_blank_ident)
		}

		// Generic type specialized lookup
		// C++ Reference: types.cpp:3586-3589
		if type.kind == .Generic {
			generic := type.variant.(Type_Generic)
			if generic.specialized != nil {
				return lookup_field_with_selection(generic.specialized, field_name, is_type, sel, allow_blank_ident)
			}
		}

	} else {
		// Handle value-level access (value.field syntax)

		// C++ Reference: types.cpp:4123-4144. Dynamic arrays and maps expose a built-in
		// `allocator` field — index 3 in Raw_Dynamic_Array, index 2 in Raw_Map. The port
		// had neither, so `d.allocator` on a [dynamic]T reported "has no field 'allocator'"
		// (662 instances across the sweep) and took the surrounding code with it:
		// core/bytes/buffer.odin fails here at line 46 and every later multi-value call in
		// the file then reports "Assignment count mismatch '2' = '1'".
		if field_name == "allocator" {
			#partial switch type.kind {
			case .Dynamic_Array:
				sel_out := sel
				selection_add_index(&sel_out, 3)
				sel_out.entity = alloc_entity_field(
					nil,
					make_token_ident("allocator"),
					t_allocator,
					false,
					3,
				)
				return sel_out
			case .Map:
				sel_out := sel
				selection_add_index(&sel_out, 2)
				sel_out.entity = alloc_entity_field(
					nil,
					make_token_ident("allocator"),
					t_allocator,
					false,
					2,
				)
				return sel_out
			}
		}

		if type.kind == .Struct {
			// ObjC class instance value handling
			// C++ Reference: types.cpp:3593-3617
			if has_type_got_objc_class_attribute(original_type) && original_type.kind == .Named {
				e := original_type.variant.(Type_Named).type_name
				assert(e.kind == .Type_Name)
				type_name_entity := e.variant.(Entity_Type_Name)

				// Check objc_metadata.value_entries for instance methods/properties
				// C++ Reference: types.cpp:3595-3608
				if type_name_entity.objc_metadata != nil {
					md := type_name_entity.objc_metadata
					sync.mutex_lock(&md.mutex)
					defer sync.mutex_unlock(&md.mutex)

					for entry in md.value_entries {
						assert(entry.entity.kind == .Procedure || entry.entity.kind == .Proc_Group)
						if entry.name == field_name {
							sel.entity = entry.entity
							sel.pseudo_field = true
							return sel
						}
					}
				}

				// Check objc_ivar for instance variables
				// C++ Reference: types.cpp:3612-3617
				objc_ivar_type := type_name_entity.objc_ivar
				if objc_ivar_type != nil {
					sel = lookup_field_with_selection(objc_ivar_type, field_name, false, sel, allow_blank_ident)
					if sel.entity != nil {
						sel.pseudo_field = true
						return sel
					}
				}
			}

			// Polymorphic struct early return check
			// C++ Reference: types.cpp:3621-3624
			// A polymorphic struct (unspecialized) has no fields
			if is_type_polymorphic(type) {
				return sel
			}

			struct_type := type.variant.(Type_Struct)
			field_count := len(struct_type.fields)

			if field_count > 0 {
				for field, i in struct_type.fields {
					if field.kind != .Variable {
						continue
					}

					variable := field.variant.(Entity_Variable)

					// Check if entity is actually a field
					if .Field not_in field.flags {
						continue
					}

					// Direct field match
					if field.token.text == field_name {
						selection_add_index(&sel, i)
						sel.entity = field
						return sel
					}

					// Using field traversal for nested field lookup
					// C++ Reference: types.cpp:3640-3654
					if .Using in field.flags {
						prev_count := len(sel.index)
						prev_indirect := sel.indirect
						selection_add_index(&sel, i)

						sel = lookup_field_with_selection(variable.type, field_name, is_type, sel, allow_blank_ident)

						if sel.entity != nil {
							if is_type_pointer(variable.type) {
								sel.indirect = true
							}
							return sel
						}
						// Restore previous selection state if no match found
						resize(&sel.index, prev_count)
						sel.indirect = prev_indirect
					}
				}
			}

			// SOA field mapping (r/g/b/a -> x/y/z/w)
			// C++ Reference: types.cpp:3657-3667
			is_soa := struct_type.soa_kind != .None
			is_soa_of_array := is_soa && is_type_array(struct_type.soa_elem)

			if is_soa_of_array {
				mapped_field_name := ""
				switch field_name {
				case "r":
					mapped_field_name = "x"
				case "g":
					mapped_field_name = "y"
				case "b":
					mapped_field_name = "z"
				case "a":
					mapped_field_name = "w"
				}
				if mapped_field_name != "" {
					return lookup_field_with_selection(type, mapped_field_name, is_type, sel, allow_blank_ident)
				}
			}

		} else if type.kind == .Bit_Field {
			// Bit field member lookup
			// C++ ref: types.cpp:3733-3747
			bf := type.variant.(Type_Bit_Field)
			for field, i in bf.fields {
				// Only consider variable entities with the field flag
				if field.kind != .Variable {
					continue
				}

				// Check if entity is actually a field
				if .Field not_in field.flags {
					continue
				}

				// Check field name match
				if field.token.text == field_name {
					selection_add_index(&sel, i)
					sel.entity = field
					sel.is_bit_field = true
					return sel
				}
			}

		} else if type.kind == .Basic {
			basic := type.variant.(Type_Basic)

			// Any field access (data, id)
			// C++ Reference: types.cpp:3685-3700
			if basic.kind == .Any {
				switch field_name {
				case "data":
					entity_data := alloc_entity_field(nil, make_token_ident("data"), t_rawptr, false, 0)
					selection_add_index(&sel, 0)
					sel.entity = entity_data
					return sel
				case "id":
					entity_id := alloc_entity_field(nil, make_token_ident("id"), t_typeid, false, 1)
					selection_add_index(&sel, 1)
					sel.entity = entity_id
					return sel
				}
			}

			// Quaternion field access (w, x, y, z)
			// C++ Reference: types.cpp:3752-3842
			// @QuaternionLayout: x=0, y=1, z=2, w=3
			#partial switch basic.kind {
			case .Quaternion64:
				// quaternion64: 4 x f16
				switch field_name {
				case "w":
					entity_w := alloc_entity_field(nil, make_token_ident("w"), t_f16, false, 3)
					selection_add_index(&sel, 3)
					sel.entity = entity_w
					return sel
				case "x":
					entity_x := alloc_entity_field(nil, make_token_ident("x"), t_f16, false, 0)
					selection_add_index(&sel, 0)
					sel.entity = entity_x
					return sel
				case "y":
					entity_y := alloc_entity_field(nil, make_token_ident("y"), t_f16, false, 1)
					selection_add_index(&sel, 1)
					sel.entity = entity_y
					return sel
				case "z":
					entity_z := alloc_entity_field(nil, make_token_ident("z"), t_f16, false, 2)
					selection_add_index(&sel, 2)
					sel.entity = entity_z
					return sel
				}

			case .Quaternion128:
				// quaternion128: 4 x f32
				switch field_name {
				case "w":
					entity_w := alloc_entity_field(nil, make_token_ident("w"), t_f32, false, 3)
					selection_add_index(&sel, 3)
					sel.entity = entity_w
					return sel
				case "x":
					entity_x := alloc_entity_field(nil, make_token_ident("x"), t_f32, false, 0)
					selection_add_index(&sel, 0)
					sel.entity = entity_x
					return sel
				case "y":
					entity_y := alloc_entity_field(nil, make_token_ident("y"), t_f32, false, 1)
					selection_add_index(&sel, 1)
					sel.entity = entity_y
					return sel
				case "z":
					entity_z := alloc_entity_field(nil, make_token_ident("z"), t_f32, false, 2)
					selection_add_index(&sel, 2)
					sel.entity = entity_z
					return sel
				}

			case .Quaternion256:
				// quaternion256: 4 x f64
				switch field_name {
				case "w":
					entity_w := alloc_entity_field(nil, make_token_ident("w"), t_f64, false, 3)
					selection_add_index(&sel, 3)
					sel.entity = entity_w
					return sel
				case "x":
					entity_x := alloc_entity_field(nil, make_token_ident("x"), t_f64, false, 0)
					selection_add_index(&sel, 0)
					sel.entity = entity_x
					return sel
				case "y":
					entity_y := alloc_entity_field(nil, make_token_ident("y"), t_f64, false, 1)
					selection_add_index(&sel, 1)
					sel.entity = entity_y
					return sel
				case "z":
					entity_z := alloc_entity_field(nil, make_token_ident("z"), t_f64, false, 2)
					selection_add_index(&sel, 2)
					sel.entity = entity_z
					return sel
				}

			case .Untyped_Quaternion:
				// Untyped quaternions use untyped float fields
				switch field_name {
				case "w":
					entity_w := alloc_entity_field(nil, make_token_ident("w"), t_untyped_float, false, 3)
					selection_add_index(&sel, 3)
					sel.entity = entity_w
					return sel
				case "x":
					entity_x := alloc_entity_field(nil, make_token_ident("x"), t_untyped_float, false, 0)
					selection_add_index(&sel, 0)
					sel.entity = entity_x
					return sel
				case "y":
					entity_y := alloc_entity_field(nil, make_token_ident("y"), t_untyped_float, false, 1)
					selection_add_index(&sel, 1)
					sel.entity = entity_y
					return sel
				case "z":
					entity_z := alloc_entity_field(nil, make_token_ident("z"), t_untyped_float, false, 2)
					selection_add_index(&sel, 2)
					sel.entity = entity_z
					return sel
				}
			}
		}
	}

	// Not found
	return sel
}

// ============================================================================
// Additional Type Helpers for Builtin Checking
// ============================================================================

// is_type_asm_proc checks if type is an asm procedure
// C++ Reference: /mnt/c/odin/src/types.cpp:1654-1658
is_type_asm_proc :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	if bt.kind != .Proc {
		return false
	}
	proc_type := bt.variant.(Type_Proc)
	return proc_type.calling_convention == .Inline_Asm
}

// ============================================================================
// Additional Type Predicates
// ============================================================================

// is_type_u8_array checks if type is [N]u8 (byte array)
// C++ Reference: /mnt/c/odin/src/types.cpp:1713-1720
is_type_u8_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Array {
		return false
	}
	arr := bt.variant.(Type_Array)
	return is_type_u8(arr.elem)
}

// is_type_rune_array checks if type is [N]rune
// C++ Reference: /mnt/c/odin/src/types.cpp:1737-1744
is_type_rune_array :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Array {
		return false
	}
	arr := bt.variant.(Type_Array)
	return is_type_rune(arr.elem)
}

// is_type_soa_struct is defined in check_equivalence.odin

// union_tag_size calculates the size of a union's tag field
// C++ Reference: /mnt/c/odin/src/types.cpp:3285-3323
//
// The tag size is determined by:
// 1. Minimum size needed to represent all variants (1, 2, 4, or 8 bytes)
// 2. Alignment of the union's variants
// 3. Custom alignment if specified
// 4. Platform max_align constraint (8 bytes)
//
// Returns 0 if union has no variants
// set_union_variant_block_size caches the offset of a union's tag — i.e. the size of the
// variant block, before the tag is appended and before final alignment.
// C++ Reference: /mnt/c/odin/src/types.cpp:4766 and :4773.
set_union_variant_block_size :: proc(u_param: ^Type, block_size: i64) {
	u := base_type(u_param)
	if u == nil || u.kind != .Union {
		return
	}
	if union_type, ok := &u.variant.(Type_Union); ok {
		union_type.variant_block_size = block_size
	}
}

union_tag_size :: proc(u_param: ^Type) -> int {
	// C++ Reference: types.cpp:3286 - Unwrap named types
	u := base_type(u_param)
	assert(u.kind == .Union, "union_tag_size requires a union type")

	// Get mutable reference to union variant for caching
	union_type := &u.variant.(Type_Union)

	// C++ Reference: types.cpp:3288-3290 - Check cache
	if union_type.tag_size > 0 {
		return int(union_type.tag_size)
	}

	// Empty union has no tag (C++ line 3292-3295)
	n := len(union_type.variants)
	if n == 0 {
		return 0
	}

	// Determine minimum tag size based on variant count (C++ line 3297-3307)
	max_align := 1
	if n < (1 << 8) {
		max_align = 1
	} else if n < (1 << 16) {
		max_align = 2
	} else if n < (1 << 32) {
		max_align = 4
	} else {
		// C++ compiler_error here, but we'll just use i64
		max_align = 8
	}

	// Consider custom alignment if specified (C++ line 3309-3311)
	if union_type.custom_align > 0 {
		max_align = max(max_align, int(union_type.custom_align))
	} else {
		// Otherwise use maximum alignment of all variants (C++ line 3312-3318)
		for variant in union_type.variants {
			align := type_align_of(variant)
			if max_align < align {
				max_align = align
			}
		}
	}

	// Cap at platform max_align (8) (C++ line 3321)
	// C++ uses: gb_min3(max_align, build_context.max_align, 8)
	// We use 8 as the platform max align constant
	MAX_ALIGN :: 8
	tag_size := min(max_align, MAX_ALIGN)

	// C++ Reference: types.cpp:3321 - Store in cache
	union_type.tag_size = i16(tag_size)
	return tag_size
}

// union_tag_type returns the appropriate integer type for a union's tag
// C++ Reference: /mnt/c/odin/src/types.cpp:3325-3336
//
// Maps tag size to unsigned integer type:
//   0 or 1 byte -> u8
//   2 bytes     -> u16
//   4 bytes     -> u32
//   8 bytes     -> u64
union_tag_type :: proc(u: ^Type) -> ^Type {
	s := union_tag_size(u)
	switch s {
	case 0:
		return t_u8 // C++ line 3328
	case 1:
		return t_u8 // C++ line 3329
	case 2:
		return t_u16 // C++ line 3330
	case 4:
		return t_u32 // C++ line 3331
	case 8:
		return t_u64 // C++ line 3332
	case:
		panic("Invalid union_tag_size") // C++ line 3334
	}
}

// is_type_string16 checks if type is string16 (UTF-16 string)
// C++ Reference: /mnt/c/odin/src/types.cpp (similar to is_type_string)
is_type_string16 :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return basic.kind == .String16
}

// is_type_cstring16 checks if type is cstring16 (wide C string)
// C++ Reference: /mnt/c/odin/src/types.cpp:1331-1337
is_type_cstring16 :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return basic.kind == .Cstring16
}

// ============================================================================
// Atomic Operations Support
// ============================================================================

// is_type_valid_atomic_type checks if a type is valid for atomic operations
// Valid atomic types: integers, floats, booleans, pointers, bit_sets (as integers)
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:5914-5926
is_type_valid_atomic_type :: proc(elem: ^Type) -> bool {
	ct := core_type(elem)
	if ct == nil {
		return false
	}

	// Pointers and pointer-like types are atomic
	if is_type_internally_pointer_like(ct) {
		return true
	}

	// A bit_set is atomic through its integer representation, so reduce it to that
	// integer and let the flag test below decide -- C++ does exactly this rather than
	// accepting every bit_set outright.
	if ct.kind == .Bit_Set {
		ct = core_type(bit_set_to_int(ct))
		if ct == nil {
			return false
		}
	}

	if ct.kind != .Basic {
		return false
	}

	basic := ct.variant.(Type_Basic)

	// C++: (elem->Basic.flags & (BasicFlag_Boolean|BasicFlag_OrderedNumeric)) != 0.
	// This must stay a flag test, not an enumeration of Basic_Kind values: the previous
	// hand-written switch silently omitted every endian-specific integer (u32be, i64le,
	// ...) and the sized booleans b8/b16/b32/b64, so atomics on them were rejected with
	// the wrong diagnostic before the endianness check could ever run.
	return basic.flags & (BASIC_FLAG_ORDERED_NUMERIC | {.Boolean}) != {}
}

// ============================================================================
// Objective-C Runtime Type Helpers
// ============================================================================

// is_type_objc_object checks if a type is compatible with objc_object
// C++ Reference: /mnt/c/odin/src/types.cpp:4734-4736
is_type_objc_object :: proc(t: ^Type) -> bool {
	return internal_check_is_assignable_to(t, t_objc_object)
}

// has_type_got_objc_class_attribute checks if a type has objc_class attribute
// C++ Reference: /mnt/c/odin/src/types.cpp:4727-4729
has_type_got_objc_class_attribute :: proc(t: ^Type) -> bool {
	if t == nil || t.kind != .Named {
		return false
	}

	named := t.variant.(Type_Named)
	if named.type_name == nil || named.type_name.kind != .Type_Name {
		return false
	}

	type_name_entity := named.type_name.variant.(Entity_Type_Name)
	return type_name_entity.objc_class_name != ""
}


// ============================================================================
// Advanced Reflection - Offset Calculation
// ============================================================================

// type_offset_of calculates the offset of a field at a given index within a type
// C++ Reference: /mnt/c/odin/src/types.cpp:4512-4609
//
// Parameters:
//   - t: The type containing the field
//   - index: The field index (for structs), array index, or special synthetic field index
//
// Returns: Offset in bytes from the start of the type
//
// Notes:
//   - For structs: Uses pre-calculated offsets (requires type_set_offsets)
//   - For arrays: Calculates as index * element_size
//   - For synthetic types (string, slice, dynamic_array, any): Hardcoded layout
//   - For unions: Tag is at special index -1
type_offset_of :: proc(t: ^Type, index: i64) -> i64 {
	bt := base_type(t)

	#partial switch bt.kind {
	case .Struct:
		// Struct offsets require alignment-aware calculation
		// C++ Reference: types.cpp:4515-4522, type_set_offsets_of (4214-4259)
		struc := bt.variant.(Type_Struct)
		if index < 0 || index >= i64(len(struc.fields)) {
			return 0
		}

		// C++ Reference: types.cpp:4544-4547. A #raw_union OVERLAYS its members, so
		// every field sits at offset 0. The port had only the aligned arm below, so
		// raw-union members were laid out sequentially: the first member's offset came
		// out right by coincidence (it is 0 either way) and every later one was wrong.
		// core/sys/linux/types.odin asserts these offsets directly — Sig_Info alone
		// accounts for most of the file's failing assertions.
		if struc.is_raw_union {
			return 0
		}

		// C++ Reference: types.cpp:4548-4557. A #packed struct applies no alignment
		// padding at all; fields are laid end to end.
		if struc.is_packed {
			curr_offset: i64 = 0
			for i in 0 ..< index {
				if field := struc.fields[i]; field.kind == .Variable {
					curr_offset += i64(type_size_of(field.variant.(Entity_Variable).type))
				}
			}
			return curr_offset
		}

		// Calculate aligned offsets for all fields up to and including target index
		// This matches the logic in type_set_offsets_of from types.cpp
		curr_offset: i64 = 0

		for i in 0 ..< index {
			if field := struc.fields[i]; field.kind == .Variable {
				var_field := field.variant.(Entity_Variable)

				// Get field alignment and size
				field_align := i64(type_align_of(var_field.type))
				field_size := i64(type_size_of(var_field.type))

				// Align current offset to field's alignment requirement
				// align_formula: (offset + align - 1) - ((offset + align - 1) % align)
				if field_align > 0 {
					curr_offset = (curr_offset + field_align - 1) - ((curr_offset + field_align - 1) % field_align)
				}

				// Add this field's size to get offset for next field
				curr_offset += field_size
			}
		}

		// Now align to the target field's alignment to get its actual offset
		if field := struc.fields[index]; field.kind == .Variable {
			var_field := field.variant.(Entity_Variable)
			target_align := i64(type_align_of(var_field.type))
			if target_align > 0 {
				curr_offset = (curr_offset + target_align - 1) - ((curr_offset + target_align - 1) % target_align)
			}
		}

		return curr_offset

	case .Tuple:
		// Tuple offsets require alignment-aware calculation, same as structs
		// C++ Reference: types.cpp:4523-4533, type_set_offsets_of (4214-4259)
		tuple := bt.variant.(Type_Tuple)
		if index < 0 || index >= i64(len(tuple.variables)) {
			return 0
		}

		// Calculate aligned offsets for all elements up to and including target index
		curr_offset: i64 = 0

		for i in 0 ..< index {
			if var := tuple.variables[i]; var != nil {
				// Get element alignment and size
				elem_align := i64(type_align_of(var.type))
				elem_size := i64(type_size_of(var.type))

				// Align current offset to element's alignment requirement
				if elem_align > 0 {
					curr_offset = (curr_offset + elem_align - 1) - ((curr_offset + elem_align - 1) % elem_align)
				}

				// Add this element's size to get offset for next element
				curr_offset += elem_size
			}
		}

		// Now align to the target element's alignment to get its actual offset
		if var := tuple.variables[index]; var != nil {
			target_align := i64(type_align_of(var.type))
			if target_align > 0 {
				curr_offset = (curr_offset + target_align - 1) - ((curr_offset + target_align - 1) % target_align)
			}
		}

		return curr_offset

	case .Array:
		// Array: offset = index * element_size
		// C++ Reference: types.cpp:4535-4537
		arr := bt.variant.(Type_Array)
		assert(0 <= index && index < arr.count)
		return index * i64(type_size_of(arr.elem))

	case .Basic:
		// Synthetic composite types with fixed layouts
		// C++ Reference: types.cpp:4539-4566
		basic := bt.variant.(Type_Basic)

		if basic.kind == .String || basic.kind == .String16 {
			// string/string16 layout: [0]=data (^u8 or ^u16), [1]=len (int)
			switch index {
			case 0:
				return 0 // data pointer
			case 1:
				return i64(size_of(rawptr)) // len starts after pointer
			}
		} else if basic.kind == .Any {
			// any layout: [0]=data (rawptr), [1]=id (typeid)
			switch index {
			case 0:
				return 0 // data pointer
			case 1:
				return 8 // typeid (always 8 bytes)
			}
		}

	case .Slice:
		// slice layout: [0]=data ([^]T), [1]=len (int)
		// C++ Reference: types.cpp:4567-4575
		switch index {
		case 0:
			return 0 // data multi-pointer
		case 1:
			return i64(size_of(rawptr)) // len starts after pointer
		}

	case .Dynamic_Array:
		// dynamic array layout: [0]=data, [1]=len, [2]=cap, [3]=allocator
		// C++ Reference: types.cpp:4576-4588
		int_size := i64(size_of(int))
		switch index {
		case 0:
			return 0 // data
		case 1:
			return int_size // len
		case 2:
			return 2 * int_size // cap
		case 3:
			return 3 * int_size // allocator
		}

	case .Union:
		// Union tag field (special index -1)
		// C++ Reference: types.cpp:4589-4598
		// Maybe-pointer unions don't have a tag field
		if !is_type_union_maybe_pointer(bt) {
			_ = type_size_of(bt) // Ensure size is calculated
			if index == -1 {
				_ = union_tag_size(bt)
				union_type := bt.variant.(Type_Union)
				return union_type.variant_block_size
			}
		}
	}

	// Default: index 0 means offset 0
	// C++ Reference: types.cpp:4600
	assert(index == 0)
	return 0
}

// type_offset_of_from_selection calculates total offset by following a Selection path
// C++ Reference: /mnt/c/odin/src/types.cpp:4611-4665
//
// The Selection contains an index path (e.g., [0, 2] for field 0, then subfield 2).
// This function walks the path, accumulating offsets and updating the current type.
//
// Parameters:
//   - type: The starting type
//   - sel: The selection path to follow
//
// Returns: Total offset in bytes
//
// Note: sel.indirect must be false (cannot calculate offset through pointers)
type_offset_of_from_selection :: proc(type: ^Type, sel: Selection) -> i64 {
	// C++ Reference: types.cpp:4612
	assert(sel.indirect == false, "Cannot calculate offset with indirect selection (pointer dereference)")

	t := type
	offset: i64 = 0

	// Walk the selection path
	// C++ Reference: types.cpp:4615-4662
	for index_val in sel.index {
		index := i64(index_val)
		t = base_type(t)

		// Accumulate offset for this step
		offset += type_offset_of(t, index)

		// Update type for next iteration
		// C++ Reference: types.cpp:4618-4660
		#partial switch t.kind {
		case .Struct:
			// Next type is the field's type
			struc := t.variant.(Type_Struct)
			if index >= 0 && index < i64(len(struc.fields)) {
				if field := struc.fields[index]; field.kind == .Variable {
					var_field := field.variant.(Entity_Variable)
					t = var_field.type
				}
			}

		case .Array:
			// Next type is element type
			arr := t.variant.(Type_Array)
			t = arr.elem

		case .Basic:
			// Handle synthetic composite types
			basic := t.variant.(Type_Basic)

			if basic.kind == .String {
				// string: [0]=^u8, [1]=int
				switch index {
				case 0:
					t = t_rawptr // data is rawptr in practice
				case 1:
					t = t_int
				}
			} else if basic.kind == .Any {
				// any: [0]=rawptr, [1]=typeid
				switch index {
				case 0:
					t = t_rawptr
				case 1:
					t = t_typeid
				}
			}

		case .Slice:
			// slice: [0]=[^]T (data), [1]=int (len)
			// NOTE: Slices only have 2 fields (data, len), not 3
			// C++ Reference: types.cpp:4641-4645
			_ = t.variant.(Type_Slice) // unused: slice_type
			switch index {
			case 0:
				t = t_rawptr // Data Pointer
			case 1:
				t = t_int // Len
			}

		case .Dynamic_Array:
			// dynamic_array: [0]=[^]T, [1]=int, [2]=int, [3]=allocator
			// C++ Reference: types.cpp:4646-4652
			_ = t.variant.(Type_Dynamic_Array) // unused: dyn_arr
			switch index {
			case 0:
				t = t_rawptr // Data Pointer
			case 1:
				t = t_int // Len
			case 2:
				t = t_int // Cap
			case 3:
				t = t_allocator // Allocator
			}
		}
	}

	return offset
}

// ============================================================================
// Type Allocation Functions
// ============================================================================

// alloc_type_generic allocates a generic/polymorphic type parameter
// C++ Reference: checker.cpp:1842-1856
alloc_type_generic :: proc(c: ^Checker, scope: ^Scope, id: i64, name: string, specialized: ^Type) -> ^Type {
	_ = c
	t := alloc_type(Type_Generic)
	if gen, ok := &t.variant.(Type_Generic); ok {
		gen.id = id
		gen.name = name
		gen.specialized = specialized
		gen.scope = scope
	}
	set_base_type(t, t)
	return t
}

// alloc_type_struct allocates a struct type
// C++ Reference: checker.cpp:1858-1893
alloc_type_struct :: proc(c: ^Checker) -> ^Type {
	_ = c
	t := alloc_type(Type_Struct)
	set_base_type(t, t)

	// Initialize wait groups for multi-threaded field resolution
	// C++ Reference: check_type.cpp:665, 681
	// The wait groups start with count=1, and wait_group_done() is called
	// when processing completes. This allows other threads to wait on field availability.
	st := &t.variant.(Type_Struct)
	sync.wait_group_add(&st.polymorphic_wait_signal, 1)
	sync.wait_group_add(&st.fields_wait_signal, 1)

	return t
}

// alloc_type_union allocates a union type
// C++ Reference: checker.cpp:1895-1920
alloc_type_union :: proc(c: ^Checker) -> ^Type {
	_ = c
	t := alloc_type(Type_Union)
	set_base_type(t, t)

	// Initialize wait group for multi-threaded polymorphic resolution
	// C++ Reference: check_type.cpp - unions also need polymorphic wait signal
	ut := &t.variant.(Type_Union)
	sync.wait_group_add(&ut.polymorphic_wait_signal, 1)

	return t
}

// alloc_type_enum allocates an enum type
// C++ Reference: checker.cpp:1922-1940
alloc_type_enum :: proc(c: ^Checker = nil) -> ^Type {
	_ = c
	t := alloc_type(Type_Enum)
	set_base_type(t, t)
	return t
}

// alloc_type_bit_field allocates a bit field type
// C++ Reference: checker.cpp:1942-1967
alloc_type_bit_field :: proc(c: ^Checker) -> ^Type {
	_ = c
	t := alloc_type(Type_Bit_Field)
	set_base_type(t, t)
	return t
}

// alloc_type_bit_set is defined in check_type.odin

// alloc_type_named is defined in check_decl_helpers.odin

// alloc_type_pointer_to_multi_pointer converts a pointer type to multi-pointer
// C++ Reference: checker.cpp:2020-2034
alloc_type_pointer_to_multi_pointer :: proc(c: ^Checker, ptr_type: ^Type) -> ^Type {
	_ = c
	if ptr, ok := ptr_type.variant.(Type_Pointer); ok {
		return alloc_type_multi_pointer(ptr.elem)
	}
	return ptr_type
}

// alloc_type_multi_pointer_to_pointer converts a multi-pointer type to pointer
// C++ Reference: checker.cpp:2036-2050
alloc_type_multi_pointer_to_pointer :: proc(c: ^Checker, mp_type: ^Type) -> ^Type {
	_ = c
	if mp, ok := mp_type.variant.(Type_Multi_Pointer); ok {
		return alloc_type_pointer(mp.elem)
	}
	return mp_type
}

// alloc_type_tuple_from_field_types creates a tuple type from field types
// C++ Reference: types.cpp:4755-4773
alloc_type_tuple_from_field_types :: proc(c: ^Checker, types: []^Type) -> ^Type {
	_ = c

	// Handle edge cases
	if len(types) == 0 {
		return nil
	}
	// Single type doesn't need tuple wrapper
	if len(types) == 1 {
		return types[0]
	}

	// Create parameter entities for each type (matches C++ alloc_entity_param usage)
	variables := make([dynamic]^Entity, len(types))

	for type, i in types {
		// C++ uses alloc_entity_param(scope, blank_token, field_types[i], false, false)
		entity := alloc_entity_param(nil, blank_token, type, false, false)
		variables[i] = entity
	}

	return alloc_type_tuple(variables[:])
}

// alloc_type_proc_from_types creates a procedure type from parameter and result types
// C++ Reference: checker.cpp:2075-2110
alloc_type_proc_from_types :: proc(c: ^Checker, params: []^Type, results: []^Type, variadic: bool) -> ^Type {
	param_tuple := alloc_type_tuple_from_field_types(c, params)
	result_tuple := alloc_type_tuple_from_field_types(c, results)

	return alloc_type_proc(nil, param_tuple, result_tuple, len(params), len(results), variadic, .Odin)
}

// ============================================================================
// Type Predicate Functions
// ============================================================================

// is_type_named checks if a type is a named type wrapper
// C++ Reference: checker.cpp:2112-2115
is_type_named :: proc(t: ^Type) -> bool {
	_, ok := t.variant.(Type_Named)
	return ok
}

// is_type_generic checks if a type is a generic/polymorphic parameter
// C++ Reference: checker.cpp:2117-2120
is_type_generic :: proc(t: ^Type) -> bool {
	_, ok := base_type(t).variant.(Type_Generic)
	return ok
}

// is_type_integer_like checks if a type behaves like an integer.
//
// C++ Reference: types.cpp:1320-1334.
//
// This mirrors C++ exactly, which matters in three ways the previous version got wrong:
// it reduces with `core_type`, not `base_type`; it has a `Bit_Set` arm, so a bit_set
// counts as integer-like (its underlying representation is an integer); and it
// nil-guards after reduction. The old version also carried an explicit `Enum` arm,
// which was compensating for the use of `base_type` -- `core_type` already unwraps an
// enum to its backing integer, so the arm is redundant here and is dropped.
is_type_integer_like :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == nil {
		return false
	}
	#partial switch v in ct.variant {
	case Type_Basic:
		// Integer-like includes both Integer and Boolean types
		return (.Integer in v.flags) || (.Boolean in v.flags)
	case Type_Bit_Set:
		if v.underlying != nil {
			return is_type_integer_like(v.underlying)
		}
		return true
	}
	return false
}

// is_type_array_like reports whether a type is a fixed-length array — either
// `[N]T` or an enumerated array `[E]T`.
//
// C++ Reference: types.cpp:1918-1920, `is_type_array(t) || is_type_enumerated_array(t)`.
// This deliberately does NOT include slices, dynamic arrays or strings: its two call
// sites (check_stmt.cpp:2652 and check_builtin.cpp:3922) both rely on the operand
// having a fixed count. The port previously accepted those three as well, which made
// `check_unsafe_return` report taking the address of an element of a local slice —
// something C++ permits, since the backing storage is not on the stack.
//
// Both C++ predicates nil-guard after `base_type` (types.cpp:1570); the port's version
// dereferenced `bt.variant` unconditionally and segfaulted on an entity whose type had
// not been resolved.
is_type_array_like :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	#partial switch _ in bt.variant {
	case Type_Array, Type_Enumerated_Array:
		return true
	}
	return false
}

// is_type_ordered_numeric checks if a type supports ordered comparison
// C++ Reference: checker.cpp:2159-2181
is_type_ordered_numeric :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	#partial switch v in bt.variant {
	case Type_Basic:
		// Check using BASIC_FLAG_ORDERED_NUMERIC composite flag
		// ORDERED_NUMERIC = Integer | Float | Rune
		return (v.flags & BASIC_FLAG_ORDERED_NUMERIC) != {}
	case Type_Pointer, Type_Multi_Pointer:
		return true
	}
	return false
}

// is_type_complex_or_quaternion checks if a type is complex or quaternion
// is_type_complex_or_quaternion is defined in check_expr.odin

// is_type_untyped_nil is defined in check_decl_helpers.odin

// is_type_untyped_uninit is defined in check_builtin_simd.odin

// is_type_union_maybe_pointer checks if a union can be used as a maybe pointer
// C++ Reference: checker.cpp:2211-2240
// is_type_union_maybe_pointer reports whether a union can use its single variant's own
// nil representation as the tag, needing no separate tag at all — `union { ^int }` is
// 8 bytes, not 16.
//
// C++ Reference: /mnt/c/odin/src/types.cpp:2031-2039 — exactly ONE variant, which must be
// `is_type_internally_pointer_like` (pointer, multi-pointer, cstring, cstring16 or proc).
//
// The port previously required TWO variants and looked for an `untyped nil` among them.
// A union's variant list never contains `untyped nil`, so this always returned false:
// every maybe-pointer union was sized and laid out as though it carried a tag.
is_type_union_maybe_pointer :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	u, ok := bt.variant.(Type_Union)
	if !ok {
		return false
	}
	if len(u.variants) != 1 {
		return false
	}
	return is_type_internally_pointer_like(u.variants[0])
}

// is_type_valid_for_keys checks if a type can be used as a map key
// C++ Reference: types.cpp:2260-2269
//
// NOTE: this used to hand-roll a structural walk (Basic-except-typeid, pointer, enum, array-of-valid,
// struct-of-valid, everything else false). C++ asks three much simpler questions, and the two disagree
// in both directions - the old version rejected typeid, unions and raw unions that C++ accepts (they
// are comparable and non-zero-sized), and accepted zero-sized structs that C++ rejects.
is_type_valid_for_keys :: proc(t: ^Type) -> bool {
	ct := core_type(t)
	if ct == nil {
		return false
	}
	if ct.kind == .Generic {
		return true
	}
	if is_type_untyped(ct) {
		return false
	}
	return type_size_of(ct) > 0 && is_type_comparable(ct)
}

// is_type_valid_bit_set_elem checks if a type can be a bit_set element
// C++ Reference: checker.cpp:2271-2289
is_type_valid_bit_set_elem :: proc(t: ^Type) -> bool {
	if is_type_enum(t) {
		return true
	}
	ct := core_type(t)
	if ct == nil {
		return false
	}
	return ct.kind == .Generic
}

// is_type_valid_vector_elem checks if a type can be a vector element
// C++ Reference: checker.cpp:2291-2307
// C++ Reference: /mnt/c/odin/src/types.cpp:2324-2347.
//
// The port previously hand-rolled this as a raw Basic_Kind RANGE test,
// `(kind >= .I8 && kind <= .F64) || (kind >= .Complex32 && kind <= .Quaternion256)`,
// which diverged from C++ in four ways at once:
//   - REJECTED booleans        — C++ accepts them (core/simd declares b8/b16/b32/b64 vectors)
//   - REJECTED rawptr          — C++ accepts it
//   - ACCEPTED complex/quaternion — C++ does not list them, so they are invalid
//   - ignored the endian flags and the 128-bit integer exclusion entirely
//
// Range tests over a Basic_Kind enum are inherently fragile here: they encode the
// declaration order of the enum rather than the property being tested.
is_type_valid_vector_elem :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	if basic, ok := bt.variant.(Type_Basic); ok {
		// C++ line 2327-2332: endian-specific types are not valid vector elements.
		flags := basic_flags_table[basic.kind]
		if .Endian_Little in flags || .Endian_Big in flags {
			return false
		}
		// C++ line 2333-2335: integers, except the 128-bit ones.
		if is_type_integer(bt) {
			#partial switch basic.kind {
			case .I128, .U128:
				return false
			}
			return true
		}
		if is_type_float(bt) {
			return true
		}
		if is_type_boolean(bt) {
			return true
		}
		if basic.kind == .Rawptr {
			return true
		}
	}

	return false
}

// is_type_valid_for_matrix_elems checks if a type can be a matrix element
// C++ Reference: types.cpp:1707-1721
//
// NOTE: this was correct all along but check_matrix_type_expr never called it - it hand-rolled
// `!is_type_integer && !is_type_float && !is_type_complex && !is_type_quaternion` instead, which both
// REJECTED Generic (so `matrix[$R, $C]$E` could never be declared) and ACCEPTED quaternion (which C++
// does not). Only check_builtin.odin used this. Now wired into check_matrix_type_expr as well.
is_type_valid_for_matrix_elems :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}

	// Integers are valid
	if is_type_integer(bt) {
		return true
	}
	// Floats are valid
	if is_type_float(bt) {
		return true
	}
	// Complex types are valid
	if is_type_complex(bt) {
		return true
	}
	// Generic types are valid (for polymorphic matrices)
	if bt.kind == .Generic {
		return true
	}

	return false
}

// ============================================================================
// Type Helper Functions
// ============================================================================

// is_calling_convention_none checks if calling convention is none
// C++ Reference: checker.cpp:2322-2325
is_calling_convention_none :: proc(cc: Proc_Calling_Convention) -> bool {
	return cc == .None
}

// is_calling_convention_odin checks if calling convention is odin (default)
// C++ Reference: checker.cpp:2327-2330
is_calling_convention_odin :: proc(cc: Proc_Calling_Convention) -> bool {
	return cc == .Odin || cc == .None
}

// get_array_type_count is defined in check_expr.odin

// type_math_rank returns the numeric rank for type promotion
// C++ Reference: checker.cpp:2345-2388
type_math_rank :: proc(t: ^Type) -> int {
	bt := base_type(t)

	if basic, ok := bt.variant.(Type_Basic); ok {
		#partial switch basic.kind {
		case .I8, .U8:
			return 1
		case .I16, .U16:
			return 2
		case .I32, .U32, .Rune:
			return 3
		case .I64, .U64:
			return 4
		case .I128, .U128:
			return 5
		case .Int, .Uint, .Uintptr:
			return 6
		case .F16:
			return 7
		case .F32:
			return 8
		case .F64:
			return 9
		case .Complex32:
			return 10
		case .Complex64:
			return 11
		case .Complex128:
			return 12
		case .Quaternion64:
			return 13
		case .Quaternion128:
			return 14
		case .Quaternion256:
			return 15
		case .Untyped_Integer:
			return 100
		case .Untyped_Float:
			return 101
		case .Untyped_Complex:
			return 102
		case .Untyped_Quaternion:
			return 103
		}
	}

	return 0
}

// is_valid_bit_field_backing_type checks if a type can back a bit_field
// C++ Reference: types.cpp:2161-2175
is_valid_bit_field_backing_type :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	bt := base_type(t)
	if is_type_untyped(bt) {
		return false
	}

	// Scalar integers are valid
	if is_type_integer(bt) {
		return true
	}

	// Arrays of integers are also valid (e.g., [4]u8 for a 32-bit bit_field)
	if arr, ok := bt.variant.(Type_Array); ok {
		return is_type_integer(arr.elem)
	}

	return false
}

// bit_set_to_int is defined in check_type.odin

// base_complex_elem_type is defined in check_poly_proc.odin

// integer_to_signed converts an integer type to its signed equivalent
// C++ Reference: check_builtin.cpp (type_integer_to_signed intrinsic)
integer_to_signed :: proc(t: ^Type) -> ^Type {
	bt := base_type(t)
	if basic, ok := bt.variant.(Type_Basic); ok {
		#partial switch basic.kind {
		case .I8, .I16, .I32, .I64, .I128, .Int:
			return t // Already signed
		case .U8:
			return t_i8
		case .U16:
			return t_i16
		case .U32:
			return t_i32
		case .U64:
			return t_i64
		case .U128:
			return t_i128
		case .Uint, .Uintptr:
			return t_int
		// Endian-specific variants - return as-is since endian type globals may not exist
		case .U16le, .U32le, .U64le, .U128le, .U16be, .U32be, .U64be, .U128be,
		     .I16le, .I32le, .I64le, .I128le, .I16be, .I32be, .I64be, .I128be:
			return t
		}
	}
	return t // Not an integer type, return as-is
}

// integer_to_unsigned converts an integer type to its unsigned equivalent
// C++ Reference: check_builtin.cpp (type_integer_to_unsigned intrinsic)
integer_to_unsigned :: proc(t: ^Type) -> ^Type {
	bt := base_type(t)
	if basic, ok := bt.variant.(Type_Basic); ok {
		#partial switch basic.kind {
		case .U8, .U16, .U32, .U64, .U128, .Uint, .Uintptr:
			return t // Already unsigned
		case .I8:
			return t_u8
		case .I16:
			return t_u16
		case .I32:
			return t_u32
		case .I64:
			return t_u64
		case .I128:
			return t_u128
		case .Int:
			return t_uint
		// Endian-specific variants - return as-is since endian type globals may not exist
		case .I16le, .I32le, .I64le, .I128le, .I16be, .I32be, .I64be, .I128be,
		     .U16le, .U32le, .U64le, .U128le, .U16be, .U32be, .U64be, .U128be:
			return t
		}
	}
	return t // Not an integer type, return as-is
}
