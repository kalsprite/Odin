package checker

/*
Documentation generation helpers for the checker.

This module provides documentation string building, entity sorting for display,
and documentation output formatting. It ports logic from the C++ docs system.

C++ References:
- /mnt/c/odin/src/docs.cpp (main documentation logic)
- /mnt/c/odin/src/docs_format.cpp (binary format definitions)
- /mnt/c/odin/src/docs_writer.cpp (binary writer implementation)

Note: This initial port focuses on the core sorting and comparison logic.
The full binary writer and format printer implementations will be added as needed.
*/

import "core:fmt"
import "core:odin/ast"
import "core:slice"
import "core:strings"

// ======================================================================================
// ENTITY SORTING FOR DOCUMENTATION DISPLAY
// C++ Reference: /mnt/c/odin/src/docs.cpp:3-65
// ======================================================================================

// print_entity_kind_ordering defines sort order for entity kinds in documentation
// Entities with negative values are not printed
// C++ Reference: docs.cpp:3-15
print_entity_kind_ordering := [Entity_Kind]int {
	.Invalid      = -1, // C++ line 4
	.Constant     = 0, // C++ line 5
	.Variable     = 1, // C++ line 6
	.Type_Name    = 4, // C++ line 7
	.Procedure    = 2, // C++ line 8
	.Proc_Group   = 3, // C++ line 9
	.Builtin      = -1, // C++ line 10
	.Import_Name  = -1, // C++ line 11
	.Library_Name = -1, // C++ line 12
	.Nil          = -1, // C++ line 13
	.Label        = -1, // C++ line 14
	.Package_Name = -1, // Added for completeness
}

// print_entity_names defines display names for entity kinds
// C++ Reference: docs.cpp:16-28
print_entity_names := [Entity_Kind]string {
	.Invalid      = "", // C++ line 17
	.Constant     = "constants", // C++ line 18
	.Variable     = "variables", // C++ line 19
	.Type_Name    = "types", // C++ line 20
	.Procedure    = "procedures", // C++ line 21
	.Proc_Group   = "proc_group", // C++ line 22
	.Builtin      = "", // C++ line 23
	.Import_Name  = "import names", // C++ line 24
	.Library_Name = "library names", // C++ line 25
	.Nil          = "", // C++ line 26
	.Label        = "", // C++ line 27
	.Package_Name = "", // Added for completeness
}

// C++ Reference: docs.cpp:31-56
cmp_entities_for_printing :: proc(a: ^Entity, b: ^Entity) -> slice.Ordering {
	assert(a != nil) // C++ line 32
	assert(b != nil) // C++ line 33

	// C++ lines 37-47: Compare by package name first
	if a.pkg != b.pkg {
		if a.pkg == nil {
			return .Less // C++ line 39
		}
		if b.pkg == nil {
			return .Greater // C++ line 42
		}
		// C++ line 44: Compare package names
		cmp_pkg := strings.compare(a.pkg.name, b.pkg.name)
		if cmp_pkg < 0 do return .Less
		if cmp_pkg > 0 do return .Greater
		// If package names are equal but pointers differ, continue to next comparison
	}

	// C++ lines 49-51: Compare by entity kind ordering
	ox := print_entity_kind_ordering[a.kind]
	oy := print_entity_kind_ordering[b.kind]
	if ox != oy {
		return ox < oy ? .Less : .Greater
	}

	// C++ line 53: Compare by name
	cmp := strings.compare(a.token.text, b.token.text)
	if cmp < 0 do return .Less
	if cmp > 0 do return .Greater
	return .Equal
}

// C++ Reference: docs.cpp:58-64
cmp_ast_package_by_name :: proc(a: ^ast.Package, b: ^ast.Package) -> slice.Ordering {
	assert(a != nil) // C++ line 59
	assert(b != nil) // C++ line 60
	// C++ line 62: return string_compare(x->name, y->name);
	cmp := strings.compare(a.name, b.name)
	if cmp < 0 do return .Less
	if cmp > 0 do return .Greater
	return .Equal
}

// ======================================================================================
// DOCUMENTATION STRING HELPERS
// C++ Reference: /mnt/c/odin/src/docs.cpp:69-179, docs_writer.cpp:281-395
// ======================================================================================

// C++ Reference: docs.cpp:100-106, 77-86
// NOTE: Architectural divergence from C++:
// - C++ writes to stdout via gb_printf (global state)
// - Odin accepts writer parameter for flexibility and testability
// - Parameter order: indent first (matching C++), writer last
print_doc_line :: proc {
	print_doc_line_string,
	print_doc_line_formatted,
}

// C++ Reference: docs.cpp:69-75
print_doc_line_string :: proc(indent: i32, data: string, writer: ^strings.Builder) {
	// C++ line 101-103: Print indent tabs
	for _ in 0 ..< indent {
		strings.write_string(writer, "\t")
	}
	// C++ line 104: Write data
	strings.write_string(writer, data)
	// C++ line 105: Write newline
	strings.write_byte(writer, '\n')
}

// C++ Reference: docs.cpp:108-117
print_doc_line_formatted :: proc(indent: i32, fmt_str: string, writer: ^strings.Builder, args: ..any) {
	// C++ line 109-111: Print indent tabs
	for _ in 0 ..< indent {
		strings.write_string(writer, "\t")
	}
	// C++ line 112-115: Format and write
	fmt.sbprintf(writer, fmt_str, ..args)
	// C++ line 116: Write newline
	strings.write_byte(writer, '\n')
}

// C++ Reference: docs.cpp:118-123
print_doc_line_no_newline :: proc(indent: i32, data: string, writer: ^strings.Builder) {
	// C++ line 119-121: Print indent tabs
	for _ in 0 ..< indent {
		strings.write_string(writer, "\t")
	}
	// C++ line 91: Write data (no newline)
	strings.write_string(writer, data)
}

// Comment_Processing_Result tracks what was appended
Comment_Processing_Result :: struct {
	has_content: bool,
	line_count:  int,
}

// C++ Reference: docs.cpp:95-179, docs_writer.cpp:281-367
// This is a key function used both for printing and binary format generation
append_comment_group_string :: proc(indent: i32, buf: ^strings.Builder, g: ^ast.Comment_Group) -> Comment_Processing_Result {
	result := Comment_Processing_Result{}

	// C++ line 96-97: Null check
	if g == nil {
		return result
	}

	// C++ lines 99-107: Calculate total length
	total_len := 0
	for comment in g.list {
		total_len += len(comment.text)
		total_len += 1 // for \n
	}
	if total_len <= len(g.list) {
		return result
	}

	count := 0

	// C++ lines 110-172: Process each comment
	for comment_token in g.list {
		comment := comment_token.text

		// C++ lines 114-122: Detect comment style and strip delimiters
		slash_slash := false
		if len(comment) >= 2 {
			if comment[1] == '/' {
				// C++ line 115-118: //... style
				slash_slash = true
				comment = comment[2:]
			} else if comment[1] == '*' {
				// C++ line 119-121: /*...*/ style
				comment = comment[2:]
				if len(comment) >= 2 {
					comment = comment[:len(comment) - 2] // Remove closing */
				}
			}
		}

		// C++ lines 124-128: Ignore the first space
		if len(comment) > 0 && comment[0] == ' ' {
			comment = comment[1:]
		}

		// C++ lines 130-137: Skip special comment prefixes for // style
		if slash_slash {
			if strings.has_prefix(comment, "+") {
				continue // C++ line 132
			}
			if strings.has_prefix(comment, "@(") {
				continue // C++ line 135
			}
		}

		// C++ lines 139-171: Process comment content
		if slash_slash {
			// C++ line 140-141: Single line comment - write directly
			for _ in 0 ..< indent {
				strings.write_byte(buf, '\t')
			}
			strings.write_string(buf, comment)
			strings.write_byte(buf, '\n')
			count += 1
		} else {
			// C++ line 143-170: Multi-line comment - process line by line
			pos := 0
			for pos < len(comment) {
				// C++ line 145-149: Find end of line
				end := pos
				for end < len(comment) && comment[end] != '\n' {
					end += 1
				}

				// C++ line 151: Extract line
				line := comment[pos:end]
				pos = end + 1 // Skip the newline

				// C++ line 152-158: Check for empty lines
				trimmed_line := strings.trim_space(line)
				if len(trimmed_line) == 0 {
					if count == 0 {
						continue // C++ line 155-157: Skip leading empty lines
					}
				}

				// C++ lines 159-166: Remove "* " prefix from block comments
				if strings.has_prefix(line, "* ") {
					line = line[2:]
				}

				// C++ line 168-169: Write the line
				for _ in 0 ..< indent {
					strings.write_byte(buf, '\t')
				}
				strings.write_string(buf, line)
				strings.write_byte(buf, '\n')
				count += 1
			}
		}
	}

	// C++ lines 174-178: Add trailing newline if we wrote anything
	if count > 0 {
		strings.write_byte(buf, '\n')
		result.has_content = true
		result.line_count = count
		return result
	}

	return result
}

// ======================================================================================
// EXPRESSION TO STRING CONVERSION
// C++ Reference: docs.cpp:184-193
// ======================================================================================

// C++ Reference: docs.cpp:184-193
print_doc_expr :: proc(expr: ^ast.Node, writer: ^strings.Builder, short_form := false) {
	// C++ Reference: docs.cpp:186-192
	s := short_form ? expr_to_string_shorthand(expr) : expr_to_string(expr)
	defer delete(s)
	strings.write_string(writer, s)
}

// ======================================================================================
// PACKAGE DOCUMENTATION PRINTING
// C++ Reference: docs.cpp:195-307
// ======================================================================================

// C++ Reference: docs.cpp:195-307
print_doc_package :: proc(info: ^Checker_Info, pkg: ^ast.Package, writer: ^strings.Builder, show_docs := true) {
	// C++ line 196-198: Null check
	if pkg == nil {
		return
	}

	// C++ line 200: Print package name
	print_doc_line_string(0, fmt.tprintf("package %s", pkg.name), writer)

	// C++ lines 203-209: Print package-level docs from all files.
	//
	// sorted_files, not raw map iteration: C++ walks pkg->files, the array the checker sorted by
	// basename (checker.cpp:6052). When two files in a package both carry a package doc comment,
	// map order decided which was printed first -- core/container/queue emitted queue.odin's doc
	// ahead of mp_queue.odin's, where C++ emits them in basename order.
	for file in sorted_files(pkg.files) {
		if file != nil && file.pkg_decl != nil {
			pkg_decl := file.pkg_decl.derived.(^ast.Package_Decl)
			if pkg_decl != nil {
				append_comment_group_string(1, writer, pkg_decl.docs)
			}
		}
	}

	// C++ lines 211-293: Print entities from package scope
	if pkg.scope != nil {
		// C++ lines 212-239: Collect exported entities
		entities := make([dynamic]^Entity, context.temp_allocator)

		for _, e in pkg.scope.elements {
			// C++ lines 216-231: Filter by entity kind
			#partial switch e.kind {
			case .Invalid, .Builtin, .Nil, .Label:
				continue
			case .Constant, .Variable, .Type_Name, .Procedure, .Proc_Group, .Import_Name, .Library_Name:
				// Fine - these are printable
			case:
				continue
			}

			// C++ lines 232-234: Must belong to this package
			if e.pkg != pkg {
				continue
			}

			// C++ lines 235-237: Must be exported
			if !is_entity_exported(info, e) {
				continue
			}

			append(&entities, e)
		}

		// C++ line 240: Sort entities for display
		slice.sort_by_cmp(entities[:], cmp_entities_for_printing)

		// C++ lines 244-291: Print entities grouped by kind
		curr_entity_kind := Entity_Kind.Invalid
		for e in entities {
			// C++ lines 246-252: Print kind header when changing
			if curr_entity_kind != e.kind {
				if curr_entity_kind != .Invalid {
					print_doc_line_string(0, "", writer)
				}
				curr_entity_kind = e.kind
				print_doc_line_string(1, print_entity_names[e.kind], writer)
			}

			// C++ lines 254-265: Get decl info
			type_expr: ^ast.Expr = nil
			init_expr: ^ast.Expr = nil
			comment: ^ast.Comment_Group = nil
			docs: ^ast.Comment_Group = nil
			if e.decl_info != nil {
				type_expr = e.decl_info.type_expr
				init_expr = e.decl_info.init_expr
				comment = e.decl_info.comment
				docs = e.decl_info.docs
			}

			// C++ line 268: Print entity name (no newline yet)
			print_doc_line_no_newline(2, e.token.text, writer)

			// C++ lines 269-275: Print type if present
			if type_expr != nil {
				t := expr_to_string(type_expr)
				defer delete(t)
				fmt.sbprintf(writer, ": %s ", t)
			} else {
				strings.write_string(writer, " :")
			}

			// C++ lines 276-284: Print initializer
			if e.kind == .Variable {
				if init_expr != nil {
					strings.write_string(writer, "= ")
					print_doc_expr(init_expr, writer)
				}
			} else {
				strings.write_string(writer, ": ")
				if init_expr != nil {
					print_doc_expr(init_expr, writer)
				}
			}

			// C++ line 286: Newline after declaration
			strings.write_byte(writer, '\n')

			// C++ lines 288-290: Print docs if enabled
			if show_docs {
				append_comment_group_string(3, writer, docs)
			}
		}

		// C++ line 292: Trailing blank line
		print_doc_line_string(0, "", writer)
	}

	// C++ lines 295-305: Print package metadata
	if len(pkg.fullpath) != 0 {
		print_doc_line_string(0, "", writer)
		print_doc_line_string(1, "fullpath:", writer)
		print_doc_line_string(2, pkg.fullpath, writer)
		print_doc_line_string(1, "files:", writer)
		// C++ iterates pkg->files, which is an ARRAY that check_create_file_scopes has already
		// sorted by basename (checker.cpp:6052, `array_sort(pkg->files, sort_file_by_name)`).
		// The port's pkg.files is a MAP, so iterating it directly yielded hash order and the
		// file list came out in an order unrelated to C++'s -- deterministic under setarch -R,
		// but wrong. sorted_files applies exactly that comparator (basename, then fullpath as
		// the tie-break) and is already used at five other sites for this same reason.
		//
		// The filename is taken from file.fullpath, as C++ takes it from f->fullpath, rather
		// than from the map key.
		for file in sorted_files(pkg.files) {
			print_doc_line_string(2, filename_from_path(file.fullpath), writer)
		}
	}
}

// ======================================================================================
// TOP-LEVEL DOCUMENTATION GENERATION
// C++ Reference: docs.cpp:309-367
// ======================================================================================

// C++ Reference: docs.cpp:309-367
generate_documentation :: proc(checker: ^Checker, writer: ^strings.Builder) {
	info := &checker.info

	// C++ lines 312-345: Binary .odin-doc format
	// NOTE(DEFERRED): Binary format requires odin_doc_write implementation
	// if build_context.cmd_doc_flags has DocFormat flag, use binary writer
	// For now, always use plain text output

	// C++ lines 347-359: Collect packages to document
	pkgs := make([dynamic]^ast.Package, context.temp_allocator)

	all_packages := .All_Packages in build_context.cmd_doc_flags
	for _, pkg in info.packages {
		// C++ lines 350-358: Filter packages based on flags
		if all_packages || pkg.kind == .Init || pkg.is_extra {
			append(&pkgs, pkg)
		}
	}

	// C++ line 361: Sort packages by name
	slice.sort_by_cmp(pkgs[:], cmp_ast_package_by_name)

	// C++ lines 363-365: Print documentation for each package
	for pkg in pkgs {
		print_doc_package(info, pkg, writer)
	}
}

// ======================================================================================
// COMMENT GROUP UTILITIES
// ======================================================================================

// comment_group_has_content checks if a comment group has actual content
// Returns true if the comment group would produce non-empty output after processing
comment_group_has_content :: proc(g: ^ast.Comment_Group) -> bool {
	if g == nil {
		return false
	}

	// Quick check: if total length <= comment count, all comments are empty/whitespace
	total_len := 0
	for comment in g.list {
		total_len += len(comment.text)
	}

	return total_len > len(g.list)
}

// ======================================================================================
// BINARY FORMAT STRUCTURES (STUBBED FOR FUTURE IMPLEMENTATION)
// C++ Reference: /mnt/c/odin/src/docs_format.cpp:1-237
// ======================================================================================

// NOTE: The binary format (.odin-doc) structures are defined in docs_format.cpp
// These would need to be ported when implementing the binary writer:
//
// Key structures:
// - OdinDocHeader (magic string, version, size, hash)
// - OdinDocFile (package index, name)
// - OdinDocPosition (file, line, column, offset)
// - OdinDocType (kind, flags, name, custom align, elements, etc.)
// - OdinDocEntity (kind, flags, position, name, type, docs, attributes, etc.)
// - OdinDocPkg (fullpath, name, flags, docs, files, entries)
//
// The format version is currently 0.3.1 (C++ lines 16-18)
// Magic string: "odindoc\0" (C++ line 1)
//
// These structures support serialization of the entire AST type system
// including polymorphic types, procedure signatures, struct layouts, etc.

// ======================================================================================
// BINARY WRITER (STUBBED FOR FUTURE IMPLEMENTATION)
// C++ Reference: /mnt/c/odin/src/docs_writer.cpp:1-1175
// ======================================================================================

// NOTE: The binary writer implementation is complex and involves:
//
// 1. Two-pass writing (preparation + writing)
//    - First pass: Calculate sizes and build string cache
//    - Second pass: Write actual data to buffer
//
// 2. String deduplication via string_cache (docs_writer.cpp:212-226)
//
// 3. Type deduplication via type_cache using type hashes (docs_writer.cpp:482-762)
//
// 4. Entity tracking and dependency resolution (docs_writer.cpp:764-1000)
//
// 5. Scope entry generation for package exports (docs_writer.cpp:1004-1053)
//
// 6. Hash computation over the entire output (docs_writer.cpp:125-135)
//
// Key functions to port when implementing binary format:
// - odin_doc_writer_prepare (initialization)
// - odin_doc_write_string (string dedup)
// - odin_doc_type (type serialization)
// - odin_doc_add_entity (entity serialization)
// - odin_doc_update_entities (link entities to types)
// - odin_doc_add_pkg_entries (package scope export)
// - odin_doc_write_to_file (final output)
//
// The implementation would need careful handling of:
// - Offset calculations and alignment
// - Pointer-to-index conversions
// - Recursive type structures
// - Entity dependency graphs

// ======================================================================================
// FUTURE WORK
// ======================================================================================

// The following features require implementation:
//
// NOTE(DEFERRED): Binary documentation format is not part of core semantic analysis
// Remaining work:
// 1. Build context cmd_doc_flags (CmdDocFlag_Short, CmdDocFlag_DocFormat, CmdDocFlag_AllPackages)
// 2. Binary .odin-doc writer (docs_writer.odin) - see docs_writer.cpp:1-1175
// 3. odin_doc_write function for binary output
