// check_builtin_simd.odin
// SIMD builtin procedure handlers
// Ported from /mnt/c/odin/src/check_builtin.cpp:720-1612
//
// This file implements all 62 SIMD intrinsic builtins for the Odin checker.
// Each handler validates operands, checks type constraints, and computes result types.
//
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:720-1612
// Enum Reference: /mnt/c/odin/src/checker_builtin_procs.hpp:140-220
// Metadata Reference: /mnt/c/odin/src/checker_builtin_procs.hpp:507-586

package checker


// ============================================================================
// SIMD Type Helper Functions
// ============================================================================

// base_array_type returns the element type of array-like types (array, simd_vector, matrix)
// C++ Reference: /mnt/c/odin/src/types.cpp:1665-1677
base_array_type :: proc(t: ^Type) -> ^Type {
	bt := base_type(t)
	if bt == nil {
		return t
	}

	#partial switch bt.kind {
	case .Array:
		return bt.variant.(Type_Array).elem
	case .Enumerated_Array:
		return bt.variant.(Type_Enumerated_Array).elem
	case .Simd_Vector:
		return bt.variant.(Type_Simd_Vector).elem
	case .Matrix:
		return bt.variant.(Type_Matrix).elem
	}

	return t
}

// get_array_type_count returns the element count of array-like types
// C++ Reference: /mnt/c/odin/src/types.cpp:1783-1794
get_array_type_count :: proc(t: ^Type) -> i64 {
	bt := base_type(t)
	if bt == nil {
		return -1
	}

	#partial switch bt.kind {
	case .Array:
		return bt.variant.(Type_Array).count
	case .Enumerated_Array:
		return bt.variant.(Type_Enumerated_Array).count
	case .Simd_Vector:
		return bt.variant.(Type_Simd_Vector).count
	}

	return -1
}

// alloc_type_simd_vector: see types.odin for the complete implementation with generic_count support
// C++ Reference: /mnt/c/odin/src/types.cpp:1189-1195

// alloc_type_bit_set allocates a bit set type
// Fields (elem, lower, upper) must be set by the caller
// C++ Reference: types.cpp:1185-1188
alloc_type_bit_set :: proc() -> ^Type {
	t := alloc_type(Type_Bit_Set)
	t.kind = .Bit_Set
	return t
}

// is_power_of_two checks if a value is a power of two
// Uses bit manipulation: a power of two has exactly one bit set,
// so x & (x-1) equals zero if and only if x is a power of two
// C++ Reference: /mnt/c/odin/src/common.hpp or gb.h
is_power_of_two :: proc(x: i64) -> bool {
	return x > 0 && (x & (x - 1)) == 0
}

// ============================================================================
// SIMD Binary Numeric Operations (add, sub, mul, div, min, max)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:722-768
// ============================================================================

check_builtin_simd_binary_numeric :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	// Check first operand
	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	// Check second operand with type hint from first
	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	// Convert second operand to match first
	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	// Validate both are SIMD vectors
	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	// Validate types match
	if !are_types_identical(x.type, y.type) {
		error(call, "'%s' expected 2 arguments of the same type", builtin_name)
		return false
	}

	// Validate element type is numeric
	elem := base_array_type(x.type)
	if !is_type_integer(elem) && !is_type_float(elem) {
		error(call.args[0], "'%s' expected a #simd type with an integer or floating point element", builtin_name)
		return false
	}

	// Special case: simd_div does not support integer elements
	// C++ Reference: check_builtin.cpp:758-763
	if id == .Simd_Div && is_type_integer(elem) {
		error(call.args[0], "'%s' is not supported for integer elements", builtin_name)
		// Note: C++ continues even after this error (doesn't return)
	}

	// Result type is same as input
	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Integer Binary Operations (saturating arithmetic, bitwise ops)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:770-824
// ============================================================================

check_builtin_simd_binary_integer :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	// Check operands
	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	// Validate SIMD vectors
	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !are_types_identical(x.type, y.type) {
		error(call, "'%s' expected 2 arguments of the same type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)

	// Different constraints for different operations
	// C++ Reference: check_builtin.cpp:801-819
	#partial switch id {
	case .Simd_Saturating_Add, .Simd_Saturating_Sub:
		if !is_type_integer(elem) {
			error(call.args[0], "'%s' expected a #simd type with an integer element", builtin_name)
			return false
		}

	case:
		// Bitwise operations allow integers or booleans
		if !is_type_integer(elem) && !is_type_boolean(elem) {
			error(call.args[0], "'%s' expected a #simd type with an integer or boolean element", builtin_name)
			return false
		}
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Shift Operations (shl, shr, shl_masked, shr_masked)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:826-872
// ============================================================================

check_builtin_simd_shift :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	// Check value operand
	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	// Check shift amount operand
	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	// Validate SIMD vectors
	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	// Validate lane counts match
	// C++ Reference: check_builtin.cpp:849-855
	x_count := get_array_type_count(x.type)
	y_count := get_array_type_count(y.type)

	if x_count != y_count {
		error(call, "'%s' mismatched simd vector lengths, got %d vs %d", builtin_name, x_count, y_count)
		return false
	}

	// Validate element types
	if !is_type_integer(base_array_type(x.type)) {
		error(call.args[0], "'%s' expected a #simd type with an integer element", builtin_name)
		return false
	}

	if !is_type_unsigned(base_array_type(y.type)) {
		error(call.args[1], "'%s' expected a #simd type with an unsigned integer element as the shifting operand", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Unary Operations (neg, abs)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:874-897
// ============================================================================

check_builtin_simd_unary :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_integer(elem) && !is_type_float(elem) {
		error(call.args[0], "'%s' expected a #simd type with an integer or floating point element", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Comparison Operations (lanes_eq, lanes_ne, lanes_lt, lanes_le, lanes_gt, lanes_ge)
// Returns integer masks where element size matches input element size
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:899-969
// ============================================================================

check_builtin_simd_comparison :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)

	// Check element type constraints based on operation
	// C++ Reference: check_builtin.cpp:921-939
	#partial switch id {
	case .Simd_Lanes_Eq, .Simd_Lanes_Ne:
		// Equality comparisons allow integer, float, or boolean
		if !is_type_integer(elem) && !is_type_float(elem) && !is_type_boolean(elem) {
			error(call.args[0], "'%s' expected a #simd type with an integer, floating point, or boolean element", builtin_name)
			return false
		}

	case:
		// Ordering comparisons require integer or float
		if !is_type_integer(elem) && !is_type_float(elem) {
			error(call.args[0], "'%s' expected a #simd type with an integer or floating point element", builtin_name)
			return false
		}
	}

	if !are_types_identical(x.type, y.type) {
		error(call, "Mismatched types to '%s'", builtin_name)
		return false
	}

	// Create result type: unsigned integer vector with element size matching input
	// C++ Reference: check_builtin.cpp:949-967
	count := get_array_type_count(x.type)
	sz := type_size_of(elem)

	new_elem: ^Type
	switch sz {
	case 1:
		new_elem = t_u8
	case 2:
		new_elem = t_u16
	case 4:
		new_elem = t_u32
	case 8:
		new_elem = t_u64
	case 16:
		error(call.args[0], "'%s' not supported for 128-bit integer backed simd vector types", builtin_name)
		return false
	case:
		error(call.args[0], "'%s' unsupported element size %d", builtin_name, sz)
		return false
	}

	operand.mode = .Value
	operand.type = alloc_type_simd_vector(count, new_elem)
	return true
}

// ============================================================================
// SIMD Memory Operations (gather, scatter, masked_load, masked_store, etc.)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:971-1054
// ============================================================================

check_builtin_simd_memory :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 3 {
		error(call, "'%s' expected 3 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	// gather (ptr: #simd[N]rawptr, values: #simd[N]T, mask: #simd[N]int_or_bool) -> #simd[N]T
	// scatter(ptr: #simd[N]rawptr, values: #simd[N]T, mask: #simd[N]int_or_bool)
	// masked_load (ptr: rawptr, values: #simd[N]T, mask: #simd[N]int_or_bool) -> #simd[N]T
	// masked_store(ptr: rawptr, values: #simd[N]T, mask: #simd[N]int_or_bool)

	ptr: Operand
	check_expr(ctx, &ptr, call.args[0])
	if ptr.mode == .Invalid {
		return false
	}

	values: Operand
	check_expr(ctx, &values, call.args[1])
	if values.mode == .Invalid {
		return false
	}

	mask: Operand
	check_expr(ctx, &mask, call.args[2])
	if mask.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(values.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(mask.type) {
		error(call.args[2], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	// Validate pointer argument based on operation type
	if id == .Simd_Gather || id == .Simd_Scatter {
		// gather/scatter expect simd vector of rawptr
		if !is_type_simd_vector(ptr.type) {
			error(call.args[0], "'%s' expected a simd vector type", builtin_name)
			return false
		}

		ptr_elem := base_array_type(ptr.type)
		if !is_type_rawptr(ptr_elem) {
			error(call.args[0], "Expected a simd vector of 'rawptr' for the addresses")
			return false
		}
	} else {
		// masked_* operations expect regular pointer
		if !is_type_pointer(ptr.type) {
			error(call.args[0], "Expected a pointer type for the address")
			return false
		}
	}

	// Validate mask element type
	mask_elem := base_array_type(mask.type)
	if !is_type_integer(mask_elem) && !is_type_boolean(mask_elem) {
		error(call.args[2], "Expected a simd vector of integers or booleans for the mask")
		return false
	}

	// Validate lane counts match
	if id == .Simd_Gather || id == .Simd_Scatter {
		ptr_count := get_array_type_count(ptr.type)
		values_count := get_array_type_count(values.type)
		mask_count := get_array_type_count(mask.type)

		if ptr_count != values_count || values_count != mask_count {
			error(call, "All simd vectors must be of the same length, got %d vs %d vs %d", ptr_count, values_count, mask_count)
			return false
		}
	} else {
		values_count := get_array_type_count(values.type)
		mask_count := get_array_type_count(mask.type)

		if values_count != mask_count {
			error(call, "All simd vectors must be of the same length, got %d vs %d", values_count, mask_count)
			return false
		}
	}

	// Set return value based on operation
	if id == .Simd_Gather || id == .Simd_Masked_Load || id == .Simd_Masked_Expand_Load {
		operand.mode = .Value
		operand.type = values.type
	} else {
		// scatter and store operations return nothing
		operand.mode = .No_Value
		operand.type = nil
	}

	return true
}

// ============================================================================
// SIMD Indices (returns constant index vector)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1056-1084
// ============================================================================

check_builtin_simd_indices :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_indices"

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr_or_type(ctx, &x, call.args[0], nil)
	if x.mode == .Invalid {
		return false
	}

	if x.mode != .Type {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_numeric(elem) {
		error(call.args[0], "'%s' expected a simd vector type with a numeric element type", builtin_name)
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Extract (get single lane by index)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1086-1110
// ============================================================================

check_builtin_simd_extract :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_extract"

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	max_count := get_array_type_count(x.type)

	// Validate index is constant and in range
	value: i64 = -1
	if !check_index_value(ctx, x.type, false, call.args[1], max_count, &value) {
		return false
	}

	if value < 0 {
		error(call.args[1], "'%s' expected a constant integer index, got %d", builtin_name, value)
		return false
	}

	operand.mode = .Value
	operand.type = elem
	return true
}

// ============================================================================
// SIMD Replace (set single lane by index)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1111-1147
// ============================================================================

check_builtin_simd_replace :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_replace"

	if len(call.args) != 3 {
		error(call, "'%s' expected 3 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	max_count := get_array_type_count(x.type)

	// Validate index
	value: i64 = -1
	if !check_index_value(ctx, x.type, false, call.args[1], max_count, &value) {
		return false
	}

	if value < 0 {
		error(call.args[1], "'%s' expected a constant integer index, got %d", builtin_name, value)
		return false
	}

	// Check replacement value
	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[2], elem)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, elem)
	if y.mode == .Invalid {
		return false
	}

	if !are_types_identical(y.type, elem) {
		error(call.args[2], "'%s' expected a type to insert that matches element type", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Reduction Operations (reduce to scalar)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1149-1200
// ============================================================================

check_builtin_simd_reduce_numeric :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_integer(elem) && !is_type_float(elem) {
		error(call.args[0], "'%s' expected a #simd type with an integer or floating point element", builtin_name)
		return false
	}

	// Return scalar element type
	operand.mode = .Value
	operand.type = elem
	return true
}

// SIMD Reduction Bitwise (and, or, xor)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1178-1200
check_builtin_simd_reduce_bitwise :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_integer(elem) && !is_type_boolean(elem) {
		error(call.args[0], "'%s' expected a #simd type with an integer or boolean element", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = elem
	return true
}

// SIMD Reduction Boolean (any, all)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1202-1223
check_builtin_simd_reduce_boolean :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_boolean(elem) {
		error(call.args[0], "'%s' expected a #simd type with a boolean element", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = t_untyped_bool
	return true
}

// ============================================================================
// SIMD Extract LSBs/MSBs (extract bits to bit set)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1225-1256
// ============================================================================

check_builtin_simd_extract_bits :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_integer_like(elem) {
		error(call.args[0], "'%s' expected a #simd type with integer or boolean elements", builtin_name)
		return false
	}

	num_elems := get_array_type_count(x.type)

	// Return a bit set type with range 0..<num_elems
	// C++ Reference: check_builtin.cpp:1248-1254
	result_type := alloc_type_bit_set()
	// Cannot mutate variant fields directly - must create new struct
	bit_set_data := Type_Bit_Set {
		elem  = t_int,
		lower = 0,
		upper = num_elems - 1,
	}
	result_type.variant = bit_set_data

	operand.mode = .Value
	operand.type = result_type
	return true
}

// ============================================================================
// SIMD Shuffle (permute elements from two vectors)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1259-1332
// ============================================================================

check_builtin_simd_shuffle :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_shuffle"

	if len(call.args) < 2 {
		error(call, "'%s' expected at least 2 arguments", builtin_name)
		return false
	}

	// Check first two vector operands
	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !are_types_identical(x.type, y.type) {
		error(call, "'%s' expected 2 arguments of the same type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	max_count := get_array_type_count(x.type) + get_array_type_count(y.type)

	// Validate all index arguments (variadic)
	arg_count: i64 = 0
	for i in 2 ..< len(call.args) {
		op: Operand
		check_expr(ctx, &op, call.args[i])
		if op.mode == .Invalid {
			return false
		}

		arg_type := base_type(op.type)
		if !is_type_integer(arg_type) || op.mode != .Constant {
			error(call.args[i], "Indices to '%s' must be constant integers", builtin_name)
			return false
		}

		// Check index is non-negative and in range
		idx_val := exact_value_to_i64(op.value)
		if idx_val < 0 {
			error(call.args[i], "Negative '%s' index", builtin_name)
			return false
		}

		if idx_val >= max_count {
			error(call.args[i], "'%s' index exceeds length", builtin_name)
			return false
		}

		arg_count += 1
	}

	if arg_count > max_count {
		error(call, "Too many '%s' indices, %d > %d", builtin_name, arg_count, max_count)
		return false
	}

	// CRITICAL: Result lane count must be power of two
	// C++ Reference: check_builtin.cpp:1324
	if !is_power_of_two(arg_count) {
		error(call, "'%s' must have a power of two index arguments, got %d", builtin_name, arg_count)
		return false
	}

	operand.mode = .Value
	operand.type = alloc_type_simd_vector(arg_count, elem)
	return true
}

// ============================================================================
// SIMD Select (ternary conditional)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1334-1385
// ============================================================================

check_builtin_simd_select :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_select"

	if len(call.args) != 3 {
		error(call, "'%s' expected 3 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	// Check condition vector
	cond: Operand
	check_expr(ctx, &cond, call.args[0])
	if cond.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(cond.type) {
		error(call.args[0], "'%s' expected a simd vector boolean type", builtin_name)
		return false
	}

	cond_elem := base_array_type(cond.type)
	if !is_type_boolean(cond_elem) && !is_type_integer(cond_elem) {
		error(call.args[0], "'%s' expected a simd vector boolean or integer type", builtin_name)
		return false
	}

	// Check value vectors
	x: Operand
	check_expr(ctx, &x, call.args[1])
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[2], x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[2], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !are_types_identical(x.type, y.type) {
		error(call, "'%s' expected 2 results of the same type", builtin_name)
		return false
	}

	// Validate lane counts match
	cond_count := get_array_type_count(cond.type)
	x_count := get_array_type_count(x.type)

	if cond_count != x_count {
		error(call, "'%s' expected condition vector to match the length of the result lengths, got %d vs %d", builtin_name, cond_count, x_count)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Runtime Swizzle (runtime lane permutation)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1387-1437
// ============================================================================

check_builtin_simd_runtime_swizzle :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_runtime_swizzle"

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	src: Operand
	check_expr(ctx, &src, call.args[0])
	if src.mode == .Invalid {
		return false
	}

	indices: Operand
	check_expr_with_type_hint(ctx, &indices, call.args[1], src.type)
	if indices.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(src.type) {
		error(call.args[0], "'%s' expected first argument to be a simd vector", builtin_name)
		return false
	}

	if !is_type_simd_vector(indices.type) {
		error(call.args[1], "'%s' expected second argument (indices) to be a simd vector", builtin_name)
		return false
	}

	src_elem := base_array_type(src.type)
	indices_elem := base_array_type(indices.type)

	if !is_type_integer(src_elem) {
		error(call.args[0], "'%s' expected first argument to be a simd vector of integers", builtin_name)
		return false
	}

	if !is_type_integer(indices_elem) {
		error(call.args[1], "'%s' expected indices to be a simd vector of integers", builtin_name)
		return false
	}

	if !are_types_identical(src.type, indices.type) {
		error(call, "'%s' expected both arguments to have the same type", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = src.type
	return true
}

// ============================================================================
// SIMD Rounding Operations (ceil, floor, trunc, nearest)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1439-1462
// ============================================================================

check_builtin_simd_rounding :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_float(elem) {
		error(call.args[0], "'%s' expected a simd vector floating point type", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Lanes Reverse (reverse lane order)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1464-1476
// ============================================================================

check_builtin_simd_lanes_reverse :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_lanes_reverse"

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Lanes Rotate (rotate lanes left/right by constant offset)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1478-1499
// ============================================================================

check_builtin_simd_lanes_rotate :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr, id: Builtin_Proc_Id) -> bool {
	builtin_name := builtin_proc_infos[id].name

	if len(call.args) != 2 {
		error(call, "'%s' expected 2 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	// Check offset is constant integer
	offset: Operand
	check_expr(ctx, &offset, call.args[1])
	if offset.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &offset, t_i64)
	if !is_type_integer(offset.type) || offset.mode != .Constant {
		error(call.args[1], "'%s' expected a constant integer offset", builtin_name)
		return false
	}

	check_assignment(ctx, &offset, t_i64, builtin_name)

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD Clamp (three-way min/max)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1501-1550
// ============================================================================

check_builtin_simd_clamp :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_clamp"

	if len(call.args) != 3 {
		error(call, "'%s' expected 3 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	y: Operand
	check_expr_with_type_hint(ctx, &y, call.args[1], x.type)
	if y.mode == .Invalid {
		return false
	}

	z: Operand
	check_expr_with_type_hint(ctx, &z, call.args[2], x.type)
	if z.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &y, x.type)
	if y.mode == .Invalid {
		return false
	}

	convert_to_typed(ctx, &z, x.type)
	if z.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(y.type) {
		error(call.args[1], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !is_type_simd_vector(z.type) {
		error(call.args[2], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	if !are_types_identical(x.type, y.type) {
		error(call, "'%s' expected arguments of the same type", builtin_name)
		return false
	}

	if !are_types_identical(x.type, z.type) {
		error(call, "'%s' expected arguments of the same type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	if !is_type_integer(elem) && !is_type_float(elem) {
		error(call.args[0], "'%s' expected a #simd type with an integer or floating point element", builtin_name)
		return false
	}

	operand.mode = .Value
	operand.type = x.type
	return true
}

// ============================================================================
// SIMD To Bits (reinterpret as unsigned integer vector)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1552-1576
// ============================================================================

check_builtin_simd_to_bits :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_to_bits"

	if len(call.args) != 1 {
		error(call, "'%s' expected 1 argument, got %d", builtin_name, len(call.args))
		return false
	}

	x: Operand
	check_expr(ctx, &x, call.args[0])
	if x.mode == .Invalid {
		return false
	}

	if !is_type_simd_vector(x.type) {
		error(call.args[0], "'%s' expected a simd vector type", builtin_name)
		return false
	}

	elem := base_array_type(x.type)
	count := get_array_type_count(x.type)
	sz := type_size_of(elem)

	bit_elem: ^Type
	switch sz {
	case 1:
		bit_elem = t_u8
	case 2:
		bit_elem = t_u16
	case 4:
		bit_elem = t_u32
	case 8:
		bit_elem = t_u64
	case:
		error(call.args[0], "'%s' unsupported element size %d", builtin_name, sz)
		return false
	}

	operand.mode = .Value
	operand.type = alloc_type_simd_vector(count, bit_elem)
	return true
}

// ============================================================================
// SIMD x86 MM_SHUFFLE (compile-time shuffle constant generator)
// C++ Reference: /mnt/c/odin/src/check_builtin.cpp:1578-1606
// ============================================================================

check_builtin_simd_x86_mm_shuffle :: proc(ctx: ^Checker_Context, operand: ^Operand, call: ^Ast_Call_Expr) -> bool {
	builtin_name := "simd_x86__MM_SHUFFLE"

	if len(call.args) != 4 {
		error(call, "'%s' expected 4 arguments, got %d", builtin_name, len(call.args))
		return false
	}

	offsets := [4]u32{6, 4, 2, 0}
	result: u32 = 0

	for i in 0 ..< 4 {
		x: Operand
		check_expr(ctx, &x, call.args[i])
		if x.mode == .Invalid {
			return false
		}

		if !is_type_integer(x.type) || x.mode != .Constant {
			error(call.args[i], "'%s' expected a constant integer", builtin_name)
			return false
		}

		val := exact_value_to_i64(x.value)
		if val < 0 || val > 3 {
			error(call.args[i], "'%s' expected a constant integer in the range 0..<4, got %d", builtin_name, val)
			return false
		}

		result |= u32(val) << offsets[i]
	}

	operand.mode = .Constant
	operand.type = t_untyped_integer
	operand.value = exact_value_i64(i64(result))
	return true
}
