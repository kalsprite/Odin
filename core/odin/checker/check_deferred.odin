package checker

/*
Deferred Checks Processing

This module implements deferred queue processing and global untyped expression resolution.
These operations happen after main procedure checking to handle:
1. Procedures with defer attributes (@(deferred_in), @(deferred_out), etc.)
2. Objective-C context providers (@(objc_context_provider))
3. Global untyped expressions that need default type resolution

C++ Reference: checker.cpp:6481-6704 (check_deferred_procedures)
               checker.cpp:6971-7007 (check_objc_context_provider_procedures)
               checker.cpp:7458-7465 (global_untyped_queue processing)
               types.cpp:899-920 (base_named_type)
               check_expr.cpp:1042-1047 (internal_check_is_assignable_to)
*/

import "core:container/queue"


// ======================================================================================
// TUPLE TO POINTERS CONVERSION
// C++ Reference: checker.cpp:6495-6513
// ======================================================================================

// tuple_to_pointers converts a tuple type's elements to pointer types
// Used for @(deferred_in_by_ptr), @(deferred_out_by_ptr), etc.
// C++ Reference: checker.cpp:6495-6513
tuple_to_pointers :: proc(ot: ^Type, allocator := context.allocator) -> ^Type {
	if ot == nil {
		return nil
	}

	// Must be a tuple
	assert(ot.kind == .Tuple)

	tuple_info := ot.variant.(Type_Tuple)

	// Create new tuple type with pointer-wrapped elements
	// C++ Reference: checker.cpp:6502-6503
	t := new(Type, allocator)
	t.kind = .Tuple

	new_tuple := Type_Tuple{}
	new_tuple.variables = make([dynamic]^Entity, 0, len(tuple_info.variables), allocator)
	new_tuple.is_packed = tuple_info.is_packed

	// Convert each variable to pointer type
	// C++ Reference: checker.cpp:6506-6509
	for e in tuple_info.variables {
		// Create pointer type
		ptr_type := new(Type, allocator)
		ptr_type.kind = .Pointer
		ptr_type.variant = Type_Pointer {
			elem = e.type,
		}

		// Use alloc_entity_variable to create proper entity
		// C++ Reference: checker.cpp:6508 (alloc_entity_variable)
		ptr_var := alloc_entity_variable(nil, e.token, ptr_type, .Resolved, allocator)

		append(&new_tuple.variables, ptr_var)
	}

	t.variant = new_tuple
	return t
}

// ======================================================================================
// DEFERRED PROCEDURE VALIDATION
// C++ Reference: checker.cpp:6515-6704
// ======================================================================================

// check_deferred_procedures validates deferred procedure attributes
// Ensures that procedures with @(deferred_*) attributes have compatible signatures
// C++ Reference: checker.cpp:6515-6704
check_deferred_procedures :: proc(c: ^Checker) {
	// Drain queue of procedures with deferred attributes
	// C++ Reference: checker.cpp check_deferred_procedures (mpsc_dequeue loop)
	for {
		src, ok := queue.mpsc_dequeue(&c.procs_with_deferred_to_check)
		if !ok || src == nil {
			break
		}

		// Must be a procedure entity
		assert(src.kind == .Procedure)

		src_proc, src_is_proc := src.variant.(Entity_Procedure)
		if !src_is_proc {
			continue
		}

		// Get deferred procedure info
		dst_kind := src_proc.deferred_procedure.kind
		dst := src_proc.deferred_procedure.entity

		if dst == nil {
			continue
		}

		assert(dst.kind == .Procedure)

		// Get attribute name for error messages
		// C++ Reference: checker.cpp check_deferred_procedures
		attribute := ""
		#partial switch dst_kind {
		case .None:
			attribute = "deferred_none"
		case .In:
			attribute = "deferred_in"
		case .Out:
			attribute = "deferred_out"
		case .In_Out:
			attribute = "deferred_in_out"
		case .In_By_Ptr:
			attribute = "deferred_in_by_ptr"
		case .Out_By_Ptr:
			attribute = "deferred_out_by_ptr"
		case .In_Out_By_Ptr:
			attribute = "deferred_in_out_by_ptr"
		}

		// Validate self-reference
		// C++ Reference: checker.cpp check_deferred_procedures
		if src == dst {
			error(src.token, "'%s' cannot be used as its own %s", src.token.text, attribute)
			continue
		}

		// Reject deferred-procedure CHAINING. C++ checker.cpp check_deferred_procedures, between the
		// self-reference check above and the polymorphic check below. The port had no equivalent,
		// so `@(deferred_none=b)` on a procedure whose target `b` itself carries a deferred
		// procedure was accepted in silence (probe nc_defchain).
		if entity_has_deferred_procedure(dst) {
			error(src.token,
			      "Deferred procedure '%s' cannot be used as the target of '%s' because it has a deferred procedure itself (deferred procedure chaining is not allowed)",
			      dst.token.text, src.token.text)
			continue
		}

		// Check polymorphic procedures
		// C++ Reference: checker.cpp check_deferred_procedures
		if is_type_polymorphic(src.type) || is_type_polymorphic(dst.type) {
			error(src.token, "'%s' cannot be used with a polymorphic procedure", attribute)
			continue
		}

		// Check if target procedure is disabled
		// C++ Reference: checker.cpp check_deferred_procedures
		if .Disabled in dst.flags {
			// Prevent procedures that have been disabled from acting as deferrals
			src_proc.deferred_procedure = {}
			src.variant = src_proc
			continue
		}

		// Both must be procedure types. C++ checker.cpp check_deferred_procedures DIAGNOSES and continues; the
		// port asserted, which turns a reportable program into an abort. Same family as #21/#283:
		// an assert on a condition user input can reach. I have not built a repro that gets a
		// non-proc here -- the attribute checker may reject earlier -- so this is a latent abort
		// rather than a demonstrated one, and the change is to fail the way C++ fails either way.
		if !is_type_proc(src.type) || !is_type_proc(dst.type) {
			error(src.token, "Invalid procedure type found during deferred procedure checking")
			continue
		}

		src_proc_type, src_ok := base_type(src.type).variant.(Type_Proc)
		dst_proc_type, dst_ok := base_type(dst.type).variant.(Type_Proc)

		if !src_ok || !dst_ok {
			continue
		}

		src_params := src_proc_type.params
		src_results := src_proc_type.results
		dst_params := dst_proc_type.params

		// Apply pointer transformation for by_ptr variants
		// C++ Reference: checker.cpp check_deferred_procedures
		by_ptr := false
		#partial switch dst_kind {
		case .In_By_Ptr:
			by_ptr = true
			src_params = tuple_to_pointers(src_params)
		case .Out_By_Ptr:
			by_ptr = true
			src_results = tuple_to_pointers(src_results)
		case .In_Out_By_Ptr:
			by_ptr = true
			src_params = tuple_to_pointers(src_params)
			src_results = tuple_to_pointers(src_results)
		}

		// Validate signature compatibility based on deferred kind
		// C++ Reference: checker.cpp check_deferred_procedures
		#partial switch dst_kind {
		case .None:
			// Deferred procedure must have no input parameters
			// C++ Reference: checker.cpp check_deferred_procedures
			if dst_params == nil {
				// Okay - no parameters
				continue
			}

			error(src.token, "Deferred procedure '%s' must have no input parameters", dst.token.text)

		case .In, .In_By_Ptr:
			// Parameters must match inputs
			// C++ Reference: checker.cpp check_deferred_procedures
			if src_params == nil && dst_params == nil {
				// Okay - both have no parameters
				continue
			}
			if (src_params == nil) != (dst_params == nil) {
				error(src.token, "Deferred procedure '%s' parameters do not match the inputs of initial procedure '%s'", dst.token.text, src.token.text)
				continue
			}

			// Both must be tuples
			// C++ Reference: checker.cpp check_deferred_procedures
			assert(src_params.kind == .Tuple)
			assert(dst_params.kind == .Tuple)

			// C++ Reference: checker.cpp check_deferred_procedures --
			//     "Deferred procedure '%.*s' parameters do not match the inputs of initial
			//      procedure '%.*s':\n\t(%s) =/= (%s)"    args: dst, src, dst_str, src_str
			// The port had invented a flat one-line spelling with the types interpolated mid
			// sentence and no parentheses. Witness wit_bl219/l_def_in.
			if !are_types_identical(src_params, dst_params) {
				error(
					src.token,
					"Deferred procedure '%s' parameters do not match the inputs of initial procedure '%s':\n\t(%s) =/= (%s)",
					dst.token.text,
					src.token.text,
					type_to_string(dst_params),
					type_to_string(src_params),
				)
				continue
			}

		case .Out, .Out_By_Ptr:
			// Parameters must match results
			// C++ Reference: checker.cpp check_deferred_procedures
			if src_results == nil && dst_params == nil {
				// Okay - both have no results/parameters
				continue
			}
			if (src_results == nil) != (dst_params == nil) {
				error(src.token, "Deferred procedure '%s' parameters do not match the results of initial procedure '%s'", dst.token.text, src.token.text)
				continue
			}

			// Both must be tuples
			// C++ Reference: checker.cpp check_deferred_procedures
			assert(src_results.kind == .Tuple)
			assert(dst_params.kind == .Tuple)

			// C++ Reference: checker.cpp check_deferred_procedures -- same shape as the inputs
			// arm above, with "results" in place of "inputs". Witness wit_bl219/l_def_out.
			if !are_types_identical(src_results, dst_params) {
				error(
					src.token,
					"Deferred procedure '%s' parameters do not match the results of initial procedure '%s':\n\t(%s) =/= (%s)",
					dst.token.text,
					src.token.text,
					type_to_string(dst_params),
					type_to_string(src_results),
				)
				continue
			}

		case .In_Out, .In_Out_By_Ptr:
			// Parameters must match concatenated inputs and results
			// C++ Reference: checker.cpp check_deferred_procedures
			if src_params == nil && src_results == nil && dst_params == nil {
				// Okay - all are empty
				continue
			}

			if dst_params == nil {
				error(src.token, "Deferred procedure must have parameters for %s", attribute)
				continue
			}

			// dst_params must be a tuple
			// C++ Reference: checker.cpp check_deferred_procedures
			assert(dst_params.kind == .Tuple)

			// Build concatenated tuple: (src_params..., src_results...)
			// C++ Reference: checker.cpp check_deferred_procedures
			tsrc := new(Type)
			tsrc.kind = .Tuple

			src_tuple := Type_Tuple{}
			src_tuple.variables = make([dynamic]^Entity, 0, 16)

			// Add parameters
			if src_params != nil {
				// C++ Reference: checker.cpp check_deferred_procedures
				assert(src_params.kind == .Tuple)
				if src_params_tuple, ok2 := src_params.variant.(Type_Tuple); ok2 {
					for var in src_params_tuple.variables {
						append(&src_tuple.variables, var)
					}
				}
			}

			// Add results
			if src_results != nil {
				// C++ Reference: checker.cpp check_deferred_procedures
				assert(src_results.kind == .Tuple)
				if src_results_tuple, ok3 := src_results.variant.(Type_Tuple); ok3 {
					for var in src_results_tuple.variables {
						append(&src_tuple.variables, var)
					}
				}
			}

			tsrc.variant = src_tuple

			// Check if concatenated tuple matches dst_params
			// C++ Reference: checker.cpp check_deferred_procedures
			// C++ Reference: checker.cpp check_deferred_procedures. NOTE the wording: the in_out
			// arm reuses "the results of initial procedure", NOT "the combined inputs and results"
			// which the port had invented. It reads oddly for an in_out attribute, but a reference
			// quirk is the contract. Witness wit_bl219/l_def_inout.
			if !are_types_identical(tsrc, dst_params) {
				error(
					src.token,
					"Deferred procedure '%s' parameters do not match the results of initial procedure '%s':\n\t(%s) =/= (%s)",
					dst.token.text,
					src.token.text,
					type_to_string(dst_params),
					type_to_string(tsrc),
				)
				continue
			}
		}
	}
}

// ======================================================================================
// OBJECTIVE-C CONTEXT PROVIDERS
// C++ Reference: checker.cpp check_deferred_procedures
// ======================================================================================

// check_objc_context_provider_procedures validates Objective-C context provider procedures
// Ensures procedures with @(objc_context_provider) have correct signatures
// C++ Reference: checker.cpp check_deferred_procedures
check_objc_context_provider_procedures :: proc(c: ^Checker) {
	// Drain queue of ObjC context provider type entities
	// C++ Reference: checker.cpp:6972 (mpsc_dequeue loop)
	for {
		e, ok := queue.mpsc_dequeue(&c.procs_with_objc_context_provider_to_check)
		if !ok || e == nil {
			break
		}

		// Must be a type name entity
		assert(e.kind == .Type_Name)

		type_name, is_type_name := e.variant.(Entity_Type_Name)
		if !is_type_name {
			continue
		}

		proc_entity := type_name.objc_context_provider
		if proc_entity == nil {
			continue
		}

		assert(proc_entity.kind == .Procedure)

		// Get procedure type
		// C++ Reference: checker.cpp:6978
		proc_type := base_type(proc_entity.type)
		if proc_type == nil || proc_type.kind != .Proc {
			// C++ dereferences proc_entity->type->Proc unguarded; an unresolved
			// signature there is a crash, so skipping is a strict safety superset.
			continue
		}

		proc_info, proc_ok := proc_type.variant.(Type_Proc)
		if !proc_ok {
			continue
		}

		// Validate return type: must be exactly 'context', not 'untyped_nil'
		// C++ Reference: checker.cpp:6980-6983
		return_type := t_untyped_nil
		if proc_info.result_count == 1 {
			if proc_info.results != nil && proc_info.results.kind == .Tuple {
				if results_tuple, results_ok := proc_info.results.variant.(Type_Tuple); results_ok {
					if len(results_tuple.variables) > 0 {
						return_type = base_named_type(results_tuple.variables[0].type)
					}
				}
			}
		}

		if return_type != c.t_context {
			error(proc_entity.token, "The @(objc_context_provider) procedure must only return a context.")
		}

		// Validate parameter count: must be exactly 1
		// C++ Reference: checker.cpp:6985-6988
		self_param_err := "The @(objc_context_provider) procedure must take as a parameter a single pointer to the @(objc_type) value."

		if proc_info.param_count != 1 {
			error(proc_entity.token, self_param_err)
		}

		// Validate parameter type: must be a pointer
		// C++ Reference: checker.cpp:6990-6993
		params_valid := proc_info.params != nil && proc_info.params.kind == .Tuple
		if !params_valid {
			error(proc_entity.token, self_param_err)
		}

		// Only reach into the variant once params is known to be a non-nil tuple; C++
		// dereferences proc.params->Tuple unguarded, which is a crash on a parameterless
		// provider rather than a diagnostic.
		params_tuple: Type_Tuple
		params_ok := false
		if params_valid {
			params_tuple, params_ok = proc_info.params.variant.(Type_Tuple)
		}
		tuple_valid := params_ok && len(params_tuple.variables) > 0
		if !tuple_valid && params_valid {
			// !params_valid already reported the same message just above.
			error(proc_entity.token, self_param_err)
		}

		pointer_valid := false
		if tuple_valid {
			self_param := base_type(params_tuple.variables[0].type)
			if self_param.kind != .Pointer {
				error(proc_entity.token, self_param_err)
			} else {
				pointer_valid = true
			}
		}

		// Validate pointer element type matches the @(objc_type)
		// C++ Reference: checker.cpp:6995-6999
		if pointer_valid {
			self_param := base_type(params_tuple.variables[0].type)
			self_param_pointer, ok2 := self_param.variant.(Type_Pointer)
			if !ok2 {
				error(proc_entity.token, self_param_err)
			} else {
				self_type := base_named_type(self_param_pointer.elem)

				// Check if self_type is assignable to the entity's type or objc_ivar
				// C++ Reference: checker.cpp check_objc_context_provider_procedures
				//
				// base_named_type yields t_invalid when the pointee is not a named type.
				// That is handed straight to internal_check_is_assignable_to, as C++ does:
				// is_type_typed(t_invalid) is true, so the `c == nil` assert in
				// check_distance_between_types passes, and the walk then falls out at -1,
				// i.e. "not assignable".
				valid := internal_check_is_assignable_to(self_type, e.type)

				if !valid && type_name.objc_ivar != nil {
					valid = internal_check_is_assignable_to(self_type, type_name.objc_ivar)
				}

				if !valid {
					error(proc_entity.token, self_param_err)
				}
			}
		}

		// Validate calling convention: must be C or Contextless
		// C++ Reference: checker.cpp:7000-7002
		if proc_info.calling_convention != .C && proc_info.calling_convention != .Contextless {
			error(e.token, self_param_err)
		}

		// Validate not polymorphic
		// C++ Reference: checker.cpp:7003-7005
		if proc_info.is_polymorphic {
			error(e.token, self_param_err)
		}
	}
}

// ======================================================================================
// GLOBAL UNTYPED EXPRESSION RESOLUTION
// C++ Reference: checker.cpp:7458-7465
// ======================================================================================

// resolve_global_untyped_expressions processes untyped expressions and assigns default types
// This happens after all procedure checking to ensure type propagation is complete
// C++ Reference: checker.cpp:7458-7465 (add untyped expression values)
resolve_global_untyped_expressions :: proc(c: ^Checker) {
	// Process all untyped expressions in queue
	// C++ Reference: checker.cpp:7459 (mpsc_dequeue loop)
	for {
		u, ok := queue.mpsc_dequeue(&c.global_untyped_queue)
		if !ok {
			break
		}

		if u.expr == nil || u.info == nil {
			continue
		}

		// Verify this is still untyped
		// C++ Reference: checker.cpp:7474-7475 (compiler_error)
		// ARCHITECTURAL NOTE: This should NEVER happen in valid code - it indicates a bug in the checker:
		// - Expression was typed but still added to untyped queue, OR
		// - Expression was typed after being added but before being processed, OR
		// - Race condition in concurrent checking
		// The C++ version uses compiler_error (internal assertion), we match this with assert
		assert(!is_type_typed(u.info.type), "Internal error: typed expression in global_untyped_queue")

		// Add type and value to AST
		// C++ Reference: checker.cpp:7464 (add_type_and_value)
		add_type_and_value(&c.builtin_ctx, u.expr, u.info.mode, u.info.type, u.info.value)
	}
}

// ======================================================================================
// HELPER FUNCTIONS
// ======================================================================================

// base_named_type unwraps a Type_Named to find the last named type in the chain
// Returns t_invalid if the type is not a named type
// C++ Reference: types.cpp:899-920
base_named_type :: proc(t: ^Type) -> ^Type {
	if t == nil {
		return t_invalid
	}

	// Must be a named type
	// C++ Reference: types.cpp:900-902
	if t.kind != .Named {
		return t_invalid
	}

	// Unwrap the named type chain
	// C++ Reference: types.cpp:904-919
	prev_named := t
	current := t

	if named, ok := current.variant.(Type_Named); ok {
		current = named.base
	} else {
		return t_invalid
	}

	for {
		if current == nil {
			break
		}

		if current.kind != .Named {
			break
		}

		// Detect self-referential types (should not happen in valid code)
		// C++ Reference: types.cpp:913-915
		if named, ok := current.variant.(Type_Named); ok {
			if current == named.base {
				return t_invalid
			}
			prev_named = current
			current = named.base
		} else {
			break
		}
	}

	return prev_named
}

// internal_check_is_assignable_to is defined in check_equivalence.odin

// NOTE: The following helper functions are implemented in other modules:
// - is_type_polymorphic: check_type.odin:653
// - is_type_proc: types.odin:234
// - base_type: types.odin:100
// - are_types_identical: types.odin:575
// - is_type_typed: types.odin:137
// - add_type_and_value: check_expr.odin:1464
// - check_is_assignable_to: check_expr.odin:2208
//
// These functions are imported and used directly without redefinition.
