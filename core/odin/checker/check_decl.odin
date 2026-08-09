package checker

/*
Declaration checking for variables and related entities.

This module implements variable declaration validation, initialization checking,
and type inference logic from the C++ implementation in check_decl.cpp.

C++ Reference: check_decl.cpp
Lines: 4-152 (check_init_variable, check_init_variables)
Lines: 1612-1758 (check_global_variable_decl)
Lines: 1897-1969 (check_entity_decl)

*/

import "core:container/queue"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:path/filepath"
import "core:strings"
import "core:sync"

// C++ Reference: check_decl.cpp check_init_variable:4-124
// NOTE(bill): 'content_name' is for debugging and error messages
check_init_variable :: proc(ctx: ^Checker_Context, e: ^Entity, operand: ^Operand, context_name: string) -> ^Type {
	// Handle invalid operands
	// C++ Reference: check_decl.cpp check_init_variable:5-41
	if operand.mode == .Invalid || operand.type == t_invalid || entity_type(e) == t_invalid {

		// C++ Reference: check_decl.cpp check_init_variable:9-23
		if operand.mode == .Builtin {
			// C++ Reference: check_decl.cpp check_init_variable:10. The block was noted here as a comment but
			// never opened, so the explanatory error_line below was emitted unblocked and
			// did not reach the output attached to its error.
			begin_error_block()
			defer end_error_block()
			expr_str := expr_to_string(operand.expr)
			defer delete(expr_str)

			error(operand.expr, "Cannot assign built-in procedure '%s' in %s", expr_str, context_name)

			error_line("\tBuilt-in procedures are implemented by the compiler and might not be actually instantiated procedure\n")

			operand.mode = .Invalid
		}

		// C++ Reference: check_decl.cpp check_init_variable:26-35
		if operand.mode == .Proc_Group {
			if entity_type(e) == nil {
				error(operand.expr, "Cannot determine type from overloaded procedure '%s'", operand.proc_group.token.text)
			} else {
				check_assignment(ctx, operand, entity_type(e), "variable assignment")
				if operand.mode != .Type {
					return operand.type
				}
			}
		}

		// C++ Reference: check_decl.cpp check_init_variable:37-40
		if entity_type(e) == nil {
			set_entity_type(e, t_invalid)
		}
		return nil
	}

	// C++ Reference: check_decl.cpp check_init_variable:43-45
	if e.kind == .Variable {
		if var, ok := &e.variant.(Entity_Variable); ok {
			var.init_expr = operand.expr
		}
	}

	// C++ Reference: check_decl.cpp check_init_variable:47-68
	if operand.mode == .Type {
		entity_t := entity_type(e)
		if entity_t != nil && is_type_typeid(entity_t) && !is_type_polymorphic(operand.type) {
			add_type_info_type(ctx, operand.type)
			add_type_and_value(ctx, operand.expr, .Value, entity_t, exact_value_typeid(operand.type))
			return entity_t
		} else {
			// ERROR_BLOCK()
			t_str := type_to_string(operand.type)

			if is_type_polymorphic(operand.type) {
				error(operand.expr, "Cannot assign a non-specialized polymorphic type '%s' to variable '%s'", t_str, e.token.text)
			} else {
				error(operand.expr, "Cannot assign a type '%s' to variable '%s'", t_str, e.token.text)
			}

			if entity_type(e) == nil {
				error_line("\tThe type of the variable '%s' cannot be inferred as a type and does not have a default type\n", e.token.text)
			}
			set_entity_type(e, operand.type)
			return nil
		}
	}

	// C++ Reference: check_decl.cpp check_init_variable:70-114
	if entity_type(e) == nil {
		// NOTE(bill): Use the type of the operand
		t := operand.type

		// C++ Reference: check_decl.cpp check_init_variable:74-84
		if is_type_untyped(t) {
			if is_type_untyped_uninit(t) {
				error(e.token, "Invalid use of --- in %s", context_name)
				set_entity_type(e, t_invalid)
				return nil
			} else if t == t_invalid || is_type_untyped_nil(t) {
				error(e.token, "Invalid use of untyped nil in %s", context_name)
				set_entity_type(e, t_invalid)
				return nil
			}
			t = default_type(t)
		}

		// C++ Reference: check_decl.cpp check_init_variable:86-89
		if is_type_asm_proc(t) {
			error(e.token, "Invalid use of inline asm in %s", context_name)
			set_entity_type(e, t_invalid)
			return nil
		} else if is_type_polymorphic(t) {
			// C++ Reference: check_decl.cpp check_init_variable:90-104
			e2 := entity_of_node(ctx.info, operand.expr)
			if e2 == nil {
				set_entity_type(e, t_invalid)
				return nil
			}
			if e2.state != .Resolved {
				set_entity_type(e, t)
				return nil
			}
			str := type_to_string(t)
			error(operand.expr, "Invalid use of a non-specialized polymorphic type '%s' in %s", str, context_name)
			set_entity_type(e, t_invalid)
			return nil
		} else if is_type_empty_union(t) {
			// C++ Reference: check_decl.cpp check_init_variable:105-110
			str := type_to_string(t)
			error(e.token, "An empty union '%s' cannot be instantiated in %s", str, context_name)
			set_entity_type(e, t_invalid)
			return nil
		}

		// C++ Reference: check_decl.cpp check_init_variable:112-113.
		//
		// C++ asserts here unguarded, and can afford to: every path that reaches this point
		// has a non-nil type. The port CAN reach it with `t == nil`, because its parser
		// recovers from a malformed initialiser differently -- `a, b, c := **v` is a syntax
		// error ("expected an operand"), and the recovery node reaches the checker with an
		// operand carrying no type at all. is_type_untyped(nil) is false and is_type_typed(nil)
		// is false, so nil slips past every branch above and trips the assert: a hard abort of
		// the whole checker on input the parser had ALREADY diagnosed.
		//
		// Treated as invalid rather than asserted. This is not a divergence from C++'s
		// behaviour on well-formed input -- it is the port declining to abort on input C++'s
		// parser never hands to its checker in this shape.
		if t == nil {
			set_entity_type(e, t_invalid)
			return nil
		}
		assert(is_type_typed(t))
		set_entity_type(e, t)
	}

	// C++ Reference: check_decl.cpp check_init_variable:116
	if _, ok := &e.variant.(Entity_Variable); ok {
		e.parent_proc_decl = ctx.curr_proc_decl
	}

	// C++ Reference: check_decl.cpp check_init_variable:118-121
	check_assignment(ctx, operand, entity_type(e), context_name)
	if operand.mode == .Invalid {
		return nil
	}

	// C++ Reference: check_decl.cpp check_init_variable:123
	return entity_type(e)
}

// C++ Reference: check_decl.cpp check_init_variables:126-152
check_init_variables :: proc(ctx: ^Checker_Context, lhs: []^Entity, inits: []^ast.Expr, context_name: string) {
	// C++ Reference: check_decl.cpp check_init_variables:127-129
	if (lhs == nil || len(lhs) == 0) && len(inits) == 0 {
		return
	}

	// NOTE(bill): If there is a bad syntax error, rhs > lhs which would mean there would need to be
	// an extra allocation
	// C++ Reference: check_decl.cpp check_init_variables:132-136
	operands := make([dynamic]Operand, 0, 2 * len(lhs), context.temp_allocator)
	check_unpack_arguments(ctx, lhs, &operands, inits, {.Allow_Ok, .Allow_Undef})

	// C++ Reference: check_decl.cpp check_init_variables:138-148
	rhs_count := len(operands)
	max := min(len(lhs), rhs_count)
	for i in 0 ..< max {
		e := lhs[i]
		d := decl_info_of_entity(e)
		o := &operands[i]
		check_init_variable(ctx, e, o, context_name)
		if d != nil {
			d.init_expr = cast(^ast.Expr)o.expr
		}
	}

	// C++ Reference: check_decl.cpp check_init_variables:149-151
	if rhs_count > 0 && len(lhs) != rhs_count {
		error(lhs[0].token, "Assignment count mismatch '%d' = '%d'", len(lhs), rhs_count)
	}
}

// C++ Reference: check_decl.cpp:1612-1758
check_global_variable_decl :: proc(ctx: ^Checker_Context, e: ^Entity, type_expr: ^ast.Expr, init_expr: ^ast.Expr) {
	// C++ Reference: check_decl.cpp:1613-1614
	assert(entity_type(e) == nil)
	assert(e.kind == .Variable)

	// C++ Reference: check_decl.cpp:1616-1620
	if e.flags & {.Visited} != {} {
		set_entity_type(e, t_invalid)
		return
	}
	e.flags += {.Visited}

	// C++ Reference: check_decl.cpp:1622-1629
	e_var := &e.variant.(Entity_Variable)
	ac := make_attribute_context(e_var.link_prefix, e_var.link_suffix)
	ac.init_expr_list_count = init_expr != nil ? 1 : 0

	decl := decl_info_of_entity(e)
	assert(decl == ctx.decl)
	if decl != nil {
		check_decl_attributes(ctx, decl.attributes, &ac, .Var)
	}

	// C++ Reference: check_decl.cpp:1631-1634
	if ac.require_declaration {
		e.flags += {.Require}
		// Enqueue entity to required_global_variable_queue for @require tracking
		// Added required_global_variable_queue to Checker_Info (checker.odin:1985)
		// C++ Reference: queue.mpsc_enqueue(&ctx.info.required_global_variable_queue, e)
		queue.mpsc_enqueue(&ctx.info.required_global_variable_queue, e)
	}

	// C++ Reference: check_decl.cpp:1637-1646
	e_var.thread_local_model = ac.thread_local_model
	e_var.is_export = ac.is_export
	e.flags -= {.Static}
	if ac.is_static {
		error(e.token, "@(static) is not supported for global variables, nor required")
	}
	// Check: @(thread_local) not allowed on blank identifier
	if len(ac.thread_local_model) > 0 && is_blank_ident_string(e.token.text) {
		error(e.token, "The 'thread_local' attribute is not allowed to be applied to '_'")
	}
	if ac.rodata {
		e_var.is_rodata = true
	}
	ac.link_name = handle_link_name(ctx, e.token, ac.link_name, ac.link_prefix, ac.link_suffix)

	// C++ Reference: check_decl.cpp:1648-1656
	// Platform validation for @(thread_local)
	if is_arch_wasm() && len(e_var.thread_local_model) != 0 {
		e_var.thread_local_model = ""
		// NOTE(bill): ignore this message for the time being
		// C++ Reference: check_decl.cpp:1653
		// error(e.token, "@(thread_local) is not supported for this target platform")
	}
	// Check if thread-local storage is disabled globally via build flag
	if ctx.info.build_context != nil && ctx.info.build_context.no_thread_local {
		e_var.thread_local_model = ""
	}

	context_name := "variable declaration"

	// C++ Reference: check_decl.cpp:1659-1674
	if type_expr != nil {
		set_entity_type(e, check_type(ctx, type_expr))
	}
	if entity_type(e) != nil {
		if is_type_polymorphic(base_type(entity_type(e))) {
			str := type_to_string(entity_type(e))
			error(e.token, "Invalid use of a polymorphic type '%s' in %s", str, context_name)
			set_entity_type(e, t_invalid)
		} else if is_type_empty_union(entity_type(e)) {
			str := type_to_string(entity_type(e))
			error(e.token, "An empty union '%s' cannot be instantiated in %s", str, context_name)
			set_entity_type(e, t_invalid)
		}
	}

	// C++ Reference: check_decl.cpp:1677-1691
	if e_var.is_foreign {
		if init_expr != nil {
			error(e.token, "A foreign variable declaration cannot have a default value")
		}
		init_entity_foreign_library(ctx, e)
		if is_arch_wasm() && e_var.foreign_library != nil {
			// LEDGER 346: `{` is a format verb in Odin's fmt; C++'s printf passes it through.
			// Unescaped this printed "'foreign %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)".
			// C++ Reference: src/check_decl.cpp check_global_variable_decl:1753
			error(e.token, "A foreign variable declaration can not be scoped to a module and must be declared in a 'foreign {{' (without a library) block")
		}
	}
	if len(ac.link_name) > 0 {
		e_var.link_name = ac.link_name
	}
	if len(ac.link_section) > 0 {
		e_var.link_section = ac.link_section
	}

	// C++ Reference: check_decl.cpp check_global_variable_decl:1693-1716
	if e_var.is_foreign || e_var.is_export {
		name := e.token.text
		if len(e_var.link_name) > 0 {
			name = e_var.link_name
		}

		fp := &ctx.info.foreigns
		found := fp[name]
		if found != nil {
			f := found
			pos := token_pos_to_string(f.token.pos)

			this_type := base_type(entity_type(e))
			other_type := base_type(entity_type(f))
			if !signature_parameter_similar_enough(this_type, other_type) {
				error(e.token, "Foreign entity '%s' previously declared elsewhere with a different type\n\tat %s", name, pos)
			}
		} else {
			fp[name] = e
		}
	}

	// C++ Reference: check_decl.cpp check_global_variable_decl:1718-1720
	if len(e_var.link_name) > 0 {
		e.flags += {.Custom_Link_Name}
	}

	// C++ Reference: check_decl.cpp check_global_variable_decl:1722-1727
	if init_expr == nil {
		if type_expr == nil {
			set_entity_type(e, t_invalid)
		}
		return
	}

	// C++ Reference: check_decl.cpp check_global_variable_decl:1729-1731
	o := Operand{}
	check_expr_with_type_hint(ctx, &o, init_expr, entity_type(e))
	check_init_variable(ctx, e, &o, "variable declaration")

	// C++ Reference: check_decl.cpp check_global_variable_decl:1732-1755
	if e_var.is_rodata && o.mode != .Constant {
		// ERROR_BLOCK()
		error(o.expr, "Variables declared with @(rodata) must have constant initialization")
		expr := unparen_expr(o.expr)
		if is_type_struct(entity_type(e)) && expr != nil {
			if cl, ok := expr.derived.(^ast.Comp_Lit); ok {
				for elem_ in cl.elems {
					elem := elem_
					if fv, ok2 := elem.derived.(^ast.Field_Value); ok2 {
						elem = fv.value
					}
					elem = cast(^ast.Expr)unparen_expr(elem)

					elem_e := entity_of_node(ctx.info, elem)
					tav := get_type_and_value(ctx, elem)
					// NOTE: C++ check_decl.cpp check_global_variable_decl:1746 structure difference
					// C++:   if (tav.mode != Constant && e == nil && elem->kind != Ast_ProcLit)
					// Odin:  if (tav.mode != .Constant && elem_e == nil) { if !is_proc_lit { ... } }
					// Both are functionally equivalent - Odin nests the proc_lit check for clarity
					if tav.mode != .Constant && elem_e == nil {
						if _, ok3 := elem.derived.(^ast.Proc_Lit); !ok3 {
							// Get token and type for error message
							tok := ast_token(elem)
							pos := token_pos_to_string(tok.pos)
							elem_type := type_of_expr(elem, ctx.info)
							s := type_to_string(elem_type)
							error_line("%s Element is not constant, which is required for @(rodata), of type %s\n", pos, s)
						}
					}
				}
			}
		}
	}

	// C++ Reference: check_decl.cpp check_global_variable_decl:1757
	check_rtti_type_disallowed(ctx, e.token, entity_type(e), "A variable declaration is using a type, %s, which has been disallowed")
}

// C++ Reference: check_decl.cpp override_entity_in_scope:155-195
override_entity_in_scope :: proc(original_entity: ^Entity, new_entity: ^Entity) {
	// NOTE(bill): The original_entity's scope may not be same scope that it was inserted into
	// e.g. file entity inserted into its package scope
	// C++ Reference: check_decl.cpp override_entity_in_scope:156-164
	original_name := original_entity.token.text
	found_scope, _ := scope_lookup_parent(original_entity.scope, original_name)
	if found_scope == nil {
		return
	}

	// IMPORTANT NOTE(bill, 2021-04-10): Overriding behaviour was flawed in that the
	// original entity was still used check checked, but the checking was only
	// relying on "constant" data such as the Entity.type and Entity.Constant.value
	//
	// Therefore two things can be done: the type can be assigned to state that it
	// has been "evaluated" and the variant data can be copied across
	// C++ Reference: check_decl.cpp override_entity_in_scope:166-176

	// C++ uses mutex protection (rw_mutex_lock/unlock) for thread safety
	sync.rw_mutex_lock(&found_scope.mutex)
	found_scope.elements[original_name] = new_entity
	sync.rw_mutex_unlock(&found_scope.mutex)

	// C++ Reference: check_decl.cpp override_entity_in_scope:177-188
	original_entity.flags += {.Overridden}
	set_entity_type(original_entity, entity_type(new_entity))
	original_entity.kind = new_entity.kind

	// Copy decl_info and aliased_of for proper aliasing semantics
	// C++ Reference: check_decl.cpp override_entity_in_scope:180-181
	original_entity.decl_info = new_entity.decl_info
	original_entity.aliased_of = new_entity

	// AST node entity linking
	// C++ Reference: check_decl.cpp override_entity_in_scope:183-188
	// Copy the identifier and update the AST node directly
	original_entity.identifier = new_entity.identifier

	// Update AST Ident node to point to the new entity (C++ line 185-187)
	// In C++: ident->Ident.entity = new_entity
	// In Odin: directly mutate the semantic_ast branch's Ident.entity field
	if original_entity.identifier != nil {
		if ident, ok := original_entity.identifier.derived.(^ast.Ident); ok {
			ident.entity = new_entity
		}
	}

	// IMPORTANT NOTE(bill, 2021-04-10): copy only the variants
	// This is most likely NEVER required, but it does not at all hurt to keep
	// C++ Reference: check_decl.cpp override_entity_in_scope:190-194
	original_entity.variant = new_entity.variant
}

// C++ Reference: check_decl.cpp:197-240
// @TypeAliasingProblem
check_override_as_type_due_to_aliasing :: proc(ctx: ^Checker_Context, e: ^Entity, entity: ^Entity, init: ^ast.Expr, named_type: ^Type) -> bool {
	// C++ Reference: check_decl.cpp:198-239
	if entity != nil && entity.kind == .Type_Name {
		// @TypeAliasingProblem
		// NOTE(bill, 2022-02-03): This is used to solve the problem caused by type aliases
		// being "confused" as constants
		//
		//         A :: B
		//         C :: proc "c" (^A)
		//         B :: struct {x: C}
		//
		//     A gets evaluated first, and then checks B.
		//     B then checks C.
		//     C then tries to check A which is unresolved but thought to be a constant.
		//     Therefore within C's check, A errs as "not a type".
		//
		// This is because a const declaration may or may not be a type and this cannot
		// be determined from a syntactical standpoint.
		// This check allows the compiler to override the entity to be checked as a type.
		//
		// There is no problem if B is prefixed with the `#type` helper enforcing at
		// both a syntax and semantic level that B must be a type.
		//
		//         A :: #type B
		//
		// This approach is not fool proof and can fail in case such as:
		//
		//         X :: type_of(x)
		//         X :: Foo(int).Type
		//
		// Since even these kind of declarations may cause weird checking cycles.
		// For the time being, these are going to be treated as an unfortunate error
		// until there is a proper delaying system to try declaration again if they
		// have failed.

		if entity_type(e) != nil && is_type_typed(entity_type(e)) {
			return false
		}

		e.kind = .Type_Name
		e.variant = Entity_Type_Name{}  // Update variant to match kind
		check_type_decl(ctx, e, init, named_type)
		return true
	}
	return false
}

// C++ Reference: check_decl.cpp:244-306
check_try_override_const_decl :: proc(ctx: ^Checker_Context, e: ^Entity, entity: ^Entity, init: ^ast.Expr, named_type: ^Type) -> bool {
	// C++ Reference: check_decl.cpp:245-271
	if entity == nil {
		// retry_proc_lit: C++ goto label (replaced with recursion)
		init_expr := unparen_expr(init)
		if init_expr == nil {
			return false
		}

		// C++ Reference: check_decl.cpp check_try_override_const_decl:251-260
		if we, ok := init_expr.derived.(^ast.Ternary_When_Expr); ok {
			if we.cond == nil {
				return false
			}
			cond_tav := get_type_and_value(ctx, we.cond)
			if cond_val, ok2 := cond_tav.value.(bool); ok2 {
				next_init := cond_val ? we.x : we.y
				// goto retry_proc_lit
				// In Odin, we can just recursively call
				return check_try_override_const_decl(ctx, e, nil, next_init, named_type)
			} else {
				return false
			}
		}

		// C++ Reference: check_decl.cpp check_try_override_const_decl:261-269
		if _, ok := init_expr.derived.(^ast.Proc_Lit); ok {
			// NOTE(bill, 2024-07-04): Override as a procedure entity because this could be within a `when` statement
			e.kind = .Procedure
			set_entity_type(e, nil)
			d := decl_info_of_entity(e)
			// C++ assigns AST node pointer (d->proc_lit = init), not pointer to type assertion local
			// The type assertion `proc_lit` is a stack variable that goes out of scope
			d.proc_lit = cast(^ast.Proc_Lit)init_expr
			check_proc_decl(ctx, e, d)
			return true
		}

		return false
	}

	// C++ Reference: check_decl.cpp check_try_override_const_decl:273-287
	#partial switch entity.kind {
	case .Type_Name:
		if check_override_as_type_due_to_aliasing(ctx, e, entity, init, named_type) {
			return true
		}
	case .Builtin:
		if entity_type(e) != nil {
			return false
		}
		e.kind = .Builtin
		if builtin, ok := entity.variant.(Entity_Builtin); ok {
			e.variant = Entity_Builtin {
				id = builtin.id,
			}
		}
		set_entity_type(e, t_invalid)
		return true
	}

	// C++ Reference: check_decl.cpp check_try_override_const_decl:289-296
	if entity_type(e) != nil && entity_type(entity) != nil {
		x := Operand {
			type = entity_type(entity),
			mode = .Variable,
		}
		if !check_is_assignable_to(ctx, &x, entity_type(e)) {
			return false
		}
	}

	// NOTE(bill): Override aliased entity
	// C++ Reference: check_decl.cpp check_try_override_const_decl:298-304
	#partial switch entity.kind {
	case .Proc_Group, .Procedure:
		override_entity_in_scope(e, entity)
		return true
	}
	return false
}

// C++ Reference: check_decl.cpp:1897-1969
check_entity_decl :: proc(ctx: ^Checker_Context, e: ^Entity, d: ^Decl_Info, named_type: ^Type) {
	// C++ Reference: check_decl.cpp:1898-1900
	if e.state == .Resolved {
		return
	}

	// C++ Reference: check_decl.cpp check_entity_decl:1994-1996
	if .Lazy in e.flags {
		sync.recursive_mutex_lock(&ctx.info.lazy_mutex)
	}

	// C++ Reference: check_decl.cpp:1905
	name := e.token.text

	// C++ Reference: check_decl.cpp:1907-1920
	if entity_type(e) != nil || e.state != .Unresolved {
		error(e.token, "Illegal declaration cycle of `%s`", name)
	} else {
		assert(e.state == .Unresolved)
		d := d
		if d == nil {
			d = decl_info_of_entity(e)
			if d == nil {
				// NOTE(bill): This is an expected path - entity has no decl info
				set_entity_type(e, t_invalid)
				e.state = .Resolved
				set_base_type(named_type, t_invalid)
				// goto end
				// C++ Reference: check_decl.cpp check_entity_decl:2071-2075 (the `end:` label). This is the
				// early-exit path, and C++ reaches `end:` here too, so it registers and
				// unlocks exactly as the normal path does.
				if .Lazy in e.flags {
					append(&ctx.info.entities, e)
					sync.recursive_mutex_unlock(&ctx.info.lazy_mutex)
				}
				return
			}
		}

		// C++ Reference: check_decl.cpp:1922-1926
		c := ctx^
		c.scope = d.scope
		c.decl = d
		c.type_level = 0
		c.curr_proc_calling_convention = .Contextless

		// C++ Reference: check_decl.cpp:1928-1935
		prev_flags := c.scope.flags
		defer c.scope.flags = prev_flags

		if check_feature_flags(ctx, cast(^ast.Node)d.decl_node) & {.Global_Context} != {} {
			c.scope.flags += {.Context_Defined}
		} else {
			c.scope.flags -= {.Context_Defined}
		}

		// C++ Reference: check_decl.cpp:1938-1958
		if _, ok := &e.variant.(Entity_Variable); ok {
			e.parent_proc_decl = c.curr_proc_decl
		}
		e.state = .In_Progress

		// C++ Reference: check_decl.cpp check_entity_decl:2032-2046
		// Entities whose type can name other entities take part in cycle detection: push
		// them onto the shared type path for the duration of their declaration check.
		track_cycle_path := false
		#partial switch e.kind {
		case .Variable, .Constant, .Type_Name:
			track_cycle_path = true
		}
		if track_cycle_path {
			check_type_path_push(&c, e)
		}
		defer if track_cycle_path {
			check_type_path_pop(&c)
		}

		#partial switch e.kind {
		case .Variable:
			check_global_variable_decl(&c, e, d.type_expr, d.init_expr)
		case .Constant:
			check_const_decl(&c, e, d.type_expr, d.init_expr, named_type)
		case .Type_Name:
			check_type_decl(&c, e, d.init_expr, named_type, d.type_expr)
		case .Procedure:
			check_proc_decl(&c, e, d)
		case .Proc_Group:
			check_proc_group_decl(&c, e, d)
		}

		// C++ Reference: check_decl.cpp:1960
		e.state = .Resolved
	}

	// end: label
	// NOTE(bill): Add it to the list of checked entities
	// C++ Reference: check_decl.cpp check_entity_decl:2071-2075
	//
	// Both the append and the mutex were commented out. Consequences: lazily-checked entities
	// never reached info.entities, so every later pass that walks that array (the unused-entity
	// and global-init passes) silently skipped them; and concurrent lazy resolution of the same
	// entity was unguarded, which is a source of duplicated work and spurious
	// "Illegal declaration cycle" reports.
	if .Lazy in e.flags {
		append(&ctx.info.entities, e)
		sync.recursive_mutex_unlock(&ctx.info.lazy_mutex)
	}
}

get_type_and_value :: proc(ctx: ^Checker_Context, expr: ^ast.Node) -> Type_And_Value {
	// C++ Reference: expr->tav field access (parser.hpp)
	// In C++, this directly accesses expr->tav. In Odin, we use the type_and_value_map
	// with rawptr keys for pointer identity lookup.
	if expr == nil {
		return {}
	}
	if tv, found := tav_lookup(ctx.info, expr); found {
		return tv
	}
	return {}
}

// C++ Reference: check_decl.cpp:308-351
check_init_constant :: proc(ctx: ^Checker_Context, e: ^Entity, operand: ^Operand) {
	// C++ Reference: check_decl.cpp:309-316
	if operand.mode == .Invalid || operand.type == t_invalid || entity_type(e) == t_invalid {
		if entity_type(e) == nil {
			set_entity_type(e, t_invalid)
		}
		return
	}

	// C++ Reference: check_decl.cpp check_init_constant:318-323
	if operand.mode != .Constant {
		entity := entity_of_node(ctx.info, operand.expr)
		if check_try_override_const_decl(ctx, e, entity, cast(^ast.Expr)operand.expr, nil) {
			return
		}
	}

	// C++ Reference: check_decl.cpp check_init_constant:325-333
	if operand.mode != .Constant {
		str := expr_to_string(operand.expr)
		defer delete(str)
		error(operand.expr, "'%s' is not a compile-time known constant", str)
		if entity_type(e) == nil {
			set_entity_type(e, t_invalid)
		}
		return
	}

	// C++ Reference: check_decl.cpp check_init_constant:335-337
	if entity_type(e) == nil {
		// NOTE(bill): type inference
		set_entity_type(e, operand.type)
	}

	// C++ Reference: check_decl.cpp check_init_constant:339-342
	check_assignment(ctx, operand, entity_type(e), "constant declaration")
	if operand.mode == .Invalid {
		return
	}

	// C++ Reference: check_decl.cpp check_init_constant:344-346
	if is_type_proc(entity_type(e)) {
		error(e.token, "Illegal declaration of a constant procedure value")
	}

	// C++ Reference: check_decl.cpp check_init_constant:348
	e.parent_proc_decl = ctx.curr_proc_decl // Track parent procedure

	// C++ Reference: check_decl.cpp check_init_constant:350
	if constant, ok := &e.variant.(Entity_Constant); ok {
		constant.value = operand.value
	}
}

// C++ Reference: check_decl.cpp:622-768
check_const_decl :: proc(ctx: ^Checker_Context, e: ^Entity, type_expr: ^ast.Expr, init_expr: ^ast.Expr, named_type: ^Type) {
	// C++ Reference: check_decl.cpp:623-630
	assert(entity_type(e) == nil)
	assert(e.kind == .Constant)
	init := unparen_expr(init_expr)

	if e.flags & {.Visited} != {} {
		set_entity_type(e, t_invalid)
		return
	}
	e.flags += {.Visited}

	// C++ Reference: check_decl.cpp check_const_decl:633-641
	if type_expr != nil {
		set_entity_type(e, check_type(ctx, type_expr))
		if are_types_identical(entity_type(e), t_typeid) {
			set_entity_type(e, nil)
			e.kind = .Type_Name
			e.variant = Entity_Type_Name{}  // Update variant to match kind
			check_type_decl(ctx, e, cast(^ast.Expr)init, named_type)
			return
		}
	}

	operand := Operand{}

	// C++ Reference: check_decl.cpp check_const_decl:645-660
	if init != nil {
		entity := check_entity_from_ident_or_selector(ctx, cast(^ast.Expr)init, false)
		if check_override_as_type_due_to_aliasing(ctx, e, entity, cast(^ast.Expr)init, named_type) {
			return
		}
		entity = nil

		if _, ok := init.derived.(^ast.Ident); ok {
			entity = check_ident(ctx, &operand, init, nil, entity_type(e), true)
		} else if _, ok2 := init.derived.(^ast.Selector_Expr); ok2 {
			entity = check_selector(ctx, &operand, init, entity_type(e))
		} else {
			check_expr_or_type(ctx, &operand, init, entity_type(e))
			// C++ Reference: check_decl.cpp check_const_decl:662
			// Retrieve entity from call expression (set by builtin checking)
			if _, ok3 := init.derived.(^ast.Call_Expr); ok3 {
				entity = get_ast_entity(ctx.info, init)
			}
		}

		// C++ Reference: check_decl.cpp check_const_decl:662-705
		#partial switch operand.mode {
		case .Type:
			// C++ Reference: check_decl.cpp check_const_decl:663-666
			if entity_type(e) != nil && !is_type_typeid(entity_type(e)) {
				check_assignment(ctx, &operand, entity_type(e), "constant declaration")
			}

			// C++ Reference: check_decl.cpp check_const_decl:668-669
			e.kind = .Type_Name
			e.variant = Entity_Type_Name{}  // Update variant to match kind
			set_entity_type(e, nil)

			// C++ Reference: check_decl.cpp check_const_decl:671-683
			if entity != nil && entity_type(entity) != nil && is_type_polymorphic_record_unspecialized(entity_type(entity)) {
				decl := decl_info_of_entity(e)
				if decl != nil {
					if len(decl.attributes) > 0 {
						error(decl.attributes[0], "Constant alias declarations cannot have attributes")
					}
				}

				override_entity_in_scope(e, entity)
				return
			}
			check_type_decl(ctx, e, ctx.decl.init_expr, named_type)
			return

		// NOTE(bill): Check to see if the expression it to be aliases
		case .Builtin:
			// C++ Reference: check_decl.cpp check_const_decl:688-695
			if entity_type(e) != nil {
				error(type_expr, "A constant alias of a built-in procedure may not have a type initializer")
			}
			e.kind = .Builtin
			if op_builtin, ok := &e.variant.(Entity_Builtin); ok {
				op_builtin.id = operand.builtin_id
			} else {
				e.variant = Entity_Builtin {
					id = operand.builtin_id,
				}
			}
			set_entity_type(e, t_invalid)
			return

		case .Proc_Group:
			// C++ Reference: check_decl.cpp check_const_decl:697-704
			assert(operand.proc_group != nil)
			assert(operand.proc_group.kind == .Proc_Group)
			// NOTE(bill, 2020-06-10): It is better to just clone the contents than overriding the entity in the scope
			// Thank goodness I made entities a tagged union to allow for this implace patching
			e.kind = .Proc_Group
			if pg, ok := operand.proc_group.variant.(Entity_Proc_Group); ok {
				procs := make([dynamic]^Entity, 0, len(pg.procs), ctx.checker.allocator)
				append(&procs, ..pg.procs[:])
				e.variant = Entity_Proc_Group {
					procs = procs,
				}
			}
			return
		}

		// C++ Reference: check_decl.cpp check_const_decl:708-751
		if entity != nil {
			if entity_type(e) != nil {
				// C++ Reference: check_decl.cpp check_const_decl:710-730
				x := Operand{}
				x.type = entity_type(entity)
				x.mode = .Variable
				if entity.kind == .Constant {
					x.mode = .Constant
					x.value = entity.variant.(Entity_Constant).value
				}
				if !check_is_assignable_to(ctx, &x, entity_type(e)) {
					expr_str := expr_to_string(init)
					defer delete(expr_str)
					op_type_str := type_to_string(entity_type(entity))
					type_str := type_to_string(entity_type(e))
					error(e.token, "Cannot assign '%s' of type '%s' to '%s'", expr_str, op_type_str, type_str)
				}
			}

			// NOTE(bill): Override aliased entity
			// C++ Reference: check_decl.cpp check_const_decl:733-750
			#partial switch entity.kind {
			case .Proc_Group, .Procedure, .Library_Name, .Import_Name:
				decl := decl_info_of_entity(e)
				if decl != nil {
					if len(decl.attributes) > 0 {
						error(decl.attributes[0], "Constant alias declarations cannot have attributes")
					}
				}

				override_entity_in_scope(e, entity)
				return
			}
		}
	}

	// C++ Reference: check_decl.cpp check_const_decl:754
	check_init_constant(ctx, e, &operand)

	// C++ Reference: check_decl.cpp check_const_decl:756-761
	if operand.mode == .Invalid || base_type(operand.type) == t_invalid {
		str := expr_to_string(init)
		defer delete(str)
		error(init, "Invalid declaration value '%s'", str)
	}

	// C++ Reference: check_decl.cpp check_const_decl:764-767
	// Process attributes for constant declarations
	decl := decl_info_of_entity(e)
	if decl != nil && len(decl.attributes) > 0 {
		ac := Attribute_Context{}
		check_decl_attributes(ctx, decl.attributes[:], &ac, .Const)

		// C++ Reference: checker.cpp:4143-4163 (const_decl_attribute)
		// Error on attributes not valid for compile-time constants
		if ac.is_static {
			error(decl.attributes[0], "@(static) is not supported for compile time constant value declarations")
		}
		if ac.thread_local_model != "" {
			error(decl.attributes[0], "@(thread_local) is not supported for compile time constant value declarations")
		}
		if ac.require_declaration {
			error(decl.attributes[0], "@(require) is not supported for compile time constant value declarations")
		}
		if ac.linkage != "" {
			error(decl.attributes[0], "@(linkage) is not supported for compile time constant value declarations")
		}
		if ac.link_name != "" {
			error(decl.attributes[0], "@(link_name) is not supported for compile time constant value declarations")
		}
		if ac.link_prefix != "" {
			error(decl.attributes[0], "@(link_prefix) is not supported for compile time constant value declarations")
		}
		if ac.link_suffix != "" {
			error(decl.attributes[0], "@(link_suffix) is not supported for compile time constant value declarations")
		}
	}
}

// C++ Reference: check_expr.cpp:5374-5471
// NOTE(bill, 2022-02-03): see `check_const_decl` for why it exists reasoning
check_entity_from_ident_or_selector :: proc(ctx: ^Checker_Context, node: ^ast.Expr, ident_only: bool) -> ^Entity {
	if node == nil {
		return nil
	}

	// C++ Reference: check_expr.cpp:5395-5397
	if ident, ok := node.derived.(^ast.Ident); ok {
		name := ident.name
		return scope_lookup(ctx.scope, name)
	} else if !ident_only {
		// C++ Reference: check_expr.cpp:5398-5470
		if se, ok2 := node.derived.(^ast.Selector_Expr); ok2 {
			if se.op.kind == .Arrow_Right {
				return nil
			}

			op_expr := se.expr
			selector := unparen_expr(se.field)
			if selector == nil {
				return nil
			}

			sel_ident, is_ident := selector.derived.(^ast.Ident)
			if !is_ident {
				return nil
			}

			entity: ^Entity = nil
			expr_entity: ^Entity = nil
			check_op_expr := true

			if op_ident, ok3 := op_expr.derived.(^ast.Ident); ok3 {
				op_name := op_ident.name
				e := scope_lookup(ctx.scope, op_name)
				if e == nil {
					return nil
				}
				add_entity_use(ctx, op_expr, e)
				expr_entity = e

				if e != nil && e.kind == .Import_Name && is_ident {
					// IMPORTANT NOTE(bill): This is very sloppy code but it's also very fragile
					// It pretty much needs to be in this order and this way
					// If you can clean this up, please do but be really careful
					_ = op_name // import_name not used
					import_scope := e.variant.(Entity_Import_Name).scope
					entity_name := sel_ident.name

					check_op_expr = false
					entity = scope_lookup_current(import_scope, entity_name)

					allow_builtin := false
					if !is_entity_declared_for_selector(entity, import_scope, &allow_builtin) {
						return nil
					}

					check_entity_decl(ctx, entity, nil, nil)
					if entity != nil && entity.kind == .Proc_Group {
						return entity
					}
					// assert(entity.type != nil)
				}
			}

			operand := Operand{}
			if check_op_expr {
				check_expr_base(ctx, &operand, op_expr, nil)
				if operand.mode == .Invalid {
					return nil
				}
			}

			if entity == nil && is_ident {
				field_name := sel_ident.name
				// Initialize allocator type if accessing dynamic array fields
				// C++ Reference: check_expr.cpp:7636-7638
				if is_type_dynamic_array(type_deref(operand.type)) {
					init_mem_allocator(ctx.checker)
				}
				sel := lookup_field(ctx.checker, operand.type, field_name, operand.mode == .Type)
				entity = sel.entity
			}

			if entity != nil {
				return entity
			}
		}
	}
	return nil
}

// check_proc_decl performs procedure declaration checking
// C++ Reference: check_decl.cpp:1074-1609 (complete implementation)
//
// This function validates procedure declarations including:
// - Type checking and inference
// - Attribute processing (@test, @init, @fini, @foreign, etc.)
// - Foreign library linkage
// - Entry point detection
// - Polymorphic procedure validation
// - Body checking and deferred processing
check_proc_decl :: proc(ctx: ^Checker_Context, e: ^Entity, d: ^Decl_Info) {
	// C++ Reference: check_decl.cpp check_proc_decl:1259
	assert(e.type == nil)

	// C++ Reference: check_decl.cpp check_proc_decl:1260-1264
	if d.proc_lit == nil {
		// Ternary produces ^Proc_Lit vs Token mismatch - use proper if/else
		if d.proc_lit != nil {
			error_node(d.proc_lit, "Expected a procedure to check")
		} else {
			error(e.token, "Expected a procedure to check")
		}
		return
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1266-1271
	// Determine procedure type (either from gen_proc_type or allocate new)
	proc_type: ^Type
	if d.gen_proc_type != nil {
		proc_type = d.gen_proc_type
	} else {
		// alloc_type_proc signature: (scope, params ^Type, results ^Type, param_count int, result_count int, variadic bool, cc)
		// Create procedure type with no parameters or results
		proc_type = alloc_type_proc(scope = e.scope, params = nil, results = nil, param_count = 0, result_count = 0, variadic = false, calling_convention = default_calling_convention())
	}
	// Use set_entity_type to properly set the type in the Entity_Procedure variant
	// This is critical for entity_type() to return the correct procedure type
	set_entity_type(e, proc_type)

	// C++ Reference: check_decl.cpp check_proc_decl:1273
	pl := d.proc_lit

	// C++ Reference: check_decl.cpp check_proc_decl:1275-1277
	check_open_scope(ctx, pl.type)
	defer check_close_scope(ctx)
	ctx.scope.procedure = e

	// C++ Reference: check_decl.cpp check_proc_decl:1279
	decl_type: ^Type = nil

	// C++ Reference: check_decl.cpp check_proc_decl:1281-1288
	if d.type_expr != nil {
		decl_type = check_type_expr(ctx, d.type_expr, nil)
		if !is_type_proc(decl_type) {
			str := type_to_string(decl_type)
			error(d.type_expr, "Expected a procedure type, got '%s'", str)
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1291-1296
	tmp_ctx := ctx^
	tmp_ctx.allow_polymorphic_types = true
	if decl_type != nil {
		tmp_ctx.type_hint = decl_type
	}
	check_procedure_type(&tmp_ctx, proc_type, pl.type)

	// C++ Reference: check_decl.cpp check_proc_decl:1298-1316
	if decl_type != nil {
		x := Operand {
			type = e.type,
			mode = .Variable,
		}
		if !check_is_assignable_to(ctx, &x, decl_type) {
			expr_str := expr_to_string(d.proc_lit)
			op_type_str := type_to_string(e.type)
			type_str := type_to_string(decl_type)
			defer delete(expr_str)
			error(e.token, "Cannot assign '%s' of type '%s' to '%s'", expr_str, op_type_str, type_str)
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1319
	pt := &proc_type.variant.(Type_Proc)
	proc_variant := &e.variant.(Entity_Procedure)
	ac := make_attribute_context(proc_variant.link_prefix, proc_variant.link_suffix)

	if d != nil {
		check_decl_attributes(ctx, d.attributes, &ac, .Proc)
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1326-1335
	if ac.test {
		e.flags += {.Test}
	}
	// C++ Reference: check_decl.cpp check_proc_decl:1337-1339, `-disable-init-fini`.
	//
	// ORDERING, and why this sits BEFORE the chain rather than after it as C++ does.
	// C++ emits this at declaration time, but emits the init/fini VALIDATION (signature,
	// "contextless", file-scope, blank-ident) later, from generate_minimum_dependency_set_internal
	// at checker.cpp generate_minimum_dependency_set_internal:3013-3086 (init arm 3013-3049,
	// fini arm 3050-3086). Both land on e.token, and the same-position merge (#219) keeps the
	// FIRST -- so under the flag C++ shows only this message and the validation is invisible.
	// Measured, not assumed: with the flag, the oracle's "must have a signature type with no
	// parameters nor results" DISAPPEARS. It is not a phase bail -- an unrelated decl-stage error
	// at a DIFFERENT position (probe nd_ifgate2) leaves the validation visible.
	// The port relocated that validation to declaration time (#286), so both messages are now
	// emitted from this one function and source order alone decides the winner. Placed first to
	// reproduce C++'s precedence.
	//
	// Tests ac rather than e.flags (C++ tests the flags) because the flags are not set yet here.
	// Equivalent: the chain below sets .Init/.Fini in exactly the arms this condition selects, and
	// the both-init-and-fini arm sets NEITHER -- so that case reports only the contradiction, in
	// both compilers.
	if ctx.info.build_context != nil && ctx.info.build_context.disable_init_fini &&
	   (ac.init || ac.fini) && !(ac.init && ac.fini) {
		error(e.token, "@(init) and @(fini) have been disabled with '-disable-init-fini'")
	}
	if ac.init && ac.fini {
		error(e.token, "A procedure cannot be both declared as @(init) and @(fini)")
	} else if ac.init {
		// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3013-3049 (the @(init) arm).
		// The port validates at declaration time instead (generate_minimum_dependency_set does not
		// exist here -- task #272, scoped out);
		// every one of these is a property of the entity and its type, so the placement is
		// equivalent. The port previously had ONLY the signature check of the five.
		sig_ok := true
		if pt.param_count != 0 || pt.result_count != 0 {
			type_str := type_to_string(proc_type)
			error(e.token, "@(init) procedures must have a signature type with no parameters nor results, got %s", type_str)
			// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3015-3020 -- clears is_init
			// at :3019.
			sig_ok = false
		}
		eligible := check_init_fini_common(ctx, e, d, pt, "init", ac.disabled_proc)
		e.flags += {.Init}
		// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3046-3049. The port allocated info.init_procedures, sorted
		// it and de-duplicated it, but NEVER appended to it -- so the whole sort phase ran on a
		// permanently empty array. LEDGER #286.
		if sig_ok && eligible {
			append(&ctx.checker.info.init_procedures, e)
		}
	} else if ac.fini {
		// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3050-3086 - the @(fini) arm,
		// identical in shape.
		sig_ok := true
		if pt.param_count != 0 || pt.result_count != 0 {
			type_str := type_to_string(proc_type)
			error(e.token, "@(fini) procedures must have a signature type with no parameters nor results, got %s", type_str)
			// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3056-3061 -- clears is_fini.
			sig_ok = false
		}
		eligible := check_init_fini_common(ctx, e, d, pt, "fini", ac.disabled_proc)
		e.flags += {.Fini}
		// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3081-3084. See #286.
		if sig_ok && eligible {
			append(&ctx.checker.info.fini_procedures, e)
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1341-1344
	if ac.set_cold {
		e.flags += {.Cold}
	}
	proc_variant.optimization_mode = Procedure_Optimization_Mode(ac.optimization_mode)

	// C++ Reference: check_decl.cpp check_proc_decl:1346
	check_objc_methods(ctx, e, &ac)

	// C++ Reference: check_decl.cpp check_proc_decl:1349-1380
	// Target feature validation
	{
		if len(ac.require_target_feature) != 0 && len(ac.enable_target_feature) != 0 {
			error(e.token, "A procedure cannot have both @(require_target_feature=\"...\") and @(enable_target_feature=\"...\")")
		}

		// Access build_context.strict_target_features
		if ctx.info.build_context != nil && ctx.info.build_context.strict_target_features && len(ac.enable_target_feature) != 0 {
			ac.require_target_feature = ac.enable_target_feature
			ac.enable_target_feature = ""
		}

		if len(ac.require_target_feature) != 0 {
			pt.require_target_feature = ac.require_target_feature
			// C++: build_settings.cpp init_build_context:2067-2088
			valid, invalid := check_target_feature_is_valid_globally(ac.require_target_feature)
			if !valid {
				error(e.token, "Required target feature '%s' is not a valid target feature", invalid)
			}
			// Note: check_target_feature_is_enabled check skipped - requires target_features_set
			// which is populated by the frontend, not available in standalone checker
		} else if len(ac.enable_target_feature) != 0 {
			// NOTE: disallow wasm, features on that arch are always global to the module
			if is_arch_wasm() {
				error(e.token, "@(enable_target_feature=\"...\") is not allowed on wasm, features for wasm must be declared globally")
			}

			pt.enable_target_feature = ac.enable_target_feature
			// C++: build_settings.cpp init_build_context:2067-2088
			valid, invalid := check_target_feature_is_valid_globally(ac.enable_target_feature)
			if !valid {
				error(e.token, "Procedure enabled target feature '%s' is not a valid target feature", invalid)
			}
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1381-1386
	#partial switch proc_variant.optimization_mode {
	case .None:
		if pl.inlining == .Inline {
			error(e.token, "#force_inline cannot be used in conjunction with the attribute 'optimization_mode' with neither \"none\" nor \"minimal\"")
		}
	case:
	// Other optimization modes don't conflict with #force_inline
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1392-1396
	proc_variant.entry_point_only = ac.entry_point_only
	proc_variant.is_export = ac.is_export

	// C++ Reference: check_decl.cpp check_proc_decl:1398-1415
	// Instrumentation handling
	has_instrumentation := false
	if pl.body == nil {
		has_instrumentation = false
		if ac.no_instrumentation != .Default {
			error(e.token, "@(no_instrumentation) is not allowed on foreign procedures")
		}
	} else {
		// Check file-level #no_instrumentation directive
		// C++ Reference: check_decl.cpp check_proc_decl:1402-1403
		if ctx.file != nil {
			// File flag is stored directly on ast.File.flags
			has_instrumentation = .No_Instrumentation not_in ctx.file.flags
		}

		// Override with attribute if specified
		switch ac.no_instrumentation {
		case .Enabled:
			has_instrumentation = true
		case .Default: // Keep file-level default
		case .Disabled:
			has_instrumentation = false
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1442,1462 (both call sites)
	//
	// THE ONE LEGITIMATE MONOTONICITY INVERSION IN THIS PROCEDURE, recorded so a future audit does
	// not re-flag it. #608/#609 audited all 44 citations here by listing (port line, C++ line) in
	// PORT order and treating every backwards jump as a suspect -- 15 of 15 flagged that way turned
	// out to be genuinely wrong lines. This one is not: Odin requires a nested procedure to be
	// declared before use, so the helper sits here, ABOVE the enter/exit dispatch. C++ has no nested
	// definition at all -- is_valid_instrumentation_call is a free function elsewhere in the file,
	// and the only lines in check_proc_decl that mention it are the two CALLS at 1442 and 1462,
	// which come after :1312's 1435-1479. Declaration-before-use versus call-order, nothing more.
	// Instrumentation validation lambda
	is_valid_instrumentation_call :: proc(c: ^Checker, type: ^Type) -> bool {
		if type == nil || type.kind != .Proc {
			return false
		}
		pt := &type.variant.(Type_Proc)
		if pt.calling_convention != .Contextless {
			return false
		}
		if pt.result_count != 0 {
			return false
		}
		if pt.param_count != 3 {
			return false
		}
		params := &pt.params.variant.(Type_Tuple)
		p0 := params.variables[0].type
		p1 := params.variables[1].type
		p2 := params.variables[2].type
		return is_type_rawptr(p0) && is_type_rawptr(p1) && are_types_identical(p2, c.t_source_code_location)
	}

	instrumentation_proc_type_str :: "proc \"contextless\" (proc_address: rawptr, call_site_return_address: rawptr, loc: runtime.Source_Code_Location)"

	// C++ Reference: check_decl.cpp check_proc_decl:1435-1479
	if ac.instrumentation_enter && ac.instrumentation_exit {
		error(e.token, "A procedure cannot be marked with both @(instrumentation_enter) and @(instrumentation_exit)")
		has_instrumentation = false
		e.flags += {.Require}
	} else if ac.instrumentation_enter {
		init_core_source_code_location(ctx.checker)
		if !is_valid_instrumentation_call(ctx.checker, e.type) {
			s := type_to_string(e.type)
			error(e.token, "@(instrumentation_enter) procedures must have the type '%s', got %s", instrumentation_proc_type_str, s)
		}
		if e.scope != nil && (e.scope.flags & {.File, .Pkg}) == {} {
			error(e.token, "@(instrumentation_enter) procedures must be declared at the file scope")
		}
		// C++ Reference: check_decl.cpp check_proc_decl:1451 - MUTEX_GUARD(&ctx.info.instrumentation_mutex)
		sync.mutex_lock(&ctx.info.instrumentation_mutex)
		defer sync.mutex_unlock(&ctx.info.instrumentation_mutex)
		if ctx.info.instrumentation_enter_entity != nil {
			error(e.token, "@(instrumentation_enter) has already been set")
		} else {
			ctx.info.instrumentation_enter_entity = e
		}
		has_instrumentation = false
		e.flags += {.Require}
	} else if ac.instrumentation_exit {
		init_core_source_code_location(ctx.checker)
		if !is_valid_instrumentation_call(ctx.checker, e.type) {
			s := type_to_string(e.type)
			error(e.token, "@(instrumentation_exit) procedures must have the type '%s', got %s", instrumentation_proc_type_str, s)
		}
		if e.scope != nil && (e.scope.flags & {.File, .Pkg}) == {} {
			error(e.token, "@(instrumentation_exit) procedures must be declared at the file scope")
		}
		// C++ Reference: check_decl.cpp check_proc_decl:1470 - MUTEX_GUARD(&ctx.info.instrumentation_mutex)
		sync.mutex_lock(&ctx.info.instrumentation_mutex)
		defer sync.mutex_unlock(&ctx.info.instrumentation_mutex)
		if ctx.info.instrumentation_exit_entity != nil {
			error(e.token, "@(instrumentation_exit) has already been set")
		} else {
			ctx.info.instrumentation_exit_entity = e
		}
		has_instrumentation = false
		e.flags += {.Require}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1483-1489
	proc_variant.has_instrumentation = has_instrumentation
	proc_variant.no_sanitize_address = ac.no_sanitize_address
	proc_variant.no_sanitize_memory = ac.no_sanitize_memory
	proc_variant.no_sanitize_thread = ac.no_sanitize_thread   // C++ check_decl.cpp check_proc_decl:1485
	proc_variant.fast_math_flags = ac.fast_math_flags          // C++ check_decl.cpp check_proc_decl:1487

	e.deprecated_message = ac.deprecated_message
	e.warning_message = ac.warning_message
	ac.link_name = handle_link_name(ctx, e.token, ac.link_name, ac.link_prefix, ac.link_suffix)

	// C++ Reference: check_decl.cpp check_proc_decl:1493-1495. The port stored link_section on VARIABLES only
	// (check_decl.odin:311); procedures dropped it.
	if len(ac.link_section) > 0 {
		proc_variant.link_section = ac.link_section
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1497-1506
	if ac.has_disabled_proc {
		if ac.disabled_proc {
			e.flags += {.Disabled}
		}
		t := base_type(e.type)
		assert(t.kind == .Proc)
		if pt.result_count != 0 {
			error(e.token, "Procedure with the 'disabled' attribute may not have any return values")
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1509-1522
	is_foreign := proc_variant.is_foreign
	is_export := proc_variant.is_export

	if len(ac.linkage) != 0 {
		if ac.linkage == "internal" {
			e.flags += {.Custom_Linkage_Internal}
		} else if ac.linkage == "strong" {
			e.flags += {.Custom_Linkage_Strong}
		} else if ac.linkage == "weak" {
			e.flags += {.Custom_Linkage_Weak}
		} else if ac.linkage == "link_once" {
			e.flags += {.Custom_Linkage_Link_Once}
		}

		if is_foreign && .Custom_Linkage_Internal in e.flags {
			error(e.token, "A foreign procedure may not have an \"internal\" linkage")
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1523-1526
	if ac.require_declaration {
		e.flags += {.Require}
		// Note: C++ sets pl.inlining = ProcInlining_no_inline here, but in Odin
		// the AST is immutable. The backend should check for .Require flag
		// and disable inlining accordingly.
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1529-1565
	// Entry point (main) detection
	if e.pkg != nil && e.token.text == "main" {
		// Check if entry point is enabled (skip if no_entry_point flag is set)
		if ctx.info.build_context != nil && !ctx.info.build_context.no_entry_point {
			if e.pkg.kind != .Runtime {
				if pt.param_count != 0 || pt.result_count != 0 {
					str := type_to_string(proc_type)
					error(e.token, "Procedure type of 'main' was expected to be 'proc()', got %s", str)
				}
				// C++ Reference: check_decl.cpp check_proc_decl:1537-1556. The port had ONLY the `else` arm --
				// under `-bedrock` it applied the non-bedrock rule, which is both the wrong
				// message and the wrong RULE: bedrock accepts "odin" OR "contextless", where
				// default_calling_convention() is a single value.
				if ctx.info.build_context != nil && ctx.info.build_context.bedrock {
					#partial switch pt.calling_convention {
					case .Odin, .Contextless:
						// Okay
					case:
						error(e.token, "Procedure 'main' cannot have a custom calling convention beyond \"odin\" and \"contextless\" with '-bedrock'")
						// C++ recovers to Odin, NOT to default_calling_convention().
						pt.calling_convention = .Odin
					}
				} else {
					if pt.calling_convention != default_calling_convention() {
						error(e.token, "Procedure 'main' cannot have a custom calling convention")
					}
					pt.calling_convention = default_calling_convention()
				}
				if e.pkg.kind == .Init {
					if ctx.info.entry_point != nil {
						error(e.token, "Redeclaration of the entry pointer procedure 'main'")
					} else {
						ctx.info.entry_point = e
					}
				}
			}
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1567-1569
	if is_foreign && is_export {
		error(pl.type, "A foreign procedure cannot have an 'export' tag")
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1571-1579
	if pt.is_polymorphic {
		if pl.body == nil {
			error(e.token, "Polymorphic procedures must have a body")
		}

		if is_foreign {
			error(e.token, "A foreign procedure cannot be a polymorphic")
			return
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1582-1602
	if pl.body != nil {
		if is_foreign {
			error(pl.body, "A foreign procedure cannot have a body")
		}
		// NO c_vararg body check here. C++ check_decl.cpp check_proc_decl:1587-1589 has that error COMMENTED OUT,
		// so the reference accepts a `#c_vararg` procedure with a body and reports at the USE
		// instead (check_expr.cpp check_ident:2004, ported into check_expr's Ident arm). The port had it live,
		// which rejected code the reference compiles. Third instance of this family after #171
		// and #333 -- the port faithfully reproducing something C++ disabled.

		d.scope = ctx.scope

		assert(pl.body != nil) // Validate it's a block statement
		if !pt.is_polymorphic {
			// Create Proc_Info for deferred procedure checking
			// C++ Reference: check_decl.cpp check_proc_decl:1592
			// The body must be a Block_Stmt
			body_block, body_ok := pl.body.derived.(^ast.Block_Stmt)
			if !body_ok {
				error(e.token, "Procedure body must be a block statement")
			} else {
				info := new(Proc_Info)
				info.file = ctx.file
				info.token = e.token
				info.decl = d
				info.type = proc_type
				info.body = body_block
				info.tags = u64(transmute(u32)pl.tags)
				check_procedure_later(ctx.checker, info)
			}
		}
	// C++ Reference: check_decl.cpp check_proc_decl:1596-1601
	// Allow body-less procedures for foreign or Objective-C imported methods
	} else if !is_foreign && !proc_variant.is_objc_impl_or_import {
		if proc_variant.is_export {
			error(e.token, "Foreign export procedures must have a body")
		} else {
			error(e.token, "Only a foreign procedure cannot have a body")
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1604-1612
	if ac.require_results {
		if pt.result_count == 0 {
			error(pl.type, "'require_results' is not needed on a procedure with no results")
		} else {
			pt.require_results = true
		}
	} else if d.foreign_require_results && pt.result_count != 0 {
		pt.require_results = true
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1614-1623
	if len(ac.link_name) > 0 {
		ln := ac.link_name
		proc_variant.link_name = ln
		if ln == "memcpy" || ln == "memmove" || ln == "mem_copy" || ln == "mem_copy_non_overlapping" {
			proc_variant.is_memcpy_like = true
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1625-1628
	if ac.deferred_procedure.entity != nil {
		proc_variant.deferred_procedure = ac.deferred_procedure
		queue.mpsc_enqueue(&ctx.checker.procs_with_deferred_to_check, e)
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1630-1645
	if is_foreign {
		name := e.token.text
		if len(proc_variant.link_name) > 0 {
			name = proc_variant.link_name
		}
		foreign_library := init_entity_foreign_library(ctx, e)
		proc_variant.is_foreign = true
		proc_variant.link_name = name
		proc_variant.foreign_library = foreign_library

		if is_arch_wasm() && foreign_library != nil {
			// NOTE: this must be delayed because the foreign import paths might not be evaluated yet
			queue.mpsc_enqueue(&ctx.info.foreign_decls_to_check, e)
		} else {
			check_foreign_procedure(ctx, e, d)
		}
	} else {
		name := e.token.text
		if len(proc_variant.link_name) > 0 {
			name = proc_variant.link_name
		}
		if len(proc_variant.link_name) > 0 || is_export {
			// C++ Reference: check_decl.cpp check_proc_decl:1652 - mutex_lock/unlock(&ctx.info.foreign_mutex)
			sync.mutex_lock(&ctx.info.foreign_mutex)
			defer sync.mutex_unlock(&ctx.info.foreign_mutex)

			// Foreign procedure name uniqueness check (C++ uses foreigns map)
			fp := &ctx.info.foreigns
			if found := fp[name]; found != nil {
				pos := token_pos_to_string(found.token.pos)
				error(d.proc_lit, "Non unique linking name for procedure '%s'\n\tother at %s", name, pos)
			} else if name == "main" {
				if e.pkg != nil && e.pkg.kind != .Runtime {
					error(d.proc_lit, "The link name 'main' is reserved for internal use")
				}
			} else {
				fp[name] = e
			}
		}
	}

	// C++ Reference: check_decl.cpp check_proc_decl:1677-1679
	if len(proc_variant.link_name) > 0 {
		e.flags += {.Custom_Link_Name}
	}
}

// C++ Reference: check_decl.cpp:1760-1895
check_proc_group_decl :: proc(ctx: ^Checker_Context, pg_entity: ^Entity, d: ^Decl_Info) {
	// C++ Reference: check_decl.cpp:1761-1763
	assert(pg_entity.kind == .Proc_Group)
	pge := &pg_entity.variant.(Entity_Proc_Group)
	proc_group_name := pg_entity.token.text

	// C++ Reference: check_decl.cpp:1765
	#partial switch init in d.init_expr.derived {
	case ^ast.Proc_Group:
		pg := init

		// C++ Reference: check_decl.cpp:1767
		// pge.entities allocated from permanent_allocator in C++
		// In Odin, use checker allocator for entity lifetime management
		procs := make([dynamic]^Entity, 0, len(pg.args), ctx.checker.allocator)

		// C++ Reference: check_decl.cpp:1770-1771
		// NOTE(bill): This must be set here to prevent cycles in checking
		// if someone places the entity within itself
		set_entity_type(pg_entity, t_invalid)

		// C++ Reference: check_decl.cpp:1773-1774
		// Track entities to detect duplicates
		entity_set := make(map[^Entity]bool, allocator = context.temp_allocator)
		defer delete(entity_set)

		// C++ Reference: check_decl.cpp:1776-1805
		for arg_ in pg.args {
			arg := arg_
			e: ^Entity = nil
			o := Operand{}

			// C++ Reference: check_decl.cpp check_proc_group_decl:1856-1870 - `member where COND`.
			//
			// Both parsers represent this as a Binary_Expr whose operator token is `where`
			// (parser.cpp:2534-2538, and core/odin/parser/parser.odin:2566-2573 does the same), so
			// no AST node is needed - but this loop never unwrapped it and reported "Expected a
			// valid entity name in procedure group, got binary expression". One such member damages
			// the whole group, and base:runtime uses the form six times
			// (`delete_map where MAP_ENABLED` and friends), which is why `make` and `delete` could
			// not resolve.
			if be, is_be := arg.derived.(^ast.Binary_Expr); is_be && be.op.kind == .Where {
				cond := Operand{}
				check_expr(ctx, &cond, be.right)
				if cond.mode != .Invalid {
					is_bool_const := false
					if cond.mode == .Constant && is_type_boolean(cond.type) {
						if _, bok := cond.value.(bool); bok {
							is_bool_const = true
						}
					}
					if !is_bool_const {
						error(arg, "Expected a constant binary expression for the 'where' clause")
					} else if b, _ := cond.value.(bool); !b {
						// Condition is false: the member is excluded from the group.
						continue
					}
				}
				arg = be.left
			}

			// C++ Reference: check_decl.cpp:1779-1783
			if _, ok := arg.derived.(^ast.Ident); ok {
				e = check_ident(ctx, &o, arg, nil, nil, true)
			} else if _, ok2 := arg.derived.(^ast.Selector_Expr); ok2 {
				e = check_selector(ctx, &o, arg, nil)
			}

			// C++ Reference: check_decl.cpp:1784-1787
			if e == nil {
				// Provide helpful error message with AST node type information
				// C++ uses ast_strings[arg->kind] to show the node kind
				// In Odin, we identify the node type from the tagged union variant
				node_type_name := "unknown"
				#partial switch _ in arg.derived {
				case ^ast.Ident: node_type_name = "identifier"
				case ^ast.Selector_Expr: node_type_name = "selector expression"
				case ^ast.Call_Expr: node_type_name = "call expression"
				case ^ast.Paren_Expr: node_type_name = "parenthesized expression"
				case ^ast.Unary_Expr: node_type_name = "unary expression"
				case ^ast.Binary_Expr: node_type_name = "binary expression"
				case: node_type_name = "expression"
				}
				error(arg, "Expected a valid entity name in procedure group, got %s", node_type_name)
				continue
			}

			// C++ Reference: check_decl.cpp:1788-1798
			if e.kind == .Variable {
				if !is_type_proc(entity_type(e)) {
					s := type_to_string(entity_type(e))
					error(arg, "Expected a procedure, got %s", s)
					continue
				}
			} else if e.kind != .Procedure {
				error(arg, "Expected a procedure entity")
				continue
			}

			// C++ Reference: check_decl.cpp:1800-1803
			if e in entity_set {
				error(arg, "Previous use of `%s` in procedure group", e.token.text)
				continue
			}
			entity_set[e] = true
			append(&procs, e)
		}

		// C++ Reference: check_decl.cpp:1809-1888
		// Validate overload safety between all procedure pairs
		for j in 0 ..< len(procs) {
			p := procs[j]
			if entity_type(p) == t_invalid {
				// NOTE(bill): This invalid overload has already been handled
				continue
			}

			if .Disabled in p.flags {
				continue
			}

			name := p.token.text

			for k in j + 1 ..< len(procs) {
				q := procs[k]
				assert(p != q)

				is_invalid := false
				pos := q.token.pos

				if entity_type(q) == nil || entity_type(q) == t_invalid {
					continue
				}

				// C++ Reference: check_decl.cpp check_proc_group_decl:1927. Noted as a comment but never opened,
				// so the "previous procedure at" line below never reached the output.
				begin_error_block()
				defer end_error_block()

				if .Disabled in q.flags {
					continue
				}

				// C++ Reference: check_decl.cpp check_proc_group_decl:1841
				kind := are_proc_types_overload_safe(entity_type(p), entity_type(q))
				both_have_where_clauses := false

				// C++ Reference: check_decl.cpp check_proc_group_decl:1842-1853
				if p.decl_info != nil && q.decl_info != nil && p.decl_info.proc_lit != nil && q.decl_info.proc_lit != nil {
					if pl, ok := p.decl_info.proc_lit.derived.(^ast.Proc_Lit); ok {
						if ql, ok2 := q.decl_info.proc_lit.derived.(^ast.Proc_Lit); ok2 {
							// Allow collisions if both have 'where' clauses and are polymorphic
							pw := pl.where_token.kind != .Invalid && is_type_polymorphic(entity_type(p), true)
							qw := ql.where_token.kind != .Invalid && is_type_polymorphic(entity_type(q), true)
							both_have_where_clauses = pw && qw
						}
					}
				}

				// C++ Reference: check_decl.cpp check_proc_group_decl:1855-1881
				if !both_have_where_clauses {
					#partial switch kind {
					case .Identical:
						error(p.token, "Overloaded procedure '%s' has the same type as another procedure in the procedure group '%s'", name, proc_group_name)
						is_invalid = true

					case .Param_Variadic:
						error(p.token, "Overloaded procedure '%s' has the same type as another procedure in the procedure group '%s'", name, proc_group_name)
						is_invalid = true

					case .Result_Count, .Result_Types:
						error(p.token, "Overloaded procedure '%s' has the same parameters but different results in the procedure group '%s'", name, proc_group_name)
						is_invalid = true

					case .Polymorphic:
						// Polymorphic overloads are handled by where clauses
						break

					case .Param_Count, .Param_Types, .Target_Features:
						// These are valid overload distinctions
						break
					}
				}

				// C++ Reference: check_decl.cpp check_proc_group_decl:1883-1886
				if is_invalid {
					pos_str := token_pos_to_string(pos)
					error_line("\tprevious procedure at %s\n", pos_str)
					set_entity_type(q, t_invalid)
				}
			}
		}

		pge.procs = procs

	case:
		error(d.init_expr, "Expected a procedure group literal")
		return
	}

	// C++ Reference: check_decl.cpp check_proc_group_decl:1890-1892
	ac := Attribute_Context{}
	check_decl_attributes(ctx, d.attributes, &ac, .Proc_Group)
	check_objc_methods(ctx, pg_entity, &ac)
}

// check_feature_flags retrieves opt-in feature flags for the current context
// C++ Reference: checker.cpp:559-592
check_feature_flags :: proc(ctx: ^Checker_Context, node: ^ast.Node) -> Opt_In_Feature_Flag {
	file: ^ast.File = ctx.file

	// C++ Reference: checker.cpp check_feature_flags:567-570 -- fall back to the current procedure literal's file.
	if file == nil && ctx.curr_proc_decl != nil && ctx.curr_proc_decl.proc_lit != nil {
		file = get_file_from_node(&ctx.checker.info, ctx.curr_proc_decl.proc_lit)
	}

	// C++ Reference: checker.cpp check_feature_flags:572-574 -- `file = node->file()`. The port was MISSING this
	// third fallback, and a stale comment here claimed Odin's AST has no node->file mapping.
	// It does: get_file_from_node resolves through `node.pos.file`, which the tokenizer stamps
	// on every position. Without it, `#+feature` lines were invisible from inside statement
	// checking, so every feature-gated check silently read as "not opted in" (LEDGER task 243).
	if file == nil && node != nil {
		file = get_file_from_node(&ctx.checker.info, node)
	}

	// Check if file has feature flags set
	// C++ Reference: checker.cpp check_feature_flags:569-571
	if file != nil && file.feature_flags_set {
		// Convert ast.Feature_Flags to Opt_In_Feature_Flag
		// Both have the same underlying bit values (u64 bitset with same enum indices)
		return transmute(Opt_In_Feature_Flag)file.feature_flags
	}

	return {}
}

// Opt_In_Feature_Flag is defined in build_settings.odin

// Note: error() proc group is defined in error.odin
// Note: set_base_type() is defined in check_type.odin
// Signatures: error_pos(pos, fmt, args...), error_token(token, fmt, args...), error_node(node, fmt, args...)

///////////////////////////////////////////////////////////////////////////////
// Foreign Import Validation
// C++ Reference: checker.cpp:5490-5545, 5382-5488, 5068-5130
///////////////////////////////////////////////////////////////////////////////

// AST State Flag Helpers
// C++ stores state_flags directly on AST nodes (parser.hpp: Ast.state_flags)
// Since core:odin/ast is immutable, we use external map in Checker_Info

get_ast_state_flag :: proc(info: ^Checker_Info, node: ^ast.Node, flag: State_Flag) -> bool {
	key := rawptr(node)
	if flags, ok := info.ast_state_flags[key]; ok {
		return flag in flags
	}
	return false
}

set_ast_state_flag :: proc(info: ^Checker_Info, node: ^ast.Node, flag: State_Flag) {
	key := rawptr(node)
	if flags, ok := &info.ast_state_flags[key]; ok {
		flags^ += {flag}
	} else {
		info.ast_state_flags[key] = {flag}
	}
}

clear_ast_state_flag :: proc(info: ^Checker_Info, node: ^ast.Node, flag: State_Flag) {
	key := rawptr(node)
	if flags, ok := &info.ast_state_flags[key]; ok {
		flags^ -= {flag}
	}
}

// path_to_entity_name is defined in entity_helpers.odin

// Helper: Check if identifier is blank (_)
// check_init_fini_common applies the three validations C++ runs identically for @(init) and
// @(fini) beyond the signature check: the contextless requirement, the file-scope requirement,
// and the blank-identifier ban. The `disabled` warning is included too.
//
// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3009-3049 (@(init)) and :3050-3085 (@(fini)). The two arms are
// literal duplicates in C++ apart from the attribute name in each message, so they are
// factored here and the name is passed in.
// RETURNS whether the entity is still eligible for registration in info.init_procedures /
// info.fini_procedures -- C++'s `is_init` / `is_fini` local. C++ clears it on the signature
// error (raised at the CALL SITE here), on the file-scope error, and -- for @(init) only -- when
// the procedure is disabled. The blank-identifier error does NOT clear it. LEDGER #286.
check_init_fini_common :: proc(ctx: ^Checker_Context, e: ^Entity, d: ^Decl_Info, pt: ^Type_Proc, kind: string, is_disabled: bool) -> (eligible: bool) {
	eligible = true
	if e == nil || pt == nil {
		return false
	}

	// "contextless" is required unless the file opted into `#+feature global-context`.
	// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3022-3029
	feature_flags: Opt_In_Feature_Flag
	if d != nil {
		feature_flags = check_feature_flags(ctx, cast(^ast.Node)d.decl_node)
	}
	if feature_flags & {.Global_Context} == {} {
		if pt.calling_convention != .Contextless {
			// begin/end_error_block is the port's ERROR_BLOCK(). Without it the buffered
			// `error` and the immediate `error_line` come out in the WRONG ORDER -- the
			// suggestion prints before the error it belongs to. Same asymmetry as task 192.
			begin_error_block()
			error(e.token, "@(%s) procedures must be declared as \"contextless\"", kind)
			error_line("\tSuggestion: this can be bypassed, for the time being, with '#+feature global-context'")
			end_error_block()
		}
	}

	// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3031-3034 -- reports AND clears is_init.
	if e.scope != nil && .File not_in e.scope.flags && .Pkg not_in e.scope.flags {
		error(e.token, "@(%s) procedures must be declared at the file scope", kind)
		eligible = false
	}

	// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3036-3039. INIT ONLY -- this is the one place the two arms
	// differ. C++'s @(init) arm has this block; the @(fini) arm (checker.cpp generate_minimum_dependency_set_internal:3050-3085) has no
	// disabled handling whatsoever. Sharing it unconditionally made the port emit
	// "This @(fini) procedure is disabled; you must call it manually" on valid code the oracle
	// accepts silently -- a genuine OVER-WARNING. Probe finidis. LEDGER #282.
	//
	// Read from the attribute context, NOT from e.flags: C++ runs this in a later pass where
	// the flag is already set, but at declaration time `e.flags += {.Disabled}` has not
	// happened yet (it is set further down this same procedure).
	//
	// C++ also sets `is_init = false` here, keeping a disabled @(init) out of
	// info.init_procedures (checker.cpp generate_minimum_dependency_set_internal:3036-3039). That is now modelled: it was previously
	// left out because no instrument could observe registration, which triage_doc fixed.
	// LEDGER #286. Note this clearing is INIT-ONLY, like the warning -- C++'s fini arm has no
	// disabled handling at all, so a disabled @(fini) IS still registered.
	if is_disabled && kind == "init" {
		warning(e.token, "This @(%s) procedure is disabled; you must call it manually", kind)
		eligible = false
	}

	// C++ Reference: checker.cpp generate_minimum_dependency_set_internal:3041-3043. Reports but does NOT clear is_init -- a blank-named
	// @(init) is still registered in C++.
	if is_blank_ident(e.token.text) {
		error(e.token, "An @(%s) procedure must not use a blank identifier as its name", kind)
	}

	return eligible
}

is_blank_ident :: proc(name: string) -> bool {
	return name == "_"
}

// Node form of is_blank_ident, matching C++'s overload (parser.cpp:1750).
is_blank_ident_node :: proc(node: ^ast.Node) -> bool {
	if node == nil {
		return false
	}
	if ident, ok := node.derived.(^ast.Ident); ok {
		return is_blank_ident(ident.name)
	}
	return false
}

// Alias for compatibility
is_blank_ident_string :: is_blank_ident

// Helper: Validate if string is a valid Odin identifier
// C++ Reference: is_string_an_identifier in checker.cpp:5022
is_valid_identifier :: proc(name: string) -> bool {
	if len(name) == 0 {
		return false
	}

	// First character must be letter or underscore
	first := rune(name[0])
	if !(first == '_' || (first >= 'a' && first <= 'z') || (first >= 'A' && first <= 'Z')) {
		return false
	}

	// Remaining characters must be letters, digits, or underscores
	for i in 1 ..< len(name) {
		c := rune(name[i])
		if !(c == '_' || (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9')) {
			return false
		}
	}

	return true
}

// check_foreign_import_attributes processes attributes for foreign import declarations
// C++ Reference: check_decl_attributes in checker.cpp:4227
//                foreign_import_decl_attribute callback in checker.cpp:5513-5541
check_foreign_import_attributes :: proc(ctx: ^Checker_Context, attributes: []^ast.Attribute, ac: ^Attribute_Context) {
	// This processes attributes specific to foreign import declarations
	// Supported attributes (C++ line 5528-5541):
	// - @(require) - force inclusion even if not directly referenced
	// - @(extra_linker_flags="...") - pass additional flags to linker
	// - @(ignore_duplicates) - don't error on duplicate library names
	// - @(foreign_import_priority=N) - control link order
	// - @(export) - re-export library from this package

	for attr in attributes {
		// C++ Reference: checker.cpp:5351-5391 - foreign_import_decl_attribute callback
		// Iterate through attribute elements
		for elem in attr.elems {
			#partial switch a in elem.derived {
			case ^ast.Ident:
				// Simple attribute like @(require), @(export), @(ignore_duplicates)
				// C++ Reference: checker.cpp:5361-5376
				name := a.name
				if name == "require" {
					ac.require_declaration = true
				} else if name == "export" {
					ac.is_export = true
				} else if name == "ignore_duplicates" {
					ac.ignore_duplicates = true
				}
			case ^ast.Field_Value:
				// Attribute with value like @(extra_linker_flags="...") or @(priority_index=N)
				// C++ Reference: checker.cpp:5377-5384 (extra_linker_flags)
				//                checker.cpp:5366-5375 (priority_index)
				if field_name, ok := a.field.derived.(^ast.Ident); ok {
					// Evaluate the value expression to a constant
					// C++ Reference: checker.cpp:3410-3423 (check_decl_attribute_value)
					value := a.value
					o := Operand{}
					check_expr(ctx, &o, value)

					name := field_name.name

					// Handle different attribute types based on name
					switch name {
					case "extra_linker_flags":
						// C++ Reference: checker.cpp:5377-5384
						if o.mode == .Constant && is_type_string(o.type) {
							if str_val, ok2 := o.value.(string); ok2 {
								ac.extra_linker_flags = str_val
							} else {
								error(elem, "Expected a string value for 'extra_linker_flags'")
							}
						} else if o.mode != .Invalid {
							error(elem, "Expected a string value for 'extra_linker_flags'")
						}

					case "priority_index", "foreign_import_priority":
						// C++ Reference: checker.cpp:5366-5375
						if o.mode == .Constant && is_type_integer(o.type) {
							// Extract integer from big.Int
							if big_int, ok2 := o.value.(big.Int); ok2 {
								// Convert big.Int to i64
								int_val, err := big.int_get_i64(&big_int)
								if err == nil {
									ac.foreign_import_priority = int_val
								} else {
									error(elem, "Integer value for '%s' out of range", name)
								}
							} else {
								error(elem, "Expected an integer value for '%s'", name)
							}
						} else if o.mode != .Invalid {
							error(elem, "Expected an integer value for '%s'", name)
						}
					}
				}
			}
		}
	}
}

// check_add_foreign_import_decl processes foreign import declarations
// C++ Reference: checker.cpp:5490-5545
//
// Handles foreign library imports like:
//   foreign import lib "system:library.lib"
//   foreign import custom "path/to/lib.a"
//
// Creates library entity and queues for fullpath resolution
// check_add_foreign_import_decl is defined in check_collect.odin

// check_foreign_import_fullpaths resolves library paths for all queued foreign imports
// C++ Reference: checker.cpp:5382-5488
//
// Processes the foreign_imports_to_check_fullpaths queue:
// - Evaluates path expressions to constant strings
// - Resolves relative paths to absolute paths
// - Validates library files exist
// - Stores resolved paths in Entity_Library_Name.paths
check_foreign_import_fullpaths :: proc(ctx: ^Checker_Context) {
	// Process all queued foreign imports (C++ line 5388)
	for {
		entity, ok := queue.mpsc_dequeue(&ctx.info.foreign_imports_to_check_fullpaths)
		if !ok do break

		assert(entity.kind == .Library_Name, "Expected library entity")

		lib := &entity.variant.(Entity_Library_Name)
		decl, decl_ok := lib.decl.derived.(^ast.Foreign_Import_Decl)
		if !decl_ok {
			// Not a foreign import decl, skip
			continue
		}

		// Get file context for path resolution
		// C++ Reference: checker.cpp check_foreign_import_fullpaths:5728-5734 - `AstFile *f = decl->file();
		// reset_checker_context(&ctx, f, &untyped);` followed by
		// `String base_dir = dir_from_path(decl->file()->fullpath);`
		//
		// The context must be re-pointed at the file that owns *this* declaration: the queue
		// is filled from every file in the program, so the caller's file/scope says nothing
		// about the entry being processed. The path expressions below are checked in this
		// file's scope, and relative library paths resolve against this file's directory.
		decl_file := get_file_from_node(ctx.info, lib.decl)
		if decl_file != nil {
			reset_checker_context(ctx, decl_file)
		}
		// C++ line 5734: GB_ASSERT(ctx.scope == e->scope);
		base_dir := ""
		if decl_file != nil {
			// NOTE: filepath.dir does not allocate - the result is a substring of the file's
			// fullpath, which outlives this scope.
			base_dir = filepath.dir(decl_file.fullpath)
		}

		// Evaluate path expressions to strings (C++ line 5401-5435)
		// NOTE: this array outlives the loop iteration - `lib.paths` below aliases its backing
		// storage and is read for the rest of the checker's life (and by the linker driver).
		// C++ allocates it from permanent_allocator() for the same reason (checker.cpp check_foreign_import_fullpaths:5738).
		fullpaths := make([dynamic]string, 0, len(decl.fullpaths), ctx.checker.allocator)

		for fp_expr in decl.fullpaths {
			// Evaluate expression to constant string (C++ line 5407-5420)
			// Try to evaluate as constant expression using check_expr
			o := Operand{}
			check_expr_base(ctx, &o, fp_expr, nil)

			file_str := ""

			// Check if expression evaluated to a constant string (C++ line 5413-5420)
			if o.mode == .Invalid {
				error_node(fp_expr, "Foreign library path must be a valid expression")
				continue
			}

			// C++ requires constant string values (line 5415-5420)
			if o.mode != .Constant {
				error_node(fp_expr, "Expected a constant string value for library path")
				continue
			}

			if !is_type_string(o.type) {
				str := type_to_string(o.type)
				error_node(fp_expr, "Expected a constant string value, got value of type '%s'", str)
				continue
			}

			// Extract string value from exact value (C++ line 5422)
			#partial switch v in o.value {
			case string:
				file_str = v
			case:
				error_node(fp_expr, "Expected a constant string value for library path")
				continue
			}

			file_str = strings.trim_space(file_str)

			// Validate library path not empty (C++ line 5423)
			if len(file_str) == 0 {
				error_node(fp_expr, "Foreign library path cannot be empty")
				continue
			}

			// Resolve path (C++ line 5425-5431)
			fullpath := file_str

			// A `system:` library is named, not located - see below. Tracked separately so
			// the path normalisation at the end of the loop leaves it alone.
			is_system_library := false

			// Check for special collections (e.g., "system:library")
			// C++ Reference: determine_path_from_string in build_settings.cpp
			colon_idx := strings.index_byte(file_str, ':')
			if colon_idx > 0 {
				collection_name := file_str[:colon_idx]

				// Has a colon - could be collection path or Windows drive letter
				// Windows drive letters are single character (e.g., "C:\path")
				if colon_idx == 1 && len(file_str) > 2 && file_str[2] == '\\' {
					// Windows absolute path with drive letter - not a collection
					fullpath = file_str
				} else if collection_name == "system" {
					// The 'system' collection is reserved for 'foreign import' and is
					// deliberately NOT resolved against a directory: what follows the colon
					// is a system library name handed to the linker as-is ("system:c" ->
					// -lc), so there is nothing on disk to look up and no base_dir to join
					// against. Resolving it would both fabricate a bogus path and, since
					// library_collections is currently never populated, report every
					// `foreign import "system:..."` in core and vendor (321 of them) as an
					// unknown collection.
					// C++ Reference: parser.cpp determine_path_from_string - `if
					// (collection_name == "system") { *path = file_str; return true; }`,
					// guarded so that only Ast_ForeignImportDecl may use it.
					is_system_library = true
					fullpath = file_str[colon_idx + 1:]
				} else {
					// Collection path format: "collection:path/to/lib"
					lib_path := file_str[colon_idx + 1:]

					// Look up collection path
					if collection_path, found := find_library_collection_path(collection_name); found {
						// Join collection path with library path
						joined, join_err := filepath.join({collection_path, lib_path}, context.temp_allocator)
						if join_err != nil {
							error_node(fp_expr, "Failed to resolve foreign library path '%s'", file_str)
							continue
						}
						fullpath = joined
					} else {
						// Unknown collection - report error but continue with original path
						error_node(fp_expr, "Unknown library collection '%s'", collection_name)
						fullpath = file_str
					}
				}
			} else if len(base_dir) > 0 && !filepath.is_abs(file_str) {
				// Relative path - resolve relative to source file
				joined, join_err := filepath.join({base_dir, file_str}, context.temp_allocator)
				if join_err != nil {
					error_node(fp_expr, "Failed to resolve foreign library path '%s'", file_str)
					continue
				}
				fullpath = joined
			}

			// Normalize path (convert to absolute if possible)
			// C++ uses determine_path_from_string (line 5427-5430)
			if !is_system_library && !strings.contains(fullpath, ":") && !filepath.is_abs(fullpath) && len(base_dir) > 0 {
				joined, join_err := filepath.join({base_dir, fullpath}, context.temp_allocator)
				if join_err != nil {
					error_node(fp_expr, "Failed to resolve foreign library path '%s'", file_str)
					continue
				}
				fullpath = joined
			}

			append(&fullpaths, strings.clone(fullpath, ctx.checker.allocator))
		}

		// Validate file extensions (C++ line 5437-5450)
		// Reject source file extensions
		for path in fullpaths[:] {
			ext := filepath.ext(path)
			ext_lower := strings.to_lower(ext, context.temp_allocator)

			// C++ rejects .c, .cpp, .cxx, .h, .hpp, .hxx
			if ext_lower == ".c" || ext_lower == ".cpp" || ext_lower == ".cxx" || ext_lower == ".h" || ext_lower == ".hpp" || ext_lower == ".hxx" {
				error_node(decl, "With 'foreign import', you cannot import a %s file/directory, you must precompile the library and link against that", ext)
				break
			}
		}

		// Store resolved paths (C++ line 5454)
		lib.paths = fullpaths[:]

		// Update library name if it was placeholder (C++ line 5499-5503)
		if lib.name == "_foreign_lib" && len(lib.paths) > 0 {
			lib.name = path_to_entity_name("", lib.paths[0])
			entity.token.text = lib.name
		}
	}

	// WASM foreign procedure link name processing (C++ line 5470-5500)
	// For WASM architecture, foreign procedure names must be qualified with module name
	// Format: "module_name::procedure_name" (unless module ends with .o)
	for {
		e, ok := queue.mpsc_dequeue(&ctx.info.foreign_decls_to_check)
		if !ok do break

		// Only process procedures (C++ line 5472-5473)
		if e.kind != .Procedure {
			continue
		}

		// WASM-specific processing (C++ line 5475-5476)
		if !is_arch_wasm() {
			continue
		}

		// Get foreign library entity (C++ line 5478-5479)
		proc_variant := &e.variant.(Entity_Procedure)
		foreign_library := proc_variant.foreign_library
		assert(foreign_library != nil, "Foreign procedure must have foreign_library")

		// Get current link name (C++ line 5481)
		name := proc_variant.link_name

		// Default module name is "env" (C++ line 5483)
		module_name := "env"

		// Validate foreign library (C++ line 5484-5488)
		assert(foreign_library.kind == .Library_Name, "Foreign library must be Library_Name entity")
		lib := &foreign_library.variant.(Entity_Library_Name)

		if len(lib.paths) != 1 {
			// Get architecture name for error message
			// C++ Reference: check_decl.cpp:5484-5488
			arch_name := "wasm"
			if ctx.info.build_context != nil {
				arch_name = target_arch_names[ctx.info.build_context.metrics.arch]
			}
			error(foreign_library.token, "'foreign import' for '%s' architecture may only have one path, got %d", arch_name, len(lib.paths))
		}

		// Use first path as module name (C++ line 5490-5492)
		if len(lib.paths) >= 1 {
			module_name = lib.paths[0]
		}

		// Qualify link name with module unless module ends with .o (C++ line 5494-5496)
		// C++ uses WASM_MODULE_NAME_SEPARATOR which is "::"
		if !strings.has_suffix(module_name, ".o") {
			// Concatenate: module_name + "::" + name
			qualified_name := strings.concatenate({module_name, "::", name}, ctx.checker.allocator)
			proc_variant.link_name = qualified_name
			name = qualified_name
		}

		// Check foreign procedure with updated link name (C++ line 5499)
		check_foreign_procedure(ctx, e, e.decl_info)
	}
}

// Import_Graph_Node is defined in check_import_export.odin (kept the original authoritative version)

// add_import_dependency_node adds import declarations to the dependency graph
// C++ Reference: checker.cpp:5068-5130
//
// Builds the import dependency graph for:
// - Topological sorting of packages
// - Import cycle detection
// - Package initialization ordering
//
// Processes:
// - Regular import declarations
// - When statement imports (conditional compilation)
add_import_dependency_node :: proc(checker: ^Checker, decl: ^ast.Stmt, graph: ^map[rawptr]^Import_Graph_Node) {
	// Helper to get or create graph node
	get_or_create_node :: proc(graph: ^map[rawptr]^Import_Graph_Node, pkg: ^ast.Package, allocator := context.allocator) -> ^Import_Graph_Node {
		key := rawptr(pkg)
		if node, ok := graph[key]; ok {
			return node
		}

		node := new(Import_Graph_Node, allocator)
		node.pkg = pkg
		// NOTE: Package scope is not set here because this helper is inside add_import_dependency_node
		// which is obsoleted by generate_import_dependency_graph. See line 2060 for proper implementation.
		node.succ = make(map[^Import_Graph_Node]struct{}, allocator)
		node.pred = make(map[^Import_Graph_Node]struct{}, allocator)

		graph[key] = node
		return node
	}

	// NOTE: Getting parent package requires file lookup infrastructure
	// C++ uses: decl->file()->pkg
	// Infrastructure is now implemented:
	// - AST nodes have file_id field (core/odin/ast/ast.odin)
	// - Checker_Info has files_by_id map (checker.odin:1445)
	// - get_file_from_node helper is available (file_helpers.odin:30)
	// To get parent package: file := get_file_from_node(info, cast(^ast.Node)decl); pkg := file.pkg
	parent_pkg: ^ast.Package = nil

	if parent_pkg == nil {
		// Cannot process without package info
		return
	}

	// Process based on declaration kind (C++ line 5071)
	#partial switch d in decl.derived {
	case ^ast.Import_Decl:
		// Regular import (C++ line 5072-5103)

		// NOTE: This function (add_import_dependency_node) is obsolete.
		// See generate_import_dependency_graph (line 2044) for proper implementation
		// which uses checker.info.packages (line 2084) for import path resolution.

		// Get parent and imported package nodes
		_ = get_or_create_node(graph, parent_pkg, checker.allocator)
	// m := get_or_create_node(graph, imported_pkg, checker.allocator)

	// Add dependency edges (C++ line 5100-5102)
	// append(&n.succ, m)  // parent imports imported
	// append(&m.pred, n)  // imported is imported by parent

	// Mark scope as imported (C++ line 5102)
	// NOTE: Scope.flags and Scope.imported fields are already implemented in Scope struct

	case ^ast.When_Stmt:
		// Conditional import (C++ line 5105-5128)
		ws := d

		// Process body imports
		if ws.body != nil {
			if block, ok := ws.body.derived.(^ast.Block_Stmt); ok {
				for stmt in block.stmts {
					add_import_dependency_node(checker, stmt, graph)
				}
			}
		}

		// Process else imports
		if ws.else_stmt != nil {
			#partial switch else_kind in ws.else_stmt.derived {
			case ^ast.Block_Stmt:
				for stmt in else_kind.stmts {
					add_import_dependency_node(checker, stmt, graph)
				}
			case ^ast.When_Stmt:
				add_import_dependency_node(checker, ws.else_stmt, graph)
			}
		}
	}
}

// generate_import_dependency_graph builds complete import graph for all packages
// C++ Reference: checker.cpp:5132-5167
//
// Returns import graph with nodes for all packages and their dependencies
generate_import_dependency_graph :: proc(checker: ^Checker, allocator := context.allocator) -> Import_Graph {
	graph := Import_Graph {
		nodes     = make(map[rawptr]^Import_Graph_Node, allocator),
		checker   = checker,
		allocator = allocator,
	}

	// Helper to get or create graph node for a package
	get_or_create_node :: proc(graph: ^Import_Graph, pkg: ^ast.Package) -> ^Import_Graph_Node {
		key := rawptr(pkg)
		if node, ok := graph.nodes[key]; ok {
			return node
		}

		node := new(Import_Graph_Node, graph.allocator)
		node.pkg = pkg
		node.scope = get_package_scope(&graph.checker.info, pkg)
		node.succ = make(map[^Import_Graph_Node]struct{}, graph.allocator)
		node.pred = make(map[^Import_Graph_Node]struct{}, graph.allocator)
		node.dep_count = 0

		graph.nodes[key] = node
		return node
	}

	// Create nodes for all packages (C++ line 5137-5141)
	for _, pkg in checker.info.packages {
		get_or_create_node(&graph, pkg)
	}

	// Calculate edges from import declarations.
	//
	// C++ Reference: checker.cpp generate_import_dependency_graph:5477-5486, inside generate_import_dependency_graph. (The
	// previous citation here, "C++ line 5143-5153", pointed at
	// correct_type_alias_in_scope_backwards -- an unrelated function. Stale-citation drift, the
	// same family LEDGER 134 measured at +193 to +334 in checker.cpp.)
	//
	// C++ iterates p->files, an ARRAY sorted by basename. The sort is safe to rely on here:
	// generate_import_dependency_graph is reached from check_import_entities, called at
	// checker.cpp:7686 -- AFTER check_create_file_scopes does the sorting at checker.cpp:7677.
	// Established by call order, not by line numbers.
	for _, pkg in checker.info.packages {
		parent_node := get_or_create_node(&graph, pkg)

		// Iterate all files in package
		for file in sorted_files(pkg.files) {
			// Process import declarations
			for decl in file.decls {
				if import_decl, ok := decl.derived.(^ast.Import_Decl); ok {
					// Look up imported package
					if imported_pkg, pkg_ok := lookup_imported_package(&checker.info, import_decl.fullpath, pkg); pkg_ok {
						imported_node := get_or_create_node(&graph, imported_pkg)

						// Add edge: parent imports imported
						parent_node.succ[imported_node] = {}
						imported_node.pred[parent_node] = {}
					}
				}
			}
		}
	}

	// Set dependency counts (C++ line 5158-5165)
	for _, node in graph.nodes {
		node.dep_count = len(node.succ)
	}

	return graph
}

///////////////////////////////////////////////////////////////////////////////
// C++ Reference: checker.cpp and parser.cpp
///////////////////////////////////////////////////////////////////////////////

// ast_token extracts the primary token from any AST node
// C++ Reference: Inline function or macro in parser.cpp
//
// In C++, each AST node has a simple token field. In Odin's core:odin/ast,
// nodes inherit from Node which has a pos field. We create a Token from that position.
ast_token :: proc(node: ^ast.Node) -> tokenizer.Token {
	if node == nil {
		return {}
	}

	// The position comes from ast_token_pos, NOT from node.pos directly.
	//
	// This used to return node.pos with a comment admitting the divergence ("C++ ast_token
	// extracts the actual token from node-specific fields, but we use a synthetic token").
	// Task 254 ported those node-specific arms -- Assign_Stmt to its operator, Deref_Expr to
	// its operator, Implicit_Selector_Expr to its FIELD -- into ast_token_pos, and left this
	// second helper computing the same thing the old way. Two helpers for one concept, one
	// correct. `case .A:` recorded the dot's column where C++ records the field's, so
	// "previous case at ..." pointed one column left. LEDGER task 274.
	//
	// Token kind stays Invalid: only the position is ever read from this.
	return tokenizer.Token {
		pos  = ast_token_pos(node),
		kind = .Invalid,
	}
}

// check_rtti_type_disallowed validates that a type is allowed for RTTI
// C++ Reference: checker.cpp check_rtti_type_disallowed:39-49
//
// Some types cannot be used with runtime type information (RTTI).
// When RTTI is disabled via -no-rtti build flag, the 'any' type is disallowed.
// Returns true if the type is disallowed and an error was reported.
check_rtti_type_disallowed :: proc(ctx: ^Checker_Context, pos: tokenizer.Token, type: ^Type, format_message: string) -> bool {
	// C++ Reference: checker.cpp check_rtti_type_disallowed:40-48
	if ctx.info.build_context != nil && ctx.info.build_context.no_rtti && type != nil {
		if is_type_any(type) {
			t := type_to_string(type)
			error(pos, format_message, t)
			return true
		}
	}
	return false
}
