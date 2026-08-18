package checker

import "core:odin/ast"
import "core:odin/tokenizer"
import "core:sync"
/*
Entity allocation and management.

This module provides entity construction functions, similar to the C++
implementation in entity.cpp.

Entity allocation functions create and initialize entities of various kinds
with appropriate flags and variant data.
*/


// Entity_Visibility_Kind determines the export scope of an entity
// C++ Reference: EntityVisiblityKind in checker.hpp
Entity_Visibility_Kind :: enum {
	Public, // Exported from package
	Private_To_Package, // Private to package (@private)
	Private_To_File, // Private to file (@private="file")
}

// Entity_Flag and Entity_Flags are now aliased from ast.Entity_Flag/ast.Entity_Flags in checker.odin

// Entity_Flags_Is_Subtype combines Using and Subtype flags
// C++ Reference: entity.cpp - EntityFlags_IsSubtype
Entity_Flags_Is_Subtype :: Entity_Flags{.Using, .Subtype}

// Global entity ID counter
global_entity_id: i64

// alloc_entity is the base allocation function for all entities
// C++ Reference: entity.cpp:342-355
alloc_entity :: proc(kind: Entity_Kind, scope: ^Scope, token: tokenizer.Token, type: ^Type, allocator := context.allocator) -> ^Entity {
	entity := new(Entity, allocator)
	entity.kind = kind
	entity.state = .Unresolved
	entity.scope = scope
	entity.token = token
	entity.type = type
	// C++ line 350: entity->id = 1 + global_entity_id.fetch_add(1)
	entity.id = 1 + cast(u64)sync.atomic_add(&global_entity_id, 1)

	// C++ Reference: entity.cpp:369 --
	//     e_->file = thread_unsafe_get_ast_file_from_id((token_).pos.file_id);
	// C++ stamps every entity with its file AT ALLOCATION, derived from the entity's OWN TOKEN.
	// That value is independent of checker state: it is correct even when the current context has
	// no file.
	//
	// LEDGER #466 (task #344). This was previously left unset with the note "pos.file is a string
	// path, not an ID / we don't have access to Checker_Info / the file will be set by the caller".
	// The deviation was real, but its CONSEQUENCE was not traced: deriving file from the context
	// instead of the token is SELF-PROPAGATING. A fileless context yields a fileless entity
	// (nothing backfills it), which yields a fileless Proc_Info (check_proc.odin:228
	// `pi.file = e.file`), which yields a fileless context for that body (check_proc.odin:660),
	// which yields more fileless entities. Measured on base/runtime: ~3 seeds/run single-threaded
	// where the loop barely starts, vs ~58/run threaded -- the amplification is what made the
	// semantic model nondeterministic under threading (#344).
	//
	// The stated obstacle is gone: #279 added a GLOBAL path-keyed source-file registry, so no
	// Checker_Info is needed to resolve a path to its file. A miss leaves file nil, exactly as
	// before, and C++'s lazy backfill (checker.cpp:2096, ported at entity_helpers.odin:447) still
	// covers that case -- so this strictly adds information, it never removes any.
	// DO NOT MEMOISE THIS LOOKUP. It takes a global mutex and runs once per entity, so a
	// single-slot thread-local cache looks like an obvious win -- it was tried and measured
	// (LEDGER #467). Two results killed it: the timing difference was inside run-to-run noise
	// (110-122ms on utf8string either way), and it made the model LESS deterministic --
	// base/runtime threaded went from sorted=1/8 to 2/8. The registry OVERWRITES entries
	// (error.odin:584), so one path can map to different ^ast.File objects over time; a fresh
	// lookup sees the current one, a memo returns whatever it cached, and which you get depends
	// on when the thread first touched that path.
	if len(token.pos.file) > 0 {
		if f := lookup_source_file(token.pos.file); f != nil {
			entity.file = f
		}
	}

	// Initialize variant based on kind
	#partial switch kind {
	case .Constant:
		entity.variant = Entity_Constant {
			type  = type,
			value = nil,
		}
	case .Variable:
		entity.variant = Entity_Variable {
			type = type,
		}
	case .Type_Name:
		entity.variant = Entity_Type_Name {
			type = type,
		}
	case .Procedure:
		entity.variant = Entity_Procedure {
			type = type,
		}
	case .Proc_Group:
		entity.variant = Entity_Proc_Group{}
	case .Builtin:
		entity.variant = Entity_Builtin{}
	case .Label:
		entity.variant = Entity_Label{}
	case .Package_Name:
		entity.variant = Entity_Package_Name{}
	case .Import_Name:
		entity.variant = Entity_Import_Name{}
	case .Library_Name:
		entity.variant = Entity_Library_Name{}
	}

	return entity
}

// alloc_entity_variable creates a variable entity
// C++ Reference: entity.cpp:357-361
alloc_entity_variable :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, state: Entity_State = .Unresolved, allocator := context.allocator) -> ^Entity {
	// C++ line 358: Entity *entity = alloc_entity(Entity_Variable, scope, token, type);
	entity := alloc_entity(.Variable, scope, token, type, allocator)
	// C++ line 359: entity->state = state;
	entity.state = state
	return entity
}

// alloc_entity_constant creates a constant entity
alloc_entity_constant :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, value: Exact_Value, allocator := context.allocator) -> ^Entity {
	entity := alloc_entity(.Constant, scope, token, type, allocator)
	entity.variant = Entity_Constant {
		type  = type,
		value = value,
	}
	return entity
}

// alloc_entity_type_name creates a type name entity
// C++ Reference: entity.cpp:383-387
alloc_entity_type_name :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, state: Entity_State = .Unresolved, allocator := context.allocator) -> ^Entity {
	// C++ line 384: Entity *entity = alloc_entity(Entity_TypeName, scope, token, type);
	entity := alloc_entity(.Type_Name, scope, token, type, allocator)
	// C++ line 385: entity->state = state;
	entity.state = state
	return entity
}

// alloc_entity_param creates a parameter entity
// C++ Reference: entity.cpp:389-397
alloc_entity_param :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, is_using := false, is_value := false, allocator := context.allocator) -> ^Entity {
	// C++ line 390: Entity *entity = alloc_entity_variable(scope, token, type);
	entity := alloc_entity_variable(scope, token, type, .Resolved, allocator)
	// C++ line 391: entity->flags |= EntityFlag_Used;
	// C++ line 392: entity->flags |= EntityFlag_Param;
	entity.flags = {.Param, .Used}
	// C++ line 393: entity->state = EntityState_Resolved;
	entity.state = .Resolved
	// C++ line 394: if (is_using) entity->flags |= EntityFlag_Using;
	if is_using {
		entity.flags += {.Using}
	}
	// C++ line 395: if (is_value) entity->flags |= EntityFlag_Value;
	if is_value {
		entity.flags += {.Value}
	}
	return entity
}

// alloc_entity_field creates a struct/union field entity
// C++ Reference: entity.cpp:409-416
alloc_entity_field :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, is_using := false, field_index := i32(0), state: Entity_State = .Unresolved, allocator := context.allocator) -> ^Entity {
	// C++ line 410: Entity *entity = alloc_entity_variable(scope, token, type);
	entity := alloc_entity_variable(scope, token, type, state, allocator)
	// C++ line 411: entity->Variable.field_index = field_index;
	if var, ok := &entity.variant.(Entity_Variable); ok {
		var.field_index = field_index
	}
	// C++ line 412: if (is_using) entity->flags |= EntityFlag_Using;
	if is_using {
		entity.flags += {.Using}
	}
	// C++ line 413: entity->flags |= EntityFlag_Field;
	entity.flags += {.Field}
	// C++ line 414: entity->state = state;
	entity.state = state
	return entity
}

// alloc_entity_using_variable creates a using variable from a parent entity
// C++ Reference: entity.cpp:363-374
alloc_entity_using_variable :: proc(parent: ^Entity, token: tokenizer.Token, type: ^Type, using_expr: ^ast.Expr, allocator := context.allocator) -> ^Entity {
	assert(parent != nil)
	// C++ line 365: token.pos = parent->token.pos;
	token := token
	token.pos = parent.token.pos
	// C++ line 366: Entity *entity = alloc_entity(Entity_Variable, parent->scope, token, type);
	entity := alloc_entity(.Variable, parent.scope, token, type, allocator)
	// C++ line 367: entity->using_parent = parent;
	entity.using_parent = parent
	// C++ line 368: entity->parent_proc_decl = parent->parent_proc_decl;
	entity.parent_proc_decl = parent.parent_proc_decl
	// C++ line 369: entity->using_expr = using_expr;
	entity.using_expr = using_expr
	// C++ line 370-371: entity->flags |= EntityFlag_Using; entity->flags |= EntityFlag_Used;
	entity.flags = {.Using, .Used}
	// C++ line 372: entity->state = EntityState_Resolved;
	entity.state = .Resolved
	return entity
}

// alloc_entity_const_param creates a constant parameter entity (for polymorphic constants)
// C++ Reference: entity.cpp:400-406
alloc_entity_const_param :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, value: Exact_Value, poly_const: bool, allocator := context.allocator) -> ^Entity {
	// C++ line 401: Entity *entity = alloc_entity_constant(scope, token, type, value);
	entity := alloc_entity_constant(scope, token, type, value, allocator)
	// C++ line 402: entity->flags |= EntityFlag_Used;
	entity.flags += {.Used}
	// C++ line 403: if (poly_const) entity->flags |= EntityFlag_PolyConst;
	if poly_const {
		entity.flags += {.Poly_Const}
	}
	// C++ line 404: entity->flags |= EntityFlag_Param;
	entity.flags += {.Param}
	// Constant parameters are immediately resolved - set state to Resolved
	// This prevents "Illegal declaration cycle" errors when the constant is used
	// in expressions like array sizes (e.g., [N]int)
	entity.state = .Resolved
	return entity
}

// alloc_entity_array_elem creates an array element entity
// C++ Reference: entity.cpp:418-425
alloc_entity_array_elem :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, field_index: i32, allocator := context.allocator) -> ^Entity {
	// C++ line 419: Entity *entity = alloc_entity_variable(scope, token, type);
	entity := alloc_entity_variable(scope, token, type, .Resolved, allocator)
	// C++ line 420: entity->Variable.field_index = field_index;
	if var, ok := &entity.variant.(Entity_Variable); ok {
		var.field_index = field_index
	}
	// C++ line 421: entity->flags |= EntityFlag_Field;
	entity.flags += {.Field}
	// C++ line 422: entity->flags |= EntityFlag_ArrayElem;
	entity.flags += {.Array_Elem}
	// C++ line 423: entity->state = EntityState_Resolved;
	entity.state = .Resolved
	return entity
}

// alloc_entity_nil creates a nil entity
// C++ Reference: entity.cpp:461-464
alloc_entity_nil :: proc(name: string, type: ^Type, allocator := context.allocator) -> ^Entity {
	// C++ line 462: Entity *entity = alloc_entity(Entity_Nil, nullptr, make_token_ident(name), type);
	token := tokenizer.Token {
		text = name,
		kind = .Ident,
	}
	entity := alloc_entity(.Nil, nil, token, type, allocator)
	// C++ stores i32 in the variant for Nil (see entity.cpp:289)
	entity.variant = i32(0)
	return entity
}

// alloc_entity_dummy_variable creates a dummy variable (_) for ignored assignments
// C++ Reference: entity.cpp:474-477
alloc_entity_dummy_variable :: proc(scope: ^Scope, token: tokenizer.Token, allocator := context.allocator) -> ^Entity {
	// C++ line 475: token.string = str_lit("_");
	token := token
	token.text = "_"
	// C++ line 476: return alloc_entity_variable(scope, token, nullptr);
	return alloc_entity_variable(scope, token, nil, .Unresolved, allocator)
}

// alloc_entity_procedure creates a procedure entity
// C++ Reference: entity.cpp:427-431
alloc_entity_procedure :: proc(scope: ^Scope, token: tokenizer.Token, signature_type: ^Type, tags: u64 = 0, allocator := context.allocator) -> ^Entity {
	entity := alloc_entity(.Procedure, scope, token, signature_type, allocator)
	// C++ line 429: entity->Procedure.tags = tags;
	if proc_variant, ok := &entity.variant.(Entity_Procedure); ok {
		proc_variant.tags = tags
	}
	return entity
}

// alloc_entity_proc_group creates a procedure group entity
alloc_entity_proc_group :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, allocator := context.allocator) -> ^Entity {
	entity := alloc_entity(.Proc_Group, scope, token, type, allocator)
	return entity
}

// alloc_entity_import_name creates an import name entity
alloc_entity_import_name :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, path: string, name: string, import_scope: ^Scope, allocator := context.allocator) -> ^Entity {
	entity := alloc_entity(.Import_Name, scope, token, type, allocator)
	entity.variant = Entity_Import_Name {
		name  = name,
		path  = path,
		scope = import_scope,
	}
	entity.state = .Resolved
	return entity
}

// alloc_entity_library_name creates a library name entity
alloc_entity_library_name :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, paths: []string, name: string, allocator := context.allocator) -> ^Entity {
	entity := alloc_entity(.Library_Name, scope, token, type, allocator)
	entity.variant = Entity_Library_Name {
		name  = name,
		paths = paths,
	}
	entity.state = .Resolved
	return entity
}

// alloc_entity_label creates a label entity
// C++ Reference: entity.cpp:466-472
alloc_entity_label :: proc(scope: ^Scope, token: tokenizer.Token, type: ^Type, node: ^ast.Stmt, parent: ^ast.Stmt, allocator := context.allocator) -> ^Entity {
	// C++ line 467: Entity *entity = alloc_entity(Entity_Label, scope, token, type);
	entity := alloc_entity(.Label, scope, token, type, allocator)
	// C++ lines 468-469: entity->Label.node = node; entity->Label.parent = parent;
	entity.variant = Entity_Label {
		name   = token.text,
		node   = node,
		parent = parent,
	}
	// C++ line 470: entity->state = EntityState_Resolved;
	entity.state = .Resolved
	return entity
}

// alloc_entity_builtin creates a builtin procedure entity
alloc_entity_builtin :: proc(name: string, id: Builtin_Proc_Id, allocator := context.allocator) -> ^Entity {
	token := tokenizer.Token {
		text = name,
		kind = .Ident,
	}
	entity := alloc_entity(.Builtin, nil, token, t_invalid, allocator)
	entity.variant = Entity_Builtin {
		id = id,
	}
	entity.state = .Resolved
	return entity
}

// Entity utility functions

// is_entity_kind_exported checks if an entity kind can be exported
// C++ Reference: entity.cpp:298-308
is_entity_kind_exported :: proc(kind: Entity_Kind, allow_builtin := false) -> bool {
	#partial switch kind {
	case .Builtin:
		// C++ line 300-301: Only exported if allow_builtin is true
		return allow_builtin
	case .Import_Name, .Library_Name, .Nil:
		// C++ line 302-305: These kinds are never exported
		return false
	}
	// C++ line 307: All other kinds can be exported
	return true
}

// entity_type returns the type of an entity
//
// C++ Reference: entity.cpp:170 -- `Type *type;` is a field of Entity itself, and no member of
// the discriminated union at entity.cpp:196 declares a `type`. C++ therefore has exactly ONE
// place an entity's type lives, and every read of `e->type` sees every write.
//
// The port duplicated that storage: Entity.type plus a `type` field on four of the variants.
// Reads then split -- `e.type` and `entity_type(e)` could disagree -- and any write that
// updated only one half was silently invisible to the other. Two such splits were already
// found and fixed one site at a time (LEDGER 192, 162); instrumenting the disagreement
// directly turned up a third across core/sys/darwin/Foundation, where the declaration-cycle
// recovery writes t_invalid to the base field only, so entity_type kept handing out the stale
// pre-cycle type that C++ discards.
//
// The variant `type` fields are now write-only duplicates: this reads the base field, which is
// the one every direct `e.type = ...` site already writes. Kept behind the original kind gate --
// C++ has no such gate, but widening it is a separate change with its own consequences for the
// kinds that carry no type (Import_Name, Package_Name, Builtin, Label, Proc_Group).
entity_type :: proc(e: ^Entity) -> ^Type {
	if e == nil {
		return nil
	}

	#partial switch _ in e.variant {
	case Entity_Constant, Entity_Variable, Entity_Type_Name, Entity_Procedure:
		return e.type
	}

	return nil
}

// set_entity_type sets the type of an entity
// This sets BOTH the entity's base type field AND the variant's type field
// to ensure both e.type and entity_type(e) return the correct value
set_entity_type :: proc(e: ^Entity, type: ^Type) {
	if e == nil {
		return
	}

	// Set the base entity type field (used by some code that reads e.type directly)
	e.type = type

	// Set the variant's type field (used by entity_type())
	#partial switch &v in e.variant {
	case Entity_Constant:
		v.type = type
	case Entity_Variable:
		v.type = type
	case Entity_Type_Name:
		v.type = type
	case Entity_Procedure:
		v.type = type
	}
}

// tuple_variable_type extracts the type from a tuple variable at a specific index
// Helper function for accessing types from Type_Tuple.variables
// Matches C++ pattern: tuple->Tuple.variables[index]->type
tuple_variable_type :: proc(tuple: ^Type, index: int) -> ^Type {
	if tuple == nil || tuple.kind != .Tuple {
		return nil
	}

	tup := tuple.variant.(Type_Tuple)
	if index < 0 || index >= len(tup.variables) {
		return nil
	}

	entity := tup.variables[index]
	return entity_type(entity)
}

// is_entity_param checks if an entity is a parameter
is_entity_param :: proc(e: ^Entity) -> bool {
	if e == nil || e.kind != .Variable {
		return false
	}
	return .Param in e.flags
}

// is_entity_using checks if an entity has the using attribute
is_entity_using :: proc(e: ^Entity) -> bool {
	if e == nil {
		return false
	}
	return .Using in e.flags
}

// is_entity_exported checks if an entity is exported from its package
// C++ Reference: entity.cpp:314-333
is_entity_exported :: proc {
	is_entity_exported_simple,
	is_entity_exported_with_info,
}

// is_entity_exported_simple checks entity export without file flags
// Use is_entity_exported_with_info when Checker_Info is available for complete checking
is_entity_exported_simple :: proc(e: ^Entity, allow_builtin := false) -> bool {
	assert(e != nil)
	// C++ line 316: if (!is_entity_kind_exported(e->kind, allow_builtin))
	if !is_entity_kind_exported(e.kind, allow_builtin) {
		return false
	}

	// C++ line 320: if (e->flags & EntityFlag_NotExported)
	if .Not_Exported in e.flags {
		return false
	}

	// C++ line 323: if (e->file != nullptr && (e->file->flags & (AstFile_IsPrivatePkg|AstFile_IsPrivateFile)) != 0)
	// This check WAS omitted here, justified by a comment claiming the file flags are "not
	// available without Checker_Info". That claim is false: has_file_flag (and every wrapper over
	// it, including is_file_private/is_file_private_to_pkg) NEVER READS `info` -- it returns
	// `flag in file.flags`, and set_file_flags writes straight to `file.flags`. The flags live on
	// the ast.File node, exactly as they do on AstFile in the reference, so no side table and no
	// Checker_Info is involved. check_collect.odin:1098 already reads ctx.scope.file.flags
	// directly. The `info` parameter on those helpers is vestigial.
	// Omitting it made this overload a WEAKER predicate than the reference's single function, and
	// it is the overload the two-argument call sites resolve to -- notably check_expr.odin:6115,
	// the site that reports "'%s' is not exported by '%s'".
	if e.file != nil {
		if .Is_Private_Pkg in e.file.flags || .Is_Private_File in e.file.flags {
			return false
		}
	}

	// C++ line 327: String name = e->token.string;
	name := e.token.text
	// C++ line 328-331: Check name exportability
	switch len(name) {
	case 0:
		return false
	case 1:
		return name[0] != '_'
	}
	return true
}

// is_entity_exported_with_info checks entity export including file flags
// C++ Reference: entity.cpp:314-333 (complete implementation)
is_entity_exported_with_info :: proc(info: ^Checker_Info, e: ^Entity, allow_builtin := false) -> bool {
	assert(e != nil)
	// C++ line 316: if (!is_entity_kind_exported(e->kind, allow_builtin))
	if !is_entity_kind_exported(e.kind, allow_builtin) {
		return false
	}

	// C++ line 320: if (e->flags & EntityFlag_NotExported)
	if .Not_Exported in e.flags {
		return false
	}

	// C++ line 323: if (e->file != nullptr && (e->file->flags & (AstFile_IsPrivatePkg|AstFile_IsPrivateFile)) != 0)
	if e.file != nil && info != nil {
		if is_file_private_to_pkg(info, e.file) || is_file_private(info, e.file) {
			return false
		}
	}

	// C++ line 327: String name = e->token.string;
	name := e.token.text
	// C++ line 328-331: Check name exportability
	switch len(name) {
	case 0:
		return false
	case 1:
		return name[0] != '_'
	}
	return true
}

// entity_has_deferred_procedure checks if an entity has a deferred procedure
// C++ Reference: entity.cpp:331-337
entity_has_deferred_procedure :: proc(e: ^Entity) -> bool {
	assert(e != nil)
	// C++ line 333: if (e->kind == Entity_Procedure)
	if e.kind == .Procedure {
		// C++ line 334: return e->Procedure.deferred_procedure.entity != nullptr;
		if proc_data, ok := e.variant.(Entity_Procedure); ok {
			return proc_data.deferred_procedure.entity != nil
		}
	}
	return false
}

// strip_entity_wrapping: see entity_helpers.odin for the complete implementation
// C++ Reference: entity.cpp:482-498

// is_entity_local_variable checks if an entity is a local (non-global) variable
// C++ Reference: entity.cpp:501-520
is_entity_local_variable :: proc(e: ^Entity) -> bool {
	// C++ line 502-505: if (e == nullptr) return false;
	if e == nil {
		return false
	}
	// C++ line 506-508: if (e->kind != Entity_Variable) return false;
	if e.kind != .Variable {
		return false
	}

	// C++ line 509-511: Check if it's a global variable
	if var_data, ok := e.variant.(Entity_Variable); ok {
		if var_data.is_global {
			return false
		}
	}

	// C++ line 512-514: if (e->scope == nullptr) return true;
	if e.scope == nil {
		return true
	}

	// C++ line 515-517: Check special flags that make it non-local
	if (.For_Value in e.flags) || (.Switch_Value in e.flags) || (.Static in e.flags) {
		return false
	}

	// C++ line 518-519: Check scope flags
	// return ((e->scope->flags &~ ScopeFlag_ContextDefined) == 0) ||
	//        (e->scope->flags & ScopeFlag_Proc) != 0;
	scope_flags := e.scope.flags
	// Remove Context_Defined flag for comparison
	scope_flags_no_context := scope_flags - {.Context_Defined}

	// Either no flags (except Context_Defined), or it's in a Proc scope
	return (scope_flags_no_context == {}) || (.Proc in scope_flags)
}

// has_parameter_value checks if a parameter has a default value
// C++ Reference: entity.cpp:120-128
has_parameter_value :: proc(param_value: Parameter_Value) -> bool {
	// C++ line 121-123: if (param_value.kind != ParameterValue_Invalid) return true;
	if param_value.kind != .Invalid {
		return true
	}
	// C++ line 124-126: if (param_value.original_ast_expr != nullptr) return true;
	if param_value.original_ast_expr != nil {
		return true
	}
	// C++ line 127: return false;
	return false
}
