package checker

/*
Procedure Group Resolution (Overload Resolution).

This module implements procedure group (overload) resolution, allowing multiple
procedures with the same name but different signatures to coexist and be resolved
at call sites based on argument types.

Reference: check_expr.cpp:6933-7504
*/

import "core:odin/ast"
import "core:sync"
import "core:slice"
import "core:strings"

// eval_param_and_score is C++'s lambda of the same name, ported once.
// C++ Reference: check_expr.cpp check_call_arguments_internal (the lambda's full extent).
// ANCHORED deliberately: this block and the six below were bare `check_expr.cpp:NNNN` citations, which
// citefn --check cannot verify. They had drifted a uniform ~+22 lines and --check read drifted=0 the
// whole time. Each was remapped by CONTENT, not by applying the offset blanket-fashion (#587).
//
// The port had TWO REDUCED copies of it inline in this file (the named-argument scoring loop and
// the positional one) while check_expr.odin carried a third, fuller one. #527 fixed the two items
// that made the reduced copies emit invented text and bail where C++ continues. This ports the
// rest and gives both sites one implementation, per CLAUDE.md's standing rule that simplified
// versions are not acceptable -- two copies is exactly how this drifted.
//
// Returns the score. `err` is an in-out flag mirroring C++'s CallArgumentError parameter: set on
// failure, never cleared, and the caller consults it AFTER the loop so a bad argument no longer
// hides a later missing-parameter report.
eval_param_and_score :: proc(
	ctx: ^Checker_Context,
	operand: ^Operand,
	param_type: ^Type,
	err: ^bool,
	param_is_variadic: bool,
	param: ^Entity,
	show_error: bool,
) -> i64 {
	// C++ Reference: check_expr.cpp check_call_arguments_internal. `#no_broadcast` on a parameter disables array
	// programming for THAT parameter, so the assignability test has to be told.
	allow_array_programming := !(param != nil && .No_Broadcast in param.flags)

	score: i64 = 0
	if !check_is_assignable_to_with_score(ctx, operand, param_type, &score, param_is_variadic, allow_array_programming) {
		ok := param_accepts_via_any_int(ctx, operand, param, param_type)

		// C++ Reference: check_expr.cpp check_call_arguments_internal. When broadcasting is disallowed but the
		// argument WOULD have been assignable with it allowed, C++ names the reason rather
		// than emitting a bare type mismatch.
		if !allow_array_programming && check_is_assignable_to(ctx, operand, param_type, true) {
			if show_error {
				error_node(operand.expr, "'#no_broadcast' disallows automatic broadcasting a value across all elements of an array-like type in a procedure argument")
			}
		}

		if ok {
			score = assign_score_function(MAXIMUM_TYPE_DISTANCE)
		} else {
			// C++ Reference: check_expr.cpp check_call_arguments_internal.
			if show_error {
				check_assignment(ctx, operand, param_type, "procedure argument")
			}
			err^ = true
		}
	} else if show_error {
		// C++ Reference: check_expr.cpp check_call_arguments_internal. C++ calls check_assignment on the SUCCESS
		// path too. check_is_assignable_to_with_score answers "could this convert";
		// check_assignment performs the conversion and reports what only the conversion can
		// discover. Omitting it was an UNDER-REJECTION -- #194's class, fixed there for a
		// different site and WAS missing here. FIXED -- the check_assignment call below IS the fix.
		// (This line used to read "still missing here", which reads like an OPEN gap; tick 192
		// re-verified it with witness $S/phase2/wit_claims/cl_pgenum and both compilers now emit
		// the same diagnostic. Wording corrected so it is not chased again.) The example:
		//     E :: enum{A,B};  fe :: proc(x: E);  ge :: proc{fe};  ge(0)
		//     oracle -> Cannot convert untyped value '0' to 'E' from 'untyped integer'
		//     port   -> accepted
		// data/err is deliberately NOT set here: C++ leaves err untouched in this branch.
		check_assignment(ctx, operand, param_type, "procedure argument")
	}

	// C++ Reference: check_expr.cpp check_call_arguments_internal.
	if param != nil && .Const_Input in param.flags {
		if operand.mode != .Constant {
			if show_error {
				error_node(operand.expr, "Expected a constant value for the argument '%s'", param.token.text)
			}
			err^ = true
		}
	}

	// C++ Reference: check_expr.cpp check_call_arguments_internal.
	if param != nil && param.kind == .Constant && is_type_proc(entity_type(param)) {
		_, is_proc_value := operand.value.(Exact_Value_Procedure)
		ok := operand.mode == .Constant || is_proc_value
		if !ok {
			if show_error {
				error_node(operand.expr, "Expected a constant procedure value for the argument '%s'", param.token.text)
			}
			err^ = true
		}
	}

	// THE LAMBDA'S TAIL. C++ Reference: check_expr.cpp check_call_arguments_internal.
	//
	// All three copies of this lambda stopped short and omitted these nine lines (LEDGER #682).
	// They EMIT NOTHING -- the whole effect is recorded state -- so no message-based method could
	// see the gap, and the model dump could not either until `tidepn` was added (#686/#687). What
	// finally measured it: every entity that differed had the port registering exactly ONE fewer
	// type-info dependency than the reference, `println_any` (an `any` parameter) among them.
	//
	// `!err^` is C++'s `!err`: the `any` registration is skipped for an argument that already
	// failed. The port's `err` is a bool rather than an error enum, but the CONDITION is the same
	// one -- "no error recorded for this argument yet".
	if !err^ && is_type_any(param_type) {
		add_type_info_type(ctx, operand.type)
	}
	if operand.mode == .Type && is_type_typeid(param_type) {
		add_type_info_type(ctx, operand.type)
		add_type_and_value(ctx, operand.expr, .Value, param_type, exact_value_typeid(operand.type))
	} else if show_error && is_type_untyped(operand.type) {
		update_untyped_expr_type(ctx, operand.expr, param_type, true)
	}

	return score
}

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
// (STRANDED above a different procedure until #734 -- another procedure was inserted between
//  this doc comment and the definition it documents.)
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
// Reference: check_expr.cpp:665

// strip_or_return_expr peels `or_return` / `or_break` / `or_continue` wrappers
// and parentheses off an expression.
// C++ Reference: parser.cpp strip_or_return_expr
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
// C++ Reference: check_expr.cpp check_call_arguments_proc_group,
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
// C++ Reference: types.cpp:3355-3369
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
// Reference: check_expr.cpp:57-60
Valid_Index_And_Score :: struct {
	index: int, // Index into the candidate list
	score: i64, // Match quality score (higher = better match)
}

// Call_Argument_Data is defined in check_expr.odin
// Reference: check_expr.cpp:41-50

// Call_Argument_Error_Mode controls how errors are reported during argument checking
// Reference: check_expr.cpp:31-35
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
// C++ Reference: types.cpp:3371-3436
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
// Reference: checker.cpp:3230-3240
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
// Reference: check_expr.cpp:992-1002
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
// Reference: check_expr.cpp valid_index_and_score_cmp
valid_index_and_score_cmp :: proc(a, b: Valid_Index_And_Score) -> slice.Ordering {
	if a.score > b.score {
		return .Less // a is better (higher score)
	} else if a.score < b.score {
		return .Greater // b is better
	}
	return .Equal
}

// get_procedure_param_count_excluding_defaults counts required parameters
// Reference: check_expr.cpp:6174-6225
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
// Reference: check_expr.cpp:1005-1034
check_is_assignable_to_with_score :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, score: ^i64 = nil, is_variadic := false, allow_array_programming := true) -> bool {
	if ctx == nil {
		assert(operand.mode == .Value)
	}

	// REMOVED: the "polymorphic procedure as default value" special case.
	//
	// C++ Reference: check_expr.cpp:1026-1036 as it USED to read. It short-circuited to
	// `true` with score 1 for ANY polymorphic procedure assigned to ANY concrete proc type,
	// on the reasoning that "it will be properly instantiated when actually used" -- so the
	// initial check never verified that the polymorphic procedure could instantiate to the
	// target at all. Measured under-rejections it caused, oracle vs port before this edit:
	//     poly(a, b: $T) -> T   as default for proc(x: int) -> int    oracle 1 error, port 0
	//     poly(x: $T) -> T      as default for proc(x, y: int) -> int oracle 1 error, port 0
	//     poly(x: $T)           as default for proc(x: int) -> int    oracle 1 error, port 0
	// Upstream PR #7208 deleted the block and instead records the procedure entity on the
	// parameter value (ParameterValue.proc_entity, entity.cpp:114), so resolution can find it
	// later without weakening the assignability test now. LEDGER #386.

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
// Reference: check_expr.cpp:6228-6241
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
// Reference: check_expr.cpp:6325-6364 (implied)
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
// Reference: check_expr.cpp:6799-6857
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
// Reference: types.cpp:3338-3353
matched_target_features :: proc(pt: ^Type_Proc) -> int {
	if len(pt.require_target_feature) == 0 {
		return 0
	}

	matches := 0

	// C++ (types.cpp matched_target_features) scores on VALIDITY FOR THE TARGET ARCH, not on whether the feature is
	// enabled -- the note that used to stand here claimed this needed target_features_set and was
	// simply wrong about which predicate C++ uses. Two smaller divergences went with it:
	//   - C++ does NOT trim whitespace, so " sse2" is not a valid feature to it. Trimming here made
	//     the port score candidates C++ scores zero.
	//   - C++ BREAKS on the first empty element; the port skipped it and kept going, so "a,,b"
	//     counted b where C++ stops at the empty.
	rest := pt.require_target_feature
	for feature in strings.split_iterator(&rest, ",") {
		if feature == "" {
			break
		}
		valid, _ := check_target_feature_is_valid_for_target_arch(feature)
		if valid {
			matches += 1
		}
	}

	return matches
}

// Split_Args holds the result of splitting call arguments into positional and named
// Reference: check_expr.cpp:7527-7545
Split_Args :: struct {
	positional: []^ast.Node,
	named:      []^ast.Node,
}

// split_call_arguments splits arguments into positional and named slices
// Positional arguments come first, named arguments (Field_Value nodes) come after
// Reference: check_expr.cpp:7527-7545
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

// check_call_parameter_mixture rejects an argument list that mixes `field = value` arguments
// with positional ones. `context_name` names the construct for the message.
//
// C++ Reference: check_expr.cpp:8525-8551.
//
// This procedure previously had no callers at all, cited "check_expr.cpp (implied in argument
// parsing)", and implemented only C++'s `allow_mixed` branch under an invented message
// ("Positional arguments must appear before named arguments in procedure calls"). All four of
// C++'s call sites take the DEFAULT branch - allow_mixed is never passed as true - so the one
// rule that was written is the one C++ never applies here, and the rule C++ always applies was
// missing. Both branches are now present and the default is faithful.
check_call_parameter_mixture :: proc(args: []^ast.Expr, context_name: string, allow_mixed := false) -> bool {
	success := true
	if len(args) == 0 {
		return true
	}

	// A NIL ARGUMENT IS REACHABLE HERE, and dereferencing it is a SEGFAULT the reference shares.
	// parse_atom_expr returns nullptr with no diagnostic when f->allow_type is set
	// (src/parser.cpp:3663-3665) and parse_call_expr appends it unconditionally, so `Foo(..)` in
	// a type position hands this function a one-element slice whose only element is nil.
	// src/check_expr.cpp:8674 then does `args[0]->kind` and dies -- MEASURED: `v: Foo(..)` with
	// `Foo :: struct($T: typeid)` segfaults the reference, thread 3, in
	// check_call_parameter_mixture, and segfaulted the port at the identical line for the
	// identical reason. Filed upstream; a reference QUIRK is the contract but a reference CRASH is
	// not, so the port answers the question the reference was trying to ask: a nil argument is not
	// a `field = value`, which is what its kind test would have concluded had it been able to run.
	is_field_value_arg :: proc(arg: ^ast.Expr) -> bool {
		if arg == nil {
			return false
		}
		_, ok := arg.derived.(^ast.Field_Value)
		return ok
	}

	// C++ lines 8528-8538
	if allow_mixed {
		was_named := false
		for arg in args {
			is_named := is_field_value_arg(arg)
			if was_named && !is_named {
				error_node(arg, "Non-named parameter is not allowed to follow named parameter i.e. 'field = value' in a %s", context_name)
				success = false
				break
			}
			was_named = was_named || is_named
		}
		return success
	}

	// C++ lines 8539-8549
	first_is_field_value := is_field_value_arg(args[0])
	for arg in args {
		is_field_value := is_field_value_arg(arg)
		mix := is_field_value != first_is_field_value
		if mix {
			error_node(arg, "Mixture of 'field = value' and value elements in a %s is not allowed", context_name)
			success = false
		}
	}
	return success
}

// filter_proc_group_by_param_count removes candidates with incompatible parameter counts
// Reference: check_expr.cpp:6998-7019
filter_proc_group_by_param_count :: proc(candidates: ^[dynamic]^Entity, min_arg_count: int, max_arg_count: int) {
	// C++ Reference: check_expr.cpp:7378-7404. C++ walks FORWARD with a manual index and removes
	// with `array_unordered_remove`, which swaps the LAST element into the vacated slot and does
	// not advance the index -- so the surviving order is a PERMUTATION of the original, and that
	// permutation is what the "Did you mean one of the following overloads?" list prints.
	//
	// The port walked in reverse with `ordered_remove`, preserving the original order. Same
	// membership, different sequence, so every overload list whose group had a candidate filtered
	// out printed in a different order from C++ (probe: builtin_arity).
	//
	// C++ also does NOT remove non-procedure entries -- it does `proc_index++; continue;` and
	// keeps them. The port dropped them, which is a second membership divergence.
	for i := 0; i < len(candidates); /**/ {
		entity_proc := candidates[i]
		proc_type := base_type(entity_type(entity_proc))

		if proc_type == nil || proc_type.kind != .Proc {
			i += 1
			continue
		}

		pt := &proc_type.variant.(Type_Proc)

		total_param_count := 0
		required_param_count := get_procedure_param_count_excluding_defaults(proc_type, &total_param_count)

		// Too few arguments for required parameters
		if required_param_count > max_arg_count {
			unordered_remove(candidates, i)
			continue
		}

		// Too many arguments for non-variadic procedure
		if !pt.variadic && max_arg_count != max(int) && total_param_count < max_arg_count {
			unordered_remove(candidates, i)
			continue
		}
		i += 1
	}
}

// check_call_arguments_internal performs the detailed argument checking
// Handles positional arguments, named arguments, variadic parameters, and scoring
// Reference: check_expr.cpp:6095-6638
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

	// THE ARITY CHECK. C++ Reference: check_expr.cpp check_call_arguments_internal, and its POSITION is load-bearing:
	// it runs before the polymorphic instantiation below, exactly as C++ runs it before its own
	// instantiation at check_expr.cpp check_call_arguments_internal.
	//
	// C++ has ONE of these because it scores proc-group candidates through this very function --
	// the same check_call_arguments_internal a direct call uses -- so the single check both sets
	// `err = CallArgumentError_TooManyArguments` (which check_expr.cpp check_call_arguments_internal's
	// `err == CallArgumentError_None` then consults, suppressing instantiation) and emits the
	// diagnostic. The port split that function in two, and this copy had NEITHER half. Two
	// defects followed from the one omission (LEDGER #510):
	//
	//   MODEL POLLUTION. A candidate whose arity the call overshoots was instantiated anyway.
	//   `syscall` in core/sys/linux is a proc GROUP dispatching by arity to syscall1..6, so
	//       ptrace_attach :: proc(rq: PTrace_Attach_Type, pid: Pid) {
	//           syscall(SYS_ptrace, rq, pid, 0, rawptr(nil))    // 5 args
	//       }
	//   inferred syscall1's `$T` from the first TWO arguments of that five-argument call. C++
	//   instantiates syscall1 only for ptrace_traceme, the one wrapper that passes one argument.
	//   Invisible to every text-anchored gate, because the losing candidate is discarded either
	//   way -- only -dump-model shows it.
	//
	//   INVENTED DIAGNOSTIC. With no check here, a single-candidate group fell through to
	//   "Too many arguments to procedure call" further down -- a string that appears NOWHERE in
	//   src/. The oracle names the procedure and gives counts, as below.
	//
	// The variadic arm is C++'s: a variadic procedure has no upper bound to violate, so it is
	// simply excluded rather than clamped here (C++ clamps positional_operand_count for its own
	// later use, which the port does at its own use sites).
	if !pt.variadic && len(positional_operands) > pt.param_count {
		if show_error {
			if ce, ce_ok := call_node.derived.(^ast.Call_Expr); ce_ok {
				proc_str := expr_to_string(ce.expr)
				defer delete(proc_str)
				required := get_procedure_param_count_excluding_defaults(proc_type)
				if required != pt.param_count {
					error_node(call_node, "Too many arguments for '%s', expected %d..=%d arguments, got %d",
						proc_str, required, pt.param_count, len(positional_operands))
				} else {
					error_node(call_node, "Too many arguments for '%s', expected %d arguments, got %d",
						proc_str, pt.param_count, len(positional_operands))
				}
			}
		}
		return false
	}

	// Handle polymorphic procedures by attempting instantiation
	// C++ Reference: check_expr.cpp check_call_arguments_internal -- C++ builds the operand
	// array first and instantiates from it afterwards; the port does both inside this block.
	specialized_proc_type := proc_type
	if pt.is_polymorphic && !pt.is_poly_specialized {
		// C++ Reference: check_expr.cpp check_call_arguments_internal and 6779-6820.
		//
		// The operand array handed to polymorphic instantiation is sized to the PARAMETER count,
		// not the argument count, and a variadic procedure's variadic slot is ALWAYS filled with
		// a synthetic operand. Its TYPE is what decides whether inference can succeed:
		//   variadic args present -> the variadic parameter's own declared type
		//   variadic args absent  -> t_untyped_nil, which `..$E` cannot infer E from, so
		//                            find_or_generate FAILS and this candidate is rejected.
		//
		// That failure IS the mechanism by which `append(&d)` (array, zero values) is rejected.
		// It is NOT an arity rule -- three earlier attempts expressed it as a count check
		// (max(args,param_count); exact param_count; empty slot) and all three had to be reverted.
		//
		// C++ builds the synthetic operand as an `ast_ident("nil")` whose only contribution is a
		// position; Operand.expr here is ^ast.Node, so an existing node carrying the same position
		// serves identically -- call_node when there are no variadic args (C++ uses
		// ast_token(call).pos) and the first variadic argument otherwise.
		//
		// C++'s `dummy_argument_count` is incremented here in C++ (the empty-variadic slot) but
		// NOT here in the port: this block only builds the operand array for instantiation, and
		// the counter lives with the scoring further down. See its declaration below.
		operands: []Operand
		defer delete(operands)
		if pt.params != nil && pt.params.kind == .Tuple {
			ptup := &pt.params.variant.(Type_Tuple)
			pcount := len(ptup.variables)
			ops := make([]Operand, pcount)

			has_variadic_slot := pt.variadic && pt.variadic_index >= 0 && pt.variadic_index < pcount

			positional_count := len(positional_operands)
			if has_variadic_slot {
				positional_count = min(positional_count, pt.variadic_index)
			}
			positional_count = min(positional_count, pcount)
			for i in 0 ..< positional_count {
				ops[i] = positional_operands[i]
			}

			if has_variadic_slot {
				variadic_args := positional_operands[positional_count:]
				o := Operand {
					mode = .Value,
					expr = call_node,
				}
				if len(variadic_args) != 0 {
					o.expr = variadic_args[0].expr
					o.type = ptup.variables[pt.variadic_index].type
				} else {
					o.type = t_untyped_nil
				}
				ops[pt.variadic_index] = o
			}

			// Map NAMED arguments into their parameter slots BEFORE instantiation.
			// C++ Reference: check_expr.cpp:6322-6361 orders named arguments into
			// ordered_operands ahead of the polymorphic arm, so by the time it instantiates,
			// a parameter supplied by name is indistinguishable from one supplied positionally.
			// The port did this ordering only in a LATER block, so the polymorphic arm saw an
			// unwritten operand for every named-only parameter and reported
			//     Cannot determine polymorphic type from parameter: 'invalid type' to '$T'
			// at the DECLARATION. Same wrong-position signature #524 fixed for the zero-argument
			// case. LEDGER #533.
			named_filled := make([]bool, pcount)
			defer delete(named_filled)
			for named_arg, ni in args_split.named {
				if ni >= len(named_operands) {
					break
				}
				fv, fv_ok := named_arg.derived.(^ast.Field_Value)
				if !fv_ok {
					continue
				}
				ident, id_ok := fv.field.derived.(^ast.Ident)
				if !id_ok {
					continue
				}
				param_idx := lookup_procedure_parameter(pt, ident.name)
				// A bad or duplicate name is NOT diagnosed here: the later ordering block owns
				// those two messages, and emitting them from this pass as well would double them.
				if param_idx < 0 || param_idx >= pcount || named_filled[param_idx] {
					continue
				}
				ops[param_idx] = named_operands[ni]
				named_filled[param_idx] = true
			}

			// Fill DEFAULTED parameters that no argument supplied, BEFORE instantiation.
			//
			// C++ Reference: check_expr.cpp check_call_arguments_internal. That loop
			// runs ahead of the instantiation and writes a real operand
			// (Addressing_Value, the parameter's type, the default's original expression) into
			// every unsupplied slot that has a default. The port left those slots ZERO-VALUED --
			// mode .Invalid, type nil -- in BOTH operand builders: this one and the polymorphic
			// arm of check_call_arguments_basic.
			//
			// It was invisible until check_get_params gained C++'s assignability gate
			// (check_type.cpp:2197-2222), whose `#any_int` branch reads `operand.type`:
			// `shrink(&arr)` leaves `#any_int new_cap := -1` unwritten, the gate saw a nil type,
			// failed generation, and the only viable candidate of the `shrink` group was
			// rejected. Corpus member p674sh is the guard. LEDGER #675.
			for i in 0 ..< pcount {
				if i < positional_count {
					continue
				}
				if named_filled[i] {
					continue
				}
				if has_variadic_slot && i == pt.variadic_index {
					continue
				}
				pe := ptup.variables[i]
				if pe == nil {
					continue
				}
				var_e, var_ok := pe.variant.(Entity_Variable)
				if !var_ok || var_e.param_value.kind == .Invalid {
					continue
				}
				// C++ declines the fill when `#+vet explicit-allocators` rejects the default:
				// check_expr.cpp:6846 gates it on `!context_allocator_error`.
				if ctx.file != nil && .Explicit_Allocators in ctx.file.vet_flags &&
				   param_default_is_context_allocator(var_e.param_value.original_ast_expr) {
					continue
				}
				ops[i].mode = .Value
				ops[i].type = entity_type(pe)
				if var_e.param_value.kind == .Nil {
					ops[i].type = t_untyped_nil
				}
				ops[i].expr = var_e.param_value.original_ast_expr
			}

			operands = ops

			// MISSING-REQUIRED gate. C++ Reference: check_expr.cpp check_call_arguments_internal sets
			// `err = CallArgumentError_ParameterMissing`, which check_expr.cpp check_call_arguments_internal's
			// `err == CallArgumentError_None` then consults to suppress instantiation.
			//
			// LEDGER #524, and this is the THIRD gate found on only one side of a function the
			// port split in two. #255 added this check to the DIRECT-CALL path
			// (check_expr.odin:10842); #510 found the too-many-arguments gate present there and
			// absent here and added it; this is the same asymmetry again. C++ has neither problem
			// because proc-group candidates are scored through the very same
			// check_call_arguments_internal a direct call uses -- one function, one gate.
			//
			// Without it, `gp()` on a polymorphic group instantiated with an UNWRITTEN operand:
			// mode .Invalid, type nil, expr nil. That reached determine_type_from_polymorphic,
			// whose guard printed
			//     Cannot determine polymorphic type from parameter: 'invalid type' to '$T'
			// at the DECLARATION's position, because operand.expr was nil and there was no call
			// site to point at. The oracle names the parameter and reports at the call.
			//
			// RESTRICTED TO len(named_operands) == 0, deliberately. C++ runs this check AFTER
			// ordering named arguments into ordered_operands, so it knows which parameters a name
			// supplies. This path does not: named arguments are mapped to parameter indices later
			// (the `len(named_operands) > 0` block below), so at this point a parameter supplied
			// only by name is indistinguishable from one not supplied at all, and gating on it
			// would report a missing parameter that was in fact provided. The subset covered here
			// is exactly the one where the answer is unambiguous, and on it the behaviour is
			// C++'s. The named-argument case is left as it was -- not made worse, not yet fixed;
			// see #524's residual note.
			{
				for i in 0 ..< pcount {
					if i < positional_count {
						continue // supplied positionally
					}
					if named_filled[i] {
						continue // supplied by name -- now knowable, see above
					}
					if has_variadic_slot && i == pt.variadic_index {
						continue // a variadic slot with no arguments is legitimately empty
					}
					pe := ptup.variables[i]
					if pe == nil {
						continue
					}
					// A parameter with a default value is not missing.
					if var_e, var_ok := pe.variant.(Entity_Variable); var_ok {
						if var_e.param_value.kind != .Invalid {
							continue
						}
					}
					// C++ has three arms here (type parameter / an already-valued constant, which
					// it ignores / the general case). Only the general one is ported: the other
					// two need a repro before they are written, and #266 is the standing lesson
					// about implementing branches that no input reaches.
					if show_error {
						type_str := type_to_string(pe.type)
						defer delete(type_str)
						error_node(call_node, "Parameter '%s' of type '%s' is missing in procedure call",
							pe.token.text, type_str)
					}
					return false
				}
			}
		} else {
			ops := make([]Operand, len(positional_operands))
			copy(ops, positional_operands)
			operands = ops
		}

		// Try to instantiate the polymorphic procedure
		poly_data := Poly_Proc_Data{}
		ctx_copy := ctx^
		// #1108 (B2-i i5). C++ Reference: check_expr.cpp check_call_arguments — `in_proc_group` is
		// set true ONLY around the SILENT candidate-scoring loop and cleared BEFORE the winner is
		// re-checked:
		//
		//     c->in_proc_group = true;
		//     for_array(i, procs) { ... CallArgumentErrorMode::NoErrors ... }
		//     c->in_proc_group = false;
		//
		// Its sole reader is check_type.cpp's polymorphic-name-parameter check (ported at
		// check_type.odin):
		//     if (!ctx->in_proc_group) {
		//         error(op.expr, "Expected a constant value for this polymorphic name parameter,
		//                         got %s", ...);
		//     }
		//     success = false;
		//
		// The port set the flag unconditionally, INSIDE check_call_arguments_internal — which runs
		// for EVERY error mode, the reporting pass included. So that diagnostic could never print,
		// and `success = false` still failed the call: A SILENT HARD ERROR.
		// MEASURED: `fp :: proc($N: int); g :: proc{fp}; x := 3; g(x)`
		//     oracle: exit 1, "Expected a constant value for this polymorphic name parameter, got x"
		//     port:   exit 0, ZERO diagnostics — it ACCEPTED the call outright.
		//
		// `!show_error` is exactly C++'s scoping: NoErrors (speculative scoring) -> true,
		// Show_Errors (the winner re-check, and the single-candidate path) -> false.
		ctx_copy.in_proc_group = !show_error
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

	// C++ Reference: check_expr.cpp check_call_arguments_internal -- `dummy_argument_count`,
	// incremented at the empty-variadic slot and once per parameter filled from its default
	// value, then spent at the two `score -= dummy_argument_count * (...)` sites.
	//
	// THIS COMMENT USED TO SAY the counter was "written twice and never read anywhere in that
	// file" and therefore deliberately not ported. That was true when it was written and is not
	// true now: merge a64cb7bfd (PR #7227) added both readers. A documented divergence is only
	// as good as its stated reason, so it goes when the reason does.
	//
	// What the counter buys, in C++'s own words: "A synthesised default argument is not evidence
	// of a better match: it contributes assign_score_function(1) as a dummy bonus and is then
	// scored again as a perfect-match argument. Discount both, plus 1 to break the resulting tie,
	// so an exact-arity overload wins."
	//
	// So the two dummies are NOT symmetric, and the arithmetic is worth writing down:
	//   default-filled parameter -- adds asf(1) at fill time and asf(0) when the synthesised
	//     operand is scored, then gives back asf(0)+asf(1)+1. Net -1: a hair's-breadth penalty
	//     that only decides otherwise-exact ties.
	//   empty variadic slot -- adds NOTHING (C++'s scoring loop `continue`s on the variadic
	//     parameter, and the variadic_operands loop has nothing to iterate), then gives back the
	//     same asf(0)+asf(1)+1 = 602. Net -602: a real penalty, roughly two perfect arguments.
	// Porting only the subtraction would have made both of those wrong in the same direction, and
	// silently -- which is why the fill and the bonus below are ported alongside it.
	dummy_argument_count: i64 = 0
	dummy_argument_penalty :: #force_inline proc() -> i64 {
		return assign_score_function(0) + assign_score_function(1) + 1
	}

	// Handle named arguments by creating ordered operand array
	// Reference: check_expr.cpp:6291-6364
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
		// Reference: check_expr.cpp check_call_arguments_proc_group
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

		// Synthesise an operand for every parameter left unfilled that carries a default value,
		// so the scoring loop below scores it like any other argument.
		// C++ Reference: check_expr.cpp check_call_arguments_internal, the
		// `for (isize i = 0; i < pt->param_count; i++) { if (!visited[i]) ... }` loop.
		//
		// #1110 (B2-i i3): THE COMMENT THAT STOOD HERE WAS FACTUALLY WRONG. It read:
		//     "C++'s `-vet explicit-allocators` arm inside that loop is NOT ported here, and its
		//      absence is deliberate rather than an omission: C++ gates it on
		//      `!checking_proc_group`, and every path through this file is a proc-group candidate."
		// The second clause is false. check_call_arguments_single is invoked from THREE sites in
		// this very file with checking_proc_group = FALSE (the single-candidate path, the
		// single-valid path, and the winner re-check); only the speculative scoring loop passes
		// true. So the C++ arm is reachable here, and its absence was an omission.
		//
		// C++ Reference: check_expr.cpp check_call_arguments_internal:
		//     bool context_allocator_error = false;
		//     if (ast_file_vet_explicit_allocators(c->file) && !checking_proc_group) {
		//         ... if the default is context.allocator / context.temp_allocator ...
		//         context_allocator_error = true;
		//     }
		//     if (!context_allocator_error) { ...fill the default...; continue; }
		//     ... if (show_error) { if (context_allocator_error) {
		//         error(call, "Parameter '%.*s' of type '%s' must be explicitly provided in "
		//                     "procedure call", ...); } ... }
		//     err = CallArgumentError_ParameterMissing;
		//
		// So under the vet flag the default is NOT filled and a distinct diagnostic is raised.
		// MEASURED: `#+vet explicit-allocators` with `fa :: proc(n: int, allocator := context.allocator)`
		// called through a group as `g(1)` — oracle 1, port 0.
		for i in 0 ..< len(ordered_operands) {
			if visited[i] {
				continue
			}
			e := params.variables[i]
			if e == nil || e.kind != .Variable {
				continue
			}
			var_e := &e.variant.(Entity_Variable)
			if var_e.param_value.kind == .Invalid {
				continue
			}

			// See the #1110 note above. The gate is the vet flag AND !checking_proc_group, exactly
			// as C++ spells it: a SPECULATIVE candidate scoring pass must not raise this.
			context_allocator_error := false
			if ctx.file != nil && .Explicit_Allocators in ctx.file.vet_flags && !checking_proc_group {
				if param_default_is_context_allocator(var_e.param_value.original_ast_expr) {
					context_allocator_error = true
				}
			}
			if context_allocator_error {
				if show_error {
					type_str := type_to_string(entity_type(e))
					error_node(call_node, "Parameter '%s' of type '%s' must be explicitly provided in procedure call", e.token.text, type_str)
				}
				data.error = true
				// NO FILL — C++ skips the default entirely on this path, leaving visited[i] false.
				continue
			}

			o := Operand {
				mode = .Value,
				type = entity_type(e),
				expr = var_e.param_value.original_ast_expr,
			}
			if var_e.param_value.kind == .Nil {
				o.type = t_untyped_nil
			}
			ordered_operands[i] = o
			visited[i] = true
			total_score += assign_score_function(1)
			dummy_argument_count += 1
		}
		// An empty variadic slot is a dummy too. C++ fills it with a `nil` ident of type
		// t_untyped_nil, which its scoring loop then skips (`param_is_variadic` -> continue), so
		// the slot contributes nothing but is still counted -- hence the full 602 penalty rather
		// than the default's net 1.
		if pt.variadic && pt.variadic_index >= 0 && int(pt.variadic_index) < len(visited) && !visited[pt.variadic_index] {
			dummy_argument_count += 1
		}

		// C++ Reference: check_expr.cpp check_call_arguments_internal. C++'s `err` is a value the scoring loop SETS and
		// keeps going with, not a bail. Mirrored here so a mis-typed argument no longer hides a
		// separate missing-parameter error reported after the loop.
		had_wrong_types := false

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

			// Routed through the single ported lambda (LEDGER #534).
			is_variadic_param := i == pt.variadic_index
			arg_err := false
			arg_score := eval_param_and_score(ctx, &operand, param_type, &arg_err, is_variadic_param, param, show_error)
			if arg_err {
				had_wrong_types = true
			}
			total_score += arg_score
		}

		missing_ok := report_missing_parameters(pt, params, visited[:], call_node, show_error)
		if !missing_ok || had_wrong_types {
			return false
		}

		total_score -= dummy_argument_count * dummy_argument_penalty()

		data.result_type = pt.results
		data.final_proc_type = specialized_proc_type
		data.score = int(total_score)
		return true
	}

	// Fall through to existing positional-only logic
	// See the named-argument site above: C++ SETS an error and continues scoring (#526).
	had_wrong_types := false

	// #1109 (B2-i i2). C++ Reference: check_expr.cpp check_call_arguments_internal:
	//
	//     bool vari_expand = (ce->ellipsis.pos.line != 0);
	//     ...
	//     if (vari_expand && !variadic) {
	//         error(ce->ellipsis, "Cannot use '..' in call to a non-variadic procedure: '%.*s'", ...);
	//         err = CallArgumentError_NonVariadicExpand;
	//     }
	//
	// The PORT'S DIRECT-CALL PATH already does this (check_expr.odin) and is correct there — which
	// is why a direct `nv(..s)` matches the oracle. THE GROUP PATH NEVER READ call.ellipsis AT
	// ALL, so `g(..s)` on a non-variadic group member was accepted silently.
	// MEASURED: `nv :: proc(x: []int); g :: proc{nv}; g(..s)` — oracle 1, port 0.
	//
	// C++ RECORDS AND CONTINUES (err = ...; no return), so the argument mismatch is still reported
	// afterwards; the direct path's #962 note makes the same point. Same shape here.
	// call_node is a ^ast.Node here, not a ^ast.Call_Expr — this procedure takes the generic node.
	vari_expand := false
	call_ce, call_is_ce := call_node.derived.(^ast.Call_Expr)
	if call_is_ce {
		vari_expand = call_ce.ellipsis.kind != .Invalid
	}
	if vari_expand && !pt.variadic {
		callee_name: string
		owned := false
		if id, is_id := call_ce.expr.derived.(^ast.Ident); is_id {
			callee_name = id.name
		} else {
			callee_name = expr_to_string(call_ce.expr)
			owned = true
		}
		defer if owned { delete(callee_name) }
		if show_error {
			error(call_ce.ellipsis.pos, "Cannot use '..' in call to a non-variadic procedure: '%s'", callee_name)
		}
		data.error = true
	}

	// THE AMBIGUOUS-POLYMORPHIC-VARIADIC GATE. C++ Reference: src/check_expr.cpp:7074-7086.
	//
	//     if (variadic) {
	//         Entity *var_entity = pt->params->Tuple.variables[pt->variadic_index];
	//         Type *slice = var_entity->type;
	//         Type *elem = base_type(slice)->Slice.elem;
	//         if (is_type_polymorphic(elem)) {
	//             if (show_error) {
	//                 error(call, "Ambiguous call to a polymorphic variadic procedure with no variadic input %s", type_to_string(final_proc_type));
	//             }
	//             err = CallArgumentError_AmbiguousPolymorphicVariadic;
	//         }
	//
	// The twin of the block in check_expr.odin's check_call_arguments_basic. Both are needed:
	// the port carries TWO transcriptions of C++'s single check_call_arguments_internal, and a
	// proc GROUP whose members include a polymorphic variadic reaches only this one. That is not
	// an inference -- cell k_procgroup passed through the other copy's fix silently and only
	// closed once this was added, which is exactly what it was written to discriminate.
	//
	// See the companion comment in check_expr.odin for why the message's "with no variadic
	// input" does not mean the slot is empty. LEDGER #1244.
	if pt.variadic && pt.variadic_index >= 0 && pt.params != nil {
		if vparams, vok := pt.params.variant.(Type_Tuple);
		   vok && int(pt.variadic_index) < len(vparams.variables) {
			vslice := base_type(entity_type(vparams.variables[pt.variadic_index]))
			if vslice != nil {
				if vs, vs_ok := vslice.variant.(Type_Slice); vs_ok && is_type_polymorphic(vs.elem) {
					if show_error {
						error_node(call_node, "Ambiguous call to a polymorphic variadic procedure with no variadic input %s", type_to_string(specialized_proc_type))
					}
					data.error = true
				}
			}
		}
	}

	// Match positional arguments
	for &operand, i in positional_operands {
		// Index of the parameter this argument binds to. Everything at or past the
		// variadic index binds to the variadic parameter, so the index saturates there
		// rather than running off the end.
		//
		// C++ Reference: check_expr.cpp check_call_arguments_internal and its variadic_operands
		// loop — arguments in the variadic slot are scored one by one against the
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

		// C++ Reference: check_expr.cpp check_call_arguments_internal -- an INVALID operand is skipped, not
		// scored:
		//     Operand *o = &ordered_operands[i];
		//     if (o->mode == Addressing_Invalid) {
		//         continue;
		//     }
		//
		// C++ has ONE scoring loop. The port split it in two -- an ordered_operands path
		// taken only when `len(named_operands) > 0`, and this positional-only path -- and
		// the guard was ported into the FIRST one only. So a call with no named arguments
		// dropped an already-errored argument into check_is_assignable_to_with_score, which
		// returns false for an invalid operand (matching C++), and the candidate was
		// rejected.
		//
		// The consequence is not a missing diagnostic but the WRONG one, and it only shows
		// up on already-broken code: with every candidate rejected, valids.count is 0, so
		// the group reports "No procedures or ambiguous call ..." where C++ -- having kept
		// all of them -- reports "Ambiguous procedure group call ...". Measured on probe
		// pgbad (a failed `#load` passed to a two-member group).
		//
		// Skipping is what makes the cascade quiet: the argument's own error was already
		// reported at the point it went invalid, so re-judging it here can only add noise.
		if operand.mode == .Invalid {
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
			// #1109 (B2-i i1). C++ Reference: check_expr.cpp check_call_arguments_internal scores
			// every variadic operand against the ELEMENT type, and substitutes the SLICE type
			// ONLY under vari_expand:
			//
			//     Type *elem = base_type(slice)->Slice.elem;
			//     Type *t = elem;
			//     for_array(operand_index, variadic_operands) {
			//         if (vari_expand) { t = slice; ... }
			//         score += eval_param_and_score(c, o, t, err, true, var_entity, show_error);
			//     }
			//
			// The port had an UNCONDITIONAL "if the argument is assignable to the whole slice,
			// take it" fast path with a FABRICATED score. That accepted a bare slice passed to a
			// variadic parameter — no `..` in sight — which the reference rejects:
			//     fv :: proc(xs: ..int); g :: proc{fv}; s := []int{1,2}; g(s)
			//         oracle: "Cannot assign value 's' of type '[]int' to 'int' in a procedure
			//                  argument"
			//         port:   accepted.
			//
			// It could not simply be deleted: it is ALSO what made the legitimate `g(..s)` work on
			// this path, since the group path has no vari_expand handling of its own. Gating it on
			// the ellipsis is what separates the two spellings — which is exactly C++'s condition.
			// The score is left as-is; correcting it to the real conversion distance is a separate
			// question from which spellings are legal.
			if vari_expand && check_is_assignable_to(ctx, &operand, param_type) {
				total_score += assign_score_function(1, true)
				continue
			}
			if slice_type := base_type(param_type); slice_type != nil && slice_type.kind == .Slice {
				effective_type = slice_type.variant.(Type_Slice).elem
			}
		}

		// Routed through the single ported lambda (LEDGER #534). `effective_type` rather than
		// param_type: the variadic element-type substitution above (#120) is this path's own and
		// is preserved.
		arg_err := false
		arg_score = eval_param_and_score(ctx, &operand, effective_type, &arg_err, is_variadic_param, param, show_error)
		if arg_err {
			had_wrong_types = true
		}
		total_score += arg_score
	}

	// The default-value fill, positional twin of the block in the named path above. This path has
	// no ordered_operands array to write into, so the synthesised operand is scored on the spot;
	// the score it produces is identical either way, because C++'s scoring loop would have reached
	// it with exactly this (type, expr) pair.
	{
		first_unfilled := min(len(positional_operands), len(params.variables))
		for i in first_unfilled ..< len(params.variables) {
			if pt.variadic && i == int(pt.variadic_index) {
				continue
			}
			e := params.variables[i]
			if e == nil || e.kind != .Variable {
				continue
			}
			var_e := &e.variant.(Entity_Variable)
			if var_e.param_value.kind == .Invalid {
				continue
			}

			// #1110, SECOND SITE. The port has TWO default-fill implementations — the named-path
			// loop above and this positional twin — and THIS is the one a plain `g(1)` reaches.
			// I patched the named one first and the witness stayed silent; a behavioural probe
			// (replacing the whole gate with `if true`) still produced nothing, which proved the
			// loop was never reached rather than the gate being wrong. Same condition as C++:
			// the vet flag AND !checking_proc_group.
			context_allocator_error := false
			if ctx.file != nil && .Explicit_Allocators in ctx.file.vet_flags && !checking_proc_group {
				if param_default_is_context_allocator(var_e.param_value.original_ast_expr) {
					context_allocator_error = true
				}
			}
			if context_allocator_error {
				if show_error {
					ca_type_str := type_to_string(entity_type(e))
					error_node(call_node, "Parameter '%s' of type '%s' must be explicitly provided in procedure call", e.token.text, ca_type_str)
				}
				data.error = true
				continue
			}

			param_type := entity_type(e)
			o := Operand {
				mode = .Value,
				type = param_type,
				expr = var_e.param_value.original_ast_expr,
			}
			if var_e.param_value.kind == .Nil {
				o.type = t_untyped_nil
			}
			total_score += assign_score_function(1)
			dummy_argument_count += 1
			arg_err := false
			total_score += eval_param_and_score(ctx, &o, param_type, &arg_err, false, e, show_error)
			if arg_err {
				had_wrong_types = true
			}
		}
		// The empty variadic slot. `len(positional_operands) <= variadic_index` is exactly
		// C++'s `!visited[variadic_index] && variadic_operands.count == 0`: the variadic
		// parameter is always last, so no argument reached it. It also excludes `xs..`, which
		// cannot occur with zero variadic arguments.
		if pt.variadic && pt.variadic_index >= 0 && len(positional_operands) <= int(pt.variadic_index) {
			dummy_argument_count += 1
		}
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

	if had_wrong_types {
		return false
	}

	total_score -= dummy_argument_count * dummy_argument_penalty()

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
// C++ Reference: check_expr.cpp check_call_arguments_internal,
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
		// C++ Reference: check_expr.cpp:6835-6844. C++ does NOT skip these wholesale: a
		// missing type parameter gets its own message, and a constant parameter is ignored
		// only when it actually carries a value. The port skipped both unconditionally, so a
		// call missing a type parameter reported nothing at all.
		if e.kind == .Constant {
			if c, is_const := e.variant.(Entity_Constant); is_const && c.value != nil {
				continue
			}
		}
		// A default value stands in for the missing argument
		if v, is_var := e.variant.(Entity_Variable); is_var {
			if v.param_value.kind != .Invalid {
				continue
			}
		}

		if show_error {
			// C++ Reference: check_expr.cpp:6835-6845. The port's wording was invented:
			// C++ names the parameter's TYPE as well, and distinguishes type parameters.
			if e.kind == .Type_Name {
				error_node(call_node, "Type parameter '%s' is missing in procedure call", e.token.text)
			} else {
				type_str := type_to_string(entity_type(e))
				error_node(call_node, "Parameter '%s' of type '%s' is missing in procedure call", e.token.text, type_str)
			}
		}
		ok = false
	}
	return ok
}

// check_call_arguments_single checks a single procedure candidate
// Reference: check_expr.cpp check_call_arguments_internal
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

	// C++ Reference: check_expr.cpp:7249-7253 and 7274-7279. Four divergences fixed here.
	//
	// (1) C++ unwraps SelectorExpr to the SELECTOR before recording the use:
	//       while (ident->kind == Ast_SelectorExpr) ident = ident->SelectorExpr.selector;
	//     so `pkg.foo(...)` records against `foo`, not against the whole `pkg.foo`.
	// (2) C++ uses `entity_to_use = data->gen_entity ? data->gen_entity : e` -- for a
	//     polymorphic call the INSTANTIATED entity, not the generic one.
	// (3) C++ calls update_untyped_expr_type with entity_to_use->type; the port omitted it.
	// (4) add_type_and_value takes entity_to_use->TYPE, not the operand's.
	ident := operand.expr
	for ident != nil {
		// NOTE: the port names this field `field`, not `selector` as C++ does.
		se, se_ok := ident.derived.(^ast.Selector_Expr)
		if !se_ok || se.field == nil {
			break
		}
		ident = se.field
	}

	entity_to_use := entity
	if data.gen_entity != nil {
		entity_to_use = data.gen_entity
	}

	if ok && !return_on_failure && entity_to_use != nil {
		add_entity_use(ctx, ident, entity_to_use)
		if operand.expr != nil && entity_to_use.type != nil {
			update_untyped_expr_type(ctx, operand.expr, entity_to_use.type, true)
			add_type_and_value(ctx, operand.expr, operand.mode, entity_to_use.type, operand.value)
		}
	}

	// C++ Reference: check_expr.cpp check_call_arguments_single
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
				// LEDGER #886. ATOMIC, because C++ declares this field `std::atomic<bool>`
			// (checker.hpp:228) and the port flattened it to a plain `bool`
			// (ast/semantic_types.odin). C++ reads it with `.load(std::memory_order_relaxed)`
			// (check_decl.cpp:2227) and writes it with a plain `= true` on the atomic, i.e. a
			// seq_cst store (check_expr.cpp:7371).
			//
			// NOT a systemic gap: C++'s Decl_Info has FOUR atomics, the port declares all four as
			// plain fields, and it already compensates at the access sites for `proc_checked_state`
			// (8 of 13 sites use sync.atomic_*, plus proc_checked_mutex). This field had ZERO
			// compensated accesses, so two checker threads could both read `false`, both evaluate
			// the `where` clause with print_err set, and both render.
				sync.atomic_store(&decl.where_clauses_evaluated, true)
				// C++ Reference: check_expr.cpp check_call_arguments_single. The generated entity's RESULTS
				// become the call's result type; the port never set this, so a polymorphic
				// call's result came from whatever the generic signature said.
				if is_type_proc(gen.type) {
					if pt, pt_ok := base_type(entity_to_use.type).variant.(Type_Proc); pt_ok {
						data.result_type = pt.results
					}
				}
			}
		}
	}

	return ok
}

// print_call_argument_types renders C++'s "Given argument types:" block.
//
// C++ Reference: check_expr.cpp:7666-7689 (the `print_argument_types` lambda inside
// check_call_arguments_proc_group).
//
// This used to carry an `i := 0` that was never incremented, mirroring a C++ lambda that
// declared `isize i = 0` and never advanced it -- so every named argument was labelled with
// the FIRST named field's name. That was correct parity at the time and was filed as #156.
// Upstream has since rewritten the lambda: the buggy version survives only as a comment
// block at check_expr.cpp:7636-7664, and the live one iterates with `for_array(i, ...)`,
// so the index now tracks the operand. The port follows. LEDGER #385.
print_call_argument_types :: proc(positional_operands: []Operand, named_operands: []Operand, args_split: Split_Args) {
	error_line("\tGiven argument types:\n")
	for o in positional_operands {
		error_line("\t • %s\n", type_to_string(o.type))
	}
	for o, i in named_operands {
		type_str := type_to_string(o.type)
		labelled := false
		if i < len(args_split.named) {
			if fv, ok := args_split.named[i].derived.(^ast.Field_Value); ok {
				field := expr_to_string(fv.field)
				error_line("\t • %s = %s\n", field, type_str)
				delete(field)
				labelled = true
			}
		}
		if !labelled {
			error_line("\t • %s\n", type_str)
		}
	}
}

// proc_display_type_string renders a procedure entity's type the way C++ does: from the
// declaration's own AST when it has one, otherwise the canonical type string.
// The second result reports whether the caller must free it - expr_to_string allocates,
// type_to_string does not.
// C++ Reference: check_expr.cpp:7770-7774, 7876-7880, 7949-7953.
proc_display_type_string :: proc(t: ^Type) -> (string, bool) {
	pt := &t.variant.(Type_Proc)
	if pt.node != nil {
		return expr_to_string(pt.node), true
	}
	return type_to_string(t), false
}

@(private = "file")
overload_is_ignored :: proc(possibly_ignore: []bool, possibly_ignore_set: int, i: int) -> bool {
	return possibly_ignore_set != 0 && possibly_ignore[i]
}

// print_procedure_group_overloads renders the padded "Did you mean one of the following
// overloads?" table, preceded by C++'s address-of Suggestion block when one applies.
//
// C++ Reference: check_expr.cpp:7686-7906. The port previously emitted none of this: a
// failed procedure-group call named no candidates at all, so the user was told the call
// did not match without being shown what it could have matched.
print_procedure_group_overloads :: proc(
	ctx: ^Checker_Context,
	procs: []^Entity,
	positional_operands: []Operand,
	named_operands: []Operand,
	args_split: Split_Args,
	expr_name: string,
) {
	if len(procs) == 0 {
		return
	}

	// Try to reduce the list further for `$T: typeid` like parameters.
	// NOTE(bill): This currently only checks for #soa types.
	// C++ Reference: check_expr.cpp:7692-7747.
	possibly_ignore := make([]bool, len(procs), context.temp_allocator)
	possibly_ignore_set := 0
	for p, i in procs {
		t := base_type(entity_type(p))
		if t == nil || t.kind != .Proc {
			continue
		}
		pt := &t.variant.(Type_Proc)
		if pt.param_count == 0 || pt.params == nil || pt.params.kind != .Tuple {
			continue
		}
		for v, j in pt.params.variant.(Type_Tuple).variables {
			if v == nil || v.kind != .Type_Name {
				continue
			}
			dst_t := base_type(entity_type(v))
			for dst_t != nil && dst_t.kind == .Generic {
				spec := dst_t.variant.(Type_Generic).specialized
				if spec == nil {
					break
				}
				dst_t = spec
			}
			if j >= len(positional_operands) {
				continue
			}
			o := positional_operands[j]
			if o.mode != .Type {
				continue
			}
			ot := base_type(o.type)
			if ot != nil && dst_t != nil && ot.kind == dst_t.kind {
				continue
			}
			st := base_type(type_deref(o.type))
			dt := base_type(type_deref(dst_t))
			if st != nil && dt != nil && st.kind == dt.kind {
				continue
			}
			if is_type_soa_struct(st) {
				possibly_ignore[i] = true
				possibly_ignore_set += 1
				continue
			}
		}
	}
	if possibly_ignore_set == len(procs) {
		possibly_ignore_set = 0
	}

	// Column widths, so the `::` and `at` columns line up.
	// C++ Reference: check_expr.cpp:7750-7785.
	max_name_length := 0
	max_type_length := 0
	for p, i in procs {
		if overload_is_ignored(possibly_ignore, possibly_ignore_set, i) {
			continue
		}
		t := base_type(entity_type(p))
		if t == nil || t == t_invalid || t.kind != .Proc {
			continue
		}
		name_len := len(p.token.text)
		if p.pkg != nil {
			name_len += len(p.pkg.name) + 1
		}
		max_name_length = max(max_name_length, name_len)

		pt, allocated := proc_display_type_string(t)
		max_type_length = max(max_type_length, len(pt))
		if allocated {
			delete(pt)
		}
	}
	max_spaces := max(max_name_length, max_type_length)
	spaces := make([]u8, max_spaces, context.temp_allocator)
	for &c in spaces {
		c = ' '
	}
	spaces_str := string(spaces)

	// C++ walks the candidates once looking for a parameter that would have matched had
	// the argument been passed by pointer, and if so prints the whole call back with an
	// `&` inserted. C++ Reference: check_expr.cpp:7788-7855.
	try_addr := false
	try_addr_idx := -1
	for p, i in procs {
		if overload_is_ignored(possibly_ignore, possibly_ignore_set, i) {
			continue
		}
		t := base_type(entity_type(p))
		if t == nil || t == t_invalid || t.kind != .Proc {
			continue
		}
		pt := &t.variant.(Type_Proc)
		if pt.params == nil || pt.params.kind != .Tuple {
			continue
		}
		vars := pt.params.variant.(Type_Tuple).variables
		n := min(len(vars), len(positional_operands))
		for k in 0 ..< n {
			dst := entity_type(vars[k])
			src := positional_operands[k]
			if check_is_assignable_to(ctx, &src, dst) {
				// okay
			} else if check_is_assignable_to(ctx, &src, type_deref(dst)) {
				try_addr = true
				if try_addr_idx < 0 {
					try_addr_idx = k
				}
			}
		}
	}

	if try_addr {
		error_line("  \n")
		error_line("\tSuggestion:\n")
		error_line("\t\t%s(", expr_name)
		i := 0
		for o in positional_operands {
			if i > 0 {
				error_line(", ")
			}
			i += 1
			expr := expr_to_string(o.expr)
			if i - 1 == try_addr_idx {
				error_line("&")
			}
			error_line("%s", expr)
			delete(expr)
		}
		// C++ walks this loop with its OWN index (`for_array(named_idx, named_operands)`,
		// check_expr.cpp:7847) and uses the shared `i` only to decide the comma. The port used
		// to index args_split.named with `i`, which was parity with the pre-fix C++ and is now
		// stale -- same #156 rewrite that retired the never-incremented counter above.
		// LEDGER #385.
		for o, named_idx in named_operands {
			if i > 0 {
				error_line(", ")
			}
			i += 1
			expr := expr_to_string(o.expr)
			labelled := false
			if named_idx < len(args_split.named) {
				if fv, ok := args_split.named[named_idx].derived.(^ast.Field_Value); ok {
					field := expr_to_string(fv.field)
					error_line("%s = %s", field, expr)
					delete(field)
					labelled = true
				}
			}
			if !labelled {
				error_line("%s", expr)
			}
			delete(expr)
		}
		error_line(")\n")
		// Extra spaces, to stop the error machinery consuming the newline.
		error_line("  \n")
	}

	error_line("Did you mean one of the following overloads?\n")
	for p, i in procs {
		if overload_is_ignored(possibly_ignore, possibly_ignore_set, i) {
			continue
		}
		t := base_type(entity_type(p))
		if t == nil || t == t_invalid || t.kind != .Proc {
			continue
		}
		pt, allocated := proc_display_type_string(t)
		defer if allocated {
			delete(pt)
		}

		prefix := ""
		prefix_sep := ""
		if p.pkg != nil {
			prefix = p.pkg.name
			prefix_sep = "."
		}
		name := p.token.text
		name_len := len(prefix) + len(prefix_sep) + len(name)

		name_padding := max(max_name_length - name_len, 0)
		type_padding := max(max_type_length - len(pt), 0)

		sep := "::"
		if p.kind == .Variable {
			sep = ":="
		}
		error_line(
			"\t%s%s%s %s%s %s %sat %s\n",
			prefix,
			prefix_sep,
			name,
			spaces_str[:name_padding],
			sep,
			pt,
			spaces_str[:type_padding],
			token_pos_to_string(p.token.pos),
		)
	}
	error_line("\n")
}

// check_procedure_group_call resolves overloaded procedure calls
// This is the main entry point for procedure group resolution
// Reference: check_expr.cpp:6933-7504
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
	// C++ Reference: check_expr.cpp:6880-6920
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
	// Reference: check_expr.cpp:6969-6988
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

		// If all candidates were filtered out, restore the original list so the diagnostics
		// downstream have something to name.
		//
		// LEDGER #522: these two statements were in the WRONG ORDER and the branch was a
		// guaranteed panic. `copy(procs[:len(procs_slice)], ...)` slices `procs` to
		// len(procs_slice) while `procs` is EMPTY -- that is the condition guarding the branch --
		// so it aborted the checker with "Invalid slice indices 0:1 is out of range 0..<0". The
		// resize that makes room ran on the next line, after the copy that needed it.
		//
		// REPRO, and it is ordinary code rather than a corner case:
		//     vari :: proc(a: int, rest: ..int) {}
		//     gv   :: proc{vari}
		//     gv(1, 2, 3, x = 4)          // named argument naming no parameter
		// The oracle reports "No parameter named 'x' for this procedure type"; the port died.
		// Every candidate is filtered out (none has a parameter `x`), which is exactly the
		// state this branch exists to recover from -- so the recovery path could never run.
		//
		// The neighbouring citation to check_expr.cpp:6990-6995 is DRIFTED: those lines are the
		// polymorphic-variadic arm, not this restore. Left uncited rather than given a
		// plausible-looking wrong line number.
		if len(procs) == 0 {
			resize(&procs, len(procs_slice))
			copy(procs[:len(procs_slice)], procs_slice)
		}
	}

	// Filter candidates by parameter count
	if len(procs) > 1 {
		filter_proc_group_by_param_count(&procs, min_arg_count, max_arg_count)
	}

	// If only one candidate remains, check it directly
	// Reference: check_expr.cpp:7030-7048
	if len(procs) == 1 {
		entity := procs[0]
		proc_type := base_type(entity_type(entity))

		// Split arguments before checking
		// Reference: check_expr.cpp:7527-7545
		args_split := split_call_arguments(call)
		defer delete(args_split.positional)
		defer delete(args_split.named)

		// Check positional arguments, unpacking any multi-valued expression and
		// hinting each argument with the sole candidate's matching parameter type.
		//
		// C++ Reference: check_expr.cpp check_call_arguments_proc_group,
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
		// Reference: check_expr.cpp:7041
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
	// Reference: check_expr.cpp:7527-7545
	args_split := split_call_arguments(call)
	defer delete(args_split.positional)
	defer delete(args_split.named)

	// Check positional arguments, unpacking any multi-valued expression.
	//
	// C++ Reference: check_expr.cpp check_call_arguments_proc_group,
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
	// #626: `lhs` and `variadic_index` are declared at PROCEDURE scope, not inside the positional
	// block, because C++ uses the same `lhs` for BOTH the positional unpack and the named-argument
	// type hint (check_expr.cpp, two sites). The port had them block-scoped, so the named
	// loop below had nothing to derive a hint from and passed nil -- a live over-rejection.
	lhs: []^Entity = nil
	variadic_index := -1
	{

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

	// Check named arguments.
	// C++ Reference: check_expr.cpp check_call_arguments_proc_group.
	//
	// #626. The previous version of this loop did ONE of the four things C++ does here: it checked
	// fv.value with a nil type hint. The three it omitted were the two shape diagnostics and, most
	// consequentially, the TYPE HINT -- C++ looks the named key up among the parameter entities and
	// passes that parameter's type into the value check. Without it, any named argument whose value
	// needs a hint to resolve is rejected outright. Measured: `pg(1, c = .Green)` for a proc group
	// whose candidates both take `c: Color` is accepted by the oracle and was rejected by the port
	// with "Cannot determine type for implicit selector expression '.Green'". That is an
	// OVER-REJECTION of valid code, and it is #72's class re-appearing on the one path #72 did not
	// cover.
	named_operands := make([dynamic]Operand)
	defer delete(named_operands)

	for arg in args_split.named {
		// C++ Reference: check_expr.cpp:7550-7553.
		fv, fv_ok := arg.derived.(^ast.Field_Value)
		if !fv_ok {
			error_node(arg, "Expected a 'field = value'")
			return data
		}
		// C++ Reference: check_expr.cpp:7555-7559.
		field_ident, ident_ok := fv.field.derived.(^ast.Ident)
		if !ident_ok {
			expr_str := expr_to_string(fv.field)
			defer delete(expr_str)
			error_node(arg, "Invalid parameter name '%s' in procedure call", expr_str)
			return data
		}
		key := field_ident.name

		// C++ Reference: check_expr.cpp:7564-7573. The hint comes from the FIRST parameter entity
		// whose name matches the key AND whose type is not polymorphic. Polymorphic parameters are
		// skipped deliberately: their type is not yet known, so hinting with it would be wrong
		// rather than merely unhelpful.
		type_hint: ^Type
		for e in lhs {
			if e != nil && e.token.text == key && !is_type_polymorphic(entity_type(e)) {
				type_hint = entity_type(e)
				break
			}
		}

		// C++ Reference: check_expr.cpp:7574-7576.
		operand := Operand{}
		check_expr_with_type_hint(ctx, &operand, fv.value, type_hint)
		append(&named_operands, operand)
	}

	// Track valid candidates with scores
	valid_candidates := make([dynamic]Valid_Index_And_Score)
	defer delete(valid_candidates)

	// Build proc_entities array to track both original and generated polymorphic entities
	// C++ Reference: check_expr.cpp check_call_arguments_proc_group -- construction, and the arm
	// where a polymorphic candidate appends its instantiated entity and re-points the index
	// This is critical for polymorphic procedure groups - when a polymorphic procedure
	// generates a specialized entity, we need to track it in the candidates array
	proc_entities := make([dynamic]^Entity, len(procs), len(procs) * 2 + 1)
	defer delete(proc_entities)
	copy(proc_entities[:], procs[:])

	// Track maximum matched target features for scoring
	// C++ Reference: check_expr.cpp check_call_arguments_proc_group, at its two scoring sites
	max_matched_features := 0

	// Test each candidate.
	//
	// C++ Reference: check_expr.cpp:7549 `for_array(i, procs)`. C++ iterates `procs`, which is
	// FIXED for the duration of the loop, while appending generated specializations to the
	// SEPARATE `proc_entities` (check_expr.cpp:7578). The port iterated `proc_entities` -- the very
	// array the body appends to -- so every polymorphic candidate that produced a specialization
	// was scored a SECOND time as if it were another group member. Measured on a two-member group
	// (`proc{c1, c2}` where both take `^$T/[dynamic]$E` and `..E`): procs=2 but THREE candidate
	// evaluations, yielding two "valid" entries with identical score 301 for what is really one
	// procedure. `proc_entities` starts as a copy of `procs`, so index `i` still addresses the same
	// entity in both and `candidate_index = i` below stays correct.
	for entity_proc, i in procs {
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

		// C++ Reference: check_expr.cpp check_call_arguments_proc_group. The flat
		// `assign_score_function(1)` penalty that used to sit here was REPLACED upstream (merge
		// a64cb7bfd, PR #7227) by an ordering:
		//
		//   value-polymorphic > concrete > specialized generic > unconstrained generic
		//
		// `proc($S: string)` specialises on a compile-time VALUE, so it is more specific than a
		// concrete overload. `proc(x: $T)` specialises on a TYPE and is a fallback, so it should
		// lose to an exact concrete overload. `proc(x: $T/[]$E)` constrains that type, so it sits
		// between the two.
		//
		// The tie-breaks are deliberately small integers: assign_score_function(1) is roughly a
		// full perfect-match unit and would swamp argument match quality, which is why the old
		// flat bonus could not express this ordering at all.
		if is_type_polymorphic(proc_type) {
			has_polymorphic_constant := false
			has_specialized_generic := false
			if pt.params != nil {
				if ptup, tuple_ok := &pt.params.variant.(Type_Tuple); tuple_ok {
					for param in ptup.variables {
						if param == nil {
							continue
						}
						if _, is_const := param.variant.(Entity_Constant); is_const {
							has_polymorphic_constant = true
						}
						bt := base_type(param.type)
						if bt != nil {
							if gen, gen_ok := bt.variant.(Type_Generic); gen_ok && gen.specialized != nil {
								has_specialized_generic = true
							}
						}
					}
				}
			}
			if has_polymorphic_constant {
				candidate.score += 2
			} else {
				candidate.score += -1 if has_specialized_generic else -2
			}
		}

		// Track max matched target features across all candidates
		// Reference: check_expr.cpp:7204
		matched := matched_target_features(pt)
		max_matched_features = max(max_matched_features, matched)

		append(&valid_candidates, candidate)
	}

	// Adjust scores based on target feature matching
	// Procedures with more matched features get higher scores
	//
	// C++ Reference: check_expr.cpp:7603-7610. This site read `procs[valids[i].index]` where
	// its immediate neighbours read `proc_entities[...]`; the port used proc_entities, and the
	// inconsistency was filed upstream as #263. Upstream has now corrected C++ to proc_entities
	// with the note "A polymorphic candidate appends its instantiated entity to proc_entities
	// above, so valids[i].index can be >= procs.count" -- i.e. the old read could index PAST the
	// end of procs. The port was right; nothing to change here. LEDGER #386.
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
		// C++ Reference: check_expr.cpp:7677-7931.
		begin_error_block()
		defer end_error_block()
		expr_name := expr_to_string(operand.expr)
		defer delete(expr_name)
		error_node(operand.expr, "No procedures or ambiguous call for procedure group '%s' that match with the given arguments", expr_name)
		if len(positional_operands) == 0 && len(named_operands) == 0 {
			error_line("\tNo given arguments\n")
		} else {
			print_call_argument_types(positional_operands, named_operands[:], args_split)
		}
		// C++ Reference: check_expr.cpp:7688-7690 --
		//     if (procs.count == 0) { procs = proc_group_entities_cloned(c, *operand); }
		// The candidate filtering above can empty `procs` entirely; measured, a zero-argument
		// group call (`g()`) arrives here with len(procs) == 0 while `g(1.5)` arrives with 2.
		// print_procedure_group_overloads then early-returns on the empty list, so the whole
		// "Did you mean one of the following overloads?" block vanished for exactly the calls
		// that need it most. C++ REFILLS from the group entity instead of giving up.
		if len(procs) == 0 {
			refill := proc_group_entities_cloned(ctx, operand, context.temp_allocator)
			if len(refill) > 0 {
				resize(&procs, len(refill))
				copy(procs[:], refill)
			}
		}
		print_procedure_group_overloads(ctx, procs[:], positional_operands, named_operands[:], args_split, expr_name)
		data.error = true
		return data
	}

	if len(valid_candidates) == 1 {
		// Exactly one match - use it
		// C++ Reference: check_expr.cpp:7992 `Entity *e = proc_entities[valids[0].index];`.
		// The index stored in a candidate is an index into `proc_entities`, NOT `procs` -- when a
		// polymorphic candidate produces a specialization the loop appends it to `proc_entities`
		// and records `len(proc_entities)-1`, which is out of range for `procs`. The port read
		// `procs` here. It never crashed only because the duplicate-scoring defect above kept
		// `len(valid_candidates)` at 2, so this single-winner branch was unreachable in exactly
		// the cases that would have gone out of bounds. Fixing the loop exposed it immediately
		// ("Index 3 is out of range 0..<3").
		winner := proc_entities[valid_candidates[0].index]
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
		// C++ Reference: check_expr.cpp:7932-7982. The port named neither the group nor
		// the candidates' source positions, invented the "Candidate: " prefix and the
		// "- multiple procedures match equally" tail, omitted the given-argument block,
		// omitted each candidate's `where` clauses, and emitted its continuation lines
		// outside an error block so they preceded the diagnostic.
		begin_error_block()
		defer end_error_block()
		expr_name := expr_to_string(operand.expr)
		defer delete(expr_name)
		error_node(operand.expr, "Ambiguous procedure group call '%s' that match with the given arguments", expr_name)
		if len(positional_operands) == 0 && len(named_operands) == 0 {
			error_line("\tNo given arguments\n")
		} else {
			print_call_argument_types(positional_operands, named_operands[:], args_split)
		}

		for i := 0; i < num_best; i += 1 {
			candidate := proc_entities[valid_candidates[i].index]
			t := base_type(entity_type(candidate))
			if t == nil || t.kind != .Proc {
				continue
			}
			pt, allocated := proc_display_type_string(t)
			defer if allocated {
				delete(pt)
			}
			sep := "::"
			if candidate.kind == .Variable {
				sep = ":="
			}
			error_line("\t%s %s %s ", candidate.token.text, sep, pt)

			if candidate.decl_info != nil && candidate.decl_info.proc_lit != nil {
				pl := candidate.decl_info.proc_lit
				if pl.where_token.kind != .Invalid {
					error_line("\n\t\twhere ")
					for clause, j in pl.where_clauses {
						if j != 0 {
							error_line("\t\t      ")
						}
						str := expr_to_string(clause)
						error_line("%s", str)
						delete(str)
						if j != len(pl.where_clauses) - 1 {
							error_line(",")
						}
					}
					error_line("\n\t")
				}
			}
			error_line("at %s\n", token_pos_to_string(candidate.token.pos))
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
