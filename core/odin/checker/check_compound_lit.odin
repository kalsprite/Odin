package checker

/*
Core compound literals (struct, array, slice).

Reference: check_expr.cpp:9549-10728
*/

import "core:math/big"
import "core:odin/ast"
import "core:sync"

// check_compound_literal_field_values checks named field values in struct literals
// Reference: check_expr.cpp:9549-9702
//
// Validates:
// - All elements are Field_Value nodes
// - Field names exist in struct
// - No duplicate fields
// - Field value types match
check_compound_literal_field_values :: proc(ctx: ^Checker_Context, elems: []^ast.Expr, o: ^Operand, type: ^Type, is_constant: ^bool) {
	bt := base_type(type)

	// Track visited fields
	fields_visited := make(map[string]bool)
	defer delete(fields_visited)

	// Track fields visited through raw_union paths
	// Maps field name -> name of raw_union field that initialized it
	// C++ Reference: checker.cpp:9634-9635
	fields_visited_through_raw_union := make(map[string]string)
	defer delete(fields_visited_through_raw_union)

	// Determine assignment context string based on type
	// C++ Reference: checker.cpp:9637-9640
	assignment_str := "structure literal"
	if bt.kind == .Bit_Field {
		// C++ Reference: check_expr.cpp:10289 -- the inner quotes are part of the string.
		assignment_str = "'bit_field' literal"
	}

	for elem in elems {
		// Validate element is Field_Value
		// Reference: C++ lines 9564-9567
		fv, is_field_value := elem.derived.(^ast.Field_Value)
		if !is_field_value {
			error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
			continue
		}

		// Get field name
		// Reference: C++ lines 9569-9583
		field_expr := fv.field

		// Handle implicit selector (e.g., .field)
		// Reference: C++ lines 9570-9576
		if implicit_sel, is_implicit := field_expr.derived.(^ast.Implicit_Selector_Expr); is_implicit {
			expr_str := expr_to_string(field_expr)
			defer delete(expr_str)
			// C++ Reference: check_expr.cpp:10300 -- names the expression AND the context.
			// The port dropped the "from '%s'" clause and hardcoded "structure literal",
			// which is wrong for a bit_field literal.
			error(field_expr, "Field names do not start with a '.', remove the '.' from '%s' in %s", expr_str, assignment_str)
			field_expr = implicit_sel.field
		}

		// Validate field is identifier
		// Reference: C++ lines 9577-9582
		ident, is_ident := field_expr.derived.(^ast.Ident)
		if !is_ident {
			expr_str := expr_to_string(field_expr)
			defer delete(expr_str)
			error(elem, "Invalid field name '%s' in %s", expr_str, assignment_str)
			continue
		}

		field_name := ident.name

		// Look up field in struct
		// Reference: C++ lines 9585-9590
		sel := lookup_field(type, field_name, o.mode == .Type)
		if sel.entity == nil {
			error(field_expr, "Unknown field '%s' in %s", field_name, assignment_str)
			continue
		}

		// Get field entity
		// Reference: C++ lines 9671-9678
		field: ^Entity
		#partial switch v in bt.variant {
		case Type_Struct:
			if len(sel.index) > 0 {
				field = v.fields[sel.index[0]]
			}
		case Type_Bit_Field:
			// C++ Reference: checker.cpp:9674-9675
			if len(sel.index) > 0 {
				field = v.fields[sel.index[0]]
			}
		case:
			// Unknown type - should not happen if lookup_field succeeded
			// C++ Reference: checker.cpp:9676-9677
			assert(false, "Unknown type in compound literal field extraction")
		}

		if field == nil {
			continue
		}

		// Track entity use
		// Reference: C++ line 9602
		add_entity_use(ctx, field_expr, field)

		// Check for duplicate fields
		// Reference: C++ lines 9682-9696
		if field_name in fields_visited {
			// Check if this is a nested field accessed through raw_union
			// C++ Reference: checker.cpp:9683-9689
			if len(sel.index) > 1 {
				// Check if conflict due to raw_union path
				if union_field, found := fields_visited_through_raw_union[sel.entity.token.text]; found {
					error(field_expr, "Field '%s' is already initialized due to a previously assigned struct #raw_union field '%s'", sel.entity.token.text, union_field)
				} else {
					error(field_expr, "Duplicate or reused field '%s' in %s", sel.entity.token.text, assignment_str)
				}
			} else {
				// Direct duplicate field
				// C++ Reference: checker.cpp:9690
				error(field_expr, "Duplicate field '%s' in %s", field.token.text, assignment_str)
			}
			continue
		} else if union_field, found := fields_visited_through_raw_union[sel.entity.token.text]; found {
			// Field was already initialized through a raw_union path
			// C++ Reference: checker.cpp:9693-9696
			error(field_expr, "Field '%s' is already initialized due to a previously assigned struct #raw_union field '%s'", sel.entity.token.text, union_field)
			continue
		}

		// Check for indirect field
		// Reference: C++ lines 9618-9621
		if sel.indirect {
			error(field_expr, "Cannot assign to the %d-nested anonymous indirect field '%s' in a %s", len(sel.index) - 1, field_name, assignment_str)
			continue
		}

		// Handle nested anonymous fields
		// Reference: C++ lines 9623-9678
		if len(sel.index) > 1 {
			// Multi-level field access through anonymous structs
			// This affects constant-ness tracking

			if is_constant^ {
				// Check if path through nested fields can be constant
				// Reference: C++ lines 9705-9732
				ft := type
				for index in sel.index {
					bt_nested := base_type(ft)
					#partial switch v in bt_nested.variant {
					case Type_Struct:
						if v.is_raw_union {
							is_constant^ = false
							break
						}
						ft = entity_type(v.fields[index])
					case Type_Array:
						ft = v.elem
					case Type_Bit_Field:
						// C++ Reference: checker.cpp:9720-9723
						// Bit fields cannot be constant
						is_constant^ = false
						ft = entity_type(v.fields[index])
					case:
						// Unexpected type in nested path
						// C++ Reference: checker.cpp:9724-9726
						ft = t_invalid
						break
					}
				}
				if is_constant^ && elem_cannot_be_constant(ft) {
					is_constant^ = false
				}
			}

			// Track raw_union field access for conflict detection
			// Reference: C++ lines 9734-9758
			// When traversing nested anonymous structs, check if any level is a raw_union
			// If so, mark all fields of that raw_union as "visited through" this field path
			nested_ft := bt
			for index in sel.index {
				bt_nested := base_type(nested_ft)
				#partial switch v in bt_nested.variant {
				case Type_Struct:
					// If this level is a raw_union, mark all its fields as visited through the current field
					// C++ Reference: checker.cpp:9738-9743
					if v.is_raw_union {
						for re in v.fields {
							// Map each raw_union field name to the final field name we're initializing
							fields_visited_through_raw_union[re.token.text] = sel.entity.token.text
						}
					}
					nested_ft = entity_type(v.fields[index])
				case Type_Array:
					nested_ft = v.elem
				case Type_Bit_Field:
					// C++ Reference: checker.cpp:9749-9751
					nested_ft = entity_type(v.fields[index])
				case:
					// Unexpected type in nested path
					// C++ Reference: checker.cpp:9752-9754
					nested_ft = t_invalid
					break
				}
			}

			// Update field to actual nested entity
			field = sel.entity
		}

		// Mark field as visited
		fields_visited[field_name] = true

		// Check field value type
		// Reference: C++ lines 9666-9682
		value_operand := Operand{}
		check_expr_or_type(ctx, &value_operand, fv.value, entity_type(field))

		// Check constant-ness
		// Reference: C++ lines 9684-9694
		if elem_cannot_be_constant(entity_type(field)) {
			is_constant^ = false
		}
		if is_constant^ {
			is_constant^ = check_is_operand_compound_lit_constant(ctx, &value_operand, entity_type(field))
		}

		// Handle bit field assignments
		// Reference: C++ lines 9692-9700
		prev_bit_field_bit_size := ctx.bit_field_bit_size
		if field.kind == .Variable && field.variant.(Entity_Variable).bit_field_bit_size != 0 {
			// Set bit_field_bit_size for assignment checking
			// HACK NOTE(bill): This is a bit of a hack, but it will work fine for this use case
			ctx.bit_field_bit_size = i64(field.variant.(Entity_Variable).bit_field_bit_size)
		}

		check_assignment(ctx, &value_operand, entity_type(field), assignment_str)

		ctx.bit_field_bit_size = prev_bit_field_bit_size
	}
}

// check_compound_literal checks compound literal expressions
// Reference: check_expr.cpp:9763-10728
//
// Implemented:
// - Struct literals with named or positional fields
// - Array literals with positional and indexed elements
// - Slice literals
// - Empty literals (zero initialization)
// - SOA struct literals (positional and indexed)
// - Bit_set literals
// - SIMD vector literals
// - Matrix literals
// - Bit_field literals
// - EnumeratedArray literals
// - Indexed/range array initialization ([0] = x, [1..5] = y)
// - Map literals
// - Dynamic array literals
check_compound_literal :: proc(ctx: ^Checker_Context, o: ^Operand, node: ^ast.Node, type_hint: ^Type) -> Expr_Kind {
	kind := Expr_Kind.Expr
	cl := node.derived.(^ast.Comp_Lit)

	// Initialize type from hint
	// Reference: C++ lines 9767-9773
	type := type_hint
	if type != nil && is_type_untyped(type) {
		type = nil
	}

	is_to_be_determined_array_count := false
	is_constant := true
	is_soa := false

	// Get type expression
	// Reference: C++ lines 9775-9833
	type_expr := cl.type

	// Use type_hint_expr if available for [?]T syntax
	// Reference: C++ lines 9856-9862
	used_type_hint_expr := false
	if type_expr == nil && ctx.type_hint_expr != nil {
		if is_expr_inferred_fixed_array(ctx.type_hint_expr) {
			// C++ clones the AST, but in Odin core:odin/ast is immutable so we can reuse
			type_expr = ctx.type_hint_expr
			used_type_hint_expr = true
		}
	}

	// Process type expression
	if type_expr != nil {
		type = nil

		// Handle array type syntax
		if array_type, ok := type_expr.derived.(^ast.Array_Type); ok {
			// Handle [?]T syntax for inferred array count
			// Reference: C++ lines 9867-9878
			count := array_type.len
			if count != nil {
				// Check for [?] syntax
				if unary, is_unary := count.derived.(^ast.Unary_Expr); is_unary {
					if unary.op.kind == .Question {
						// Inferred array count: [?]T{...}
						elem_type := check_type(ctx, array_type.elem)
						type = alloc_type_array(elem_type, -1)
						is_to_be_determined_array_count = true
					}
				}
			} else {
				// Slice type (no count specified)
				elem_type := check_type(ctx, array_type.elem)
				type = alloc_type_slice(elem_type)
			}

			// Check for SOA tag
			// Reference: C++ lines 9879-9895
			if len(cl.elems) > 0 && array_type.tag != nil {
				if tag_expr, ok2 := array_type.tag.derived.(^ast.Tag_Expr); ok2 {
					if tag_expr.name == "soa" {
						is_soa = true
						// Check restrictions on SOA array literals
						if count == nil {
							// #soa slices not supported
							// C++ Reference: checker.cpp:9886-9888
							error(node, "#soa slices are not supported for compound literals")
							return kind
						} else if unary, is_unary := count.derived.(^ast.Unary_Expr); is_unary && unary.op.kind == .Question {
							// #soa arrays cannot use [?] syntax
							// C++ Reference: checker.cpp:9889-9892
							error(node, "#soa fixed length arrays must specify their length and cannot use ?")
						}
					}
				}
			}
		} else if dyn_array_type, ok2 := type_expr.derived.(^ast.Dynamic_Array_Type); ok2 {
			// Handle dynamic array with SOA tag
			// Reference: C++ lines 9896-9907
			if len(cl.elems) > 0 && dyn_array_type.tag != nil {
				if tag_expr, ok3 := dyn_array_type.tag.derived.(^ast.Tag_Expr); ok3 {
					if tag_expr.name == "soa" {
						is_soa = true
						// #soa dynamic arrays not supported
						// C++ Reference: checker.cpp:9901-9904
						error(node, "#soa dynamic arrays are not supported for compound literals")
						return kind
					}
				}
			}
		}

		// Fall back to normal type checking
		if type == nil {
			type = check_type(ctx, type_expr)
		}
	}

	// Require explicit type
	// Reference: C++ lines 9835-9838
	if type == nil {
		error(node, "Missing type in compound literal")
		return kind
	}

	// Get base type and validate
	// Reference: C++ lines 9841-9849
	t := base_type(type)
	if is_type_polymorphic(t) {
		type_str := type_to_string(type)
		error(node, "Cannot use a polymorphic type for a compound literal, got '%s'", type_str)
		o.expr = node
		o.type = type
		return kind
	}

	// Dispatch by type
	// Reference: C++ lines 9852-10663
	#partial switch variant in t.variant {

	case Type_Struct:
		// Struct literal checking
		// Reference: C++ lines 9853-9942

		if len(cl.elems) == 0 {
			break // Empty literal OK
		}

		ts := variant

		// Handle SOA struct literals
		// Reference: C++ lines 10022-10026
		if ts.soa_kind != .None {
			if ts.soa_kind != .Fixed {
				// Reject slices and dynamic arrays (soa_kind == 2 or 3)
				// C++ Reference: checker.cpp:10022-10024
				error(node, "#soa slices and dynamic arrays are not supported for compound literals")
				break
			}
			// StructSoa_Fixed (soa_kind == 1) falls through to array handling in C++
			// C++ Reference: checker.cpp:10025-10026 + 10037-10043
			// In Odin, we can't fall through, so we handle it inline here
			is_soa = true
			elem_type := ts.soa_elem
			context_name := "#soa array literal"
			max_type_count: i64 = -1
			if !is_to_be_determined_array_count {
				max_type_count = ts.soa_count
			}

			// Process elements (same as array literal)
			// Reference: C++ lines 10112-10142 + array validation
			max: i64 = 0

			bet := base_type(elem_type)
			if !elem_type_can_be_constant(bet) {
				is_constant = false
			}

			if bet == t_invalid {
				break
			}

			// Check for indexed/range initialization vs positional elements
			// Reference: C++ lines 10087-10187
			if len(cl.elems) > 0 {
				_, is_field_value := cl.elems[0].derived.(^ast.Field_Value)

				if is_field_value {
					// Indexed/range initialization: [0] = x, [1..3] = y
					// C++ Reference: check_expr.cpp:10088-10187
					rc := range_cache_make()
					defer range_cache_destroy(&rc)

					for elem in cl.elems {
						fv, is_fv := elem.derived.(^ast.Field_Value)
						if !is_fv {
							error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
							continue
						}

						// Check if field is a range expression
						if is_ast_range(fv.field) {
							// Range initialization: [1..5] = value
							// C++ Reference: check_expr.cpp:10098-10152
							x := Operand{}
							y := Operand{}
							ok := check_array_range(ctx, fv.field, false, &x, &y, nil)
							if !ok {
								continue
							}

							if x.mode != .Constant || !is_type_integer(core_type(x.type)) {
								error(x.expr, "Expected a constant integer as an array field")
								continue
							}
							if y.mode != .Constant || !is_type_integer(core_type(y.type)) {
								error(y.expr, "Expected a constant integer as an array field")
								continue
							}

							lo := exact_value_to_i64(x.value)
							hi := exact_value_to_i64(y.value)
							max_index := hi

							// Get the binary operator to check range type
							binary := fv.field.derived.(^ast.Binary_Expr)
							if binary.op.kind == .Range_Half {
								// ..< (exclusive)
								hi -= 1
							} else {
								// .. or ..= (inclusive)
								max_index += 1
							}

							// Check for overlap with existing ranges
							new_range := range_cache_add_range(&rc, lo, hi)
							if !new_range {
								error(elem, "Overlapping field range index %d %s %d for %s", lo, binary.op.text, hi, context_name)
								continue
							}

							// Bounds checking
							if max_type_count >= 0 && (lo < 0 || lo >= max_type_count) {
								error(elem, "Index %d is out of bounds (0..<%d) for %s", lo, max_type_count, context_name)
								continue
							}
							if max_type_count >= 0 && (hi < 0 || hi >= max_type_count) {
								error(elem, "Index %d is out of bounds (0..<%d) for %s", hi, max_type_count, context_name)
								continue
							}

							if max < hi {
								max = max_index
							}

							// Check the value expression
							operand := Operand{}
							check_expr_with_type_hint(ctx, &operand, fv.value, elem_type)
							check_assignment(ctx, &operand, elem_type, context_name)

							if is_constant {
								is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
							}
						} else {
							// Single index initialization: [0] = value
							// C++ Reference: check_expr.cpp:10153-10186
							op_index := Operand{}
							check_expr(ctx, &op_index, fv.field)

							if op_index.mode != .Constant || !is_type_integer(core_type(op_index.type)) {
								error(elem, "Expected a constant integer as an array field")
								continue
							}

							index := exact_value_to_i64(op_index.value)

							// Bounds checking
							if max_type_count >= 0 && (index < 0 || index >= max_type_count) {
								error(elem, "Index %d is out of bounds (0..<%d) for %s", index, max_type_count, context_name)
								continue
							}

							// Check for duplicate index
							new_index := range_cache_add_index(&rc, index)
							if !new_index {
								error(elem, "Duplicate field index %d for %s", index, context_name)
								continue
							}

							if max < index + 1 {
								max = index + 1
							}

							// Check the value expression
							operand := Operand{}
							check_expr_with_type_hint(ctx, &operand, fv.value, elem_type)
							check_assignment(ctx, &operand, elem_type, context_name)

							if is_constant {
								is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
							}
						}
					}
				} else {
					// Positional elements (non-indexed)
					// Reference: C++ lines 10112-10142
					for elem, index in cl.elems {
						if elem == nil {
							error(node, "Invalid literal element")
							continue
						}

						if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
							error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
							continue
						}

						if 0 <= max_type_count && max_type_count <= i64(index) {
							error(elem, "Index %d is out of bounds (>= %d) for %s", index, max_type_count, context_name)
						}

						operand := Operand{}
						check_expr_or_type(ctx, &operand, elem, elem_type)
						check_assignment(ctx, &operand, elem_type, context_name)

						if is_constant {
							is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
						}
					}

					if max < i64(len(cl.elems)) {
						max = i64(len(cl.elems))
					}
				}
			}

			// Validate count for SOA Fixed arrays
			if max_type_count >= 0 && len(cl.elems) > 0 {
				if 0 < max && max < ts.soa_count {
					error(node, "Expected %d values for this #soa array literal, got %d", ts.soa_count, max)
				}
			}

			// Done with SOA Fixed struct literal
			break
		}

		// Handle raw_union struct literals
		// Reference: C++ lines 9937-9958
		if ts.is_raw_union {
			if len(cl.elems) > 0 {
				// NOTE: unions cannot be constant
				// C++ Reference: checker.cpp:9940-9941
				is_constant = elem_type_can_be_constant(t)

				// Check that all elements are Field_Value (no positional syntax)
				// C++ Reference: checker.cpp:9943-9946
				if len(cl.elems) > 0 {
					if _, is_fv := cl.elems[0].derived.(^ast.Field_Value); !is_fv {
						type_str := type_to_string(type)
						error(node, "%s ('struct #raw_union') compound literals are only allowed to contain 'field = value' elements", type_str)
					} else {
						// Check that only 1 field is initialized
						// C++ Reference: checker.cpp:9948-9954
						if len(cl.elems) != 1 {
							type_str := type_to_string(type)
							error(node, "%s ('struct #raw_union') compound literals are only allowed to contain up to 1 'field = value' element, got %d", type_str, len(cl.elems))
						} else {
							// Use the standard field checking (already handles raw_union conflicts)
							check_compound_literal_field_values(ctx, cl.elems, o, type, &is_constant)
						}
					}
				}
			}
			break
		}

		// Wait for struct fields to be resolved
		// Reference: C++ lines 9881-9892
		sync.wait_group_wait(&ts.fields_wait_signal)

		field_count := len(ts.fields)
		min_field_count := field_count

		// Count fields with default values to compute min_field_count
		// Reference: C++ lines 9963-9971
		// Fields with default values at the end don't need to be specified in literals
		for i := min_field_count - 1; i >= 0; i -= 1 {
			e := ts.fields[i]
			assert(e.kind == .Variable, "Struct field must be a Variable entity")
			if ev, ok := e.variant.(Entity_Variable); ok {
				if ev.param_value.kind != .Invalid {
					min_field_count -= 1
				} else {
					break
				}
			}
		}

		// Check if using named fields
		if len(cl.elems) > 0 {
			if _, is_field_value := cl.elems[0].derived.(^ast.Field_Value); is_field_value {
				// Named field syntax
				// Reference: C++ line 9895
				check_compound_literal_field_values(ctx, cl.elems, o, type, &is_constant)
			} else {
				// Positional field syntax
				// Reference: C++ lines 9896-9940

				seen_field_value := false

				// `index` is the field this element fills, which runs ahead of
				// the element position once a multi-valued element expands
				// across several fields (`S{returns_two(), 3}`).
				// `handled_elem_count` is how many fields have been filled.
				index := 0
				handled_elem_count := 0
				for elem in cl.elems {
					defer index += 1

					if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
						seen_field_value = true
						error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
						continue
					} else if seen_field_value {
						error(elem, "Value elements cannot be used after a 'field = value'")
						continue
					}

					if index >= field_count {
						error(elem, "Too many values in structure literal, expected %d, got %d", field_count, len(cl.elems))
						break
					}

					field := ts.fields[index]

					elem_operand := Operand{}
					check_multi_expr_with_type_hint(ctx, &elem_operand, elem, entity_type(field))

					if elem_operand.type != nil && elem_operand.type.kind == .Tuple {
						// A multi-valued element spreads across consecutive fields.
						// C++ Reference: check_expr.cpp check_compound_literal,
						// the `is_type_tuple(o.type)` branch of the struct
						// positional element loop.
						is_constant = false

						tuple := elem_operand.type.variant.(Type_Tuple)
						count := len(tuple.variables)
						for src_field, jj in tuple.variables {
							if index + jj >= field_count {
								error(elem, "Too many values in structure literal, expected %d, got %d", field_count, index + count)
								break
							}
							src_operand := elem_operand
							src_operand.type = src_field.type

							dst_field := ts.fields[index + jj]
							check_assignment(ctx, &src_operand, entity_type(dst_field), "structure literal")
						}

						index += count - 1
						handled_elem_count += count
					} else {
						check_not_tuple(ctx, &elem_operand)

						// Check if can be constant
						// Reference: C++ lines 9922-9927
						if elem_cannot_be_constant(entity_type(field)) {
							is_constant = false
						}
						if is_constant {
							is_constant = check_is_operand_compound_lit_constant(ctx, &elem_operand, entity_type(field))
						}

						check_assignment(ctx, &elem_operand, entity_type(field), "structure literal")
						handled_elem_count += 1
					}
				}

				// Validate element count
				// Reference: C++ lines 9931-9939
				if len(cl.elems) < field_count {
					if min_field_count < field_count {
						if len(cl.elems) < min_field_count {
							error(node, "Too few values in structure literal, expected at least %d, got %d", min_field_count, len(cl.elems))
						}
					} else if handled_elem_count != field_count {
						error(node, "Too few values in structure literal, expected %d, got %d", field_count, len(cl.elems))
					}
				}
			}
		}

	case Type_Array, Type_Slice, Type_Fixed_Capacity_Dynamic_Array:
		// Array, slice and fixed-capacity-dynamic-array literal checking
		// Reference: C++ lines 9949-10187
		//
		// LEDGER #309: Type_Fixed_Capacity_Dynamic_Array was the ONE kind C++'s chain
		// (check_expr.cpp:10781-10810) covers that this switch did not, so `x: [dynamic; 2]int
		// = {1, 2}` -- entirely legal -- fell through to the catch-all and was rejected with
		// "Invalid compound literal type". An OVER-rejection: valid code refused. #53 ported the
		// TYPE and #127 audited its sites, but the literal form was not among them.
		//
		// It belongs HERE rather than with Type_Dynamic_Array because C++ treats it as bounded,
		// like an array: it sets max_type_count from the capacity and, unlike the dynamic-array
		// branch one line above it, does NOT set is_constant = false.

		elem_type: ^Type
		context_name: string
		max_type_count: i64 = -1

		if arr, is_array := variant.(Type_Array); is_array {
			elem_type = arr.elem
			context_name = "array literal"
			if !is_to_be_determined_array_count {
				max_type_count = arr.count
			}
		} else if slice, is_slice := variant.(Type_Slice); is_slice {
			elem_type = slice.elem
			context_name = "slice literal"
		} else if fc, is_fc := variant.(Type_Fixed_Capacity_Dynamic_Array); is_fc {
			// C++ Reference: check_expr.cpp:10799-10802. context_name is what the shared
			// index-bounds diagnostics interpolate, so this spelling is what produces
			// "Index 2 is out of bounds (>= 2) for fixed capacity dynamic array literal".
			elem_type = fc.elem
			context_name = "fixed capacity dynamic array literal"
			max_type_count = fc.capacity
		}

		max: i64 = 0

		bet := base_type(elem_type)
		if !elem_type_can_be_constant(bet) {
			is_constant = false
		}

		if bet == t_invalid {
			break
		}

		// Check for indexed/range initialization vs positional elements
		// Reference: C++ lines 10087-10187
		if len(cl.elems) > 0 {
			_, is_field_value := cl.elems[0].derived.(^ast.Field_Value)

			if is_field_value {
				// Indexed/range initialization: [0] = x, [1..3] = y
				// C++ Reference: check_expr.cpp:10088-10187
				rc := range_cache_make()
				defer range_cache_destroy(&rc)

				for elem in cl.elems {
					fv, is_fv := elem.derived.(^ast.Field_Value)
					if !is_fv {
						error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
						continue
					}

					// Check if field is a range expression
					if is_ast_range(fv.field) {
						// Range initialization: [1..5] = value
						// C++ Reference: check_expr.cpp:10098-10152
						x := Operand{}
						y := Operand{}
						ok := check_array_range(ctx, fv.field, false, &x, &y, nil)
						if !ok {
							continue
						}

						if x.mode != .Constant || !is_type_integer(core_type(x.type)) {
							error(x.expr, "Expected a constant integer as an array field")
							continue
						}
						if y.mode != .Constant || !is_type_integer(core_type(y.type)) {
							error(y.expr, "Expected a constant integer as an array field")
							continue
						}

						lo := exact_value_to_i64(x.value)
						hi := exact_value_to_i64(y.value)
						max_index := hi

						// Get the binary operator to check range type
						binary := fv.field.derived.(^ast.Binary_Expr)
						if binary.op.kind == .Range_Half {
							// ..< (exclusive)
							hi -= 1
						} else {
							// .. or ..= (inclusive)
							max_index += 1
						}

						// Check for overlap with existing ranges
						new_range := range_cache_add_range(&rc, lo, hi)
						if !new_range {
							error(elem, "Overlapping field range index %d %s %d for %s", lo, binary.op.text, hi, context_name)
							continue
						}

						// Bounds checking
						if max_type_count >= 0 && (lo < 0 || lo >= max_type_count) {
							error(elem, "Index %d is out of bounds (0..<%d) for %s", lo, max_type_count, context_name)
							continue
						}
						if max_type_count >= 0 && (hi < 0 || hi >= max_type_count) {
							error(elem, "Index %d is out of bounds (0..<%d) for %s", hi, max_type_count, context_name)
							continue
						}

						if max < hi {
							max = max_index
						}

						// Check the value expression
						operand := Operand{}
						check_expr_with_type_hint(ctx, &operand, fv.value, elem_type)
						check_assignment(ctx, &operand, elem_type, context_name)

						if is_constant {
							is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
						}
					} else {
						// Single index initialization: [0] = value
						// C++ Reference: check_expr.cpp:10153-10186
						op_index := Operand{}
						check_expr(ctx, &op_index, fv.field)

						if op_index.mode != .Constant || !is_type_integer(core_type(op_index.type)) {
							error(elem, "Expected a constant integer as an array field")
							continue
						}

						index := exact_value_to_i64(op_index.value)

						// Bounds checking
						if max_type_count >= 0 && (index < 0 || index >= max_type_count) {
							error(elem, "Index %d is out of bounds (0..<%d) for %s", index, max_type_count, context_name)
							continue
						}

						// Check for duplicate index
						new_index := range_cache_add_index(&rc, index)
						if !new_index {
							error(elem, "Duplicate field index %d for %s", index, context_name)
							continue
						}

						if max < index + 1 {
							max = index + 1
						}

						// Check the value expression
						operand := Operand{}
						check_expr_with_type_hint(ctx, &operand, fv.value, elem_type)
						check_assignment(ctx, &operand, elem_type, context_name)

						if is_constant {
							is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
						}
					}
				}
			} else {
				// Positional elements (non-indexed)
				// Reference: C++ lines 10112-10142
				// `max` counts the slots consumed, which is more than the number
				// of elements once a multi-valued element expands
				// (`[]int{returns_two(), 3}`).
				for elem in cl.elems {
					index := max
					defer max += 1

					if elem == nil {
						error(node, "Invalid literal element")
						continue
					}

					if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
						error(elem, "Mixture of 'field = value' and value elements in a literal is not allowed")
						continue
					}

					if 0 <= max_type_count && max_type_count <= index {
						error(elem, "Index %d is out of bounds (>= %d) for %s", index, max_type_count, context_name)
					}

					operand := Operand{}
					check_multi_expr_with_type_hint(ctx, &operand, elem, elem_type)

					if operand.type != nil && operand.type.kind == .Tuple {
						// A multi-valued element spreads across consecutive slots.
						// C++ Reference: check_expr.cpp check_compound_literal,
						// the `is_type_tuple(operand.type)` branch of the
						// array/slice positional element loop.
						is_constant = false

						tuple := operand.type.variant.(Type_Tuple)
						for tuple_field in tuple.variables {
							elem_operand := operand
							elem_operand.type = tuple_field.type
							check_assignment(ctx, &elem_operand, elem_type, context_name)
						}

						max += i64(len(tuple.variables)) - 1
					} else {
						check_assignment(ctx, &operand, elem_type, context_name)

						if is_constant {
							is_constant = check_is_operand_compound_lit_constant(ctx, &operand, elem_type)
						}
					}
				}
			}
		}

		// Validate array count
		// Reference: C++ lines 10224-10231
		if arr, is_array := variant.(Type_Array); is_array {
			if is_to_be_determined_array_count {
				// Set inferred array count for [?]T syntax
				// C++ Reference: checker.cpp:10226
				arr_type := &t.variant.(Type_Array)
				arr_type.count = max
			} else if len(cl.elems) > 0 {
				_, not_field_value := cl.elems[0].derived.(^ast.Field_Value)
				if !not_field_value {
					if 0 < max && max < arr.count {
						error(node, "Expected %d values for this array literal, got %d", arr.count, max)
					}
				}
			}
		}

		// C++ Reference: check_expr.cpp:10992-10997. Note the asymmetry with the array case just
		// above, which is C++'s and not a slip: an array literal is faulted for having TOO FEW
		// values, a fixed-capacity one only for having too many. The capacity is an upper bound,
		// not a required length.
		if fc, is_fc := variant.(Type_Fixed_Capacity_Dynamic_Array); is_fc {
			if max > fc.capacity {
				error(
					node,
					"Expected a maximum of %d values for this fixed capacity dynamic array, got %d",
					fc.capacity,
					max,
				)
			}
		}

	case Type_Map:
		// Map literal: map[string]int{"a" = 1, "b" = 2}
		// Reference: C++ lines 10535-10575
		//
		// Dynamic literals are opt-in: C++ gates them on a per-file
		// `#+feature dynamic-literals` or the project-wide build setting
		// (check_expr.cpp:11009 for [dynamic]T, :11409 for map). Only reported for a
		// NON-EMPTY literal. `check_for_dynamic_literals` already existed with zero call
		// sites; the feature flags it reads are populated in check_files.odin.
		//
		// C++ Reference: check_expr.cpp:11423-11426. The RESULT is the gate:
		//     if (check_for_dynamic_literals(c, node, cl)) {
		//         add_map_reserve_dependencies(c);
		//         add_map_set_dependencies(c);
		//     }
		// The port called the predicate for its DIAGNOSTIC only and discarded the bool, so a
		// dynamic map literal registered neither helper. Same defect shape as #303.
		if len(cl.elems) > 0 {
			if check_for_dynamic_literals(ctx, node) {
				add_map_reserve_dependencies(ctx)
				add_map_set_dependencies(ctx)
			}
		}
		mp := variant
		key_type := mp.key
		value_type := mp.value

		// C++ Reference: check_expr.cpp:11374-11407. This arm was a REIMPLEMENTATION, not a
		// port, and diverged in five ways -- two of which rejected valid code:
		//   1. Elements were checked with a bare check_expr, no type hint, so an
		//      implicit-selector key (`map[E]int{.A = 1}`) had nothing to resolve against
		//      and drew a spurious "Cannot determine type for implicit selector expression".
		//   2. No typeid branch, so a typeid-keyed literal (`map[typeid]int{int = 1}`) drew
		//      a spurious "'int' is not an expression but a type".
		//   3. check_assignment was replaced by check_is_assignable_to plus two invented
		//      messages ("Cannot use '%s' as key in map[%s]"), losing C++'s wording.
		//   4. The invalid-bail sat BEFORE the assignment check rather than after it.
		//   5. A failed key `continue`d past the VALUE, so its diagnostics were dropped.
		// The empty-literal break also comes BEFORE is_constant is cleared in C++ (:11375).
		if len(cl.elems) == 0 {
			break
		}
		is_constant = false

		key_is_typeid := is_type_typeid(key_type)
		value_is_typeid := is_type_typeid(value_type)

		for elem in cl.elems {
			fv, is_fv := elem.derived.(^ast.Field_Value)
			if !is_fv {
				error(elem, "Only 'field = value' elements are allowed in a map literal")
				continue
			}

			if key_is_typeid {
				check_expr_or_type(ctx, o, fv.field, key_type)
			} else {
				check_expr_with_type_hint(ctx, o, fv.field, key_type)
			}
			check_assignment(ctx, o, key_type, "map literal")
			if o.mode == .Invalid {
				continue
			}

			if value_is_typeid {
				check_expr_or_type(ctx, o, fv.value, value_type)
			} else {
				check_expr_with_type_hint(ctx, o, fv.value, value_type)
			}
			check_assignment(ctx, o, value_type, "map literal")
		}

	case Type_Bit_Set:
		// Bit_set literal: bit_set[Enum]{.Value_A, .Value_B}
		// Reference: C++ lines 10577-10635
		bs := variant

		// Get the element type for validation
		// C++ Reference: check_expr.cpp:11420-11460.
		//
		// Two DIFFERENT types are in play and using one for both is what produced ~2,888
		// spurious "Cannot use 'X' as an element in bit_set[...]" errors:
		//   elem_hint — base_type(BitSet.elem), pushed down so `.Foo` resolves at all
		//               (C++ :11439 passes exactly this to check_expr_with_type_hint)
		//   elem_type — the DECLARED BitSet.elem, which is what the element must be
		//               assignable TO (C++ :11460 check_assignment against BitSet.elem)
		elem_type := bs.elem
		elem_hint := base_type(bs.elem)

		// Process each element in the bit_set literal
		for elem in cl.elems {
			// Bit_set literals cannot use named fields
			// Reference: C++ lines 10579-10583
			// C++ Reference: check_expr.cpp:11431-11435. C++ also clears is_constant here;
			// the port errored and continued, leaving the literal constant.
			if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
				error(elem, "'field = value' in a bit_set literal is not allowed")
				is_constant = false
				continue
			}

			// Check if element is a range expression (e.g., .A..=.C)
			// Reference: C++ lines 10585-10605
			elem_expr := unparen_expr(elem)
			if is_ast_range(cast(^ast.Expr)elem_expr) {
				// Range expression in bit_set
				if be, is_binary := elem_expr.derived.(^ast.Binary_Expr); is_binary {
					// Check both endpoints
					lhs_op, rhs_op: Operand
					// Range endpoints need the same hint: `.A ..= .C`.
					check_expr_with_type_hint(ctx, &lhs_op, be.left, elem_hint)
					check_expr_with_type_hint(ctx, &rhs_op, be.right, elem_hint)

					// Both must be assignable to elem_type
					if lhs_op.mode != .Invalid && !check_is_assignable_to(ctx, &lhs_op, elem_type) {
						error(be.left, "Cannot assign this value to bit_set element type")
					}
					if rhs_op.mode != .Invalid && !check_is_assignable_to(ctx, &rhs_op, elem_type) {
						error(be.right, "Cannot assign this value to bit_set element type")
					}

					// Range elements are not constant-time computable in general
					if lhs_op.mode != .Constant || rhs_op.mode != .Constant {
						is_constant = false
					}
				}
			} else {
				// Single value element
				// Reference: C++ lines 10607-10630
				elem_operand := Operand{}
				// C++ Reference: check_expr.cpp:11439 - check_expr_with_type_hint(c, o, elem, et).
				// Without the hint every implicit-selector element (`Permission{.Read}`) reaches
				// check_implicit_selector_expr with a nil hint and fails.
				check_expr_with_type_hint(ctx, &elem_operand, elem, elem_hint)

				// C++ Reference: check_expr.cpp:11439-11441. There is NO early bail on an
				// invalid element here. An invented `if elem_operand.mode == .Invalid { continue }`
				// used to sit above this, which skipped the update below -- so a literal whose
				// element failed to resolve stayed CONSTANT. Callers that inspect the operand
				// afterwards then saw a perfectly good constant and dropped their own
				// diagnostics: `@(fast_math = {.Bad})` lost both "Expected a constant attribute
				// element" and the outer bit_set error.
				if elem_operand.mode != .Constant {
					is_constant = false
				}

				// C++ Reference: check_expr.cpp:11460 — check_assignment against the
				// DECLARED element type, not a bespoke check_is_assignable_to. The custom
				// version this replaces compared the operand against elem_type after
				// hinting with elem_type, which rejected perfectly legal elements whenever
				// BitSet.elem and the resolved selector type differed only by naming.
				check_assignment(ctx, &elem_operand, elem_type, "bit_set literal")
				if elem_operand.mode == .Invalid {
					continue
				}

				// C++ Reference: check_expr.cpp:11461-11472 — range bounds check.
				if elem_operand.mode == .Constant {
					v := exact_value_to_i64(elem_operand.value)
					if v < bs.lower || v > bs.upper {
						s := expr_to_string(elem_operand.expr)
						defer delete(s)
						error(
							elem,
							"Bit field value out of bounds, %s (%d) not in the range %d .. %d",
							s, v, bs.lower, bs.upper,
						)
						continue
					}
				}
			}
		}

	case Type_Enumerated_Array:
		// EnumeratedArray literal: [Direction]int{.North = 1, .South = 2} or [Direction]int{1, 2, 3, 4}
		// Reference: C++ lines 10190-10430
		ea := variant
		elem_type := ea.elem
		index_type := ea.index
		elem_count := ea.count

		// Empty literal is OK
		if len(cl.elems) == 0 {
			break
		}

		// Determine if using named or positional syntax
		has_named := false
		has_positional := false
		for elem in cl.elems {
			if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
				has_named = true
			} else {
				has_positional = true
			}
		}

		// Cannot mix named and positional
		if has_named && has_positional {
			error(node, "Cannot mix named and positional elements in enumerated array literal")
			break
		}

		// For non-sparse enumerated arrays, positional/bare elements are not allowed
		// Must use named syntax: { .Field = value }
		if has_positional && !ea.is_sparse {
			error(node, "Bare elements are not allowed in enumerated array literal; use '.FieldName = value' syntax")
			break
		}

		if has_named {
			// Named syntax: [Enum]T{.A = val, .B = val}
			// Reference: C++ lines 10200-10300
			indices_visited := make(map[i64]bool, context.temp_allocator)

			for elem in cl.elems {
				fv := elem.derived.(^ast.Field_Value)

				// Check index expression (should be enum value)
				// Use index_type as hint for implicit selector resolution
				index_operand := Operand{}
				check_expr_with_type_hint(ctx, &index_operand, fv.field, index_type)

				// C++ Reference: check_expr.cpp:11160-11163. C++ demands the index be
				// CONSTANT and its type IDENTICAL to the index type. The port asked only
				// for assignability, which accepted a non-constant index outright --
				// `[E]int{ ev = 1 }` for a variable `ev: E` passed silently. The message
				// was invented too ("Index '%s' is not valid for enumerated array indexed
				// by '%s'"), and it anchored at fv.field rather than the operand.
				if index_operand.mode != .Constant || !are_types_identical(index_operand.type, index_type) {
					// NOTE: type_to_string results are NOT deleted in this file (LEDGER 142 --
					// deleting one is a `free(): invalid pointer` abort); expr_to_string
					// results ARE. The two allocate differently.
					idx_type_str := type_to_string(index_type)
					error(index_operand.expr, "Expected a constant enum of type '%s' as an array field", idx_type_str)
					continue
				}

				// C++ Reference: check_expr.cpp:11174-11179 -- names the index and the
				// context, and anchors at `elem`. The port's message named neither.
				idx_val := exact_value_to_i64(index_operand.value)
				if indices_visited[idx_val] {
					idx_str := expr_to_string(index_operand.expr)
					defer delete(idx_str)
					error(elem, "Duplicate field index %s for enumerated array literal", idx_str)
					continue
				}
				indices_visited[idx_val] = true

				// Check value expression WITH the element type as the hint.
				//
				// C++ Reference: check_expr.cpp:11145 -
				// `check_expr_with_type_hint(c, &operand, fv->value, elem_type)`.
				// The port hinted the INDEX (fv.field, just above) but not the value, so a
				// nested braced literal had no type to resolve against and reported
				// "Missing type in compound literal". Every `[Enum]Bit_Set{ .A = {.X} }` and
				// `[Enum]Struct{ .A = {1, 2} }` failed - including the checker's own
				// basic_flags_table and builtin_proc_infos. Plain `[N]T{...}` and `[]T{...}`
				// were unaffected, which is why this looked narrower than it was.
				value_operand := Operand{}
				check_expr_with_type_hint(ctx, &value_operand, fv.value, elem_type)

				// C++ Reference: check_expr.cpp:11187-11192. check_assignment, not a bespoke
				// check_is_assignable_to plus the invented "Cannot assign '%s' to enumerated
				// array element of type '%s'"; and the constant test is
				// check_is_operand_compound_lit_constant, not a bare mode comparison -- the
				// two differ for nil, typeid and procedure-valued elements.
				check_assignment(ctx, &value_operand, elem_type, "enumerated array literal")

				if is_constant {
					is_constant = check_is_operand_compound_lit_constant(ctx, &value_operand, elem_type)
				}
			}

			// Report enum cases the literal does not cover -- unless it is written
			// `#partial [E]T{...}`, which explicitly opts out of completeness.
			//
			// C++ Reference: check_expr.cpp:11244, which guards this on `!is_partial`,
			// where `is_partial = cl->tag && cl->tag->BasicDirective.name.string ==
			// "partial"` (check_expr.cpp:11073). The port never consulted the tag, so
			// `#partial` literals -- core/crypto/rsa's
			// `PKCS1_HASH_OIDS := #partial [hash.Algorithm][]byte{...}` -- were rejected
			// for exactly the cases they deliberately omit.
			//
			// C++ NAMES the unhandled cases and suggests `#partial`; the port used to report
			// only a count, on the grounds that replacing it "needs the error-collector
			// semantics sorted out first" (LEDGER task 192). That was the same reasoning
			// that kept the dynamic-literal suggestions out, and it is obsolete for the same
			// reason: begin_error_block/end_error_block hold a header and its continuations
			// together. LEDGER task 268.
			is_partial := false
			if cl.tag != nil {
				if bd, bd_ok := cl.tag.derived.(^ast.Basic_Directive); bd_ok {
					is_partial = bd.name == "partial"
				}
			}

			if !ea.is_sparse && !is_partial {
				// C++ Reference: check_expr.cpp:11248-11283. C++ walks the index enum's
				// fields and collects the ones the literal never mentioned, then names them.
				et := base_type(index_type)
				unhandled: [dynamic]^Entity
				defer delete(unhandled)
				if et != nil && et.kind == .Enum {
					for f in et.variant.(Type_Enum).fields {
						if f == nil || f.kind != .Constant {
							continue
						}
						c, is_const := f.variant.(Entity_Constant)
						if !is_const {
							continue
						}
						bi, is_int := c.value.(big.Int)
						if !is_int {
							continue
						}
						tmp := bi
						idx, err := big.int_get_i64(&tmp)
						if err != nil {
							continue
						}
						if !indices_visited[idx] {
							append(&unhandled, f)
						}
					}
				}

				if len(unhandled) > 0 {
					begin_error_block()
					defer end_error_block()
					if len(unhandled) == 1 {
						// C++ Reference: check_expr.cpp:11270 -- error_no_newline. See the
						// switch-statement twin in check_stmt.odin.
						error_no_newline(node, "Unhandled enumerated array case: %s", unhandled[0].token.text)
					} else {
						error(node, "Unhandled enumerated array cases:")
						for f in unhandled {
							error_line("\t%s\n", f.token.text)
						}
					}
					if !build_context.terse_errors {
						error_line("\n")
						// The braces must NOT go through the formatter: error_line's
						// formatting treats `{` as a verb introducer, so the literal
						// "{...}" came out as
						//     #partial [E]int%!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)..}
						// This was invisible until task 273 made the singular form's line
						// non-terminating, because the Suggestion was not reaching the
						// output at all. Build the text first, emit it as one argument.
						// The literal braces are passed as an ARGUMENT, not left in the
						// format string: error_line's formatter treats `{` as a verb
						// introducer and turned "{...}" into
						//     %!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)..}
						error_line("\tSuggestion: Was '#partial %s%s' wanted?\n", type_to_string(type), "{...}")
					}
				}
			}
		} else {
			// Positional syntax: [Enum]T{val1, val2, val3}
			// Reference: C++ lines 10300-10400
			for elem in cl.elems {
				// Same hint as the named path above - a positional enumerated-array element
				// is still an element of `elem_type` and a nested braced literal needs it.
								elem_operand := Operand{}
				check_expr_with_type_hint(ctx, &elem_operand, elem, elem_type)
				check_assignment(ctx, &elem_operand, elem_type, "enumerated array literal")

				// C++ Reference: check_expr.cpp:11223-11225 -- guarded, and via
				// check_is_operand_compound_lit_constant, not a bare mode comparison.
				if is_constant {
					is_constant = check_is_operand_compound_lit_constant(ctx, &elem_operand, elem_type)
				}
			}

			// Validate element count for positional syntax
			if i64(len(cl.elems)) != elem_count {
				error(node, "Expected %d values for enumerated array literal, got %d", elem_count, len(cl.elems))
			}
		}

	case Type_Dynamic_Array:
		// Dynamic array literal: [dynamic]int{1, 2, 3}
		// Reference: C++ lines 10172-10177
		//
		// Dynamic literals are opt-in: C++ gates them on a per-file
		// `#+feature dynamic-literals` or the project-wide build setting
		// (check_expr.cpp:11009 for [dynamic]T, :11409 for map). Only reported for a
		// NON-EMPTY literal. `check_for_dynamic_literals` already existed with zero call
		// sites; the feature flags it reads are populated in check_files.odin.
		//
		// C++ Reference: check_expr.cpp:11022-11027, same shape as the map case above:
		//     if (check_for_dynamic_literals(c, node, cl)) {
		//         add_package_dependency(c, "runtime", "__dynamic_array_reserve");
		//         add_package_dependency(c, "runtime", "__dynamic_array_append");
		//     }
		if len(cl.elems) > 0 {
			if check_for_dynamic_literals(ctx, node) {
				add_package_dependency(ctx, "runtime", "__dynamic_array_reserve")
				add_package_dependency(ctx, "runtime", "__dynamic_array_append")
			}
		}
		da := variant
		elem_type := da.elem

		// Dynamic arrays are never constant (require runtime allocation)
		is_constant = false

		// Dynamic array literals cannot use named/indexed fields
		for elem in cl.elems {
			if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
				error(elem, "Dynamic array literals cannot contain 'field = value' entries")
				continue
			}

			// Check element value
						elem_operand := Operand{}
			check_expr_with_type_hint(ctx, &elem_operand, elem, elem_type)
			check_assignment(ctx, &elem_operand, elem_type, "dynamic array literal")
		}

	case Type_Simd_Vector:
		// SIMD vector literal: #simd[4]f32{1, 2, 3, 4}
		// Reference: C++ lines 9984-9994
		sv := variant
		elem_type := sv.elem
		elem_count := sv.count

		// SIMD vector literals cannot use named fields
		// Reference: C++ lines 9985-9987
		for elem in cl.elems {
			if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
				error(elem, "SIMD vector literals cannot contain 'field = value' entries")
				continue
			}

			// Check element value
						elem_operand := Operand{}
			check_expr_with_type_hint(ctx, &elem_operand, elem, elem_type)
			check_assignment(ctx, &elem_operand, elem_type, "simd vector literal")

			// C++ Reference: check_expr.cpp:11223-11225 -- guarded, and via
			// check_is_operand_compound_lit_constant, not a bare mode comparison.
			if is_constant {
				is_constant = check_is_operand_compound_lit_constant(ctx, &elem_operand, elem_type)
			}
		}

		// Validate element count
		// Reference: C++ lines 9990-9994
		if i64(len(cl.elems)) != elem_count && len(cl.elems) != 0 {
			error(node, "Expected %d values for SIMD vector literal, got %d", elem_count, len(cl.elems))
		}

	case Type_Matrix:
		// Matrix literal: matrix[2, 3]f32{1, 2, 3, 4, 5, 6}
		// Reference: C++ lines 9988-9994
		mx := variant
		elem_type := mx.elem
		total_count := mx.row_count * mx.column_count

		// Matrix literals cannot use named fields
		for elem in cl.elems {
			if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
				error(elem, "Matrix literals cannot contain 'field = value' entries")
				continue
			}

			// Check element value
						elem_operand := Operand{}
			check_expr_with_type_hint(ctx, &elem_operand, elem, elem_type)
			check_assignment(ctx, &elem_operand, elem_type, "matrix literal")

			// C++ Reference: check_expr.cpp:11223-11225 -- guarded, and via
			// check_is_operand_compound_lit_constant, not a bare mode comparison.
			if is_constant {
				is_constant = check_is_operand_compound_lit_constant(ctx, &elem_operand, elem_type)
			}
		}

		// Validate element count
		if i64(len(cl.elems)) != total_count && len(cl.elems) != 0 {
			error(node, "Expected %d values for matrix[%d, %d] literal, got %d", total_count, mx.row_count, mx.column_count, len(cl.elems))
		}

	case Type_Bit_Field:
		// C++ Reference: check_expr.cpp:11477-11488. C++ has NO bit_field element loop --
		// it delegates to check_compound_literal_field_values, the SAME helper it uses for
		// struct literals, which is why that helper takes assignment_str at all. The port
		// HAD the helper (with a live Type_Bit_Field branch) and ALSO a hand-rolled loop
		// here, so the helper's branch was dead and this copy drifted five ways: no type
		// hint on the value (so `B{ f = .A }` for an enum-typed field was rejected outright),
		// an invented assignability message, an un-quoted "bit_field literal" in the
		// duplicate message, a per-element error for positional syntax where C++ emits one
		// at the node, and "'B' has no field 'c'" for C++'s "Unknown field 'c' in ...".
		if len(cl.elems) == 0 {
			break // NOTE(bill): No need to init
		}
		if _, is_fv := cl.elems[0].derived.(^ast.Field_Value); !is_fv {
			type_str := type_to_string(type)
			error(node, "%s ('bit_field') compound literals are only allowed to contain 'field = value' elements", type_str)
		} else {
			check_compound_literal_field_values(ctx, cl.elems, o, type, &is_constant)
		}

	case Type_Basic:
		// Handle `any` type compound literals
		// Reference: C++ lines 10530-10610
		if !is_type_any(type) {
			// Non-any basic types cannot have compound literals with fields
			// Reference: C++ lines 10452-10460
			if len(cl.elems) != 0 {
				type_str := type_to_string(type)
				error(node, "Illegal compound literal, %s cannot be used as a compound literal with fields", type_str)
				is_constant = false
			}
			break
		}

		// Handle `any` type literals: any{data, id}
		if len(cl.elems) == 0 {
			break // Empty any literal is OK
		}

		// Validate fields
		// Reference: C++ lines 10464-10530
		field_types := [2]^Type{t_rawptr, t_typeid}
		field_count := 2

		if len(cl.elems) > 0 {
			if _, is_field_value := cl.elems[0].derived.(^ast.Field_Value); is_field_value {
				// Named field syntax: any{data = ptr, id = typeid}
				// Reference: C++ lines 10467-10505
				fields_visited := [2]bool{}

				for elem in cl.elems {
					if fv, is_fv := elem.derived.(^ast.Field_Value); !is_fv {
						error(elem, "Mixture of 'field = value' and value elements in a 'any' literal is not allowed")
						continue
					} else {
						// Validate field name is identifier
						ident, is_ident := fv.field.derived.(^ast.Ident)
						if !is_ident {
							expr_str := expr_to_string(fv.field)
							defer delete(expr_str)
							error(elem, "Invalid field name '%s' in 'any' literal", expr_str)
							continue
						}

						field_name := ident.name

						// Look up field in any type
						sel := lookup_field(type, field_name, o.mode == .Type)
						if sel.entity == nil {
							error(elem, "Unknown field '%s' in 'any' literal", field_name)
							continue
						}

						index := sel.index[0]

						// Check for duplicate fields
						if fields_visited[index] {
							error(elem, "Duplicate field '%s' in 'any' literal", field_name)
							continue
						}

						fields_visited[index] = true

						// Check field value
						field_operand := Operand{}
						check_expr(ctx, &field_operand, fv.value)

						// NOTE: 'any' literals can never be constant
						// Reference: C++ line 10501
						is_constant = false

						check_assignment(ctx, &field_operand, field_types[index], "'any' literal")
					}
				}
			} else {
				// Positional field syntax: any{ptr, typeid}
				// Reference: C++ lines 10506-10528
				for elem, index in cl.elems {
					if _, is_fv := elem.derived.(^ast.Field_Value); is_fv {
						error(elem, "Mixture of 'field = value' and value elements in a 'any' literal is not allowed")
						continue
					}

					elem_operand := Operand{}
					check_expr(ctx, &elem_operand, elem)

					if index >= field_count {
						error(elem_operand.expr, "Too many values in 'any' literal, expected %d", field_count)
						break
					}

					// NOTE: 'any' literals can never be constant
					// Reference: C++ line 10521
					is_constant = false

					check_assignment(ctx, &elem_operand, field_types[index], "'any' literal")
				}

				// Validate element count
				if len(cl.elems) < field_count {
					error(node, "Too few values in 'any' literal, expected %d, got %d", field_count, len(cl.elems))
				}
			}
		}

	case:
		if len(cl.elems) == 0 {
			break // Empty literal for any type
		}

		type_str := type_to_string(type)
		error(node, "Invalid compound literal type '%s'", type_str)
		return kind
	}

	// Set operand mode and exact value
	// Reference: C++ lines 10665-10728
	if is_constant {
		o.mode = .Constant

		// Special handling for bit sets (C++ lines 10843-10870)
		if is_type_bit_set(type) {
			// NOTE: Bit sets are encoded as integers
			// C++ Reference: check_expr.cpp:10843-10870
			bt := base_type(type)
			bs := bt.variant.(Type_Bit_Set)

			// Build integer value from bit fields
			bits: big.Int
			one: big.Int
			big.int_set_from_integer(&one, 1)

			for elem in cl.elems {
				if elem == nil {
					continue
				}
				// Get the stored type and value for this element
				_, elem_value, elem_mode := type_and_value_of_expr(ctx, elem)
				if elem_mode != .Constant {
					continue
				}
				// Check if the value is an integer (stored as big.Int in Exact_Value)
				if _, is_int := elem_value.(big.Int); is_int {
					v := exact_value_to_i64(elem_value)
					lower := bs.lower
					index := int(v - lower)
					bit: big.Int
					big.int_shl(&bit, &one, index)
					big.int_bit_or(&bits, &bits, &bit)
				}
			}
			o.value = bits
		} else if is_type_constant_type(type) && len(cl.elems) == 0 {
			// Empty constant type literals get default zero values (C++ lines 10696-10722)
			value := exact_value_compound(cast(^ast.Expr)node)
			bt := core_type(type)
			if basic, ok := bt.variant.(Type_Basic); ok {
				#partial switch basic.kind {
				case .Llvm_Bool, .Bool, .B8, .B16, .B32, .B64:
					value = exact_value_bool(false)
				case .I8, .U8, .I16, .U16, .I32, .U32, .I64, .U64, .I128, .U128, .Int, .Uint, .Uintptr, .I16le, .U16le, .I32le, .U32le, .I64le, .U64le, .I128le, .U128le, .I16be, .U16be, .I32be, .U32be, .I64be, .U64be, .I128be, .U128be:
					value = exact_value_i64(0)
				case .F16, .F32, .F64, .F16le, .F32le, .F64le, .F16be, .F32be, .F64be:
					value = exact_value_float(0)
				case .Complex32, .Complex64, .Complex128:
					value = exact_value_complex(0, 0)
				case .Quaternion64, .Quaternion128, .Quaternion256:
					value = exact_value_quaternion(0, 0, 0, 0)
				case .Rawptr:
					value = exact_value_pointer(0)
				case .String, .Cstring:
					value = exact_value_string("")
				case .Rune:
					value = exact_value_i64(0)
				}
			}
			o.value = value
		} else {
			// All other constant literals use compound marker (C++ line 10724)
			o.value = exact_value_compound(cast(^ast.Expr)node)
		}
	} else {
		o.mode = .Value
	}

	o.type = type
	o.expr = node

	return kind
}
