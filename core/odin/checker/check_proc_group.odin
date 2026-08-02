package checker

/*
Procedure Group Resolution (Overload Resolution).

This module implements procedure group (overload) resolution, allowing multiple
procedures with the same name but different signatures to coexist and be resolved
at call sites based on argument types.

Reference: /mnt/c/odin/src/check_expr.cpp:6933-7504
*/

import "core:odin/ast"
import "core:slice"
import "core:strings"

// param_accepts_via_any_int implements C++'s `#any_int` fallback for a procedure argument.
//
// C++ Reference: check_expr.cpp:6853-6866. When the ordinary assignability check fails, a
// parameter tagged `#any_int` gets a second chance: if the operand is not a type, the parameter
// is an integer, and the operand is an integer OR an enum, then CASTABILITY is enough.
//
// The port set Entity_Flag.Any_Int at declaration time (check_type.odin:4201) but never read it
// anywhere except the type printer and the docs writer, so the fallback did not exist. Plain
// calls survived on the port's more permissive general assignability; proc-GROUP scoring uses
// check_is_assignable_to_with_score and rejected them - which is why
// `validate(date.year, date.month, date.day)` in core/time/datetime failed on argument 2 while
// the same call to a non-group procedure was fine.
param_accepts_via_any_int :: proc(ctx: ^Checker_Context, operand: ^Operand, param: ^Entity, param_type: ^Type) -> bool {
	if param == nil || .Any_Int not_in param.flags {
		return false
	}
	if operand.mode == .Type {
		return false
	}
	if !is_type_integer(param_type) {
		return false
	}
	if !is_type_integer(operand.type) && !is_type_enum(operand.type) {
		return false
	}
	return check_is_castable_to(ctx, operand, param_type)
}

// MAXIMUM_TYPE_DISTANCE is defined in check_equivalence.odin (value: 10)
// Reference: /mnt/c/odin/src/check_expr.cpp:665

// strip_or_return_expr peels `or_return` / `or_break` / `or_continue` wrappers
// and parentheses off an expression.
// C++ Reference: /mnt/c/odin/src/parser.cpp strip_or_return_expr
strip_or_return_expr :: proc(node: ^ast.Expr) -> ^ast.Expr {
	n := node
	for {
		if n == nil {
			return nil
		}
		#partial switch e in n.derived {
		case ^ast.Or_Return_Expr:
			n = e.expr
		case ^ast.Or_Branch_Expr:
			n = e.expr
		case ^ast.Paren_Expr:
			n = e.expr
		case:
			return n
		}
	}
}

// might_return_multiple_values checks if an expression could yield multiple values.
// Used for arity filtering in proc groups: when an argument might expand into
// several values, the candidate list must not be pruned by argument count.
//
// NOTE(bill): The only thing that may have multiple values will be a call
// expression (assuming `or_return` and `()` will be stripped). This is a purely
// syntactic test on purpose — at this point in checking the callee may not be
// resolved yet, so asking for its result arity would answer "one value" for
// every not-yet-checked call and prune away every viable candidate.
//
// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_call_arguments_proc_group,
// the `max_arg_count = ISIZE_MAX` loops.
might_return_multiple_values :: proc(ctx: ^Checker_Context, expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}

	// Named arguments carry the candidate expression in the value
	inner := expr
	if fv, is_fv := unparen_expr(inner).derived.(^ast.Field_Value); is_fv {
		inner = fv.value
	}

	inner = strip_or_return_expr(inner)
	if inner == nil {
		return false
	}

	_, is_call := inner.derived.(^ast.Call_Expr)
	return is_call
}

// Proc_Type_Overload_Kind classifies how two procedure types differ
// Used by are_proc_types_overload_safe to determine overload safety
// C++ Reference: /mnt/c/odin/src/types.cpp:3355-3369
Proc_Type_Overload_Kind :: enum {
	Identical, // The types are identical (not safe - collision)
	Calling_Convention, // Different calling conventions
	Param_Count, // Different parameter counts (safe)
	Param_Variadic, // Variadic differs (not safe - ambiguous)
	Param_Types, // Different parameter types (safe)
	Result_Count, // Different result counts (not safe - same params, different results)
	Result_Types, // Different result types (not safe - same params, different results)
	Polymorphic, // One is polymorphic, other isn't (conditionally safe)
	Target_Features, // Different target feature requirements (safe)
	Not_Procedure, // One or both are not procedures
}

// Valid_Index_And_Score tracks a candidate procedure with its match quality score
// Reference: /mnt/c/odin/src/check_expr.cpp:57-60
Valid_Index_And_Score :: struct {
	index: int, // Index into the candidate list
	score: i64, // Match quality score (higher = better match)
}

// Call_Argument_Data is defined in check_expr.odin
// Reference: /mnt/c/odin/src/check_expr.cpp:41-50

// Call_Argument_Error_Mode controls how errors are reported during argument checking
// Reference: /mnt/c/odin/src/check_expr.cpp:31-35
Call_Argument_Error_Mode :: enum {
	No_Errors, // Don't report errors (for candidate testing)
	Show_Errors, // Report all errors
}

// are_proc_types_overload_safe determines if two procedure types can safely coexist
// in a procedure group (overload set). Returns the classification of their difference.
//
// Overload safety rules:
// - SAFE: Different parameter counts, different parameter types, different target features
// - UNSAFE: Identical signatures, same params but different results, variadic differences
// - CONDITIONAL: Polymorphic (allowed with 'where' clauses)
//
// C++ Reference: /mnt/c/odin/src/types.cpp:3371-3436
are_proc_types_overload_safe :: proc(x, y: ^Type) -> Proc_Type_Overload_Kind {
	// Null checks (C++ lines 3372-3376)
	if x == nil && y == nil do return .Not_Procedure
	if x == nil || y == nil do return .Not_Procedure
	if !is_type_proc(x) do return .Not_Procedure
	if !is_type_proc(y) do return .Not_Procedure

	// Get base procedure types (C++ lines 3378-3379)
	px_base := base_type(x)
	py_base := base_type(y)

	assert(px_base.kind == .Proc && py_base.kind == .Proc)
	px := &px_base.variant.(Type_Proc)
	py := &py_base.variant.(Type_Proc)

	// NOTE: Calling convention checking is commented out in C++ (lines 3382-3384)
	// if px.calling_convention != py.calling_convention {
	// 	return .Calling_Convention
	// }

	// Check parameter count (C++ lines 3390-3392)
	if px.param_count != py.param_count {
		return .Param_Count
	}

	// Check parameter types (C++ lines 3394-3399)
	if px.params != nil && py.params != nil {
		if px.params.kind == .Tuple && py.params.kind == .Tuple {
			px_tuple := &px.params.variant.(Type_Tuple)
			py_tuple := &py.params.variant.(Type_Tuple)

			for i in 0 ..< px.param_count {
				ex := px_tuple.variables[i]
				ey := py_tuple.variables[i]
				if !are_types_identical(entity_type(ex), entity_type(ey)) {
					return .Param_Types
				}
			}
		}
	}

	// IMPORTANT TODO(bill): Determine the rules for overloading procedures with variadic parameters
	// C++ lines 3401-3404
	if px.variadic != py.variadic {
		return .Param_Variadic
	}

	// Check polymorphic status (C++ lines 3407-3409)
	if px.is_polymorphic != py.is_polymorphic {
		return .Polymorphic
	}

	// Check result count (C++ lines 3411-3413)
	if px.result_count != py.result_count {
		return .Result_Count
	}

	// Check result types (C++ lines 3415-3421)
	if px.results != nil && py.results != nil {
		if px.results.kind == .Tuple && py.results.kind == .Tuple {
			px_results := &px.results.variant.(Type_Tuple)
			py_results := &py.results.variant.(Type_Tuple)

			for i in 0 ..< px.result_count {
				ex := px_results.variables[i]
				ey := py_results.variables[i]
				if !are_types_identical(entity_type(ex), entity_type(ey)) {
					return .Result_Types
				}
			}
		}
	}

	// Check target features (C++ lines 3423-3425)
	if matched_target_features(px) != matched_target_features(py) {
		return .Target_Features
	}

	// C++ lines 3427-3433: Dead code that checks first param identity (no-op)
	// Omitted from Odin port

	// Types are identical (C++ line 3435)
	return .Identical
}

// proc_group_entities retrieves the list of procedures in a procedure group
// Reference: /mnt/c/odin/src/checker.cpp:3230-3240
// proc_group_entities is defined in entity_helpers.odin

// proc_group_entities_cloned is defined in entity_helpers.odin

// score_type_name_argument handles a polymorphic type parameter (`$T: typeid/...`),
// whose argument is a TYPE rather than a value.
//
// C++ Reference: check_expr.cpp:6953-6968. The parameter loop in
// check_call_arguments_internal has a dedicated `Entity_TypeName` arm that requires
// an `Addressing_Type` operand, scores it, and `continue`s — it never reaches
// `check_is_assignable_to_with_score`. Both of the port's scoring loops were missing
// that arm, so the type operand was fed to the assignability check and every call
// through a proc group whose members take a type parameter failed. `make`, `new`,
// `resize` and friends are all such groups, which is why the failure was universal.
// The single-candidate path (check_call_arguments_basic) already skips these, which
// is why a direct call to the same procedure resolved fine.
//
// Returns (score, true) when the parameter was a type name and has been handled;
// a negative score means the argument was rejected. Returns (0, false) otherwise.
score_type_name_argument :: proc(ctx: ^Checker_Context, param: ^Entity, operand: ^Operand, call_node: ^ast.Node, show_error: bool) -> (i64, bool) {
	if param.kind != .Type_Name {
		return 0, false
	}
	if operand.mode != .Type {
		if show_error {
			error_node(call_node, "Expected a type for the argument '%s'", param.token.text)
		}
		return -1, true
	}
	if are_types_identical(entity_type(param), operand.type) {
		return assign_score_function(1), true
	}
	return assign_score_function(MAXIMUM_TYPE_DISTANCE), true
}

// assign_score_function converts a type distance into a match quality score
// Higher score = better match. Uses a quadratic formula to ensure distinct scores.
// Reference: /mnt/c/odin/src/check_expr.cpp:992-1002
assign_score_function :: proc(distance: i64, is_variadic := false) -> i64 {
	// Formula: 3*x^2 + 1 > x^2 + x + 1 (for positive x)
	// This ensures that lower distances always produce higher scores
	c := 3 * MAXIMUM_TYPE_DISTANCE * MAXIMUM_TYPE_DISTANCE + 1

	// Calculate quadratic score
	d := distance * distance // x^2
	if is_variadic && d >= 0 {
		d += distance + 1 // x^2 + x + 1 (penalty for variadic)
	}

	return max(i64(c) - d, 0)
}

// valid_index_and_score_cmp compares two candidates by score (for sorting)
// Returns: -1 if a better than b, +1 if b better than a, 0 if equal
// Reference: /mnt/c/odin/src/check_expr.cpp:62-66
valid_index_and_score_cmp :: proc(a, b: Valid_Index_And_Score) -> slice.Ordering {
	if a.score > b.score {
		return .Less // a is better (higher score)
	} else if a.score < b.score {
		return .Greater // b is better
	}
	return .Equal
}

// get_procedure_param_count_excluding_defaults counts required parameters
// Reference: /mnt/c/odin/src/check_expr.cpp:6174-6225
get_procedure_param_count_excluding_defaults :: proc(proc_type: ^Type, total_count: ^int = nil) -> int {
	if proc_type.kind != .Proc {
		if total_count != nil {
			total_count^ = 0
		}
		return 0
	}

	pt := &proc_type.variant.(Type_Proc)
	param_count := 0
	param_count_excluding_defaults := 0
	variadic := pt.variadic

	// Get parameter count from tuple
	if pt.params != nil && pt.params.kind == .Tuple {
		params := &pt.params.variant.(Type_Tuple)
		param_count = len(params.variables)

		// Adjust param_count for variadic procedures (C++ lines 6186-6202)
		// Remove trailing defaults from variadic params, then remove variadic param itself
		if variadic {
			for i := param_count - 1; i >= 0; i -= 1 {
				entity := params.variables[i]

				// Stop if we hit a type name parameter
				if entity.kind == .Type_Name {
					break
				}

				// Remove trailing default parameters
				if entity.kind == .Variable {
					var_entity := &entity.variant.(Entity_Variable)
					if var_entity.param_value.kind != .Invalid {
						param_count -= 1
						continue
					}
				}
				break
			}
			param_count -= 1 // Remove variadic param itself
		}
	}

	param_count_excluding_defaults = param_count

	// Count required params excluding defaults (C++ lines 6206-6221)
	if pt.params != nil && pt.params.kind == .Tuple {
		params := &pt.params.variant.(Type_Tuple)
		for i := param_count - 1; i >= 0; i -= 1 {
			entity := params.variables[i]

			// Stop if we hit a type name parameter
			if entity.kind == .Type_Name {
				break
			}

			// Count backwards through default parameters
			if entity.kind == .Variable {
				var_entity := &entity.variant.(Entity_Variable)
				if var_entity.param_value.kind != .Invalid {
					param_count_excluding_defaults -= 1
					continue
				}
			}
			break
		}
	}

	if total_count != nil {
		total_count^ = param_count
	}
	return param_count_excluding_defaults
}

// check_is_assignable_to_with_score checks assignability and returns a match score
// Reference: /mnt/c/odin/src/check_expr.cpp:1005-1034
check_is_assignable_to_with_score :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, score: ^i64 = nil, is_variadic := false, allow_array_programming := true) -> bool {
	if ctx == nil {
		assert(operand.mode == .Value)
	}

	// Special case: polymorphic procedure as default value
	if operand.mode == .Value && is_type_proc(target_type) && is_type_proc(operand.type) {
		entity := entity_from_expr_ctx(ctx, operand.expr)
		if entity != nil && entity.kind == .Procedure {
			proc_entity := &entity.variant.(Entity_Procedure)
			if proc_entity.type != nil && is_type_polymorphic(proc_entity.type) {
				base_target := base_type(target_type)
				if !is_type_polymorphic(base_target) {
					// Allow polymorphic proc as default for concrete proc type
					if score != nil {
						score^ = assign_score_function(1)
					}
					return true
				}
			}
		}
	}

	// Calculate type distance
	distance := check_distance_between_types(ctx, operand, target_type, allow_array_programming)
	if distance >= 0 {
		if score != nil {
			score^ = assign_score_function(distance, is_variadic)
		}
		return true
	}

	if score != nil {
		score^ = 0
	}
	return false
}

// lookup_procedure_parameter looks up a parameter index by name
// Returns -1 if not found or name is blank identifier
// Reference: /mnt/c/odin/src/check_expr.cpp:6228-6241
lookup_procedure_parameter :: proc(pt: ^Type_Proc, name: string) -> int {
	if pt.params == nil || pt.params.kind != .Tuple {
		return -1
	}

	// Blank identifiers cannot be looked up
	if is_blank_ident(name) {
		return -1
	}

	params := &pt.params.variant.(Type_Tuple)
	for param, i in params.variables {
		param_name := param.token.text
		if is_blank_ident(param_name) {
			continue
		}
		if param_name == name {
			return i
		}
	}

	return -1
}

// has_named_arguments checks if a call expression has any named arguments
// Reference: /mnt/c/odin/src/check_expr.cpp:6325-6364 (implied)
has_named_arguments :: proc(call: ^ast.Call_Expr) -> bool {
	for arg in call.args {
		if _, ok := arg.derived.(^ast.Field_Value); ok {
			return true
		}
	}
	return false
}

// check_named_arguments validates and type-checks named arguments for a procedure call
// Returns true if all named arguments are valid, false otherwise
// Reference: /mnt/c/odin/src/check_expr.cpp:6799-6857
check_named_arguments :: proc(ctx: ^Checker_Context, proc_type: ^Type, named_args: []^ast.Node, named_operands: ^[dynamic]Operand, show_error: bool) -> bool {
	success := true

	base_proc_type := base_type(proc_type)
	if len(named_args) == 0 {
		return success
	}

	pt: ^Type_Proc = nil
	if base_proc_type != nil && base_proc_type.kind == .Proc {
		pt = &base_proc_type.variant.(Type_Proc)
	}

	for arg in named_args {
		// Expect Field_Value node (name = value)
		fv, is_field_value := arg.derived.(^ast.Field_Value)
		if !is_field_value {
			if show_error {
				error_node(arg, "Expected a 'field = value'")
			}
			return false
		}

		// Field must be an identifier
		ident, is_ident := fv.field.derived.(^ast.Ident)
		if !is_ident {
			if show_error {
				error_node(arg, "Invalid parameter name in procedure call")
			}
			success = false
			continue
		}

		key := ident.name
		value := fv.value

		// Try to find type hint from parameter list
		type_hint: ^Type = nil
		if pt != nil {
			param_index := lookup_procedure_parameter(pt, key)
			if param_index < 0 {
				if show_error {
					error_node(value, "No parameter named '%s' for this procedure type", key)
				}
				success = false
				continue
			}

			if pt.params != nil && pt.params.kind == .Tuple {
				params := &pt.params.variant.(Type_Tuple)
				if param_index < len(params.variables) {
					entity := params.variables[param_index]
					entity_param_type := entity_type(entity)
					if !is_type_polymorphic(entity_param_type) {
						type_hint = entity_param_type
					}
				}
			}
		}

		// Check the value expression with the type hint
		operand := Operand{}
		check_expr_with_type_hint(ctx, &operand, value, type_hint)
		if operand.mode == .Invalid {
			success = false
		}
		append(named_operands, operand)
	}

	return success
}

// matched_target_features counts how many target features are matched/enabled
// This is used for scoring procedure candidates in overload resolution
// Reference: /mnt/c/odin/src/types.cpp:3338-3353
matched_target_features :: proc(pt: ^Type_Proc) -> int {
	if len(pt.require_target_feature) == 0 {
		return 0
	}

	matches := 0

	// Split the comma-separated feature list
	feature_str := pt.require_target_feature
	features := strings.split(feature_str, ",", context.temp_allocator)

	for feature in features {
		trimmed := strings.trim_space(feature)
		if len(trimmed) > 0 {
			// Note: Full implementation requires checking if feature is enabled in
			// build_context.target_features_set (populated by frontend, not available here).
			// For now, count all valid features as "matched" for scoring purposes.
			// C++: types.cpp:3365 uses check_target_feature_is_valid_for_target_arch
			valid, _ := check_target_feature_is_valid_for_target_arch(trimmed)
			if valid {
				matches += 1
			}
		}
	}

	return matches
}

// Split_Args holds the result of splitting call arguments into positional and named
// Reference: /mnt/c/odin/src/check_expr.cpp:7527-7545
Split_Args :: struct {
	positional: []^ast.Node,
	named:      []^ast.Node,
}

// split_call_arguments splits arguments into positional and named slices
// Positional arguments come first, named arguments (Field_Value nodes) come after
// Reference: /mnt/c/odin/src/check_expr.cpp:7527-7545
split_call_arguments :: proc(call: ^ast.Call_Expr, allocator := context.allocator) -> Split_Args {
	// Count positional args (stop at first Field_Value)
	positional_count := 0
	for arg in call.args {
		if _, is_named := arg.derived.(^ast.Field_Value); is_named {
			break
		}
		positional_count += 1
	}

	// Create slices
	positional := make([]^ast.Node, positional_count, allocator)
	named := make([]^ast.Node, len(call.args) - positional_count, allocator)

	// Fill positional
	for i in 0 ..< positional_count {
		positional[i] = call.args[i]
	}

	// Fill named
	named_idx := 0
	for i in positional_count ..< len(call.args) {
		named[named_idx] = call.args[i]
		named_idx += 1
	}

	return Split_Args{positional = positional, named = named}
}

// check_call_parameter_mixture validates that positional arguments don't appear after named ones
// C++ Reference: check_expr.cpp (implied in argument parsing)
// Returns true if argument order is valid, false if positional appears after named
check_call_parameter_mixture :: proc(ctx: ^Checker_Context, call: ^ast.Call_Expr) -> bool {
	seen_named := false

	for arg in call.args {
		_, is_named := arg.derived.(^ast.Field_Value)

		if is_named {
			seen_named = true
		} else if seen_named {
			// Positional argument after a named argument
			error_node(arg, "Positional arguments must appear before named arguments in procedure calls")
			return false
		}
	}

	return true
}

// filter_proc_group_by_param_count removes candidates with incompatible parameter counts
// Reference: /mnt/c/odin/src/check_expr.cpp:6998-7019
filter_proc_group_by_param_count :: proc(candidates: ^[dynamic]^Entity, min_arg_count: int, max_arg_count: int) {
	// Filter in reverse to safely remove elements
	for i := len(candidates) - 1; i >= 0; i -= 1 {
		entity_proc := candidates[i]
		proc_type := base_type(entity_type(entity_proc))

		if proc_type == nil || proc_type.kind != .Proc {
			ordered_remove(candidates, i)
			continue
		}

		pt := &proc_type.variant.(Type_Proc)

		total_param_count := 0
		required_param_count := get_procedure_param_count_excluding_defaults(proc_type, &total_param_count)

		// Too few arguments for required parameters
		if required_param_count > max_arg_count {
			ordered_remove(candidates, i)
			continue
		}

		// Too many arguments for non-variadic procedure
		if !pt.variadic && max_arg_count != max(int) && total_param_count < max_arg_count {
			ordered_remove(candidates, i)
			continue
		}
	}
}

// check_call_arguments_internal performs the detailed argument checking
// Handles positional arguments, named arguments, variadic parameters, and scoring
// Reference: /mnt/c/odin/src/check_expr.cpp:6095-6638
check_call_arguments_internal :: proc(
	ctx: ^Checker_Context,
	call_node: ^ast.Node,
	entity: ^Entity,
	proc_type: ^Type,
	positional_operands: []Operand,
	named_operands: []Operand,
	args_split: Split_Args,
	error_mode: Call_Argument_Error_Mode,
	data: ^Call_Argument_Data,
	checking_proc_group: bool,
) -> bool {
	show_error := error_mode == .Show_Errors

	if proc_type.kind != .Proc {
		return false
	}

	pt := &proc_type.variant.(Type_Proc)

	// Handle polymorphic procedures by attempting instantiation
	// C++ Reference: check_expr.cpp:6116-6140
	specialized_proc_type := proc_type
	if pt.is_polymorphic && !pt.is_poly_specialized {
		// Build operands array from positional operands
		operands := make([]Operand, len(positional_operands))
		defer delete(operands)
		copy(operands, positional_operands)

		// Try to instantiate the polymorphic procedure
		poly_data := Poly_Proc_Data{}
		ctx_copy := ctx^
		ctx_copy.in_proc_group = true
		if find_or_generate_polymorphic_procedure_from_parameters(&ctx_copy, entity, operands, call_node, &poly_data) {
			// Use the specialized procedure type instead
			if poly_data.gen_entity != nil {
				data.gen_entity = poly_data.gen_entity
				specialized_proc_type = base_type(entity_type(poly_data.gen_entity))
				pt = &specialized_proc_type.variant.(Type_Proc)
			}
		} else {
			// Instantiation failed
			return false
		}
	}

	// Get parameter list
	if pt.params == nil || pt.params.kind != .Tuple {
		// No parameters
		if len(positional_operands) > 0 || len(named_operands) > 0 {
			if show_error {
				error_node(call_node, "Too many arguments to procedure call")
			}
			return false
		}
		data.result_type = pt.results
		data.final_proc_type = specialized_proc_type
		data.score = 0
		return true
	}

	params := &pt.params.variant.(Type_Tuple)

	// Score accumulator
	total_score: i64 = 0

	// Handle named arguments by creating ordered operand array
	// Reference: /mnt/c/odin/src/check_expr.cpp:6291-6364
	if len(named_operands) > 0 {
		// Create ordered array matching parameter order
		ordered_operands := make([dynamic]Operand, len(params.variables))
		defer delete(ordered_operands)

		// Initialize with invalid operands (representing unfilled parameters)
		for i in 0 ..< len(ordered_operands) {
			ordered_operands[i] = Operand {
				mode = .Invalid,
			}
		}

		// Track which parameters have been filled
		visited := make([dynamic]bool, len(params.variables))
		defer delete(visited)
		for i in 0 ..< len(visited) {
			visited[i] = false
		}

		// Fill positional arguments first (use pre-checked positional_operands)
		for &operand, i in positional_operands {
			if i < len(ordered_operands) {
				ordered_operands[i] = operand
				visited[i] = true
			}
		}

		// Fill named arguments using pre-checked named_operands
		// Reference: /mnt/c/odin/src/check_expr.cpp:7569-7600
		for named_arg, i in args_split.named {
			if fv, ok := named_arg.derived.(^ast.Field_Value); ok {
				if ident, ok2 := fv.field.derived.(^ast.Ident); ok2 {
					name := ident.name

					// Find parameter index
					param_idx := lookup_procedure_parameter(pt, name)
					if param_idx < 0 {
						if show_error {
							error_node(named_arg, "No parameter named '%s' for this procedure type", name)
						}
						return false
					}

					// Check for duplicate parameter
					if visited[param_idx] {
						if show_error {
							error_node(named_arg, "Duplicate parameter '%s' in procedure call", name)
						}
						return false
					}

					// Use pre-checked named operand (already checked in caller)
					ordered_operands[param_idx] = named_operands[i]
					visited[param_idx] = true
				}
			}
		}

		// Now score using ordered operands
		for &operand, i in ordered_operands {
			if operand.mode == .Invalid {
				// Parameter not provided - it may have a default value
				// This will be validated by parameter count checks
				continue
			}

			param := params.variables[i]
			param_type := entity_type(param)

			if param_type == nil {
				continue
			}

			if score, handled := score_type_name_argument(ctx, param, &operand, call_node, show_error); handled {
				if score < 0 {
					return false
				}
				total_score += score
				continue
			}

			arg_score: i64 = 0
			is_variadic_param := i == pt.variadic_index

			if !check_is_assignable_to_with_score(ctx, &operand, param_type, &arg_score, is_variadic_param) {
				if !param_accepts_via_any_int(ctx, &operand, param, param_type) {
					if show_error {
						error_node(call_node, "Argument for parameter '%s' has incompatible type", param.token.text)
					}
					return false
				}
			}

			total_score += arg_score
		}

		if !report_missing_parameters(pt, params, visited[:], call_node, show_error) {
			return false
		}

		data.result_type = pt.results
		data.final_proc_type = specialized_proc_type
		data.score = int(total_score)
		return true
	}

	// Fall through to existing positional-only logic
	// Match positional arguments
	for &operand, i in positional_operands {
		// Index of the parameter this argument binds to. Everything at or past the
		// variadic index binds to the variadic parameter, so the index saturates there
		// rather than running off the end.
		//
		// C++ Reference: check_expr.cpp:6970-6975 and the variadic_operands loop at
		// :6992-6999 — arguments in the variadic slot are scored one by one against the
		// slice's ELEMENT type, via eval_param_and_score(..., t = elem, ...).
		param_index := i
		if pt.variadic && pt.variadic_index >= 0 && i >= int(pt.variadic_index) {
			param_index = int(pt.variadic_index)
		} else if i >= len(params.variables) {
			if show_error {
				error_node(call_node, "Too many arguments to procedure call")
			}
			return false
		}
		if param_index >= len(params.variables) {
			continue
		}

		param := params.variables[param_index]
		param_type := entity_type(param)

		if param_type == nil {
			continue
		}

		if score, handled := score_type_name_argument(ctx, param, &operand, call_node, show_error); handled {
			if score < 0 {
				return false
			}
			total_score += score
			continue
		}

		// Check if this argument is assignable to this parameter
		arg_score: i64 = 0
		is_variadic_param := pt.variadic && param_index == int(pt.variadic_index)

		// For an argument bound to the variadic parameter, score it against the
		// element type. The port previously scored against the SLICE type itself, so a
		// group member declared `proc(items: ..^Int)` never matched `f(x)` for an `^Int`
		// — which is how core/math/big calls `internal_destroy` throughout.
		//
		// `f(xs..)` passes the slice itself, so accept that spelling first.
		effective_type := param_type
		if is_variadic_param {
			if check_is_assignable_to(ctx, &operand, param_type) {
				total_score += assign_score_function(1, true)
				continue
			}
			if slice_type := base_type(param_type); slice_type != nil && slice_type.kind == .Slice {
				effective_type = slice_type.variant.(Type_Slice).elem
			}
		}

		if !check_is_assignable_to_with_score(ctx, &operand, effective_type, &arg_score, is_variadic_param) {
			if !param_accepts_via_any_int(ctx, &operand, param, effective_type) {
				if show_error {
					error_node(call_node, "Argument %d has incompatible type", i + 1)
				}
				return false
			}
		}

		total_score += arg_score
	}

	{
		// Every parameter past the positional operands is unfilled.
		positional_visited := make([]bool, len(params.variables), context.temp_allocator)
		for i in 0 ..< min(len(positional_operands), len(params.variables)) {
			positional_visited[i] = true
		}
		if !report_missing_parameters(pt, params, positional_visited, call_node, show_error) {
			return false
		}
	}

	data.result_type = pt.results
		data.final_proc_type = specialized_proc_type
	data.score = int(total_score)
	return true
}

// report_missing_parameters rejects a candidate that leaves a required parameter
// unfilled. Without it a call is scored purely on the arguments it does supply,
// so a 3-parameter procedure would happily "match" a 2-argument call and end up
// tied with the correct 2-parameter overload.
//
// A parameter may be legitimately absent when it has a default value, when it is
// the variadic parameter (which may be empty), or when it is a polymorphic type
// or constant parameter resolved during instantiation rather than passed.
//
// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_call_arguments_internal,
// the `for (isize i = 0; i < pt->param_count; i++) if (!visited[i])` loop that
// sets `CallArgumentError_ParameterMissing`.
report_missing_parameters :: proc(pt: ^Type_Proc, params: ^Type_Tuple, visited: []bool, call_node: ^ast.Node, show_error: bool) -> bool {
	ok := true
	for e, i in params.variables {
		if i < len(visited) && visited[i] {
			continue
		}
		if e == nil {
			continue
		}
		// The variadic parameter may be empty
		if pt.variadic && i == pt.variadic_index {
			continue
		}
		// Polymorphic type/constant parameters are resolved during instantiation
		#partial switch e.kind {
		case .Type_Name, .Constant:
			continue
		}
		// A default value stands in for the missing argument
		if v, is_var := e.variant.(Entity_Variable); is_var {
			if v.param_value.kind != .Invalid {
				continue
			}
		}

		if show_error {
			if e.token.text != "" {
				error_node(call_node, "Missing argument for parameter '%s'", e.token.text)
			} else {
				error_node(call_node, "Missing argument for parameter at position %d", i)
			}
		}
		ok = false
	}
	return ok
}

// check_call_arguments_single checks a single procedure candidate
// Reference: /mnt/c/odin/src/check_expr.cpp:6859-6930
check_call_arguments_single :: proc(
	ctx: ^Checker_Context,
	call_node: ^ast.Node,
	operand: ^Operand,
	entity: ^Entity,
	proc_type: ^Type,
	positional_operands: []Operand,
	named_operands: []Operand,
	args_split: Split_Args,
	error_mode: Call_Argument_Error_Mode,
	data: ^Call_Argument_Data,
	checking_proc_group: bool,
) -> bool {
	return_on_failure := error_mode == .No_Errors

	// Ensure we have a procedure type
	base_proc_type := base_type(proc_type)
	if base_proc_type == nil || base_proc_type.kind != .Proc {
		return false
	}

	// Check arguments
	ok := check_call_arguments_internal(ctx, call_node, entity, base_proc_type, positional_operands, named_operands, args_split, error_mode, data, checking_proc_group)

	if !ok && return_on_failure {
		return false
	}

	// If successful and not just testing, add entity use and type tracking
	if ok && !return_on_failure && entity != nil {
		add_entity_use(ctx, operand.expr, entity)
		// Add type and value for proper expression type tracking
		if operand.expr != nil && operand.type != nil {
			add_type_and_value(ctx, operand.expr, operand.mode, operand.type, operand.value)
		}
	}

	// C++ Reference: check_expr.cpp:7281-7308
	//
	// A polymorphic candidate that instantiated successfully is not yet a match:
	// its `where` clauses are evaluated against the BOUND parameters, and a
	// clause that comes out false rejects the candidate. This is the only thing
	// separating two group members whose parameter lists are both structurally
	// satisfied - `proc(v: $T/[$N]$E) where IS_FLOAT(E)` and `proc(q: $Q) where
	// IS_QUATERNION(Q)` both accept a [3]f16 structurally, and without this the
	// group call is reported as ambiguous.
	//
	// NOTE: unlike C++ this does not schedule the body; the port already calls
	// check_procedure_later from inside
	// find_or_generate_polymorphic_procedure_from_parameters.
	if data.gen_entity != nil {
		gen := data.gen_entity
		decl := gen.decl_info
		if decl != nil && decl.proc_lit != nil {
			ctx_copy := ctx^
			ctx_copy.scope = decl.scope
			ctx_copy.decl = decl
			ctx_copy.proc_name = gen.token.text
			ctx_copy.curr_proc_decl = decl
			ctx_copy.curr_proc_sig = gen.type

			// Only used to attach an "at caller location" note.
			caller: ^ast.Expr = nil
			if ce, ce_ok := call_node.derived.(^ast.Call_Expr); ce_ok {
				caller = ce
			}

			clauses_ok := evaluate_where_clauses(&ctx_copy, caller, decl.scope, decl.proc_lit.where_clauses, !return_on_failure)
			if return_on_failure {
				if !clauses_ok {
					return false
				}
			} else {
				decl.where_clauses_evaluated = true
			}
		}
	}

	return ok
}

// check_procedure_group_call resolves overloaded procedure calls
// This is the main entry point for procedure group resolution
// Reference: /mnt/c/odin/src/check_expr.cpp:6933-7504
check_procedure_group_call :: proc(ctx: ^Checker_Context, operand: ^Operand, call_node: ^ast.Node) -> Call_Argument_Data {
	data := Call_Argument_Data {
		result_type = t_invalid,
		error       = false,
	}

	call := call_node.derived.(^ast.Call_Expr)

	// Get the list of candidate procedures
	procs_slice := proc_group_entities(ctx, &operand^)
	if len(procs_slice) == 0 {
		error_node(operand.expr, "Empty procedure group")
		data.error = true
		return data
	}

	// Clone to a dynamic array for filtering
	procs := make([dynamic]^Entity, len(procs_slice))
	defer delete(procs)
	copy(procs[:], procs_slice)

	// Count arguments, considering multi-value returns
	// C++ Reference: /mnt/c/odin/src/check_expr.cpp:6880-6920
	min_arg_count := len(call.args)
	max_arg_count := len(call.args)

	// Check if any argument might return multiple values (tuple expansion)
	// If so, max_arg_count becomes unbounded for filtering purposes
	for arg in call.args {
		if might_return_multiple_values(ctx, arg) {
			max_arg_count = max(int) // Unbounded - tuple could expand to any count
			break
		}
	}

	// Filter by named arguments FIRST (before arity filtering)
	// Reference: /mnt/c/odin/src/check_expr.cpp:6969-6988
	if len(call.args) > 0 {
		for arg in call.args {
			// Check if this is a named argument (field_value: name = value)
			if fv, ok := arg.derived.(^ast.Field_Value); ok {
				if ident, ok2 := fv.field.derived.(^ast.Ident); ok2 {
					name := ident.name

					// Remove procedures that don't have this parameter name
					for i := len(procs) - 1; i >= 0; i -= 1 {
						entity := procs[i]
						proc_type := base_type(entity_type(entity))

						if proc_type != nil && proc_type.kind == .Proc {
							pt := &proc_type.variant.(Type_Proc)
							param_index := lookup_procedure_parameter(pt, name)
							if param_index < 0 {
								// This procedure doesn't have a parameter with this name
								ordered_remove(&procs, i)
							}
						}
					}
				}
			}
		}

		// If all candidates were filtered out, restore the original list
		// This allows for better error messages downstream
		// Reference: /mnt/c/odin/src/check_expr.cpp:6990-6995
		if len(procs) == 0 {
			copy(procs[:len(procs_slice)], procs_slice)
			resize(&procs, len(procs_slice))
		}
	}

	// Filter candidates by parameter count
	if len(procs) > 1 {
		filter_proc_group_by_param_count(&procs, min_arg_count, max_arg_count)
	}

	// If only one candidate remains, check it directly
	// Reference: /mnt/c/odin/src/check_expr.cpp:7030-7048
	if len(procs) == 1 {
		entity := procs[0]
		proc_type := base_type(entity_type(entity))

		// Split arguments before checking
		// Reference: /mnt/c/odin/src/check_expr.cpp:7527-7545
		args_split := split_call_arguments(call)
		defer delete(args_split.positional)
		defer delete(args_split.named)

		// Check positional arguments, unpacking any multi-valued expression and
		// hinting each argument with the sole candidate's matching parameter type.
		//
		// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_call_arguments_proc_group,
		// the `procs.count == 1` branch's
		// `check_unpack_arguments(c, lhs, lhs_count, &positional_operands, positional_args, UnpackFlag_None, variadic_index)`.
		//
		// No flags: neither `---` nor optional-ok spreading is legal at a call site.
		positional_args := call.args[:len(args_split.positional)]
		positional_operands_dyn := make([dynamic]Operand, 0, 2 * len(positional_args))
		defer delete(positional_operands_dyn)
		{
			lhs: []^Entity = nil
			unpack_variadic_index := -1
			if proc_type != nil && proc_type.kind == .Proc {
				lhs = populate_proc_parameter_list(ctx, proc_type)
				if pt, is_proc := &proc_type.variant.(Type_Proc); is_proc && pt.variadic {
					unpack_variadic_index = pt.variadic_index
				}
			}
			check_unpack_arguments(ctx, lhs, &positional_operands_dyn, positional_args, {}, unpack_variadic_index)
		}
		positional_operands := positional_operands_dyn[:]

		// Check named arguments using helper function
		// Reference: /mnt/c/odin/src/check_expr.cpp:7041
		named_operands := make([dynamic]Operand)
		defer delete(named_operands)

		if !check_named_arguments(ctx, proc_type, args_split.named, &named_operands, true) {
			data.error = true
			return data
		}

		ok := check_call_arguments_single(ctx, call_node, operand, entity, proc_type, positional_operands, named_operands[:], args_split, .Show_Errors, &data, false)

		if !ok {
			data.error = true
		}

		return data
	}

	// Multiple candidates - need to score and select best match

	// Split arguments before checking
	// Reference: /mnt/c/odin/src/check_expr.cpp:7527-7545
	args_split := split_call_arguments(call)
	defer delete(args_split.positional)
	defer delete(args_split.named)

	// Check positional arguments, unpacking any multi-valued expression.
	//
	// C++ Reference: /mnt/c/odin/src/check_expr.cpp check_call_arguments_proc_group,
	// the multi-candidate
	// `check_unpack_arguments(c, lhs, lhs_count, &positional_operands, positional_args, UnpackFlag_None, variadic_index)`.
	//
	// NOTE(bill): the `lhs` here improves type inference for procedure groups
	// where the same positional parameter has the same type (and ellipsis) in
	// every candidate; where the candidates disagree the slot is left nil so no
	// type hint is applied.
	positional_args := call.args[:len(args_split.positional)]
	positional_operands_dyn := make([dynamic]Operand, 0, 2 * len(positional_args))
	defer delete(positional_operands_dyn)
	{
		lhs: []^Entity = nil
		variadic_index := -1

		// Smallest parameter count across all candidates
		proc_arg_count := -1
		for p in procs {
			bt := base_type(entity_type(p))
			if bt != nil && bt.kind == .Proc {
				cpt := &bt.variant.(Type_Proc)
				if proc_arg_count < 0 {
					proc_arg_count = cpt.param_count
				} else {
					proc_arg_count = min(proc_arg_count, cpt.param_count)
				}
			}
		}

		if proc_arg_count > 0 {
			lhs = make([]^Entity, proc_arg_count, context.temp_allocator)
			for param_index in 0 ..< proc_arg_count {
				e: ^Entity = nil
				for p in procs {
					bt := base_type(entity_type(p))
					if bt == nil || bt.kind != .Proc {
						continue
					}
					cpt := &bt.variant.(Type_Proc)
					if cpt.params == nil || cpt.params.kind != .Tuple {
						continue
					}
					vars := cpt.params.variant.(Type_Tuple).variables
					if param_index >= len(vars) {
						continue
					}

					if e == nil {
						e = vars[param_index]
					} else {
						f := vars[param_index]
						if e == f {
							continue
						}
						if f != nil && are_types_identical(e.type, f.type) {
							ee := .Ellipsis in e.flags
							fe := .Ellipsis in f.flags
							if ee == fe {
								continue
							}
						}
						// NOTE(bill): Entities are not close enough to be used
						e = nil
						break
					}
				}
				lhs[param_index] = e
			}

			// Only hint into the variadic slot when every candidate is
			// polymorphic and agrees on where the variadic parameter is.
			for p in procs {
				bt := base_type(entity_type(p))
				if bt == nil || bt.kind != .Proc {
					continue
				}
				cpt := &bt.variant.(Type_Proc)
				if cpt.is_polymorphic {
					if variadic_index == -1 {
						variadic_index = cpt.variadic_index
					} else if variadic_index != cpt.variadic_index {
						variadic_index = -1
						break
					}
				} else {
					variadic_index = -1
					break
				}
			}
		}

		check_unpack_arguments(ctx, lhs, &positional_operands_dyn, positional_args, {}, variadic_index)
	}
	positional_operands := positional_operands_dyn[:]

	// Check named arguments using helper function
	// Reference: /mnt/c/odin/src/check_expr.cpp:7124-7153
	named_operands := make([dynamic]Operand)
	defer delete(named_operands)

	// For multi-candidate testing, we still need to check named args
	// but we don't show errors yet (will be shown when final candidate is selected)
	for arg in args_split.named {
		if fv, ok := arg.derived.(^ast.Field_Value); ok {
			// Check only the VALUE part of Field_Value
			// Reference: /mnt/c/odin/src/check_expr.cpp:7151
			operand := Operand{}
			check_expr_base(ctx, &operand, fv.value, nil)
			append(&named_operands, operand)
		} else {
			// Should not happen (split should only put Field_Value in named)
			append(&named_operands, Operand{mode = .Invalid})
		}
	}

	// Track valid candidates with scores
	valid_candidates := make([dynamic]Valid_Index_And_Score)
	defer delete(valid_candidates)

	// Build proc_entities array to track both original and generated polymorphic entities
	// C++ Reference: check_expr.cpp:7157-7160, 7196-7198
	// This is critical for polymorphic procedure groups - when a polymorphic procedure
	// generates a specialized entity, we need to track it in the candidates array
	proc_entities := make([dynamic]^Entity, len(procs), len(procs) * 2 + 1)
	defer delete(proc_entities)
	copy(proc_entities[:], procs[:])

	// Track maximum matched target features for scoring
	// Reference: /mnt/c/odin/src/check_expr.cpp:7204-7221
	max_matched_features := 0

	// Test each candidate
	for entity_proc, i in proc_entities {
		if .Disabled in entity_proc.flags {
			continue
		}

		proc_type := base_type(entity_type(entity_proc))
		if proc_type == nil || proc_type.kind != .Proc {
			continue
		}

		pt := &proc_type.variant.(Type_Proc)

		// Test this candidate
		candidate_data := Call_Argument_Data{}

		// Create a sub-context for testing (to suppress errors)
		// C++ Reference: check_expr.cpp:7559-7562 sets all THREE of these before probing
		// a candidate. The port set only no_polymorphic_errors, which left
		// hide_polymorphic_errors permanently false everywhere (its sole reader,
		// check_type.odin:3637, mirrors check_type.cpp:1636) and left
		// allow_polymorphic_types at whatever the enclosing context happened to hold.
		test_ctx := ctx^
		test_ctx.no_polymorphic_errors = true
		test_ctx.allow_polymorphic_types = is_type_polymorphic(proc_type)
		test_ctx.hide_polymorphic_errors = true

		ok := check_call_arguments_single(&test_ctx, call_node, operand, entity_proc, proc_type, positional_operands, named_operands[:], args_split, .No_Errors, &candidate_data, true)

		if !ok {
			continue
		}

		// Determine which entity index to use
		// If polymorphic procedure generated a specialized entity, use that instead
		// C++ Reference: check_expr.cpp:7196-7198
		candidate_index := i
		if candidate_data.gen_entity != nil {
			append(&proc_entities, candidate_data.gen_entity)
			candidate_index = len(proc_entities) - 1
		}

		// This is a valid candidate
		candidate := Valid_Index_And_Score {
			index = candidate_index,
			score = i64(candidate_data.score),
		}

		// Prefer non-polymorphic over polymorphic
		if is_type_polymorphic(proc_type) {
			candidate.score += assign_score_function(1)
		}

		// Track max matched target features across all candidates
		// Reference: /mnt/c/odin/src/check_expr.cpp:7204
		matched := matched_target_features(pt)
		max_matched_features = max(max_matched_features, matched)

		append(&valid_candidates, candidate)
	}

	// Adjust scores based on target feature matching
	// Procedures with more matched features get higher scores
	// Reference: /mnt/c/odin/src/check_expr.cpp:7212-7221
	if max_matched_features > 0 {
		for &candidate in valid_candidates {
			entity_proc := proc_entities[candidate.index]
			proc_type := base_type(entity_type(entity_proc))
			if proc_type != nil && proc_type.kind == .Proc {
				pt := &proc_type.variant.(Type_Proc)
				matched := matched_target_features(pt)
				// Give bonus score for better feature matching
				candidate.score += assign_score_function(i64(max_matched_features - matched))
			}
		}
	}

	// Check results
	if len(valid_candidates) == 0 {
		// No valid candidates
		// C++ Reference: check_expr.cpp:7676-7684. C++ NAMES THE GROUP and renders the
		// argument list as a bulleted block; the port printed neither the group name nor
		// C++'s format ("\t[0] T" instead of "\t • T"), and emitted the continuation
		// outside an error block so it preceded the diagnostic.
		begin_error_block()
		defer end_error_block()
		expr_name := expr_to_string(operand.expr)
		defer delete(expr_name)
		error_node(operand.expr, "No procedures or ambiguous call for procedure group '%s' that match with the given arguments", expr_name)
		if len(positional_operands) == 0 {
			error_line("\tNo given arguments\n")
		} else {
			error_line("\tGiven argument types:\n")
			for op in positional_operands {
				type_str := type_to_string(op.type)
				error_line("\t \u2022 %s\n", type_str)
			}
		}
		data.error = true
		return data
	}

	if len(valid_candidates) == 1 {
		// Exactly one match - use it
		winner := procs[valid_candidates[0].index]
		proc_type := base_type(entity_type(winner))

		ok := check_call_arguments_single(ctx, call_node, operand, winner, proc_type, positional_operands, named_operands[:], args_split, .Show_Errors, &data, false)

		if !ok {
			data.error = true
		}

		return data
	}

	// Multiple candidates - sort by score and pick best
	slice.sort_by_cmp(valid_candidates[:], valid_index_and_score_cmp)

	best_score := valid_candidates[0].score
	best_entity := proc_entities[valid_candidates[0].index]

	// Count how many candidates share the best score
	num_best := 1
	for i := 1; i < len(valid_candidates); i += 1 {
		if valid_candidates[i].score < best_score {
			break
		}
		if proc_entities[valid_candidates[i].index] == best_entity {
			break
		}
		num_best += 1
	}

	if num_best > 1 {
		// Ambiguous call
		error_node(operand.expr, "Ambiguous procedure group call - multiple procedures match equally")
		for i := 0; i < num_best; i += 1 {
			candidate := proc_entities[valid_candidates[i].index]
			// Print full procedure signature with parameter types for better diagnostics
			if candidate.type != nil {
				type_str := type_to_string(candidate.type)
				error_line("\tCandidate: %s :: %s", candidate.token.text, type_str)
			} else {
				error_line("\tCandidate: %s", candidate.token.text)
			}
		}
		data.error = true
		return data
	}

	// Unambiguous best candidate
	winner := best_entity
	proc_type := base_type(entity_type(winner))

	ok := check_call_arguments_single(ctx, call_node, operand, winner, proc_type, positional_operands, named_operands[:], args_split, .Show_Errors, &data, false)

	if !ok {
		data.error = true
	}

	return data
}
