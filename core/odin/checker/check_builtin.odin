package checker

/*
Builtin procedure checking.

This module implements type checking for Odin's built-in procedures,
following the logic in check_builtin.cpp from the Odin compiler.

C++ Reference: /mnt/c/odin/src/check_builtin.cpp

*/

import "core:container/queue"
import "core:fmt"
import "core:math"
import "core:math/big"
import "core:odin/ast"
import "core:os"
import "core:path/filepath"
import "core:slice"
import "core:sync"

// check_builtin_procedure is the central dispatcher for builtin checking
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2396-2506
check_builtin_procedure :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id, type_hint: ^Type) -> bool {
	// Step 1: Get builtin metadata
	info := builtin_proc_infos[id]

	// Step 2: Validate argument count
	// C++ ref: check_builtin.cpp:2402-2419
	arg_count := len(call.args)
	if arg_count < info.arg_count {
		error_node(call, "Too few arguments for '%s', expected %d, got %d", info.name, info.arg_count, arg_count)
		return false
	}
	if arg_count > info.arg_count && !info.variadic {
		error_node(call, "Too many arguments for '%s', expected %d, got %d", info.name, info.arg_count, arg_count)
		return false
	}

	// Step 3: Pre-check first argument for special builtins
	// C++ ref: check_builtin.cpp:2421-2468
	// Some builtins accept types or expressions, handle specially
	#partial switch id {
	case .Len, .Cap, .Size_Of, .Align_Of, .Offset_Of, .Type_Of, .Type_Info_Of, .Typeid_Of:
		// These are checked inside their handlers
		break

	case .Min, .Max:
		// C++ Reference: check_builtin.cpp:2811-2812. min/max must check the first argument as
		// type-or-expr, so they do it themselves.
		//
		// NOTE: .Swizzle, .Complex, .Real, .Imag and .Conj used to be listed here too, but C++
		// does NOT exclude them (check_builtin.cpp:2803-2824) - they fall through to the default
		// arm and have args[0] checked into `operand`. Their handlers are written against that
		// contract: C++'s swizzle case opens with `if (!operand->type) return false;`, and the
		// complex/conj cases open with `Operand x = *operand;`. Excluding them here left `operand`
		// holding the builtin itself (mode = .Builtin, type = nil), so `complex(a, b)` reached
		// convert_to_typed with a nil-typed operand and segfaulted. base:runtime and core/strings
		// both hit this.
		break

	case .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		// C++ Reference: check_builtin.cpp:2827-2830 — "first type will require a type hint".
		//
		// Their sole argument is an Atomic_Memory_Order, and it is almost always written as a
		// bare implicit selector: `intrinsics.atomic_thread_fence(.Acquire)`. Pre-checking it
		// here checks it with NO type hint, so `.Acquire` has nothing to resolve against and
		// reports "Cannot determine type for implicit selector expression"; the handler's own
		// hinted re-check then reuses the recorded (failed) result.
		//
		// The neighbouring atomics were unaffected because their memory order is the SECOND
		// argument, which the prologue never touches — which is exactly the asymmetry that
		// located this: `atomic_load_explicit(&x, .Seq_Cst)` worked while
		// `atomic_thread_fence(.Acquire)` did not.
		break

	case:
		// Default: check first arg as multi-expr
		//
		// A `field = value` first argument is NOT pre-checked here. C++ gates named arguments
		// immediately after this switch (check_builtin.cpp:2856-2868): they are rejected for every
		// builtin except soa_zip and quaternion, whose handlers resolve the names themselves. Since
		// no expression dispatch - C++'s or this port's - has a case for ^ast.Field_Value, feeding
		// one in here produced "Expression type not yet supported: ^Field_Value" for every
		// `quaternion(w=..., x=..., y=..., z=...)` in base:runtime: 31 diagnostics in core/bytes,
		// 32 in core/strings.
		if arg_count > 0 {
			if _, is_field_value := call.args[0].derived_expr.(^ast.Field_Value); !is_field_value {
				check_expr(ctx, operand, call.args[0])
			}
		}
	}

	// C++ Reference: check_builtin.cpp:2856-2868. Only soa_zip and quaternion accept `field = value`.
	if arg_count > 0 {
		if _, is_field_value := call.args[0].derived_expr.(^ast.Field_Value); is_field_value {
			#partial switch id {
			case .Soa_Zip, .Quaternion:
				// okay
			case:
				error_node(call, "'field = value' calling is not allowed on built-in procedures")
				return false
			}
		}
	}

	// Step 4: Dispatch to per-builtin handler
	// C++ ref: check_builtin.cpp:2506 (main switch)
	result := false
	#partial switch id {
	case .Len, .Cap:
		result = check_builtin_len_cap(ctx, operand, call, id, type_hint)

	case .Size_Of:
		result = check_builtin_size_of(ctx, operand, call)

	case .Align_Of:
		result = check_builtin_align_of(ctx, operand, call)

	case .Offset_Of:
		result = check_builtin_offset_of_impl(ctx, operand, call)

	case .Offset_Of_By_String:
		result = check_builtin_offset_of_by_string(ctx, operand, call)

	case .Type_Of:
		result = check_builtin_type_of(ctx, operand, call)

	case .Type_Info_Of:
		result = check_builtin_type_info_of(ctx, operand, call)

	case .Typeid_Of:
		result = check_builtin_typeid_of(ctx, operand, call)

	// Atomic operations
	case .Atomic_Type_Is_Lock_Free:
		result = check_builtin_atomic_type_is_lock_free(ctx, operand, call)

	case .Atomic_Thread_Fence, .Atomic_Signal_Fence:
		result = check_builtin_atomic_fence(ctx, operand, call, id)

	case .Atomic_Store, .Atomic_Store_Explicit:
		result = check_builtin_atomic_store(ctx, operand, call, id)

	case .Atomic_Load, .Atomic_Load_Explicit:
		result = check_builtin_atomic_load(ctx, operand, call, id)

	case .Atomic_Add, .Atomic_Add_Explicit, .Atomic_Sub, .Atomic_Sub_Explicit, .Atomic_And, .Atomic_And_Explicit, .Atomic_Nand, .Atomic_Nand_Explicit, .Atomic_Or, .Atomic_Or_Explicit, .Atomic_Xor, .Atomic_Xor_Explicit, .Atomic_Exchange, .Atomic_Exchange_Explicit:
		result = check_builtin_atomic_rmw(ctx, operand, call, id)

	case .Atomic_Compare_Exchange_Strong, .Atomic_Compare_Exchange_Strong_Explicit, .Atomic_Compare_Exchange_Weak, .Atomic_Compare_Exchange_Weak_Explicit:
		result = check_builtin_atomic_compare_exchange(ctx, operand, call, id)

	// Objective-C runtime builtins
	case .Objc_Send:
		result = check_builtin_objc_send(ctx, operand, call)

	case .Objc_Find_Selector, .Objc_Find_Class, .Objc_Register_Selector, .Objc_Register_Class:
		result = check_builtin_objc_find_register(ctx, operand, call, id)

	case .Objc_Ivar_Get:
		result = check_builtin_objc_ivar_get(ctx, operand, call, type_hint)

	case .Objc_Block:
		result = check_builtin_objc_block(ctx, operand, call)

	case .Objc_Super:
		result = check_builtin_objc_super(ctx, operand, call)

	// Complex number operations
	case .Complex:
		result = check_builtin_complex(ctx, operand, call, type_hint)

	case .Real, .Imag:
		result = check_builtin_real_imag(ctx, operand, call, id, type_hint)

	case .Conj:
		result = check_builtin_conj(ctx, operand, call)

	// Quaternion operations
	case .Quaternion:
		result = check_builtin_quaternion(ctx, operand, call, type_hint)

	case .Jmag, .Kmag:
		result = check_builtin_jmag_kmag(ctx, operand, call, id)

	// Expansion/compression operations
	case .Expand_Values:
		result = check_builtin_expand_values(ctx, operand, call)

	case .Compress_Values:
		result = check_builtin_compress_values(ctx, operand, call)

	// SOA operations
	case .Soa_Zip:
		result = check_builtin_soa_zip(ctx, operand, call, type_hint)

	case .Soa_Unzip:
		result = check_builtin_soa_unzip(ctx, operand, call)

	// Control flow
	case .Unreachable:
		result = check_builtin_unreachable(ctx, operand, call)

	// Data access
	case .Raw_Data:
		result = check_builtin_raw_data(ctx, operand, call)

	// Type intrinsics
	case .Type_Base_Type, .Type_Core_Type:
		result = check_builtin_type_base_core(ctx, operand, call, id)

	case .Type_Elem_Type:
		result = check_builtin_type_elem(ctx, operand, call)

	case .Type_Is_Boolean, .Type_Is_Integer, .Type_Is_Rune, .Type_Is_Float, .Type_Is_Complex, .Type_Is_Quaternion, .Type_Is_String, .Type_Is_Cstring, .Type_Is_Typeid, .Type_Is_Any, .Type_Is_Endian_Platform, .Type_Is_Endian_Little, .Type_Is_Endian_Big, .Type_Is_Unsigned, .Type_Is_Ordered, .Type_Is_Comparable, .Type_Is_Simple_Compare, .Type_Is_Nearly_Simple_Compare, .Type_Is_Numeric, .Type_Is_Ordered_Numeric, .Type_Is_Pointer, .Type_Is_Multi_Pointer, .Type_Is_Array, .Type_Is_Enumerated_Array, .Type_Is_Dynamic_Array, .Type_Is_Slice, .Type_Is_Struct, .Type_Is_Union, .Type_Is_Enum, .Type_Is_Proc, .Type_Is_Bit_Set, .Type_Is_Bit_Field, .Type_Is_Map, .Type_Is_Matrix, .Type_Is_Simd_Vector, .Type_Is_Internally_Pointer_Like:
		result = check_builtin_type_is_predicate(ctx, operand, call, id)

	case .Type_Is_Matrix_Row_Major, .Type_Is_Matrix_Column_Major:
		result = check_builtin_type_is_matrix_major(ctx, operand, call, id)

	case .Type_Is_Subtype_Of:
		result = check_builtin_type_is_subtype_of(ctx, operand, call)

	case .Type_Has_Nil:
		result = check_builtin_type_has_nil(ctx, operand, call)

	case .Type_Field_Index_Of:
		result = check_builtin_type_field_index_of(ctx, operand, call)

	// Advanced type intrinsics
	case .Type_Bit_Set_Elem_Type, .Type_Bit_Set_Underlying_Type, .Type_Bit_Set_Backing_Type:
		result = check_builtin_type_bit_set_accessors(ctx, operand, call, id)

	case .Type_Union_Variant_Count:
		result = check_builtin_type_union_variant_count(ctx, operand, call)

	case .Type_Variant_Type_Of:
		result = check_builtin_type_variant_type_of(ctx, operand, call)

	case .Type_Variant_Index_Of:
		result = check_builtin_type_variant_index_of(ctx, operand, call)

	case .Type_Struct_Field_Count:
		result = check_builtin_type_struct_field_count(ctx, operand, call)

	case .Type_Struct_Has_Implicit_Padding:
		result = check_builtin_type_struct_has_implicit_padding(ctx, operand, call)

	case .Type_Proc_Parameter_Count, .Type_Proc_Return_Count:
		result = check_builtin_type_proc_count(ctx, operand, call, id)

	case .Type_Proc_Parameter_Type, .Type_Proc_Return_Type:
		result = check_builtin_type_proc_type_at_index(ctx, operand, call, id)

	case .Type_Proc_Calling_Convention:
		result = check_builtin_type_proc_calling_convention(ctx, operand, call)

	case .Type_Polymorphic_Record_Parameter_Count:
		result = check_builtin_type_polymorphic_record_parameter_count(ctx, operand, call)

	case .Type_Polymorphic_Record_Parameter_Value:
		result = check_builtin_type_polymorphic_record_parameter_value(ctx, operand, call)

	case .Type_Enum_Is_Contiguous:
		result = check_builtin_type_enum_is_contiguous(ctx, operand, call)

	case .Type_Equal_Proc:
		result = check_builtin_type_equal_proc(ctx, operand, call)

	case .Type_Hasher_Proc:
		result = check_builtin_type_hasher_proc(ctx, operand, call)

	case .Type_Map_Info:
		result = check_builtin_type_map_info(ctx, operand, call)

	case .Type_Map_Cell_Info:
		result = check_builtin_type_map_cell_info(ctx, operand, call)

	case .Type_Canonical_Name:
		result = check_builtin_type_canonical_name(ctx, operand, call)

	// Additional type intrinsics
	case .Type_Field_Type:
		result = check_builtin_type_field_type(ctx, operand, call)

	case .Type_Field_Bit_Offset, .Type_Field_Bit_Size:
		result = check_builtin_type_field_bit(ctx, operand, call, id)

	case .Type_Has_Field:
		result = check_builtin_type_has_field(ctx, operand, call)

	case .Type_Has_Shared_Fields:
		result = check_builtin_type_has_shared_fields(ctx, operand, call)

	case .Type_Is_Named, .Type_Is_Cstring16, .Type_Is_String16, .Type_Is_Dereferenceable, .Type_Is_Sliceable, .Type_Is_Indexable, .Type_Is_Valid_Map_Key, .Type_Is_Valid_Matrix_Elements, .Type_Is_Raw_Union, .Type_Is_Specialized_Polymorphic_Record, .Type_Is_Unspecialized_Polymorphic_Record:
		result = check_builtin_type_is_predicate(ctx, operand, call, id)

	case .Type_Is_Specialization_Of:
		result = check_builtin_type_is_specialization_of(ctx, operand, call)

	case .Type_Is_Superset_Of:
		result = check_builtin_type_is_superset_of(ctx, operand, call)

	case .Type_Is_Variant_Of:
		result = check_builtin_type_is_variant_of(ctx, operand, call)

	case .Type_Integer_To_Signed:
		result = check_builtin_type_integer_to_signed(ctx, operand, call)

	case .Type_Integer_To_Unsigned:
		result = check_builtin_type_integer_to_unsigned(ctx, operand, call)

	case .Type_Merge:
		result = check_builtin_type_merge(ctx, operand, call)

	case .Type_Convert_Variants_To_Pointers:
		result = check_builtin_type_convert_variants_to_pointers(ctx, operand, call)

	case .Type_Union_Base_Tag_Value:
		result = check_builtin_type_union_base_tag_value(ctx, operand, call)

	case .Type_Union_Tag_Offset:
		result = check_builtin_type_union_tag_offset(ctx, operand, call)

	case .Type_Union_Tag_Type:
		result = check_builtin_type_union_tag_type(ctx, operand, call)

	// Swizzle operation
	case .Swizzle:
		result = check_builtin_swizzle(ctx, operand, call, type_hint)

	// Numeric utility operations
	case .Min:
		result = check_builtin_min(ctx, operand, call)

	case .Max:
		result = check_builtin_max(ctx, operand, call)

	case .Abs:
		result = check_builtin_abs(ctx, operand, call)

	case .Clamp:
		result = check_builtin_clamp(ctx, operand, call)

	// Bit manipulation intrinsics
	case .Count_Ones, .Count_Zeros, .Count_Trailing_Zeros, .Count_Leading_Zeros, .Count_Trailing_Ones, .Count_Leading_Ones, .Reverse_Bits:
		result = check_builtin_bit_count(ctx, operand, call, id)

	case .Byte_Swap:
		result = check_builtin_byte_swap(ctx, operand, call)

	// Overflow-checking arithmetic
	case .Overflow_Add, .Overflow_Sub, .Overflow_Mul:
		result = check_builtin_overflow_arith(ctx, operand, call, id)

	// Saturating arithmetic
	case .Saturating_Add, .Saturating_Sub:
		result = check_builtin_saturating_arith(ctx, operand, call, id)

	// Floating-point intrinsics
	case .Sqrt:
		result = check_builtin_sqrt(ctx, operand, call)

	case .Fused_Mul_Add:
		result = check_builtin_fused_mul_add(ctx, operand, call)

	// Fixed-point arithmetic
	case .Fixed_Point_Mul, .Fixed_Point_Div, .Fixed_Point_Mul_Sat, .Fixed_Point_Div_Sat:
		result = check_builtin_fixed_point(ctx, operand, call, id)

	// SIMD operations
	// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:720-1612

	// SIMD binary numeric operations
	case .Simd_Add, .Simd_Sub, .Simd_Mul, .Simd_Div, .Simd_Min, .Simd_Max, .Simd_Rem, .Simd_Pairwise_Add, .Simd_Pairwise_Sub:
		result = check_builtin_simd_binary_numeric(ctx, operand, call, id)

	// SIMD integer binary operations (saturating, bitwise)
	case .Simd_Saturating_Add, .Simd_Saturating_Sub, .Simd_Bit_And, .Simd_Bit_Or, .Simd_Bit_Xor, .Simd_Bit_And_Not:
		result = check_builtin_simd_binary_integer(ctx, operand, call, id)

	// SIMD shift operations
	case .Simd_Shl, .Simd_Shr, .Simd_Shl_Masked, .Simd_Shr_Masked:
		result = check_builtin_simd_shift(ctx, operand, call, id)

	// SIMD unary operations
	case .Simd_Neg, .Simd_Abs:
		result = check_builtin_simd_unary(ctx, operand, call, id)

	// SIMD comparison operations
	case .Simd_Lanes_Eq, .Simd_Lanes_Ne, .Simd_Lanes_Lt, .Simd_Lanes_Le, .Simd_Lanes_Gt, .Simd_Lanes_Ge:
		result = check_builtin_simd_comparison(ctx, operand, call, id)

	// SIMD memory operations
	case .Simd_Gather, .Simd_Scatter, .Simd_Masked_Load, .Simd_Masked_Store, .Simd_Masked_Expand_Load, .Simd_Masked_Compress_Store:
		result = check_builtin_simd_memory(ctx, operand, call, id)

	// SIMD indices
	case .Simd_Indices:
		result = check_builtin_simd_indices(ctx, operand, call)

	// SIMD extract/replace
	case .Simd_Extract:
		result = check_builtin_simd_extract(ctx, operand, call)

	case .Simd_Replace:
		result = check_builtin_simd_replace(ctx, operand, call)

	// SIMD reduction numeric
	case .Simd_Reduce_Add_Bisect, .Simd_Reduce_Mul_Bisect, .Simd_Reduce_Add_Ordered, .Simd_Reduce_Mul_Ordered, .Simd_Reduce_Add_Pairs, .Simd_Reduce_Mul_Pairs, .Simd_Reduce_Min, .Simd_Reduce_Max:
		result = check_builtin_simd_reduce_numeric(ctx, operand, call, id)

	// SIMD reduction bitwise
	case .Simd_Reduce_And, .Simd_Reduce_Or, .Simd_Reduce_Xor:
		result = check_builtin_simd_reduce_bitwise(ctx, operand, call, id)

	// SIMD reduction boolean
	case .Simd_Reduce_Any, .Simd_Reduce_All:
		result = check_builtin_simd_reduce_boolean(ctx, operand, call, id)

	// SIMD extract bits
	case .Simd_Extract_Lsbs, .Simd_Extract_Msbs:
		result = check_builtin_simd_extract_bits(ctx, operand, call, id)

	// SIMD shuffle/select
	case .Simd_Shuffle:
		result = check_builtin_simd_shuffle(ctx, operand, call)

	case .Simd_Select:
		result = check_builtin_simd_select(ctx, operand, call)

	case .Simd_Runtime_Swizzle:
		result = check_builtin_simd_runtime_swizzle(ctx, operand, call)

	case .Simd_Odd_Even:
		result = check_builtin_simd_odd_even(ctx, operand, call)

	case .Simd_Sums_Of_N:
		result = check_builtin_simd_sums_of_n(ctx, operand, call)

	// SIMD rounding and reciprocal approximation operations
	case .Simd_Ceil, .Simd_Floor, .Simd_Trunc, .Simd_Nearest, .Simd_Approx_Recip, .Simd_Approx_Recip_Sqrt:
		result = check_builtin_simd_rounding(ctx, operand, call, id)

	// SIMD lanes manipulation
	case .Simd_Lanes_Reverse:
		result = check_builtin_simd_lanes_reverse(ctx, operand, call)

	case .Simd_Lanes_Rotate_Left, .Simd_Lanes_Rotate_Right:
		result = check_builtin_simd_lanes_rotate(ctx, operand, call, id)

	// SIMD clamp
	case .Simd_Clamp:
		result = check_builtin_simd_clamp(ctx, operand, call)

	// SIMD to_bits
	case .Simd_To_Bits:
		result = check_builtin_simd_to_bits(ctx, operand, call)

	case .Simd_To_Bits_Signed:
		result = check_builtin_simd_to_bits_signed(ctx, operand, call)

	// SIMD interleave/deinterleave
	case .Simd_Interleave:
		result = check_builtin_simd_interleave(ctx, operand, call)

	case .Simd_Deinterleave:
		result = check_builtin_simd_deinterleave(ctx, operand, call)

	// Platform-specific SIMD
	case .Simd_X86_MM_Shuffle:
		result = check_builtin_simd_x86_mm_shuffle(ctx, operand, call)

	// Memory intrinsics
	case .Alloca:
		result = check_builtin_alloca(ctx, operand, call)

	case .Cpu_Relax:
		result = check_builtin_cpu_relax(ctx, operand, call)

	case .Trap:
		result = check_builtin_trap(ctx, operand, call)

	case .Debug_Trap:
		result = check_builtin_debug_trap(ctx, operand, call)

	case .Mem_Copy, .Mem_Copy_Non_Overlapping:
		result = check_builtin_mem_copy(ctx, operand, call, id)

	case .Mem_Zero, .Mem_Zero_Volatile:
		result = check_builtin_mem_zero(ctx, operand, call, id)

	case .Ptr_Offset:
		result = check_builtin_ptr_offset(ctx, operand, call)

	case .Ptr_Sub:
		result = check_builtin_ptr_sub(ctx, operand, call)

	case .Volatile_Store, .Unaligned_Store, .Non_Temporal_Store:
		result = check_builtin_store(ctx, operand, call, id)

	case .Volatile_Load, .Unaligned_Load, .Non_Temporal_Load:
		result = check_builtin_load(ctx, operand, call, id)

	case .Prefetch_Read_Instruction, .Prefetch_Read_Data, .Prefetch_Write_Instruction, .Prefetch_Write_Data:
		result = check_builtin_prefetch(ctx, operand, call, id)

	// Miscellaneous intrinsics
	case .Is_Package_Imported:
		result = check_builtin_is_package_imported(ctx, operand, call)

	case .Read_Cycle_Counter:
		result = check_builtin_read_cycle_counter(ctx, operand, call)

	case .Read_Cycle_Counter_Frequency:
		result = check_builtin_read_cycle_counter_frequency(ctx, operand, call)

	case .Expect:
		result = check_builtin_expect(ctx, operand, call)

	case .Likely, .Unlikely:
		result = check_builtin_likely(ctx, operand, call, id)

	case .Syscall, .Syscall_Bsd:
		result = check_builtin_syscall(ctx, operand, call, id)

	case .Entry_Point:
		result = check_builtin_entry_point(ctx, operand, call)

	// C variadic intrinsics
	case .C_Va_Start, .C_Va_End, .C_Va_Copy, .C_Va_Arg:
		result = check_builtin_c_procedure(ctx, operand, call, id)

	// WebAssembly intrinsics
	case .Wasm_Memory_Grow:
		result = check_builtin_wasm_memory_grow(ctx, operand, call)

	case .Wasm_Memory_Size:
		result = check_builtin_wasm_memory_size(ctx, operand, call)

	case .Wasm_Memory_Atomic_Wait32:
		result = check_builtin_wasm_memory_atomic_wait32(ctx, operand, call)

	case .Wasm_Memory_Atomic_Notify32:
		result = check_builtin_wasm_memory_atomic_notify32(ctx, operand, call)

	// Matrix operations
	case .Hadamard_Product:
		result = check_builtin_hadamard_product(ctx, operand, call)

	case .Matrix_Flatten:
		result = check_builtin_matrix_flatten(ctx, operand, call)

	case .Outer_Product:
		result = check_builtin_outer_product(ctx, operand, call)

	case .Transpose:
		result = check_builtin_transpose(ctx, operand, call)

	// Constant operations (compile-time)
	case .Constant_Ceil, .Constant_Floor, .Constant_Round, .Constant_Trunc:
		result = check_builtin_constant_rounding(ctx, operand, call, id)

	case .Constant_Log2:
		result = check_builtin_constant_log2(ctx, operand, call)

	case .Constant_Utf16_Cstring:
		result = check_builtin_constant_utf16_cstring(ctx, operand, call, type_hint)

	// Platform-specific intrinsics
	case .X86_Cpuid:
		result = check_builtin_x86_cpuid(ctx, operand, call)

	case .X86_Xgetbv:
		result = check_builtin_x86_xgetbv(ctx, operand, call)

	case .Valgrind_Client_Request:
		result = check_builtin_valgrind_client_request(ctx, operand, call)

	case .Has_Target_Feature:
		result = check_builtin_has_target_feature(ctx, operand, call)

	// Additional core builtins
	case .Concatenate:
		result = check_builtin_concatenate(ctx, operand, call)

	case .Soa_Struct:
		result = check_builtin_soa_struct(ctx, operand, call)

	case .Procedure_Of:
		result = check_builtin_procedure_of(ctx, operand, call)

	case:
		// Unimplemented builtins
		error_node(call, "Builtin '%s' not yet implemented", info.name)
		return false
	}

	// Step 5: Set expression node
	if result {
		operand.expr = call
	}

	return result
}

// check_builtin_len_cap handles len() and cap() builtins
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2529-2637
check_builtin_len_cap :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id, type_hint: ^Type) -> bool {
	// Check argument (type or expression)
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode == .Invalid {
		return false
	}

	op_type := type_deref(operand.type)
	result_type := t_int // Default

	// Type hint support (int or uint)
	if type_hint != nil {
		bt := base_type(type_hint)
		if bt == t_int || bt == t_uint {
			result_type = type_hint
		}
	}

	mode := Addressing_Mode.Invalid
	value: Exact_Value = nil

	// Dispatch by operand type
	if is_type_string(op_type) && id == .Len {
		// String length
		if operand.mode == .Constant {
			mode = .Constant
			if str, str_ok := operand.value.(string); str_ok {
				value = exact_value_i64(i64(len(str)))
			// C++ Reference: check_builtin.cpp:2617-2619
			// Handle String16 constant values
			} else if s16, s16_ok := operand.value.(Exact_Value_String16); s16_ok {
				value = exact_value_i64(i64(s16.len))
			}
			result_type = t_untyped_integer
		} else {
			mode = .Value
			// C++ Reference: check_builtin.cpp:2628-2630
			// Add appropriate string length dependency based on type
			if is_type_string16(op_type) || is_type_cstring16(op_type) {
				add_package_dependency(ctx, "runtime", "cstring16_len")
			} else {
				add_package_dependency(ctx, "runtime", "cstring_len")
			}
		}

	} else if is_type_enumerated_array(op_type) && id == .Len {
		// Enumerated array length - always constant
		// C++ Reference: check_builtin.cpp:2637-2641
		bt := base_type(op_type)
		ea := bt.variant.(Type_Enumerated_Array)
		mode = .Constant
		value = exact_value_i64(ea.count)
		result_type = t_untyped_integer

	} else if is_type_array(op_type) {
		// Array length - always constant
		//
		// NOTE: must go through base_type. is_type_array unwraps named types internally, so it
		// answers true for e.g. `distinct [N]T`, but the variant then lives on the BASE type -
		// asserting on op_type directly crashes with "Invalid type assertion from Type_Variant to
		// Type_Array, actual type: Type_Named". Every sibling branch here already does this.
		bt := base_type(op_type)
		arr := bt.variant.(Type_Array)
		mode = .Constant
		value = exact_value_i64(arr.count)
		result_type = t_untyped_integer

	} else if is_type_fixed_capacity_dynamic_array(op_type) {
		// `[dynamic; N]T`: the CAPACITY is a compile-time constant (it is part of the
		// type), while the length is a runtime value.
		// C++ Reference: check_builtin.cpp:2970-2982.
		ct := core_type(op_type)
		fc := ct.variant.(Type_Fixed_Capacity_Dynamic_Array)
		if id == .Cap {
			mode = .Constant
			value = exact_value_i64(fc.capacity)
			result_type = t_untyped_integer
		} else {
			assert(id == .Len)
			mode = .Value
		}

	} else if is_type_slice(op_type) {
		// Slice len/cap - runtime value
		// Both len and cap are valid for slices
		mode = .Value

	} else if is_type_dynamic_array(op_type) {
		// Dynamic array len/cap - runtime value
		mode = .Value

	} else if is_type_map(op_type) {
		// Map length - runtime value
		mode = .Value

	} else if operand.mode == .Type && is_type_enum(op_type) {
		// Enum len/cap on type
		// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2591-2601
		bt := base_type(op_type)
		mode = .Constant
		result_type = t_untyped_integer

		if id == .Len {
			// len(EnumType) returns number of enum fields
			te := bt.variant.(Type_Enum)
			value = exact_value_i64(i64(len(te.fields)))
		} else {
			// cap(EnumType) returns max - min + 1
			assert(id == .Cap)
			te := bt.variant.(Type_Enum)
			value = exact_value_sub(te.max_value, te.min_value)
			value = exact_value_increment_one(value)
		}

	} else if is_type_simd_vector(op_type) {
		// SIMD vector length - constant
		// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2603-2608
		bt := base_type(op_type)
		simd := bt.variant.(Type_Simd_Vector)
		mode = .Constant
		value = exact_value_i64(simd.count)
		result_type = t_untyped_integer

	} else if is_type_struct(op_type) {
		// SOA struct support
		// C++ Reference: check_builtin.cpp:2659-2668
		bt := base_type(op_type)
		st := bt.variant.(Type_Struct)
		#partial switch st.soa_kind {
		case .Fixed:
			// #soa[N]T - fixed size, returns constant
			mode = .Constant
			value = exact_value_i64(st.soa_count)
			result_type = t_untyped_integer
		case .Slice:
			// #soa[]T - slice-like SOA, only len is valid
			if id == .Len {
				mode = .Value
			}
			// cap not valid for SOA slices (mode stays Invalid)
		case .Dynamic:
			// #soa[dynamic]T - dynamic SOA, both len and cap valid
			mode = .Value
		}

	} else {
		// Unsupported type
		builtin_name := builtin_proc_infos[id].name
		type_str := type_to_string(op_type)
		if is_type_bit_set(op_type) && id == .Len {
			error_node(call, "'%s' is not supported for '%s', did you mean 'card'?", builtin_name, type_str)
		} else {
			error_node(call, "'%s' is not supported for '%s'", builtin_name, type_str)
		}
		return false
	}

	// Type operand must result in constant
	if operand.mode == .Type && mode != .Constant {
		mode = .Invalid
	}

	if mode == .Invalid {
		return false
	}

	operand.mode = mode
	operand.value = value
	operand.type = result_type
	return true
}

// check_builtin_size_of handles size_of() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2639-2658
check_builtin_size_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	// Check argument (type or expression)
	o: Operand
	check_expr_or_type(ctx, &o, call.args[0])
	if o.mode == .Invalid {
		return false
	}

	t := o.type
	if t == nil || t == t_invalid {
		error_node(call.args[0], "Invalid argument for 'size_of'")
		return false
	}

	t = default_type(t)

	operand.mode = .Constant
	operand.value = exact_value_i64(i64(type_size_of(t))) // type_size_of returns int, convert to i64
	operand.type = t_untyped_integer
	return true
}

// check_builtin_align_of handles align_of() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2660-2679
check_builtin_align_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	// Nearly identical to size_of
	o: Operand
	check_expr_or_type(ctx, &o, call.args[0])
	if o.mode == .Invalid {
		return false
	}

	t := o.type
	if t == nil || t == t_invalid {
		error_node(call.args[0], "Invalid argument for 'align_of'")
		return false
	}

	t = default_type(t)

	operand.mode = .Constant
	operand.value = exact_value_i64(i64(type_align_of(t))) // type_align_of returns int, convert to i64
	operand.type = t_untyped_integer
	return true
}

// Removed: old stub implementation replaced by check_builtin_offset_of_impl

// check_builtin_type_of handles type_of() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2870-2907
check_builtin_type_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	o: Operand
	check_expr_or_type(ctx, &o, call.args[0])

	if o.mode == .Invalid || o.mode == .Builtin {
		return false
	}

	if o.type == nil || o.type == t_invalid || is_type_asm_proc(o.type) {
		error_node(o.expr, "Invalid argument to 'type_of'")
		return false
	}

	if is_type_untyped(o.type) {
		type_str := type_to_string(o.type)
		error_node(o.expr, "'type_of' of %s cannot be determined", type_str)
		return false
	}

	// C++ Reference: check_builtin.cpp:2890-2897
	// NOTE(bill): Prevent type cycles for procedure declarations
	if ctx.curr_proc_sig == o.type {
		expr_str := expr_to_string(o.expr)
		defer delete(expr_str)
		error_node(o.expr, "Invalid cyclic type usage from 'type_of', got '%s'", expr_str)
		return false
	}

	if is_type_polymorphic(o.type) {
		error_node(o.expr, "'type_of' of polymorphic type cannot be determined")
		return false
	}

	// C++ Reference: check_builtin.cpp:7390-7418
	// Store procedure entity on call expression for constant folding
	// This is required for check_decl.odin to handle constant procedure aliases
	if e := entity_of_node(ctx.info, call.args[0]); e != nil {
		if is_type_proc(e.type) {
			set_ast_entity(ctx.info, call, e)
		}
	}

	operand.mode = .Type
	operand.type = o.type
	return true
}

// check_builtin_type_info_of handles type_info_of() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2909-2952
// Returns ^Type_Info for any type
check_builtin_type_info_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_info_of"

	// Check scope flags - cannot be used in runtime package (C++ line 2911-2913)
	if .Global in ctx.scope.flags {
		error_node(call, "'%s' cannot be declared within the runtime package due to how the internals of the compiler works", builtin_name)
		return false
	}

	// Check build flags for no_rtti (C++ line 2914-2917)
	if ctx.info.build_context != nil && ctx.info.build_context.no_rtti {
		error_node(call, "'%s' has been disallowed", builtin_name)
		return false
	}

	// Initialize type info system (C++ line 2920)
	init_core_type_info(ctx.checker)

	// Check the argument (C++ line 2921-2926)
	expr := call.args[0]
	o: Operand
	check_expr_or_type(ctx, &o, expr)
	if o.mode == .Invalid {
		return false
	}

	// Validate the type (C++ line 2927-2936)
	t := o.type
	if t == nil || t == t_invalid || is_type_polymorphic(t) {
		if is_type_polymorphic(t) {
			error_node(expr, "Invalid argument for '%s', unspecialized polymorphic type", builtin_name)
		} else {
			error_node(expr, "Invalid argument for '%s'", builtin_name)
		}
		return false
	}

	// Get default type (handles untyped) (C++ line 2936)
	t = default_type(t)

	// Register type for RTTI (C++ line 2938-2940)
	add_type_info_type(ctx, t)
	assert(t_type_info_ptr != nil, "t_type_info_ptr not initialized")
	add_type_info_type(ctx, t_type_info_ptr)

	// Handle runtime typeid case (C++ line 2942-2947)
	if is_operand_value(o) && is_type_typeid(t) {
		// Package dependency tracking implemented in entity_helpers.odin:709
		add_package_dependency(ctx, "runtime", "__type_info_of")
	} else if o.mode != .Type {
		error_node(expr, "Expected a type or typeid for '%s'", builtin_name)
		return false
	}

	// Set result (C++ line 2949-2951)
	operand.mode = .Value
	operand.type = t_type_info_ptr
	return true
}

// check_builtin_typeid_of handles typeid_of() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2954-2990
// Returns typeid (integer constant) for any type
check_builtin_typeid_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "typeid_of"

	// Check scope flags - cannot be used in runtime package (C++ line 2956-2958)
	if .Global in ctx.scope.flags {
		error_node(call, "'%s' cannot be declared within the runtime package due to how the internals of the compiler works", builtin_name)
		return false
	}

	// Check build flags for no_rtti (C++ line 2959-2962)
	if ctx.info.build_context != nil && ctx.info.build_context.no_rtti {
		error_node(call, "'%s' has been disallowed", builtin_name)
		return false
	}

	// Initialize type info system (C++ line 2965)
	init_core_type_info(ctx.checker)

	// Check the argument (C++ line 2966-2971)
	expr := call.args[0]
	o: Operand
	check_expr_or_type(ctx, &o, expr)
	if o.mode == .Invalid {
		return false
	}

	// Validate the type (C++ line 2972-2977)
	t := o.type
	if t == nil || t == t_invalid || is_type_polymorphic(t) {
		error_node(expr, "Invalid argument for '%s'", builtin_name)
		return false
	}

	// Get default type (handles untyped) (C++ line 2977)
	t = default_type(t)

	// Register type for RTTI (C++ line 2979)
	add_type_info_type(ctx, t)

	// Must be a type expression (C++ line 2981-2984)
	if o.mode != .Type {
		error_node(expr, "Expected a type for '%s'", builtin_name)
		return false
	}

	// Set result - typeid is a compile-time constant (C++ line 2986-2989)
	operand.mode = .Value
	operand.type = t_typeid
	operand.value = exact_value_typeid(t)
	return true
}

// ============================================================================
// Atomic Operations
// ============================================================================

// Atomic_Memory_Order enum matches Odin's runtime.Atomic_Memory_Order
// C++ Reference: OdinAtomicMemoryOrder in /mnt/c/odin/src/checker.hpp
Atomic_Memory_Order :: enum {
	Relaxed = 0,
	Consume = 1,
	Acquire = 2,
	Release = 3,
	Acq_Rel = 4,
	Seq_Cst = 5,
}

Atomic_Memory_Order_Strings := [Atomic_Memory_Order]string {
	.Relaxed = "relaxed",
	.Consume = "consume",
	.Acquire = "acquire",
	.Release = "release",
	.Acq_Rel = "acq_rel",
	.Seq_Cst = "seq_cst",
}

// check_atomic_memory_order_argument validates memory order argument
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:686-716
check_atomic_memory_order_argument :: proc(ctx: ^Checker_Context, expr: ^ast.Expr, builtin_name: string, out_order: ^Atomic_Memory_Order = nil, extra_message := "") -> bool {
	x: Operand
	// Check with type hint if t_atomic_memory_order is available (set when core:runtime is loaded)
	type_hint := t_atomic_memory_order // May be nil if runtime not yet loaded
	check_expr_with_type_hint(ctx, &x, expr, type_hint)
	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant {
		// C++ Reference: check_builtin.cpp:880-883 -- names the type that was supplied.
		type_str := type_to_string(x.type)
		if extra_message != "" {
			error_node(expr, "Expected a constant Atomic_Memory_Order value for the %s of '%s', got %s", extra_message, builtin_name, type_str)
		} else {
			error_node(expr, "Expected a constant Atomic_Memory_Order value for '%s', got %s", builtin_name, type_str)
		}
		return false
	}

	// Extract integer value
	value: i64
	if iv, ok := x.value.(big.Int); ok {
		// Convert big.Int to i64
		val, err := big.int_get_i64(&iv)
		if err == nil {
			value = val
		} else {
			error_node(expr, "Integer constant too large for memory order")
			return false
		}
	} else {
		error_node(expr, "Expected an integer constant for memory order")
		return false
	}

	if value < 0 || value >= i64(len(Atomic_Memory_Order)) {
		error_node(expr, "Illegal Atomic_Memory_Order value, got %d", value)
		return false
	}

	if out_order != nil {
		out_order^ = Atomic_Memory_Order(value)
	}

	return true
}

// check_atomic_ptr_argument validates pointer argument for atomic operations
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1756-1763
check_atomic_ptr_argument :: proc(operand: ^Operand, builtin_name: string, elem: ^Type) -> bool {
	if !is_type_valid_atomic_type(elem) {
		error_node(operand.expr, "Only an integer, floating-point, boolean, or pointer can be used as an atomic for '%s'", builtin_name)
		return false
	}
	return true
}

// check_builtin_atomic_type_is_lock_free checks if a type is guaranteed lock-free for atomics
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5718-5746
check_builtin_atomic_type_is_lock_free :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "atomic_type_is_lock_free"

	o: Operand
	check_expr_or_type(ctx, &o, call.args[0])

	if o.mode == .Invalid || o.mode == .Builtin {
		return false
	}
	if o.type == nil || o.type == t_invalid || is_type_asm_proc(o.type) {
		error_node(o.expr, "Invalid argument to '%s'", builtin_name)
		return false
	}
	if is_type_polymorphic(o.type) {
		error_node(o.expr, "'%s' of polymorphic type cannot be determined", builtin_name)
		return false
	}
	if is_type_untyped(o.type) {
		error_node(o.expr, "'%s' of untyped type is not allowed", builtin_name)
		return false
	}

	lock_free := is_type_lock_free(o.type)

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(lock_free)
	return true
}

// check_builtin_atomic_thread_fence handles atomic_thread_fence and atomic_signal_fence
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5523-5543
check_builtin_atomic_fence :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	memory_order: Atomic_Memory_Order
	if !check_atomic_memory_order_argument(ctx, call.args[0], builtin_name, &memory_order) {
		return false
	}

	// Validate allowed orderings for fence operations
	#partial switch memory_order {
	case .Acquire, .Release, .Acq_Rel, .Seq_Cst:
		// Valid orderings for fence
		break
	case:
		order_name := Atomic_Memory_Order_Strings[memory_order]
		error_node(call.args[0], "Illegal memory ordering for '%s', got .%s", builtin_name, order_name)
		return false
	}

	operand.mode = .No_Value
	operand.type = nil
	return true
}

// check_builtin_atomic_store handles atomic_store and atomic_store_explicit
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5548-5596
check_builtin_atomic_store :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// First arg must be a normal (non-rawptr) pointer
	// C++ Reference: check_builtin.cpp:6183 - is_type_normal_pointer(operand->type, &elem)
	elem: ^Type
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	// Validate element type is atomic-compatible
	if !check_atomic_ptr_argument(operand, builtin_name, elem) {
		return false
	}

	// Check value argument
	x: Operand
	check_expr_with_type_hint(ctx, &x, call.args[1], elem)
	check_assignment(ctx, &x, elem, builtin_name)

	// Check memory ordering for explicit version
	if id == .Atomic_Store_Explicit {
		memory_order: Atomic_Memory_Order
		if !check_atomic_memory_order_argument(ctx, call.args[2], builtin_name, &memory_order) {
			return false
		}

		// atomic_store cannot use Acquire or Acq_Rel
		#partial switch memory_order {
		case .Consume, .Acquire, .Acq_Rel:
			order_name := Atomic_Memory_Order_Strings[memory_order]
			error_node(call.args[2], "Illegal memory order .%s for '%s'", order_name, builtin_name)
			return false
		}
	}

	operand.mode = .No_Value
	operand.type = nil
	return true
}

// check_builtin_atomic_load handles atomic_load and atomic_load_explicit
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5602-5644
check_builtin_atomic_load :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// First arg must be a normal (non-rawptr) pointer
	// C++ Reference: check_builtin.cpp:6183 - is_type_normal_pointer(operand->type, &elem)
	elem: ^Type
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	// Validate element type is atomic-compatible
	if !check_atomic_ptr_argument(operand, builtin_name, elem) {
		return false
	}

	// Check memory ordering for explicit version
	if id == .Atomic_Load_Explicit {
		memory_order: Atomic_Memory_Order
		if !check_atomic_memory_order_argument(ctx, call.args[1], builtin_name, &memory_order) {
			return false
		}

		// atomic_load cannot use Release or Acq_Rel
		#partial switch memory_order {
		case .Release, .Acq_Rel:
			order_name := Atomic_Memory_Order_Strings[memory_order]
			error_node(call.args[1], "Illegal memory order .%s for '%s'", order_name, builtin_name)
			return false
		}
	}

	operand.mode = .Value
	operand.type = elem
	return true
}

// check_builtin_atomic_rmw handles atomic RMW operations (add/sub/and/or/xor/exchange)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5646-5725
check_builtin_atomic_rmw :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// First arg must be a normal (non-rawptr) pointer
	// C++ Reference: check_builtin.cpp:6183 - is_type_normal_pointer(operand->type, &elem)
	elem: ^Type
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	// Validate element type is atomic-compatible
	if !check_atomic_ptr_argument(operand, builtin_name, elem) {
		return false
	}

	// Check value argument
	x: Operand
	check_expr_with_type_hint(ctx, &x, call.args[1], elem)
	check_assignment(ctx, &x, elem, builtin_name)

	// For arithmetic/bitwise ops (not exchange), require integer types
	is_exchange := id == .Atomic_Exchange || id == .Atomic_Exchange_Explicit
	if !is_exchange {
		t := type_deref(operand.type)
		if !is_type_integer_like(t) {
			type_str := type_to_string(t)
			error_node(operand.expr, "Expected an integer type for '%s', got %s", builtin_name, type_str)
		} else if is_type_different_to_arch_endianness(t) {
			type_str := type_to_string(t)
			error_node(operand.expr, "Expected an integer type of the same platform endianness for '%s', got %s", builtin_name, type_str)
		}
	}

	// Check memory ordering for explicit versions
	is_explicit := id == .Atomic_Add_Explicit || id == .Atomic_Sub_Explicit || id == .Atomic_And_Explicit || id == .Atomic_Nand_Explicit || id == .Atomic_Or_Explicit || id == .Atomic_Xor_Explicit || id == .Atomic_Exchange_Explicit

	if is_explicit {
		if !check_atomic_memory_order_argument(ctx, call.args[2], builtin_name, nil) {
			return false
		}
	}

	operand.mode = .Value
	operand.type = elem
	return true
}

// check_builtin_atomic_compare_exchange handles compare_exchange operations
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5727-5825
check_builtin_atomic_compare_exchange :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// First arg must be a normal (non-rawptr) pointer
	// C++ Reference: check_builtin.cpp:6183 - is_type_normal_pointer(operand->type, &elem)
	elem: ^Type
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	// Validate element type is atomic-compatible
	if !check_atomic_ptr_argument(operand, builtin_name, elem) {
		return false
	}

	// Check old value argument (arg 1)
	x: Operand
	check_expr_with_type_hint(ctx, &x, call.args[1], elem)
	check_assignment(ctx, &x, elem, builtin_name)

	// Check new value argument (arg 2)
	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[2], elem)
	check_assignment(ctx, &y, elem, builtin_name)

	// Type must be comparable
	t := type_deref(operand.type)
	if !is_type_comparable(t) {
		type_str := type_to_string(t)
		error_node(operand.expr, "Expected a comparable type for '%s', got %s", builtin_name, type_str)
		return false
	}

	// Check memory orderings for explicit versions
	is_explicit := id == .Atomic_Compare_Exchange_Strong_Explicit || id == .Atomic_Compare_Exchange_Weak_Explicit

	if is_explicit {
		success_order: Atomic_Memory_Order
		failure_order: Atomic_Memory_Order

		if !check_atomic_memory_order_argument(ctx, call.args[3], builtin_name, &success_order, "success ordering") {
			return false
		}
		if !check_atomic_memory_order_argument(ctx, call.args[4], builtin_name, &failure_order, "failure ordering") {
			return false
		}

		// Validate ordering constraints
		// Failure ordering cannot be Release or Acq_Rel
		#partial switch failure_order {
		case .Release, .Acq_Rel:
			error_node(call.args[4], "Failure ordering cannot be Release or Acq_Rel for '%s'", builtin_name)
			return false
		}

		// Failure ordering cannot be stronger than success ordering
		// Ordering strength: Relaxed < Consume < Acquire < Release < Acq_Rel < Seq_Cst
		invalid_combination := false

		#partial switch success_order {
		case .Relaxed, .Release:
			// Relaxed and Release success only allow Relaxed failure
			// C++ Reference: check_builtin.cpp:5794-5799
			if failure_order != .Relaxed {
				invalid_combination = true
			}

		case .Consume:
			// Consume success allows Relaxed or Consume failure (NOT Acquire!)
			// C++ Reference: check_builtin.cpp:5800-5809
			if failure_order != .Relaxed && failure_order != .Consume {
				invalid_combination = true
			}

		case .Acquire, .Acq_Rel:
			// Acquire and Acq_Rel success allow Relaxed, Consume, or Acquire failure
			// C++ Reference: check_builtin.cpp:5810-5821
			if failure_order != .Relaxed && failure_order != .Consume && failure_order != .Acquire {
				invalid_combination = true
			}

		case .Seq_Cst:
			// Seq_Cst success allows Relaxed, Consume, Acquire, or Seq_Cst failure
			// C++ Reference: check_builtin.cpp:5822-5833
			if failure_order != .Relaxed && failure_order != .Consume && failure_order != .Acquire && failure_order != .Seq_Cst {
				invalid_combination = true
			}
		}

		if invalid_combination {
			success_name := Atomic_Memory_Order_Strings[success_order]
			failure_name := Atomic_Memory_Order_Strings[failure_order]
			error_node(call.args[4], "Failure ordering .%s cannot be stronger than success ordering .%s for '%s'", failure_name, success_name, builtin_name)
			return false
		}
	}
	// C++ Reference: check_builtin.cpp:5847-5850
	// compare_exchange returns (T, bool) - the original value and success flag
	operand.mode = .Optional_Ok
	operand.type = elem
	return true
}

// ============================================================================
// Objective-C Runtime Builtins
// ============================================================================

// check_builtin_objc_send handles objc_send builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:285-377
check_builtin_objc_send :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "objc_send"

	// C++ Reference: check_builtin.cpp:271-276
	// Platform validation: Objective-C intrinsics only work on Darwin platforms
	if !is_platform_darwin(ctx) {
		// Allow on doc generation (e.g. Metal stuff)
		if ctx.info.build_context != nil {
			cmd := ctx.info.build_context.command_kind
			if .Doc not_in cmd && .Check not_in cmd {
				error_node(call, "'%s' only works on darwin", builtin_name)
			}
		}
	}

	// Argument 0: Return type (Type or nil)
	// C++ ref: check_builtin.cpp:288-299
	rt: Operand
	check_expr_or_type(ctx, &rt, call.args[0])

	return_type: ^Type = nil
	if rt.mode == .Type {
		return_type = rt.type
	} else if is_operand_nil(rt) {
		return_type = nil
	} else {
		error_node(rt.expr, "'objc_send' expected a type or nil to define the return type, got value")
		return false
	}

	// Argument 1: Object or Type (self parameter)
	// C++ ref: check_builtin.cpp:307-349
	self: Operand
	check_expr_or_type(ctx, &self, call.args[1])

	sel_type := t_objc_SEL

	if self.mode == .Type {
		// Class method: Type.selector()
		if !is_type_objc_object(self.type) {
			error_node(self.expr, "'objc_send' expected a type derived from intrinsics.objc_object")
			return false
		}
		if !has_type_got_objc_class_attribute(self.type) {
			error_node(self.expr, "'objc_send' expected a named type with the attribute @(objc_class=<string>)")
			return false
		}
		sel_type = t_objc_Class
	} else if !is_operand_value(self) {
		error_node(self.expr, "'objc_send' expected a type or value derived from intrinsics.objc_object")
		return false
	} else if !check_is_assignable_to(ctx, &self, t_objc_id) {
		error_node(self.expr, "'objc_send' expected a value assignable to objc_id")
		return false
	} else if !is_type_pointer(self.type) {
		error_node(self.expr, "'objc_send' expected a pointer to a value derived from intrinsics.objc_object")
		return false
	} else {
		// Instance method: check pointer element is objc_object with class attribute
		deref_type := type_deref(self.type)
		if deref_type.kind != .Named {
			error_node(self.expr, "'objc_send' expected a named type with the attribute @(objc_class=<string>)")
			return false
		}
		if !has_type_got_objc_class_attribute(deref_type) {
			error_node(self.expr, "'objc_send' expected a named type with the attribute @(objc_class=<string>)")
			return false
		}
	}

	// Argument 2: Selector name (string constant)
	// C++ ref: check_builtin.cpp:352-354
	name: string
	if !is_constant_string(ctx, "objc_send", call.args[2], &name) {
		return false
	}

	// Remaining arguments: message parameters
	// C++ ref: check_builtin.cpp:356-372
	// Must be typed expressions (no untyped values allowed)
	arg_offset := 3
	for i in arg_offset ..< len(call.args) {
		x: Operand
		check_expr(ctx, &x, call.args[i])
		if is_type_untyped(x.type) {
			error_node(x.expr, "'objc_send' expects typed parameters")
			return false
		}
	}

	// Package dependency tracking implemented in entity_helpers.odin:709
	add_package_dependency(ctx, "runtime", "objc_msgSend")
	add_package_dependency(ctx, "runtime", "objc_msgSend_fpret")
	add_package_dependency(ctx, "runtime", "objc_msgSend_fp2ret")
	add_package_dependency(ctx, "runtime", "objc_msgSend_stret")

	// Set result
	if return_type != nil {
		operand.mode = .Value
		operand.type = return_type
	} else {
		operand.mode = .No_Value
		operand.type = nil
	}

	return true
}

// check_builtin_objc_find_register handles objc_find_selector, objc_find_class,
// objc_register_selector, and objc_register_class
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:379-406
check_builtin_objc_find_register :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// C++ Reference: check_builtin.cpp:271-276
	// Platform validation: Objective-C intrinsics only work on Darwin platforms
	if !is_platform_darwin(ctx) {
		// Allow on doc generation (e.g. Metal stuff)
		if ctx.info.build_context != nil {
			cmd := ctx.info.build_context.command_kind
			if .Doc not_in cmd && .Check not_in cmd {
				error_node(call, "'%s' only works on darwin", builtin_name)
			}
		}
	}

	// Argument 0: Name (string constant)
	// C++ ref: check_builtin.cpp:384-387
	name: string
	if !is_constant_string(ctx, builtin_name, call.args[0], &name) {
		return false
	}

	// Set return type based on builtin
	// C++ ref: check_builtin.cpp:389-398
	#partial switch id {
	case .Objc_Find_Selector, .Objc_Register_Selector:
		operand.type = t_objc_SEL
	case .Objc_Find_Class, .Objc_Register_Class:
		operand.type = t_objc_Class
	case:
		error_node(call, "Unknown objc builtin '%s'", builtin_name)
		return false
	}

	operand.mode = .Value

	// Package dependency tracking implemented in entity_helpers.odin:709
	add_package_dependency(ctx, "runtime", "objc_lookUpClass")
	add_package_dependency(ctx, "runtime", "sel_registerName")
	add_package_dependency(ctx, "runtime", "objc_allocateClassPair")

	return true
}

// check_builtin_objc_ivar_get handles objc_ivar_get builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:408-458
check_builtin_objc_ivar_get :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	builtin_name := "objc_ivar_get"

	// C++ Reference: check_builtin.cpp:271-276
	// Platform validation: Objective-C intrinsics only work on Darwin platforms
	if !is_platform_darwin(ctx) {
		// Allow on doc generation (e.g. Metal stuff)
		if ctx.info.build_context != nil {
			cmd := ctx.info.build_context.command_kind
			if .Doc not_in cmd && .Check not_in cmd {
				error_node(call, "'%s' only works on darwin", builtin_name)
			}
		}
	}

	// Argument 0: Object (value derived from objc_object)
	// C++ ref: check_builtin.cpp:412-429
	self: Operand
	check_expr_or_type(ctx, &self, call.args[0])

	if !is_operand_value(self) {
		error_node(self.expr, "'objc_ivar_get' expected a value derived from intrinsics.objc_object")
		return false
	}

	if !check_is_assignable_to(ctx, &self, t_objc_id) {
		error_node(self.expr, "'objc_ivar_get' expected a value assignable to objc_id")
		return false
	}

	if !is_type_pointer(self.type) {
		error_node(self.expr, "'objc_ivar_get' expected a pointer to a value derived from intrinsics.objc_object")
		return false
	}

	// Get dereferenced type
	self_type := type_deref(self.type)

	// Must be named type with objc_class attribute
	// C++ ref: check_builtin.cpp:433-440
	if self_type.kind != .Named {
		error_node(self.expr, "'objc_ivar_get' expected a named type with the attribute @(objc_class=<string>)")
		return false
	}

	if !has_type_got_objc_class_attribute(self_type) {
		error_node(self.expr, "'objc_ivar_get' expected a named type with the attribute @(objc_class=<string>)")
		return false
	}

	// Extract ivar type from Entity_Type_Name.objc_ivar field
	// C++ ref: check_builtin.cpp:442-448
	named := self_type.variant.(Type_Named)
	type_name_entity := named.type_name.variant.(Entity_Type_Name)
	ivar_type := type_name_entity.objc_ivar

	if ivar_type == nil {
		type_str := type_to_string(self_type)
		error_node(self.expr, "'objc_ivar_get' requires that type %s have the attribute @(objc_ivar=<ivar_type_name>)", type_str)
		return false
	}

	// Determine result type based on hint
	// C++ ref: check_builtin.cpp:450-454
	result_type: ^Type
	// C++ Reference: check_builtin.cpp:462 - `type_hint->kind == Type_Pointer` (a rawptr hint is not usable here)
	if type_hint != nil && type_hint.kind == .Pointer {
		hint_ptr := type_hint.variant.(Type_Pointer)
		if hint_ptr.elem == ivar_type {
			result_type = type_hint
		} else {
			result_type = alloc_type_pointer(ivar_type)
		}
	} else {
		result_type = alloc_type_pointer(ivar_type)
	}

	operand.mode = .Value
	operand.type = result_type
	return true
}

// check_builtin_objc_block handles objc_block() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:470-691
// Creates ObjC block literals with captured values
check_builtin_objc_block :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "objc_block"

	// Platform validation: Objective-C intrinsics only work on Darwin platforms
	if !is_platform_darwin(ctx) {
		if ctx.info.build_context != nil {
			cmd := ctx.info.build_context.command_kind
			if .Doc not_in cmd && .Check not_in cmd {
				error_node(call, "'%s' only works on darwin", builtin_name)
				return false
			}
		}
	}

	// The last argument is the handler proc, any others are capture-by-copy arguments
	if len(call.args) < 1 {
		error_node(call, "'%s' requires at least one argument (the handler procedure)", builtin_name)
		return false
	}

	capture_arg_count := len(call.args) - 1

	// Check capture arguments - they must be values
	for i := 0; i < capture_arg_count; i += 1 {
		x: Operand
		check_expr(ctx, &x, call.args[i])

		#partial switch x.mode {
		case .Value, .Variable, .Constant:
			// OK
		case:
			error_node(x.expr, "'%s' capture arguments must be values", builtin_name)
			return false
		}
	}

	// Validate handler proc
	handler: Operand
	check_expr_or_type(ctx, &handler, call.args[capture_arg_count])

	if !is_operand_value(handler) || !is_type_proc(handler.type) {
		error_node(handler.expr, "'%s' expected a procedure as the last argument", builtin_name)
		return false
	}

	// Only direct references to procs are allowed
	handler_node := unparen_expr(handler.expr)
	#partial switch n in handler_node.derived {
	case ^ast.Proc_Lit:
		// OK - anonymous procedure
	case ^ast.Ident:
		if n.entity == nil {
			error_node(handler.expr, "'%s' failed to resolve entity from expression", builtin_name)
			return false
		}
		entity_proc, is_proc := n.entity.variant.(Entity_Procedure)
		_ = entity_proc
		if !is_proc {
			error_node(handler.expr, "'%s' expected a direct reference to a procedure", builtin_name)
			return false
		}
	case:
		error_node(handler.expr, "'%s' expected a direct reference to a procedure", builtin_name)
		return false
	}

	// Get proc type info
	proc_type := base_type(handler.type)
	proc_info := proc_type.variant.(Type_Proc)

	if capture_arg_count > proc_info.param_count {
		error_node(handler.expr, "'%s' captured arguments exceeded the handler's parameter count", builtin_name)
		return false
	}

	// Check calling convention
	#partial switch proc_info.calling_convention {
	case .Odin, .Contextless, .C:
		// OK
	case:
		error_node(handler.expr, "'%s' invalid calling convention for block procedure", builtin_name)
		return false
	}

	if proc_info.is_polymorphic {
		error_node(handler.expr, "'%s' unspecialized polymorphic procedures are not allowed", builtin_name)
		return false
	}

	// At most a single return value is supported
	if proc_info.result_count > 1 {
		error_node(handler.expr, "'%s' handler procedures cannot have multiple return values", builtin_name)
		return false
	}

	// Check captured arguments are assignable to handler's capture parameters
	// C++ Reference: check_builtin.cpp L580-620
	if proc_info.params != nil {
		params := proc_info.params.variant.(Type_Tuple)
		for i := 0; i < capture_arg_count; i += 1 {
			if i >= len(params.variables) {
				break
			}
			param := params.variables[i]
			if param == nil {
				continue
			}

			x: Operand
			check_expr(ctx, &x, call.args[i])
			if x.mode == .Invalid {
				return false
			}

			// Check assignability
			if !check_is_assignable_to(ctx, &x, param.type) {
				x_str := type_to_string(x.type)
				p_str := type_to_string(param.type)
				error_node(x.expr, "'%s' capture argument %d: cannot assign '%s' to '%s'", builtin_name, i + 1, x_str, p_str)
				return false
			}
		}
	}

	// Add runtime dependencies for ObjC blocks
	// C++ Reference: check_builtin.cpp L622-640
	add_package_dependency(ctx, "runtime", "_NSConcreteGlobalBlock")
	add_package_dependency(ctx, "runtime", "_NSConcreteStackBlock")

	// NOTE: Full implementation would create specialized Objc_Block(T) type
	// via check_polymorphic_record_type. For now, return rawptr which is
	// semantically compatible as a pointer type.
	operand.mode = .Value
	operand.type = t_rawptr
	return true
}

// check_builtin_objc_super handles objc_super() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:693-800
// Returns a reference to the superclass for method calls
check_builtin_objc_super :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "objc_super"

	// Platform validation: Objective-C intrinsics only work on Darwin platforms
	if !is_platform_darwin(ctx) {
		if ctx.info.build_context != nil {
			cmd := ctx.info.build_context.command_kind
			if .Doc not_in cmd && .Check not_in cmd {
				error_node(call, "'%s' only works on darwin", builtin_name)
				return false
			}
		}
	}

	// First argument should already be checked - must be a pointer to ObjC object
	if !is_type_pointer(operand.type) {
		error_node(operand.expr, "'%s' expected a pointer to an Objective-C object", builtin_name)
		return false
	}

	obj_type := type_deref(operand.type)
	if obj_type.kind != .Named {
		error_node(operand.expr, "'%s' expected a named type derived from objc_object", builtin_name)
		return false
	}

	if !has_type_got_objc_class_attribute(obj_type) {
		error_node(operand.expr, "'%s' expected a type with the @(objc_class=<string>) attribute", builtin_name)
		return false
	}

	if operand.mode != .Value && operand.mode != .Variable {
		error_node(operand.expr, "'%s' expression must be a value or variable", builtin_name)
		return false
	}

	// Look up the superclass type via objc_superclass attribute
	// C++ Reference: check_builtin.cpp L750-780
	superclass_type: ^Type = nil

	// Get the entity for the named type to access objc_superclass attribute
	if named, ok := obj_type.variant.(Type_Named); ok {
		if named.type_name != nil {
			if type_name_ent, ent_ok := named.type_name.variant.(Entity_Type_Name); ent_ok {
				superclass_type = type_name_ent.objc_superclass
			}
		}
	}

	if superclass_type == nil {
		// No superclass defined - this is an error for objc_super
		error_node(operand.expr, "'%s' type has no @(objc_superclass=...) attribute defined", builtin_name)
		return false
	}

	// Return a pointer to the superclass type
	// C++ Reference: check_builtin.cpp L785-795
	operand.mode = .Value
	operand.type = alloc_type_pointer(superclass_type)
	return true
}

// ============================================================================
// Advanced Reflection Builtins
// ============================================================================

// check_builtin_offset_of_impl handles offset_of() builtin (full implementation)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2682-2793
//
// Supports two forms:
//   - offset_of(value.field) -> uintptr
//   - offset_of(Type, field) -> uintptr
//
// Field can be a nested path: offset_of(MyStruct, nested.field.x)
check_builtin_offset_of_impl :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	// C++ Reference: check_builtin.cpp:2685-2732
	type: ^Type
	field_arg: ^ast.Expr

	arg_count := len(call.args)

	if arg_count == 1 {
		// Form 1: offset_of(value.field)
		// C++ Reference: check_builtin.cpp:2686-2709
		arg0 := unparen_expr(call.args[0])

		// Must be selector expression
		if sel, ok := arg0.derived.(^ast.Selector_Expr); ok {
			// Check the base expression
			x: Operand
			check_expr(ctx, &x, sel.expr)
			if x.mode == .Invalid {
				return false
			}

			type = type_deref(x.type)
			field_arg = sel.field
		} else {
			expr_str := expr_to_string(arg0)
			defer delete(expr_str)
			error_node(call.args[0], "Invalid expression for 'offset_of', '%s' is not a selector expression", expr_str)
			return false
		}

	} else if arg_count == 2 {
		// Form 2: offset_of(Type, field)
		// C++ Reference: check_builtin.cpp:2710-2720
		type = check_type(ctx, call.args[0])

		bt := base_type(type)
		if bt == nil || bt == t_invalid {
			error_node(call.args[0], "Expected a type for 'offset_of'")
			return false
		}

		field_arg_node := unparen_expr(call.args[1])
		// unparen_expr returns ^ast.Node, cast to ^ast.Expr
		field_arg = cast(^ast.Expr)field_arg_node

	} else {
		error_node(call, "Expected either 1 or 2 arguments to 'offset_of', in the format of 'offset_of(Type, field)' or 'offset_of(value.field)'")
		return false
	}

	assert(type != nil)

	// Extract field name from field_arg
	// C++ Reference: check_builtin.cpp:2721-2732
	field_name: string

	if field_arg == nil {
		error_node(call, "Expected an identifier for field argument")
		return false
	}

	if ident, ok := field_arg.derived.(^ast.Ident); ok {
		field_name = ident.name
	}

	if field_name == "" {
		error_node(field_arg, "Expected an identifier for field argument")
		return false
	}

	// Validate type is not array
	// C++ Reference: check_builtin.cpp:2734-2738
	if is_type_array(type) {
		type_str := type_to_string(type)
		error_node(field_arg, "Invalid a struct type for 'offset_of', got '%s'", type_str)
		return false
	}

	// Check for polymorphic/incomplete structs
	// C++ Reference: check_builtin.cpp:2808-2821
	bt := base_type(type)
	if bt.kind == .Struct {
		struc := bt.variant.(Type_Struct)

		// Only check if struct has a scope (is not completely uninitialized)
		// C++ Reference: check_builtin.cpp:2809
		if struc.scope != nil {
			if is_type_polymorphic(bt) {
				type_str := type_to_string(type)
				error_node(field_arg, "Cannot use 'offset_of' on an unspecialized polymorphic struct type, got '%s'", type_str)
				return false
			}

			// Check for incomplete struct declaration
			// C++ Reference: check_builtin.cpp:2815-2820
			// A struct is incomplete if it has no fields AND no AST node (forward declaration)
			if len(struc.fields) == 0 && struc.node == nil {
				type_str := type_to_string(type)
				error_node(field_arg, "Cannot use 'offset_of' on incomplete struct declaration, got '%s'", type_str)
				return false
			}
		}
	}

	// Look up the field
	// C++ Reference: check_builtin.cpp:2758-2776
	sel := lookup_field(type, field_name, false)
	if sel.entity == nil {
		type_str := type_to_string_shorthand(type)
		error_node(call.args[0], "'%s' has no field named '%s'", type_str, field_name)

		// C++ Reference: check_builtin.cpp:2777 - suggest similar field names
		suggest_bt := base_type(type)
		if suggest_bt != nil && suggest_bt.kind == .Struct {
			st := suggest_bt.variant.(Type_Struct)
			check_did_you_mean_type(field_name, st.fields[:])
		}

		return false
	}

	// Cannot use offset_of with indirect (pointer) field access
	// C++ Reference: check_builtin.cpp:2777-2783
	if sel.indirect {
		type_str := type_to_string_shorthand(type)
		error_node(call.args[0], "Field '%s' is embedded via a pointer in '%s'", field_name, type_str)
		return false
	}

	// Calculate offset and set result
	// C++ Reference: check_builtin.cpp:2785-2791
	operand.mode = .Constant
	operand.value = exact_value_i64(type_offset_of_from_selection(type, sel))
	operand.type = t_uintptr
	return true
}

// check_builtin_offset_of_by_string handles offset_of_by_string() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2795-2870
//
// Signature: offset_of_by_string(Type, field_name: string) -> uintptr
//
// Unlike offset_of, this variant takes the field name as a runtime string,
// allowing for dynamic field lookup.
check_builtin_offset_of_by_string :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	// Must have exactly 2 arguments
	// C++ Reference: check_builtin.cpp:2798-2812
	arg_count := len(call.args)
	if arg_count != 2 {
		error_node(call, "Expected 2 arguments to 'offset_of_by_string', in the format of 'offset_of_by_string(Type, field)'")
		return false
	}

	// Argument 0: Type
	// C++ Reference: check_builtin.cpp:2800-2809
	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'offset_of_by_string'")
		return false
	}

	// Argument 1: Field name (string constant)
	// C++ Reference: check_builtin.cpp:2813-2829
	field_arg := unparen_expr(call.args[1])
	field_name: string

	if field_arg == nil {
		error_node(call, "Expected a constant (non-empty) string for field argument")
		return false
	}

	x: Operand
	check_expr(ctx, &x, field_arg)

	// Must be constant string
	if x.mode == .Constant && is_type_string(x.type) {
		if str_val, ok := x.value.(string); ok {
			field_name = str_val
		}
	}

	if field_name == "" {
		error_node(field_arg, "Expected a constant (non-empty) string for field argument")
		return false
	}

	// Type cannot be array
	// C++ Reference: check_builtin.cpp:2831-2835
	if is_type_array(type) {
		type_str := type_to_string(type)
		error_node(field_arg, "Invalid a struct type for 'offset_of_by_string', got '%s'", type_str)
		return false
	}

	// Look up field
	// C++ Reference: check_builtin.cpp:2837-2856
	sel := lookup_field(type, field_name, false)
	if sel.entity == nil {
		type_str := type_to_string_shorthand(type)
		error_node(call.args[0], "'%s' has no field named '%s'", type_str, field_name)

		// C++ Reference: check_builtin.cpp - suggest similar field names
		suggest_bt := base_type(type)
		if suggest_bt != nil && suggest_bt.kind == .Struct {
			st := suggest_bt.variant.(Type_Struct)
			check_did_you_mean_type(field_name, st.fields[:])
		}

		return false
	}

	// Cannot use with indirect field access
	// C++ Reference: check_builtin.cpp:2857-2863
	if sel.indirect {
		type_str := type_to_string_shorthand(type)
		error_node(call.args[0], "Field '%s' is embedded via a pointer in '%s'", field_name, type_str)
		return false
	}

	// Calculate offset and return
	// C++ Reference: check_builtin.cpp:2865-2868
	operand.mode = .Constant
	operand.value = exact_value_i64(type_offset_of_from_selection(type, sel))
	operand.type = t_uintptr
	return true
}

// ============================================================================
// Complex Number Operations
// ============================================================================

// check_builtin_complex handles complex() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3078-3151
//
// Signature: complex(real, imag: float_type) -> complex_type
//
// Creates a complex number from real and imaginary parts.
check_builtin_complex :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	builtin_name := "complex"

	// Check first argument
	// C++ Reference: check_builtin.cpp:3080-3086
	x := operand^

	// Reset to invalid initially (C++ pattern)
	operand.type = t_invalid
	operand.mode = .Invalid

	// Check second argument
	y: Operand
	check_expr(ctx, &y, call.args[1])
	if y.mode == .Invalid {
		return false
	}

	// Convert both to common type
	// C++ Reference: check_builtin.cpp:3092-3104
	convert_to_typed(ctx, &x, y.type)
	if x.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	// If both constant, convert to float for proper handling
	if x.mode == .Constant && y.mode == .Constant {
		x.value = exact_value_to_float(x.value)
		y.value = exact_value_to_float(y.value)

		if is_type_numeric(x.type) && is_exact_value_float(x.value) {
			x.type = t_untyped_float
		}
		if is_type_numeric(y.type) && is_exact_value_float(y.value) {
			y.type = t_untyped_float
		}
	}

	// Validate types match
	// C++ Reference: check_builtin.cpp:3106-3113
	if !are_types_identical(x.type, y.type) {
		x_str := type_to_string(x.type)
		y_str := type_to_string(y.type)
		error_node(call, "Mismatched types to '%s', '%s' vs '%s'", builtin_name, x_str, y_str)
		return false
	}

	// Validate element type is float
	// C++ Reference: check_builtin.cpp:3115-3120
	if !is_type_float(x.type) {
		type_str := type_to_string(x.type)
		error_node(call, "Arguments have type '%s', expected a floating point", type_str)
		return false
	}

	// Check for endian-specific types (not allowed)
	// C++ Reference: check_builtin.cpp:3121-3126
	if is_type_endian_specific(x.type) {
		type_str := type_to_string(x.type)
		error_node(call, "Arguments with a specified endian are not allowed, expected a normal floating point, got '%s'", type_str)
		return false
	}

	// Set result mode and value
	// C++ Reference: check_builtin.cpp:3128-3135
	if x.mode == .Constant && y.mode == .Constant {
		r := exact_value_to_f64(x.value)
		i := exact_value_to_f64(y.value)
		operand.value = exact_value_complex(r, i)
		operand.mode = .Constant
	} else {
		operand.mode = .Value
	}

	// Determine result type based on float type
	// C++ Reference: check_builtin.cpp:3137-3144
	bt := core_type(x.type)
	kind := bt.variant.(Type_Basic).kind

	#partial switch kind {
	case .F16:
		operand.type = t_complex32
	case .F32:
		operand.type = t_complex64
	case .F64:
		operand.type = t_complex128
	case .Untyped_Float:
		operand.type = t_untyped_complex
	case:
		panic("Invalid float type for complex")
	}

	// Apply type hint if compatible
	// C++ Reference: check_builtin.cpp:3146-3148
	if type_hint != nil && check_is_castable_to(ctx, operand, type_hint) {
		operand.type = type_hint
	}

	return true
}

// check_builtin_real_imag handles real() and imag() builtins
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3352-3414
//
// Signature: real(x: complex_or_quaternion) -> float_type
//            imag(x: complex_or_quaternion) -> float_type
//
// Extracts the real or imaginary component of a complex/quaternion number.
check_builtin_real_imag :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id, type_hint: ^Type) -> bool {
	builtin_name := builtin_proc_infos[id].name
	_ = builtin_name // unused but kept for consistency

	// x is already checked as operand
	x := operand

	if x.type == nil {
		return false
	}

	// Handle untyped values
	// C++ Reference: check_builtin.cpp:3362-3378
	if is_type_untyped(x.type) {
		if x.mode == .Constant {
			if is_type_numeric(x.type) {
				x.type = t_untyped_complex
			}
		} else if is_type_quaternion(x.type) {
			convert_to_typed(ctx, x, t_quaternion256)
			if x.mode == .Invalid {
				return false
			}
		} else {
			convert_to_typed(ctx, x, t_complex128)
			if x.mode == .Invalid {
				return false
			}
		}
	}

	// Validate type is complex or quaternion
	// C++ Reference: check_builtin.cpp:3380-3385
	if !is_type_complex(x.type) && !is_type_quaternion(x.type) {
		type_str := type_to_string(x.type)
		error_node(call, "Argument has type '%s', expected a complex or quaternion type", type_str)
		return false
	}

	// Extract component value
	// C++ Reference: check_builtin.cpp:3387-3394
	if x.mode == .Constant {
		#partial switch id {
		case .Real:
			x.value = exact_value_real(x.value)
		case .Imag:
			x.value = exact_value_imag(x.value)
		}
	} else {
		x.mode = .Value
	}

	// Determine result type based on complex/quaternion type
	// C++ Reference: check_builtin.cpp:3396-3407
	bt := core_type(x.type)
	kind := bt.variant.(Type_Basic).kind

	#partial switch kind {
	case .Complex32:
		x.type = t_f16
	case .Complex64:
		x.type = t_f32
	case .Complex128:
		x.type = t_f64
	case .Quaternion64:
		x.type = t_f16
	case .Quaternion128:
		x.type = t_f32
	case .Quaternion256:
		x.type = t_f64
	case .Untyped_Complex:
		x.type = t_untyped_float
	case .Untyped_Quaternion:
		x.type = t_untyped_float
	case:
		panic("Invalid complex/quaternion type")
	}

	// Apply type hint if compatible
	// C++ Reference: check_builtin.cpp:3409-3411
	if type_hint != nil && check_is_castable_to(ctx, operand, type_hint) {
		operand.type = type_hint
	}

	return true
}

// check_builtin_conj handles conj() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3472-3516
//
// Signature: conj(x: complex_or_quaternion_or_array_thereof) -> same_type
//
// Returns the complex conjugate (negates imaginary parts).
check_builtin_conj :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "conj"
	_ = builtin_name // unused but kept for consistency

	// x is already checked as operand
	x := operand

	if x.type == nil {
		return false
	}

	t := x.type
	elem := core_array_type(t)

	// Handle complex conjugate
	// C++ Reference: check_builtin.cpp:3482-3491
	if is_type_complex(t) {
		if x.mode == .Constant {
			v := exact_value_to_complex(x.value).(complex128)
			r := real(v)
			i := -imag(v)
			x.value = exact_value_complex(r, i)
			x.mode = .Constant
		} else {
			x.mode = .Value
		}
		return true
	}

	// Handle quaternion conjugate
	// C++ Reference: check_builtin.cpp:3492-3503
	if is_type_quaternion(t) {
		if x.mode == .Constant {
			v := exact_value_to_quaternion(x.value).(quaternion256)
			r := +real(v)
			i := -imag(v)
			j := -jmag(v)
			k := -kmag(v)
			x.value = exact_value_quaternion(r, i, j, k)
			x.mode = .Constant
		} else {
			x.mode = .Value
		}
		return true
	}

	// Handle arrays and matrices of complex/quaternion
	// C++ Reference: check_builtin.cpp:3504-3507
	if is_type_array_like(t) && (is_type_complex(elem) || is_type_quaternion(elem)) {
		x.mode = .Value
		return true
	}

	if is_type_matrix(t) && (is_type_complex(elem) || is_type_quaternion(elem)) {
		x.mode = .Value
		return true
	}

	// Invalid type
	// C++ Reference: check_builtin.cpp:3508-3513
	type_str := type_to_string(x.type)
	error_node(call, "Expected a complex or quaternion, got '%s'", type_str)
	return false
}

// ============================================================================
// Swizzle Operation
// ============================================================================

// check_builtin_swizzle handles swizzle() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:2992-3076
//
// Signature: swizzle(v: [N]T, ..int) -> [M]T
//
// Reorders elements of an array or SIMD vector by index.
check_builtin_swizzle :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	builtin_name := "swizzle"

	// C++ Reference: check_builtin.cpp:3410-3414. args[0] is already checked into `operand` by
	// the prologue's default arm; C++ only guards on the result here.
	if operand.type == nil {
		return false
	}

	original_type := operand.type
	type := base_type(original_type)
	max_count: i64 = 0
	elem_type: ^Type = nil

	// Validate type is array or SIMD vector
	// C++ Reference: check_builtin.cpp:3003-3017
	if !is_type_array(type) && !is_type_simd_vector(type) {
		type_str := type_to_string(operand.type)
		error_node(call, "'%s' is only allowed on an array or #simd vector, got '%s'", builtin_name, type_str)
		return false
	}

	if type.kind == .Array {
		arr := type.variant.(Type_Array)
		max_count = arr.count
		elem_type = arr.elem
	} else if type.kind == .Simd_Vector {
		simd := type.variant.(Type_Simd_Vector)
		max_count = simd.count
		elem_type = simd.elem
	}

	// Validate index arguments (variadic, starting from arg 1)
	// C++ Reference: check_builtin.cpp:3019-3049
	arg_count: i64 = 0
	for i in 1 ..< len(call.args) {
		op: Operand
		check_expr(ctx, &op, call.args[i])
		if op.mode == .Invalid {
			return false
		}

		arg_type := base_type(op.type)
		if !is_type_integer(arg_type) || op.mode != .Constant {
			error_node(op.expr, "Indices to '%s' must be constant integers", builtin_name)
			return false
		}

		// Check index is non-negative
		if exact_value_is_negative(op.value) {
			error_node(op.expr, "Negative '%s' index", builtin_name)
			return false
		}

		// Check index is in range
		idx_val := exact_value_to_i64(op.value)
		if idx_val >= max_count {
			error_node(op.expr, "'%s' index exceeds length", builtin_name)
			return false
		}

		arg_count += 1
	}

	// Validate index count
	// C++ Reference: check_builtin.cpp:3054-3057
	if arg_count < 2 {
		error_node(call, "Not enough '%s' indices, %d < 2", builtin_name, arg_count)
		return false
	}

	// Set addressing mode
	// C++ Reference: check_builtin.cpp:3059-3067
	if type.kind == .Array {
		if operand.mode == .Variable {
			operand.mode = .Swizzle_Variable
		} else {
			operand.mode = .Swizzle_Value
		}
	} else {
		operand.mode = .Value
	}

	// For SIMD vectors, arg count must be power of two
	// C++ Reference: check_builtin.cpp:3069-3072
	if is_type_simd_vector(type) {
		if !is_power_of_two(arg_count) {
			error_node(call, "'%s' with a #simd vector must have a power of two arguments, got %d", builtin_name, arg_count)
			return false
		}
	}

	// Determine result type
	// C++ Reference: check_builtin.cpp:3074
	operand.type = determine_swizzle_array_type(original_type, type_hint, arg_count)
	return true
}

// ============================================================================
// Numeric Utility Operations (min, max, abs, clamp)
// ============================================================================

// check_builtin_min handles min() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3744-3919
//
// Two forms:
//   - min(Type) -> returns minimum value of type
//   - min(a, b, ...) -> returns minimum of arguments (variadic)
check_builtin_min :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "min"

	// Check first argument (could be type or expression)
	// C++ Reference: check_builtin.cpp:3748
	check_multi_expr_or_type(ctx, operand, call.args[0])

	if operand.type == nil {
		return false
	}

	original_type := operand.type
	type := base_type(operand.type)

	// Validate type is ordered
	// C++ Reference: check_builtin.cpp:3757-3764
	if operand.mode == .Type && is_type_enumerated_array(type) {
		// Enumerated arrays are allowed
	} else if !is_type_ordered(type) || !(is_type_numeric(type) || is_type_string(type)) {
		type_str := type_to_string(original_type)
		error_node(call, "Expected an ordered numeric type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	// Form 1: min(Type) - return minimum value of type
	// C++ Reference: check_builtin.cpp:3766-3827
	if operand.mode == .Type {
		if len(call.args) != 1 {
			error_node(call, "If '%s' gets a type, only 1 argument is allowed, got %d", builtin_name, len(call.args))
			return false
		}

		// Boolean min: false
		if is_type_boolean(type) {
			operand.mode = .Constant
			operand.type = original_type
			operand.value = exact_value_bool(false)
			return true
		}

		// Integer min
		if is_type_integer(type) {
			operand.mode = .Constant
			operand.type = original_type

			if is_type_unsigned(type) {
				// Unsigned: 0
				operand.value = exact_value_u64(0)
			} else {
				// Signed: -2^(bits-1)
				sz := i64(8 * type_size_of(type))
				a := exact_value_i64(1)
				b := exact_value_i64(sz - 1)
				v := exact_binary_operator_value(.Shl, a, b)
				v = exact_unary_operator_value(.Sub, v, i32(sz), false)
				operand.value = v
			}
			return true
		}

		// Float min
		if is_type_float(type) {
			operand.mode = .Constant
			operand.type = original_type

			size := type_size_of(type)
			switch size {
			case 2:
				// f16
				operand.value = exact_value_float(-65504.0)
			case 4:
				// f32
				operand.value = exact_value_float(-3.402823466e+38)
			case 8:
				// f64
				operand.value = exact_value_float(-1.7976931348623158e+308)
			case:
				panic("Unhandled float type size")
			}
			return true
		}

		// Enum min
		if is_type_enum(type) {
			te := type.variant.(Type_Enum)
			operand.mode = .Constant
			operand.type = original_type
			operand.value = te.min_value
			return true
		}

		// Enumerated array min
		if is_type_enumerated_array(type) {
			bt := base_type(type)
			ea := bt.variant.(Type_Enumerated_Array)
			// Get min_value from the index enum type
			index_bt := base_type(ea.index)
			if index_enum, ok := index_bt.variant.(Type_Enum); ok {
				operand.mode = .Constant
				operand.type = ea.index
				operand.value = index_enum.min_value
				return true
			}
		}

		type_str := type_to_string(original_type)
		error_node(call, "Invalid type for '%s', got %s", builtin_name, type_str)
		return false
	}

	// Form 2: min(a, b, ...) - variadic min
	// C++ Reference: check_builtin.cpp:3829-3917
	if len(call.args) <= 1 {
		error_node(call, "Too few arguments for '%s', two or more are required", builtin_name)
		return false
	}

	all_constant := operand.mode == .Constant

	// Collect all operands
	operands := make([dynamic]Operand, 0, len(call.args), context.temp_allocator)
	append(&operands, operand^)

	for i in 1 ..< len(call.args) {
		b: Operand
		check_expr(ctx, &b, call.args[i])
		if b.mode == .Invalid {
			return false
		}

		if !is_type_ordered(b.type) || !(is_type_numeric(b.type) || is_type_string(b.type)) {
			type_str := type_to_string(b.type)
			error_node(call, "Expected an ordered numeric type to '%s', got '%s'", builtin_name, type_str)
			return false
		}

		append(&operands, b)

		if all_constant {
			all_constant = b.mode == .Constant
		}
	}

	// Constant folding: compute min at compile time
	if all_constant {
		// First, check that all types are compatible
		for i in 0 ..< len(operands) - 1 {
			a := &operands[i]
			b := &operands[i + 1]

			// Convert untyped to common type for comparison
			convert_to_typed(ctx, a, b.type)
			if a.mode == .Invalid {
				return false
			}
			convert_to_typed(ctx, b, a.type)
			if b.mode == .Invalid {
				return false
			}

			if !are_types_identical(base_type(a.type), base_type(b.type)) {
				type_a := type_to_string(a.type)
				type_b := type_to_string(b.type)
				error_node(call, "Mismatched types to '%s', '%s' vs '%s'", builtin_name, type_a, type_b)
				return false
			}
		}

		value := operands[0].value
		result_type := operands[0].type

		for i in 1 ..< len(operands) {
			y := operands[i]
			// If value < y.value, keep value; otherwise use y
			if !compare_exact_values(.Lt, value, y.value) {
				value = y.value
				result_type = y.type
			}
		}

		operand.value = value
		operand.type = result_type
		return true
	}

	// Runtime: ensure all types are compatible
	operand.mode = .Value
	operand.type = original_type

	// Convert all operands to common type
	for i in 0 ..< len(operands) {
		a := &operands[i]
		for j in 0 ..< len(operands) {
			if i == j do continue

			b := &operands[j]
			convert_to_typed(ctx, a, b.type)
			if a.mode == .Invalid {
				return false
			}
			convert_to_typed(ctx, b, a.type)
			if b.mode == .Invalid {
				return false
			}
		}
	}

	// Verify all types match
	for i in 0 ..< len(operands) - 1 {
		a := &operands[i]
		b := &operands[i + 1]

		if !are_types_identical(a.type, b.type) {
			type_a := type_to_string(a.type)
			type_b := type_to_string(b.type)
			error_node(a.expr, "Mismatched types to '%s', '%s' vs '%s'", builtin_name, type_a, type_b)
			return false
		}
	}

	operand.type = operands[0].type
	return true
}

// check_builtin_max handles max() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:3921-4102
//
// Two forms:
//   - max(Type) -> returns maximum value of type
//   - max(a, b, ...) -> returns maximum of arguments (variadic)
check_builtin_max :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "max"

	// Check first argument (could be type or expression)
	// C++ Reference: check_builtin.cpp:3925
	check_multi_expr_or_type(ctx, operand, call.args[0])

	if operand.type == nil {
		return false
	}

	original_type := operand.type
	type := base_type(operand.type)

	// Validate type is ordered
	// C++ Reference: check_builtin.cpp:3934-3941
	if operand.mode == .Type && is_type_enumerated_array(type) {
		// Enumerated arrays are allowed
	} else if !is_type_ordered(type) || !(is_type_numeric(type) || is_type_string(type)) {
		type_str := type_to_string(original_type)
		error_node(call, "Expected an ordered numeric type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	// Form 1: max(Type) - return maximum value of type
	// C++ Reference: check_builtin.cpp:3943-4008
	if operand.mode == .Type {
		if len(call.args) != 1 {
			error_node(call, "If '%s' gets a type, only 1 argument is allowed, got %d", builtin_name, len(call.args))
			return false
		}

		// Boolean max: true
		if is_type_boolean(type) {
			operand.mode = .Constant
			operand.type = original_type
			operand.value = exact_value_bool(true)
			return true
		}

		// Integer max
		if is_type_integer(type) {
			operand.mode = .Constant
			operand.type = original_type

			sz := i64(8 * type_size_of(type))
			a := exact_value_i64(1)

			if is_type_unsigned(type) {
				// Unsigned: 2^bits - 1
				b := exact_value_i64(sz)
				v := exact_binary_operator_value(.Shl, a, b)
				v = exact_binary_operator_value(.Sub, v, a)
				operand.value = v
			} else {
				// Signed: 2^(bits-1) - 1
				b := exact_value_i64(sz - 1)
				v := exact_binary_operator_value(.Shl, a, b)
				v = exact_binary_operator_value(.Sub, v, a)
				operand.value = v
			}
			return true
		}

		// Float max
		if is_type_float(type) {
			operand.mode = .Constant
			operand.type = original_type

			size := type_size_of(type)
			switch size {
			case 2:
				// f16
				operand.value = exact_value_float(65504.0)
			case 4:
				// f32
				operand.value = exact_value_float(3.402823466e+38)
			case 8:
				// f64
				operand.value = exact_value_float(1.7976931348623158e+308)
			case:
				panic("Unhandled float type size")
			}
			return true
		}

		// Enum max
		if is_type_enum(type) {
			te := type.variant.(Type_Enum)
			operand.mode = .Constant
			operand.type = original_type
			operand.value = te.max_value
			return true
		}

		// Enumerated array max
		if is_type_enumerated_array(type) {
			bt := base_type(type)
			ea := bt.variant.(Type_Enumerated_Array)
			// Get max_value from the index enum type
			index_bt := base_type(ea.index)
			if index_enum, ok := index_bt.variant.(Type_Enum); ok {
				operand.mode = .Constant
				operand.type = ea.index
				operand.value = index_enum.max_value
				return true
			}
		}

		type_str := type_to_string(original_type)
		error_node(call, "Invalid type for '%s', got %s", builtin_name, type_str)
		return false
	}

	// Form 2: max(a, b, ...) - variadic max
	// C++ Reference: check_builtin.cpp:4011-4100
	if len(call.args) <= 1 {
		error_node(call, "Too few arguments for '%s', two or more are required", builtin_name)
		return false
	}

	all_constant := operand.mode == .Constant

	// Collect all operands
	operands := make([dynamic]Operand, 0, len(call.args), context.temp_allocator)
	append(&operands, operand^)

	for i in 1 ..< len(call.args) {
		b: Operand
		check_expr(ctx, &b, call.args[i])
		if b.mode == .Invalid {
			return false
		}

		if !is_type_ordered(b.type) || !(is_type_numeric(b.type) || is_type_string(b.type)) {
			type_str := type_to_string(b.type)
			error_node(call, "Expected an ordered numeric type to '%s', got '%s'", builtin_name, type_str)
			return false
		}

		append(&operands, b)

		if all_constant {
			all_constant = b.mode == .Constant
		}
	}

	// Constant folding: compute max at compile time
	if all_constant {
		// First, check that all types are compatible
		for i in 0 ..< len(operands) - 1 {
			a := &operands[i]
			b := &operands[i + 1]

			// Convert untyped to common type for comparison
			convert_to_typed(ctx, a, b.type)
			if a.mode == .Invalid {
				return false
			}
			convert_to_typed(ctx, b, a.type)
			if b.mode == .Invalid {
				return false
			}

			if !are_types_identical(base_type(a.type), base_type(b.type)) {
				type_a := type_to_string(a.type)
				type_b := type_to_string(b.type)
				error_node(call, "Mismatched types to '%s', '%s' vs '%s'", builtin_name, type_a, type_b)
				return false
			}
		}

		value := operands[0].value
		result_type := operands[0].type

		for i in 1 ..< len(operands) {
			y := operands[i]
			// If value > y.value, keep value; otherwise use y
			if !compare_exact_values(.Gt, value, y.value) {
				value = y.value
				result_type = y.type
			}
		}

		operand.value = value
		operand.type = result_type
		return true
	}

	// Runtime: ensure all types are compatible
	operand.mode = .Value
	operand.type = original_type

	// Convert all operands to common type
	for i in 0 ..< len(operands) {
		a := &operands[i]
		for j in 0 ..< len(operands) {
			if i == j do continue

			b := &operands[j]
			convert_to_typed(ctx, a, b.type)
			if a.mode == .Invalid {
				return false
			}
			convert_to_typed(ctx, b, a.type)
			if b.mode == .Invalid {
				return false
			}
		}
	}

	// Verify all types match
	for i in 0 ..< len(operands) - 1 {
		a := &operands[i]
		b := &operands[i + 1]

		if !are_types_identical(a.type, b.type) {
			type_a := type_to_string(a.type)
			type_b := type_to_string(b.type)
			error_node(a.expr, "Mismatched types to '%s', '%s' vs '%s'", builtin_name, type_a, type_b)
			return false
		}
	}

	operand.type = operands[0].type
	return true
}

// check_builtin_abs handles abs() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:4104-4164
//
// Signature: abs(n: numeric) -> numeric
//
// Returns absolute value. For complex/quaternion, returns magnitude.
check_builtin_abs :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "abs"

	if operand.type == nil {
		return false
	}

	// Validate type is numeric (but not array)
	// C++ Reference: check_builtin.cpp:4110-4115
	if !(is_type_numeric(operand.type) && !is_type_array(operand.type)) {
		type_str := type_to_string(operand.type)
		error_node(call, "Expected a numeric type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	// Constant folding
	// C++ Reference: check_builtin.cpp:4117-4146
	if operand.mode == .Constant {
		#partial switch &v in operand.value {
		case big.Int:
			// Integer: absolute value using big.int_abs
			// C++ Reference: check_builtin.cpp:4120 - mp_abs(&operand->value.value_integer, ...)
			// Note: big.int_abs modifies in place
			result: big.Int
			big.int_abs(&result, &v)
			operand.value = result

		case f64:
			// Float: clear sign bit
			bits := transmute(u64)v
			bits &= 0x7FFFFFFFFFFFFFFF
			operand.value = transmute(f64)bits

		case complex128:
			// Complex: magnitude sqrt(r^2 + i^2)
			r := real(v)
			i := imag(v)
			operand.value = exact_value_float(math.sqrt(r * r + i * i))

		case quaternion256:
			// Quaternion: magnitude sqrt(r^2 + i^2 + j^2 + k^2)
			r := real(v)
			i := imag(v)
			j := jmag(v)
			k := kmag(v)
			operand.value = exact_value_float(math.sqrt(r * r + i * i + j * j + k * k))

		case:
			panic("Invalid numeric constant for abs")
		}
	} else {
		operand.mode = .Value

		// Add runtime dependencies for complex/quaternion abs
		// C++ Reference: check_builtin.cpp:4149-4156
		bt := base_type(operand.type)
		if are_types_identical(bt, t_complex64) {
			add_package_dependency(ctx, "runtime", "abs_complex64")
		}
		if are_types_identical(bt, t_complex128) {
			add_package_dependency(ctx, "runtime", "abs_complex128")
		}
		if are_types_identical(bt, t_quaternion128) {
			add_package_dependency(ctx, "runtime", "abs_quaternion128")
		}
		if are_types_identical(bt, t_quaternion256) {
			add_package_dependency(ctx, "runtime", "abs_quaternion256")
		}
	}

	// For complex/quaternion, result is the float component type
	// C++ Reference: check_builtin.cpp:4158-4161
	if is_type_complex_or_quaternion(operand.type) {
		operand.type = base_complex_elem_type(operand.type)
	}

	assert(!is_type_complex_or_quaternion(operand.type))
	return true
}

// check_builtin_clamp handles clamp() builtin
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:4166-4258
//
// Signature: clamp(value, min, max: ordered) -> ordered
//
// Returns value clamped between min and max.
check_builtin_clamp :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "clamp"

	if operand.type == nil {
		return false
	}

	type := operand.type

	// Validate first argument is ordered numeric or string
	// C++ Reference: check_builtin.cpp:4172-4178
	if !is_type_ordered(type) || !(is_type_numeric(type) || is_type_string(type)) {
		type_str := type_to_string(operand.type)
		error_node(call, "Expected an ordered numeric or string type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	// Check min and max arguments
	// C++ Reference: check_builtin.cpp:4180-4206
	min_arg := call.args[1]
	max_arg := call.args[2]

	x := operand^
	y: Operand
	z: Operand

	check_expr(ctx, &y, min_arg)
	if y.mode == .Invalid {
		return false
	}
	if !is_type_ordered(y.type) || !(is_type_numeric(y.type) || is_type_string(y.type)) {
		type_str := type_to_string(y.type)
		error_node(call, "Expected an ordered numeric or string type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	check_expr(ctx, &z, max_arg)
	if z.mode == .Invalid {
		return false
	}
	if !is_type_ordered(z.type) || !(is_type_numeric(z.type) || is_type_string(z.type)) {
		type_str := type_to_string(z.type)
		error_node(call, "Expected an ordered numeric or string type to '%s', got '%s'", builtin_name, type_str)
		return false
	}

	// Constant folding
	// C++ Reference: check_builtin.cpp:4208-4226
	if x.mode == .Constant && y.mode == .Constant && z.mode == .Constant {
		a := x.value
		b := y.value
		c := z.value

		operand.mode = .Constant

		// If value < min, return min
		if compare_exact_values(.Lt, a, b) {
			operand.value = b
			operand.type = y.type
			// Else if value > max, return max
		} else if compare_exact_values(.Gt, a, c) {
			operand.value = c
			operand.type = z.type
			// Else return value
		} else {
			operand.value = a
			operand.type = x.type
		}
		return true
	}

	// Runtime: ensure all types are compatible
	// C++ Reference: check_builtin.cpp:4227-4254
	operand.mode = .Value
	operand.type = type

	ops := [3]^Operand{&x, &y, &z}

	// Convert all to common type
	for i in 0 ..< 3 {
		a := ops[i]
		for j in 0 ..< 3 {
			if i == j do continue
			b := ops[j]

			convert_to_typed(ctx, a, b.type)
			if a.mode == .Invalid {
				return false
			}
		}
	}

	// Verify all types match
	if !are_types_identical(x.type, y.type) || !are_types_identical(x.type, z.type) {
		type_x := type_to_string(x.type)
		type_y := type_to_string(y.type)
		type_z := type_to_string(z.type)
		error_node(call, "Mismatched types to '%s', '%s', '%s', '%s'", builtin_name, type_x, type_y, type_z)
		return false
	}

	operand.type = ops[0].type
	return true
}

// check_builtin_procedure_directive handles special directive-based builtin procedures
// like #caller_expression, #location, etc.
// Reference: /mnt/c/odin/src/check_builtin.cpp:2089-2175
//
// Implemented directives:
// - #caller_expression: Returns the source code string of an expression
// - #location: Returns Source_Code_Location for an entity
// - #exists: Checks if a file exists
// - #config: Returns compile-time configuration values
// - #defined: Checks if an identifier is defined
// - #assert: Compile-time assertion
// - #panic: Compile-time panic
//
// Note: #load directive is handled separately in check_load_directive (check_expr.odin)
check_builtin_procedure_directive :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Node, type_hint: ^Type) -> bool {
	// C++ Reference: check_builtin.cpp:2089-2175

	call_expr, ok := call.derived.(^ast.Call_Expr)
	if !ok {
		return false
	}

	basic_dir, ok2 := call_expr.expr.derived.(^ast.Basic_Directive)
	if !ok2 {
		return false
	}

	name := basic_dir.name

	if name == "caller_expression" {
		// Validate argument count
		if len(call_expr.args) > 1 {
			error(call_expr.args[0], "'#caller_expression' expects either 0 or 1 arguments, got %d", len(call_expr.args))
		}

		// Validate that the argument is a valid earlier parameter
		// C++ Reference: check_builtin.cpp:2117-2128
		if len(call_expr.args) > 0 {
			arg := call_expr.args[0]
			ident, is_ident := arg.derived.(^ast.Ident)
			if !is_ident {
				error(arg, "'#caller_expression' expected an identifier")
			} else {
				o: Operand
				e := check_ident(ctx, &o, arg, nil, nil, true)
				if e == nil || .Param not_in e.flags {
					error(arg, "'#caller_expression' expected a valid earlier parameter name")
				}
			}
			_ = ident
		}

		operand.type = t_string
		operand.mode = .Value
		return true
	}

	if name == "location" {
		// #location directive - returns Source_Code_Location
		// C++ Reference: check_builtin.cpp:2093-2112
		if len(call_expr.args) > 1 {
			error(call_expr.args[0], "'#location' expects either 0 or 1 arguments, got %d", len(call_expr.args))
		}

		// Check argument if present
		if len(call_expr.args) > 0 {
			arg := call_expr.args[0]
			arg_op: Operand
			check_expr(ctx, &arg_op, arg)
			// Argument should be an entity reference
		}

		// Return Source_Code_Location type
		loc_type := ctx.info.cached_source_code_location
		if loc_type != nil {
			operand.type = loc_type
			operand.mode = .Value
			return true
		}

		// Fallback if type not loaded
		error(call_expr.expr, "'#location' requires core:runtime to be imported")
		return false
	}

	if name == "exists" {
		if len(call_expr.args) != 1 {
			error(call_expr.close, "'#exists' expects 1 argument, got %d", len(call_expr.args))
			return false
		}

		o: Operand
		check_expr(ctx, &o, call_expr.args[0])
		if o.mode != .Constant || !is_type_string(o.type) {
			error(call_expr.args[0], "'#exists' expected a constant string argument")
			return false
		}

		original_path, is_str := o.value.(string)
		if !is_str {
			error(call_expr.args[0], "'#exists' expected a constant string for file path")
			return false
		}

		// Check if file exists using cache
		cache, _ := cache_load_file_directive(ctx, call, original_path, false, .Exists)

		operand.type = t_untyped_bool
		operand.mode = .Constant
		operand.value = cache != nil && cache.exists
		return true
	}

	if name == "config" {
		// #config(name, default_value) - compile-time configuration
		// C++ Reference: check_builtin.cpp:2130-2175
		if len(call_expr.args) != 2 {
			error(call_expr.close, "'#config' expects 2 arguments: name and default value, got %d", len(call_expr.args))
			return false
		}

		// First argument must be an identifier (config name) - gets used as string
		// C++ Reference: check_builtin.cpp:2725-2729
		config_name: string
		if ident, is_ident := unparen_expr(call_expr.args[0]).derived.(^ast.Ident); is_ident {
			config_name = ident.name
		} else {
			error(call_expr.args[0], "'#config' first argument must be an identifier (config name)")
			return false
		}

		// Second argument is the default value.
		// C++ Reference: check_builtin.cpp:2731-2738
		default_op: Operand
		check_expr(ctx, &default_op, unparen_expr(call_expr.args[1]))
		if default_op.mode != .Constant {
			error(call_expr.args[1], "'#config' default value must be a constant")
			return false
		}

		// C++ Reference: check_builtin.cpp:2744-2757
		//
		// The default's type is carried through AS IS - notably NOT through
		// default_type(). `FD_SETSIZE :: #config(POSIX_FD_SETSIZE, 1024)` has to
		// stay `untyped integer` so it still compares against a distinct type
		// like posix's `FD :: distinct c.int`; defaulting it to `int` makes
		// every such comparison a type mismatch.
		operand.type = default_op.type
		operand.mode = default_op.mode
		operand.value = default_op.value

		// An explicitly defined value overrides the default, carrying its own type.
		if defined_value, found := build_context.defined_values[config_name]; found {
			operand.mode = .Constant
			operand.value = defined_value
		}
		return true
	}

	if name == "defined" {
		// #defined(identifier) - checks if an identifier is defined
		// C++ Reference: check_builtin.cpp related to defined checks
		if len(call_expr.args) != 1 {
			error(call_expr.close, "'#defined' expects 1 argument, got %d", len(call_expr.args))
			return false
		}

		// C++ Reference: check_builtin.cpp:2691-2706
		//
		// The argument may be an identifier OR a selector expression, and it must
		// be looked up WITHOUT being checked - `#defined(X)` exists precisely to
		// ask about names that may not be declared, so resolving it through
		// check_ident would emit "Undeclared name" for every false answer.
		arg := unparen_expr(call_expr.args[0])
		is_ident: bool
		is_sel: bool
		_, is_ident = arg.derived.(^ast.Ident)
		_, is_sel = arg.derived.(^ast.Selector_Expr)
		if !is_ident && !is_sel {
			// C++ Reference: check_builtin.cpp:2693 -- names the node kind that was found,
			// and reports against the CALL, not the argument.
			error(call_expr, "'#defined' expects an identifier or selector expression, got %s", ast_kind_string(arg))
			return false
		}

		if ctx.curr_proc_decl == nil {
			error(call_expr, "'#defined' is only allowed within a procedure, prefer the replacement '#config(NAME, default_value)'")
			return false
		}

		operand.type = t_untyped_bool
		operand.mode = .Constant
		operand.value = check_identifier_exists(ctx.scope, arg)
		return true
	}

	if name == "assert" {
		// #assert(condition, message?) - compile-time assertion
		// C++ Reference: check_builtin.cpp assertion handling
		if len(call_expr.args) < 1 || len(call_expr.args) > 2 {
			error(call_expr.close, "'#assert' expects 1 or 2 arguments, got %d", len(call_expr.args))
			return false
		}

		// First argument must be a constant boolean condition
		cond_op: Operand
		check_expr(ctx, &cond_op, call_expr.args[0])
		if cond_op.mode != .Constant {
			error(call_expr.args[0], "'#assert' condition must be a constant expression")
			return false
		}

		cond_val := exact_value_to_bool(cond_op.value)
		if !cond_val {
			// C++ Reference: check_builtin.cpp:2638-2649. C++ prints the CONDITION EXPRESSION,
			// not the word "failed", and in the two-argument form appends the second argument
			// in parentheses. The port printed "Compile-time assertion failed" -- a hyphen C++
			// does not use, and no condition at all.
			//
			// STALE COMMENT REMOVED (LEDGER task 269): this used to say the ERROR_BLOCK and
			// the "Called within" continuation were NOT reproduced, because attempting them
			// "swallowed EVERY subsequent diagnostic in the package (see LEDGER task 230)".
			// Task 230's diagnosis was RETRACTED in task 231 -- the abort was a delete() on a
			// type_to_string result in the probe harness, not a block/continuation problem --
			// and the continuation was implemented at some point after. The comment sat
			// directly above the working code claiming it did not exist. Verified against the
			// oracle: single-argument, two-argument and file-scope forms all match.
			// C++ Reference: check_builtin.cpp:2639 ERROR_BLOCK() -- keeps the continuation
			// line attached to this error instead of being flushed ahead of it.
			begin_error_block()
			defer end_error_block()
			defer if ctx.proc_name != "" {
				// NOTE: deliberately NOT `delete`d -- see the #panic arm below.
				sig := type_to_string(ctx.curr_proc_sig)
				error_line("\tCalled within '%s' :: %s\n", ctx.proc_name, sig)
			}
			arg1 := expr_to_string(call_expr.args[0])
			defer delete(arg1)
			if len(call_expr.args) == 1 {
				error(call_expr.expr, "Compile time assertion: %s", arg1)
			} else {
				arg2 := expr_to_string(call_expr.args[1])
				defer delete(arg2)
				error(call_expr.expr, "Compile time assertion: %s (%s)", arg1, arg2)
			}
		}

		// #assert returns nothing (no value)
		operand.mode = .No_Value
		return true
	}

	if name == "panic" {
		// #panic(message?) - compile-time panic
		// C++ Reference: check_builtin.cpp:2664-2686. ERROR_BLOCK() spans the WHOLE arm there,
		// so the "Called within" continuation stays attached to the panic error. Without it the
		// buffered `error` and the immediate `error_line` come out in the wrong order and the
		// continuation prints BEFORE the diagnostic it belongs to.
		begin_error_block()
		defer end_error_block()
		if len(call_expr.args) > 1 {
			error(call_expr.close, "'#panic' expects 0 or 1 arguments, got %d", len(call_expr.args))
			return false
		}

		// Get message if provided
		if len(call_expr.args) == 1 {
			msg_op: Operand
			check_expr(ctx, &msg_op, call_expr.args[0])
			if msg_op.mode == .Constant {
				if str, is_str := msg_op.value.(string); is_str {
					error(call_expr.expr, "Compile time panic: %s", str)  // C++ check_builtin.cpp:2677 -- no hyphen
				} else {
					error(call_expr.expr, "Compile time panic")
				}
			} else {
				error(call_expr.expr, "Compile time panic")
			}
		} else {
			error(call_expr.expr, "Compile time panic")
		}

		// C++ Reference: check_builtin.cpp:2678-2682 -- same continuation as #assert.
		// NOTE: no `delete` on the type_to_string result. type_to_string does not always
		// return freshly-allocated storage, and freeing it aborts with
		// "free(): invalid pointer" (LEDGER tasks 192 and 231).
		if ctx.proc_name != "" {
			sig := type_to_string(ctx.curr_proc_sig)
			error_line("\tCalled within '%s' :: %s\n", ctx.proc_name, sig)
		}

		// #panic diverges (never returns)
		operand.mode = .No_Value
		return true
	}

	// Check for #load directive
	if name == "load" {
		// #load(path, [type]) - load file contents at compile time
		// C++ Reference: check_builtin.cpp:1820-1880
		if len(call_expr.args) < 1 || len(call_expr.args) > 2 {
			error(call_expr.close, "'#load' expects 1 or 2 arguments, got %d", len(call_expr.args))
			return false
		}

		// First argument must be a constant string (file path)
		path_op: Operand
		check_expr(ctx, &path_op, call_expr.args[0])
		if path_op.mode != .Constant || !is_type_string(path_op.type) {
			error(call_expr.args[0], "'#load' first argument must be a constant string (file path)")
			return false
		}

		original_path, is_str := path_op.value.(string)
		if !is_str {
			error(call_expr.args[0], "'#load' expected a constant string for file path")
			return false
		}

		// Determine result type (default is []u8)
		result_type := t_u8_slice
		if len(call_expr.args) == 1 {
			if type_hint != nil && is_valid_type_for_load(type_hint) {
				result_type = type_hint
			}
		} else if len(call_expr.args) == 2 {
			load_type := check_type(ctx, call_expr.args[1])
			if load_type != nil {
				if is_valid_type_for_load(load_type) {
					result_type = load_type
				} else {
					error(call_expr.args[1], "'#load' invalid type, expected a string or slice of simple types")
				}
			}
		}

		// Load the file
		cache, load_ok := cache_load_file_directive(ctx, call, original_path, true, .Contents)
		if load_ok && cache != nil {
			operand.type = result_type
			operand.mode = .Constant
			operand.value = string(cache.data)
			return true
		}

		// File not found - set directive was false flag
		call.state_flags += {.Directive_Was_False}
		return false
	}

	return false
}

// ======================================================================================
// FILE LOADING CACHE SYSTEM
// ======================================================================================

// cache_load_file_directive loads a file and caches the result
// C++ Reference: check_builtin.cpp:1669-1770
cache_load_file_directive :: proc(
	ctx: ^Checker_Context,
	call: ^ast.Node,
	original_path: string,
	err_on_not_found: bool,
	tier: Load_File_Tier,
) -> (cache: ^Load_File_Cache, ok: bool) {
	// Determine full path
	path: string
	if filepath.is_abs(original_path) {
		path = original_path
	} else {
		// Get base directory from file
		file := get_file_from_node(ctx.info, call)
		if file == nil {
			if err_on_not_found {
				error_node(call, "Failed to '#load' file: %s; cannot determine base directory", original_path)
			}
			return nil, false
		}
		base_dir := filepath.dir(file.fullpath)
		joined, join_err := filepath.join({base_dir, original_path})
		if join_err != nil {
			if err_on_not_found {
				error_node(call, "Failed to '#load' file: %s; could not resolve path", original_path)
			}
			return nil, false
		}
		path = joined
	}

	// Lock the cache mutex
	sync.lock(&ctx.info.load_file_mutex)
	defer sync.unlock(&ctx.info.load_file_mutex)

	// Check if already cached
	if cached, found := ctx.info.load_file_cache[path]; found {
		cache = cached
		if tier <= cache.tier {
			// Already have sufficient data cached
			if cache.file_error == .None {
				return cache, true
			}
			// Handle cached error
			if err_on_not_found {
				report_load_file_error(call, cache.file_error, path)
			}
			return cache, false
		}
	}

	// Need to load or upgrade cache
	if cache == nil {
		cache = new(Load_File_Cache)
		cache.path = path
		cache.tier = .Invalid
		cache.hashes = make(map[string]u64)
		ctx.info.load_file_cache[path] = cache
	}

	// Perform file operation based on tier
	if tier > cache.tier {
		cache.tier = tier

		#partial switch tier {
		case .Exists:
			cache.exists = os.exists(path)
			cache.file_error = .None if cache.exists else .Not_Exists

		case .Contents:
			// NOTE: the contents are retained in the load-file cache for the lifetime of the
			// checker, so they must not come from the temporary allocator.
			data, read_err := os.read_entire_file(path, context.allocator)
			if read_err == nil {
				cache.exists = true
				cache.data = data
				cache.file_error = .None
			} else {
				cache.exists = false
				cache.file_error = .Not_Exists if !os.exists(path) else .Permission
			}
		}
	}

	// Handle errors
	if cache.file_error != .None {
		if err_on_not_found {
			report_load_file_error(call, cache.file_error, path)
		}
		return cache, false
	}

	return cache, true
}

// report_load_file_error reports an appropriate error for file loading failures
report_load_file_error :: proc(call: ^ast.Node, file_error: File_Error, path: string) {
	#partial switch file_error {
	case .Not_Exists:
		error_node(call, "Failed to load file: %s; file cannot be found", path)
	case .Permission:
		error_node(call, "Failed to load file: %s; file permissions problem", path)
	case .Invalid:
		error_node(call, "Failed to load file: %s; invalid file", path)
	case:
		error_node(call, "Failed to load file: %s; unknown error", path)
	}
}

// is_valid_type_for_load checks if a type is valid for #load
// C++ Reference: check_builtin.cpp:1772-1814
is_valid_type_for_load :: proc(type: ^Type) -> bool {
	if type == nil || type == t_invalid {
		return false
	}

	// String is valid
	if is_type_string(type) {
		return true
	}

	// Slice of simple types is valid
	if is_type_slice(type) {
		bt := base_type(type)
		if slice, is_slice := bt.variant.(Type_Slice); is_slice {
			elem := slice.elem
			// Must be a basic type with known size
			if is_type_integer(elem) || is_type_float(elem) || is_type_boolean(elem) {
				return true
			}
		}
	}

	return false
}

// =============================================================================
// NEW CORE BUILTINS
// =============================================================================

// check_builtin_quaternion handles quaternion() builtin
// quaternion(w, x, y, z) constructs a quaternion from four real components
// C++ Reference: check_builtin.cpp:2915-2962
check_builtin_quaternion :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	if len(call.args) != 4 {
		error_node(call, "'quaternion' requires exactly 4 arguments, got %d", len(call.args))
		return false
	}

	// C++ Reference: check_builtin.cpp:3571-3672.
	//
	// `quaternion` is one of only two builtins that accept `field = value` arguments (the other is
	// soa_zip). The port checked each argument with plain check_expr, so a named argument arrived as
	// an ^ast.Field_Value and fell through to "Expression type not yet supported". Every
	// `quaternion(w=..., x=..., y=..., z=...)` in base:runtime hit this - 31 diagnostics in
	// core/bytes, 32 in core/strings.
	args: [4]Operand

	_, first_is_field_value := call.args[0].derived_expr.(^ast.Field_Value)

	// C++ Reference: check_builtin.cpp:3574-3587 - named and positional must not be mixed.
	for arg in call.args {
		_, arg_is_fv := arg.derived_expr.(^ast.Field_Value)
		if arg_is_fv != first_is_field_value {
			error_node(arg, "Mixture of 'field = value' and value elements in the procedure call 'quaternion' is not allowed")
			operand.type = t_untyped_quaternion
			operand.mode = .Constant
			operand.value = exact_value_quaternion(0, 0, 0, 0)
			return true
		}
	}

	if first_is_field_value {
		// C++ Reference: check_builtin.cpp:3605-3670. Two naming styles are accepted but must not be
		// mixed: 1 = x/y/z/w, 2 = imag/jmag/kmag/real. Index 3 is the real component in both.
		fields_set: [4]u32
		for i in 0 ..< 4 {
			fv := call.args[i].derived_expr.(^ast.Field_Value)
			ident, is_ident := fv.field.derived_expr.(^ast.Ident)
			if !is_ident {
				error_node(fv.field, "Expected an identifier for field argument")
				return false
			}
			index := -1
			style: u32 = 0
			switch ident.name {
			case "x":    index = 0; style = 1
			case "y":    index = 1; style = 1
			case "z":    index = 2; style = 1
			case "w":    index = 3; style = 1
			case "imag": index = 0; style = 2
			case "jmag": index = 1; style = 2
			case "kmag": index = 2; style = 2
			case "real": index = 3; style = 2
			case:
				error_node(fv.field, "Unknown name for 'quaternion', expected (w, x, y, z; or real, imag, jmag, kmag), got '%s'", ident.name)
				return false
			}
			if fields_set[index] != 0 {
				error_node(fv.field, "Previously assigned field: '%s'", ident.name)
				return false
			}
			fields_set[index] = style

			check_expr(ctx, &args[index], fv.value)
			if args[index].mode == .Invalid {
				return false
			}
		}
		// C++ Reference: check_builtin.cpp:3665-3670
		for i in 1 ..< 4 {
			if fields_set[i] != fields_set[i - 1] {
				error_node(call, "Mixture of xyzw and real/etc is not allowed with 'quaternion'")
				break
			}
		}
	} else {
		// C++ Reference: check_builtin.cpp:3672-3680. C++ REQUIRES named arguments here and still
		// checks the positional ones so later diagnostics are not suppressed.
		error_node(call, "'quaternion' requires that all arguments are named (w, x, y, z; or real, imag, jmag, kmag)")
		for i in 0 ..< 4 {
			check_expr(ctx, &args[i], call.args[i])
			if args[i].mode == .Invalid {
				return false
			}
		}
	}

	// All arguments must be numeric (float or integer)
	for i := 0; i < 4; i += 1 {
		if !is_type_numeric(args[i].type) {
			error(args[i].expr, "Expected numeric type for 'quaternion' argument %d, got %s", i + 1, type_to_string(args[i].type))
			return false
		}
	}

	// Determine result type based on type hint or argument types
	result_type: ^Type = nil
	if type_hint != nil && is_type_quaternion(type_hint) {
		result_type = type_hint
	} else {
		// Default to quaternion128 (f32 components)
		result_type = t_quaternion128
	}

	// Check if all arguments are constant
	all_constant := true
	for i := 0; i < 4; i += 1 {
		if args[i].mode != .Constant {
			all_constant = false
			break
		}
	}

	operand.type = result_type
	if all_constant {
		operand.mode = .Constant
		// Store as compound value - for now store as nil to indicate constant
		operand.value = nil
	} else {
		operand.mode = .Value
	}

	return true
}

// check_builtin_jmag_kmag handles jmag() and kmag() builtins
// jmag(q) returns the j-component of a quaternion
// kmag(q) returns the k-component of a quaternion
// C++ Reference: check_builtin.cpp:2963-3010
check_builtin_jmag_kmag :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		name := id == .Jmag ? "jmag" : "kmag"
		error_node(call, "'%s' requires exactly 1 argument, got %d", name, len(call.args))
		return false
	}

	check_expr(ctx, operand, call.args[0])
	if operand.mode == .Invalid {
		return false
	}

	op_type := base_type(operand.type)
	if !is_type_quaternion(op_type) {
		name := id == .Jmag ? "jmag" : "kmag"
		error_node(call, "'%s' requires a quaternion type, got %s", name, type_to_string(operand.type))
		return false
	}

	// Result is the float component type
	quat := op_type.variant.(Type_Basic)
	result_type: ^Type = nil
	#partial switch quat.kind {
	case .Quaternion64:
		result_type = t_f16
	case .Quaternion128:
		result_type = t_f32
	case .Quaternion256:
		result_type = t_f64
	case:
		result_type = t_f32
	}

	operand.type = result_type
	operand.mode = .Value
	return true
}

// check_builtin_expand_values handles expand_values() builtin
// expand_values(v) expands a struct/array into its individual values
// C++ Reference: check_builtin.cpp:3850-3920
// expand_values_tuple_type builds the tuple type that `expand_values(x)` / `**x` yields.
//
// C++ Reference: check_expr.cpp:3016-3033 (the Token_MulMul case) and check_builtin.cpp's
// BuiltinProc_expand_values, which construct the same tuple.
//
// Struct -> a tuple of every field type. Array -> a tuple of `count` copies of the element type.
// A one-element tuple collapses to the bare element type, matching C++
// (`if (tuple->Tuple.variables.count == 1) o->type = tuple->Tuple.variables[0]->type;`).
//
// NOTE: C++ imposes NO limit on the array length here. The previous implementation rejected arrays
// longer than 4 ("requires array size <= 4"), which was invented.
expand_values_tuple_type :: proc(ctx: ^Checker_Context, type: ^Type) -> (^Type, bool) {
	bt := base_type(type)
	if bt == nil {
		return nil, false
	}

	types: [dynamic]^Type
	defer delete(types)

	#partial switch v in bt.variant {
	case Type_Struct:
		for field in v.fields {
			append(&types, field.type)
		}
	case Type_Array:
		for _ in 0 ..< v.count {
			append(&types, v.elem)
		}
	case:
		return nil, false
	}

	if len(types) == 1 {
		return types[0], true
	}
	return alloc_type_tuple_from_field_types(ctx.checker, types[:]), true
}

check_builtin_expand_values :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'expand_values' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr(ctx, operand, call.args[0])
	if operand.mode == .Invalid {
		return false
	}

	result, ok := expand_values_tuple_type(ctx, operand.type)
	if !ok {
		error_node(call, "'expand_values' requires a struct or array type, got %s", type_to_string(operand.type))
		return false
	}
	operand.mode = .Value
	operand.type = result
	return true
}

// check_builtin_compress_values handles compress_values() builtin
// compress_values(a, b, c, ...) compresses individual values into a struct
// C++ Reference: check_builtin.cpp:3921-3990
check_builtin_compress_values :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) < 1 {
		error_node(call, "'compress_values' requires at least 1 argument")
		return false
	}

	// The first argument should be a type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "First argument to 'compress_values' must be a type")
		return false
	}

	target_type := operand.type
	bt := base_type(target_type)

	// Must be a struct type
	if st, is_struct := bt.variant.(Type_Struct); is_struct {
		// Check remaining arguments against struct fields
		field_count := len(st.fields)
		arg_count := len(call.args) - 1

		if arg_count != field_count {
			error_node(call, "'compress_values' expected %d values for struct '%s', got %d", field_count, type_to_string(target_type), arg_count)
			return false
		}

		// Check each argument against corresponding field type
		for i := 1; i < len(call.args); i += 1 {
			arg: Operand
			check_expr(ctx, &arg, call.args[i])
			if arg.mode == .Invalid {
				return false
			}

			field_idx := i - 1
			if field_idx < len(st.fields) {
				field := st.fields[field_idx]
				if !check_is_assignable_to(ctx, &arg, field.type) {
					error_node(call.args[i], "Cannot assign '%s' to field '%s' of type '%s'", type_to_string(arg.type), field.token.text, type_to_string(field.type))
					return false
				}
			}
		}

		operand.type = target_type
		operand.mode = .Value
		return true
	}

	error_node(call, "'compress_values' requires a struct type, got %s", type_to_string(target_type))
	return false
}

// check_builtin_soa_zip handles soa_zip() builtin
// soa_zip(slices...) zips slices into an #soa slice of a struct built from their element types
// C++ Reference: check_builtin.cpp:4677-4820
//
// soa_zip is one of only two builtins that accept `field = value` arguments (the other is
// quaternion; see check_builtin.cpp:2859 and the prologue at the top of this file). The names
// given that way become the field names of the generated struct, which is the entire point of
// the form - `soa_zip(name=..., type=...)` is what makes `for f in fields { f.name }` work in
// core:reflect. The previous implementation checked each argument with plain check_expr, so a
// Field_Value node reached check_expr's unsupported-node arm, and named the fields `_0`.._9`
// unconditionally, so even a successful zip produced a struct with the wrong field names.
check_builtin_soa_zip :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	if len(call.args) < 1 {
		error_node(call, "'soa_zip' requires at least 1 argument")
		return false
	}

	// C++ line 4682-4700: all arguments must agree on whether they are `field = value` or not.
	_, first_is_field_value := call.args[0].derived.(^ast.Field_Value)
	fail := false
	for arg in call.args {
		_, is_fv := arg.derived.(^ast.Field_Value)
		if is_fv != first_is_field_value {
			error(arg, "Mixture of 'field = value' and value elements in the procedure call 'soa_zip' is not allowed")
			fail = true
			break
		}
	}

	types := make([dynamic]^Type, 0, len(call.args), context.temp_allocator)
	names := make([dynamic]string, 0, len(call.args), context.temp_allocator)
	name_set := make(map[string]struct{}, 2 * len(call.args), context.temp_allocator)

	// C++ line 4702-4742
	for arg in call.args {
		name := ""
		value_expr := arg
		if fv, is_fv := arg.derived.(^ast.Field_Value); is_fv {
			if ident, is_ident := fv.field.derived.(^ast.Ident); is_ident {
				name = ident.name
			} else if !fail {
				error(fv.field, "Expected an identifier for field argument")
			}
			value_expr = fv.value
		}

		op: Operand
		check_expr(ctx, &op, value_expr)
		if op.mode == .Invalid {
			return false
		}
		arg_type := base_type(op.type)
		if !is_type_slice(arg_type) {
			error(op.expr, "Indices to 'soa_zip' must be slices, got %s", type_to_string(op.type))
			return false
		}

		if name == "_" {
			error(op.expr, "Field argument name '%s' is not allowed", name)
			name = ""
		}
		if len(name) == 0 {
			name = fmt.aprintf("_%d", len(types), allocator = ctx.checker.allocator)
		}

		if _, exists := name_set[name]; exists {
			error(op.expr, "Field argument name '%s' already exists", name)
		} else {
			name_set[name] = {}
			append(&types, arg_type.variant.(Type_Slice).elem)
			append(&names, name)
		}
	}

	// C++ line 4747-4761: the fields live in their own scope parented to the builtin package's,
	// so that lookup_field on the generated struct resolves them.
	parent_scope: ^Scope = nil
	if ctx.checker.info.builtin_package != nil {
		parent_scope = get_package_scope(&ctx.checker.info, ctx.checker.info.builtin_package)
	}
	s := create_scope(parent_scope, ctx.checker.allocator)

	fields := make([dynamic]^Entity, 0, len(types), ctx.checker.allocator)
	for type, i in types {
		e := alloc_entity_field(s, make_token_ident(names[i]), type, false, i32(i), .Resolved)
		append(&fields, e)
		scope_insert(s, e)
	}

	// C++ line 4763-4799: if the call is in a position that already wants a particular #soa
	// slice, and the generated fields match it exactly, reuse that element type rather than
	// minting a structurally-equal but distinct one. Any mismatch simply falls through to the
	// fresh struct below - this is a canonicalisation, not a constraint.
	elem: ^Type = nil
	if type_hint != nil && is_type_struct(type_hint) {
		hint_matches: {
			soa_type := base_type(type_hint)
			soa_struct := soa_type.variant.(Type_Struct)
			if soa_struct.soa_kind != .Slice {
				break hint_matches
			}
			soa_elem_type := soa_struct.soa_elem
			et := base_type(soa_elem_type)
			if et == nil || et.kind != .Struct {
				break hint_matches
			}
			ets := et.variant.(Type_Struct)
			if len(ets.fields) != len(fields) {
				break hint_matches
			}
			if !fail && first_is_field_value {
				for name, i in names {
					sel := lookup_field(et, name, false)
					if sel.entity == nil || len(sel.index) != 1 {
						break hint_matches
					}
					if !are_types_identical(entity_type(sel.entity), types[i]) {
						break hint_matches
					}
				}
			} else {
				for f, i in ets.fields {
					if !are_types_identical(entity_type(f), types[i]) {
						break hint_matches
					}
				}
			}
			elem = soa_elem_type
		}
	}

	if elem == nil {
		elem = alloc_type_struct(ctx.checker)
		ts := &elem.variant.(Type_Struct)
		ts.scope = s
		ts.fields = fields
		ts.tags = make([dynamic]string, len(fields), ctx.checker.allocator)
		ts.names = make(map[string]^Entity, len(fields), ctx.checker.allocator)
		for f, i in fields {
			ts.names[f.token.text] = f
			ts.tags[i] = ""
		}
	}

	operand.mode = .Value
	operand.type = make_soa_struct_slice(ctx, call, nil, elem)
	return true
}

// check_builtin_soa_unzip handles soa_unzip() builtin
// soa_unzip(soa_slice) unzips a SOA struct slice into individual slices
// C++ Reference: check_builtin.cpp:4181-4250
check_builtin_soa_unzip :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'soa_unzip' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr(ctx, operand, call.args[0])
	if operand.mode == .Invalid {
		return false
	}

	// Argument must be a SOA slice
	bt := base_type(operand.type)
	if !is_type_soa_struct(operand.type) {
		error_node(call, "'soa_unzip' requires a SOA type, got %s", type_to_string(operand.type))
		return false
	}

	// Get the SOA element type (the struct that was SOA'd)
	soa_struct, ok := bt.variant.(Type_Struct)
	if !ok || soa_struct.soa_elem == nil {
		error_node(call, "'soa_unzip' internal error: SOA type has no element")
		return false
	}

	// Get the original struct's fields
	elem_bt := base_type(soa_struct.soa_elem)
	elem_struct, elem_ok := elem_bt.variant.(Type_Struct)
	if !elem_ok {
		error_node(call, "'soa_unzip' internal error: SOA element is not a struct")
		return false
	}

	// Create slice types for each field
	// C++ Reference: check_builtin.cpp L4200-4240
	slice_types := make([]^Type, len(elem_struct.fields))
	for i := 0; i < len(elem_struct.fields); i += 1 {
		field := elem_struct.fields[i]
		if field != nil {
			slice_types[i] = alloc_type_slice(field.type)
		} else {
			slice_types[i] = t_invalid
		}
	}

	// Create a tuple of these slice types
	result_type := alloc_type_tuple_from_field_types(ctx.checker, slice_types)

	operand.mode = .Value
	operand.type = result_type
	return true
}

// check_builtin_unreachable handles unreachable() builtin
// unreachable() indicates code that should never be reached
// C++ Reference: check_builtin.cpp:4251-4280
check_builtin_unreachable :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 0 {
		error_node(call, "'unreachable' takes no arguments, got %d", len(call.args))
		return false
	}

	// Mark as diverging - this is a no-return statement
	// The operand mode being No_Value signals divergence to callers
	operand.mode = .No_Value
	operand.type = nil

	return true
}

// check_builtin_raw_data handles raw_data() builtin
// raw_data(container) returns a pointer to the raw data of a container
// C++ Reference: check_builtin.cpp:4281-4360
check_builtin_raw_data :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'raw_data' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr(ctx, operand, call.args[0])
	if operand.mode == .Invalid {
		return false
	}

	bt := base_type(operand.type)
	elem_type: ^Type = nil

	// Check type and get element type
	if is_type_slice(bt) {
		slice := bt.variant.(Type_Slice)
		elem_type = slice.elem
	} else if is_type_dynamic_array(bt) {
		da := bt.variant.(Type_Dynamic_Array)
		elem_type = da.elem
	} else if is_type_string(bt) {
		elem_type = t_u8
	} else if is_type_array(bt) {
		arr := bt.variant.(Type_Array)
		elem_type = arr.elem
	// C++ Reference: check_builtin.cpp:5512 - `case Type_Pointer:` (rawptr has no element type)
	} else if bt.kind == .Pointer {
		ptr := bt.variant.(Type_Pointer)
		if is_type_array(ptr.elem) {
			arr := base_type(ptr.elem).variant.(Type_Array)
			elem_type = arr.elem
		} else {
			error_node(call, "'raw_data' pointer argument must point to an array")
			return false
		}
	} else {
		error_node(call, "'raw_data' requires a slice, dynamic array, string, array, or pointer to array, got %s", type_to_string(operand.type))
		return false
	}

	// Result is a multi-pointer to the element type
	operand.type = alloc_type_multi_pointer(elem_type)
	operand.mode = .Value
	return true
}

// =============================================================================
// TYPE INTRINSICS
// =============================================================================

// check_builtin_type_base_core handles type_base_type() and type_core_type()
// type_base_type(T) returns the base type of a type alias
// type_core_type(T) returns the core underlying type
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_base_core :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		name := id == .Type_Base_Type ? "type_base_type" : "type_core_type"
		error_node(call, "'%s' requires exactly 1 argument, got %d", name, len(call.args))
		return false
	}

	// Argument must be a type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		name := id == .Type_Base_Type ? "type_base_type" : "type_core_type"
		error_node(call.args[0], "'%s' requires a type argument", name)
		return false
	}

	input_type := operand.type

	// Compute result type
	result_type: ^Type
	if id == .Type_Base_Type {
		result_type = base_type(input_type)
	} else {
		result_type = core_type(input_type)
	}

	if result_type == nil {
		result_type = t_invalid
	}

	operand.mode = .Type
	operand.type = result_type
	return true
}

// check_builtin_type_elem handles type_elem_type()
// type_elem_type(T) returns the element type of arrays, slices, pointers, etc.
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_elem :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_elem_type' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	// Argument must be a type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "'type_elem_type' requires a type argument")
		return false
	}

	// C++ Reference: check_builtin.cpp:6787-6812
	//
	// C++ emits NO error for a kind it does not recognise - it simply leaves operand->type as it
	// was and sets the mode to Type. That is deliberate: a polymorphic `$T` passes straight through
	// and is resolved at instantiation. The port invented an error here
	// ("requires a type with an element type ...") which has no C++ counterpart, and it is what
	// broke every `ELEM_TYPE(T)` in core/math/linalg once polymorphic matrix procedures became
	// checkable.
	bt := base_type(operand.type)
	elem_type := operand.type

	#partial switch v in bt.variant {
	case Type_Basic:
		// C++ Reference: check_builtin.cpp:6793-6802. Complex and quaternion decay to their
		// component float type. These were missing entirely.
		#partial switch v.kind {
		case .Complex32:
			elem_type = t_f16
		case .Complex64:
			elem_type = t_f32
		case .Complex128:
			elem_type = t_f64
		case .Quaternion64:
			elem_type = t_f16
		case .Quaternion128:
			elem_type = t_f32
		case .Quaternion256:
			elem_type = t_f64
		}
	case Type_Pointer:
		elem_type = v.elem
	case Type_Array:
		elem_type = v.elem
	case Type_Enumerated_Array:
		elem_type = v.elem
	case Type_Slice:
		elem_type = v.elem
	case Type_Dynamic_Array:
		elem_type = v.elem
	case Type_Simd_Vector:
		elem_type = v.elem
	}
	// NOTE: C++ has no Matrix or MultiPointer arm here, so for those the type passes through
	// unchanged. Adding those two arms was tried and measured identical on core/math/linalg (767
	// either way), so there is no evidence for deviating from C++ and the arms are not carried.

	operand.mode = .Type
	operand.type = elem_type
	return true
}

// check_builtin_type_is_predicate handles all type_is_* predicates
// These return a compile-time boolean indicating whether the type matches the predicate
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_is_predicate :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		info := builtin_proc_infos[id]
		error_node(call, "'%s' requires exactly 1 argument, got %d", info.name, len(call.args))
		return false
	}

	// Argument must be a type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		info := builtin_proc_infos[id]
		error_node(call.args[0], "'%s' requires a type argument", info.name)
		return false
	}

	input_type := operand.type
	result: bool = false

	// Evaluate the predicate
	#partial switch id {
	case .Type_Is_Boolean:
		result = is_type_boolean(input_type)
	case .Type_Is_Integer:
		result = is_type_integer(input_type)
	case .Type_Is_Rune:
		result = is_type_rune(input_type)
	case .Type_Is_Float:
		result = is_type_float(input_type)
	case .Type_Is_Complex:
		result = is_type_complex(input_type)
	case .Type_Is_Quaternion:
		result = is_type_quaternion(input_type)
	case .Type_Is_String:
		result = is_type_string(input_type)
	case .Type_Is_Cstring:
		result = is_type_cstring(input_type)
	case .Type_Is_Typeid:
		result = is_type_typeid(input_type)
	case .Type_Is_Any:
		result = is_type_any(input_type)
	case .Type_Is_Endian_Platform:
		result = is_type_endian_platform(input_type)
	case .Type_Is_Endian_Little:
		result = is_type_endian_little(input_type)
	case .Type_Is_Endian_Big:
		result = is_type_endian_big(input_type)
	case .Type_Is_Unsigned:
		result = is_type_unsigned(input_type)
	case .Type_Is_Ordered:
		result = is_type_ordered(input_type)
	case .Type_Is_Comparable:
		result = is_type_comparable(input_type)
	case .Type_Is_Simple_Compare:
		result = is_type_simple_compare(input_type)
	case .Type_Is_Nearly_Simple_Compare:
		result = is_type_nearly_simple_compare(input_type)
	case .Type_Is_Internally_Pointer_Like:
		result = is_type_internally_pointer_like(input_type)
	case .Type_Is_Numeric:
		result = is_type_numeric(input_type)
	case .Type_Is_Ordered_Numeric:
		result = is_type_ordered_numeric(input_type)
	case .Type_Is_Pointer:
		result = is_type_pointer(input_type)
	case .Type_Is_Multi_Pointer:
		result = is_type_multi_pointer(input_type)
	case .Type_Is_Array:
		result = is_type_array(input_type)
	case .Type_Is_Enumerated_Array:
		result = is_type_enumerated_array(input_type)
	case .Type_Is_Dynamic_Array:
		result = is_type_dynamic_array(input_type)
	case .Type_Is_Slice:
		result = is_type_slice(input_type)
	case .Type_Is_Struct:
		result = is_type_struct(input_type)
	case .Type_Is_Union:
		result = is_type_union(input_type)
	case .Type_Is_Enum:
		result = is_type_enum(input_type)
	case .Type_Is_Proc:
		result = is_type_proc(input_type)
	case .Type_Is_Bit_Set:
		result = is_type_bit_set(input_type)
	case .Type_Is_Bit_Field:
		result = is_type_bit_field(input_type)
	case .Type_Is_Map:
		result = is_type_map(input_type)
	case .Type_Is_Matrix:
		result = is_type_matrix(input_type)
	case .Type_Is_Simd_Vector:
		result = is_type_simd_vector(input_type)
	case .Type_Is_Named:
		result = is_type_named(input_type)
	case .Type_Is_Cstring16:
		result = is_type_cstring16(input_type)
	case .Type_Is_String16:
		result = is_type_string16(input_type)
	case .Type_Is_Dereferenceable:
		result = is_type_dereferenceable(input_type)
	case .Type_Is_Sliceable:
		result = is_type_sliceable(input_type)
	case .Type_Is_Indexable:
		result = is_type_indexable(input_type)
	case .Type_Is_Valid_Map_Key:
		result = is_type_valid_for_keys(input_type)
	case .Type_Is_Valid_Matrix_Elements:
		result = is_type_valid_for_matrix_elems(input_type)
	case .Type_Is_Raw_Union:
		result = is_type_raw_union(input_type)
	case .Type_Is_Specialized_Polymorphic_Record:
		result = is_type_polymorphic_record_specialized(input_type)
	case .Type_Is_Unspecialized_Polymorphic_Record:
		result = is_type_polymorphic_record_unspecialized(input_type)
	}

	// Return as compile-time constant boolean
	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = result
	return true
}

// check_builtin_type_is_subtype_of handles type_is_subtype_of(T, S)
// Returns true if T is a subtype of S
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_is_subtype_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 2 {
		error_node(call, "'type_is_subtype_of' requires exactly 2 arguments, got %d", len(call.args))
		return false
	}

	// First argument: subtype
	sub_op: Operand
	check_expr_or_type(ctx, &sub_op, call.args[0])
	if sub_op.mode != .Type {
		error_node(call.args[0], "'type_is_subtype_of' requires type arguments")
		return false
	}

	// Second argument: supertype
	super_op: Operand
	check_expr_or_type(ctx, &super_op, call.args[1])
	if super_op.mode != .Type {
		error_node(call.args[1], "'type_is_subtype_of' requires type arguments")
		return false
	}

	// Check if sub_type is a subtype of super_type
	result := is_type_subtype_of(sub_op.type, super_op.type)

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = result
	return true
}

// check_builtin_type_has_nil handles type_has_nil(T)
// Returns true if the type can hold a nil value
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_has_nil :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_has_nil' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	// Argument must be a type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "'type_has_nil' requires a type argument")
		return false
	}

	result := type_has_nil(operand.type)

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = result
	return true
}

// check_builtin_type_field_index_of handles type_field_index_of(T, name)
// Returns the index of a field in a struct type
// C++ Reference: check_builtin.cpp (type intrinsics)
check_builtin_type_field_index_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 2 {
		error_node(call, "'type_field_index_of' requires exactly 2 arguments, got %d", len(call.args))
		return false
	}

	// First argument: type
	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "'type_field_index_of' requires a type as first argument")
		return false
	}

	struct_type := operand.type
	bt := base_type(struct_type)
	if !is_type_struct(bt) {
		error_node(call.args[0], "'type_field_index_of' requires a struct type, got %s", type_to_string(struct_type))
		return false
	}

	// Second argument: field name (string)
	name_op: Operand
	check_expr(ctx, &name_op, call.args[1])
	if name_op.mode != .Constant {
		error_node(call.args[1], "'type_field_index_of' requires a constant string for field name")
		return false
	}

	field_name, is_string := name_op.value.(string)
	if !is_string {
		error_node(call.args[1], "'type_field_index_of' requires a string for field name")
		return false
	}

	// Find the field
	st := bt.variant.(Type_Struct)
	field_index: int = -1
	for field, idx in st.fields {
		if field.token.text == field_name {
			field_index = idx
			break
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	operand.value = exact_value_i64(i64(field_index))
	return true
}

// check_builtin_type_bit_set_accessors handles type_bit_set_elem_type, type_bit_set_underlying_type, type_bit_set_backing_type
// C++ Reference: check_builtin.cpp L6954-7004, L7571-7588
check_builtin_type_bit_set_accessors :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		builtin_name := builtin_proc_infos[id].name
		error_node(call.args[0], "Expected a type for '%s'", builtin_name)
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	bs := operand.type
	if !is_type_bit_set(bs) {
		builtin_name := builtin_proc_infos[id].name
		// C++ splits this across two handlers with DIFFERENT messages: elem_type
		// (check_builtin.cpp:7463) and underlying_type (7489) name only the builtin, while
		// backing_type (8125) also names the offending type. The port folds all three into
		// one procedure, so the tail is gated on the id rather than added to all three.
		// Confirmed against the oracle, which prints ", got int" for backing_type and
		// nothing for the other two.
		if id == .Type_Bit_Set_Backing_Type {
			error_node(call.args[0], "Expected a bit_set type for '%s', got %s", builtin_name, type_to_string(operand.type))
		} else {
			error_node(call.args[0], "Expected a bit_set type for '%s'", builtin_name)
		}
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	bt := base_type(bs)
	bs_variant := bt.variant.(Type_Bit_Set)

	#partial switch id {
	case .Type_Bit_Set_Elem_Type:
		operand.mode = .Type
		operand.type = bs_variant.elem
	case .Type_Bit_Set_Underlying_Type, .Type_Bit_Set_Backing_Type:
		operand.mode = .Type
		operand.type = bit_set_to_int(bt)
	}
	return true
}

// check_builtin_type_union_variant_count handles type_union_variant_count(T)
// C++ Reference: check_builtin.cpp L7006-7030
check_builtin_type_union_variant_count :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_union_variant_count' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a type for 'type_union_variant_count'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	u := operand.type
	if !is_type_union(u) {
		error_node(call.args[0], "Expected a union type for 'type_union_variant_count'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	bt := base_type(u)
	u_variant := bt.variant.(Type_Union)

	operand.mode = .Constant
	operand.type = t_untyped_integer
	operand.value = exact_value_i64(i64(len(u_variant.variants)))
	return true
}

// check_builtin_type_variant_type_of handles type_variant_type_of(T, index)
// C++ Reference: check_builtin.cpp L7032-7072
check_builtin_type_variant_type_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 2 {
		error_node(call, "'type_variant_type_of' requires exactly 2 arguments, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a type for 'type_variant_type_of'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	u := operand.type
	if !is_type_union(u) {
		error_node(call.args[0], "Expected a union type for 'type_variant_type_of'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	bt := base_type(u)
	u_variant := bt.variant.(Type_Union)

	// Check index argument
	x: Operand
	check_expr_or_type(ctx, &x, call.args[1])
	if !is_type_integer(x.type) || x.mode != .Constant {
		error_node(call, "Expected a constant integer for 'type_variant_type_of'")
		operand.mode = .Type
		operand.type = t_invalid
		return false
	}

	index := exact_value_to_i64(x.value)
	if index < 0 || index >= i64(len(u_variant.variants)) {
		error_node(call, "Variant tag out of bounds index for 'type_variant_type_of'")
		operand.mode = .Type
		operand.type = t_invalid
		return false
	}

	operand.mode = .Type
	operand.type = u_variant.variants[index]
	return true
}

// check_builtin_type_variant_index_of handles type_variant_index_of(T, V)
// C++ Reference: check_builtin.cpp L7074-7116
check_builtin_type_variant_index_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 2 {
		error_node(call, "'type_variant_index_of' requires exactly 2 arguments, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a type for 'type_variant_index_of'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	u := operand.type
	if !is_type_union(u) {
		error_node(call.args[0], "Expected a union type for 'type_variant_index_of'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	v := check_type(ctx, call.args[1])
	bt := base_type(u)
	u_variant := bt.variant.(Type_Union)

	// Find the variant index
	variant_index: i64 = -1
	for vt, idx in u_variant.variants {
		if are_types_identical(v, vt) {
			variant_index = i64(idx)
			break
		}
	}

	if variant_index < 0 {
		error_node(call.args[1], "Expected a variant type for 'type_variant_index_of'")
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	operand.value = exact_value_i64(variant_index)
	return true
}

// check_builtin_type_struct_field_count handles type_struct_field_count(T)
// C++ Reference: check_builtin.cpp L7118-7130
check_builtin_type_struct_field_count :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_struct_field_count' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])

	operand.value = exact_value_i64(0)
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a struct type for 'type_struct_field_count'")
	} else if !is_type_struct(operand.type) {
		error_node(call.args[0], "Expected a struct type for 'type_struct_field_count'")
	} else {
		bt := base_type(operand.type)
		st := bt.variant.(Type_Struct)
		operand.value = exact_value_i64(i64(len(st.fields)))
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	return true
}

// check_builtin_type_struct_has_implicit_padding handles type_struct_has_implicit_padding(T)
// C++ Reference: check_builtin.cpp L7131-7155
check_builtin_type_struct_has_implicit_padding :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_struct_has_implicit_padding' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])

	operand.value = exact_value_bool(false)
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a struct type for 'type_struct_has_implicit_padding'")
	} else if !is_type_struct(operand.type) && !is_type_soa_struct(operand.type) {
		error_node(call.args[0], "Expected a struct type for 'type_struct_has_implicit_padding'")
	} else {
		bt := base_type(operand.type)
		st := bt.variant.(Type_Struct)
		if st.is_packed {
			operand.value = exact_value_bool(false)
		} else if len(st.fields) != 0 {
			size := type_size_of(bt)
			// Check if there's padding after the last field
			last_field_idx := len(st.fields) - 1
			last_offset := type_offset_of(bt, i64(last_field_idx))
			last_field_size := type_size_of(st.fields[last_field_idx].type)
			if last_offset + i64(last_field_size) < i64(size) {
				operand.value = exact_value_bool(true)
			} else {
				// Check for internal padding by summing field sizes and comparing to total
				sum_field_sizes: i64 = 0
				for field in st.fields {
					sum_field_sizes += i64(type_size_of(field.type))
				}
				operand.value = exact_value_bool(sum_field_sizes < i64(size))
			}
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	return true
}

// check_builtin_type_proc_count handles type_proc_parameter_count and type_proc_return_count
// C++ Reference: check_builtin.cpp L7157-7182
check_builtin_type_proc_count :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	builtin_name := builtin_proc_infos[id].name

	operand.value = exact_value_i64(0)
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a procedure type for '%s'", builtin_name)
	} else if !is_type_proc(operand.type) {
		error_node(call.args[0], "Expected a procedure type for '%s'", builtin_name)
	} else {
		bt := base_type(operand.type)
		pt := bt.variant.(Type_Proc)
		#partial switch id {
		case .Type_Proc_Parameter_Count:
			operand.value = exact_value_i64(i64(pt.param_count))
		case .Type_Proc_Return_Count:
			operand.value = exact_value_i64(i64(pt.result_count))
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	return true
}

// check_builtin_type_proc_type_at_index handles type_proc_parameter_type and type_proc_return_type
// C++ Reference: check_builtin.cpp L7184-7300
check_builtin_type_proc_type_at_index :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 2 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	builtin_name := builtin_proc_infos[id].name

	if operand.mode != .Type || !is_type_proc(operand.type) {
		error_node(call.args[0], "Expected a procedure type for '%s'", builtin_name)
		return false
	}

	if is_type_polymorphic(operand.type) {
		error_node(call.args[0], "Expected a non-polymorphic procedure type for '%s'", builtin_name)
		return false
	}

	// Check index argument
	op: Operand
	check_expr(ctx, &op, call.args[1])
	if op.mode != .Constant || !is_type_integer(op.type) {
		error_node(op.expr, "Expected a constant integer for the index of procedure parameter value")
		return false
	}

	index := exact_value_to_i64(op.value)
	if index < 0 {
		error_node(op.expr, "Expected a non-negative integer for the index of procedure parameter value, got %d", index)
		return false
	}

	bt := base_type(operand.type)
	pt := bt.variant.(Type_Proc)

	param: ^Entity
	count: i64

	#partial switch id {
	case .Type_Proc_Parameter_Type:
		count = i64(pt.param_count)
		if index < count && pt.params != nil {
			params_tuple := pt.params.variant.(Type_Tuple)
			param = params_tuple.variables[index]
		}
	case .Type_Proc_Return_Type:
		count = i64(pt.result_count)
		if index < count && pt.results != nil {
			results_tuple := pt.results.variant.(Type_Tuple)
			param = results_tuple.variables[index]
		}
	}

	if index >= count {
		error_node(op.expr, "Index of procedure parameter value out of bounds, expected 0..<%d, got %d", count, index)
		return false
	}

	assert(param != nil)
	#partial switch param.kind {
	case .Constant:
		operand.mode = .Constant
		operand.type = param.type
		operand.value = param.variant.(Entity_Constant).value
	case .Type_Name, .Variable:
		operand.mode = .Type
		operand.type = param.type
	case:
		panic("Unhandled procedure entity type")
	}

	return true
}

// check_builtin_type_polymorphic_record_parameter_count handles type_polymorphic_record_parameter_count(T)
// C++ Reference: check_builtin.cpp L7302-7316
check_builtin_type_polymorphic_record_parameter_count :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_polymorphic_record_parameter_count' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])

	operand.value = exact_value_i64(0)
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a record type for 'type_polymorphic_record_parameter_count'")
	} else {
		tuple := get_record_polymorphic_params(operand.type)
		if tuple != nil {
			operand.value = exact_value_i64(i64(len(tuple.variables)))
		} else {
			error_node(call.args[0], "Expected a record type for 'type_polymorphic_record_parameter_count'")
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	return true
}

// check_builtin_type_polymorphic_record_parameter_value handles type_polymorphic_record_parameter_value(T, index)
// C++ Reference: check_builtin.cpp L7317-7374
check_builtin_type_polymorphic_record_parameter_value :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 2 {
		error_node(call, "'type_polymorphic_record_parameter_value' requires exactly 2 arguments, got %d", len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type {
		error_node(call.args[0], "Expected a record type for 'type_polymorphic_record_parameter_value'")
		return false
	}

	if !is_type_polymorphic_record_specialized(operand.type) {
		error_node(call.args[0], "Expected a specialized polymorphic record type for 'type_polymorphic_record_parameter_value'")
		return false
	}

	// Check index argument
	op: Operand
	check_expr(ctx, &op, call.args[1])
	if op.mode != .Constant || !is_type_integer(op.type) {
		error_node(op.expr, "Expected a constant integer for the index of record parameter value")
		return false
	}

	index := exact_value_to_i64(op.value)
	if index < 0 {
		error_node(op.expr, "Expected a non-negative integer for the index of record parameter value, got %d", index)
		return false
	}

	tuple := get_record_polymorphic_params(operand.type)
	if tuple == nil {
		error_node(call.args[0], "Expected a specialized polymorphic record type for 'type_polymorphic_record_parameter_value'")
		return false
	}

	count := i64(len(tuple.variables))
	if index >= count {
		error_node(op.expr, "Index of record parameter value out of bounds, expected 0..<%d, got %d", count, index)
		return false
	}

	param := tuple.variables[index]
	assert(param != nil)
	#partial switch param.kind {
	case .Constant:
		operand.mode = .Constant
		operand.type = param.type
		operand.value = param.variant.(Entity_Constant).value
	case .Type_Name:
		operand.mode = .Type
		operand.type = param.type
	case:
		panic("Unhandled polymorphic record type")
	}

	return true
}

// check_builtin_type_enum_is_contiguous handles type_enum_is_contiguous(T)
// C++ Reference: check_builtin.cpp L7591-7632
check_builtin_type_enum_is_contiguous :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_enum_is_contiguous' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_enum_is_contiguous'")
		return false
	}
	if !is_type_enum(bt) {
		error_node(call.args[0], "Expected an enum type for 'type_enum_is_contiguous'")
		return false
	}

	en := bt.variant.(Type_Enum)

	// Sort enum constants by value
	enum_constants := make([dynamic]^Entity, context.temp_allocator)
	for field in en.fields {
		append(&enum_constants, field)
	}
	slice.sort_by(enum_constants[:], proc(a, b: ^Entity) -> bool {
		av := exact_value_to_i64(a.variant.(Entity_Constant).value)
		bv := exact_value_to_i64(b.variant.(Entity_Constant).value)
		return av < bv
	})

	// Check if values are contiguous
	contiguous := true
	for i in 0 ..< len(enum_constants) - 1 {
		curr := exact_value_to_i64(enum_constants[i].variant.(Entity_Constant).value)
		next := exact_value_to_i64(enum_constants[i + 1].variant.(Entity_Constant).value)
		diff := next - curr
		if diff != 1 && diff != 0 {
			contiguous = false
			break
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(contiguous)
	return true
}

// check_builtin_type_equal_proc handles type_equal_proc(T)
// C++ Reference: check_builtin.cpp L7635-7654
check_builtin_type_equal_proc :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_equal_proc' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_equal_proc'")
		return false
	}
	if !is_type_comparable(bt) {
		error_node(call.args[0], "Expected a comparable type for 'type_equal_proc'")
		return false
	}

	operand.mode = .Value
	operand.type = t_equal_proc
	return true
}

// check_builtin_type_hasher_proc handles type_hasher_proc(T)
// C++ Reference: check_builtin.cpp L7656-7677
check_builtin_type_hasher_proc :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_hasher_proc' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_hasher_proc'")
		return false
	}
	if !is_type_valid_for_keys(bt) {
		error_node(call.args[0], "Expected a valid type for map keys for 'type_hasher_proc'")
		return false
	}

	add_map_key_type_dependencies(ctx, bt)

	operand.mode = .Value
	operand.type = t_hasher_proc
	return true
}

// check_builtin_type_map_info handles type_map_info(T)
// C++ Reference: check_builtin.cpp L7679-7700
check_builtin_type_map_info :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_map_info' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_map_info'")
		return false
	}
	if !is_type_map(bt) {
		error_node(call.args[0], "Expected a map type for 'type_map_info'")
		return false
	}

	add_map_key_type_dependencies(ctx, bt)

	operand.mode = .Value
	operand.type = t_map_info_ptr
	return true
}

// check_builtin_type_map_cell_info handles type_map_cell_info(T)
// C++ Reference: check_builtin.cpp L7701-7714
check_builtin_type_map_cell_info :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_map_cell_info' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_map_cell_info'")
		return false
	}

	operand.mode = .Value
	operand.type = t_map_cell_info_ptr
	return true
}

// check_builtin_type_canonical_name handles type_canonical_name(T)
// C++ Reference: check_builtin.cpp L7716-7730
check_builtin_type_canonical_name :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'type_canonical_name' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	type := check_type(ctx, call.args[0])
	bt := base_type(type)
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for 'type_canonical_name'")
		return false
	}

	operand.mode = .Constant
	operand.type = t_untyped_string
	operand.value = exact_value_string(type_to_canonical_string(type))
	return true
}

// ===========================================================================
// Math/Bit Intrinsics
// ===========================================================================

// check_builtin_bit_count handles count_ones, count_zeros, count_trailing_zeros, count_leading_zeros, reverse_bits
// C++ Reference: check_builtin.cpp L5193-5306
check_builtin_bit_count :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 1 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	builtin_name := builtin_proc_infos[id].name

	if is_type_simd_vector(x.type) {
		elem := base_array_type(x.type)
		if !is_type_integer_like(elem) {
			// C++ Reference: check_builtin.cpp:5572 -- names the offending type. Note C++ does
			// NOT quote it here, unlike most of its sibling messages.
			error_node(x.expr, "#simd values passed to '%s' must have an element of an integer-like type (integer, boolean, enum, bit_set), got %s", builtin_name, type_to_string(x.type))
		}
	} else if !is_type_integer_like(x.type) {
		error_node(x.expr, "Values passed to '%s' must be an integer-like type (integer, boolean, enum, bit_set), got %s", builtin_name, type_to_string(x.type))
	}

	type := default_type(x.type)
	operand.mode = .Value
	operand.type = type

	// Note: Constant evaluation for bit counting is deferred to runtime
	// for simplicity, matching the C++ implementation pattern for reverse_bits

	return true
}

// check_builtin_byte_swap handles byte_swap(x)
// C++ Reference: check_builtin.cpp L5309-5336
check_builtin_byte_swap :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'byte_swap' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_integer_like(x.type) && !is_type_float(x.type) {
		error_node(x.expr, "Values passed to 'byte_swap' must be an integer-like type (integer, boolean, enum, bit_set) or float, got %s", type_to_string(x.type))
	}

	sz := type_size_of(x.type)
	if sz < 2 {
		error_node(x.expr, "Type passed to 'byte_swap' must be at least 2 bytes, got size of %d", sz)
	}

	operand.mode = .Value
	operand.type = default_type(x.type)
	return true
}

// check_builtin_overflow_arith handles overflow_add, overflow_sub, overflow_mul
// C++ Reference: check_builtin.cpp L5338-5380
check_builtin_overflow_arith :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 2 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	builtin_name := builtin_proc_infos[id].name

	x: Operand
	y: Operand
	check_expr(ctx, &x, call.args[0])
	check_expr(ctx, &y, call.args[1])
	if x.mode == .Invalid {
		return false
	}
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &x, y.type)
	if x.mode == .Invalid {
		return false
	}

	if is_type_untyped(x.type) {
		error_node(x.expr, "Expected a typed integer for '%s'", builtin_name)
		return false
	}
	if !is_type_integer(x.type) {
		error_node(x.expr, "Expected an integer for '%s'", builtin_name)
		return false
	}

	ct := core_type(x.type)
	if is_type_different_to_arch_endianness(ct) {
		if basic, ok := ct.variant.(Type_Basic); ok {
			if .Endian_Little in basic.flags || .Endian_Big in basic.flags {
				error_node(x.expr, "Expected an integer which does not specify the explicit endianness for '%s'", builtin_name)
				return false
			}
		}
	}

	operand.mode = .Value
	operand.type = make_optional_ok_type(default_type(x.type))
	return true
}

// check_builtin_saturating_arith handles saturating_add, saturating_sub
// C++ Reference: check_builtin.cpp L5382-5423
check_builtin_saturating_arith :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 2 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	builtin_name := builtin_proc_infos[id].name

	x: Operand
	y: Operand
	check_expr(ctx, &x, call.args[0])
	check_expr(ctx, &y, call.args[1])
	if x.mode == .Invalid {
		return false
	}
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &x, y.type)
	if x.mode == .Invalid {
		return false
	}

	if is_type_untyped(x.type) {
		error_node(x.expr, "Expected a typed integer for '%s'", builtin_name)
		return false
	}
	if !is_type_integer(x.type) {
		error_node(x.expr, "Expected an integer for '%s'", builtin_name)
		return false
	}

	ct := core_type(x.type)
	if is_type_different_to_arch_endianness(ct) {
		if basic, ok := ct.variant.(Type_Basic); ok {
			if .Endian_Little in basic.flags || .Endian_Big in basic.flags {
				error_node(x.expr, "Expected an integer which does not specify the explicit endianness for '%s'", builtin_name)
				return false
			}
		}
	}

	operand.mode = .Value
	operand.type = default_type(x.type)
	return true
}

// check_builtin_sqrt handles sqrt(x)
// C++ Reference: check_builtin.cpp L5425-5458
check_builtin_sqrt :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 1 {
		error_node(call, "'sqrt' requires exactly 1 argument, got %d", len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	elem := core_array_type(x.type)
	if !is_type_float(x.type) && !(is_type_simd_vector(x.type) && is_type_float(elem)) {
		error_node(x.expr, "Expected a floating point or #simd vector value for 'sqrt'")
		return false
	}

	if is_type_different_to_arch_endianness(elem) {
		if basic, ok := elem.variant.(Type_Basic); ok {
			if .Endian_Little in basic.flags || .Endian_Big in basic.flags {
				error_node(x.expr, "Expected a float which does not specify the explicit endianness for 'sqrt'")
				return false
			}
		}
	}

	// Constant evaluation for scalar floats
	if is_type_float(x.type) && x.mode == .Constant {
		v := exact_value_to_f64(x.value)
		operand.mode = .Constant
		operand.type = x.type
		operand.value = exact_value_float(math.sqrt(v))
		return true
	}

	operand.mode = .Value
	operand.type = default_type(x.type)
	return true
}

// check_builtin_fused_mul_add handles fused_mul_add(x, y, z) = x * y + z
// C++ Reference: check_builtin.cpp L5461-5500
check_builtin_fused_mul_add :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	if len(call.args) != 3 {
		error_node(call, "'fused_mul_add' requires exactly 3 arguments, got %d", len(call.args))
		return false
	}

	x: Operand
	y: Operand
	z: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}
	check_expr(ctx, &y, call.args[1])
	if y.mode == .Invalid {
		return false
	}
	check_expr(ctx, &z, call.args[2])
	if z.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &x, y.type)
	if x.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &z, x.type)
	if z.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &x, z.type)
	if x.mode == .Invalid {
		return false
	}

	if is_type_untyped(x.type) {
		error_node(x.expr, "Expected a typed floating point value or #simd vector for 'fused_mul_add'")
		return false
	}

	elem := core_array_type(x.type)
	if !is_type_float(x.type) && !(is_type_simd_vector(x.type) && is_type_float(elem)) {
		error_node(x.expr, "Expected a floating point or #simd vector value for 'fused_mul_add'")
		return false
	}

	if is_type_different_to_arch_endianness(elem) {
		if basic, ok := elem.variant.(Type_Basic); ok {
			if .Endian_Little in basic.flags || .Endian_Big in basic.flags {
				error_node(x.expr, "Expected a float which does not specify the explicit endianness for 'fused_mul_add'")
				return false
			}
		}
	}

	operand.mode = .Value
	operand.type = default_type(x.type)
	return true
}

// check_builtin_fixed_point handles fixed_point_mul, fixed_point_div, fixed_point_mul_sat, fixed_point_div_sat
// C++ Reference: check_builtin.cpp L6078-6150
check_builtin_fixed_point :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	if len(call.args) != 3 {
		builtin_name := builtin_proc_infos[id].name
		error_node(call, "'%s' requires exactly 3 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	builtin_name := builtin_proc_infos[id].name

	x: Operand
	y: Operand
	z: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}
	check_expr(ctx, &y, call.args[1])
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &x, y.type)
	if x.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	if !are_types_identical(x.type, y.type) {
		// C++ check_builtin.cpp:6512. NOTE the format: this variant has NO "got". C++ has
		// six spellings of "Mismatched types for" -- three carrying ", got %s vs %s" (the
		// overflow_* family at 5770/5821 and a three-operand one at 5909) and three with a
		// bare ", %s vs %s" (6108, this one, 6577). gotscan.py matched the wrong variant;
		// the oracle settled it.
		error_node(x.expr, "Mismatched types for '%s', %s vs %s", builtin_name, type_to_string(x.type), type_to_string(y.type))
		return false
	}

	if !is_type_integer(x.type) || is_type_untyped(x.type) {
		error_node(x.expr, "Expected an integer type for '%s'", builtin_name)
		return false
	}

	check_expr(ctx, &z, call.args[2])
	if z.mode == .Invalid {
		return false
	}
	if z.mode != .Constant || !is_type_integer(z.type) {
		error_node(z.expr, "Expected a constant integer for the scale in '%s'", builtin_name)
		return false
	}

	n := exact_value_to_i64(z.value)
	if n <= 0 {
		error_node(z.expr, "Scale parameter in '%s' must be positive, got %d", builtin_name, n)
		return false
	}

	sz := i64(8 * type_size_of(x.type))
	if n > sz {
		error_node(z.expr, "Scale parameter in '%s' is larger than the base integer bit width, got %d, expected a maximum of %d", builtin_name, n, sz)
		return false
	}

	operand.type = x.type
	operand.mode = .Value
	return true
}

// =============================================================================
// Memory Intrinsics
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5057-5108 (alloca)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5111-5119 (cpu_relax, trap, debug_trap)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5514-5715 (mem_copy, mem_zero, ptr_offset, ptr_sub)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:5770-5841 (volatile/unaligned/non_temporal store/load)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:6200-6233 (prefetch_*)
// =============================================================================

// is_type_normal_pointer checks if a type is a normal (non-rawptr) pointer
// and optionally returns the element type
// C++ Reference: check_expr.cpp:5900-5910
is_type_normal_pointer :: proc(ptr: ^Type, elem: ^^Type) -> bool {
	t := base_type(ptr)
	if is_type_pointer(t) {
		if is_type_rawptr(t) {
			return false
		}
		if elem != nil {
			elem^ = t.variant.(Type_Pointer).elem
		}
		return true
	}
	return false
}

// check_builtin_alloca validates the alloca intrinsic
// Returns a multi-pointer to u8 for the allocated stack memory
check_builtin_alloca :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "alloca"

	sz: Operand
	al: Operand

	check_expr(ctx, &sz, call.args[0])
	if sz.mode == .Invalid {
		return false
	}
	check_expr(ctx, &al, call.args[1])
	if al.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &sz, t_int)
	if sz.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &al, t_int)
	if al.mode == .Invalid {
		return false
	}

	if !is_type_integer(sz.type) || !is_type_integer(al.type) {
		error_node(operand.expr, "Both parameters to '%s' must be integers", builtin_name)
		return false
	}

	if sz.mode == .Constant {
		i_sz := exact_value_to_i64(sz.value)
		if i_sz < 0 {
			error_node(sz.expr, "Size parameter to '%s' must be non-negative, got %d", builtin_name, i_sz)
			return false
		}
	}

	if al.mode == .Constant {
		i_al := exact_value_to_i64(al.value)
		if i_al < 0 {
			error_node(al.expr, "Alignment parameter to '%s' must be non-negative, got %d", builtin_name, i_al)
			return false
		}
		if i_al > (1 << 29) {
			error_node(al.expr, "Alignment parameter to '%s' must not exceed '1<<29', got %d", builtin_name, i_al)
			return false
		}
		if i_al != 0 && !is_power_of_two(i_al) {
			error_node(al.expr, "Alignment parameter to '%s' must be a power of 2 or 0, got %d", builtin_name, i_al)
			return false
		}
	} else {
		error_node(al.expr, "Alignment parameter to '%s' must be constant", builtin_name)
	}

	operand.type = alloc_type_multi_pointer(t_u8)
	operand.mode = .Value
	return true
}

// check_builtin_cpu_relax validates the cpu_relax intrinsic
// Used to hint to the CPU that the current thread is in a spin-wait loop
check_builtin_cpu_relax :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	operand.mode = .No_Value
	return true
}

// check_builtin_trap validates the trap intrinsic
// Causes an unconditional trap (diverging - never returns)
check_builtin_trap :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	operand.mode = .No_Value
	return true
}

// check_builtin_debug_trap validates the debug_trap intrinsic
// Causes a debug breakpoint trap
check_builtin_debug_trap :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	operand.mode = .No_Value
	return true
}

// check_builtin_mem_copy validates mem_copy and mem_copy_non_overlapping
// mem_copy: intrinsics.mem_copy(dst, src, len)
// mem_copy_non_overlapping: same signature, but asserts no overlap
check_builtin_mem_copy :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	operand.mode = .No_Value
	operand.type = t_invalid

	dst: Operand
	src: Operand
	length: Operand

	check_expr(ctx, &dst, call.args[0])
	check_expr(ctx, &src, call.args[1])
	check_expr(ctx, &length, call.args[2])

	if dst.mode == .Invalid {
		return false
	}
	if src.mode == .Invalid {
		return false
	}
	if length.mode == .Invalid {
		return false
	}

	if !is_type_pointer(dst.type) && !is_type_multi_pointer(dst.type) {
		error_node(dst.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(dst.type))
		return false
	}
	if !is_type_pointer(src.type) && !is_type_multi_pointer(src.type) {
		error_node(src.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(src.type))
		return false
	}
	if !is_type_integer(length.type) {
		error_node(length.expr, "Expected an integer value for the number of bytes for '%s', got %s", builtin_name, type_to_string(length.type))
		return false
	}

	if length.mode == .Constant {
		n := exact_value_to_i64(length.value)
		if n < 0 {
			// C++ check_builtin.cpp:5967 and 6009 pass expr_to_string(len.expr) -- the
			// SOURCE TEXT of the length expression, not its type and not its value.
			len_str := expr_to_string(length.expr)
			defer delete(len_str)
			error_node(length.expr, "Expected a non-negative integer value for the number of bytes for '%s', got %s", builtin_name, len_str)
		}
	}

	return true
}

// check_builtin_mem_zero validates mem_zero and mem_zero_volatile
// mem_zero: intrinsics.mem_zero(ptr, len)
// mem_zero_volatile: same signature, but memory access won't be optimized away
check_builtin_mem_zero :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	operand.mode = .No_Value
	operand.type = t_invalid

	ptr: Operand
	length: Operand

	check_expr(ctx, &ptr, call.args[0])
	check_expr(ctx, &length, call.args[1])

	if ptr.mode == .Invalid {
		return false
	}
	if length.mode == .Invalid {
		return false
	}

	if !is_type_pointer(ptr.type) && !is_type_multi_pointer(ptr.type) {
		error_node(ptr.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(ptr.type))
		return false
	}
	if !is_type_integer(length.type) {
		error_node(length.expr, "Expected an integer value for the number of bytes for '%s', got %s", builtin_name, type_to_string(length.type))
		return false
	}

	if length.mode == .Constant {
		n := exact_value_to_i64(length.value)
		if n < 0 {
			// C++ check_builtin.cpp:5967 and 6009 pass expr_to_string(len.expr) -- the
			// SOURCE TEXT of the length expression, not its type and not its value.
			len_str := expr_to_string(length.expr)
			defer delete(len_str)
			error_node(length.expr, "Expected a non-negative integer value for the number of bytes for '%s', got %s", builtin_name, len_str)
		}
	}

	return true
}

// check_builtin_ptr_offset validates ptr_offset intrinsic
// Returns ptr + offset * sizeof(*ptr)
check_builtin_ptr_offset :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "ptr_offset"

	ptr: Operand
	offset: Operand

	check_expr(ctx, &ptr, call.args[0])
	check_expr(ctx, &offset, call.args[1])

	if ptr.mode == .Invalid {
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}
	if offset.mode == .Invalid {
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	operand.mode = .Value
	operand.type = ptr.type

	if !is_type_pointer(ptr.type) && !is_type_multi_pointer(ptr.type) {
		error_node(ptr.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(ptr.type))
		return false
	}
	if are_types_identical(core_type(ptr.type), t_rawptr) {
		error_node(ptr.expr, "Expected a dereferenceable pointer value for '%s', got %s", builtin_name, type_to_string(ptr.type))
		return false
	}
	if !is_type_integer(offset.type) {
		error_node(offset.expr, "Expected an integer value for the offset parameter for '%s', got %s", builtin_name, type_to_string(offset.type))
		return false
	}

	return true
}

// check_builtin_ptr_sub validates ptr_sub intrinsic
// Returns (ptr0 - ptr1) / sizeof(*ptr0)
check_builtin_ptr_sub :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "ptr_sub"

	ptr0: Operand
	ptr1: Operand

	check_expr(ctx, &ptr0, call.args[0])
	check_expr(ctx, &ptr1, call.args[1])

	if ptr0.mode == .Invalid {
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}
	if ptr1.mode == .Invalid {
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	operand.mode = .Value
	operand.type = t_int

	if !is_type_pointer(ptr0.type) && !is_type_multi_pointer(ptr0.type) {
		error_node(ptr0.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(ptr0.type))
		return false
	}
	if are_types_identical(core_type(ptr0.type), t_rawptr) {
		error_node(ptr0.expr, "Expected a dereferenceable pointer value for '%s', got %s", builtin_name, type_to_string(ptr0.type))
		return false
	}

	if !is_type_pointer(ptr1.type) && !is_type_multi_pointer(ptr1.type) {
		error_node(ptr1.expr, "Expected a pointer value for '%s', got %s", builtin_name, type_to_string(ptr1.type))
		return false
	}
	if are_types_identical(core_type(ptr1.type), t_rawptr) {
		error_node(ptr1.expr, "Expected a dereferenceable pointer value for '%s', got %s", builtin_name, type_to_string(ptr1.type))
		return false
	}

	if !are_types_identical(ptr0.type, ptr1.type) {
		error_node(ptr0.expr, "Mismatched types for '%s', %s vs %s", builtin_name, type_to_string(ptr0.type), type_to_string(ptr1.type))
		return false
	}

	elem := type_deref(ptr0.type)
	if type_size_of(elem) == 0 {
		error_node(ptr0.expr, "Expected a pointer to a non-zero sized element for '%s', got %s", builtin_name, type_to_string(ptr0.type))
		return false
	}

	return true
}

// check_builtin_store validates volatile_store, unaligned_store, non_temporal_store
// All take (ptr, value) and store value at ptr
check_builtin_store :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	// First argument should already be checked
	elem: ^Type = nil
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	x: Operand
	check_expr_with_type_hint(ctx, &x, call.args[1], elem)
	check_assignment(ctx, &x, elem, builtin_name)

	operand.type = nil
	operand.mode = .No_Value
	return true
}

// check_builtin_load validates volatile_load, unaligned_load, non_temporal_load
// All take (ptr) and load the value at ptr
check_builtin_load :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	// First argument should already be checked
	elem: ^Type = nil
	if !is_type_normal_pointer(operand.type, &elem) {
		error_node(operand.expr, "Expected a pointer for '%s'", builtin_name)
		return false
	}

	operand.type = elem
	operand.mode = .Value
	return true
}

// check_builtin_prefetch validates prefetch_read_instruction, prefetch_read_data,
// prefetch_write_instruction, prefetch_write_data
// All take (ptr, locality) where locality is 0..3
check_builtin_prefetch :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	operand.mode = .No_Value
	operand.type = nil

	x: Operand
	y: Operand

	check_expr(ctx, &x, call.args[0])
	check_expr(ctx, &y, call.args[1])

	if x.mode == .Invalid {
		return false
	}
	if y.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &x, t_rawptr, builtin_name)
	if x.mode == .Invalid {
		return false
	}

	if y.mode != .Constant || !is_type_integer(y.type) {
		error_node(y.expr, "Second argument to '%s' representing the locality must be an integer in the range 0..=3", builtin_name)
		return false
	}

	locality := exact_value_to_i64(y.value)
	if !(0 <= locality && locality <= 3) {
		error_node(y.expr, "Second argument to '%s' representing the locality must be an integer in the range 0..=3", builtin_name)
		return false
	}

	return true
}

// is_package_imported
check_builtin_is_package_imported :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "is_package_imported"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant || !is_type_string(x.type) {
		error_node(x.expr, "Argument to '%s' must be a constant string", builtin_name)
		return false
	}

	// Get the package path from the constant string
	pkg_path, _ := x.value.(string)   // raw string, as C++ reads ev.value_string

	// Check if the package is imported by looking up in the checker's packages map
	// C++ Reference: check_builtin.cpp:3795-3820
	is_imported := false

	// Check if the package exists in the loaded packages
	if ctx.info != nil {
		_, found := ctx.info.packages[pkg_path]
		is_imported = found
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(is_imported)

	return true
}

// read_cycle_counter
check_builtin_read_cycle_counter :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "read_cycle_counter"

	if len(call.args) != 0 {
		error_node(call, "'%s' expects no arguments", builtin_name)
		return false
	}

	// C++ check_builtin.cpp:5549-5551 returns t_i64, NOT t_u64. The port's u64 made
	// `cast(u64)intrinsics.read_cycle_counter()` look like a cast to its own type, so -vet
	// reported "Unneeded cast ... to identical type 'u64'" on core/testing/runner.odin:508
	// where the real compiler reports nothing. This is a TYPE bug surfaced by a message:
	// the expression's type was wrong, not just its diagnostic. LEDGER 292.
	operand.mode = .Value
	operand.type = t_i64

	return true
}

// read_cycle_counter_frequency
check_builtin_read_cycle_counter_frequency :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "read_cycle_counter_frequency"

	if len(call.args) != 0 {
		error_node(call, "'%s' expects no arguments", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = t_i64

	return true
}

// expect
check_builtin_expect :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "expect"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	// `expect` is NOT boolean-only. C++ (check_builtin.cpp:6560-6604) unifies the two
	// operands, requires them to be the SAME type, and then requires that type to be
	// integer-LIKE -- integer, boolean, enum or bit_set. The port's version demanded a
	// boolean first argument and a constant boolean second, which rejected the common
	// enum form, e.g. core/encoding/xml's
	//     likely :: intrinsics.expect
	//     if likely(open.kind, Token_Kind.Ident) == .Ident { ... }
	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}
	convert_to_typed(ctx, &x, y.type)

	if !are_types_identical(x.type, y.type) {
	// NOTE: type_to_string returns either a string LITERAL ("<no type>", "<invalid>")
	// or a builder over context.temp_allocator -- never a context.allocator allocation.
	// `delete` on it frees a non-heap pointer and aborts with "free(): invalid pointer".
	// (expr_to_string is the opposite: it clones into context.allocator and MUST be freed.)
		xts := type_to_string(x.type)
		yts := type_to_string(y.type)
		error_node(x.expr, "Mismatched types for '%s', %s vs %s", builtin_name, xts, yts)
		operand^ = x // minimize error propagation
		return true
	}

	if !is_type_integer_like(x.type) {
		xts := type_to_string(x.type)
		error_node(x.expr, "Values passed to '%s' must be an integer-like type (integer, boolean, enum, bit_set), got %s", builtin_name, xts)
		operand^ = x
		return true
	}

	// Not fatal in C++: it reports and carries on.
	if y.mode != .Constant {
		error_node(y.expr, "Second argument to '%s' must be constant as it is the expected value", builtin_name)
	}

	if x.mode == .Constant {
		// C++: "just completely ignore this intrinsic entirely"
		operand^ = x
		return true
	}

	operand.mode = .Value
	operand.type = x.type

	return true
}

// syscall / syscall_bsd
check_builtin_syscall :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := id == .Syscall ? "syscall" : "syscall_bsd"

	if len(call.args) < 1 {
		error_node(call, "'%s' expects at least 1 argument (the syscall number)", builtin_name)
		return false
	}

	if len(call.args) > 7 {
		error_node(call, "'%s' expects at most 7 arguments", builtin_name)
		return false
	}

	// Check all arguments are uintptr
	for arg in call.args {
		x: Operand
		check_expr(ctx, &x, arg)

		if x.mode == .Invalid {
			return false
		}

		check_assignment(ctx, &x, t_uintptr, builtin_name)
		if x.mode == .Invalid {
			return false
		}
	}

	operand.mode = .Value

	// C++ Reference: check_builtin.cpp:6716 vs 6765.
	//
	// `syscall` yields a bare uintptr, but `syscall_bsd` yields an OPTIONAL-OK
	// tuple `(uintptr, bool)` - the BSD calling convention reports failure in the
	// carry flag. The port returned a bare uintptr for both, so every
	// `result, ok := intrinsics.syscall_bsd(...)` in core/sys/freebsd was an
	// assignment count mismatch.
	if id == .Syscall_Bsd {
		operand.type = make_optional_ok_type(t_uintptr)
	} else {
		operand.type = t_uintptr
	}

	return true
}

// wasm_memory_grow
check_builtin_wasm_memory_grow :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "wasm_memory_grow"

	if !is_arch_wasm() {
		error_node(call, "'%s' is only available on WebAssembly targets", builtin_name)
		return false
	}

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	// First argument: memory index (i32)
	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant || !is_type_integer(x.type) {
		error_node(x.expr, "First argument to '%s' (memory index) must be a constant integer", builtin_name)
		return false
	}

	// Second argument: delta (uintptr)
	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &y, t_uintptr, builtin_name)
	if y.mode == .Invalid {
		return false
	}

	operand.mode = .Value
	operand.type = t_int

	return true
}

// wasm_memory_size
check_builtin_wasm_memory_size :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "wasm_memory_size"

	if !is_arch_wasm() {
		error_node(call, "'%s' is only available on WebAssembly targets", builtin_name)
		return false
	}

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	// First argument: memory index (i32)
	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant || !is_type_integer(x.type) {
		error_node(x.expr, "Argument to '%s' (memory index) must be a constant integer", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = t_int

	return true
}

// wasm_memory_atomic_wait32
check_builtin_wasm_memory_atomic_wait32 :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "wasm_memory_atomic_wait32"

	if !is_arch_wasm() {
		error_node(call, "'%s' is only available on WebAssembly targets", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:7868-7871
	// TODO: Check if "atomics" feature is enabled via target_features_set
	// This requires frontend integration to populate the features set

	if len(call.args) != 3 {
		error_node(call, "'%s' expects 3 arguments", builtin_name)
		return false
	}

	// First argument: pointer to i32
	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	ptr_type := alloc_type_pointer(t_i32)
	check_assignment(ctx, &x, ptr_type, builtin_name)
	if x.mode == .Invalid {
		return false
	}

	// Second argument: expected value (i32)
	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &y, t_i32, builtin_name)
	if y.mode == .Invalid {
		return false
	}

	// Third argument: timeout (i64)
	z: Operand
	check_expr(ctx, &z, call.args[2])

	if z.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &z, t_i64, builtin_name)
	if z.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:7912-7913 - returns u32
	operand.mode = .Value
	operand.type = t_u32

	return true
}

// wasm_memory_atomic_notify32
check_builtin_wasm_memory_atomic_notify32 :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "wasm_memory_atomic_notify32"

	if !is_arch_wasm() {
		error_node(call, "'%s' is only available on WebAssembly targets", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:7925-7928
	// TODO: Check if "atomics" feature is enabled via target_features_set
	// This requires frontend integration to populate the features set

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	// First argument: pointer to i32
	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	ptr_type := alloc_type_pointer(t_i32)
	check_assignment(ctx, &x, ptr_type, builtin_name)
	if x.mode == .Invalid {
		return false
	}

	// Second argument: count (i32)
	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &y, t_i32, builtin_name)
	if y.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:7957-7958 - returns u32
	operand.mode = .Value
	operand.type = t_u32

	return true
}

// hadamard_product - element-wise matrix multiplication
check_builtin_hadamard_product :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "hadamard_product"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	if !is_type_matrix(x.type) {
		error_node(x.expr, "First argument to '%s' must be a matrix type, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	if !is_type_matrix(y.type) {
		error_node(y.expr, "Second argument to '%s' must be a matrix type, got '%s'", builtin_name, type_to_string(y.type))
		return false
	}

	// Matrices must have same dimensions
	if !are_types_identical(x.type, y.type) {
		error_node(call, "'%s' requires both matrices to have identical types", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type

	return true
}

// matrix_flatten - flatten matrix to array
check_builtin_matrix_flatten :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "matrix_flatten"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if !is_type_matrix(x.type) {
		error_node(x.expr, "Argument to '%s' must be a matrix type, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	// Result is an array with rows * columns elements
	mat := base_type(x.type).variant.(Type_Matrix)
	elem_count := mat.row_count * mat.column_count
	result_type := alloc_type_array(mat.elem, i64(elem_count))

	operand.mode = .Value
	operand.type = result_type

	return true
}

// outer_product - outer product of two vectors
check_builtin_outer_product :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "outer_product"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	// Both arguments must be arrays (vectors)
	if !is_type_array(x.type) {
		error_node(x.expr, "First argument to '%s' must be an array (vector) type, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	if !is_type_array(y.type) {
		error_node(y.expr, "Second argument to '%s' must be an array (vector) type, got '%s'", builtin_name, type_to_string(y.type))
		return false
	}

	x_array := base_type(x.type).variant.(Type_Array)
	y_array := base_type(y.type).variant.(Type_Array)

	// Element types must be compatible numeric types
	if !are_types_identical(x_array.elem, y_array.elem) {
		error_node(call, "'%s' requires both vectors to have the same element type", builtin_name)
		return false
	}

	if !is_type_numeric(x_array.elem) {
		error_node(call, "'%s' requires numeric element type", builtin_name)
		return false
	}

	// Result is a matrix[M, N] where M = len(x), N = len(y)
	result_type := alloc_type_matrix(x_array.elem, x_array.count, y_array.count, nil, nil, false)

	operand.mode = .Value
	operand.type = result_type

	return true
}

// transpose - transpose matrix
check_builtin_transpose :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "transpose"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if !is_type_matrix(x.type) {
		error_node(x.expr, "Argument to '%s' must be a matrix type, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	// Result has swapped dimensions
	mat := base_type(x.type).variant.(Type_Matrix)
	result_type := alloc_type_matrix(mat.elem, mat.column_count, mat.row_count, nil, nil, mat.is_row_major)

	operand.mode = .Value
	operand.type = result_type

	return true
}

// constant_ceil, constant_floor, constant_round, constant_trunc
check_builtin_constant_rounding :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name: string
	#partial switch id {
	case .Constant_Ceil:
		builtin_name = "constant_ceil"
	case .Constant_Floor:
		builtin_name = "constant_floor"
	case .Constant_Round:
		builtin_name = "constant_round"
	case .Constant_Trunc:
		builtin_name = "constant_trunc"
	case:
		builtin_name = "constant_rounding"
	}

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant {
		error_node(x.expr, "Argument to '%s' must be a constant", builtin_name)
		return false
	}

	if !is_type_float(x.type) && !is_type_untyped(x.type) {
		error_node(x.expr, "Argument to '%s' must be a floating-point constant, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	// Apply the rounding operation at compile time
	if f, ok := x.value.(f64); ok {
		result: f64
		#partial switch id {
		case .Constant_Ceil:
			result = math.ceil(f)
		case .Constant_Floor:
			result = math.floor(f)
		case .Constant_Round:
			result = math.round(f)
		case .Constant_Trunc:
			result = math.trunc(f)
		case:
			result = f
		}
		operand.mode = .Constant
		operand.type = x.type
		operand.value = result
	} else {
		operand.mode = .Constant
		operand.type = x.type
		operand.value = x.value
	}

	return true
}

// constant_log2
check_builtin_constant_log2 :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "constant_log2"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:5119. The condition really is `&&`, so a
	// constant of any numeric kind is accepted; mirrored verbatim rather than
	// tightened, since tightening it here would reject code the real compiler builds.
	if !is_type_integer(x.type) && x.mode != .Constant {
		error_node(call.args[0], "Expected a constant integer for '%s'", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:5123-5127. This is an EXACT integer result —
	// `big_int_log2` is `mp_count_bits(x) - 1`, i.e. the index of the highest set bit
	// (floor of log2) — and the operand type is `t_untyped_integer`.
	//
	// The port previously computed `math.log2_f64` and returned `t_untyped_float`, so
	// every use of the result in an integer context failed with
	// "'untyped float' truncated to 'u32'". core/sys/linux/bits.odin defines
	// `log2 :: intrinsics.constant_log2` and uses it for whole enum bodies.
	log2_result: i64
	#partial switch v in x.value {
	case big.Int:
		bi := v
		bits, err := big.count_bits(&bi)
		if err != nil {
			error_node(call.args[0], "Expected a constant integer for '%s'", builtin_name)
			return false
		}
		log2_result = i64(bits) - 1
	case:
		i := exact_value_to_i64(x.value)
		bits := 0
		for u := u64(i); u != 0; u >>= 1 {
			bits += 1
		}
		log2_result = i64(bits) - 1
	}

	operand.mode = .Constant
	operand.value = exact_value_i64(log2_result)
	operand.type = t_untyped_integer

	return true
}

// constant_utf16_cstring
check_builtin_constant_utf16_cstring :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, type_hint: ^Type) -> bool {
	builtin_name := "constant_utf16_cstring"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant {
		error_node(x.expr, "Argument to '%s' must be a constant string", builtin_name)
		return false
	}

	if !is_type_string(x.type) {
		error_node(x.expr, "Argument to '%s' must be a string, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	// C++ Reference: check_builtin.cpp:7784-7788
	// Use type_hint to determine return type
	operand.mode = .Value
	if type_hint != nil && is_type_string16(type_hint) {
		operand.type = t_string16
	} else {
		operand.type = t_cstring16
	}

	return true
}

// x86_cpuid
check_builtin_x86_cpuid :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "x86_cpuid"

	if !is_arch_x86() {
		error_node(call, "'%s' is only available on x86/x86_64 targets", builtin_name)
		return false
	}

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments (leaf, subleaf)", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &x, t_u32, builtin_name)
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr(ctx, &y, call.args[1])

	if y.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &y, t_u32, builtin_name)
	if y.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:7990-7991
	// Returns (u32, u32, u32, u32) tuple (eax, ebx, ecx, edx)
	result_type := alloc_type_tuple_from_field_types(ctx.checker, {t_u32, t_u32, t_u32, t_u32})

	operand.mode = .Value
	operand.type = result_type

	return true
}

// x86_xgetbv
check_builtin_x86_xgetbv :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "x86_xgetbv"

	if !is_arch_x86() {
		error_node(call, "'%s' is only available on x86/x86_64 targets", builtin_name)
		return false
	}

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument (xcr index)", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	check_assignment(ctx, &x, t_u32, builtin_name)
	if x.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:8014-8015
	// Returns (u32, u32) tuple (eax, edx)
	result_type := alloc_type_tuple_from_field_types(ctx.checker, {t_u32, t_u32})

	operand.mode = .Value
	operand.type = result_type

	return true
}

// valgrind_client_request
// NOTE(bill): Check it but make it a no-op for non x86 (i386, amd64) targets
check_builtin_valgrind_client_request :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "valgrind_client_request"
	ARG_COUNT :: 7

	if len(call.args) != ARG_COUNT {
		error_node(call, "'%s' expects %d arguments", builtin_name, ARG_COUNT)
		return false
	}

	// All 7 arguments must be uintptr
	for arg in call.args {
		x: Operand
		check_expr_with_type_hint(ctx, &x, arg, t_uintptr)

		if x.mode == .Invalid {
			return false
		}

		check_assignment(ctx, &x, t_uintptr, builtin_name)
		if x.mode == .Invalid {
			return false
		}
	}

	operand.mode = .Value
	operand.type = t_uintptr

	return true
}

// has_target_feature
check_builtin_has_target_feature :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "has_target_feature"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])

	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Constant || !is_type_string(x.type) {
		error_node(x.expr, "Argument to '%s' must be a constant string", builtin_name)
		return false
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	// The actual value would be determined by checking target features
	operand.value = exact_value_bool(false)

	return true
}

// concatenate - concatenate arrays at compile time
check_builtin_concatenate :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "concatenate"

	if len(call.args) < 1 {
		error_node(call, "'%s' expects at least 1 argument", builtin_name)
		return false
	}

	// Check first argument to get element type
	first: Operand
	check_expr(ctx, &first, call.args[0])

	if first.mode == .Invalid {
		return false
	}

	if !is_type_array(first.type) && !is_type_string(first.type) {
		error_node(first.expr, "Arguments to '%s' must be arrays or strings", builtin_name)
		return false
	}

	total_count: i64 = 0
	elem_type: ^Type

	if is_type_string(first.type) {
		elem_type = t_u8
		if str, ok := first.value.(string); ok {
			total_count = i64(len(str))
		}
	} else {
		arr := base_type(first.type).variant.(Type_Array)
		elem_type = arr.elem
		total_count = arr.count
	}

	// Check remaining arguments
	for i := 1; i < len(call.args); i += 1 {
		arg: Operand
		check_expr(ctx, &arg, call.args[i])

		if arg.mode == .Invalid {
			return false
		}

		if is_type_string(arg.type) {
			if !is_type_string(first.type) {
				error_node(arg.expr, "All arguments to '%s' must have the same type", builtin_name)
				return false
			}
			if str, ok := arg.value.(string); ok {
				total_count += i64(len(str))
			}
		} else if is_type_array(arg.type) {
			arr := base_type(arg.type).variant.(Type_Array)
			if !are_types_identical(arr.elem, elem_type) {
				error_node(arg.expr, "All arrays in '%s' must have the same element type", builtin_name)
				return false
			}
			total_count += arr.count
		} else {
			error_node(arg.expr, "Arguments to '%s' must be arrays or strings", builtin_name)
			return false
		}
	}

	if is_type_string(first.type) {
		operand.mode = .Value
		operand.type = t_string
	} else {
		result_type := alloc_type_array(elem_type, total_count)
		operand.mode = .Value
		operand.type = result_type
	}

	return true
}

// soa_struct - create SOA type from struct
check_builtin_soa_struct :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "soa_struct"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments (count, struct type)", builtin_name)
		return false
	}

	// First argument: count
	count_op: Operand
	check_expr(ctx, &count_op, call.args[0])

	if count_op.mode == .Invalid {
		return false
	}

	if count_op.mode != .Constant || !is_type_integer(count_op.type) {
		error_node(count_op.expr, "First argument to '%s' must be a constant integer", builtin_name)
		return false
	}

	// Second argument: struct type
	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[1])

	if type_op.mode == .Invalid {
		return false
	}

	if type_op.mode != .Type {
		error_node(type_op.expr, "Second argument to '%s' must be a type", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:4808-4921
	// Accept struct type or small array (≤4 elements)
	elem := type_op.type
	bt := base_type(elem)

	// Get count value first
	count := exact_value_to_i64(count_op.value)

	soa_struct: ^Type

	if arr, arr_ok := bt.variant.(Type_Array); arr_ok {
		// Array case (≤4 elements): create anonymous struct with indexed fields
		// C++ lines 4850-4881
		if arr.count > 4 {
			error_node(type_op.expr, "Invalid type for '%s', expected a struct or array of length 4 or below, got '%s'", builtin_name, type_to_string(type_op.type))
			return false
		}

		array_elem := arr.elem
		soa_struct = alloc_type_struct(ctx.checker)
		ts := &soa_struct.variant.(Type_Struct)

		ts.node = call
		ts.soa_kind = .Fixed
		ts.soa_elem = array_elem
		ts.soa_count = count

		// Create scope for the new struct
		ts.scope = create_scope(ctx.scope, ctx.checker.allocator)
		if ts.scope != nil {
			ts.scope.flags += {.Type}
		}

		// Create fields named _0, _1, _2, etc.
		for i in 0 ..< arr.count {
			name := fmt.tprintf("_%d", i)
			field_type := alloc_type_array(array_elem, count)
			new_field := alloc_entity_field(ts.scope, make_token_ident(name), field_type, false, i32(i))
			append(&ts.fields, new_field)
			append(&ts.tags, "")
		}

		// Mark as completed
		sync.wait_group_done(&ts.fields_wait_signal)

	} else if is_type_struct(elem) {
		// Struct case: use make_soa_struct_fixed
		// C++ line 4883-4912
		soa_struct = make_soa_struct_fixed(ctx, call, call.args[1], elem, count, nil)
	} else {
		error_node(type_op.expr, "Invalid type for '%s', expected a struct or array of length 4 or below, got '%s'", builtin_name, type_to_string(type_op.type))
		return false
	}

	if soa_struct == nil || soa_struct == t_invalid {
		return false
	}

	add_type_info_type(ctx, soa_struct)

	operand.mode = .Type
	operand.type = soa_struct

	return true
}

// procedure_of - get procedure from method value
// C++ Reference: check_builtin.cpp:7737-7770
check_builtin_procedure_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "procedure_of"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	arg := call.args[0]

	// C++ Reference: check_builtin.cpp:7741-7746
	// The argument must be a call expression (method call)
	call_arg, is_call := arg.derived.(^ast.Call_Expr)
	if !is_call {
		error_node(arg, "'%s' expects a procedure call expression", builtin_name)
		return false
	}

	x: Operand
	check_expr(ctx, &x, call_arg.expr)

	if x.mode == .Invalid {
		return false
	}

	// C++ Reference: check_builtin.cpp:7748-7752
	// Handle builtin procedures - they don't have a procedure type
	if x.mode == .Builtin {
		error_node(arg, "'%s' does not work on built-in procedures", builtin_name)
		return false
	}

	if !is_type_proc(x.type) {
		error_node(x.expr, "Argument to '%s' must be a procedure call, got '%s'", builtin_name, type_to_string(x.type))
		return false
	}

	// C++ Reference: check_builtin.cpp:7753-7756
	// Store entity for later use and return the actual procedure type
	e := entity_of_node(&ctx.checker.info, call_arg.expr)
	if e != nil {
		set_ast_entity(ctx.info, call, e)
	}

	operand.mode = .Value
	operand.type = x.type
	operand.value = x.value

	return true
}

// type_field_type - get the type of a field by name
check_builtin_type_field_type :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_field_type"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments (type, field_name)", builtin_name)
		return false
	}

	// First argument: struct/union type
	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_struct(type_op.type) && !is_type_union(type_op.type) {
		error_node(call.args[0], "First argument to '%s' must be a struct or union type", builtin_name)
		return false
	}

	// Second argument: field name (constant string)
	name_op: Operand
	check_expr(ctx, &name_op, call.args[1])

	if name_op.mode != .Constant || !is_type_string(name_op.type) {
		error_node(call.args[1], "Second argument to '%s' must be a constant string", builtin_name)
		return false
	}

	// Get the field name from the constant string value
	field_name, _ := name_op.value.(string)   // raw string, as C++ reads ev.value_string

	// C++ Reference: check_builtin.cpp, BuiltinProc_type_field_type:
	//     Selection sel = lookup_field(type, field_name, false);
	//     if (sel.index.count == 0) { error(...); }
	//     operand->type = sel.entity->type;
	//
	// This previously hand-rolled a FLAT scan of `Type_Struct.fields`, which does not
	// follow `using`/embedded fields the way lookup_field does. A field reached through
	// an embedded struct -- core/sys/orca's `str8_elt`, whose `listElt` comes from an
	// embedded member -- was reported as absent, so `container_of`'s `where` clause
	// failed on a type that genuinely has the field.
	sel := lookup_field(type_op.type, field_name, false)
	if len(sel.index) == 0 || sel.entity == nil {
		error_node(call, "Type '%s' has no field named '%s'", type_to_string(type_op.type), field_name)
		return false
	}
	field_type := entity_type(sel.entity)

	operand.mode = .Type
	operand.type = field_type

	return true
}

// type_has_field - check if a type has a field with the given name
check_builtin_type_has_field :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_has_field"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments (type, field_name)", builtin_name)
		return false
	}

	// First argument: struct/union type
	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	// Second argument: field name (constant string)
	name_op: Operand
	check_expr(ctx, &name_op, call.args[1])

	if name_op.mode != .Constant || !is_type_string(name_op.type) {
		error_node(call.args[1], "Second argument to '%s' must be a constant string", builtin_name)
		return false
	}

	// Get the field name from the constant string value
	field_name, ok := name_op.value.(string)
	if !ok {
		error_node(call.args[1], "Could not evaluate field name as string constant")
		return false
	}

	// C++ Reference: check_builtin.cpp, BuiltinProc_type_has_field:
	//     Selection sel = lookup_field(type, field_name, false);
	//     operand->value = exact_value_bool(sel.index.count != 0);
	//
	// Two things the port had wrong. `is_type` must be FALSE -- passing true asks for
	// type-level members (enum constants and the like), not struct fields, so
	// `type_has_field(S, "a")` never found `a` and the intrinsic answered false for
	// EVERY struct field. And the result is the SELECTION PATH being non-empty, not
	// `sel.entity != nil`.
	sel := lookup_field(type_op.type, field_name, false)
	result := len(sel.index) != 0

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(result)

	return true
}

// type_has_shared_fields - check if union has shared fields
check_builtin_type_has_shared_fields :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_has_shared_fields"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_union(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be a union type", builtin_name)
		return false
	}

	// Check if union has shared fields
	// NOTE: Odin's Type_Union does not have shared_fields - always returns false
	result := false

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(result)

	return true
}

// type_is_specialization_of - check if T is a specialization of S
check_builtin_type_is_specialization_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_is_specialization_of"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	type1_op: Operand
	check_expr_or_type(ctx, &type1_op, call.args[0])

	if type1_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	type2_op: Operand
	check_expr_or_type(ctx, &type2_op, call.args[1])

	if type2_op.mode != .Type {
		error_node(call.args[1], "Second argument to '%s' must be a type", builtin_name)
		return false
	}

	// Check if type1 is a specialization of type2 (polymorphic parent relationship)
	result := false
	bt1 := base_type(type1_op.type)
	bt2 := base_type(type2_op.type)
	if struct_type, struct_ok := bt1.variant.(Type_Struct); struct_ok {
		if struct_type.polymorphic_parent != nil {
			result = are_types_identical(base_type(struct_type.polymorphic_parent), bt2)
		}
	} else if union_type, union_ok := bt1.variant.(Type_Union); union_ok {
		if union_type.polymorphic_parent != nil {
			result = are_types_identical(base_type(union_type.polymorphic_parent), bt2)
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(result)

	return true
}

// type_is_superset_of - check if T is a superset of S (for bit sets)
check_builtin_type_is_superset_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_is_superset_of"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	type1_op: Operand
	check_expr_or_type(ctx, &type1_op, call.args[0])

	if type1_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	type2_op: Operand
	check_expr_or_type(ctx, &type2_op, call.args[1])

	if type2_op.mode != .Type {
		error_node(call.args[1], "Second argument to '%s' must be a type", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:7939-8038
	//
	// NOTE: this applies to ENUMS and UNIONS, not bit_sets. The port previously
	// had a bit_set-only range comparison with no C++ counterpart, so every
	// enum query - such as core/os/file_stream.odin's
	// `#assert(type_is_superset_of(File_Stream_Mode, io.Stream_Mode))` -
	// silently answered false.
	operand.mode = .Constant
	operand.type = t_untyped_bool

	super := type1_op.type
	sub := type2_op.type
	if are_types_identical(super, sub) {
		operand.value = exact_value_bool(true)
		return true
	}

	super = base_type(super)
	sub = base_type(sub)
	if are_types_identical(super, sub) {
		operand.value = exact_value_bool(true)
		return true
	}

	if super == nil || sub == nil || super.kind != sub.kind {
		a := type_to_string(type1_op.type)
		b := type_to_string(type2_op.type)
		error_node(call.args[0], "'%s' expects types of the same kind, got %s vs %s", builtin_name, a, b)
		return false
	}

	#partial switch super.kind {
	case .Enum:
		super_enum := &super.variant.(Type_Enum)
		sub_enum := &sub.variant.(Type_Enum)

		if len(sub_enum.fields) > len(super_enum.fields) {
			operand.value = exact_value_bool(false)
			return true
		}

		base_super := base_enum_type(super)
		base_sub := base_enum_type(sub)
		if base_super == nil && base_sub == nil {
			// okay
		} else if !are_types_identical(base_type(base_super), base_type(base_sub)) {
			operand.value = exact_value_bool(false)
			return true
		}

		// Every member of the subset must appear in the superset with the same value.
		for f_sub in sub_enum.fields {
			if f_sub == nil || f_sub.kind != .Constant {
				continue
			}
			sub_const := &f_sub.variant.(Entity_Constant)

			found := false
			for f_super in super_enum.fields {
				if f_super == nil || f_super.kind != .Constant {
					continue
				}
				if f_sub.token.text != f_super.token.text {
					continue
				}
				super_const := &f_super.variant.(Entity_Constant)
				if compare_exact_values(.Cmp_Eq, sub_const.value, super_const.value) {
					found = true
					break
				}
			}

			if !found {
				operand.value = exact_value_bool(false)
				return true
			}
		}

		operand.value = exact_value_bool(true)
		return true

	case .Union:
		super_union := &super.variant.(Type_Union)
		sub_union := &sub.variant.(Type_Union)

		if len(sub_union.variants) > len(super_union.variants) {
			operand.value = exact_value_bool(false)
			return true
		}
		if sub_union.kind != super_union.kind {
			operand.value = exact_value_bool(false)
			return true
		}

		// Positional: the subset's variants must prefix the superset's.
		for t_sub, i in sub_union.variants {
			if !are_types_identical(t_sub, super_union.variants[i]) {
				operand.value = exact_value_bool(false)
				return true
			}
		}

		operand.value = exact_value_bool(true)
		return true
	}

	a := type_to_string(type1_op.type)
	b := type_to_string(type2_op.type)
	error_node(call.args[0], "'%s' expects types of the same kind and either an enum or union, got %s vs %s", builtin_name, a, b)
	return false
}

// type_is_variant_of - check if T is a variant of union U
check_builtin_type_is_variant_of :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_is_variant_of"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	type1_op: Operand
	check_expr_or_type(ctx, &type1_op, call.args[0])

	if type1_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	type2_op: Operand
	check_expr_or_type(ctx, &type2_op, call.args[1])

	if type2_op.mode != .Type {
		error_node(call.args[1], "Second argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_union(type2_op.type) {
		error_node(call.args[1], "Second argument to '%s' must be a union type", builtin_name)
		return false
	}

	// Check if type1 is a variant of union type2
	result := false
	bt2 := base_type(type2_op.type)
	if union_type, ok := bt2.variant.(Type_Union); ok {
		for variant in union_type.variants {
			if are_types_identical(type1_op.type, variant) {
				result = true
				break
			}
		}
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(result)

	return true
}

// type_integer_to_signed - convert integer type to signed equivalent
check_builtin_type_integer_to_signed :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_integer_to_signed"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_integer(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be an integer type", builtin_name)
		return false
	}

	// Get signed equivalent
	signed_type := integer_to_signed(type_op.type)

	operand.mode = .Type
	operand.type = signed_type

	return true
}

// type_integer_to_unsigned - convert integer type to unsigned equivalent
check_builtin_type_integer_to_unsigned :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_integer_to_unsigned"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_integer(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be an integer type", builtin_name)
		return false
	}

	// Get unsigned equivalent
	unsigned_type := integer_to_unsigned(type_op.type)

	operand.mode = .Type
	operand.type = unsigned_type

	return true
}

// type_merge - merge two compatible types
check_builtin_type_merge :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_merge"

	if len(call.args) != 2 {
		error_node(call, "'%s' expects 2 arguments", builtin_name)
		return false
	}

	type1_op: Operand
	check_expr_or_type(ctx, &type1_op, call.args[0])

	if type1_op.mode != .Type {
		error_node(call.args[0], "First argument to '%s' must be a type", builtin_name)
		return false
	}

	type2_op: Operand
	check_expr_or_type(ctx, &type2_op, call.args[1])

	if type2_op.mode != .Type {
		error_node(call.args[1], "Second argument to '%s' must be a type", builtin_name)
		return false
	}

	// C++ Reference: check_builtin.cpp:6507-6560
	// Validate both are non-polymorphic union types
	if is_type_polymorphic(type1_op.type, false) {
		error_node(call.args[0], "Expected a non-polymorphic type for '%s', got '%s'", builtin_name, type_to_string(type1_op.type))
		return false
	}
	if is_type_polymorphic(type2_op.type, false) {
		error_node(call.args[1], "Expected a non-polymorphic type for '%s', got '%s'", builtin_name, type_to_string(type2_op.type))
		return false
	}

	if !is_type_union(type1_op.type) {
		error_node(call.args[0], "Expected a union type for '%s', got '%s'", builtin_name, type_to_string(type1_op.type))
		return false
	}
	if !is_type_union(type2_op.type) {
		error_node(call.args[1], "Expected a union type for '%s', got '%s'", builtin_name, type_to_string(type2_op.type))
		return false
	}

	ux := base_type(type1_op.type)
	uy := base_type(type2_op.type)
	union_x := ux.variant.(Type_Union)
	union_y := uy.variant.(Type_Union)

	// Check union kinds match
	if union_x.kind != union_y.kind {
		error_node(call.args[0], "Union kinds must match for '%s'", builtin_name)
		operand.mode = .Type
		operand.type = t_invalid
		return true
	}

	// Create merged union type
	merged := alloc_type_union(ctx.checker)
	merged_union := &merged.variant.(Type_Union)

	// Copy properties
	merged_union.kind = union_x.kind
	merged_union.custom_align = max(union_x.custom_align, union_y.custom_align)
	merged_union.node = call
	merged_union.scope = union_x.scope

	// Add variants from first union
	for variant in union_x.variants {
		append(&merged_union.variants, variant)
	}

	// Add variants from second union (avoiding duplicates)
	for y_variant in union_y.variants {
		found := false
		for x_variant in union_x.variants {
			if are_types_identical(x_variant, y_variant) {
				found = true
				break
			}
		}
		if !found {
			append(&merged_union.variants, y_variant)
		}
	}

	operand.mode = .Type
	operand.type = merged

	return true
}

// type_convert_variants_to_pointers - convert union variants to pointer types
check_builtin_type_convert_variants_to_pointers :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_convert_variants_to_pointers"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	bt := base_type(type_op.type)

	// Handle polymorphic types - just return
	// C++ Reference: check_builtin.cpp:6387-6389
	if is_type_polymorphic(bt, false) {
		operand.mode = .Type
		operand.type = type_op.type
		return true
	}

	if !is_type_union(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be a union type", builtin_name)
		return false
	}

	union_type := bt.variant.(Type_Union)
	if union_type.is_polymorphic {
		error_node(call.args[0], "Expected a non-polymorphic union type for '%s', got '%s'", builtin_name, type_to_string(type_op.type))
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	// Create new union type with pointer variants
	// C++ Reference: check_builtin.cpp:6407-6422
	new_type := alloc_type_union(ctx.checker)
	new_union := &new_type.variant.(Type_Union)

	// Create pointer type for each variant
	for variant in union_type.variants {
		ptr_type := alloc_type_pointer(variant)
		append(&new_union.variants, ptr_type)
	}

	// Copy properties from original union
	new_union.node = type_op.expr
	new_union.scope = union_type.scope
	if union_type.kind == .No_Nil {
		new_union.kind = .No_Nil
	}

	operand.mode = .Type
	operand.type = new_type

	return true
}

// type_union_base_tag_value - get the base tag value for a union
check_builtin_type_union_base_tag_value :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_union_base_tag_value"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_union(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be a union type", builtin_name)
		return false
	}

	// Base tag value depends on union kind:
	// - Normal, Maybe, Shared_Nil: nil is 0, first variant is 1 → base = 1
	// - No_Nil: no nil value, first variant is 0 → base = 0
	bt := base_type(type_op.type)
	union_type := bt.variant.(Type_Union)
	base_value: i64 = union_type.kind == .No_Nil ? 0 : 1

	operand.mode = .Constant
	operand.type = t_int
	operand.value = exact_value_i64(base_value)

	return true
}

// type_union_tag_offset - get the tag offset within a union
check_builtin_type_union_tag_offset :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_union_tag_offset"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_union(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be a union type", builtin_name)
		return false
	}

	// Tag offset is variant_block_size (where tag starts after payload)
	bt := base_type(type_op.type)
	union_type := bt.variant.(Type_Union)
	tag_offset := union_type.variant_block_size

	operand.mode = .Constant
	operand.type = t_uintptr
	operand.value = exact_value_i64(tag_offset)

	return true
}

// type_union_tag_type - get the tag type of a union
check_builtin_type_union_tag_type :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_union_tag_type"

	if len(call.args) != 1 {
		error_node(call, "'%s' expects 1 argument", builtin_name)
		return false
	}

	type_op: Operand
	check_expr_or_type(ctx, &type_op, call.args[0])

	if type_op.mode != .Type {
		error_node(call.args[0], "Argument to '%s' must be a type", builtin_name)
		return false
	}

	if !is_type_union(type_op.type) {
		error_node(call.args[0], "Argument to '%s' must be a union type", builtin_name)
		return false
	}

	// Return the actual tag type based on union tag size
	operand.mode = .Type
	operand.type = union_tag_type(type_op.type)

	return true
}

// ===========================================================================
// Branch hints, extra bit queries, matrix layout and C varargs
// ===========================================================================

// check_builtin_likely handles likely(cond) and unlikely(cond)
// C++ Reference: check_builtin.cpp, `case BuiltinProc_likely:` / `case BuiltinProc_unlikely:`
check_builtin_likely :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_boolean(x.type) {
		type_str := type_to_string(x.type)
		error_node(x.expr, "Expected a boolean expression to '%s', got %s", builtin_name, type_str)
		operand^ = x // minimize error propagation
		return true
	}

	if x.mode == .Constant {
		// NOTE(bill): just completely ignore this intrinsic entirely
		operand^ = x
		return true
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// check_builtin_type_is_matrix_major handles type_is_matrix_row_major and type_is_matrix_column_major
// C++ Reference: check_builtin.cpp, `case BuiltinProc_type_is_matrix_row_major:`
//
// Deviation: C++ reads `bt->Matrix.is_row_major` off the *unbased* type, which is only
// correct when the argument is an unnamed matrix type; for a named matrix it reads another
// variant's storage. The port reads the based type, which is what that code intends.
check_builtin_type_is_matrix_major :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	bt := check_type(ctx, call.args[0])
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for '%s'", builtin_name)
		return false
	}

	type := base_type(bt)
	mat, is_matrix := type.variant.(Type_Matrix)
	if !is_matrix {
		type_str := type_to_string(bt)
		error_node(call.args[0], "Expected a matrix type for '%s', got '%s'", builtin_name, type_str)
		return false
	}

	result: bool
	if id == .Type_Is_Matrix_Row_Major {
		result = mat.is_row_major == true
	} else {
		result = mat.is_row_major == false
	}

	operand.mode = .Constant
	operand.type = t_untyped_bool
	operand.value = exact_value_bool(result)
	return true
}

// check_builtin_type_field_bit handles type_field_bit_offset and type_field_bit_size
// C++ Reference: check_builtin.cpp, `case BuiltinProc_type_field_bit_offset:`
//
// Both are bit_field specific. An unknown field name is not an error in C++; the result
// is simply 0.
check_builtin_type_field_bit :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error_node(call, "'%s' requires exactly 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	bt := check_type(ctx, call.args[0])
	if bt == nil || bt == t_invalid {
		error_node(call.args[0], "Expected a type for '%s'", builtin_name)
		return false
	}

	type := base_type(bt)
	bf, is_bit_field := type.variant.(Type_Bit_Field)
	if !is_bit_field {
		error_node(call.args[0], "Expected a bit field type for '%s'", builtin_name)
		operand.mode = .Invalid
		operand.type = t_invalid
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[1])
	field_name, name_ok := x.value.(string)
	if !is_type_string(x.type) || x.mode != .Constant || !name_ok {
		error_node(call.args[1], "Expected a constant string for field argument")
		return false
	}

	bit_offset: i64 = 0
	bit_size: i64 = 0
	for f, i in bf.fields {
		if f == nil || .Bit_Field_Field not_in f.flags {
			continue
		}
		if f.token.text == field_name {
			if i < len(bf.bit_offsets) {
				bit_offset = i64(bf.bit_offsets[i])
			}
			if i < len(bf.bit_sizes) {
				bit_size = i64(bf.bit_sizes[i])
			}
			break
		}
	}

	value: i64 = 0
	#partial switch id {
	case .Type_Field_Bit_Offset:
		value = bit_offset
	case .Type_Field_Bit_Size:
		value = bit_size
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	operand.value = exact_value_i64(value)
	return true
}

// check_builtin_type_proc_calling_convention handles type_proc_calling_convention(P)
// C++ Reference: check_builtin.cpp, `case BuiltinProc_type_proc_calling_convention:`
check_builtin_type_proc_calling_convention :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	builtin_name := "type_proc_calling_convention"

	if len(call.args) != 1 {
		error_node(call, "'%s' requires exactly 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	check_expr_or_type(ctx, operand, call.args[0])
	if operand.mode != .Type || !is_type_proc(operand.type) {
		error_node(call.args[0], "Expected a procedure type for '%s'", builtin_name)
		return false
	}

	if is_type_polymorphic(operand.type) {
		error_node(call.args[0], "Expected a non-polymorphic procedure type for '%s'", builtin_name)
		return false
	}

	pt := base_type(operand.type).variant.(Type_Proc)

	operand.mode = .Constant
	operand.type = t_odin_calling_convention
	operand.value = exact_value_i64(odin_calling_convention_enum_value(pt.calling_convention))
	return true
}

// check_builtin_entry_point handles intrinsics.__entry_point()
// C++ Reference: check_builtin.cpp, `case BuiltinProc___entry_point:`
//
// The recorded call sites are what mark the program as having an explicit entry point;
// they are drained by drain_intrinsics_entry_point_usage.
check_builtin_entry_point :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr) -> bool {
	operand.mode = .No_Value
	operand.type = nil
	queue.mpsc_enqueue(&ctx.info.intrinsics_entry_point_usage, call)
	return true
}

// check_builtin_c_procedure handles c_va_start, c_va_end, c_va_copy and c_va_arg
// C++ Reference: check_builtin.cpp, `gb_internal bool check_builtin_c_procedure(...)`
check_builtin_c_procedure :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^ast.Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	// check_c_va_list_operand validates that `expr` is a `^intrinsics.c_va_list`.
	check_c_va_list_operand :: proc(ctx: ^Checker_Context, expr: ^ast.Expr, builtin_name: string) -> (ok: bool) {
		x: Operand
		check_expr(ctx, &x, expr)
		if x.mode == .Invalid {
			return false
		}
		if t_c_va_list_ptr == nil {
			// 'intrinsics.c_va_list' never resolved, so there is nothing to compare against.
			error_node(expr, "'%s' expected a value of type ^intrinsics.c_va_list, but 'intrinsics.c_va_list' could not be resolved", builtin_name)
			return false
		}
		if !are_types_identical(x.type, t_c_va_list_ptr) {
			list_str := type_to_string(t_c_va_list_ptr)
			type_str := type_to_string(x.type)
			error_node(expr, "'%s' expected a value of type %s, got type %s", builtin_name, list_str, type_str)
			return false
		}
		return true
	}

	#partial switch id {
	case .C_Va_Start:
		if !check_c_va_list_operand(ctx, call.args[0], builtin_name) {
			return false
		}

		args: Operand
		check_expr(ctx, &args, call.args[1])
		if args.mode == .Invalid {
			return false
		}
		e := entity_of_node(ctx.info, args.expr)
		if e == nil || .C_Var_Arg not_in e.flags {
			error_node(call.args[0], "'%s' expected a `#c_vararg` parameter", builtin_name)
		}

		operand.mode = .No_Value
		operand.type = nil
		return true

	case .C_Va_End:
		if !check_c_va_list_operand(ctx, call.args[0], builtin_name) {
			return false
		}

		operand.mode = .No_Value
		operand.type = nil
		return true

	case .C_Va_Copy:
		if !check_c_va_list_operand(ctx, call.args[0], builtin_name) {
			return false
		}
		if !check_c_va_list_operand(ctx, call.args[1], builtin_name) {
			return false
		}

		operand.mode = .No_Value
		operand.type = nil
		return true

	case .C_Va_Arg:
		if !check_c_va_list_operand(ctx, call.args[0], builtin_name) {
			return false
		}

		type := check_type(ctx, call.args[1])
		if type == nil || type == t_invalid {
			error_node(call.args[1], "'%s' expected a type as the second parameter to intrinsics.%s", builtin_name, builtin_name)
			return false
		}

		operand.mode = .Value
		operand.type = type
		return true
	}

	return false
}
