package checker

/*
AST Cloning Utilities

This module provides deep cloning of AST nodes for polymorphic procedure instantiation.
Each polymorphic procedure specialization needs its own AST tree copy to avoid sharing
cached entity bindings and type information.

C++ Reference: /mnt/c/odin/src/parser.cpp:155-496 (clone_ast, clone_ast_array)
*/

import "core:odin/ast"

// clone_ast_array_helper clones a slice of AST nodes with proper type conversion
// Helper for handling typed AST node slices ([]^Expr, []^Stmt, etc.)
clone_ast_array_helper :: proc {
	clone_ast_slice_helper,
	clone_ast_dynamic_array_helper,
}

clone_ast_slice_helper :: proc(nodes: $T/[]$E, file: ^ast.File = nil) -> T {
	if len(nodes) == 0 {
		return nil
	}

	result := make(T, len(nodes))
	for node, i in nodes {
		result[i] = transmute(E)clone_ast_node(transmute(^ast.Node)node, file)
	}
	return result
}

clone_ast_dynamic_array_helper :: proc(nodes: $T/[dynamic]$E, file: ^ast.File = nil) -> T {
	if len(nodes) == 0 {
		return nil
	}

	result := make(T, len(nodes))
	for node, i in nodes {
		result[i] = transmute(E)clone_ast_node(transmute(^ast.Node)node, file)
	}
	return result
}

// clone_ast_node performs deep cloning of an AST node
// This is critical for polymorphic procedure instantiation where each specialization
// needs its own AST tree to avoid polluting type checking caches.
//
// C++ Reference: parser.cpp:176-496
//
// IMPORTANT:
// - Returns a pointer to the new variant's embedded Node (same address due to `using`)
// - Clears cached entity bindings and type information
//
clone_ast_node :: proc(node: ^ast.Node, file: ^ast.File = nil) -> ^ast.Node {
	if node == nil {
		return nil
	}

	// C++ Reference: parser.cpp:176-496
	// In C++, alloc_ast_node allocates the full variant size, and returns it cast to Node*.
	// In Odin, variants have `using node` which embeds Node at the start.
	// We allocate the full variant, then return a pointer to its embedded Node.

	#partial switch variant in node.derived {
	case ^ast.Bad_Expr:
		n := new(ast.Bad_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Ident:
		// C++ line 195: n->Ident.entity = nullptr;
		n := new(ast.Ident)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Implicit:
		n := new(ast.Implicit)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Undef:
		n := new(ast.Undef)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Basic_Lit:
		n := new(ast.Basic_Lit)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Basic_Directive:
		n := new(ast.Basic_Directive)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		return n

	case ^ast.Poly_Type:
		// C++ lines 202-205
		n := new(ast.Poly_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Ident)clone_ast_node(n.type, file)
		n.specialization = cast(^ast.Expr)clone_ast_node(n.specialization, file)
		return n

	case ^ast.Ellipsis:
		// C++ lines 206-208
		n := new(ast.Ellipsis)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Proc_Group:
		// C++ lines 209-211
		n := new(ast.Proc_Group)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.args = clone_ast_array_helper(n.args)
		return n

	case ^ast.Proc_Lit:
		// C++ lines 212-216
		n := new(ast.Proc_Lit)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Proc_Type)clone_ast_node(n.type, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		n.where_clauses = clone_ast_array_helper(n.where_clauses)
		return n

	case ^ast.Comp_Lit:
		// C++ lines 217-220
		n := new(ast.Comp_Lit)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		n.elems = clone_ast_array_helper(n.elems)
		return n

	case ^ast.Tag_Expr:
		// C++ lines 223-225
		n := new(ast.Tag_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Unary_Expr:
		// C++ lines 226-228
		n := new(ast.Unary_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Binary_Expr:
		// C++ lines 229-232
		n := new(ast.Binary_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.left = cast(^ast.Expr)clone_ast_node(n.left, file)
		n.right = cast(^ast.Expr)clone_ast_node(n.right, file)
		return n

	case ^ast.Paren_Expr:
		// C++ lines 233-235
		n := new(ast.Paren_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Selector_Expr:
		// C++ lines 236-239
		n := new(ast.Selector_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.field = cast(^ast.Ident)clone_ast_node(n.field, file)
		return n

	case ^ast.Implicit_Selector_Expr:
		// C++ lines 240-242
		n := new(ast.Implicit_Selector_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.field = cast(^ast.Ident)clone_ast_node(n.field, file)
		return n

	case ^ast.Selector_Call_Expr:
		// C++ lines 243-246
		n := new(ast.Selector_Call_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.call = cast(^ast.Call_Expr)clone_ast_node(n.call, file)
		return n

	case ^ast.Index_Expr:
		// C++ lines 247-250
		n := new(ast.Index_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.index = cast(^ast.Expr)clone_ast_node(n.index, file)
		return n

	case ^ast.Deref_Expr:
		// C++ lines 256-258
		n := new(ast.Deref_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Slice_Expr:
		// C++ lines 259-263
		n := new(ast.Slice_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.low = cast(^ast.Expr)clone_ast_node(n.low, file)
		n.high = cast(^ast.Expr)clone_ast_node(n.high, file)
		return n

	case ^ast.Call_Expr:
		// C++ lines 264-267
		n := new(ast.Call_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.args = clone_ast_array_helper(n.args)
		return n

	case ^ast.Field_Value:
		// C++ lines 269-272
		n := new(ast.Field_Value)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.field = cast(^ast.Expr)clone_ast_node(n.field, file)
		n.value = cast(^ast.Expr)clone_ast_node(n.value, file)
		return n

	case ^ast.Ternary_If_Expr:
		// C++ lines 279-283
		n := new(ast.Ternary_If_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.x = cast(^ast.Expr)clone_ast_node(n.x, file)
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.y = cast(^ast.Expr)clone_ast_node(n.y, file)
		return n

	case ^ast.Ternary_When_Expr:
		// C++ lines 284-288
		n := new(ast.Ternary_When_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.x = cast(^ast.Expr)clone_ast_node(n.x, file)
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.y = cast(^ast.Expr)clone_ast_node(n.y, file)
		return n

	case ^ast.Or_Else_Expr:
		// C++ lines 289-292
		n := new(ast.Or_Else_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.x = cast(^ast.Expr)clone_ast_node(n.x, file)
		n.y = cast(^ast.Expr)clone_ast_node(n.y, file)
		return n

	case ^ast.Or_Return_Expr:
		// C++ lines 293-295
		n := new(ast.Or_Return_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Or_Branch_Expr:
		// C++ lines 296-299
		n := new(ast.Or_Branch_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Type_Assertion:
		// C++ lines 300-303
		n := new(ast.Type_Assertion)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		return n

	case ^ast.Type_Cast:
		// C++ lines 304-307
		n := new(ast.Type_Cast)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Auto_Cast:
		// C++ lines 308-310
		n := new(ast.Auto_Cast)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Inline_Asm_Expr:
		// C++ lines 312-317
		n := new(ast.Inline_Asm_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.param_types = clone_ast_array_helper(n.param_types)
		n.return_type = cast(^ast.Expr)clone_ast_node(n.return_type, file)
		n.asm_string = cast(^ast.Expr)clone_ast_node(n.asm_string, file)
		n.constraints_string = cast(^ast.Expr)clone_ast_node(n.constraints_string, file)
		return n

	case ^ast.Bad_Stmt:
		n := new(ast.Bad_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		return n

	case ^ast.Empty_Stmt:
		n := new(ast.Empty_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		return n

	case ^ast.Expr_Stmt:
		// C++ lines 321-323
		n := new(ast.Expr_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		return n

	case ^ast.Assign_Stmt:
		// C++ lines 324-327
		n := new(ast.Assign_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.lhs = clone_ast_array_helper(n.lhs)
		n.rhs = clone_ast_array_helper(n.rhs)
		return n

	case ^ast.Block_Stmt:
		// C++ lines 328-331
		n := new(ast.Block_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.stmts = clone_ast_array_helper(n.stmts)
		return n

	case ^ast.If_Stmt:
		// C++ lines 332-338
		n := new(ast.If_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.init = cast(^ast.Stmt)clone_ast_node(n.init, file)
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		n.else_stmt = cast(^ast.Stmt)clone_ast_node(n.else_stmt, file)
		return n

	case ^ast.When_Stmt:
		// C++ lines 339-343
		n := new(ast.When_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		n.else_stmt = cast(^ast.Stmt)clone_ast_node(n.else_stmt, file)
		return n

	case ^ast.Return_Stmt:
		// C++ lines 344-346
		n := new(ast.Return_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.results = clone_ast_array_helper(n.results)
		return n

	case ^ast.For_Stmt:
		// C++ lines 347-353
		n := new(ast.For_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.init = cast(^ast.Stmt)clone_ast_node(n.init, file)
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.post = cast(^ast.Stmt)clone_ast_node(n.post, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		return n

	case ^ast.Range_Stmt:
		// C++ lines 354-359
		n := new(ast.Range_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.vals = clone_ast_array_helper(n.vals)
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		return n

	case ^ast.Inline_Range_Stmt:
		// C++ lines 360-366
		n := new(ast.Inline_Range_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.val0 = cast(^ast.Expr)clone_ast_node(n.val0, file)
		n.val1 = cast(^ast.Expr)clone_ast_node(n.val1, file)
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		return n

	case ^ast.Case_Clause:
		// C++ lines 367-371
		n := new(ast.Case_Clause)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.list = clone_ast_array_helper(n.list)
		n.body = clone_ast_array_helper(n.body)
		// C++ line 370: n->CaseClause.implicit_entity = nullptr;
		return n

	case ^ast.Switch_Stmt:
		// C++ lines 372-377
		n := new(ast.Switch_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.init = cast(^ast.Stmt)clone_ast_node(n.init, file)
		n.cond = cast(^ast.Expr)clone_ast_node(n.cond, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		return n

	case ^ast.Type_Switch_Stmt:
		// C++ lines 378-382
		n := new(ast.Type_Switch_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		n.tag = cast(^ast.Stmt)clone_ast_node(n.tag, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		return n

	case ^ast.Tag_Stmt:
		// `#some_unknown_tag stmt`
		//
		// The parser emits Tag_Stmt as its FALLBACK for an unrecognised statement tag
		// (core/odin/parser/parser.odin:1576-1582), so this only appears in already-erroneous code -
		// but it reaches here whenever such a statement sits inside a polymorphic procedure body,
		// because instantiation clones the body. Without this case that panicked the whole run.
		//
		// C++ has no equivalent: its AST has no TagStmt kind at all, so there is nothing to mirror.
		// core/odin/ast/clone.odin (the shipped cloner) does handle it, and this matches that shape.
		n := new(ast.Tag_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.stmt = cast(^ast.Stmt)clone_ast_node(n.stmt, file)
		return n

	case ^ast.Defer_Stmt:
		// C++ lines 383-385
		n := new(ast.Defer_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.stmt = cast(^ast.Stmt)clone_ast_node(n.stmt, file)
		return n

	case ^ast.Branch_Stmt:
		// C++ lines 386-388
		n := new(ast.Branch_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.label = cast(^ast.Ident)clone_ast_node(n.label, file)
		return n

	case ^ast.Using_Stmt:
		// C++ lines 389-391
		n := new(ast.Using_Stmt)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.list = clone_ast_array_helper(n.list)
		return n

	case ^ast.Bad_Decl:
		n := new(ast.Bad_Decl)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		return n

	case ^ast.Foreign_Block_Decl:
		// C++ lines 395-399
		n := new(ast.Foreign_Block_Decl)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.foreign_library = cast(^ast.Expr)clone_ast_node(n.foreign_library, file)
		n.body = cast(^ast.Stmt)clone_ast_node(n.body, file)
		n.attributes = clone_ast_array_helper(n.attributes)
		return n

	case ^ast.Value_Decl:
		// C++ lines 403-408
		n := new(ast.Value_Decl)
		n^ = variant^
		n.node.stmt_base.tav = {}
		n.node.stmt_base.derived = n
		n.node.derived_stmt = n
		n.names = clone_ast_array_helper(n.names)
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		n.values = clone_ast_array_helper(n.values)
		n.attributes = clone_ast_array_helper(n.attributes)
		return n

	case ^ast.Attribute:
		// C++ lines 410-412
		n := new(ast.Attribute)
		n^ = variant^
		n.node.tav = {}
		n.node.derived = n
		n.elems = clone_ast_array_helper(n.elems)
		return n

	case ^ast.Field:
		// C++ lines 413-416
		n := new(ast.Field)
		n^ = variant^
		n.node.tav = {}
		n.node.derived = n
		n.names = clone_ast_array_helper(n.names)
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		n.default_value = cast(^ast.Expr)clone_ast_node(n.default_value, file)
		return n

	case ^ast.Field_List:
		// C++ lines 422-424
		n := new(ast.Field_List)
		n^ = variant^
		n.node.tav = {}
		n.node.derived = n
		n.list = clone_ast_array_helper(n.list)
		return n

	case ^ast.Typeid_Type:
		// C++ lines 426-428
		n := new(ast.Typeid_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.specialization = cast(^ast.Expr)clone_ast_node(n.specialization, file)
		return n

	case ^ast.Helper_Type:
		// C++ lines 429-431
		n := new(ast.Helper_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		return n

	case ^ast.Distinct_Type:
		// C++ lines 432-434
		n := new(ast.Distinct_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		return n

	case ^ast.Proc_Type:
		// C++ lines 435-438
		n := new(ast.Proc_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.params = cast(^ast.Field_List)clone_ast_node(n.params, file)
		n.results = cast(^ast.Field_List)clone_ast_node(n.results, file)
		return n

	case ^ast.Pointer_Type:
		// C++ lines 443-446
		n := new(ast.Pointer_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		n.tag = cast(^ast.Expr)clone_ast_node(n.tag, file)
		return n

	case ^ast.Multi_Pointer_Type:
		// C++ lines 447-449
		n := new(ast.Multi_Pointer_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		return n

	case ^ast.Array_Type:
		// C++ lines 450-454
		n := new(ast.Array_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.len = cast(^ast.Expr)clone_ast_node(n.len, file)
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		n.tag = cast(^ast.Expr)clone_ast_node(n.tag, file)
		return n

	case ^ast.Dynamic_Array_Type:
		// C++ lines 455-457
		n := new(ast.Dynamic_Array_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		return n

	case ^ast.Matrix_Index_Expr:
		// `m[i, j]`
		// C++ Reference: parser.cpp:251-255 - clones expr, row_index, column_index.
		//
		// Reachable as soon as polymorphic matrix procedures can be declared: instantiating
		// `proc(m: $T/matrix[$R, $C]$E)` clones the body, and any m[i, j] in it lands here.
		n := new(ast.Matrix_Index_Expr)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.expr = cast(^ast.Expr)clone_ast_node(n.expr, file)
		n.row_index = cast(^ast.Expr)clone_ast_node(n.row_index, file)
		n.column_index = cast(^ast.Expr)clone_ast_node(n.column_index, file)
		return n

	case ^ast.Relative_Type:
		// C++ Reference: parser.cpp:441-444 - clones tag and type.
		n := new(ast.Relative_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.tag = cast(^ast.Expr)clone_ast_node(n.tag, file)
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		return n

	case ^ast.Fixed_Capacity_Dynamic_Array_Type:
		// `[dynamic; N]T`
		// C++ Reference: parser.cpp:461-464 - clones elem, capacity AND tag.
		//
		// Without this case clone_ast_node hit its "unhandled AST variant" panic, so ANY attempt to
		// instantiate a polymorphic procedure whose signature mentions [dynamic; $N]$E aborted the
		// whole package check (exit 132). That is why such procedures appeared to have unchecked
		// bodies - checking never got that far.
		n := new(ast.Fixed_Capacity_Dynamic_Array_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		n.capacity = cast(^ast.Expr)clone_ast_node(n.capacity, file)
		n.tag = cast(^ast.Expr)clone_ast_node(n.tag, file)
		return n

	case ^ast.Struct_Type:
		// C++ lines 458-465
		n := new(ast.Struct_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.poly_params = cast(^ast.Field_List)clone_ast_node(n.poly_params, file)
		n.align = cast(^ast.Expr)clone_ast_node(n.align, file)
		n.where_clauses = clone_ast_array_helper(n.where_clauses)
		return n

	case ^ast.Union_Type:
		// C++ lines 466-470
		n := new(ast.Union_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.variants = clone_ast_array_helper(n.variants)
		n.poly_params = cast(^ast.Field_List)clone_ast_node(n.poly_params, file)
		n.where_clauses = clone_ast_array_helper(n.where_clauses)
		return n

	case ^ast.Enum_Type:
		// C++ lines 471-474
		n := new(ast.Enum_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.base_type = cast(^ast.Expr)clone_ast_node(n.base_type, file)
		n.fields = clone_ast_array_helper(n.fields)
		return n

	case ^ast.Bit_Set_Type:
		// C++ lines 475-478
		n := new(ast.Bit_Set_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		n.underlying = cast(^ast.Expr)clone_ast_node(n.underlying, file)
		return n

	case ^ast.Bit_Field_Type:
		// C++ lines 479-482
		n := new(ast.Bit_Field_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.backing_type = cast(^ast.Expr)clone_ast_node(n.backing_type, file)
		// Clone bit field fields
		if len(n.fields) > 0 {
			new_fields := make([]^ast.Bit_Field_Field, len(n.fields))
			for field, i in n.fields {
				if field != nil {
					new_fields[i] = cast(^ast.Bit_Field_Field)clone_ast_node(field, file)
				}
			}
			n.fields = new_fields
		}
		return n

	case ^ast.Map_Type:
		// C++ lines 483-487
		n := new(ast.Map_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.key = cast(^ast.Expr)clone_ast_node(n.key, file)
		n.value = cast(^ast.Expr)clone_ast_node(n.value, file)
		return n

	case ^ast.Matrix_Type:
		// C++ lines 488-492
		n := new(ast.Matrix_Type)
		n^ = variant^
		n.node.expr_base.tav = {}
		n.node.expr_base.derived = n
		n.node.derived_expr = n
		n.row_count = cast(^ast.Expr)clone_ast_node(n.row_count, file)
		n.column_count = cast(^ast.Expr)clone_ast_node(n.column_count, file)
		n.elem = cast(^ast.Expr)clone_ast_node(n.elem, file)
		return n

	case ^ast.Bit_Field_Field:
		// Bit_Field_Field has using node: Node
		n := new(ast.Bit_Field_Field)
		n^ = variant^
		n.node.tav = {}
		n.node.derived = n
		n.name = cast(^ast.Ident)clone_ast_node(n.name, file)
		n.type = cast(^ast.Expr)clone_ast_node(n.type, file)
		n.bit_size = cast(^ast.Expr)clone_ast_node(n.bit_size, file)
		return n

	case:
		// Unhandled variant - this is a panic in C++ too (line 191)
		// GB_PANIC("Unhandled Ast %.*s", LIT(ast_strings[n->kind]));
		panic("clone_ast_node: unhandled AST variant")
	}

	return nil // Unreachable, but needed for type checking
}
