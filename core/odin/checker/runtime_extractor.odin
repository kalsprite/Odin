package checker

/*
Runtime Type Extractor

This module extracts type information from base/runtime source files
without fully checking them. This allows the checker to provide type
information for code that imports base:runtime.

The extractor parses runtime source files and extracts:
- Struct definitions
- Enum definitions
- Union definitions
- Type aliases
- Procedure signatures
- Simple constants

It skips constructs that require compiler constants (ODIN_OS, etc.)
since we only need the type shapes, not evaluated values.
*/

import "core:os"
import "core:path/filepath"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"

// extract_runtime_types parses base/runtime and extracts type information
// Returns a package with extracted type entities
extract_runtime_types :: proc(info: ^Checker_Info, allocator := context.allocator) -> ^ast.Package {
	if info == nil {
		return nil
	}

	// Get runtime path from ODIN_ROOT
	odin_root := build_context.ODIN_ROOT
	if len(odin_root) == 0 {
		odin_root = os.get_env("ODIN_ROOT", allocator)
	}
	if len(odin_root) == 0 {
		return nil
	}

	runtime_path, join_err := filepath.join({odin_root, "base", "runtime"}, allocator)
	if join_err != nil {
		return nil
	}

	// Create runtime package
	pkg := create_runtime_package(runtime_path, allocator)
	if pkg == nil {
		return nil
	}

	// Create scope for runtime package
	pkg_scope := create_scope(nil, allocator)
	pkg_scope.flags += {.Pkg}
	pkg_scope.pkg = pkg
	pkg.scope = pkg_scope
	info.package_scopes[pkg] = pkg_scope

	// Parse runtime files (but don't check them).
	//
	// base/runtime is as platform-split as any other package - entry_windows.odin,
	// procs_darwin.odin, os_specific_wasi.odin and friends - so it is collected through the
	// target-aware collector too. Pulling in another platform's files here would define the
	// same runtime types twice and leave the extractor picking whichever it saw last.
	parsed_pkg, parse_ok := collect_package_for_target(runtime_path)
	if !parse_ok || parsed_pkg == nil {
		return pkg
	}

	// Set package kind to Runtime so parser accepts "package runtime"
	parsed_pkg.kind = .Runtime
	parse_ok = parser.parse_package(parsed_pkg, nil)
	// Even with parse errors, try to extract what we can

	// Extract type definitions from parsed AST
	for _, file in parsed_pkg.files {
		extract_types_from_file(info, pkg, pkg_scope, file, allocator)
	}

	return pkg
}

// create_runtime_package creates a package struct for runtime
create_runtime_package :: proc(path: string, allocator := context.allocator) -> ^ast.Package {
	pkg := new(ast.Package, allocator)
	pkg.kind = .Runtime
	pkg.name = "runtime"
	pkg.fullpath = path
	pkg.files = make(map[string]^ast.File, allocator = allocator)
	return pkg
}

// extract_types_from_file walks a file's declarations and extracts type info
extract_types_from_file :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	file: ^ast.File,
	allocator := context.allocator,
) {
	if file == nil {
		return
	}

	for decl in file.decls {
		extract_type_from_decl(info, pkg, scope, decl, allocator)
	}
}

// extract_type_from_decl extracts type information from a declaration
extract_type_from_decl :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	decl: ^ast.Stmt,
	allocator := context.allocator,
) {
	if decl == nil {
		return
	}

	#partial switch d in decl.derived {
	case ^ast.Value_Decl:
		extract_from_value_decl(info, pkg, scope, d, allocator)
	case ^ast.When_Stmt:
		// Extract from both branches of when statements
		// This handles conditionally defined procedures like type_assertion_check
		extract_from_when_stmt(info, pkg, scope, d, allocator)
	}
}

// extract_from_when_stmt extracts declarations from both branches of a when statement
extract_from_when_stmt :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	when_stmt: ^ast.When_Stmt,
	allocator := context.allocator,
) {
	if when_stmt == nil {
		return
	}

	// Extract from body (true branch)
	if when_stmt.body != nil {
		if block, ok := when_stmt.body.derived.(^ast.Block_Stmt); ok {
			for stmt in block.stmts {
				extract_type_from_decl(info, pkg, scope, stmt, allocator)
			}
		}
	}

	// Extract from else branch (false branch)
	if when_stmt.else_stmt != nil {
		// else_stmt could be another When_Stmt (else when) or Block_Stmt (else)
		#partial switch else_body in when_stmt.else_stmt.derived {
		case ^ast.When_Stmt:
			extract_from_when_stmt(info, pkg, scope, else_body, allocator)
		case ^ast.Block_Stmt:
			for stmt in else_body.stmts {
				extract_type_from_decl(info, pkg, scope, stmt, allocator)
			}
		}
	}
}

// extract_from_value_decl handles value declarations (types, constants, procs)
extract_from_value_decl :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	decl: ^ast.Value_Decl,
	allocator := context.allocator,
) {
	if decl == nil || len(decl.names) == 0 {
		return
	}

	// Skip private declarations (start with _)
	for name_expr in decl.names {
		ident, ok := name_expr.derived.(^ast.Ident)
		if !ok {
			continue
		}
		name := ident.name
		if len(name) == 0 || name[0] == '_' {
			continue
		}

		// Check if this is a type definition
		if len(decl.values) > 0 {
			value := decl.values[0]
			if value != nil {
				extract_type_definition(info, pkg, scope, name, ident, value, allocator)
			}
		}
	}
}

// make_token_from_ident creates a tokenizer token from an AST identifier
make_token_from_ident :: proc(ident: ^ast.Ident) -> tokenizer.Token {
	return tokenizer.Token{
		kind = .Ident,
		text = ident.name,
		pos  = ident.pos,
	}
}

// extract_type_definition extracts a type definition and creates an entity
extract_type_definition :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	name: string,
	ident: ^ast.Ident,
	value: ^ast.Expr,
	allocator := context.allocator,
) {
	if value == nil {
		return
	}

	type: ^Type = nil
	is_procedure := false

	#partial switch v in value.derived {
	case ^ast.Struct_Type:
		type = extract_struct_type(info, scope, name, v, allocator)
	case ^ast.Enum_Type:
		type = extract_enum_type(info, scope, name, v, allocator)
	case ^ast.Union_Type:
		type = extract_union_type(info, scope, name, v, allocator)
	case ^ast.Proc_Lit:
		// Procedure definition - extract signature and create procedure entity
		type = extract_proc_type(info, scope, v, allocator)
		is_procedure = true
	case ^ast.Proc_Type:
		// Procedure type alias
		type = extract_proc_type_from_type(info, scope, v, allocator)
	case ^ast.Distinct_Type:
		// Distinct type
		type = extract_distinct_type(info, scope, name, v, allocator)
	case ^ast.Bit_Set_Type:
		type = extract_bit_set_type(info, scope, v, allocator)
	case ^ast.Proc_Group:
		// Procedure overload group - extract all procedures in the group
		extract_proc_group(info, pkg, scope, name, ident, v, allocator)
		return
	}

	if type != nil {
		token := make_token_from_ident(ident)
		if is_procedure {
			// Create procedure entity for procedure definitions
			entity := alloc_entity_procedure(scope, token, type, 0, allocator)
			entity.pkg = pkg
			entity.state = .Resolved
			scope_insert(scope, entity)
		} else {
			// Create type entity for type definitions
			entity := alloc_entity_type_name(scope, token, type, .Resolved, allocator)
			entity.pkg = pkg
			scope_insert(scope, entity)
		}
	}
}

// extract_struct_type creates a Type for a struct definition
extract_struct_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	name: string,
	st: ^ast.Struct_Type,
	allocator := context.allocator,
) -> ^Type {
	if st == nil {
		return nil
	}

	type := alloc_type(Type_Struct)
	type.kind = .Struct

	struct_info := &type.variant.(Type_Struct)
	struct_info.node = cast(^ast.Node)st
	struct_info.scope = create_scope(scope, allocator)
	struct_info.scope.flags += {.Type}
	struct_info.is_packed = st.is_packed
	struct_info.is_raw_union = st.is_raw_union

	// Extract fields
	if st.fields != nil {
		extract_struct_fields(info, struct_info, st.fields, allocator)
	}

	return type
}

// extract_struct_fields extracts field information from a struct
extract_struct_fields :: proc(
	info: ^Checker_Info,
	struct_info: ^Type_Struct,
	field_list: ^ast.Field_List,
	allocator := context.allocator,
) {
	if field_list == nil {
		return
	}

	for field in field_list.list {
		if field == nil {
			continue
		}

		// Get field type (simplified - just create a placeholder)
		field_type := t_untyped_nil // Placeholder - real type would need full resolution

		for name_expr in field.names {
			if ident, ok := name_expr.derived.(^ast.Ident); ok {
				token := make_token_from_ident(ident)
				entity := alloc_entity_variable(struct_info.scope, token, field_type, .Resolved, allocator)
				entity.flags += {.Field}
				append(&struct_info.fields, entity)

				// Add to struct scope
				scope_insert(struct_info.scope, entity)
			}
		}
	}
}

// extract_enum_type creates a Type for an enum definition
extract_enum_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	name: string,
	et: ^ast.Enum_Type,
	allocator := context.allocator,
) -> ^Type {
	if et == nil {
		return nil
	}

	type := alloc_type(Type_Enum)
	type.kind = .Enum

	enum_info := &type.variant.(Type_Enum)
	enum_info.node = cast(^ast.Node)et
	enum_info.scope = create_scope(scope, allocator)
	enum_info.scope.flags += {.Type}
	enum_info.base_type = t_int // Default base type

	// Extract enum fields - append directly to enum_info.fields
	if et.fields != nil {
		for field in et.fields {
			// The parser wraps EVERY enum member -- valued and bare alike -- in an
			// ast.Enum_Field_Value, mirroring Ast_EnumFieldValue (parser.cpp:920-929). This
			// used to branch on ^ast.Ident (bare) vs ^ast.Field_Value (valued); both arms are
			// now unreachable, so the two are merged into the single node the parser emits.
			// The name lives in `.name` regardless of whether `.value` is present.
			if efv, is_efv := field.derived.(^ast.Enum_Field_Value); is_efv && efv.name != nil {
				if fv_ident, fv_ident_ok := efv.name.derived.(^ast.Ident); fv_ident_ok {
					token := make_token_from_ident(fv_ident)
					entity := alloc_entity_constant(enum_info.scope, token, type, {}, allocator)
					append(&enum_info.fields, entity)
					scope_insert(enum_info.scope, entity)
				}
			}
		}
	}

	return type
}

// extract_union_type creates a Type for a union definition
extract_union_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	name: string,
	ut: ^ast.Union_Type,
	allocator := context.allocator,
) -> ^Type {
	if ut == nil {
		return nil
	}

	type := alloc_type(Type_Union)
	type.kind = .Union

	union_info := &type.variant.(Type_Union)
	union_info.node = cast(^ast.Node)ut
	union_info.scope = create_scope(scope, allocator)
	union_info.scope.flags += {.Type}

	// Union variants would need type resolution - leave empty for now
	// The important thing is the type exists and can be referenced

	return type
}

// extract_proc_type creates a Type for a procedure literal
extract_proc_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	pl: ^ast.Proc_Lit,
	allocator := context.allocator,
) -> ^Type {
	if pl == nil || pl.type == nil {
		return nil
	}

	return extract_proc_type_from_type(info, scope, pl.type, allocator)
}

// extract_proc_type_from_type creates a Type from a procedure type expression
extract_proc_type_from_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	pt: ^ast.Proc_Type,
	allocator := context.allocator,
) -> ^Type {
	if pt == nil {
		return nil
	}

	type := alloc_type(Type_Proc)
	type.kind = .Proc

	proc_info := &type.variant.(Type_Proc)
	proc_info.node = cast(^ast.Node)pt
	proc_info.scope = create_scope(scope, allocator)
	proc_info.scope.flags += {.Proc}

	// Extract parameter and result types would need full type resolution
	// For now, just mark it as a procedure type

	return type
}

// extract_type_alias handles type aliases (TypeName :: OtherType)
extract_type_alias :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	ident: ^ast.Ident,
	allocator := context.allocator,
) -> ^Type {
	// For type aliases, we'd need to resolve the referenced type
	// For now, return nil - the entity won't be created
	// This could be improved to look up builtin types
	return nil
}

// extract_distinct_type handles distinct type definitions
extract_distinct_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	name: string,
	dt: ^ast.Distinct_Type,
	allocator := context.allocator,
) -> ^Type {
	if dt == nil {
		return nil
	}

	// For distinct types, we need the base type
	// For now, create a placeholder Named type
	type := alloc_type(Type_Named)
	type.kind = .Named

	return type
}

// extract_bit_set_type handles bit_set type definitions
extract_bit_set_type :: proc(
	info: ^Checker_Info,
	scope: ^Scope,
	bst: ^ast.Bit_Set_Type,
	allocator := context.allocator,
) -> ^Type {
	if bst == nil {
		return nil
	}

	type := alloc_type(Type_Bit_Set)
	type.kind = .Bit_Set

	// Bit set details would need type resolution
	// For now, just mark it as a bit_set type

	return type
}

// extract_proc_group handles procedure overload groups
extract_proc_group :: proc(
	info: ^Checker_Info,
	pkg: ^ast.Package,
	scope: ^Scope,
	name: string,
	ident: ^ast.Ident,
	pg: ^ast.Proc_Group,
	allocator := context.allocator,
) {
	if pg == nil {
		return
	}

	// For proc groups, create a single procedure entity
	// The type can be any of the overloads - we just need the entity to exist
	// for dependency tracking purposes
	type := alloc_type(Type_Proc)
	type.kind = .Proc

	proc_info := &type.variant.(Type_Proc)
	proc_info.scope = create_scope(scope, allocator)
	proc_info.scope.flags += {.Proc}

	token := make_token_from_ident(ident)
	entity := alloc_entity_procedure(scope, token, type, 0, allocator)
	entity.pkg = pkg
	entity.state = .Resolved
	scope_insert(scope, entity)
}
