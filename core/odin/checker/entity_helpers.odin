package checker

/*
Entity helper functions for manipulation and queries.

This module provides higher-level entity operations used throughout the checker,
including entity creation with flags, entity queries, and entity state management.

C++ Reference: /mnt/c/odin/src/checker.cpp (entity helper functions)
               /mnt/c/odin/src/entity.cpp (entity allocation and queries)
*/

import "core:unicode"
import "core:container/queue"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// ======================================================================================
// UTILITY HELPERS
// ======================================================================================

// is_string_an_identifier checks if a string is a valid Odin identifier
// C++ Reference: checker.cpp:4998-5020
// Valid identifiers:
// - Start with a letter, where '_' COUNTS as a letter (C++ rune_is_letter, unicode.cpp:17)
// - Remaining characters may be letters or digits
is_string_an_identifier :: proc(s: string) -> bool {
	if len(s) == 0 {
		return false
	}

	// C++ Reference: checker.cpp:5335-5356, which uses rune_is_letter / rune_is_digit.
	//
	// rune_is_letter (unicode.cpp:15-20) counts '_' AS A LETTER — and also accepts the
	// Unicode letter categories above U+0080. The port had inlined an ASCII a-zA-Z test
	// that dropped both. Underscore is legal anywhere in an Odin identifier, so this
	// rejected `_aes`, and since path_to_entity_name derives an import's name through this
	// predicate, `import "core:crypto/_aes"` was rejected outright and every `_aes.X` in
	// core/crypto/aes and core/crypto/_aes/* became an undeclared name.
	is_letter :: proc(r: rune) -> bool {
		if r < 0x80 {
			return r == '_' || (r >= 'a' && r <= 'z') || (r >= 'A' && r <= 'Z')
		}
		return unicode.is_letter(r)
	}
	is_digit :: proc(r: rune) -> bool {
		if r < 0x80 {
			return r >= '0' && r <= '9'
		}
		return unicode.is_digit(r)
	}

	first_rune, width := utf8.decode_rune_in_string(s)
	if !is_letter(first_rune) {
		return false
	}

	pos := width
	for pos < len(s) {
		r, w := utf8.decode_rune_in_string(s[pos:])
		if !is_letter(r) && !is_digit(r) {
			return false
		}
		pos += w
	}

	return true
}

// token_pos_cmp compares two token positions for sorting
// C++ Reference: tokenizer.cpp:209-220
// Returns: -1 if a < b, 0 if a == b, 1 if a > b
// Comparison order: offset, then line, then column, then file_id
token_pos_cmp :: proc(a, b: tokenizer.Pos) -> int {
	// C++ checks offset FIRST
	if a.offset < b.offset {return -1}
	if a.offset > b.offset {return 1}

	// Then line
	if a.line < b.line {return -1}
	if a.line > b.line {return 1}

	// Then column
	if a.column < b.column {return -1}
	if a.column > b.column {return 1}

	// Then file path
	// C++ does numeric comparison of file_id, Odin uses string comparison of file path
	if a.file < b.file {return -1}
	if a.file > b.file {return 1}

	return 0
}

// expr_to_string is defined in check_expr_helpers.odin

// ======================================================================================
// ENTITY CREATION HELPERS WITH FLAGS
// C++ Reference: /mnt/c/odin/src/entity.cpp:363-478
// ======================================================================================

// alloc_entity_using_variable: see entity.odin for the authoritative implementation
// C++ Reference: entity.cpp:363-374

// alloc_entity_const_param: see entity.odin for the authoritative implementation
// C++ Reference: entity.cpp:400-406

// alloc_entity_array_elem: see entity.odin for the authoritative implementation
// C++ Reference: entity.cpp:418-425

// alloc_entity_dummy_variable is defined in entity.odin

// ======================================================================================
// ENTITY QUERIES
// C++ Reference: /mnt/c/odin/src/entity.cpp:298-520
// ======================================================================================

// is_entity_exported: see entity.odin for the authoritative implementation
// C++ Reference: entity.cpp:310-329

// entity_has_deferred_procedure is defined in entity.odin

// strip_entity_wrapping unwraps procedure constants to get the underlying entity
// C++ Reference: entity.cpp:482-498
strip_entity_wrapping :: proc {
	strip_entity_wrapping_entity,
	strip_entity_wrapping_expr_ctx,
	strip_entity_wrapping_expr_info,
}

strip_entity_wrapping_entity :: proc(info: ^Checker_Info, e: ^Entity) -> ^Entity {
	if e == nil {
		return nil
	}

	if e.kind != .Constant {
		return e
	}

	// C++ Reference: entity.cpp:490-493
	// if (e->Constant.value.kind == ExactValue_Procedure) {
	//     return strip_entity_wrapping(e->Constant.value.value_procedure);
	// }
	// Note: C++ recursively calls the Ast* overload which extracts entity from expr
	if const_entity, ok := e.variant.(Entity_Constant); ok {
		if proc_value, is_proc := const_entity.value.(Exact_Value_Procedure); is_proc {
			// Extract entity from procedure expression and continue unwrapping
			// This matches C++ calling strip_entity_wrapping(Ast*) overload
			inner_entity := entity_from_expr_info(info, proc_value.expr)
			return strip_entity_wrapping_entity(info, inner_entity)
		}
	}

	return e
}

strip_entity_wrapping_expr_ctx :: proc(ctx: ^Checker_Context, expr: ^ast.Node) -> ^Entity {
	e := entity_from_expr(ctx, expr)
	return strip_entity_wrapping_entity(ctx.info, e)
}

strip_entity_wrapping_expr_info :: proc(info: ^Checker_Info, expr: ^ast.Node) -> ^Entity {
	e := entity_from_expr(info, expr)
	return strip_entity_wrapping_entity(info, e)
}

// entity_from_expr extracts the entity from an AST expression
// C++ Reference: check_expr.cpp:266-278
entity_from_expr :: proc {
	entity_from_expr_ctx,
	entity_from_expr_info,
}

entity_from_expr_ctx :: proc(ctx: ^Checker_Context, expr: ^ast.Node) -> ^Entity {
	e := unparen_expr(expr)
	if e == nil {
		return nil
	}

	#partial switch node in e.derived {
	case ^ast.Ident:
		// C++ line 268: return expr->Ident.entity
		return get_ast_entity(ctx.info, e)

	case ^ast.Selector_Expr:
		return entity_from_expr(ctx, node.field)
	}

	return nil
}

entity_from_expr_info :: proc(info: ^Checker_Info, expr: ^ast.Node) -> ^Entity {
	e := unparen_expr(expr)
	if e == nil {
		return nil
	}

	#partial switch node in e.derived {
	case ^ast.Ident:
		// C++ line 268: return expr->Ident.entity
		return get_ast_entity(info, e)

	case ^ast.Selector_Expr:
		return entity_from_expr(info, node.field)
	}

	return nil
}

// is_entity_local_variable: see entity.odin for the authoritative implementation
// C++ Reference: entity.cpp:501-520

// parent_proc_decl_of_entity gets the parent procedure decl info
// Helper to extract parent_proc_decl from entity variant
parent_proc_decl_of_entity :: proc(e: ^Entity) -> ^Decl_Info {
	if e == nil {
		return nil
	}

	// parent_proc_decl is now in Entity base struct
	return e.parent_proc_decl
}

// ======================================================================================
// AST ENTITY MAPPING
// C++ Reference: /mnt/c/odin/src/checker.cpp:1829, 2080
//                /mnt/c/odin/src/check_expr.cpp:268
// ======================================================================================

// set_ast_entity stores entity for an AST node
// Replaces C++ direct mutation: node->Ident.entity = e
// C++ Reference: checker.cpp:2022 - identifier->Ident.entity = entity
//                checker.cpp:2275 - clause->CaseClause.implicit_entity = e
set_ast_entity :: proc(info: ^Checker_Info, node: ^ast.Node, entity: ^Entity) {
	if node == nil || entity == nil {
		return
	}

	// Now that AST is mutable, directly set the entity field
	// NOTE: AST uses ^ast.Entity but we use ^checker.Entity, so we cast via rawptr
	#partial switch n in node.derived {
	case ^ast.Ident:
		n.entity = cast(^ast.Entity)cast(rawptr)entity
	case ^ast.Case_Clause:
		// For case clauses, store the implicit entity
		n.implicit_entity = cast(^ast.Entity)cast(rawptr)entity
	}
}

// get_ast_entity retrieves entity for an AST node
// Replaces C++ direct access: node->Ident.entity
// C++ Reference: check_expr.cpp:279 - return expr->Ident.entity
get_ast_entity :: proc(info: ^Checker_Info, node: ^ast.Node) -> ^Entity {
	if node == nil {
		return nil
	}

	// Now that AST is mutable, directly access the entity field
	// NOTE: AST uses ^ast.Entity but we use ^checker.Entity, so we cast via rawptr
	#partial switch n in node.derived {
	case ^ast.Ident:
		return cast(^Entity)cast(rawptr)n.entity
	case ^ast.Case_Clause:
		// For case clauses, return the implicit entity
		return cast(^Entity)cast(rawptr)n.implicit_entity
	}

	return nil
}

// ======================================================================================
// ENTITY MAP TRACKING
// C++ Reference: C++ uses direct AST mutation, we use external map
// ======================================================================================

// set_entity_for_node stores the entity associated with an AST node
// C++ Reference: identifier->Ident.entity = entity
set_entity_for_node :: proc(info: ^Checker_Info, node: ^ast.Node, entity: ^Entity) {
	// This is now just a wrapper around set_ast_entity
	set_ast_entity(info, node, entity)
}

// get_entity_for_node retrieves the entity associated with an AST node
// C++ Reference: return expr->Ident.entity
get_entity_for_node :: proc(info: ^Checker_Info, node: ^ast.Node) -> ^Entity {
	// This is now just a wrapper around get_ast_entity
	return get_ast_entity(info, node)
}

// ======================================================================================
// ENTITY ADDITION AND REGISTRATION
// C++ Reference: /mnt/c/odin/src/checker.cpp:1819-2075
// ======================================================================================

// add_entity_definition registers an entity definition with the checker
// C++ Reference: checker.cpp:1819-1832
add_entity_definition :: proc(info: ^Checker_Info, identifier: ^ast.Node, entity: ^Entity) {
	assert(identifier != nil)

	if identifier == nil {
		return
	}

	#partial switch ident in identifier.derived {
	case ^ast.Ident:
		// C++ Reference: checker.cpp:1824-1826
		// Check if identifier has already been handled
		if get_ast_entity(info, identifier) != nil {
			// NOTE(bill): Identifier has already been handled
			return
		}

		assert(entity != nil)

		// C++ line 1829: identifier->Ident.entity = entity
		set_ast_entity(info, identifier, entity)

		// Set entity.identifier
		// C++ line 1830: entity->identifier = identifier
		entity.identifier = identifier

		// Queue for definition processing
		// C++ line 1831: queue.mpsc_enqueue(&i->definition_queue, entity);
		queue.mpsc_enqueue(&info.definition_queue, entity)

	case:
		return
	}
}

// redeclaration_error reports a redeclaration error
// C++ Reference: checker.cpp:1834-1875
redeclaration_error :: proc(name: string, prev: ^Entity, found: ^Entity) -> bool {
	pos := found.token.pos

	// C++ line 1836: Entity *up = found->using_parent;
	up := found.using_parent
	if up != nil {
		// Error from using declaration
		// C++ line 1838-1840
		if pos == up.token.pos {
			// NOTE(bill): Error should have been handled already
			return false
		}

		// C++ line 1842-1854
		if .Result in found.flags {
			error(prev.token, "Direct shadowing of the named return value '%s' in this scope through 'using'\n\tat %s", name, token_pos_to_string(up.token.pos))
		} else {
			error(prev.token, "Redeclaration of '%s' in this scope through 'using'\n\tat %s", name, token_pos_to_string(up.token.pos))
		}
	} else {
		// Direct redeclaration (not through using)
		// C++ line 1856-1873
		if pos == prev.token.pos {
			// NOTE(bill): Error should have been handled already
			return false
		}

		if .Result in found.flags {
			error(prev.token, "Direct shadowing of the named return value '%s' in this scope\n\tat %s", name, token_pos_to_string(pos))
		} else {
			error(prev.token, "Redeclaration of '%s' in this scope\n\tat %s", name, token_pos_to_string(pos))
		}
	}

	return false
}

// add_entity_flags_from_file adds lazy flag based on file flags
// C++ Reference: checker.cpp:1877-1888
add_entity_flags_from_file :: proc(ctx: ^Checker_Context, e: ^Entity, scope: ^Scope) {
	// C++ line 1878: Check preconditions
	// if (c->file != nullptr && (c->file->flags & AstFile_IsLazy) != 0 && scope->flags & ScopeFlag_File)

	if ctx.file == nil {
		return
	}

	// Check file lazy flag using build_infrastructure.odin helper
	if !is_file_lazy(ctx.info, ctx.file) {
		return
	}

	// C++ line 1878: Check scope is file-level
	if .File not_in scope.flags {
		return
	}

	// C++ line 1879-1881: Check if main proc in init package
	// AstPackage *pkg = c->file->pkg;
	// if (pkg->kind == Package_Init && e->kind == Entity_Procedure && e->token.string == "main")
	if ctx.pkg != nil && is_package_init(ctx.info, ctx.pkg) {
		if e.kind == .Procedure && e.token.text == "main" {
			return // main in init package cannot be lazy
		}
	}

	// C++ line 1882-1884: Test, init, fini procedures cannot be lazy
	// } else if (e->flags & (EntityFlag_Test|EntityFlag_Init|EntityFlag_Fini)) {
	if .Test in e.flags || .Init in e.flags || .Fini in e.flags {
		return
	}

	// C++ line 1885: Mark as lazy
	// e->flags |= EntityFlag_Lazy;
	e.flags += {.Lazy}
}


// add_entity_with_name adds an entity to a scope with a specific name
// C++ Reference: checker.cpp:1890-1908
add_entity_with_name :: proc {
	add_entity_with_name_ctx,
	add_entity_with_name_info,
}

add_entity_with_name_ctx :: proc(ctx: ^Checker_Context, scope: ^Scope, identifier: ^ast.Node, entity: ^Entity, name: string) -> bool {
	if scope == nil {
		return false
	}

	// NOTE: C++'s add_entity_with_name (checker.cpp:2083) does NOT set
	// parent_proc_decl. It is set only at the explicit sites that mirror
	// check_stmt.cpp:752/2182 and check_decl.cpp:116/351/2031 — i.e. for
	// entities *declared by a statement or declaration* inside a body.
	// Setting it here caught procedure parameters and named results too,
	// so every nested procedure's own results were reported as captures of
	// its parent's variables.

	// Try to insert into scope (if not blank identifier)
	if !is_blank_ident(name) {
		// C++ Reference: Entity *ie = scope_insert(scope, entity);
		// if (ie != nullptr) { return redeclaration_error(name, entity, ie); }
		if existing := scope_insert(scope, entity); existing != nil {
			return redeclaration_error(name, entity, existing)
		}
	}

	if identifier != nil {
		// Set entity.file from ctx.file
		// C++ Reference: checker.cpp (implicit in add_entity flow)
		if entity.file == nil {
			entity.file = ctx.file
		}

		add_entity_definition(ctx.info, identifier, entity)
	}

	return true
}

add_entity_with_name_info :: proc(info: ^Checker_Info, scope: ^Scope, identifier: ^ast.Node, entity: ^Entity, name: string) -> bool {
	if scope == nil {
		return false
	}

	// Try to insert into scope (if not blank identifier)
	if !is_blank_ident(name) {
		sync.rw_mutex_lock(&scope.mutex)
		defer sync.rw_mutex_unlock(&scope.mutex)

		if existing, found := scope.elements[name]; found {
			return redeclaration_error(name, entity, existing)
		}

		scope.elements[name] = entity
	}

	if identifier != nil {
		// C++ asserts: GB_ASSERT(entity->file != nullptr);
		add_entity_definition(info, identifier, entity)
	}

	return true
}

// add_entity adds an entity to a scope using its token name
// C++ Reference: checker.cpp:1930-1932
add_entity :: proc(ctx: ^Checker_Context, scope: ^Scope, identifier: ^ast.Node, entity: ^Entity) -> bool {
	return add_entity_with_name_ctx(ctx, scope, identifier, entity, entity.token.text)
}

// NOTE: add_entity_use is defined in check_expr.odin
// It was moved there during earlier porting work and includes full implementation
// C++ Reference: checker.cpp:1934-1961

// could_entity_be_lazy checks if an entity can be lazily type checked
// C++ Reference: checker.cpp:1964-2011
could_entity_be_lazy :: proc(e: ^Entity, d: ^Decl_Info) -> bool {
	if .Lazy not_in e.flags {
		return false
	}

	// Special entities can't be lazy
	if .Test in e.flags || .Init in e.flags || .Fini in e.flags {
		return false
	}

	// Exported variables/procedures can't be lazy
	if e.kind == .Variable {
		if var, ok := e.variant.(Entity_Variable); ok {
			if var.is_export {
				return false
			}
		}
	}

	if e.kind == .Procedure {
		#partial switch v in e.variant {
		case Entity_Procedure:
			if v.is_foreign || v.is_export {
				return false
			}
		}
	}

	// Check attributes for test/export/init/linkage markers
	// C++ Reference: checker.cpp:1982-2013
	for attr in d.attributes {
		// C++ line 1983: if (attr->kind != Ast_Attribute) continue;
		#partial switch a in attr.derived {
		case ^ast.Attribute:
			// C++ line 1984: for (Ast *elem : attr->Attribute.elems)
			for elem in a.elems {
				name := ""

				// Extract name from element
				// C++ lines 1987-1999
				#partial switch e in elem.derived {
				case ^ast.Ident:
					// C++ line 1988-1990: case Ast_Ident: name = i->token.string;
					name = e.name

				case ^ast.Implicit:
					// C++ line 1991-1993: case Ast_Implicit: name = i->string;
					// In Odin AST, Implicit has tok field, get text from token
					name = e.tok.text

				case ^ast.Field_Value:
					// C++ line 1994-1998: case Ast_FieldValue: if (fv->field->kind == Ast_Ident)
					if field_ident, ok := e.field.derived.(^ast.Ident); ok {
						name = field_ident.name
					}
				}

				// C++ lines 2001-2011: Check for disallowed attributes
				if len(name) != 0 {
					if name == "test" {
						return false
					} else if name == "export" {
						return false
					} else if name == "init" {
						return false
					} else if name == "linkage" {
						return false
					}
				}
			}
		}
	}

	return true
}

// add_entity_and_decl_info combines entity and declaration registration
// C++ Reference: checker.cpp:2013-2075
add_entity_and_decl_info :: proc(ctx: ^Checker_Context, identifier: ^ast.Node, e: ^Entity, d: ^Decl_Info, is_exported: bool) {
	if identifier == nil {
		error(e.token, "Invalid variable declaration")
		return
	}

	#partial switch ident in identifier.derived {
	case ^ast.Ident:
		// C++ Reference: checker.cpp:2219 - GB_ASSERT(identifier->Ident.token.string == e->token.string)
		assert(ident.name == e.token.text)

	case:
		ident_str := expr_to_string(identifier)
		defer delete(ident_str)
		error(identifier, "A variable declaration must be an identifier, got '%s'", ident_str)
		return
	}

	assert(e != nil && d != nil)

	// Check if entity can remain lazy
	if !could_entity_be_lazy(e, d) {
		e.flags -= {.Lazy}
	}

	// Add to scope
	if e.scope != nil {
		scope := e.scope

		// Check if should be added to package scope (exported entities)
		if .File in scope.flags && is_entity_kind_exported(e.kind) && is_exported {
			// C++ Reference: checker.cpp:2041-2049
			// AstPackage *pkg = scope->file->pkg;
			// GB_ASSERT(pkg->scope == scope->parent);
			// GB_ASSERT(c->pkg == pkg);
			pkg := scope.file.pkg
			assert(ctx.pkg == pkg, "Package mismatch in exported entity handling")

			// C++ Reference: checker.cpp:2229-2245
			//
			// NOTE: an exported file-scope entity is ONLY enqueued - it is
			// deliberately NOT added to the file scope. C++'s
			// `add_entity(c, scope, identifier, e)` sits in the ELSE branch, and
			// the `add_entity(c, pkg->scope, ...)` inside this branch is
			// commented out there in favour of the queue.
			//
			// Adding it to the file scope as well made a package-level
			// declaration collide with a same-file import of the same name -
			// `import "core:compress"` beside `compress :: proc{...}` in
			// core/compress/shoco/shoco.odin - which the real compiler accepts.
			if pkg != nil {
				enqueue_exported_entity(ctx.info, pkg, identifier, e)
			}
		} else {
			add_entity(ctx, scope, identifier, e)
		}
	}

	// Register definition and link decl info
	add_entity_definition(ctx.info, identifier, e)

	// Set e.decl_info and e.pkg
	// C++ Reference: checker.cpp:2060-2061
	e.decl_info = d
	e.pkg = ctx.pkg

	// Set d.entity
	// C++ line 2062: d->entity.store(e);
	// C++ uses atomic store, we use direct assignment in single-threaded context
	d.entity = e

	// Queue for processing if not lazy
	// C++ line 2066: queue.mpsc_enqueue(&info->entity_queue, e);
	is_lazy := .Lazy in e.flags
	// Get queue count BEFORE enqueuing (used for order_in_src below)
	// Use thread-safe accessor to avoid data race
	queue_count := queue.mpsc_count(&ctx.info.entity_queue)
	if !is_lazy {
		queue.mpsc_enqueue(&ctx.info.entity_queue, e)
	}

	// Set order_in_src for deterministic ordering
	// C++ Reference: checker.cpp:2074-2079
	if len(e.token.pos.file) != 0 {
		// C++ line 2075: e->order_in_src = cast(u64)(e->token.pos.file_id)<<32 | u32(e->token.pos.offset);
		// Odin adaptation: Use hash of file path as file_id since Odin uses string paths
		// Hash the file path to get a consistent numeric identifier
		file_hash := u64(0)
		for b in transmute([]byte)e.token.pos.file {
			file_hash = file_hash * 31 + u64(b)
		}
		// Combine file hash (high 32 bits) with offset (low 32 bits)
		e.order_in_src = (file_hash << 32) | u64(e.token.pos.offset)
	} else {
		// C++ line 2076-2078: GB_ASSERT(!is_lazy); e->order_in_src = cast(u64)(1+queue_count);
		assert(!is_lazy, "Lazy entity without file position")
		e.order_in_src = u64(1 + queue_count)
	}
}

// add_implicit_entity stores an implicit entity on a case clause
// C++ Reference: checker.cpp:2078-2083
add_implicit_entity :: proc(ctx: ^Checker_Context, clause: ^ast.Node, e: ^Entity) {
	assert(clause != nil && e != nil)

	#partial switch c in clause.derived {
	case ^ast.Case_Clause:
		// C++ line 2080: clause->CaseClause.implicit_entity = e;
		set_ast_entity(ctx.info, clause, e)

	case:
		panic("add_implicit_entity: not a case clause")
	}
}

// ======================================================================================
// DEPENDENCY TRACKING
// ======================================================================================

// add_declaration_dependency tracks entity dependencies
// C++ Reference: checker.cpp:952-963
add_declaration_dependency :: proc(ctx: ^Checker_Context, entity: ^Entity) {
	if entity == nil {
		return
	}

	// Skip disabled entities (C++ line 956-959)
	if .Disabled in entity.flags {
		return
	}

	// Add dependency to current declaration (C++ line 960-962)
	if ctx.decl != nil && ctx.decl != entity.decl_info {
		add_dependency(ctx.info, ctx.decl, entity)
	}
}

// add_dependency adds an entity to a declaration's dependency set
// C++ Reference: checker.cpp:862-870
add_dependency :: proc(info: ^Checker_Info, decl: ^Decl_Info, entity: ^Entity) {
	if decl == nil || entity == nil {
		return
	}

	// C++ line 863: Conditional locking for performance optimization
	// During single-threaded phases, skip mutex to avoid overhead
	if in_single_threaded_checker_stage() {
		// Single-threaded mode: no lock needed
		decl.deps[entity] = {}
	} else {
		// Multi-threaded mode: thread-safe access
		sync.rw_mutex_lock(&decl.deps_mutex)
		defer sync.rw_mutex_unlock(&decl.deps_mutex)
		decl.deps[entity] = {}
	}
}

// add_package_dependency adds a dependency on a runtime package procedure
// Used for string decoding functions, RTTI support, etc.
// C++ Reference: checker.cpp:926-937
add_package_dependency :: proc(ctx: ^Checker_Context, package_name: string, name: string, required := false) {
	// Validate context
	if ctx == nil || ctx.info == nil {
		return
	}

	// C++ line 928: AstPackage *p = get_core_package(&c->checker->info, make_string_c(package_name));
	pkg := get_core_package(ctx.info, package_name)
	if pkg == nil {
		return
	}

	// C++ line 929: Entity *e = scope_lookup(p->scope, n);
	pkg_scope := get_package_scope(ctx.info, pkg)
	if pkg_scope == nil {
		return
	}

	entity := scope_lookup(pkg_scope, name)

	// C++ line 930: GB_ASSERT_MSG(e != nullptr, "%s", name);
	if entity == nil {
		return
	}

	// C++ line 931: GB_ASSERT(c->decl != nullptr);
	if ctx.decl == nil {
		return
	}

	// C++ line 932: e->flags |= EntityFlag_Used;
	entity.flags += {.Used}

	// C++ line 933-935: if (required) { e->flags |= EntityFlag_Require; }
	if required {
		entity.flags += {.Require}
	}

	// C++ line 936: add_dependency(c->info, c->decl, e);
	add_dependency(ctx.info, ctx.decl, entity)
}

// add_map_get_dependencies adds runtime dependencies for map read operations
// C++ Reference: check_expr.cpp:315-323
add_map_get_dependencies :: proc(ctx: ^Checker_Context, t: ^Type) {
	if ctx.decl == nil {
		return
	}
	add_package_dependency(ctx, "runtime", "__dynamic_map_get")
}

// add_map_set_dependencies adds runtime dependencies for map write operations
// C++ Reference: check_expr.cpp:324-339
add_map_set_dependencies :: proc(ctx: ^Checker_Context, t: ^Type) {
	if ctx.decl == nil {
		return
	}
	add_package_dependency(ctx, "runtime", "__dynamic_map_set")
	add_package_dependency(ctx, "runtime", "__dynamic_map_reserve")
}

// add_map_key_type_dependencies adds the runtime hasher dependencies a map key type requires
// C++ Reference: check_type.cpp:2988-3040
//
// NOTE: the previous implementation invented procedure names that do not exist in base:runtime -
// __default_hash_string / __default_eq_string / __default_hash_ptr / __default_hash_int / ... and a
// parallel __default_eq_* family that base:runtime has no equivalent of at all. Because
// add_package_dependency silently returns when scope_lookup misses (C++ asserts there instead), every
// one of those calls was a no-op, so this function registered nothing. The real names are
// default_hasher, default_hasher_string, default_hasher_cstring, default_hasher_f64,
// default_hasher_complex128 and default_hasher_quaternion256.
add_map_key_type_dependencies :: proc(ctx: ^Checker_Context, key_type: ^Type) {
	key := core_type(key_type)
	if key == nil {
		return
	}

	if is_type_cstring(key) {
		add_package_dependency(ctx, "runtime", "default_hasher_cstring")
	} else if is_type_string(key) {
		add_package_dependency(ctx, "runtime", "default_hasher_string")
	} else if !is_type_polymorphic(key) {
		if !is_type_comparable(key) {
			return
		}

		if is_type_simple_compare(key) {
			add_package_dependency(ctx, "runtime", "default_hasher")
			return
		}

		if basic, is_basic := key.variant.(Type_Basic); is_basic {
			if .Quaternion in basic.flags {
				add_package_dependency(ctx, "runtime", "default_hasher_f64")
				add_package_dependency(ctx, "runtime", "default_hasher_quaternion256")
				return
			} else if .Complex in basic.flags {
				add_package_dependency(ctx, "runtime", "default_hasher_f64")
				add_package_dependency(ctx, "runtime", "default_hasher_complex128")
				return
			} else if .Float in basic.flags {
				add_package_dependency(ctx, "runtime", "default_hasher_f64")
				return
			}
		}

		#partial switch v in key.variant {
		case Type_Struct:
			add_package_dependency(ctx, "runtime", "default_hasher")
			for field in v.fields {
				if field != nil {
					add_map_key_type_dependencies(ctx, entity_type(field))
				}
			}
		case Type_Union:
			add_package_dependency(ctx, "runtime", "default_hasher")
			for variant in v.variants {
				add_map_key_type_dependencies(ctx, variant)
			}
		case Type_Enumerated_Array:
			add_package_dependency(ctx, "runtime", "default_hasher")
			add_map_key_type_dependencies(ctx, v.elem)
		case Type_Array:
			add_package_dependency(ctx, "runtime", "default_hasher")
			add_map_key_type_dependencies(ctx, v.elem)
		}
	}
}

// ======================================================================================
// HELPER UTILITIES
// ======================================================================================

// NOTE: is_blank_ident is defined in check_expr.odin as an overloaded proc set
// It supports string, token, and AST node arguments
// C++ Reference: parser.cpp:1695

// path_to_entity_name extracts an entity name from a path
// If name is non-empty, returns it; otherwise extracts filename from fullpath
// C++ Reference: checker.cpp:5022-5060
path_to_entity_name :: proc(name: string, fullpath: string, strip_extension := true) -> string {
	if len(name) != 0 {
		return name
	}

	// NOTE(bill): use file name (without extension) as the identifier
	// If it is a valid identifier
	filename := fullpath

	// Strip leading/trailing quotes if present
	if len(filename) >= 2 && filename[0] == '"' && filename[len(filename) - 1] == '"' {
		filename = filename[1:len(filename) - 1]
	}

	// Find the start of the actual name (after last separator)
	// Separators are: / \ : (for collection paths like "core:fmt")
	start := 0
	for i := len(filename) - 1; i >= 0; i -= 1 {
		c := filename[i]
		if c == '/' || c == '\\' || c == ':' {
			start = i + 1
			break
		}
	}

	filename = filename[start:]

	if strip_extension {
		// Find last dot
		dot := len(filename)
		for dot > 0 {
			dot -= 1
			c := filename[dot]
			if c == '.' {
				break
			}
		}

		if dot > 0 {
			filename = filename[:dot]
		}
	}

	if is_string_an_identifier(filename) {
		return filename
	} else {
		return "_"
	}
}

// ======================================================================================
// ENTITY COMPARISON AND SORTING
// C++ Reference: /mnt/c/odin/src/checker.cpp:534-539
// ======================================================================================

// entity_variable_pos_cmp compares two entities by token position
// Used for sorting entities by their source location
// C++ Reference: checker.cpp:534-539
entity_variable_pos_cmp :: proc(a: ^Entity, b: ^Entity) -> int {
	return token_pos_cmp(a.token.pos, b.token.pos)
}

// ======================================================================================
// ENTITY KIND PREDICATES
// C++ Reference: /mnt/c/odin/src/entity.cpp
// ======================================================================================

// is_entity_kind checks if entity is of specific kind
// C++ Reference: Inlined checks throughout C++ code
is_entity_kind :: proc(e: ^Entity, kind: Entity_Kind) -> bool {
	if e == nil {
		return false
	}
	return e.kind == kind
}

// is_entity_constant checks if entity is a constant
// C++ Reference: entity.cpp (inlined e->kind == Entity_Constant checks)
is_entity_constant :: proc(e: ^Entity) -> bool {
	return is_entity_kind(e, .Constant)
}

// is_entity_variable checks if entity is a variable
// C++ Reference: entity.cpp (inlined e->kind == Entity_Variable checks)
is_entity_variable :: proc(e: ^Entity) -> bool {
	return is_entity_kind(e, .Variable)
}

// is_entity_procedure checks if entity is a procedure
// C++ Reference: entity.cpp (inlined e->kind == Entity_Procedure checks)
is_entity_procedure :: proc(e: ^Entity) -> bool {
	return is_entity_kind(e, .Procedure)
}

// is_entity_type_name checks if entity is a type name
// C++ Reference: entity.cpp (inlined e->kind == Entity_TypeName checks)
is_entity_type_name :: proc(e: ^Entity) -> bool {
	return is_entity_kind(e, .Type_Name)
}

// is_entity_import_name checks if entity is an import
// C++ Reference: entity.cpp (inlined e->kind == Entity_ImportName checks)
is_entity_import_name :: proc(e: ^Entity) -> bool {
	return is_entity_kind(e, .Import_Name)
}

// ======================================================================================
// ENTITY STATE PREDICATES
// C++ Reference: /mnt/c/odin/src/entity.cpp, checker.cpp
// ======================================================================================

// entity_has_code checks if entity generates code
// C++ Reference: Derived from code generation logic
entity_has_code :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}

	#partial switch e.kind {
	case .Procedure, .Variable:
		return true
	case .Constant:
		// Constants with procedures (like builtin procs) have code
		if const_ent, ok := e.variant.(Entity_Constant); ok {
			return is_type_proc(const_ent.type)
		}
	}

	return false
}

// NOTE: entity_has_deferred_procedure is already defined above (line 146-158)
// It is kept in its original location for backward compatibility

// NOTE: is_entity_exported is already defined above (line 108-144)
// It handles checking if entity is exported from package
// The spec requested entity_is_exported but we already have is_entity_exported

// ======================================================================================
// ENTITY SCOPE HELPERS
// C++ Reference: /mnt/c/odin/src/checker.cpp
// ======================================================================================

// entity_scope_level returns the nesting level of entity's scope
// C++ Reference: Derived from scope traversal patterns
entity_scope_level :: proc(e: ^Entity) -> int {
	if e == nil || e.scope == nil {
		return 0
	}

	level := 0
	for s := e.scope; s != nil; s = s.parent {
		level += 1
	}

	return level
}

// entity_in_file_scope checks if entity is in file (not procedure) scope
// C++ Reference: Derived from parent_proc_decl checks
entity_in_file_scope :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}

	return e.parent_proc_decl == nil
}

// entity_in_foreign_scope checks if entity is in foreign block
// C++ Reference: checker.cpp lines 2596-2666 (checking e->Procedure.is_foreign, e->Variable.is_foreign)
entity_in_foreign_scope :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}

	// Check entity variant for is_foreign field
	#partial switch v in e.variant {
	case Entity_Variable:
		return v.is_foreign
	case Entity_Procedure:
		return v.is_foreign
	}

	return false
}

// ======================================================================================
// ENTITY EXTRACTION FROM AST
// C++ Reference: /mnt/c/odin/src/checker.cpp
// ======================================================================================

// implicit_entity_of_node extracts implicit entity from case clause
// C++ Reference: checker.cpp:1623-1628
implicit_entity_of_node :: proc {
	implicit_entity_of_node_ctx,
	implicit_entity_of_node_info,
}

implicit_entity_of_node_ctx :: proc(ctx: ^Checker_Context, clause: ^ast.Node) -> ^Entity {
	return implicit_entity_of_node_info(ctx.info, clause)
}

implicit_entity_of_node_info :: proc(info: ^Checker_Info, clause: ^ast.Node) -> ^Entity {
	if clause == nil {
		return nil
	}

	#partial switch c in clause.derived {
	case ^ast.Case_Clause:
		// In C++: return clause->CaseClause.implicit_entity
		// We use AST entity mapping since we don't modify AST directly
		return get_ast_entity(info, clause)
	}

	return nil
}

// NOTE: entity_of_node is defined in check_decl_helpers.odin
// C++ Reference: checker.cpp:1630-1676

// decl_info_of_entity extracts DeclInfo from an entity
// C++ Reference: checker.cpp:1667-1672
decl_info_of_entity :: proc(e: ^Entity) -> ^Decl_Info {
	if e != nil {
		return e.decl_info
	}
	return nil
}

// ======================================================================================
// ENTITY LOOKUP AND SCOPE MANIPULATION HELPERS
// C++ Reference: /mnt/c/odin/src/checker.cpp
// ======================================================================================

// lookup_entity searches for entity by name in scope chain
// C++ Reference: checker.cpp:436-440 - scope_lookup wrapper
// This is a simple wrapper around scope_lookup_parent that only returns the entity
lookup_entity :: proc(scope: ^Scope, name: string) -> ^Entity {
	// C++ line 437: Entity *entity = nullptr;
	// C++ line 438: scope_lookup_parent(s, name, nullptr, &entity, hash);
	// C++ line 439: return entity;
	_, entity := scope_lookup_parent(scope, name)
	return entity
}

// lookup_entity_in_package searches for entity in package scope
// C++ Reference: Derived from package scope lookup patterns
lookup_entity_in_package :: proc(info: ^Checker_Info, pkg: ^ast.Package, name: string) -> ^Entity {
	if pkg == nil {
		return nil
	}

	pkg_scope := get_package_scope(info, pkg)
	return scope_lookup_current(pkg_scope, name)
}

// current_scope gets the current scope from context
// C++ Reference: Direct access to ctx->scope
current_scope :: proc(ctx: ^Checker_Context) -> ^Scope {
	if ctx == nil {
		return nil
	}

	return ctx.scope
}

// push_scope pushes a new scope onto the context and returns the previous scope
// C++ Reference: Scope stack management in checker context
push_scope :: proc(ctx: ^Checker_Context, scope: ^Scope) -> ^Scope {
	if ctx == nil {
		return nil
	}

	prev := ctx.scope
	ctx.scope = scope
	return prev
}

// pop_scope restores previous scope on the context
// C++ Reference: Scope stack management in checker context
pop_scope :: proc(ctx: ^Checker_Context, prev: ^Scope) {
	if ctx == nil {
		return
	}

	ctx.scope = prev
}

// ======================================================================================
// ENTITY PACKAGE LOOKUP
// C++ Reference: /mnt/c/odin/src/checker.cpp:3161-3205
// ======================================================================================

// get_runtime_package returns the base:runtime package, or nil if it was not loaded.
//
// C++ Reference: checker.cpp:899-915 (get_runtime_package). The C++ version looks the package
// up by path and GB_ASSERTs it is present, which it can do because parse_packages seeds
// base:runtime unconditionally before any checking starts (src/parser.cpp:7067) - a compiler
// run with no runtime package is a compiler bug there.
//
// This is a library, and check_files can be called with a file list the caller assembled
// itself, which is entirely legitimate and includes no runtime. Asserting would turn that into
// a crash in the host process, so the absent case is reported by returning nil instead. Both
// callers - add_package_dependency via get_core_package, and find_core_entity - already treat
// a missing runtime as "no dependency to record" / "no such type", so nil propagates into the
// same degraded-but-correct behaviour the checker already has when ODIN_ROOT is unset.
get_runtime_package :: proc(info: ^Checker_Info) -> ^ast.Package {
	return info.runtime_package
}

// get_fullpath_core_collection constructs the full path to a core collection
// C++ Reference: build_settings.cpp:1553-1578
// Returns: ODIN_ROOT/core/{path}
get_fullpath_core_collection :: proc(info: ^Checker_Info, path: string, allocator := context.temp_allocator) -> (fullpath: string, ok: bool) {
	if info.build_context == nil {
		return "", false
	}

	odin_root := info.build_context.ODIN_ROOT
	if len(odin_root) == 0 {
		return "", false
	}

	// C++ Reference: build_settings.cpp:1554-1568
	// String module_dir = odin_root_dir();
	// String core = str_lit("core/");
	// isize str_len = module_dir.len + core.len + path.len;
	// ... concatenate module_dir + "core/" + path ...

	// Build: ODIN_ROOT/core/{path}
	builder := strings.builder_make(allocator)
	strings.write_string(&builder, odin_root)

	// Ensure trailing separator
	if len(odin_root) > 0 && odin_root[len(odin_root)-1] != '/' && odin_root[len(odin_root)-1] != '\\' {
		strings.write_string(&builder, "/")
	}

	strings.write_string(&builder, "core/")
	strings.write_string(&builder, path)

	fullpath = strings.to_string(builder)
	ok = true
	return fullpath, ok
}

// get_core_package returns a core package by name
// C++ Reference: checker.cpp:905-925
get_core_package :: proc(info: ^Checker_Info, name: string) -> ^ast.Package {
	// Special case for runtime package
	if name == "runtime" {
		return get_runtime_package(info)
	}

	// C++ Reference: checker.cpp:911
	// String path = get_fullpath_core_collection(a, name, nullptr);
	// auto found = string_map_get(&info->packages, path);
	path, ok := get_fullpath_core_collection(info, name, context.temp_allocator)

	if ok {
		// Try the full path first
		if pkg, found := info.packages[path]; found {
			return pkg
		}
	}

	// Fallback: Try common core package paths
	// This handles cases where package is registered with different key formats
	candidates := []string{fmt.tprintf("core:%s", name), name}

	for candidate in candidates {
		if pkg, found := info.packages[candidate]; found {
			return pkg
		}
	}

	// Package not found - this is a fatal error
	// C++ Reference: checker.cpp:914-922
	fmt.eprintf("Name: %s\n", name)
	if ok {
		fmt.eprintf("Fullpath: %s\n", path)
	}
	fmt.eprintf("\nAvailable packages:\n")
	for key in info.packages {
		fmt.eprintf("  %s\n", key)
	}
	panic(fmt.tprintf("Missing core package: %s", name))
}

// find_core_entity is defined in type_info.odin

// find_core_type is defined in type_info.odin

// find_entity_in_pkg finds an entity in a named package
// C++ Reference: checker.cpp:3186-3194
find_entity_in_pkg :: proc(info: ^Checker_Info, pkg_name: string, entity_name: string) -> ^Entity {
	pkg := get_core_package(info, pkg_name)
	pkg_scope := get_package_scope(info, pkg)
	e := scope_lookup_current(pkg_scope, entity_name)
	if e == nil {
		panic(fmt.tprintf("Could not find type declaration for '%s.%s'", pkg_name, entity_name))
	}
	return e
}

// find_type_in_pkg finds a type in a named package
// C++ Reference: checker.cpp:3196-3205
find_type_in_pkg :: proc(info: ^Checker_Info, pkg_name: string, type_name: string) -> ^Type {
	pkg := get_core_package(info, pkg_name)
	pkg_scope := get_package_scope(info, pkg)
	e := scope_lookup_current(pkg_scope, type_name)
	if e == nil {
		panic(fmt.tprintf("Could not find type declaration for '%s.%s'", pkg_name, type_name))
	}
	assert(e.type != nil, fmt.tprintf("Type '%s.%s' is nil", pkg_name, type_name))
	return e.type
}

// ======================================================================================
// PROCEDURE GROUP ENTITY EXTRACTION
// C++ Reference: /mnt/c/odin/src/checker.cpp:3230-3248
// ======================================================================================

// proc_group_entities extracts entities from a procedure group operand
// C++ Reference: checker.cpp:3235-3245
proc_group_entities :: proc(ctx: ^Checker_Context, o: ^Operand) -> []^Entity {
	// C++ line 3237: if (o.mode == Addressing_ProcGroup)
	if o.mode != .Proc_Group {
		return nil
	}

	// C++ line 3238: GB_ASSERT(o.proc_group != nullptr);
	assert(o.proc_group != nil, "proc_group_entities: operand proc_group is nil")

	// C++ line 3239: if (o.proc_group->kind == Entity_ProcGroup)
	assert(o.proc_group.kind == .Proc_Group, "proc_group_entities: entity is not a procedure group")

	// C++ line 3240: check_entity_decl(c, o.proc_group, nullptr, nullptr);
	check_entity_decl(ctx, o.proc_group, nil, nil)

	// C++ line 3241: return o.proc_group->ProcGroup.entities;
	pg, ok := o.proc_group.variant.(Entity_Proc_Group)
	assert(ok, "proc_group_entities: entity variant is not Entity_Proc_Group")

	return pg.procs[:]
}

// proc_group_entities_cloned clones the entities array from a procedure group
// C++ Reference: checker.cpp:3242-3248
proc_group_entities_cloned :: proc(ctx: ^Checker_Context, o: ^Operand, allocator := context.allocator) -> []^Entity {
	entities := proc_group_entities(ctx, o)
	if len(entities) == 0 {
		return nil
	}

	// Clone the slice
	cloned := make([]^Entity, len(entities), allocator)
	copy(cloned, entities)
	return cloned
}

// ======================================================================================
// TYPE PATH MANAGEMENT
// C++ Reference: /mnt/c/odin/src/checker.cpp:3425-3453
// ======================================================================================

// Type path is used for cycle detection during type checking.
// The C++ version uses an array that's pushed/popped during type resolution, referenced
// through a pointer stored in the CheckerContext so that every copy of a context shares
// one path.

// new_checker_type_path allocates a fresh, empty type path.
// C++ Reference: checker.cpp:3427-3436
//
// C++ recycles these through a thread-local free list backed by the permanent allocator;
// here the path is heap allocated and released by destroy_checker_type_path. The observable
// semantics -- a brand new, empty path -- are identical.
new_checker_type_path :: proc(allocator := context.allocator) -> ^Checker_Type_Path {
	tp := new(Checker_Type_Path, allocator)
	tp^ = make(Checker_Type_Path, 0, 16, allocator)
	return tp
}

// destroy_checker_type_path releases a type path allocated by new_checker_type_path.
// C++ Reference: checker.cpp:3438-3443
destroy_checker_type_path :: proc(tp: ^Checker_Type_Path, allocator := context.allocator) {
	if tp == nil {
		return
	}
	delete(tp^)
	free(tp, allocator)
}

// check_type_path_push adds an entity to the type checking path
// C++ Reference: checker.cpp:3445-3449
check_type_path_push :: proc(ctx: ^Checker_Context, e: ^Entity) {
	assert(ctx.type_path != nil)
	assert(e != nil)
	append(ctx.type_path, e)
}

// check_type_path_pop removes the last entity from the type checking path
// C++ Reference: checker.cpp:3450-3453
check_type_path_pop :: proc(ctx: ^Checker_Context) -> ^Entity {
	assert(ctx.type_path != nil)
	assert(len(ctx.type_path^) > 0)
	return pop(ctx.type_path)
}

// check_cycle checks if the current entity is part of a type cycle
// C++ Reference: check_expr.cpp:1803-1823
check_cycle :: proc(ctx: ^Checker_Context, curr: ^Entity, report: bool) -> bool {
	if curr == nil {
		return false
	}
	if curr.state != .In_Progress {
		return false
	}
	if ctx.type_path == nil {
		return false
	}

	// Search through the type path for the current entity
	type_path := ctx.type_path^
	for prev, i in type_path {
		if prev == curr {
			if report {
				error_token(curr.token, "Illegal declaration cycle of `%s`", curr.token.text)
				// Print the cycle chain
				for j := i; j < len(type_path); j += 1 {
					cycle_ent := type_path[j]
					error_token(cycle_ent.token, "\t%s refers to", cycle_ent.token.text)
				}
				error_token(curr.token, "\t%s", curr.token.text)
				curr.type = t_invalid
			}
			return true
		}
	}
	return false
}

// ======================================================================================
// ENTITY DEPENDENCY HELPERS
// C++ Reference: /mnt/c/odin/src/checker.cpp:3005-3016
// ======================================================================================

// is_entity_a_dependency checks if an entity should be included in dependency graphs
// Used for code generation and dependency analysis
// C++ Reference: checker.cpp:3005-3016
is_entity_a_dependency :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}

	#partial switch e.kind {
	case .Procedure:
		return true
	case .Constant, .Variable:
		// Only entities with a package are dependencies
		// (i.e., not local variables or parameters)
		return e.pkg != nil
	case .Type_Name:
		return false
	case:
		return false
	}
}

// ======================================================================================
// ENTITY SELECTOR VALIDATION
// C++ Reference: /mnt/c/odin/src/check_expr.cpp:5358-5371
// ======================================================================================

// is_entity_declared_for_selector validates if entity is properly declared for selector access
// This checks if a builtin entity is accessible from the import scope, and if global entities
// are accessible from non-global scopes.
// C++ Reference: check_expr.cpp:5358-5371
is_entity_declared_for_selector :: proc(entity: ^Entity, import_scope: ^Scope, allow_builtin: ^bool, builtin_pkg_scope: ^Scope = nil, intrinsics_pkg_scope: ^Scope = nil) -> bool {
	is_declared := entity != nil

	if is_declared {
		// C++ line 5361-5365: Special handling for builtins
		if entity.kind == .Builtin {
			// NOTE(bill): Builtin's are in the universal scope which is part of every scope's hierarchy
			// This means that we should just ignore the found result through it
			if builtin_pkg_scope != nil && intrinsics_pkg_scope != nil {
				allow_builtin^ = entity.scope == import_scope || (entity.scope != builtin_pkg_scope && entity.scope != intrinsics_pkg_scope)
			} else {
				// If we don't have package scopes, allow builtin by default
				allow_builtin^ = true
			}
		} else if entity.scope != nil && .Global in entity.scope.flags && .Global not_in import_scope.flags {
			// C++ line 5366-5368: Global entity accessed from non-global scope
			// if ((entity->scope->flags&ScopeFlag_Global) == ScopeFlag_Global && (import_scope->flags&ScopeFlag_Global) == 0)
			is_declared = false
		}
	}

	return is_declared
}

// ======================================================================================
// TOKEN HELPERS
// ======================================================================================

// make_token_ident creates an identifier token from a string
// C++ Reference: tokenizer.cpp:251-258
make_token_ident :: proc(s: string) -> tokenizer.Token {
	return tokenizer.Token{kind = .Ident, text = s}
}

// init_mem_allocator initializes the cached Allocator type from core:runtime
// C++ Reference: checker.cpp:3338-3359
init_mem_allocator :: proc(c: ^Checker) {
	info := &c.info

	// NOTE: the guard keys off the GLOBAL, not info.cached_allocator, matching C++
	// (checker.cpp:3570). reset_runtime_type_globals clears the globals but not the cached_ fields,
	// so guarding on the cached field would return early on a second checker in the same process
	// and leave t_allocator nil.
	if t_allocator != nil {
		return
	}

	// Look up Allocator type in core:runtime
	allocator_type := find_core_type(c, "Allocator")
	if allocator_type == nil {
		// Runtime package not loaded - skip initialization
		return
	}

	// C++ Reference: checker.cpp:3573-3575. The checker reads the GLOBALS (t_allocator has 9 read
	// sites); the info.cached_ fields are written here for symmetry but are not read anywhere.
	// Assigning only the cached fields was why every `context.allocator` failed.
	t_allocator = allocator_type
	t_allocator_ptr = alloc_type_pointer(allocator_type)

	info.cached_allocator = allocator_type
	info.cached_allocator_ptr = t_allocator_ptr

	// Also cache Allocator_Error enum type
	// C++ Reference: checker.cpp:3575
	allocator_error := find_core_type(c, "Allocator_Error")
	if allocator_error != nil {
		t_allocator_error = allocator_error
		info.cached_allocator_error = allocator_error
	}
}

// init_core_context initializes the cached Context type from core:runtime
// C++ Reference: checker.cpp:3360-3362
init_core_context :: proc(c: ^Checker) {
	info := &c.info

	// NOTE: guard on the GLOBAL, matching C++ (checker.cpp:3579). See init_mem_allocator.
	if t_context != nil {
		return
	}

	// Look up Context type in core:runtime
	context_type := find_core_type(c, "Context")
	if context_type == nil {
		// Runtime package not loaded - skip initialization
		return
	}

	// C++ Reference: checker.cpp:3582-3583. The checker reads the globals - check_expr.odin:6729
	// assigns `o.type = t_context` for the `context` implicit, and check_equivalence.odin:827 and
	// check_deferred.odin:353 compare against it. Leaving t_context nil made every `context.X`
	// selector report "Cannot use a selector expression on nil-value expression", which is why
	// `allocator := context.allocator` - the most common idiom in core - failed everywhere.
	t_context = context_type
	t_context_ptr = alloc_type_pointer(context_type)

	info.cached_context = context_type
	info.cached_context_ptr = t_context_ptr
}

// init_core_map_type initializes the cached map-internal types from core:runtime
// C++ Reference: checker.cpp:3604-3617 (init_core_map_type)
//
// These globals back the `intrinsics.type_map_info` / `intrinsics.type_map_cell_info` builtins
// and the map runtime layout. Nothing in the port initialised them, so they stayed nil after
// reset_runtime_type_globals (types.odin:377-382) - and check_builtin_type_map_cell_info would
// hand `operand.type = t_map_cell_info_ptr` (nil) back with mode = .Value. A nil-typed operand
// then reached check_init_variable, where `assert(is_type_typed(t))` fired: base:runtime's
// dynamic_map_internal.odin does exactly this at line 242 (`INFO_HS := intrinsics.type_map_cell_info(Map_Hash)`).
init_core_map_type :: proc(c: ^Checker) {
	// NOTE: guard on the GLOBAL, matching C++ (checker.cpp:3605). See init_mem_allocator.
	if t_map_info != nil {
		return
	}

	// C++ Reference: checker.cpp:3608. init_map_internal_types asserts t_allocator is set, and
	// this is what guarantees it for callers that reach a map type before init_preload runs.
	init_mem_allocator(c)

	map_info := find_core_type(c, "Map_Info")
	map_cell_info := find_core_type(c, "Map_Cell_Info")
	raw_map := find_core_type(c, "Raw_Map")
	if map_info == nil || map_cell_info == nil || raw_map == nil {
		// Runtime package not loaded - skip initialization
		return
	}

	// C++ Reference: checker.cpp:3609-3616
	t_map_info = map_info
	t_map_cell_info = map_cell_info
	t_raw_map = raw_map

	t_map_info_ptr = alloc_type_pointer(map_info)
	t_map_cell_info_ptr = alloc_type_pointer(map_cell_info)
	t_raw_map_ptr = alloc_type_pointer(raw_map)
}

// init_preload initializes core runtime types that the checker needs
// This caches Allocator, Context, Source_Code_Location, Type_Info, and ObjC types
// for use in codegen and runtime operations.
//
// C++ Reference: checker.cpp:3335-3395 (init_preload)
init_preload :: proc(c: ^Checker) {
	// Initialize Type_Info first (used by many other systems)
	// C++ Reference: checker.cpp:3340
	init_core_type_info(c)

	// Initialize Allocator type
	// C++ Reference: checker.cpp:3338-3359
	init_mem_allocator(c)

	// Initialize Context type
	// C++ Reference: checker.cpp:3360-3362
	init_core_context(c)

	// Initialize Source_Code_Location type
	// C++ Reference: checker.cpp:3363-3367
	init_core_source_code_location(c)

	// Initialize the map-internal types (Map_Info, Map_Cell_Info, Raw_Map)
	// C++ Reference: checker.cpp:3630
	init_core_map_type(c)

	// Initialize Objective-C types from intrinsics package
	// C++ Reference: checker.cpp (objc type handling)
	init_objc_types(c)

	// Initialize c_va_list from intrinsics package
	// C++ Reference: checker.cpp:1528-1591
	init_c_va_list_types(c)
}
