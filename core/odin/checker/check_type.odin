package checker

/*
Type expression checking.

This module implements type validation and construction from AST type expressions,
following the logic in check_type.cpp from the Odin compiler.

C++ Reference: check_type.cpp (3856 lines)
*/

import "core:container/queue"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:sync"

// Matrix dimension bounds. C++ Reference: check_type.cpp -- these are GLOBALS there, and as of
// merge ebac23eb0 check_expr.cpp's check_binary_matrix reads MATRIX_ELEMENT_COUNT_MAX as well.
// They were previously declared local to check_matrix_type_expr, which no other file could see.
// C++ check_type.cpp check_matrix_type checks only a MINIMUM per dimension and then
// bounds row_count*column_count by MAX. LEDGER #798.
MATRIX_ELEMENT_COUNT_MIN :: 1
MATRIX_ELEMENT_COUNT_MAX :: 64
// C++ Reference: types.cpp -- `MATRIX_ELEMENT_MAX_SIZE = MATRIX_ELEMENT_COUNT_MAX * (2 * 8)`, the
// comment on that line being `// complex128`. #934 needs it: `transpose` on a rank-2 array bounds
// the SIZE of the transposed type as well as its element count.
MATRIX_ELEMENT_MAX_SIZE :: MATRIX_ELEMENT_COUNT_MAX * (2 * 8)

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
			// C++ Reference: check_type.cpp check_type_internal (the Addressing_Type arm)
			if !ctx.in_polymorphic_specialization {
				t := base_type(o.type)
				if t != nil && is_type_polymorphic_record_unspecialized(t) {
					// C++ check_type_internal
					err_str := expr_to_string(e)
					defer delete(err_str)
					error_node(e, "Invalid use of a non-specialized polymorphic type '%s'", err_str)
					return true
				}
			}
			return true

		case .No_Value:
			// C++ Reference: check_type.cpp check_type_internal
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type", err_str)

		case:
			// C++ Reference: check_type.cpp check_type_internal.
			// The text differs from the Selector_Expr arm below and that is NOT an accident on C++'s
			// part: the Ident default says "used as a type when not a type", the Selector default says
			// "is not a type". Two switches with the same SHAPE and different TEXT. The port had the
			// selector's wording here, and the identical (wrong) citation on both hid it.
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type when not a type", err_str)
		}

	case ^ast.Helper_Type:
		// Helper type (e.g., #type)
		return check_type_internal(ctx, n.type, type, named_type)

	case ^ast.Distinct_Type:
		// C++ Reference: check_type.cpp check_type_internal
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

	// C++ Reference: check_type.cpp check_type_internal. Both ternary forms may appear in TYPE
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
			// C++ Reference: check_type.cpp check_type_internal (Selector_Expr, NOT the Ident
			// switch above -- the two are separate and their default arms use DIFFERENT text)
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' used as a type", err_str)

		case:
			// C++ Reference: check_type.cpp check_type_internal
			err_str := expr_to_string(o.expr)
			defer delete(err_str)
			error_node(o.expr, "'%s' is not a type", err_str)
		}

	case ^ast.Paren_Expr:
		// Parenthesized type
		if n.expr == nil {
			// C++ Reference: check_type.cpp check_type_internal
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

	case:
		// C++ Reference: check_type.cpp check_type_internal -- the DEFAULT arm:
		//     default: {
		//         Operand o = {};
		//         check_expr_base(ctx, &o, e, nullptr);
		//         if (o.mode == Addressing_Constant && o.value.kind == ExactValue_Typeid) {
		//             Type *t = o.value.value_typeid;
		//             if (t != nullptr && t != t_invalid) { *type = t; return true; }
		//         }
		//     }
		//
		// Any node kind with no type arm above is still run through the EXPRESSION checker. That
		// does two things, and the port had NEITHER:
		//
		// 1. It surfaces the real diagnostic from INSIDE the expression. C++ has no IndexExpr arm
		//    here, so `a: int[3]` lands in this default; check_expr_base -> check_index ->
		//    check_expr on `int` -> mode Type -> error_operand_not_expression emits
		//        'int' is not an expression but a type
		//    at the INNER node. check_type_expr then adds its own "'int[3]' is not a type", but
		//    BOTH sit at the same position (the index expression starts at `int`), so the
		//    same-position merge (#219) keeps the first. The port produced only the outer message
		//    and therefore showed the wrong one of the two (#279).
		//
		// 2. It ACCEPTS a constant typeid used as a type. Omitting this half would be an
		//    under-acceptance, so it is ported even though the repro above only exercises (1).
		o: Operand
		check_expr_base(ctx, &o, e, nil)
		if o.mode == .Constant {
			if tv, is_typeid := o.value.(Exact_Value_Typeid); is_typeid {
				if tv.type != nil && tv.type != t_invalid {
					type^ = tv.type
					return true
				}
			}
		}
	}

	// C++ Reference: check_type.cpp:3569+ ends `*type = t_invalid; return false;` SILENTLY.
	// The port used to emit an invented "Invalid type expression: %s" here. C++ has no such
	// checker diagnostic -- the message belongs to the CALLER (check_type_expr), and for an
	// undeclared name the real diagnostic ("Undeclared name: X") has already been reported by
	// check_ident. Emitting here displaced it: both land on the same position and the merge
	// pass keeps one, so the invented text won and "Undeclared name" was never seen.
	type^ = t_invalid
	return false
}

// check_type_expr checks a type expression and returns the type
check_type_expr :: proc(ctx: ^Checker_Context, e: ^ast.Node, named_type: ^Type) -> ^Type {
	type: ^Type = t_invalid
	ok := check_type_internal(ctx, e, &type, named_type)
	if !ok {
		// C++ Reference: check_type.cpp check_type_expr. The caller owns this diagnostic, and it is an
		// ERROR BLOCK: the headline is followed by a "Suggestion:" continuation for the two
		// mistakes C programmers make -- `T[N]` for `[N]T` and `*T` for `^T`. The port emitted the
		// headline alone. C++ also RECOVERS from both by rebuilding the node the user meant and
		// checking that, which keeps the cascade short.
		begin_error_block()
		block_open := true
		defer if block_open { end_error_block() }

		err_str := expr_to_string(e)
		defer delete(err_str)
		error_node(e, "'%s' is not a type", err_str)
		type = t_invalid

		// C++ calls unparen_expr(e); `e` is a ^Node here, so unwrap the parentheses directly.
		node := e
		for {
			pe, is_paren := node.derived.(^ast.Paren_Expr)
			if !is_paren || pe.expr == nil {
				break
			}
			node = pe.expr
		}
		#partial switch n in node.derived {
		case ^ast.Index_Expr:
			index_str := n.index != nil ? expr_to_string(n.index) : ""
			defer delete(index_str)
			type_str := expr_to_string(n.expr)
			defer delete(type_str)
			error_line("\tSuggestion: Did you mean '[%s]%s'?\n", index_str, type_str)
			end_error_block()
			block_open = false

			// C++ Reference: check_type.cpp check_type_expr -- "Minimize error propagation of bad array
			// syntax by treating this like a type".
			if n.expr != nil {
				pseudo := ast.new(ast.Array_Type, n.pos, n.expr)
				pseudo.open = n.open
				pseudo.len = n.index
				pseudo.close = n.close
				pseudo.elem = n.expr
				check_array_type_internal(ctx, pseudo, &type, nil)
			}

		case ^ast.Unary_Expr:
			if n.op.kind != .Mul {
				end_error_block()
				block_open = false
				break
			}
			type_str := expr_to_string(n.expr)
			defer delete(type_str)
			error_line("\tSuggestion: Did you mean '^%s'?\n", type_str)
			end_error_block()
			block_open = false

			if n.expr != nil {
				pseudo := ast.new(ast.Pointer_Type, n.pos, n.expr)
				pseudo.pointer = n.op.pos
				pseudo.elem = n.expr
				return check_type_expr(ctx, pseudo, named_type)
			}

		case:
			end_error_block()
			block_open = false
		}
	}

	if type == nil {
		type = t_invalid
	}

	// C++ Reference: check_type.cpp check_type_expr. A Named type that reached here with no base is
	// repaired rather than diagnosed (C++'s own `error("Invalid type definition of '%s'")` here is
	// #if 0'd out, with an "IMPORTANT TODO(bill): Is this a serious error?!"). A type ALIAS keeps
	// its null base deliberately -- laytan's note: the declaration is a mini "cycle" filled in
	// later -- so only non-aliases are forced to t_invalid.
	if named, is_named := &type.variant.(Type_Named); is_named && named.base == nil {
		is_alias := false
		if named.type_name != nil {
			if tn, ok2 := named.type_name.variant.(Entity_Type_Name); ok2 {
				is_alias = tn.is_type_alias
			}
		}
		if !is_alias {
			named.base = t_invalid
		}
	}

	// C++ Reference: check_type.cpp check_type_expr sets TypeFlag_Polymorphic / TypeFlag_PolySpecialized
	// here. NOT PORTED, deliberately: those two flags are written at this one site and read
	// NOWHERE in the entire C++ compiler (`grep -rn TypeFlag_ src/` finds the enum and these two
	// writes, nothing else). Only TypeFlag_InProcessOfCheckingPolymorphic is live, and the port
	// already has it as .In_Process_Of_Checking_Polymorphic. Adding write-only state would be the
	// duplicated-state defect this port keeps having to remove.

	// C++ Reference: check_type.cpp check_type_expr. The gate that decides whether the expression is
	// recorded as a type at all. Note C++'s precedence: (Named && base == nullptr) || is_type_typed.
	named_without_base := false
	if named, is_named := &type.variant.(Type_Named); is_named && named.base == nil {
		named_without_base = true
	}
	if named_without_base || is_type_typed(type) {
		add_type_and_value(ctx, e, .Type, type, Exact_Value{})
	} else {
		// NOTE: type_to_string results are NOT freed in this port (expr_to_string results are).
		// LEDGER #142 records a crash from exactly this mistake.
		name := type_to_string(type)
		error_node(e, "Invalid type definition of %s", name)
		type = t_invalid
	}

	// C++ Reference: check_type.cpp check_type_expr. The port's check_type_internal arms each call
	// set_base_type before returning, so this is a no-op on the success path -- but it is NOT a
	// no-op on the error path above, where C++ overwrites the arm's write with t_invalid.
	set_base_type(named_type, type)

	// C++ Reference: check_type.cpp:4145 check_type_expr. One of C++'s THREE call sites, and ALL
	// THREE are now ported: check_decl.odin:415 (C++ check_decl.cpp:1833), this one, and
	// check_expr.odin:9332 (C++ check_expr.cpp:12838).
	// This comment previously said the third was "still missing"; it was added by a later tick and
	// the note was never updated -- and its cited line 12686 had drifted too (it is now an
	// IndexExpr dispatch). VERIFIED by witness, not by reading: $S/phase2/wit_nortti/{nr_var,
	// nr_expr,nr_type} under `-no-rtti -target:freestanding_wasm32` each produce THREE matching
	// diagnostics. Those cells could not have been run before tick 191, because the harness
	// ignored -no-rtti and portwrap silently dropped it.
	check_rtti_type_disallowed(ctx, ast_token(e), type, "Use of a type, %s, which has been disallowed")

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
		// C++ Reference: check_type.cpp make_soa_struct_internal. C++'s wording, and C++ returns a plain ARRAY of
		// the element rather than t_invalid so the declaration still yields a usable type.
		str := type_to_string(elem)
		error(elem_expr, "Invalid type for an #soa array, expected a struct or array of length 4 or below, got '%s'", str)
		return make_array_type(elem, count, generic_type)
	}

	// #936: TWO INVENTED GUARDS WERE DELETED HERE. Both cited C++ line numbers ("C++ lines
	// 3080-3084" and "3092-3097") and neither rule exists.
	//
	// C++'s make_soa_struct_internal (check_type.cpp:3292-3459) contains exactly TWO error() calls
	// in its whole body: the "Invalid type for an #soa array" one immediately above, and "Array
	// count too large for an #soa struct". Neither invented message -- "Cannot create SOA of SOA
	// types", "Cannot create SOA of unspecialized polymorphic struct type" -- appears anywhere in
	// src/*.cpp, nor in spec/all_errors.txt, which is the reference's own message inventory.
	//
	//   NESTED SOA: MEASURED. `a: #soa[]#soa[]P` is ACCEPTED by the oracle and was rejected here.
	//   **24 cells** in `soaops`, all `accept -> reject`, spread over addr/addrfield/index/slice --
	//   they were all the same defect, because rejecting the TYPE poisons every operation on it
	//   ("Cannot address value 'a[0]' as it has not got a determined type yet" was the follow-on).
	//
	//   UNSPECIALIZED POLYMORPHIC: no C++ counterpart either, and it is not what produces the
	//   diagnostic on `#soa[]Q` for a polymorphic `Q`. Both compilers say "Invalid use of a
	//   non-specialized polymorphic type 'Q'" there, from a DIFFERENT site that is already correct,
	//   which is why deleting this one leaves that case matching. Rule 65 -- ported is not reached.
	//
	// C++ line 3100: Allocate new struct type
	t := alloc_type_struct(ctx.checker)
	ts := &t.variant.(Type_Struct)

	// C++ lines 3102-3106: Set SOA metadata
	ts.soa_kind = soa_kind
	ts.soa_elem = elem

	// #1072. C++ Reference: check_type.cpp make_soa_struct_internal, between the node assignment
	// and soa_count:
	//
	//     if (count > I32_MAX) {
	//         count = I32_MAX;
	//         error(array_typ_expr, "Array count too large for an #soa struct, got %lld", count);
	//     }
	//     soa_struct->Struct.soa_count = cast(i32)count;
	//
	// This is the SECOND of the two error() calls the comment below correctly enumerates -- and
	// only the first was ever implemented. check_array_count rejects only counts needing more
	// than one BigInt limb, so anything up to U64_MAX reaches here and the port accepted it
	// silently. C++ additionally CLAMPS, and soa_count participates in are_types_identical and
	// in name canonicalisation, so without the clamp the two compilers can also disagree on
	// whether two #soa types are the same type.
	// NOTE THE ORDER: C++ assigns the clamp to `count` BEFORE formatting, so the message reports
	// I32_MAX rather than the count actually written. "got 2147483647" for a source that says
	// 3_000_000_000 reads like a bug in the reference, and arguably is one -- but it is the
	// contract, and MEASURED: oracle "got 2147483647", port (clamping into a temporary and
	// printing the original) "got 3000000000". Verdict alone would never have caught this.
	soa_count := count
	if soa_count > i64(max(i32)) {
		soa_count = i64(max(i32))
		error_node(array_type_expr, "Array count too large for an #soa struct, got %d", soa_count)
	}
	ts.soa_count = soa_count
	// C++ Reference: check_type.cpp make_soa_struct_internal - `soa_struct->Struct.is_polymorphic = is_polymorphic;`
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

	// C++ Reference: check_type.cpp make_soa_struct_internal. C++ builds the #soa fields EAGERLY whenever the
	// element type's fields are already resolved (`old_struct->Struct.fields_wait_signal.futex.load()`,
	// check_type.cpp make_soa_struct_internal) and enqueues ONLY when they are not (the `is_complete` else-branch at
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
	// #754 CLOSED THE ARRAY GAP. This used to read "Array elements stay on the queue: C++ spreads
	// them into x/y/z/w fields inline here, which the port's complete_soa_type has no arm for (it
	// asserts the element is a struct). That gap is pre-existing and out of scope for this change."
	// complete_soa_type now HAS that arm, so array elements are handled -- and they must be marked
	// ready HERE too, not merely tolerated there. An ARRAY element has no source struct whose
	// fields could still be resolving, so it is ready the moment it exists.
	//
	// This half is load-bearing on its own: routing an array element down the ENQUEUE branch would
	// complete it correctly but SKIP `add_type_info_type`, because C++ registers only on the
	// is_complete branch, and its array path always takes that branch. That is exactly the
	// missed-RTTI defect #690 recorded as a curiosity and #692's gate caught -- reintroducing it
	// for array elements only would have been invisible to every diagnostic-text gate.
	// #1072. C++ Reference: check_type.cpp make_soa_struct_internal, after the field construction
	// and before the is_complete branch:
	//
	//     Token token = {};
	//     token.string = str_lit("Base_Type");
	//     Entity *base_type_entity = alloc_entity_type_name(scope, token, elem, EntityState_Resolved);
	//     add_entity(ctx, scope, nullptr, base_type_entity);
	//
	// UNCONDITIONAL in C++ -- on the complete, incomplete AND polymorphic paths alike. The port
	// created no such entity anywhere, so `Base_Type` was simply not a member of any #soa type
	// and every use of it failed to resolve. This is an OVER-REJECTION: the port refuses what the
	// reference accepts. MEASURED: `A :: #soa[]S; B :: A.Base_Type` -- oracle 0, port 1.
	//
	// Placed here so it precedes the branch, matching C++'s order and covering all three paths.
	if ts.scope != nil {
		base_type_entity := alloc_entity_type_name(ts.scope, make_token_ident("Base_Type"), elem, .Resolved, ctx.checker.allocator)
		scope_insert(ts.scope, base_type_entity)
	}

	elem_fields_ready := false
	if !is_polymorphic {
		if is_type_struct(bt) || is_type_raw_union(bt) {
			old_ts := &bt.variant.(Type_Struct)
			elem_fields_ready = len(old_ts.fields) > 0 && wait_signal_is_set(&old_ts.fields_wait_signal)
		} else if is_type_array(bt) {
			elem_fields_ready = true
		}
	}

	if is_polymorphic {
		// t243p. C++ Reference: check_type.cpp:3337-3344 sets is_complete = true for a
		// polymorphic element, so :3447 runs `add_type_info_type` + `wait_signal_set` for it
		// exactly as for a concrete one. This port routes that completion through
		// complete_soa_type (whose is_polymorphic arm mirrors :3337-3344), which is the same
		// route the elem_fields_ready branch below takes.
		//
		// PREVIOUSLY: "Nothing to build, and nothing to queue." That is why
		// complete_soa_type's `ts.soa_count = 0` was UNREACHABLE CODE -- nothing on the
		// polymorphic path ever called it. A polymorphic fixed-count #soa therefore kept the
		// count written in the source, and the port ACCEPTED
		//     f :: proc(x: #soa[4]$T) -> i32 { return 0 }
		//     main :: proc() { s: #soa[4]P; _ = f(s) }
		// which the reference REJECTS with "Cannot assign value 's' of type '#soa[4]P' to
		// '#soa[0]P'". An OVER-ACCEPTANCE, invisible to a verdict corpus unless the cell is
		// written by hand: witness wit_polysoa243/pfixed.
		//
		// The reference's own '#soa[0]P' is a defect in the reference -- polymorphic
		// fixed-count #soa parameters are unusable there in EVERY spelling -- and is filed
		// upstream. Per Jon's ruling the quirk is still the contract, because it is an error
		// and not a crash, so the port must reject too.
		add_type_info_type(ctx, t)
		complete_soa_type(ctx.checker, t, false)
	} else if elem_fields_ready {
		// C++ Reference: check_type.cpp make_soa_struct_internal.
		//
		//     if (is_complete) { add_type_info_type(ctx, soa_struct); wait_signal_set(&...); }
		//     else             { mpsc_enqueue(...); thread_pool_add_task(complete_soa_type_worker); }
		//
		// `elem_fields_ready` is this port's spelling of C++'s `is_complete`, and C++ orders the
		// registration BEFORE the wait-signal set -- so it belongs immediately before the call that
		// builds the fields and signals.
		//
		// ONLY on this branch. The deferred branch does NOT register on either side: C++'s
		// complete_soa_type and complete_soa_type_worker contain no
		// add_type_info_type at all. Registering there too would be an over-registration, not a
		// symmetry fix.
		//
		// This was the ONLY add_type_info_type call site in C++'s check_type.cpp, and the port had
		// ZERO -- a per-file census disagreement recorded as a curiosity in #690 and left alone
		// because no gate covered it. The gate built in #692 went red on its first full-corpus run
		// and named exactly this: every `#soa` type went unregistered for RTTI, which is why the
		// three `soa_zip`-based procedures in core/reflect (`struct_fields_zipped`,
		// `enum_fields_zipped`, `bit_fields_zipped`) read ref=5 port=4 in all 117 packages
		// that import core:reflect. LEDGER #694.
		add_type_info_type(ctx, t)
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
// C++ Reference: check_type.cpp check_type_internal PolyType arm:3635-3679
check_poly_type :: proc(ctx: ^Checker_Context, pt: ^ast.Poly_Type, type: ^^Type, named_type: ^Type) -> bool {
	// Get the identifier after the $
	// C++ check_type.cpp check_type_internal
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
	// C++ check_type.cpp check_type_internal
	if pt.specialization != nil {
		// Create a temporary context with in_polymorphic_specialization flag
		c := ctx^
		c.in_polymorphic_specialization = true
		specific = check_type(&c, pt.specialization)
	}

	// Create the generic type
	// C++ check_type.cpp check_type_internal
	t := make_type_generic(ctx.scope, name, specific)

	// Validate and register the polymorphic type parameter
	// C++ check_type.cpp check_type_internal
	if ctx.allow_polymorphic_types {
		// Check for disallowed polymorphic return types
		// C++ check_type.cpp check_type_internal
		if ctx.disallow_polymorphic_return_types {
			error_node(ident_node, "Undeclared polymorphic parameter '%s' in return type", name)
		}

		// Determine which scope to add the entity to
		// C++ check_type.cpp check_type_internal
		ps := ctx.polymorphic_scope
		s := ctx.scope
		entity_scope := s
		if ps != nil && ps != s {
			// The polymorphic scope is an ancestor - add entity there
			entity_scope = ps
		}

		// Create type name entity for the polymorphic parameter
		// C++ check_type.cpp check_type_internal
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
		// C++ check_type.cpp check_type_internal
		error_node(ident_node, "Invalid use of a polymorphic parameter '$%s'", name)
		type^ = t_invalid
		return false
	}

	type^ = t
	set_base_type(named_type, type^)
	return true
}

// C++ Reference: check_type.cpp:3726-3772.
//
// The port had a five-line reduction here -- `elem := check_type(ctx, pt.elem)` and nothing else.
// That routed the element through check_type_internal's Ident arm, whose non-specialized
// polymorphic check (:43-53) is UNGATED, so `^Objc_Block` was rejected outright. C++ never reaches
// that arm on this path: it resolves the element with check_expr_or_type and then applies its OWN
// non-specialized check, gated on disallow_polymorphic_return_types -- false in a parameter
// position, which is why the reference accepts
//     f :: proc "c" (block: ^Objc_Block) -> int
// (core/sys/darwin/Foundation/NSNotification.odin:60, the last corpus-wide divergence, #294).
//
// The reduction also dropped three diagnostics and the fresh type_path. Restored in full.
check_pointer_type :: proc(ctx: ^Checker_Context, pt: ^ast.Pointer_Type, type: ^^Type, named_type: ^Type) -> bool {
	// C++ line 3726-3730: a COPY of the context with a fresh type path. The element of a pointer
	// may legally close a cycle (`T :: struct { next: ^T }`), so it must not inherit the enclosing
	// path or check_type_path_push would report a false cycle.
	c := ctx^
	c.type_path = new_checker_type_path()
	defer destroy_checker_type_path(c.type_path)

	elem: ^Type = t_invalid
	o: Operand

	// C++ lines 3735-3738.
	if unparen_expr(pt.elem) == nil {
		error_node(pt, "Invalid pointer type")
		return false
	}

	check_expr_or_type(&c, &o, pt.elem)
	if o.mode != .Invalid && o.mode != .Type {
		// C++ lines 3741-3752: three shapes, two of them suggestions.
		if o.mode == .Variable {
			s := expr_to_string(pt.elem)
			defer delete(s)
			error_node(pt, "^ is used for pointer types, did you mean '&%s'?", s)
		} else if is_type_pointer(o.type) {
			s := expr_to_string(pt.elem)
			defer delete(s)
			error_node(pt, "^ is used for pointer types, did you mean a dereference: '%s^'?", s)
		} else {
			// C++ line 3751: "call check_type_expr again to get a consistent error message"
			elem = check_type_expr(&c, pt.elem, nil)
		}
	} else {
		elem = o.type
	}

	// C++ lines 3758-3767. Note this reads the ORIGINAL ctx, not the copy, for both flags, and
	// requires the element to be written as a bare identifier.
	if !ctx.in_polymorphic_specialization && ctx.disallow_polymorphic_return_types {
		t := base_type(elem)
		if t != nil {
			_, is_ident := unparen_expr(pt.elem).derived.(^ast.Ident)
			if is_ident && is_type_polymorphic_record_unspecialized(t) {
				err_str := expr_to_string(pt)
				defer delete(err_str)
				error_node(pt, "Invalid use of a non-specialized polymorphic type '%s'", err_str)
			}
		}
	}

	// C++ Reference: check_type.cpp:3774-3791 -- the pointer TAG.
	//
	// The port ignored pt.tag entirely and always allocated a plain pointer, so `#soa ^T` silently
	// became `^T`. That is visible in any diagnostic naming the type:
	//     oracle   Cannot convert ... to '#soa ^#soa[]S'
	//     port     Cannot convert ... to '^#soa[]S'
	// and it made size_of report one word where the language lays a #soa pointer out as two
	// (LEDGER #516 fixed the size arm; this is what kept that arm unreachable from the type
	// syntax).
	//
	// The tag was NOT lost by the parser -- parser.odin:3707 records it, mirroring C++
	// parser.cpp:2466. Both implementations carry a `tag` on the pointer node; only the port's
	// CHECKER never read it. Worth stating because a missing tag could equally have been a parser
	// defect, and the fix would have been in a different file.
	//
	// Three branches, all of them C++'s. The final `else` is an UNDER-REJECTION the port had: any
	// tag at all was accepted silently, so `#foo ^int` checked clean.
	if pt.tag != nil {
		// C++ asserts the tag is a BasicDirective. The parser only ever stores one here, but this
		// is a checker reading a parser-produced node, so it degrades to the plain-pointer path
		// rather than asserting -- an assert would turn a parser bug into a checker crash.
		if tag_directive, tag_ok := pt.tag.derived.(^ast.Basic_Directive); tag_ok {
			name := tag_directive.name
			if name == "soa" {
				// TODO(bill): generic #soa pointers  -- C++'s own note, kept.
				if is_type_soa_struct(elem) {
					type^ = alloc_type_soa_pointer(elem)
				} else {
					error_node(pt.tag, "#soa pointers require an #soa record type as the element")
					type^ = make_pointer_type(elem)
				}
			} else {
				error_node(pt.tag, "Invalid tag applied to pointer, got #%s", name)
				type^ = make_pointer_type(elem)
			}
		} else {
			type^ = make_pointer_type(elem)
		}
	} else {
		type^ = make_pointer_type(elem)
	}
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

			// C++ Reference: check_type.cpp check_array_type_internal (merge ebac23eb0),
			// verbatim rationale:
			//   "the length is `max - min + 1`, computed exactly and then narrowed to an i64. a
			//    wide enough enumeration wraps & nothing tests downstream; reject here"
			// C++ tests `len.value_integer.used > 1` -- a LIMB count. That is NOT portable: this
			// port's core:math/big uses 60-bit digits where the reference BigInt does not, so a
			// literal `used > 1` would reject values in [2^60, 2^64) that C++ accepts. The port
			// already settled this exact question for `#align` at check_type.odin:1474-1489, which
			// documents `used > 1` as meaning "too large to fit in i64" and tests it with
			// int_get_i128 against the i64 bounds. Same idiom reused here. LEDGER #798.
			if len(enum_info.fields) > 0 {
				span := exact_value_sub(enum_info.max_value, enum_info.min_value)
				length := exact_value_add(span, exact_value_i64(1))
				if bi, is_big := length.(big.Int); is_big {
					temp_bi := bi
					v128, get_err := big.int_get_i128(&temp_bi)
					if get_err != nil || v128 > i128(max(i64)) || v128 < i128(min(i64)) {
						str, _ := big.int_itoa_string(&temp_bi, 10, false, context.temp_allocator)
						error_node(e, "Enumerated array length too large, %s", str)
						type^ = t_invalid
						return
					}
				}
			}

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
				error_line("\tenumerated array length: %d\n", ea.count)
				error_line("\tenum field count: %d\n", len(enum_info.fields))
				error_line("\tSuggestion: prepend #sparse to the enumerated array to allow for non-contiguous elements\n")

				// C++ lines 3286-3289: Warning if too sparse
				if 2 * len(enum_info.fields) < int(ea.count) {
					error_line("\tWarning: the number of named elements is much smaller than the length of the array, are you sure this is what you want?\n")
					error_line("\t         this warning will be removed if #sparse is applied\n")
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
		// C++ Reference: check_type.cpp:3541-3546, whose comment gives the reason:
		//     // Track user input and recovery value seperate, since both could be '0'
		count_recovered := false
		if count < 0 {
			error(at.len, "? can only be used in conjunction with compound literals")
			count = 0
			count_recovered = true
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
					error(at.elem, // C++ Reference: check_type.cpp check_array_type_internal -- the port dropped "with no specific endianness".
					"Invalid element type for #simd, expected an integer, float, boolean, or 'rawptr' with no specific endianness, got '%s'", elem_str)
					type^ = make_array_type(elem, count, generic_type)
					return
				}

				if generic_type != nil {
					// Generic count - allow for polymorphic specialization
				} else if count < 1 || !is_power_of_two(count) {
					type^ = make_array_type(elem, count, generic_type)
					// *** KNOWN OPEN DIVERGENCE (sweep suite simdlane__simdret, cell sr.0), AND
					// *** THE FIX DOES NOT BELONG HERE. C++ Reference: check_type.cpp:3566-3577:
					//         if (count_recovered) { return; }
					//         // a polymorphic value used as the count is still unresolved while
					//         // the signature is checked and reads as 0; only a written count is
					//         // constant
					//         if (ctx->disallow_polymorphic_return_types && o.mode != Addressing_Constant) { return; }
					//     error(at->count, "Invalid length for #simd, ...");
					// So the reference separates a WRITTEN `#simd[0]` (constant -> report) from an
					// UNRESOLVED polymorphic count (non-constant -> stay silent).
					// MEASURED with a temporary probe: in THIS port the two states are IDENTICAL --
					//     h :: proc() -> #simd[0]int   (oracle REJECTS)
					//     g :: proc($N: int) -> #simd[N]f32 (oracle ACCEPTS)
					//   both give count=0 recovered=false o.mode=Constant generic_type=nil
					//   disallow=true.
					// So NO guard at this point can distinguish them: the port's check_array_count
					// resolves a polymorphic count to a CONSTANT 0 where the reference leaves the
					// operand non-constant. Porting the reference's test verbatim made `g` fail --
					// trading a missing diagnostic for a FALSE one -- so it was reverted and the
					// root cause recorded instead. The real fix is to make check_array_count's
					// operand mode faithful, which is a separate change with its own blast radius.
					if count_recovered {
						return
					}
					// C++ Reference: check_type.cpp:3573-3575 --
					//     // a polymorphic value used as the count is still unresolved while the
					//     // signature is checked and reads as 0; only a written count is constant
					//     if (ctx->disallow_polymorphic_return_types && o.mode != Addressing_Constant) { return; }
					// RESTORED by #1164. This test was attempted in #1161 and REVERTED, because at
					// that time the port could not distinguish the two states -- both a written
					// `#simd[0]` and an unresolved polymorphic count arrived here with
					// o.mode == Constant. #1164 fixed the cause (the Entity_Constant ident arm now
					// returns early on an unresolved value, which was only possible once `nil`
					// stopped being a Constant-with-nil-value), so the reference's own predicate
					// finally works here.
					if ctx.disallow_polymorphic_return_types && o.mode != .Constant {
						return
					}
					error_node(at.len, "Invalid length for #simd, expected a power of two length, got '%d'", count)
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
	// C++ reaches every one of these through check_open_scope (checker.cpp:349-360),
	// which sets ScopeFlag_Type for StructType/EnumType/UnionType/BitSetType/BitFieldType.
	// These sites call create_scope directly and so never set it. That flag is what stops
	// check_vet_unused (checker.cpp:720) from treating FIELDS as unused local variables:
	// without it, -vet reported every field of every unreferenced struct, 68,119 spurious
	// diagnostics across the sweep against the oracle's ~1 per package. make_soa_struct_internal
	// already sets it (check_type.odin:372); these three were simply missed. LEDGER 290.
	struct_scope := create_scope(ctx.scope, ctx.checker.allocator)
	if struct_scope != nil {
		struct_scope.flags += {.Type}
	}

	// Create the struct type
	struct_type := new(Type, ctx.checker.allocator)
	struct_type.kind = .Struct
	struct_type.variant = Type_Struct {
		node  = st,
		scope = struct_scope,
	}

	// NOTE: the wait signals need no initialization. A zero-valued Wait_Signal is UNSET,
	// which matches C++ where Type_Struct's futex is zero-initialized and only
	// wait_signal_set makes it available. (The previous sync.Wait_Group emulation had to
	// add 1 here, because a zero-valued Wait_Group reads as ALREADY DONE -- the polarity is
	// inverted between the two. See ast/semantic_types.odin Wait_Signal.)

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
	// C++ Reference: check_type.cpp:680-685 --
	//   Even a one-field `#raw_union` must be marked. RISC-V psABI excludes unions from the
	//   hardware floating-point convention. `struct{union{f32}}` goes in `a0` where
	//   `struct{f32}` goes in `fa0`.
	// The `min_field_count > 1` conjunct was dropped upstream in the abi_conformance PR; keeping
	// it made `type_is_raw_union` answer false for the zero- and one-field shapes.
	if node.is_raw_union {
		st.is_raw_union = true
		context_str = "struct #raw_union"
	}

	// Set basic struct properties
	st.node = node
	// Only set scope if not already set (may have been created in check_struct_type_expr)
	if st.scope == nil {
		// See the note at check_struct_type_expr: ScopeFlag_Type. LEDGER 290.
		st.scope = create_scope(ctx.scope, ctx.checker.allocator)
		if st.scope != nil {
			st.scope.flags += {.Type}
		}
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
	// C++ Reference: check_type.cpp check_struct_type
	wait_signal_set(&st.polymorphic_wait_signal)

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

		// `#simple`: every field must be at least "nearly simple compare".
		//
		// C++ Reference: check_type.cpp check_struct_type. The port's PARSER already recorded the
		// directive (parser.odin:3675 -> ast.Struct_Type.is_simple) and the predicate already
		// existed (types.odin, is_type_nearly_simple_compare) -- nothing ever read the flag, so
		// `struct #simple { a: string }` was accepted in silence. LEDGER #312, probes
		// n7_simp1/2 (rejected) and n7_simp3 (must stay clean).
		//
		// C++ declares a `success` flag here and never sets it false in the loop, so is_simple
		// is assigned unconditionally even when fields were reported. Reproduced as-is: that is
		// upstream's, and "correcting" it would diverge.
		if node.is_simple {
			for f in st.fields {
				if f == nil || f.kind != .Variable {
					continue
				}
				ft := entity_type(f)
				if !is_type_nearly_simple_compare(ft) {
					// NOT deleted. type_to_string can hand back a literal ("<no type>") or an
					// interned string, so freeing it aborts with "free(): invalid pointer" --
					// which is exactly what my first version of this loop did, and exactly the
					// mistake LEDGER #142 was retracted for. The neighbouring call at
					// check_type.odin:3142 does not free either.
					type_str := type_to_string(ft)
					error(
						f.token,
						"'struct #simple' requires all fields to be at least 'nearly simple compare', got %s",
						type_str,
					)
				}
			}
			st.is_simple = true
		}

		// Signal that field processing is complete
		// C++ Reference: check_type.cpp check_struct_type
		wait_signal_set(&st.fields_wait_signal)
	} else {
		// Polymorphic types don't have fields checked now, but we still need to
		// signal completion so waiters don't block forever
		wait_signal_set(&st.fields_wait_signal)
	}

	// Process alignment attributes
	// Helper macro equivalent for checking alignment attributes
	// RETURNS `abort` -- true means the CALLER must return from check_struct_type immediately.
	//
	// C++ Reference: check_type.cpp:728-737, the ST_ALIGN macro. Because it is a MACRO, its
	// `return;` on the '#packed' conflict returns from check_struct_type itself, so C++ reports
	// the FIRST conflicting directive and stops. The port turned the macro body into this nested
	// proc, which cannot return from its caller; the `return false` it produced was DISCARDED at
	// all three call sites, so the port reported EVERY conflicting directive.
	// `struct #packed #min_field_align(2) #align(4)` gave oracle 1 error, port 2. LEDGER #787.
	//
	// The result therefore means "abort", NOT "assigned": C++ does not return when
	// check_custom_align fails, it just leaves custom_##_name unassigned and carries on.
	check_align := proc(ctx: ^Checker_Context, node: ^ast.Struct_Type, align_expr: ^ast.Expr, align_value: ^i64, attr_name: string, st: ^Type_Struct) -> (abort: bool) {
		if align_expr == nil {
			return false
		}

		if st.is_packed {
			// C++ Reference: check_type.cpp check_struct_type
			error(align_expr, "'#%s' cannot be applied with '#packed'", attr_name)
			return true
		}

		align := i64(1)
		if check_custom_align(ctx, align_expr, &align, attr_name) {
			align_value^ = align
		}

		return false
	}

	// C++ Reference: check_type.cpp:739-741, ST_ALIGN(min_field_align)/(max_field_align)/(align).
	// The order is C++'s, so the FIRST directive conflicting with '#packed' is the one reported.
	//
	// The `pop_scope` before each early return is NOT in C++ and is NOT a divergence: C++'s macro
	// returns from a function that never pushed this scope, whereas the port pushed one at
	// check_type.odin:1154 and pops it at the tail. Returning without popping would leave the
	// scope stack unbalanced for every later declaration in the file. LEDGER #787.

	// Check #min_field_align
	if check_align(ctx, node, node.min_field_align, &st.custom_min_field_align, "min_field_align", st) {
		pop_scope(ctx, prev_scope)
		return
	}

	// Check #max_field_align
	if check_align(ctx, node, node.max_field_align, &st.custom_max_field_align, "max_field_align", st) {
		pop_scope(ctx, prev_scope)
		return
	}

	// Check #align
	if check_align(ctx, node, node.align, &st.custom_align, "align", st) {
		pop_scope(ctx, prev_scope)
		return
	}

	// Validate alignment coherence
	// C++ Reference: check_type.cpp (alignment validation section)
	if st.custom_align != 0 && st.custom_align < st.custom_min_field_align {
		error(node.align, "#align(%d) is defined to be less than #min_field_align(%d)", st.custom_align, st.custom_min_field_align)
	}

	if st.custom_max_field_align != 0 && st.custom_align > st.custom_max_field_align {
		error(node.align, "#align(%d) is defined to be greater than #max_field_align(%d)", st.custom_align, st.custom_max_field_align)
	}

	if st.custom_max_field_align != 0 && st.custom_min_field_align > st.custom_max_field_align {
		// ANCHOR IS `node.align`, NOT `node.min_field_align`, and that is DELIBERATE.
		// C++ Reference: check_type.cpp:756 -- all THREE coherence errors pass `st->align`.
		// It reads like an upstream copy-paste, but it is load-bearing in two ways and the port
		// diverged on both by "correcting" it to the obvious anchor:
		//   1. Same anchor => print_all_errors MERGES these three into ONE (LEDGER #578). With
		//      min_field_align as the anchor this error sat at a DIFFERENT position, survived the
		//      merge, and the port emitted a spurious SECOND error.
		//      `struct #align(8) #min_field_align(16) #max_field_align(4)` -- oracle 1, port 2.
		//   2. When `#align` is ABSENT, `st->align` is nullptr and C++ emits a POSITIONLESS
		//      "Error: ..." with no file, line or source snippet. The port printed a full
		//      position. `struct #min_field_align(8) #max_field_align(4)` -- oracle bare, port
		//      anchored at 2:29.
		// Reproduced as-is. LEDGER #787, battery cases g and h.
		error(node.align, "#min_field_align(%d) is defined to be greater than #max_field_align(%d)", st.custom_min_field_align, st.custom_max_field_align)

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
		// f.docs / f.comment are consumed at the field-entity creation below (#1177). They used to
		// be discarded here, which is what made the commented-out assignments look harmless.

		// Check field type
		if type_expr != nil {
			field_type = check_type_expr(ctx, type_expr, nil)
			if is_type_polymorphic(field_type) {
				st.is_polymorphic = true
				field_type = nil
			}
		}

		if field_type == nil {
			// C++ Reference: check_type.cpp check_struct_fields
			error(field, "Invalid parameter type")
			field_type = t_invalid
		}

		if is_type_untyped(field_type) {
			if is_type_untyped_uninit(field_type) {
				// C++ Reference: check_type.cpp check_struct_fields
				error(field, "Cannot determine parameter type from ---")
			} else {
				// C++ Reference: check_type.cpp check_struct_fields
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
			// t203: the id alloc_entity assigns. No checker consumer on either side (see the
			// enum-member twin below); closes the deviation without claiming a behaviour change.
			entity.id = 1 + cast(u64)sync.atomic_add(&global_entity_id, 1)
			// t203: STAMP THE FILE, exactly as alloc_entity does (entity.odin:76). C++ builds
			// this entity through alloc_entity_field -> INTERNAL_ENTITY_INIT, whose last line is
			//     e_->file = thread_unsafe_get_ast_file_from_id((token_).pos.file_id);
			// so in the reference EVERY entity carries its file unconditionally. Both of this
			// port's hand-built entities (here and the enum member below) skipped it, and a nil
			// `file` is not inert: is_entity_exported returns early on
			// `.Is_Private_Pkg in e.file.flags`, so a fileless entity silently reads as EXPORTED
			// no matter what file it came from. Same class as the nil-`.type` defect fixed above
			// -- bypassing alloc_entity loses whatever alloc_entity does, not just the type.
			if len(entity.token.pos.file) > 0 {
				if f := lookup_source_file(entity.token.pos.file); f != nil {
					entity.file = f
				}
			}
			// Both type fields, exactly as alloc_entity does. This entity is built by hand
			// rather than through alloc_entity_field, and it used to set ONLY the variant --
			// so every struct field in the program had a nil base `.type` while entity_type()
			// returned the real one. C++ has a single Entity::type field and cannot diverge.
			//
			// That gap was silent and load-bearing: are_types_identical compared two nil field
			// types and returned "identical", so the checker ACCEPTED assigning
			// `struct{x: f32}` to `struct{x: int}`. It also made the guarded branch in
			// add_type_info_type_internal (`if field.type != nil`) skip every struct field,
			// and made canonical struct names omit their field types.
			entity.type = field_type
			entity.variant = Entity_Variable {
				type        = field_type,
				field_index = field_src_index,
				// C++ Reference: check_type.cpp:198 --
				//     field->Variable.field_group_index = field_group_index;
				// `field_group_index` was COMPUTED here (incremented once per Ast_Field, line
				// 1456) and then never read -- the one assignment C++ makes from it was missing,
				// so every struct field in the program carried group 0.
				// It is only observable through `odin doc`: MEASURED with triage_docbin on
				// core/unicode/utf8, where the oracle gives Grapheme_Iterator's fifteen fields
				// groups 0..14 and the port gave 0 for all fifteen.
				// C++ assigns after add_entity; setting it in the literal is the same because
				// add_entity does not read the field.
				field_group_index = field_group_index,
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

			// C++ Reference: check_type.cpp:202-208 --
			//     if (j == 0)                  { field->Variable.docs    = docs; }
			//     if (j+1 == p->names.count)   { field->Variable.comment = comment; }
			// #1177. These two assignments were COMMENTED OUT and the values discarded a few lines
			// above (`_ = f.docs; _ = f.comment`), so every struct FIELD lost its doc comment. Both
			// Entity_Variable.docs/.comment (ast/semantic_types.odin:532-533) and ast.Field's
			// docs/comment (ast.odin:873,879) exist and are type-compatible, so the omission was not
			// a compile constraint.
			// NOTE THE ASYMMETRY, which is the reference's and is preserved: docs attach to the FIRST
			// name of a multi-name field group (`a, b: int`) and the comment to the LAST.
			// The consumer is docs_writer's entity emission, so this is STATE that only `odin doc`
			// output can show -- see the note in COVERAGE.md about the inverted fix order: no
			// instrument here compares comment TEXT, so this had to be fixed from the code read.
			if j == 0 {
				if v, vok := &entity.variant.(Entity_Variable); vok {
					v.docs = f.docs
				}
			}
			if j + 1 == len(f.names) {
				if v, vok := &entity.variant.(Entity_Variable); vok {
					v.comment = f.comment
				}
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
				// #893: unquote_string gained an ok flag. It is DISCARDED here, and C++ does not
				// discard it -- it reports **"Invalid string literal"** (not "Invalid struct
				// tag", as this comment said at #893; corrected at #899) and then CLEARS the tag
				// with `tag = {}`.
				//
				// Left as-is because the guard looks UNREACHABLE from a well-formed token: the
				// tokenizer validates string literals before the checker sees them, so a tag that
				// parsed cannot fail unquoting. `"\q"` -- the obvious candidate -- is rejected by
				// BOTH tokenizers as "Unknown escape sequence" and never reaches here. Not
				// demonstrated either way, so the C++ arm is not reproduced on speculation.
				//
				// #903: THE FOURTH ARGUMENT IS NOW PASSED. C++ hands `tag.text[0] == '`'` as
				// `has_carriage_return`, so a RAW-STRING tag goes through strip_carriage_return.
				// The port had no such parameter, so a raw tag on a CRLF file kept its CRs --
				// measured as `line1\r\nline2` against the reference's `line1\nline2`, and
				// visible only once schema v4 put tags into the model dump (#899/#902).
				unquoted_tag, _ := unquote_string(tag, len(tag) != 0 && tag[0] == '`')
				tag = unquoted_tag
			}
			append(&st.tags, tag)

			field_src_index += 1
		}

		// Handle 'using' fields - import symbols into struct scope
		if is_using && len(f.names) > 0 {
			first_type := entity_type(st.fields[len(st.fields) - 1])
			soa_ptr := is_type_soa_pointer(first_type)
			t := base_type(type_deref(first_type))

			if (soa_ptr || !does_field_type_allow_using(t)) && len(f.names) >= 1 {
				if ident, ok2 := f.names[0].derived.(^ast.Ident); ok2 {
					field_name := ident.name
					// C++ Reference: check_type.cpp check_struct_fields:
					//     gbString type_str = type_to_string(first_type);
					//
					// #1072: FIRST_TYPE, NOT `t`. `t` is the base_type(type_deref(..)) computed
					// two lines up FOR THE PREDICATE ONLY; C++ tests with `t` and REPORTS with
					// `first_type`, so the message names the field's DECLARED type, pointer
					// indirection and name intact. The port reported the stripped one.
					// MEASURED on `using f: ^Named_E` where Named_E is an alias of an enum:
					//     C++  "... of type '^E'"
					//     port "... of type 'enum int {A}'"
					// The port both dropped the pointer and expanded the enum inline.
					type_str := type_to_string(first_type)
					// t213: C++ (check_type.cpp:232) passes `name_token`, a TOKEN, so the recorded
					// end is zero; `error(ident, ...)` resolves to error_node and computes an end
					// one column past the identifier. Only -json-errors shows the difference --
					// end_column 21 (oracle) vs 22 (port) -- because both render as one `^`.
					error(ident.pos, "'using' cannot be applied to the field '%s' of type '%s'", field_name, type_str)
					continue
				}
			}

			populate_using_entity_scope(ctx, st.scope, node, f, field_type, 1)
		}

		// Handle 'subtype' fields
		if is_subtype && len(f.names) > 0 {
			first_type := entity_type(st.fields[len(st.fields) - 1])
			t := base_type(type_deref(first_type))

			if !does_field_type_allow_using(t) && len(f.names) >= 1 {
				if ident, ok3 := f.names[0].derived.(^ast.Ident); ok3 {
					field_name := ident.name
					// C++ Reference: check_type.cpp check_struct_fields — the subtype arm makes
					// the same choice as the using arm above: test with `t`, report `first_type`.
					type_str := type_to_string(first_type)
					// Sibling of the `using` site above; C++ check_type.cpp:249 also passes
					// `name_token`.
					error(ident.pos, "'subtype' cannot be applied to the field '%s' of type '%s'", field_name, type_str)
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

	// C++ Reference: check_type.cpp check_record_polymorphic_params - `bool can_check_fields = true;`
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

		field_group_index := 0

		// C++ lines 386-532: Iterate through field groups
		for field in polymorphic_params.list {
			field_group_index += 1

			// C++ Reference: check_type.cpp check_record_polymorphic_params
			type_expr := field.type
			default_value := unparen_expr(field.default_value)
			type: ^Type = nil
			is_type_param := false
			is_type_polymorphic_type := false
			specialization: ^Type = nil

			// C++ lines 425-428
			if type_expr == nil && default_value == nil {
				error(field, "Expected a type for this parameter")
				continue
			}

			// C++ lines 430-446
			if type_expr != nil {
				if ellipsis, is_ellipsis := type_expr.derived.(^ast.Ellipsis); is_ellipsis {
					type_expr = ellipsis.expr
					error(field, "A polymorphic parameter cannot be variadic")
				}
				if typeid_type, is_typeid := type_expr.derived.(^ast.Typeid_Type); is_typeid {
					is_type_param = true
					if typeid_type.specialization != nil {
						specialization = check_type_expr(ctx, typeid_type.specialization, nil)
					}
					// C++ line 445: type = alloc_type_generic(ctx->scope, 0, str_lit(""), specialization);
					//
					// C++ never runs check_type over the `typeid` node itself. The port did,
					// and then overwrote the result with the specialization when one was
					// written - so `$T: typeid` bound T to whatever check_type_expr makes of a
					// bare `typeid`, and `$T: typeid/Spec` bound it to Spec rather than to a
					// generic constrained by Spec. Neither is a type variable, which is also
					// why the specialization was never checked against the operand: nothing
					// was left holding it.
					type = alloc_type_generic(ctx.checker, ctx.scope, 0, "", specialization)
				} else {
					type = check_type_expr(ctx, type_expr, nil)
					if is_type_polymorphic(type) {
						is_type_polymorphic_type = true
					}
				}
			}

			// C++ lines 449-458
			param_value: Parameter_Value
			if default_value != nil {
				out_type: ^Type = nil
				param_value = handle_parameter_value(ctx, type, &out_type, default_value, false)
				if type == nil && out_type != nil {
					type = out_type
				}
				if param_value.kind != .Constant && param_value.kind != .Nil {
					error(default_value, "Invalid parameter value")
					param_value = {}
				}
			}

			// C++ lines 462-465
			if type == nil {
				error(field, "Invalid parameter type")
				type = t_invalid
			}

			// C++ lines 466-473
			if is_type_untyped(type) {
				if is_type_untyped_uninit(type) {
					error(field, "Cannot determine parameter type from ---")
				} else {
					error(field, "Cannot determine parameter type from a nil")
				}
				type = t_invalid
			}

			// C++ lines 475-480
			if is_type_polymorphic_type && !is_type_proc(type) {
				str := type_to_string(type)
				error(field, "Parameter types cannot be polymorphic, got %s", str)
				type = t_invalid
			}

			// C++ lines 482-484
			if !is_type_param && check_constant_parameter_value(ctx, type, field) {
				// failed
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

				// C++ Reference: check_type.cpp check_record_polymorphic_params. The operand defaults to t_invalid and
					// falls back to the parameter's declared default when the caller supplied
					// fewer operands than there are parameters. Indexing is by len(entities), not
					// by a separate counter: a name that fails the identifier check above adds no
					// entity, so it must consume no operand either.
					//
					// What C++ does NOT do here is validate the operand: no Addressing_Invalid
					// skip, no nil-type check, and no "is it a type?" test. Each of those was
					// invented by this port, and each `continue`d past `add_entity`, so a
					// rejected operand left the parameter name unbound and every later
					// reference to it reported "Undeclared name". The operand-is-not-a-type
					// diagnostic is C++'s to emit, from check_polymorphic_record_type
					// (check_expr.cpp:8378), before control ever reaches this function.
					if poly_operands != nil {
						operand_storage := Operand{type = t_invalid}
						operand := &operand_storage
						if len(entities) < len(poly_operands) {
							operand_storage = poly_operands[len(entities)]
						} else if param_value.kind != .Invalid {
							operand_storage.mode = .Constant
							operand_storage.value = param_value.value
						}

						t := operand.type

					if is_type_param {
						// C++ Reference: check_type.cpp check_record_polymorphic_params
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
						} else if specialization != nil &&
						   !check_type_specialization_to(ctx, specialization, operand.type, false, true) {
							// C++ lines 517-525
							if !ctx.no_polymorphic_errors {
								ts := type_to_string(operand.type)
								ss := type_to_string(specialization)
								error(operand.expr, "Cannot convert type '%s' to the specialization '%s'", ts, ss)
							}
						}

						// When mode is .Type, operand.type is the actual type (e.g., int)
						// We create a type name entity bound to this type
						t = operand.type
						e = alloc_entity_type_name(ctx.scope, token, t)
						// C++ line 527: e->TypeName.is_type_alias = true;
						if tn, tn_ok := &e.variant.(Entity_Type_Name); tn_ok {
							tn.is_type_alias = true
						}
						e.flags += {.Poly_Const}
						// Note: Don't call set_base_type here - the entity's type is already t
						// and t already has its base set correctly
					} else {
						// C++ Reference: check_type.cpp check_record_polymorphic_params - constant parameter.
						//
						// C++ performs NO validation of the operand here. The declared
						// parameter type was already vetted by
						// check_constant_parameter_value (check_type.cpp check_record_polymorphic_params); the operand
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
					// C++ lines 544-553: No operand, create entity for polymorphic param
					if is_type_param {
						e = alloc_entity_type_name(scope, token, type)
						// C++ line 547: e->TypeName.is_type_alias = true;
						if tn, tn_ok := &e.variant.(Entity_Type_Name); tn_ok {
							tn.is_type_alias = true
						}
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

// check_constant_parameter_value rejects a polymorphic/procedure parameter whose declared
// type cannot hold a compile-time constant. Returns true when it errored.
// C++ Reference: check_type.cpp check_constant_parameter_value
check_constant_parameter_value :: proc(ctx: ^Checker_Context, type: ^Type, expr: ^ast.Node) -> bool {
	if !is_type_constant_type(type) {
		str := type_to_string(type)
		error(expr, "A parameter must be a valid constant type, got %s", str)
		return true
	}
	return false
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
	sync.recursive_mutex_lock(&found_gen_types.mutex)
	defer sync.recursive_mutex_unlock(&found_gen_types.mutex)

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

	case .Fixed_Capacity_Dynamic_Array:
		// C++ types.cpp is_type_polymorphic. The CAPACITY can itself be polymorphic --
		// `[dynamic; $N]T` -- so a generic capacity makes the whole type polymorphic
		// regardless of the element.
		//
		// Without this arm `[dynamic; $N]u8` was not recognised as polymorphic at all,
		// so a call site never attempted unification and reported "Cannot pass argument
		// of type '[dynamic; 8]u8' to parameter of type '[dynamic; $N]u8'". Everything
		// downstream was already in place: the type-expression checker sets
		// `generic_capacity` (check_type.odin:3381) and is_polymorphic_type_assignable
		// already binds it via polymorphic_assign_index. Only the predicate that
		// gates entry to that path was missing.
		if fc, ok := t.variant.(Type_Fixed_Capacity_Dynamic_Array); ok {
			if fc.generic_capacity != nil {
				return true
			}
			return is_type_polymorphic(fc.elem, or_specialized)
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

// set_polymorphic_record_instance_name composes the NAME of an instantiated polymorphic record
// and writes it to BOTH the type and its entity's token.
//
// C++ Reference: check_expr.cpp check_polymorphic_record_type.
//
// `Foo(int)` is named `Foo($T=int)`, and `Buf(4, int)` is named `Buf($N=4, $T=int)`. This is a
// STORED NAME, not a rendering: C++'s Type_Named printer arm (types.cpp:5542-5549) writes only
// `Named.name`, and the `allow_polymorphic` mode of write_type_to_string that WOULD assemble the
// parameter list is dead code upstream (type_to_string_polymorphic, types.cpp:5706, has zero
// callers). So the whole difference lives here. Without this the port names every instantiation
// just `Foo`, and `Foo(int)` / `Foo(string)` render identically in every diagnostic. #662.
//
// This must run AFTER check_struct_type/check_union_type return, because those call
// add_polymorphic_record_entity, which builds the entity's token from the PRE-rename name
// (check_type.odin:1887, C++ check_type.cpp:335). That is exactly why C++ writes the new name to
// the entity's token as well as to Named.name -- the entity already exists by this point.
//
// NOTE(parity): C++ does NOT nil-check `tuple->variables[i]`, and neither does this. Adding a
// guard would change the ", " separator's index accounting; if a nil ever appears here both
// implementations fault, and that would be a defect in the tuple, not in this naming.
set_polymorphic_record_instance_name :: proc(ctx: ^Checker_Context, named_type: ^Type, original_type: ^Type) {
	if named_type == nil || original_type == nil {
		return
	}
	bt := base_type(named_type)
	if bt == nil {
		return
	}
	// C++ check_expr.cpp:8548 -- only records are renamed.
	#partial switch bt.kind {
	case .Struct, .Union:
	case:
		return
	}

	// C++ check_expr.cpp:8549-8551
	orig_named, orig_ok := original_type.variant.(Type_Named)
	if !orig_ok || orig_named.type_name == nil {
		return
	}

	// C++ check_expr.cpp:8553-8554
	b := strings.builder_make(ctx.checker.allocator)
	strings.write_string(&b, orig_named.type_name.token.text)
	strings.write_byte(&b, '(')

	// C++ check_expr.cpp:8556-8576
	tuple := get_record_polymorphic_params(bt)
	if tuple != nil {
		for v, i in tuple.variables {
			if i > 0 {
				strings.write_string(&b, ", ")
			}
			strings.write_byte(&b, '$')
			strings.write_string(&b, v.token.text)

			#partial switch ev in v.variant {
			case Entity_Type_Name:
				// C++ check_expr.cpp:8565-8569
				if v.type != nil && v.type.kind != .Generic {
					strings.write_byte(&b, '=')
					// C++ passes shorthand=false here; the port's type_to_string defaults to
					// shorthand=true, so it must be passed explicitly.
					strings.write_string(&b, type_to_string(v.type, false))
				}
			case Entity_Constant:
				// C++ check_expr.cpp:8570-8575 -- `value.kind != ExactValue_Invalid`, which in
				// the port is a nil union.
				if ev.value != nil {
					strings.write_byte(&b, '=')
					strings.write_string(&b, exact_value_to_string(ev.value))
				}
			}
		}
	}
	// C++ check_expr.cpp:8577
	strings.write_byte(&b, ')')

	// C++ check_expr.cpp:8579-8583 -- write BOTH.
	new_name := strings.to_string(b)
	new_named := &named_type.variant.(Type_Named)
	new_named.name = new_name
	if new_named.type_name != nil {
		new_named.type_name.token.text = new_name
	}
}

// get_record_polymorphic_params retrieves polymorphic parameters from struct/union types
// C++ Reference: types.cpp get_record_polymorphic_params
// (STRANDED above a different procedure until #734 -- another procedure was inserted between
//  this doc comment and the definition it documents.)
get_record_polymorphic_params :: proc(t: ^Type) -> ^Type_Tuple {
	if t == nil {
		return nil
	}

	bt := base_type(t)

	#partial switch bt.kind {
	case .Struct:
		// C++ Reference: types.cpp:2462 -- `wait_signal_until_available(&t->Struct.polymorphic_wait_signal);`
		//
		// THIS IS A BARRIER, not a nicety, and it had been commented out. It is the READER half
		// of the polymorphic-record publication protocol: check_struct_type releases this signal
		// immediately after check_record_polymorphic_params and BEFORE it publishes the entity
		// into the originating record's gen_types cache (check_type.odin above; C++ 696 then 701,
		// same order). So every entity a reader can find in that cache is guaranteed to have
		// released its signal, and waiting here can never deadlock against the publisher.
		//
		// Without it, find_polymorphic_record_entity -- which calls this for EVERY cached entity
		// on every lookup -- reads polymorphic_params out of a struct another worker is still
		// building. MEASURED: see $S/polyrace.sh.
		if st_ptr, st_ptr_ok := &bt.variant.(Type_Struct); st_ptr_ok {
			wait_signal_until_available(&st_ptr.polymorphic_wait_signal)
		}
		if st, ok := bt.variant.(Type_Struct); ok {
			if st.polymorphic_params != nil && st.polymorphic_params.kind == .Tuple {
				if tuple, tuple_ok := &st.polymorphic_params.variant.(Type_Tuple); tuple_ok {
					return tuple
				}
			}
		}

	case .Union:
		// C++ Reference: types.cpp:2468 -- the union half of the same barrier. check_union_type
		// releases this signal at the same point in the same order (check_type.odin:3185, then
		// add_polymorphic_record_entity), so the same no-deadlock argument holds.
		if ut_ptr, ut_ptr_ok := &bt.variant.(Type_Union); ut_ptr_ok {
			wait_signal_until_available(&ut_ptr.polymorphic_wait_signal)
		}
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
	sync.recursive_mutex_lock(&named.gen_types_data.mutex)
	defer sync.recursive_mutex_unlock(&named.gen_types_data.mutex)

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

			// C++ Reference: check_type.cpp find_polymorphic_record_entity, find_polymorphic_record_entity.
			//
			// Three things this used to get wrong:
			//
			//  1. It keyed on the OPERAND's mode; C++ keys on the PARAMETER ENTITY's kind
			//     (`p->kind`). The parameter is what says whether this slot is a type or a
			//     constant; the operand merely supplies a value for it.
			//  2. It had no guard against a POLYMORPHIC operand. C++ refuses outright --
			//     "NOTE(bill): Do not add polymorphic version to the gen_types" -- because
			//     two distinct generic placeholders compare equal, so `Map_Cell($T)` and
			//     `Map_Cell($K)` alias each other in the cache. (Instrumented in task 189:
			//     `Map_Cell` instantiated with `$T`, then CACHE HIT for `$K` and `$V`.)
			//  3. It had no `o.expr == nullptr` skip and no same-entity shortcut.
			if operand.expr == nil {
				continue
			}
			if ctx != nil && ctx.checker != nil {
				if oe := entity_of_node(&ctx.checker.info, operand.expr); oe != nil && oe == param_entity {
					// Same entity, so necessarily the same thing.
					continue
				}
			}

			#partial switch param_entity.kind {
			case .Type_Name:
				if is_type_polymorphic(operand.type) {
					// Never treat a still-generic operand as a cached instantiation.
					match = false
					break
				}
				if !are_types_identical(operand.type, param_type) {
					match = false
					break
				}
			case .Constant:
				const_entity := param_entity.variant.(Entity_Constant)
				if !compare_exact_values(.Cmp_Eq, operand.value, const_entity.value) {
					match = false
					break
				}
				if !are_types_identical(operand.type, param_type) {
					match = false
					break
				}
			case:
				match = false
			}
			if !match {
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

		// Clone the record's AST for this instantiation, as C++ does
		// (check_expr.cpp check_polymorphic_record_type) and as the union arm below already does. Checking
		// annotates nodes with their resolved type-and-value, so re-checking the
		// ORIGINAL nodes for a second instantiation risks the first instantiation's
		// cached types winning.
		cloned_node := clone_ast_node(st.node)
		if cloned_node == nil {
			return nil
		}

		// Get the actual Struct_Type node from the Node
		struct_node, struct_node_ok := cloned_node.derived.(^ast.Struct_Type)
		if !struct_node_ok {
			return nil
		}

		// Create new struct type with initialized variant
		new_struct_type := alloc_type_struct(ctx.checker)
		if sv, sv_ok := &new_struct_type.variant.(Type_Struct); sv_ok {
			sv.node = cloned_node
		}

		// C++ Reference: check_expr.cpp check_polymorphic_record_type. `polymorphic_parent` links an instance
		// back to the generic record it came from. The port declared and READ this field
		// (types.odin:853, check_builtin.odin:6932, check_type_specialization_to) but
		// never wrote it, so it was permanently nil and every reader silently took the
		// "not polymorphic" path — including the `$Q/Queue` specialization test.
		if s, s_ok := &new_struct_type.variant.(Type_Struct); s_ok {
			s.polymorphic_parent = original_type
		}

		// Set up the named type relationship
		set_base_type(new_named_type, new_struct_type)

		// Check struct with the provided operands.
		//
		// C++ Reference: check_expr.cpp check_polymorphic_record_type —
		//     CheckerContext ctx = *c;
		//     // NOTE(bill): We need to make sure the lookup scope for the record is
		//     // the same as where it was created
		//     ctx.scope = polymorphic_record_parent_scope(original_type);
		//
		// Passing the caller's ctx straight through means the record's FIELD TYPES are
		// looked up from the instantiation site. For a record instantiated from another
		// package that put the importer's package scope on the chain instead of the
		// defining one, so a field naming a sibling-file type - core/container/queue's
		// `MPSC_Queue :: struct($T: typeid) { q: Queue(T) }` - failed as
		// "Undeclared name".
		inst_ctx := ctx^
		if parent_scope := polymorphic_record_parent_scope(original_type); parent_scope != nil {
			inst_ctx.scope = parent_scope
		}
		check_struct_type(&inst_ctx, new_struct_type, struct_node, operands, new_named_type, original_type)

		// C++ Reference: check_expr.cpp check_polymorphic_record_type -- the rename runs
		// after the record body is checked, for both the struct and union branches. #662.
		set_polymorphic_record_instance_name(ctx, new_named_type, original_type)

		return new_named_type

	case .Union:
		ut, ut_ok := bt.variant.(Type_Union)
		if !ut_ok || ut.node == nil {
			return nil
		}

		// Clone the record's AST for this instantiation, exactly as C++ does
		// (check_expr.cpp check_polymorphic_record_type). Checking annotates nodes with their resolved types, so
		// re-checking the ORIGINAL nodes for a second instantiation lets the first
		// instantiation's cached type-and-value win: `Maybe(T6)` followed by
		// `Maybe(Stamp)` produced a second union whose variant was still `[6]u8`.
		cloned_node := clone_ast_node(ut.node)
		if cloned_node == nil {
			return nil
		}

		// Get the actual Union_Type node from the Node
		union_node, union_node_ok := cloned_node.derived.(^ast.Union_Type)
		if !union_node_ok {
			return nil
		}

		// Create new union type with initialized variant
		new_union_type := alloc_type_union(ctx.checker)

		// C++ Reference: check_expr.cpp check_polymorphic_record_type — see the struct arm above.
		if u, u_ok := &new_union_type.variant.(Type_Union); u_ok {
			u.polymorphic_parent = original_type
			u.node = cloned_node
		}

		// Set up the named type relationship
		set_base_type(new_named_type, new_union_type)

		// `check_union_type` assigns `ut.scope = ctx.scope` and never opens one of its
		// own -- C++'s does the same, because C++ opens the scope HERE
		// (check_expr.cpp check_polymorphic_record_type). The port's struct arm gets away without this only
		// because `check_struct_type` happens to create its own scope internally. Without
		// a fresh scope per instantiation every `Maybe($T)` binds `$T` into the SAME
		// scope, so two instantiations reachable together -- two parameters of one
		// procedure, or two fields of one struct -- collided and the second silently
		// reused the first's binding.
		inst_ctx := ctx^
		if parent_scope := polymorphic_record_parent_scope(original_type); parent_scope != nil {
			inst_ctx.scope = parent_scope
		}
		check_open_scope(&inst_ctx, cloned_node)
		check_union_type(&inst_ctx, new_union_type, union_node, operands, new_named_type, original_type)
		check_close_scope(&inst_ctx)

		// C++ Reference: check_expr.cpp check_polymorphic_record_type -- same rename as
		// the struct branch above; C++ has ONE block after the if/else, the port has two returns.
		set_polymorphic_record_instance_name(ctx, new_named_type, original_type)

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
// #1221: `allow_multi_pointer` mirrors C++'s second parameter (types.cpp:1271). Defaulted to
// false so every existing call site is unchanged; only check_unary_op's Token_Mul arm passes true.
type_deref :: proc(t: ^Type, allow_multi_pointer := false) -> ^Type {
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

	case .Multi_Pointer:
		// C++ types.cpp:1286-1290: multi-pointers deref ONLY when explicitly allowed; otherwise
		// the switch falls through and the ORIGINAL type is returned, not the element.
		if allow_multi_pointer {
			mp := bt.variant.(Type_Multi_Pointer)
			return mp.elem
		}

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
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

	return bt.kind == .Soa_Pointer
}

is_type_struct :: proc(t: ^Type) -> bool {
	bt := base_type(t)
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

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
		// C++ Reference: check_type.cpp:13-22. TWO variants, chosen on whether the AST node is
		// available, and the port had ONLY the second:
		//     if (node != nullptr) { str = expr_to_string(node); }
		//     if (str != nullptr) { error(..., "'%.*s' is already declared in '%s'", LIT(name), str); }
		//     else                { error(..., "'%.*s' is already declared", LIT(name)); }
		// #1201. Dropping the `in '%s'` clause loses the only part of the message that says WHICH
		// aggregate the collision happened in.
		if node != nil {
			str := expr_to_string(node)
			defer delete(str)
			error(e.token, "'%s' is already declared in '%s'", name, str)
		} else {
			error(e.token, "'%s' is already declared", name)
		}
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
				// C++ check_type.cpp populate_using_entity_scope_field passes type_to_string(original_type). The port passed
				// the ^Type itself to a "%v", which dumps the whole Type struct. LEDGER 287.
				// C++ Reference: check_type.cpp:44-52 -- again TWO variants on `node != nullptr`, and
				// again the port had only the one WITHOUT the type. #1201.
				if node != nil {
					str := expr_to_string(node)
					defer delete(str)
					error(e.token, "'%s' is already declared in '%s', through 'using' from '%s'", name, str, type_to_string(original_type))
				} else {
					error(e.token, "'%s' is already declared, through 'using' from '%s'", name, type_to_string(original_type))
				}
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

	// NOTE: zero-valued Wait_Signal is UNSET; no initialization required. See above.

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
	// check_open_scope/check_close_scope, and check_type.cpp check_enum_type stores THAT scope
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
	//      recover the enclosing scope (mirroring check_decl.cpp clone_enum_type), which lands
	//      on the grandparent when `scope` is already the enclosing one.
	// C++ Reference: check_type.cpp -- the set and the matching clear around the enum
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
		scope     = ctx.scope, // C++ check_type.cpp check_enum_type — the freshly opened enum scope
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
	wait_signal_set(&ut.polymorphic_wait_signal)

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

			// #1076: C++ HAS A THREE-WAY if / else-if / else HERE; THE PORT COLLAPSED THE FIRST
			// TWO INTO ONE DISJUNCTION. C++ Reference: check_type.cpp check_union_type:
			//
			//     if (is_type_untyped(t)) {
			//         ok = false; error(node, "Invalid variant type in union '%s'", str);
			//     } else if (is_type_empty_union(t)) {
			//         Type *base = base_type(t);
			//         if (base == nullptr || base->kind != Type_Union || base->Union.node == nullptr) {
			//             ok = false; error(node, "Invalid variant type in union '%s'", str);
			//         }
			//     } else {
			//         ...duplicate scan...
			//     }
			//
			// TWO consequences, both measured:
			//  * An empty union that is NAMED (base is a Union WITH a node) passes the inner
			//    guard, so `ok` stays true and C++ ACCEPTS it. The port rejected it outright.
			//        Empty :: union {}; U :: union { Empty, int }   oracle 0, port 1
			//  * C++ does NOT run the duplicate scan for an empty union at all — the else-if
			//    consumes the case. So two identical empty-union variants draw NO duplicate
			//    diagnostic.
			//        V :: union { Empty, Empty }                    oracle 0, port 1
			// Restored as C++ spells it.
			if is_type_untyped(t) {
				ok = false
				// C++ Reference: check_type.cpp check_union_type
				type_str := type_to_string(t)
				error(variant_node, "Invalid variant type in union '%s'", type_str)
			} else if is_type_empty_union(t) {
				base := base_type(t)
				if base == nil || base.kind != .Union || base.variant.(Type_Union).node == nil {
					ok = false
					// C++ Reference: check_type.cpp check_union_type
					type_str := type_to_string(t)
					error(variant_node, "Invalid variant type in union '%s'", type_str)
				}
			} else {
				// Check for duplicate variant types
				for existing_variant, j in ut.variants {
					if union_variant_index_types_equal(t, existing_variant) {
						ok = false
						// C++ Reference: check_type.cpp check_union_type
						type_str := type_to_string(t)
						// C++ Reference: check_type.cpp check_union_type. The "Previous found at" line
						// below was written but never reached the output: without a block an
						// unblocked error_line does not stay attached to its error.
						begin_error_block()
						defer end_error_block()
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
						// C++ Reference: check_type.cpp check_union_type
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
		// #1116. C++ Reference: check_type.cpp check_union_type does a STRAIGHT COPY:
		//     union_type->Union.kind = ut->kind;
		// with no per-kind mapping at all. The port mapped shared_nil onto .Normal, with the
		// comment "shared_nil is represented as Normal in the type system / The semantic difference
		// is enforced during variant checking above". The variant check IS present and correct —
		// but the KIND is also read for OUTPUT, and those readers then could never fire:
		//     name_canonicalization.odin  the "#shared_nil" suffix in canonical type names
		//     check_expr.odin             type_to_string
		//     docs_writer.odin            the Doc_Type_Flag_Union.Shared_Nil bit
		// So a #shared_nil union was indistinguishable from a plain one in every rendered name.
		//
		// REPORTED BY THE mirc AGENT as state-only and "needs a model dump". IT IS WITNESSABLE:
		// a NAMED union prints as its name, but an ANONYMOUS one prints its expanded form —
		//     x: union #shared_nil { ^int, rawptr } = "wrong"
		//     oracle: "... to 'union #shared_nil {^int, rawptr}' ..."
		//     port:   "... to 'union {^int, rawptr}' ..."
		// and the #no_nil equivalent already matched, because THAT kind was recorded.
		//
		// SAFE because every BEHAVIOURAL consumer tests .No_Nil specifically
		// (check_equivalence's `kind != .No_Nil`, check_builtin's `== .No_Nil` and
		// `== .No_Nil ? 0 : 1`), for which Shared_Nil and Normal are equivalent either way.
		ut.kind = .Shared_Nil
	}

	// Validate #no_nil constraint.
	// C++ Reference: check_type.cpp check_union_type:
	//
	//     case UnionType_no_nil:
	//         if (union_type->Union.is_polymorphic && poly_operands == nullptr) {
	//             GB_ASSERT(variants.count == 0);
	//             if (ut->variants.count != 1) {
	//                 break;                    // <-- LEAVES THE CASE. NO ERROR.
	//             }
	//         }
	//         if (variants.count < 2) {
	//             error(node, "A union with #no_nil must have at least 2 variants");
	//         }
	//         break;
	//
	// #1076: THE GUARD WAS INVERTED. That `break` exits the switch case and SUPPRESSES the
	// error; the port's comment read "Fall through to error below" and it did exactly that, so
	// an unspecialized polymorphic #no_nil union with anything other than one source variant was
	// rejected. MEASURED: `U :: union($T: typeid) #no_nil { T, int }` — oracle 0, port 1.
	// (Two source variants, != 1, so C++ takes the break and says nothing.)
	//
	// Reproduced with a labelled block, which is the faithful spelling of C++'s `break` out of a
	// switch case that Odin's `if` cannot express directly.
	if node.kind == .no_nil {
		no_nil_check: {
			if ut.is_polymorphic && len(poly_operands) == 0 {
				assert(len(ut.variants) == 0)
				if len(node.variants) != 1 {
					break no_nil_check
				}
			}

			if len(ut.variants) < 2 {
				// C++ Reference: check_type.cpp check_union_type
				error(node, "A union with #no_nil must have at least 2 variants")
			}
		}
	}

	// Process #align attribute
	if node.align != nil {
		custom_align := i64(1)
		if check_custom_align(ctx, node.align, &custom_align, "align") {
			if len(ut.variants) == 0 {
				// C++ Reference: check_type.cpp check_union_type
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
		// C++ Reference: check_type.cpp:937-948. The parser emits an ast.Enum_Field_Value for
		// EVERY member -- valued (`Red = 0`) and bare (`Red,`) alike, with `.value` nil for the
		// bare form -- exactly as Ast_EnumFieldValue does. So the reference's two rejections are
		// both reachable and both must be kept distinct:
		//   1. the node is not an Enum_Field_Value at all (nothing the parser produces today,
		//      but a hand-built AST can reach it), and
		//   2. the node's `name` is nil or is not an Ident (`enum { 1 = 2 }`).
		// Both emit the same text and both `continue`, so the split is invisible in output --
		// it is kept because the reference keeps it and a future divergence in either arm
		// should show up as one arm changing, not as a merged arm being re-split.
		field_value, is_efv := field.derived.(^ast.Enum_Field_Value)
		if !is_efv {
			// C++ Reference: check_type.cpp:937-940
			error(field, "An enum field's name must be an identifier")
			continue
		}

		ident_node := field_value.name
		init_node := field_value.value

		// Validate identifier
		// C++ Reference: check_type.cpp:943-946 -- note the diagnostic is anchored on `field`,
		// the Enum_Field_Value node, NOT on `ident`.
		ident: ^ast.Ident
		if ident_node != nil {
			ok: bool
			ident, ok = ident_node.derived.(^ast.Ident)
			if !ok {
				ident = nil
			}
		}
		if ident == nil {
			error(field, "An enum field's name must be an identifier")
			continue
		}

		// C++ Reference: check_type.cpp:947-948 -- read AFTER the identifier validation.
		docs := field_value.docs
		comment := field_value.comment

		name := ident.name

		// C++ line 851: u32 entity_flags = 0
		entity_flags: Entity_Constant_Flags = {}

		// Process field value
		if init_node != nil {
			// Explicit value provided
			o: Operand
			check_expr(ctx, &o, init_node)

			if o.mode != .Constant {
				// C++ Reference: check_type.cpp check_enum_type
				error(init_node, "Enumeration value must be a constant")
				o.mode = .Invalid
			}

			if o.mode != .Invalid {
				// C++ Reference: check_type.cpp check_enum_type — `constant_type` is the named enum
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

		// #1074: AN INVENTED RULE WAS DELETED HERE.
		//
		//     if name == "names" {
		//         error(field, "'names' is a reserved identifier for enumerations")
		//         continue
		//     }
		//
		// It cited "C++ Reference: check_type.cpp check_enum_type". That procedure has no such
		// check: C++ goes straight from the blank-identifier skip above to the min/max tracking
		// below. `grep -rn "reserved identifier" src/` returns NOTHING — the string exists
		// nowhere in the reference.
		//
		// Two divergences, not one: the diagnostic itself, and the `continue`, which dropped the
		// member from Enum.fields entirely — so len, min and max of the enum were all wrong
		// afterwards. MEASURED on `E :: enum { a, names, b }`: oracle 0, port 1.

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
		// t203: STAMP THE FILE -- see the twin comment on the struct-field entity above.
		// C++ check_type.cpp:1002 runs INTERNAL_ENTITY_INIT on this entity, which sets e->file.
		// WITNESS ($S/phase2/wit_priv203/p4), a single file:
		//     #+private
		//     package p
		//     E :: enum { A, B }
		//     f :: proc() { using E; _ = A }
		// The reference reports TWO errors -- the `using`-disallowed one, then `Undeclared name: A`
		// -- because check_using_stmt_entity skips every enum field failing is_entity_exported,
		// and `#+private` sets AstFile_IsPrivatePkg on the field's file. The port reported ONE:
		// its own is_entity_exported guard (check_stmt.odin) was already correct, but `field.file`
		// was nil here, so the guard could never fire and `using` imported members the reference
		// refuses to import. Drop `#+private` and both agree -- the flag was the whole difference.
		if len(entity.token.pos.file) > 0 {
			if f := lookup_source_file(entity.token.pos.file); f != nil {
				entity.file = f
			}
		}
		// t203: C++ check_type.cpp:1002 INTERNAL_ENTITY_INIT also assigns the unique id, and :1008
		// assigns `e->identifier = ident`. Both were missing here. The id has NO checker consumer
		// on either side (the reference reads Entity::id only in llvm_backend_stmt.cpp:2442, for
		// name mangling), so this is deviation-closing rather than defect-fixing -- recorded as
		// such, not dressed up as a fix. `identifier` DOES have checker consumers.
		entity.id = 1 + cast(u64)sync.atomic_add(&global_entity_id, 1)
		entity.identifier = ident
		// C++ line 946: entity->flags |= EntityFlag_Visited
		entity.flags = {.Visited}
		// C++ line 947: entity->state = EntityState_Resolved
		entity.state = .Resolved
		// Both type fields, as alloc_entity does -- the second instance of the same defect
		// fixed for struct fields in progress#166. This entity is also built by hand, and
		// setting only the variant left every enum member with a nil base `.type`.
		// checker_lifecycle.odin:599 reads that field raw and would register a global
		// constant with no type at all.
		entity.type = constant_type
		// C++ line 948-950: entity->Constant.flags |= entity_flags; entity->Constant.docs = docs; entity->Constant.comment = comment
		entity.variant = Entity_Constant {
			type    = constant_type,
			value   = iota,
			flags   = entity_flags,
			docs    = docs,
			comment = comment,
			// C++ Reference: check_type.cpp check_enum_type `e->Constant.init_expr = init;`,
			// added by upstream PR #7289 (merge b9bbcd33b). `init_node` is this port's spelling
			// of C++'s `init` -- the Field_Value's value expression, nil for a bare member. #755.
			init_expr = init_node,
		}

		// Check for duplicate names and add to scope
		// C++ Reference: check_type.cpp check_enum_type. Note that C++ adds the entity to
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
	// C++ Reference: check_type.cpp:1282-1283 -- `type->BitSet.node = node; type->BitSet.elem =
	// t_invalid;`. The `elem = t_invalid` seed is what every EARLY RETURN in this procedure leaves
	// behind, and the port left `elem` nil instead. The two are not interchangeable downstream:
	// check_assignment against a nil target takes its `target_type == nil` branch, defaults the
	// untyped operand and reports nothing, so `bit_set[0..<8; f32]{3}` silently passed the
	// assignment and then tripped the range check with the oracle-absent "Bit field value out of
	// bounds, 3 (3) not in the range 0 .. 0", while the oracle reports "Cannot assign value '3' of
	// type 'untyped integer' to 'invalid type' in a bit_set literal" and skips the range check.
	bit_set_type.variant = Type_Bit_Set {
		node = bst,
		elem = t_invalid,
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
			// C++ Reference: check_type.cpp check_bit_set_type formats the BigInts themselves via
			// big_int_to_string, not an i64. The port went through exact_value_to_i64, which
			// renders identically for anything that fits in 64 bits and TRUNCATES anything
			// that does not -- the same class as #166. Print the big integers, as C++ does.
			if iv_big, ok1 := iv.(big.Int); ok1 {
				if jv_big, ok2 := jv.(big.Int); ok2 {
					lo := iv_big
					hi := jv_big
					si, _ := big.int_itoa_string(&lo, 10, false, context.temp_allocator)
					sj, _ := big.int_itoa_string(&hi, 10, false, context.temp_allocator)
					error(bst.elem, "Lower interval bound larger than upper bound, %s .. %s", si, sj)
					return true
				}
			}
			error(bst.elem, "Lower interval bound larger than upper bound, %d .. %d", lower, upper)
			// C++ Reference: check_type.cpp check_bit_set_type -- a bare `return;` from a VOID function
			// whose caller (check_type.cpp:3903) allocated the type and never inspects a
			// result. C++ therefore reports the bad bounds and leaves a usable type behind.
			//
			// The port returned false, which propagates to check_type_expr and produces a
			// SECOND, spurious "'bit_set[5 ..= 2]' is not a type" that C++ never emits.
			// Probe iv3: oracle 1 diagnostic, port 2. Same invalidate-and-cascade shape as
			// the matrix row/column fix above.
			return true
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
				// C++ Reference: check_type.cpp:1350-1362. The diagnostic is NOT a bail-out on its
				// own -- C++ only returns when the type is not even a valid bit-field backing type.
				// An INTEGER ARRAY is diagnosed and then ACCEPTED as the underlying, which is why
				// `bit_set[0..<8; [2]u8]` gets ONE error from the oracle and then checks `s += {3}`
				// cleanly against a 16-bit backing. The port bailed on every non-integer.
				if !is_valid_bit_field_backing_type(u) {
					// Bare `return;` from a void C++ function whose caller allocated the type and
					// never inspects a result -- the same shape as the bounds arm above. Returning
					// false here produced a spurious, oracle-absent second diagnostic,
					// "'bit_set[0 ..< 8]' is not a type", plus a downstream cascade.
					return true
				}
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
						// C++ Reference: check_type.cpp:1468-1476 -- a bare `return;`. NOTE the
						// deliberate ASYMMETRY with the range-element arm above: THIS site has no
						// is_valid_bit_field_backing_type escape, so an integer array is rejected
						// here and accepted there. That asymmetry is C++'s and must be preserved.
						// Returning false emitted a spurious "'bit_set[E]' is not a type".
						return true
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

	// C++ Reference: check_type.cpp check_bit_field_type.
	//
	// C++ assigns the backing type FIRST, defaulting to t_u8 when the written one is unusable
	//     bit_field_type->BitField.backing_type = backing_type ? backing_type : t_u8;
	// and then `return`s (void) after reporting. The bit_field type therefore still exists and
	// the caller sees a type, so nothing cascades.
	//
	// The port returned FALSE from both arms, which made the caller add a second diagnostic --
	// "'bit_field string {a: int | 1}' is not a type" -- that C++ never emits. It also invented
	// both message texts ("bit_field requires a backing type" / "Invalid backing type '%s' for
	// bit_field, expected an integer type"). C++ uses one identical string for both arms, at
	// bft.backing_type.
	bf.backing_type = backing_type if backing_type != nil && backing_type != t_invalid else t_u8

	if backing_type == nil || backing_type == t_invalid {
		error_node(bft.backing_type, "Backing type for a bit_field must be an integer or an array of an integer")
		return true
	}

	if !is_valid_bit_field_backing_type(backing_type) {
		error_node(bft.backing_type, "Backing type for a bit_field must be an integer or an array of an integer")
		return true
	}

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
	// See the note at check_struct_type_expr: ScopeFlag_Type. C++ sets it for BitFieldType
	// too (checker.cpp:358). LEDGER 290.
	scope := create_scope(ctx.scope)
	if scope != nil {
		scope.flags += {.Type}
	}
	bft.scope = scope

	// Process each field
	// C++ lines 1041-1190
	total_bits_used: i64 = 0
	field_count := len(bft.fields)

	bf.fields = make([dynamic]^Entity, 0, field_count)
	bf.bit_sizes = make([dynamic]int, 0, field_count)
	bf.bit_offsets = make([dynamic]int, 0, field_count)
	// #904: parallel to the two above, and allocated the same way for the same reason. Lifetime
	// follows bit_sizes/bit_offsets exactly -- none of the three is individually freed, and neither
	// is Type_Struct.tags, so this adds no new teardown obligation.
	bf.tags = make([dynamic]string, 0, field_count)

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

		// C++ Reference: check_type.cpp check_bit_field_type --
		//     if (f->name == nullptr || f->name->kind != Ast_Ident) {
		//         error(field, "A bit_field's field name must be an identifier");
		//         continue;
		//     }
		// The port invented its own wording. Text aligned; the guard itself was already here.
		// UNREACHABLE FROM SOURCE, and measured so rather than assumed: `bit_field u32 { 1: int | 3 }`
		// and `{ a.b: int | 3 }` are both refused by the PARSER first, so this and its two siblings
		// ("Invalid AST for a bit_field", "A bit_field's field must have a type") are AST-INTEGRITY
		// guards, not user-facing diagnostics. No witness can exist for them, which is why msgaudit
		// reports them as missing and no corpus cell ever will.
		if field_name == "" {
			error_node(ast_field, "A bit_field's field name must be an identifier")
			continue
		}

		// Check field type
		// C++ lines 1064-1085
		// C++ tests `f->type == nullptr` BEFORE calling check_type, with the message below; the
		// port tests the RESULT of check_type instead. Kept as-is structurally -- restructuring
		// unreachable code buys nothing -- but the wording is now the reference's.
		field_type := check_type(ctx, ast_field.type)
		if field_type == nil || field_type == t_invalid {
			error_node(ast_field.type, "A bit_field's field must have a type")
			continue
		}

		// C++ Reference: check_type.cpp check_bit_field_type. THREE checks, in this order, and NONE of
		// them skips the field -- C++ reports and keeps going, so a bad field still gets an
		// entity and still contributes to the total-bit-size check below.
		//
		// The port had a single combined check that also `continue`d. That lost the <= 8 bytes
		// limit entirely (a `u128` field was accepted silently) and merged C++'s untyped and
		// wrong-kind messages into one.
		if type_size_of(field_type) > 8 {
			error_node(ast_field.type, "The type of a bit_field's field must be <= 8 bytes, got %d", type_size_of(field_type))
		}
		if is_type_untyped(field_type) {
			type_str := type_to_string(field_type)
			error_node(ast_field.type, "The type of a bit_field's field must be a typed integer, enum, or boolean, got %s", type_str)
		} else if !(is_type_integer(field_type) || is_type_enum(field_type) || is_type_boolean(field_type)) {
			type_str := type_to_string(field_type)
			error_node(ast_field.type, "The type of a bit_field's field must be an integer, enum, or boolean, got %s", type_str)
		}

		// Check bit size expression
		// C++ lines 1097-1120
		// C++ Reference: check_type.cpp check_bit_field_type.
		//
		// A MISSING bit size is an ERROR in C++ and the field is skipped. The port defaulted to
		// `8 * type_size_of(field_type)` and accepted the field -- an under-rejection.
		if ast_field.bit_size == nil {
			error_node(ast_field, "A bit_field's field must have a specified bit size")
			continue
		}

		bit_size: i64 = 0
		bit_size_op: Operand
		check_expr(ctx, &bit_size_op, ast_field.bit_size)
		if bit_size_op.mode != .Constant {
			// C++ marks the operand invalid and CARRIES ON (check_type.cpp check_bit_field_type); it does
			// not skip the field. The port used to `continue` here.
			error_node(ast_field.bit_size, "A bit_field's specified bit size must be a constant")
			bit_size_op.mode = .Invalid
		}

		// C++ Reference: check_type.cpp check_bit_field_type -- a float constant is CONVERTED, not rejected:
		//
		//     if (o.value.kind == ExactValue_Float) {
		//         o.value = exact_value_to_integer(o.value);
		//     }
		//
		// #1084: the port switched on the operand's TYPE and then rewrote the TYPE, leaving the
		// VALUE a float. C++ switches on the VALUE KIND and rewrites the VALUE. The distinction
		// matters immediately below, where the reference tests the value kind to decide whether
		// the bit size is an integer at all.
		if _, is_float_value := bit_size_op.value.(f64); is_float_value {
			bit_size_op.value = exact_value_to_integer(bit_size_op.value)
		}

		// C++ Reference: check_type.cpp check_bit_field_type. This is an ERROR, not a warning, and it fires
		// only for the `|` operator specifically. The port had an invented WARNING suggesting
		// `=`, so a program C++ rejects was accepted here.
		if be, is_binary := ast_field.bit_size.derived.(^ast.Binary_Expr); is_binary && be.op.kind == .Or {
			expr_str := expr_to_string(ast_field.bit_size)
			defer delete(expr_str)
			error_node(ast_field.bit_size, "Wrap the expression in parentheses, e.g. (%s)", expr_str)
		}

		// C++ Reference: check_type.cpp check_bit_field_type. C++ reports and FALLS
		// THROUGH -- the `if` has no `continue`, so the field still reaches the redeclaration
		// check below and, if the name is new, still gets an entity with a clamped width.
		//
		// The port `continue`d, so a field with a non-integer bit size was dropped entirely and
		// its NAME was never registered. A later field reusing that name was then not seen as a
		// duplicate, and the oracle's redeclaration error went missing:
		//     B :: bit_field u32 { a: u8 | "x", a: u8 | 3 }
		//     oracle: the non-integer bit size AND "'a' is already declared in this bit_field"
		//     port:   the non-integer bit size only
		// Probe p677f. LEDGER #677.
		// #1084: C++ TESTS THE VALUE KIND, NOT THE TYPE:
		//
		//     ExactValue bit_size = o.value;
		//     if (bit_size.kind != ExactValue_Integer) {
		//         error(f->bit_size, "Expected an integer constant value for the specified bit size, got %s", s);
		//     }
		//
		// The port asked `!is_type_integer(bit_size_op.type)`. The two disagree in BOTH
		// directions:
		//   * An ENUM constant carries ExactValue_Integer but is not is_type_integer, so C++
		//     ACCEPTS `a: u8 | E.X` and the port REJECTED it. MEASURED: oracle 0, port 1.
		//   * A non-constant `int` expression IS is_type_integer but its value kind is Invalid,
		//     so C++ emits this diagnostic in ADDITION to "must be a constant" and the port
		//     emitted only the first.
		// Testing the value kind reproduces both.
		if _, is_int_value := bit_size_op.value.(big.Int); !is_int_value {
			val_str := expr_to_string(ast_field.bit_size)
			defer delete(val_str)
			error_node(ast_field.bit_size, "Expected an integer constant value for the specified bit size, got %s", val_str)
		}

		// Check for duplicate field names -- HERE, after the type and bit-size validation.
		//
		// C++ Reference: check_type.cpp check_bit_field_type:
		//     if (scope_lookup_current(ctx->scope, interned) != nullptr) {
		//         error(f->name, "'%.*s' is already declared in this bit_field", LIT(name));
		//     } else { ...clamps, alloc_entity_field, bit_sizes, total_bit_size... }
		// So a duplicate skips ONLY the clamps and the entity -- everything above it has already
		// run and already reported.
		//
		// The port ran this check FIRST, before `check_type` on the field, and `continue`d. Every
		// diagnostic C++ produces for a duplicated field was therefore lost:
		//     B :: bit_field u32 { a: u8 | 3, a: string | 4 }
		//     oracle: redeclaration AND "The type of a bit_field's field must be <= 8 bytes, got 16"
		//     port:   redeclaration only
		// Probe p677a. The bit-size CLAMPS must stay below this point, not above it: probe p677b
		// (`a: u8 | 99` on the duplicate) shows the oracle emits NO "cannot exceed 64 bits" for a
		// duplicated field, because that check lives in C++'s `else`. LEDGER #677.
		if field_name in bf.names {
			error_node(ast_field.name, "'%s' is already declared in this bit_field", field_name)
			continue
		}

		bit_size = exact_value_to_i64(bit_size_op.value)

		// C++ Reference: check_type.cpp check_bit_field_type. THREE bounds, each of which CLAMPS and
		// carries on -- C++ never skips the field here, so the entity is still created and the
		// clamped width still counts toward the total below. The port `continue`d on each,
		// leaving the bit_field short a field and changing every downstream cascade. It also
		// had no >64 bound at all, so a 65-bit field on a wide backing type was accepted.
		if bit_size <= 0 {
			error_node(ast_field.bit_size, "A bit_field's specified bit size cannot be <= 0, got %d", bit_size)
			bit_size = 1
		}
		if bit_size > 64 {
			error_node(ast_field.bit_size, "A bit_field's specified bit size cannot exceed 64 bits, got %d", bit_size)
			bit_size = 64
		}
		field_max_bits := i64(8 * type_size_of(field_type))
		if bit_size > field_max_bits {
			error_node(ast_field.bit_size, "A bit_field's specified bit size cannot exceed its type, got %d, expect <=%d", bit_size, field_max_bits)
			bit_size = field_max_bits
		}

		// NOTE: the per-field "exceeds backing type capacity" check that used to sit here was
		// INVENTED. Its comment cited "C++ lines 1147-1155"; that range (src/check_type.cpp)
		// contains the entity construction, not a capacity check. C++ compares the TOTAL once,
		// after the loop, against the bit_field node -- see below.

		// Create entity for field
		//
		// C++ Reference: check_type.cpp check_bit_field_type -
		//	Entity *e = alloc_entity_field(ctx->scope, ..., type, false, field_src_index);
		//	e->flags |= EntityFlag_BitFieldField;
		//
		// The port used alloc_entity_VARIABLE and added only .Bit_Field_Field, so the entity
		// never carried .Field. lookup_field_with_selection's bit_field arm (types.odin:3160)
		// skips any entity without it - `if .Field not_in field.flags { continue }`, which is
		// C++'s own guard - so EVERY bit_field member lookup failed, by value and through a
		// pointer alike. core/mem's Rollback_Stack_Header accounts for 294 of the class.
		field_entity := alloc_entity_field(scope, field_token, field_type, false, i32(bit_field_index))
		// C++ Reference: check_type.cpp check_bit_field_type, immediately before the flag:
		//     e->Variable.bit_field_bit_size = bit_size_u8;
		//
		// THIS ASSIGNMENT WAS ABSENT, and it is the only writer of the field in the whole
		// checker. `Entity_Variable.bit_field_bit_size` was declared (ast/semantic_types.odin)
		// and READ in three places -- check_stmt's assignment path, check_compound_lit's field
		// init, and dump_model -- all of which therefore saw a permanent zero. Every one of
		// those readers guards on `!= 0`, so the entire bit-field width machinery was dead:
		// ctx.bit_field_bit_size never became non-zero, and a constant was only ever range
		// checked against the BACKING type. `B :: bit_field u8 { a: u8 | 3 }; B{a = 255}` was
		// accepted, storing 255 in three bits.
		//
		// The clamps above have already forced bit_size into 1..=64 and within the field type,
		// which is what makes the u8 narrowing safe -- same order as the reference.
		(&field_entity.variant.(Entity_Variable)).bit_field_bit_size = u8(bit_size)
		field_entity.flags += {.Bit_Field_Field}

		// Add to scope
		scope_insert(scope, field_entity)

		// Add to type
		append(&bf.fields, field_entity)
		bf.names[field_name] = field_entity
		append(&bf.bit_sizes, int(bit_size))
		append(&bf.bit_offsets, int(total_bits_used))

		// C++ Reference: check_type.cpp check_bit_field_type --
		//     String tag = f->tag.string;
		//     if (tag.len != 0 && !unquote_string(permanent_allocator(), &tag, 0, tag.text[0] == '`')) {
		//         error(f->tag, "Invalid string literal");
		//         tag = {};
		//     }
		//     array_add(&tags, tag);
		//
		// #904: this whole step was MISSING -- the tag was parsed and dropped on the floor. An
		// entry is appended for EVERY field, tagged or not, because the array is POSITIONAL and a
		// consumer reads tags[i] for fields[i]. The `ok` flag is discarded for the same reason as
		// the struct arm: the tokenizer validates string literals before the checker sees them, so
		// C++'s error looks unreachable from a well-formed token and is not reproduced on
		// speculation (#899).
		bf_tag := ast_field.tag.text
		if len(bf_tag) != 0 {
			unquoted_bf_tag, _ := unquote_string(bf_tag, bf_tag[0] == '`')
			bf_tag = unquoted_bf_tag
		}
		append(&bf.tags, bf_tag)

		total_bits_used += bit_size
	}

	// C++ Reference: check_type.cpp check_bit_field_type. ONE check, after every field has been processed,
	// reported against the bit_field NODE and naming the total rather than the field that
	// happened to tip it over.
	if total_bits_used > backing_bits {
		backing_str := type_to_string(backing_type)
		error_node(bft, "The total bit size of a bit_field's fields (%d) must fit into its backing type's (%s) bit size of %d", total_bits_used, backing_str, backing_bits)
	}

	// ENDIANNESS. C++ Reference: check_type.cpp check_bit_field_type.
	//
	// This runs AFTER the field loop, over the ENTITIES collected by it, and it has TWO
	// diagnostics -- one comparing each field against the backing type, one comparing each field
	// against the first field's kind. Both anchor at the field's TOKEN (its name).
	//
	// The port had a per-field block instead, with an INVENTED message ("bit_field field has %s
	// endianness but backing type has %s endianness" appears nowhere in src/), no counterpart to
	// C++'s second diagnostic, none of the guards, and a `continue` that suppressed the rest of
	// the field's own checks. It also gated the whole thing on the backing type being explicitly
	// endian-specific, so `bit_field u32 { a: u16le|5, b: u16be|5 }` -- which the oracle rejects
	// twice -- produced NOTHING. Probes p678a/b/d. LEDGER #678.
	//
	// determine_endian_kind (C++): booleans are Unknown ("it doesn't matter, and when
	// it does, that api is absolutely stupid"), anything smaller than 2 bytes is Unknown, an
	// endian-specific type is Little or Big, everything else is Native.
	Endian_Kind :: enum u8 {
		Unknown, // C++'s Endian_Unknown -- the ZERO enumerator, which its `if (field_kind)` tests
		Native,
		Little,
		Big,
	}
	determine_endian_kind :: proc(t: ^Type) -> Endian_Kind {
		if is_type_boolean(t) {
			return .Unknown
		}
		if type_size_of(t) < 2 {
			return .Unknown
		}
		if is_type_endian_specific(t) {
			return is_type_endian_little(t) ? .Little : .Big
		}
		return .Native
	}

	backing_type_elem := core_array_type(backing_type)
	backing_type_elem_size := i64(type_size_of(backing_type_elem))
	backing_type_endian_kind := determine_endian_kind(backing_type_elem)
	endian_kind := Endian_Kind.Unknown
	for f in bf.fields {
		field_kind := determine_endian_kind(entity_type(f))
		field_size := i64(type_size_of(entity_type(f)))

		// C++ tests `field_kind` for truthiness, and Endian_Unknown is the zero enumerator, so
		// an Unknown field takes neither branch.
		if field_kind != .Unknown && backing_type_endian_kind != field_kind && field_size > 1 && backing_type_elem_size > 1 {
			error_token(f.token, "All 'bit_field' field types must match the same endian kind as the backing type, i.e. all native, all little, or all big")
		}

		if endian_kind == .Unknown {
			endian_kind = field_kind
		} else if field_kind != .Unknown && endian_kind != field_kind && field_size > 1 {
			error_token(f.token, "All 'bit_field' field types must be of the same endian variety, i.e. all native, all little, or all big")
		}
	}

	return true
}

// check_matrix_type_expr creates and validates a matrix type
// C++ Reference: check_type.cpp:3093-3160 (check_matrix_type, ~68 lines)
check_matrix_type_expr :: proc(ctx: ^Checker_Context, mt: ^ast.Matrix_Type, type: ^^Type, named_type: ^Type) -> bool {
	// C++ Reference: types.cpp:402-403 - MIN = 1, MAX = 64.
	// NOTE: MAX applies to the TOTAL element count (row*column), not to each dimension.
	// C++ check_type.cpp check_matrix_type checks only a MINIMUM per dimension and then bounds
	// row_count*column_count by MAX. The port previously capped each dimension at 16 and
	// the total at 16, rejecting valid types such as matrix[8, 8]T.
	// NOTE: both constants are now declared at PACKAGE scope (see the top of this file) rather
	// than locally. C++ has them as globals and, as of merge ebac23eb0, check_expr.cpp's
	// check_binary_matrix references MATRIX_ELEMENT_COUNT_MAX too -- a local would not be
	// visible there. LEDGER #798.

	// Create the matrix type
	matrix_type := alloc_type(Type_Matrix)
	mat := &matrix_type.variant.(Type_Matrix)
	mat.node = mt

	// NOTE: this publishes a still-ZEROED matrix type (elem=nil, row_count=0, column_count=0) to the
	// caller before any validation has run, so every error path below MUST overwrite it with
	// t_invalid. C++ avoids the problem structurally: check_type.cpp:3093-3158 validates everything
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
	// C++ Reference: check_type.cpp check_matrix_type -- `Type *elem = check_type_expr(ctx, mt->elem, nullptr)`.
	//
	// #1073: THE CALL WAS `check_type`, WHILE THE COMMENT ON THE LINE ABOVE QUOTED C++ CORRECTLY
	// AS check_type_expr. Third instance of comment-right/code-wrong (cf. #1070's builtin
	// prologue, and the matrix element ordering note further down this same procedure).
	//
	// The two differ in ONE respect that matters here: check_type installs a FRESH
	// checker_type_path (check_type.odin, and C++ check_type.cpp check_type), whereas
	// check_type_expr inherits the caller's. The type path IS the declaration-cycle detector, so
	// starting a new one means a cycle running through a matrix element is never seen.
	//
	// MEASURED: `A :: struct { m: matrix[2, 2]A }`
	//     oracle  exit 1, "Illegal declaration cycle"
	//     port    exit 139 -- SIGSEGV, recursion to stack exhaustion
	// A crash is never the contract, so this is a fix regardless of tier.
	elem := check_type_expr(ctx, mt.elem, nil)

	// #1095: AN INVENTED BAIL WAS DELETED HERE:
	//
	//     if elem == nil || elem == t_invalid {
	//         error_node(mt.elem, "Invalid element type for matrix")
	//         type^ = t_invalid; set_base_type(named_type, t_invalid); return false
	//     }
	//
	// `grep -rn "Invalid element type for matrix" src/` returns NOTHING. C++'s check_matrix_type
	// has NO nil/invalid test on the element at all: it runs check_type_expr, then the
	// is_type_valid_for_matrix_elems check further down (which the port already has, with the
	// t_typeid escape hatch), and then ALWAYS assigns via alloc_type_matrix — a t_invalid element
	// included.
	//
	// The bail did three wrong things at once: emitted a message the reference never emits,
	// SUPPRESSED the diagnostics C++ produces after it, and returned false, which made
	// check_type_expr add a cascading "'<expr>' is not a type".
	// MEASURED, both cells textdiff-only (verdicts agreed, so the verdict corpus saw nothing):
	//     `M :: matrix[x, y]Undefined`
	//         oracle: "Undeclared name: x" + "Undeclared name: y"
	//         port:   "'matrix[x, y]Undefined' is not a type"   (both count errors LOST)
	//     `A :: struct { m: matrix[2, 2]A }`  (the #1073 cycle cell)
	//         oracle line 2: "Matrix elements types are limited to integers, floats, and
	//                         complex, got invalid type"
	// Nothing downstream needs a non-nil elem here: the assignment below mirrors C++'s
	// alloc_type_matrix, which stores whatever check_type_expr returned.

	mat.elem = elem

	// C++ Reference: check_type.cpp check_matrix_type. BOTH counts are computed first, through
	// check_array_count, and only then are the generic tests and the range checks run.
	//
	// check_array_count OWNS every count diagnostic: "Array count must be a constant integer,
	// got %s", the `[?]` form, "Invalid negative array count", "Array count too large", and the
	// polymorphic-specialization error. The port instead hand-rolled a mode dispatch here with
	// two INVENTED messages ("matrix row count must be an integer" / "... must be a constant
	// integer or polymorphic type parameter") and, worse, RETURNED on either. So for
	// `matrix[x, y]f32` with non-constant x and y the port emitted one invented error for the
	// row, never looked at the column at all, and added a spurious "'matrix[x, y]f32' is not a
	// type" from the invalidation -- against the oracle's two "Array count must be a constant
	// integer, got x/y". LEDGER #165.
	//
	// The range checks below still run on the failed counts (check_array_count returns 0), but
	// C++ suppresses their output via the same-position merge: "Invalid matrix row count ...
	// got x" anchors at the same expression as "Array count must be a constant integer, got x".
	// That is the merge ported in LEDGER #219, so it needs no special-casing here.
	row_op: Operand
	col_op: Operand
	row_count := check_array_count(ctx, &row_op, mt.row_count)
	column_count := check_array_count(ctx, &col_op, mt.column_count)

	generic_row: ^Type = nil
	generic_column: ^Type = nil

	// C++ Reference: check_type.cpp check_matrix_type tests `mode == Addressing_Type && type->kind ==
	// Type_Generic` DIRECTLY -- not through base_type and not through a broader
	// is_type_polymorphic, which is what the port used and which accepts more than C++ does.
	if row_op.mode == .Type && row_op.type != nil && row_op.type.kind == .Generic {
		generic_row = row_op.type
	}
	if col_op.mode == .Type && col_op.type != nil && col_op.type.kind == .Generic {
		generic_column = col_op.type
	}

	// C++ Reference: check_type.cpp check_matrix_type -- minimum only; the maximum is enforced on the
	// total below. C++ reports and CARRIES ON: it does not invalidate the type and does not skip
	// the column check. Both branches print the SOURCE EXPRESSION via expr_to_string(row.expr),
	// not the evaluated count -- identical for `matrix[0,2]f32` and WRONG for `matrix[ROWS,2]f32`,
	// where C++ says "got ROWS". Probe mxc1.
	if generic_row == nil && row_count < MATRIX_ELEMENT_COUNT_MIN {
		if mt.row_count == nil {
			error_node(mt, "Invalid matrix row count, got nothing")
		} else {
			rc_str := expr_to_string(mt.row_count)
			defer delete(rc_str)
			error_node(mt.row_count, "Invalid matrix row count, expected %d+ rows, got %s", MATRIX_ELEMENT_COUNT_MIN, rc_str)
		}
	}

	// C++ Reference: check_type.cpp check_matrix_type, same two branches and the same expr_to_string.
	// NOTE(parity) -- RESOLVED, kept only as history. C++ once said "rows" in the COLUMN message
	// (a copy-paste slip), the port reproduced it for parity, and it was reported as #189. Upstream
	// FIXED it and the port followed: src/ now reads "expected %d+ columns" and so does the emit
	// site below. Do NOT re-introduce "rows". Probe mxc2.
	if generic_column == nil && column_count < MATRIX_ELEMENT_COUNT_MIN {
		if mt.column_count == nil {
			error_node(mt, "Invalid matrix column count, got nothing")
		} else {
			cc_str := expr_to_string(mt.column_count)
			defer delete(cc_str)
			// "columns", not "rows". The port faithfully reproduced C++'s copy-paste slip here
			// (check_type.cpp check_matrix_type said "rows" in the COLUMN branch), which was correct parity at
			// the time and is now stale: the slip was reported as #189, fixed upstream, and merged.
			// The reference now reads "expected %d+ columns". LEDGER #385.
			error_node(mt.column_count, "Invalid matrix column count, expected %d+ columns, got %s", MATRIX_ELEMENT_COUNT_MIN, cc_str)
		}
	}

	mat.row_count = row_count
	mat.generic_row_count = generic_row
	mat.column_count = column_count
	mat.generic_column_count = generic_column
	// C++ Reference: check_type.cpp check_matrix_type passes mt->is_row_major to alloc_type_matrix.
	mat.is_row_major = mt.is_row_major

	// C++ Reference: check_type.cpp check_matrix_type.
	// Validate total element count (row * column)
	// C++ check_type.cpp check_matrix_type - the single maximum, applied to row*column.
	if generic_row == nil && generic_column == nil {
		// C++ Reference: check_type.cpp check_matrix_type (merge ebac23eb0). Upstream
		// rewrote this guard to be OVERFLOW-SAFE and split the message in two. Its own comment:
		//   "row_count*column_count can overflow and wrap back under the limit, so test the
		//    dimensions first; each is at least MATRIX_ELEMENT_COUNT_MIN. Either one exceeding
		//    the maximum means the product does too"
		// The port tested only the product, so a pair of dimensions whose product wrapped negative
		// (or back under the cap) passed the guard entirely. LEDGER #798.
		// The product is INLINE, not hoisted: `||` short-circuits, so `row_count*column_count` is
		// only evaluated once both dimensions are known to be within range -- which is precisely
		// what makes it safe to multiply. Hoisting it above the guard would reintroduce the
		// overflow this change exists to prevent.
		if row_count > MATRIX_ELEMENT_COUNT_MAX || column_count > MATRIX_ELEMENT_COUNT_MAX || row_count*column_count > MATRIX_ELEMENT_COUNT_MAX {
			// C++ Reference: check_type.cpp check_matrix_type --
			//     error(node, "Matrix types are limited to a maximum of %d elements, got %lld", ...)
			// The anchor is the MATRIX TYPE NODE, not the column-count expression. `matrix[9, 9]f32`
			// puts the oracle at 2:6 (the `matrix` keyword); the port sat at 2:16 (the second 9).
			//
			// The comment that used to stand here asserted the opposite and cited it as settled --
			// it was wrong against the C++ line it names, and nothing pinned it (there is no m88
			// corpus member). Probes p676e/p676f. LEDGER #676, INSTRUMENT-MISREPORT #49.
			// C++ Reference: check_type.cpp:3141-3146 (merge ebac23eb0). TWO forms now, and the
			// choice is whether the product is printable without overflowing. Upstream's comment:
			//   "the element count is only printable when the multiply cannot overflow, which is
			//    exactly the case the dimension test above catches"
			// Both forms name the dimensions; only the safe one appends the product.
			if row_count != 0 && column_count > max(i64) / row_count {
				error_node(&mt.node, "Matrix types are limited to a maximum of %d elements, got %d by %d", MATRIX_ELEMENT_COUNT_MAX, row_count, column_count)
			} else {
				error_node(&mt.node, "Matrix types are limited to a maximum of %d elements, got %d by %d (%d elements)", MATRIX_ELEMENT_COUNT_MAX, row_count, column_count, row_count*column_count)
			}
			// C++ REPORTS AND CONTINUES -- check_type.cpp check_matrix_type is a bare
			// `if { error(); }` with no bail, and the matrix type is built normally afterwards.
			// The port's `type^ = t_invalid; set_base_type(...); return false` was invented, and it
			// cost a second diagnostic: the caller then reported "'matrix[9, 9]f32' is not a type".
			// LEDGER #372.
		}
	}

	// Validate the element type -- AFTER the counts, where C++ does it.
	//
	// C++ Reference: check_type.cpp check_matrix_type. C++ resolves the element type and runs
	// is_type_valid_for_matrix_elems AFTER all three count diagnostics (row minimum, column
	// minimum, total maximum). It reports and CONTINUES,
	// falling through to `type_assign:` and allocating the matrix regardless.
	//
	// The port ran this block FIRST, before the counts. That is not cosmetic, because this error
	// and the column-count errors share an anchor (`mt.column_count`), and print_all_errors MERGES
	// diagnostics at the same position keeping the FIRST emitted (LEDGER #578). Running early made
	// the element error win and SUPPRESSED the genuine count diagnostic:
	//     matrix[0, 0]string   oracle: row count + COLUMN COUNT | port: row count + element type
	//     matrix[x, x]string   oracle: two "Array count must be a constant integer"
	//                          port:   one, plus the element error at the column position
	// Probes p676a / p676d. LEDGER #676.
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
			// C++ Reference: check_type.cpp check_matrix_type -- `error(column.expr, ...)`.
			// C++ reports this at the COLUMN COUNT expression, not at the element type, which is
			// surprising but is what the oracle does: for `matrix[2,2]string` it points at the
			// second `2`, where the port once pointed at `string`.
			error_node(mt.column_count, "Matrix elements types are limited to integers, floats, and complex, got %s", type_str)
		}
	}

	// #1078: AN EAGER STRIDE ASSIGNMENT WAS DELETED HERE:
	//
	//     elem_size := type_size_of(elem)
	//     mat.stride_in_bytes = int(row_count) * elem_size
	//
	// and the comment sitting directly above it already said "C++ doesn't calculate this here"
	// — the fourth comment-right/code-wrong in this campaign (cf. #1070, #1072, #1073).
	//
	// C++ Reference: types.cpp alloc_type_matrix sets elem, row_count, column_count,
	// is_row_major and RETURNS — stride_in_bytes is left ZERO and computed lazily by
	// matrix_type_stride_in_bytes (types.cpp), which branches on is_row_major:
	//     if (is_row_major) stride = elem_size*column_count; else stride = elem_size*row_count;
	//
	// The port's own matrix_type_stride_in_bytes (types.odin) has that branch and is CORRECT —
	// but it returns the cached field first when non-zero, so this eager value, which ignores
	// is_row_major entirely, always won. Every #row_major matrix therefore had the wrong stride
	// and, through type_size_of, the wrong SIZE.
	// MEASURED: `M :: #row_major matrix[2, 3]f32` — size_of(M) is 24 on the oracle, 16 here.
	//
	// Leaving the field at zero is what makes the lazy path run, which is exactly C++'s design.

	return true
}

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

// check_map_type_expr checks a `map[K]V` type expression
// C++ Reference: check_type.cpp check_map_type
// (This header was STRANDED 44 lines above its own procedure -- #730. The whole of
//  check_fixed_capacity_dynamic_array_type had been inserted between the doc comment
//  and the definition it documents, so a top-down reader met this text as if it
//  described the FCDA procedure, and citefn.proc_by_line scoped its citation there too.)
check_map_type_expr :: proc(ctx: ^Checker_Context, mt: ^ast.Map_Type, type: ^^Type, named_type: ^Type) -> bool {
	// C++ Reference: check_type.cpp check_map_type
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

	// C++ Reference: check_type.cpp check_map_type.
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
	// C++ Reference: check_type.cpp check_map_type
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

	// C++ Reference: check_type.cpp check_map_type
	type^ = make_map_type(key, value)
	set_base_type(named_type, type^)

	// C++ Reference: check_type.cpp check_map_type
	add_map_key_type_dependencies(ctx, key)

	// C++ Reference: check_type.cpp check_map_type. Both calls were missing. init_core_map_type is
	// what populates t_map_info / t_map_cell_info / t_raw_map (and, via init_mem_allocator,
	// t_allocator, which init_map_internal_types asserts on).
	init_core_map_type(ctx.checker)

	// NOTE: C++ can call init_map_internal_types unconditionally because the compiler always has
	// base:runtime loaded, so init_core_map_type -> init_mem_allocator always sets t_allocator.
	// This port is also used as a library on package sets that never load base:runtime, where
	// find_core_type returns nil and init_mem_allocator returns early by design (see its comment).
	// In that case t_allocator stays nil and init_map_internal_types' assert would fire, so gate on
	// the precondition C++ gets for free rather than on a weakened assert.
	if ctx.checker.t_allocator != nil {
		init_map_internal_types(ctx.checker, type^)
	}

	// C++ Reference: check_type.cpp check_map_type
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
			// C++ Reference: check_type.cpp check_procedure_type (`if (c->foreign_context.default_cc > 0)`,
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
			// C++ Reference: check_type.cpp check_procedure_type
			error(proc_type_node, "A procedure type with the #optional_ok tag requires 2 return values, got %d", result_count)
		} else if results != nil && results.kind == .Tuple {
			// Check that second return is boolean
			tuple := results.variant.(Type_Tuple)
			if len(tuple.variables) >= 2 {
				second := tuple.variables[1]
				second_type := entity_type(second)
				if !is_type_polymorphic(second_type) && !is_type_boolean(second_type) {
					// NOTE: type_to_string's result is NOT deleted here, matching the other 37
					// call sites in this file. Deleting one is what caused the crash retracted
					// in #142 -- do not "fix" this as a leak without settling ownership first.
					type_str := type_to_string(second_type)
					// C++ Reference: check_type.cpp check_procedure_type. THE ANCHOR IS THE
					// SECOND RETURN VALUE, not the procedure type: C++ raises this through
					// `error(second->token, ...)`. The port used error_node(proc_type_node, ...),
					// which reports the whole `proc(...) -> (T, U)` instead of the offending `U`.
					// Contrast the #optional_allocator_error arm below, where C++ genuinely DOES
					// anchor on proc_type_node -- the two arms differ deliberately, so
					// neither can be inferred from the other.
					error(second.token, "Second return value of an #optional_ok procedure must be a boolean, got %s", type_str)
				}
			}
		}
	}

	// Check #optional_allocator_error attribute
	if .Optional_Allocator_Error in proc_type_node.tags {
		if optional_ok {
			// C++ Reference: check_type.cpp check_procedure_type
			error(proc_type_node, "A procedure type cannot have both an #optional_ok tag and #optional_allocator_error")
		}
		optional_ok = true

		if result_count != 2 {
			// C++ Reference: check_type.cpp check_procedure_type
			error(proc_type_node, "A procedure type with the #optional_allocator_error tag requires 2 return values, got %d", result_count)
		} else if results != nil && results.kind == .Tuple {
			// Check that second return is runtime.Allocator_Error
			init_mem_allocator(c.checker)
			tuple := results.variant.(Type_Tuple)
			if len(tuple.variables) >= 2 {
				second := tuple.variables[1]
				second_type := entity_type(second)
				if !are_types_identical(second_type, ctx.checker.t_allocator_error) {
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
	// Set the c_vararg flag. The two DIAGNOSTICS that used to be emitted here are gone:
	//
	//   - "Calling convention does not support #c_vararg" duplicated the C++-faithful check
	//     further down this same function (the parameter loop, matching check_type.cpp check_procedure_type-
	//     2756), which reports against the PARAMETER's token. This one reported against the
	//     whole proc type, so a rejected #c_vararg produced TWO errors at two positions where
	//     C++ produces one.
	//   - "#c_vararg can only be applied to variadic procedures" has no C++ counterpart at
	//     all. C++'s only other #c_vararg message is "can only be applied to the last
	//     parameter", which the parameter loop already emits.
	//
	// The flag assignment stays; only the reporting moves to the single faithful site.
	if c_vararg {
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
// Reference: check_type.cpp:1573-1617
// Takes a polymorphic type (e.g., []$T) and an operand (e.g., []int{1,2,3})
// and determines what concrete type the polymorphic parameter should be (e.g., int)
determine_type_from_polymorphic :: proc(ctx: ^Checker_Context, poly_type: ^Type, operand: Operand) -> ^Type {
	// C++ line 1574-1575: Check modification permissions
	modify_type := !ctx.no_polymorphic_errors
	show_error := modify_type && !ctx.hide_polymorphic_errors

	// C++ line 1576-1585: Validate operand is a value
	if !is_operand_value(operand) {
		if show_error {
			// C++ Reference: check_type.cpp determine_type_from_polymorphic and its sibling — both build the strings with
			// type_to_string(..., true) first. Passing a ^Type straight to %v printed the whole
			// Type struct, addresses and all, instead of a type name.
			// NOTE: do NOT free these. type_to_string returns string literals or
			// temp-allocator storage; only expr_to_string is caller-owned. Freeing a
			// literal here segfaulted every package that reached this diagnostic.
			ots := type_to_string(operand.type)
			pts := type_to_string(poly_type)
			begin_error_block()
			error(operand.expr, "Cannot determine polymorphic type from parameter: '%s' to '%s'", ots, pts)
			// C++ check_type.cpp determine_type_from_polymorphic follows with a Suggestion, gated on the operand being
			// a TYPE rather than a value -- `f(int)` where `f :: proc(x: $T)`. The port emitted the
			// error and never the Suggestion. The gate matters: passing a mistyped VALUE gets the
			// error alone, and an unconditional Suggestion would misdiagnose that case.
			if operand.mode == .Type {
				error_line("\tSuggestion: Are you trying to pass a type to a value parameter?\n")
			}
			end_error_block()
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
		// C++ Reference: check_type.cpp determine_type_from_polymorphic and its sibling — both build the strings with
		// type_to_string(..., true) first. Passing a ^Type straight to %v printed the whole
		// Type struct, addresses and all, instead of a type name.
		// NOTE: do NOT free these — see the note at the other call site.
		// C++ Reference: check_type.cpp determine_type_from_polymorphic opens an ERROR_BLOCK before this error so the
		// suggestions below stay attached to it; the port had none, and the suggestion
		// escaped to stderr ahead of its own diagnostic.
		begin_error_block()
		defer end_error_block()

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

		// C++ Reference: check_type.cpp determine_type_from_polymorphic. THREE branches, and the port had one
		// merged approximation of the middle one: no expression name, an invented " or use a
		// slice literal" tail, and no trailing newline. The compound-literal and pointer arms
		// were absent entirely.
		if is_type_slice(pt) && (is_type_dynamic_array(operand.type) || is_type_array(operand.type)) {
			expr := unparen_expr(operand.expr)
			if _, is_cl := expr.derived.(^ast.Comp_Lit); is_cl {
				es := type_to_string(base_any_array_type(operand.type))
				// LEDGER 346: braces escaped for Odin's fmt. C++ Reference: src/check_type.cpp determine_type_from_polymorphic
				error_line("\tSuggestion: Try using a slice compound literal instead '[]%s{{...}}'\n", es)
			} else {
				os := expr_to_string(operand.expr)
				error_line("\tSuggestion: Try slicing the value with '%s[:]'\n", os)
			}
		} else if is_type_pointer(poly_type) {
			if is_polymorphic_type_assignable(ctx, type_deref(poly_type), operand.type, false, false) {
				os := expr_to_string(operand.expr)
				error_line("\tSuggestion: Did you mean '&%s'?\n", os)
			}
		}
	}

	return t_invalid
}

// is_caller_expression checks if an expression is a caller expression directive
// Reference: check_type.cpp:1637-1655
// is_expr_from_a_parameter reports whether an expression is rooted in a procedure parameter.
// C++ Reference: check_type.cpp is_expr_from_a_parameter:
//
//     if (expr == nullptr) { return false; }
//     expr = unparen_expr(expr);
//     if (expr->kind == Ast_SelectorExpr) {
//         Ast *lhs = expr->SelectorExpr.expr;
//         return is_expr_from_a_parameter(ctx, lhs);
//     } else if (expr->kind == Ast_Ident) {
//         Operand x = {};
//         Entity *e = check_ident(ctx, &x, expr, nullptr, nullptr, true);
//         GB_ASSERT(e != nullptr);
//         if (e->flags & EntityFlag_Param) { return true; }
//     }
//     return false;
//
// #1085: absent from the port, so handle_parameter_value's second rejection was unreachable.
// The recursion is the point: `a.x.y` walks left to `a` and asks whether THAT is a parameter,
// because the selector itself resolves to a struct FIELD entity which carries no .Param flag.
// C++ asserts the entity is non-null; a nil here is treated as "not a parameter" rather than
// aborting, since a crash is never the contract.
is_expr_from_a_parameter :: proc(ctx: ^Checker_Context, expr: ^ast.Node) -> bool {
	if expr == nil {
		return false
	}
	e := unparen_expr(expr)
	#partial switch v in e.derived {
	case ^ast.Selector_Expr:
		return is_expr_from_a_parameter(ctx, v.expr)
	case ^ast.Ident:
		x: Operand
		entity := check_ident(ctx, &x, e, nil, nil, true)
		if entity != nil && .Param in entity.flags {
			return true
		}
	}
	return false
}

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
// Reference: check_type.cpp:1657-1763
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
				// The GLOBAL, and no guard: C++ (check_type.cpp handle_parameter_value) assigns
				// t_source_code_location unconditionally. See the #location arm in
				// check_builtin.odin for why the cached_ read was wrong. LEDGER #354.
				param_value.kind = .Location
				o.type = ctx.checker.t_source_code_location
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
	// Reference: check_type.cpp:1677-1689
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

	// Check the default value expression.
	//
	// C++ Reference: check_type.cpp handle_parameter_value, transcribed exactly:
	//     expr = unparen_expr(expr);
	//     if (expr && expr->kind == Ast_Uninit) { error(expr, "Default parameter cannot be ---"); }
	//     else if (in_type) { check_expr_with_type_hint(...); }
	//     else              { check_expr(...); }
	//     if (in_type) { check_assignment(ctx, &o, in_type, str_lit("parameter value")); }
	//
	// THE `---` BRANCH LIVES HERE, NOT AT THE Undef ARM OF check_expr. It short-circuits, so a
	// default parameter never reaches that arm -- which is what lets that arm carry the GLOBAL
	// message. The port had no branch here at all and fell through to check_expr, so one shared
	// site served both callers and a package-level `y: int = ---` was told it was a "default
	// parameter". LEDGER #804.
	//
	// `check_assignment` is deliberately a SEPARATE `if in_type != nil` AFTER the three-way, not
	// nested in the middle branch: C++ still calls it on the `---` path, with `o` left in its
	// zero state (mode .Invalid), where check_assignment returns early. Reproduced as-is.
	// RENAMED, not assigned and not shadowed. C++ writes `expr = unparen_expr(expr)`, and every
	// LATER use in the function sees the unparenthesised node. Odin forbids assigning to a
	// parameter, and `-vet` forbids shadowing one, so the unparenthesised value gets its own name
	// and EVERY subsequent reference below uses it -- that is what reproduces C++'s reach. Using
	// the raw `expr` past this point would silently diverge for any parenthesised default, e.g.
	// `x: int = (---)`.
	pexpr := unparen_expr(expr)
	if _, is_undef := pexpr.derived.(^ast.Undef); pexpr != nil && is_undef {
		error(pexpr, "Default parameter cannot be ---")
	} else if in_type != nil {
		check_expr_with_type_hint(ctx, &o, pexpr, in_type)
	} else {
		check_expr(ctx, &o, pexpr)
	}
	if in_type != nil {
		check_assignment(ctx, &o, in_type, "parameter value")
	}

	// Determine parameter value kind based on the operand
	// Reference: check_type.cpp:1702-1751
	if is_operand_nil(o) {
		param_value.kind = .Nil
	} else if o.mode != .Constant {
		// Non-constant operand - check for special cases
		// Reference: check_type.cpp:1704-1740

		// Handle procedure literals as default parameters
		// C++ Reference: check_type.cpp:1705-1707
		if _, is_proc_lit := pexpr.derived.(^ast.Proc_Lit); is_proc_lit {
			param_value.kind = .Constant
			param_value.value = exact_value_procedure(cast(^ast.Expr)pexpr)
		} else {
			entity := entity_of_node(ctx.info, o.expr)
			if entity != nil {
				if entity.kind == .Procedure {
					// Procedure as default parameter
					// C++ Reference: check_type.cpp handle_parameter_value.
					param_value.kind = .Constant
					param_value.value = exact_value_procedure(cast(^ast.Expr)entity.identifier)
					// Record the entity itself, not just its identifier expression. Added
					// upstream alongside the removal of the polymorphic-default
					// short-circuit; see Parameter_Value.proc_entity. LEDGER #386.
					param_value.proc_entity = entity
				} else if .Param in entity.flags {
					// Cannot use another parameter as default
					error(pexpr, "Default parameter cannot be another parameter")
				} else if is_expr_from_a_parameter(ctx, pexpr) {
					// #1085. C++ Reference: check_type.cpp handle_parameter_value — the else of
					// the EntityFlag_Param test is NOT the value branch; it is a SECOND test:
					//
					//     if (e->flags & EntityFlag_Param) {
					//         error(expr, "Default parameter cannot be another parameter");
					//     } else {
					//         if (is_expr_from_a_parameter(ctx, expr)) {
					//             error(expr, "Default parameter cannot be another parameter");
					//         } else {
					//             param_value.kind = ParameterValue_Value; ...
					//         }
					//     }
					//
					// The first test catches a BARE parameter reference; this one catches a
					// parameter reached through selectors, which resolves to a FIELD entity (no
					// .Param flag) even though its base is a parameter.
					// MEASURED: `f :: proc(a: Foo, b: int = a.x)` — oracle 1, port 0.
					error(pexpr, "Default parameter cannot be another parameter")
				} else {
					// Store as runtime value (for global variables, etc.)
					param_value.kind = .Value
					param_value.ast_value = cast(^ast.Expr)pexpr
				}
			} else if allow_caller_location && o.mode == .Context {
				// C++ Reference: check_type.cpp handle_parameter_value.
				//     } else if (allow_caller_location && o.mode == Addressing_Context) {
				//         param_value.kind = ParameterValue_Value;
				//         param_value.ast_value = expr;
				//     }
				//
				// `proc(ctx := context)` is legal, and core uses it -- vendor/libc-shim's
				// set_context is exactly this shape. `context` is not an entity, so
				// entity_of_node returns nil, and it carries no exact value, so without this
				// arm it fell to the final else and was REJECTED as "Default parameter must be
				// a constant, got context". That then cascaded: the parameter had no usable
				// default, so every zero-argument call reported "Parameter 'ctx' of type
				// 'Context' is missing in procedure call".
				//
				// The arm sits between the entity branch and the exact-value branch in C++,
				// and the ORDER matters -- placing it later would let the o.value test claim
				// the operand first.
				param_value.kind = .Value
				param_value.ast_value = cast(^ast.Expr)pexpr
			} else if o.value != nil {
				// Has an exact value even though not constant mode
				param_value.kind = .Constant
				param_value.value = o.value
			} else {
				// C++ Reference: check_type.cpp handle_parameter_value -- names the offending EXPRESSION,
				// not a type. LEDGER #149.
				expr_str := expr_to_string(o.expr)
				defer delete(expr_str)
				error(pexpr, "Default parameter must be a constant, got %s", expr_str)
			}
		}
	} else {
		// Constant operand
		if o.value != nil {
			param_value.kind = .Constant
			param_value.value = o.value
		} else {
			// C++ check_type.cpp handle_parameter_value names the offending EXPRESSION, quoted.
			const_str := expr_to_string(o.expr)
			defer delete(const_str)
			error(o.expr, "Invalid constant parameter, got '%s'", const_str)
		}
	}

	// Set output type
	// Reference: check_type.cpp handle_parameter_value
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

					// C++ Reference: check_type.cpp check_get_params.
					//
					// MEASURED root cause (#260). C++ has no separate variadic branch here: for
					// `args: ..E` the type_expr IS the Ellipsis node, so `check_type` returns the
					// slice and control flows through C++'s single `else`, where
					// `is_type_polymorphic_type` is set. This port split the ellipsis into its own
					// branch and the flag computation did not come with it.
					//
					// Consequence, measured end to end: for `append(&d)` the parameter `args: ..E`
					// has type `[]$E` yet is_type_polymorphic_type stayed false, so the gate below
					// (~line 4903) never called determine_type_from_polymorphic, generation
					// SUCCEEDED, and the candidate scored 601 -- where the oracle fails generation
					// (check_expr.cpp:473 via success=false at check_type.cpp check_get_params), keeps pt
					// generic, and rejects at the ambiguous-variadic guard (check_expr.cpp:6988).
					//
					// Instrumenting the flag site showed 864 hits, ZERO with variadic=true --
					// the variadic parameter never reached it at all.
					if is_type_polymorphic(param_type) {
						is_type_polymorphic_type = true
					}
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
		// Reference: check_type.cpp:424-435
		param_value: Parameter_Value
		if field.default_value != nil && !is_field_variadic {
			// C++ Reference: check_type.cpp check_get_params. A `typeid` parameter may
			// not carry a default, and C++ reports it INSTEAD of evaluating the default at all --
			// the error and handle_parameter_value are the two arms of one if/else:
			//
			//     if (default_value != nullptr) {
			//         if (type_expr != nullptr && type_expr->kind == Ast_TypeidType) {
			//             error(type_expr, "A type parameter may not have a default value");
			//         } else {
			//             param_value = handle_parameter_value(...);
			//         }
			//     }
			//
			// The port had no such arm and called handle_parameter_value unconditionally, so
			// `f :: proc($T: typeid = int)` checked SILENTLY -- an under-rejection of source the
			// reference compiler rejects, and invisible to any check that reads only the port's
			// own output (#71). Anchored on the TYPE expression, not the default. LEDGER #672.
			//
			// The nil guard mirrors C++'s first disjunct: this site also serves C++'s
			// type_expr == nullptr path (:1919), where there is no type expression to test.
			is_typeid_param := false
			if field.type != nil {
				_, is_typeid_param = field.type.derived.(^ast.Typeid_Type)
			}
			if is_typeid_param {
				error(field.type, "A type parameter may not have a default value")
			} else {
			// Check the default value expression
			// Reference: handle_parameter_value in C++ (lines 1657-1760)
			// allow_caller_location = true for procedure parameters
			out_type: ^Type = nil
			param_value = handle_parameter_value(ctx, param_type, &out_type, field.default_value, true)

			// If parameter type not specified, infer from default value
			if param_type == nil && out_type != nil {
				param_type = out_type
			}

			// NO KIND VALIDATION HERE, DELIBERATELY -- C++ applies none in this path.
			// handle_parameter_value is called with allow_caller_location=true and its result is
			// used AS-IS.
			//
			// The port used to carry a `#partial switch param_value.kind` here, with an allow-list
			// and an `error(field.default_value, "Invalid parameter value")` default arm. That was
			// a COPY of C++'s polymorphic-RECORD-parameter block (check_type.cpp
			// check_record_polymorphic_params -- the ONLY place that message exists in C++, where
			// it runs with allow_caller_location=false and permits just Constant/Nil), pasted into
			// the PROCEDURE-parameter path where C++ has no such block at all.
			//
			// It was then widened twice as each false positive surfaced -- `.Value` had to be
			// admitted because the block fired on every `allocator := context.allocator` default
			// in core -- until the allow-list held all five non-Invalid kinds and the default arm
			// could only ever catch `.Invalid`. What survived was a single spurious "Invalid
			// parameter value" on `f :: proc(x: int = (---))`, where C++ emits one diagnostic and
			// the port emitted two. Widening the allow-list once more would have been a third coat
			// of paint on an invention; the block itself was the defect. LEDGER #805/#895.
			//
			// THE TWO RESTRICTIONS C++ ACTUALLY APPLIES in this procedure are both implemented
			// below and were never part of that switch: the `is_type_polymorphic(param_type)`
			// block ("A default value for a parameter must not be a polymorphic constant type"),
			// and the poly-name block ("Constant parameters cannot have a default value").
			//
			// Deleting the switch also dropped its `param_value = Parameter_Value{}` reset. That
			// is UNOBSERVABLE: the arm only ran when the kind was already `.Invalid`, and every
			// consumer of param_value below guards on the kind before reading any other field.
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

		// C++ Reference: check_type.cpp check_get_params. A POLYMORPHIC parameter type
		// may not carry a runtime default. Constant/Nil/Invalid defaults are fine (they can be
		// substituted per instantiation); Location/Expression/Value are not.
		//
		// THE BREAK-OUT IS LOAD-BEARING and easy to miss: a default whose expression resolves to a
		// POLYMORPHIC PROCEDURE entity is ALLOWED, because its type is settled per call site. C++
		// tests exactly that -- `entity_from_expr(param_value.ast_value)`, kind Entity_Procedure,
		// `is_type_polymorphic(e->type)` -- and only then falls through to the error.
		//
		// The port had none of this, so `f :: proc(x: $T = F)` checked without the diagnostic:
		// the oracle emits it plus the ambiguity error, the port emitted only the ambiguity one.
		// Anchored on the PARAMETER (C++'s `params[i]`), not the default. LEDGER #673.
		if is_type_polymorphic(param_type) {
			#partial switch param_value.kind {
			case .Invalid, .Constant, .Nil:
				// Substitutable per instantiation -- C++ breaks with no diagnostic.
			case .Location, .Expression, .Value:
				allow_polymorphic_proc := false
				if param_value.original_ast_expr != nil {
					if e := entity_from_expr(ctx, param_value.original_ast_expr); e != nil {
						if _, is_proc := e.variant.(Entity_Procedure); is_proc && is_type_polymorphic(e.type) {
							allow_polymorphic_proc = true
						}
					}
				}
				if !allow_polymorphic_proc {
					error(param, "A default value for a parameter must not be a polymorphic constant type, got %s", type_to_string(param_type))
				}
			}
		}

		// Check for 'using' parameter flag
		is_using := ast.Field_Flag.Using in field.flags

		// C++ Reference: check_type.cpp check_get_params, inside check_get_params -- PARAMETERS only.
		// C++ does NOT guard `using` on struct fields, so this belongs here and not in
		// check_struct_fields (placing it there rejects every `using` struct field).
		// The message differs from the statement form: "statement/procedure parameter".
		// Blocked until task 243 made check_feature_flags resolve a file from the node.
		if is_using && check_feature_flags(ctx, cast(^ast.Node)field) & {.Using_Stmt} == {} {
			begin_error_block()
			error(field, "'using' has been disallowed as it is considered bad practice to use as a statement/procedure parameter outside of immediate refactoring")
			error_line("\tIf you do require it for refactoring purposes or legacy code, it can be enabled on a per-file basis with '#+feature using-stmt'\n")
			end_error_block()
		}

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
				// C++ Reference: check_type.cpp check_get_params
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
			// C++ Reference: check_type.cpp check_get_params
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
			// C++ Reference: check_type.cpp check_get_params

			// #no_alias validation (C++ lines 2134-2138)
			if ast.Field_Flag.No_Alias in field.flags {
				// C++ Reference: check_type.cpp check_get_params. Three divergences were here:
				// the port tested is_type_pointer||is_type_multi_pointer instead of
				// is_type_internally_pointer_like (which is broader), it lacked C++'s two
				// guards, and its message was invented -- and ungrammatical, missing the
				// "to" in "can only be applied to".
				//
				// C++'s guards matter: on t_invalid we have already errored, and under
				// no_polymorphic_errors we are speculatively checking a proc-group candidate
				// that will be re-checked with errors enabled, so erroring now is premature.
				if param_type != t_invalid &&
				   !is_type_internally_pointer_like(param_type) &&
				   !ctx.no_polymorphic_errors {
					error(name_node, "'#no_alias' can only be applied to pointer-like type parameters")
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
						// C++ Reference: check_type.cpp check_get_params opens an ERROR_BLOCK here. Without
						// it the error_line below is emitted outside the collector, so it
						// printed BEFORE the harness header and was dropped from the count --
						// exactly what misroute.py detects.
						begin_error_block()
						defer end_error_block()
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

					// Validate type is not polymorphic. C++ check_type.cpp check_get_params.
					// LEDGER #707: read `(C++ lines 1992-1997)`, stale by ~88 lines against an older C++
					// revision. 1992-1997 is inside the `handle_parameter_value` region, not this check.
					if is_type_polymorphic(param_type) {
						// C++ check_type.cpp check_get_params names the TYPE, quoted. Computed before
						// param_type is reset to t_invalid below, as C++ does.
						error(operand.expr, "Cannot pass polymorphic type as a parameter, got '%s'", type_to_string(param_type))
						local_success = false
						param_type = t_invalid
					}

					// Check type is not untyped. C++ check_type.cpp check_get_params.
					// LEDGER #707: read `(C++ lines 1999-2005)`, which is the `is_type_polymorphic`
					// block ABOVE -- i.e. it named the wrong check, not merely the wrong lines.
					if is_type_untyped(default_type(param_type)) {
						// C++ check_type.cpp check_get_params (and the identical site at 2226-2232)
						// name the TYPE, quoted.
						error(operand.expr, "Cannot determine type from the parameter, got '%s'", type_to_string(param_type))
						local_success = false
						param_type = t_invalid
					}

					// Validate specialization constraint. C++ check_type.cpp check_get_params
					// (`modify_type` at 2094, the guard at 2096, block closes 2106).
					// LEDGER #707: read `(C++ lines 2008-2018)`, stale by ~88 lines.
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

					// C++ Reference: check_type.cpp check_get_params. An operand with NO expression
					// carries no position, and determine_type_from_polymorphic needs one to
					// report against, so C++ substitutes the parameter list itself.
					//
					// The accompanying reset used to be unconditional. Upstream PR #7208 made
					// it conditional -- C++'s own note is "Can still have valid type with null
					// expr. Needed for resolving" -- because an operand synthesised during
					// instantiation legitimately has a type and a valid mode but no expr, and
					// forcing it to t_invalid destroyed the very type being resolved. The port
					// never had the reset at all, so it already behaved like the fixed C++ on
					// that half; what it lacked was the position fallback. Both halves are now
					// present and match. LEDGER #386.
					if operand.expr == nil && params_node != nil {
						operand.expr = &params_node.node
						if operand.mode == .Invalid || operand.type == nil {
							operand.mode = .Invalid
							operand.type = t_invalid
						}
					}

					// If parameter type contains polymorphic types (e.g., []$T),
					// determine concrete type from operand (C++ lines 2057-2070)
					if is_type_polymorphic_type {
						param_type = determine_type_from_polymorphic(ctx, param_type, operand)
						if param_type == t_invalid {
							local_success = false
						} else if !ctx.no_polymorphic_errors {
							// C++ Reference: check_type.cpp check_get_params.
							//
							// Passing a still-polymorphic PROCEDURE as a value to a polymorphic
							// parameter cannot yield a complete type. Repro (probe partialpoly):
							//     f :: proc(x: $T) -> T { return x }
							//     h :: proc(cb: $F) { }
							//     h(f)     // oracle rejects here, port accepted
							//
							// C++'s sibling assignment `is_type_polymorphic_type = false` at 2155
							// is DELIBERATELY NOT PORTED: verified dead -- the variable is never
							// read again anywhere in the remainder of check_get_params (checked
							// through line 2340).
							proc_entity := entity_from_expr(ctx, operand.expr)
							if proc_entity != nil {
								if _, is_proc_value := operand.value.(Exact_Value_Procedure); is_proc_value {
									if is_type_polymorphic(entity_type(proc_entity), false) {
										error(operand.expr, "Cannot determine complete type of partial polymorphic procedure")
									}
								}
							}
						}
					}

					// Extract constant value for polymorphic constant parameters
					// C++ Reference: check_type.cpp check_get_params
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
									// C++ check_type.cpp check_get_params names the EXPRESSION and, unlike its
									// neighbours here, does NOT quote it.
									name_str := expr_to_string(operand.expr)
									defer delete(name_str)
									error(operand.expr, "Expected a constant value for this polymorphic name parameter, got %s", name_str)
								}
								local_success = false
							}
						}
					}

					// C++ Reference: check_type.cpp check_get_params.
					//
					// The call-site operand must be assignable to the (now-determined) parameter
					// type or generation of this polymorphic procedure FAILS. `#no_broadcast`
					// disables array programming for the test.
					//
					// Read the C++ before assuming this is a broad gate: `ok` is initialised
					// TRUE and only the `#any_int` branch can falsify it, so for every other
					// parameter the block is INERT -- a failed assignability test alone changes
					// nothing. Only an `#any_int` parameter whose operand is neither assignable
					// nor castable reaches `success = false`.
					//
					// The diagnostic beside it is behind `#if 0`, so this branch EMITS NOTHING;
					// the flag is its entire effect and no message-based comparison of the two
					// implementations can see it. What it DOES change is whether the procedure
					// is instantiated at all -- and therefore whether its BODY is ever checked.
					// Repro (probe p675a):
					//     f :: proc(a: $T, #any_int n: int) -> T { bad := undeclared; return a }
					//     f(1, "hi")
					// The oracle reports only the argument conversion; the port additionally
					// reported "Undeclared name" from a body C++ never checks.
					//
					// This block is only correct because the polymorphic operand array now has
					// its DEFAULTED slots filled before instantiation (check_expr.odin, the
					// pre-fill mirroring check_expr.cpp:6825-6857). Without that, an unsupplied
					// `#any_int new_cap := -1` arrives with `operand.type == nil`, `ok` goes
					// false, and `shrink(&arr)` loses its only viable candidate -- measured, and
					// guarded by corpus member p674sh. LEDGER #80, #674, #675.
					allow_array_programming := true
					if ast.Field_Flag.No_Broadcast in field.flags {
						allow_array_programming = false
					}
					if param_type != t_invalid && !check_is_assignable_to(ctx, &operand, param_type, allow_array_programming) {
						// C++ names this `ok`; renamed here because `ok` at check_type.odin:4816
						// is the enclosing `field, ok := param.derived.(^ast.Field)` and the
						// project's own `-vet -strict-style` check rejects the shadow. #679.
						any_int_ok := true
						if ast.Field_Flag.Any_Int in field.flags {
							if operand.type == nil {
								any_int_ok = false
							} else if (!is_type_integer(operand.type) && !is_type_enum(operand.type)) ||
							          (!is_type_integer(param_type) && !is_type_enum(param_type)) {
								any_int_ok = false
							} else if !check_is_castable_to(ctx, &operand, param_type) {
								any_int_ok = false
							}
						}
						if !any_int_ok {
							local_success = false
						}
					}

					// Validate operand is not untyped after type determination.
					// C++ Reference: check_type.cpp check_get_params. C++ has this block TWICE, verbatim:
					// once at :2087-2092 and again at :2226-2232. THIS port block mirrors the
					// SECOND copy -- it matches :2226-2232 statement for statement, including the
					// `success = false` and `type = t_invalid` that follow the error. The other
					// port copy (check_type.odin:5257) is the one that mirrors :2087-2092.
					//
					// LEDGER #705: this site cited `:2087-2088 (and the identical site at
					// 2222-2223)`, i.e. it anchored on the copy it does NOT implement and gave the
					// other one's location four lines out. Corrected to the copy actually mirrored.
					// The bare `(C++ lines 2125-2131)` that stood above it was wrong too and is
					// replaced by this anchored form.
					//
					// I predicted this would remove one citemono inversion, because :2226 falls
					// after :2222 (the preceding citation) where :2087 fell before it. MEASURED:
					// it did NOT -- the count stayed at 18. citemono flags against the RUNNING
					// MAXIMUM, not the previous citation, and :2261 (port :5213) is already in
					// that maximum, so :2226 is still "backwards". The correction is right on its
					// own terms -- the citation now names the copy this code actually implements --
					// but it buys nothing from the metric. Second time in two ticks that a real
					// citation fix moved the count by zero (#704, #147).
					if is_type_untyped(default_type(param_type)) {
						// The message names the TYPE, quoted.
						error(operand.expr, "Cannot determine type from the parameter, got '%s'", type_to_string(param_type))
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
					// Regular parameter. C++ Reference: check_type.cpp check_get_params -- the whole
					// non-`using`, non-polymorphic branch: entity construction (:2319-2321),
					// state/flags (:2322-2326), interned name (:2328-2329), then param_value /
					// field_group_index / type_expr (:2331-2333).
					// LEDGER #704: this block cited `2199-2202`, which is the `#no_broadcast` /
					// check_is_assignable_to block in a DIFFERENT part of the function. Corrected.
					// C++ Reference: check_type.cpp check_get_params —
					//     param->flags |= EntityFlag_Used|EntityFlag_Param|EntityFlag_Value;
					// (cited as :2319 before #704; :2319 is the `entities_to_use` slot fetch, and
					// the quoted line is five lines below it.)
					// EntityFlag_Value is set on EVERY parameter, unconditionally. It is
					// what makes check_ident give a parameter `.Value` rather than
					// `.Variable` mode (check_expr.cpp:2017-2020), which in turn is what
					// routes an assignment to it into the parameter-immutability check.
					param_entity = alloc_entity_param(scope, tokenizer.Token{text = param_name, pos = actual_name_node.pos}, param_type, is_using, true)

					// Store default parameter value.
					// C++ Reference: check_type.cpp check_get_params `param->Variable.param_value = param_value;`
					// (cited as `C++ line 2200` before #704 -- that line is
					// `allow_array_programming = false` in the #no_broadcast block, unrelated.)
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
				// C++ Reference: check_type.cpp check_get_params
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
						// C++ Reference: check_type.cpp check_get_params
						if .No_Capture not_in param_entity.flags {
							param_entity.flags += {.No_Capture}
						}
					}
				}

				// Set entity flags from field flags
				// C++ Reference: check_type.cpp check_get_params

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
		// C++ Reference: check_type.cpp check_get_params
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

// ast_references_poly_params reports whether a type expression mentions any
// polymorphic type parameter bound in `scope`.
//
// C++ Reference: check_type.cpp:2410-2456
//
// This is a purely syntactic walk - it deliberately does NOT check the
// expression, because the whole point is to decide whether checking it is safe
// yet. See its caller in check_get_results.
ast_references_poly_params :: proc(scope: ^Scope, node: ^ast.Expr) -> bool {
	if node == nil {
		return false
	}

	#partial switch n in node.derived_expr {
	case ^ast.Ident:
		e := scope_lookup(scope, n.name)
		if e != nil && e.kind == .Type_Name {
			t := entity_type(e)
			if t != nil && t.kind == .Generic {
				return true
			}
		}
		return false
	case ^ast.Selector_Expr:
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Index_Expr:
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Call_Expr:
		for arg in n.args {
			if ast_references_poly_params(scope, arg) {
				return true
			}
		}
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Comp_Lit:
		return ast_references_poly_params(scope, n.type)
	case ^ast.Unary_Expr:
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Paren_Expr:
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Deref_Expr:
		return ast_references_poly_params(scope, n.expr)
	case ^ast.Pointer_Type:
		return ast_references_poly_params(scope, n.elem)
	case ^ast.Array_Type:
		return ast_references_poly_params(scope, n.elem) ||
		       ast_references_poly_params(scope, n.len)
	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		return ast_references_poly_params(scope, n.elem) ||
		       ast_references_poly_params(scope, n.capacity)
	case ^ast.Dynamic_Array_Type:
		return ast_references_poly_params(scope, n.elem)
	case ^ast.Map_Type:
		return ast_references_poly_params(scope, n.key) ||
		       ast_references_poly_params(scope, n.value)
	}

	return false
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
		//
		// C++ Reference: check_type.cpp check_get_results
		//
		// While the GENERIC signature is being built the polymorphic parameters
		// are only bound to Type_Generic placeholders, so a result type that
		// mentions one cannot be evaluated yet - `-> type_of(simd_to_bits(T{}))`
		// would reach check_compound_lit with T still generic and be rejected.
		// C++ substitutes a fresh Type_Generic named after the source text and
		// resolves the expression at instantiation instead.
		// C++ Reference: check_type.cpp check_get_results --
		//
		//     Ast *default_value = unparen_expr(field->default_value);
		//     ParameterValue param_value = {};
		//     ... if (default_value != nullptr) {
		//             param_value = handle_parameter_value(ctx, type, nullptr, default_value, false);
		//         }
		//     ... param->Variable.param_value = param_value;
		//
		// #971: THE PORT NEVER LOOKED AT `field.default_value` HERE AT ALL -- this procedure
		// contained no mention of default_value, param_value or handle_parameter_value, while the
		// PARAMETER path (check_get_params) records all of it. So `proc() -> (a: int = 3)` parsed,
		// checked and produced a result entity whose `param_value.kind` was Invalid with
		// `ast_value` / `original_ast_expr` / `init_expr` all nil.
		//
		// A named result's default is its INITIAL value, not decoration, and it is not always the
		// zero. `core:strings`'s `hash_str_rabin_karp :: proc(s: string) -> (hash: u32 = 0, pow: u32 = 1)`
		// multiplies by `pow`; started at 0 instead of 1, every needle of three bytes or more
		// reports "not found" -- `strings.index("abcdef", "cde")` returns -1 with nothing refusing
		// and nothing crashing.
		//
		// Calling handle_parameter_value also CHECKS the expression, which is the half the report
		// called more useful: recording the value without checking it would leave
		// `-> (a: int = SOME_CONST)` and `-> (a: f64 = 1.0/3.0)` unusable, since their `tav.type`
		// would still be nil and a backend could only read literals out of the syntax tree.
		result_default := unparen_expr(field.default_value)
		param_value: Parameter_Value

		result_type: ^Type = nil
		if field.type != nil {
			if ctx.allow_polymorphic_types && ast_references_poly_params(ctx.scope, field.type) {
				name := expr_to_string(field.type)
				result_type = alloc_type_generic(ctx.checker, ctx.scope, 0, name, nil)
			} else {
				result_type = check_type(ctx, field.type)
			}
			// C++ passes the RESOLVED type in and no out-pointer: the default must conform to the
			// declared type. `allow_caller_location` is false for results, as for C++.
			if result_default != nil {
				param_value = handle_parameter_value(ctx, result_type, nil, result_default, false)
			}
		} else {
			// C++'s `field->type == nullptr` arm: no declared type, so the type is INFERRED FROM
			// THE DEFAULT via the out-pointer. `-> (a = 3)`.
			param_value = handle_parameter_value(ctx, nil, &result_type, result_default, false)
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
				// #1106. C++ Reference: check_type.cpp check_get_results treats a result field
				// with names as NAMED, and inside that branch:
				//
				//     if (is_blank_ident(token)) {
				//         error(name, "Result value cannot be a blank identifer `_`");
				//     }
				//
				// and then builds the entity anyway. `is_blank_ident` is `len == 1 && str[0]=='_'`
				// (parser.cpp), so the EMPTY string is NOT blank — and the parser writes "" for a
				// genuinely anonymous result field. A `_` in a result list is therefore ALWAYS
				// user-written.
				//
				// The port conflated the two: it accepted "_" as a parser placeholder and routed
				// it down the UNNAMED path, which made the blank-identifier error further down
				// this same procedure DEAD CODE for the only input that can reach it.
				// MEASURED: `f :: proc() -> (_: int) { return 1 }` — oracle 1, port 0.
				// Dropping "_" from this test is the whole fix; the diagnostic was already there.
				is_unnamed_result = first_ident.name == ""
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
			// t243: C++ sets EntityFlag_Used|EntityFlag_Param|EntityFlag_Result on BOTH arms of
			// check_get_results (check_type.cpp:2534 unnamed, :2562 named -- resolved by name).
			// alloc_entity_param already supplies {.Param, .Used}, so .Result was the ONLY flag
			// this arm lacked; the port set it on the named arm alone.
			// OBSERVABILITY, established BEFORE changing it rather than assumed: every reference
			// reader of EntityFlag_Result needs an entity that is reachable, and an unnamed result
			// is in NO scope and has NO name (token.text == ""), so none can see it --
			//   check_stmt.cpp:2935           entity_of_node(lhs), needs an ident to assign to
			//   checker.cpp:796              check_scope_usage_internal, walks scope members
			//   checker.cpp:461,500,2035,2061 all name-keyed scope lookups
			// MEASURED on wit_bigres243/unnamed, the one reader an unnamed result could plausibly
			// reach: `-> ([1 << 20]u8)` warns for the call-site local ONLY on BOTH compilers.
			// So this is a parity-of-STATE fix with no behavioural delta today. It is made because
			// a future reader of the flag would silently diverge, NOT to move a corpus cell -- and
			// it is recorded as such so nobody later mistakes it for a closed divergence.
			entity.flags += {.Result}
			// C++ Reference: check_type.cpp check_get_results. C++ branches on `field->names.count
			// == 0` and assigns -1 only there; the field_group_index assignment lives in the arm
			// for fields that HAVE names. The port's `is_unnamed_result` is a wider test -- it also
			// captures a field whose single name is the parser's EMPTY placeholder, which is what
			// `-> (int, bool)` produces (parser.cpp parse_field_list: a colon-less item becomes
			// `ast_field(f, [blank ident], type, ...)`, so names.count is 1, not 0). Only the
			// UNPARENTHESISED form `-> int` reaches parse_results' own `empty_names` path.
			//
			// So C++ gives `-> (int, bool)` groups 0 and 1 and `-> bool` -1, while the port gave -1
			// to all three. MEASURED against `odin doc -doc-format` on a probe carrying all the
			// forms, and visible in core/unicode/utf8's encode_rune.
			//
			// Only the INDEX is corrected here. ONE further difference remains, recorded as open
			// rather than guessed at: C++ routes a field whose single name is the parser's EMPTY
			// placeholder through its NAMED arm (names.count == 1), where it calls
			// add_entity/add_entity_use with that placeholder ident -- so the reference puts an
			// empty-named entity into the result scope where the port puts none. That changes scope
			// CONTENTS, which is why it is not being guessed at.
			// The EntityFlag_Result half of this note is CLOSED as of t243; see the block below.
			if var_data, var_ok := &entity.variant.(Entity_Variable); var_ok {
				var_data.field_group_index = len(field.names) == 0 ? -1 : field_group_index
				// #971: C++ assigns `param->Variable.param_value = param_value` on BOTH the unnamed
				// and the named arm.
				var_data.param_value = param_value
			}

			append(&result_types, result_type)
			append(&result_entities, entity)
		} else {
			// Handle named results
			for name_node in field.names {
				ident, ident_ok := name_node.derived.(^ast.Ident)
				if !ident_ok {
					error(name_node, "Expected an identifer for as the field name")
					continue
				}

				name := ident.name

				// Check for blank identifier (user explicitly wrote `_: type`)
				if is_blank_ident(name) {
					error(name_node, "Result value cannot be a blank identifer `_`")
					// #1106: NO `continue` HERE. C++ Reference: check_type.cpp check_get_results
					// reports and FALLS THROUGH — it still builds the entity and still appends it
					// to `variables`, so the results TUPLE keeps its arity.
					// The port's `continue` dropped the element, which changed the procedure's
					// return count and produced a CASCADE the reference never emits:
					//     `f :: proc() -> (_: int) { return 1 }`
					//         oracle: 1 diagnostic (the blank identifier)
					//         port:   that PLUS "No return values expected"
					//     `f :: proc() -> (_: int, b: int) { return 1, 2 }`
					//         port additionally: "Expected 1 return values, got 2"
					// This half only became visible once the blank case reached this branch at
					// all — before the is_unnamed_result fix above, it never got here.
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
					var_data.param_value = param_value   // #971
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
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

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
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

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
	// C++ nil-guards after reducing (types.cpp, e.g. is_type_enum:
	//     t = base_type(t); if (t == nullptr) { return false; }
	// base_type(nil) returns nil here, so the deref below would fault.
	if bt == nil {
		return false
	}

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
// C++ Reference: check_expr.cpp:1389-1419
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
		// C++ Reference: check_expr.cpp polymorphic_assign_index
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
		// C++ Reference: check_expr.cpp polymorphic_assign_index
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
// C++ Reference: check_type.cpp check_type_specialization_to_internal
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
				// type comes from the single store (Entity.type); the remaining fields are
				// genuinely variant-only. C++ Reference: entity.cpp:170.
				e.variant = Entity_Constant {
					type              = entity_type(t_e),
					value             = type_const.value,
					param_value       = type_const.param_value,
					flags             = type_const.flags,
					field_group_index = type_const.field_group_index,
				}
				e.type = entity_type(t_e)
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
		// C++ Reference: check_type.cpp:1554-1562 --
		//     // `specialization` may already be published in a polymorphic record's gen_types
		//     // cache; finalize it under that record's (recursive) gen_types mutex so a
		//     // concurrent find_polymorphic_record_entity on another thread cannot observe a
		//     // torn Type.
		//     GenTypesData *gen_types = gen_types_data_of_specialization(specialization);
		//     if (gen_types != nullptr) mutex_lock(&gen_types->mutex);
		//     gb_memmove(specialization, type, gb_size_of(Type));
		//     if (gen_types != nullptr) mutex_unlock(&gen_types->mutex);
		//
		// The port took NO lock here. C++'s single gb_memmove is at least one unsynchronised
		// store; the port's is three (kind, variant, flags), so the torn window is wider, not
		// narrower. Reported from a downstream consumer (rexcode-mir) as an intermittent
		// ~4-5%-of-builds failure to check base/runtime under threads, where
		// `Map_Cell(T){}` is diagnosed as having type `Map_Cell` -- i.e. a reader walking the
		// gen_types cache saw an entry that had not yet been finalised -- with the error COUNT
		// varying run to run on byte-identical input, which is the signature of a per-entry
		// window rather than one missing instantiation.
		gen_types := gen_types_data_of_specialization(specialization)
		if gen_types != nil {
			sync.recursive_mutex_lock(&gen_types.mutex)
		}
		// C++ line 1560: gb_memmove(specialization, type, sizeof(Type)) — change the
		// actual type while keeping the types defined within it.
		//
		// PUBLICATION ORDER IS LOAD-BEARING, and it was wrong. `kind` must be stored LAST.
		// Every reader dispatches on `kind` and then asserts the matching `variant` member
		// (check_equivalence.odin's 42 `x.variant.(Type_Foo)` sites, and the same pattern
		// throughout). Storing `kind` FIRST published "I am now a Type_Basic" while `variant`
		// still held the OLD payload, so a concurrent reader took the .Basic arm and asserted
		// against a Type_Generic. That is not theoretical: it is the exact captured trap,
		//     check_equivalence.odin(259:14) type assertion: Invalid type assertion from
		//     Type_Variant to Type_Basic, actual type: Type_Generic
		// measured at 3/480 with 16-way concurrency on $S/phase2/wit_polyrace/raceprobe.
		// Storing the payload first and `kind` last means a reader that observes the NEW kind
		// is guaranteed (x86-TSO store ordering, plus the explicit atomic release below) to
		// observe the new variant with it. A reader that observes the OLD kind sees a wholly
		// old, self-consistent Type, which is what the pre-existing lock already allowed.
		//
		// NOTE ON PARITY: C++ tolerates this window because `x->Basic` is a bare union member
		// access with NO tag check -- a torn read there yields wrong data, not a trap. The port's
		// tagged union checks, so what is silently benign in the reference is fatal here. Fixing
		// the ORDER is what makes the port safe without weakening the check, which is strictly
		// better than matching C++ by removing the check.
		specialization.variant = type.variant
		specialization.flags = type.flags
		sync.atomic_store_explicit(&specialization.kind, type.kind, .Release)
		if gen_types != nil {
			sync.recursive_mutex_unlock(&gen_types.mutex)
		}
	}

	return true
}

// gen_types_data_of_specialization returns the Gen_Types_Data of the polymorphic record that
// `specialization` was instantiated from, when `specialization` has been published into that
// record's gen_types cache; nil otherwise.
//
// C++ Reference: check_type.cpp:1509-1520. The port had no counterpart at all, which is why the
// in-place finalization above was unsynchronised. The link is the specialization's own type-name
// entity: add_polymorphic_record_entity stamps `original_type_for_parapoly` on it (check_type.odin
// above, C++ check_type.cpp:315), so an instantiation can be walked back to its generic parent
// and hence to the cache it lives in. A nil result means the type is not a published
// specialization and needs no lock -- NOT that locking failed.
gen_types_data_of_specialization :: proc(specialization: ^Type) -> ^Gen_Types_Data {
	if specialization == nil || specialization.kind != .Named {
		return nil
	}
	named, ok := &specialization.variant.(Type_Named)
	if !ok || named.type_name == nil {
		return nil
	}
	type_name, tn_ok := &named.type_name.variant.(Entity_Type_Name)
	if !tn_ok {
		return nil
	}
	orig := type_name.original_type_for_parapoly
	if orig == nil || orig.kind != .Named {
		return nil
	}
	orig_named, orig_ok := &orig.variant.(Type_Named)
	if !orig_ok {
		return nil
	}
	return orig_named.gen_types_data
}

// check_type_specialization_to checks whether a concrete type satisfies a polymorphic
// specialization, e.g. `Queue(string)` against the `$Q/Queue` of `proc(q: ^$Q/Queue)`.
//
// C++ Reference: check_type.cpp check_type_specialization_to. The port previously carried a
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

	// === Type_Basic === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Basic {
		if compound {
			// Compound literals require identical types
			return are_types_identical(poly, source)
		}
		// Check type compatibility, allowing untyped→typed conversions
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable uses check_is_assignable_to
		// here. (FILE CORRECTED: this said check_type.cpp. The PORT DOES NOT CALL IT -- see #719 item 1;
		//  this comment states C++'s behaviour correctly while the code below diverges.)
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

	// === Type_Named === (C++ check_expr.cpp is_polymorphic_type_assignable)
	// (An earlier citation here was anchored but WRONG BY CONTENT -- it landed on `case Type_Basic`.)
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
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable, Type_Named arm:
		//
		//     if (compound || !is_type_generic(poly)) {
		//         return are_types_identical(poly, source);
		//     }
		//     return check_is_assignable_to(c, &o, poly);
		//
		// where `o` is built once at the top of the procedure as
		// `Operand o = {Addressing_Value}; o.type = source;`.
		//
		// #964: THE PORT'S TWO BRANCHES RETURNED THE SAME EXPRESSION. `if compound { X } return X`
		// -- so `compound` decided nothing, `is_type_generic` was never consulted (it is one of the
		// procedures with zero callers that the #949 audit turned up), and the
		// `check_is_assignable_to` fallback was unreachable. The comment above it said "identity or
		// assignment check", describing C++'s behaviour rather than the code beneath it.
		//
		// Direction: the port was STRICTER, so any divergence is an under-acceptance. REACHABILITY
		// IS NOT ESTABLISHED -- four polymorphic shapes were measured and all four matched, and
		// separating the two implementations needs a case where specialization FAILS,
		// are_types_identical is FALSE and check_is_assignable_to is TRUE for a Named generic poly.
		// No such witness was found. This lands as a faithfulness fix, not a measured one.
		if compound || !is_type_generic(poly) {
			return are_types_identical(poly, source)
		}
		o := Operand{mode = .Value, type = source}
		return check_is_assignable_to(ctx, &o, poly)
	}

	// === Type_Generic === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Generic {
		generic := poly_base.variant.(Type_Generic)

		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable (the Generic.specialized guard)
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
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable (the modify_type default_type+gb_memmove)
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

	// === Type_Pointer === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Pointer && source_base.kind == .Pointer {
		poly_ptr := poly_base.variant.(Type_Pointer)
		source_ptr := source_base.variant.(Type_Pointer)
		// Recursively check element types
		return is_polymorphic_type_assignable(ctx, poly_ptr.elem, source_ptr.elem, true, modify_type)
	}

	// Handle MultiPointer → Pointer conversion (C++ check_expr.cpp is_polymorphic_type_assignable, the MultiPointer-source branch inside case Type_Pointer)
	if poly_base.kind == .Pointer && source_base.kind == .Multi_Pointer {
		poly_ptr := poly_base.variant.(Type_Pointer)
		source_mp := source_base.variant.(Type_Multi_Pointer)
		// Allow multi-pointer to pointer conversion with element subtype check
		return is_polymorphic_type_assignable(ctx, poly_ptr.elem, source_mp.elem, true, modify_type)
	}

	// === Type_MultiPointer === (C++ check_expr.cpp is_polymorphic_type_assignable)
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

	// === Type_Array === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Array && source_base.kind == .Array {
		poly_arr := &poly_base.variant.(Type_Array)
		source_arr := source_base.variant.(Type_Array)

		// Handle generic count for arrays with polymorphic sizes
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable (generic_count + polymorphic_assign_index
		// + the modify_type write-back, inside case Type_Array)
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

	// Handle EnumeratedArray → Array conversion (C++ check_expr.cpp is_polymorphic_type_assignable, the EnumeratedArray-source branch inside case Type_Array)
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

	// === Type_EnumeratedArray === (C++ check_expr.cpp is_polymorphic_type_assignable)
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

	// === Type_Slice === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Slice && source_base.kind == .Slice {
		poly_slice := poly_base.variant.(Type_Slice)
		source_slice := source_base.variant.(Type_Slice)
		return is_polymorphic_type_assignable(ctx, poly_slice.elem, source_slice.elem, compound, modify_type)
	}

	// === Type_DynamicArray === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Dynamic_Array && source_base.kind == .Dynamic_Array {
		poly_dyn := poly_base.variant.(Type_Dynamic_Array)
		source_dyn := source_base.variant.(Type_Dynamic_Array)
		return is_polymorphic_type_assignable(ctx, poly_dyn.elem, source_dyn.elem, compound, modify_type)
	}

	// === Type_FixedCapacityDynamicArray === (C++ check_expr.cpp is_polymorphic_type_assignable)
	//
	// `[dynamic; $N]$E` against a concrete `[dynamic; 8]int`: bind N to the source capacity, then
	// require the capacities to agree before recursing on the element type. Mirrors the Array arm
	// above, which does the same for `[$N]$E`.
	if poly_base.kind == .Fixed_Capacity_Dynamic_Array && source_base.kind == .Fixed_Capacity_Dynamic_Array {
		poly_fc := &poly_base.variant.(Type_Fixed_Capacity_Dynamic_Array)
		source_fc := source_base.variant.(Type_Fixed_Capacity_Dynamic_Array)

		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable (the generic_capacity block)
		if poly_fc.generic_capacity != nil {
			if !polymorphic_assign_index(&poly_fc.generic_capacity, &poly_fc.capacity, source_fc.capacity, modify_type) {
				return false
			}
		}

		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable -- the `if (capacity == source->...capacity)`
		// falling through to `return false`. C++ returns false when the capacities disagree, so a
		// concrete mismatch is simply not assignable.
		if poly_fc.capacity != source_fc.capacity {
			return false
		}

		return is_polymorphic_type_assignable(ctx, poly_fc.elem, source_fc.elem, compound, modify_type)
	}

	// === Type_Map === (C++ check_expr.cpp is_polymorphic_type_assignable)
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

	// === Type_SoaPointer === (C++ check_expr.cpp is_polymorphic_type_assignable)
	//
	//     isize level = check_is_assignable_to_using_subtype(source->SoaPointer.elem,
	//                       poly->SoaPointer.elem, 0, false, /*allow_polymorphic*/true);
	//     if (level > 0) { return true; }
	//     return is_polymorphic_type_assignable(c, poly->SoaPointer.elem, source->SoaPointer.elem,
	//                                           true, modify_type);
	//
	// #982: MISSING, found by auditing this switch against C++ after #981 showed two arms had been
	// deleted. MEASURED: `f :: proc(p: #soa ^#soa[]$E)` called with `&soa[0]` is accepted by the
	// reference and was rejected here. The concrete form `#soa ^#soa[]Foo` already matched, so only
	// the POLYMORPHIC element was affected -- the same shape as #981.
	//
	// The subtype probe comes first and is not an optimisation: an SOA pointer to an EMBEDDED
	// record is assignable to a pointer to the embedded type, and only the recursion's failure
	// would otherwise be reported.
	if poly_base.kind == .Soa_Pointer && source_base.kind == .Soa_Pointer {
		pe := poly_base.variant.(Type_Soa_Pointer).elem
		se := source_base.variant.(Type_Soa_Pointer).elem
		if check_is_assignable_to_using_subtype(se, pe, 0, false, true) > 0 {
			return true
		}
		return is_polymorphic_type_assignable(ctx, pe, se, true, modify_type)
	}

	// === Type_BitField === (C++ check_expr.cpp is_polymorphic_type_assignable)
	//
	//     return is_polymorphic_type_assignable(c, poly->BitField.backing_type,
	//                                           source->BitField.backing_type, true, modify_type);
	//
	// #982: also missing. No witness was found for it -- a polymorphic bit_field specialization has
	// no spelling I could construct that both compilers accept -- so this lands as faithfulness,
	// stated as such, alongside the SoaPointer arm that IS measured.
	if poly_base.kind == .Bit_Field && source_base.kind == .Bit_Field {
		pb := poly_base.variant.(Type_Bit_Field).backing_type
		sb := source_base.variant.(Type_Bit_Field).backing_type
		return is_polymorphic_type_assignable(ctx, pb, sb, true, modify_type)
	}

	// NOTE ON Type_Enum: C++ has `case Type_Enum: return false;`. The port has no arm, so an enum
	// poly falls through to this procedure's own final `return false`. Same answer, and checked
	// rather than assumed -- that case body is one line.

	// === Type_Union === (C++ check_expr.cpp is_polymorphic_type_assignable, `case Type_Union`)
	//
	// #981: THE COMMENT THAT STOOD HERE SAID C++'s SWITCH "HAS NO STRUCT AND NO UNION CASE". IT
	// HAS BOTH -- check_expr.cpp, immediately before the Proc case. The arms were removed to break
	// a real infinite recursion, and the diagnosis of that recursion was right: the port's OLD arms
	// DELEGATED to check_type_specialization_to, which calls back here with the arguments
	// unchanged. C++'s arms do no such thing. They recurse only on STRICTLY SMALLER arguments --
	// each union variant, or the soa element -- so the cycle cannot form.
	//
	// Deleting them also deleted the only path by which `#soa` specializations match, which is the
	// defect being fixed here.
	if poly_base.kind == .Union && source_base.kind == .Union {
		pu := poly_base.variant.(Type_Union)
		su := source_base.variant.(Type_Union)
		if len(pu.variants) != len(su.variants) {
			return false
		}
		for i in 0 ..< len(pu.variants) {
			if !is_polymorphic_type_assignable(ctx, pu.variants[i], su.variants[i], false, modify_type) {
				return false
			}
		}
		return true
	}

	// === Type_Struct === (C++ check_expr.cpp is_polymorphic_type_assignable, `case Type_Struct`)
	//
	// The ONLY thing C++ matches here is an SOA struct against an SOA struct of the same KIND,
	// recursing on the element. Anything else returns false -- records proper remain
	// check_type_specialization_to's job, which is the half the old comment got right.
	//
	// #981, MEASURED: `make(#soa[dynamic]SoaS)` was rejected with "No procedures or ambiguous call
	// for procedure group 'make'". The overload is
	// `make_soa_dynamic_array :: proc($T: typeid/#soa[dynamic]$E, ...)`, so resolving it IS this
	// match. All three SOA forms failed -- `#soa[]$E`, `#soa[dynamic]$E`, `#soa[4]$E` -- while
	// plain `[]$E` and `[dynamic]$E` matched, which is what localised it here.
	if poly_base.kind == .Struct && source_base.kind == .Struct {
		ps := poly_base.variant.(Type_Struct)
		ss := source_base.variant.(Type_Struct)
		if ps.soa_kind == ss.soa_kind && ps.soa_kind != .None {
			ok := is_polymorphic_type_assignable(ctx, ps.soa_elem, ss.soa_elem, true, modify_type)
			if ok && modify_type {
				// C++ rebuilds the poly type as a CONCRETE soa struct over the now-resolved
				// element and memmoves it over `poly`, so the caller sees a finished type rather
				// than one still carrying a generic element.
				rebuilt: ^Type
				#partial switch ss.soa_kind {
				case .Fixed:
					rebuilt = make_soa_struct_fixed(ctx, ps.node, nil, ps.soa_elem, ps.soa_count, nil)
				case .Slice:
					rebuilt = make_soa_struct_slice(ctx, ps.node, nil, ps.soa_elem)
				case .Dynamic:
					rebuilt = make_soa_struct_dynamic_array(ctx, ps.node, nil, ps.soa_elem)
				}
				if rebuilt != nil {
					poly_base^ = rebuilt^
				}
			}
			return ok
		}
		return false
	}

	// === Type_Proc === (C++ check_expr.cpp is_polymorphic_type_assignable)
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

	// === Type_BitSet === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Bit_Set && source_base.kind == .Bit_Set {
		poly_bs := &poly_base.variant.(Type_Bit_Set)
		source_bs := source_base.variant.(Type_Bit_Set)

		// #1107 (B2-c c4). C++ Reference: check_expr.cpp is_polymorphic_type_assignable,
		// case Type_BitSet:
		//
		//     if (!is_type_polymorphic(poly->BitSet.elem)) {
		//         if (poly->BitSet.upper != source->BitSet.upper ||
		//             poly->BitSet.lower != source->BitSet.lower) {
		//             return false;
		//         }
		//     }
		//
		// THE BOUNDS GUARD WAS ABSENT, so two range-bit_sets with the same element type but
		// DIFFERENT bounds unified. MEASURED:
		//     f :: proc($T: typeid/bit_set[0..<4]) {}
		//     f(bit_set[0..<8])        oracle 1 (specialization mismatch), port 0
		//
		// The guard is skipped when the poly ELEMENT is itself polymorphic — for `bit_set[$E]`
		// the bounds were never computable when the poly type was built, so they are zero and
		// comparing them would reject everything.
		if !is_type_polymorphic(poly_bs.elem) {
			if poly_bs.upper != source_bs.upper || poly_bs.lower != source_bs.lower {
				return false
			}
		}

		// Check element type
		if !is_polymorphic_type_assignable(ctx, poly_bs.elem, source_bs.elem, true, modify_type) {
			return false
		}

		// C++ Reference: same arm, continued. For a generic `bit_set[$E]` the poly type's bounds
		// and underlying are zero/nil because they could not be determined at construction, so
		// the INSTANTIATION fills them in from the source. The port did none of this, leaving an
		// instantiated bit_set with upper == lower == 0 and a nil underlying.
		//     if (poly->BitSet.upper == 0 && modify_type) poly->BitSet.upper = source->...upper;
		//     if (poly->BitSet.lower == 0 && modify_type) poly->BitSet.lower = source->...lower;
		if poly_bs.upper == 0 && modify_type {
			poly_bs.upper = source_bs.upper
		}
		if poly_bs.lower == 0 && modify_type {
			poly_bs.lower = source_bs.lower
		}

		// C++ Reference: same arm. NOTE THE SHAPE — it is an if/else-if on the POLY side alone,
		// not the port's `both non-nil` conjunction:
		//     if (poly->BitSet.underlying == nullptr) {
		//         if (modify_type) poly->BitSet.underlying = source->BitSet.underlying;
		//     } else if (!is_polymorphic_type_assignable(c, poly->BitSet.underlying,
		//                                                source->BitSet.underlying, true, modify_type)) {
		//         return false;
		//     }
		// The port's version skipped the recursion entirely whenever the SOURCE's underlying was
		// nil, and never propagated the source's underlying into the instantiation.
		if poly_bs.underlying == nil {
			if modify_type {
				poly_bs.underlying = source_bs.underlying
			}
		} else if !is_polymorphic_type_assignable(ctx, poly_bs.underlying, source_bs.underlying, true, modify_type) {
			return false
		}

		return true
	}

	// === Type_Matrix === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Matrix && source_base.kind == .Matrix {
		poly_mat := &poly_base.variant.(Type_Matrix)
		source_mat := source_base.variant.(Type_Matrix)

		// Handle generic row count for matrices with polymorphic dimensions
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable
		if poly_mat.generic_row_count != nil {
			poly_mat.stride_in_bytes = 0
			if !polymorphic_assign_index(&poly_mat.generic_row_count, &poly_mat.row_count, source_mat.row_count, modify_type) {
				return false
			}
		}

		// Handle generic column count
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable
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

	// === Type_SimdVector === (C++ check_expr.cpp is_polymorphic_type_assignable)
	if poly_base.kind == .Simd_Vector && source_base.kind == .Simd_Vector {
		poly_sv := &poly_base.variant.(Type_Simd_Vector)
		source_sv := source_base.variant.(Type_Simd_Vector)

		// Handle generic count for SIMD vectors with polymorphic sizes
		// C++ Reference: check_expr.cpp is_polymorphic_type_assignable
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
// soa_add_entity_to_scope inserts a synthesized #soa field into the struct's scope, reporting a
// redeclaration if the name is already taken. Blank identifiers are skipped.
//
// C++ Reference: check_type.cpp:2996-3004. Lifted out of complete_soa_type in t243p (body
// unchanged) so that soa_add_extra_fields can reach it -- a nested procedure cannot be called
// from file scope.
soa_add_entity_to_scope :: proc(scope: ^Scope, entity: ^Entity) {
	name := entity.token.text
	if !is_blank_ident(name) {
		existing := scope_insert(scope, entity)
		if existing != nil {
			redeclaration_error(name, entity, existing)
		}
	}
}

// soa_add_extra_fields appends the synthetic trailing fields every non-Fixed #soa struct carries:
// __$len for Slice and Dynamic, plus __$cap and allocator for Dynamic. Fixed carries none, so this
// is a no-op there. `field_count` is the number of real spread fields already written, which is
// where the extras start; it is 0 for a polymorphic struct.
//
// C++ Reference: check_type.cpp:3422-3441, the `if (is_complete && soa_kind != StructSoa_Fixed)`
// block in make_soa_struct_internal.
//
// EXTRACTED IN t243p, AND WHY IT MATTERS. C++ reaches this block from BOTH of its completed paths
// -- polymorphic (:3344 sets is_complete = true) and concrete (:3382, :3418) -- because the gate is
// `is_complete`, not the route taken. The port had the block INLINE in complete_soa_type, reachable
// only from the concrete path, so the polymorphic path silently skipped it. That is the identical
// failure mode to FIX 9 one level up: a rule with two callers, written once, drifting because the
// second caller never ran it. Sharing one definition is what stops it recurring.
soa_add_extra_fields :: proc(checker: ^Checker, ts: ^Type_Struct, scope: ^Scope, field_count: int) {
	if ts.soa_kind == .Fixed {
		return
	}

	// C++ lines 3423-3426: __$len
	len_token := make_token_ident("__$len")
	len_field := alloc_entity_field(scope, len_token, t_int, false, i32(field_count) + 0)
	ts.fields[field_count + 0] = len_field
	soa_add_entity_to_scope(scope, len_field)
	len_field.flags += {.Used}

	// C++ lines 3428-3440: __$cap and allocator, Dynamic only
	if ts.soa_kind == .Dynamic {
		cap_token := make_token_ident("__$cap")
		cap_field := alloc_entity_field(scope, cap_token, t_int, false, i32(field_count) + 1)
		ts.fields[field_count + 1] = cap_field
		soa_add_entity_to_scope(scope, cap_field)
		cap_field.flags += {.Used}

		// C++ line 3435: init_mem_allocator(ctx->checker)
		init_mem_allocator(checker)
		allocator_token := make_token_ident("allocator")
		allocator_field := alloc_entity_field(scope, allocator_token, checker.t_allocator, false, i32(field_count) + 2)
		ts.fields[field_count + 2] = allocator_field
		soa_add_entity_to_scope(scope, allocator_field)
		allocator_field.flags += {.Used}
	}
}

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

	// C++ Reference: check_type.cpp:2966-2968 --
	//     if (t->Struct.fields_wait_signal.futex.load()) { return true; }
	//
	// This guard is NOT an optimization, and the note that used to sit here calling it one --
	// and skipping it because "Wait_Group doesn't expose load directly" -- was wrong on both
	// counts. It is the idempotence guard, and since the Wait_Signal port it is a DIRECT
	// transcription of the C++ line above: wait_signal_is_set is that `.futex.load()`.
	//
	// Without it complete_soa_type ran its whole body every time it was called, including the
	// unconditional `wait_group_done` at the end. alloc_type_struct starts the counter at 1, so
	// the second completion drove it to -1 and `sync.wait_group_add` panicked with
	// "sync.Wait_Group negative counter" (that was under the old Wait_Group emulation; a
	// Wait_Signal cannot go negative, but the guard is still required for idempotence and is
	// what C++ does). Two callers reach the same type in ordinary code:
	// make_soa_struct_internal completes it inline when the element's fields are ready,
	// and the selector path completes it again on first field access
	// (check_expr.odin:4876, complete_soa_type(..., true)). So
	//     x: #soa[]S
	//     _ = x.a
	// -- valid Odin the oracle accepts silently -- aborted the checker outright, for every #soa
	// form (slice, array, dynamic) and for a valid field just as much as a misspelled one.
	//
	// Since the Wait_Signal port the test is the same one C++ makes: the signal is SET exactly
	// when a completion has already run.
	if wait_signal_is_set(&ts.fields_wait_signal) {
		return true
	}

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
		// t243p. C++ Reference: check_type.cpp:3337-3344, then :3422 and :3447.
		//
		//     if (is_polymorphic) {
		//         field_count = 0;
		//         soa_struct->Struct.fields = permanent_slice_make<Entity *>(field_count+extra_field_count);
		//         soa_struct->Struct.tags   = gb_alloc_array(..., field_count+extra_field_count);
		//         soa_struct->Struct.soa_count = 0;
		//         is_complete = true;
		//     }
		//
		// The `is_complete = true` is the whole point: C++ then FALLS THROUGH to the shared
		// extra-field block (:3422, gated `is_complete && soa_kind != StructSoa_Fixed`) and to
		// `add_type_info_type` + `wait_signal_set` (:3447, gated `is_complete`). Neither is gated
		// on HOW the struct got here, so a polymorphic #soa is completed exactly like a concrete
		// one -- it just has zero spread fields.
		//
		// This arm previously did `ts.soa_count = 0; return true`, which looked equivalent to the
		// C++ comment above it but was not: it returned BEFORE the extra-field block and BEFORE
		// the wait signal. Two consequences, one latent and one live:
		//   * no wait signal -- the FIX 9 hang shape, latent here only because polymorphic bodies
		//     are checked at instantiation with concrete types (5 forms tried, wit_polysoa243).
		//   * no __$len -- a polymorphic Slice/Dynamic #soa had no length field at all.
		// The live defect was elsewhere: because make_soa_struct_internal's polymorphic branch
		// never CALLED complete_soa_type, the `ts.soa_count = 0` above was UNREACHABLE, so the
		// struct kept the written count and the port ACCEPTED `f :: proc(x: #soa[4]$T)` applied to
		// `#soa[4]P`, which the reference REJECTS. Witness wit_polysoa243/pfixed.
		ts.soa_count = 0
		ts.fields = make([dynamic]^Entity, int(extra_field_count))
		ts.tags = make([dynamic]string, int(extra_field_count))
		soa_add_extra_fields(checker, ts, ts.scope, 0)
		wait_signal_set(&ts.fields_wait_signal)
		return true
	}

	// C++ lines 2978-2982: Get source struct information
	scope := ts.scope
	soa_count := ts.soa_count
	elem := ts.soa_elem
	old_struct := base_type(elem)

	// #754: an #soa of an ARRAY element (`#soa[4][3]f32`) is legal -- make_soa_struct_internal
	// validates it ("expected a struct or array of length 4 or below"), and the oracle
	// accepts it. C++ never reaches ITS identical assert because make_soa_struct_internal
	// spreads array elements into x/y/z/w fields INLINE and never queues them. The port had no
	// such branch, so an array element passed validation, fell through to the struct path, and
	// hit the assert below -- aborting the whole checker (SIGILL) on code the reference compiles
	// cleanly. The gap was noted as "pre-existing and out of scope"; what that note did
	// not record is that the cost is a hard crash, not a degraded result.
	//
	// `src_field_count` is the number of fields to copy FROM A SOURCE STRUCT, and is 0 for an
	// array element because this branch has already populated ts.fields itself. `field_count`
	// stays the real field count either way, because the extra-field block below indexes from it.
	// C++ Reference: check_type.cpp make_soa_struct_internal.
	src_field_count := 0
	old_ts: ^Type_Struct = nil

	if old_array, is_array_elem := &old_struct.variant.(Type_Array); is_array_elem {
		field_count = int(old_array.count)
		ts.fields = make([dynamic]^Entity, field_count + int(extra_field_count))
		ts.tags = make([dynamic]string, field_count + int(extra_field_count))

		// C++ names them from a fixed 4-entry table, which is exactly why the validation rule
		// above caps an array element at length 4.
		params_xyzw := [4]string{"x", "y", "z", "w"}
		for i in 0 ..< field_count {
			field_type: ^Type = nil
			if ts.soa_kind == .Fixed {
				assert(soa_count >= 0)
				field_type = alloc_type_array(old_array.elem, soa_count)
			} else {
				field_type = alloc_type_multi_pointer(old_array.elem)
			}

			new_field := alloc_entity_field(scope, make_token_ident(params_xyzw[i]), field_type, false, i32(i))
			ts.fields[i] = new_field
			name := new_field.token.text
			if !is_blank_ident(name) {
				existing := scope_insert(scope, new_field)
				if existing != nil {
					redeclaration_error(name, new_field, existing)
				}
			}
			new_field.flags += {.Used}
			if ts.soa_kind != .Fixed {
				new_field.flags += {.Soa_Ptr_Field}
			}
		}
	} else {
		// C++ line 2982: Verify element is a struct
		assert(old_struct.kind == .Struct, "SOA element must be struct type")

		// C++ lines 2984-2988: Wait for source struct fields to be ready
		old_ts = &old_struct.variant.(Type_Struct)
		if wait_to_finish {
			// Wait for struct fields to be resolved
			wait_signal_until_available(&old_ts.fields_wait_signal)
		}
		// Note: If not wait_to_finish, we assume fields are already resolved (callee responsibility)

		// C++ line 2990: Get field count
		field_count = len(old_ts.fields)
		src_field_count = field_count

		// C++ lines 2992-2993: Allocate field arrays
		ts.fields = make([dynamic]^Entity, field_count + int(extra_field_count))
		ts.tags = make([dynamic]string, field_count + int(extra_field_count))
	}

	// C++ lines 2996-3004: the entity-insert helper was NESTED here until t243p. It is now the
	// file-scope soa_add_entity_to_scope, because soa_add_extra_fields needs it and a nested
	// procedure is not reachable from file scope. Body unchanged.

	// C++ lines 3007-3029: Transform fields from source struct.
	// #754: bounded by `src_field_count`, which is 0 for an ARRAY element -- that branch built
	// ts.fields itself above and has no source struct to copy from (old_ts is nil there).
	for i in 0 ..< src_field_count {
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
			soa_add_entity_to_scope(scope, new_field)
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

	// C++ lines 3031-3049 / 3422-3441: Add extra fields for Slice/Dynamic.
	// t243p: extracted to soa_add_extra_fields so the POLYMORPHIC path runs it too. See that
	// procedure's comment for why sharing it is the actual fix and not a tidy-up.
	soa_add_extra_fields(checker, ts, scope, field_count)

	// C++ line 3051: Add type info (commented out in C++)
	// add_type_info_type(ctx, original_type)

	// C++ line 3053: Signal completion
	// Note: For SOA types created via complete_soa_type, the fields_wait_signal
	// was already initialized in alloc_type_struct, so we signal done here
	wait_signal_set(&ts.fields_wait_signal)

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
			// C++ Reference: check_type.cpp:2864-2871. C++ accepts the count only when the
			// BigInt occupies AT MOST ONE limb -- `switch (count.used) { case 0: return 0;
			// case 1: return big_int_to_u64(&count); }` -- and anything wider falls through
			// to "Array count too large". BigInt is a libtommath mp_int and MP_DIGIT_BIT is
			// 60 on every 64-bit target (src/libtommath/tommath.h:58-60), so the threshold is
			// a magnitude below 2^60, NOT "fits in an i64".
			//
			// This CANNOT be written as `count.used <= 1` against core:math/big: that library
			// uses 63-bit digits (_DIGIT_TYPE_BITS - _DIGIT_NAILS, core/math/big/common.odin:207),
			// so mirroring the field would put the threshold at 2^63 and keep accepting the
			// counts the reference rejects.
			CPP_MP_DIGIT_BIT :: 60
			bits, bits_err := big.count_bits(&count)
			result, get_err := big.int_get_i64(&count)
			if bits_err != nil || get_err != nil || bits > CPP_MP_DIGIT_BIT {
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

