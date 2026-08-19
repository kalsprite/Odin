package checker

/*
Type Equivalence and Assignability System

This module implements the core type comparison logic for the Odin checker,
including type identity, equivalence, assignability, and convertibility checks.

C++ Reference: types.cpp lines 2893-3191
C++ Reference: check_expr.cpp lines 667-1047
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

// are_proc_properties_identical compares the five procedure attributes that are part of a proc
// type's identity but live outside its parameter and result tuples.
// C++ Reference: types.cpp:3191-3197. Named here rather than inlined because C++ has TWO callers --
// are_types_identical_internal's Type_Proc arm and check_distance_between_types' proc arm -- and
// having one of them drift is exactly how a proc becomes assignable but not identical, or worse,
// identical but not assignable.
are_proc_properties_identical :: proc(x, y: ^Type) -> bool {
	x_proc, x_ok := x.variant.(Type_Proc)
	y_proc, y_ok := y.variant.(Type_Proc)
	if !x_ok || !y_ok {
		return false
	}
	return(
		x_proc.calling_convention == y_proc.calling_convention &&
		x_proc.c_vararg == y_proc.c_vararg &&
		x_proc.variadic == y_proc.variadic &&
		x_proc.diverging == y_proc.diverging &&
		x_proc.optional_ok == y_proc.optional_ok \
	)
}

// check_proc_params_assignable reports whether a value of proc type `src` may be assigned to a
// variable of proc type `dst` even though the two are not identical.
//
// C++ Reference: check_expr.cpp:1060-1101. Results must be identical and the parameter tuples must
// agree in count and packing; a parameter is then allowed to differ ONLY when both sides are
// pointers and the source's pointee is a struct that embeds the destination's pointee at offset 0.
// That is the whole of the relaxation: `proc(^Derived)` is assignable to `proc(^Base)` when Derived
// `using`-embeds Base first, because the two pointers hold the same address.
check_proc_params_assignable :: proc(c: ^Checker_Context, dst, src: ^Type) -> bool {
	dst_proc, dst_ok := dst.variant.(Type_Proc)
	src_proc, src_ok := src.variant.(Type_Proc)
	if !dst_ok || !src_ok {
		return false
	}

	if dst_proc.params == nil || src_proc.params == nil {
		return false
	}

	if !are_types_identical(src_proc.results, dst_proc.results) {
		return false
	}

	dst_tuple, dst_tuple_ok := dst_proc.params.variant.(Type_Tuple)
	src_tuple, src_tuple_ok := src_proc.params.variant.(Type_Tuple)
	if !dst_tuple_ok || !src_tuple_ok {
		return false
	}

	if len(dst_tuple.variables) != len(src_tuple.variables) || dst_tuple.is_packed != src_tuple.is_packed {
		return false
	}

	for i in 0 ..< len(dst_tuple.variables) {
		edst := dst_tuple.variables[i]
		esrc := src_tuple.variables[i]
		if edst == nil || esrc == nil {
			return false
		}

		if edst.kind != esrc.kind || !are_types_identical(edst.type, esrc.type) {
			// Pointers to subtype fields that are at byte offset 0 are OK.
			// C++ tests the RAW kind here, not base_type, so a named pointer type does not
			// qualify -- matched deliberately.
			dst_ptr, src_ptr: Type_Pointer
			dst_is_ptr, src_is_ptr: bool
			if edst.type != nil {
				dst_ptr, dst_is_ptr = edst.type.variant.(Type_Pointer)
			}
			if esrc.type != nil {
				src_ptr, src_is_ptr = esrc.type.variant.(Type_Pointer)
			}
			if dst_is_ptr && src_is_ptr && is_type_struct(src_ptr.elem) &&
			   check_is_assignable_to_using_offset_zero_subtype(src_ptr.elem, dst_ptr.elem) {
				continue
			}

			return false
		}

		// NOTE: needed for polymorphic procedures.
		if edst.kind == .Constant {
			edst_const := edst.variant.(Entity_Constant)
			esrc_const := esrc.variant.(Entity_Constant)
			if !compare_exact_values(.Cmp_Eq, edst_const.value, esrc_const.value) {
				return false
			}
		}
	}

	return true
}

// are_types_identical_internal is the workhorse type identity checker.
// It recursively compares type structures for equality.
//
// The check_tuple_names parameter controls whether tuple parameter/field names
// must match (used for unique type_info entries) or can differ (normal identity check).
//
// C++ Reference: types.cpp are_types_identical_internal
// WHY EVERY `x.variant.(T)` IN THIS PROCEDURE USES THE TWO-VALUE FORM.
//
// C++ reads these union members WITHOUT any tag check -- types.cpp's Basic arm is literally
//     return x->Basic.kind == y->Basic.kind;
// a bare member access on an untagged union, discriminated only by the separate `kind` field the
// switch above already tested. The port's union IS tagged, so `x.variant.(T)` asserts, and a
// single-value assertion TRAPS on mismatch.
//
// That difference is not academic. This procedure is the hottest concurrent READER in the checker
// (find_polymorphic_record_entity calls it for every cached entity on every polymorphic lookup),
// and a live Type can have `kind` and `variant` disagree for a few instructions while another
// thread specializes it. In C++ that window yields a wrong comparison; here it yielded a CRASH:
//     check_equivalence.odin(259:14) type assertion: Invalid type assertion from Type_Variant to
//     Type_Basic, actual type: Type_Generic
// measured at ~0.7-2% under 16-way concurrency, and captured by a peer in 15 agreeing backtraces
// all landing here via are_types_identical <- find_polymorphic_record_entity <- check_call_expr.
// The trapping thread HOLDS the gen_types mutex and every other polymorphic thread is queued
// behind it, so the writer is off this path entirely: gen_types_data_of_specialization returns nil
// when the specialization's kind is not .Named, and check_type_specialization_to_internal then
// performs its Generic->Basic write with NO lock. C++ has the identical conditional lock, so the
// window exists in the reference too -- it simply cannot trap there.
//
// Returning false on a torn read is the conservative answer and the one closest to C++: under a
// concurrent write the bytes are arbitrary, so "not identical" is as valid as anything C++ would
// compute from them, and it degrades to a redundant specialization rather than a dead compiler.
// THIS IS NOT A FIX FOR THE RACE -- the unlocked write is still open (COVERAGE.md TICK 232b/233).
// It removes the port-only fatality, which is required because a reference quirk is the contract
// EXCEPT when it is a crash.
are_types_identical_internal :: proc(x, y: ^Type, check_tuple_names: bool) -> bool {
	if x == y {
		return true
	}

	if x == nil || y == nil {
		return false
	}

	// Note: Type aliases are already unwrapped by the caller (are_types_identical)
	// C++ Reference: types.cpp are_types_identical_internal (commented out in C++)

	// C++ Reference: types.cpp are_types_identical_internal switches on `x->kind` and then reads
	// Y's union member WITHOUT ever checking y->kind -- e.g. `case Type_Basic: return
	// x->Basic.kind == y->Basic.kind;`. C++'s own `if (x->kind != y->kind) return false;` guard
	// sits a few lines above inside an `#if 0`. So when the kinds differ C++ reinterprets y's
	// storage as the wrong variant and compares whatever is there, which essentially always
	// answers "not identical".
	//
	// The port's `y.variant.(Type_Basic)` is a CHECKED assertion, so the same mismatch TRAPS.
	// That is not a theoretical difference: it was observed as a SIGILL at the `.Basic` arm --
	//     type assertion: Invalid type assertion from Type_Variant to Type_Basic,
	//     actual type: Type_Basic
	// (the two disagreeing because the tag is re-read for the panic message after a concurrent
	// write moved it) at a rate of 1 in 400 runs of $S/phase2/wit_polyrace/raceprobe, while the
	// ORACLE was 0 in 200 on the same input. A reference quirk is the contract, but not when the
	// port's realisation of it is a crash -- Jon's `using` ruling.
	//
	// Returning false is the deterministic form of C++'s answer, and it is expected to be INERT
	// on any input where C++ is not already reading garbage. That is the recorded prediction:
	// if the corpus, parity, jsoncheck or docbin sets move, this blanket guard is wrong and the
	// fix has to become arm-local (checked assert per y-side read, 21 sites) instead.
	if x.kind != y.kind {
		return false
	}

	#partial switch x.kind {
	case .Generic:
		// C++ Reference: types.cpp are_types_identical_internal
		x_gen, x_gen_ok := x.variant.(Type_Generic)
		if !x_gen_ok { return false }
		y_gen, y_gen_ok := y.variant.(Type_Generic)
		if !y_gen_ok { return false }
		return are_types_identical(x_gen.specialized, y_gen.specialized)

	case .Basic:
		// C++ Reference: types.cpp are_types_identical_internal
		x_basic, x_basic_ok := x.variant.(Type_Basic)
		if !x_basic_ok { return false }
		y_basic, y_basic_ok := y.variant.(Type_Basic)
		if !y_basic_ok { return false }
		return x_basic.kind == y_basic.kind

	case .Enumerated_Array:
		// C++ Reference: types.cpp are_types_identical_internal
		x_ea, x_ea_ok := x.variant.(Type_Enumerated_Array)
		if !x_ea_ok { return false }
		y_ea, y_ea_ok := y.variant.(Type_Enumerated_Array)
		if !y_ea_ok { return false }
		return are_types_identical(x_ea.index, y_ea.index) && are_types_identical(x_ea.elem, y_ea.elem)

	case .Array:
		// C++ Reference: types.cpp are_types_identical_internal
		x_arr, x_arr_ok := x.variant.(Type_Array)
		if !x_arr_ok { return false }
		y_arr, y_arr_ok := y.variant.(Type_Array)
		if !y_arr_ok { return false }
		return x_arr.count == y_arr.count && are_types_identical(x_arr.elem, y_arr.elem)

	case .Matrix:
		// C++ Reference: types.cpp are_types_identical_internal
		x_mat, x_mat_ok := x.variant.(Type_Matrix)
		if !x_mat_ok { return false }
		y_mat, y_mat_ok := y.variant.(Type_Matrix)
		if !y_mat_ok { return false }
		return x_mat.row_count == y_mat.row_count && x_mat.column_count == y_mat.column_count && x_mat.is_row_major == y_mat.is_row_major && are_types_identical(x_mat.elem, y_mat.elem)

	case .Dynamic_Array:
		// C++ Reference: types.cpp are_types_identical_internal
		x_da, x_da_ok := x.variant.(Type_Dynamic_Array)
		if !x_da_ok { return false }
		y_da, y_da_ok := y.variant.(Type_Dynamic_Array)
		if !y_da_ok { return false }
		return are_types_identical(x_da.elem, y_da.elem)

	case .Fixed_Capacity_Dynamic_Array:
		// C++ Reference: types.cpp are_types_identical_internal. Capacity is part of the identity, as in C++.
		//
		// NOTE: an earlier version of this comment claimed this arm fixed the 13-per-package
		// "Overloaded procedure has the same type as another procedure in the procedure group"
		// errors in base:runtime. It does not - that count was measured identical before and after
		// this arm was added. Those come from proc-group overload comparison, not from here.
		x_fc, x_fc_ok := x.variant.(Type_Fixed_Capacity_Dynamic_Array)
		if !x_fc_ok { return false }
		y_fc, y_fc_ok := y.variant.(Type_Fixed_Capacity_Dynamic_Array)
		if !y_fc_ok { return false }
		return x_fc.capacity == y_fc.capacity && are_types_identical(x_fc.elem, y_fc.elem)

	case .Slice:
		// C++ Reference: types.cpp are_types_identical_internal
		x_slice, x_slice_ok := x.variant.(Type_Slice)
		if !x_slice_ok { return false }
		y_slice, y_slice_ok := y.variant.(Type_Slice)
		if !y_slice_ok { return false }
		return are_types_identical(x_slice.elem, y_slice.elem)

	case .Bit_Set:
		// C++ Reference: types.cpp are_types_identical_internal
		x_bs, x_bs_ok := x.variant.(Type_Bit_Set)
		if !x_bs_ok { return false }
		y_bs, y_bs_ok := y.variant.(Type_Bit_Set)
		if !y_bs_ok { return false }

		if are_types_identical(x_bs.elem, y_bs.elem) && are_types_identical(x_bs.underlying, y_bs.underlying) {
			if is_type_enum(x_bs.elem) {
				return true
			}
			return x_bs.lower == y_bs.lower && x_bs.upper == y_bs.upper
		}
		return false

	case .Enum:
		// C++ Reference: types.cpp are_types_identical_internal
		if x == y {
			return true
		}
		x_enum, x_enum_ok := x.variant.(Type_Enum)
		if !x_enum_ok { return false }
		y_enum, y_enum_ok := y.variant.(Type_Enum)
		if !y_enum_ok { return false }

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
			// C++ Reference: types.cpp are_types_identical_internal
			a_const := a.variant.(Entity_Constant)
			b_const := b.variant.(Entity_Constant)
			same := compare_exact_values(.Cmp_Eq, a_const.value, b_const.value)
			if !same {
				return false
			}
		}

		return true

	case .Union:
		// C++ Reference: types.cpp are_types_identical_internal
		x_union, x_union_ok := x.variant.(Type_Union)
		if !x_union_ok { return false }
		y_union, y_union_ok := y.variant.(Type_Union)
		if !y_union_ok { return false }

		if len(x_union.variants) == len(y_union.variants) && x_union.kind == y_union.kind {
			// Check alignment compatibility
			// C++ Reference: types.cpp are_types_identical_internal
			if x_union.custom_align != y_union.custom_align {
				if type_align_of(x) != type_align_of(y) {
					return false
				}
			}

			// NOTE: zeroth variant is nil for normal unions
			// C++ Reference: types.cpp are_types_identical_internal
			for variant, i in x_union.variants {
				if !are_types_identical(variant, y_union.variants[i]) {
					return false
				}
			}
			return true
		}

	case .Struct:
		// C++ Reference: types.cpp are_types_identical_internal
		x_struct, x_struct_ok := x.variant.(Type_Struct)
		if !x_struct_ok { return false }
		y_struct, y_struct_ok := y.variant.(Type_Struct)
		if !y_struct_ok { return false }

		if x_struct.is_raw_union == y_struct.is_raw_union && len(x_struct.fields) == len(y_struct.fields) && x_struct.is_packed == y_struct.is_packed && x_struct.is_all_or_none == y_struct.is_all_or_none && x_struct.soa_kind == y_struct.soa_kind && x_struct.soa_count == y_struct.soa_count && are_types_identical(x_struct.soa_elem, y_struct.soa_elem) {

			// Check alignment compatibility
			// C++ Reference: types.cpp are_types_identical_internal
			if x_struct.custom_align != y_struct.custom_align {
				if type_align_of(x) != type_align_of(y) {
					return false
				}
			}

			// Check all fields match
			// C++ Reference: types.cpp are_types_identical_internal
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
				// C++ Reference: types.cpp are_types_identical_internal
				xf_flags := (xf.flags & Entity_Flags_Is_Subtype)
				yf_flags := (yf.flags & Entity_Flags_Is_Subtype)
				if xf_flags != yf_flags {
					return false
				}
			}
			// C++ Reference: types.cpp are_types_identical_internal (RE-VERIFIED; the 3352 citation was stale AGAIN -- 3352 is the subtype-flag test
			// was stale -- that range is lookup_subtype_polymorphic_selection, another function)
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
		// C++ Reference: types.cpp are_types_identical_internal
		x_ptr, x_ptr_ok := x.variant.(Type_Pointer)
		if !x_ptr_ok { return false }
		y_ptr, y_ptr_ok := y.variant.(Type_Pointer)
		if !y_ptr_ok { return false }
		return are_types_identical(x_ptr.elem, y_ptr.elem)

	case .Multi_Pointer:
		// C++ Reference: types.cpp are_types_identical_internal
		x_mp, x_mp_ok := x.variant.(Type_Multi_Pointer)
		if !x_mp_ok { return false }
		y_mp, y_mp_ok := y.variant.(Type_Multi_Pointer)
		if !y_mp_ok { return false }
		return are_types_identical(x_mp.elem, y_mp.elem)

	case .Soa_Pointer:
		// C++ Reference: types.cpp are_types_identical_internal
		x_soa, x_soa_ok := x.variant.(Type_Soa_Pointer)
		if !x_soa_ok { return false }
		y_soa, y_soa_ok := y.variant.(Type_Soa_Pointer)
		if !y_soa_ok { return false }
		return are_types_identical(x_soa.elem, y_soa.elem)

	case .Named:
		// C++ Reference: types.cpp are_types_identical_internal
		x_named, x_named_ok := x.variant.(Type_Named)
		if !x_named_ok { return false }
		y_named, y_named_ok := y.variant.(Type_Named)
		if !y_named_ok { return false }
		return x_named.type_name == y_named.type_name

	case .Tuple:
		// C++ Reference: types.cpp are_types_identical_internal
		x_tuple, x_tuple_ok := x.variant.(Type_Tuple)
		if !x_tuple_ok { return false }
		y_tuple, y_tuple_ok := y.variant.(Type_Tuple)
		if !y_tuple_ok { return false }

		if len(x_tuple.variables) == len(y_tuple.variables) && x_tuple.is_packed == y_tuple.is_packed {
			for i in 0 ..< len(x_tuple.variables) {
				xe := x_tuple.variables[i]
				ye := y_tuple.variables[i]
				if xe.kind != ye.kind || !are_types_identical(xe.type, ye.type) {
					return false
				}
				// Check parameter names if required (for unique type_info)
				// C++ Reference: types.cpp are_types_identical_internal
				if check_tuple_names {
					if xe.token.text != ye.token.text {
						return false
					}
				}
				// Check constant values for polymorphic procedures
				// C++ Reference: types.cpp are_types_identical_internal
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
		// C++ Reference: types.cpp are_types_identical_internal -- which CALLS
		// are_proc_properties_identical here rather than spelling the five fields out. The port had
		// them inlined; routing both this arm and check_distance_between_types' new
		// check_proc_params_assignable branch through one helper is what keeps "identical" and
		// "assignable" from drifting apart on the same five attributes.
		x_proc, x_proc_ok := x.variant.(Type_Proc)
		if !x_proc_ok { return false }
		y_proc, y_proc_ok := y.variant.(Type_Proc)
		if !y_proc_ok { return false }
		return(
			are_proc_properties_identical(x, y) &&
			are_types_identical_internal(x_proc.params, y_proc.params, check_tuple_names) &&
			are_types_identical_internal(x_proc.results, y_proc.results, check_tuple_names) \
		)

	case .Map:
		// C++ Reference: types.cpp are_types_identical_internal
		x_map, x_map_ok := x.variant.(Type_Map)
		if !x_map_ok { return false }
		y_map, y_map_ok := y.variant.(Type_Map)
		if !y_map_ok { return false }
		return are_types_identical(x_map.key, y_map.key) && are_types_identical(x_map.value, y_map.value)

	case .Simd_Vector:
		// C++ Reference: types.cpp are_types_identical_internal
		x_sv, x_sv_ok := x.variant.(Type_Simd_Vector)
		if !x_sv_ok { return false }
		y_sv, y_sv_ok := y.variant.(Type_Simd_Vector)
		if !y_sv_ok { return false }
		if x_sv.count == y_sv.count {
			return are_types_identical(x_sv.elem, y_sv.elem)
		}

	case .Bit_Field:
		// C++ Reference: types.cpp are_types_identical_internal
		x_bf, x_bf_ok := x.variant.(Type_Bit_Field)
		if !x_bf_ok { return false }
		y_bf, y_bf_ok := y.variant.(Type_Bit_Field)
		if !y_bf_ok { return false }

		if are_types_identical(x_bf.backing_type, y_bf.backing_type) && len(x_bf.fields) == len(y_bf.fields) {
			// Check all field properties match
			// C++ Reference: types.cpp are_types_identical_internal
			for i in 0 ..< len(x_bf.fields) {
				a := x_bf.fields[i]
				b := y_bf.fields[i]
				// C++ Reference: types.cpp are_types_identical_internal
				if !are_types_identical(a.type, b.type) {
					return false
				}
				// C++ Reference: types.cpp are_types_identical_internal
				if a.token.text != b.token.text {
					return false
				}
				// C++ Reference: types.cpp are_types_identical_internal
				if x_bf.bit_sizes[i] != y_bf.bit_sizes[i] {
					return false
				}
				// C++ Reference: types.cpp are_types_identical_internal
				if x_bf.bit_offsets[i] != y_bf.bit_offsets[i] {
					return false
				}
			}
			return true
		}
	}

	// C++ Reference: types.cpp are_types_identical_internal
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	if operand.mode == .Type {
		if is_type_typeid(type) {
			if is_type_polymorphic(operand.type) {
				return -1
			}
			// Register type info for RTTI when converting type to typeid
			// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	if are_types_identical(s, type) {
		return 0
	}

	src := base_type(s)
	dst := base_type(type)

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_untyped_uninit(src) {
		return 1
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_untyped_nil(src) {
		if type_has_nil(dst) {
			return 1
		}
		return -1
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_untyped(src) {
		if is_type_any(dst) {
			// NOTE: Anything can cast to 'Any'
			// C++ Reference: check_expr.cpp:729 -- add_type_info_type(c, s), which the port had
			// only in the LATER general `any` arm (:874 below) and in the typeid arm. It is not
			// redundant with those: this arm returns before either is reached, and
			// add_type_info_type runs default_type BEFORE its untyped guard, so an untyped
			// constant scored against an `any` parameter registers its DEFAULT type (int, f64,
			// string, bool) rather than being skipped.
			if c != nil {
				add_type_info_type(c, s)
			}
			return MAXIMUM_TYPE_DISTANCE
		}
		// #1113. C++ Reference: check_expr.cpp check_distance_between_types:
		//
		//     if (dst->kind == Type_Basic) {
		//
		// THE RAW KIND, with NO unwrapping. The port used `core_type(dst)`, whose comment claimed
		// it was "to unwrap distinct/named types to their underlying basic type" — but core_type
		// also unwraps ENUM (to its backing integer) and BIT_FIELD (to its backing type), so an
		// ENUM destination entered an arm the reference skips entirely.
		//
		// CONSEQUENCE, reported by the mirc agent as an order-dependent union conversion:
		//     E :: enum u8 { A, B }
		//     U :: union { int, E }   U(5) REJECTED by the port, accepted by the reference
		//     U :: union { E, int }   U(5) accepted by both
		// The multi-variant union scoring loop is character-identical to C++'s, so the algorithm
		// was never the bug — the SCORE was. Admitting the enum here gives it a score >= 0, and
		// with `int` also scoring, the loop's tie-detection (prev_lowest_score == lowest_score)
		// then rejects in one variant order and accepts in the other:
		//     {int, E}: lowest=0, prev=0    -> equal -> ambiguous -> reject
		//     {E, int}: lowest=k, prev=k, lowest=0 -> unequal -> accept
		//
		// A DIRECT `x: E = 5` is rejected by BOTH front ends, which is what made this hard to see:
		// the divergence is in the intermediate SCORE, not the final assignability verdict.
		//
		// Named/distinct destinations do NOT need the unwrap: the reference skips this arm for them
		// too (their kind is Type_Named) and handles them further down. Controls pin that.
		if dst.kind == .Basic {
			if operand.mode == .Constant {
				// Check if the constant value can be represented in the destination type
				// C++ Reference: check_expr.cpp check_distance_between_types
				if !check_representable_as_constant(c, operand.value, dst) {
					return -1
				}
				// Check type compatibility for typed destinations
				// C++ Reference: check_expr.cpp check_distance_between_types
				if is_type_typed(dst) && src.kind == .Basic {
					src_basic := src.variant.(Type_Basic)
					#partial switch src_basic.kind {
					case .Untyped_Bool:
						if is_type_boolean(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					case .Untyped_Rune:
						if is_type_integer(dst) || is_type_rune(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					case .Untyped_Integer:
						if is_type_integer(dst) || is_type_rune(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					case .Untyped_String:
						if is_type_string(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					case .Untyped_Float:
						if is_type_float(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					case .Untyped_Complex:
						if is_type_complex(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
						if is_type_quaternion(dst) {
							return 2
						}
					case .Untyped_Quaternion:
						if is_type_quaternion(dst) {
							return 1 if are_types_identical(dst, default_type(src)) else 2
						}
					}
				}
				// C++ Reference: check_expr.cpp check_distance_between_types
					return 3
			}
			// Non-constant untyped values
			// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types. The in_enum_type gate is part of the
	// condition, not optional: C++ only treats an enum and its own base type as
	// distance-3 assignable while checking an enum's own body. Dropping the gate makes
	// the port accept base-type values as that enum everywhere.
	if c != nil && c.in_enum_type {
		if is_type_enum(dst) {
			dst_enum := dst.variant.(Type_Enum)
			if are_types_identical(dst_enum.base_type, operand.type) {
				return 3
			}
		}
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
	// Subtype checking for using-based inheritance
	subtype_level := check_is_assignable_to_using_subtype(operand.type, type)
	if subtype_level > 0 {
		return i64(4 + subtype_level)
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	// Polymorphic type assignability
	if is_type_polymorphic(dst) && !is_type_polymorphic(src) {
		modify_type := c != nil && !c.no_polymorphic_errors
		if is_polymorphic_type_assignable(c, type, s, false, modify_type) {
			return 2
		}
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
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
		} else if is_type_untyped(src) || is_type_struct(type_deref(src)) { // allow for subtyping of structs
			// C++ check_expr.cpp:905 -- the struct term lets a struct that SUBTYPES one of the
			// variants (via `using` embedding), by value or through a pointer, score against every
			// variant and pick the best. Dropping it made the port over-reject; see wit_uni204.
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_proc(dst) {
		if are_types_identical(src, dst) {
			return 3
		}
		// Check if source is a polymorphic procedure that can be instantiated to match dst
		// C++ Reference: check_expr.cpp check_distance_between_types
		if c != nil && is_type_proc(src) {
			if src_proc, ok := base_type(src).variant.(Type_Proc); ok {
				if src_proc.is_polymorphic && !src_proc.is_poly_specialized {
					poly_data: Poly_Proc_Data
					if check_polymorphic_procedure_assignment(c, operand, dst, operand.expr, &poly_data) {
						// C++ Reference: check_expr.cpp:934-937 -- on success the reference
						// RECORDS the instantiation before scoring it:
						//     Entity *e = poly_proc_data.gen_entity;
						//     add_type_and_value(c, operand->expr, Addressing_Value, e->type, {});
						//     add_entity_use(c, operand->expr, e);
						// The port returned 4 and recorded neither, so the expression kept the
						// POLYMORPHIC type on its TAV entry instead of the specialized one, and
						// the generated entity was never marked used.
						if e := poly_data.gen_entity; e != nil {
							add_type_and_value(c, operand.expr, .Value, e.type, Exact_Value{})
							add_entity_use(c, operand.expr, e)
						}
						return 4
					}
				}
			}
		}

		// C++ Reference: check_expr.cpp:940-942 -- the THIRD arm of `if (is_type_proc(dst))`,
		// which the port did not have at all, along with check_proc_params_assignable and its
		// helper check_is_assignable_to_using_offset_zero_subtype. Without it the port
		// OVER-REJECTS a proc value whose pointer parameter is a struct embedding the
		// destination's parameter type at offset 0:
		//
		//	Base    :: struct { x: int }
		//	Derived :: struct { using base: Base, y: int }
		//	handler :: proc(d: ^Derived) {}
		//	f: proc(b: ^Base) = handler        // oracle accepts, port rejected
		//
		// Witnessed both ways before writing this: wit_bk217/k_proc_param_subtype_rev (the
		// reverse direction) and .../k_proc_param_unrelated (an unrelated struct) are rejected by
		// BOTH front ends, so the rule admits exactly the offset-zero subtype direction.
		if is_type_proc(src) && are_proc_properties_identical(dst, src) && check_proc_params_assignable(c, dst, src) {
			return 4
		}
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_complex_or_quaternion(dst) {
		elem := base_complex_elem_type(dst)
		if are_types_identical(elem, base_type(src)) {
			return 5
		}
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	if is_type_any(dst) {
		if !is_type_polymorphic(src) {
			// Check if trying to convert context to Any (not allowed)
			// C++ Reference: check_expr.cpp check_distance_between_types
			if operand.mode == .Context && are_types_identical(operand.type, c.checker.t_context) {
				return -1
			}
			// NOTE: Anything can cast to 'Any'
			// Register type info for RTTI when converting to Any
			// C++ Reference: check_expr.cpp check_distance_between_types
			if c != nil {
				add_type_info_type(c, s)
			}
			return MAXIMUM_TYPE_DISTANCE
		}
	}

	// C++ Reference: check_expr.cpp check_distance_between_types
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

	// C++ Reference: check_expr.cpp check_distance_between_types
	return -1
}

// NOTE: assign_score_function is defined in check_proc_group.odin
// NOTE: check_is_assignable_to_with_score is defined in check_proc_group.odin

// check_is_assignable_to checks if an operand can be assigned to a target type.
// Wrapper around check_is_assignable_to_with_score that discards the score
// C++ Reference: check_expr.cpp check_is_assignable_to_with_score
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
// C++ Reference: types.cpp:1836-1852
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
	// C++ Reference: types.cpp base_complex_elem_type - GB_PANIC("Invalid complex type")
	assert(false, "Invalid complex type passed to base_complex_elem_type")
	return t_invalid
}

// is_type_soa_struct checks if a type is a structure-of-arrays struct
// C++ Reference: types.cpp:1864-1868
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
