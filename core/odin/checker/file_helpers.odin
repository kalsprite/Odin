package checker

/*
File helper functions for accessing file-level metadata.

These helpers provide safe access to file metadata stored in external maps.
C++ stores this data directly on AstFile, but since core:odin/ast.File is immutable,
we use external maps in Checker_Info.

C++ Reference: /mnt/c/odin/src/parser.hpp:107-173 - struct AstFile
*/

import "core:odin/ast"

// get_file_scope retrieves the scope associated with a file
// C++ Reference: checker.cpp:5723 - f->scope
get_file_scope :: proc(info: ^Checker_Info, file: ^ast.File) -> ^Scope {
	return info.file_scopes[file]
}

// set_file_scope associates a scope with a file
// C++ Reference: checker.cpp:5723 - f->scope = s
set_file_scope :: proc(info: ^Checker_Info, file: ^ast.File, scope: ^Scope) {
	info.file_scopes[file] = scope
}

// get_file_from_node retrieves the file that contains a given AST node
// C++ Reference: parser.hpp:868-871 - Ast::file() method using global_files[this->file_id]
//
// This deliberately does NOT go through node.file_id / info.files_by_id. In C++ the parser
// stamps every node with the id of the file it came from (Ast::file_id, set in alloc_ast_node),
// so global_files[file_id] is a sound lookup. core:odin/parser assigns neither ast.File.id nor
// ast.Node.file_id - both are left at their zero value - so files_by_id degenerates to a single
// entry under key 0 holding whichever file was registered last, and every node in the program
// resolves to that one arbitrary file. That is worse than failing: check_intrinsics_entry_point_usage
// used it to ask "is this node in base:runtime?", got a foreign file back, and reported
// `usage of intrinsics.__entry_point will be a no-op` against base/runtime/entry_unix.odin in
// every package that transitively pulls the runtime in.
//
// The tokenizer does record the owning file on every position (parser.odin:150 initialises it
// with file.fullpath), and info.files is keyed by exactly that string, so pos.file is an
// equivalent and actually-populated identity. Resolving through it restores the C++ property
// without needing to change the shared parser.
get_file_from_node :: proc(info: ^Checker_Info, node: ^ast.Node) -> ^ast.File {
	if node == nil {
		return nil
	}
	if file, ok := info.files[node.pos.file]; ok {
		return file
	}
	return nil
}

// NOTE: File flag operations (get_file_flags, set_file_flags, has_file_flag, etc.) and
// vet/feature flag operations are now in build_infrastructure.odin to consolidate
// all file flag and package kind operations in one place.

// get_delayed_imports retrieves the delayed import queue for a file
// C++ Reference: parser.hpp:162 - delayed_decls_queues[AstDelayQueue_Import]
get_delayed_imports :: proc(info: ^Checker_Info, file: ^ast.File) -> [dynamic]^ast.Stmt {
	if file == nil {
		return {}
	}
	return file.delayed_decls_import
}

// add_delayed_import adds an import statement to the delayed processing queue
// C++ Reference: parser.hpp:162 - array_add(&f->delayed_decls_queues[AstDelayQueue_Import], stmt)
add_delayed_import :: proc(info: ^Checker_Info, file: ^ast.File, stmt: ^ast.Stmt) {
	if file == nil {
		return
	}
	append(&file.delayed_decls_import, stmt)
}

// get_delayed_foreign_blocks retrieves the delayed foreign block queue for a file
// C++ Reference: parser.hpp:162 - delayed_decls_queues[AstDelayQueue_ForeignBlock]
get_delayed_foreign_blocks :: proc(info: ^Checker_Info, file: ^ast.File) -> [dynamic]^ast.Stmt {
	if file == nil {
		return {}
	}
	return file.delayed_decls_foreign_block
}

// add_delayed_foreign_block adds a foreign block to the delayed processing queue
// C++ Reference: parser.hpp:162 - array_add(&f->delayed_decls_queues[AstDelayQueue_ForeignBlock], stmt)
add_delayed_foreign_block :: proc(info: ^Checker_Info, file: ^ast.File, stmt: ^ast.Stmt) {
	if file == nil {
		return
	}
	append(&file.delayed_decls_foreign_block, stmt)
}

// get_delayed_exprs retrieves the delayed expression queue for a file
// C++ Reference: parser.hpp:162 - delayed_decls_queues[AstDelayQueue_Expr]
get_delayed_exprs :: proc(info: ^Checker_Info, file: ^ast.File) -> [dynamic]^ast.Expr {
	if file == nil {
		return {}
	}
	return file.delayed_decls_expr
}

// add_delayed_expr adds an expression to the delayed processing queue
// C++ Reference: parser.hpp:162 - array_add(&f->delayed_decls_queues[AstDelayQueue_Expr], expr)
add_delayed_expr :: proc(info: ^Checker_Info, file: ^ast.File, expr: ^ast.Expr) {
	if file == nil {
		return
	}
	append(&file.delayed_decls_expr, expr)
}

// clear_delayed_imports clears the delayed import queue for a file
// Used after processing delayed declarations
clear_delayed_imports :: proc(info: ^Checker_Info, file: ^ast.File) {
	if file == nil {
		return
	}
	clear(&file.delayed_decls_import)
}

// clear_delayed_foreign_blocks clears the delayed foreign block queue for a file
// Used after processing delayed declarations
clear_delayed_foreign_blocks :: proc(info: ^Checker_Info, file: ^ast.File) {
	if file == nil {
		return
	}
	clear(&file.delayed_decls_foreign_block)
}

// clear_delayed_exprs clears the delayed expression queue for a file
// Used after processing delayed declarations
clear_delayed_exprs :: proc(info: ^Checker_Info, file: ^ast.File) {
	if file == nil {
		return
	}
	clear(&file.delayed_decls_expr)
}
