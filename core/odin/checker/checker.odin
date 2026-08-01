package checker

/*
Package checker provides semantic analysis for Odin AST.

This package implements type checking, name resolution, and semantic validation
following the design of the Odin compiler's C++ checker implementation.

Architecture:
- Checker: Top-level checker state
- Checker_Info: Symbol table and metadata repository
- Checker_Context: Per-operation checking context
- Decl_Info: Declaration metadata for any-order processing
- Scope: Hierarchical symbol scopes
- Operand: Intermediate expression values

The checker supports parallel semantic analysis through fine-grained locking
and work queues for entity and procedure checking.
*/

import "base:runtime"
import "core:container/queue"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:sync"

// ======================================================================================
// TYPE ALIASES FROM AST
// ======================================================================================
// NOTE: The semantic AST defines Entity, Type, Scope, Decl_Info, and related types.
// The checker currently redefines these types, but they are structurally identical
// to the AST versions. These aliases document that we should eventually use the AST
// types directly. See TYPE_UNIFICATION.md for the full plan.

// Core semantic types from ast.semantic_types
// NOTE: These are commented out aliases showing the planned unification targets:
// Entity :: ast.Entity  - Replace checker's Entity definition when unified
// Type :: ast.Type      - Replace checker's Type definition when unified
// Scope :: ast.Scope    - Replace checker's Scope definition when unified
// Decl_Info :: ast.Decl_Info  - Replace checker's Decl_Info definition when unified

// Supporting types from ast.semantic_types that are duplicated:
// - Addressing_Mode, Entity_State, Entity_Kind, Scope_Flag
// - Type_Kind, Type_Flag, Basic_Kind, Basic_Flag
// - Calling_Convention, Exact_Value, Parameter_Value
// - All Entity_* and Type_* variant structs

// Type aliases to ensure structural equivalence with AST types
// NOTE: These must be present for re-declared types like Scope to be compatible

// ======================================================================================
// CHECKER-SPECIFIC TYPES
// ======================================================================================

// Addressing_Mode indicates how an expression can be used
// C++ Reference: enum AddressingMode in parser.hpp:9-24
// NOTE: Enum ordering MUST match C++ exactly for compatibility
Addressing_Mode :: ast.Addressing_Mode

// Expr_Kind distinguishes expression vs statement context
Expr_Kind :: enum {
	Expr,
	Stmt,
}

// Stmt_Flag controls statement validation
Stmt_Flag :: distinct bit_set[Stmt_Flag_Bit;u32]
Stmt_Flag_Bit :: enum {
	Break_Allowed,
	Continue_Allowed,
	Fallthrough_Allowed,
	Type_Switch,
	Check_Scope_Decls,
}

// State_Flag tracks context-level flags that affect checking behavior
// These propagate downward from parent to child statements
// C++ Reference: StateFlag enum in /mnt/c/odin/src/parser.hpp:323-333
// NOTE: Use AST types directly now that they're available
State_Flag :: ast.Node_State_Flag
State_Flags :: ast.Node_State_Flags

// Viral_State_Flag tracks properties that propagate upward through the AST
// These "go viral" from child to parent expressions during checking
// C++ Reference: ViralStateFlag enum in /mnt/c/odin/src/parser.hpp:335-339
// NOTE: Use AST types directly now that they're available
Viral_State_Flag :: ast.Node_Viral_State_Flag
Viral_State_Flags :: ast.Node_Viral_State_Flags

// Ast_File_Flag controls file-level behavior
// C++ Reference: enum AstFileFlag in /mnt/c/odin/src/parser.hpp:91-98
// NOTE: These types are NOT present in core:odin/ast. We track them externally in Checker_Info.
// C++ uses bit positions (1<<0, 1<<1, etc.), we use enum values for bit_set
File_Flag :: ast.File_Flag
File_Flags :: ast.File_Flags

// Builtin_Proc_Pkg categorizes builtin procedures
Builtin_Proc_Pkg :: ast.Builtin_Proc_Pkg

BUILTIN_PROC_PKG_NAMES := [Builtin_Proc_Pkg]string {
	.Builtin    = "builtin",
	.Intrinsics = "intrinsics",
}

// Builtin_Proc describes a built-in procedure
Builtin_Proc :: struct {
	name:           string,
	arg_count:      int,
	variadic:       bool,
	kind:           Expr_Kind,
	pkg:            Builtin_Proc_Pkg,
	diverging:      bool,
	ignore_results: bool,
}

// Exact_Value variant components are re-declared from ast
Exact_Value_Pointer :: ast.Exact_Value_Pointer
Exact_Value_Compound :: ast.Exact_Value_Compound
Exact_Value_Procedure :: ast.Exact_Value_Procedure
Exact_Value_Typeid :: ast.Exact_Value_Typeid
Exact_Value_String16 :: ast.Exact_Value_String16

// Exact_Value is re-declared from ast.Exact_Value
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// C++ Reference: struct ExactValue in /mnt/c/odin/src/exact_value.cpp:37-52
Exact_Value :: ast.Exact_Value

// Expr_Info stores information for untyped expressions
Expr_Info :: struct {
	mode:   Addressing_Mode,
	is_lhs: bool,
	type:   ^Type,
	value:  Exact_Value,
}

// Raddbg_Type_View stores type debugging information for RadDbg
// C++ Reference: struct RaddbgTypeView in /mnt/c/odin/src/checker.hpp:436-439
Raddbg_Type_View :: struct {
	type: ^Type, // C++ line 437: Type *type
	view: string, // C++ line 438: String view
}

// Load_File_Tier represents the level of file information cached
// C++ Reference: enum LoadFileTier in /mnt/c/odin/src/checker.hpp:387-391
Load_File_Tier :: enum {
	Invalid,
	Exists,   // Only checked if file exists
	Contents, // Full file contents loaded
}

// Load_File_Cache stores cached file loading results for #load and #exists directives
// C++ Reference: struct LoadFileCache in /mnt/c/odin/src/checker.hpp:393-400
Load_File_Cache :: struct {
	tier:       Load_File_Tier,
	exists:     bool,
	path:       string,
	file_error: File_Error,
	data:       []u8,                 // File contents (if loaded)
	hashes:     map[string]u64,       // Pre-computed hashes for #load_hash
}

// File_Error represents file operation errors
// C++ Reference: gbFileError enum
File_Error :: enum {
	None,
	Invalid,
	Not_Exists,
	Permission,
	Truncation_Failure,
}

// Load_Directory_Cache stores cached directory loading results for #load_directory
// C++ Reference: struct LoadDirectoryCache in /mnt/c/odin/src/checker.hpp:408-412
Load_Directory_Cache :: struct {
	path:       string,
	file_error: File_Error,
	files:      [dynamic]^Load_File_Cache,
}

// Untyped_Expr_Info pairs an expression with its untyped info for queue processing
// C++ Reference: struct UntypedExprInfo in /mnt/c/odin/src/checker.hpp:364-367
Untyped_Expr_Info :: struct {
	expr: ^ast.Expr, // C++ line 365: Ast *expr
	info: ^Expr_Info, // C++ line 366: ExprInfo *info
}

// Type_And_Value stores type and value information for expression nodes
// C++ Reference: struct TypeAndValue in parser.hpp (stored in expr->tav)
// Since we use core:odin/ast which doesn't have a tav field, we store in an external map
Type_And_Value :: ast.Type_And_Value

// Operand is the intermediate value during type checking
Operand :: struct {
	mode:       Addressing_Mode,
	type:       ^Type,
	value:      Exact_Value,
	expr:       ^ast.Node, // Expression node (could be Expr, Ident, etc.)
	builtin_id: Builtin_Proc_Id,
	proc_group: ^Entity,
}

// Block_Label represents a labeled block
Block_Label :: ast.Block_Label

// Deferred_Procedure_Kind tracks procedure defer attributes
Deferred_Procedure_Kind :: ast.Deferred_Procedure_Kind

Deferred_Procedure :: ast.Deferred_Procedure

// Instrumentation_Flag controls procedure instrumentation
// C++ Reference: /mnt/c/odin/src/checker.hpp:112-116
Instrumentation_Flag :: enum i32 {
	Enabled  = -1,
	Default  = 0,
	Disabled = +1,
}

// NOTE: Vet_Flag_Bit, Vet_Flags, and related constants are defined in build_settings.odin
// to avoid duplication. See build_settings.odin:261-286

// Attribute_Context stores declaration attributes
// C++ Reference: /mnt/c/odin/src/checker.hpp:118-167
Attribute_Context :: struct {
	link_name:                  string, // C++ line 119
	link_prefix:                string, // C++ line 120
	link_suffix:                string, // C++ line 121
	link_section:               string, // C++ line 122
	linkage:                    string, // C++ line 123
	thread_local_model:         string, // C++ line 125
	deprecated_message:         string, // C++ line 126
	warning_message:            string, // C++ line 127
	deferred_procedure:         Deferred_Procedure, // C++ line 128
	is_export:                  bool, // C++ line 129
	is_static:                  bool, // C++ line 130
	require_results:            bool, // C++ line 131
	require_declaration:        bool, // C++ line 132
	has_disabled_proc:          bool, // C++ line 133
	disabled_proc:              bool, // C++ line 134
	test:                       bool, // C++ line 135
	init:                       bool, // C++ line 136
	fini:                       bool, // C++ line 137
	set_cold:                   bool, // C++ line 138
	entry_point_only:           bool, // C++ line 139
	instrumentation_enter:      bool, // C++ line 140
	instrumentation_exit:       bool, // C++ line 141
	no_sanitize_address:        bool, // C++ line 142
	no_sanitize_memory:         bool, // C++ line 143
	rodata:                     bool, // C++ line 144
	ignore_duplicates:          bool, // C++ line 145
	optimization_mode:          u32, // C++ line 146 (ProcedureOptimizationMode)
	foreign_import_priority:    i64, // C++ line 147
	extra_linker_flags:         string, // C++ line 148
	no_instrumentation:         Instrumentation_Flag, // C++ line 149

	// Objective-C attributes (C++ lines 151-160)
	objc_class:                 string, // C++ line 151
	objc_name:                  string, // C++ line 152
	objc_selector:              string, // C++ line 153
	objc_type:                  ^Type, // C++ line 154
	objc_superclass:            ^Type, // C++ line 155
	objc_ivar:                  ^Type, // C++ line 156
	objc_context_provider:      ^Entity, // C++ line 157
	objc_is_class_method:       bool, // C++ line 158
	objc_is_implementation:     bool, // C++ line 159
	objc_is_disabled_implement: bool, // C++ line 160

	// Target features (C++ lines 162-163)
	require_target_feature:     string, // C++ line 162
	enable_target_feature:      string, // C++ line 163

	// RAD Debugger support (C++ lines 165-166)
	raddbg_type_view:           bool, // C++ line 165
	raddbg_type_view_string:    string, // C++ line 166

	// Initialization tracking
	init_expr_list_count:       int, // Number of initializer expressions (for attributes)
}

// Proc_Checked_State tracks procedure checking progress
Proc_Checked_State :: ast.Proc_Checked_State

// Entity_State is re-declared from ast.Entity_State
Entity_State :: ast.Entity_State

// Variadic_Reuse_Data is re-declared from ast.Variadic_Reuse_Data
// C++ Reference: struct VariadicReuseData in /mnt/c/odin/src/checker.hpp:197-200
Variadic_Reuse_Data :: ast.Variadic_Reuse_Data

// Decl_Info is re-declared from ast.Decl_Info
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// NOTE: Checker-specific fields like variadic_reuses are stored externally in maps
Decl_Info :: ast.Decl_Info

// Proc_Tag defines procedure attribute tags
// C++ Reference: enum ProcTag in /mnt/c/odin/src/parser.hpp:272-279
// NOTE: Values are bitmasks (1<<n), not sequential indices, to support bit testing
Proc_Tag :: ast.Proc_Tag // NOTE: Uses bit_set for tag flags (refactored from bitfield)
Proc_Tags :: ast.Proc_Tags

// Proc_Info stores procedure checking information
Proc_Info :: struct {
	file:                       ^ast.File,
	token:                      tokenizer.Token,
	decl:                       ^Decl_Info,
	type:                       ^Type,
	body:                       ^ast.Block_Stmt,
	tags:                       u64,
	generated_from_polymorphic: bool,
	poly_def_node:              ^ast.Expr,
}

// Scope_Flag controls scope behavior
Scope_Flag :: ast.Scope_Flag
Scope_Flag_Bit :: ast.Scope_Flag_Bit

DEFAULT_SCOPE_CAPACITY :: 32

// Scope is re-declared from ast.Scope to ensure type compatibility
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// NOTE: This MUST match the AST definition exactly for type equivalence
Scope :: ast.Scope

// Entity is re-declared from ast.Entity to ensure type compatibility
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// C++ Reference: struct Entity in /mnt/c/odin/src/entity.cpp:162-296
// NOTE: This MUST match the AST definition exactly for type equivalence
Entity :: ast.Entity

// Entity_Kind is re-declared from ast.Entity_Kind
Entity_Kind :: ast.Entity_Kind

// Entity_Flag is re-declared from ast.Entity_Flag
Entity_Flag :: ast.Entity_Flag

// Entity_Flags is re-declared from ast.Entity_Flags
Entity_Flags :: ast.Entity_Flags

// Entity_Variant is re-declared from ast.Entity_Variant
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
Entity_Variant :: ast.Entity_Variant

// Parameter_Value_Kind categorizes parameter default values
// C++ Reference: enum ParameterValueKind in /mnt/c/odin/src/entity.cpp:102-109
Parameter_Value_Kind :: ast.Parameter_Value_Kind

// Parameter_Value stores parameter default value information
// C++ Reference: struct ParameterValue in /mnt/c/odin/src/entity.cpp:111-118
Parameter_Value :: ast.Parameter_Value

// Entity_Constant_Flag defines flags for constant entities
// C++ Reference: enum EntityConstantFlags in /mnt/c/odin/src/entity.cpp:130-131
Entity_Constant_Flag :: ast.Entity_Constant_Flag

Entity_Constant_Flags :: ast.Entity_Constant_Flags

// Entity_Constant is re-declared from ast.Entity_Constant
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// C++ Reference: Entity.Constant struct in /mnt/c/odin/src/entity.cpp:202-209
Entity_Constant :: ast.Entity_Constant

// Entity_Variable is re-declared from ast.Entity_Variable
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// C++ Reference: Entity.Variable struct in /mnt/c/odin/src/entity.cpp:210-234
Entity_Variable :: ast.Entity_Variable

// Type_Name_ObjC_Metadata_Entry represents a name/entity pair in ObjC metadata
// C++ Reference: struct TypeNameObjCMetadataEntry in /mnt/c/odin/src/entity.cpp
Type_Name_ObjC_Metadata_Entry :: ast.Type_Name_ObjC_Metadata_Entry

// Type_Name_ObjC_Metadata stores Objective-C class metadata for type names
// C++ Reference: struct TypeNameObjCMetadata in /mnt/c/odin/src/entity.cpp
// This structure holds methods and properties that can be accessed on ObjC classes
Type_Name_ObjC_Metadata :: ast.Type_Name_ObjC_Metadata
// Objc_Method_Data stores Objective-C method registration data
// C++ Reference: struct ObjcMethodData in /mnt/c/odin/src/checker.hpp:382-385
Objc_Method_Data :: struct {
	ac:     Attribute_Context, // C++ line 383: AttributeContext ac
	entity: ^Entity, // C++ line 384: Entity *entity
}

// Entity_Type_Name represents type name entities
// C++ Reference: Entity.TypeName struct in /mnt/c/odin/src/entity.cpp:235-246
// Entity_Type_Name is re-declared from ast.Entity_Type_Name
Entity_Type_Name :: ast.Entity_Type_Name

// Procedure_Optimization_Mode controls procedure optimization level
// C++ Reference: enum ProcedureOptimizationMode in /mnt/c/odin/src/entity.cpp:134-138
Procedure_Optimization_Mode :: ast.Procedure_Optimization_Mode

// Gen_Procs_Data stores specialized polymorphic procedure instances
// C++ Reference: checker.hpp:415-418
Gen_Procs_Data :: ast.Gen_Procs_Data

// Entity_Procedure represents procedure entities
// C++ Reference: Entity.Procedure struct in /mnt/c/odin/src/entity.cpp:247-269
// Entity_Procedure is re-declared from ast.Entity_Procedure
Entity_Procedure :: ast.Entity_Procedure

// Entity_Proc_Group is re-declared from ast.Entity_Proc_Group
Entity_Proc_Group :: ast.Entity_Proc_Group

// Entity_Builtin is re-declared from ast.Entity_Builtin
Entity_Builtin :: ast.Entity_Builtin

// Entity_Label is re-declared from ast.Entity_Label
Entity_Label :: ast.Entity_Label

// Entity_Package_Name is re-declared from ast.Entity_Package_Name
Entity_Package_Name :: ast.Entity_Package_Name

// Entity_Import_Name is re-declared from ast.Entity_Import_Name
Entity_Import_Name :: ast.Entity_Import_Name

// Entity_Library_Name is re-declared from ast.Entity_Library_Name
Entity_Library_Name :: ast.Entity_Library_Name

// Type is re-declared from ast.Type to ensure type compatibility
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
// NOTE: This MUST match the AST definition exactly for type equivalence
Type :: ast.Type

Type_Flags :: ast.Type_Flags

Type_Flag :: ast.Type_Flag

Type_Kind :: ast.Type_Kind

// Type_Variant is re-declared from ast.Type_Variant
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
Type_Variant :: ast.Type_Variant

// Type_Basic is re-declared from ast.Type_Basic
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
Type_Basic :: ast.Type_Basic

// Gen_Types_Data stores specialized polymorphic type instances
// C++ Reference: checker.hpp:420-423
Gen_Types_Data :: ast.Gen_Types_Data

// Type_Named is re-declared from ast.Type_Named
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
Type_Named :: ast.Type_Named

// Type_Pointer is re-declared from ast.Type_Pointer
Type_Pointer :: ast.Type_Pointer

// Type_Array is re-declared from ast.Type_Array
Type_Array :: ast.Type_Array

// Type_Slice is re-declared from ast.Type_Slice
Type_Slice :: ast.Type_Slice

// Type_Dynamic_Array is re-declared from ast.Type_Dynamic_Array
Type_Dynamic_Array :: ast.Type_Dynamic_Array
Type_Fixed_Capacity_Dynamic_Array :: ast.Type_Fixed_Capacity_Dynamic_Array

// Type_Map is re-declared from ast.Type_Map
Type_Map :: ast.Type_Map

// Struct_Soa_Kind defines structure-of-arrays layout types
// C++ Reference: enum StructSoaKind in /mnt/c/odin/src/types.cpp:129-133
Struct_Soa_Kind :: runtime.Type_Info_Struct_Soa_Kind

// Type_Struct is re-declared from ast.Type_Struct
Type_Struct :: ast.Type_Struct

// Type_Union is re-declared from ast.Type_Union
Type_Union :: ast.Type_Union

// Union_Kind is re-declared from ast.Union_Kind
Union_Kind :: ast.Union_Kind

// Type_Enum is re-declared from ast.Type_Enum
Type_Enum :: ast.Type_Enum

// Type_Proc is re-declared from ast.Type_Proc
Type_Proc :: ast.Type_Proc

// Type_Tuple is re-declared from ast.Type_Tuple
Type_Tuple :: ast.Type_Tuple

// Type_Generic is re-declared from ast.Type_Generic
Type_Generic :: ast.Type_Generic

// Type_Multi_Pointer is re-declared from ast.Type_Multi_Pointer
Type_Multi_Pointer :: ast.Type_Multi_Pointer

// Type_Soa_Pointer is re-declared from ast.Type_Soa_Pointer
Type_Soa_Pointer :: ast.Type_Soa_Pointer

// Type_Enumerated_Array is re-declared from ast.Type_Enumerated_Array
Type_Enumerated_Array :: ast.Type_Enumerated_Array

// Type_Bit_Set is re-declared from ast.Type_Bit_Set
Type_Bit_Set :: ast.Type_Bit_Set

// Type_Bit_Field is re-declared from ast.Type_Bit_Field
Type_Bit_Field :: ast.Type_Bit_Field

// Type_Simd_Vector is re-declared from ast.Type_Simd_Vector
Type_Simd_Vector :: ast.Type_Simd_Vector

// Type_Matrix is re-declared from ast.Type_Matrix
Type_Matrix :: ast.Type_Matrix

// Basic_Kind is re-declared from ast.Basic_Kind
// The canonical definition lives in /mnt/c/odin/core/odin/ast/semantic_types.odin
Basic_Kind :: ast.Basic_Kind

// Basic_Flag is re-declared from ast.Basic_Flag
Basic_Flag :: ast.Basic_Flag

// Basic_Flags is re-declared from ast.Basic_Flags
Basic_Flags :: ast.Basic_Flags

// Composite flag constants for common type categories
// C++ Reference: types.cpp:115-119
BASIC_FLAG_NUMERIC :: Basic_Flags{.Integer, .Float, .Complex, .Quaternion}
BASIC_FLAG_ORDERED :: Basic_Flags{.Integer, .Float, .String, .Pointer, .Rune}
BASIC_FLAG_ORDERED_NUMERIC :: Basic_Flags{.Integer, .Float, .Rune}
BASIC_FLAG_CONSTANT_TYPE :: Basic_Flags{.Boolean, .Integer, .Float, .Complex, .Quaternion, .String, .Pointer, .Rune}
BASIC_FLAG_SIMPLE_COMPARE :: Basic_Flags{.Boolean, .Integer, .Pointer, .Rune}

// Calling_Convention defines procedure calling conventions
// C++ Reference: enum ProcCallingConvention in /mnt/c/odin/src/parser.hpp
Calling_Convention :: ast.Calling_Convention

// Alias for compatibility
Proc_Calling_Convention :: Calling_Convention
Builtin_Proc_Id :: ast.Builtin_Proc_Id


// Builtin_Proc_Info stores metadata for each builtin procedure
// Note: Expr_Kind is already defined earlier in this file
// C++ Reference: struct BuiltinProc in /mnt/c/odin/src/checker.hpp:62-70
Builtin_Proc_Info :: struct {
	name:           string,
	arg_count:      int,
	variadic:       bool,
	kind:           Expr_Kind,
	pkg:            Builtin_Proc_Pkg,
	diverging:      bool, // Procedure never returns (like panic)
	ignore_results: bool, // Results can be ignored
}

// builtin_proc_infos maps builtin IDs to their metadata
// C++ Reference: gb_global BuiltinProc builtin_procs[] in /mnt/c/odin/src/checker_builtin_procs.hpp:369-728
builtin_proc_infos := [Builtin_Proc_Id]Builtin_Proc_Info {
	.Invalid = {name = "", arg_count = 0, variadic = false, kind = .Stmt, pkg = .Builtin},
	.Len = {name = "len", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Cap = {name = "cap", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Size_Of = {name = "size_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Align_Of = {name = "align_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Offset_Of = {name = "offset_of", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	.Offset_Of_By_String = {name = "offset_of_by_string", arg_count = 2, variadic = false, kind = .Expr, pkg = .Builtin},
	.Type_Of = {name = "type_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Type_Info_Of = {name = "type_info_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Typeid_Of = {name = "typeid_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Swizzle = {name = "swizzle", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	.Complex = {name = "complex", arg_count = 2, variadic = false, kind = .Expr, pkg = .Builtin},
	.Real = {name = "real", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Imag = {name = "imag", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Conj = {name = "conj", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Quaternion = {name = "quaternion", arg_count = 4, variadic = false, kind = .Expr, pkg = .Builtin},
	.Jmag = {name = "jmag", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Kmag = {name = "kmag", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	// Expansion/compression operations
	.Expand_Values = {name = "expand_values", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Compress_Values = {name = "compress_values", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	// SOA operations
	.Soa_Zip = {name = "soa_zip", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	.Soa_Unzip = {name = "soa_unzip", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	// Control flow
	.Unreachable = {name = "unreachable", arg_count = 0, variadic = false, kind = .Stmt, pkg = .Builtin, diverging = true},
	// Data access
	.Raw_Data = {name = "raw_data", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	// Math operations
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3744-4258
	.Min = {name = "min", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	.Max = {name = "max", arg_count = 1, variadic = true, kind = .Expr, pkg = .Builtin},
	.Abs = {name = "abs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Builtin},
	.Clamp = {name = "clamp", arg_count = 3, variadic = false, kind = .Expr, pkg = .Builtin},

	// Bit manipulation intrinsics
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5193-5336
	.Count_Ones = {name = "count_ones", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Count_Zeros = {name = "count_zeros", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Count_Trailing_Zeros = {name = "count_trailing_zeros", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Count_Leading_Zeros = {name = "count_leading_zeros", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Count_Trailing_Ones = {name = "count_trailing_ones", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Count_Leading_Ones = {name = "count_leading_ones", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Reverse_Bits = {name = "reverse_bits", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Byte_Swap = {name = "byte_swap", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Overflow-checking arithmetic
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5338-5380
	.Overflow_Add = {name = "overflow_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Overflow_Sub = {name = "overflow_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Overflow_Mul = {name = "overflow_mul", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Saturating arithmetic
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5382-5423
	.Saturating_Add = {name = "saturating_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Saturating_Sub = {name = "saturating_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Floating-point intrinsics
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5425-5500
	.Sqrt = {name = "sqrt", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Fused_Mul_Add = {name = "fused_mul_add", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Fixed-point arithmetic
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:6078-6150
	.Fixed_Point_Mul = {name = "fixed_point_mul", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Fixed_Point_Div = {name = "fixed_point_div", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Fixed_Point_Mul_Sat = {name = "fixed_point_mul_sat", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Fixed_Point_Div_Sat = {name = "fixed_point_div_sat", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Atomic operations
	// C++ Reference: /mnt/c/odin/src/checker_builtin_procs.hpp:369-728
	.Atomic_Type_Is_Lock_Free = {name = "atomic_type_is_lock_free", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Thread_Fence = {name = "atomic_thread_fence", arg_count = 1, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Atomic_Signal_Fence = {name = "atomic_signal_fence", arg_count = 1, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Atomic_Store = {name = "atomic_store", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Atomic_Store_Explicit = {name = "atomic_store_explicit", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Atomic_Load = {name = "atomic_load", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Load_Explicit = {name = "atomic_load_explicit", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Add = {name = "atomic_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Add_Explicit = {name = "atomic_add_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Sub = {name = "atomic_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Sub_Explicit = {name = "atomic_sub_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_And = {name = "atomic_and", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_And_Explicit = {name = "atomic_and_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Nand = {name = "atomic_nand", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Nand_Explicit = {name = "atomic_nand_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Or = {name = "atomic_or", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Or_Explicit = {name = "atomic_or_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Xor = {name = "atomic_xor", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Xor_Explicit = {name = "atomic_xor_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Exchange = {name = "atomic_exchange", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Exchange_Explicit = {name = "atomic_exchange_explicit", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Compare_Exchange_Strong = {name = "atomic_compare_exchange_strong", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Compare_Exchange_Strong_Explicit = {name = "atomic_compare_exchange_strong_explicit", arg_count = 5, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Compare_Exchange_Weak = {name = "atomic_compare_exchange_weak", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Atomic_Compare_Exchange_Weak_Explicit = {name = "atomic_compare_exchange_weak_explicit", arg_count = 5, variadic = false, kind = .Expr, pkg = .Intrinsics},
	// Objective-C runtime builtins
	// C++ Reference: /mnt/c/odin/src/checker_builtin_procs.hpp:350-356
	.Objc_Send = {name = "objc_send", arg_count = 3, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Objc_Find_Selector = {name = "objc_find_selector", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Objc_Find_Class = {name = "objc_find_class", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Objc_Register_Selector = {name = "objc_register_selector", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Objc_Register_Class = {name = "objc_register_class", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Objc_Ivar_Get = {name = "objc_ivar_get", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Objc_Block = {name = "objc_block", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Objc_Super = {name = "objc_super", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},

	// SIMD operations
	// C++ Reference: /mnt/c/odin/src/checker_builtin_procs.hpp:507-586
	.Simd_Add = {name = "simd_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Sub = {name = "simd_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Mul = {name = "simd_mul", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Div = {name = "simd_div", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Rem = {name = "simd_rem", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Shl = {name = "simd_shl", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Shr = {name = "simd_shr", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Shl_Masked = {name = "simd_shl_masked", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Shr_Masked = {name = "simd_shr_masked", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Saturating_Add = {name = "simd_saturating_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Saturating_Sub = {name = "simd_saturating_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Bit_And = {name = "simd_bit_and", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Bit_Or = {name = "simd_bit_or", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Bit_Xor = {name = "simd_bit_xor", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Bit_And_Not = {name = "simd_bit_and_not", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Neg = {name = "simd_neg", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Abs = {name = "simd_abs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Min = {name = "simd_min", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Max = {name = "simd_max", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Clamp = {name = "simd_clamp", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Eq = {name = "simd_lanes_eq", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Ne = {name = "simd_lanes_ne", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Lt = {name = "simd_lanes_lt", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Le = {name = "simd_lanes_le", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Gt = {name = "simd_lanes_gt", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Ge = {name = "simd_lanes_ge", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Extract = {name = "simd_extract", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Replace = {name = "simd_replace", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Add_Bisect = {name = "simd_reduce_add_bisect", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Mul_Bisect = {name = "simd_reduce_mul_bisect", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Add_Ordered = {name = "simd_reduce_add_ordered", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Mul_Ordered = {name = "simd_reduce_mul_ordered", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Add_Pairs = {name = "simd_reduce_add_pairs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Mul_Pairs = {name = "simd_reduce_mul_pairs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Min = {name = "simd_reduce_min", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Max = {name = "simd_reduce_max", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_And = {name = "simd_reduce_and", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Or = {name = "simd_reduce_or", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Xor = {name = "simd_reduce_xor", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_Any = {name = "simd_reduce_any", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Reduce_All = {name = "simd_reduce_all", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Extract_Lsbs = {name = "simd_extract_lsbs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Extract_Msbs = {name = "simd_extract_msbs", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Shuffle = {name = "simd_shuffle", arg_count = 2, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Simd_Select = {name = "simd_select", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Runtime_Swizzle = {name = "simd_runtime_swizzle", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Odd_Even = {name = "simd_odd_even", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Sums_Of_N = {name = "simd_sums_of_n", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Pairwise_Add = {name = "simd_pairwise_add", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Pairwise_Sub = {name = "simd_pairwise_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Ceil = {name = "simd_ceil", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Floor = {name = "simd_floor", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Trunc = {name = "simd_trunc", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Nearest = {name = "simd_nearest", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Approx_Recip = {name = "simd_approx_recip", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Approx_Recip_Sqrt = {name = "simd_approx_recip_sqrt", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_To_Bits = {name = "simd_to_bits", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_To_Bits_Signed = {name = "simd_to_bits_signed", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Reverse = {name = "simd_lanes_reverse", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Rotate_Left = {name = "simd_lanes_rotate_left", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Lanes_Rotate_Right = {name = "simd_lanes_rotate_right", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Gather = {name = "simd_gather", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Scatter = {name = "simd_scatter", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Simd_Masked_Load = {name = "simd_masked_load", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Masked_Store = {name = "simd_masked_store", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Simd_Masked_Expand_Load = {name = "simd_masked_expand_load", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Masked_Compress_Store = {name = "simd_masked_compress_store", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Simd_Indices = {name = "simd_indices", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_Interleave = {name = "simd_interleave", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Simd_Deinterleave = {name = "simd_deinterleave", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Simd_X86_MM_Shuffle = {name = "simd_x86__MM_SHUFFLE", arg_count = 4, variadic = false, kind = .Expr, pkg = .Intrinsics},
	// Type intrinsics
	.Type_Base_Type = {name = "type_base_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Core_Type = {name = "type_core_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Elem_Type = {name = "type_elem_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Boolean = {name = "type_is_boolean", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Integer = {name = "type_is_integer", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Rune = {name = "type_is_rune", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Float = {name = "type_is_float", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Complex = {name = "type_is_complex", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Quaternion = {name = "type_is_quaternion", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_String = {name = "type_is_string", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Cstring = {name = "type_is_cstring", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Typeid = {name = "type_is_typeid", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Any = {name = "type_is_any", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Endian_Platform = {name = "type_is_endian_platform", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Endian_Little = {name = "type_is_endian_little", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Endian_Big = {name = "type_is_endian_big", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Unsigned = {name = "type_is_unsigned", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Ordered = {name = "type_is_ordered", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Comparable = {name = "type_is_comparable", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Simple_Compare = {name = "type_is_simple_compare", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Nearly_Simple_Compare = {name = "type_is_nearly_simple_compare", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Numeric = {name = "type_is_numeric", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Ordered_Numeric = {name = "type_is_ordered_numeric", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Pointer = {name = "type_is_pointer", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Multi_Pointer = {name = "type_is_multi_pointer", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Array = {name = "type_is_array", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Enumerated_Array = {name = "type_is_enumerated_array", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Dynamic_Array = {name = "type_is_dynamic_array", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Slice = {name = "type_is_slice", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Struct = {name = "type_is_struct", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Union = {name = "type_is_union", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Enum = {name = "type_is_enum", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Proc = {name = "type_is_proc", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Bit_Set = {name = "type_is_bit_set", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Bit_Field = {name = "type_is_bit_field", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Map = {name = "type_is_map", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Matrix = {name = "type_is_matrix", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Matrix_Row_Major = {name = "type_is_matrix_row_major", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Matrix_Column_Major = {name = "type_is_matrix_column_major", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Simd_Vector = {name = "type_is_simd_vector", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Internally_Pointer_Like = {name = "type_is_internally_pointer_like", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Subtype_Of = {name = "type_is_subtype_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Has_Nil = {name = "type_has_nil", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Field_Index_Of = {name = "type_field_index_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Advanced type intrinsics
	.Type_Bit_Set_Elem_Type = {name = "type_bit_set_elem_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Bit_Set_Underlying_Type = {name = "type_bit_set_underlying_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Bit_Set_Backing_Type = {name = "type_bit_set_backing_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Union_Variant_Count = {name = "type_union_variant_count", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Variant_Type_Of = {name = "type_variant_type_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Variant_Index_Of = {name = "type_variant_index_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Struct_Field_Count = {name = "type_struct_field_count", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Struct_Has_Implicit_Padding = {name = "type_struct_has_implicit_padding", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Proc_Parameter_Count = {name = "type_proc_parameter_count", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Proc_Return_Count = {name = "type_proc_return_count", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Proc_Parameter_Type = {name = "type_proc_parameter_type", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Proc_Return_Type = {name = "type_proc_return_type", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Proc_Calling_Convention = {name = "type_proc_calling_convention", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Polymorphic_Record_Parameter_Count = {name = "type_polymorphic_record_parameter_count", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Polymorphic_Record_Parameter_Value = {name = "type_polymorphic_record_parameter_value", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Enum_Is_Contiguous = {name = "type_enum_is_contiguous", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Equal_Proc = {name = "type_equal_proc", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Hasher_Proc = {name = "type_hasher_proc", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Map_Info = {name = "type_map_info", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Map_Cell_Info = {name = "type_map_cell_info", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Canonical_Name = {name = "type_canonical_name", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Additional type intrinsics
	.Type_Field_Type = {name = "type_field_type", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Field_Bit_Offset = {name = "type_field_bit_offset", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Field_Bit_Size = {name = "type_field_bit_size", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Has_Field = {name = "type_has_field", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Has_Shared_Fields = {name = "type_has_shared_fields", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Named = {name = "type_is_named", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Cstring16 = {name = "type_is_cstring16", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_String16 = {name = "type_is_string16", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Dereferenceable = {name = "type_is_dereferenceable", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Sliceable = {name = "type_is_sliceable", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Indexable = {name = "type_is_indexable", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Specialization_Of = {name = "type_is_specialization_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Specialized_Polymorphic_Record = {name = "type_is_specialized_polymorphic_record", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Unspecialized_Polymorphic_Record = {name = "type_is_unspecialized_polymorphic_record", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Valid_Map_Key = {name = "type_is_valid_map_key", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Valid_Matrix_Elements = {name = "type_is_valid_matrix_elements", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Superset_Of = {name = "type_is_superset_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Variant_Of = {name = "type_is_variant_of", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Is_Raw_Union = {name = "type_is_raw_union", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Integer_To_Signed = {name = "type_integer_to_signed", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Integer_To_Unsigned = {name = "type_integer_to_unsigned", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Merge = {name = "type_merge", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Convert_Variants_To_Pointers = {name = "type_convert_variants_to_pointers", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Union_Base_Tag_Value = {name = "type_union_base_tag_value", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Union_Tag_Offset = {name = "type_union_tag_offset", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Type_Union_Tag_Type = {name = "type_union_tag_type", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Memory intrinsics
	.Alloca = {name = "alloca", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Cpu_Relax = {name = "cpu_relax", arg_count = 0, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Trap = {name = "trap", arg_count = 0, variadic = false, kind = .Expr, pkg = .Intrinsics, diverging = true},
	.Debug_Trap = {name = "debug_trap", arg_count = 0, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Mem_Copy = {name = "mem_copy", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Mem_Copy_Non_Overlapping = {name = "mem_copy_non_overlapping", arg_count = 3, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Mem_Zero = {name = "mem_zero", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Mem_Zero_Volatile = {name = "mem_zero_volatile", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Ptr_Offset = {name = "ptr_offset", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Ptr_Sub = {name = "ptr_sub", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Volatile_Store = {name = "volatile_store", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Volatile_Load = {name = "volatile_load", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Unaligned_Store = {name = "unaligned_store", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Unaligned_Load = {name = "unaligned_load", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Non_Temporal_Store = {name = "non_temporal_store", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Non_Temporal_Load = {name = "non_temporal_load", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Prefetch_Read_Instruction = {name = "prefetch_read_instruction", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Prefetch_Read_Data = {name = "prefetch_read_data", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Prefetch_Write_Instruction = {name = "prefetch_write_instruction", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.Prefetch_Write_Data = {name = "prefetch_write_data", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},

	// Miscellaneous intrinsics
	.Is_Package_Imported = {name = "is_package_imported", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Read_Cycle_Counter = {name = "read_cycle_counter", arg_count = 0, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Read_Cycle_Counter_Frequency = {name = "read_cycle_counter_frequency", arg_count = 0, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Expect = {name = "expect", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Likely = {name = "likely", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Unlikely = {name = "unlikely", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Syscall = {name = "syscall", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Syscall_Bsd = {name = "syscall_bsd", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Entry_Point = {name = "__entry_point", arg_count = 0, variadic = false, kind = .Stmt, pkg = .Intrinsics},

	// C variadic intrinsics
	.C_Va_Start = {name = "c_va_start", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.C_Va_End = {name = "c_va_end", arg_count = 1, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.C_Va_Copy = {name = "c_va_copy", arg_count = 2, variadic = false, kind = .Stmt, pkg = .Intrinsics},
	.C_Va_Arg = {name = "c_va_arg", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// WebAssembly intrinsics
	.Wasm_Memory_Grow = {name = "wasm_memory_grow", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Wasm_Memory_Size = {name = "wasm_memory_size", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Wasm_Memory_Atomic_Wait32 = {name = "wasm_memory_atomic_wait32", arg_count = 3, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Wasm_Memory_Atomic_Notify32 = {name = "wasm_memory_atomic_notify32", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Matrix operations
	.Hadamard_Product = {name = "hadamard_product", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Matrix_Flatten = {name = "matrix_flatten", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Outer_Product = {name = "outer_product", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Transpose = {name = "transpose", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Constant operations (compile-time)
	.Constant_Ceil = {name = "constant_ceil", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Constant_Floor = {name = "constant_floor", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Constant_Log2 = {name = "constant_log2", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Constant_Round = {name = "constant_round", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Constant_Trunc = {name = "constant_trunc", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Constant_Utf16_Cstring = {name = "constant_utf16_cstring", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Platform-specific intrinsics
	.X86_Cpuid = {name = "x86_cpuid", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.X86_Xgetbv = {name = "x86_xgetbv", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Valgrind_Client_Request = {name = "valgrind_client_request", arg_count = 7, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Has_Target_Feature = {name = "has_target_feature", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},

	// Additional core builtins
	.Concatenate = {name = "concatenate", arg_count = 1, variadic = true, kind = .Expr, pkg = .Intrinsics},
	.Soa_Struct = {name = "soa_struct", arg_count = 2, variadic = false, kind = .Expr, pkg = .Intrinsics},
	.Procedure_Of = {name = "procedure_of", arg_count = 1, variadic = false, kind = .Expr, pkg = .Intrinsics},
}

// Entity_Graph_Node tracks declaration dependencies
Entity_Graph_Node :: struct {
	entity:    ^Entity,
	pred:      map[^Entity_Graph_Node]struct{},
	succ:      map[^Entity_Graph_Node]struct{},
	index:     int,
	dep_count: int,
}

// Import_Graph_Node tracks package import dependencies
// Used for topological sorting and cycle detection in import graphs
Import_Graph_Node :: struct {
	pkg:       ^ast.Package, // The package represented by this node
	scope:     ^Scope, // The package's scope
	pred:      map[^Import_Graph_Node]struct{}, // Predecessor nodes (packages that import this)
	succ:      map[^Import_Graph_Node]struct{}, // Successor nodes (packages this imports)
	dep_count: int, // Number of dependencies
}

// Package_Exported_Entity represents an exported entity from a package
// C++ Reference: struct AstPackageExportedEntity in /mnt/c/odin/src/parser.hpp:188-191
// NOTE: This type is NOT present in core:odin/ast. We track exported entities externally.
// Used for multi-threaded package processing via MPSC queues.
Package_Exported_Entity :: ast.Package_Exported_Entity

// Ast_Call_Expr is an alias for ast.Call_Expr
// Used for consistency in function signatures
Ast_Call_Expr :: ast.Call_Expr

// Foreign_Context tracks foreign declaration state
// C++ Reference: struct ForeignContext in /mnt/c/odin/src/checker.hpp:343-351
Foreign_Context :: struct {
	curr_library:    ^ast.Expr, // C++ line 344
	default_cc:      Calling_Convention, // C++ line 345
	// C++ tests `default_cc > 0` to mean "explicitly set", which works there because
	// ProcCC_Invalid is 0. This enum starts at .Odin = 0, so the zero value is
	// indistinguishable from an explicit @(default_calling_convention="odin") and we
	// need a separate flag to carry that distinction.
	default_cc_set:  bool,
	link_prefix:     string, // C++ line 346
	link_suffix:     string, // C++ line 347
	visibility_kind: Entity_Visibility_Kind, // C++ line 349
	require_results: bool, // C++ line 350
}

// Target_Os_Kind, Target_Arch_Kind, Command_Kind, and Build_Context are defined in build_settings.odin

// Type_Info_Pair represents a type with its canonical hash for RTTI tracking
// C++ Reference: name_canonicalization.hpp:58-61
// Used for minimal dependency type info set and index mapping
Type_Info_Pair :: struct {
	type: ^Type, // The type
	hash: u64, // Canonical hash (see: type_hash_canonical_type)
}

// Checker_Info stores all symbol information
Checker_Info :: struct {
	checker:                                      ^Checker,
	files:                                        map[string]^ast.File,
	files_by_id:                                  map[i32]^ast.File, // File ID lookup for node.file_id -> file
	packages:                                     map[string]^ast.Package,
	// Registration (discovery) order of the above, mirroring C++'s `parser->packages` Array.
	// C++ walks that array for the early passes (e.g. check_create_file_scopes, checker.cpp:6049);
	// this port only had the map, whose iteration order is ASLR-dependent. Maintained by
	// register_package - never insert into `packages` directly.
	packages_ordered:                             [dynamic]^ast.Package,
	builtin_package:                              ^ast.Package,
	intrinsics_package:                           ^ast.Package, // C++: intrinsics_pkg
	config_package:                               ^ast.Package, // C++: config_pkg (for #config lookup)
	runtime_package:                              ^ast.Package,
	init_package:                                 ^ast.Package,
	init_scope:                                   ^Scope,
	global_scope:                                 ^Scope, // Global/universal scope for dummy variables
	init_fullpath:                                string, // C++ parser.hpp:224 - Full path to init file
	entry_point:                                  ^Entity,
	variable_init_order:                          [dynamic]^Decl_Info,
	global_untyped:                               map[^ast.Expr]^Expr_Info,
	global_untyped_mutex:                         sync.RW_Mutex,

	// Entity processing queues (C++ checker.hpp:494-520)
	// These queues enable multi-threaded entity collection and processing
	definition_queue:                             queue.MPSC_Queue(^Entity), // C++ line 494
	entity_queue:                                 queue.MPSC_Queue(^Entity), // C++ line 495
	required_global_variable_queue:               queue.MPSC_Queue(^Entity), // C++ line 496
	required_foreign_imports_through_force_queue: queue.MPSC_Queue(^Entity), // C++ line 497
	foreign_imports_to_check_fullpaths:           queue.MPSC_Queue(^Entity), // C++ line 498
	foreign_decls_to_check:                       queue.MPSC_Queue(^Entity), // C++ line 499
	raddbg_type_views_queue:                      queue.MPSC_Queue(Raddbg_Type_View), // C++ line 501
	intrinsics_entry_point_usage:                 queue.MPSC_Queue(^ast.Node), // C++ line 504
	objc_class_implementations:                   queue.MPSC_Queue(^Entity), // C++ line 511
	objc_method_mutex:                            sync.Mutex, // C++ line 513: Thread-safe access to objc_method_implementations
	objc_method_implementations:                  map[^Type][dynamic]Objc_Method_Data, // C++ line 514: Type -> method data array
	all_procedures_queue:                         queue.MPSC_Queue(^Proc_Info), // C++ line 520

	// Final storage arrays (drained from queues)
	definitions:                                  [dynamic]^Entity,
	entities:                                     [dynamic]^Entity,
	all_procedures:                               [dynamic]^Proc_Info,
	raddbg_type_views:                            [dynamic]Raddbg_Type_View, // C++ line 502
	required_foreign_imports_through_force:       [dynamic]^Entity, // C++ line 469

	// Special procedure lists for initialization/finalization/testing
	// C++ Reference: checker.hpp:463-465
	testing_procedures:                           [dynamic]^Entity, // C++ line 463: Array<Entity *> testing_procedures
	init_procedures:                              [dynamic]^Entity, // C++ line 464: Array<Entity *> init_procedures
	fini_procedures:                              [dynamic]^Entity, // C++ line 465: Array<Entity *> fini_procedures
	foreigns:                                     map[string]^Entity,
	foreign_mutex:                                sync.Mutex,
	type_info_mutex:                              sync.Mutex,
	// C++ Reference: checker.cpp:4791 - guards insertion into builtin_package.scope, which any
	// file's @(builtin) declaration can write to concurrently.
	builtin_mutex:                                sync.Mutex,
	// C++ Reference: checker.hpp:743 - "Mutex required for lazy type checking of specific files".
	// RECURSIVE because resolving one lazy entity can reference another lazy entity on the same
	// thread, re-entering check_entity_decl while the lock is already held.
	lazy_mutex:                                   sync.Recursive_Mutex,

	// Parent entity tracking deleted - not needed in current implementation

	// AST flag storage - DELETED
	// Flags are now stored directly on AST nodes:
	//   - node.state_flags (Node_State_Flags) - downward-propagating flags
	//   - node.viral_state_flags (Node_Viral_State_Flags) - upward-propagating flags
	// See: /mnt/c/odin/core/odin/ast/ast.odin lines 28-44

	// When statement condition memoization deleted - now stored directly on When_Stmt

	// File scope storage - EXTERNAL MAP REQUIRED
	// NOTE: Cannot use file.scope because ast.File.scope has type ^ast.Scope (core library type),
	// while checker defines its own ^Scope type. External map required until type unification.
	// C++ Reference: checker.cpp:246 - f->scope = s
	// See scope.odin for usage in create_scope_from_file
	file_scopes:                                  map[^ast.File]^Scope,

	// Package scope storage - EXTERNAL MAP REQUIRED
	// NOTE: Cannot use pkg.scope because ast.Package.scope has type ^ast.Scope (core library type),
	// while checker defines its own ^Scope type. External map required until type unification.
	// C++ Reference: checker.cpp:265 - pkg->scope = s
	// See scope.odin:528 for usage in create_scope_from_package
	package_scopes:                               map[^ast.Package]^Scope,

	// Package decl_info storage - EXTERNAL MAP REQUIRED
	// NOTE: Cannot use pkg.decl_info because ast.Package.decl_info has type ^ast.Decl_Info,
	// while checker defines its own ^Decl_Info type. External map required until type unification.
	// C++ Reference: parser.hpp:213 - pkg->decl_info
	// See package_helpers.odin for usage in get/set_package_decl_info
	package_decl_infos:                           map[^ast.Package]^Decl_Info,

	// AST node to scope mapping - EXTERNAL MAP REQUIRED
	// NOTE: For statement and type nodes (Block_Stmt, If_Stmt, Proc_Type, etc.)
	// C++ stores scopes directly on nodes, but we need external map until type unification
	// C++ Reference: checker.cpp:295-315 (add_scope), 317-339 (scope_of_node)
	// See scope.odin:430-463 for usage
	ast_scope_map:                                map[rawptr]^Scope,
	ast_scope_map_mutex:                          sync.RW_Mutex,

	// Type and value storage - EXTERNAL MAP REQUIRED
	// NOTE: Cannot use node.tav because ast.Node.tav has type ^ast.Type_And_Value,
	// but ast.Type_And_Value is not defined in core:odin/ast. External map required until type is defined.
	// C++ Reference: checker.cpp:1773-1817 (add_type_and_value)
	// In C++, this is stored directly on expr->tav, but we need external map for now
	// Type and value information lives on the AST node itself (ast.Node.tav), exactly as in
	// C++ (`expr->tav`). The former `type_and_value_map: map[rawptr]Type_And_Value` and its
	// RW mutex are gone: a field write cannot race a rehash, so no lock is needed, and a
	// reader can no longer find an entry "missing" - a state C++ cannot represent and which
	// was aborting check_stmt.odin's .Map_Index assertion. See tav_lookup.

	// AST state flags - EXTERNAL MAP REQUIRED
	// NOTE: ast.Node has state_flags field, but Been_Handled flag needs separate tracking
	// because it's used during declaration processing phase before nodes are finalized
	// C++ Reference: checker.cpp - Various state flag operations
	ast_state_flags:                              map[rawptr]ast.Node_State_Flags,

	// File loading cache for #load, #exists, #load_hash directives
	// C++ Reference: checker.hpp:518-530
	load_file_cache:                              map[string]^Load_File_Cache,
	load_file_mutex:                              sync.Mutex,
	load_directory_cache:                         map[string]^Load_Directory_Cache,
	load_directory_mutex:                         sync.Mutex,
	load_directory_map:                           map[^ast.Call_Expr]^Load_Directory_Cache,

	// File metadata storage - DELETED
	// C++ Reference: parser.hpp:107-173 - struct AstFile
	// All file metadata now stored directly on ast.File:
	//   - file.flags (File_Flags)
	//   - file.vet_flags (Vet_Flags)
	//   - file.feature_flags (Feature_Flags)
	//   - file.vet_flags_set (bool)
	//   - file.feature_flags_set (bool)

	// Package metadata storage - DELETED
	// C++ Reference: parser.hpp:193-215 - struct AstPackage
	// All package metadata now stored directly on ast.Package:
	//   - pkg.scope (^Scope)
	//   - pkg.decl_info (^Decl_Info)
	//   - pkg.is_extra (bool)
	//   - pkg.order (int)

	// Package exported entity queues - DELETED
	// C++ Reference: parser.hpp:209 - MPMCQueue<AstPackageExportedEntity> exported_entity_queue
	// Now stored directly on ast.Package.exported_entity_queue (queue.MPMC_Queue)
	// Perfect parity achieved - no more external maps for AST metadata!

	// AST node to scope mapping - DELETED
	// Scopes are now stored directly on statement and type nodes:
	//   - Block_Stmt.scope, If_Stmt.scope, For_Stmt.scope, Range_Stmt.scope, etc.
	//   - Proc_Type.scope, Struct_Type.scope, Union_Type.scope, Enum_Type.scope, etc.
	// See: /mnt/c/odin/core/odin/ast/ast.odin lines 217, 231, 266, 280, 611, 663, 684, 698

	// Delayed declaration queues - DELETED
	// C++ Reference: checker.cpp:5892-5953 (delayed_decls_queues processing)
	// Delayed declarations now stored directly on ast.File:
	//   - file.delayed_decls_import
	//   - file.delayed_decls_foreign_block
	//   - file.delayed_decls_expr

	// Core runtime type cache (C++ types.cpp:725-732)
	// These types are loaded from core:runtime and cached for fast access
	// Used throughout type checking for allocator operations, context access, etc.
	// NOTE: Stored here instead of as globals to support multiple checker instances
	cached_allocator:                             ^Type, // core:runtime.Allocator
	cached_allocator_ptr:                         ^Type, // ^Allocator
	cached_allocator_error:                       ^Type, // core:runtime.Allocator_Error
	cached_context:                               ^Type, // core:runtime.Context
	cached_context_ptr:                           ^Type, // ^Context
	cached_source_code_location:                  ^Type, // core:runtime.Source_Code_Location
	cached_source_code_location_ptr:              ^Type, // ^Source_Code_Location

	// Build configuration (C++ build_settings.cpp:448)
	// In C++, build_context is a global. We store it in Checker_Info for better encapsulation.
	// nil means use default settings (RTTI enabled)
	build_context:                                ^Build_Context, // Build flags controlling compilation

	// Minimum dependency type info tracking (C++ checker.hpp:455-461)
	// Tracks the minimal set of types that need RTTI generation for the final binary
	// C++ Reference: checker.hpp:455-461, name_canonicalization.hpp:58-67
	minimum_dependency_type_info_mutex:           sync.RW_Mutex, // C++ line 455
	min_dep_type_info_set:                        map[u64]Type_Info_Pair, // C++ line 459: TypeSet (hash -> type pair)
	min_dep_type_info_set_mutex:                  sync.RW_Mutex, // C++ line 458: RWSpinLock
	min_dep_type_info_index_map:                  map[u64]i64, // C++ line 456: hash -> min dep index
	type_info_types_hash_map:                     [dynamic]Type_Info_Pair, // C++ line 460: sorted hash map for lookups

	// Type resolution cache - DELETED
	// Type and value information is now stored directly on AST nodes: node.tav
	// See: /mnt/c/odin/core/odin/ast/ast.odin line 55

	// Instrumentation support (C++ check_decl.cpp:1300-1321)
	// Tracks special @(instrumentation_enter/exit) procedures
	// C++ Reference: checker.hpp:369 (BlockingMutex instrumentation_mutex)
	instrumentation_mutex:                        sync.Mutex,
	instrumentation_enter_entity:                 ^Entity,
	instrumentation_exit_entity:                  ^Entity,
}

// Checker_Context is the per-operation checking state
Checker_Context :: struct {
	mutex:                             sync.Mutex,
	checker:                           ^Checker,
	info:                              ^Checker_Info,
	pkg:                               ^ast.Package,
	file:                              ^ast.File,
	scope:                             ^Scope,
	decl:                              ^Decl_Info,
	state_flags:                       State_Flags,
	in_defer:                          bool,
	type_hint:                         ^Type,
	type_hint_expr:                    ^ast.Expr, // C++ Reference: checker.hpp:530 - For [?]T{...} syntax
	// The LHS currently being checked by an assignment statement, unparenthesised.
	// C++ Reference: checker.hpp `assignment_lhs_hint`, set in check_stmt.cpp:2531.
	// This is how `context = ...` is recognised as DEFINING the context rather than
	// reading it: check_expr's Implicit arm compares the node it is checking against
	// this hint (check_expr.cpp:12277) and sets Scope_Flag.Context_Defined when they
	// match. Without it, a "c"/"contextless" procedure could never establish a context.
	assignment_lhs_hint:               ^ast.Node,
	proc_name:                         string,
	curr_proc_decl:                    ^Decl_Info,
	curr_proc_sig:                     ^Type,
	curr_proc_calling_convention:      Calling_Convention,
	in_proc_sig:                       bool,
	foreign_context:                   Foreign_Context,
	type_level:                        int,
	untyped:                           ^map[^ast.Expr]^Expr_Info,
	inline_for_depth:                  i64, // Track nested #unroll for depth

	// Type and value storage - DELETED
	// Type and value information is now stored directly on AST nodes: node.tav
	// See: /mnt/c/odin/core/odin/ast/ast.odin line 55
	stmt_flags:                        Stmt_Flag,
	in_enum_type:                      bool,
	allow_polymorphic_types:           bool,
	polymorphic_scope:                 ^Scope,
	disallow_polymorphic_return_types: bool,
	in_polymorphic_specialization:     bool,
	no_polymorphic_errors:             bool, // Suppress polymorphic type errors during inference
	hide_polymorphic_errors:           bool, // Hide polymorphic error messages
	allow_arrow_right_selector_expr:   bool, // Allow -> selector in call expressions

	// Bit field tracking (C++ check_compound_lit.odin:196-205)
	// Tracks current bit field size during compound literal checking
	bit_field_bit_size:                i64,

	// C++ Reference: checker.hpp:569 - bool in_proc_group
	// Suppresses error messages when checking polymorphic constant parameters during
	// procedure group overload resolution
	in_proc_group:                     bool,

	// Delayed declaration processing flag
	// C++ Reference: checker.hpp:570 - bool collect_delayed_decls
	// Controls whether declarations that can't be immediately processed should be queued
	collect_delayed_decls:             bool, // Enable delayed declaration queueing

	// Type path for cycle detection
	// C++ Reference: checker.hpp:819 - CheckerTypePath *type_path
	// Used to track entities during type resolution to detect cyclic dependencies.
	//
	// NOTE: This MUST be a pointer, exactly as in C++. A Checker_Context is copied by
	// value in many places (`c := ctx^`); every copy has to keep pushing onto and
	// popping from the *same* path, otherwise (a) the path each copy sees is a stale
	// snapshot so cycle detection misses, and (b) the aliased [dynamic] headers each
	// grow the shared backing store independently, which frees it out from under the
	// other copies and corrupts the heap.
	type_path:                         ^Checker_Type_Path,
}

// Checker_Type_Path is the stack of entities currently being resolved, used to detect
// illegal declaration cycles.
// C++ Reference: checker.hpp:613 - typedef Array<Entity *> CheckerTypePath
Checker_Type_Path :: distinct [dynamic]^Entity

// Checker is the top-level type checker
Checker :: struct {
	info:                                      Checker_Info,
	builtin_ctx:                               Checker_Context,
	procs_to_check:                            [dynamic]^Proc_Info,
	nested_proc_lits:                          [dynamic]^Decl_Info,
	nested_proc_lits_mutex:                    sync.Mutex, // C++ Reference: checker.hpp - thread-safe access to nested_proc_lits

	// Additional processing queues (C++ checker.hpp:597-602)
	procs_with_deferred_to_check:              queue.MPSC_Queue(^Entity), // Procedures with defer statements
	procs_with_objc_context_provider_to_check: queue.MPSC_Queue(^Entity), // Objective-C context providers
	global_untyped_queue:                      queue.MPSC_Queue(Untyped_Expr_Info), // C++ line 601
	soa_types_to_complete:                     queue.MPSC_Queue(^Type), // C++ line 602
	allocator:                                 runtime.Allocator,
}
