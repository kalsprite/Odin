package checker

/*
Type Equivalence and Assignability System

This module implements the core type comparison logic for the Odin checker,
including type identity, equivalence, assignability, and convertibility checks.

C++ Reference: /mnt/c/odin/src/types.cpp lines 2893-3191
C++ Reference: /mnt/c/odin/src/check_expr.cpp lines 667-1047
*/

import "core:odin/ast"

// MAXIMUM_TYPE_DISTANCE represents the maximum "distance" between types for assignability scoring.
// Used in type assignment compatibility checks - larger distances mean less preferred conversions.
// C++ Reference: check_expr.cpp:718
MAXIMUM_TYPE_DISTANCE :: 10

//
// Core Type Identity Functions
//

// are_types_identical checks if two types are structurally identical.
// This is the strictest form of type equality - it compares the actual type structure.
//
// Type aliases (distinct types created with ::) are unwrapped before comparison,
// but named types that are not aliases are compared by identity (same type declaration).
//
// C++ Reference: types.cpp:2895-2923
are_types_identical :: proc(x, y: ^Type) -> bool {
	if x == y {
		return true
	}

	if (x == nil && y != nil) || (x != nil && y == nil) {
		return false
	}

	// Unwrap type aliases (but not distinct types)
	// C++ Reference: types.cpp:2905-2916
	x_unwrapped := x
	y_unwrapped := y

	if x.kind == .Named {
		named := x.variant.(Type_Named)
		if entity := named.type_name; entity != nil && entity.kind == .Type_Name {
			if type_name := entity.variant.(Entity_Type_Name); type_name.is_type_alias {
				x_unwrapped = named.base
			}
		}
	}

	if y.kind == .Named {
		named := y.variant.(Type_Named)
		if entity := named.type_name; entity != nil && entity.kind == .Type_Name {
			if type_name := entity.variant.(Entity_Type_Name); type_name.is_type_alias {
				y_unwrapped = named.base
			}
		}
	}

	if x_unwrapped == nil || y_unwrapped == nil || x_unwrapped.kind != y_unwrapped.kind {
		return false
	}

	return are_types_identical_internal(x_unwrapped, y_unwrapped, false)
}

// are_types_identical_unique_tuples checks type identity with tuple name checking enabled.
// Used specifically for type_info map deduplication to ensure tuples with different
// parameter names are considered distinct.
// C++ Reference: types.cpp:2924-2951
are_types_identical_unique_tuples :: proc(x, y: ^Type) -> bool {
	if x == y {
		return true
	}

	if x == nil || y == nil {
		return false
	}

	// Unwrap type aliases
	x_unwrapped := x
	y_unwrapped := y

	if x.kind == .Named {
		named := x.variant.(Type_Named)
		if entity := named.type_name; entity != nil && entity.kind == .Type_Name {
			if type_name := entity.variant.(Entity_Type_Name); type_name.is_type_alias {
				x_unwrapped = named.base
			}
		}
	}

	if y.kind == .Named {
		named := y.variant.(Type_Named)
		if entity := named.type_name; entity != nil && entity.kind == .Type_Name {
			if type_name := entity.variant.(Entity_Type_Name); type_name.is_type_alias {
				y_unwrapped = named.base
			}
		}
	}

	if x_unwrapped.kind != y_unwrapped.kind {
		return false
	}

	return are_types_identical_internal(x_unwrapped, y_unwrapped, true)
}

// are_types_identical_internal is the workhorse type identity checker.
// It recursively compares type structures for equality.
//
// The check_tuple_names parameter controls whether tuple parameter/field names
// must match (used for unique type_info entries) or can differ (normal identity check).
//
// C++ Reference: types.cpp:2954-3191
are_types_identical_internal :: proc(x, y: ^Type, check_tuple_names: bool) -> bool {
	if x == y {
		return true
	}

	if x == nil || y == nil {
		return false
	}

	// Note: Type aliases are already unwrapped by the caller (are_types_identical)
	// C++ Reference: types.cpp:2963-2979 (commented out in C++)

	#partial switch x.kind {
	case .Generic:
		// C++ Reference: types.cpp:2982-2983
		x_gen := x.variant.(Type_Generic)
		y_gen := y.variant.(Type_Generic)
		return are_types_identical(x_gen.specialized, y_gen.specialized)

	case .Basic:
		// C++ Reference: types.cpp:2985-2986
		x_basic := x.variant.(Type_Basic)
		y_basic := y.variant.(Type_Basic)
		return x_basic.kind == y_basic.kind

	case .Enumerated_Array:
		// C++ Reference: types.cpp:2988-2990
		x_ea := x.variant.(Type_Enumerated_Array)
		y_ea := y.variant.(Type_Enumerated_Array)
		return are_types_identical(x_ea.index, y_ea.index) && are_types_identical(x_ea.elem, y_ea.elem)

	case .Array:
		// C++ Reference: types.cpp:2992-2993
		x_arr := x.variant.(Type_Array)
		y_arr := y.variant.(Type_Array)
		return x_arr.count == y_arr.count && are_types_identical(x_arr.elem, y_arr.elem)

	case .Matrix:
		// C++ Reference: types.cpp:2995-2999
		x_mat := x.variant.(Type_Matrix)
		y_mat := y.variant.(Type_Matrix)
		return x_mat.row_count == y_mat.row_count && x_mat.column_count == y_mat.column_count && x_mat.is_row_major == y_mat.is_row_major && are_types_identical(x_mat.elem, y_mat.elem)

	case .Dynamic_Array:
		// C++ Reference: types.cpp:3001-3002
		x_da := x.variant.(Type_Dynamic_Array)
		y_da := y.variant.(Type_Dynamic_Array)
		return are_types_identical(x_da.elem, y_da.elem)

	case .Slice:
		// C++ Reference: types.cpp:3004-3005
		x_slice := x.variant.(Type_Slice)
		y_slice := y.variant.(Type_Slice)
		return are_types_identical(x_slice.elem, y_slice.elem)

	case .Bit_Set:
		// C++ Reference: types.cpp:3007-3015
		x_bs := x.variant.(Type_Bit_Set)
		y_bs := y.variant.(Type_Bit_Set)

		if are_types_identical(x_bs.elem, y_bs.elem) && are_types_identical(x_bs.underlying, y_bs.underlying) {
			if is_type_enum(x_bs.elem) {
				return true
			}
			return x_bs.lower == y_bs.lower && x_bs.upper == y_bs.upper
		}
		return false

	case .Enum:
		// C++ Reference: types.cpp:3018-3049
		if x == y {
			return true
		}
		x_enum := x.variant.(Type_Enum)
		y_enum := y.variant.(Type_Enum)

		if len(x_enum.fields) != len(y_enum.fields) {
			return false
		}
		if !are_types_identical(x_enum.base_type, y_enum.base_type) {
			return false
		}
		if x_enum.min_value_index != y_enum.min_value_index {
			return false
		}
		if x_enum.max_value_index != y_enum.max_value_index {
			return false
		}

		for i in 0 ..< len(x_enum.fields) {
			a := x_enum.fields[i]
			b := y_enum.fields[i]
			if a.token.text != b.token.text {
				return false
			}
			assert(a.kind == b.kind)
			assert(a.kind == .Constant)
			// C++ Reference: types.cpp:3043
			a_const := a.variant.(Entity_Constant)
			b_const := b.variant.(Entity_Constant)
			same := compare_exact_values(.Cmp_Eq, a_const.value, b_const.value)
			if !same {
				return false
			}
		}

		return true

	case .Union:
		// C++ Reference: types.cpp:3051-3069
		x_union := x.variant.(Type_Union)
		y_union := y.variant.(Type_Union)

		if len(x_union.variants) == len(y_union.variants) && x_union.kind == y_union.kind {
			// Check alignment compatibility
			// C++ Reference: types.cpp:3055-3059
			if x_union.custom_align != y_union.custom_align {
				if type_align_of(x) != type_align_of(y) {
					return false
				}
			}

			// NOTE: zeroth variant is nil for normal unions
			// C++ Reference: types.cpp:3061-3066
			for variant, i in x_union.variants {
				if !are_types_identical(variant, y_union.variants[i]) {
					return false
				}
			}
			return true
		}

	case .Struct:
		// C++ Reference: types.cpp:3071-3109
		x_struct := x.variant.(Type_Struct)
		y_struct := y.variant.(Type_Struct)

		if x_struct.is_raw_union == y_struct.is_raw_union && len(x_struct.fields) == len(y_struct.fields) && x_struct.is_packed == y_struct.is_packed && x_struct.is_all_or_none == y_struct.is_all_or_none && x_struct.soa_kind == y_struct.soa_kind && x_struct.soa_count == y_struct.soa_count && are_types_identical(x_struct.soa_elem, y_struct.soa_elem) {

			// Check alignment compatibility
			// C++ Reference: types.cpp:3079-3083
			if x_struct.custom_align != y_struct.custom_align {
				if type_align_of(x) != type_align_of(y) {
					return false
				}
			}

			// Check all fields match
			// C++ Reference: types.cpp:3085-3105
			for i in 0 ..< len(x_struct.fields) {
				xf := x_struct.fields[i]
				yf := y_struct.fields[i]
				if xf.kind != yf.kind {
					return false
				}
				if !are_types_identical(xf.type, yf.type) {
					return false
				}
				if xf.token.text != yf.token.text {
					return false
				}
				if x_struct.tags[i] != y_struct.tags[i] {
					return false
				}
				// Check subtype flags (using subtype)
				// C++ Reference: types.cpp:3100-3103
				xf_flags := (xf.flags & Entity_Flags_Is_Subtype)
				yf_flags := (yf.flags & Entity_Flags_Is_Subtype)
				if xf_flags != yf_flags {
					return false
				}
			}
			// C++ Reference: types.cpp:3106-3109
			// ARCHITECTURAL NOTE: The C++ code has a commented-out check for polymorphic_params:
			//   return are_types_identical(x->Struct.polymorphic_params, y->Struct.polymorphic_params)
			// This check is intentionally skipped, following structural equality semantics:
			// - Two specialized struct instances are identical if all their fields are identical
			// - The polymorphic origin (template parameters) is NOT part of type identity
			// - This allows different specializations of the same template to be considered
			//   identical if they happen to have the same field layout
			// This matches the current C++ implementation which returns true without the check.
			return true
		}

	case .Pointer:
		// C++ Reference: types.cpp:3112-3113
		x_ptr := x.variant.(Type_Pointer)
		y_ptr := y.variant.(Type_Pointer)
		return are_types_identical(x_ptr.elem, y_ptr.elem)

	case .Multi_Pointer:
		// C++ Reference: types.cpp:3115-3116
		x_mp := x.variant.(Type_Multi_Pointer)
		y_mp := y.variant.(Type_Multi_Pointer)
		return are_types_identical(x_mp.elem, y_mp.elem)

	case .Soa_Pointer:
		// C++ Reference: types.cpp:3118-3119
		x_soa := x.variant.(Type_Soa_Pointer)
		y_soa := y.variant.(Type_Soa_Pointer)
		return are_types_identical(x_soa.elem, y_soa.elem)

	case .Named:
		// C++ Reference: types.cpp:3121-3122
		x_named := x.variant.(Type_Named)
		y_named := y.variant.(Type_Named)
		return x_named.type_name == y_named.type_name

	case .Tuple:
		// C++ Reference: types.cpp:3124-3145
		x_tuple := x.variant.(Type_Tuple)
		y_tuple := y.variant.(Type_Tuple)

		if len(x_tuple.variables) == len(y_tuple.variables) && x_tuple.is_packed == y_tuple.is_packed {
			for i in 0 ..< len(x_tuple.variables) {
				xe := x_tuple.variables[i]
				ye := y_tuple.variables[i]
				if xe.kind != ye.kind || !are_types_identical(xe.type, ye.type) {
					return false
				}
				// Check parameter names if required (for unique type_info)
				// C++ Reference: types.cpp:3133-3136
				if check_tuple_names {
					if xe.token.text != ye.token.text {
						return false
					}
				}
				// Check constant values for polymorphic procedures
				// C++ Reference: types.cpp:3138-3141
				if xe.kind == .Constant {
					xe_const := xe.variant.(Entity_Constant)
					ye_const := ye.variant.(Entity_Constant)
					if !compare_exact_values(.Cmp_Eq, xe_const.value, ye_const.value) {
						return false
					}
				}
			}
			return true
		}

	case .Proc:
		// C++ Reference: types.cpp:3147-3154
		x_proc := x.variant.(Type_Proc)
		y_proc := y.variant.(Type_Proc)
		return(
			x_proc.calling_convention == y_proc.calling_convention &&
			x_proc.c_vararg == y_proc.c_vararg &&
			x_proc.variadic == y_proc.variadic &&
			x_proc.diverging == y_proc.diverging &&
			x_proc.optional_ok == y_proc.optional_ok &&
			are_types_identical_internal(x_proc.params, y_proc.params, check_tuple_names) &&
			are_types_identical_internal(x_proc.results, y_proc.results, check_tuple_names) \
		)

	case .Map:
		// C++ Reference: types.cpp:3156-3158
		x_map := x.variant.(Type_Map)
		y_map := y.variant.(Type_Map)
		return are_types_identical(x_map.key, y_map.key) && are_types_identical(x_map.value, y_map.value)

	case .Simd_Vector:
		// C++ Reference: types.cpp:3160-3164
		x_sv := x.variant.(Type_Simd_Vector)
		y_sv := y.variant.(Type_Simd_Vector)
		if x_sv.count == y_sv.count {
			return are_types_identical(x_sv.elem, y_sv.elem)
		}

	case .Bit_Field:
		// C++ Reference: types.cpp:3166-3187
		x_bf := x.variant.(Type_Bit_Field)
		y_bf := y.variant.(Type_Bit_Field)

		if are_types_identical(x_bf.backing_type, y_bf.backing_type) && len(x_bf.fields) == len(y_bf.fields) {
			// Check all field properties match
			// C++ Reference: types.cpp:3172-3183
			for i in 0 ..< len(x_bf.fields) {
				a := x_bf.fields[i]
				b := y_bf.fields[i]
				// C++ Reference: types.cpp:3175-3176
				if !are_types_identical(a.type, b.type) {
					return false
				}
				// C++ Reference: types.cpp:3177-3178
				if a.token.text != b.token.text {
					return false
				}
				// C++ Reference: types.cpp:3179-3180
				if x_bf.bit_sizes[i] != y_bf.bit_sizes[i] {
					return false
				}
				// C++ Reference: types.cpp:3181-3182
				if x_bf.bit_offsets[i] != y_bf.bit_offsets[i] {
					return false
				}
			}
			return true
		}
	}

	// C++ Reference: types.cpp:3190
	return false
}

//
// Helper Functions for Type Assignability
//

// type_has_nil checks if a type can be assigned the value nil.
// C++ Reference: types.cpp:2474-2514
type_has_nil :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	#partial switch bt.kind {
	case .Basic:
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .Rawptr, .Any:
			return true
		case .Cstring, .Cstring16:
			return true
		case .Typeid:
			return true
		}
		return false

	case .Enum, .Bit_Set:
		return true

	case .Slice, .Proc, .Pointer, .Soa_Pointer, .Multi_Pointer, .Dynamic_Array, .Map:
		return true

	case .Union:
		union_type := bt.variant.(Type_Union)
		return union_type.kind != .No_Nil

	case .Struct:
		struct_type := bt.variant.(Type_Struct)
		if is_type_soa_struct(bt) {
			#partial switch struct_type.soa_kind {
			case .None:
				// Should not happen since is_type_soa_struct returned true
				return false
			case .Fixed:
				// StructSoa_Fixed - fixed-size SOA cannot be nil
				return false
			case .Slice, .Dynamic:
				// StructSoa_Slice, StructSoa_Dynamic - can be nil
				return true
			}
		}
		return false
	}
	return false
}

//
// Type Assignability Checking
//

// Operand is defined in checker.odin (full version with all fields)

// Addressing_Mode is defined in checker.odin (14 variants including Soa_Variable, Swizzle_Value, etc.)

// check_distance_between_types determines how "compatible" an operand is with a target type.
// Returns -1 if incompatible, or a non-negative "distance" score where lower is better.
//
// Distance meanings:
//   0 = identical types
//   1 = untyped value to typed compatible type
//   2-4 = various conversions (untyped, enum, subtype)
//   5+ = implicit conversions (rawptr, pointers, polymorphic, etc.)
//   MAXIMUM_TYPE_DISTANCE = auto_cast or very permissive conversion
//
// C++ Reference: check_expr.cpp:667-989
check_distance_between_types :: proc(c: ^Checker_Context, operand: ^Operand, type: ^Type, allow_array_programming := true) -> i64 {
	// Note: c can be nil for simple type checks
	if c == nil {
		assert(operand.mode == .Value)
		assert(is_type_typed(operand.type))
	}

	if operand.mode == .Invalid || type == t_invalid {
		return -1
	}

	// C++ Reference: check_expr.cpp:677-679
	if operand.mode == .Builtin {
		return -1
	}

	// C++ Reference: check_expr.cpp:681-690
	if operand.mode == .Type {
		if is_type_typeid(type) {
			if is_type_polymorphic(operand.type) {
				return -1
			}
			// Register type info for RTTI when converting type to typeid
			// C++ Reference: check_expr.cpp:686
			if c != nil {
				add_type_info_type(c, operand.type)
			}
			return 4
		}
		return -1
	}

	if operand.mode == .Proc_Group && !is_type_proc(type) {
		return -1
	}

	s := operand.type

	// C++ Reference: check_expr.cpp:697-699
	if are_types_identical(s, type) {
		return 0
	}

	src := base_type(s)
	dst := base_type(type)

	// C++ Reference: check_expr.cpp:704-706
	if is_type_untyped_uninit(src) {
		return 1
	}

	// C++ Reference: check_expr.cpp:708-713
	if is_type_untyped_nil(src) {
		if type_has_nil(dst) {
			return 1
		}
		return -1
	}

	// C++ Reference: check_expr.cpp:714-823
	if is_type_untyped(src) {
		if is_type_any(dst) {
			// NOTE: Anything can cast to 'Any'
			return MAXIMUM_TYPE_DISTANCE
		}
		// Use core_type to unwrap distinct/named types to their underlying basic type
		dst_core := core_type(dst)
		if dst_core != nil && dst_core.kind == .Basic {
			if operand.mode == .Constant {
				// Check if the constant value can be represented in the destination type
				// C++ Reference: check_expr.cpp:722
				if !check_representable_as_constant(c, operand.value, dst) {
					return -1
				}
				// Check type compatibility for typed destinations
				// C++ Reference: check_expr.cpp:723-763
				if is_type_typed(dst) && src.kind == .Basic {
					src_basic := src.variant.(Type_Basic)
					#partial switch src_basic.kind {
					case .Untyped_Bool:
						if is_type_boolean(dst) {
							return 1
						}
					case .Untyped_Rune:
						if is_type_integer(dst) || is_type_rune(dst) {
							return 1
						}
					case .Untyped_Integer:
						if is_type_integer(dst) || is_type_rune(dst) {
							return 1
						}
					case .Untyped_String:
						if is_type_string(dst) {
							return 1
						}
					case .Untyped_Float:
						if is_type_float(dst) {
							return 1
						}
					case .Untyped_Complex:
						if is_type_complex(dst) {
							return 1
						}
						if is_type_quaternion(dst) {
							return 2
						}
					case .Untyped_Quaternion:
						if is_type_quaternion(dst) {
							return 1
						}
					}
				}
				// C++ Reference: check_expr.cpp:765
				return 2
			}
			// Non-constant untyped values
			// C++ Reference: check_expr.cpp:769-821
			if src.kind == .Basic {
				d := base_array_type(dst)
				score: i64 = -1
				src_basic := src.variant.(Type_Basic)
				#partial switch src_basic.kind {
				case .Untyped_Bool:
					if is_type_boolean(d) {
						score = 1
					}
				case .Untyped_Rune:
					if is_type_integer(d) || is_type_rune(d) {
						score = 1
					}
				case .Untyped_Integer:
					if is_type_integer(d) || is_type_rune(d) {
						score = 1
					}
				case .Untyped_String:
					if is_type_string(d) {
						score = 1
					}
				case .Untyped_Float:
					if is_type_float(d) {
						score = 1
					}
				case .Untyped_Complex:
					if is_type_complex(d) {
						score = 1
					}
					if is_type_quaternion(d) {
						score = 2
					}
				case .Untyped_Quaternion:
					if is_type_quaternion(d) {
						score = 1
					}
				}
				if score > 0 {
					if is_type_typed(d) {
						score += 1
					}
					if d != dst {
						score += 6
					}
				}
				return score
			}
		}
	}

	// C++ Reference: check_expr.cpp:825-831
	if c != nil {
		if is_type_enum(dst) {
			dst_enum := dst.variant.(Type_Enum)
			if are_types_identical(dst_enum.base_type, operand.type) {
				// Would check c.in_enum_type here
				return 3
			}
		}
	}

	// C++ Reference: check_expr.cpp:834-839
	// Subtype checking for using-based inheritance
	subtype_level := check_is_assignable_to_using_subtype(operand.type, type)
	if subtype_level > 0 {
		return i64(4 + subtype_level)
	}

	// C++ Reference: check_expr.cpp:841-860
	// rawptr <- ^T
	if are_types_identical(type, t_rawptr) && is_type_pointer(src) {
		return 5
	}
	// rawptr <- [^]T
	if are_types_identical(type, t_rawptr) && is_type_multi_pointer(src) {
		return 5
	}
	// ^T <- [^]T
	if dst.kind == .Pointer && src.kind == .Multi_Pointer {
		dst_ptr := dst.variant.(Type_Pointer)
		src_mp := src.variant.(Type_Multi_Pointer)
		if are_types_identical(dst_ptr.elem, src_mp.elem) {
			return 4
		}
	}
	// [^]T <- ^T
	if dst.kind == .Multi_Pointer && src.kind == .Pointer {
		dst_mp := dst.variant.(Type_Multi_Pointer)
		src_ptr := src.variant.(Type_Pointer)
		if are_types_identical(dst_mp.elem, src_ptr.elem) {
			return 4
		}
	}

	// C++ Reference: check_expr.cpp:862-867
	// Polymorphic type assignability
	if is_type_polymorphic(dst) && !is_type_polymorphic(src) {
		modify_type := c != nil && !c.no_polymorphic_errors
		if is_polymorphic_type_assignable(c, type, s, false, modify_type) {
			return 2
		}
	}

	// C++ Reference: check_expr.cpp:869-911
	if is_type_union(dst) {
		union_type := dst.variant.(Type_Union)
		for vt in union_type.variants {
			if are_types_identical(vt, s) {
				return 1
			}
			if is_type_proc(vt) {
				if are_types_identical(base_type(vt), src) {
					return 1
				}
			}
		}

		// Single-variant union implicit conversion
		if len(union_type.variants) == 1 {
			vt := union_type.variants[0]
			score := check_distance_between_types(c, operand, vt, allow_array_programming)
			if score >= 0 {
				return score + 2
			}
		} else if is_type_untyped(src) {
			// Multiple variants, untyped - pick best match
			prev_lowest_score: i64 = -1
			lowest_score: i64 = -1
			for vt in union_type.variants {
				score := check_distance_between_types(c, operand, vt, allow_array_programming)
				if score >= 0 {
					if lowest_score < 0 {
						lowest_score = score
					} else {
						if prev_lowest_score < 0 {
							prev_lowest_score = lowest_score
						} else {
							prev_lowest_score = min(prev_lowest_score, lowest_score)
						}
						lowest_score = min(lowest_score, score)
					}
				}
			}
			if lowest_score >= 0 {
				if prev_lowest_score != lowest_score { 	// remove ambiguities
					return lowest_score + 2
				}
			}
		}
	}

	// C++ Reference: check_expr.cpp:913-924
	if is_type_proc(dst) {
		if are_types_identical(src, dst) {
			return 3
		}
		// Check if source is a polymorphic procedure that can be instantiated to match dst
		// C++ Reference: check_expr.cpp:918-923
		if c != nil && is_type_proc(src) {
			if src_proc, ok := base_type(src).variant.(Type_Proc); ok {
				if src_proc.is_polymorphic && !src_proc.is_poly_specialized {
					poly_data: Poly_Proc_Data
					if check_polymorphic_procedure_assignment(c, operand, dst, operand.expr, &poly_data) {
						return 4
					}
				}
			}
		}
	}

	// C++ Reference: check_expr.cpp:926-931
	if is_type_complex_or_quaternion(dst) {
		elem := base_complex_elem_type(dst)
		if are_types_identical(elem, base_type(src)) {
			return 5
		}
	}

	// C++ Reference: check_expr.cpp:933-962
	if allow_array_programming {
		if is_type_array(dst) {
			elem := base_array_type(dst)
			distance := check_distance_between_types(c, operand, elem, allow_array_programming)
			if distance >= 0 {
				return distance + 6
			}
		}

		if is_type_simd_vector(dst) {
			dst_elem := base_array_type(dst)
			distance := check_distance_between_types(c, operand, dst_elem, allow_array_programming)
			if distance >= 0 {
				return distance + 6
			}
		}
	}

	// C++ Reference: check_expr.cpp:951-962
	if is_type_matrix(dst) {
		if are_types_identical(src, dst) {
			return 5
		}
		mat := dst.variant.(Type_Matrix)
		if mat.row_count == mat.column_count {
			dst_elem := base_array_type(dst)
			distance := check_distance_between_types(c, operand, dst_elem, allow_array_programming)
			if distance >= 0 {
				return distance + 7
			}
		}
	}

	// C++ Reference: check_expr.cpp:965-975
	if is_type_any(dst) {
		if !is_type_polymorphic(src) {
			// Check if trying to convert context to Any (not allowed)
			// C++ Reference: check_expr.cpp:967-969
			if operand.mode == .Context && are_types_identical(operand.type, t_context) {
				return -1
			}
			// NOTE: Anything can cast to 'Any'
			// Register type info for RTTI when converting to Any
			// C++ Reference: check_expr.cpp:973
			if c != nil {
				add_type_info_type(c, s)
			}
			return MAXIMUM_TYPE_DISTANCE
		}
	}

	// C++ Reference: check_expr.cpp:977-986
	// Handle auto_cast expressions - they can be cast to any compatible type
	if operand.expr != nil {
		if _, is_auto_cast := operand.expr.derived.(^ast.Auto_Cast); is_auto_cast {
			// Create a temporary operand without the auto_cast expression to prevent
			// infinite recursion: check_is_castable_to -> check_is_assignable_to ->
			// check_distance_between_types -> check_is_castable_to (for auto_cast) -> ...
			// We only need to check if the underlying type is castable, not the expression.
			temp_operand := operand^
			temp_operand.expr = nil // Clear expr to prevent recursion
			if check_is_castable_to(c, &temp_operand, type) {
				return MAXIMUM_TYPE_DISTANCE
			}
		}
	}

	// C++ Reference: check_expr.cpp:988
	return -1
}

// NOTE: assign_score_function is defined in check_proc_group.odin
// NOTE: check_is_assignable_to_with_score is defined in check_proc_group.odin

// check_is_assignable_to checks if an operand can be assigned to a target type.
// Wrapper around check_is_assignable_to_with_score that discards the score
// C++ Reference: check_expr.cpp:1037-1040
check_is_assignable_to :: proc(c: ^Checker_Context, operand: ^Operand, type: ^Type, allow_array_programming := true) -> bool {
	score: i64 = 0
	return check_is_assignable_to_with_score(c, operand, type, &score, false, allow_array_programming)
}

// internal_check_is_assignable_to is a convenience function for simple type assignability checks.
// C++ Reference: check_expr.cpp:1042-1047
internal_check_is_assignable_to :: proc(src, dst: ^Type) -> bool {
	x: Operand
	x.type = src
	x.mode = .Value
	return check_is_assignable_to(nil, &x, dst)
}

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// base_complex_elem_type extracts the element type from complex or quaternion types
// Returns the floating-point type that makes up the components
// C++ Reference: /mnt/c/odin/src/types.cpp:1836-1852
base_complex_elem_type :: proc(t: ^Type) -> ^Type {
	t_ct := core_type(t)
	if t_ct.kind == .Basic {
		basic := t_ct.variant.(Type_Basic)
		#partial switch basic.kind {
		// Complex types
		case .Complex32:
			return t_f16
		case .Complex64:
			return t_f32
		case .Complex128:
			return t_f64
		// Quaternion types
		case .Quaternion64:
			return t_f16
		case .Quaternion128:
			return t_f32
		case .Quaternion256:
			return t_f64
		// Untyped complex/quaternion
		case .Untyped_Complex:
			return t_untyped_float
		case .Untyped_Quaternion:
			return t_untyped_float
		}
	}
	// C++ Reference: types.cpp:1850 - GB_PANIC("Invalid complex type")
	assert(false, "Invalid complex type passed to base_complex_elem_type")
	return t_invalid
}

// is_type_soa_struct checks if a type is a structure-of-arrays struct
// C++ Reference: /mnt/c/odin/src/types.cpp:1864-1868
is_type_soa_struct :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil {
		return false
	}
	// C++ Reference: types.cpp:1867
	return bt.kind == .Struct && bt.variant.(Type_Struct).soa_kind != .None
}

// is_type_complex_or_quaternion checks if type is complex or quaternion
is_type_complex_or_quaternion :: proc(t: ^Type) -> bool {
	return is_type_complex(t) || is_type_quaternion(t)
}
