package checker

/*
Type expression checking.

This module implements type validation and construction from AST type expressions,
following the logic in check_type.cpp from the Odin compiler.

C++ Reference: /mnt/c/odin/src/check_type.cpp (3856 lines)
*/

import "core:container/queue"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:sync"

// check_type_internal is the main dispatcher for type checking
// Returns false if the type is invalid
check_type_internal :: proc(ctx: ^Checker_Context, e: ^ast.Node, type: ^^Type, named_type: ^Type) -> bool {
	assert(type != nil)

	if e == nil {
		type^ = t_invalid
		return true
	}

	#partial switch n in e.derived {
	case ^ast.Ident:
		// Check identifier as a type
		o: Operand
		entity := check_ident(ctx, &o, e, named_type, nil, false)
		_ = entity

		#partial switch o.mode {
		case .Invalid:
		// Error already reported

		case .Type:
			type^ = o.type
			// Check for non-specialized polymorphic types
			// C++ Reference: check_type.cpp:3379-3386
			if !ctx.in_polymorphic_specialization {
				t := base_type(o.type)
				if t != nil && is_type_polymorphic_record_unspecialized(t) {
					// C++ line 3382-3383: err_str = expr_to_string(e);
					// error(e, "Invalid use of a non-specialized polymorphic type '%s'", err_str);
					err_str := expr_to_string(e)
					defer delete(err_str)
					error_node(e, "Invalid use of a non-specialized polymorphic type '%s'", err_str)
					return true
				}
			}
			return true

		case .No_Value:
			// C++ Reference: check_type.cpp:3390-3393
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type", err_str)

		case:
			// C++ Reference: check_type.cpp:3395-3398
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' is not a type", err_str)
		}

	case ^ast.Helper_Type:
		// Helper type (e.g., #type)
		return check_type_internal(ctx, n.type, type, named_type)

	case ^ast.Distinct_Type:
		// C++ Reference: check_type.cpp:3407
		error_node(n, "Invalid use of a distinct type")
		// Treat as helper type to reduce cascading errors
		return check_type_internal(ctx, n.type, type, named_type)

	case ^ast.Poly_Type:
		// Polymorphic type parameter ($T)
		return check_poly_type(ctx, n, type, named_type)

	case ^ast.Typeid_Type:
		// typeid type
		type^ = t_typeid
		set_base_type(named_type, type^)
		return true

	case ^ast.Pointer_Type:
		// Pointer type (^T)
		return check_pointer_type(ctx, n, type, named_type)

	case ^ast.Multi_Pointer_Type:
		// Multi-pointer type ([^]T)
		return check_multi_pointer_type(ctx, n, type, named_type)

	case ^ast.Array_Type:
		// Array type ([N]T)
		check_array_type_internal(ctx, e, type, named_type)
		return true

	case ^ast.Dynamic_Array_Type:
		// Dynamic array type ([dynamic]T)
		return check_dynamic_array_type(ctx, n, type, named_type)

	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		// Fixed-capacity dynamic array type ([dynamic; N]T)
		return check_fixed_capacity_dynamic_array_type(ctx, n, type, named_type)

	// Note: Slice types are handled as Array_Type with no size in Odin's AST

	case ^ast.Struct_Type:
		// Struct type
		return check_struct_type_expr(ctx, n, type, named_type)

	case ^ast.Union_Type:
		// Union type
		return check_union_type_expr(ctx, n, type, named_type)

	case ^ast.Enum_Type:
		// Enum type
		return check_enum_type_expr(ctx, n, type, named_type)

	case ^ast.Bit_Set_Type:
		// Bit set type
		return check_bit_set_type_expr(ctx, n, type, named_type)

	case ^ast.Map_Type:
		// Map type
		return check_map_type_expr(ctx, n, type, named_type)

	case ^ast.Proc_Type:
		// Procedure type
		return check_proc_type_expr(ctx, n, type, named_type)

	case ^ast.Bit_Field_Type:
		// Bit field type
		return check_bit_field_type_expr(ctx, n, type, named_type)

	case ^ast.Matrix_Type:
		// Matrix type
		return check_matrix_type_expr(ctx, n, type, named_type)

	// C++ Reference: check_type.cpp:3956-3974. Both ternary forms may appear in TYPE
	// position and are resolved by checking the expression and taking its type if the
	// result is itself a type:
	//     x :: A if COND else B
	//     x :: A when COND else B
	// The port had neither, so such a declaration reported
	// "Invalid type expression: ..." and left the name bound to an invalid type. That is
	// how base/runtime/internal.odin:18
	//     __float16 :: f16 when __ODIN_LLVM_F16_SUPPORTED else u16
	// failed, and every later use of __float16 then produced
	// "Cannot assign value of type '<invalid>' to '<invalid>'" — 465 of those in the sweep
	// from this one declaration.
	case ^ast.Ternary_If_Expr, ^ast.Ternary_When_Expr:
		o: Operand
		check_expr_or_type(ctx, &o, e)
		if o.mode == .Type {
			type^ = o.type
			set_base_type(named_type, type^)
			return true
		}

	case ^ast.Selector_Expr:
		// Package.Type selector
		o: Operand
		check_selector(ctx, &o, e, named_type)

		#partial switch o.mode {
		case .Invalid:
		// Error already reported

		case .Type:
			assert(o.type != nil)
			type^ = o.type
			return true

		case .No_Value:
			// C++ Reference: check_type.cpp:3390-3393
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type", err_str)

		case:
			// C++ Reference: check_type.cpp:3395-3398
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' is not a type", err_str)
		}

	case ^ast.Paren_Expr:
		// Parenthesized type
		if n.expr == nil {
			// C++ Reference: check_type.cpp (paren expr handling)
			error_node(n, "Expected an expression or type within the parentheses")
			type^ = t_invalid
			return true
		}
		type^ = check_type_expr(ctx, n.expr, named_type)
		set_base_type(named_type, type^)
		return true

	case ^ast.Unary_Expr:
		// Unary expression (pointer with ^)
		if n.op.kind == .Pointer {
			elem := check_type(ctx, n.expr)
			type^ = make_pointer_type(elem)
			set_base_type(named_type, type^)
			return true
		}

	case ^ast.Call_Expr:
		// Call expression - can be type_of() or other type-returning builtins
		// C++ Reference: check_type.cpp handles this through check_expr_or_type
		o: Operand
		check_expr_base(ctx, &o, e, nil)

		#partial switch o.mode {
		case .Invalid:
			// Error already reported

		case .Type:
			assert(o.type != nil)
			type^ = o.type
			return true

		case .No_Value:
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type", err_str)

		case:
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' is not a type", err_str)
		}
	}

	// Invalid type expression
	err_str := expr_to_string(e)
	defer delete(err_str)
	error_node(e, "Invalid type expression: %s", err_str)
	type^ = t_invalid
	return false
}

// check_type_expr checks a type expression and returns the type
check_type_expr :: proc(ctx: ^Checker_Context, e: ^ast.Node, named_type: ^Type) -> ^Type {
	type: ^Type = t_invalid
	ok := check_type_internal(ctx, e, &type, named_type)
	_ = ok
	return type
}

// check_type checks a type expression on a *fresh* cycle-detection path.
// C++ Reference: check_type.cpp:4002-4008
//
// This is what distinguishes check_type from check_type_expr: indirections that legally
// break a declaration cycle (`^T`, `[^]T`, `[dynamic]T`, `map[K]V`, ...) go through
// check_type, so a self-referential type reached behind a pointer is not reported as an
// illegal cycle. Callers that must keep the cycle chain intact (struct/union fields, for
// instance) call check_type_expr directly.
check_type :: proc(ctx: ^Checker_Context, e: ^ast.Node) -> ^Type {
	// C++ lines 4003-4006: CheckerContext c = *ctx; c.type_path = new_checker_type_path();
	// The path lives on the stack here; it stays empty (and so allocation-free) unless
	// something below actually pushes onto it.
	c := ctx^
	type_path: Checker_Type_Path
	defer delete(type_path)
	c.type_path = &type_path

	return check_type_expr(&c, e, nil)
}

// make_soa_struct_internal creates a Structure-of-Arrays struct type
// C++ Reference: check_type.cpp:3074-3232
// This creates the SOA struct type and queues it for field completion
make_soa_struct_internal :: proc(ctx: ^Checker_Context, array_type_expr: ^ast.Node, elem_expr: ^ast.Node, elem: ^Type, count: i64, generic_type: ^Type, soa_kind: Struct_Soa_Kind) -> ^Type {
	// C++ lines 3075-3079: Verify element is a valid type
	// Valid types: structs, raw unions, and small arrays (count <= 4)
	bt := base_type(elem)

	// C++ Reference: check_type.cpp:3279 - `bool is_polymorphic = is_type_polymorphic(elem);`
	//
	// This asked a different question: `generic_type != nil` is "was an array COUNT generic
	// supplied?". `#soa[]$E` has no count, so the flag was false and the polymorphic element `$E`
	// fell into the "not a valid element" error below, which meant `$T/#soa[]$E` never formed a
	// distinct type and base:runtime's `delete`/`make` groups reported their #soa overloads as
	// duplicates of the plain ones.
	is_polymorphic := is_type_polymorphic(elem)

	is_valid_elem := false
	if is_type_struct(bt) {
		is_valid_elem = true
	} else if is_type_raw_union(bt) {
		is_valid_elem = true
	} else if is_type_array(bt) {
		arr := bt.variant.(Type_Array)
		if arr.count <= 4 {
			is_valid_elem = true
		}
	}

	if !is_polymorphic && !is_valid_elem {
		// C++ Reference: check_type.cpp:3281-3286. C++'s wording, and C++ returns a plain ARRAY of
		// the element rather than t_invalid so the declaration still yields a usable type.
		str := type_to_string(elem)
		error(elem_expr, "Invalid type for an #soa array, expected a struct or array of length 4 or below, got '%s'", str)
		return make_array_type(elem, count, generic_type)
	}

	// Handle struct-specific checks
	if is_type_struct(bt) {
		old_struct := &bt.variant.(Type_Struct)

		// C++ lines 3080-3084: Disallow nested SOA
		if old_struct.soa_kind != .None {
			error(elem_expr, "Cannot create SOA of SOA types")
			return t_invalid
		}
	}

	// C++ lines 3092-3097: Disallow generic types without specialization (structs only)
	if is_type_struct(bt) {
		old_struct := &bt.variant.(Type_Struct)
		if generic_type != nil && old_struct.is_polymorphic && !old_struct.is_poly_specialized {
			error(elem_expr, "Cannot create SOA of unspecialized polymorphic struct type")
			return t_invalid
		}
	}

	// C++ line 3100: Allocate new struct type
	t := alloc_type_struct(ctx.checker)
	ts := &t.variant.(Type_Struct)

	// C++ lines 3102-3106: Set SOA metadata
	ts.soa_kind = soa_kind
	ts.soa_elem = elem
	ts.soa_count = count
	// C++ Reference: check_type.cpp:3302 - `soa_struct->Struct.is_polymorphic = is_polymorphic;`
	// This assignment was missing entirely, so nothing downstream could tell a polymorphic #soa
	// struct from a concrete one - complete_soa_type then asserted on the Generic element.
	ts.is_polymorphic = is_polymorphic
	ts.node = array_type_expr

	// C++ lines 3108-3110: Copy struct properties (structs only)
	if is_type_struct(bt) {
		old_struct := &bt.variant.(Type_Struct)
		ts.is_packed = old_struct.is_packed
		ts.custom_align = old_struct.custom_align
	}

	// C++ lines 3112-3115: Create scope for the new struct
	// Use the parent scope from the element type's scope
	parent_scope := ctx.scope
	if is_type_struct(bt) {
		old_struct := &bt.variant.(Type_Struct)
		if old_struct.scope != nil {
			parent_scope = old_struct.scope.parent
		}
	}
	ts.scope = create_scope(parent_scope, ctx.checker.allocator)
	if ts.scope != nil {
		ts.scope.flags += {.Type}
	}

	// C++ lines 3118-3120: Allocate mutex for thread-safe completion
	ts.soa_mutex = new(sync.Mutex, ctx.checker.allocator)

	// C++ Reference: check_type.cpp:3320-3440. C++ builds the #soa fields EAGERLY whenever the
	// element type's fields are already resolved (`old_struct->Struct.fields_wait_signal.futex.load()`,
	// check_type.cpp:3371) and enqueues ONLY when they are not (the `is_complete` else-branch at
	// 3428-3440). A polymorphic #soa struct is complete immediately - it has no fields to build
	// until instantiation - and is never queued.
	//
	// The port deferred unconditionally, which is not merely a scheduling difference: a freshly
	// minted `#soa[]T` had ZERO fields until the next drain, so are_types_identical compared it
	// against an already-completed `#soa[]T`, saw len(fields) 0 vs N, and reported two
	// identically-spelled types as different - e.g.
	//   Cannot assign value of type '#soa[]Struct_Field' to '#soa[]Struct_Field' in return statement
	// on core:reflect's struct_fields_zipped. Anything that mints an #soa type and immediately
	// compares or uses it hit this; soa_zip is just the loudest case.
	//
	// Readiness is `fields present AND no outstanding resolution`. That is deliberately the
	// conservative direction: C++'s wait signal is set-when-complete, whereas sync.Wait_Group
	// counts DOWN to zero and a struct that never began resolution also reads zero, so the
	// counter alone would call an empty struct complete. Requiring fields to actually be there
	// means an unresolved element defers exactly as it did before.
	//
	// Array elements stay on the queue: C++ spreads them into x/y/z/w fields inline here, which
	// the port's complete_soa_type has no arm for (it asserts the element is a struct). That gap
	// is pre-existing and out of scope for this change.
	elem_fields_ready := false
	if !is_polymorphic && (is_type_struct(bt) || is_type_raw_union(bt)) {
		old_ts := &bt.variant.(Type_Struct)
		elem_fields_ready = len(old_ts.fields) > 0 && sync.atomic_load(&old_ts.fields_wait_signal.counter) == 0
	}

	if is_polymorphic {
		// Nothing to build, and nothing to queue.
	} else if elem_fields_ready {
		complete_soa_type(ctx.checker, t, false)
	} else {
		queue.mpsc_enqueue(&ctx.checker.soa_types_to_complete, t)
	}

	return t
}

// make_soa_struct_fixed creates a fixed-size SOA struct (#soa[N]Struct)
// C++ Reference: check_type.cpp:3235-3237
make_soa_struct_fixed :: proc(ctx: ^Checker_Context, array_type_expr: ^ast.Node, elem_expr: ^ast.Node, elem: ^Type, count: i64, generic_type: ^Type) -> ^Type {
	// C++ line 3236: return make_soa_struct_internal(ctx, array_typ_expr, elem_expr, elem, count, generic_type, StructSoa_Fixed);
	return make_soa_struct_internal(ctx, array_type_expr, elem_expr, elem, count, generic_type, .Fixed)
}

// make_soa_struct_slice creates a slice SOA struct (#soa[]Struct)
// C++ Reference: check_type.cpp:3239-3241
make_soa_struct_slice :: proc(ctx: ^Checker_Context, array_type_expr: ^ast.Node, elem_expr: ^ast.Node, elem: ^Type) -> ^Type {
	// C++ line 3240: return make_soa_struct_internal(ctx, array_typ_expr, elem_expr, elem, -1, nullptr, StructSoa_Slice);
	return make_soa_struct_internal(ctx, array_type_expr, elem_expr, elem, -1, nil, .Slice)
}

// make_soa_struct_dynamic_array creates a dynamic SOA struct (#soa[dynamic]Struct)
// C++ Reference: check_type.cpp:3244-3246
make_soa_struct_dynamic_array :: proc(ctx: ^Checker_Context, array_type_expr: ^ast.Node, elem_expr: ^ast.Node, elem: ^Type) -> ^Type {
	// C++ line 3245: return make_soa_struct_internal(ctx, array_typ_expr, elem_expr, elem, -1, nullptr, StructSoa_Dynamic);
	return make_soa_struct_internal(ctx, array_type_expr, elem_expr, elem, -1, nil, .Dynamic)
}

// check_poly_type processes polymorphic type parameters ($T)
// C++ Reference: check_type.cpp:3420-3464
check_poly_type :: proc(ctx: ^Checker_Context, pt: ^ast.Poly_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Get the identifier after the $
	// C++ lines 3421-3426
	ident_node := pt.type
	ident, ok := ident_node.derived.(^ast.Ident)
	if !ok {
		error(ident_node, "Expected an identifier after the $")
		type^ = t_invalid
		return false
	}

	name := ident.name
	specific: ^Type = nil

	// Check for specialization constraint ($T/SomeType)
	// C++ lines 3429-3436
	if pt.specialization != nil {
		// Create a temporary context with in_polymorphic_specialization flag
		c := ctx^
		c.in_polymorphic_specialization = true
		specific = check_type(&c, pt.specialization)
	}

	// Create the generic type
	// C++ line 3437
	t := make_type_generic(ctx.scope, name, specific)

	// Validate and register the polymorphic type parameter
	// C++ lines 3438-3463
	if ctx.allow_polymorphic_types {
		// Check for disallowed polymorphic return types
		// C++ lines 3439-3441
		if ctx.disallow_polymorphic_return_types {
			error_node(ident_node, "Undeclared polymorphic parameter '%s' in return type", name)
		}

		// Determine which scope to add the entity to
		// C++ lines 3442-3449
		ps := ctx.polymorphic_scope
		s := ctx.scope
		entity_scope := s
		if ps != nil && ps != s {
			// The polymorphic scope is an ancestor - add entity there
			entity_scope = ps
		}

		// Create type name entity for the polymorphic parameter
		// C++ lines 3450-3455
		token := make_token_ident(name)
		e := alloc_entity_type_name(entity_scope, token, t, .Resolved)
		if gen, gen_ok := &t.variant.(Type_Generic); gen_ok {
			gen.entity = e
		}

		// Mark as type alias
		if tn, tn_ok := &e.variant.(Entity_Type_Name); tn_ok {
			tn.is_type_alias = true
		}

		// Add to both polymorphic scope and current scope
		add_entity(ctx, ps, ident_node, e)
		add_entity(ctx, s, ident_node, e)
	} else {
		// Polymorphic types not allowed in this context
		// C++ lines 3457-3460
		error_node(ident_node, "Invalid use of a polymorphic parameter '$%s'", name)
		type^ = t_invalid
		return false
	}

	type^ = t
	set_base_type(named_type, type^)
	return true
}

check_pointer_type :: proc(ctx: ^Checker_Context, pt: ^ast.Pointer_Type, type: ^^Type, named_type: ^Type) -> bool {
	elem := check_type(ctx, pt.elem)
	type^ = make_pointer_type(elem)
	set_base_type(named_type, type^)
	return true
}

// check_multi_pointer_type processes multi-pointer types ([^]T)
// C++ Reference: check_type.cpp:3580-3584
check_multi_pointer_type :: proc(ctx: ^Checker_Context, mpt: ^ast.Multi_Pointer_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Check element type
	// C++ line 3581
	elem := check_type(ctx, mpt.elem)

	// Create multi-pointer type
	// C++ line 3581
	type^ = alloc_type_multi_pointer(elem)

	// Set base type for named types
	// C++ line 3582
	set_base_type(named_type, type^)

	return true
}

// check_array_type_internal processes array and slice types
// C++ Reference: check_type.cpp:3248-3357
check_array_type_internal :: proc(ctx: ^Checker_Context, e: ^ast.Node, type: ^^Type, named_type: ^Type) {
	at, ok := e.derived.(^ast.Array_Type)
	if !ok {
		type^ = t_invalid
		return
	}

	// C++ lines 3250-3356: Check if this is a sized array or slice
	if at.len != nil {
		// Sized array: [N]T, [Enum]T, or tagged arrays (#soa, #simd)
		// C++ lines 3251-3340

		o: Operand
		count := check_array_count(ctx, &o, at.len)
		generic_type: ^Type = nil
		elem := check_type_expr(ctx, at.elem, nil)

		// Check for generic count parameter ($N)
		// C++ lines 3257-3258
		if o.mode == .Type && o.type.kind == .Generic {
			generic_type = o.type
		} else if o.mode == .Type && is_type_enum(o.type) {
			// Enumerated array: [MyEnum]T
			// C++ lines 3259-3295
			index := o.type
			bt := base_type(index)
			assert(bt.kind == .Enum)

			enum_info := bt.variant.(Type_Enum)
			// For enum-indexed arrays, use the enum's min/max values
			t := alloc_type_enumerated_array(elem, index, &enum_info.min_value, &enum_info.max_value, i64(len(enum_info.fields)), .Ellipsis)

			// C++ lines 3266-3291: Handle #sparse tag for enumerated arrays
			is_sparse := false
			if at.tag != nil {
				// C++ line 3268: GB_ASSERT(at->tag->kind == Ast_BasicDirective);
				tag_directive, tag_ok := at.tag.derived.(^ast.Basic_Directive)
				if tag_ok {
					// C++ line 3269-3274: Check tag name
					name := tag_directive.name
					if name == "sparse" {
						is_sparse = true
					} else {
						error(at.tag, "Invalid tag applied to an enumerated array, got #%s", name)
					}
				}
			}

			// C++ lines 3277-3290: Check for non-contiguous enumeration
			ea := &t.variant.(Type_Enumerated_Array)
			if !is_sparse && ea.count > i64(len(enum_info.fields)) {
				// C++ line 3280: error(e, "Non-contiguous enumeration used as an index in an enumerated array");
				begin_error_block()
				error(e, "Non-contiguous enumeration used as an index in an enumerated array")
				error_line("\tenumerated array length: %d", ea.count)
				error_line("\tenum field count: %d", len(enum_info.fields))
				error_line("\tSuggestion: prepend #sparse to the enumerated array to allow for non-contiguous elements")

				// C++ lines 3286-3289: Warning if too sparse
				if 2 * len(enum_info.fields) < int(ea.count) {
					error_line("\tWarning: the number of named elements is much smaller than the length of the array, are you sure this is what you want?")
					error_line("\t         this warning will be removed if #sparse is applied")
				}
				end_error_block()
			}

			// C++ line 3291: t->EnumeratedArray.is_sparse = is_sparse;
			ea.is_sparse = is_sparse

			type^ = t
			return
		}

		// Validate count for non-generic arrays
		// C++ lines 3298-3301
		if count < 0 {
			error(at.len, "? can only be used in conjunction with compound literals")
			count = 0
		}

		// Check for array tags (#soa, #simd)
		// C++ lines 3304-3337
		if at.tag != nil {
			tag_directive, tag_ok := at.tag.derived.(^ast.Basic_Directive)
			if !tag_ok {
				error(at.tag, "Expected a basic directive for array tag")
				type^ = make_array_type(elem, count, generic_type)
				return
			}

			tag_name := tag_directive.name

			if tag_name == "soa" {
				// #soa array (Structure of Arrays)
				// C++ line 3308: *type = make_soa_struct_fixed(ctx, e, at->elem, elem, count, generic_type);
				type^ = make_soa_struct_fixed(ctx, e, at.elem, elem, count, generic_type)
			} else if tag_name == "simd" {
				// #simd vector
				// C++ lines 3309-3333
				if !is_type_valid_vector_elem(elem) && !is_type_polymorphic(elem) {
					elem_str := type_to_string(elem)
					error(at.elem, "Invalid element type for #simd, expected an integer, float, boolean, or 'rawptr', got '%s'", elem_str)
					type^ = make_array_type(elem, count, generic_type)
					return
				}

				if generic_type != nil {
					// Generic count - allow for polymorphic specialization
				} else if count < 1 || !is_power_of_two(count) {
					type^ = make_array_type(elem, count, generic_type)
					if ctx.disallow_polymorphic_return_types && count == 0 {
						return
					}
					error_node(at.len, "Invalid length for #simd, expected a power of two length, got %d", count)
					return
				}

				// Create SIMD vector type
				// C++ line 3329
				type^ = alloc_type_simd_vector(count, elem, generic_type)

				// Validate max element count
				// C++ lines 3331-3333
				SIMD_ELEMENT_COUNT_MAX :: 64
				if count > SIMD_ELEMENT_COUNT_MAX {
					error(at.len, "#simd support a maximum element count of %d, got %d", SIMD_ELEMENT_COUNT_MAX, count)
				}
			} else {
				error(at.tag, "Invalid tag applied to array, got #%s", tag_name)
				type^ = make_array_type(elem, count, generic_type)
			}
		} else {
			// Regular array: [N]T
			// C++ line 3339
			type^ = make_array_type(elem, count, generic_type)
		}
	} else {
		// Slice: []T or tagged slices (#soa)
		// C++ lines 3341-3356
		elem := check_type(ctx, at.elem)

		if at.tag != nil {
			tag_directive, tag_ok := at.tag.derived.(^ast.Basic_Directive)
			if !tag_ok {
				error(at.tag, "Expected a basic directive for slice tag")
				type^ = make_slice_type(elem)
				return
			}

			tag_name := tag_directive.name

			if tag_name == "soa" {
				// #soa slice
				// C++ line 3348: *type = make_soa_struct_slice(ctx, e, at->elem, elem);
				type^ = make_soa_struct_slice(ctx, e, at.elem, elem)
			} else {
				error(at.tag, "Invalid tag applied to array, got #%s", tag_name)
				type^ = make_slice_type(elem)
			}
		} else {
			// Regular slice: []T
			// C++ line 3354
			type^ = make_slice_type(elem)
		}
	}
}

check_dynamic_array_type :: proc(ctx: ^Checker_Context, dat: ^ast.Dynamic_Array_Type, type: ^^Type, named_type: ^Type) -> bool {
	elem := check_type(ctx, dat.elem)

	// C++ Reference: check_type.cpp:3811-3827.
	//
	// The tag was ignored entirely, so `#soa[dynamic]T` silently built a PLAIN dynamic array. Two
	// consequences: #soa dynamic arrays did not work at all, and `$T/#soa[dynamic]$E` was
	// indistinguishable from `$T/[dynamic]$E`, which is why base:runtime's `delete` and `make`
	// groups reported those overloads as duplicates.
	if dat.tag != nil {
		if bd, is_bd := dat.tag.derived_expr.(^ast.Basic_Directive); is_bd {
			if bd.name == "soa" {
				type^ = make_soa_struct_dynamic_array(ctx, dat, dat.elem, elem)
			} else {
				error_node(dat.tag, "Invalid tag applied to dynamic array, got #%s", bd.name)
				type^ = make_dynamic_array_type(elem)
			}
		} else {
			error_node(dat.tag, "Invalid tag applied to dynamic array")
			type^ = make_dynamic_array_type(elem)
		}
	} else {
		type^ = make_dynamic_array_type(elem)
	}

	set_base_type(named_type, type^)
	return true
}


check_struct_type_expr :: proc(ctx: ^Checker_Context, st: ^ast.Struct_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create a new scope for the struct's fields
	// This scope is used for field conflict detection (e.g., using field conflicts)
	struct_scope := create_scope(ctx.scope, ctx.checker.allocator)

	// Create the struct type
	struct_type := new(Type, ctx.checker.allocator)
	struct_type.kind = .Struct
	struct_type.variant = Type_Struct {
		node  = st,
		scope = struct_scope,
	}

	// Initialize wait groups for multi-threaded field resolution
	st_var := &struct_type.variant.(Type_Struct)
	sync.wait_group_add(&st_var.polymorphic_wait_signal, 1)
	sync.wait_group_add(&st_var.fields_wait_signal, 1)

	type^ = struct_type
	set_base_type(named_type, struct_type)

	// Delegate to the full check_struct_type function
	check_struct_type(ctx, struct_type, st, nil, named_type, nil)

	return true
}

// check_struct_type performs full struct type validation
// Ported from check_struct_type in check_type.cpp:631-724
check_struct_type :: proc(ctx: ^Checker_Context, struct_type: ^Type, node: ^ast.Struct_Type, poly_operands: []Operand, named_type: ^Type, original_type_for_poly: ^Type) {
	assert(struct_type.kind == .Struct)

	context_str := "struct"

	// Calculate minimum field count for scope reservation
	min_field_count := 0
	if node.fields != nil {
		for field in node.fields.list {
			#partial switch f in field.derived {
			case ^ast.Value_Decl:
				min_field_count += len(f.names)
			case ^ast.Field:
				min_field_count += len(f.names)
			}
		}
	}

	// Reserve scope capacity (in Odin, the map will grow dynamically)
	// scope_reserve(ctx.scope, min_field_count)

	// Access the struct variant
	st := &struct_type.variant.(Type_Struct)

	// Check for #raw_union attribute
	if node.is_raw_union && min_field_count > 1 {
		st.is_raw_union = true
		context_str = "struct #raw_union"
	}

	// Set basic struct properties
	st.node = node
	// Only set scope if not already set (may have been created in check_struct_type_expr)
	if st.scope == nil {
		st.scope = create_scope(ctx.scope, ctx.checker.allocator)
	}
	st.is_packed = node.is_packed
	st.is_all_or_none = node.is_all_or_none

	// Push the struct scope before processing polymorphic parameters
	// This ensures polymorphic parameters (like T in Box($T: typeid)) are added
	// to the struct's scope, not the parent scope. This is critical for nested
	// polymorphic types like Box(Box(int)) where each level needs its own T binding.
	prev_scope := push_scope(ctx, st.scope)

	// Process polymorphic parameters (now they'll be added to st.scope)
	st.polymorphic_params = check_record_polymorphic_params(ctx, node.poly_params, &st.is_polymorphic, poly_operands)

	// Signal that polymorphic processing is complete
	// C++ Reference: check_type.cpp:665
	sync.wait_group_done(&st.polymorphic_wait_signal)

	// Check if this is a specialized polymorphic type
	st.is_poly_specialized = check_record_poly_operand_specialization(ctx, struct_type, poly_operands, &st.is_polymorphic)

	// Register polymorphic record entity if needed
	if original_type_for_poly != nil {
		assert(named_type != nil)
		add_polymorphic_record_entity(ctx, node, named_type, original_type_for_poly)
	}

	// Process fields only for non-polymorphic or specialized types
	if !st.is_polymorphic {
		// Check where clauses
		if len(node.where_clauses) > 0 && node.poly_params == nil {
			error(node.where_clauses[0], "'where' clauses can only be used on structures with polymorphic parameters")
		} else {
			where_clause_ok := evaluate_where_clauses(ctx, node, ctx.scope, node.where_clauses, true)
			_ = where_clause_ok
		}

		// Check struct fields
		check_struct_fields(ctx, node, st, min_field_count, struct_type, context_str)

		// Signal that field processing is complete
		// C++ Reference: check_type.cpp:681
		sync.wait_group_done(&st.fields_wait_signal)
	} else {
		// Polymorphic types don't have fields checked now, but we still need to
		// signal completion so waiters don't block forever
		sync.wait_group_done(&st.fields_wait_signal)
	}

	// Process alignment attributes
	// Helper macro equivalent for checking alignment attributes
	check_align := proc(ctx: ^Checker_Context, node: ^ast.Struct_Type, align_expr: ^ast.Expr, align_value: ^i64, attr_name: string, st: ^Type_Struct) -> bool {
		if align_expr == nil {
			return false
		}

		if st.is_packed {
			// C++ Reference: check_type.cpp:686
			error(align_expr, "'#%s' cannot be applied with '#packed'", attr_name)
			return false
		}

		align := i64(1)
		if check_custom_align(ctx, align_expr, &align, attr_name) {
			align_value^ = align
			return true
		}

		return false
	}

	// Check #min_field_align
	check_align(ctx, node, node.min_field_align, &st.custom_min_field_align, "min_field_align", st)

	// Check #max_field_align
	check_align(ctx, node, node.max_field_align, &st.custom_max_field_align, "max_field_align", st)

	// Check #align
	check_align(ctx, node, node.align, &st.custom_align, "align", st)

	// Validate alignment coherence
	// C++ Reference: check_type.cpp (alignment validation section)
	if st.custom_align != 0 && st.custom_align < st.custom_min_field_align {
		error(node.align, "#align(%d) is defined to be less than #min_field_align(%d)", st.custom_align, st.custom_min_field_align)
	}

	if st.custom_max_field_align != 0 && st.custom_align > st.custom_max_field_align {
		error(node.align, "#align(%d) is defined to be greater than #max_field_align(%d)", st.custom_align, st.custom_max_field_align)
	}

	if st.custom_max_field_align != 0 && st.custom_min_field_align > st.custom_max_field_align {
		error(node.min_field_align, "#min_field_align(%d) is defined to be greater than #max_field_align(%d)", st.custom_min_field_align, st.custom_max_field_align)

		// Sort the values to keep code consistent
		a := min(st.custom_min_field_align, st.custom_max_field_align)
		b := max(st.custom_min_field_align, st.custom_max_field_align)
		st.custom_min_field_align = a
		st.custom_max_field_align = b
	}

	// Pop the struct scope that was pushed at the start
	pop_scope(ctx, prev_scope)
}

// check_struct_fields processes struct field declarations
// Ported from check_struct_fields in check_type.cpp:103-229
check_struct_fields :: proc(ctx: ^Checker_Context, node: ^ast.Struct_Type, st: ^Type_Struct, init_field_capacity: int, struct_type: ^Type, context_str: string) {
	// Initialize field arrays
	st.fields = make([dynamic]^Entity, 0, init_field_capacity)
	st.tags = make([dynamic]string, 0, init_field_capacity)
	st.names = make(map[string]^Entity)

	// Count variables for better estimation
	variable_count := 0
	if node.fields != nil {
		for field in node.fields.list {
			#partial switch f in field.derived {
			case ^ast.Field:
				variable_count += max(len(f.names), 1)
			}
		}
	}

	field_src_index := i32(0)
	field_group_index := i32(-1)

	if node.fields == nil {
		return
	}

	for field in node.fields.list {
		// Only process Field nodes
		f, ok := field.derived.(^ast.Field)
		if !ok {
			continue
		}

		field_group_index += 1

		type_expr := f.type
		field_type: ^Type = nil
		_ = f.docs
		_ = f.comment

		// Check field type
		if type_expr != nil {
			field_type = check_type_expr(ctx, type_expr, nil)
			if is_type_polymorphic(field_type) {
				st.is_polymorphic = true
				field_type = nil
			}
		}

		if field_type == nil {
			// C++ Reference: check_type.cpp:146
			error(field, "Invalid parameter type")
			field_type = t_invalid
		}

		if is_type_untyped(field_type) {
			if is_type_untyped_uninit(field_type) {
				// C++ Reference: check_type.cpp:148
				error(field, "Cannot determine parameter type from ---")
			} else {
				// C++ Reference: check_type.cpp:150
				error(field, "Cannot determine parameter type from a nil")
			}
			field_type = t_invalid
		}

		// Check field flags
		is_using := ast.Field_Flag.Using in f.flags
		is_subtype := ast.Field_Flag.Subtype in f.flags

		// Process field names
		for name_node, j in f.names {
			// C++ lines 160-166: Handle both Ident and PolyType
			// if (!ast_node_expect2(name, Ast_Ident, Ast_PolyType)) { continue; }
			// if (name->kind == Ast_PolyType) { name = name->PolyType.type; }

			actual_name_node := name_node

			// Check if this is a PolyType ($T) - if so, extract the inner identifier
			if poly_type, is_poly := name_node.derived.(^ast.Poly_Type); is_poly {
				actual_name_node = poly_type.type
			}

			// Now expect an identifier
			ident, ok2 := actual_name_node.derived.(^ast.Ident)
			if !ok2 {
				// Not an identifier or PolyType, skip
				continue
			}

			field_name := ident.name

			// Create field entity using checker allocator (not context.allocator
			// which may be temp_allocator in tests)
			entity := new(Entity, ctx.checker.allocator)
			entity.kind = .Variable
			entity.token = tokenizer.Token {
				text = field_name,
				pos  = name_node.pos,
			}
			entity.scope = ctx.scope
			entity.state = .Resolved
			entity.variant = Entity_Variable {
				type        = field_type,
				field_index = field_src_index,
			}
			// All struct fields need the .Field flag for lookup
			entity.flags += {.Field}
			if is_using {
				entity.flags += {.Using}
			}

			// C++ lines 171-173
			if is_subtype {
				entity.flags += {.Subtype}
			}

			// Set documentation comments
			if j == 0 {
				// entity.Variable.docs = docs
			}
			if j + 1 == len(f.names) {
				// entity.Variable.comment = comment
			}

			append(&st.fields, entity)

			// Add field to struct's scope for conflict detection
			// This enables detection of conflicts between declared fields and promoted 'using' fields
			// C++ Reference: check_type.cpp - struct fields are added to scope for using conflict detection
			add_entity(ctx, st.scope, name_node, entity)

			// Process field tag
			// C++ lines 183-188: Unquote string literal and validate
			tag := f.tag.text
			if len(tag) != 0 {
				// C++ line 184: if (tag.len != 0 && !unquote_string(permanent_allocator(), &tag, 0, tag.text[0] == '`'))
				unquoted_tag := unquote_string(tag)
				// Note: Odin's unquote_string doesn't return a bool, so we just use the result
				// If the string was invalid, unquote_string will handle it gracefully
				tag = unquoted_tag
			}
			append(&st.tags, tag)

			field_src_index += 1
		}

		// Handle 'using' fields - import symbols into struct scope
		if is_using && len(f.names) > 0 {
			first_type := st.fields[len(st.fields) - 1].variant.(Entity_Variable).type
			soa_ptr := is_type_soa_pointer(first_type)
			t := base_type(type_deref(first_type))

			if (soa_ptr || !does_field_type_allow_using(t)) && len(f.names) >= 1 {
				if ident, ok2 := f.names[0].derived.(^ast.Ident); ok2 {
					field_name := ident.name
					// C++ Reference: check_type.cpp:204
					type_str := type_to_string(t)
					error(ident, "'using' cannot be applied to the field '%s' of type '%s'", field_name, type_str)
					continue
				}
			}

			populate_using_entity_scope(ctx, st.scope, node, f, field_type, 1)
		}

		// Handle 'subtype' fields
		if is_subtype && len(f.names) > 0 {
			first_type := st.fields[len(st.fields) - 1].variant.(Entity_Variable).type
			t := base_type(type_deref(first_type))

			if !does_field_type_allow_using(t) && len(f.names) >= 1 {
				if ident, ok3 := f.names[0].derived.(^ast.Ident); ok3 {
					field_name := ident.name
					// C++ Reference: check_type.cpp:221
					type_str := type_to_string(t)
					error(ident, "'subtype' cannot be applied to the field '%s' of type '%s'", field_name, type_str)
				}
			}
		}
	}
}

// check_custom_align validates custom alignment attributes (#align, #min_field_align, etc.)
// C++ Reference: check_type.cpp:232-266
check_custom_align :: proc(ctx: ^Checker_Context, node: ^ast.Expr, align: ^i64, msg: string) -> bool {
	assert(align != nil)

	// Evaluate the alignment expression
	// C++ lines 234-235
	o: Operand
	check_expr(ctx, &o, node)

	// Must be a constant value
	// C++ lines 236-241
	if o.mode != .Constant {
		if o.mode != .Invalid {
			error(node, "#%s must be a constant", msg)
		}
		return false
	}

	// Must be an integer type
	// C++ lines 243-244
	type := base_type(o.type)
	if !is_type_untyped(type) && !is_type_integer(type) {
		error(node, "#%s must be an integer", msg)
		return false
	}

	// Extract the value
	// C++ lines 244-262
	#partial switch v in o.value {
	case big.Int:
		// C++ lines 247-253: Check if value is too large to fit in i64
		// if (v.used > 1) { error(...); return false; }
		// In Odin's big.Int, we need to check if the value exceeds i64 range
		temp_v := v

		// Check if the value fits in i64 range
		// big.int_get_i128 will give us the value, but we need to validate it fits in i64
		align_value_i128, get_err := big.int_get_i128(&temp_v)

		// Check if value is too large for i64 or had conversion errors
		if get_err != nil || align_value_i128 > i128(max(i64)) || align_value_i128 < i128(min(i64)) {
			// C++ lines 248-252: Value too large, convert to string and error
			str, _ := big.int_itoa_string(&temp_v, 10, false, context.temp_allocator)
			error_node(node, "#%s too large, %s", msg, str)
			return false
		}

		align_value := i64(align_value_i128)

		// Validate power of 2 and >= 1
		// C++ lines 254-258
		if align_value < 1 || !is_power_of_two(align_value) {
			error_node(node, "#%s must be a power of 2, got %d", msg, align_value)
			return false
		}

		// Set output value
		// C++ line 259
		align^ = align_value
		return true
	}

	// Not an integer constant
	// C++ line 264
	error(node, "#%s must be an integer", msg)
	return false
}

check_record_polymorphic_params :: proc(ctx: ^Checker_Context, polymorphic_params: ^ast.Field_List, is_polymorphic: ^bool, poly_operands: []Operand) -> ^Type {
	// C++ Reference: check_type.cpp:347-545
	polymorphic_params_type: ^Type = nil

	// C++ lines 349-351: No params means no polymorphic type
	if polymorphic_params == nil {
		if !is_polymorphic^ {
			is_polymorphic^ = polymorphic_params != nil && len(poly_operands) == 0
		}
		return nil
	}

	// C++ Reference: check_type.cpp:398 - `bool can_check_fields = true;`
	//
	// C++ writes `can_check_fields` in two places and NEVER READS IT - the only signal that
	// leaves this procedure is `is_polymorphic^` (and the returned tuple). This port had turned
	// the dead variable into a live gate on the whole parameter loop, seeded from
	// check_record_poly_operand_specialization - which is not C++'s call to make here (that
	// predicate belongs to check_struct_type / check_union_type, which call it themselves) and
	// which had a nasty consequence:
	//
	// instantiating a record with an operand that is ITSELF still generic - `Cache($T)` inside
	// `init :: proc(c: ^$C/Cache($T))` - made the predicate false, so the loop was skipped, so
	// none of the per-operand `is_polymorphic^ = true` assignments below could run, so
	// check_struct_type saw is_polymorphic == false and went on to check the fields of a record
	// it had not actually specialized. A self-referential field (`head: ^Cache(T)`) then
	// re-entered check_polymorphic_record_type with the same still-generic operand, forever:
	// ~7800 stack frames and a SIGSEGV on core/container/{avl,lru,rbtree}, core/odin/{parser,ast}.
	//
	// The loop now always runs, as in C++.
	// C++ lines 361-538
	{
		scope := ctx.scope

		// C++ lines 365-373: Count total parameters
		param_count := 0
		for field in polymorphic_params.list {
			name_count := max(len(field.names), 1)
			param_count += name_count
		}

		// C++ lines 374-383: Allocate entity storage
		entities := make([dynamic]^Entity, 0, param_count, context.temp_allocator)

		poly_operand_index := 0
		field_group_index := 0

		// C++ lines 386-532: Iterate through field groups
		for field in polymorphic_params.list {
			field_group_index += 1

			// C++ lines 387-389: Get field type expression
			type_expr := field.type
			if type_expr == nil {
				error(field, "Expected a type for this polymorphic parameter")
				continue
			}

			// C++ lines 391-405: Check the type expression
			type := check_type_expr(ctx, type_expr, nil)
			if type == nil {
				continue
			}

			// C++ lines 407-415: Check if this is a type parameter (typeid)
			is_type_param := false
			if typeid_type, ok := type_expr.derived.(^ast.Typeid_Type); ok {
				is_type_param = true
				if typeid_type.specialization != nil {
					type = check_type_expr(ctx, typeid_type.specialization, nil)
				}
			}

			// C++ lines 418-420: Check if type itself is polymorphic
			if is_type_polymorphic(type, true) {
				is_polymorphic^ = true
			}

			// C++ lines 424-435: Handle default parameter value
			param_value: Parameter_Value
			if field.default_value != nil {
				out_type := type
				param_value = handle_parameter_value(ctx, type, &out_type, field.default_value, false)
			}

			// C++ lines 438-456: Validate the type
			if is_type_untyped(type) {
				if is_type_param {
					error(type_expr, "A type parameter cannot be of an untyped type")
				} else {
					error(type_expr, "A constant parameter cannot be of an untyped type")
				}
			}
			if !is_type_param && is_type_polymorphic(type, true) {
				error(type_expr, "A constant parameter cannot be of a polymorphic type")
			}

			// C++ lines 458-460: Constant params must be constant
			if !is_type_param && !are_types_identical(type, t_typeid) {
				type = default_type(type)
			}

			// C++ lines 463-531: Process each name in the field
			name_count := max(len(field.names), 1)
			for name_index in 0..<name_count {
				name_node: ^ast.Node = nil
				if name_index < len(field.names) {
					name_node = field.names[name_index]
				}

				// C++ lines 465-470: Handle PolyType
				actual_name_node := name_node
				if poly_type, is_poly := name_node.derived.(^ast.Poly_Type); is_poly {
					actual_name_node = poly_type.type
				}

				// C++ lines 472-473: Get identifier
				ident, ident_ok := actual_name_node.derived.(^ast.Ident)
				if !ident_ok {
					error(actual_name_node, "Expected an identifier for polymorphic parameter")
					continue
				}

				token := tokenizer.Token{text = ident.name, pos = actual_name_node.pos}
				name: ^ast.Ident = nil
				if ident.name != "_" && ident.name != "" {
					name = ident
				}

				// C++ lines 475-530: Check for poly operand or create entity
				e: ^Entity = nil

				if poly_operand_index < len(poly_operands) {
					operand := &poly_operands[poly_operand_index]
					poly_operand_index += 1

					// C++ lines 478-504: Validate operand
					if operand.mode == .Invalid {
						continue
					}

					t := operand.type
					if t == nil {
						error(operand.expr, "Invalid polymorphic parameter operand")
						continue
					}

					if is_type_param {
						// C++ lines 487-499
						// For type parameters ($T: typeid), the operand should be in Type mode
						// or have a typeid type. When mode=.Type, t is the actual type being passed.
						if operand.mode != .Type && !is_type_typeid(t) {
							error(operand.expr, "Expected a type for this polymorphic parameter")
							continue
						}

						// C++ Reference: check_type.cpp:513-516
						//   if (is_type_polymorphic(base_type(operand.type))) {
						//       *is_polymorphic_ = true;
						//       can_check_fields = false;
						//   }
						//
						// The operand supplied for this type parameter can itself still be
						// generic - `Cache($T)` written inside a `$C/Cache($T)` constraint binds
						// T to a Type_Generic, not to a concrete type. The record is therefore
						// NOT specialized, and saying so here is what stops check_struct_type
						// from descending into fields that refer back to the record. Without
						// this the instantiation recurses until the stack runs out.
						if is_type_polymorphic(base_type(operand.type)) {
							is_polymorphic^ = true
						}

						// When mode is .Type, operand.type is the actual type (e.g., int)
						// We create a type name entity bound to this type
						t = operand.type
						e = alloc_entity_type_name(ctx.scope, token, t)
						e.flags += {.Poly_Const}
						// Note: Don't call set_base_type here - the entity's type is already t
						// and t already has its base set correctly
					} else {
						// C++ Reference: check_type.cpp:529-543 - constant parameter.
						//
						// C++ performs NO validation of the operand here. The declared
						// parameter type was already vetted by
						// check_constant_parameter_value (check_type.cpp:486); the operand
						// itself may legitimately still be generic - `Array($T, $SHIFT)`
						// written inside a `^$X/Array($T, $SHIFT)` constraint binds SHIFT to
						// a Type_Generic, not to a constant - and that is signalled by
						// setting is_polymorphic^, not by erroring.
						if is_type_proc(type) {
							t = determine_type_from_polymorphic(ctx, type, operand^)
						}
						if is_type_polymorphic(base_type(t)) {
							is_polymorphic^ = true
						}
						if e == nil {
							e = alloc_entity_const_param(scope, token, t, operand.value, is_type_polymorphic(t))
							if const_data, const_ok := &e.variant.(Entity_Constant); const_ok {
								const_data.param_value = param_value
								const_data.field_group_index = i32(field_group_index)
							}
						}
					}
				} else {
					// C++ lines 517-526: No operand, create entity for polymorphic param
					if is_type_param {
						e = alloc_entity_type_name(scope, token, type)
						e.flags += {.Poly_Const}
					} else {
						e = alloc_entity_const_param(scope, token, type, param_value.value, is_type_polymorphic(type))
						if const_data, const_ok2 := &e.variant.(Entity_Constant); const_ok2 {
							const_data.field_group_index = i32(field_group_index)
							const_data.param_value = param_value
						}
					}
				}

				// C++ lines 528-530: Finalize entity
				e.state = .Resolved
				add_entity(ctx, scope, name, e)
				append(&entities, e)
			}
		}

		// C++ lines 534-538: Create tuple type from entities
		if len(entities) > 0 {
			polymorphic_params_type = alloc_type_tuple(entities[:])
		}
	}

	// C++ lines 541-544: Update is_polymorphic flag
	if !is_polymorphic^ {
		is_polymorphic^ = polymorphic_params != nil && len(poly_operands) == 0
	}

	return polymorphic_params_type
}

// check_record_poly_operand_specialization validates polymorphic record operand specialization
// Returns true if all operands are concrete (non-polymorphic) and can be used for specialization
// C++ Reference: check_type.cpp:547-573
check_record_poly_operand_specialization :: proc(ctx: ^Checker_Context, record_type: ^Type, poly_operands: []Operand, is_polymorphic: ^bool) -> bool {
	// No operands means no specialization
	// C++ line 548-550
	if poly_operands == nil || len(poly_operands) == 0 {
		return false
	}

	// Check each operand for polymorphic types
	// C++ lines 551-571
	for operand in poly_operands {
		// If any operand is polymorphic, this is not a concrete specialization
		// C++ lines 553-555
		if is_type_polymorphic(operand.type) {
			return false
		}

		// Check for cyclic type dependency
		// C++ lines 556-559
		if record_type == operand.type {
			// NOTE: Cycle detected - can't specialize with itself
			return false
		}

		// Handle the edge case for where clauses with typeid parameters
		// C++ lines 560-570
		if operand.mode == .Type {
			// ANNOYING EDGE CASE FOR `where` clauses
			// If the operand is a type name entity with type typeid,
			// mark as polymorphic but don't specialize
			if entity := entity_of_node(ctx.info, operand.expr); entity != nil {
				if entity.kind == .Type_Name {
					if entity_t := entity_type(entity); entity_t != nil {
						if is_type_typeid(entity_t) {
							is_polymorphic^ = true
							return false
						}
					}
				}
			}
		}
	}

	// All operands are concrete - this is a valid specialization
	// C++ line 572
	return true
}

// ensure_polymorphic_record_entity_has_gen_types ensures a polymorphic record has gen_types_data allocated
// Returns the gen_types_data for the original type
// C++ Reference: check_type.cpp:269-284
ensure_polymorphic_record_entity_has_gen_types :: proc(ctx: ^Checker_Context, original_type: ^Type) -> ^Gen_Types_Data {
	// C++ line 272: assert(original_type->kind == Type_Named)
	assert(original_type != nil && original_type.kind == .Named)

	named := &original_type.variant.(Type_Named)

	// C++ line 273: mutex_lock(&original_type->Named.gen_types_data_mutex)
	sync.mutex_lock(&named.gen_types_data_mutex)
	defer sync.mutex_unlock(&named.gen_types_data_mutex)

	// C++ lines 274-278: Allocate gen_types_data if it doesn't exist
	if named.gen_types_data == nil {
		gen_types := new(Gen_Types_Data)
		gen_types.types = make([dynamic]^Entity)
		named.gen_types_data = gen_types
	}

	// C++ lines 279-282: Return the gen_types_data
	return named.gen_types_data
}

add_polymorphic_record_entity :: proc(
	ctx: ^Checker_Context,
	node: ^ast.Node, // Can be Struct_Type, Union_Type, etc.
	named_type: ^Type,
	original_type: ^Type,
) {
	// C++ Reference: check_type.cpp:287-334
	// C++ line 288: assert(is_type_named(named_type))
	assert(named_type != nil && named_type.kind == .Named)
	// C++ line 289: assert(original_type->kind == Type_Named)
	assert(original_type != nil && original_type.kind == .Named)

	// C++ line 291: Scope *s = ctx->scope->parent
	// Add null check to prevent crash when ctx.scope is nil
	s: ^Scope = nil
	if ctx.scope != nil {
		s = ctx.scope.parent
	}

	// C++ lines 293-296: Get package from original type
	pkg := ctx.pkg
	orig_named := &original_type.variant.(Type_Named)
	if orig_named.type_name != nil && orig_named.type_name.pkg != nil {
		pkg = orig_named.type_name.pkg
	}

	// C++ lines 298-301: Default to current context's pkg if unavailable
	if pkg == nil {
		pkg = ctx.pkg
	}

	// C++ lines 303-317: Create entity for the specialized type
	e: ^Entity
	{
		// C++ line 305-307: Create token from node and named type name
		token := tokenizer.Token {
			text = named_type.variant.(Type_Named).name,
			pos  = node.pos,
			kind = .String,
		}

		// C++ line 311: e = alloc_entity_type_name(s, token, named_type)
		e = alloc_entity_type_name(s, token, named_type, .Resolved)
		// C++ line 312: e->state = EntityState_Resolved
		e.state = .Resolved
		// C++ line 313: e->file = ctx->file
		e.file = ctx.file
		// C++ line 314: e->pkg = pkg
		e.pkg = pkg
		// C++ line 315: e->TypeName.original_type_for_parapoly = original_type
		if type_name, ok := &e.variant.(Entity_Type_Name); ok {
			type_name.original_type_for_parapoly = original_type
		}
		// C++ line 316: add_entity_use(ctx, node, e)
		add_entity_use(ctx, node, e)
	}

	// C++ line 319: named_type->Named.type_name = e
	new_named := &named_type.variant.(Type_Named)
	new_named.type_name = e

	// C++ lines 320-322: Copy ObjC metadata from original type
	if orig_type_name, ok1 := orig_named.type_name.variant.(Entity_Type_Name); ok1 {
		if e_type_name, ok2 := &e.variant.(Entity_Type_Name); ok2 {
			e_type_name.objc_class_name = orig_type_name.objc_class_name
			e_type_name.objc_metadata = orig_type_name.objc_metadata
		}
	}

	// C++ lines 324-333: Add to gen_types array with thread safety
	found_gen_types := ensure_polymorphic_record_entity_has_gen_types(ctx, original_type)
	sync.mutex_lock(&found_gen_types.mutex)
	defer sync.mutex_unlock(&found_gen_types.mutex)

	// C++ lines 328-332: Check if already in array
	for prev in found_gen_types.types {
		if prev == e {
			return
		}
	}
	// C++ line 333: array_add(&found_gen_types->types, e)
	append(&found_gen_types.types, e)
}

// is_type_polymorphic checks if a type contains polymorphic parameters
// C++ Reference: types.cpp:2333-2480
is_type_polymorphic :: proc(t: ^Type, or_specialized := false) -> bool {
	if t == nil {
		return false
	}

	// Recursion guard - prevents infinite loops when checking cyclic types
	// C++ lines 2337-2339
	if .In_Process_Of_Checking_Polymorphic in t.flags {
		return false
	}

	#partial switch t.kind {
	case .Generic:
		// Type_Generic is always polymorphic (e.g., $T)
		return true

	case .Named:
		// C++ lines 2345-2352: Named types delegate to their base type
		// Set flag to prevent infinite recursion for cyclic named types
		if named, ok := t.variant.(Type_Named); ok {
			flags := t.flags
			t.flags += {.In_Process_Of_Checking_Polymorphic}
			result := is_type_polymorphic(named.base, or_specialized)
			t.flags = flags
			return result
		}

	case .Pointer:
		// C++ lines 2354-2355
		if ptr, ok := t.variant.(Type_Pointer); ok {
			return is_type_polymorphic(ptr.elem, or_specialized)
		}

	case .Multi_Pointer:
		// C++ lines 2357-2358
		if mp, ok := t.variant.(Type_Multi_Pointer); ok {
			return is_type_polymorphic(mp.elem, or_specialized)
		}

	case .Soa_Pointer:
		// C++ lines 2360-2361
		if soa, ok := t.variant.(Type_Soa_Pointer); ok {
			return is_type_polymorphic(soa.elem, or_specialized)
		}

	case .Enumerated_Array:
		// C++ lines 2363-2367
		if ea, ok := t.variant.(Type_Enumerated_Array); ok {
			if is_type_polymorphic(ea.index, or_specialized) {
				return true
			}
			return is_type_polymorphic(ea.elem, or_specialized)
		}

	case .Array:
		// C++ lines 2368-2372
		if arr, ok := t.variant.(Type_Array); ok {
			// Check for generic count (polymorphic array sizes)
			if arr.generic_count != nil {
				return true
			}
			return is_type_polymorphic(arr.elem, or_specialized)
		}

	case .Simd_Vector:
		// C++ lines 2376-2380
		if sv, ok := t.variant.(Type_Simd_Vector); ok {
			// C++ lines 2377-2379: Check for polymorphic count
			if sv.generic_count != nil {
				return true
			}
			return is_type_polymorphic(sv.elem, or_specialized)
		}

	case .Dynamic_Array:
		// C++ lines 2378-2379
		if da, ok := t.variant.(Type_Dynamic_Array); ok {
			return is_type_polymorphic(da.elem, or_specialized)
		}

	case .Slice:
		// C++ lines 2380-2381
		if slice, ok := t.variant.(Type_Slice); ok {
			return is_type_polymorphic(slice.elem, or_specialized)
		}

	case .Matrix:
		// C++ lines 2383-2390
		if mat, ok := t.variant.(Type_Matrix); ok {
			// Check for generic dimensions (polymorphic matrix sizes)
			if mat.generic_row_count != nil {
				return true
			}
			if mat.generic_column_count != nil {
				return true
			}
			return is_type_polymorphic(mat.elem, or_specialized)
		}

	case .Tuple:
		// C++ lines 2392-2402
		if tuple, ok := t.variant.(Type_Tuple); ok {
			for e in tuple.variables {
				if e.kind == .Constant {
					// Check if constant has unresolved polymorphic value
					if const_var, const_ok := e.variant.(Entity_Constant); const_ok {
						if const_var.value == nil {
							return or_specialized
						}
					}
				} else if is_type_polymorphic(entity_type(e), or_specialized) {
					return true
				}
			}
		}

	case .Proc:
		// C++ lines 2404-2416
		if proc_type, ok := t.variant.(Type_Proc); ok {
			if proc_type.is_polymorphic {
				return true
			}
			if proc_type.param_count > 0 && is_type_polymorphic(proc_type.params, or_specialized) {
				return true
			}
			if proc_type.result_count > 0 && is_type_polymorphic(proc_type.results, or_specialized) {
				return true
			}
		}

	case .Enum:
		// C++ lines 2418-2425
		if enum_type, ok := t.variant.(Type_Enum); ok {
			if enum_type.base_type != nil {
				return is_type_polymorphic(enum_type.base_type, or_specialized)
			}
		}

	case .Union:
		// C++ lines 2426-2438
		if union_type, ok := t.variant.(Type_Union); ok {
			if union_type.is_polymorphic {
				return true
			}
			if or_specialized && union_type.is_poly_specialized {
				return true
			}
		}

	case .Struct:
		// C++ lines 2439-2446
		if struct_type, ok := t.variant.(Type_Struct); ok {
			if struct_type.is_polymorphic {
				return true
			}
			if or_specialized && struct_type.is_poly_specialized {
				return true
			}
		}

	case .Map:
		// C++ lines 2448-2458
		if map_type, ok := t.variant.(Type_Map); ok {
			if map_type.key == nil || map_type.value == nil {
				return false
			}
			if is_type_polymorphic(map_type.key, or_specialized) {
				return true
			}
			if is_type_polymorphic(map_type.value, or_specialized) {
				return true
			}
		}

	case .Bit_Set:
		// C++ lines 2460-2467
		if bs, ok := t.variant.(Type_Bit_Set); ok {
			if is_type_polymorphic(bs.elem, or_specialized) {
				return true
			}
			if bs.underlying != nil && is_type_polymorphic(bs.underlying, or_specialized) {
				return true
			}
		}
	}

	return false
}

// get_record_polymorphic_params retrieves polymorphic parameters from struct/union types
// C++ Reference: types.cpp:2313-2330
get_record_polymorphic_params :: proc(t: ^Type) -> ^Type_Tuple {
	if t == nil {
		return nil
	}

	bt := base_type(t)

	#partial switch bt.kind {
	case .Struct:
		// Wait for polymorphic params to be ready (if using wait groups)
		// sync.wait_group_wait(&bt.variant.(Type_Struct).polymorphic_wait_signal)
		if st, ok := bt.variant.(Type_Struct); ok {
			if st.polymorphic_params != nil && st.polymorphic_params.kind == .Tuple {
				if tuple, tuple_ok := &st.polymorphic_params.variant.(Type_Tuple); tuple_ok {
					return tuple
				}
			}
		}

	case .Union:
		// Wait for polymorphic params to be ready (if using wait groups)
		// sync.wait_group_wait(&bt.variant.(Type_Union).polymorphic_wait_signal)
		if ut, ok := bt.variant.(Type_Union); ok {
			if ut.polymorphic_params != nil && ut.polymorphic_params.kind == .Tuple {
				if tuple, tuple_ok := &ut.polymorphic_params.variant.(Type_Tuple); tuple_ok {
					return tuple
				}
			}
		}
	}

	return nil
}

// find_polymorphic_record_entity searches for an existing polymorphic record specialization
// that matches the given operands. Returns the entity if found, nil otherwise.
// C++ Reference: check_expr.cpp:124
find_polymorphic_record_entity :: proc(ctx: ^Checker_Context, original_type: ^Type, operands: []Operand) -> ^Entity {
	if original_type == nil || original_type.kind != .Named {
		return nil
	}

	named := &original_type.variant.(Type_Named)
	if named.gen_types_data == nil {
		return nil
	}

	// Lock for thread-safe access
	sync.mutex_lock(&named.gen_types_data.mutex)
	defer sync.mutex_unlock(&named.gen_types_data.mutex)

	// Search through existing specializations
	for entity in named.gen_types_data.types {
		if entity == nil {
			continue
		}

		entity_t := entity_type(entity)
		if entity_t == nil {
			continue
		}

		// Get the polymorphic params of this specialization
		spec_params := get_record_polymorphic_params(entity_t)
		if spec_params == nil {
			continue
		}

		// Check if operand count matches
		if len(operands) != len(spec_params.variables) {
			continue
		}

		// Compare each operand type with the specialization's parameter types
		match := true
		for operand, i in operands {
			if i >= len(spec_params.variables) {
				match = false
				break
			}

			param_entity := spec_params.variables[i]
			if param_entity == nil {
				match = false
				break
			}

			param_type := entity_type(param_entity)

			// For type parameters, compare the types
			if operand.mode == .Type {
				if !are_types_identical(operand.type, param_type) {
					match = false
					break
				}
			} else if operand.mode == .Constant {
				// For constant parameters, compare types and values
				if !are_types_identical(operand.type, param_type) {
					match = false
					break
				}
				// Also check constant value if applicable
				if param_entity.kind == .Constant {
					const_entity := param_entity.variant.(Entity_Constant)
					if !compare_exact_values(.Cmp_Eq, operand.value, const_entity.value) {
						match = false
						break
					}
				}
			} else {
				match = false
				break
			}
		}

		if match {
			return entity
		}
	}

	return nil
}

// lookup_polymorphic_record_parameter looks up a parameter by name in a polymorphic record
// Returns the parameter index if found, -1 otherwise.
// C++ Reference: check_expr.cpp:7612
lookup_polymorphic_record_parameter :: proc(t: ^Type, name: string) -> int {
	params := get_record_polymorphic_params(t)
	if params == nil {
		return -1
	}

	for entity, i in params.variables {
		if entity != nil && entity.token.text == name {
			return i
		}
	}

	return -1
}

// check_polymorphic_record_type validates and potentially instantiates a polymorphic record type
// with the given operands. Returns the specialized type if successful, nil otherwise.
// C++ Reference: check_expr.cpp:7635
check_polymorphic_record_type :: proc(ctx: ^Checker_Context, original_type: ^Type, operands: []Operand, node: ^ast.Node) -> ^Type {
	if original_type == nil {
		return nil
	}

	// Check if it's actually a polymorphic record
	if !is_type_polymorphic_record_unspecialized(original_type) {
		return original_type
	}

	// First, try to find an existing specialization
	existing := find_polymorphic_record_entity(ctx, original_type, operands)
	if existing != nil {
		return entity_type(existing)
	}

	// Need to create a new specialization
	// Get the base type to determine if it's a struct or union
	bt := base_type(original_type)
	if bt == nil {
		return nil
	}

	// Get the named type info for the original
	named, named_ok := original_type.variant.(Type_Named)
	if !named_ok {
		return nil
	}

	// Create a new named type for the specialization
	new_named_type := alloc_type_named(named.name, nil, nil, ctx.checker.allocator)

	#partial switch bt.kind {
	case .Struct:
		st, st_ok := bt.variant.(Type_Struct)
		if !st_ok || st.node == nil {
			return nil
		}

		// Get the actual Struct_Type node from the Node
		struct_node, struct_node_ok := st.node.derived.(^ast.Struct_Type)
		if !struct_node_ok {
			return nil
		}

		// Create new struct type with initialized variant
		new_struct_type := alloc_type_struct(ctx.checker)

		// C++ Reference: check_expr.cpp:8451. `polymorphic_parent` links an instance
		// back to the generic record it came from. The port declared and READ this field
		// (types.odin:853, check_builtin.odin:6932, check_type_specialization_to) but
		// never wrote it, so it was permanently nil and every reader silently took the
		// "not polymorphic" path — including the `$Q/Queue` specialization test.
		if s, s_ok := &new_struct_type.variant.(Type_Struct); s_ok {
			s.polymorphic_parent = original_type
		}

		// Set up the named type relationship
		set_base_type(new_named_type, new_struct_type)

		// Check struct with the provided operands
		check_struct_type(ctx, new_struct_type, struct_node, operands, new_named_type, original_type)

		return new_named_type

	case .Union:
		ut, ut_ok := bt.variant.(Type_Union)
		if !ut_ok || ut.node == nil {
			return nil
		}

		// Get the actual Union_Type node from the Node
		union_node, union_node_ok := ut.node.derived.(^ast.Union_Type)
		if !union_node_ok {
			return nil
		}

		// Create new union type with initialized variant
		new_union_type := alloc_type_union(ctx.checker)

		// C++ Reference: check_expr.cpp:8461 — see the struct arm above.
		if u, u_ok := &new_union_type.variant.(Type_Union); u_ok {
			u.polymorphic_parent = original_type
		}

		// Set up the named type relationship
		set_base_type(new_named_type, new_union_type)

		// Check union with the provided operands
		check_union_type(ctx, new_union_type, union_node, operands, new_named_type, original_type)

		return new_named_type
	}

	return nil
}

// C++ Reference: types.cpp:2242-2247
is_type_untyped_uninit :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return basic.kind == .Untyped_Uninit
}

// C++ Reference: types.cpp:2236-2241
is_type_untyped_nil :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if bt == nil || bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	// NOTE(bill): checking for `nil` or `---` at once is just to improve the error handling
	return basic.kind == .Untyped_Nil || basic.kind == .Untyped_Uninit
}

// type_deref dereferences pointer and SOA pointer types
// Reference: types.cpp:1202-1225
type_deref :: proc(t: ^Type) -> ^Type {
	if t == nil {
		return nil
	}

	bt := base_type(t)
	if bt == nil {
		return nil
	}

	#partial switch bt.kind {
	case .Pointer:
		ptr := bt.variant.(Type_Pointer)
		return ptr.elem

	case .Soa_Pointer:
		// SOA pointer dereferences to the soa_elem of the underlying struct
		// C++ ref: types.cpp:1209-1214
		soa_ptr := bt.variant.(Type_Soa_Pointer)
		elem := base_type(soa_ptr.elem)

		// The elem should be a struct with soa_kind != None
		if elem.kind == .Struct {
			struc := elem.variant.(Type_Struct)
			assert(struc.soa_kind != .None, "SOA pointer elem must have non-zero soa_kind")
			return struc.soa_elem
		}
		// Fallback if invariant is violated
		return soa_ptr.elem
	}

	return t
}

is_type_soa_pointer :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	return bt.kind == .Soa_Pointer
}

is_type_struct :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	return bt.kind == .Struct
}

// Note: is_type_array is defined in types.odin (Week 1 Group 1 critical predicates)

does_field_type_allow_using :: proc(t: ^Type) -> bool {
	// Types that can be used with 'using' keyword
	// C++ Reference: check_type.cpp:91-101
	bt := base_type(t)

	if is_type_struct(t) {
		return true
	} else if is_type_array(t) {
		arr := bt.variant.(Type_Array)
		return arr.count <= 4 // Small arrays can be 'used'
	} else if is_type_bit_field(t) {
		return true
	}

	return false
}

// populate_using_array_index creates an array element accessor entity (x, y, z, w, r, g, b, a)
// C++ Reference: check_type.cpp:5-32
populate_using_array_index :: proc(ctx: ^Checker_Context, target_scope: ^Scope, node: ^ast.Struct_Type, field: ^ast.Field, t: ^Type, name: string, idx: i32) {
	bt := base_type(t)
	assert(bt.kind == .Array)

	// Check for existing entity with this name
	// C++ lines 8-19
	e := scope_lookup_current(target_scope, name)
	if e != nil {
		error(e.token, "'%s' is already declared", name)
	} else {
		// Create array element accessor entity
		// C++ lines 21-31
		tok := tokenizer.Token {
			text = name,
			pos  = {},
		}

		if field != nil {
			if len(field.names) > 0 {
				if ident, ok := field.names[0].derived.(^ast.Ident); ok {
					tok.pos = ident.pos
				}
			} else if field.type != nil {
				tok.pos = field.type.pos
			}
		}

		// Create entity for array element
		// C++ line 29
		arr := bt.variant.(Type_Array)
		f := alloc_entity_array_elem(nil, tok, arr.elem, idx)

		// Add entity to scope
		add_entity(ctx, target_scope, nil, f)
	}
}

// populate_using_entity_scope imports fields from 'using' types into the specified scope
// C++ Reference: check_type.cpp:34-89
populate_using_entity_scope :: proc(ctx: ^Checker_Context, target_scope: ^Scope, node: ^ast.Struct_Type, field: ^ast.Field, field_type: ^Type, level: int) {
	if field_type == nil {
		return
	}

	// C++ lines 38-39
	original_type := field_type
	t := base_type(type_deref(field_type))

	// Handle struct types
	// C++ lines 46-66
	if t.kind == .Struct {
		st := t.variant.(Type_Struct)
		for f in st.fields {
			assert(f.kind == .Variable)
			name := f.token.text

			// Check for name conflicts
			// C++ lines 50-59
			e := scope_lookup_current(target_scope, name)
			if e != nil && name != "_" {
				error(e.token, "'%s' is already declared, through 'using' from '%v'", name, original_type)
			} else {
				// Add field entity to target scope
				// C++ line 61
				add_entity(ctx, target_scope, nil, f)

				// Recursively process nested 'using' fields
				// C++ lines 62-64
				if .Using in f.flags {
					populate_using_entity_scope(ctx, target_scope, node, field, entity_type(f), level + 1)
				}
			}
		}
	} else if t.kind == .Array {
		// Handle small arrays (count <= 4) with x, y, z, w or r, g, b, a accessors
		// C++ lines 67-88
		arr := t.variant.(Type_Array)
		if arr.count <= 4 {
			switch arr.count {
			case 4:
				// w/a for 4th element
				// C++ lines 69-71
				populate_using_array_index(ctx, target_scope, node, field, t, "w", 3)
				populate_using_array_index(ctx, target_scope, node, field, t, "a", 3)
				fallthrough
			case 3:
				// z/b for 3rd element
				// C++ lines 73-75
				populate_using_array_index(ctx, target_scope, node, field, t, "z", 2)
				populate_using_array_index(ctx, target_scope, node, field, t, "b", 2)
				fallthrough
			case 2:
				// y/g for 2nd element
				// C++ lines 77-79
				populate_using_array_index(ctx, target_scope, node, field, t, "y", 1)
				populate_using_array_index(ctx, target_scope, node, field, t, "g", 1)
				fallthrough
			case 1:
				// x/r for 1st element
				// C++ lines 81-83
				populate_using_array_index(ctx, target_scope, node, field, t, "x", 0)
				populate_using_array_index(ctx, target_scope, node, field, t, "r", 0)
				fallthrough
			case:
				// C++ lines 85-86
				break
			}
		}
	}
}

// check_union_type_expr creates and validates a union type from AST
// Entry point called from check_type_internal
check_union_type_expr :: proc(ctx: ^Checker_Context, ut: ^ast.Union_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create the union type
	union_type := new(Type, ctx.checker.allocator)
	union_type.kind = .Union
	union_type.variant = Type_Union {
		node  = ut,
		scope = ctx.scope,
	}

	// Initialize wait group for multi-threaded polymorphic resolution
	ut_var := &union_type.variant.(Type_Union)
	sync.wait_group_add(&ut_var.polymorphic_wait_signal, 1)

	type^ = union_type
	set_base_type(named_type, union_type)

	// Delegate to the full check_union_type function
	check_union_type(ctx, union_type, ut, nil, named_type, nil)

	return true
}

// check_enum_type_expr creates and validates an enum type from AST
// Entry point called from check_type_internal
check_enum_type_expr :: proc(ctx: ^Checker_Context, et: ^ast.Enum_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create the enum type
	enum_type := new(Type, ctx.checker.allocator)
	enum_type.kind = .Enum

	type^ = enum_type
	set_base_type(named_type, enum_type)

	// C++ Reference: check_type.cpp:3890-3892 wraps check_enum_type in
	// check_open_scope/check_close_scope, and check_type.cpp:885 stores THAT scope
	// (the enum's own) as Enum.scope. The members are then added into it.
	//
	// Storing the enclosing scope here instead is wrong three ways:
	//   1. the duplicate-member check (scope_lookup_current, below) sees every
	//      package-level declaration and false-positives on any enum member whose
	//      name collides with one — e.g. core/reflect's `Type_Kind.Bit_Field`
	//      against its package-level `Bit_Field :: struct`;
	//   2. selector resolution against Enum.scope (C++ check_expr.cpp:9332) would
	//      search the wrong scope;
	//   3. check_decl_helpers.odin:1368 takes `original_enum.scope.parent` to
	//      recover the enclosing scope (mirroring check_decl.cpp:419), which lands
	//      on the grandparent when `scope` is already the enclosing one.
	// C++ Reference: check_type.cpp:3887 and :3896 set and clear this around the enum
	// check. The port declared Checker_Context.in_enum_type and read it in
	// convert_to_typed (check_expr.odin:3567, mirroring check_expr.cpp:5044) but NEVER
	// set it, so that read was permanently false and the enum arm was dead code.
	// With it false, convert_to_typed takes base_type(target) instead of
	// core_type(target), so an untyped integer constant cannot reach an enum's backing
	// integer type and every `A = 0` member fails to convert.
	prev_in_enum_type := ctx.in_enum_type
	ctx.in_enum_type = true

	check_open_scope(ctx, et)
	enum_type.variant = Type_Enum {
		base_type = t_int,
		node      = et,
		scope     = ctx.scope, // C++ check_type.cpp:885 — the freshly opened enum scope
	}
	check_enum_type(ctx, enum_type, named_type, et)
	check_close_scope(ctx)

	ctx.in_enum_type = prev_in_enum_type

	return true
}

// check_union_type performs full union type validation
// Ported from check_union_type in check_type.cpp:725-827
check_union_type :: proc(ctx: ^Checker_Context, union_type: ^Type, node: ^ast.Union_Type, poly_operands: []Operand, named_type: ^Type, original_type_for_poly: ^Type) {
	assert(union_type.kind == .Union)

	// Access the union variant
	ut := &union_type.variant.(Type_Union)

	// Set basic union properties
	ut.node = node
	ut.scope = ctx.scope

	// Process polymorphic parameters
	ut.polymorphic_params = check_record_polymorphic_params(ctx, node.poly_params, &ut.is_polymorphic, poly_operands)

	// Signal that polymorphic processing is complete
	// C++ Reference: check_type.cpp - union polymorphic wait signal
	sync.wait_group_done(&ut.polymorphic_wait_signal)

	// Check if this is a specialized polymorphic type
	ut.is_poly_specialized = check_record_poly_operand_specialization(ctx, union_type, poly_operands, &ut.is_polymorphic)

	// Register polymorphic record entity if needed
	if original_type_for_poly != nil {
		assert(named_type != nil)
		add_polymorphic_record_entity(ctx, node, named_type, original_type_for_poly)
	}

	// Process where clauses
	if !ut.is_polymorphic {
		if len(node.where_clauses) > 0 && node.poly_params == nil {
			error(node.where_clauses[0], "'where' clauses can only be used on unions with polymorphic parameters")
		} else {
			where_clause_ok := evaluate_where_clauses(ctx, node, ctx.scope, node.where_clauses, true)
			_ = where_clause_ok
		}
	}

	// Process union variants
	ut.variants = make([dynamic]^Type, 0, len(node.variants))

	for variant_node in node.variants {
		t := check_type_expr(ctx, variant_node, nil)

		// Skip variant addition for unspecialized polymorphic unions
		if ut.is_polymorphic && len(poly_operands) == 0 {
			// NOTE: don't add any variants if this is an unspecialized polymorphic record
			continue
		}

		if t != nil && t != t_invalid {
			ok := true
			t = default_type(t)

			// Validate variant type
			if is_type_untyped(t) || is_type_empty_union(t) {
				ok = false
				// C++ Reference: check_type.cpp:769
				type_str := type_to_string(t)
				error(variant_node, "Invalid variant type in union '%s'", type_str)
			} else {
				// Check for duplicate variant types
				for existing_variant, j in ut.variants {
					if union_variant_index_types_equal(t, existing_variant) {
						ok = false
						// C++ Reference: check_type.cpp:775
						type_str := type_to_string(t)
						error(variant_node, "Duplicate variant type '%s'", type_str)
						if j < len(node.variants) {
							pos_str := token_pos_to_string(node.variants[j].pos)
							error_line("\tPrevious found at %s\n", pos_str)
						}
						break
					}
				}
			}

			if ok {
				append(&ut.variants, t)

				// Validate #shared_nil constraint
				if node.kind == .shared_nil {
					if !type_has_nil(t) {
						// C++ Reference: check_type.cpp:783
						type_str := type_to_string(t)
						error(variant_node, "Each variant of a union with #shared_nil must have a 'nil' value, got %s", type_str)
					}
				}
			}
		}
	}

	// Map AST union kind to Type_Union kind
	switch node.kind {
	case .Normal:
		ut.kind = .Normal
	case .no_nil:
		ut.kind = .No_Nil
	case .maybe:
		ut.kind = .Maybe
	case .shared_nil:
		// shared_nil is represented as Normal in the type system
		// The semantic difference is enforced during variant checking above
		ut.kind = .Normal
	}

	// Validate #no_nil constraint
	if node.kind == .no_nil {
		// For unspecialized polymorphic unions, skip variant count check
		if ut.is_polymorphic && len(poly_operands) == 0 {
			assert(len(ut.variants) == 0)
			if len(node.variants) != 1 {
				// Fall through to error below
			} else {
				// Single variant in source, this is fine for unspecialized
			}
		}

		if len(ut.variants) < 2 {
			// C++ Reference: check_type.cpp:811
			error(node, "A union with #no_nil must have at least 2 variants")
		}
	}

	// Process #align attribute
	if node.align != nil {
		custom_align := i64(1)
		if check_custom_align(ctx, node.align, &custom_align, "align") {
			if len(ut.variants) == 0 {
				// C++ Reference: check_type.cpp:820
				error(node.align, "An empty union cannot have a custom alignment")
			} else {
				ut.custom_align = custom_align
			}
		}
	}
}

// check_enum_type performs full enum type validation
// Ported from check_enum_type in check_type.cpp:828-970
check_enum_type :: proc(ctx: ^Checker_Context, enum_type: ^Type, named_type: ^Type, node: ^ast.Enum_Type) {
	assert(enum_type.kind == .Enum)

	// Access the enum variant
	et := &enum_type.variant.(Type_Enum)

	// Set basic enum properties
	et.base_type = t_int
	et.scope = ctx.scope

	// Check and validate base type
	base_type := t_int
	if node.base_type != nil {
		base_type = check_type(ctx, node.base_type)
	}

	if base_type == nil || base_type == t_invalid || !is_type_integer(base_type) {
		// C++ Reference: check_type.cpp:841
		error(node, "Base type for enumeration must be an integer")
		return
	}

	if is_type_enum(base_type) {
		// C++ Reference: check_type.cpp:845
		error(node, "Base type for enumeration cannot be another enumeration")
		return
	}

	if is_type_integer_128bit(base_type) {
		// C++ Reference: check_type.cpp:849
		error(node, "Base type for enumeration cannot be a 128-bit integer")
		return
	}

	// NOTE: Must be set up here for the check_expr/check_init_constant system
	et.base_type = base_type

	// Initialize field arrays
	et.fields = make([dynamic]^Entity, 0, len(node.fields))

	// Determine the constant type for enum values
	constant_type := enum_type
	if named_type != nil {
		constant_type = named_type
	}

	// Initialize iota and min/max tracking
	iota := exact_value_i64(-1)
	min_value := exact_value_i64(0)
	max_value := exact_value_i64(0)
	min_value_index := i64(0)
	max_value_index := i64(0)
	min_value_set := false
	max_value_set := false

	// Reserve scope capacity
	// scope_reserve(ctx.scope, len(node.fields))

	// Process each enum field
	for field, i in node.fields {
		// Fields can be either:
		// 1. Field_Value (e.g., Red = 0) - has field and value
		// 2. Ident (e.g., Red,) - just a name with auto-incremented value
		ident_node: ^ast.Expr
		init_node: ^ast.Expr
		docs: ^ast.Comment_Group
		comment: ^ast.Comment_Group

		if field_value, is_fv := field.derived.(^ast.Field_Value); is_fv {
			// Field_Value: name = value
			ident_node = field_value.field
			init_node = field_value.value
			docs = field_value.docs
			comment = field_value.comment
		} else if _, is_ident := field.derived.(^ast.Ident); is_ident {
			// Just an Ident: name with auto-increment
			ident_node = field
			init_node = nil
			docs = nil
			comment = nil
		} else {
			// C++ Reference: check_type.cpp:880
			error(field, "An enum field's name must be an identifier")
			continue
		}

		// Validate identifier
		ident, ident_ok := ident_node.derived.(^ast.Ident)
		if !ident_ok {
			// C++ Reference: check_type.cpp:886
			error(field, "An enum field's name must be an identifier")
			continue
		}

		name := ident.name

		// C++ line 851: u32 entity_flags = 0
		entity_flags: Entity_Constant_Flags = {}

		// Process field value
		if init_node != nil {
			// Explicit value provided
			o: Operand
			check_expr(ctx, &o, init_node)

			if o.mode != .Constant {
				// C++ Reference: check_type.cpp:898
				error(init_node, "Enumeration value must be a constant")
				o.mode = .Invalid
			}

			if o.mode != .Invalid {
				// C++ Reference: check_type.cpp:958 — `constant_type` is the named enum
				// type (or the enum type itself), NOT the backing integer.
				//
				// This previously had to pass base_type as a compensation: with
				// ctx.in_enum_type never being set, convert_to_typed could not take an
				// untyped integer constant to an enum's backing type, so matching C++ here
				// cost +12,008. Setting in_enum_type in check_enum_type_expr (above) is
				// what makes this line safe.
				check_assignment(ctx, &o, constant_type, "enumeration")
			}

			if o.mode != .Invalid {
				iota = o.value
			} else {
				// If assignment failed, still increment iota
				iota = exact_binary_operator_value(.Add, iota, exact_value_i64(1))
			}
		} else {
			// Auto-increment iota
			// C++ line 910
			iota = exact_binary_operator_value(.Add, iota, exact_value_i64(1))
			// C++ line 911: entity_flags |= EntityConstantFlag_ImplicitEnumValue
			entity_flags += {.Implicit_Enum_Value}
		}

		// Skip blank identifiers
		if is_blank_ident(name) {
			continue
		}

		// Check for reserved identifier 'names'
		if name == "names" {
			// C++ Reference: check_type.cpp:919
			error(field, "'names' is a reserved identifier for enumerations")
			continue
		}

		// Track min/max values
		if min_value_set {
			if compare_exact_values(.Gt, min_value, iota) {
				min_value_index = i64(i)
				min_value = iota
			}
		} else {
			min_value_index = i64(i)
			min_value = iota
			min_value_set = true
		}

		if max_value_set {
			if compare_exact_values(.Lt, max_value, iota) {
				max_value_index = i64(i)
				max_value = iota
			}
		} else {
			max_value_index = i64(i)
			max_value = iota
			max_value_set = true
		}

		// Create enum constant entity
		// C++ lines 944-950
		entity := new(Entity, ctx.checker.allocator)
		entity.kind = .Constant
		entity.token = tokenizer.Token {
			text = name,
			pos  = ident.pos,
		}
		entity.scope = ctx.scope
		// C++ line 946: entity->flags |= EntityFlag_Visited
		entity.flags = {.Visited}
		// C++ line 947: entity->state = EntityState_Resolved
		entity.state = .Resolved
		// C++ line 948-950: entity->Constant.flags |= entity_flags; entity->Constant.docs = docs; entity->Constant.comment = comment
		entity.variant = Entity_Constant {
			type    = constant_type,
			value   = iota,
			flags   = entity_flags,
			docs    = docs,
			comment = comment,
		}

		// Check for duplicate names and add to scope
		// C++ Reference: check_type.cpp:1015-1022. Note that C++ adds the entity to
		// the scope and records the field ONLY when the name is not already taken;
		// a duplicate is reported and otherwise skipped entirely.
		existing := scope_lookup_current(ctx.scope, name)
		if existing != nil {
			error(ident, "'%s' is already declared in this enumeration", name)
		} else {
			add_entity(ctx, ctx.scope, nil, entity)
			append(&et.fields, entity)
			add_entity_use(ctx, field, entity)
		}
	}

	assert(len(et.fields) <= len(node.fields))

	// Set min/max values
	et.min_value = min_value
	et.max_value = max_value
	et.min_value_index = min_value_index
	et.max_value_index = max_value_index
}

// check_bit_set_type_expr creates and validates a bit set type
// C++ Reference: check_type.cpp:1212-1435
check_bit_set_type_expr :: proc(ctx: ^Checker_Context, bst: ^ast.Bit_Set_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create the bit set type
	bit_set_type := new(Type, ctx.checker.allocator)
	bit_set_type.kind = .Bit_Set
	bit_set_type.variant = Type_Bit_Set {
		node = bst,
	}

	type^ = bit_set_type
	set_base_type(named_type, bit_set_type)

	bs_variant := &bit_set_type.variant.(Type_Bit_Set)
	MAX_BITS :: 128

	// Unparen the element expression
	// C++ line 3220
	base := unparen_expr(bst.elem)

	// Check if this is a range expression (i64..i64)
	// C++ lines 1221-1362
	base_expr := cast(^ast.Expr)base
	if is_ast_range(base_expr) {
		be, is_binary := base.derived.(^ast.Binary_Expr)
		if !is_binary {
			error(bst.elem, "Expected a range expression for bit_set")
			return false
		}

		// Check both sides of the range
		// C++ lines 1223-1237
		lhs, rhs: Operand
		check_expr(ctx, &lhs, be.left)
		check_expr(ctx, &rhs, be.right)

		if lhs.mode == .Invalid || rhs.mode == .Invalid {
			return false
		}

		// Convert to common type
		// C++ lines 1230-1237
		convert_to_typed(ctx, &lhs, rhs.type)
		if lhs.mode == .Invalid {
			return false
		}
		convert_to_typed(ctx, &rhs, lhs.type)
		if rhs.mode == .Invalid {
			return false
		}

		// Verify types match
		// C++ lines 1238-1250
		if !are_types_identical(lhs.type, rhs.type) {
			if lhs.type != t_invalid && rhs.type != t_invalid {
				lhs_str := type_to_string(lhs.type)
				rhs_str := type_to_string(rhs.type)
				expr_str := expr_to_string(bst.elem)
				defer delete(expr_str)
				error(bst.elem, "Mismatched types in range '%s' : '%s' vs '%s'", expr_str, lhs_str, rhs_str)
			}
			return false
		}

		// Validate range element type
		// C++ lines 1252-1257
		if !is_type_valid_bit_set_range(lhs.type) {
			type_str := type_to_string(lhs.type)
			error(bst.elem, "'%s' is invalid for an interval expression, expected an integer or rune", type_str)
			return false
		}

		// Require constant values
		// C++ lines 1259-1262
		if lhs.mode != .Constant || rhs.mode != .Constant {
			error(bst.elem, "Intervals must be constant values")
			return false
		}

		// Extract integer values
		// C++ lines 1264-1279
		iv := exact_value_to_integer(lhs.value)
		jv := exact_value_to_integer(rhs.value)

		lower := exact_value_to_i64(iv)
		upper := exact_value_to_i64(jv)

		if lower > upper {
			error(bst.elem, "Lower interval bound larger than upper bound, %d .. %d", lower, upper)
			return false
		}

		// Get default type
		// C++ line 1281
		t := default_type(lhs.type)

		// Check for underlying type
		// C++ lines 1282-1294
		if bst.underlying != nil {
			u := check_type(ctx, bst.underlying)
			if !is_type_integer(u) {
				u_str := type_to_string(u)
				error(bst.underlying, "Expected an underlying integer for the bit set, got %s", u_str)
				return false
			}
			bs_variant.underlying = u
		}

		// Validate bounds are representable in the range type
		// C++ lines 1296-1313
		if !check_representable_as_constant(ctx, iv, t) {
			i_str := exact_value_to_string(iv)
			t_str := type_to_string(t)
			error(bst.elem, "%s is not representable by %s", i_str, t_str)
			return false
		}
		if !check_representable_as_constant(ctx, jv, t) {
			j_str := exact_value_to_string(jv)
			t_str := type_to_string(t)
			error(bst.elem, "%s is not representable by %s", j_str, t_str)
			return false
		}

		// Adjust lower bound and calculate bits required
		// C++ lines 1314-1328
		actual_lower := lower
		bits := MAX_BITS
		if bs_variant.underlying != nil {
			bits = 8 * type_size_of(bs_variant.underlying)

			if lower > 0 {
				actual_lower = 0
			} else if lower < 0 {
				error(bst.elem, "bit_set does not allow a negative lower bound (%d) when an underlying type is set", lower)
			}
		}

		// Calculate bits required based on range operator
		// C++ lines 1329-1351
		bits_required := upper - actual_lower
		#partial switch be.op.kind {
		case .Ellipsis, .Range_Full:
			bits_required += 1
		}

		is_valid := true
		#partial switch be.op.kind {
		case .Ellipsis, .Range_Full:
			if upper - lower >= i64(bits) {
				is_valid = false
			}
		case .Range_Half:
			if upper - lower > i64(bits) {
				is_valid = false
			}
			upper -= 1
		}

		// Report error if range is too large
		// C++ lines 1352-1358
		if !is_valid {
			if actual_lower != lower {
				error(bst.elem, "bit_set range is greater than %d bits, %d bits are required (internally the lower bound was changed to 0 as an underlying type was set)", bits, bits_required)
			} else {
				error(bst.elem, "bit_set range is greater than %d bits, %d bits are required", bits, bits_required)
			}
		}

		// Set bit set fields
		// C++ lines 1360-1362
		bs_variant.elem = t
		bs_variant.lower = lower
		bs_variant.upper = upper

	} else {
		// Enum-based bit set: bit_set[MyEnum]
		// C++ lines 1363-1434
		elem := check_type_expr(ctx, bst.elem, nil)
		bs_variant.elem = elem

		// Validate element type is enum
		// C++ lines 1367-1375
		if !is_type_valid_bit_set_elem(elem) {
			error(bst.elem, "Expected an enum type for a bit_set")
		} else {
			et := base_type(elem)
			if et.kind == .Enum {
				enum_info := et.variant.(Type_Enum)

				if !is_type_integer(enum_info.base_type) {
					error(bst.elem, "Enum type for bit_set must be an integer")
					return false
				}

				// Calculate min/max from enum fields
				// C++ lines 1376-1396
				lower := i64(max(i64))
				upper := i64(min(i64))

				for e in enum_info.fields {
					if e.kind != .Constant {
						continue
					}
					const_ent := e.variant.(Entity_Constant)
					value := exact_value_to_integer(const_ent.value)
					x := exact_value_to_i64(value)
					lower = min(lower, x)
					upper = max(upper, x)
				}

				if len(enum_info.fields) == 0 {
					lower = 0
					upper = 0
				}

				assert(lower <= upper)

				// Check underlying type
				// C++ lines 1398-1419
				lower_changed := false
				bits := MAX_BITS

				if bst.underlying != nil {
					u := check_type(ctx, bst.underlying)
					if !is_type_integer(u) {
						u_str := type_to_string(u)
						error(bst.underlying, "Expected an underlying integer for the bit set, got %s", u_str)
						return false
					}
					bs_variant.underlying = u
					bits = 8 * type_size_of(u)

					if lower > 0 {
						lower = 0
						lower_changed = true
					} else if lower < 0 {
						elem_str := type_to_string(elem)
						error(bst.elem, "bit_set does not allow a negative lower bound (%d) of the element type '%s' when an underlying type is set", lower, elem_str)
					}
				}

				// Validate bits required
				// C++ lines 1421-1428
				if upper - lower >= i64(bits) {
					bits_required := upper - lower + 1
					if lower_changed {
						error(bst.elem, "bit_set range is greater than %d bits, %d bits are required (internally the lower bound was changed to 0 as an underlying type was set)", bits, bits_required)
					} else {
						error(bst.elem, "bit_set range is greater than %d bits, %d bits are required", bits, bits_required)
					}
				}

				// Set bounds
				// C++ lines 1430-1431
				bs_variant.lower = lower
				bs_variant.upper = upper
			}
		}
	}

	return true
}

// check_bit_field_type_expr creates and validates a bit field type
// C++ Reference: check_type.cpp:991-1199 (~208 lines)
check_bit_field_type_expr :: proc(ctx: ^Checker_Context, bft: ^ast.Bit_Field_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create the bit field type
	bit_field_type := alloc_type(Type_Bit_Field)
	bf := &bit_field_type.variant.(Type_Bit_Field)
	bf.node = bft

	type^ = bit_field_type
	set_base_type(named_type, bit_field_type)

	// Check backing type
	// C++ lines 993-1014
	backing_type: ^Type = nil
	if bft.backing_type != nil {
		backing_type = check_type(ctx, bft.backing_type)
	}

	if backing_type == nil || backing_type == t_invalid {
		error_node(bft, "bit_field requires a backing type")
		return false
	}

	if !is_valid_bit_field_backing_type(backing_type) {
		type_str := type_to_string(backing_type)
		error_node(bft.backing_type, "Invalid backing type '%s' for bit_field, expected an integer type", type_str)
		return false
	}

	bf.backing_type = backing_type

	// Get backing type size in bits
	// C++ line 1016
	backing_bits := i64(8 * type_size_of(backing_type))

	// Check for endian attribute on backing type
	// C++ lines 1018-1037
	backing_endian := Endianness.Platform
	if basic, is_basic := base_type(backing_type).variant.(Type_Basic); is_basic {
		if .Endian_Little in basic.flags {
			backing_endian = .Little
		} else if .Endian_Big in basic.flags {
			backing_endian = .Big
		}
	}

	// Create scope for bit field fields
	// C++ line 1039
	scope := create_scope(ctx.scope)
	bft.scope = scope

	// Process each field
	// C++ lines 1041-1190
	total_bits_used: i64 = 0
	field_count := len(bft.fields)

	bf.fields = make([dynamic]^Entity, 0, field_count)
	bf.bit_sizes = make([dynamic]int, 0, field_count)
	bf.bit_offsets = make([dynamic]int, 0, field_count)

	for ast_field, bit_field_index in bft.fields {
		if ast_field == nil {
			continue
		}

		// Get field name
		// C++ lines 1045-1055
		field_name := ""
		field_token := tokenizer.Token{}
		if ast_field.name != nil {
			if ident, is_ident := ast_field.name.derived.(^ast.Ident); is_ident {
				field_name = ident.name
				field_token = tokenizer.Token{
					kind = .Ident,
					text = ident.name,
					pos  = ident.pos,
				}
			}
		}

		if field_name == "" {
			error_node(ast_field, "bit_field field must have a name")
			continue
		}

		// Check for duplicate field names
		// C++ lines 1057-1062
		if field_name in bf.names {
			error_node(ast_field.name, "Duplicate field name '%s' in bit_field", field_name)
			continue
		}

		// Check field type
		// C++ lines 1064-1085
		field_type := check_type(ctx, ast_field.type)
		if field_type == nil || field_type == t_invalid {
			error_node(ast_field.type, "Invalid field type in bit_field")
			continue
		}

		// Validate field type is integer, enum, or boolean
		// C++ Reference: check_type.cpp:1030
		if !is_type_integer(field_type) && !is_type_enum(field_type) && !is_type_boolean(field_type) {
			type_str := type_to_string(field_type)
			error_node(ast_field.type, "bit_field field type must be an integer, enum, or boolean, got '%s'", type_str)
			continue
		}

		// Validate field type endianness matches backing type endianness
		// C++ Reference: check_type.cpp:1127-1167
		if backing_endian != .Platform {
			field_endian := Endianness.Platform
			if basic, is_basic := base_type(field_type).variant.(Type_Basic); is_basic {
				if .Endian_Little in basic.flags {
					field_endian = .Little
				} else if .Endian_Big in basic.flags {
					field_endian = .Big
				}
			}
			if field_endian != .Platform && field_endian != backing_endian {
				backing_str := backing_endian == .Little ? "little" : "big"
				field_str := field_endian == .Little ? "little" : "big"
				error_node(ast_field.type, "bit_field field has %s endianness but backing type has %s endianness", field_str, backing_str)
				continue
			}
		}

		// Check bit size expression
		// C++ lines 1097-1120
		bit_size: i64 = 0
		if ast_field.bit_size != nil {
			// C++ Reference: check_type.cpp:1051-1055
			// Warn about binary expressions that might be a typo (e.g., `field : u8 | 4` instead of `field : u8 = 4`)
			if _, is_binary := ast_field.bit_size.derived.(^ast.Binary_Expr); is_binary {
				warning_node(ast_field.bit_size, "bit_field bit size is a binary expression; did you mean to use '=' instead of '|'?")
			}

			bit_size_op: Operand
			check_expr(ctx, &bit_size_op, ast_field.bit_size)

			if bit_size_op.mode != .Constant {
				error_node(ast_field.bit_size, "bit_field bit size must be a constant")
				continue
			}

			// C++ Reference: check_type.cpp:1048-1050
			// C++ converts float constants to integer instead of rejecting
			if is_type_float(bit_size_op.type) {
				// Convert float to integer
				bit_size_op.type = t_untyped_integer
			}

			if !is_type_integer(bit_size_op.type) {
				error_node(ast_field.bit_size, "bit_field bit size must be an integer")
				continue
			}

			bit_size = exact_value_to_i64(bit_size_op.value)
		} else {
			// Default to type size
			bit_size = i64(8 * type_size_of(field_type))
		}

		// Validate bit size
		// C++ lines 1122-1145
		if bit_size <= 0 {
			error_node(ast_field.bit_size, "bit_field bit size must be positive, got %d", bit_size)
			continue
		}

		field_max_bits := i64(8 * type_size_of(field_type))
		if bit_size > field_max_bits {
			type_str := type_to_string(field_type)
			error_node(ast_field.bit_size, "bit_field bit size %d exceeds maximum %d for type '%s'", bit_size, field_max_bits, type_str)
			continue
		}

		// Check if field fits in remaining backing space
		// C++ lines 1147-1155
		if total_bits_used + bit_size > backing_bits {
			backing_str := type_to_string(backing_type)
			error_node(ast_field, "bit_field field '%s' exceeds backing type '%s' capacity (%d bits used, %d needed, %d available)", field_name, backing_str, total_bits_used, bit_size, backing_bits)
			continue
		}

		// Create entity for field
		//
		// C++ Reference: check_type.cpp:1149-1153 -
		//	Entity *e = alloc_entity_field(ctx->scope, ..., type, false, field_src_index);
		//	e->flags |= EntityFlag_BitFieldField;
		//
		// The port used alloc_entity_VARIABLE and added only .Bit_Field_Field, so the entity
		// never carried .Field. lookup_field_with_selection's bit_field arm (types.odin:3160)
		// skips any entity without it - `if .Field not_in field.flags { continue }`, which is
		// C++'s own guard - so EVERY bit_field member lookup failed, by value and through a
		// pointer alike. core/mem's Rollback_Stack_Header accounts for 294 of the class.
		field_entity := alloc_entity_field(scope, field_token, field_type, false, i32(bit_field_index))
		field_entity.flags += {.Bit_Field_Field}

		// Add to scope
		scope_insert(scope, field_entity)

		// Add to type
		append(&bf.fields, field_entity)
		bf.names[field_name] = field_entity
		append(&bf.bit_sizes, int(bit_size))
		append(&bf.bit_offsets, int(total_bits_used))

		total_bits_used += bit_size
	}

	return true
}

// check_matrix_type_expr creates and validates a matrix type
// C++ Reference: check_type.cpp:2870-2922 (~52 lines)
check_matrix_type_expr :: proc(ctx: ^Checker_Context, mt: ^ast.Matrix_Type, type: ^^Type, named_type: ^Type) -> bool {
	// C++ Reference: types.cpp:402-403 - MIN = 1, MAX = 64.
	// NOTE: MAX applies to the TOTAL element count (row*column), not to each dimension.
	// C++ check_type.cpp:3108-3131 checks only a MINIMUM per dimension and then bounds
	// row_count*column_count by MAX. The port previously capped each dimension at 16 and
	// the total at 16, rejecting valid types such as matrix[8, 8]T.
	MATRIX_ELEMENT_COUNT_MIN :: 1
	MATRIX_ELEMENT_COUNT_MAX :: 64

	// Create the matrix type
	matrix_type := alloc_type(Type_Matrix)
	mat := &matrix_type.variant.(Type_Matrix)
	mat.node = mt

	// NOTE: this publishes a still-ZEROED matrix type (elem=nil, row_count=0, column_count=0) to the
	// caller before any validation has run, so every error path below MUST overwrite it with
	// t_invalid. C++ avoids the problem structurally: check_type.cpp:3090-3156 validates everything
	// first and assigns exactly once at `type_assign:` via alloc_type_matrix with all fields known.
	//
	// Leaving a zeroed matrix in circulation caused a SIGSEGV in core/math/linalg: downstream,
	// is_type_matrix answers true, the `mat.row_count == mat.column_count` guard in
	// check_distance_between_types (check_equivalence.odin:813) passes because 0 == 0,
	// base_array_type then returns the nil elem, and that nil reaches is_type_enum, which does
	// `base_type(t).kind` with no nil guard (as does C++'s - C++ simply never passes nil).
	//
	// The early publish is retained because a named matrix type needs its base set before the
	// element type is checked, to support self-referential declarations.
	type^ = matrix_type
	set_base_type(named_type, matrix_type)

	// Check element type
	// C++ lines 2872-2880
	elem := check_type(ctx, mt.elem)
	if elem == nil || elem == t_invalid {
		error_node(mt.elem, "Invalid element type for matrix")
		// Do not leave the half-built matrix type published to the caller.
		type^ = t_invalid
		set_base_type(named_type, t_invalid)
		return false
	}

	// Validate the element type.
	// C++ Reference: check_type.cpp check_matrix_type, the is_type_valid_for_matrix_elems block.
	//
	// C++ reports and CONTINUES here - it falls through to its `type_assign:` label and allocates the
	// matrix regardless. The port used to publish t_invalid and bail, turning one bad element type
	// into a cascade at every use of the matrix.
	if !is_type_valid_for_matrix_elems(elem) {
		// C++ keeps a narrow escape for `proc($T: typeid) -> matrix[2, 2]T`, where the element
		// expression names a typeid-valued type alias. Its own comment marks this a HACK; it is
		// reproduced rather than generalised, because widening it would accept element types C++
		// rejects.
		escaped := false
		if elem == t_typeid {
			e := entity_of_node(ctx.info, mt.elem)
			if e != nil && e.kind == .Type_Name {
				if tn, tn_ok := e.variant.(Entity_Type_Name); tn_ok && tn.is_type_alias {
					escaped = true
				}
			}
		}
		if !escaped {
			type_str := type_to_string(elem)
			error_node(mt.elem, "Matrix elements types are limited to integers, floats, and complex, got %s", type_str)
		}
	}

	mat.elem = elem

	// Check row count
	// C++ lines 2892-2900
	row_count: i64 = 0
	generic_row: ^Type = nil
	if mt.row_count != nil {
		row_op: Operand
		check_expr(ctx, &row_op, mt.row_count)

		if row_op.mode == .Constant {
			if !is_type_integer(row_op.type) {
				error_node(mt.row_count, "matrix row count must be an integer")
				// Do not leave the half-built matrix type published to the caller.
				type^ = t_invalid
				set_base_type(named_type, t_invalid)
				return false
			}
			row_count = exact_value_to_i64(row_op.value)
		} else if row_op.mode == .Type && is_type_polymorphic(row_op.type) {
			// Polymorphic row count (e.g., matrix[$N, M]f32)
			generic_row = row_op.type
		} else {
			error_node(mt.row_count, "matrix row count must be a constant integer or polymorphic type parameter")
			// Do not leave the half-built matrix type published to the caller.
			type^ = t_invalid
			set_base_type(named_type, t_invalid)
			return false
		}
	}

	// Validate row count range
	// C++ lines 2902-2908
	if generic_row == nil {
		// C++ check_type.cpp:3108-3116 - minimum only; the maximum is enforced on the total below.
		if row_count < MATRIX_ELEMENT_COUNT_MIN {
			error_node(mt.row_count, "Invalid matrix row count, expected %d+ rows, got %d", MATRIX_ELEMENT_COUNT_MIN, row_count)
			// Do not leave the half-built matrix type published to the caller.
			type^ = t_invalid
			set_base_type(named_type, t_invalid)
			return false
		}
	}

	mat.row_count = row_count
	mat.generic_row_count = generic_row

	// Check column count
	// C++ lines 2910-2918
	column_count: i64 = 0
	generic_column: ^Type = nil
	if mt.column_count != nil {
		col_op: Operand
		check_expr(ctx, &col_op, mt.column_count)

		if col_op.mode == .Constant {
			if !is_type_integer(col_op.type) {
				error_node(mt.column_count, "matrix column count must be an integer")
				// Do not leave the half-built matrix type published to the caller.
				type^ = t_invalid
				set_base_type(named_type, t_invalid)
				return false
			}
			column_count = exact_value_to_i64(col_op.value)
		} else if col_op.mode == .Type && is_type_polymorphic(col_op.type) {
			// Polymorphic column count
			generic_column = col_op.type
		} else {
			error_node(mt.column_count, "matrix column count must be a constant integer or polymorphic type parameter")
			// Do not leave the half-built matrix type published to the caller.
			type^ = t_invalid
			set_base_type(named_type, t_invalid)
			return false
		}
	}

	// Validate column count range
	// C++ lines 2920-2922
	if generic_column == nil {
		// C++ check_type.cpp:3118-3126 - minimum only; the maximum is enforced on the total below.
		if column_count < MATRIX_ELEMENT_COUNT_MIN {
			error_node(mt.column_count, "Invalid matrix column count, expected %d+ columns, got %d", MATRIX_ELEMENT_COUNT_MIN, column_count)
			// Do not leave the half-built matrix type published to the caller.
			type^ = t_invalid
			set_base_type(named_type, t_invalid)
			return false
		}
	}

	mat.column_count = column_count
	mat.generic_column_count = generic_column

	// C++ Reference: check_type.cpp:2887-2930
	// Validate total element count (row * column)
	// C++ check_type.cpp:3128-3131 - the single maximum, applied to row*column.
	if generic_row == nil && generic_column == nil {
		total_elements := row_count * column_count
		if total_elements > MATRIX_ELEMENT_COUNT_MAX {
			error_node(mt, "Matrix types are limited to a maximum of %d elements, got %d", MATRIX_ELEMENT_COUNT_MAX, total_elements)
			// Do not leave the half-built matrix type published to the caller.
			type^ = t_invalid
			set_base_type(named_type, t_invalid)
			return false
		}
	}

	// Calculate stride (elements are stored column-major by default)
	// C++ doesn't calculate this here - done later during codegen
	elem_size := type_size_of(elem)
	mat.stride_in_bytes = int(row_count) * elem_size

	return true
}

// check_map_type_expr checks a `map[K]V` type expression
// C++ Reference: check_type.cpp:3042-3086 (check_map_type)
// check_fixed_capacity_dynamic_array_type checks a `[dynamic; N]T` type expression.
// C++ Reference: check_type.cpp:3830-3852 (case_ast_node(dat, FixedCapacityDynamicArrayType, e))
check_fixed_capacity_dynamic_array_type :: proc(
	ctx: ^Checker_Context,
	dat: ^ast.Fixed_Capacity_Dynamic_Array_Type,
	type: ^^Type,
	named_type: ^Type,
) -> bool {
	// C++ Reference: check_type.cpp:3831-3836. check_array_count also handles a polymorphic count,
	// which is how `[dynamic; $N]$E` gets its generic capacity - the operand comes back as a Type
	// whose kind is Generic.
	o: Operand
	capacity := check_array_count(ctx, &o, dat.capacity)
	generic_capacity: ^Type = nil
	if o.mode == .Type && o.type != nil && o.type.kind == .Generic {
		generic_capacity = o.type
	}

	// C++ Reference: check_type.cpp:3838-3841
	if capacity < 0 {
		error_node(dat.capacity, "? can only be used in conjunction with compound literals of fixed-length arrays")
		capacity = 0
	}

	elem := check_type(ctx, dat.elem)

	// C++ Reference: check_type.cpp:3844-3849. C++ asserts the tag is a BasicDirective and then
	// always reports it as invalid; no tag is accepted on this type.
	if dat.tag != nil {
		if bd, is_bd := dat.tag.derived_expr.(^ast.Basic_Directive); is_bd {
			error_node(dat.tag, "Invalid tag applied to fixed capacity dynamic array, got #%s", bd.name)
		} else {
			error_node(dat.tag, "Invalid tag applied to fixed capacity dynamic array")
		}
	}

	// C++ Reference: check_type.cpp:3850-3852
	type^ = make_fixed_capacity_dynamic_array_type(elem, capacity, generic_capacity)
	set_base_type(named_type, type^)
	return true
}

check_map_type_expr :: proc(ctx: ^Checker_Context, mt: ^ast.Map_Type, type: ^^Type, named_type: ^Type) -> bool {
	// C++ Reference: check_type.cpp:3046-3057
	if mt.key == nil {
		if mt.value != nil {
			value := check_type(ctx, mt.value)
			// NOTE: no delete - type_to_string returns either a string literal ("<no type>",
			// "<invalid>") or a temp-allocator string, unlike expr_to_string which is caller-owned.
			str := type_to_string(value)
			error_node(mt, "Missing map key type, got 'map[]%s'", str)
		} else {
			error_node(mt, "Missing map key type, got 'map[]T'")
		}
		type^ = t_invalid
		return false
	}

	key := check_type(ctx, mt.key)
	value := check_type(ctx, mt.value)

	// C++ Reference: check_type.cpp:3062-3070.
	//
	// NOTE: this replaces a hand-rolled trio of rejections (slice / dynamic array / map key) that had
	// no C++ counterpart. Those also returned false and left type^ = t_invalid, abandoning the map
	// entirely; C++ reports and CONTINUES, still building the type and running the inits below, so a
	// bad key yields one diagnostic in C++ where the port produced a cascade from the missing type.
	if !is_type_valid_for_keys(key) {
		if is_type_boolean(key) {
			error_node(mt, "A boolean cannot be used as a key for a map, use an array instead for this case")
		} else {
			str := type_to_string(key)
			error_node(mt, "Invalid type of a key for a map, got '%s'", str)
		}
	}
	// C++ Reference: check_type.cpp:3071-3075
	//
	// REGRESSION GUARD: this check is skipped for a polymorphic key. C++ runs it unconditionally,
	// but C++'s type_size_of has no Type_Generic case and evidently does not report 0 for one -
	// base:runtime's `delete_map :: proc(m: $T/map[$K]$V, ...)` compiles under C++, and would not if
	// this fired. This port's type_size_of DOES return 0 for a generic, so porting the check
	// verbatim made every `map[$K]$V` signature report "Invalid type of a key for a map of size 0,
	// got '$K'" - 3 in core/unicode, 7 in core/slice, 3 in core/math/linalg. A polymorphic key has
	// no size until it is instantiated, so there is nothing to judge here.
	if !is_type_polymorphic(key) && type_size_of(key) == 0 {
		str := type_to_string(key)
		error_node(mt, "Invalid type of a key for a map of size 0, got '%s'", str)
	}

	// C++ Reference: check_type.cpp:3077-3078
	type^ = make_map_type(key, value)
	set_base_type(named_type, type^)

	// C++ Reference: check_type.cpp:3079
	add_map_key_type_dependencies(ctx, key)

	// C++ Reference: check_type.cpp:3081-3082. Both calls were missing. init_core_map_type is
	// what populates t_map_info / t_map_cell_info / t_raw_map (and, via init_mem_allocator,
	// t_allocator, which init_map_internal_types asserts on).
	init_core_map_type(ctx.checker)

	// NOTE: C++ can call init_map_internal_types unconditionally because the compiler always has
	// base:runtime loaded, so init_core_map_type -> init_mem_allocator always sets t_allocator.
	// This port is also used as a library on package sets that never load base:runtime, where
	// find_core_type returns nil and init_mem_allocator returns early by design (see its comment).
	// In that case t_allocator stays nil and init_map_internal_types' assert would fire, so gate on
	// the precondition C++ gets for free rather than on a weakened assert.
	if t_allocator != nil {
		init_map_internal_types(type^)
	}

	// C++ Reference: check_type.cpp:3084-3086
	if ctx.info.build_context != nil && ctx.info.build_context.bedrock {
		error_node(mt, "'map' is not a valid type when using '-bedrock'")
	}

	return true
}

check_proc_type_expr :: proc(ctx: ^Checker_Context, pt: ^ast.Proc_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Create procedure type
	proc_type := new(Type, ctx.checker.allocator)
	proc_type.kind = .Proc

	type^ = proc_type
	set_base_type(named_type, proc_type)

	// C++ Reference: check_type.cpp:3929-3931 wraps check_procedure_type in
	// check_open_scope / check_close_scope, so a procedure type's PARAMETERS live in a
	// scope of their own.
	//
	// The port stored ctx.scope — the ENCLOSING scope — and never opened one, so every
	// proc type inserted its parameter names into the surrounding scope. Two unrelated
	// procedure types in the same file each declaring a parameter called `data` then
	// collided, and check_get_params reported "Duplicate parameter 'data'" for the second.
	// base/runtime/core.odin hits this immediately (Hasher_Proc's `data` against an
	// earlier one), and it was worth 2,243 diagnostics.
	//
	// This is the same defect as the enum-scope bug (task 71): C++ opens a scope around
	// the type check and the port stored the enclosing one instead.
	check_open_scope(ctx, pt)
	proc_type.variant = Type_Proc {
		node  = pt,
		scope = ctx.scope, // the freshly opened parameter scope
	}
	ok := check_procedure_type(ctx, proc_type, pt, nil)
	check_close_scope(ctx)
	return ok
}

// check_procedure_type performs full procedure type validation
// Ported from check_procedure_type in check_type.cpp:2414-2572
check_procedure_type :: proc(ctx: ^Checker_Context, proc_type: ^Type, proc_type_node: ^ast.Proc_Type, operands: []Operand = nil) -> bool {
	assert(proc_type.kind == .Proc)

	// If polymorphic scope is not set and polymorphic types are allowed, use current scope
	if ctx.polymorphic_scope == nil && ctx.allow_polymorphic_types {
		ctx.polymorphic_scope = ctx.scope
	}

	// Create a copy of the context for procedure signature checking
	c := ctx^
	c.curr_proc_sig = proc_type
	c.in_proc_sig = true

	// === CALLING CONVENTION VALIDATION ===

	// Resolve calling convention from AST
	// AST calling convention is a union of string or Foreign_Block_Default
	cc: Calling_Convention = .Odin // Default

	switch v in proc_type_node.calling_convention {
	case string:
		// Map string to calling convention enum
		// Strip quotes from the string (parser includes them)
		cc_str := v
		if len(cc_str) >= 2 && (cc_str[0] == '"' || cc_str[0] == '`') {
			cc_str = cc_str[1:len(cc_str)-1]
		}
		// Route through the single shared mapping rather than duplicating it. The previous
		// inline copy diverged from C++ in three ways: it lacked "naked" and the three
		// preserve/* conventions, and it mapped "system" to .SysV - but C++
		// (parser.cpp:4055-4059) maps "system" to stdcall on Windows and cdecl everywhere
		// else, so on any non-Windows target that was simply the wrong convention.
		cc = string_to_calling_convention(cc_str)
		if cc == .Invalid {
			error_node(proc_type_node, "Unknown calling convention: %s", cc_str)
			cc = .Odin
		}

	case ast.Proc_Calling_Convention_Extra:
		// Foreign block default - use foreign context's default
		if v == .Foreign_Block_Default {
			// C++ Reference: check_type.cpp:2630-2635 (`if (c->foreign_context.default_cc > 0)`,
			// where 0 is ProcCC_Invalid). See Foreign_Context.default_cc_set for why the
			// port cannot use the enum's zero value as the "unset" sentinel.
			cc = .C // Default to C
			if ctx.foreign_context.default_cc_set {
				cc = ctx.foreign_context.default_cc
			}
		}
	}

	// Set scope flags based on calling convention
	// C++ Reference: check_type.cpp:2436-2440
	if cc == .Odin {
		c.scope.flags |= {.Context_Defined}
	} else {
		c.scope.flags &= ~{.Context_Defined}
	}

	// Validate calling convention for target architecture
	// Get actual target architecture from build context, default to amd64 if not set
	arch := Target_Arch_Kind.Amd64
	if ctx.info.build_context != nil {
		arch = ctx.info.build_context.metrics.arch
	}

	switch cc {
	case .Preserve_None, .Preserve_Most, .Preserve_All, .Invalid:
		// No target-architecture restriction in C++ for these.
	case .Std, .Fast:
		// StdCall and FastCall only work on i386 and amd64
		// C++ Reference: check_type.cpp:2447-2451
		if arch != .I386 && arch != .Amd64 {
			error(proc_type_node, "Invalid procedure calling convention \"%s\" for target architecture, expected either i386 or amd64, got %s", proc_calling_convention_strings[cc], target_arch_names[arch])
		}

	case .Win64, .SysV:
		// Win64 and SysV only work on amd64
		// C++ Reference: check_type.cpp:2452-2457
		if arch != .Amd64 {
			error(proc_type_node, "Invalid procedure calling convention \"%s\" for target architecture, expected amd64, got %s", proc_calling_convention_strings[cc], target_arch_names[arch])
		}

	case .Odin, .Contextless, .C, .None, .Naked, .Inline_Asm:
	// These are valid on all architectures
	}

	// === PARAMETER PROCESSING ===

	variadic := false
	variadic_index := -1
	c_vararg := false
	success := true
	specialization_count := 0

	// Check parameters
	params := check_get_params(&c, c.scope, proc_type_node.params, &variadic, &variadic_index, &c_vararg, &success, &specialization_count, operands)

	// === RETURN TYPE PROCESSING ===

	// Save and modify polymorphic return type flag
	no_poly_return := c.disallow_polymorphic_return_types
	c.disallow_polymorphic_return_types = c.scope == c.polymorphic_scope
	// NOTE: if the polymorphic scope is the current proc's scope, then the return types shall not declare new poly vars

	results := check_get_results(&c, c.scope, proc_type_node.results)

	c.disallow_polymorphic_return_types = no_poly_return

	// === COUNT PARAMETERS AND RESULTS ===

	param_count := 0
	result_count := 0

	if params != nil && params.kind == .Tuple {
		tuple := params.variant.(Type_Tuple)
		param_count = len(tuple.variables)
	}

	if results != nil && results.kind == .Tuple {
		tuple := results.variant.(Type_Tuple)
		result_count = len(tuple.variables)
	}

	// Check if results have named returns
	has_named_results := false
	if result_count > 0 && results != nil && results.kind == .Tuple {
		tuple := results.variant.(Type_Tuple)
		if len(tuple.variables) > 0 {
			first_entity := tuple.variables[0]
			if first_entity.token.text != "" {
				has_named_results = true
			}
		}
	}

	// === ATTRIBUTE VALIDATION ===

	// Check #optional_ok attribute
	optional_ok := .Optional_Ok in proc_type_node.tags
	if optional_ok {
		if result_count != 2 {
			// C++ Reference: check_type.cpp:2486
			error(proc_type_node, "A procedure type with the #optional_ok tag requires 2 return values, got %d", result_count)
		} else if results != nil && results.kind == .Tuple {
			// Check that second return is boolean
			tuple := results.variant.(Type_Tuple)
			if len(tuple.variables) >= 2 {
				second := tuple.variables[1]
				second_type := entity_type(second)
				if !is_type_polymorphic(second_type) && !is_type_boolean(second_type) {
					type_str := type_to_string(second_type)
					error_node(proc_type_node, "Second return value of an #optional_ok procedure must be a boolean, got %s", type_str)
				}
			}
		}
	}

	// Check #optional_allocator_error attribute
	if .Optional_Allocator_Error in proc_type_node.tags {
		if optional_ok {
			// C++ Reference: check_type.cpp:2499
			error(proc_type_node, "A procedure type cannot have both an #optional_ok tag and #optional_allocator_error")
		}
		optional_ok = true

		if result_count != 2 {
			// C++ Reference: check_type.cpp:2503
			error(proc_type_node, "A procedure type with the #optional_allocator_error tag requires 2 return values, got %d", result_count)
		} else if results != nil && results.kind == .Tuple {
			// Check that second return is runtime.Allocator_Error
			init_mem_allocator(c.checker)
			tuple := results.variant.(Type_Tuple)
			if len(tuple.variables) >= 2 {
				second := tuple.variables[1]
				second_type := entity_type(second)
				if !are_types_identical(second_type, t_allocator_error) {
					type_str := type_to_string(second_type)
					error_node(proc_type_node, "A procedure type with the #optional_allocator_error expects a `runtime.Allocator_Error`, got '%s'", type_str)
				}
			}
		}
	}

	// === POPULATE PROCEDURE TYPE ===

	pt := &proc_type.variant.(Type_Proc)
	pt.node = proc_type_node
	pt.scope = c.scope
	pt.params = params
	pt.param_count = param_count
	pt.results = results
	pt.result_count = result_count
	pt.variadic = variadic
	pt.variadic_index = variadic_index
	pt.calling_convention = cc
	pt.is_polymorphic = proc_type_node.generic // Will be updated below
	pt.specialization_count = specialization_count
	pt.diverging = proc_type_node.diverging
	pt.optional_ok = optional_ok
	pt.has_named_results = has_named_results

	// Set c_vararg flag if applicable
	// C++ lines 2542-2557
	// Note: C++ checks entity flags after params are created, but we check here
	// since we already have the c_vararg flag from check_get_params
	// Validate and set c_vararg flag if applicable
	// C++ Reference: check_type.cpp:2548-2556
	if c_vararg {
		// Validate calling convention supports c_vararg
		if cc == .Odin || cc == .Contextless {
			error_node(proc_type_node, "Calling convention does not support #c_vararg")
		}
		// Validate c_vararg is only on variadic procedures
		if !variadic {
			error_node(proc_type_node, "#c_vararg can only be applied to variadic procedures")
		}
		// Set flag if validations pass
		if (cc != .Odin && cc != .Contextless) && variadic {
			pt.c_vararg = true
		}
	}

	// === POLYMORPHIC TYPE DETECTION ===

	is_polymorphic := false

	// Check parameters for polymorphic types
	if params != nil && params.kind == .Tuple {
		tuple := params.variant.(Type_Tuple)
		for entity, i in tuple.variables {
			// Check entity kind - non-variable entities indicate polymorphic params
			if entity.kind != .Variable {
				is_polymorphic = true
			}

			// Get entity type and check if polymorphic
			param_type := entity_type(entity)
			if is_type_polymorphic(param_type) {
				// Validate polymorphic parameter usage
				// C++ Reference: check_type.cpp:2538
				if entity.kind == .Variable {
					if var_data, ok := &entity.variant.(Entity_Variable); ok {
						// Cast type_expr to ^ast.Expr for validation
						type_expr := cast(^ast.Expr)var_data.type_expr
						check_procedure_param_polymorphic_type(&c, param_type, type_expr)
					}
				}
				is_polymorphic = true
			}

			// Validate entity-level #c_vararg flag
			// C++ Reference: check_type.cpp:2542-2556
			if .C_Var_Arg in entity.flags {
				// Check that c_vararg is only on the last parameter
				if i != param_count - 1 {
					error(entity.token, "#c_vararg can only be applied to the last parameter")
					continue
				}

				#partial switch cc {
				case .Odin, .Contextless:
					error(entity.token, "Calling convention does not support #c_vararg")
				case:
					pt.c_vararg = true
				}
			}
		}
	}

	// Check results for polymorphic types
	if results != nil && results.kind == .Tuple {
		tuple := results.variant.(Type_Tuple)
		for entity in tuple.variables {
			// Check entity kind - non-variable entities indicate polymorphic results
			if entity.kind != .Variable {
				is_polymorphic = true
				break
			}

			// Get entity type and check if polymorphic
			result_type := entity_type(entity)
			if is_type_polymorphic(result_type) {
				is_polymorphic = true
				break
			}
		}
	}

	pt.is_polymorphic = is_polymorphic

	return success
}

// determine_type_from_polymorphic infers concrete type from polymorphic type parameter
// Reference: /mnt/c/odin/src/check_type.cpp:1573-1617
// Takes a polymorphic type (e.g., []$T) and an operand (e.g., []int{1,2,3})
// and determines what concrete type the polymorphic parameter should be (e.g., int)
determine_type_from_polymorphic :: proc(ctx: ^Checker_Context, poly_type: ^Type, operand: Operand) -> ^Type {
	// C++ line 1574-1575: Check modification permissions
	modify_type := !ctx.no_polymorphic_errors
	show_error := modify_type && !ctx.hide_polymorphic_errors

	// C++ line 1576-1585: Validate operand is a value
	if !is_operand_value(operand) {
		if show_error {
			// C++ Reference: check_type.cpp:1645 / :1664 — both build the strings with
			// type_to_string(..., true) first. Passing a ^Type straight to %v printed the whole
			// Type struct, addresses and all, instead of a type name.
			// NOTE: do NOT free these. type_to_string returns string literals or
			// temp-allocator storage; only expr_to_string is caller-owned. Freeing a
			// literal here segfaulted every package that reached this diagnostic.
			ots := type_to_string(operand.type)
			pts := type_to_string(poly_type)
			error(operand.expr, "Cannot determine polymorphic type from parameter: '%s' to '%s'", ots, pts)
		}
		return t_invalid
	}

	// If the parameter type has no polymorphic variable left in it - because an EARLIER
	// argument already bound it - then there is nothing to determine, and this is an ordinary
	// assignability question about the real operand.
	//
	// This matters because `is_polymorphic_type_assignable` takes only `operand.type`, so the
	// operand's constant VALUE is discarded before it can be judged. `divmod(delta.nanos, 1e9)`
	// in core/time/datetime binds T = i64 from the first argument and then hands the second an
	// untyped-float TYPE with no value; representability of 1e9 as an i64 cannot be decided from
	// that, so it was rejected with "Cannot determine polymorphic type from parameter:
	// 'untyped float' to 'i64'". C++ ends up in check_is_assignable_to on the real operand for
	// this case (check_expr.cpp:1425-1427); doing it here reaches the same answer without
	// changing the shared predicate's signature.
	if !is_type_polymorphic(poly_type) {
		o := operand
		if check_is_assignable_to(ctx, &o, poly_type) {
			return poly_type
		}
	}

	// C++ line 1587-1589: Try to assign operand type to polymorphic type
	// This performs the actual type parameter binding through is_polymorphic_type_assignable
	if is_polymorphic_type_assignable(ctx, poly_type, operand.type, false, modify_type) {
		return poly_type
	}

	// C++ line 1590-1615: Show detailed error if binding failed
	if show_error {
		// C++ Reference: check_type.cpp:1645 / :1664 — both build the strings with
		// type_to_string(..., true) first. Passing a ^Type straight to %v printed the whole
		// Type struct, addresses and all, instead of a type name.
		// NOTE: do NOT free these — see the note at the other call site.
		ots := type_to_string(operand.type)
		pts := type_to_string(poly_type)
		error(operand.expr, "Cannot determine polymorphic type from parameter: '%s' to '%s'", ots, pts)

		// C++ line 1598-1614: Special error hint for slice/array mismatches
		pt := poly_type
		for pt != nil && pt.kind == .Generic {
			if generic, ok := pt.variant.(Type_Generic); ok && generic.specialized != nil {
				pt = generic.specialized
			} else {
				break
			}
		}

		// Helpful suggestion for slice vs dynamic_array/array mismatch
		if is_type_slice(pt) && (is_type_dynamic_array(operand.type) || is_type_array(operand.type)) {
			// Suggest using slice syntax
			error_line("\tSuggestion: Try slicing the value with '[:]' or use a slice literal")
		}
	}

	return t_invalid
}

// is_caller_expression checks if an expression is a caller expression directive
// Reference: /mnt/c/odin/src/check_type.cpp:1637-1655
is_caller_expression :: proc(expr: ^ast.Node) -> bool {
	// Check for #caller_expression directive
	if basic_dir, ok := expr.derived.(^ast.Basic_Directive); ok {
		if basic_dir.name == "caller_expression" {
			return true
		}
	}

	// Check for #caller_expression(...) call
	call := unparen_expr(expr)
	if call_expr, ok := call.derived.(^ast.Call_Expr); ok {
		if basic_dir, ok2 := call_expr.expr.derived.(^ast.Basic_Directive); ok2 {
			return basic_dir.name == "caller_expression"
		}
	}

	return false
}

// handle_parameter_value evaluates a default parameter value expression
// Reference: /mnt/c/odin/src/check_type.cpp:1657-1763
// Validates that the default value is a compile-time constant
handle_parameter_value :: proc(ctx: ^Checker_Context, in_type: ^Type, out_type_ptr: ^^Type, expr: ^ast.Node, allow_caller_location: bool) -> Parameter_Value {
	param_value: Parameter_Value
	param_value.original_ast_expr = cast(^ast.Expr)expr

	if expr == nil {
		return param_value
	}

	o: Operand

	// Handle #caller_location directive
	// C++ Reference: check_type.cpp:1665-1676
	if allow_caller_location {
		if basic_dir, ok := expr.derived.(^ast.Basic_Directive); ok {
			if basic_dir.name == "caller_location" {
				init_core_source_code_location(ctx.checker)
				loc_type := ctx.info.cached_source_code_location
				if loc_type == nil {
					error(expr, "'#caller_location' requires base:runtime to be imported")
					return param_value
				}
				param_value.kind = .Location
				o.type = loc_type
				o.mode = .Value
				o.expr = expr

				if in_type != nil {
					check_assignment(ctx, &o, in_type, "parameter value")
				}

				if out_type_ptr != nil {
					out_type_ptr^ = o.type
				}
				return param_value
			}
		}
	}

	// Handle caller expression directives like #caller_expression
	// Reference: /mnt/c/odin/src/check_type.cpp:1677-1689
	if is_caller_expression(expr) {
		// If it's not a basic directive, validate it as a call expression
		if _, ok := expr.derived.(^ast.Basic_Directive); !ok {
			check_builtin_procedure_directive(ctx, &o, expr, t_string)
		}

		param_value.kind = .Expression
		o.type = t_string
		o.mode = .Value
		o.expr = expr

		if in_type != nil {
			check_assignment(ctx, &o, in_type, "parameter value")
		}

		if out_type_ptr != nil {
			out_type_ptr^ = o.type
		}
		return param_value
	}

	// Check the default value expression
	// Reference: /mnt/c/odin/src/check_type.cpp:1691-1699
	if in_type != nil {
		check_expr_with_type_hint(ctx, &o, expr, in_type)
		check_assignment(ctx, &o, in_type, "parameter value")
	} else {
		check_expr(ctx, &o, expr)
	}

	// Determine parameter value kind based on the operand
	// Reference: /mnt/c/odin/src/check_type.cpp:1702-1751
	if is_operand_nil(o) {
		param_value.kind = .Nil
	} else if o.mode != .Constant {
		// Non-constant operand - check for special cases
		// Reference: /mnt/c/odin/src/check_type.cpp:1704-1740

		// Handle procedure literals as default parameters
		// C++ Reference: check_type.cpp:1705-1707
		if _, is_proc_lit := expr.derived.(^ast.Proc_Lit); is_proc_lit {
			param_value.kind = .Constant
			param_value.value = exact_value_procedure(cast(^ast.Expr)expr)
		} else {
			entity := entity_of_node(ctx.info, o.expr)
			if entity != nil {
				if entity.kind == .Procedure {
					// Procedure as default parameter
					param_value.kind = .Constant
					param_value.value = exact_value_procedure(cast(^ast.Expr)entity.identifier)
				} else if .Param in entity.flags {
					// Cannot use another parameter as default
					error(expr, "Default parameter cannot be another parameter")
				} else {
					// Store as runtime value (for global variables, etc.)
					param_value.kind = .Value
					param_value.ast_value = cast(^ast.Expr)expr
				}
			} else if o.value != nil {
				// Has an exact value even though not constant mode
				param_value.kind = .Constant
				param_value.value = o.value
			} else {
				error(expr, "Default parameter must be a constant")
			}
		}
	} else {
		// Constant operand
		if o.value != nil {
			param_value.kind = .Constant
			param_value.value = o.value
		} else {
			error(o.expr, "Invalid constant parameter")
		}
	}

	// Set output type
	// Reference: /mnt/c/odin/src/check_type.cpp:1754-1760
	if out_type_ptr != nil {
		if in_type != nil {
			out_type_ptr^ = in_type
		} else {
			out_type_ptr^ = default_type(o.type)
		}
	}

	return param_value
}

// check_get_params processes procedure parameters and builds the parameter tuple type
// Ported from check_get_params in check_type.cpp:1766-2279
// Implementation now includes polymorphic type parameter support
check_get_params :: proc(
	ctx: ^Checker_Context,
	scope: ^Scope,
	params_node: ^ast.Field_List,
	is_variadic: ^bool,
	variadic_index: ^int,
	is_c_vararg: ^bool, // C++ line 1803
	success: ^bool,
	specialization_count: ^int,
	operands: []Operand,
) -> ^Type {
	if params_node == nil {
		return nil
	}

	// Early return for empty parameter list
	if len(params_node.list) == 0 {
		if success != nil {
			success^ = true
		}
		return nil
	}

	// Count total parameter variables
	variable_count := 0
	for param in params_node.list {
		field, ok := param.derived.(^ast.Field)
		if !ok {
			continue
		}
		variable_count += max(len(field.names), 1)
	}

	// Initialize output parameters
	local_success := true
	local_is_variadic := false
	local_variadic_index := -1
	local_is_c_vararg := false // C++ line 1803

	// Allocate storage for parameter entities (use checker allocator, not context.allocator
	// which may be temp_allocator in tests)
	variables := make([dynamic]^Entity, 0, variable_count, ctx.checker.allocator)

	// Process each parameter field
	field_group_index := i32(-1)
	for param in params_node.list {
		field, ok := param.derived.(^ast.Field)
		if !ok {
			continue
		}

		field_group_index += 1

		// Get type expression, handling variadic and polymorphic parameters
		type_expr := field.type
		param_type: ^Type = nil
		is_field_variadic := false

		// Track polymorphic parameter state (C++ lines 1818-1821)
		is_type_param := false // $T: typeid
		is_type_polymorphic_type := false // []$T, ^$T, etc.
		determine_type_from_operand := false // Infer type from call-site operand
		specialization: ^Type = nil // $T: typeid/SomeInterface

		// Check for ellipsis (variadic parameter)
		if type_expr != nil {
			if ellipsis, is_ellipsis := type_expr.derived.(^ast.Ellipsis); is_ellipsis {
				is_field_variadic = true
				local_is_variadic = true
				local_variadic_index = len(variables)

				// Variadic parameter must have single name
				if len(field.names) != 1 {
					error(param, "Invalid AST: Invalid variadic parameter with multiple names")
					local_success = false
				}

				// Check for unsupported default value on variadic
				if field.default_value != nil {
					error(type_expr, "A variadic parameter may not have a default value")
					local_success = false
				}

				// Get inner type and wrap in slice
				inner_type_expr := ellipsis.expr
				if inner_type_expr != nil {
					inner_type := check_type(ctx, inner_type_expr)
					param_type = make_slice_type(inner_type)
				} else {
					error(type_expr, "Variadic parameter must have a type")
					param_type = t_invalid
					local_success = false
				}
			} else if typeid_type, is_typeid := type_expr.derived.(^ast.Typeid_Type); is_typeid {
				// Polymorphic type parameter: $T: typeid or $T: typeid/SomeType
				// C++ lines 1852-1868
				if typeid_type.specialization != nil {
					// Check specialization type (e.g., $T: typeid/Integer)
					specialization = check_type(ctx, typeid_type.specialization)
					if specialization == t_invalid {
						specialization = nil
					}

					// If operands provided, we'll determine type from call-site argument
					if len(operands) > 0 {
						determine_type_from_operand = true
						param_type = t_invalid // Will be set later from operand
					} else {
						// No operands - create generic type parameter
						param_type = make_type_generic(scope, "", specialization)
					}
				} else {
					// Plain $T: typeid with no specialization
					param_type = t_typeid
				}
			} else {
				// Normal parameter type (may contain polymorphic types like []$T)
				// C++ lines 1870-1881
				prev_allow := ctx.allow_polymorphic_types
				if len(operands) > 0 {
					// Allow polymorphic types when specializing
					ctx.allow_polymorphic_types = true
				}

				param_type = check_type(ctx, type_expr)

				ctx.allow_polymorphic_types = prev_allow

				// Check if result is polymorphic (e.g., []$T)
				if is_type_polymorphic(param_type) {
					is_type_polymorphic_type = true
				}
			}
		}

		// Handle default parameter values
		// Reference: /mnt/c/odin/src/check_type.cpp:424-435
		param_value: Parameter_Value
		if field.default_value != nil && !is_field_variadic {
			// Check the default value expression
			// Reference: handle_parameter_value in C++ (lines 1657-1760)
			// allow_caller_location = true for procedure parameters
			out_type: ^Type = nil
			param_value = handle_parameter_value(ctx, param_type, &out_type, field.default_value, true)

			// If parameter type not specified, infer from default value
			if param_type == nil && out_type != nil {
				param_type = out_type
			}

			// Validate the default value kind.
			//
			// `.Value` MUST be accepted here. C++ produces ParameterValue_Value for a non-constant
			// default that resolves to an entity - `allocator := context.allocator` (the
			// `allocator` field of Context), and equally a global variable used as a default - and
			// it applies NO post-validation in this path at all: handle_parameter_value is called
			// with allow_caller_location=true at check_type.cpp:1919 and :1975 and its result is
			// used as-is. The only C++ site that restricts the kind is check_type.cpp:459, which is
			// the POLYMORPHIC parameter path (allow_caller_location=false) and permits just
			// Constant/Nil.
			//
			// This switch was a port invention in the procedure-parameter path, and rejecting
			// `.Value` is what produced "Invalid parameter value" on every `context.allocator`
			// default in core. The stale reference it carried (check_type.cpp:431-434) points at
			// unrelated code.
			#partial switch param_value.kind {
			case .Constant, .Nil, .Location, .Expression, .Value:
				// Valid parameter value kinds
			case:
				error(field.default_value, "Invalid parameter value")
				param_value = Parameter_Value{} // Reset to invalid
			}
		}

		// Validate parameter type
		if param_type == nil {
			error(param, "Invalid parameter type")
			param_type = t_invalid
			local_success = false
		}

		if is_type_untyped(param_type) {
			if is_type_untyped_uninit(param_type) {
				error(param, "Cannot determine parameter type from ---")
			} else {
				error(param, "Cannot determine parameter type from a nil")
			}
			param_type = t_invalid
			local_success = false
		}

		// Check for 'using' parameter flag
		is_using := ast.Field_Flag.Using in field.flags

		// Process each parameter name
		for name_node, j in field.names {
			_ = j

			// Check for polymorphic name ($T as parameter name)
			// C++ lines 1955-1977
			is_poly_name := false
			actual_name_node := name_node

			if poly_name, is_poly := name_node.derived.(^ast.Poly_Type); is_poly {
				is_poly_name = true
				// Extract the actual identifier from $T
				actual_name_node = poly_name.type

				// Determine if this is a type parameter
				// C++ Reference: check_type.cpp:1968-1976
				if type_expr != nil {
					if _, is_typeid := type_expr.derived.(^ast.Typeid_Type); is_typeid {
						is_type_param = true
					} else {
						// Polymorphic constant parameter ($N: int, $Size: int, etc.)
						// C++ lines 1972-1975: Constant parameters cannot have default values
						if param_value.kind != .Invalid {
							error(field.default_value, "Constant parameters cannot have a default value")
							param_value.kind = .Invalid
						}
					}
				}
			}

			ident, ident_ok := actual_name_node.derived.(^ast.Ident)
			if !ident_ok {
				error(name_node, "Parameter name must be an identifier")
				local_success = false
				continue
			}

			param_name := ident.name

			// Note: Blank identifier (_) is valid for unnamed parameters
			// The parser creates "_" as a placeholder when parsing proc(int) style types
			// C++ also allows this - it represents parameters that can't be referenced by name

			// Check for #c_vararg flag
			// C++ lines 1940-1948
			if ast.Field_Flag.C_Vararg in field.flags {
				// #c_vararg must be on a variadic parameter
				if type_expr == nil || !is_field_variadic {
					error(param, "'#c_vararg' can only be applied to variadic type fields")
					local_success = false
				} else {
					local_is_c_vararg = true
				}
			}

			// Check for #any_int flag
			// C++ lines 2222-2228
			if ast.Field_Flag.Any_Int in field.flags {
				// Validate parameter type is integer or enum
				if !is_type_integer(param_type) && !is_type_enum(param_type) {
					param_type_str := type_to_string(param_type)
					error(name_node, "A parameter with '#any_int' must be an integer, got %s", param_type_str)
					local_success = false
				}
				// Note: Entity_Flag.Any_Int is set later after entity creation (lines 2446-2449)
			}

			// Validate flags for polymorphic constant parameters
			// C++ Reference: check_type.cpp:2169-2189
			if is_poly_name && !is_type_param {
				// Polymorphic constant parameters can't use most flags
				// Note: #const is allowed (redundant but not an error since $N is already constant)
				if ast.Field_Flag.No_Alias in field.flags {
					error(name_node, "'#no_alias' can only be applied to non constant values")
					local_success = false
				}
				if ast.Field_Flag.Any_Int in field.flags {
					error(name_node, "'#any_int' can only be applied to variable fields")
					local_success = false
				}
				// #const is redundant on polymorphic constant parameters but allowed
				if ast.Field_Flag.By_Ptr in field.flags {
					error(name_node, "'#by_ptr' can only be applied to variable fields")
					local_success = false
				}
				if ast.Field_Flag.No_Capture in field.flags {
					error(name_node, "'#no_capture' can only be applied to variable fields")
					local_success = false
				}
			}

			// Validate and process parameter flags
			// C++ Reference: check_type.cpp:2134-2165

			// #no_alias validation (C++ lines 2134-2138)
			if ast.Field_Flag.No_Alias in field.flags {
				if !is_type_pointer(param_type) && !is_type_multi_pointer(param_type) {
					error(name_node, "'#no_alias' can only be applied pointer or multi-pointer typed parameters")
					local_success = false
				}
			}

			// #by_ptr validation (C++ lines 2140-2144)
			if ast.Field_Flag.By_Ptr in field.flags {
				if is_type_internally_pointer_like(param_type) {
					error(name_node, "'#by_ptr' can only be applied to non-pointer-like parameters")
					local_success = false
				}
			}

			// #no_capture validation (C++ lines 2146-2165)
			if ast.Field_Flag.No_Capture in field.flags {
				if is_field_variadic && local_variadic_index == len(variables) {
					if ast.Field_Flag.C_Vararg in field.flags {
						error(name_node, "'#no_capture' cannot be applied to a #c_vararg parameter")
						local_success = false
					} else {
						error(name_node, "'#no_capture' is already implied on all variadic parameter")
					}
				} else if is_type_polymorphic(param_type) {
					// Polymorphic types are allowed - no error
				} else {
					if is_type_internally_pointer_like(param_type) {
						error(name_node, "'#no_capture' is currently reserved for future use")
					} else {
						error(name_node, "'#no_capture' can only be applied to pointer-like types")
						error_line("\t'#no_capture' does not currently do anything useful\n")
						local_success = false
					}
				}
			}

			// Handle polymorphic type parameters and operand-based binding
			// C++ lines 1980-2018 (is_type_param branch)
			// C++ lines 2044-2132 (operand handling)
			if is_type_param {
				// $T: typeid parameter
				// If operands provided, bind to the concrete type from call-site
				if len(operands) > 0 && len(variables) < len(operands) {
					operand := operands[len(variables)]

					// Operand must be a type (C++ lines 1982-1991)
					if operand.mode == .Type {
						param_type = operand.type
					} else {
						if !ctx.no_polymorphic_errors {
							error(operand.expr, "Expected a type to assign to the type parameter")
						}
						local_success = false
						param_type = t_invalid
					}

					// Validate type is not polymorphic (C++ lines 1992-1997)
					if is_type_polymorphic(param_type) {
						error(operand.expr, "Cannot pass polymorphic type as a parameter")
						local_success = false
						param_type = t_invalid
					}

					// Check type is not untyped (C++ lines 1999-2005)
					if is_type_untyped(default_type(param_type)) {
						error(operand.expr, "Cannot determine type from the parameter")
						local_success = false
						param_type = t_invalid
					}

					// Validate specialization constraint (C++ lines 2008-2018)
					modify_type := !ctx.no_polymorphic_errors
					if specialization != nil && !check_type_specialization_to(ctx, specialization, param_type, false, modify_type) {
						if !ctx.no_polymorphic_errors {
							type_str := type_to_string(param_type)
							spec_str := type_to_string(specialization)
							error(operand.expr, "Cannot convert type '%s' to the specialization '%s'", type_str, spec_str)
						}
						local_success = false
						param_type = t_invalid
					}
				}

				// Type parameters cannot use these flags (C++ lines 2021-2040)
				if ast.Field_Flag.Const in field.flags {
					error(name_node, "'#const' can only be applied to variable fields")
					local_success = false
				}
				if ast.Field_Flag.Any_Int in field.flags {
					error(name_node, "'#any_int' can only be applied to variable fields")
					local_success = false
				}
				if ast.Field_Flag.No_Broadcast in field.flags {
					error(name_node, "'#no_broadcast' can only be applied to variable fields")
					local_success = false
				}
				if ast.Field_Flag.By_Ptr in field.flags {
					error(name_node, "'#by_ptr' can only be applied to variable fields")
					local_success = false
				}
				if ast.Field_Flag.No_Capture in field.flags {
					error(name_node, "'#no_capture' can only be applied to variable fields")
					local_success = false
				}

				// Create type name entity for $T (C++ line 2042)
				param_entity := alloc_entity_type_name(scope, tokenizer.Token{text = param_name, pos = actual_name_node.pos}, param_type, .Resolved)
				// Mark as type alias (C++ line 2043)
				if type_name, ok2 := &param_entity.variant.(Entity_Type_Name); ok2 {
					type_name.is_type_alias = true
				}

				// Add type parameter to scope (C++ line 2042)
				// Check for duplicate parameter name
				if param_name != "_" { // Allow multiple blank parameters
					if existing := scope_insert(scope, param_entity); existing != nil {
						error(name_node, "Duplicate parameter '%s' in polymorphic type", param_name)
						local_success = false
					}
				}
				append(&variables, param_entity)
			} else {
				// Regular value parameter (possibly polymorphic type like []$T)
				// OR polymorphic constant parameter ($N: int)
				// C++ lines 2044-2203

				// Initialize polymorphic constant value (C++ line 2045)
				poly_const: Exact_Value = {}

				// If operands provided, extract values and determine types
				if len(operands) > 0 && len(variables) < len(operands) {
					operand := operands[len(variables)]

					// If parameter type contains polymorphic types (e.g., []$T),
					// determine concrete type from operand (C++ lines 2057-2070)
					if is_type_polymorphic_type {
						param_type = determine_type_from_polymorphic(ctx, param_type, operand)
						if param_type == t_invalid {
							local_success = false
						}
					}

					// Extract constant value for polymorphic constant parameters
					// C++ Reference: check_type.cpp:2072-2095
					if is_poly_name {
						valid := false

						// Check if operand is a procedure (C++ lines 2074-2083)
						if is_type_proc(operand.type) {
							expr := unparen_expr(operand.expr)
							proc_entity := entity_from_expr(ctx, expr)

							if proc_entity != nil {
								// Use identifier if available, otherwise use expr
								ident_expr := proc_entity.identifier if proc_entity.identifier != nil else operand.expr
								poly_const = exact_value_procedure(cast(^ast.Expr)ident_expr)
								valid = true
							} else if _, is_proc_lit := expr.derived.(^ast.Proc_Lit); is_proc_lit {
								poly_const = exact_value_procedure(cast(^ast.Expr)expr)
								valid = true
							}
						}

						// If not valid procedure, check if it's a constant value (C++ lines 2085-2093)
						if !valid {
							if operand.mode == .Constant {
								poly_const = operand.value
							} else {
								// C++ line 2089: Suppress error during proc group overload resolution
								if !ctx.in_proc_group {
									error(operand.expr, "Expected a constant value for this polymorphic name parameter")
								}
								local_success = false
							}
						}
					}

					// Validate operand is not untyped after type determination (C++ lines 2125-2131)
					if is_type_untyped(default_type(param_type)) {
						error(operand.expr, "Cannot determine type from the parameter")
						local_success = false
						param_type = t_invalid
					}
				}

				// Validate constant parameter type (C++ line 2192)
				// For polymorphic constant parameters, the type must be a constant type
				if is_poly_name && !is_type_polymorphic(param_type) {
					if !is_type_constant_type(param_type) {
						param_type_str := type_to_string(param_type)
						error(param, "A parameter must be a valid constant type, got %s", param_type_str)
						local_success = false
					}
				}

				// Create parameter entity (C++ lines 2196-2203)
				param_entity: ^Entity
				if is_poly_name {
					// Polymorphic constant parameter ($N: int)
					// C++ line 2196: alloc_entity_const_param
					param_entity = alloc_entity_const_param(
						scope,
						tokenizer.Token{text = param_name, pos = actual_name_node.pos},
						param_type,
						poly_const,
						is_type_polymorphic(param_type), // poly_const flag
					)
					// Store field_group_index (C++ line 2197)
					if const_ent, ok3 := &param_entity.variant.(Entity_Constant); ok3 {
						const_ent.field_group_index = field_group_index
					}
				} else {
					// Regular parameter (C++ lines 2199-2202)
					param_entity = alloc_entity_param(scope, tokenizer.Token{text = param_name, pos = actual_name_node.pos}, param_type, is_using)

					// Store default parameter value (C++ line 2200)
					if param_value.kind != .Invalid {
						if var, ok4 := &param_entity.variant.(Entity_Variable); ok4 {
							var.param_value = param_value
						}
					}

					// Store field_group_index (C++ line 2201)
					if var, ok5 := &param_entity.variant.(Entity_Variable); ok5 {
						var.field_group_index = field_group_index
					}
				}

				// Set entity flags for variadic and c_vararg parameters
				// C++ Reference: check_type.cpp:2206-2212
				if is_field_variadic && local_variadic_index == len(variables) {
					if .Ellipsis not_in param_entity.flags {
						param_entity.flags += {.Ellipsis}
					}
					if local_is_c_vararg {
						if .C_Var_Arg not_in param_entity.flags {
							param_entity.flags += {.C_Var_Arg}
						}
					} else {
						// Regular variadic (non-c_vararg) gets No_Capture flag
						// C++ Reference: check_type.cpp:2211
						if .No_Capture not_in param_entity.flags {
							param_entity.flags += {.No_Capture}
						}
					}
				}

				// Set entity flags from field flags
				// C++ Reference: check_type.cpp:2215-2238

				// #no_alias flag (C++ lines 2215-2216)
				if ast.Field_Flag.No_Alias in field.flags {
					if .No_Alias not_in param_entity.flags {
						param_entity.flags += {.No_Alias}
					}
				}

				// #no_broadcast flag (C++ lines 2218-2219)
				if ast.Field_Flag.No_Broadcast in field.flags {
					if .No_Broadcast not_in param_entity.flags {
						param_entity.flags += {.No_Broadcast}
					}
				}

				// #any_int flag - note: validation not shown here, done elsewhere
				// C++ lines 2222-2228
				if ast.Field_Flag.Any_Int in field.flags {
					if .Any_Int not_in param_entity.flags {
						param_entity.flags += {.Any_Int}
					}
				}

				// #const flag (C++ lines 2230-2231)
				if ast.Field_Flag.Const in field.flags {
					if .Const_Input not_in param_entity.flags {
						param_entity.flags += {.Const_Input}
					}
				}

				// #by_ptr flag (C++ lines 2233-2234)
				if ast.Field_Flag.By_Ptr in field.flags {
					if .By_Ptr not_in param_entity.flags {
						param_entity.flags += {.By_Ptr}
					}
				}

				// #no_capture flag (C++ lines 2236-2237)
				if ast.Field_Flag.No_Capture in field.flags {
					if .No_Capture not_in param_entity.flags {
						param_entity.flags += {.No_Capture}
					}
				}

				// Add parameter to scope (C++ lines 2242-2250)
				// Check for duplicate parameter name
				if param_name != "_" { // Allow multiple blank parameters
					if existing := scope_insert(scope, param_entity); existing != nil {
						error(name_node, "Duplicate parameter '%s'", param_name)
						local_success = false
					}
				}
				append(&variables, param_entity)
			}
		}
	}

	// Validate variadic state
	if local_is_variadic {
		assert(local_variadic_index >= 0)
		assert(len(params_node.list) > 0)
	}

	// Build tuple type from parameter entities
	tuple := new(Type, ctx.checker.allocator)
	tuple.kind = .Tuple

	// Store Entity_Variable objects directly, matching C++ implementation
	tuple.variant = Type_Tuple {
		variables = variables,
		is_packed = false, // Parameters are never packed
	}

	// Set output parameters
	if success != nil {
		success^ = local_success
	}
	if is_variadic != nil {
		is_variadic^ = local_is_variadic
	}
	if variadic_index != nil {
		variadic_index^ = local_variadic_index
	}
	if is_c_vararg != nil {
		is_c_vararg^ = local_is_c_vararg // C++ line 2274
	}
	if specialization_count != nil {
		// Count specialized Generic types in scope
		// C++ Reference: check_type.cpp:2256-2268
		local_specialization_count := 0
		if scope != nil {
			for name, entity in scope.elements {
				_ = name
				if entity.kind == .Type_Name {
					t := entity.type
					if t != nil && t.kind == .Generic {
						if generic, ok := t.variant.(Type_Generic); ok {
							if generic.specialized != nil {
								local_specialization_count += 1
							}
						}
					}
				}
			}
		}
		specialization_count^ = local_specialization_count
	}

	return tuple
}

// check_get_results processes procedure return types and builds the results tuple type
// Ported from check_get_results in check_type.cpp:2281-2389
check_get_results :: proc(ctx: ^Checker_Context, scope: ^Scope, results_node: ^ast.Field_List) -> ^Type {
	// No results - void procedure
	if results_node == nil {
		return nil
	}

	// Empty results list - void procedure
	if len(results_node.list) == 0 {
		return nil
	}

	// Count total result variables
	variable_count := 0
	for field in results_node.list {
		if f, ok := field.derived.(^ast.Field); ok {
			variable_count += max(len(f.names), 1)
		}
	}

	// Build result types and entities
	result_types := make([dynamic]^Type, 0, variable_count, context.temp_allocator)
	result_entities := make([dynamic]^Entity, 0, variable_count, context.temp_allocator)
	has_named_results := false

	field_group_index := i32(-1)

	for field_node in results_node.list {
		field, ok := field_node.derived.(^ast.Field)
		if !ok {
			continue
		}

		field_group_index += 1

		// Check result type
		result_type: ^Type = nil
		if field.type != nil {
			result_type = check_type(ctx, field.type)
		}

		// Validate result type
		if result_type == nil {
			error(field_node, "Invalid parameter type")
			result_type = t_invalid
		}

		if is_type_untyped(result_type) {
			if is_type_untyped_uninit(result_type) {
				error(field_node, "Cannot determine parameter type from ---")
			} else {
				error(field_node, "Cannot determine parameter type from a nil")
			}
			result_type = t_invalid
		}

		// No validation needed here - polymorphic types are valid in return position

		// Check if this is an unnamed result
		// The parser may create placeholder names ("_" or "") for type-only fields
		is_unnamed_result := len(field.names) == 0
		if !is_unnamed_result && len(field.names) == 1 {
			if first_ident, ident_ok := field.names[0].derived.(^ast.Ident); ident_ok {
				// Parser-generated placeholders use "_" or empty string
				is_unnamed_result = first_ident.name == "_" || first_ident.name == ""
			}
		}

		// Handle unnamed result
		if is_unnamed_result {
			// Create anonymous result entity (not added to scope)
			token := tokenizer.Token {
				text = "",
				pos  = field_node.pos,
			}
			if field.type != nil {
				token.pos = field.type.pos
			}

			entity := alloc_entity_param(scope, token, result_type, false, false)
			// Set field_group_index for unnamed result (C++ line 2337)
			if var_data, var_ok := &entity.variant.(Entity_Variable); var_ok {
				var_data.field_group_index = -1
			}

			append(&result_types, result_type)
			append(&result_entities, entity)
		} else {
			// Handle named results
			for name_node in field.names {
				ident, ident_ok := name_node.derived.(^ast.Ident)
				if !ident_ok {
					error(name_node, "Expected an identifier for the field name")
					continue
				}

				name := ident.name

				// Check for blank identifier (user explicitly wrote `_: type`)
				if is_blank_ident(name) {
					error(name_node, "Result value cannot be a blank identifier `_`")
					continue
				}

				// Create named result entity
				token := tokenizer.Token {
					text = name,
					pos  = name_node.pos,
				}
				entity := alloc_entity_param(scope, token, result_type, false, false)

				// Mark as result (C++ line 2359)
				entity.flags += {.Result}
				// Set field_group_index (C++ line 2361)
				if var_data, var_ok := &entity.variant.(Entity_Variable); var_ok {
					var_data.field_group_index = field_group_index
				}

				append(&result_types, result_type)
				append(&result_entities, entity)

				// Add to scope
				add_entity(ctx, scope, name_node, entity)

				// Mark as used to prevent "declared but not used" warning
				add_entity_use(ctx, name_node, entity)

				has_named_results = true
			}
		}
	}

	// Check for duplicate result names
	for i in 0 ..< len(result_entities) {
		x := result_entities[i].token.text
		if len(x) == 0 || is_blank_ident(x) {
			continue
		}

		for j in (i + 1) ..< len(result_entities) {
			y := result_entities[j].token.text
			if len(y) == 0 || is_blank_ident(y) {
				continue
			}

			if x == y {
				error(result_entities[j].token, "Duplicate return value name '%s'", y)
			}
		}
	}

	// Build tuple type from Entity_Variable objects
	// C++ Reference: check_type.cpp:2291, 2386
	// IMPORTANT: Always return a tuple, even for single results
	tuple := new(Type, ctx.checker.allocator)
	tuple.kind = .Tuple
	tuple.variant = Type_Tuple {
		variables = make([dynamic]^Entity, len(result_entities), ctx.checker.allocator),
		is_packed = false, // Results are never packed
	}

	tuple_data := &tuple.variant.(Type_Tuple)
	for entity, i in result_entities {
		tuple_data.variables[i] = entity
	}

	return tuple
}

// check_procedure_param_polymorphic_type validates that polymorphic record types
// used as procedure parameters are properly specialized (not bare type names)
// C++ Reference: check_type.cpp:2391-2411
check_procedure_param_polymorphic_type :: proc(ctx: ^Checker_Context, type: ^Type, type_expr: ^ast.Expr) {
	if type == nil || type_expr == nil || ctx.in_polymorphic_specialization {
		return
	}

	// Only check if type is an unspecialized polymorphic record
	// C++ Reference: check_type.cpp:2393
	if !is_type_polymorphic_record_unspecialized(type) {
		return
	}

	// Check for invalid direct use of polymorphic type
	// Valid: MyType(int, f64) or MyType($T, $U)
	// Invalid: MyType (bare identifier/selector)
	invalid_polymorphic_type_use := false

	#partial switch expr in type_expr.derived {
	case ^ast.Ident:
		// C++ Reference: check_type.cpp:2397-2398
		invalid_polymorphic_type_use = true
	case ^ast.Selector_Expr:
		// C++ Reference: check_type.cpp:2401-2402
		invalid_polymorphic_type_use = true
	}

	if invalid_polymorphic_type_use {
		// C++ Reference: check_type.cpp:2407-2409
		expr_str := expr_to_string(type_expr)
		defer delete(expr_str)
		error(type_expr, "Invalid use of a non-specialized polymorphic type '%s'", expr_str)
	}
}

// Note: Target_Arch_Kind is defined in build_settings.odin

// Note: check_selector moved to check_expr.odin

set_base_type :: proc(named: ^Type, base: ^Type) {
	if named != nil && named.kind == .Named {
		// Update named type's base
		if ntype, ok := &named.variant.(Type_Named); ok {
			ntype.base = base
		}
	}
}

// ========================================
// Helper functions for union and enum types
// ========================================

// is_type_empty_union checks if a type is an empty union
// Ported from is_type_empty_union in types.cpp:2111-2120
is_type_empty_union :: proc(t: ^Type) -> bool {
	if t == nil {
		return false
	}
	bt := base_type(t)
	if t == nil {
		return false
	}
	if bt.kind != .Union {
		return false
	}
	union_type := bt.variant.(Type_Union)
	return len(union_type.variants) == 0
}

// is_type_integer_128bit checks if a type is a 128-bit integer
// Ported from is_type_integer_128bit in types.cpp:1277-1284
is_type_integer_128bit :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	if t == nil {
		return false
	}
	if bt.kind != .Basic {
		return false
	}
	basic := bt.variant.(Type_Basic)
	return (basic.kind == .I128 || basic.kind == .U128) && basic.size == 16
}

// is_type_enum checks if a type is an enum
is_type_enum :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	return bt.kind == .Enum
}

// type_has_nil checks if a type can have a nil value
// Ported from type_has_nil in types.cpp:2474-2513
// type_has_nil is defined in check_equivalence.odin

// union_variant_index_types_equal checks if two types are considered equal for union variant indexing
// Ported from union_variant_index_types_equal in types.cpp:3258-3266
union_variant_index_types_equal :: proc(v: ^Type, vt: ^Type) -> bool {
	if are_types_identical(v, vt) {
		return true
	}
	// Special case: procedure types compare by base type identity
	if is_type_proc(v) && is_type_proc(vt) {
		return are_types_identical(base_type(v), base_type(vt))
	}
	return false
}

// NOTE: exact_binary_operator_value, compare_exact_values, and check_expr
// are now implemented in check_expr.odin

// ============================================================================
// Polymorphic Type Checking Implementation
// ============================================================================

// polymorphic_assign_index binds a generic count parameter to a concrete value
// Used for generic array counts, SIMD vector counts, matrix dimensions, and fixed dynamic capacities
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:1389-1419
//
// TWO DIVERGENCES FIXED HERE, both of which broke `[$N]$E`:
//
//  1. The entity was read from Type_Generic.entity. C++ does NOT do that - it looks the entity up in
//     the generic's own scope by name (`scope_lookup(gt->Generic.scope, gt->Generic.interned_name)`).
//     For a generic COUNT the `entity` field is never populated, so every branch fell through to the
//     bare `return false` at the end and `[$N]$E` simply never unified. That is why
//     `proc(a: $T/[$N]$E)` could not be called with a `[4]int`, while `[4]$E` and `[]$E` worked.
//
//  2. The mutations were unconditional. C++ guards every write with modify_type, because callers run
//     speculative match attempts with modify_type = false (the Generic arm of
//     is_polymorphic_type_assignable does exactly that when testing a specialization). Mutating the
//     entity into a Constant during a trial match permanently corrupts it for later real matches.
polymorphic_assign_index :: proc(
	gt: ^^Type, // Generic type (Type_Generic) - cleared after binding when modify_type
	dst_count: ^i64, // Destination count to set
	source_count: i64, // Source count value
	modify_type: bool, // False for speculative matches: check only, do not bind
) -> bool {
	// If gt is nil or already cleared, just set the count
	if gt == nil || gt^ == nil {
		if dst_count != nil {
			dst_count^ = source_count
		}
		return true
	}

	// Verify this is actually a generic type
	if gt^.kind != .Generic {
		if dst_count != nil {
			dst_count^ = source_count
		}
		return true
	}

	generic := gt^.variant.(Type_Generic)

	// C++ Reference: check_expr.cpp:1392-1393. C++ resolves the entity by name from the generic's
	// scope and asserts it exists. The stored `entity` field is consulted only as a fallback, since
	// it is populated for some generics and not others.
	e: ^Entity
	if generic.scope != nil && generic.name != "" {
		e = scope_lookup(generic.scope, generic.name)
	}
	if e == nil {
		e = generic.entity
	}
	if e == nil {
		return false
	}

	if e.kind == .Type_Name {
		// C++ Reference: check_expr.cpp:1394-1403
		if dst_count != nil {
			dst_count^ = source_count
		}
		if modify_type {
			gt^ = nil
			e.kind = .Constant
			e.variant = Entity_Constant {
				type  = t_untyped_integer,
				value = exact_value_i64(source_count),
			}
			set_entity_type(e, t_untyped_integer)
		}
		return true
	} else if e.kind == .Constant {
		// C++ Reference: check_expr.cpp:1404-1416
		constant := e.variant.(Entity_Constant)

		count: i64
		#partial switch &v in constant.value {
		case big.Int:
			c, err := big.int_get_i64(&v)
			if err != nil {
				return false
			}
			count = c
		case:
			// C++ requires ExactValue_Integer; anything else is not a valid count.
			return false
		}

		if count != source_count {
			return false
		}
		if dst_count != nil {
			dst_count^ = source_count
		}
		if modify_type {
			gt^ = nil
		}
		return true
	}

	return false
}

// check_type_specialization_to_internal walks a polymorphic record's parameter list
// against a concrete instance's, binding each parameter.
// C++ Reference: /mnt/c/odin/src/check_type.cpp:1519-1563
check_type_specialization_to_internal :: proc(
	ctx: ^Checker_Context,
	specialization: ^Type,
	type: ^Type,
	s_tuple: ^Type_Tuple,
	t_tuple: ^Type_Tuple,
	modify_type: bool,
) -> bool {
	// C++ GB_ASSERTs equal counts; return false instead so a malformed pair cannot
	// take down the checker.
	if s_tuple == nil || t_tuple == nil || len(s_tuple.variables) != len(t_tuple.variables) {
		return false
	}

	for i in 0 ..< len(s_tuple.variables) {
		s_e := s_tuple.variables[i]
		t_e := t_tuple.variables[i]
		st := entity_type(s_e)
		tt := entity_type(t_e)
		if st == nil || tt == nil {
			return false
		}

		// C++ line 1529: override polymorphic named constants in types
		if st.kind == .Generic && t_e.kind == .Constant {
			generic := st.variant.(Type_Generic)
			e := scope_lookup(generic.scope, generic.name)
			if e != nil && modify_type {
				e.kind = .Constant
				type_const := t_e.variant.(Entity_Constant)
				e.variant = Entity_Constant {
					type              = type_const.type,
					value             = type_const.value,
					param_value       = type_const.param_value,
					flags             = type_const.flags,
					field_group_index = type_const.field_group_index,
				}
				e.type = type_const.type
			}
			continue
		}

		// C++ line 1538-1542: two constants of basic type must compare equal
		if st.kind == .Basic && tt.kind == .Basic && s_e.kind == .Constant && t_e.kind == .Constant {
			s_c := s_e.variant.(Entity_Constant)
			t_c := t_e.variant.(Entity_Constant)
			if !compare_exact_values(.Cmp_Eq, s_c.value, t_c.value) {
				return false
			}
			continue
		}

		// C++ line 1545: `compound` is hard-coded true here
		if !is_polymorphic_type_assignable(ctx, st, tt, true, modify_type) {
			return false
		}
	}

	if modify_type {
		// C++ line 1560: gb_memmove(specialization, type, sizeof(Type)) — change the
		// actual type while keeping the types defined within it.
		specialization.kind = type.kind
		specialization.variant = type.variant
		specialization.flags = type.flags
	}

	return true
}

// check_type_specialization_to checks whether a concrete type satisfies a polymorphic
// specialization, e.g. `Queue(string)` against the `$Q/Queue` of `proc(q: ^$Q/Queue)`.
//
// C++ Reference: /mnt/c/odin/src/check_type.cpp:1565-1631. The port previously carried a
// reduced version of this that diverged in four ways, all restored here:
//
//  1. The head guard was inverted. C++ returns TRUE for a nil/invalid `type` (nothing to
//     contradict); the port returned false.
//  2. The kind-mismatch and untyped arms were absent entirely.
//  3. The struct/union arms jumped straight to comparing `polymorphic_parent` on both
//     sides, skipping C++'s two early accepts. The second of those,
//     `t->Struct.polymorphic_parent == specialization`, is the case where the
//     specialization names the generic RECORD ITSELF rather than an instantiation —
//     exactly `^$Q/Queue`. Its absence made every such call fail to infer, reporting
//     "Cannot determine polymorphic type from parameter: '^Queue' to '^$Q/Queue'".
//  4. When no struct/union arm applied the port returned false; C++ falls through to the
//     Named check and the general assignability test.
check_type_specialization_to :: proc(
	ctx: ^Checker_Context,
	specialization: ^Type, // Polymorphic parent type (e.g., Queue($T), or Queue itself)
	type: ^Type, // Concrete type (e.g., Queue(string))
	compound: bool,
	modify_type: bool,
) -> bool {
	// C++ line 1566-1569
	if type == nil || type == t_invalid {
		return true
	}
	if specialization == nil {
		return false
	}

	t := base_type(type)
	s := base_type(specialization)
	if t == nil || s == nil {
		return false
	}

	// C++ line 1573-1580
	if t.kind != s.kind {
		if t.kind == .Enumerated_Array && s.kind == .Array {
			// Might be okay, check later
		} else {
			return false
		}
	}

	if is_type_untyped(t) {
		// C++ line 1582-1587
		o := Operand {
			mode = .Value,
			type = default_type(type),
		}
		return check_cast_internal(ctx, &o, specialization)
	} else if t.kind == .Struct && s.kind == .Struct {
		ts := t.variant.(Type_Struct)
		ss := s.variant.(Type_Struct)

		// C++ line 1589-1596
		if ts.polymorphic_parent == nil && t == s {
			return true
		}
		if ts.polymorphic_parent == specialization {
			return true
		}
		if ts.polymorphic_parent == ss.polymorphic_parent &&
		   ss.polymorphic_params != nil &&
		   ts.polymorphic_params != nil {
			return check_type_specialization_to_internal(
				ctx, specialization, type,
				get_record_polymorphic_params(s), get_record_polymorphic_params(t),
				modify_type,
			)
		}
	} else if t.kind == .Union && s.kind == .Union {
		tu := t.variant.(Type_Union)
		su := s.variant.(Type_Union)

		// C++ line 1603-1619
		if tu.polymorphic_parent == nil && t == s {
			return true
		}
		if tu.polymorphic_parent == specialization {
			return true
		}
		if tu.polymorphic_parent == su.polymorphic_parent &&
		   su.polymorphic_params != nil &&
		   tu.polymorphic_params != nil {
			return check_type_specialization_to_internal(
				ctx, specialization, type,
				get_record_polymorphic_params(s), get_record_polymorphic_params(t),
				modify_type,
			)
		}
	}

	// C++ line 1622-1625
	if specialization.kind == .Named && type.kind != .Named {
		return false
	}

	// C++ line 1626-1630
	return is_polymorphic_type_assignable(ctx, base_type(specialization), base_type(type), compound, modify_type)
}

// is_polymorphic_type_assignable checks if poly type can be assigned from source
// with optional type modification for generic type parameter binding
// C++ Reference: check_expr.cpp:1352-1670
is_polymorphic_type_assignable :: proc(
	ctx: ^Checker_Context,
	poly: ^Type, // Polymorphic type (may contain $T)
	source: ^Type, // Concrete source type
	compound: bool, // True for compound types (requires identical match)
	modify_type: bool, // True to actually bind type parameters
) -> bool {
	if poly == nil || source == nil {
		return false
	}

	// For polymorphic checking, we need to handle many type kinds
	poly_base := base_type(poly)
	source_base := base_type(source)

	// === Type_Basic === (C++ lines 1356-1358)
	if poly_base.kind == .Basic {
		if compound {
			// Compound literals require identical types
			return are_types_identical(poly, source)
		}
		// Check type compatibility, allowing untyped→typed conversions
		// C++ Reference: check_type.cpp uses check_is_assignable_to for this case
		if are_types_identical(poly, source) {
			return true
		}
		// Handle untyped literal compatibility with typed target
		// An untyped integer is compatible with any integer type, etc.
		if source_base.kind == .Basic {
			source_basic := source_base.variant.(Type_Basic)
			#partial switch source_basic.kind {
			case .Untyped_Bool:
				return is_type_boolean(poly)
			case .Untyped_Integer:
				return is_type_integer(poly) || is_type_rune(poly)
			case .Untyped_Float:
				return is_type_float(poly) || is_type_complex(poly) || is_type_quaternion(poly)
			case .Untyped_Rune:
				return is_type_integer(poly) || is_type_rune(poly)
			case .Untyped_String:
				return is_type_string(poly)
			case .Untyped_Complex:
				return is_type_complex(poly) || is_type_quaternion(poly)
			case .Untyped_Quaternion:
				return is_type_quaternion(poly)
			}
		}
		return false
	}

	// === Type_Named === (C++ check_expr.cpp:1429-1436)
	//
	// C++ switches on `poly->kind`, NOT on base_type(poly)->kind. base_type of a Named type is
	// never Named, so testing poly_base here made this arm UNREACHABLE and every `Box($T)`
	// fell through to the Struct arm below. That was survivable for a bare polymorphic struct
	// parameter but not for `^Box($T)`: the pointer arm recurses on the element, the element is
	// a Named, and without this arm it never reached check_type_specialization_to - so
	// `queue.mpsc_is_empty(&c.info.entity_queue)` reported the self-contradictory
	// "Cannot determine polymorphic type from parameter: '^MPSC_Queue' to '^MPSC_Queue'".
	if poly.kind == .Named {
		// Try specialized type first
		if check_type_specialization_to(ctx, poly, source, compound, modify_type) {
			return true
		}
		// Fall back to identity or assignment check
		if compound {
			return are_types_identical(poly, source)
		}
		return are_types_identical(poly, source)
	}

	// === Type_Generic === (C++ lines 1370-1382)
	if poly_base.kind == .Generic {
		generic := poly_base.variant.(Type_Generic)

		// C++ Reference: check_expr.cpp:1422-1427
		//
		// TWO DIVERGENCES FIXED HERE:
		//  1. This called is_polymorphic_type_assignable directly. C++ calls
		//     check_type_specialization_to, which additionally handles Named/Struct/Union
		//     specializations before delegating to is_polymorphic_type_assignable on the base types
		//     (check_type.cpp:1626). Calling the inner function skipped all of that.
		//  2. It hardcoded modify_type = false. C++ threads the caller's modify_type through. That
		//     is what allows polymorphic_assign_index to convert the count entity of `[$N]$E` from
		//     Entity_TypeName into Entity_Constant during the REAL match. With false hardcoded the
		//     conversion never happened, so `N` stayed a generic TYPE inside the instantiated body -
		//     `x := N` reported "Cannot assign a non-specialized polymorphic type '$N'" and
		//     `#assert(N == 8)` reported "'N' is not an expression but a type".
		if generic.specialized != nil {
			if !check_type_specialization_to(ctx, generic.specialized, source, compound, modify_type) {
				return false
			}
		}

		// If modify_type, bind $T to source type
		// C++ Reference: check_expr.cpp:1377-1380
		// C++ does: gb_memmove(poly, ds, gb_size_of(Type))
		if modify_type {
			// Get the default (typed) version of source
			ds := default_type(source)

			// Copy all Type fields from source to poly
			// This binds the generic parameter $T to the concrete type
			// Note: In C++, size/align are cached fields at the end of Type struct
			// In Odin, they're computed on-demand via type_size_of/type_align_of
			poly.kind = ds.kind
			poly.variant = ds.variant
			poly.flags = ds.flags
		}

		// Generic accepts any type
		return true
	}

	// === Type_Pointer === (C++ lines 1383-1397)
	if poly_base.kind == .Pointer && source_base.kind == .Pointer {
		poly_ptr := poly_base.variant.(Type_Pointer)
		source_ptr := source_base.variant.(Type_Pointer)
		// Recursively check element types
		return is_polymorphic_type_assignable(ctx, poly_ptr.elem, source_ptr.elem, true, modify_type)
	}

	// Handle MultiPointer → Pointer conversion (C++ lines 1388-1393)
	if poly_base.kind == .Pointer && source_base.kind == .Multi_Pointer {
		poly_ptr := poly_base.variant.(Type_Pointer)
		source_mp := source_base.variant.(Type_Multi_Pointer)
		// Allow multi-pointer to pointer conversion with element subtype check
		return is_polymorphic_type_assignable(ctx, poly_ptr.elem, source_mp.elem, true, modify_type)
	}

	// === Type_MultiPointer === (C++ lines 1399-1413)
	if poly_base.kind == .Multi_Pointer && source_base.kind == .Multi_Pointer {
		poly_mp := poly_base.variant.(Type_Multi_Pointer)
		source_mp := source_base.variant.(Type_Multi_Pointer)
		return is_polymorphic_type_assignable(ctx, poly_mp.elem, source_mp.elem, true, modify_type)
	}

	// Handle Pointer → MultiPointer conversion
	if poly_base.kind == .Multi_Pointer && source_base.kind == .Pointer {
		poly_mp := poly_base.variant.(Type_Multi_Pointer)
		source_ptr := source_base.variant.(Type_Pointer)
		return is_polymorphic_type_assignable(ctx, poly_mp.elem, source_ptr.elem, true, modify_type)
	}

	// === Type_Array === (C++ lines 1409-1418)
	if poly_base.kind == .Array && source_base.kind == .Array {
		poly_arr := &poly_base.variant.(Type_Array)
		source_arr := source_base.variant.(Type_Array)

		// Handle generic count for arrays with polymorphic sizes
		// C++ Reference: check_expr.cpp:1411-1414
		if poly_arr.generic_count != nil {
			if !polymorphic_assign_index(&poly_arr.generic_count, &poly_arr.count, source_arr.count, modify_type) {
				return false
			}
		}

		// Check count matches
		if poly_arr.count != source_arr.count {
			return false
		}

		// Check element types
		return is_polymorphic_type_assignable(ctx, poly_arr.elem, source_arr.elem, compound, modify_type)
	}

	// Handle EnumeratedArray → Array conversion (C++ lines 1446-1455)
	if poly_base.kind == .Array && source_base.kind == .Enumerated_Array {
		poly_arr := poly_base.variant.(Type_Array)
		source_ea := source_base.variant.(Type_Enumerated_Array)

		// Check count matches
		if poly_arr.count != source_ea.count {
			return false
		}

		// Check element types
		return is_polymorphic_type_assignable(ctx, poly_arr.elem, source_ea.elem, compound, modify_type)
	}

	// === Type_EnumeratedArray === (C++ lines 1460-1481)
	if poly_base.kind == .Enumerated_Array && source_base.kind == .Enumerated_Array {
		poly_ea := poly_base.variant.(Type_Enumerated_Array)
		source_ea := source_base.variant.(Type_Enumerated_Array)

		// Check index types
		if !is_polymorphic_type_assignable(ctx, poly_ea.index, source_ea.index, compound, modify_type) {
			return false
		}

		// Check element types
		return is_polymorphic_type_assignable(ctx, poly_ea.elem, source_ea.elem, compound, modify_type)
	}

	// === Type_Slice === (C++ lines 1488-1492)
	if poly_base.kind == .Slice && source_base.kind == .Slice {
		poly_slice := poly_base.variant.(Type_Slice)
		source_slice := source_base.variant.(Type_Slice)
		return is_polymorphic_type_assignable(ctx, poly_slice.elem, source_slice.elem, compound, modify_type)
	}

	// === Type_DynamicArray === (C++ lines 1483-1487)
	if poly_base.kind == .Dynamic_Array && source_base.kind == .Dynamic_Array {
		poly_dyn := poly_base.variant.(Type_Dynamic_Array)
		source_dyn := source_base.variant.(Type_Dynamic_Array)
		return is_polymorphic_type_assignable(ctx, poly_dyn.elem, source_dyn.elem, compound, modify_type)
	}

	// === Type_FixedCapacityDynamicArray === (C++ check_expr.cpp:1578-1595)
	//
	// `[dynamic; $N]$E` against a concrete `[dynamic; 8]int`: bind N to the source capacity, then
	// require the capacities to agree before recursing on the element type. Mirrors the Array arm
	// above, which does the same for `[$N]$E`.
	if poly_base.kind == .Fixed_Capacity_Dynamic_Array && source_base.kind == .Fixed_Capacity_Dynamic_Array {
		poly_fc := &poly_base.variant.(Type_Fixed_Capacity_Dynamic_Array)
		source_fc := source_base.variant.(Type_Fixed_Capacity_Dynamic_Array)

		// C++ Reference: check_expr.cpp:1580-1589
		if poly_fc.generic_capacity != nil {
			if !polymorphic_assign_index(&poly_fc.generic_capacity, &poly_fc.capacity, source_fc.capacity, modify_type) {
				return false
			}
		}

		// C++ Reference: check_expr.cpp:1590. C++ returns false when the capacities disagree, so a
		// concrete mismatch is simply not assignable.
		if poly_fc.capacity != source_fc.capacity {
			return false
		}

		return is_polymorphic_type_assignable(ctx, poly_fc.elem, source_fc.elem, compound, modify_type)
	}

	// === Type_Map === (C++ lines 1623-1633)
	if poly_base.kind == .Map && source_base.kind == .Map {
		poly_map := poly_base.variant.(Type_Map)
		source_map := source_base.variant.(Type_Map)

		// Check both key and value types
		if !is_polymorphic_type_assignable(ctx, poly_map.key, source_map.key, compound, modify_type) {
			return false
		}
		if !is_polymorphic_type_assignable(ctx, poly_map.value, source_map.value, compound, modify_type) {
			return false
		}

		return true
	}

	// NO Type_Struct / Type_Union ARM - deliberately.
	//
	// C++ Reference: check_expr.cpp:1421-1620 (is_polymorphic_type_assignable). Its switch on
	// `poly->kind` has no Struct and no Union case; a record poly falls through to the final
	// `return false`. Records are check_type_specialization_to's job, and that procedure calls
	// THIS one as its fall-back tail (check_type.cpp:1626), passing base types so the callee can
	// never re-enter it through the Named arm.
	//
	// This port used to have Struct and Union arms here that "delegate to
	// check_type_specialization_to". Combined with check_type_specialization_to's own
	// `polymorphic_parent == nil -> is_polymorphic_type_assignable(specialization, type)`
	// fall-back, that is a closed cycle with the arguments never changing: the two procedures
	// call each other until the stack is gone. It is reachable from ordinary code - a
	// `$T/Some_Struct` constraint resolved against a non-polymorphic struct - and took out
	// core/crypto/legacy/md5 and the multi-threaded test runner.

	// === Type_Proc === (C++ lines 1587-1622)
	if poly_base.kind == .Proc && source_base.kind == .Proc {
		poly_proc := poly_base.variant.(Type_Proc)
		source_proc := source_base.variant.(Type_Proc)

		// Match calling convention
		if poly_proc.calling_convention != source_proc.calling_convention {
			return false
		}

		// Match variadic and c_vararg flags
		if poly_proc.variadic != source_proc.variadic {
			return false
		}
		if poly_proc.c_vararg != source_proc.c_vararg {
			return false
		}

		// Match param and result counts
		if poly_proc.param_count != source_proc.param_count {
			return false
		}
		if poly_proc.result_count != source_proc.result_count {
			return false
		}

		// Check parameters
		if poly_proc.params != nil && source_proc.params != nil {
			if !is_polymorphic_type_assignable(ctx, poly_proc.params, source_proc.params, compound, modify_type) {
				return false
			}
		}

		// Check results
		if poly_proc.results != nil && source_proc.results != nil {
			if !is_polymorphic_type_assignable(ctx, poly_proc.results, source_proc.results, compound, modify_type) {
				return false
			}
		}

		return true
	}

	// === Type_Tuple === (implicitly handled for params/results)
	if poly_base.kind == .Tuple && source_base.kind == .Tuple {
		poly_tuple := poly_base.variant.(Type_Tuple)
		source_tuple := source_base.variant.(Type_Tuple)

		// Must have same number of elements
		if len(poly_tuple.variables) != len(source_tuple.variables) {
			return false
		}

		// Check each element
		for i in 0 ..< len(poly_tuple.variables) {
			poly_elem_type := entity_type(poly_tuple.variables[i])
			source_elem_type := entity_type(source_tuple.variables[i])

			if !is_polymorphic_type_assignable(ctx, poly_elem_type, source_elem_type, compound, modify_type) {
				return false
			}
		}

		return true
	}

	// === Type_BitSet === (C++ lines 1497-1521)
	if poly_base.kind == .Bit_Set && source_base.kind == .Bit_Set {
		poly_bs := poly_base.variant.(Type_Bit_Set)
		source_bs := source_base.variant.(Type_Bit_Set)

		// Check element type
		if !is_polymorphic_type_assignable(ctx, poly_bs.elem, source_bs.elem, compound, modify_type) {
			return false
		}

		// Check underlying type if present
		if poly_bs.underlying != nil && source_bs.underlying != nil {
			if !is_polymorphic_type_assignable(ctx, poly_bs.underlying, source_bs.underlying, compound, modify_type) {
				return false
			}
		}

		return true
	}

	// === Type_Matrix === (C++ lines 1630-1648)
	if poly_base.kind == .Matrix && source_base.kind == .Matrix {
		poly_mat := &poly_base.variant.(Type_Matrix)
		source_mat := source_base.variant.(Type_Matrix)

		// Handle generic row count for matrices with polymorphic dimensions
		// C++ Reference: check_expr.cpp:1632-1636
		if poly_mat.generic_row_count != nil {
			poly_mat.stride_in_bytes = 0
			if !polymorphic_assign_index(&poly_mat.generic_row_count, &poly_mat.row_count, source_mat.row_count, modify_type) {
				return false
			}
		}

		// Handle generic column count
		// C++ Reference: check_expr.cpp:1638-1642
		if poly_mat.generic_column_count != nil {
			poly_mat.stride_in_bytes = 0
			if !polymorphic_assign_index(&poly_mat.generic_column_count, &poly_mat.column_count, source_mat.column_count, modify_type) {
				return false
			}
		}

		// Check dimensions match
		if poly_mat.row_count != source_mat.row_count {
			return false
		}
		if poly_mat.column_count != source_mat.column_count {
			return false
		}

		// Check element type
		return is_polymorphic_type_assignable(ctx, poly_mat.elem, source_mat.elem, compound, modify_type)
	}

	// === Type_SimdVector === (C++ lines 1651-1662)
	if poly_base.kind == .Simd_Vector && source_base.kind == .Simd_Vector {
		poly_sv := &poly_base.variant.(Type_Simd_Vector)
		source_sv := source_base.variant.(Type_Simd_Vector)

		// Handle generic count for SIMD vectors with polymorphic sizes
		// C++ Reference: check_expr.cpp:1653-1656
		if poly_sv.generic_count != nil {
			if !polymorphic_assign_index(&poly_sv.generic_count, &poly_sv.count, source_sv.count, modify_type) {
				return false
			}
		}

		// Check count matches
		if poly_sv.count != source_sv.count {
			return false
		}

		// Check element type
		return is_polymorphic_type_assignable(ctx, poly_sv.elem, source_sv.elem, compound, modify_type)
	}

	// Default: types don't match
	return false
}

// ======================================================================================
// SOA TYPE COMPLETION
// C++ Reference: check_type.cpp:2955-3055
// ======================================================================================

// complete_soa_type generates fields for Structure-of-Arrays types
// This converts a struct #soa[N]T or #soa[]T into a struct with array/pointer fields
//
// For #soa[N]T (Fixed):
//   struct { x: int, y: int } -> struct { x: [N]int, y: [N]int }
//
// For #soa[]T (Slice):
//   struct { x: int, y: int } -> struct { x: [^]int, y: [^]int, __$len: int }
//
// For #soa[dynamic]T (Dynamic):
//   struct { x: int, y: int } -> struct { x: [^]int, y: [^]int, __$len: int, __$cap: int, allocator: mem.Allocator }
//
// C++ Reference: check_type.cpp:2955-3055
complete_soa_type :: proc(checker: ^Checker, t: ^Type, wait_to_finish: bool) -> bool {
	original_type := t
	_ = original_type // C++ line 2957: gb_unused

	// C++ line 2959: Get base type
	bt := base_type(t)

	// C++ lines 2960-2962: Early exit if not SOA struct
	if t == nil || !is_type_soa_struct(t) {
		return true
	}

	// C++ line 2964: Mutex guard for thread safety
	// MUTEX_GUARD(&t->Struct.soa_mutex);
	ts := &bt.variant.(Type_Struct)
	if ts.soa_mutex != nil {
		sync.mutex_lock(ts.soa_mutex)
		defer sync.mutex_unlock(ts.soa_mutex)
	}

	// C++ lines 2966-2968: Check if already completed using wait signal
	// if (t->Struct.fields_wait_signal.futex.load()) { return true; }
	// Wait signals are implemented using sync.Wait_Group in Odin
	// A completed wait group has value 0, an uncompleted one is > 0
	// The C++ checks if futex.load() != 0, we check the opposite for Wait_Group semantics
	// NOTE: Wait_Group doesn't expose load directly, so we skip this optimization
	// The fields will be checked/populated regardless

	// C++ lines 2970-2976: Determine extra field count based on SOA kind
	// SOA kind values: None=0, Fixed=1, Slice=2, Dynamic=3
	field_count: int = 0
	extra_field_count: i32 = 0
	#partial switch ts.soa_kind {
	case .Fixed:
		extra_field_count = 0 // Fixed: No len/cap/allocator
	case .Slice:
		extra_field_count = 1 // Slice: __$len only
	case .Dynamic:
		extra_field_count = 3 // Dynamic: __$len, __$cap, allocator
	}

	// C++ Reference: check_type.cpp:3319-3326. A polymorphic #soa element (`#soa[]$E`) has no
	// concrete struct to spread into fields yet, so C++ sets field_count = 0, zeroes soa_count and
	// marks the struct complete without building anything - the real fields appear at instantiation.
	// Without this the Generic element reaches the assert below and aborts the whole run.
	if ts.is_polymorphic {
		ts.soa_count = 0
		return true
	}

	// C++ lines 2978-2982: Get source struct information
	scope := ts.scope
	soa_count := ts.soa_count
	elem := ts.soa_elem
	old_struct := base_type(elem)

	// C++ line 2982: Verify element is a struct
	assert(old_struct.kind == .Struct, "SOA element must be struct type")

	// C++ lines 2984-2988: Wait for source struct fields to be ready
	old_ts := &old_struct.variant.(Type_Struct)
	if wait_to_finish {
		// Wait for struct fields to be resolved
		sync.wait_group_wait(&old_ts.fields_wait_signal)
	}
	// Note: If not wait_to_finish, we assume fields are already resolved (callee responsibility)

	// C++ line 2990: Get field count
	field_count = len(old_ts.fields)

	// C++ lines 2992-2993: Allocate field arrays
	ts.fields = make([dynamic]^Entity, field_count + int(extra_field_count))
	ts.tags = make([dynamic]string, field_count + int(extra_field_count))

	// C++ lines 2996-3004: Helper to add entity to scope
	add_entity_to_scope :: proc(scope: ^Scope, entity: ^Entity) {
		name := entity.token.text
		if !is_blank_ident(name) {
			existing := scope_insert(scope, entity)
			if existing != nil {
				redeclaration_error(name, entity, existing)
			}
		}
	}

	// C++ lines 3007-3029: Transform fields from source struct
	for i in 0 ..< field_count {
		old_field := old_ts.fields[i]

		// C++ line 3009: Only process variable entities (actual fields)
		if old_field.kind == .Variable {
			// C++ lines 3010-3016: Determine field type based on SOA kind
			field_type: ^Type = nil
			if ts.soa_kind == .Fixed { 	// Fixed
				// Fixed: [N]T
				assert(soa_count >= 0)
				field_type = alloc_type_array(old_field.type, soa_count)
			} else {
				// Slice/Dynamic: [^]T (multi-pointer)
				field_type = alloc_type_multi_pointer(old_field.type)
			}

			// C++ line 3017: Create new field entity
			old_var := &old_field.variant.(Entity_Variable)
			new_field := alloc_entity_field(scope, old_field.token, field_type, false, old_var.field_index)

			// C++ lines 3018-3023: Set flags
			ts.fields[i] = new_field
			add_entity_to_scope(scope, new_field)
			new_field.flags += {.Used}

			if ts.soa_kind != .Fixed { 	// Not Fixed
				new_field.flags += {.Soa_Ptr_Field}
			}
		} else {
			// C++ line 3025: Non-variable entities pass through unchanged
			ts.fields[i] = old_field
		}

		// C++ line 3028: Copy tag
		ts.tags[i] = old_ts.tags[i]
	}

	// C++ lines 3031-3049: Add extra fields for Slice/Dynamic
	if ts.soa_kind != .Fixed { 	// Not Fixed
		// C++ lines 3032-3035: Add __$len field
		len_token := make_token_ident("__$len")
		len_field := alloc_entity_field(scope, len_token, t_int, false, i32(field_count) + 0)
		ts.fields[field_count + 0] = len_field
		add_entity_to_scope(scope, len_field)
		len_field.flags += {.Used}

		// C++ lines 3037-3048: Add __$cap and allocator for Dynamic
		if ts.soa_kind == .Dynamic { 	// Dynamic
			// __$cap field
			cap_token := make_token_ident("__$cap")
			cap_field := alloc_entity_field(scope, cap_token, t_int, false, i32(field_count) + 1)
			ts.fields[field_count + 1] = cap_field
			add_entity_to_scope(scope, cap_field)
			cap_field.flags += {.Used}

			// allocator field (requires mem.Allocator type)
			// C++ line 3043: init_mem_allocator(checker)
			init_mem_allocator(checker)
			allocator_token := make_token_ident("allocator")
			allocator_field := alloc_entity_field(scope, allocator_token, t_allocator, false, i32(field_count) + 2)
			ts.fields[field_count + 2] = allocator_field
			add_entity_to_scope(scope, allocator_field)
			allocator_field.flags += {.Used}
		}
	}

	// C++ line 3051: Add type info (commented out in C++)
	// add_type_info_type(ctx, original_type)

	// C++ line 3053: Signal completion
	// Note: For SOA types created via complete_soa_type, the fields_wait_signal
	// was already initialized in alloc_type_struct, so we signal done here
	sync.wait_group_done(&ts.fields_wait_signal)

	return true
}

// check_array_count checks and returns the array count from an expression
// Returns 0 on error
// check_array_count evaluates an array-length expression.
// C++ Reference: check_type.cpp:2776-2872.
//
// The sentinel return values are load-bearing and callers depend on them:
//   -1  the length is to be determined later — either `[?]T` (only legal attached to a
//       compound literal, diagnosed by the caller at check_type.odin:565) or an enum
//       used as an enumerated-array index.
//    0  invalid, already diagnosed.
//
// This was previously a simplified stub that called check_expr, accepted only
// .Constant/.Type, and returned exact_value_to_i64. It never produced -1, so `[?]T`
// silently became [0]T and the "? can only be used in conjunction with compound
// literals" diagnostic below could never fire.
check_array_count :: proc(ctx: ^Checker_Context, operand: ^Operand, expr: ^ast.Expr) -> i64 {
	// C++ line 2777-2779
	if expr == nil {
		return 0
	}

	// C++ line 2780-2790: `?` is recognised syntactically, before any checking.
	if unary, is_unary := expr.derived.(^ast.Unary_Expr); is_unary {
		if unary.op.kind == .Question {
			return -1
		}
		if unary.expr == nil {
			error(expr, "Invalid array count '[%s]'", unary.op.text)
			return 0
		}
	}

	// C++ line 2792: check_expr_or_type, not check_expr — an enum type is a legal
	// array count (enumerated arrays) and must not be rejected as a non-value.
	check_expr_or_type(ctx, operand, expr)

	if operand.mode == .Type {
		ot := base_type(operand.type)

		// C++ line 2796-2804
		if ot != nil && ot.kind == .Generic {
			if ctx.allow_polymorphic_types {
				if gen, gen_ok := &ot.variant.(Type_Generic); gen_ok && gen.specialized != nil {
					gen.specialized = nil
					error(operand.expr, "Polymorphic array length cannot have a specialization")
				}
				return 0
			}
		}
		// C++ line 2805-2807: an enum index yields a to-be-determined count.
		if is_type_enum(ot) {
			return -1
		}
	}

	if operand.mode != .Constant {
		// C++ line 2809-2840
		if operand.mode != .Invalid {
			entity := entity_of_node(ctx.info, operand.expr)
			is_poly_type := false
			is_poly_const_value := false
			if entity != nil {
				is_poly_type =
					entity.kind == .Type_Name &&
					entity.type == t_typeid &&
					.Poly_Const in entity.flags
				// COMPENSATION, not C++ parity. In C++ a polymorphic value parameter
				// (`$N: int`) is a CONSTANT operand inside its own signature, so
				// `[N]int` and `#simd[W]u64` never reach this branch at all. In this
				// port such an entity is not bound as a constant in the signature /
				// type-expression path — task 57 fixed that for procedure BODIES only —
				// so it lands here and would be reported as a non-constant count.
				//
				// Verified against the real compiler: `f :: proc($W: uint) -> #simd[W]u64`
				// and `g :: proc($N: int) -> [N]int` both check with zero errors, and
				// core/hash/xxhash depends on exactly this.
				//
				// Remove this arm once polymorphic constants are bound as constants in
				// signatures; the C++ is_poly_type escape above is then sufficient.
				is_poly_const_value = entity.kind == .Constant && .Poly_Const in entity.flags
			}

			// C++ line 2821-2824
			if ctx.allow_polymorphic_types && (is_poly_type || is_poly_const_value) {
				return 0
			}

			begin_error_block()
			s := expr_to_string(operand.expr)
			defer delete(s)
			error(expr, "Array count must be a constant integer, got %s", s)

			if is_poly_type {
				error_line("\tSuggestion: 'where' clause may be required to restrict the enumerated array index type to an enum\n")
				error_line("\t            'where intrinsics.type_is_enum(%s)'\n", entity.token.text)
			}
			end_error_block()

			operand.mode = .Invalid
			operand.type = t_invalid
		}
		return 0
	}

	// C++ line 2842-2869
	type := core_type(operand.type)

	// COMPENSATION, not C++ parity. A polymorphic value parameter (`$N: int`) is
	// .Constant here but carries NO value yet, so none of the arms below match and it
	// would fall through to the final "must be a constant integer" error. In C++ such a
	// count is resolved by the time it reaches this point, so the case cannot arise.
	//
	// The previous stub returned exact_value_to_i64(...) == 0 for this, which silently
	// produced [0]T — wrong, but quiet. Returning the to-be-determined sentinel keeps it
	// quiet without inventing a zero length.
	//
	// Verified against the real compiler: `proc($W: uint) -> #simd[W]u64` and
	// `proc($N: int) -> [N]int` both check with zero errors; core/hash/xxhash relies on it.
	// Remove once polymorphic constants carry values in the signature path.
	if operand.value == nil && ctx.allow_polymorphic_types {
		return 0
	}

	if is_type_untyped(type) || is_type_integer(type) {
		#partial switch v in operand.value {
		case big.Int:
			count := v
			if is_neg, _ := big.int_is_negative(&count); is_neg {
				str, err := big.int_to_string(&count)
				if err == nil {
					defer delete(str)
					error(expr, "Invalid negative array count, %s", str)
				} else {
					error(expr, "Invalid negative array count")
				}
				return 0
			}
			result, get_err := big.int_get_i64(&count)
			if get_err != nil {
				str, err := big.int_to_string(&count)
				if err == nil {
					defer delete(str)
					error(expr, "Array count too large, %s", str)
				} else {
					error(expr, "Array count too large")
				}
				return 0
			}
			return result
		case f64:
			// C++ line 2862-2868: accept a float only if it round-trips exactly.
			u := u64(v)
			if f64(u) == v {
				return i64(u)
			}
		}
	}

	error(expr, "Array count must be a constant integer")
	return 0
}

// is_type_valid_bit_set_range checks if a type is valid for bit_set range
// Valid types: integer and rune types
is_type_valid_bit_set_range :: proc(t: ^Type) -> bool {
	return is_type_integer(t) || is_type_rune(t)
}
