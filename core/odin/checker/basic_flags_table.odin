package checker

/*
Basic type flags table - maps each Basic_Kind to its type category flags.
C++ Reference: /mnt/c/odin/src/types.cpp:473-547

This table enables O(1) type category checks using bit flags instead of
switch-based comparisons. Each Basic_Kind has an associated set of flags
that describe its properties (Boolean, Integer, Float, Rune, etc.).

Usage:
	t := base_type(my_type)
	if basic, ok := t.variant.(Type_Basic); ok {
		flags := basic_flags_table[basic.kind]
		is_integer := .Integer in flags
		is_numeric := (.Integer in flags) || (.Float in flags) || (.Complex in flags) || (.Quaternion in flags)
	}
*/

// basic_flags_table maps each Basic_Kind enum value to its type category flags
// C++ Reference: types.cpp:473-547 (gb_global BasicType basic_types[])
//
// This table MUST be kept in sync with Basic_Kind enum values.
// Each entry specifies which type categories a basic kind belongs to.
basic_flags_table := [Basic_Kind]Basic_Flags {
	.Invalid            = {},

	// Boolean types
	// C++ lines 473-478
	.Llvm_Bool          = {.Boolean, .LLVM},
	.Bool               = {.Boolean},
	.B8                 = {.Boolean},
	.B16                = {.Boolean},
	.B32                = {.Boolean},
	.B64                = {.Boolean},

	// Integer types
	// C++ lines 481-494
	.I8                 = {.Integer},
	.U8                 = {.Integer, .Unsigned},
	.I16                = {.Integer},
	.U16                = {.Integer, .Unsigned},
	.I32                = {.Integer},
	.U32                = {.Integer, .Unsigned},
	.I64                = {.Integer},
	.U64                = {.Integer, .Unsigned},
	.I128               = {.Integer},
	.U128               = {.Integer, .Unsigned},

	// Rune is a distinct i32 with Rune flag
	// C++ line 493
	.Rune               = {.Integer, .Rune},

	// Float types
	// C++ lines 495-497
	.F16                = {.Float},
	.F32                = {.Float},
	.F64                = {.Float},

	// Complex types
	// C++ lines 498-500
	.Complex32          = {.Complex},
	.Complex64          = {.Complex},
	.Complex128         = {.Complex},

	// Quaternion types
	// C++ lines 501-503
	.Quaternion64       = {.Quaternion},
	.Quaternion128      = {.Quaternion},
	.Quaternion256      = {.Quaternion},

	// Platform-dependent integer types
	// C++ lines 505-508
	.Int                = {.Integer},
	.Uint               = {.Integer, .Unsigned},
	// NOTE: `uintptr` is NOT flagged as a pointer; C++ types.cpp:522 gives it only
	// `BasicFlag_Integer | BasicFlag_Unsigned`. Only `rawptr` carries BasicFlag_Pointer.
	.Uintptr            = {.Integer, .Unsigned},
	.Rawptr             = {.Pointer},

	// String types
	// C++ lines 510-513
	.String             = {.String},
	.Cstring            = {.String},
	.String16           = {.String},
	.Cstring16          = {.String},

	// Special types
	// C++ lines 515-516
	.Any                = {},
	.Typeid             = {},

	// Endian-specific integer types (little-endian)
	// C++ lines 518-525
	.I16le              = {.Integer, .Endian_Little},
	.U16le              = {.Integer, .Unsigned, .Endian_Little},
	.I32le              = {.Integer, .Endian_Little},
	.U32le              = {.Integer, .Unsigned, .Endian_Little},
	.I64le              = {.Integer, .Endian_Little},
	.U64le              = {.Integer, .Unsigned, .Endian_Little},
	.I128le             = {.Integer, .Endian_Little},
	.U128le             = {.Integer, .Unsigned, .Endian_Little},

	// Endian-specific integer types (big-endian)
	// C++ lines 527-534
	.I16be              = {.Integer, .Endian_Big},
	.U16be              = {.Integer, .Unsigned, .Endian_Big},
	.I32be              = {.Integer, .Endian_Big},
	.U32be              = {.Integer, .Unsigned, .Endian_Big},
	.I64be              = {.Integer, .Endian_Big},
	.U64be              = {.Integer, .Unsigned, .Endian_Big},
	.I128be             = {.Integer, .Endian_Big},
	.U128be             = {.Integer, .Unsigned, .Endian_Big},

	// Endian-specific float types (little-endian)
	// C++ lines 536-538
	.F16le              = {.Float, .Endian_Little},
	.F32le              = {.Float, .Endian_Little},
	.F64le              = {.Float, .Endian_Little},

	// Endian-specific float types (big-endian)
	// C++ lines 540-542
	.F16be              = {.Float, .Endian_Big},
	.F32be              = {.Float, .Endian_Big},
	.F64be              = {.Float, .Endian_Big},

	// Untyped variants
	// C++ lines 544-552
	.Untyped_Bool       = {.Boolean, .Untyped},
	.Untyped_Integer    = {.Integer, .Untyped},
	.Untyped_Float      = {.Float, .Untyped},
	.Untyped_Complex    = {.Complex, .Untyped},
	.Untyped_Quaternion = {.Quaternion, .Untyped},
	.Untyped_String     = {.String, .Untyped},
	.Untyped_Rune       = {.Integer, .Rune, .Untyped},
	.Untyped_Nil        = {.Untyped},
	.Untyped_Uninit     = {.Untyped},
}

// get_basic_flags returns the type category flags for a Basic_Kind
// This is a convenience wrapper around the basic_flags_table
get_basic_flags :: proc(kind: Basic_Kind) -> Basic_Flags {
	return basic_flags_table[kind]
}

// has_basic_flag checks if a Basic_Kind has a specific flag
has_basic_flag :: proc(kind: Basic_Kind, flag: Basic_Flag) -> bool {
	return flag in basic_flags_table[kind]
}
