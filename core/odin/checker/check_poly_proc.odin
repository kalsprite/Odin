package checker

import "core:odin/ast"
import "core:sync"
/*
Polymorphic Procedure Support 

This module implements polymorphic procedure instantiation and caching.
Polymorphic procedures are procedures with type parameters (e.g., $T) that are
specialized at compile time based on call site types.

Example:
	identity :: proc(x: $T) -> T { return x }
	a := identity(42)      // Instantiates identity_i32
	b := identity(3.14)    // Instantiates identity_f64

C++ Reference:
- check_expr.cpp:369-659 (find_or_generate_polymorphic_procedure)
- check_expr.cpp:650-655 (check_polymorphic_procedure_assignment)
- checker.cpp (polymorphic infrastructure)
*/


// Poly_Proc_Data stores the result of polymorphic procedure instantiation
// Used to communicate the generated entity and proc_info back to the caller
// C++ Reference: check_expr.cpp:99-103 (PolyProcData struct)
Poly_Proc_Data :: struct {
	gen_entity: ^Entity, // The specialized procedure entity
	proc_info:  ^Proc_Info, // Procedure info for deferred checking
}

// check_polymorphic_procedure_assignment validates polymorphic procedure assignment
// This is called when assigning a polymorphic procedure to a concrete procedure type
//
// C++ Reference: check_expr.cpp:650-655
//
// Example:
//   identity :: proc(x: $T) -> T { return x }
//   f: proc(i32) -> i32 = identity  // Calls this function
//
check_polymorphic_procedure_assignment :: proc(ctx: ^Checker_Context, operand: ^Operand, target_type: ^Type, poly_def_node: ^ast.Node, poly_proc_data: ^Poly_Proc_Data) -> bool {
	// C++ lines 651-652
	if operand.expr == nil {
		return false
	}

	// Get the entity from the operand expression
	// C++ line 652: Entity *base_entity = entity_from_expr(operand->expr);
	// entity_from_expr is defined in entity_helpers.odin
	base_entity := entity_from_expr_ctx(ctx, operand.expr)
	if base_entity == nil {
		return false
	}

	// Delegate to the main instantiation function
	// C++ line 654
	return find_or_generate_polymorphic_procedure(
		ctx,
		base_entity,
		target_type,
		nil, // No parameter operands in assignment context
		poly_def_node,
		poly_proc_data,
	)
}

// find_or_generate_polymorphic_procedure_from_parameters infers types from call arguments
// This is called when calling a polymorphic procedure with concrete arguments
//
// C++ Reference: check_expr.cpp:657-659
//
// Example:
//   identity :: proc(x: $T) -> T { return x }
//   a := identity(42)  // Infers T = i32 from argument
//
find_or_generate_polymorphic_procedure_from_parameters :: proc(ctx: ^Checker_Context, base_entity: ^Entity, operands: []Operand, poly_def_node: ^ast.Node, poly_proc_data: ^Poly_Proc_Data) -> bool {
	// C++ line 658
	return find_or_generate_polymorphic_procedure(
		ctx,
		base_entity,
		nil, // No target type in call context
		operands,
		poly_def_node,
		poly_proc_data,
	)
}

// find_or_generate_polymorphic_procedure is the core polymorphic instantiation function
// It takes a polymorphic procedure and either:
// 1. target_type (for assignment): Instantiate to match the target type
// 2. operands (for calls): Infer types from arguments and instantiate
//
// The function checks a cache of previously generated specializations and reuses
// them if possible. Otherwise, it creates a new specialized procedure.
//
// C++ Reference: check_expr.cpp:369-648
//
find_or_generate_polymorphic_procedure :: proc(old_ctx: ^Checker_Context, base_entity: ^Entity, target_type: ^Type, param_operands: []Operand, poly_def_node: ^ast.Node, poly_proc_data: ^Poly_Proc_Data) -> bool {
	///////////////////////////////////////////////////////////////////////////////
	//                                                                           //
	// NOTE: This procedure is complex and somewhat messy, mirroring the C++.   //
	// It handles type inference, procedure cloning, and caching.                //
	//                                                                           //
	///////////////////////////////////////////////////////////////////////////////

	// Validation: C++ lines 379-391
	if base_entity == nil {
		return false
	}

	if !is_type_proc(base_entity_type(base_entity)) {
		return false
	}

	if .Disabled in base_entity.flags {
		return false
	}

	// Get source and destination types
	// C++ lines 393-397
	src := base_type(base_entity_type(base_entity))
	dst: ^Type = nil
	if target_type != nil {
		dst = base_type(target_type)
	}

	// Validate parameter/type consistency
	// C++ lines 399-404
	if param_operands == nil {
		assert(dst != nil, "find_or_generate_polymorphic_procedure: need target type when no operands")
	}
	if param_operands != nil {
		assert(dst == nil, "find_or_generate_polymorphic_procedure: can't have both target type and operands")
	}

	// Check if procedure is polymorphic and unspecialized
	// C++ lines 406-408
	src_proc, src_ok := src.variant.(Type_Proc)
	if !src_ok || !src_proc.is_polymorphic || src_proc.is_poly_specialized {
		return false
	}

	// If we have a target type, validate parameter/result counts match
	// C++ lines 410-419
	if dst != nil {
		dst_proc, dst_ok := dst.variant.(Type_Proc)
		if !dst_ok {
			return false
		}

		if dst_proc.is_polymorphic {
			return false
		}

		if dst_proc.param_count != src_proc.param_count || dst_proc.result_count != src_proc.result_count {
			return false
		}
	}

	// Get declaration info
	// C++ lines 422-425
	old_decl := decl_info_of_entity(base_entity)
	if old_decl == nil {
		return false
	}

	// Build operand array from target type if needed
	// C++ lines 428-445
	operands := param_operands
	defer if param_operands == nil {
		delete(operands)
	}

	if param_operands == nil {
		// Create operands from destination type parameters
		// C++ lines 434-440
		dst_proc := dst.variant.(Type_Proc)
		operands = make([]Operand, dst_proc.param_count)

		if params_tuple, params_ok := dst_proc.params.variant.(Type_Tuple); params_ok {
			for param, i in params_tuple.variables {
				operands[i] = Operand {
					mode = .Value,
					type = entity_type(param),
				}
			}
		}
	}

	// Create a new checker context for type inference
	// C++ lines 448-456
	nctx := old_ctx^
	scope := create_scope(base_entity.scope, nctx.checker.allocator)
	scope.flags += {.Proc}
	nctx.scope = scope
	nctx.allow_polymorphic_types = true
	if nctx.polymorphic_scope == nil {
		nctx.polymorphic_scope = scope
	}

	// Build procedure type from polymorphic template
	// C++ lines 459-468
	pt := src_proc

	// Allocate new procedure type for specialization
	// NOTE: This may leak memory if type already exists, but arena allocation handles this
	// C++ lines 461-463
	final_proc_type := alloc_type_proc(scope, nil, nil, 0, 0, false, pt.calling_convention)

	// Check the procedure type with the provided operands to infer type parameters
	// This populates the scope with type parameter bindings
	// C++ line 464
	if pt.node == nil {
		return false
	}
	pt_node, pt_node_ok := pt.node.derived.(^ast.Proc_Type)
	if !pt_node_ok {
		return false
	}
	success := check_procedure_type(&nctx, final_proc_type, pt_node, operands)
	if !success {
		return false
	}

	// Access the gen_procs cache (thread-safe)
	// C++ lines 470-500
	gen_procs: ^Gen_Procs_Data = nil

	assert(base_entity.kind == .Procedure, "Expected procedure entity")
	proc_variant := &base_entity.variant.(Entity_Procedure)
	sync.mutex_lock(&proc_variant.gen_procs_mutex)
	gen_procs = proc_variant.gen_procs

	if gen_procs != nil {
		// Cache exists, check if we already have this specialization
		// C++ lines 477-494
		sync.rw_mutex_shared_lock(&gen_procs.mutex)
		sync.mutex_unlock(&proc_variant.gen_procs_mutex)

		for other in gen_procs.procs {
			pt := base_type(entity_type(other))
			if are_types_identical(pt, final_proc_type) {
				// Found existing specialization!
				// C++ lines 485-490
				sync.rw_mutex_shared_unlock(&gen_procs.mutex)

				if poly_proc_data != nil {
					poly_proc_data.gen_entity = other
				}
				return true
			}
		}

		sync.rw_mutex_shared_unlock(&gen_procs.mutex)
	} else {
		// No cache yet, create one
		// C++ lines 495-499
		gen_procs = new(Gen_Procs_Data, nctx.checker.allocator)
		gen_procs.procs.allocator = nctx.checker.allocator
		proc_variant.gen_procs = gen_procs
		sync.mutex_unlock(&proc_variant.gen_procs_mutex)
	}

	// At this point, we need to create a new specialization
	// First, re-check the procedure type without errors suppressed
	// C++ lines 503-550
	{
		prev_no_polymorphic_errors := nctx.no_polymorphic_errors
		defer nctx.no_polymorphic_errors = prev_no_polymorphic_errors
		nctx.no_polymorphic_errors = false

		// Reset scope for clean type checking
		// C++ lines 509-512
		clear_scope(scope)

		// Clone the procedure type AST for fresh checking
		// C++ lines 514-515
		cloned_proc_type_node := clone_ast_node(pt.node)
		cloned_pt, cloned_pt_ok := cloned_proc_type_node.derived.(^ast.Proc_Type)
		if !cloned_pt_ok {
			return false
		}
		success = check_procedure_type(&nctx, final_proc_type, cloned_pt, operands)
		if !success {
			return false
		}

		// Double-check cache again (race condition protection)
		// C++ lines 521-548
		sync.rw_mutex_shared_lock(&gen_procs.mutex)
		for other in gen_procs.procs {
			pt := base_type(entity_type(other))
			if are_types_identical(pt, final_proc_type) {
				// Another thread created it while we were checking
				// C++ lines 525-546
				sync.rw_mutex_shared_unlock(&gen_procs.mutex)

				if poly_proc_data != nil {
					poly_proc_data.gen_entity = other
				}

				// Queue for procedure checking if not yet checked
				// C++ lines 531-544
				decl := other.decl_info
				if decl.proc_checked_state != .Checked {
					proc_info := new(Proc_Info)
					proc_info.file = other.file
					proc_info.token = other.token
					proc_info.decl = decl
					proc_info.type = entity_type(other)
					proc_info.body = decl.proc_lit.derived.(^ast.Proc_Lit).body.derived.(^ast.Block_Stmt)
					if proc_var, proc_ok := &other.variant.(Entity_Procedure); proc_ok {
						proc_info.tags = proc_var.tags
					}
					proc_info.generated_from_polymorphic = true
					proc_info.poly_def_node = cast(^ast.Expr)poly_def_node

					check_procedure_later(nctx.checker, proc_info)
				}

				return true
			}
		}
		sync.rw_mutex_shared_unlock(&gen_procs.mutex)
	}

	// Create the specialized procedure entity
	// C++ lines 553-612

	// Clone the procedure literal AST
	// C++ line 553
	proc_lit := clone_ast_node(old_decl.proc_lit)
	pl := proc_lit.derived.(^ast.Proc_Lit)

	// Associate the scope with the procedure type node
	// C++ lines 555-556
	add_scope(&nctx, pl.type, final_proc_type.variant.(Type_Proc).scope)

	// Mark as specialized polymorphic
	// C++ lines 557-558
	if final_pt, final_ok := &final_proc_type.variant.(Type_Proc); final_ok {
		final_pt.is_poly_specialized = true
		final_pt.is_polymorphic = true

		// Copy procedure flags from source
		// C++ lines 560-568
		final_pt.variadic = src_proc.variadic
		final_pt.require_results = src_proc.require_results
		final_pt.c_vararg = src_proc.c_vararg
		final_pt.has_named_results = src_proc.has_named_results
		final_pt.diverging = src_proc.diverging
		final_pt.return_by_pointer = src_proc.return_by_pointer
		final_pt.optional_ok = src_proc.optional_ok
		final_pt.enable_target_feature = src_proc.enable_target_feature
		final_pt.require_target_feature = src_proc.require_target_feature

		// Check for cycles in type parameters
		// C++ lines 571-579
		for o in operands {
			if final_proc_type == o.type || base_entity_type(base_entity) == o.type {
				// Cycle detected
				final_pt.is_poly_specialized = false
				break
			}
		}
	}

	// Get procedure tags
	// C++ line 581
	tags: u64 = 0
	if proc_var, proc_ok := &base_entity.variant.(Entity_Procedure); proc_ok {
		tags = proc_var.tags
	}

	// Clone identifier
	// C++ Reference: check_expr.cpp:588-589
	//   Ast *ident = clone_ast(base_entity->identifier);
	//   Token token = ident->Ident.token;
	//
	// The token must come from the *cloned identifier*, not from base_entity.token.
	// add_entity_use overwrites entity.identifier with the most recent use-site
	// identifier (checker.cpp:2143 does exactly the same), so when the base entity was
	// reached through a procedure group its own token and its identifier can name
	// different procedures -- e.g. base_entity is `syscall2` while its identifier is the
	// `syscall` at the call site. Taking the token from the identifier keeps the two in
	// step, which is what add_entity_and_decl_info asserts.
	ident := clone_ast_node(base_entity.identifier)
	token := base_entity.token
	if ident_expr, ident_ok := ident.derived.(^ast.Ident); ident_ok {
		token = make_token_from_ident(ident_expr)
	}

	// Create declaration info for the specialized procedure
	// C++ lines 584-590
	d := make_decl_info(scope, old_decl.parent, nctx.checker.allocator)
	d.gen_proc_type = final_proc_type
	d.type_expr = pl.type
	d.proc_lit = cast(^ast.Proc_Lit)proc_lit
	d.proc_checked_state = .Unchecked
	d.defer_use_checked = false
	d.para_poly_original = old_decl.entity

	// Allocate specialized procedure entity
	// C++ lines 592-593
	entity := alloc_entity_procedure(nil, token, final_proc_type, tags)
	entity.state = .Resolved
	entity.identifier = ident

	// Register entity and decl
	// C++ lines 596-601
	add_entity_and_decl_info(&nctx, ident, entity, d, false)
	entity.scope = scope.parent
	entity.file = base_entity.file
	entity.pkg = base_entity.pkg
	entity.flags = {}

	if proc_var, proc_ok := &base_entity.variant.(Entity_Procedure); proc_ok {
		entity_proc := &entity.variant.(Entity_Procedure)
		entity_proc.optimization_mode = proc_var.optimization_mode

		// Copy flags
		// C++ lines 605-610
		if .Cold in base_entity.flags {
			entity.flags += {.Cold}
		}
		if .Disabled in base_entity.flags {
			entity.flags += {.Disabled}
		}
	}

	d.entity = entity

	// Add to cache
	// C++ lines 623-625
	sync.rw_mutex_lock(&gen_procs.mutex)
	append(&gen_procs.procs, entity)
	sync.rw_mutex_unlock(&gen_procs.mutex)

	// Create procedure info for deferred checking
	// C++ lines 627-635
	// NOTE: C++ lines 614-621 have a bug where they try to walk scope chain to find file,
	// but the logic is incorrect (checks s->file == nullptr in while condition but then
	// assigns s->file inside loop, so file is always nullptr). We use entity.file instead,
	// which was set from base_entity.file at line 428.
	proc_info := new(Proc_Info)
	proc_info.file = entity.file
	proc_info.token = token
	proc_info.decl = d
	proc_info.type = final_proc_type
	proc_info.body = pl.body.derived.(^ast.Block_Stmt)
	proc_info.tags = tags
	proc_info.generated_from_polymorphic = true
	proc_info.poly_def_node = cast(^ast.Expr)poly_def_node

	// Return results
	// C++ lines 638-642
	if poly_proc_data != nil {
		poly_proc_data.gen_entity = entity
		poly_proc_data.proc_info = proc_info

		if entity_proc, entity_ok := &entity.variant.(Entity_Procedure); entity_ok {
			entity_proc.generated_from_polymorphic = proc_info.generated_from_polymorphic
		}
	}

	// Queue for procedure checking
	// C++ line 645
	check_procedure_later(nctx.checker, proc_info)

	return true
}

// Helper: clear_scope removes all children and elements from a scope
// Used when re-checking procedure types
clear_scope :: proc(s: ^Scope) {
	s.head_child = nil
	clear(&s.elements)
	clear(&s.imported)
}

// NOTE: clone_ast_node is now implemented in ast_clone.odin
// C++ Reference: /mnt/c/odin/src/parser.cpp:176-496 (~320 lines of recursive cloning)
// The implementation provides full deep cloning of all AST node types

// Helper: base_entity_type gets the type of an entity
base_entity_type :: proc(e: ^Entity) -> ^Type {
	return entity_type(e)
}

// Helper: is_type_proc checks if a type is a procedure type
is_type_proc :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	bt := base_type(t)
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

	return bt.kind == .Proc
}
