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
// Uses node.file_id to index into the files_by_id map
get_file_from_node :: proc(info: ^Checker_Info, node: ^ast.Node) -> ^ast.File {
	if node == nil {
		return nil
	}
	if file, ok := info.files_by_id[node.file_id]; ok {
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
