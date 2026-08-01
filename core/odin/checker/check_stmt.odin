package checker

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:sync"

// Type_And_Token pairs a type with a token for duplicate case detection
// C++ Reference: check_expr.cpp (TypeAndToken struct)
Type_And_Token :: struct {
	type:  ^Type,
	token: tokenizer.Token,
}

// Constants for inline range loop unrolling
// C++ Reference: checker.hpp line 64
MAX_INLINE_FOR_DEPTH :: 1024 // Maximum total unroll depth (nested loops multiply)

// compound_assign_to_binary_op converts a compound assignment operator to its binary equivalent
// e.g., += becomes +, *= becomes *, etc.
// C++ Reference: check_stmt.cpp (operator conversion in compound assignment checking)
compound_assign_to_binary_op :: proc(kind: tokenizer.Token_Kind) -> tokenizer.Token_Kind {
	#partial switch kind {
	case .Add_Eq:      return .Add
	case .Sub_Eq:      return .Sub
	case .Mul_Eq:      return .Mul
	case .Quo_Eq:      return .Quo
	case .Mod_Eq:      return .Mod
	case .Mod_Mod_Eq:  return .Mod_Mod
	case .And_Eq:      return .And
	case .Or_Eq:       return .Or
	case .Xor_Eq:      return .Xor
	case .And_Not_Eq:  return .And_Not
	case .Shl_Eq:      return .Shl
	case .Shr_Eq:      return .Shr
	case .Cmp_And_Eq:  return .Cmp_And
	case .Cmp_Or_Eq:   return .Cmp_Or
	case:              return kind  // Return unchanged if not a compound operator
	}
}

// is_diverging_expr checks if an expression never returns (e.g., panic)
// C++ Reference: check_stmt.cpp lines 0-24
is_diverging_expr :: proc(ctx: ^Checker_Context, expr: ^ast.Expr) -> bool {
	expr := unparen_expr(expr)

	// Only call expressions can diverge
	// C++ Reference: check_stmt.cpp lines 1-4
	call_expr, is_call := expr.derived.(^ast.Call_Expr)
	if !is_call {
		return false
	}

	// Check for #panic directive
	// C++ Reference: check_stmt.cpp lines 5-8
	#partial switch proc_expr in call_expr.expr.derived {
	case ^ast.Basic_Directive:
		if proc_expr.name == "panic" {
			return true
		}
	}

	// Check procedure type for diverging flag
	// C++ Reference: check_stmt.cpp lines 9-23
	proc_node := unparen_expr(call_expr.expr)
	tv, has_tv := tav_lookup(ctx.info, proc_node)
	if !has_tv {
		return false
	}

	// Check if it's a builtin procedure
	// C++ Reference: check_stmt.cpp lines 11-19
	if tv.mode == .Builtin {
		e := entity_of_node(&ctx.checker.info, proc_node)
		id: Builtin_Proc_Id = .Invalid
		if e != nil {
			#partial switch b in e.variant {
			case Entity_Builtin:
				id = b.id
			}
		}
		// Note: C++ has DIRECTIVE and Count enum values not currently needed in Odin version
		// Check if builtin is diverging using metadata table
		if id != .Invalid && builtin_proc_infos[id].diverging {
			return true
		}
	}

	// Check if procedure type is diverging
	// C++ Reference: check_stmt.cpp lines 21-23
	t := tv.type
	t = base_type(t)
	if t != nil && t.kind == .Proc {
		if proc_type, ok := t.variant.(Type_Proc); ok {
			return proc_type.diverging
		}
	}

	return false
}

// is_diverging_stmt checks if a statement never returns
// C++ Reference: check_stmt.cpp lines 25-30
is_diverging_stmt :: proc(ctx: ^Checker_Context, stmt: ^ast.Stmt) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Expr_Stmt:
		return is_diverging_expr(ctx, s.expr)
	}
	return false
}

// check_scope_decls collects and checks declarations within a scope
// This processes constants, type names, and nested procedures found in procedure bodies.
// C++ Reference: check_expr.cpp:347-367
check_scope_decls :: proc(ctx: ^Checker_Context, stmts: []^ast.Stmt) {
	s := ctx.scope
	if s == nil {
		return
	}

	// Step 1: Collect entities from the statements into the current scope
	// C++ Reference: check_expr.cpp:350
	check_collect_entities(ctx, stmts)

	// Step 2: Check all collected entities that need immediate checking
	// C++ Reference: check_expr.cpp:352-366
	for _, entity in s.elements {
		if entity == nil {
			continue
		}
		// Only check constants, type names, and procedures
		// Variables are checked when their statements are processed
		#partial switch entity.kind {
		case .Constant, .Type_Name, .Procedure:
			decl := decl_info_of_entity(entity)
			if decl != nil {
				check_entity_decl(ctx, entity, decl, nil)
			}
		}
	}
}

// contains_deferred_call checks if an AST node contains deferred procedure calls
// C++ Reference: check_stmt.cpp lines 32-61
contains_deferred_call :: proc(ctx: ^Checker_Context, node: ^ast.Node) -> bool {
	if node == nil {
		return false
	}

	// Check viral flags first (fast path)
	// C++ Reference: check_stmt.cpp:34
	// Viral flags are stored directly on AST nodes
	if .Contains_Deferred_Procedure in node.viral_state_flags {
		return true
	}

	// Fallback: recursively check child nodes
	// C++ Reference: check_stmt.cpp:37-59
	#partial switch n in node.derived {
	case ^ast.Expr_Stmt:
		expr_node := cast(^ast.Node)n.expr
		return contains_deferred_call(ctx, expr_node)

	case ^ast.Assign_Stmt:
		for rhs_expr in n.rhs {
			if contains_deferred_call(ctx, cast(^ast.Node)rhs_expr) {
				return true
			}
		}
		for lhs_expr in n.lhs {
			if contains_deferred_call(ctx, cast(^ast.Node)lhs_expr) {
				return true
			}
		}

	case ^ast.Value_Decl:
		for value_expr in n.values {
			if contains_deferred_call(ctx, cast(^ast.Node)value_expr) {
				return true
			}
		}
	}

	return false
}

// accumulate_viral_flags_from_expr retrieves viral state flags from an expression
// These flags propagate upward through the AST during type checking
// C++ Reference: check_stmt.cpp (similar pattern to contains_deferred_call)
accumulate_viral_flags_from_expr :: proc(ctx: ^Checker_Context, expr: ^ast.Expr) -> Viral_State_Flags {
	if expr == nil {
		return {}
	}

	// Viral flags are stored directly on AST nodes
	// Cast to Node to access the viral_state_flags field
	return expr.viral_state_flags
}

// check_open_scope is defined in scope.odin

// check_close_scope is defined in scope.odin

// check_label validates and registers a label
// C++ Reference: check_stmt.cpp lines 705-745
check_label :: proc(ctx: ^Checker_Context, label: ^ast.Node, parent: ^ast.Stmt) {
	if label == nil {
		return
	}

	// In Odin AST, labels are ^ast.Expr (specifically Ident)
	label_expr := cast(^ast.Expr)label
	if label_expr == nil {
		error_node(label, "A label must be an expression")
		return
	}

	// Extract identifier from expression
	ident_node, ok := label_expr.derived.(^ast.Ident)
	if !ok {
		error_node(label, "A label's name must be an identifier")
		return
	}

	name := ident_node.name

	// Cannot use blank identifier as label
	if name == "_" {
		error_node(label, "A label's name cannot be a blank identifier")
		return
	}

	// Labels only allowed within procedures
	if ctx.curr_proc_decl == nil {
		error_node(label, "A label is only allowed within a procedure")
		return
	}

	// Check for duplicate labels
	if ctx.decl != nil {
		for bl in ctx.decl.labels {
			if bl.name == name {
				error_node(label, "Duplicate label with the name '%s'", name)
				return
			}
		}
	}

	// Create label entity
	// Construct token from identifier
	token := tokenizer.Token {
		text = name,
		pos  = label_expr.pos,
		kind = .Ident,
	}
	entity := alloc_entity_label(ctx.scope, token, t_invalid, nil, parent)

	// Add to scope
	existing := scope_insert(ctx.scope, entity)
	if existing != nil {
		error_node(label, "Label '%s' conflicts with existing entity", name)
		return
	}

	// Add to procedure's label list
	if ctx.decl != nil {
		bl := Block_Label {
			name  = name,
			label = parent,
		}
		append(&ctx.decl.labels, bl)
	}
}

// label_string extracts the string name from a label node
// C++ Reference: check_stmt.cpp lines 286-295
label_string :: proc(node: ^ast.Node) -> string {
	if node == nil {
		return ""
	}

	// In Odin AST, labels are ^ast.Expr (specifically Ident)
	expr := cast(^ast.Expr)node
	if expr != nil {
		if ident, is_ident := expr.derived.(^ast.Ident); is_ident {
			return ident.name
		}
	}

	// If we can't extract the label, this is an internal error
	panic("INVALID LABEL: Unable to extract label string")
}

// check_is_terminating_list checks if a statement list terminates (ends with return/break/etc)
// C++ Reference: check_stmt.cpp lines 145-161
check_is_terminating_list :: proc(ctx: ^Checker_Context, stmts: []^ast.Stmt, label: string) -> bool {
	// Iterate backwards to find the last non-empty, non-constant declaration
	for i := len(stmts) - 1; i >= 0; i -= 1 {
		stmt := stmts[i]

		#partial switch s in stmt.derived {
		case ^ast.Empty_Stmt:
		// Okay - skip
		case ^ast.Value_Decl:
			if !s.is_mutable {
				// Constant declaration - okay, skip
			} else {
				// Mutable declaration - check if it terminates
				return check_is_terminating(ctx, stmt, label)
			}
		case:
			// Check if statement is diverging or terminating
			return check_is_terminating(ctx, stmt, label)
		}
	}

	return false
}

// check_has_break_list checks if any statement in the list has a break
// C++ Reference: check_stmt.cpp lines 163-170
check_has_break_list :: proc(ctx: ^Checker_Context, stmts: []^ast.Stmt, label: string, implicit: bool) -> bool {
	for stmt in stmts {
		if check_has_break(ctx, stmt, label, implicit) {
			return true
		}
	}
	return false
}

// check_has_break_expr checks if an expression contains an or_break
// C++ Reference: check_stmt.cpp lines 172-177
check_has_break_expr :: proc(ctx: ^Checker_Context, expr: ^ast.Expr, label: string) -> bool {
	if expr == nil {
		return false
	}

	// Check viral flags for or_break
	// C++ Reference: check_stmt.cpp:173
	// Viral flags are stored directly on AST nodes
	if expr == nil {
		return false
	}
	return .Contains_Or_Break in expr.viral_state_flags
}

// check_has_break_expr_list checks if any expression in the list contains an or_break
// C++ Reference: check_stmt.cpp lines 179-186
check_has_break_expr_list :: proc(ctx: ^Checker_Context, exprs: []^ast.Expr, label: string) -> bool {
	for expr in exprs {
		if check_has_break_expr(ctx, expr, label) {
			return true
		}
	}
	return false
}

// check_has_break checks if a statement contains a break (explicit or via or_break)
// C++ Reference: check_stmt.cpp lines 188-284
check_has_break :: proc(ctx: ^Checker_Context, stmt: ^ast.Stmt, label: string, implicit: bool) -> bool {
	#partial switch s in stmt.derived {
	case ^ast.Branch_Stmt:
		if s.tok.kind == .Break {
			if s.label == nil {
				return implicit
			}
			// Check if label matches
			// In Odin AST, s.label is ^ast.Expr (specifically Ident)
			if ident, is_ident := s.label.derived.(^ast.Ident); is_ident {
				return ident.name == label
			}
		}

	case ^ast.Defer_Stmt:
		return check_has_break(ctx, s.stmt, label, implicit)

	case ^ast.Block_Stmt:
		return check_has_break_list(ctx, s.stmts, label, implicit)

	case ^ast.If_Stmt:
		if s.init != nil && check_has_break(ctx, s.init, label, implicit) {
			return true
		}
		if s.cond != nil && check_has_break_expr(ctx, s.cond, label) {
			return true
		}
		if check_has_break(ctx, s.body, label, implicit) {
			return true
		}
		if s.else_stmt != nil && check_has_break(ctx, s.else_stmt, label, implicit) {
			return true
		}

	case ^ast.Case_Clause:
		return check_has_break_list(ctx, s.body, label, implicit)

	case ^ast.Switch_Stmt:
		// Note: C++ code calls check_has_break_expr on init, but init is a statement
		// This appears to be a typo in the C++ code. Using check_has_break instead.
		if s.init != nil && check_has_break(ctx, s.init, label, implicit) {
			return true
		}
		if label != "" && check_has_break(ctx, s.body, label, false) {
			return true
		}

	case ^ast.Type_Switch_Stmt:
		if label != "" && check_has_break(ctx, s.body, label, false) {
			return true
		}

	case ^ast.For_Stmt:
		if s.init != nil && check_has_break(ctx, s.init, label, implicit) {
			return true
		}
		if s.cond != nil && check_has_break_expr(ctx, s.cond, label) {
			return true
		}
		if s.post != nil && check_has_break(ctx, s.post, label, implicit) {
			return true
		}
		if label != "" && check_has_break(ctx, s.body, label, false) {
			return true
		}

	case ^ast.Range_Stmt:
		if label != "" && check_has_break(ctx, s.body, label, false) {
			return true
		}

	case ^ast.Expr_Stmt:
		// C++ Reference: check_stmt.cpp:262-266
		if check_has_break_expr(ctx, s.expr, label) {
			return true
		}

	case ^ast.Value_Decl:
		if s.is_mutable && check_has_break_expr_list(ctx, s.values, label) {
			return true
		}

	case ^ast.Assign_Stmt:
		if check_has_break_expr_list(ctx, s.lhs, label) {
			return true
		}
		if check_has_break_expr_list(ctx, s.rhs, label) {
			return true
		}
	}

	return false
}

// check_is_terminating checks if a statement terminates (never falls through)
// NOTE: The last expression has to be a 'return' statement
// C++ Reference: check_stmt.cpp lines 297-417
// Handles: return, block, expr (diverging), if/else, when, for, switch, type_switch
check_is_terminating :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, label: string) -> bool {
	#partial switch s in node.derived {
	case ^ast.Return_Stmt:
		return true

	case ^ast.Block_Stmt:
		if check_is_terminating_list(ctx, s.stmts, label) {
			if s.label != nil {
				return check_is_terminating_list(ctx, s.stmts, label_string(s.label))
			}
			return true
		}

	case ^ast.Expr_Stmt:
		// C++ Reference: check_stmt.cpp:314-316
		// An expression statement terminates if it contains a diverging call (e.g., panic())
		return is_diverging_expr(ctx, s.expr)

	case ^ast.Value_Decl:
		return check_has_break_expr_list(ctx, s.values, label)

	case ^ast.Assign_Stmt:
		return check_has_break_expr_list(ctx, s.lhs, label) || check_has_break_expr_list(ctx, s.rhs, label)

	case ^ast.Branch_Stmt:
		return s.tok.kind == .Fallthrough

	case ^ast.If_Stmt:
		if s.else_stmt != nil {
			if check_is_terminating(ctx, s.body, label) && check_is_terminating(ctx, s.else_stmt, label) {
				return true
			}
		}

	case ^ast.When_Stmt:
		// C++ Reference: check_stmt.cpp:340-364
		// When statements with constant conditions only check the relevant branch
		if s.is_cond_determined {
			// Condition was evaluated at compile time
			if s.determined_cond {
				// Condition is true - only check body
				return check_is_terminating(ctx, s.body, label)
			} else {
				// Condition is false - only check else branch
				if s.else_stmt == nil {
					return false
				}
				return check_is_terminating(ctx, s.else_stmt, label)
			}
		}
		// Fallback: if condition wasn't determined, require both branches
		// NOTE(bill): Check the things regardless as a bug occurred earlier
		if s.else_stmt != nil {
			if check_is_terminating(ctx, s.body, label) && check_is_terminating(ctx, s.else_stmt, label) {
				return true
			}
		}

	case ^ast.For_Stmt:
		if s.cond == nil && !check_has_break(ctx, s.body, label, true) {
			if s.label != nil {
				return !check_has_break(ctx, s.body, label_string(s.label), false)
			}
			return true
		}

	case ^ast.Inline_Range_Stmt:
		// Unroll range never terminates
		return false

	case ^ast.Range_Stmt:
		return false

	case ^ast.Switch_Stmt:
		has_default := false
		if body_block, is_block := s.body.derived.(^ast.Block_Stmt); is_block {
			for clause_stmt in body_block.stmts {
				if clause, is_clause := clause_stmt.derived.(^ast.Case_Clause); is_clause {
					if len(clause.list) == 0 {
						has_default = true
					}
					if !check_is_terminating_list(ctx, clause.body, label) || check_has_break_list(ctx, clause.body, label, true) {
						return false
					}
				}
			}
		}
		return has_default

	case ^ast.Type_Switch_Stmt:
		has_default := false
		if body_block, is_block := s.body.derived.(^ast.Block_Stmt); is_block {
			for clause_stmt in body_block.stmts {
				if clause, is_clause := clause_stmt.derived.(^ast.Case_Clause); is_clause {
					if len(clause.list) == 0 {
						has_default = true
					}
					if !check_is_terminating_list(ctx, clause.body, label) || check_has_break_list(ctx, clause.body, label, true) {
						return false
					}
				}
			}
		}
		return has_default
	}

	return false
}

// check_block_stmt_for_errors checks for common error patterns in block statements.
// This catches cases like: `if cond { x := 123; }` where x is declared but never used.
// C++ Reference: check_stmt.cpp:1621-1676
check_block_stmt_for_errors :: proc(ctx: ^Checker_Context, body: ^ast.Stmt) {
	block, is_block := body.derived.(^ast.Block_Stmt)
	if !is_block {
		return
	}

	// Only check blocks with scope elements
	if block.scope == nil || len(block.scope.elements) == 0 {
		return
	}

	// Only check blocks that are children of control flow statements
	// C++ Reference: check_stmt.cpp:1629-1641
	if block.scope.parent != nil && block.scope.parent.node != nil {
		parent := block.scope.parent.node
		is_control_flow := false
		#partial switch _ in parent.derived {
		case ^ast.If_Stmt, ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Inline_Range_Stmt, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
			is_control_flow = true
		}
		if !is_control_flow {
			return
		}
	}

	// Count non-empty/non-bad statements
	// C++ Reference: check_stmt.cpp:1644-1660
	stmt_count := 0
	the_stmt: ^ast.Stmt = nil
	for stmt in block.stmts {
		if stmt == nil {
			continue
		}
		#partial switch _ in stmt.derived {
		case ^ast.Empty_Stmt, ^ast.Bad_Stmt, ^ast.Bad_Decl:
			// Skip empty/bad statements
		case:
			the_stmt = stmt
			stmt_count += 1
		}
	}

	// If there's exactly one statement and it's a ValueDecl, warn about unused variables
	// C++ Reference: check_stmt.cpp:1662-1674
	if stmt_count == 1 && the_stmt != nil {
		if value_decl, is_decl := the_stmt.derived.(^ast.Value_Decl); is_decl {
			for name in value_decl.names {
				ident, is_ident := name.derived.(^ast.Ident)
				if !is_ident {
					continue
				}
				if ident.name != "_" {
					error(name, "'%s' declared but not used", ident.name)
				}
			}
		}
	}
}

// check_stmt_list processes a list of statements with the given flags
// C++ Reference: check_stmt.cpp lines 63-142
check_stmt_list :: proc(ctx: ^Checker_Context, stmts: []^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}

	if len(stmts) == 0 {
		return viral_flags
	}

	// Check scope declarations (constants, types, procedures) before checking statements
	// C++ Reference: check_stmt.cpp:69-71
	// IMPORTANT: Set ctx.stmt_flags BEFORE check_scope_decls because entity collection
	// may trigger expression checking (for type inference), which needs proper flags
	// (e.g., Break_Allowed for or_break expressions inside loops)
	if .Check_Scope_Decls in flags {
		prev_stmt_flags := ctx.stmt_flags
		ctx.stmt_flags = flags
		check_scope_decls(ctx, stmts)
		ctx.stmt_flags = prev_stmt_flags
	}

	ft_ok := .Fallthrough_Allowed in flags
	// Note: C++ uses flags without fallthrough for nested statements, but our implementation
	// handles fallthrough validation differently, so flags2 is not needed

	// Find last non-empty statement
	// C++ Reference: check_stmt.cpp:76-82
	// Decrements max for each trailing empty statement until a non-empty statement is found
	max := len(stmts)
	loop1: for i := len(stmts) - 1; i >= 0; i -= 1 {
		#partial switch _ in stmts[i].derived {
		case ^ast.Empty_Stmt:
			max -= 1 // Decrement and continue checking previous statements
		case:
			break loop1 // Stop when first non-empty statement is found (break for loop, not switch)
		}
	}

	// Find last non-constant declaration
	// C++ Reference: check_stmt.cpp:84-95
	// Decrements max for each trailing empty statement or constant declaration
	max_non_constant_declaration := len(stmts)
	loop2: for i := len(stmts) - 1; i >= 0; i -= 1 {
		#partial switch s in stmts[i].derived {
		case ^ast.Empty_Stmt:
			max_non_constant_declaration -= 1 // Empty statement - continue
		case ^ast.Value_Decl:
			if !s.is_mutable {
				max_non_constant_declaration -= 1 // Constant declaration - continue
			} else {
				break loop2 // Mutable declaration - stop here (break for loop, not switch)
			}
		case:
			break loop2 // Any other statement - stop here (break for loop, not switch)
		}
	}

	// First pass: Check each statement
	for i in 0 ..< max {
		stmt := stmts[i]
		if stmt == nil {
			continue
		}

		// Skip empty statements
		#partial switch _ in stmt.derived {
		case ^ast.Empty_Stmt:
			continue
		}

		new_flags := flags
		if ft_ok && i + 1 == max {
			new_flags += {.Fallthrough_Allowed}
		}

		prev_stmt_flags := ctx.stmt_flags
		ctx.stmt_flags = new_flags

		viral_flags |= check_stmt(ctx, stmt, new_flags)

		ctx.stmt_flags = prev_stmt_flags
	}

	// Second pass: Check for unreachable code (after all statements have been type-checked)
	for i in 0 ..< max {
		stmt := stmts[i]
		if stmt == nil {
			continue
		}

		// Skip empty statements
		#partial switch _ in stmt.derived {
		case ^ast.Empty_Stmt:
			continue
		}

		if i + 1 < max_non_constant_declaration {
			// C++ Reference: check_stmt.cpp:112-127. The diagnostic is UNCONDITIONAL there:
			// there is no "but the unreachable statements are themselves diverging" escape.
			// The port used to compute an `all_remaining_diverging` guard and suppress on it,
			// which silently dropped the error for `return 1; panic("x")` and for
			// `break; panic("x")` inside a loop. No such guard exists in C++.
			#partial switch s in stmt.derived {
			case ^ast.Return_Stmt:
				error_node(stmt, "Statements after this 'return' are never executed")

			case ^ast.Branch_Stmt:
				error_node(stmt, "Statements after this '%s' are never executed", s.tok.text)

			case ^ast.Expr_Stmt:
				if is_diverging_stmt(ctx, stmt) {
					error_node(stmt, "Statements after a diverging procedure call are never executed")
				}
			}
		} else if i + 1 == max_non_constant_declaration {
			// C++ Reference: check_stmt.cpp lines 128-141
			// Check for unreachable defer statements when diverging call is at end of scope
			if is_diverging_stmt(ctx, stmt) {
				for j in 0 ..< i {
					prev_stmt := stmts[j]
					// C++ is an if/else-if CHAIN whose first arm is `ValueDecl && !is_mutable`.
					// A `#partial switch` on the node type is not the same shape: a MUTABLE
					// Value_Decl matches the `^ast.Value_Decl` case and falls out silently,
					// where C++ falls through to the contains_deferred_call arm. That made
					// `x := f()` before a diverging call an under-rejection. Keep the chain.
					is_const_decl := false
					if vd, vd_ok := prev_stmt.derived.(^ast.Value_Decl); vd_ok {
						is_const_decl = !vd.is_mutable
					}
					_, is_defer := prev_stmt.derived.(^ast.Defer_Stmt)

					if is_const_decl {
						// Constant declaration - okay
					} else if is_defer {
						error_node(prev_stmt, "Unreachable defer statement due to diverging procedure call at the end of the current scope")
					} else if contains_deferred_call(ctx, prev_stmt) {
						error_node(prev_stmt, "Unreachable deferred procedure call due to a diverging procedure call at the end of the current scope")
					}
				}
			}
		}
	}

	return viral_flags
}

// check_stmt is the main entry point for statement checking
// Handles state flags propagation
// C++ Reference: check_stmt.cpp lines 644-673
check_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	prev_state_flags := ctx.state_flags
	defer ctx.state_flags = prev_state_flags

	// Handle state_flags from AST node for #bounds_check/#no_bounds_check pragmas
	// Reference: check_stmt.cpp lines 647-665
	if node != nil {
		ast_flags := node.state_flags
		if .Bounds_Check in ast_flags {
			ctx.state_flags |= {.Bounds_Check}
			ctx.state_flags -= {.No_Bounds_Check}
		}
		if .No_Bounds_Check in ast_flags {
			ctx.state_flags |= {.No_Bounds_Check}
			ctx.state_flags -= {.Bounds_Check}
		}
		if .Type_Assert in ast_flags {
			ctx.state_flags |= {.Type_Assert}
			ctx.state_flags -= {.No_Type_Assert}
		}
		if .No_Type_Assert in ast_flags {
			ctx.state_flags |= {.No_Type_Assert}
			ctx.state_flags -= {.Type_Assert}
		}
	}

	viral_flags := check_stmt_internal(ctx, node, flags)
	return viral_flags
}

// check_stmt_internal is the main statement dispatcher
// C++ Reference: check_stmt.cpp lines 2746-2975
check_stmt_internal :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	mod_flags := flags - {.Fallthrough_Allowed}

	if node != nil {
	}
	#partial switch stmt in node.derived {
	case ^ast.Empty_Stmt:
	// No-op

	case ^ast.Bad_Stmt:
	// No-op

	case ^ast.Bad_Decl:
	// No-op

	case ^ast.Expr_Stmt:
		check_expr_stmt(ctx, node)

	case ^ast.Assign_Stmt:
		check_assign_stmt(ctx, node)

	case ^ast.Block_Stmt:
		check_open_scope(ctx, node)
		defer check_close_scope(ctx)

		check_label(ctx, stmt.label, node)
		viral_flags |= check_stmt_list(ctx, stmt.stmts, flags)
		check_block_stmt_for_errors(ctx, node)

	case ^ast.If_Stmt:
		viral_flags |= check_if_stmt(ctx, node, mod_flags)

	case ^ast.When_Stmt:
		viral_flags |= check_when_stmt(ctx, node, flags)

	case ^ast.Return_Stmt:
		viral_flags |= check_return_stmt(ctx, node)

	case ^ast.For_Stmt:
		viral_flags |= check_for_stmt(ctx, node, mod_flags)

	case ^ast.Range_Stmt:
		viral_flags |= check_range_stmt(ctx, node, mod_flags)

	case ^ast.Inline_Range_Stmt:
		viral_flags |= check_unroll_range_stmt(ctx, node, mod_flags)

	case ^ast.Case_Clause:
		// Case clauses are handled by check_switch_stmt and check_type_switch_stmt
		error_node(node, "Case clauses should not appear outside of switch statements")

	case ^ast.Switch_Stmt:
		viral_flags |= check_switch_stmt(ctx, node, mod_flags)

	case ^ast.Type_Switch_Stmt:
		viral_flags |= check_type_switch_stmt(ctx, node, mod_flags)

	case ^ast.Defer_Stmt:
		viral_flags |= check_defer_stmt(ctx, node)

	case ^ast.Branch_Stmt:
		viral_flags |= check_branch_stmt(ctx, node, flags)

	case ^ast.Using_Stmt:
		viral_flags |= check_using_stmt(ctx, node, flags)

	case ^ast.Value_Decl:
		viral_flags |= check_value_decl_stmt(ctx, node, mod_flags)

	case ^ast.Foreign_Block_Decl:
		check_foreign_block_decl(ctx, node)

	case:
		// Unknown statement type
		error_node(node, "Unknown statement type in check_stmt_internal")
	}

	return viral_flags
}

// check_expr_stmt validates an expression used as a statement
// C++ Reference: check_stmt.cpp lines 2330-2431
check_expr_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt) {
	stmt := node.derived.(^ast.Expr_Stmt)

	operand: Operand
	operand.mode = .Invalid

	kind := check_expr_base(ctx, &operand, stmt.expr, nil)

	// Check if it's a type instead of an expression
	if operand.mode == .Type {
		type_str := type_to_string(operand.type)
		error_node(node, "'%s' is not an expression but a type and cannot be used as a statement", type_str)
		return
	}

	if operand.mode == .No_Value {
		return
	}

	expr := unparen_expr(operand.expr)

	// Check if procedure requires results to be handled
	// C++ Reference: check_stmt.cpp:2351-2401
	// This check must happen BEFORE the kind == .Stmt early return to catch discarded results
	#partial switch e in expr.derived {
	case ^ast.Call_Expr:
		// Check if procedure has require_results flag
		// Use entity_of_node to get the procedure entity, then get its type
		proc_entity := entity_of_node(ctx.info, e.expr)
		if proc_entity != nil {
			proc_type := get_entity_type(proc_entity)
			if proc_type != nil {
				bt := base_type(proc_type)
				if bt != nil && bt.kind == .Proc {
					pt := bt.variant.(Type_Proc)
					if pt.require_results {
						expr_str := expr_to_string(e.expr)
						defer delete(expr_str)
						error_node(node, "'%s' requires that its results must be handled", expr_str)
					}
				}
			}
		}
		return

	case ^ast.Selector_Call_Expr:
		// Check selector call for require_results
		if call, ok := e.call.derived.(^ast.Call_Expr); ok {
			proc_entity := entity_of_node(ctx.info, call.expr)
			if proc_entity != nil {
				proc_type := get_entity_type(proc_entity)
				if proc_type != nil {
					bt := base_type(proc_type)
					if bt != nil && bt.kind == .Proc {
						pt := bt.variant.(Type_Proc)
						if pt.require_results {
							expr_str := expr_to_string(call.expr)
							defer delete(expr_str)
							error_node(node, "'%s' requires that its results must be handled", expr_str)
						}
					}
				}
			}
		}
		return
	case:
	}

	if kind == .Stmt {
		return
	}

	// C++ lines 2404-2430: Expression is not used - this is usually an error
	// However, some expressions are okay to discard
	#partial switch e2 in expr.derived {
	case ^ast.Ident, ^ast.Selector_Expr, ^ast.Binary_Expr, ^ast.Unary_Expr:
		begin_error_block()
		defer end_error_block()

		expr_str := expr_to_string(expr)
		defer delete(expr_str)
		error_node(node, "Expression is not used: '%s'", expr_str)

		// C++ lines 2409-2430: Suggest assignment for == operator
		#partial switch bin in expr.derived {
		case ^ast.Binary_Expr:
			if bin.op.kind == .Cmp_Eq {
				// Check if left-hand side can be assigned to
				// C++ checks: Addressing_Context, Addressing_Variable, Addressing_MapIndex, Addressing_SoaVariable
				lhs_tav, has_tav := tav_lookup(ctx.info, bin.left)
				can_assign := false

				if has_tav {
					// Check addressing mode from type checking
					#partial switch lhs_tav.mode {
					case .Context, .Variable, .Map_Index, .Soa_Variable:
						can_assign = true
					}
				}

				if can_assign {
					// Suggest using = instead of ==
					lhs_str := expr_to_string(bin.left)
					rhs_str := expr_to_string(bin.right)
					defer delete(lhs_str)
					defer delete(rhs_str)
					error_line("\tSuggestion: Did you mean to do an assignment?")
					error_line("\t            '%s = %s;'", lhs_str, rhs_str)
				}
			}
		}
	}
}

// check_assignment_arguments unpacks RHS expressions into operands for assignment
// Handles tuple unpacking, multi-return unpacking, and optional-ok patterns
// C++ Reference: check_expr.cpp lines 5958-6035
check_assignment_arguments :: proc(ctx: ^Checker_Context, lhs: []Operand, rhs_operands: ^[dynamic]Operand, rhs: []^ast.Expr) -> bool {
	optional_ok := false
	tuple_index := 0

	for rhs_expr in rhs {
		o: Operand
		o.mode = .Invalid

		// Use type hint from LHS if available
		type_hint: ^Type = nil
		if tuple_index < len(lhs) {
			type_hint = lhs[tuple_index].type
		}

		check_expr_base(ctx, &o, rhs_expr, type_hint)

		if o.mode == .No_Value {
			error_operand_no_value(&o)
			o.mode = .Invalid
		}

		// Check if this is a tuple type or needs special unpacking
		if o.type == nil || o.type.kind != .Tuple {
			// Check for optional-ok patterns: x, ok := map[key]
			if len(lhs) == 2 && len(rhs) == 1 && (o.mode == .Map_Index || o.mode == .Optional_Ok || o.mode == .Optional_Ok_Ptr) {
				expr := unparen_expr(o.expr)

				// Split into value and ok operands
				val0 := o
				val1 := o
				val0.mode = .Value
				val1.mode = .Value
				val1.type = t_untyped_bool

				// The second value is only `bool` by default; for an
				// #optional_ok / #optional_allocator_error procedure it is the
				// callee's declared second result.
				check_promote_optional_ok(ctx, &o, nil, &val1.type)

				if ta, is_ta := expr.derived.(^ast.Type_Assertion); is_ta &&
				   (o.mode == .Optional_Ok || o.mode == .Optional_Ok_Ptr) {
					// NOTE(bill): Used only for optimizations in the backend
					if is_blank_ident_node(lhs[0].expr) {
						ta.ignores[0] = true
					}
					if is_blank_ident_node(lhs[1].expr) {
						ta.ignores[1] = true
					}
				}

				append(rhs_operands, val0)
				append(rhs_operands, val1)
				optional_ok = true
				tuple_index += 2
			} else if o.mode == .Optional_Ok && is_type_tuple(o.type) {
				// A single-valued use of an #optional_ok call: keep only the
				// first result and consume both tuple slots.
				tuple := &o.type.variant.(Type_Tuple)
				assert(len(tuple.variables) == 2)
				val := o
				val.type = get_entity_type(tuple.variables[0])
				val.mode = .Value
				append(rhs_operands, val)
				tuple_index += len(tuple.variables)
			} else {
				// Normal single value
				append(rhs_operands, o)
				tuple_index += 1
			}
		} else {
			// Unpack tuple into individual operands
			#partial switch t in o.type.variant {
			case Type_Tuple:
				for entity in t.variables {
					unpacked := o
					unpacked.type = get_entity_type(entity)
					append(rhs_operands, unpacked)
				}
				tuple_index += len(t.variables)
			case:
				// Non-tuple type - use as-is
				append(rhs_operands, o)
				tuple_index += 1
			}
		}
	}

	return optional_ok
}

// check_assign_stmt validates assignment statements
// C++ Reference: check_stmt.cpp lines 2433-2509
check_assign_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt) {
	stmt := node.derived.(^ast.Assign_Stmt)

	if stmt.op.kind == .Eq {
		// Multi-sided assignment: a, b, c = 1, 2, 3

		lhs_count := len(stmt.lhs)
		if lhs_count == 0 {
			error_node(node, "Missing LHS in assignment statement")
			return
		}

		// Prepare operand arrays for multi-assignment
		lhs_operands := make([]Operand, lhs_count, context.temp_allocator)
		rhs_operands := make([dynamic]Operand, 0, 2 * lhs_count, context.temp_allocator)

		// Check all LHS expressions
		for i in 0 ..< lhs_count {
			// Check if it's a blank identifier
			is_blank := false
			if ident, ok := stmt.lhs[i].derived.(^ast.Ident); ok {
				is_blank = is_blank_ident(ident.name)
			}

			if is_blank {
				// Blank identifier - create placeholder operand
				lhs_operands[i].expr = stmt.lhs[i]
				lhs_operands[i].mode = .Value
			} else {
				// C++ Reference: check_stmt.cpp:2531. The LHS being checked is published
				// so check_expr's Implicit arm can tell `context = ...` (which DEFINES the
				// context) from a read of it.
				ctx.assignment_lhs_hint = unparen_expr(stmt.lhs[i])
				check_expr(ctx, &lhs_operands[i], stmt.lhs[i])
			}
		}
		ctx.assignment_lhs_hint = nil // C++ Reference: check_stmt.cpp:2535

		// Unpack RHS into operands (handles tuples, multi-return, etc.)
		check_assignment_arguments(ctx, lhs_operands[:], &rhs_operands, stmt.rhs)

		// Check each LHS-RHS pair
		rhs_count := len(rhs_operands)
		max := min(lhs_count, rhs_count)
		for i in 0 ..< max {
			// Skip blank identifiers
			is_blank := false
			if expr_node := lhs_operands[i].expr; expr_node != nil {
				if ident, ok := expr_node.derived.(^ast.Ident); ok {
					is_blank = is_blank_ident(ident.name)
				}
			}
			if is_blank {
				continue
			}
			check_assignment_variable(ctx, &lhs_operands[i], &rhs_operands[i], "assignment")
		}

		// Check for count mismatch
		if lhs_count != rhs_count {
			error_node(stmt.lhs[0], "Assignment count mismatch: %d variables, %d values", lhs_count, rhs_count)
		}

	} else {
		// Compound assignment: a += 1, a *= 2, etc.

		if len(stmt.lhs) != 1 || len(stmt.rhs) != 1 {
			error_node(node, "Assignment operator '%s' requires single-valued operands", stmt.op.text)
			return
		}

		// Validate operator is a compound assignment operator
		if stmt.op.kind == .Eq {
			error_node(node, "Internal error: compound assignment with = operator")
			return
		}

		// Check LHS
		lhs: Operand
		lhs.mode = .Invalid
		check_expr(ctx, &lhs, stmt.lhs[0])

		// Create synthetic binary expression for type checking
		// This matches C++ behavior: a += b is checked as a + b
		binary_expr := new(ast.Expr)
		binary_expr.pos = stmt.pos
		binary_derived := new(ast.Binary_Expr)
		binary_derived.left = stmt.lhs[0]
		binary_derived.right = stmt.rhs[0]
		// Convert compound assignment operator to binary operator
		// e.g., += becomes +, *= becomes *, etc.
		binary_derived.op = stmt.op
		binary_derived.op.kind = compound_assign_to_binary_op(stmt.op.kind)
		binary_expr.derived = binary_derived

		// Check the binary operation
		rhs: Operand
		rhs.mode = .Invalid
		check_binary_expr(ctx, &rhs, binary_expr, nil, true)

		if rhs.mode != .Invalid {
			rhs.expr = binary_expr
			check_assignment_variable(ctx, &lhs, &rhs, "assignment operation")
		}
	}
}

// all_operands_valid reports whether an arity error is worth emitting.
// Once any error has been reported, an operand that resolved to `t_invalid`
// means the real cause was already diagnosed, so the follow-on count mismatch
// is suppressed.
// C++ Reference: check_stmt.cpp all_operands_valid
all_operands_valid :: proc(operands: []Operand) -> bool {
	if any_errors() {
		for o in operands {
			if o.type == t_invalid {
				return false
			}
		}
	}
	return true
}

// check_unsafe_return validates that returned values don't reference stack memory
// C++ Reference: check_stmt.cpp lines 2547-2614
check_unsafe_return :: proc(ctx: ^Checker_Context, o: ^Operand, type: ^Type, expr: ^ast.Expr) {
	// Helper for error reporting
	unsafe_return_error :: proc(o: ^Operand, msg: string, extra_type: ^Type = nil) {
		expr_str := expr_to_string(o.expr)
		defer delete(expr_str)

		if extra_type != nil {
			type_str := type_to_string(extra_type)
			error_node(o.expr, "It is unsafe to return %s ('%s') of type ('%s') from a procedure, as it uses the current stack frame's memory", msg, expr_str, type_str)
		} else {
			error_node(o.expr, "It is unsafe to return %s ('%s') from a procedure, as it uses the current stack frame's memory", msg, expr_str)
		}
	}

	// Early exits
	if type == nil || expr == nil {
		return
	}

	#partial switch e in expr.derived {
	// C++: check_stmt.cpp:2566-2570
	case ^ast.Comp_Lit:
		if is_type_slice(type) {
			if len(e.elems) == 0 {
				return
			}
			unsafe_return_error(o, "a compound literal of a slice")
			return // Early exit to prevent recursive field check
		}

	// C++: check_stmt.cpp:2571-2594
	case ^ast.Unary_Expr:
		if e.op.kind == .And {
			x := unparen_expr(e.expr)

			// Only a BARE identifier naming a local counts. `entity_of_node` resolves a
			// selector to its BASE entity, so `&p.inner` reported the address of `p` -
			// and when `p` is a pointer parameter, `&p.inner` is not stack memory at all.
			// core/os/file_linux.odin's `return &impl.file`, where `impl: ^File_Impl`, is
			// exactly that shape and accounted for 96 of the class.
			//
			// The real compiler's behaviour, measured with `$S/ra1`: it flags `&o` for a
			// local `o`, and does NOT flag `&o.inner`, `&p.inner`, or `&q.inner`. Matching
			// that means requiring the operand to be an identifier.
			is_bare_ident: bool
			if _, ok := x.derived.(^ast.Ident); ok {
				is_bare_ident = true
			}
			entity := entity_of_node(&ctx.checker.info, x)

			if is_bare_ident && is_entity_local_variable(entity) {
				unsafe_return_error(o, "the address of a local variable")
			} else if _, is_comp_lit := x.derived.(^ast.Comp_Lit); is_comp_lit {
				unsafe_return_error(o, "the address of a compound literal")
			} else if idx, is_index := x.derived.(^ast.Index_Expr); is_index {
				f := entity_of_node(&ctx.checker.info, idx.expr)
				// entity_type, not `.type`: the base field is not always populated,
				// only the variant's — the same accessor split as tasks 82 and 90.
				ft := entity_type(f)
				if f != nil && (is_type_array_like(ft) || is_type_matrix(ft)) {
					if is_entity_local_variable(f) {
						unsafe_return_error(o, "the address of an indexed variable", ft)
					}
				}
			} else if mat_idx, is_mat_idx := x.derived.(^ast.Matrix_Index_Expr); is_mat_idx {
				f := entity_of_node(&ctx.checker.info, mat_idx.expr)
				ft := entity_type(f)
				if f != nil && is_type_matrix(ft) && is_entity_local_variable(f) {
					unsafe_return_error(o, "the address of an indexed variable", ft)
				}
			}
		}

	// C++: check_stmt.cpp:2595-2601
	case ^ast.Slice_Expr:
		x := unparen_expr(e.expr)
		entity := entity_of_node(&ctx.checker.info, x)

		if is_entity_local_variable(entity) && is_type_array(entity.type) {
			unsafe_return_error(o, "a slice of a local variable")
		} else if _, is_comp_lit := x.derived.(^ast.Comp_Lit); is_comp_lit {
			unsafe_return_error(o, "a slice of a compound literal")
		}
	}

	// C++: check_stmt.cpp:2598-2606
	// Allow returning constant slices from #load directive calls
	is_load_directive := false
	if call, is_call := expr.derived.(^ast.Call_Expr); is_call {
		if bd, is_bd := call.expr.derived.(^ast.Basic_Directive); is_bd {
			is_load_directive = bd.name == "load"
		}
	}
	if o.mode == .Constant && is_type_slice(type) && !is_load_directive {
		unsafe_return_error(o, "a compound literal of a slice")
		error_line("\tNote: A constant slice value will use the memory of the current stack frame\n")
	}

	// C++: check_stmt.cpp:2607-2614
	// Recursively check compound literal fields
	if cl, is_comp_lit := expr.derived.(^ast.Comp_Lit); is_comp_lit {
		for elem in cl.elems {
			if fv, is_field_value := elem.derived.(^ast.Field_Value); is_field_value {
				e := entity_of_node(&ctx.checker.info, fv.field)
				if e != nil {
					check_unsafe_return(ctx, o, e.type, fv.value)
				}
			}
		}
	}
}

// check_return_stmt validates return statements
// C++ Reference: check_stmt.cpp lines 2616-2695
check_return_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Return_Stmt)

	// Must be inside a procedure
	if ctx.curr_proc_sig == nil {
		error_node(node, "Return statement outside of procedure")
		return viral_flags
	}

	// Cannot return from defer
	if ctx.in_defer {
		error_node(node, "'return' cannot be used within a defer statement")
		return viral_flags
	}

	proc_type := ctx.curr_proc_sig

	// Check if procedure is diverging
	#partial switch t in proc_type.variant {
	case Type_Proc:
		if t.diverging {
			error_node(node, "Diverging procedures may not return")
			return viral_flags
		}

		// Get result types
		result_count := 0
		has_named_results := t.has_named_results

		result_entities: []^Entity = nil
		if t.results != nil {
			#partial switch res in t.results.variant {
			case Type_Tuple:
				result_entities = res.variables[:]
				result_count = len(res.variables)
			}
		}

		// Unpack multi-valued expressions (tuples, optional-ok) into a flat
		// operand list before any arity checking, exactly as C++ does.
		// C++ Reference: check_stmt.cpp check_return_stmt, the
		// `check_unpack_arguments(..., UnpackFlag_AllowOk)` call.
		//
		// `.Allow_Ok` (and NOT `.Allow_Undef`): a return statement may spread a
		// map index / type assertion / optional-ok call across two named results
		// (`return m[k]`), but `---` is not a legal return value.
		operands := make([dynamic]Operand, 0, 2 * len(stmt.results), context.temp_allocator)
		check_unpack_arguments(ctx, result_entities, &operands, stmt.results, {.Allow_Ok})

		if result_count == 0 && len(stmt.results) > 0 {
			error_node(stmt.results[0], "No return values expected")
		} else if has_named_results && len(operands) == 0 {
			// Named returns with no explicit values - okay
		} else if len(operands) != result_count {
			// Ignore error message as it has most likely already been reported
			if all_operands_valid(operands[:]) {
				if len(operands) == 1 {
					// NOTE: type_to_string's result is never caller-owned - it is either a
					// static literal ("<no type>", "<invalid>") or a temp-allocator string
					// (check_expr.odin:7305). Freeing it with the context allocator aborted the
					// process with `free(): invalid pointer` the moment an invalid operand
					// reached this diagnostic. check_expr.odin:4512 had already hit this and
					// removed its delete; this was the last live one.
					type_str := type_to_string(operands[0].type)
					error_node(node, "Expected %d return values, got %d (%s)", result_count, len(operands), type_str)
				} else {
					error_node(node, "Expected %d return values, got %d", result_count, len(operands))
				}
			}
		} else {
			// Check each return value
			for i in 0 ..< result_count {
				if result_entities == nil {
					continue
				}

				entity := result_entities[i]
				if entity == nil {
					continue
				}
				target_type := entity_type(entity)
				if target_type == nil {
					continue
				}

				operand := &operands[i]
				check_assignment(ctx, operand, target_type, "return statement")

				if is_type_untyped(operand.type) {
					update_untyped_expr_type(ctx, operand.expr, target_type, true)
				}
			}
		}

		// C++: check_stmt.cpp:2680-2692
		// Unwrap type conversions before checking for unsafe returns
		for &operand in operands {
			if operand.expr == nil {
				continue
			}
			expr := unparen_expr(operand.expr)
			unwrap_loop: for {
				if expr == nil {
					break unwrap_loop
				}
				call, is_call := expr.derived.(^ast.Call_Expr)
				if !is_call {
					break unwrap_loop
				}

				// Check if it's a type conversion
				if proc_tav, has_tav := tav_lookup(ctx.info, call.expr); has_tav {
					if proc_tav.mode != .Type {
						break unwrap_loop
					}
				} else {
					break unwrap_loop
				}

				// Must have exactly one argument
				if len(call.args) != 1 {
					break unwrap_loop
				}

				arg := call.args[0]

				// Don't unwrap field value expressions
				if _, is_field_value := arg.derived.(^ast.Field_Value); is_field_value {
					break unwrap_loop
				}

				// Check type identity
				if arg_tav, has_arg_tav := tav_lookup(ctx.info, arg); has_arg_tav {
					if !are_types_identical(arg_tav.type, operand.type) {
						break unwrap_loop
					}
				} else {
					break unwrap_loop
				}

				expr = unparen_expr(arg)
			}

			check_unsafe_return(ctx, &operand, operand.type, cast(^ast.Expr)expr)
		}

	case:
		error_node(node, "Invalid procedure type in return statement")
	}

	return viral_flags
}

// check_when_stmt validates compile-time when statements
// C++ Reference: check_stmt.cpp lines 676-703
check_when_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.When_Stmt)

	// Check condition - must be constant boolean
	// C++ Reference: check_stmt.cpp lines 677-682
	operand: Operand
	operand.mode = .Invalid
	check_expr(ctx, &operand, stmt.cond)

	// Combined check to match C++ behavior: must be constant AND boolean
	// C++: if (operand.mode != Addressing_Constant || !is_type_boolean(operand.type))
	if operand.mode != .Constant || !is_type_boolean(operand.type) {
		error_node(stmt.cond, "Non-constant boolean 'when' condition")
		return {}
	}

	// Validate body is a block statement
	// C++ Reference: check_stmt.cpp lines 683-686
	// C++: if (ws->body == nullptr || ws->body->kind != Ast_BlockStmt)
	if stmt.body == nil {
		error_node(stmt.cond, "Invalid body for 'when' statement")
		return {}
	}

	_, is_block := stmt.body.derived.(^ast.Block_Stmt)
	if !is_block {
		error_node(stmt.cond, "Invalid body for 'when' statement")
		return {}
	}

	// Evaluate constant condition and check appropriate branch
	// C++ Reference: check_stmt.cpp lines 687-702
	// C++: if (operand.value.kind == ExactValue_Bool && operand.value.value_bool)
	condition_value := false
	if v, is_bool := operand.value.(bool); is_bool {
		condition_value = v
	}

	if condition_value {
		// Condition is true - check the body
		// C++ Reference: check_stmt.cpp lines 687-689
		body_block := stmt.body.derived.(^ast.Block_Stmt)
		viral_flags |= check_stmt_list(ctx, body_block.stmts, flags)
	} else if stmt.else_stmt != nil {
		// Condition is false - check else clause
		// C++ Reference: check_stmt.cpp lines 690-702
		#partial switch _ in stmt.else_stmt.derived {
		case ^ast.Block_Stmt:
			// C++: case Ast_BlockStmt: check_stmt_list(ctx, ws->else_stmt->BlockStmt.stmts, flags);
			else_block := stmt.else_stmt.derived.(^ast.Block_Stmt)
			viral_flags |= check_stmt_list(ctx, else_block.stmts, flags)

		case ^ast.When_Stmt:
			// C++: case Ast_WhenStmt: check_when_stmt(ctx, &ws->else_stmt->WhenStmt, flags);
			// Recursive when-else-when
			viral_flags |= check_when_stmt(ctx, stmt.else_stmt, flags)

		case:
			// C++: default: error(ws->else_stmt, "Invalid 'else' statement in 'when' statement");
			error_node(stmt.else_stmt, "Invalid 'else' statement in 'when' statement")
		}
	}

	return viral_flags
}

// check_if_stmt validates if/else/else-if statements
// C++ Reference: check_stmt.cpp lines 2511-2542
check_if_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.If_Stmt)

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	check_label(ctx, stmt.label, node)

	// Check optional init statement
	if stmt.init != nil {
		viral_flags |= check_stmt(ctx, stmt.init, {})
	}

	// Check condition - must be boolean
	operand: Operand
	operand.mode = .Invalid
	check_expr(ctx, &operand, stmt.cond)
	if operand.mode != .Invalid && !is_type_boolean(operand.type) {
		error_node(stmt.cond, "Non-boolean condition in 'if' statement")
	}

	viral_flags |= accumulate_viral_flags_from_expr(ctx, stmt.cond)

	// Check body (then clause)
	viral_flags |= check_stmt(ctx, stmt.body, mod_flags)

	// Check optional else clause
	if stmt.else_stmt != nil {
		// Else can be another if (else-if) or a block
		#partial switch _ in stmt.else_stmt.derived {
		case ^ast.If_Stmt, ^ast.Block_Stmt:
			viral_flags |= check_stmt(ctx, stmt.else_stmt, mod_flags)
		case:
			error_node(stmt.else_stmt, "Invalid 'else' statement in 'if' statement")
		}
	}

	return viral_flags
}

// check_for_stmt validates for loop statements (C-style)
// C++ Reference: check_stmt.cpp lines 2697-2743
check_for_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.For_Stmt)

	// C++ line 2699: For loops allow break and continue
	flags := mod_flags + {.Break_Allowed, .Continue_Allowed}

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	check_label(ctx, stmt.label, node)

	// Check optional init statement
	if stmt.init != nil {
		viral_flags |= check_stmt(ctx, stmt.init, {})
	}

	// Check optional condition - must be boolean if present
	if stmt.cond != nil {
		operand: Operand
		operand.mode = .Invalid
		check_expr(ctx, &operand, stmt.cond)
		if operand.mode != .Invalid && !is_type_boolean(operand.type) {
			error_node(stmt.cond, "Non-boolean condition in 'for' statement")
		}

		// C++ Reference: check_stmt.cpp:2716-2735
		// Additional check for tautological unsigned comparisons in for loop conditions
		// This catches patterns like `for i := 0; i >= 0; i += 1` where i is unsigned
		if be, is_binary := stmt.cond.derived.(^ast.Binary_Expr); is_binary {
			check_for_loop_tautological_comparison(ctx, stmt.cond, be)
		}

		viral_flags |= accumulate_viral_flags_from_expr(ctx, stmt.cond)
	}

	// Check optional post statement
	if stmt.post != nil {
		viral_flags |= check_stmt(ctx, stmt.post, {})

		// Validate post is a simple statement (assignment)
		#partial switch _ in stmt.post.derived {
		case ^ast.Assign_Stmt:
		// Valid
		case:
			error_node(stmt.post, "'for' statement post statement must be a simple statement")
		}
	}

	// C++ line 2740: Check body with break/continue flags
	viral_flags |= check_stmt(ctx, stmt.body, flags)

	return viral_flags
}

// check_for_loop_tautological_comparison checks for tautological comparisons in for loop conditions
// C++ Reference: check_stmt.cpp:2716-2735
// Examples:
//   unsigned_val >= 0 in for loop condition -> always true
//   unsigned_val < 0 in for loop condition -> always false
check_for_loop_tautological_comparison :: proc(ctx: ^Checker_Context, node: ^ast.Node, be: ^ast.Binary_Expr) {
	// Check if it's a comparison operator
	#partial switch be.op.kind {
	case .Lt, .Gt, .Lt_Eq, .Gt_Eq:
		// Continue with check
	case:
		return
	}

	// Check for constant 0 on one side and unsigned on the other
	left_op, right_op: Operand
	check_expr(ctx, &left_op, be.left)
	check_expr(ctx, &right_op, be.right)

	is_constant_zero :: proc(op: ^Operand) -> bool {
		if op.mode != .Constant || op.value == nil {
			return false
		}
		return is_exact_value_zero(op.value)
	}

	is_unsigned_type :: proc(t: ^Type) -> bool {
		if t == nil {
			return false
		}
		bt := base_type(t)
		if bt == nil || bt.kind != .Basic {
			return false
		}
		basic := bt.variant.(Type_Basic)
		#partial switch basic.kind {
		case .U8, .U16, .U32, .U64, .U128, .Uint, .Uintptr, .U16le, .U32le, .U64le, .U128le, .U16be, .U32be, .U64be, .U128be:
			return true
		case:
			return false
		}
	}

	// Check patterns like `unsigned >= 0` (always true) or `unsigned < 0` (always false)
	if is_constant_zero(&right_op) && is_unsigned_type(left_op.type) {
		#partial switch be.op.kind {
		case .Gt_Eq:
			warning_node(node, "Comparison of unsigned value >= 0 is always true in 'for' loop condition")
		case .Lt:
			warning_node(node, "Comparison of unsigned value < 0 is always false in 'for' loop condition")
		case .Lt_Eq:
			warning_node(node, "Comparison of unsigned value <= 0 is equivalent to == 0 in 'for' loop condition")
		}
	}

	// Check patterns like `0 <= unsigned` (always true) or `0 > unsigned` (always false)
	if is_constant_zero(&left_op) && is_unsigned_type(right_op.type) {
		#partial switch be.op.kind {
		case .Lt_Eq:
			warning_node(node, "Comparison of 0 <= unsigned value is always true in 'for' loop condition")
		case .Gt:
			warning_node(node, "Comparison of 0 > unsigned value is always false in 'for' loop condition")
		case .Gt_Eq:
			warning_node(node, "Comparison of 0 >= unsigned value is equivalent to == 0 in 'for' loop condition")
		}
	}
}

// check_switch_stmt validates switch statements
// C++ Reference: check_stmt.cpp lines 1115-1351
check_switch_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Switch_Stmt)

	// Switch allows break and fallthrough
	flags := mod_flags + {.Break_Allowed, .Fallthrough_Allowed}

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	check_label(ctx, stmt.label, node)

	// Check optional init statement
	if stmt.init != nil {
		viral_flags |= check_stmt(ctx, stmt.init, {})
	}

	// Check tag expression (or create implicit "true")
	x: Operand
	x.mode = .Invalid

	if stmt.cond != nil {
		// Explicit tag expression
		check_expr(ctx, &x, stmt.cond)
		check_assignment(ctx, &x, nil, "switch expression")
		viral_flags |= accumulate_viral_flags_from_expr(ctx, stmt.cond)
		if x.type == nil {
		}
	} else {
		// Implicit tag: switch { } becomes switch true { }
		x.mode = .Constant
		x.type = t_bool
		x.value = true

		// Create a synthetic "true" identifier for error reporting
		// (C++ does this at check_stmt.cpp lines 1140-1145)
	}

	// C++ lines 1177-1181: Validate #partial is only used with enum types
	is_partial := stmt.partial
	if is_partial {
		if !is_type_enum(x.type) {
			error_node(stmt.cond if stmt.cond != nil else node, "#partial switch statement can only be used with an enum type")
		}
	}

	// Validate body is a block statement
	body_block, ok := stmt.body.derived.(^ast.Block_Stmt)
	if !ok {
		error_node(stmt.body, "Switch body must be a block statement")
	}

	// Check for multiple default clauses
	first_default: ^ast.Stmt = nil
	for case_stmt in body_block.stmts {
		if case_clause, is_case := case_stmt.derived.(^ast.Case_Clause); is_case {
			if len(case_clause.list) == 0 {
				// This is a default clause
				if first_default != nil {
					error_node(case_stmt, "Multiple default clauses (first at line %d)", first_default.pos.line)
				} else {
					first_default = case_stmt
				}
			}
		} else {
			error_node(case_stmt, "Invalid AST - expected case clause")
		}
	}

	// C++ line 1183: Track seen case values for duplicate detection
	// Multimap: hash of exact value -> list of (type, token) pairs
	seen_cases := make(map[uintptr][dynamic]Type_And_Token, context.temp_allocator)
	defer {
		for _, v in seen_cases {
			delete(v)
		}
		delete(seen_cases)
	}

	// Check each case clause
	for case_stmt in body_block.stmts {
		case_clause, is_case := case_stmt.derived.(^ast.Case_Clause)
		if !is_case {
			continue // Error already reported above
		}

		// Check each case expression
		for case_expr in case_clause.list {
			// C++ lines 1196-1254: Handle range expressions in switch cases (e.g., case 1..10:)
			if is_ast_range(case_expr) {
				be, is_binary := case_expr.derived.(^ast.Binary_Expr)
				if !is_binary {
					error_node(case_expr, "Internal error: is_ast_range returned true but expression is not binary")
					continue
				}

				// Check left and right operands of the range
				lhs: Operand
				lhs.mode = .Invalid
				check_expr_with_type_hint(ctx, &lhs, be.left, x.type)

				if x.mode == .Invalid {
					continue
				}
				if lhs.mode == .Invalid {
					continue
				}

				rhs: Operand
				rhs.mode = .Invalid
				check_expr_with_type_hint(ctx, &rhs, be.right, x.type)

				if rhs.mode == .Invalid {
					continue
				}

				// Validate that the switch type is ordered
				if !is_type_ordered(x.type) {
					type_str := type_to_string(x.type)
					error_node(case_expr, "Unordered type '%s' is invalid for an interval expression", type_str)
					continue
				}

				// Determine upper bound comparison operator based on range type
				upper_op := tokenizer.Token_Kind.Invalid
				#partial switch be.op.kind {
				case .Ellipsis:
					upper_op = .Lt_Eq
				case .Range_Full:
					upper_op = .Lt_Eq
				case .Range_Half:
					upper_op = .Lt
				case:
					error_node(case_expr, "Invalid range operator in switch case")
					continue
				}

				// Check: lhs <= x
				a := lhs
				check_comparison(ctx, case_expr, &a, &x, .Lt_Eq)
				if a.mode == .Invalid {
					continue
				}

				// Check: x <= rhs (or x < rhs for half-open ranges)
				b := rhs
				check_comparison(ctx, case_expr, &b, &x, upper_op)
				if b.mode == .Invalid {
					continue
				}

				// Check: lhs <= rhs (ensure range bounds are valid)
				a1 := lhs
				b1 := rhs
				check_comparison(ctx, case_expr, &a1, &b1, .Lt_Eq)

				// An ENUM range covers every member between its bounds, not just the two
				// endpoints. C++ splits on exactly this (check_expr.cpp:9582-9607,
				// add_to_seen_map): for an enum operand it walks `vi` from the lower to the
				// upper bound registering each value -- stopping before the upper bound for
				// a half-open range -- and only for non-enums does it register the two
				// bounds alone.
				//
				// The port had only the non-enum half, so `case .B ..= .E5:` credited B and
				// E5 and left C and D "unhandled". core/image/bmp's
				// `case .ABBR_16 ..= .V5:` reported seven spurious unhandled cases.
				is_enum_range := is_type_enum(x.type) &&
					lhs.mode == .Constant && lhs.value != nil &&
					rhs.mode == .Constant && rhs.value != nil
				if is_enum_range {
					v0 := exact_value_to_i64(lhs.value)
					v1 := exact_value_to_i64(rhs.value)
					for vi := v0; vi <= v1; vi += 1 {
						// Half-open (`..<`) excludes the upper bound.
						if upper_op != .Lt_Eq && vi == v1 {
							break
						}
						val := exact_value_i64(vi)
						key := hash_exact_value(val)
						if key == 0 {
							continue
						}
						if existing_list, found := &seen_cases[key]; found {
							dup := false
							for entry in existing_list {
								temp_operand := Operand {
									mode = .Value,
									type = entry.type,
								}
								if check_is_assignable_to(ctx, &temp_operand, x.type) {
									dup = true
									break
								}
							}
							if dup {
								// C++ reports against the SWITCH OPERAND expression
								// (add_constant_switch_case uses operand.expr, and the
								// enum-range path sets that to x.expr), and it keeps
								// walking the range afterwards. Breaking out here left the
								// remaining members unregistered, which then produced a
								// second, spurious "Unhandled switch cases".
								begin_error_block()
								x_str := expr_to_string(x.expr)
								error_node(x.expr, "Duplicate case '%s'", x_str)
								delete(x_str)
								end_error_block()
							}
						}
						entry := Type_And_Token {
							type  = x.type,
							token = ast_token(case_expr),
						}
						if key not_in seen_cases {
							seen_cases[key] = make([dynamic]Type_And_Token, context.temp_allocator)
						}
						append(&seen_cases[key], entry)
					}
				}

				// Add both bounds to seen cases for duplicate detection
				// Note: We add both lhs and rhs as separate entries
				if !is_enum_range && lhs.mode == .Constant && lhs.value != nil {
					key := hash_exact_value(lhs.value)
					if key != 0 {
						if existing_list, found := &seen_cases[key]; found {
							for entry in existing_list {
								temp_operand := Operand {
									mode = .Value,
									type = entry.type,
								}
								if check_is_assignable_to(ctx, &temp_operand, lhs.type) {
									begin_error_block()
									defer end_error_block()

									lhs_str := expr_to_string(be.left)
									defer delete(lhs_str)
									error_node(be.left, "Duplicate case '%s'", lhs_str)
									error_line("\tprevious case at %s", token_pos_to_string(entry.token.pos))
									break
								}
							}
						}

						entry := Type_And_Token {
							type  = lhs.type,
							token = ast_token(be.left),
						}
						if key not_in seen_cases {
							seen_cases[key] = make([dynamic]Type_And_Token, context.temp_allocator)
						}
						append(&seen_cases[key], entry)
					}
				}

				// A HALF-OPEN range (`a ..< b`) does not include its upper bound, so `b` must
				// not be registered as a value this case covers. The port registered both
				// bounds unconditionally, so
				//
				//	case 0 ..< _surr_self:
				//	case _surr_self ..= MAX_RUNE:
				//
				// reported `Duplicate case '_surr_self'` even though the two are disjoint.
				// core/unicode/utf16 is written exactly that way and accounted for the whole
				// 180-diagnostic class. `upper_op` is .Lt for `..<` and .Lt_Eq for `..=`/`..`,
				// which is already computed above for the bounds comparison.
				//
				// Genuine overlaps are still caught: `0 ..= A` followed by `A ..= B` registers
				// A from both cases and still errors, which the probe pins.
				if !is_enum_range && rhs.mode == .Constant && rhs.value != nil && upper_op != .Lt {
					key := hash_exact_value(rhs.value)
					if key != 0 {
						if existing_list, found := &seen_cases[key]; found {
							for entry in existing_list {
								temp_operand := Operand {
									mode = .Value,
									type = entry.type,
								}
								if check_is_assignable_to(ctx, &temp_operand, rhs.type) {
									begin_error_block()
									defer end_error_block()

									rhs_str := expr_to_string(be.right)
									defer delete(rhs_str)
									error_node(be.right, "Duplicate case '%s'", rhs_str)
									error_line("\tprevious case at %s", token_pos_to_string(entry.token.pos))
									break
								}
							}
						}

						entry := Type_And_Token {
							type  = rhs.type,
							token = ast_token(be.right),
						}
						if key not_in seen_cases {
							seen_cases[key] = make([dynamic]Type_And_Token, context.temp_allocator)
						}
						append(&seen_cases[key], entry)
					}
				}

				// Handle string type dependencies
				// C++ Reference: check_stmt.cpp:1247-1254
				// Add runtime dependencies for string comparison functions
				base_type_x := base_type(x.type)
				if is_type_string16(base_type_x) {
					add_package_dependency(ctx, "runtime", "string16_le")
					add_package_dependency(ctx, "runtime", "string16_lt")
				} else if is_type_string(base_type_x) {
					add_package_dependency(ctx, "runtime", "string_le")
					add_package_dependency(ctx, "runtime", "string_lt")
				}

				// Skip the regular case value check since we handled it as a range
				continue
			}

			y: Operand
			y.mode = .Invalid

			// Type switches (typeid) use check_expr_or_type, regular switches use check_expr
			// Pass the switch expression type as a hint to support implicit selectors (e.g., .EnumValue)
			is_typeid_switch := is_type_typeid(x.type)
			if is_typeid_switch {
				// For typeid switches, case expressions can be types
				check_expr_or_type(ctx, &y, case_expr, x.type)
			} else {
				check_expr_with_type_hint(ctx, &y, case_expr, x.type)
			}

			if x.mode == .Invalid || y.mode == .Invalid {
				continue
			}

			// C++ Reference: check_stmt.cpp:1314-1329, which carries the comment
			// "NOTE(bill): the ordering here matters":
			//     convert_to_typed(ctx, &y, x.type);
			//     Operand z = y;                                  // a COPY
			//     check_comparison(ctx, expr, &z, &x, Token_CmpEq);
			//     ... add_to_seen_map(ctx, &seen, y);             // records y, not z
			//
			// check_comparison OVERWRITES its first operand with the comparison result.
			// This port passed &y, so by the time the duplicate/exhaustiveness recording
			// below read `y` it held an `untyped bool` in mode .Value — never .Constant —
			// so seen_cases stayed EMPTY and every enum switch reported all of its members
			// as unhandled. Verified by instrumentation: `[CASE] mode=Value type=untyped bool`
			// and `seen_cases_len=0`.
			if !is_typeid_switch && y.mode != .Type {
				convert_to_typed(ctx, &y, x.type)
				if y.mode == .Invalid {
					continue
				}

				z := y
				check_comparison(ctx, case_expr, &z, &x, .Cmp_Eq)
				if z.mode == .Invalid {
					continue
				}
				if y.mode != .Constant {
					continue
				}
				update_untyped_expr_type(ctx, z.expr, x.type, !is_type_untyped(x.type))
			}

			// Ensure case value is not a type (except for typeid switches)
			if y.mode == .Type && !is_typeid_switch {
				error_node(case_expr, "Cannot use type '%s' as a case value", type_to_string(y.type))
				continue
			}

			// C++ lines 8995-9038: Duplicate case value detection
			if y.mode == .Constant && y.value != nil {
				// Hash the exact value
				key := hash_exact_value(y.value)
				if key != 0 {
					// Check if we've seen this value before
					if existing_list, found := &seen_cases[key]; found {
						// Check if any previous case with same hash is actually the same value
						for entry in existing_list {
							// Check type compatibility
							temp_operand := Operand {
								mode = .Value,
								type = entry.type,
							}
							if check_is_assignable_to(ctx, &temp_operand, y.type) {
								// Found a duplicate
								begin_error_block()
								defer end_error_block()

								// C++ Reference: check_expr.cpp:9564-9569 prints the case EXPRESSION,
								// not the value. `%v` on an Exact_Value dumps big.Int's
								// internals ("Int{used = 1, digit = [8192, 0, ...]}").
								dup_str := expr_to_string(case_expr)
								defer delete(dup_str)
								error_node(case_expr, "Duplicate case '%s'", dup_str)
								error_line("\tprevious case at %s", token_pos_to_string(entry.token.pos))
								break
							}
						}
					}

					// Add this case to the seen map
					entry := Type_And_Token {
						type  = y.type,
						token = ast_token(case_expr),
					}
					if key not_in seen_cases {
						seen_cases[key] = make([dynamic]Type_And_Token, context.temp_allocator)
					}
					append(&seen_cases[key], entry)
				}
			}
		}

		// Check case body with break/fallthrough allowed
		check_open_scope(ctx, case_stmt)
		viral_flags |= check_stmt_list(ctx, case_clause.body, flags)
		check_close_scope(ctx)
	}

	// C++ lines 1303-1336: Enum exhaustiveness checking
	if !is_partial && is_type_enum(x.type) {
		et := base_type(x.type)
		enum_type := et.variant.(Type_Enum)
		fields := enum_type.fields

		// Track unhandled enum values
		unhandled := make([dynamic]^Entity, 0, len(fields), context.temp_allocator)
		defer delete(unhandled)

		// Check each enum field to see if it was handled
		for field in fields {
			if field.kind != .Constant {
				continue
			}

			// Get the constant value for this enum field
			const_ent := field.variant.(Entity_Constant)
			v := const_ent.value

			// Check if this value was seen in the switch cases
			key := hash_exact_value(v)
			found := false
			if key != 0 {
				if existing_list, exists := &seen_cases[key]; exists {
					// Check if any entry in the list matches
					for _ in existing_list {
						// NOTE: We could do more sophisticated type checking here
						// but for enum values, hash equality is sufficient
						found = true
						break
					}
				}
			}

			if !found {
				append(&unhandled, field)
			}
		}

		// Report unhandled cases
		if len(unhandled) > 0 {
			begin_error_block()
			defer end_error_block()

			if len(unhandled) == 1 {
				error_node(node, "Unhandled switch case: %s", unhandled[0].token.text)
			} else {
				error_node(node, "Unhandled switch cases:")
				for f in unhandled {
					error_line("\t%s", f.token.text)
				}
			}
			error_line("\tSuggestion: Was '#partial switch' wanted?")
		}
	}

	// C++ lines 1606-1618: Strict style checking for case alignment
	if build_context.strict_style {
		switch_pos := stmt.switch_pos
		if body, is_block := stmt.body.derived.(^ast.Block_Stmt); is_block {
			for stmt_node in body.stmts {
				if clause, is_case := stmt_node.derived.(^ast.Case_Clause); is_case {
					case_pos := clause.case_pos
					if case_pos.column > switch_pos.column {
						error_pos(case_pos, "With '-strict-style', 'case' statements must share the same column as the 'switch' token")
					}
				}
			}
		}
	}

	return viral_flags
}

// check_type_switch_stmt validates type switch statements
// C++ Reference: check_stmt.cpp lines 1371-1570
check_type_switch_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Type_Switch_Stmt)

	// C++ line 1375: Type switch allows break but NOT fallthrough
	flags := mod_flags + {.Break_Allowed, .Type_Switch}

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	check_label(ctx, stmt.label, node)

	// Type switch tag must be an assignment statement with 'in'
	if stmt.tag == nil {
		error_node(node, "Type switch requires a tag assignment")
	}

	assign_stmt, is_assign := stmt.tag.derived.(^ast.Assign_Stmt)
	if !is_assign {
		error_node(stmt.tag, "Expected an 'in' assignment for this type switch statement")
	}

	// Validate assignment structure: `x in expr` or `&x in expr`
	if len(assign_stmt.lhs) != 1 {
		error_node(stmt.tag, "Expected 1 name before 'in'")
	}
	if len(assign_stmt.rhs) != 1 {
		error_node(stmt.tag, "Expected 1 expression after 'in'")
	}

	lhs := assign_stmt.lhs[0]
	rhs := assign_stmt.rhs[0]

	// Check if LHS is addressed (e.g., `&x in union_value`)
	is_addressed := false
	if unary, is_unary := lhs.derived.(^ast.Unary_Expr); is_unary {
		if unary.op.kind == .And {
			is_addressed = true
			lhs = unary.expr
		}
	}

	// LHS must be an identifier
	lhs_ident, is_ident := lhs.derived.(^ast.Ident)
	if !is_ident {
		error_node(lhs, "Expected an identifier, got '%v'", lhs)
	}

	// Check RHS expression (the value being type-switched)
	x: Operand
	x.mode = .Invalid
	check_expr(ctx, &x, rhs)
	check_assignment(ctx, &x, nil, "type switch expression")

	// C++ lines 1409-1422: Validate type is Union or Any
	Type_Switch_Kind :: enum {
		Invalid,
		Union,
		Any,
	}

	check_valid_type_switch_type :: proc(type: ^Type) -> Type_Switch_Kind {
		t := type_deref(type)
		if is_type_union(t) {
			return .Union
		}
		if is_type_any(t) {
			return .Any
		}
		return .Invalid
	}

	switch_kind := check_valid_type_switch_type(x.type)
	if switch_kind == .Invalid {
		type_str := type_to_string(x.type)
		error_node(rhs, "Invalid type for this type switch expression, got '%s'", type_str)
		return viral_flags
	}

	// Validate #partial is only used with unions
	if stmt.partial {
		if switch_kind != .Union {
			error_node(node, "#partial switch statement may only be used with a union")
		}
	}

	// Validate body is a block statement
	body_block, ok := stmt.body.derived.(^ast.Block_Stmt)
	if !ok {
		error_node(stmt.body, "Type switch body must be a block statement")
	}

	// Check for multiple default clauses
	first_default: ^ast.Stmt = nil
	for case_stmt in body_block.stmts {
		if case_clause, is_case := case_stmt.derived.(^ast.Case_Clause); is_case {
			if len(case_clause.list) == 0 {
				if first_default != nil {
					error_node(case_stmt, "Multiple default clauses (first at line %d)", first_default.pos.line)
				} else {
					first_default = case_stmt
				}
			}
		} else {
			error_node(case_stmt, "Invalid AST - expected case clause")
		}
	}

	// C++ lines 1457-1459: Track seen types for duplicate case type detection
	// Maps type to the AST node where it was first seen
	nil_seen: ^ast.Expr = nil
	seen_types := make(map[^Type]^ast.Expr, context.temp_allocator)
	defer delete(seen_types)

	// Process each case clause
	for case_stmt in body_block.stmts {
		case_clause, is_case := case_stmt.derived.(^ast.Case_Clause)
		if !is_case {
			continue
		}

		// Determine the case type for the tag variable
		case_type := x.type // Default to original type
		saw_nil := false

		// Check each case type expression
		for type_expr in case_clause.list {
			y: Operand
			y.mode = .Invalid

			// Type switch cases are types or nil
			check_expr_or_type(ctx, &y, type_expr, nil)

			if y.mode == .Invalid {
				continue
			}

			// C++ lines 1478-1494: Validate nil case
			if is_operand_nil(y) {
				// Check if nil is allowed for this type
				if !type_has_nil(type_deref(x.type)) {
					type_str := type_to_string(type_deref(x.type))
					error_node(type_expr, "'nil' case is not allowed for the type '%s'", type_str)
					continue
				}
				saw_nil = true

				// Check for duplicate nil cases
				if nil_seen != nil {
					begin_error_block()
					defer end_error_block()

					error_node(type_expr, "'nil' case has already been handled previously")
					error_line("\t'nil' was already previously seen at %s", token_pos_to_string(nil_seen.pos))
				} else {
					nil_seen = type_expr
				}
				case_type = y.type
				continue
			}

			// Case must be a type
			if y.mode != .Type {
				error_node(type_expr, "Expected a type as a case, got value")
				continue
			}

			// C++ lines 1503-1525: Validate case type is a variant of the union being switched
			if switch_kind == .Union {
				bt := base_type(type_deref(x.type))
				assert(is_type_union(bt), "Expected union type")
				union_type := bt.variant.(Type_Union)

				tag_type_found := false
				for vt in union_type.variants {
					if are_types_identical(vt, y.type) {
						tag_type_found = true
						break
					}
				}
				if !tag_type_found {
					type_str := type_to_string(y.type)
					error_node(type_expr, "Unknown variant type, got '%s'", type_str)
					continue
				}
				// Register type info for RTTI
				// C++ Reference: check_stmt.cpp type switch handling
				add_type_info_type(ctx, y.type)
			} else if switch_kind == .Any {
				// Any type accepts all types - register for RTTI
				// C++ Reference: check_stmt.cpp type switch handling
				add_type_info_type(ctx, y.type)
			}

			// C++ lines 1527-1537: Track seen types for duplicate detection
			if prev_expr, found := seen_types[y.type]; found {
				begin_error_block()
				defer end_error_block()

				type_str := type_to_string(y.type)
				error_node(type_expr, "Duplicate type case '%s'", type_str)
				error_line("\tprevious type case at %s", token_pos_to_string(prev_expr.pos))
				continue
			}
			seen_types[y.type] = type_expr

			// Use this type for the tag variable (if single case)
			if len(case_clause.list) == 1 && !saw_nil {
				case_type = y.type
			}
		}

		// Multiple cases or nil means tag keeps original type
		if len(case_clause.list) > 1 || saw_nil {
			case_type = x.type
		}

		// Create scope with tag variable
		check_open_scope(ctx, case_stmt)

		// Create the tag variable entity with the narrowed type
		// C++ Reference: check_stmt.cpp:1557-1565
		tag_token := tokenizer.Token {
			text = lhs_ident.name,
			pos  = lhs.pos,
			kind = .Ident,
		}
		tag_var := alloc_entity_variable(ctx.scope, tag_token, case_type, .Resolved, ctx.checker.allocator)

		// Set entity flags to match C++ behavior
		tag_var.flags += {.Used, .Switch_Value}
		if !is_addressed {
			tag_var.flags += {.Value}
		}

		// Add tag variable to case scope
		existing := scope_insert(ctx.scope, tag_var)
		if existing != nil {
			error_node(lhs, "Tag variable '%s' conflicts with existing entity", lhs_ident.name)
		}

		// Check case body
		viral_flags |= check_stmt_list(ctx, case_clause.body, flags)
		check_close_scope(ctx)
	}

	// C++ lines 1571-1603: Check union completeness for non-partial switches
	if !stmt.partial && is_type_union(type_deref(x.type)) {
		ut := base_type(type_deref(x.type))
		assert(is_type_union(ut), "Expected union type")
		union_type := ut.variant.(Type_Union)
		variants := union_type.variants

		// Collect unhandled variants
		unhandled := make([dynamic]^Type, 0, len(variants), context.temp_allocator)
		defer delete(unhandled)

		for variant in variants {
			found := false
			for seen_type, _ in seen_types {
				if are_types_identical(variant, seen_type) {
					found = true
					break
				}
			}
			if !found {
				append(&unhandled, variant)
			}
		}

		// Report unhandled cases
		if len(unhandled) > 0 {
			begin_error_block()
			defer end_error_block()

			if len(unhandled) == 1 {
				type_str := type_to_string(unhandled[0])
				error_node(node, "Unhandled switch case: %s", type_str)
			} else {
				error_node(node, "Unhandled switch cases:")
				for t in unhandled {
					type_str := type_to_string(t)
					error_line("\t%s", type_str)
				}
			}
			error_line("")
			error_line("\tSuggestion: Was '#partial switch' wanted?")
		}
	}

	// C++ lines 1606-1618: Strict style checking for case alignment
	if build_context.strict_style {
		switch_pos := stmt.switch_pos
		if body, is_block := stmt.body.derived.(^ast.Block_Stmt); is_block {
			for stmt_node in body.stmts {
				if clause, is_case := stmt_node.derived.(^ast.Case_Clause); is_case {
					case_pos := clause.case_pos
					if case_pos.column > switch_pos.column {
						error_pos(case_pos, "With '-strict-style', 'case' statements must share the same column as the 'switch' token")
					}
				}
			}
		}
	}

	return viral_flags
}

// check_branch_stmt validates break/continue/fallthrough statements
// C++ Reference: check_stmt.cpp lines 2862-2935
check_branch_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Branch_Stmt)
	token := stmt.tok

	// Validate based on token kind
	#partial switch token.kind {
	case .Break:
		if .Break_Allowed not_in flags && stmt.label == nil {
			error_node(node, "'break' only allowed in non-inline loops or 'switch' statements")
		}

	case .Continue:
		if .Continue_Allowed not_in flags && stmt.label == nil {
			error_node(node, "'continue' only allowed in non-inline loops")
		}

	case .Fallthrough:
		// Fallthrough is switch-specific
		if .Fallthrough_Allowed not_in flags {
			if .Type_Switch in flags {
				error_node(node, "'fallthrough' statement not allowed within a type switch statement")
			} else {
				error_node(node, "'fallthrough' statement in illegal position, expected at the end of a 'case' block")
			}
		} else if stmt.label != nil {
			error_node(node, "'fallthrough' cannot have a label")
		}

	case:
		error_node(node, "Invalid AST: Branch Statement '%s'", token.text)
	}

	// Handle labeled branches
	// C++ lines 2890-2932: Label resolution and validation
	if stmt.label != nil {
		// C++ line 2891-2894: Verify label is an identifier
		if stmt.label.derived.(^ast.Ident) == nil {
			error_node(stmt.label, "A branch statement's label name must be an identifier")
			return {}
		}

		// C++ lines 2896-2902: Look up the label entity
		ident := stmt.label
		name := ident.derived.(^ast.Ident).name
		o := Operand{}
		e := check_ident(ctx, &o, ident, nil, nil, false)
		if e == nil {
			error_node(ident, "Undeclared label name: %s", name)
			return {}
		}
		add_entity_use(ctx, ident, e)

		// C++ lines 2903-2905: Verify it's a label entity
		if e.kind != .Label {
			error_node(ident, "'%s' is not a label", name)
			return {}
		}

		// C++ lines 2906-2926: Check label's parent statement type matches branch type
		label_ent := e.variant.(Entity_Label)
		parent := label_ent.parent
		assert(parent != nil, "Label parent should not be nil")

		#partial switch _ in parent.derived {
		case ^ast.Block_Stmt, ^ast.If_Stmt, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
			if token.kind != .Break {
				error_node(stmt.label, "Label '%s' can only be used with 'break'", e.token.text)
			}
		case ^ast.Range_Stmt, ^ast.For_Stmt:
			if token.kind != .Break && token.kind != .Continue {
				error_node(stmt.label, "Label '%s' can only be used with 'break' and 'continue'", e.token.text)
			}
		}

		// C++ lines 2929-2931: Check labeled branches aren't used in defer
		if ctx.in_defer {
			error_node(stmt.label, "A labelled '%s' cannot be used within a 'defer'", token.text)
		}
	}

	// Branch statements don't produce viral flags
	return viral_flags
}

// is_ast_decl checks if a statement is a declaration
// C++ Reference: check_stmt.cpp (implicit in is_ast_decl checks)
// is_ast_decl is defined in check_collect.odin

// check_defer_stmt validates defer statements
// C++ Reference: check_stmt.cpp lines 2803-2860
check_defer_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Defer_Stmt)

	// Cannot defer a declaration
	if is_ast_decl(stmt.stmt) {
		error_node(node, "You cannot defer a declaration")
		return viral_flags
	}

	// Set in_defer flag during checking
	prev_in_defer := ctx.in_defer
	ctx.in_defer = true
	defer ctx.in_defer = prev_in_defer

	// Check the deferred statement
	viral_flags |= check_stmt(ctx, stmt.stmt, {})

	// C++ line 2812: Track defer usage
	if ctx.decl != nil {
		ctx.decl.defer_used += 1
	}

	// C++ lines 2814-2860: Error/warning handling
	deferred_stmt := stmt.stmt
	original_stmt := deferred_stmt

	// C++ lines 2818-2820: Early exit for empty defer blocks
	// FEATURE: C++ doesn't warn, but we add a warning for empty defer blocks
	if block, is_block := deferred_stmt.derived.(^ast.Block_Stmt); is_block && len(block.stmts) == 0 {
		warning_node(deferred_stmt, "Empty defer block has no effect")
		return viral_flags
	}

	// C++ lines 2822-2843: Find the singular inner statement (unwrap single-statement blocks)
	is_singular := true
	for is_singular {
		if block, is_block := deferred_stmt.derived.(^ast.Block_Stmt); is_block {
			inner_stmt: ^ast.Stmt = nil
			for s in block.stmts {
				if _, is_empty := s.derived.(^ast.Empty_Stmt); is_empty {
					continue
				}
				if inner_stmt != nil {
					is_singular = false
					break
				}
				inner_stmt = s
			}
			if inner_stmt != nil {
				deferred_stmt = inner_stmt
			} else {
				break
			}
		} else {
			break
		}
	}
	if !is_singular {
		deferred_stmt = original_stmt
	}

	// C++ lines 2845-2858: Check for assignment to named return values
	if assign_stmt, is_assign := deferred_stmt.derived.(^ast.Assign_Stmt); is_assign {
		if assign_stmt.op.kind == .Eq {
			for lhs in assign_stmt.lhs {
				e := entity_of_node(&ctx.checker.info, lhs)
				if e != nil && .Result in e.flags {
					error_node(lhs, "Assignments to named return values within 'defer' will not affect the value that is returned")
				}
			}
		}
	}

	return viral_flags
}

// check_value_decl_stmt validates variable declarations in statement context
// C++ Reference: check_stmt.cpp lines 2056-2328
check_value_decl_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	vd := node.derived.(^ast.Value_Decl)

	// Constant declarations in statement context
	// C++ Reference: check_stmt.cpp lines 2058-2071
	if !vd.is_mutable {
		// constant value declaration
		// NOTE(bill): Check `_` declarations
		for name in vd.names {
			is_blank := false
			ident: ^ast.Ident
			if id, ok := name.derived.(^ast.Ident); ok {
				ident = id
				is_blank = is_blank_ident(id.name)
			}
			if is_blank {
				if ident != nil {
					e := entity_of_node(&ctx.checker.info, name)
					d := decl_info_of_entity(e)
					if d != nil {
						check_entity_decl(ctx, e, d, nil)
					}
				}
			}
		}
		return viral_flags
	}

	// Mutable variable declarations
	// C++ Reference: check_stmt.cpp lines 2072-2116
	entities := make([dynamic]^Entity, 0, len(vd.names), context.temp_allocator)
	entity_count := 0

	new_name_count := 0
	for name in vd.names {
		entity: ^Entity = nil
		if name.derived == nil {
			error_node(name, "Expected an identifier for variable declaration")
		} else if ident, is_ident := name.derived.(^ast.Ident); !is_ident {
			error_node(name, "Expected an identifier for variable declaration")
		} else {
			token := tokenizer.Token {
				text = ident.name,
				pos  = name.pos,
				kind = .Ident,
			}
			str := token.text
			found: ^Entity = nil

			// NOTE(bill): Ignore assignments to '_'
			if str != "_" {
				found = scope_lookup_current(ctx.scope, str)
				new_name_count += 1
			}

			if found == nil {
				entity = alloc_entity_variable(ctx.scope, token, nil, .Unresolved, ctx.checker.allocator)

				// Handle foreign variables
				// C++ Reference: check_stmt.cpp lines 2093-2098
				fl := ctx.foreign_context.curr_library
				if fl != nil {
					#partial switch &v in entity.variant {
					case Entity_Variable:
						v.is_foreign = true
						v.foreign_library_ident = fl
					}
				}
			} else {
				// Check if this is a pre-collected entity from check_collect_value_decl
				// If so, reuse it instead of reporting a redeclaration error
				existing_entity := entity_of_node(&ctx.checker.info, name)
				if existing_entity != nil && existing_entity == found && found.kind == .Variable {
					entity = found
					// Update new_name_count since this is actually a new declaration
					// that was pre-collected
				} else {
					pos := found.token.pos
					error_node(name, "Redeclaration of '%s' in this scope\n\tat %s", str, token_pos_to_string(pos))
					entity = found
				}
			}
		}

		if entity == nil {
			token := tokenizer.Token {
				text = "",
				pos  = name.pos,
				kind = .Ident,
			}
			// Create dummy entity in global scope
			entity = alloc_entity_dummy_variable(ctx.checker.info.global_scope, token, ctx.checker.allocator)
		}

		entity.parent_proc_decl = ctx.curr_proc_decl
		append(&entities, entity)
		entity_count += 1

		// Store entity in AST entity map (since AST nodes are immutable)
		set_entity_for_node(&ctx.checker.info, name, entity)
	}

	// Check for new declarations
	// C++ Reference: check_stmt.cpp lines 2118-2137
	if new_name_count == 0 {
		error_node(node, "No new declarations on the left hand side")

		// Check if all are underscores and suggest using assignment
		all_underscore := true
		for name in vd.names {
			is_blank := false
			if ident, ok := name.derived.(^ast.Ident); ok {
				is_blank = is_blank_ident(ident.name)
			}
			if !is_blank {
				all_underscore = false
				break
			}
		}

		if all_underscore {
			error_line("\tSuggestion: Try changing the declaration (:=) to an assignment (=)\n")
		}
	}

	// Check type annotation
	// C++ Reference: check_stmt.cpp lines 2139-2158
	init_type: ^Type = nil
	if vd.type != nil {
		init_type = check_type(ctx, vd.type)
		if init_type == nil {
			init_type = t_invalid
		} else if is_type_polymorphic(base_type(init_type)) {
			/* DISABLED: This error seems too aggressive for instantiated generic types.
	// NOTE: type_to_string returns either a string LITERAL ("<no type>", "<invalid>")
	// or a builder over context.temp_allocator -- never a context.allocator allocation.
	// `delete` on it frees a non-heap pointer and aborts with "free(): invalid pointer".
	// (expr_to_string is the opposite: it clones into context.allocator and MUST be freed.)
			str := type_to_string(init_type)
			error(vd.type, "Invalid use of a polymorphic type '%s' in variable declaration", str)
			init_type = t_invalid
			*/
		}

		// Helpful error for common mistake
		// C++ Reference: check_stmt.cpp lines 2152-2157
		if init_type == t_invalid && entity_count == 1 && (.Break_Allowed in mod_flags || .Fallthrough_Allowed in mod_flags) {
			e := entities[0]
			if e != nil && e.token.text == "default" {
				warning_token(e.token, "Did you mean 'case:'?")
			}
		}
	}

	// Check declaration attributes
	// C++ Reference: check_stmt.cpp lines 2161-2220
	ac := Attribute_Context {
		link_prefix = ctx.foreign_context.link_prefix,
		link_suffix = ctx.foreign_context.link_suffix,
	}
	check_decl_attributes(ctx, vd.attributes[:], &ac)

	// Apply attributes to entities
	for i in 0 ..< entity_count {
		e := entities[i]
		assert(e != nil)

		if .Visited in e.flags {
			e.type = t_invalid
			continue
		}
		e.flags += {.Visited}

		e.state = .In_Progress
		if e.type == nil {
			set_entity_type(e, init_type)
			// Also set main entity type for type hint propagation in check_unpack_arguments
			e.type = init_type
			e.state = .Resolved
		}

		// Handle link_name
		ac.link_name = handle_link_name(ctx, e.token, ac.link_name, ac.link_prefix, ac.link_suffix)
		if len(ac.link_name) > 0 {
			#partial switch &v in e.variant {
			case Entity_Variable:
				v.link_name = ac.link_name
			}
		}

		// Handle @(static) attribute
		// C++ Reference: check_stmt.cpp lines 2185-2196
		e.flags -= {.Static}
		if ac.is_static {
			name := e.token.text
			if name == "_" {
				error_token(e.token, "The 'static' attribute is not allowed to be applied to '_'")
			} else {
				e.flags += {.Static}
				if ctx.in_defer {
					error_token(e.token, "'static' variables cannot be declared within a defer statement")
				}
			}
		}

		// Handle @(rodata) attribute
		// C++ Reference: check_stmt.cpp lines 2197-2203
		if ac.rodata {
			if ac.is_static {
				#partial switch &v in e.variant {
				case Entity_Variable:
					v.is_rodata = true
				}
			} else {
				error_token(e.token, "Only global or @(static) variables can have @(rodata) applied")
			}
		}

		// Handle @(thread_local) attribute
		// C++ Reference: check_stmt.cpp lines 2204-2220
		if ac.thread_local_model != "" {
			name := e.token.text
			if name == "_" {
				error_token(e.token, "The 'thread_local' attribute is not allowed to be applied to '_'")
			} else {
				e.flags += {.Static}
				if ctx.in_defer {
					error_token(e.token, "'thread_local' variables cannot be declared within a defer statement")
				}
			}
			#partial switch &v in e.variant {
			case Entity_Variable:
				v.thread_local_model = ac.thread_local_model
			}
		}

		if ac.is_static && ac.thread_local_model != "" {
			error_token(e.token, "The 'static' attribute is not needed if 'thread_local' is applied")
		}
	}

	// Check initialization values
	// C++ Reference: check_stmt.cpp:2295-2301. The type_hint_expr save/set/restore is
	// part of this call, not decoration — it is what makes `x: [?]T = {...}` work, by
	// letting the untyped compound literal borrow the declaration's type expression
	// (read at check_compound_lit.odin:287, mirroring check_expr.cpp:10566).
	// The port declared the field but never wrote it, so that reader was dead.
	prev_type_hint_expr := ctx.type_hint_expr
	ctx.type_hint_expr = vd.type

	check_init_variables(ctx, entities[:], vd.values, "variable declaration")

	ctx.type_hint_expr = prev_type_hint_expr

	// Check arity match
	// C++ Reference: check_stmt.cpp line 2230
	check_arity_match(ctx, vd, false)

	// Post-processing for foreign and static variables
	// C++ Reference: check_stmt.cpp lines 2232-2280
	for i in 0 ..< entity_count {
		e := entities[i]

		#partial switch v in e.variant {
		case Entity_Variable:
			if v.is_foreign {
				// Foreign variables cannot have default values
				// C++ Reference: check_stmt.cpp lines 2235-2248
				if len(vd.values) > 0 {
					error_token(e.token, "A foreign variable declaration cannot have a default value")
				}

				name := e.token.text
				if len(v.link_name) > 0 {
					name = v.link_name
				}

				init_entity_foreign_library(ctx, e)

				// Check for duplicate foreign entities
				// C++ Reference: check_stmt.cpp lines 2250-2266
				key := name
				found := ctx.checker.info.foreigns[key]
				if found != nil {
					f := found
					pos := f.token.pos
					this_type := base_type(e.type)
					other_type := base_type(f.type)
					if !signature_parameter_similar_enough(this_type, other_type) {
						error_token(e.token, "Foreign entity '%s' previously declared elsewhere with a different type\n\tat %s", name, token_pos_to_string(pos))
					}
				} else {
					ctx.checker.info.foreigns[key] = e
				}
			} else if .Static in e.flags {
				// Static variables with values must be constant
				// C++ Reference: check_stmt.cpp lines 2267-2278
				if len(vd.values) > 0 {
					if entity_count != len(vd.values) {
						error_token(e.token, "A static variable declaration with a default value must be constant")
					} else {
						value := vd.values[i]
						if tv, ok := tav_lookup(ctx.info, value); ok {
							if tv.mode != .Constant {
								error_token(e.token, "A static variable declaration with a default value must be constant")
							}
						}
					}
				}
			}
		}

		add_entity(ctx, ctx.scope, vd.names[i], e)
	}

	// Handle 'using' modifier on variables
	// C++ Reference: check_stmt.cpp lines 2282-2327
	if vd.is_using {
		token := tokenizer.Token {
			text = "",
			pos  = vd.names[0].pos,
			kind = .Ident,
		}
		if vd.type != nil && entity_count > 1 {
			error_token(token, "'using' can only be applied to one variable of the same type")
			// NOTE(bill): `using` will only be applied to a single declaration
		}

		// Only apply to first entity
		for entity_index in 0 ..< min(entity_count, 1) {
			e := entities[entity_index]
			if e == nil {
				continue
			}
			if e.kind != .Variable {
				continue
			}

			name := e.token.text
			t := base_type(type_deref(e.type))

			if name == "_" {
				error_token(token, "'using' cannot be applied to variable declared as '_'")
			} else if is_type_struct(t) || is_type_raw_union(t) {
				// Apply using to struct/union fields
				// C++ Reference: check_stmt.cpp lines 2302-2318
				#partial switch st in t.variant {
				case Type_Struct:
					scope := st.scope
					assert(scope != nil)

					for _, f in scope.elements {
						if f.kind == .Variable {
							uvar := alloc_entity_using_variable(e, f.token, get_entity_type(f), vd.names[0])

							if .Value in e.flags {
								uvar.flags += {.Value}
							}

							prev := scope_insert(ctx.scope, uvar)
							if prev != nil {
								error_token(token, "Namespace collision while 'using' '%s' of: %s", name, prev.token.text)
								return viral_flags
							}
						}
					}

					add_entity_use(ctx, nil, e)
				}
			} else {
				// NOTE(bill): skip the rest to remove extra errors
				error_token(token, "'using' can only be applied to variables of type struct or raw_union")
				return viral_flags
			}
		}
	}

	return viral_flags
}

// check_assignment_variable validates an assignment to a variable
// This performs variable-specific validation before delegating to check_assignment
// C++ Reference: /mnt/c/odin/src/check_stmt.cpp:421-640
check_assignment_variable :: proc(ctx: ^Checker_Context, lhs, rhs: ^Operand, context_name: string) -> ^Type {
	// C++: check_stmt.cpp:422-424
	if rhs.mode == .Invalid {
		return nil
	}

	// C++: check_stmt.cpp:425-429
	if rhs.type == t_invalid && rhs.mode != .Proc_Group && rhs.mode != .Builtin {
		return nil
	}

	// C++: check_stmt.cpp:431
	node := unparen_expr(lhs.expr)

	// C++: check_stmt.cpp:433-440
	// NOTE: Ignore assignments to '_'
	is_blank := false
	if ident, ok := node.derived.(^ast.Ident); ok {
		is_blank = is_blank_ident(ident.name)
	}
	if is_blank {
		check_assignment(ctx, rhs, nil, "assignment to '_' identifier")
		if rhs.mode == .Invalid {
			return nil
		}
		return rhs.type
	}

	e: ^Entity = nil
	used := false

	// C++: check_stmt.cpp:445-450
	if lhs.mode == .Invalid || (lhs.type == t_invalid && lhs.mode != .Proc_Group && lhs.mode != .Builtin) {
		return nil
	}

	// C++: check_stmt.cpp:452-493
	if rhs.mode == .Proc_Group {
		procs := proc_group_entities(ctx, rhs)
		assert(len(procs) > 0)

		// NOTE: These should be done
		// C++: check_stmt.cpp:457-470
		for i := 0; i < len(procs); i += 1 {
			t := base_type(procs[i].type)
			if t == t_invalid {
				continue
			}
			x := Operand{}
			x.mode = .Value
			x.type = t
			if check_is_assignable_to(ctx, &x, lhs.type) {
				e = procs[i]
				add_entity_use(ctx, rhs.expr, e)
				break
			}
		}

		// C++: check_stmt.cpp:472-476
		if e != nil {
			rhs.mode = .Value
			rhs.type = e.type
			rhs.proc_group = nil
		}
	} else {
		// C++: check_stmt.cpp:478-492
		ident_node: ^ast.Node = nil

		#partial switch n in node.derived {
		case ^ast.Ident:
			ident_node = node
		case ^ast.Index_Expr:
			if _, ok := n.expr.derived.(^ast.Ident); ok {
				ident_node = n.expr
			}
		}

		if ident_node != nil {
			if ident, ok := ident_node.derived.(^ast.Ident); ok {
				e = scope_lookup(ctx.scope, ident.name)
				if e != nil && e.kind == .Variable {
					used = .Used in e.flags // NOTE: Make backup just in case
				}
			}
		}
	}

	// C++: check_stmt.cpp:495-497
	if e != nil && used {
		e.flags += {.Used}
	}

	// C++: check_stmt.cpp:499
	assignment_type := lhs.type

	// C++: check_stmt.cpp:501-505
	if rhs.mode == .Type && is_type_polymorphic(rhs.type) {
		t_str := type_to_string(rhs.type)
		error_node(rhs.expr, "Invalid use of a non-specialized polymorphic type '%s'", t_str)
	}

	// C++: check_stmt.cpp:507-622
	#partial switch lhs.mode {
	case .Invalid:
		// C++: check_stmt.cpp:508-509
		return nil

	case .Variable:
		// C++: check_stmt.cpp:511-515
		if e != nil && e.kind == .Variable {
			var := e.variant.(Entity_Variable)
			if var.is_rodata {
				error_node(lhs.expr, "Assignment to variable '%s' marked as @(rodata) is not allowed", e.token.text)
			}
		}

		// NOTE: the parameter-immutability check does NOT belong in this arm. C++
		// has it only in the DEFAULT arm of this switch (check_stmt.cpp:558-605),
		// i.e. for modes that are not already `.Variable`. A field reached through a
		// `using` on a POINTER parameter resolves as `.Variable` and is legitimately
		// assignable — `defilter_8 :: proc(params: ^Filter_Params) { using params;
		// src = src[1:] }` in core/image/png. The correct copy is in the `case:` arm
		// below, and it now fires for the by-VALUE case because parameters finally
		// carry `.Value` (see check_type.odin, alloc_entity_param).

	case .Map_Index:
		// C++: check_stmt.cpp:517-534
		ln := unparen_expr(lhs.expr)
		if idx_expr, ok := ln.derived.(^ast.Index_Expr); ok {
			x := idx_expr.expr
			tav, has_tav := tav_lookup(ctx.info, x)
			assert(has_tav)
			if tav.mode != .Variable {
				if !is_type_pointer(tav.type) {
					str := expr_to_string(lhs.expr)
					defer delete(str)
					error_node(lhs.expr, "Cannot assign to the value of a map '%s'", str)
					return nil
				}
			}
		}

	case .Context:
	// C++: check_stmt.cpp:536-537
	// No checks needed for context assignment

	case .Soa_Variable:
	// C++: check_stmt.cpp:539-540
	// No checks needed for SOA variable assignment

	case .Swizzle_Variable:
	// C++: check_stmt.cpp:542-543
	// No checks needed for swizzle variable assignment

	case:
		// C++: check_stmt.cpp:545-621
		// Default case: check for invalid assignments

		// C++: check_stmt.cpp:546-557
		if sel_expr, ok := lhs.expr.derived.(^ast.Selector_Expr); ok {
			// NOTE: Extra error checks
			op_c := Operand {
				mode = .Invalid,
			}
			check_expr(ctx, &op_c, sel_expr.expr)
			if op_c.mode == .Map_Index {
				str := expr_to_string(lhs.expr)
				defer delete(str)
				error_node(lhs.expr, "Cannot assign to struct field '%s' in map", str)
				return nil
			}
		}

		// C++: check_stmt.cpp:559-569
		// In C++, this creates a new local 'e' that shadows the function-scope 'e'
		// In Odin, we reuse the existing 'e' to avoid redeclaration
		e = entity_of_node(&ctx.checker.info, lhs.expr)
		original_e := e

		name := unparen_expr(lhs.expr)
		for sel_expr, ok := name.derived.(^ast.Selector_Expr); ok; sel_expr, ok = name.derived.(^ast.Selector_Expr) {
			name = sel_expr.expr
			e = entity_of_node(&ctx.checker.info, name)
		}
		if e == nil {
			e = original_e
		}

		// C++: check_stmt.cpp:571-619
		str := expr_to_string(lhs.expr)
		defer delete(str)

		// Note: Named return values have both .Param and .Result flags, but they ARE mutable
		if e != nil && .Param in e.flags && .Result not_in e.flags {
			// C++: check_stmt.cpp:572-584
			// ERROR_BLOCK
			if .Using in e.flags {
				error_node(lhs.expr, "Cannot assign to '%s' which is from a 'using' procedure parameter", str)
			} else {
				error_node(lhs.expr, "Cannot assign to '%s' which is a procedure parameter", str)
			}
			if is_type_pointer(e.type) {
				error_line("\tSuggestion: Did you mean to shadow it? '%s := %s'?\n", e.token.text, e.token.text)
			} else {
				error_line("\tSuggestion: Did you mean to pass '%s' by pointer?\n", e.token.text)
			}
		} else if e == nil || .Result not_in e.flags {
			// C++: check_stmt.cpp:585-617
			// ERROR_BLOCK
			error_node(lhs.expr, "Cannot assign to '%s'", str)

			if e != nil && .For_Value in e.flags {
				if is_type_map(e.type) {
					error_line("\tSuggestion: Did you mean? 'for key, &%s in ...'\n", e.token.text)
				} else {
					error_line("\tSuggestion: Did you mean? 'for &%s in ...'\n", e.token.text)
				}
			} else if e != nil && .Switch_Value in e.flags {
				error_line("\tSuggestion: Did you mean? 'switch &%s in ...'\n", e.token.text)
			}
		}
	}

	// C++: check_stmt.cpp:624-633
	// Track bit field bit size for assignment checking
	lhs_e := entity_of_node(&ctx.checker.info, lhs.expr)
	prev_bit_field_bit_size := ctx.bit_field_bit_size
	if lhs_e != nil && lhs_e.kind == .Variable {
		if var_ent, ok := lhs_e.variant.(Entity_Variable); ok && var_ent.bit_field_bit_size != 0 {
			// HACK NOTE(bill): This is a bit of a hack, but it will work fine for this use case
			ctx.bit_field_bit_size = i64(var_ent.bit_field_bit_size)
		}
	}

	// C++: check_stmt.cpp:631
	check_assignment(ctx, rhs, assignment_type, context_name)

	// C++: check_stmt.cpp:633 - Restore previous bit field bit size
	ctx.bit_field_bit_size = prev_bit_field_bit_size

	// C++: check_stmt.cpp:635-637
	if rhs.mode == .Invalid {
		return nil
	}

	// C++: check_stmt.cpp:639
	return rhs.type
}

// check_foreign_block_decl validates foreign import blocks
// C++ Reference: /mnt/c/odin/src/checker.cpp:4760-4780 (check_add_foreign_block_decl)
// C++ Reference: /mnt/c/odin/src/checker.cpp:3417-3488 (foreign_block_decl_attribute)
//
// Foreign blocks have the form:
//   foreign lib_name { ... }
//
// Where lib_name is an identifier referring to a foreign import declaration.
// The block sets up a foreign context that applies to all declarations within.
check_foreign_block_decl :: proc(ctx: ^Checker_Context, node: ^ast.Stmt) {
	fb := node.derived.(^ast.Foreign_Block_Decl)
	foreign_library := fb.foreign_library

	// Create a modified context with foreign library set
	// C++ Reference: checker.cpp:4764-4770
	c := ctx^
	if _, ok := foreign_library.derived.(^ast.Ident); ok {
		c.foreign_context.curr_library = foreign_library
	} else {
		error_node(foreign_library, "Foreign block name must be an identifier")
		c.foreign_context.curr_library = nil
	}

	// Check foreign block attributes
	// C++ Reference: checker.cpp:4772
	// Supported attributes:
	// - @(default_calling_convention="c|stdcall|...")
	// - @(link_prefix="...")
	// - @(link_suffix="...")
	// - @(private="file|package")
	// - @(require_results)
	check_foreign_block_attributes(&c, fb.attributes)

	// Process declarations in the block body
	// C++ Reference: checker.cpp:4774-4778
	if block, ok := fb.body.derived.(^ast.Block_Stmt); ok {
		check_stmt_list(&c, block.stmts, {})
	} else {
		error_node(fb.body, "Foreign block body must be a block statement")
	}
}

// check_foreign_block_attributes validates foreign block attributes
// C++ Reference: checker.cpp:3706 (foreign_block_decl_attribute), dispatched via
// check_decl_attributes at checker.cpp:4562 (the previously cited line range
// 3417-3488 was stale and no longer corresponds to this function)
check_foreign_block_attributes :: proc(ctx: ^Checker_Context, attributes: [dynamic]^ast.Attribute) {
	for attr in attributes {
		for elem_node in attr.elems {
			// An attribute element is either a bare identifier (`@(name)`,
			// value-less form) or a Field_Value (`@(name=value)`). Extracting
			// via a comma-ok switch mirrors the pattern used elsewhere in this
			// package (e.g. check_collect.odin, check_import_export.odin,
			// check_decl.odin, check_decl_helpers.odin, docs_writer.odin).
			name: string
			value_node: ^ast.Expr = nil

			#partial switch e in elem_node.derived {
			case ^ast.Ident:
				name = e.name
			case ^ast.Field_Value:
				if field_ident, ok2 := e.field.derived.(^ast.Ident); ok2 {
					name = field_ident.name
					value_node = e.value
				} else {
					error_node(e.field, "Attribute name must be an identifier")
					continue
				}
			case:
				continue
			}

			// Process attribute value
			operand: Operand
			if value_node != nil {
				check_expr(ctx, &operand, value_node)
				if operand.mode != .Constant {
					error_node(value_node, "Attribute value must be a constant")
					continue
				}
			}

			// Handle specific attributes
			// C++ Reference: checker.cpp:3420-3485
			switch name {
			case "default_calling_convention":
				// C++ line 3425-3436
				if value_node == nil {
					error_node(elem_node, "Expected a string value for 'default_calling_convention'")
					continue
				}
				if str, ok := operand.value.(string); ok {
					cc := string_to_calling_convention(str)
					if cc == .Invalid {
						error_node(value_node, "Unknown procedure calling convention: '%s'", str)
					} else {
						ctx.foreign_context.default_cc = cc
						ctx.foreign_context.default_cc_set = true
					}
				} else {
					error_node(value_node, "Expected a string value for 'default_calling_convention'")
				}

			case "link_prefix":
				// C++ line 3437-3448
				if value_node == nil {
					error_node(elem_node, "Expected a string value for 'link_prefix'")
					continue
				}
				if str, ok := operand.value.(string); ok {
					link_prefix := strings.trim_space(str)
					if !is_foreign_name_valid(link_prefix) {
						error_node(value_node, "Invalid link prefix: %s", link_prefix)
					}
					ctx.foreign_context.link_prefix = link_prefix
				} else {
					error_node(value_node, "Expected a string value for 'link_prefix'")
				}

			case "link_suffix":
				// C++ line 3449-3460
				if value_node == nil {
					error_node(elem_node, "Expected a string value for 'link_suffix'")
					continue
				}
				if str, ok := operand.value.(string); ok {
					link_suffix := strings.trim_space(str)
					if !is_foreign_name_valid(link_suffix) {
						error_node(value_node, "Invalid link suffix: %s", link_suffix)
					}
					ctx.foreign_context.link_suffix = link_suffix
				} else {
					error_node(value_node, "Expected a string value for 'link_suffix'")
				}

			case "private":
				// C++ Reference: checker.cpp - @(private) or @(private="file"|"package")
				kind := Entity_Visibility_Kind.Private_To_Package
				if value_node == nil {
					// @(private) defaults to package-level privacy
					kind = .Private_To_Package
				} else if str, ok := operand.value.(string); ok {
					switch str {
					case "file":
						kind = .Private_To_File
					case "package":
						kind = .Private_To_Package
					case:
						error_node(value_node, "Invalid 'private' value '%s', expected 'file' or 'package'", str)
						continue
					}
				} else {
					error_node(value_node, "Expected a string value for 'private'")
					continue
				}
				ctx.foreign_context.visibility_kind = kind

			case "require_results":
				// C++ line 3479-3484
				if value_node != nil {
					error_node(elem_node, "Expected no value for 'require_results'")
				}
				ctx.foreign_context.require_results = true

			case:
			// Check if it's a user tag (any unrecognized attribute)
			// C++ line 3420-3424
			// User tags are allowed but not processed
			}
		}
	}
}

// string_to_calling_convention converts a string to a calling convention
// C++ Reference: /mnt/c/odin/src/checker.cpp (string_to_calling_convention)
string_to_calling_convention :: proc(str: string) -> Calling_Convention {
	switch str {
	case "odin":
		return .Odin
	case "contextless":
		return .Contextless
	case "cdecl", "c":
		return .C
	case "stdcall", "std":
		return .Std
	case "fastcall", "fast":
		return .Fast
	case "none":
		return .None
	case "naked":
		return .Naked
	case "win64":
		return .Win64
	case "sysv":
		return .SysV
	case "preserve/none":
		return .Preserve_None
	case "preserve/most":
		return .Preserve_Most
	case "preserve/all":
		return .Preserve_All
	case "system":
		// C++ parser.cpp:4055-4059 - target dependent, NOT sysv.
		if build_context.metrics.os == .Windows {
			return .Std
		}
		return .C
	case:
		// C++ returns ProcCC_Invalid here. Returning .None conflated an unrecognised
		// convention with the legitimate "none" convention.
		return .Invalid
	}
}

// check_using_stmt validates using statements for imports, enums, and struct variables
// C++ Reference: check_stmt.cpp lines 748-874 (check_using_stmt_entity)
//                check_stmt.cpp lines 2937-2974 (UsingStmt case)
check_using_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Using_Stmt)

	// Validate using statement has entities
	if len(stmt.list) == 0 {
		error_node(node, "Empty 'using' list")
		return {}
	}

	// Check vet flags for using statement warnings
	// C++ Reference: check_stmt.cpp lines 2942-2946
	if .Using_Stmt in check_vet_flags(ctx) {
		error_node(node, "'using' as a statement is not allowed when '-vet' or '-vet-using' is applied")
		error_line("\t'using' is considered bad practice to use as a statement outside of immediate refactoring\n")
	}

	// Process each using expression
	for expr in stmt.list {
		expr_node := unparen_expr(expr)
		expr_typed := cast(^ast.Expr)expr_node
		entity: ^Entity = nil
		is_selector := false

		// Check what kind of expression we're using
		#partial switch e in expr_node.derived {
		case ^ast.Ident:
			// using foo
			operand: Operand
			operand.mode = .Invalid
			entity = check_ident(ctx, &operand, expr_node, nil, nil, true)

		case ^ast.Selector_Expr:
			// using pkg.foo
			operand: Operand
			operand.mode = .Invalid
			entity = check_selector(ctx, &operand, expr_node, nil)
			is_selector = true

		case ^ast.Implicit:
			error_node(node, "'using' applied to an implicit value")
			continue

		case:
			error_node(node, "'using' can only be applied to an entity")
			continue
		}

		// Process the entity
		if !check_using_stmt_entity(ctx, stmt, expr_typed, is_selector, entity) {
			return viral_flags
		}
	}

	// Using statements don't produce viral flags
	return viral_flags
}

// check_using_stmt_entity processes a single entity in a using statement
// Returns true to continue processing, false to stop
// C++ Reference: check_stmt.cpp lines 748-874
check_using_stmt_entity :: proc(ctx: ^Checker_Context, us: ^ast.Using_Stmt, expr: ^ast.Expr, is_selector: bool, e: ^Entity) -> bool {
	// Validate entity exists
	if e == nil {
		is_blank := false
		if ident, ok := expr.derived.(^ast.Ident); ok {
			is_blank = is_blank_ident(ident.name)
		}
		if is_blank {
			error_node(expr, "'using' in a statement is not allowed with the blank identifier '_'")
		} else {
			error_node(expr, "'using' applied to an unknown entity")
		}
		return true
	}

	// Track entity usage
	add_entity_use(ctx, expr, e)

	// Process based on entity kind
	#partial switch e.kind {
	case .Type_Name:
		// Using enum type - import enum values
		// C++ Reference: check_stmt.cpp lines 763-784
		t := base_type(e.type)
		if t.kind == .Enum {
			#partial switch enum_type in t.variant {
			case Type_Enum:
				// Import all enum fields into current scope
				for field in enum_type.fields {
					if !is_entity_exported(field) {
						continue
					}

					// Insert field into current scope
					found := scope_insert(ctx.scope, field)
					if found != nil {
						expr_str := expr_to_string(expr)
						defer delete(expr_str)
						error_node(expr, "Namespace collision while 'using' enum '%s' of: %s", expr_str, found.token.text)
						return false
					}

					// Set using_parent relationship
					field.using_parent = e
				}
			}
		} else {
			error_node(expr, "'using' can be only applied to enum type entities")
		}

	case .Import_Name:
		// Using import - import all public entities from imported scope
		// C++ Reference: check_stmt.cpp lines 786-813
		#partial switch import_name in e.variant {
		case Entity_Import_Name:
			scope := import_name.scope
			if scope == nil {
				error_node(expr, "Import has no scope")
				return false
			}

			// Lock scope for thread-safe access to elements map
			// C++ Reference: check_stmt.cpp lines 788-789
			sync.rw_mutex_lock(&scope.mutex)
			defer sync.rw_mutex_unlock(&scope.mutex)

			// Import all exported entities
			for name, decl in scope.elements {
				if !is_entity_exported(decl, true) {
					continue
				}

				// Insert into current scope
				found := scope_insert_with_name(ctx.scope, name, decl)
				if found != nil {
					expr_str := expr_to_string(expr)
					defer delete(expr_str)
					error_node(expr, "Namespace collision while 'using' import name '%s' of: %s\n\tat %v\n\tat %v", expr_str, found.token.text, found.token.pos, decl.token.pos)
					return false
				}
			}
		}

	case .Variable:
		// Using struct variable - import struct fields
		// C++ Reference: check_stmt.cpp lines 815-845
		is_ptr := is_type_pointer(e.type)
		t := base_type(type_deref(e.type))

		if t.kind == .Struct {
			#partial switch struct_type in t.variant {
			case Type_Struct:
				// Wait for struct fields to be resolved (multi-threaded synchronization)
				// C++ Reference: check_stmt.cpp:818-822
				// Need to use pointer to variant for wait group
				st_ptr := &t.variant.(Type_Struct)
				sync.wait_group_wait(&st_ptr.fields_wait_signal)

				found_scope := struct_type.scope
				if found_scope == nil {
					error_node(expr, "Struct has no scope")
					return false
				}

				// Import all struct fields
				for _, field in found_scope.elements {
					if field.kind == .Variable {
						// Create using variable entity
						uvar := alloc_entity_using_variable(e, field.token, get_entity_type(field), expr)

						// Inherit flags from parent variable
						if !is_ptr {
							#partial switch ev in e.variant {
							case Entity_Variable:
								if .Value in e.flags {
									uvar.flags += {.Value}
								}
							}
						}
						if .Param in e.flags {
							uvar.flags += {.Param}
						}
						if .Soa_Ptr_Field in e.flags {
							uvar.flags += {.Soa_Ptr_Field}
						}

						// Insert into current scope
						prev := scope_insert(ctx.scope, uvar)
						if prev != nil {
							expr_str := expr_to_string(expr)
							defer delete(expr_str)
							error_node(expr, "Namespace collision while using '%s' of: '%s'", expr_str, prev.token.text)
							return false
						}
					}
				}
			}
		} else {
			error_node(expr, "'using' can only be applied to variables of type 'struct'")
			return false
		}

	case .Constant:
		error_node(expr, "'using' cannot be applied to a constant")

	case .Procedure, .Proc_Group:
		error_node(expr, "'using' cannot be applied to a procedure")

	case .Builtin:
		error_node(expr, "'using' cannot be applied to a builtin")

	case .Nil:
		error_node(expr, "'using' cannot be applied to 'nil'")

	case .Label:
		error_node(expr, "'using' cannot be applied to a label")

	case .Invalid:
		error_node(expr, "'using' cannot be applied to an invalid entity")

	case:
		error_node(expr, "'using' cannot be applied to this entity type")
	}

	return true
}

// check_range_stmt validates for..in range loops
// C++ Reference: check_stmt.cpp lines 1701-2054
check_range_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Range_Stmt)

	// Range loops allow break and continue
	new_flags := mod_flags + {.Break_Allowed, .Continue_Allowed}

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	check_label(ctx, stmt.label, node)

	// `for <init>; <vals> in <expr>` carries an init statement, which must be checked
	// inside the loop's scope so anything it declares is visible to the body.
	// C++ Reference: check_stmt.cpp:1754-1757.
	if stmt.init != nil {
		viral_flags |= check_stmt(ctx, stmt.init, mod_flags)
	}

	// Track value types and entities
	vals := make([dynamic]^Type, 0, 2, context.temp_allocator)
	entities := make([dynamic]^Entity, 0, 2, context.temp_allocator)
	is_map := false
	is_bit_set := false
	is_soa := false
	is_reverse := stmt.reverse

	expr := unparen_expr(stmt.expr)

	// Determine if we can take addresses (for &elem)
	is_possibly_addressable := true
	max_val_count := 2

	// Check if expression is a range (e.g., 0..<10)
	// C++ Reference: check_stmt.cpp lines 1725-1742
	skip_expr_range_stmt := false
	if is_ast_range(cast(^ast.Expr)expr) {
		// Range expression: for i in 0..<10
		// C++ uses ast_node macro to validate BinaryExpr; we check gracefully
		// We use 'expr' throughout (not the binary_expr value) - matches C++ behavior
		_, is_binary := expr.derived.(^ast.Binary_Expr)
		if !is_binary {
			error_node(expr, "Invalid range expression")
			skip_expr_range_stmt = true
		}

		if !skip_expr_range_stmt {
			x, y: Operand
			x.mode = .Invalid
			y.mode = .Invalid

			is_possibly_addressable = false

			// check_range validates the range and returns the operands
			// Use 'expr' here, not binary_expr - matches C++ line 1733
			ok := check_range(ctx, expr, true, &x, &y, nil, nil)
			if !ok {
				skip_expr_range_stmt = true
			} else {
				append(&vals, x.type)
				append(&vals, t_int)

				if is_reverse {
					error_node(node, "#reverse for is not supported with ranges, prefer an explicit for loop with init, condition, and post arguments")
				}
			}
		}
	} else if !skip_expr_range_stmt {
		// Non-range expression: check type or value
		// C++ Reference: check_stmt.cpp lines 1743-1959
		operand: Operand
		operand.mode = .Invalid
		check_expr_base(ctx, &operand, expr, nil)
		error_operand_no_value(&operand)

		if operand.mode == .Type {
			// Iterating over a type (must be enum)
			// C++ Reference: check_stmt.cpp lines 1748-1767
			if !is_type_enum(operand.type) {
				type_str := type_to_string(operand.type)
				error_node(operand.expr, "Cannot iterate over the type '%s'", type_str)
				skip_expr_range_stmt = true
			} else {
				is_possibly_addressable = false

				if is_reverse {
					error_node(node, "#reverse for is not supported for enum types")
				}

				append(&vals, operand.type)
				append(&vals, t_int)
				add_type_info_type(ctx, operand.type)

				// C++ Reference: check_stmt.cpp:1763-1765
				if ctx.info.build_context != nil && ctx.info.build_context.no_rtti {
					error_node(node, "Iteration over an enum type is not allowed when runtime type information (RTTI) has been disallowed")
				}
				skip_expr_range_stmt = true
			}
		} else if operand.mode != .Invalid && !skip_expr_range_stmt {
			// Iterating over a value
			// C++ Reference: check_stmt.cpp lines 1768-1937

			// Handle optional-ok promotion
			// C++ Reference: check_stmt.cpp lines 1769-1778
			if operand.mode == .Optional_Ok || operand.mode == .Optional_Ok_Ptr {
				unwrapped_expr := unparen_expr(operand.expr)
				if _, is_type_assert := unwrapped_expr.derived.(^ast.Type_Assertion); !is_type_assert {
					// Only for procedure calls
					end_type: ^Type = nil
					check_promote_optional_ok(ctx, &operand, nil, &end_type, false)
					if is_type_boolean(end_type) {
						check_promote_optional_ok(ctx, &operand, nil, &end_type, true)
					}
				}
			}

			is_ptr := is_type_pointer(operand.type)
			t := base_type(type_deref(operand.type))

			// Determine value types based on container type
			#partial switch t.kind {
			case .Basic:
				// String iteration
				// C++ Reference: check_stmt.cpp lines 1783-1802
				#partial switch tv in t.variant {
				case Type_Basic:
					if tv.kind == .String16 {
						is_possibly_addressable = false
						append(&vals, t_rune)
						append(&vals, t_int)
						if is_reverse {
							add_package_dependency(ctx, "runtime", "string16_decode_last_rune")
						} else {
							add_package_dependency(ctx, "runtime", "string16_decode_rune")
						}
					} else if tv.kind == .String || tv.kind == .Untyped_String {
						is_possibly_addressable = false
						append(&vals, t_rune)
						append(&vals, t_int)
						if is_reverse {
							add_package_dependency(ctx, "runtime", "string_decode_last_rune")
						} else {
							add_package_dependency(ctx, "runtime", "string_decode_rune")
						}
					}
				}

			case .Bit_Set:
				// Bit set iteration
				// C++ Reference: check_stmt.cpp lines 1805-1826
				#partial switch bs in t.variant {
				case Type_Bit_Set:
					append(&vals, bs.elem)
					max_val_count = 1
					is_bit_set = true
					is_possibly_addressable = false
					add_type_info_type(ctx, operand.type)

					// C++ Reference: check_stmt.cpp:1811-1813
					if ctx.info.build_context != nil && ctx.info.build_context.no_rtti && is_type_enum(bs.elem) {
						error_node(node, "Iteration over a bit_set of an enum is not allowed when runtime type information (RTTI) has been disallowed")
					}

					// Check for shadowing warning
					// C++ Reference: check_stmt.cpp lines 1814-1825
					if len(stmt.vals) == 1 && stmt.vals[0] != nil {
						if ident, is_ident := stmt.vals[0].derived.(^ast.Ident); is_ident {
							name := ident.name
							found := scope_lookup(ctx.scope, name)
							if found != nil && are_types_identical(get_entity_type(found), bs.elem) {
								expr_str := expr_to_string(expr)
								defer delete(expr_str)
								error_node(stmt.vals[0], "'%s' shadows a previous declaration which might be ambiguous with 'for (%s in %s)'", name, name, expr_str)
								error_line("\tSuggestion: Use a different identifier if iteration is wanted, or surround in parentheses if a normal for loop is wanted\n")
							}
						}
					}
				}

			case .Enumerated_Array:
				// Enumerated array iteration
				// C++ Reference: check_stmt.cpp lines 1828-1832
				#partial switch ea in t.variant {
				case Type_Enumerated_Array:
					is_possibly_addressable = operand.mode == .Variable || is_ptr
					append(&vals, ea.elem)
					append(&vals, ea.index)
				}

			case .Array:
				// Array iteration
				// C++ Reference: check_stmt.cpp lines 1834-1838
				#partial switch arr in t.variant {
				case Type_Array:
					is_possibly_addressable = operand.mode == .Variable || is_ptr
					append(&vals, arr.elem)
					append(&vals, t_int)
				}

			case .Dynamic_Array:
				// Dynamic array iteration
				// C++ Reference: check_stmt.cpp lines 1840-1844
				#partial switch da in t.variant {
				case Type_Dynamic_Array:
					is_possibly_addressable = true
					append(&vals, da.elem)
					append(&vals, t_int)
				}

			case .Slice:
				// Slice iteration
				// C++ Reference: check_stmt.cpp lines 1846-1850
				#partial switch sl in t.variant {
				case Type_Slice:
					is_possibly_addressable = true
					append(&vals, sl.elem)
					append(&vals, t_int)
				}

			case .Map:
				// Map iteration
				// C++ Reference: check_stmt.cpp lines 1852-1872
				#partial switch mp in t.variant {
				case Type_Map:
					is_possibly_addressable = true
					is_map = true
					append(&vals, mp.key)
					append(&vals, mp.value)

					if is_reverse {
						error_node(node, "#reverse for is not supported for map types, as maps are unordered")
					}

					// Check for shadowing warning
					// C++ Reference: check_stmt.cpp lines 1860-1871
					if len(stmt.vals) == 1 && stmt.vals[0] != nil {
						if ident, is_ident := stmt.vals[0].derived.(^ast.Ident); is_ident {
							name := ident.name
							found := scope_lookup(ctx.scope, name)
							if found != nil && are_types_identical(get_entity_type(found), mp.key) {
								expr_str := expr_to_string(expr)
								defer delete(expr_str)
								error_node(stmt.vals[0], "'%s' shadows a previous declaration which might be ambiguous with 'for (%s in %s)'", name, name, expr_str)
								error_line("\tSuggestion: Use a different identifier if iteration is wanted, or surround in parentheses if a normal for loop is wanted\n")
							}
						}
					}
				}

			case .Tuple:
				// Multi-valued iteration (e.g., from a procedure returning multiple values)
				// C++ Reference: check_stmt.cpp lines 1874-1922
				#partial switch tup in t.variant {
				case Type_Tuple:
					is_possibly_addressable = false

					count := len(tup.variables)
					if count < 1 {
						check_not_tuple(ctx, &operand)
						error_line("\tMultiple return valued parameters in a range statement are limited to a minimum of 1 usable values with a trailing boolean for the conditional, got %d\n", count)
						skip_expr_range_stmt = true
					} else {
						MAXIMUM_COUNT :: 100
						if count > MAXIMUM_COUNT {
							check_not_tuple(ctx, &operand)
							error_line("\tMultiple return valued parameters in a range statement are limited to a maximum of %d usable values with a trailing boolean for the conditional, got %d\n", MAXIMUM_COUNT, count)
							skip_expr_range_stmt = true
						} else {
							// Last value must be boolean (for loop condition)
							cond_type := get_entity_type(tup.variables[count - 1])
							if !is_type_boolean(cond_type) {
								type_str := type_to_string(cond_type)
								error_node(operand.expr, "The final type of %d-valued expression must be a boolean, got %s", count, type_str)
								skip_expr_range_stmt = true
							} else {
								max_val_count = count

								for entity in tup.variables {
									append(&vals, get_entity_type(entity))
								}

								// Validate variable count matches
								valid := true
								for i := len(stmt.vals) - 1; i >= 0 && valid; i -= 1 {
									if stmt.vals[i] != nil && count < i + 2 {
										type_str := type_to_string(t)
										error_node(operand.expr, "Expected a %d-valued expression on the rhs, got (%s)", i + 2, type_str)
										skip_expr_range_stmt = true
										valid = false
									}
								}

								if is_reverse {
									error_node(node, "#reverse for is not supported for multiple return valued parameters")
								}
							}
						}
					}
				}

			case .Struct:
				// SOA struct iteration
				// C++ Reference: check_stmt.cpp lines 1924-1936
				#partial switch st in t.variant {
				case Type_Struct:
					if st.soa_kind != .None {
						if st.soa_kind == .Fixed {
							is_possibly_addressable = operand.mode == .Variable || is_ptr
						} else {
							is_possibly_addressable = true
						}
						is_soa = true
						append(&vals, st.soa_elem)
						append(&vals, t_int)
					}
				}
			}
		}

		// Validate we can iterate over this type
		// C++ Reference: check_stmt.cpp lines 1939-1958
		if len(vals) == 0 || vals[0] == nil {
			expr_str := expr_to_string(operand.expr)
			type_str := type_to_string(operand.type)
			defer delete(expr_str)

			error_node(operand.expr, "Cannot iterate over '%s' of type '%s'", expr_str, type_str)

			// Provide helpful suggestion for map/bit_set
			if len(stmt.vals) == 1 {
				deref_t := type_deref(operand.type)
				if deref_t != nil && (is_type_map(deref_t) || is_type_bit_set(deref_t)) {
					val_str := expr_to_string(stmt.vals[0])
					defer delete(val_str)
					error_line("\tSuggestion: place parentheses around the expression\n")
					error_line("\t            for (%s in %s) {\n", val_str, expr_str)
				}
			}
		}
	}

	// Validate variable count
	// C++ Reference: check_stmt.cpp lines 1963-1965
	if len(stmt.vals) > max_val_count {
		plural := max_val_count == 1 ? "" : "s"
		error_node(stmt.vals[max_val_count], "Expected a maximum of %d identifier%s, got %d", max_val_count, plural, len(stmt.vals))
	}

	// Create loop variable entities
	// C++ Reference: check_stmt.cpp lines 1967-2049
	rhs := vals[:]
	lhs := make([]^ast.Expr, len(rhs), context.temp_allocator)
	for i in 0 ..< min(len(stmt.vals), len(lhs)) {
		lhs[i] = stmt.vals[i]
	}

	addressable_index := is_map ? 1 : 0

	for i in 0 ..< len(rhs) {
		if lhs[i] == nil {
			continue
		}

		name := lhs[i]
		type := rhs[i]
		entity: ^Entity = nil

		// Check for addressed variable (&elem)
		is_addressed := false
		if unary, is_unary := name.derived.(^ast.Unary_Expr); is_unary {
			if unary.op.kind == .And {
				is_addressed = true
				name = unary.expr
			}
		}

		// Create entity for loop variable
		if ident, is_ident := name.derived.(^ast.Ident); is_ident {
			token := tokenizer.Token {
				text = ident.name,
				pos  = name.pos,
				kind = .Ident,
			}
			str := token.text
			found: ^Entity = nil

			if str != "_" {
				found = scope_lookup_current(ctx.scope, str)
			}

			if found == nil {
				entity = alloc_entity_variable(ctx.scope, token, type, .Resolved, ctx.checker.allocator)
				entity.flags += {.For_Value, .Value}
				// C++ Reference: check_stmt.cpp:2043-2049
				// Add entity to scope before adding definition
				add_entity(ctx, ctx.scope, name, entity)
				add_entity_definition(&ctx.checker.info, name, entity)

				// Store parent type for later analysis
				#partial switch &v in entity.variant {
				case Entity_Variable:
					v.for_loop_parent_type = type_of_expr(expr, &ctx.checker.info)
				}

				// Handle addressing
				if is_addressed {
					if is_possibly_addressable && i == addressable_index {
						entity.flags -= {.Value}
					} else {
						idx_name := is_map ? "key" : (is_bit_set || i == 0) ? "element" : "index"
						error_token(token, "The %s variable '%s' cannot be made addressable", idx_name, str)
					}
				}

				// Handle SOA field pointers
				if is_soa && i == 0 {
					entity.flags += {.Soa_Ptr_Field}
				}
			} else {
				pos := found.token.pos
				error_token(token, "Redeclaration of '%s' in this scope\n\tat %s", str, token_pos_to_string(pos))
				entity = found
			}
		} else {
			error_node(name, "Expected an identifier for loop variable")
		}

		if entity == nil {
			token := tokenizer.Token {
				pos  = name.pos,
				kind = .Ident,
			}
			entity = alloc_entity_dummy_variable(ctx.scope, token, ctx.checker.allocator)
		}

		append(&entities, entity)

		if type == nil {
			entity.type = t_invalid
			entity.flags += {.Used}
		}
	}

	// Add entities to scope
	// C++ Reference: check_stmt.cpp lines 2043-2049
	for entity in entities {
		// Create decl_info for entity
		d := make_decl_info(ctx.scope, ctx.decl, ctx.checker.allocator)
		// Note: entity.identifier should be the AST node, not the token text
		add_entity_and_decl_info(ctx, entity.identifier, entity, d, false)
	}

	// Check body statement
	// C++ Reference: check_stmt.cpp line 2051
	viral_flags |= check_stmt(ctx, stmt.body, new_flags)

	return viral_flags
}

// is_ast_range checks if an expression is a range operator (.. ..< ..=)
// C++ Reference: parser.cpp is_ast_range function
is_ast_range :: proc(expr: ^ast.Expr) -> bool {
	if expr == nil {
		return false
	}

	binary_expr, is_binary := expr.derived.(^ast.Binary_Expr)
	if !is_binary {
		return false
	}

	// Check if operator is a range operator
	#partial switch binary_expr.op.kind {
	case .Ellipsis, .Range_Full, .Range_Half:
		return true
	}

	return false
}

// check_unroll_range_stmt validates #unroll for loops (compile-time loop unrolling)
// C++ Reference: check_stmt.cpp lines 895-1113
check_unroll_range_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, mod_flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}
	stmt := node.derived.(^ast.Inline_Range_Stmt)

	check_open_scope(ctx, node)
	defer check_close_scope(ctx)

	val0: ^Type = nil
	val1: ^Type = nil
	entities: [2]^Entity = {}
	entity_count := 0

	// Parse #unroll argument (optional explicit unroll count)
	// C++ Reference: check_stmt.cpp lines 905-936
	unroll_count: i64 = -1

	if len(stmt.args) > 0 {
		if len(stmt.args) > 1 {
			error_node(stmt.args[1], "#unroll only supports a single argument for the unroll per loop amount")
		}
		arg := stmt.args[0]

		// Check for named arguments (not supported)
		if field_value, is_field := arg.derived.(^ast.Field_Value); is_field {
			error_node(arg, "#unroll does not yet support named arguments")
			arg = field_value.value
		}

		// Evaluate argument - must be constant integer
		x: Operand
		x.mode = .Invalid
		check_expr(ctx, &x, arg)

		if x.mode != .Constant || !is_type_integer(x.type) {
			expr_str := expr_to_string(x.expr)
			defer delete(expr_str)
			error_node(x.expr, "Expected a constant integer for #unroll, got '%s'", expr_str)
		} else {
			value := exact_value_to_integer(x.value)
			v := exact_value_to_i64(value)
			if v < 1 {
				error_node(x.expr, "Expected a constant integer >= 1 for #unroll, got %d", v)
			} else {
				unroll_count = v
				if v > 1024 {
					error_node(x.expr, "Too large of a value for #unroll, got %d, expected <= 1024", v)
				}
			}
		}
	}

	// Evaluate range expression to determine unroll depth
	// C++ Reference: check_stmt.cpp lines 938-1034
	expr := unparen_expr(stmt.expr)
	inline_for_depth: Exact_Value = exact_value_i64(0)

	// Check if expression is a range (e.g., 0..<10)
	skip_expr := false
	if is_ast_range(cast(^ast.Expr)expr) {
		// Binary expression for range
		expr_typed := cast(^ast.Expr)expr
		binary_expr, is_binary := expr_typed.derived.(^ast.Binary_Expr)
		if !is_binary {
			error_node(expr, "Invalid range expression")
			skip_expr = true
		}

		if !skip_expr {
			x, y: Operand
			x.mode = .Invalid
			y.mode = .Invalid

			// Basic range checking inline
			check_expr(ctx, &x, binary_expr.left)
			if x.mode == .Invalid {
				skip_expr = true
			}

			if !skip_expr {
				check_expr(ctx, &y, binary_expr.right)
				if y.mode == .Invalid {
					skip_expr = true
				}
			}

			if !skip_expr {
				// Both sides must be constant for #unroll
				if x.mode != .Constant || y.mode != .Constant {
					error_node(expr, "An '#unroll for' range expression must be known at compile time")
					skip_expr = true
				} else if !is_type_integer(x.type) || !is_type_integer(y.type) {
					// Both must be integers
					error_node(expr, "Only integer types are allowed in '#unroll for' range expressions")
					skip_expr = true
				} else {
					// Calculate unroll depth based on range operator
					a := exact_value_to_integer(x.value)
					b := exact_value_to_integer(y.value)

					// Determine range operator: .. (inclusive), ..< (half-open), ..= (inclusive)
					op_kind := binary_expr.op.kind

					inline_for_depth = exact_value_sub(b, a)

					// For inclusive ranges (.. and ..=), add 1
					if op_kind != .Range_Half {
						inline_for_depth = exact_value_increment_one(inline_for_depth)
					}

					val0 = x.type
					val1 = t_int
				}
			}
		}
	} else if !skip_expr {
		// Non-range expression: check for constant type or value
		operand: Operand
		operand.mode = .Invalid
		check_expr_or_type(ctx, &operand, stmt.expr, nil)

		if operand.mode == .Type {
			// Iterating over a type (e.g., enum)
			if !is_type_enum(operand.type) {
				type_str := type_to_string(operand.type)
				error_node(operand.expr, "Cannot iterate over the type '%s'", type_str)
				skip_expr = true
			} else {
				val0 = operand.type
				val1 = t_int
				add_type_info_type(ctx, operand.type)

				bt := base_type(operand.type)
				#partial switch t in bt.variant {
				case Type_Enum:
					inline_for_depth = exact_value_i64(i64(len(t.fields)))
				}
				skip_expr = true
			}
		} else if operand.mode != .Invalid && !skip_expr {
			// Constant value iteration
			t := base_type(operand.type)

			#partial switch tv in t.variant {
			case Type_Basic:
				// String iteration (compile-time only)
				if (is_type_string(t) || is_type_string16(t)) && tv.kind != .Cstring {
					val0 = t_rune
					val1 = t_int

					// Extract string length from constant
					if str_val, is_str := operand.value.(string); is_str {
						inline_for_depth = exact_value_i64(i64(len(str_val)))
					}

					if unroll_count > 0 {
						error_node(node, "#unroll(%d) does not support strings", unroll_count)
					}
				} else if is_type_string(t) && tv.kind != .Cstring {
					val0 = t_rune
					val1 = t_int

					if str_val, is_str := operand.value.(string); is_str {
						inline_for_depth = exact_value_i64(i64(len(str_val)))
					}

					if unroll_count > 0 {
						error_node(node, "#unroll(%d) does not support strings", unroll_count)
					}
				}

			case Type_Array:
				val0 = tv.elem
				val1 = t_int
				inline_for_depth = unroll_count > 0 ? exact_value_i64(unroll_count) : exact_value_i64(tv.count)

			case Type_Enumerated_Array:
				val0 = tv.elem
				val1 = tv.index
				if unroll_count > 0 {
					error_node(node, "#unroll(%d) does not support enumerated arrays", unroll_count)
				}
				inline_for_depth = exact_value_i64(tv.count)

			case Type_Slice:
				if unroll_count > 0 {
					val0 = tv.elem
					val1 = t_int
					inline_for_depth = exact_value_i64(unroll_count)
				}

			case Type_Dynamic_Array:
				if unroll_count > 0 {
					val0 = tv.elem
					val1 = t_int
					inline_for_depth = exact_value_i64(unroll_count)
				}
			}
		}

		if val0 == nil {
			expr_str := expr_to_string(operand.expr)
			type_str := type_to_string(operand.type)
			defer delete(expr_str)
			error_node(operand.expr, "Cannot iterate over '%s' of type '%s' in an '#unroll for' statement", expr_str, type_str)
		} else if operand.mode != .Constant && unroll_count <= 0 {
			error_node(operand.expr, "An '#unroll for' expression must be known at compile time")
		}
	}

	// Create loop variable entities
	// C++ Reference: check_stmt.cpp lines 1037-1086
	lhs := [2]^ast.Expr{stmt.val0, stmt.val1}
	rhs := [2]^Type{val0, val1}

	for i in 0 ..< 2 {
		if lhs[i] == nil {
			continue
		}

		name := lhs[i]
		type := rhs[i]

		entity: ^Entity = nil
		if ident, is_ident := name.derived.(^ast.Ident); is_ident {
			token := tokenizer.Token {
				text = ident.name,
				pos  = name.pos,
				kind = .Ident,
			}
			str := token.text
			found: ^Entity = nil

			if str != "_" {
				found = scope_lookup_current(ctx.scope, str)
			}

			if found == nil {
				entity = alloc_entity_variable(ctx.scope, token, type, .Resolved, ctx.checker.allocator)
				// Mark as loop value (immutable)
				entity.flags += {.Value}
				add_entity_definition(&ctx.checker.info, name, entity)
			} else {
				pos := found.token.pos
				error_node(name, "Redeclaration of '%s' in this scope\n\tat %s", str, token_pos_to_string(pos))
				entity = found
			}
		} else {
			error_node(name, "Expected an identifier for loop variable")
		}

		if entity == nil {
			// Create dummy entity in global scope
			token := tokenizer.Token {
				pos  = name.pos,
				kind = .Ident,
			}
			entity = alloc_entity_dummy_variable(ctx.checker.info.global_scope, token, ctx.checker.allocator)
		}

		entities[entity_count] = entity
		entity_count += 1

		// Store entity in AST entity map (since AST nodes are immutable)
		set_entity_for_node(&ctx.checker.info, name, entity)

		if type == nil {
			entity.type = t_invalid
			entity.flags += {.Used}
		}
	}

	// Add entities to scope
	for i in 0 ..< entity_count {
		if entities[i] != nil && entities[i].token.text != "" {
			val_node: ^ast.Node = nil
			if i == 0 {
				val_node = cast(^ast.Node)stmt.val0
			} else if i == 1 {
				val_node = cast(^ast.Node)stmt.val1
			}
			if val_node != nil {
				add_entity(ctx, ctx.scope, val_node, entities[i])
			}
		}
	}

	// Calculate and validate inline_for_depth
	// C++ Reference: check_stmt.cpp lines 1088-1112
	// NOTE: Nested #unroll for loops multiply their depths
	// Save and restore inline depth
	prev_inline_for_depth := ctx.inline_for_depth
	defer ctx.inline_for_depth = prev_inline_for_depth

	v := exact_value_to_i64(inline_for_depth)
	if v <= 0 {
		// Empty loop - do nothing, just check body for errors
	} else {
		// Multiply depths for nested loops (gb_max ensures minimum of 1)
		ctx.inline_for_depth = max(ctx.inline_for_depth, 1) * v
	}

	// Check if accumulated depth exceeds limit
	if ctx.inline_for_depth >= MAX_INLINE_FOR_DEPTH && prev_inline_for_depth < MAX_INLINE_FOR_DEPTH {
		if prev_inline_for_depth > 0 {
			// Nested unroll
			error_node(node, "Nested '#unroll for' loop cannot be inlined as it exceeds the maximum '#unroll for' depth (%d levels >= %d maximum levels)", v, MAX_INLINE_FOR_DEPTH)
		} else {
			// Single unroll
			error_node(node, "'#unroll for' loop cannot be inlined as it exceeds the maximum '#unroll for' depth (%d levels >= %d maximum levels)", v, MAX_INLINE_FOR_DEPTH)
		}
		error_line("\tUse a normal 'for' loop instead by removing the 'inline' prefix")
		ctx.inline_for_depth = MAX_INLINE_FOR_DEPTH
	}

	// Check body statement
	// C++ Reference: check_stmt.cpp line 1111
	// The body is checked with the loop variables in scope
	viral_flags |= check_stmt(ctx, stmt.body, mod_flags)

	return viral_flags
}
