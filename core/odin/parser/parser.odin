// The `Odin` file parser to be used in tooling.
package odin_parser

import "core:odin/ast"
import "core:odin/tokenizer"

import "core:fmt"
import "core:strconv"

Warning_Handler :: #type proc(pos: tokenizer.Pos, fmt: string, args: ..any)
Error_Handler   :: #type proc(pos: tokenizer.Pos, fmt: string, args: ..any)

// Error_Line_Handler emits an unpositioned continuation line beneath the diagnostic just
// reported -- C++'s error_line, used to attach Suggestion/Note text.
//
// It is a SEPARATE type from Error_Handler because a continuation line has no position of its
// own; giving it one would sort it away from the diagnostic it belongs to.
Error_Line_Handler :: #type proc(fmt: string, args: ..any)

// Error_Block_Handler brackets a diagnostic and its continuation lines, so that the
// continuations attach to it instead of being flushed on their own.
//
// C++ Reference: ERROR_BLOCK() in src/error.cpp -- a scoped begin/end pair. The port's
// error_line only appends while an error value is live, and its syntax_error pops one
// immediately, so WITHOUT this bracket a parse-stage Suggestion fell through to a direct
// stderr write and came out ahead of everything else, unsorted. LEDGER #307.
Error_Block_Handler :: #type proc()

// Error_Range_Handler reports a diagnostic that SPANS a node, so the caret can underline the
// whole construct rather than marking a single column.
//
// LEDGER #322. C++'s `syntax_error` is overloaded, and the `Ast *` overload carries the node's
// range. The port's `error` takes a bare Pos and is used at all 174 parser call sites, so every
// diagnostic C++ anchors to a NODE rendered one column wide. Measured across src/parser.cpp's
// syntax_error first arguments, roughly 27 of ~150 sites are node-anchored (type/stmt/node/expr);
// the rest pass tokens and already matched, which is why the corpus sat at 124 FULL-MATCH with
// this outstanding.
//
// This is a SEPARATE handler rather than a wider Error_Handler because Error_Handler is declared
// in the TOKENIZER package and shared with the tokenizer's own diagnostics; widening it would
// churn three packages to serve the parser. The same reasoning, and the same shape, as the
// err_line / err_block pair added in #307.
Error_Range_Handler :: #type proc(pos, end: tokenizer.Pos, fmt: string, args: ..any)

Flag :: enum u32 {
	Optional_Semicolons,
}

Flags :: distinct bit_set[Flag; u32]


Parser :: struct {
	file: ^ast.File,
	tok: tokenizer.Tokenizer,

	// If .Optional_Semicolons is true, semicolons are completely as statement terminators
	// different to .Insert_Semicolon in tok.flags
	flags: Flags,

	warn: Warning_Handler,
	err:  Error_Handler,
	// Continuation lines, and the bracket that makes them attach. Supplied by the driver like
	// `err` and the build-level inputs below; all nil means continuations are simply not
	// emitted, which is what every pre-existing consumer of this package gets. #307.
	err_line:        Error_Line_Handler,
	err_block_begin: Error_Block_Handler,
	err_block_end:   Error_Block_Handler,
	err_range:       Error_Range_Handler, // LEDGER #322

	prev_tok: tokenizer.Token,
	curr_tok: tokenizer.Token,

	// >= 0: In Expression
	// <  0: In Control Clause
	// NOTE(bill): Used to prevent type literals in control clauses
	expr_level:       int,
	allow_range:      bool, // NOTE(bill): Ranges are only allowed in certain cases
	allow_in_expr:    bool, // NOTE(bill): in expression are only allowed in certain cases
	in_foreign_block: bool,
	allow_type:       bool,
	allow_newline:    bool, // NOTE(bill): Only valid for expr_level == 0. C++ parser.hpp:138

	// The build-level inputs to file_allow_newline. C++ reads these from the global
	// build_context; this package has none, so the driver supplies them.
	// C++ Reference: src/parser.cpp:42 file_allow_newline
	strict_style:     bool,           // build_context.strict_style
	vet_flags:        ast.Vet_Flags,  // build_context.vet_flags -- the fallback when a file sets none
	disallow_do:      bool,           // build_context.disallow_do (#211) -- read by parse_do_body

	lead_comment: ^ast.Comment_Group,
	line_comment: ^ast.Comment_Group,

	curr_proc: ^ast.Node,

	error_count: int,

	fix_count: int,
	fix_prev_pos: tokenizer.Pos,

	peeking: bool,
}

MAX_FIX_COUNT :: 10

Stmt_Allow_Flag :: enum {
	In,
	Label,
}
Stmt_Allow_Flags :: distinct bit_set[Stmt_Allow_Flag]


Import_Decl_Kind :: enum {
	Standard,
	Using,
}



default_warning_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	fmt.eprintf("%s(%d:%d): Warning: ", pos.file, pos.line, pos.column)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}
default_error_handler :: proc(pos: tokenizer.Pos, msg: string, args: ..any) {
	fmt.eprintf("%s(%d:%d): ", pos.file, pos.line, pos.column)
	fmt.eprintf(msg, ..args)
	fmt.eprintf("\n")
}

warn :: proc(p: ^Parser, pos: tokenizer.Pos, msg: string, args: ..any) {
	if p.warn != nil {
		p.warn(pos, msg, ..args)
	}
	p.file.syntax_warning_count += 1
}

error :: proc(p: ^Parser, pos: tokenizer.Pos, msg: string, args: ..any) {
	if p.err != nil {
		p.err(pos, msg, ..args)
	}
	p.file.syntax_error_count += 1
	p.error_count += 1
}

// error_node reports a diagnostic spanning `node`, matching C++'s `syntax_error(Ast *, ...)`.
// LEDGER #322 -- see Error_Range_Handler.
//
// FALLS BACK to the position-only handler when err_range is unset, so a host that has not wired
// the new handler still gets the diagnostic, just with the old single-column caret. Silently
// dropping it would be far worse than a narrow caret.
error_node :: proc(p: ^Parser, node: ^ast.Node, msg: string, args: ..any) {
	if node == nil {
		return
	}
	if p.err_range != nil {
		p.err_range(node.pos, node.end, msg, ..args)
	} else if p.err != nil {
		p.err(node.pos, msg, ..args)
	}
	p.file.syntax_error_count += 1
	p.error_count += 1
}


end_pos :: proc(tok: tokenizer.Token) -> tokenizer.Pos {
	pos := tok.pos
	pos.offset += len(tok.text)

	if (tok.kind == .Comment && tok.text[:2] == "/*") || (tok.kind == .String && tok.text[:1] == "`") {
		for i := 0; i < len(tok.text); i += 1 {
			c := tok.text[i]
			if c == '\n' {
				pos.line += 1
				pos.column = 1
			} else {
				pos.column += 1
			}
		}
	} else {
		pos.column += len(tok.text)
	}
	return pos
}

default_parser :: proc(flags := Flags{.Optional_Semicolons}) -> Parser {
	return Parser {
		flags = flags,
		err  = default_error_handler,
		warn = default_warning_handler,
	}
}

is_package_name_reserved :: proc(name: string) -> bool {
	switch name {
	case "builtin", "intrinsics":
		return true
	}
	return false
}

parse_file :: proc(p: ^Parser, file: ^ast.File) -> bool {
	zero_parser: {
		p.prev_tok         = {}
		p.curr_tok         = {}
		p.expr_level       = 0
		p.allow_range      = false
		p.allow_in_expr    = false
		p.in_foreign_block = false
		p.allow_type       = false
		p.lead_comment     = nil
		p.line_comment     = nil
	}

	p.tok.flags += {.Insert_Semicolon}

	p.file = file
	tokenizer.init(&p.tok, file.src, file.fullpath, p.err)
	if p.tok.ch <= 0 {
		return true
	}


	advance_token(p)
	consume_comment_groups(p, p.prev_tok)

	docs := p.lead_comment

	invalid_pre_package_token: Maybe(tokenizer.Token)

	for p.curr_tok.kind != .Package && p.curr_tok.kind != .EOF {
		if p.curr_tok.kind == .Comment {
			consume_comment_groups(p, p.prev_tok)
		} else if p.curr_tok.kind == .File_Tag {
			append(&p.file.tags, p.curr_tok)
			advance_token(p)
		} else {
			if invalid_pre_package_token == nil {
				invalid_pre_package_token = p.curr_tok
			}

			advance_token(p)
		}
	}

	if p.curr_tok.kind != .Package {
		t := invalid_pre_package_token.? or_else p.curr_tok
		// C++ opens an ERROR_BLOCK here (parser.cpp:6857) so the Suggestion below attaches to
		// the diagnostic rather than being flushed on its own.
		if p.err_block_begin != nil {
			p.err_block_begin()
		}
		defer if p.err_block_end != nil {
			p.err_block_end()
		}
		// C++ Reference: src/parser.cpp:6856-6868. "beginning", not "start" -- the port's
		// wording was its own (LEDGER #307).
		error(p, t.pos, "Expected a package declaration at the beginning of the file")
		// C++ Reference: src/parser.cpp:6864-6867, inside the same ERROR_BLOCK.
		//
		// THE ORACLE IS NONDETERMINISTIC HERE, and C++ says so itself at 6863: "this is
		// technically a race condition with the suggestion, but it's only a suggestion so in
		// practice it should be 'fine'". pkg->name is written by whichever file finishes
		// parsing first, and C++ parses a package's files in parallel. Measured over 20 oracle
		// runs each:
		//     vt_nopkg   (the only file, package-less)          --  0/20 emit the Suggestion
		//     vt_nopkg2  (package-less a.odin, valid b.odin)    --  3/20
		//     vt_nopkg3  (valid a.odin, package-less z.odin)    -- 19/20
		// The port parses a package's files sequentially in sorted order, so `pkg.name != ""`
		// resolves deterministically to "a valid file sorts earlier" -- which is the MAJORITY
		// oracle answer in all three shapes (0/20 no, 3/20 no, 19/20 yes). Same disposition as
		// LEDGER #197: where the reference itself is order-dependent, reproduce the dominant
		// order rather than the coin flip.
		if p.err_line != nil && p.file != nil && p.file.pkg != nil && p.file.pkg.name != "" {
			p.err_line("\tSuggestion: Add 'package %s' to the top of the file\n", p.file.pkg.name)
		}
		return false
	}
	
	p.file.pkg_token = expect_token(p, .Package)
	
	if ippt, ok := invalid_pre_package_token.?; ok {
		error(p, ippt.pos, "Expected only comments or lines starting with '#+' before the package declaration")
		return false
	}
	
	pkg_name := expect_token_after(p, .Ident, "package")
	if pkg_name.kind == .Ident {
		switch name := pkg_name.text; {
		case is_blank_ident(name):
			error(p, pkg_name.pos, "Invalid package name '_'")
		case is_package_name_reserved(name), file.pkg != nil && file.pkg.kind != .Runtime && name == "runtime":
			error(p, pkg_name.pos, "Use of reserved package name '%s'", name)
		}
	}
	p.file.pkg_name = pkg_name.text

	pd := ast.new(ast.Package_Decl, pkg_name.pos, end_pos(p.prev_tok))
	pd.docs    = docs
	pd.token   = p.file.pkg_token
	pd.name    = pkg_name.text
	pd.comment = p.line_comment
	p.file.pkg_decl = pd
	p.file.docs = docs

	expect_semicolon(p, pd)

	if p.file.syntax_error_count > 0 {
		return false
	}

	p.file.decls = make([dynamic]^ast.Stmt)

	for p.curr_tok.kind != .EOF {
		stmt := parse_stmt(p)
		if stmt != nil {
			if _, ok := stmt.derived.(^ast.Empty_Stmt); !ok {
				append(&p.file.decls, stmt)
				if es, es_ok := stmt.derived.(^ast.Expr_Stmt); es_ok && es.expr != nil {
					if _, pl_ok := es.expr.derived.(^ast.Proc_Lit); pl_ok {
						error_node(p, stmt, "Procedure literal evaluated but not used")
					}
				}
			}
		}
	}

	// C++ parser.cpp:6930 -- the post-parse file-scope walk, run once f->decls is complete.
	parse_setup_file_decls(p, p.file.decls[:])

	return true
}

// C++ parser.hpp:923 is_ast_decl -- gb_is_between(kind, Ast__DeclBegin+1, Ast__DeclEnd-1).
//
// The C++ range is BadDecl, ForeignBlockDecl, Label, ValueDecl, PackageDecl, ImportDecl,
// ForeignImportDecl. Label has no node in this port (see the note at ast.odin:1269, from #250),
// so it is absent here for that reason and not by oversight.
is_ast_decl :: proc(node: ^ast.Node) -> bool {
	#partial switch _ in node.derived {
	case ^ast.Bad_Decl, ^ast.Foreign_Block_Decl, ^ast.Value_Decl,
	     ^ast.Package_Decl, ^ast.Import_Decl, ^ast.Foreign_Import_Decl:
		return true
	}
	return false
}

// C++ parser.cpp:6267-6285 -- parse_setup_file_when_stmt.
//
// This recursion is load-bearing, not decoration: a file-scope `when` body is a Block_Stmt whose
// statements never appear in f->decls, so without it the file-scope gate below simply does not see
// them. Probe c26_when (`f()` inside `when true { }`) is the case that distinguishes the two.
parse_setup_file_when_stmt :: proc(p: ^Parser, ws: ^ast.When_Stmt) {
	if ws.body != nil {
		if bs, ok := ws.body.derived.(^ast.Block_Stmt); ok {
			parse_setup_file_decls(p, bs.stmts)
		}
	}

	if ws.else_stmt != nil {
		#partial switch e in ws.else_stmt.derived {
		case ^ast.Block_Stmt:
			parse_setup_file_decls(p, e.stmts)
		case ^ast.When_Stmt:
			parse_setup_file_when_stmt(p, e)
		}
	}
}

// C++ parser.cpp:6286-6368 -- parse_setup_file_decls.
//
// NOTE ON SCOPE. C++'s version also resolves import and foreign-import paths, via
// determine_path_from_string / try_add_import_path, and rewrites offending decls to ast_bad_decl.
// This port resolves import paths in the CHECKER instead (package_resolver.odin), so that half is
// deliberately NOT reproduced here -- moving resolution into the parser is a separate change with
// its own risk. What IS reproduced is the file-scope declaration gate, the #directive exemption
// that feeds file.directive_count, and the `when` recursion. The remaining path VALIDATION
// ("Invalid import path", "No foreign paths found") is still outstanding; see the ledger.
//
// The sibling diagnostic in the checker (check_collect.odin, "Only declarations are allowed at
// file scope" with no ", got %s" suffix) is C++'s checker.cpp:5241 and is faithful -- the two are
// separate messages in separate stages, not duplicates.
parse_setup_file_decls :: proc(p: ^Parser, decls: []^ast.Stmt) {
	for node in decls {
		if node == nil {
			continue
		}

		is_gate_exempt := is_ast_decl(node)
		if !is_gate_exempt {
			#partial switch _ in node.derived {
			case ^ast.When_Stmt, ^ast.Bad_Stmt, ^ast.Empty_Stmt:
				is_gate_exempt = true
			}
		}

		if !is_gate_exempt {
			// NOTE(bill): Sanity check
			if es, ok := node.derived.(^ast.Expr_Stmt); ok && es.expr != nil {
				if ce, ce_ok := es.expr.derived.(^ast.Call_Expr); ce_ok && ce.expr != nil {
					if _, bd_ok := ce.expr.derived.(^ast.Basic_Directive); bd_ok {
						p.file.directive_count += 1
						continue
					}
				}
			}

			error_node(p, node, "Only declarations are allowed at file scope, got %s", ast.node_kind_string(node))
		} else if id, id_ok := node.derived.(^ast.Import_Decl); id_ok {
			// C++ parser.cpp:6305-6312. This runs BEFORE determine_path_from_string, on the raw
			// token text, which is why it can live here even though this port resolves import
			// paths in the checker rather than the parser.
			original_string := path_string_from_token(id.relpath)
			if is_import_path_absolute(original_string) {
				error_node(p, node, "Invalid import path: '%s'", original_string)
			}
		} else if fl, fl_ok := node.derived.(^ast.Foreign_Import_Decl); fl_ok {
			// C++ parser.cpp:6315-6331.
			if len(fl.fullpaths) == 0 {
				error_node(p, node, "No foreign paths found")
			} else if !fl.multiple_filepaths && len(fl.fullpaths) == 1 {
				if bl, bl_ok := fl.fullpaths[0].derived.(^ast.Basic_Lit); bl_ok {
					file_str := path_string_from_token(bl.tok)
					if is_import_path_absolute(file_str) {
						error_node(p, node, "Invalid import path: '%s'", file_str)
					}
				}
			}
		} else if ws, ws_ok := node.derived.(^ast.When_Stmt); ws_ok {
			parse_setup_file_when_stmt(p, ws)
		}
	}
}

// C++ parser.cpp:6057 -- is_import_path_absolute.
//
// Both rules apply unconditionally; neither is gated on the host platform. The reference compiler
// rejects a Windows-style drive path while running on Linux, which probe c27_winimp verifies
// against the oracle rather than against this reading.
is_import_path_absolute :: proc(path: string) -> bool {
	if len(path) > 0 && path[0] == '/' {
		return true
	}
	if len(path) > 2 &&
	   ((path[0] >= 'a' && path[0] <= 'z') || (path[0] >= 'A' && path[0] <= 'Z')) &&
	   path[1] == ':' &&
	   (path[2] == '/' || path[2] == '\\') {
		return true
	}
	return false
}

// The path text as the two call sites above need it: delimiters removed, then whitespace trimmed,
// matching C++'s string_trim_whitespace(string_value_from_token(...)).
//
// NOT a full equivalent of string_value_from_token, which routes through exact_value_from_token and
// therefore processes escape sequences. Only the delimiters are stripped here. That is sufficient
// for both callers -- the absolute-path test reads at most the first three bytes, and the message
// prints the path as written -- but an import path containing escapes would print differently from
// the reference. No such path exists in the corpus; recorded rather than papered over.
path_string_from_token :: proc(tok: tokenizer.Token) -> string {
	s := tok.text
	if len(s) >= 2 && (s[0] == '"' || s[0] == '`') && s[len(s) - 1] == s[0] {
		s = s[1:len(s) - 1]
	}
	// Trimmed inline rather than via core:strings, to leave this package's import set alone --
	// core:odin/parser is a tooling dependency and this is the only site that would need it.
	is_space :: proc(c: byte) -> bool {
		switch c {
		case ' ', '\t', '\r', '\n', '\v', '\f':
			return true
		}
		return false
	}
	for len(s) > 0 && is_space(s[0]) {
		s = s[1:]
	}
	for len(s) > 0 && is_space(s[len(s) - 1]) {
		s = s[:len(s) - 1]
	}
	return s
}

peek_token_kind :: proc(p: ^Parser, kind: tokenizer.Token_Kind, lookahead := 0) -> (ok: bool) {
	prev_parser := p^
	p.peeking = true

	defer {
		p^ = prev_parser
		p.peeking = false
	}

	p.tok.err = nil
	for i := 0; i <= lookahead; i += 1 {
		advance_token(p)
	}
	ok = p.curr_tok.kind == kind

	return
}

peek_token :: proc(p: ^Parser, lookahead := 0) -> (tok: tokenizer.Token) {
	prev_parser := p^
	p.peeking = true

	defer {
		p^ = prev_parser
		p.peeking = false
	}

	p.tok.err = nil
	for i := 0; i <= lookahead; i += 1 {
		advance_token(p)
	}
	tok = p.curr_tok
	return
}
skip_possible_newline :: proc(p: ^Parser) -> bool {
	if tokenizer.is_newline(p.curr_tok) {
		advance_token(p)
		return true
	}
	return false
}

skip_possible_newline_for_literal :: proc(p: ^Parser) -> bool {
	if .Optional_Semicolons not_in p.flags {
		return false
	}

	curr_pos := p.curr_tok.pos
	if tokenizer.is_newline(p.curr_tok) {
		next := peek_token(p)
		if curr_pos.line+1 >= next.pos.line {
			#partial switch next.kind {
			case .Open_Brace, .Else, .Where:
				advance_token(p)
				return true
			}
		}
	}

	return false
}


next_token0 :: proc(p: ^Parser) -> bool {
	p.curr_tok = tokenizer.scan(&p.tok)
	if p.curr_tok.kind == .EOF {
		// error(p, p.curr_tok.pos, "Token is EOF");
		return false
	}
	return true
}

consume_comment :: proc(p: ^Parser) -> (tok: tokenizer.Token, end_line: int) {
	tok = p.curr_tok
	assert(tok.kind == .Comment)
	end_line = tok.pos.line

	if tok.text[1] == '*' {
		for c in tok.text {
			if c == '\n' {
				end_line += 1
			}
		}
	}

	// C++ Reference: parser.cpp:1444-1460. C++ commits end_line BEFORE advancing and never
	// adjusts it afterwards:
	//
	//     if (end_line_) *end_line_ = end_line;
	//     next_token0(f);
	//
	// The port advanced first and then added `if curr.line > tok.line { end_line += 1 }`, which
	// C++ has no counterpart for. end_line means "the line the comment group ENDS on"; bumping
	// it to the line of whatever token follows makes it one too high in the ordinary case (any
	// comment not followed by a token on its own line). That inflation was then partly cancelled
	// by consume_comment_groups testing `end_line+1 >= curr.line` instead of C++'s `==`, so the
	// pair happened to agree with C++ for a comment directly above a declaration and to disagree
	// when a blank line separated them -- attaching a visually detached comment as documentation.
	// Both deviations have to go together; removing either alone inverts the behaviour.
	_ = next_token0(p)

	return
}

consume_comment_group :: proc(p: ^Parser, n: int) -> (comments: ^ast.Comment_Group, end_line: int) {
	list: [dynamic]tokenizer.Token
	end_line = p.curr_tok.pos.line
	for p.curr_tok.kind == .Comment &&
	    p.curr_tok.pos.line <= end_line+n {
		comment: tokenizer.Token
		comment, end_line = consume_comment(p)
		append(&list, comment)
	}

	if len(list) > 0 && !p.peeking {
		comments = ast.new(ast.Comment_Group, list[0].pos, end_pos(list[len(list)-1]))
		comments.list = list[:]
		append(&p.file.comments, comments)
	}

	return
}

consume_comment_groups :: proc(p: ^Parser, prev: tokenizer.Token) {
	if p.curr_tok.kind != .Comment {
		return
	}
	comment: ^ast.Comment_Group
	end_line := 0

	if p.curr_tok.pos.line == prev.pos.line {
		comment, end_line = consume_comment_group(p, 0)
		if p.curr_tok.pos.line != end_line ||
		   p.curr_tok.pos.line == prev.pos.line+1 ||
		   p.curr_tok.kind == .EOF {
			p.line_comment = comment
		}
	}

	end_line = -1
	for p.curr_tok.kind == .Comment {
		comment, end_line = consume_comment_group(p, 1)
	}
	// C++ Reference: parser.cpp:1509. `==`, not `>=`: the group attaches as a lead comment only
	// when it ends on the line immediately above the token. See consume_comment for why this and
	// the `end_line += 1` there were a compensating pair.
	if end_line+1 == p.curr_tok.pos.line || end_line < 0 {
		p.lead_comment = comment
	}

	assert(p.curr_tok.kind != .Comment)
}

advance_token :: proc(p: ^Parser) -> tokenizer.Token {
	p.lead_comment = nil
	p.line_comment = nil
	p.prev_tok = p.curr_tok
	prev := p.prev_tok

	if next_token0(p) {
		#partial switch p.curr_tok.kind {
		case .Comment:
			consume_comment_groups(p, prev)
			if p.curr_tok.kind == .Semicolon && p.expr_level > 0 && p.curr_tok.text == "\n" {
				advance_token(p)
			}
		case .Semicolon:
			if p.expr_level > 0 && p.curr_tok.text == "\n" {
				advance_token(p)
			}
		}
	}
	return prev
}

expect_token :: proc(p: ^Parser, kind: tokenizer.Token_Kind) -> tokenizer.Token {
	prev := p.curr_tok
	if prev.kind != kind {
		e := tokenizer.to_string(kind)
		g := tokenizer.token_to_string(prev)
		// C++ Reference: src/parser.cpp:1619. casescan could not pair this one: the port had
		// two literals normalising to the same key and C++ has two variants, so it was
		// reported as ambiguous and skipped. expect_token is C++'s quoted form.
		error(p, prev.pos, "Expected '%s', got '%s'", e, g)
	}
	advance_token(p)
	return prev
}

expect_token_after :: proc(p: ^Parser, kind: tokenizer.Token_Kind, msg: string) -> tokenizer.Token {
	prev := p.curr_tok
	if prev.kind != kind {
		e := tokenizer.to_string(kind)
		g := tokenizer.token_to_string(prev)
		error(p, prev.pos, "Expected '%s' after %s, got '%s'", e, msg, g)
	}
	advance_token(p)
	return prev
}

// is_token_range mirrors C++ src/parser.cpp:1672-1683.
is_token_range :: proc(kind: tokenizer.Token_Kind) -> bool {
	#partial switch kind {
	case .Ellipsis, .Range_Full, .Range_Half:
		return true
	}
	return false
}

expect_operator :: proc(p: ^Parser) -> tokenizer.Token {
	prev := p.curr_tok
	#partial switch prev.kind {
	case .If, .When, .Or_Else:
		// okay
	case:
		if !tokenizer.is_operator(prev.kind) {
			g := tokenizer.token_to_string(prev)
			error(p, prev.pos, "Expected an operator, got '%s'", g)
		} else if !p.allow_range && is_token_range(prev.kind) {
			// C++ Reference: src/parser.cpp:1699-1703. An ELSE-IF of the operator test, so a
			// non-operator reports only the first message. The port had neither this nor the
			// ellipsis check below.
			//
			// NOTE(parity): C++ writes "an non-range" -- reproduced verbatim, same treatment
			// as #187/#189/#195.
			g := tokenizer.token_to_string(prev)
			error(p, prev.pos, "Expected an non-range operator, got '%s'", g)
		}
	}

	// C++ Reference: src/parser.cpp:1704-1707. A SEPARATE `if`, not an else -- an ellipsis in
	// a non-range position produces BOTH this and the message above.
	//
	// Odin retired the inclusive `..` in favour of `..=`, and C++ keeps this to guide anyone
	// using the old spelling. The port had no such diagnostic at all, so `bit_set[5 .. 2]`
	// reported the unhelpful "'bit_set[5 .. 2]' is not a type" instead. Probes iv1/iv2.
	//
	// NOT PORTED: C++ also sets TokenFlag_Replace on the token, consumed by its source-fixup
	// tooling. The port's tokenizer has no such flag and the checker has no fixup pass, so
	// there is nothing to set it for.
	if prev.kind == .Ellipsis {
		error(p, prev.pos, "'..' for ranges are not allowed, did you mean '..<' or '..='?")
	}

	advance_token(p)
	return prev
}

allow_token :: proc(p: ^Parser, kind: tokenizer.Token_Kind) -> bool {
	if p.curr_tok.kind == kind {
		advance_token(p)
		return true
	}
	return false
}

end_of_line_pos :: proc(p: ^Parser, tok: tokenizer.Token) -> tokenizer.Pos {
	offset := clamp(tok.pos.offset, 0, len(p.tok.src)-1)
	s := p.tok.src[offset:]
	pos := tok.pos
	pos.column -= 1
	for len(s) != 0 && s[0] != 0 && s[0] != '\n' {
		s = s[1:]
		pos.column += 1
	}
	return pos
}

// C++ Reference: src/parser.cpp:18-32, 42-45.
//
// ast_file_vet_flags prefers the file's own `#+vet` tag and falls back to the build-level
// flags. See #210: this parser collects File_Tag tokens into file.tags but never interprets
// them, so file.vet_flags_set is always false here and the fallback always wins. The lookup
// is written in its C++ shape anyway, so it becomes correct the moment tags are interpreted.
file_vet_flags :: proc(p: ^Parser) -> ast.Vet_Flags {
	if p.file != nil && p.file.vet_flags_set {
		return p.file.vet_flags
	}
	return p.vet_flags
}

file_allow_newline :: proc(p: ^Parser) -> bool {
	is_strict := p.strict_style || .Style in file_vet_flags(p)
	return !is_strict
}

// allow_field_separator is C++ src/parser.cpp:4388. It had NEVER been ported.
//
// Twelve C++ call sites route their list separator through it; the port instead spelled
// a bare comma-only accept at eleven of them and grew one private, divergent
// reimplementation (`expect_field_separator`, nested inside parse_field_list) at the twelfth.
//
// What the missing logic does: a newline-inserted semicolon IS a legal separator, but only
// when newlines are allowed for this file AND the very next token closes the list. That is
// what makes
//
//	f(1,
//	  2
//	)
//
// legal Odin. The port rejected it with "Expected ')', got 'newline'" -- an over-rejection of
// ordinary formatting (probe an1). In the other direction, a newline separator followed by
// anything else is an error C++ raises and the port did not.
allow_field_separator :: proc(p: ^Parser) -> bool {
	token := p.curr_tok
	if allow_token(p, .Comma) {
		return true
	}
	if token.kind == .Semicolon {
		ok := false
		if file_allow_newline(p) && tokenizer.is_newline(token) {
			#partial switch peek_token(p).kind {
			case .Close_Brace, .Close_Paren:
				ok = true
			}
		}
		if !ok {
			str := tokenizer.token_to_string(token)
			error(p, end_of_line_pos(p, p.prev_tok), "Expected a comma, got a %s", str)
		}
		advance_token(p)
		return true
	}
	return false
}

// expect_closing mirrors C++ src/parser.cpp:1805-1817.
//
// C++ has THREE closing helpers that are NOT interchangeable, and the port had collapsed them:
//   expect_closing_brace_of_field_list (1722) -- "Expected a comma, got a %s", then expect_token
//   expect_closing                     (1805) -- "Missing ',' before newline in %s", then expect_token
//   expect_token_after                 (1645) -- "Expected '%s' after %s, got '%s'"
//
// The distinction that matters: the first two end in a PLAIN expect_token, so their failure
// message carries NO context. The port routed everything through expect_token_after, which
// folds the context in -- so `f(1 ..< 2)` said "Expected ')' after argument list, got '..<'"
// where C++ says "Expected ')', got '..<'". Probe rng7.
//
// The missing-comma branch below is gated on p.allow_newline (#209 / progress#189 added the
// field). Note that the token is skipped either way -- allow_newline decides only whether the
// skip is announced.
expect_closing :: proc(p: ^Parser, kind: tokenizer.Token_Kind, context_name: string) -> tokenizer.Token {
	// C++'s second disjunct (`|| f->curr_token.kind == Token_EOF`) is dead -- a token cannot
	// be both Semicolon and EOF -- and is left out rather than reproduced.
	if p.curr_tok.kind != kind &&
	   p.curr_tok.kind == .Semicolon &&
	   p.curr_tok.text == "\n" {
		if p.allow_newline {
			tok := p.prev_tok
			pos := tok.pos
			pos.column += len(tok.text)
			error(p, pos, "Missing ',' before newline in %s", context_name)
		}
		advance_token(p)
	}
	return expect_token(p, kind)
}


// parse_check_directive_for_statement is C++ src/parser.cpp:2226-2300. It had NEVER been ported
// (LEDGER #304): neither of its statement-list messages appeared anywhere in core/odin/parser.
//
// C++ routes FOUR directives through it from the Token_Hash arm of parse_operand (2492-2504) --
// bounds_check, no_bounds_check, type_assert, no_type_assert -- each as
//     Ast *operand = parse_expr(f, lhs);
//     return parse_check_directive_for_statement(operand, name, StateFlag_...);
// The port had arms for the two bounds_check names that set the state flag and checked the
// conflict pair, but performed NO statement-kind validation, and had no arms at all for
// type_assert / no_type_assert.
//
// Consequences measured before the fix:
//   `v := #bounds_check x.(int)`   oracle 1 diagnostic, port 0   <-- UNDER-REJECTION
//   `v := #type_assert  x.(int)`   oracle "may only be applied to the following statements: ...",
//                                  port "Expected ';', got identifier" at a different column
//
// The conflict-pair check the port already had IS C++'s (2246/2251), not invented -- verified
// before preserving it, since #252 and #266 are precedents for invented extras.
@(private="file")
parse_check_directive_for_statement :: proc(p: ^Parser, s: ^ast.Node, tag_token: tokenizer.Token, state_flag: Maybe(ast.Node_State_Flag)) -> ^ast.Node {
	name := tag_token.text
	if s == nil {
		error(p, tag_token.pos, "Invalid operand for #%s", name)
		return nil
	}

	// C++ 2234-2240: an empty statement gets its own two messages, and the newline form is
	// distinguished from an explicit ';'. ast.Empty_Stmt now retains its token so this is
	// reproducible -- it previously stored only the position.
	if es, is_empty := s.derived.(^ast.Empty_Stmt); is_empty {
		if es.token.text == "\n" {
			error(p, tag_token.pos, "#%s cannot be followed by a newline", name)
		} else {
			error(p, tag_token.pos, "#%s cannot be applied to an empty statement \';\'", name)
		}
	}

	// C++ 2242-2245: applying the same directive twice is an error, and the flag is set
	// regardless so the conflict test below sees it.
	// C++ passes state_flag == 0 from the #partial EmptyStmt case (parser.cpp:5528). With 0,
	// `s->state_flags & 0` is false, `|= 0` is a no-op, and neither the conflict switch nor the
	// statement-kind switch has a matching case -- so ONLY the empty-statement message above
	// fires. Maybe(...) reproduces that: nil skips everything below.
	flag, has_flag := state_flag.?
	if !has_flag {
		return s
	}

	if flag in s.state_flags {
		error(p, tag_token.pos, "#%s has been applied multiple times", name)
	}
	s.state_flags += {flag}

	// C++ 2246-2266: the two mutually exclusive pairs.
	#partial switch flag {
	case .Bounds_Check:
		if .No_Bounds_Check in s.state_flags {
			error(p, tag_token.pos, "#bounds_check and #no_bounds_check cannot be applied together")
		}
	case .No_Bounds_Check:
		if .Bounds_Check in s.state_flags {
			error(p, tag_token.pos, "#bounds_check and #no_bounds_check cannot be applied together")
		}
	case .Type_Assert:
		if .No_Type_Assert in s.state_flags {
			error(p, tag_token.pos, "#type_assert and #no_type_assert cannot be applied together")
		}
	case .No_Type_Assert:
		if .Type_Assert in s.state_flags {
			error(p, tag_token.pos, "#type_assert and #no_type_assert cannot be applied together")
		}
	}

	// C++ 2268-2298: the statement-kind whitelist. Ported in FULL -- an omitted kind would
	// wrongly REJECT valid code, which is worse than the silent acceptance this replaces.
	#partial switch d in s.derived {
	case ^ast.Block_Stmt, ^ast.If_Stmt, ^ast.When_Stmt, ^ast.For_Stmt, ^ast.Range_Stmt,
	     ^ast.Unroll_Range_Stmt, ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt, ^ast.Return_Stmt,
	     ^ast.Defer_Stmt, ^ast.Assign_Stmt:
		// Okay
	case ^ast.Value_Decl:
		if !d.is_mutable {
			error(p, tag_token.pos, "#%s may only be applied to a variable declaration, and not a constant value declaration", name)
		}
	case:
		error(p, tag_token.pos, "#%s may only be applied to the following statements: \'{{}}\', \'if\', \'when\', \'for\', \'switch\', \'return\', \'defer\', assignment, variable declaration", name)
	}

	return s
}

expect_closing_brace_of_field_list :: proc(p: ^Parser) -> tokenizer.Token {
	return expect_closing_token_of_field_list(p, .Close_Brace, "field list")
}

// C++ Reference: src/parser.cpp:1722 expect_closing_brace_of_field_list.
//
// C++ consumes a possible newline first, but ONLY when f->allow_newline; with newlines
// disallowed the newline-semicolon falls through to the `allow_token(Semicolon)` arm and is
// reported. The port had no allow_newline, so it hard-coded "a newline is never an error
// here" and could not report it under -strict-style.
expect_closing_token_of_field_list :: proc(p: ^Parser, closing_kind: tokenizer.Token_Kind, msg: string) -> tokenizer.Token {
	token := p.curr_tok
	if allow_token(p, closing_kind) {
		return token
	}
	ok := true
	if p.allow_newline {
		ok = !skip_possible_newline(p)
	}
	if ok && allow_token(p, .Semicolon) {
		str := tokenizer.token_to_string(token)
		error(p, end_of_line_pos(p, p.prev_tok), "Expected a comma, got a %s", str)
	}
	// C++ Reference: src/parser.cpp:1734 -- the function ends with a bare
	//     return expect_token(f, Token_CloseBrace);
	// i.e. "Expected '}'", with NO trailing context and NO recovery scan. The port used
	// expect_token_after(..., "field list"), producing "Expected '}' after field list", and
	// then ran a token-skipping loop that C++ does not have. Two symptoms, one site (LEDGER
	// #251): the wrong message, and one fewer diagnostic line -- the loop consumed tokens up
	// to the next closer/EOF/semicolon, swallowing whatever C++ would have gone on to report.
	// Note the port's own comment at parser.odin:573 already recorded C++ as "then
	// expect_token"; the code had drifted from its own citation.
	return expect_token(p, closing_kind)
}

// C++ Reference: src/parser.cpp:4155-4160 (parse_proc_type) and 4026-4030 (parse_results).
// C++ has no helper here at all -- it inlines exactly two steps:
//
//	if (file_allow_newline(f)) { skip_possible_newline(f); }
//	expect_token_after(f, Token_CloseParen, "parameter list");
//
// The port had grown an invented one: an early accept, a semicolon-consuming "expected a
// comma" error C++ never raises for a parameter list, and a skip-to-close recovery loop.
// Replaced with C++'s behaviour; the wrapper survives only so the call site is unchanged.
expect_closing_parentheses_of_field_list :: proc(p: ^Parser) -> tokenizer.Token {
	if file_allow_newline(p) {
		skip_possible_newline(p)
	}
	return expect_token_after(p, .Close_Paren, "parameter list")
}

is_non_inserted_semicolon :: proc(tok: tokenizer.Token) -> bool {
	return tok.kind == .Semicolon && tok.text != "\n"
}

is_blank_ident :: proc{
	is_blank_ident_string,
	is_blank_ident_token,
	is_blank_ident_node,
}
is_blank_ident_string :: proc(str: string) -> bool {
	return str == "_"
}
is_blank_ident_token :: proc(tok: tokenizer.Token) -> bool {
	if tok.kind == .Ident {
		return is_blank_ident_string(tok.text)
	}
	return false
}
is_blank_ident_node :: proc(node: ^ast.Node) -> bool {
	if ident, ok := node.derived.(^ast.Ident); ok {
		return is_blank_ident(ident.name)
	}
	return true
}

fix_advance_to_next_stmt :: proc(p: ^Parser) {
	for {
		#partial switch t := p.curr_tok; t.kind {
		case .EOF, .Semicolon:
			return

		case .Package, .Foreign, .Import,
		     .If, .For, .When, .Return, .Switch,
		     .Defer, .Using,
		     .Break, .Continue, .Fallthrough,
		     .Hash:


			if t.pos == p.fix_prev_pos && p.fix_count < MAX_FIX_COUNT {
				p.fix_count += 1
				return
			}
			if t.pos.offset < p.fix_prev_pos.offset {
				p.fix_prev_pos = t.pos
				p.fix_count = 0
				return
			}
		}
		advance_token(p)
	}
}


is_semicolon_optional_for_node :: proc(p: ^Parser, node: ^ast.Node) -> bool {
	if node == nil {
		return false
	}

	if .Optional_Semicolons in p.flags {
		return true
	}

	#partial switch n in node.derived {
	case ^ast.Empty_Stmt, ^ast.Block_Stmt:
		return true

	case ^ast.If_Stmt, ^ast.When_Stmt,
	     ^ast.For_Stmt, ^ast.Range_Stmt, ^ast.Inline_Range_Stmt,
	     ^ast.Switch_Stmt, ^ast.Type_Switch_Stmt:
		return true

	case ^ast.Helper_Type:
		return is_semicolon_optional_for_node(p, n.type)
	case ^ast.Distinct_Type:
		return is_semicolon_optional_for_node(p, n.type)
	case ^ast.Pointer_Type:
		return is_semicolon_optional_for_node(p, n.elem)
	case ^ast.Struct_Type, ^ast.Union_Type, ^ast.Enum_Type, ^ast.Bit_Set_Type, ^ast.Bit_Field_Type:
		// Require semicolon within a procedure body
		return p.curr_proc == nil
	case ^ast.Proc_Lit:
		return true

	case ^ast.Package_Decl, ^ast.Import_Decl, ^ast.Foreign_Import_Decl:
		return true

	case ^ast.Foreign_Block_Decl:
		return is_semicolon_optional_for_node(p, n.body)

	case ^ast.Value_Decl:
		if n.is_mutable {
			return false
		}
		if len(n.values) > 0 {
			return is_semicolon_optional_for_node(p, n.values[len(n.values)-1])
		}
	}

	return false
}

expect_semicolon_newline_error :: proc(p: ^Parser, token: tokenizer.Token, s: ^ast.Node) {
	if .Optional_Semicolons not_in p.flags && .Insert_Semicolon in p.tok.flags && token.text == "\n" {
		#partial switch token.kind {
		case .Close_Brace:
		case .Close_Paren:
		case .Else:
			return
		}
		if is_semicolon_optional_for_node(p, s) {
			return
		}

		tok := token
		tok.pos.column -= 1
		// C++ Reference: src/parser.cpp:4731. Missed by the earlier case scan because its
		// extractor desynchronised on a rune literal at parser.odin:2210 (LEDGER 339).
		error(p, tok.pos, "Expected ';', got newline")
	}
}


expect_semicolon :: proc(p: ^Parser, node: ^ast.Node) -> bool {
	// C++ Reference: src/parser.cpp:1849-1884 (expect_semicolon), reproduced structurally.
	//
	// C++ takes NO node argument and has no node-aware logic anywhere -- grep for
	// "semicolon_optional" in src/ returns nothing. Its rule is only:
	//
	//     allow ';'                                        -> ok
	//     curr is '}' or ')' on the SAME LINE as prev      -> ok
	//     prev was ';'                                     -> ok
	//     curr is EOF                                      -> ok
	//     curr on the SAME LINE as prev                    -> ERROR
	//     (curr on a later line                            -> ok, optional-semicolon rule)
	//
	// The newline case needs no special handling because the tokenizer emits a
	// Semicolon("\n") token for it, which the first branch consumes.
	//
	// The port had an invented `is_semicolon_optional_for_node` layer whose FIRST line is
	// `if .Optional_Semicolons in p.flags { return true }` -- and default_parser sets exactly
	// that flag, so on every call with a non-nil node the semicolon was waived outright and
	// the elaborate switch beneath it was dead code. Instrumentation (LEDGER 330) showed the
	// split precisely: `x := 1 y := 2` passes node=nil and IS caught, while `S{a=1}` as a
	// statement passes node=Any_Node and was let through, so the port accepted `S` as a
	// complete statement and parsed `{a=1}` as a block.
	//
	// `node` is retained only so the ~40 call sites need not change; C++ ignores it and so
	// do we.
	_ = node

	if allow_token(p, .Semicolon) {
		expect_semicolon_newline_error(p, p.prev_tok, node)
		return true
	}

	#partial switch p.curr_tok.kind {
	case .Close_Brace, .Close_Paren:
		if p.curr_tok.pos.line == p.prev_tok.pos.line {
			return true
		}
	}

	prev := p.prev_tok
	if prev.kind == .Semicolon {
		expect_semicolon_newline_error(p, p.prev_tok, node)
		return true
	}

	if p.curr_tok.kind == .EOF {
		return true
	}

	if p.curr_tok.pos.line == prev.pos.line {
		// C++ Reference: parser.cpp:1879 moves to the END of the previous token, so the
		// caret lands where the semicolon belonged (progress#175).
		error(p, end_pos(prev), "Expected ';', got %s", tokenizer.token_to_string(p.curr_tok))
		fix_advance_to_next_stmt(p)
		return false
	}
	return true
}

new_blank_ident :: proc(p: ^Parser, pos: tokenizer.Pos) -> ^ast.Ident {
	tok: tokenizer.Token
	tok.pos = pos
	i := ast.new(ast.Ident, pos, end_pos(tok))
	i.name = "_"
	return i
}

parse_ident :: proc(p: ^Parser) -> ^ast.Ident {
	tok := p.curr_tok
	pos := tok.pos
	name := "_"
	if tok.kind == .Ident {
		name = tok.text
		advance_token(p)
	} else {
		expect_token(p, .Ident)
	}
	i := ast.new(ast.Ident, pos, end_pos(tok))
	i.name = name
	return i
}

parse_stmt_list :: proc(p: ^Parser) -> []^ast.Stmt {
	list: [dynamic]^ast.Stmt
	for p.curr_tok.kind != .Case &&
	    p.curr_tok.kind != .Close_Brace &&
	    p.curr_tok.kind != .EOF  {
		stmt := parse_stmt(p)
		if stmt != nil {
			if _, ok := stmt.derived.(^ast.Empty_Stmt); !ok {
				append(&list, stmt)
				if es, es_ok := stmt.derived.(^ast.Expr_Stmt); es_ok && es.expr != nil {
					if _, pl_ok := es.expr.derived.(^ast.Proc_Lit); pl_ok {
						error_node(p, stmt, "Procedure literal evaluated but not used")
					}
				}
			}
		}
	}
	return list[:]
}

parse_block_stmt :: proc(p: ^Parser, is_when: bool) -> ^ast.Stmt {
	skip_possible_newline_for_literal(p)
	if !is_when && p.curr_proc == nil {
		error(p, p.curr_tok.pos, "You cannot use a block statement in the file scope")
	}
	return parse_body(p)
}

parse_when_stmt :: proc(p: ^Parser) -> ^ast.When_Stmt {
	tok := expect_token(p, .When)

	cond: ^ast.Expr
	body: ^ast.Stmt
	else_stmt: ^ast.Stmt

	prev_level := p.expr_level
	p.expr_level = -1
	prev_allow_in_expr := p.allow_in_expr
	p.allow_in_expr = true

	cond = parse_expr(p, false)

	p.allow_in_expr = prev_allow_in_expr
	p.expr_level = prev_level

	if cond == nil {
		error(p, p.curr_tok.pos, "expected a condition for when statement")
	}
	if allow_token(p, .Do) {
		// C++ Reference: src/parser.cpp:4856
		body = parse_do_body(p, do_body_token(cond, tok), "then when statement")
	} else {
		body = parse_block_stmt(p, true)
	}

	skip_possible_newline_for_literal(p)
	if p.curr_tok.kind == .Else {
		else_tok := expect_token(p, .Else)
		#partial switch p.curr_tok.kind {
		case .When:
			else_stmt = parse_when_stmt(p)
		case .Open_Brace:
			else_stmt = parse_block_stmt(p, true)
		case .Do:
			expect_token(p, .Do)
			// C++ Reference: src/parser.cpp:4877
			else_stmt = parse_do_body(p, else_tok, "'else'")
		case:
			error(p, p.curr_tok.pos, "Expected when statement block statement")
			else_stmt = ast.new(ast.Bad_Stmt, p.curr_tok.pos, end_pos(p.curr_tok))
		}
	}

	end := body.end
	if else_stmt != nil {
		end = else_stmt.end
	}
	when_stmt := ast.new(ast.When_Stmt, tok.pos, end)
	when_stmt.when_pos  = tok.pos
	when_stmt.cond      = cond
	when_stmt.body      = body
	when_stmt.else_stmt = else_stmt
	return when_stmt
}

convert_stmt_to_expr :: proc(p: ^Parser, stmt: ^ast.Stmt, kind: string) -> ^ast.Expr {
	if stmt == nil {
		return nil
	}
	if es, ok := stmt.derived.(^ast.Expr_Stmt); ok {
		return es.expr
	}
	// C++ parser.cpp:2120 anchors at f->curr_token, NOT at the statement. The port used stmt.pos,
	// which points at where the simple statement STARTED rather than where the parser gave up.
	// For `for x := 0 x < 3 {` the reference reports at the closing brace and the port reported at
	// the init -- same text, same count, different anchor (probe nb_forsemi). Note the Bad_Expr
	// below already used p.curr_tok, so the two were inconsistent with each other as well.
	error(p, p.curr_tok.pos, "Expected '%s', found a simple statement.", kind)
	return ast.new(ast.Bad_Expr, p.curr_tok.pos, end_pos(p.curr_tok))
}

parse_if_stmt :: proc(p: ^Parser) -> ^ast.If_Stmt {
	tok := expect_token(p, .If)

	init: ^ast.Stmt
	cond: ^ast.Expr
	body: ^ast.Stmt
	else_stmt: ^ast.Stmt

	prev_level := p.expr_level
	p.expr_level = -1
	prev_allow_in_expr := p.allow_in_expr
	p.allow_in_expr = true
	if allow_token(p, .Semicolon) {
		cond = parse_expr(p, false)
	} else {
		init = parse_simple_stmt(p, nil)
		if parse_control_statement_semicolon_separator(p) {
			cond = parse_expr(p, false)
		} else {
			cond = convert_stmt_to_expr(p, init, "boolean expression")
			init = nil
		}
	}

	p.expr_level = prev_level
	p.allow_in_expr = prev_allow_in_expr

	if cond == nil {
		error(p, p.curr_tok.pos, "expected a condition for if statement")

	}
	if allow_token(p, .Do) {
		// C++ Reference: src/parser.cpp:4786
		body = parse_do_body(p, do_body_token(cond, tok), "the if statement")
	} else {
		body = parse_block_stmt(p, false)
	}

	else_tok := p.curr_tok.pos

	skip_possible_newline_for_literal(p)
	if p.curr_tok.kind == .Else {
		else_tok := expect_token(p, .Else)
		#partial switch p.curr_tok.kind {
		case .If:
			else_stmt = parse_if_stmt(p)
		case .Open_Brace:
			else_stmt = parse_block_stmt(p, false)
		case .Do:
			expect_token(p, .Do)
			// C++ Reference: src/parser.cpp:4819. The port reported at body.pos here -- the
			// position of the IF body, not the else body. Copy-paste slip; C++ reports at the
			// body parse_do_body just built.
			else_stmt = parse_do_body(p, else_tok, "'else'")
		case:
			error(p, p.curr_tok.pos, "Expected if statement block statement")
			else_stmt = ast.new(ast.Bad_Stmt, p.curr_tok.pos, end_pos(p.curr_tok))
		}
	}
	
	end: tokenizer.Pos
	if body != nil {
		end = body.end
	}
	if else_stmt != nil {
		end = else_stmt.end
	}
	if_stmt := ast.new(ast.If_Stmt, tok.pos, end)
	if_stmt.if_pos  = tok.pos
	if_stmt.init      = init
	if_stmt.cond      = cond
	if_stmt.body      = body
	if_stmt.else_stmt = else_stmt
	if_stmt.else_pos = else_tok
	return if_stmt
}

// C++ Reference: src/parser.cpp:4727-4739.
//
// #213: the port had C++'s control flow but not its diagnostic. When the separator position
// holds a newline-INSERTED semicolon (kind Semicolon, text "\n") rather than a written one,
// C++ reports it; the port silently accepted. Shared by all three control statements --
// `if`, `for` and `switch` -- via the call sites below. Probe do3.
parse_control_statement_semicolon_separator :: proc(p: ^Parser) -> bool {
	tok := peek_token(p)
	if tok.kind != .Open_Brace {
		if p.curr_tok.kind == .Semicolon && p.curr_tok.text != ";" {
			error(p, end_of_line_pos(p, p.prev_tok), "Expected ';', got newline")
		}
		return allow_token(p, .Semicolon)
	}
	if p.curr_tok.text == ";" {
		return allow_token(p, .Semicolon)
	}
	return false
}

parse_for_stmt :: proc(p: ^Parser) -> ^ast.Stmt {
	if p.curr_proc == nil {
		error(p, p.curr_tok.pos, "You cannot use a for statement in the file scope")
	}

	tok := expect_token(p, .For)

	init: ^ast.Stmt
	cond: ^ast.Stmt
	post: ^ast.Stmt
	body: ^ast.Stmt
	is_range := false

	general_conds: if p.curr_tok.kind != .Open_Brace && p.curr_tok.kind != .Do {
		prev_level := p.expr_level
		defer p.expr_level = prev_level
		p.expr_level = -1

		if p.curr_tok.kind == .In {
			in_tok := expect_token(p, .In)
			rhs: ^ast.Expr

			prev_allow_range := p.allow_range
			p.allow_range = true
			rhs = parse_expr(p, false)
			p.allow_range = prev_allow_range

			if allow_token(p, .Do) {
				// C++ Reference: src/parser.cpp:4950
				body = parse_do_body(p, tok, "the for statement")
			} else {
				body = parse_body(p)
			}

			range_stmt := ast.new(ast.Range_Stmt, tok.pos, body)
			range_stmt.for_pos = tok.pos
			range_stmt.in_pos = in_tok.pos
			range_stmt.expr = rhs
			range_stmt.body = body
			return range_stmt
		}

		if p.curr_tok.kind != .Semicolon {
			cond = parse_simple_stmt(p, {Stmt_Allow_Flag.In})
			if as, ok := cond.derived.(^ast.Assign_Stmt); ok && as.op.kind == .In {
				is_range = true
			}
		}

		if !is_range && parse_control_statement_semicolon_separator(p) {
			init = cond
			cond = nil


			if p.curr_tok.kind == .Open_Brace || p.curr_tok.kind == .Do {
				// C++ parser.cpp:4970 names the `x in y` alternative; the port's wording dropped
				// that clause, which is the part that tells the reader what else is allowed here.
				error(p, p.curr_tok.pos, "Expected ';', followed by a condition expression and post statement, or 'x in y' style loop, got %s", tokenizer.tokens[p.curr_tok.kind])
			} else {
				if p.curr_tok.kind != .Semicolon {
					if p.curr_tok.kind == .Ident {
						next_token := peek_token(p)
						if next_token.kind == .In || next_token.kind == .Comma {
							cond = parse_simple_stmt(p, {.In})
							if as, ok := cond.derived_stmt.(^ast.Assign_Stmt); ok {
								assert(as.op.kind == .In)
								is_range = true
							}
							break general_conds
						}
					}

					cond = parse_simple_stmt(p, nil)
				}

				if p.curr_tok.text != ";" {
					error(p, p.curr_tok.pos, "Expected ';', got %s", tokenizer.token_to_string(p.curr_tok))
				} else {
					expect_semicolon(p, nil)
				}

				if p.curr_tok.kind != .Open_Brace && p.curr_tok.kind != .Do {
					post = parse_simple_stmt(p, nil)
				}
			}
		}
	}

	if allow_token(p, .Do) {
		// C++ Reference: src/parser.cpp:5005
		body = parse_do_body(p, tok, "the for statement")
	} else {
		allow_token(p, .Semicolon)
		body = parse_body(p)
	}


	if is_range {
		assign_stmt := cond.derived.(^ast.Assign_Stmt)
		vals := assign_stmt.lhs[:]

		rhs: ^ast.Expr
		if len(assign_stmt.rhs) > 0 {
			rhs = assign_stmt.rhs[0]
		}

		range_stmt := ast.new(ast.Range_Stmt, tok.pos, body)
		range_stmt.for_pos = tok.pos
		range_stmt.init = init
		range_stmt.vals = vals
		range_stmt.in_pos = assign_stmt.op.pos
		range_stmt.expr = rhs
		range_stmt.body = body
		return range_stmt
	}

	cond_expr := convert_stmt_to_expr(p, cond, "boolean expression")
	// C++ parser.cpp:5022-5026. `for init; ; { }` -- an init with neither condition nor post
	// statement -- is rejected with a suggested rewrite. The port had no equivalent and accepted
	// it silently (probe nd_forsemi2). Anchored at `init`, as C++ does, NOT at the `for` keyword.
	if init != nil && cond_expr == nil && post == nil {
		// Braces are DOUBLED: this string goes through Odin's fmt, where `{` opens a format verb.
		// Left single they print "%!(MISSING ARGUMENT)%!(MISSING CLOSE BRACE)" -- exactly the
		// mangling #211 fixed in four other messages, and it caught me again here. Both `{` in
		// this text are literal.
		error(p, init.pos, "'for init; ; {{' without an explicit condition nor post statement is not allowed, please prefer something like 'for init; true; /**/{{'")
	}
	for_stmt := ast.new(ast.For_Stmt, tok.pos, body)
	for_stmt.for_pos = tok.pos
	for_stmt.init = init
	for_stmt.cond = cond_expr
	for_stmt.post = post
	for_stmt.body = body
	return for_stmt
}

parse_case_clause :: proc(p: ^Parser, is_type_switch: bool) -> ^ast.Case_Clause {
	tok := expect_token(p, .Case)

	list: []^ast.Expr

	if p.curr_tok.kind != .Colon {
		prev_allow_range, prev_allow_in_expr := p.allow_range, p.allow_in_expr
		defer p.allow_range, p.allow_in_expr = prev_allow_range, prev_allow_in_expr
		p.allow_range, p.allow_in_expr = !is_type_switch, !is_type_switch

		list = parse_rhs_expr_list(p)
	}

	terminator := expect_token(p, .Colon)

	stmts := parse_stmt_list(p)

	cc := ast.new(ast.Case_Clause, tok.pos, end_pos(p.prev_tok))
	cc.list = list
	cc.terminator = terminator
	cc.body = stmts
	cc.case_pos = tok.pos
	return cc
}

parse_switch_stmt :: proc(p: ^Parser) -> ^ast.Stmt {
	tok := expect_token(p, .Switch)

	init: ^ast.Stmt
	tag:  ^ast.Stmt
	is_type_switch := false
	clauses: [dynamic]^ast.Stmt

	if p.curr_tok.kind != .Open_Brace {
		prev_level := p.expr_level
		defer p.expr_level = prev_level
		p.expr_level = -1

		if p.curr_tok.kind == .In {
			in_tok := expect_token(p, .In)
			is_type_switch = true

			lhs := make([]^ast.Expr, 1)
			rhs := make([]^ast.Expr, 1)
			lhs[0] = new_blank_ident(p, tok.pos)
			rhs[0] = parse_expr(p, true)

			as := ast.new(ast.Assign_Stmt, tok.pos, rhs[0])
			as.lhs = lhs
			as.op  = in_tok
			as.rhs = rhs
			tag = as
		} else {
			tag = parse_simple_stmt(p, {Stmt_Allow_Flag.In})
			if as, ok := tag.derived.(^ast.Assign_Stmt); ok && as.op.kind == .In {
				is_type_switch = true
			} else if parse_control_statement_semicolon_separator(p) {
				init = tag
				tag = nil
				if p.curr_tok.kind != .Open_Brace {
					tag = parse_simple_stmt(p, nil)
				}
			}
		}
	}


	skip_possible_newline(p)
	open := expect_token(p, .Open_Brace)

	for p.curr_tok.kind == .Case {
		clause := parse_case_clause(p, is_type_switch)
		append(&clauses, clause)
	}

	close := expect_token(p, .Close_Brace)

	body := ast.new(ast.Block_Stmt, open.pos, end_pos(close))
	body.stmts = clauses[:]

	if is_type_switch {
		ts := ast.new(ast.Type_Switch_Stmt, tok.pos, body)
		ts.tag  = tag
		ts.body = body
		ts.switch_pos = tok.pos
		return ts
	} else {
		cond := convert_stmt_to_expr(p, tag, "switch expression")
		ts := ast.new(ast.Switch_Stmt, tok.pos, body)
		ts.init = init
		ts.cond = cond
		ts.body = body
		ts.switch_pos = tok.pos
		return ts
	}
}

parse_attribute :: proc(p: ^Parser, tok: tokenizer.Token, open_kind, close_kind: tokenizer.Token_Kind, docs: ^ast.Comment_Group) -> ^ast.Stmt {
	elems: [dynamic]^ast.Expr

	open, close: tokenizer.Token

	if p.curr_tok.kind == .Ident {
		elem := parse_ident(p)
		append(&elems, elem)
	} else {
		open = expect_token(p, open_kind)
		p.expr_level += 1
		for p.curr_tok.kind != close_kind &&
			p.curr_tok.kind != .EOF {
			elem: ^ast.Expr
			elem = parse_ident(p)
			if p.curr_tok.kind == .Eq {
				eq := expect_token(p, .Eq)
				value := parse_value(p)
				fv := ast.new(ast.Field_Value, elem.pos, value)
				fv.field = elem
				fv.sep   = eq.pos
				fv.value = value

				elem = fv
			}
			append(&elems, elem)

			allow_field_separator(p) or_break
		}
		p.expr_level -= 1
		// C++ Reference: src/parser.cpp:5289 uses expect_closing, not expect_token_after.
		close = expect_closing(p, close_kind, "attribute")
	}

	attribute := ast.new(ast.Attribute, tok.pos, end_pos(close))
	attribute.tok   = tok.kind
	attribute.open  = open.pos
	attribute.elems = elems[:]
	attribute.close = close.pos

	skip_possible_newline(p)

	decl := parse_stmt(p)
	#partial switch d in decl.derived_stmt {
	case ^ast.Value_Decl:
		if d.docs == nil { d.docs = docs }
		append(&d.attributes, attribute)
	case ^ast.Foreign_Block_Decl:
		if d.docs == nil { d.docs = docs }
		append(&d.attributes, attribute)
	case ^ast.Foreign_Import_Decl:
		if d.docs == nil { d.docs = docs }
		append(&d.attributes, attribute)
	case ^ast.Import_Decl:
		if d.docs == nil { d.docs = docs }
		append(&d.attributes, attribute)
	case:
		error(p, decl.pos, "expected a value or foreign declaration after an attribute")
		free(attribute)
		delete(elems)
	}
	return decl

}

parse_foreign_block_decl :: proc(p: ^Parser) -> ^ast.Stmt {
	decl := parse_stmt(p)
	#partial switch _ in decl.derived_stmt {
	case ^ast.Empty_Stmt, ^ast.Bad_Stmt, ^ast.Bad_Decl:
		// Ignore
		return nil
	case ^ast.When_Stmt, ^ast.Value_Decl:
		return decl
	}

	error(p, decl.pos, "Foreign blocks only allow procedure and variable declarations")

	return nil

}

parse_foreign_block :: proc(p: ^Parser, tok: tokenizer.Token) -> ^ast.Foreign_Block_Decl {
	docs := p.lead_comment

	foreign_library: ^ast.Expr
	#partial switch p.curr_tok.kind {
	case .Open_Brace:
		i := ast.new(ast.Ident, tok.pos, end_pos(tok))
		i.name = "_"
		foreign_library = i
	case:
		foreign_library = parse_ident(p)
	}

	decls: [dynamic]^ast.Stmt

	prev_in_foreign_block := p.in_foreign_block
	defer p.in_foreign_block = prev_in_foreign_block
	p.in_foreign_block = true

	skip_possible_newline_for_literal(p)
	open := expect_token(p, .Open_Brace)
	for p.curr_tok.kind != .Close_Brace && p.curr_tok.kind != .EOF {
		decl := parse_foreign_block_decl(p)
		if decl != nil {
			append(&decls, decl)
		}
	}
	close := expect_token(p, .Close_Brace)

	body := ast.new(ast.Block_Stmt, open.pos, end_pos(close))
	body.open = open.pos
	body.stmts = decls[:]
	body.close = close.pos

	decl := ast.new(ast.Foreign_Block_Decl, tok.pos, body)
	decl.docs            = docs
	decl.tok             = tok
	decl.foreign_library = foreign_library
	decl.body            = body
	return decl
}


parse_foreign_decl :: proc(p: ^Parser) -> ^ast.Decl {
	docs := p.lead_comment
	tok := expect_token(p, .Foreign)

	#partial switch p.curr_tok.kind {
	case .Ident, .Open_Brace:
		return parse_foreign_block(p, tok)

	case .Import:
		import_tok := expect_token(p, .Import)
		name: ^ast.Ident
		if p.curr_tok.kind == .Ident {
			name = parse_ident(p)
		}

		if name != nil && is_blank_ident(name) {
			error(p, name.pos, "Illegal foreign import name: '_'")
		}

		fullpaths: [dynamic]^ast.Expr
		multiple_filepaths := false
		if allow_token(p, .Open_Brace) {
			multiple_filepaths = true
			for p.curr_tok.kind != .Close_Brace &&
				p.curr_tok.kind != .EOF {
				path := parse_expr(p, false)
				append(&fullpaths, path)

				allow_field_separator(p) or_break
			}
			expect_token(p, .Close_Brace)
		} else {
			path := expect_token(p, .String)
			reserve(&fullpaths, 1)
			bl := ast.new(ast.Basic_Lit, path.pos, end_pos(path))
			bl.tok = path
			append(&fullpaths, bl)
		}

		// C++ anchors both of the diagnostics below at lib_name, NOT at the `import` keyword.
		// lib_name is the identifier when one is present, and otherwise carries the pos of the
		// `foreign` token itself (parser.cpp:5200-5207) -- not `import`. The port previously used
		// import_tok.pos, which put `foreign import lib {}` at 2:9 where the reference gives 2:16.
		// Probes c27_fgnzero and c27_fgnproc.
		lib_name_pos := tok.pos
		if name != nil {
			lib_name_pos = name.pos
		}

		if len(fullpaths) == 0 {
			error(p, lib_name_pos, "foreign import without any paths")
			// C++ parser.cpp:5239 returns a BAD DECL here, and that matters beyond recovery
			// shape: parse_setup_file_decls only reaches its "No foreign paths found" branch for
			// a real ForeignImportDecl, so C++'s zero-path case reports exactly once. Returning
			// the real node made the port report twice (probe c27_fgnzero). It also explains why
			// C++ 6318's arm indexes filepaths[0] on an empty slice without ever crashing --
			// that branch is unreachable from this parser.
			bad := ast.new(ast.Bad_Decl, lib_name_pos, end_pos(p.curr_tok))
			expect_semicolon(p, bad)
			return bad
		} else if p.curr_proc != nil {
			// C++ parser.cpp:5241. Absent from the port entirely -- a foreign import inside a
			// procedure body was silently accepted.
			error(p, lib_name_pos, "You cannot use foreign import within a procedure. This must be done at the file scope")
			bad := ast.new(ast.Bad_Decl, lib_name_pos, end_pos(p.curr_tok))
			expect_semicolon(p, bad)
			return bad
		}

		decl := ast.new(ast.Foreign_Import_Decl, tok.pos, end_pos(p.prev_tok))
		decl.docs            = docs
		decl.foreign_tok     = tok
		decl.import_tok      = import_tok
		decl.name            = name
		decl.fullpaths       = fullpaths[:]
		decl.multiple_filepaths = multiple_filepaths
		expect_semicolon(p, decl)
		decl.comment = p.line_comment
		return decl
	}

	error(p, tok.pos, "Invalid foreign declaration")
	return ast.new(ast.Bad_Decl, tok.pos, end_pos(tok))
}


parse_unrolled_for_loop :: proc(p: ^Parser, inline_tok: tokenizer.Token) -> ^ast.Stmt {
	val0, val1: ^ast.Expr
	in_tok: tokenizer.Token
	expr: ^ast.Expr
	body: ^ast.Stmt
	args: [dynamic]^ast.Expr

	if allow_token(p, .Open_Paren) {
		p.expr_level += 1
		if p.curr_tok.kind == .Close_Paren {
			error(p, p.curr_tok.pos, "#unroll expected at least 1 argument, got 0")
		} else {
			args = make([dynamic]^ast.Expr)
			for p.curr_tok.kind != .Close_Paren &&
			    p.curr_tok.kind != .EOF {
				arg := parse_value(p)

				if p.curr_tok.kind == .Eq {
					eq := expect_token(p, .Eq)
					if arg != nil {
						if _, ok := arg.derived.(^ast.Ident); !ok {
							error(p, arg.pos, "Expected an identifier for 'key=value'")
						}
					}
					value := parse_value(p)
					fv := ast.new(ast.Field_Value, arg.pos, value)
					fv.field = arg
					fv.sep   = eq.pos
					fv.value = value

					arg = fv
				}

				append(&args, arg)

				allow_field_separator(p) or_break
			}
		}

		p.expr_level -= 1
		// C++ Reference: src/parser.cpp:5347 uses expect_closing.
		_ = expect_closing(p, .Close_Paren, "#unroll")
	}

	for_tok := expect_token(p, .For)

	bad_stmt := false

	if p.curr_tok.kind != .In {
		idents := parse_ident_list(p, false)
		switch len(idents) {
		case 1:
			val0 = idents[0]
		case 2:
			val0, val1 = idents[0], idents[1]
		case:
			error(p, for_tok.pos, "Expected either 1 or 2 identifiers")
			bad_stmt = true
		}
	}

	in_tok = expect_token(p, .In)

	prev_allow_range := p.allow_range
	prev_level := p.expr_level
	p.allow_range = true
	p.expr_level = -1

	expr = parse_expr(p, false)

	p.expr_level = prev_level
	p.allow_range = prev_allow_range

	if allow_token(p, .Do) {
		// C++ Reference: src/parser.cpp:5388
		body = parse_do_body(p, for_tok, "the for statement")
	} else {
		body = parse_block_stmt(p, false)
	}

	if bad_stmt {
		return ast.new(ast.Bad_Stmt, inline_tok.pos, end_pos(p.prev_tok))
	}

	range_stmt := ast.new(ast.Inline_Range_Stmt, inline_tok.pos, body)
	range_stmt.unroll_pos = inline_tok.pos
	range_stmt.args = args[:]
	range_stmt.for_pos = for_tok.pos
	range_stmt.val0 = val0
	range_stmt.val1 = val1
	range_stmt.in_pos = in_tok.pos
	range_stmt.expr = expr
	range_stmt.body = body
	return range_stmt
}

parse_stmt :: proc(p: ^Parser) -> ^ast.Stmt {
	#partial switch p.curr_tok.kind {
	case .Inline:
		if peek_token_kind(p, .For) {
			inline_tok := expect_token(p, .Inline)
			return parse_unrolled_for_loop(p, inline_tok)
		}
		fallthrough
	// Operands
	case .No_Inline,
	     .Context, // Also allows for 'context = '
	     .Proc,
	     .Ident,
	     .Integer, .Float, .Imag,
	     .Rune, .String,
	     .Open_Paren,
	     .Pointer,
	     .Asm, // Inline assembly
	     // Unary Expressions
	     .Add, .Sub, .Xor, .Not, .And, .Increment, .Decrement:

		s := parse_simple_stmt(p, {Stmt_Allow_Flag.Label})
		expect_semicolon(p, s)
		return s


	case .Foreign: return parse_foreign_decl(p)
	case .Import:  return parse_import_decl(p)
	case .If:      return parse_if_stmt(p)
	case .When:    return parse_when_stmt(p)
	case .For:     return parse_for_stmt(p)
	case .Switch:  return parse_switch_stmt(p)

	case .Defer:
		tok := advance_token(p)
		stmt := parse_stmt(p)
		#partial switch s in stmt.derived_stmt {
		// C++ Reference: parser.cpp:5127-5136. All three of these report at `token` -- the
		// `defer` keyword itself -- not at the offending statement. The port passed `s.pos`,
		// the deferred statement, so every one of them landed a few columns to the right of
		// where C++ puts it (probe .claude/probes/defer_bad: oracle 3:2, port 3:8). Message
		// text was already correct; only the position node was wrong.
		case ^ast.Empty_Stmt:
			error(p, tok.pos, "Empty statement after defer (e.g. ';')")
		case ^ast.Defer_Stmt:
			error(p, tok.pos, "You cannot defer a defer statement")
			stmt = s.stmt
		case ^ast.Return_Stmt:
			_ = s
			error(p, tok.pos, "You cannot defer a return statement")
		}
		ds := ast.new(ast.Defer_Stmt, tok.pos, stmt)
		ds.stmt = stmt
		return ds

	case .Return:
		tok := advance_token(p)

		if p.expr_level > 0 {
			error(p, tok.pos, "You cannot use a return statement within an expression")
		}

		results: [dynamic]^ast.Expr
		for p.curr_tok.kind != .Semicolon && p.curr_tok.kind != .Close_Brace {
			result := parse_expr(p, false)
			append(&results, result)
			if p.curr_tok.kind != .Comma ||
			   p.curr_tok.kind == .EOF {
				break
			}
			advance_token(p)
		}

		end := end_pos(tok)
		if len(results) > 0 {
			end = results[len(results)-1].end
		}

		rs := ast.new(ast.Return_Stmt, tok.pos, end)
		rs.results = results[:]
		expect_semicolon(p, rs)
		return rs

	case .Break, .Continue, .Fallthrough:
		tok := advance_token(p)
		label: ^ast.Ident
		if tok.kind != .Fallthrough && p.curr_tok.kind == .Ident {
			label = parse_ident(p)
		}
		s := ast.new(ast.Branch_Stmt, tok.pos, label)
		s.tok = tok
		s.label = label
		expect_semicolon(p, s)
		return s

	case .Using:
		docs := p.lead_comment
		tok := expect_token(p, .Using)

		if p.curr_tok.kind == .Import {
			return parse_import_decl(p, Import_Decl_Kind.Using)
		}

		list := parse_lhs_expr_list(p)
		if len(list) == 0 {
			error(p, tok.pos, "Illegal use of 'using' statement")
			expect_semicolon(p, nil)
			return ast.new(ast.Bad_Stmt, tok.pos, end_pos(p.prev_tok))
		}

		if p.curr_tok.kind != .Colon {
			end := list[len(list)-1]
			expect_semicolon(p, end)
			us := ast.new(ast.Using_Stmt, tok.pos, end)
			us.list = list
			return us
		}
		expect_token_after(p, .Colon, "identifier list")
		decl := parse_value_decl(p, list, docs)
		if decl != nil {
			#partial switch d in decl.derived_stmt {
			case ^ast.Value_Decl:
				d.is_using = true
				return decl
			}
		}

		error(p, tok.pos, "Illegal use of 'using' statement")
		return ast.new(ast.Bad_Stmt, tok.pos, end_pos(p.prev_tok))

	case .At:
		docs := p.lead_comment
		tok := advance_token(p)
		return parse_attribute(p, tok, .Open_Paren, .Close_Paren, docs)

	case .Hash:
		tok := expect_token(p, .Hash)
		tag := expect_token(p, .Ident)
		name := tag.text

		switch name {
		case "bounds_check", "no_bounds_check", "type_assert", "no_type_assert":
			// C++ Reference: src/parser.cpp:5500-5511 -- the STATEMENT path routes the same four
			// names through parse_check_directive_for_statement, exactly as the expression path
			// does. The port set the state flag directly with NO validation, so
			// `#bounds_check ;` was accepted silently (oracle 1 diagnostic, port 0). LEDGER #304
			// residual.
			stmt := parse_stmt(p)
			flag: ast.Node_State_Flag
			switch name {
			case "bounds_check":    flag = .Bounds_Check
			case "no_bounds_check": flag = .No_Bounds_Check
			case "type_assert":     flag = .Type_Assert
			case "no_type_assert":  flag = .No_Type_Assert
			case: unimplemented()
			}
			return cast(^ast.Stmt)parse_check_directive_for_statement(p, cast(^ast.Node)stmt, tag, flag)
		case "partial":
			stmt := parse_stmt(p)
			// C++ Reference: src/parser.cpp:5512-5530. Two things the port lacked: the
			// "already applied" guard on each switch arm, and the EmptyStmt arm, which defers
			// to the validator with NO state flag so that `#partial ;` gets the
			// empty-statement message rather than "can only be applied to a switch statement".
			#partial switch v in stmt.derived_stmt {
			case ^ast.Switch_Stmt:
				if v.partial {
					error(p, tok.pos, "#partial already applied to a switch statement")
				}
				v.partial = true
			case ^ast.Type_Switch_Stmt:
				if v.partial {
					error(p, tok.pos, "#partial already applied to a switch statement")
				}
				v.partial = true
			case ^ast.Empty_Stmt:
				return cast(^ast.Stmt)parse_check_directive_for_statement(p, cast(^ast.Node)stmt, tag, nil)
			case:
				error(p, tok.pos, "#partial can only be applied to a switch statement")
			}
			return stmt
		case "assert", "panic":
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tag))
			bd.tok  = tok
			bd.name = name
			ce := parse_call_expr(p, bd)
			es := ast.new(ast.Expr_Stmt, ce.pos, ce)
			es.expr = ce
			return es

		case "force_inline", "force_no_inline", "must_tail":
			expr := parse_inlining_or_tailing_operand(p, true, tag)
			es := ast.new(ast.Expr_Stmt, expr.pos, expr)
			es.expr = expr
			return es
		case "unroll":
			return parse_unrolled_for_loop(p, tag)
		case "reverse":
			stmt := parse_stmt(p)

			if range, is_range := stmt.derived.(^ast.Range_Stmt); is_range {
				if range.reverse {
					error(p, range.pos, "#reverse already applied to a 'for in' statement")
				}
				range.reverse = true
			} else {
				error(p, stmt.pos, "#reverse can only be applied to a 'for in' statement")
			}
			return stmt
		case "include":
			error(p, tag.pos, "#include is not a valid import declaration kind. Did you meant 'import'?")
			return ast.new(ast.Bad_Stmt, tok.pos, end_pos(tag))
		case:
			stmt := parse_stmt(p)
			end := stmt.pos if stmt != nil else end_pos(tok)
			te := ast.new(ast.Tag_Stmt, tok.pos, end)
			te.op   = tok
			te.name = name
			te.stmt = stmt

			fix_advance_to_next_stmt(p)
			return te
		}
	case .Open_Brace:
		return parse_block_stmt(p, false)

	case .Semicolon:
		tok := advance_token(p)
		s := ast.new(ast.Empty_Stmt, tok.pos, end_pos(tok))
		s.token = tok
		return s
	}


	#partial switch p.curr_tok.kind {
	case .Else:
		token := expect_token(p, .Else)
		error(p, token.pos, "'else' unattached to an 'if' statement")
		#partial switch p.curr_tok.kind {
		case .If:
			return parse_if_stmt(p)
		case .When:
			return parse_when_stmt(p)
		case .Open_Brace:
			return parse_block_stmt(p, true)
		case .Do:
			// C++ Reference: src/parser.cpp:5631-5637. The zero Token opts out of the
			// same-line check. C++ then tests disallow_do a SECOND time here, after
			// parse_do_body has already reported it -- reproduced, see #213.
			expect_token(p, .Do)
			stmt := parse_do_body(p, {}, "the for statement")
			if p.disallow_do {
				error_node(p, stmt, "'do' has been disallowed")
			}
			return stmt
		case:
			fix_advance_to_next_stmt(p)
			return ast.new(ast.Bad_Stmt, token.pos, end_pos(p.curr_tok))
		}
	}


	tok := advance_token(p)
	error(p, tok.pos, "Expected a statement, got '%s'", tokenizer.token_to_string(tok))
	fix_advance_to_next_stmt(p)
	s := ast.new(ast.Bad_Stmt, tok.pos, end_pos(tok))
	return s
}


token_precedence :: proc(p: ^Parser, kind: tokenizer.Token_Kind) -> int {
	#partial switch kind {
	case .Question, .If, .When, .Or_Else:
		return 1
	case .Ellipsis, .Range_Half, .Range_Full:
		if !p.allow_range {
			return 0
		}
		return 2
	case .Cmp_Or:
		return 3
	case .Cmp_And:
		return 4
	case .Cmp_Eq, .Not_Eq,
	     .Lt, .Gt,
	     .Lt_Eq, .Gt_Eq:
		return 5
	case .In, .Not_In:
		if p.expr_level < 0 && !p.allow_in_expr {
			return 0
		}
		fallthrough
	case .Add, .Sub, .Or, .Xor:
		return 6
	case .Mul, .Quo,
	     .Mod, .Mod_Mod,
	     .And, .And_Not,
	     .Shl, .Shr:
		return 7
	}
	return 0
}

parse_type_or_ident :: proc(p: ^Parser) -> ^ast.Expr {
	prev_allow_type := p.allow_type
	prev_expr_level := p.expr_level
	defer {
		p.allow_type = prev_allow_type
		p.expr_level = prev_expr_level
	}

	p.allow_type = true
	p.expr_level = -1

	lhs := true
	return parse_atom_expr(p, parse_operand(p, lhs), lhs)
}
// C++ Reference: src/parser.cpp:3683-3706.
//
// The port had a one-line reduction of this: a lowercase "expected a type" with no offender
// named, no token consumed, and the whole trailing Paren_Expr branch missing.
parse_type :: proc(p: ^Parser) -> ^ast.Expr {
	type := parse_type_or_ident(p)
	if type == nil {
		// prev_token is captured BEFORE the advance below, because it is what the message
		// names. C++ does not advance past '{' -- consuming it there would eat the brace that
		// opens a body the caller still has to parse.
		prev_token := p.curr_tok
		token: tokenizer.Token
		if p.curr_tok.kind == .Open_Brace {
			token = p.curr_tok
		} else {
			token = advance_token(p)
		}
		if prev_token.text == "\n" {
			error(p, token.pos, "Expected a type, got newline")
		} else {
			error(p, token.pos, "Expected a type, got '%s'", prev_token.text)
		}
		return ast.new(ast.Bad_Expr, token.pos, end_pos(p.curr_tok))
	} else if pe, is_paren := type.derived.(^ast.Paren_Expr); is_paren {
		// C++: `type->kind == Ast_ParenExpr && unparen_expr(type) == nullptr`, i.e. peeling
		// every layer of parens yields nothing, as in `()` or `(())`.
		//
		// This CANNOT be written as `ast.unparen_expr(type) == nil`: the port's helper differs
		// from C++'s. C++ follows into ParenExpr.expr unconditionally, so an empty paren peels
		// to nullptr; the port's stops and returns the Paren_Expr itself when .expr is nil
		// (ast.odin:697-711), so it never yields nil. The equivalent test is therefore "peels
		// down to a Paren_Expr that is still empty". The helper divergence is real and affects
		// 15 call sites, so it is filed separately rather than changed from here.
		inner := ast.unparen_expr(type)
		empty := false
		if ipe, ok := inner.derived.(^ast.Paren_Expr); ok && ipe.expr == nil {
			empty = true
		}
		if empty {
			error_node(p, type, "Expected a type within the parentheses")
			return ast.new(ast.Bad_Expr, pe.open, pe.close)
		}
	}
	return type
}

parse_body :: proc(p: ^Parser) -> ^ast.Block_Stmt {
	prev_expr_level := p.expr_level
	defer p.expr_level = prev_expr_level

	p.expr_level = 0
	open := expect_token(p, .Open_Brace)
	stmts := parse_stmt_list(p)
	close := expect_token(p, .Close_Brace)

	bs := ast.new(ast.Block_Stmt, open.pos, end_pos(close))
	bs.open = open.pos
	bs.stmts = stmts
	bs.close = close.pos
	return bs
}

// C++ Reference: src/parser.cpp:4707-4725 parse_do_body.
//
// #211: this function did not exist. Its body was inlined at all 8 call sites, and every copy
// had drifted:
//   * none reset expr_level to 0 -- C++ notes "the body may be within an expression", and a
//     negative expr_level (a control clause) otherwise leaks into the body.
//   * none set allow_newline = false, so the do-body inherited the enclosing list's newline
//     rule. This is the 5th of C++'s 6 allow_newline save/restore sites (see #209).
//   * none checked disallow_do.
//   * each carried its own hand-written message; C++ has one, parameterised by `msg`.
//
// `token` may be the zero Token, which is how the bare `do` statement at C++ 5633 opts out of
// the same-line check. C++ spells that test as `token.pos.file_id != 0`; this port's Pos
// carries a file NAME rather than an id, so the equivalent emptiness test is used.
// C++ passes `cond ? ast_token(cond) : token` at the if/when sites. This port has no
// ast_token; for the node kinds that reach here ast_token's position is the node's own pos,
// which is what the old inlined copies already compared against.
do_body_token :: proc(cond: ^ast.Expr, fallback: tokenizer.Token) -> tokenizer.Token {
	if cond == nil {
		return fallback
	}
	tok := fallback
	tok.pos = cond.pos
	return tok
}

parse_do_body :: proc(p: ^Parser, token: tokenizer.Token, msg: string) -> ^ast.Stmt {
	prev_expr_level := p.expr_level
	prev_allow_newline := p.allow_newline

	// NOTE(bill): The body may be within an expression so reset to zero
	p.expr_level = 0
	p.allow_newline = false

	body := convert_stmt_to_body(p, parse_stmt(p))
	if p.disallow_do {
		error(p, body.pos, "'do' has been disallowed")
	} else if token.pos.file != "" && token.pos.line != body.pos.line {
		error(p, body.pos, "The body of a 'do' must be on the same line as %s", msg)
	}
	p.expr_level = prev_expr_level
	p.allow_newline = prev_allow_newline

	return body
}

convert_stmt_to_body :: proc(p: ^Parser, stmt: ^ast.Stmt) -> ^ast.Stmt {
	#partial switch s in stmt.derived_stmt {
	case ^ast.Block_Stmt:
		error_node(p, stmt, "Expected a normal statement rather than a block statement")
		return stmt
	case ^ast.Empty_Stmt:
		error_node(p, stmt, "Expected a non-empty statement")
	}

	bs := ast.new(ast.Block_Stmt, stmt.pos, stmt)
	bs.open = stmt.pos
	bs.stmts = make([]^ast.Stmt, 1)
	bs.stmts[0] = stmt
	bs.close = stmt.end
	bs.uses_do = true
	return bs
}

new_ast_field :: proc(names: []^ast.Expr, type: ^ast.Expr, default_value: ^ast.Expr) -> ^ast.Field {
	pos, end: tokenizer.Pos

	if len(names) > 0 {
		pos = names[0].pos
		if default_value != nil {
			end = default_value.end
		} else if type != nil {
			end = type.end
		} else {
			end = names[len(names)-1].pos
		}
	} else {
		if type != nil {
			pos = type.pos
		} else if default_value != nil {
			pos = default_value.pos
		}

		if default_value != nil {
			end = default_value.end
		} else if type != nil {
			end = type.end
		}
	}

	field := ast.new(ast.Field, pos, end)
	field.names = names
	field.type  = type
	field.default_value = default_value
	return field
}

Expr_And_Flags :: struct {
	expr:  ^ast.Expr,
	flags: ast.Field_Flags,
}

convert_to_ident_list :: proc(p: ^Parser, list: []Expr_And_Flags, ignore_flags, allow_poly_names: bool) -> []^ast.Expr {
	idents := make([dynamic]^ast.Expr, 0, len(list))

	for ident, i in list {
		if !ignore_flags {
			if i != 0 {
				error(p, ident.expr.pos, "Illegal use of prefixes in parameter list")
			}
		}

		id: ^ast.Expr = ident.expr

		#partial switch n in ident.expr.derived_expr {
		case ^ast.Ident:
		case ^ast.Bad_Expr:
		case ^ast.Poly_Type:
			if allow_poly_names {
				if n.specialization == nil {
					break
				} else {
					error(p, ident.expr.pos, "expected a polymorphic identifier without an specialization")
				}
			} else {
				error(p, ident.expr.pos, "Expected a non-polymorphic identifier")
			}
		case:
			error(p, ident.expr.pos, "Expected an identifier")
			id = ast.new(ast.Ident, ident.expr.pos, ident.expr.end)
		}

		append(&idents, id)
	}

	return idents[:]
}

is_token_field_prefix :: proc(p: ^Parser) -> ast.Field_Flag {
	#partial switch p.curr_tok.kind {
	case .EOF:
		return .Invalid
	case .Using:
		// C++ Reference: parser.cpp:4223-4224 -- returns WITHOUT advancing. The caller
		// consumes the token, uniformly for every flag.
		return .Using
	case .Hash:
		if tok := peek_token(p); tok.kind == .Ident {
			switch tok.text {
			case "simd", "type", "row_major", "column_major", "sparse", "soa":
				return .Invalid
			}
		}

		// C++ Reference: parser.cpp:4242-4255. Advance past the '#' ONLY, then test the
		// CURRENT token. C++ deliberately leaves curr on the directive ident so the caller
		// can (a) consume it on the success path and (b) NAME it in the Unknown error.
		// The port advanced twice here, so by the time parse_field_prefixes reported
		// "Unknown prefix kind" it was pointing at whatever followed -- for
		// `struct { #bogus x: int }` it named the FIELD NAME, '#x', and had eaten it.
		advance_token(p)
		if p.curr_tok.kind == .Ident {
			for kf in ast.field_hash_flag_strings {
				if kf.key == p.curr_tok.text {
					return kf.flag
				}
			}
		}
		return .Unknown
	}
	return .Invalid
}

parse_field_prefixes :: proc(p: ^Parser) -> (flags: ast.Field_Flags) {
	counts: [len(ast.Field_Flag)]int

	for {
		kind := is_token_field_prefix(p)
		if kind == .Invalid {
			break
		}

		if kind == .Unknown {
			error(p, p.curr_tok.pos, "Unknown prefix kind '#%s'", p.curr_tok.text)
			advance_token(p)
			continue
		}

		counts[kind] += 1
		advance_token(p)
	}

	for kind in ast.Field_Flag {
		count := counts[kind]
		if kind == .Invalid || kind == .Unknown {
			// Ignore
		} else {
			if count > 1 { error(p, p.curr_tok.pos, "multiple '%s' in this field list", ast.field_flag_strings[kind]) }
			if count > 0 { flags += {kind} }
		}
	}

	return
}

check_field_flag_prefixes :: proc(p: ^Parser, name_count: int, allowed_flags, set_flags: ast.Field_Flags) -> (flags: ast.Field_Flags) {
	flags = set_flags
	if name_count > 1 && .Using in flags {
		error(p, p.curr_tok.pos, "Cannot apply 'using' to more than one of the same type")
		flags -= {.Using}
	}

	for flag in ast.Field_Flag {
		if flag not_in allowed_flags && flag in flags {
			#partial switch flag {
			case .Unknown, .Invalid:
				// ignore
			case .Tags, .Ellipsis, .Results, .Default_Parameters, .Typeid_Token:
				panic("Impossible prefixes")
			case:
				// NOTE(parity): C++ writes "in not allowed" (src/parser.cpp:4320) -- "in" where "is"
				// was meant. Reproduced verbatim because the objective is byte-identical
				// diagnostics; reported upstream rather than silently corrected here.
				error(p, p.curr_tok.pos, "'%s' in not allowed within this field list", ast.field_flag_strings[flag])
			}
			flags -= {flag}
		}
	}

	return flags
}

parse_var_type :: proc(p: ^Parser, flags: ast.Field_Flags) -> ^ast.Expr {
	if .Ellipsis in flags && p.curr_tok.kind == .Ellipsis {
		tok := advance_token(p)
		type := parse_type_or_ident(p)
		if type == nil {
			error(p, tok.pos, "variadic field missing type after '..'")
			type = ast.new(ast.Bad_Expr, tok.pos, end_pos(tok))
		}
		// LEDGER #323. The node's position is the `..` TOKEN, not the inner type. C++
		// ast_ellipsis (parser.cpp:859) stores the whole token and ast_token() reads it back,
		// so `b: ..int` anchors at the `..`; the port anchored at `int`, two columns right.
		//
		// Note `e.tok` keeps only the token KIND, so the position was not recoverable from the
		// node afterwards -- this constructor was the only place it existed.
		//
		// Invisible until #322 gave parser diagnostics a caret SPAN: a one-column caret at the
		// wrong column looks much like a one-column caret at the right one. The span made the
		// off-by-two obvious. Third arg is `type`, so the node still ends where the inner type
		// ends -- C++'s span is `..int` entire.
		e := ast.new(ast.Ellipsis, tok.pos, type)
		e.tok = tok.kind
		e.expr = type
		return e
	}
	type: ^ast.Expr
	if .Typeid_Token in flags && p.curr_tok.kind == .Typeid {
		tok := expect_token(p, .Typeid)
		specialization: ^ast.Expr
		end := tok.pos
		if allow_token(p, .Quo) {
			specialization = parse_type(p)
			end = specialization.end
		}

		ti := ast.new(ast.Typeid_Type, tok.pos, end)
		ti.tok = tok.kind
		ti.specialization = specialization
		type = ti
	} else {
		type = parse_type(p)
	}

	return type
}

check_procedure_name_list :: proc(p: ^Parser, names: []^ast.Expr) -> bool {
	if len(names) == 0 {
		return false
	}

	_, first_is_polymorphic := names[0].derived.(^ast.Poly_Type)
	any_polymorphic_names := first_is_polymorphic

	for i := 1; i < len(names); i += 1 {
		name := names[i]

		if first_is_polymorphic {
			if _, ok := name.derived.(^ast.Poly_Type); ok {
				any_polymorphic_names = true
			} else {
				error(p, name.pos, "Mixture of polymorphic and non-polymorphic identifiers")
				return any_polymorphic_names
			}
		} else {
			if _, ok := name.derived.(^ast.Poly_Type); ok {
				any_polymorphic_names = true
				error(p, name.pos, "Mixture of polymorphic and non-polymorphic identifiers")
				return any_polymorphic_names
			} else {
				// Okay
			}
		}
	}

	return any_polymorphic_names
}

parse_ident_list :: proc(p: ^Parser, allow_poly_names: bool) -> []^ast.Expr {
	list: [dynamic]^ast.Expr

	for {
		if allow_poly_names && p.curr_tok.kind == .Dollar {
			tok := expect_token(p, .Dollar)
			ident := parse_ident(p)
			if is_blank_ident(ident) {
				error_node(p, ident, "Invalid polymorphic type definition with a blank identifier")
			}
			poly_name := ast.new(ast.Poly_Type, tok.pos, ident)
			poly_name.type = ident
			append(&list, poly_name)
		} else {
			ident := parse_ident(p)
			append(&list, ident)
		}
		if p.curr_tok.kind != .Comma ||
		   p.curr_tok.kind == .EOF {
			break
		}
		advance_token(p)
	}

	return list[:]
}



parse_field_list :: proc(p: ^Parser, follow: tokenizer.Token_Kind, allowed_flags: ast.Field_Flags) -> (field_list: ^ast.Field_List, total_name_count: int) {
	handle_field :: proc(p: ^Parser,
	                     seen_ellipsis: ^bool, fields: ^[dynamic]^ast.Field,
	                     docs: ^ast.Comment_Group,
	                     names: []^ast.Expr,
	                     allowed_flags, set_flags: ast.Field_Flags,
	                     ) -> bool {

		// REMOVED (#209): a private `expect_field_separator` used to live here -- a divergent
		// reimplementation of C++'s allow_field_separator that reported at the wrong position
		// ("expected a comma, got a semicolon" at tok.pos, not "Expected a comma, got a %s" at
		// the end of the previous line), never consulted file_allow_newline, and never checked
		// that the newline was actually followed by a closing token. Its one call site now uses
		// the real allow_field_separator.
		is_type_ellipsis :: proc(type: ^ast.Expr) -> bool {
			if type == nil {
				return false
			}
			_, ok := type.derived.(^ast.Ellipsis)
			return ok
		}

		is_signature := (allowed_flags & ast.Field_Flags_Signature_Params) == ast.Field_Flags_Signature_Params

		any_polymorphic_names := check_procedure_name_list(p, names)
		flags := check_field_flag_prefixes(p, len(names), allowed_flags, set_flags)

		type:          ^ast.Expr
		default_value: ^ast.Expr
		tag: tokenizer.Token

		expect_token_after(p, .Colon, "field list")

		// C++ Reference: parser.cpp:4613-4614 goes straight from the colon to
		// parse_var_type. There is NO post-colon parse_field_prefixes call, and the
		// omission is deliberate: field directives belong BEFORE the name. The port had
		// an invented call here, which ACCEPTED syntax the reference compiler rejects --
		// `proc(dst: #no_alias ^int)` and `proc(x: #any_int int)` are both errors in C++
		// ("Expected ')' after parameter list") and were silently accepted here.
		// It also swallowed any unrecognised directive in a field's TYPE position, so
		// `p: #relative(u16) ^int` never reached parse_var_type at all and cascaded.

		if p.curr_tok.kind != .Eq {
			type = parse_var_type(p, allowed_flags)
			tt := ast.unparen_expr(type)
			if is_signature && !any_polymorphic_names {
				if ti, ok := tt.derived.(^ast.Typeid_Type); ok && ti.specialization != nil {
					error_node(p, type, "Specialization of typeid is not allowed without polymorphic names")
				}
			}
		}

		if allow_token(p, .Eq) {
			default_value = parse_expr(p, false)
			if .Default_Parameters not_in allowed_flags {
				error(p, p.curr_tok.pos, "Default parameters are only allowed for procedures")
				default_value = nil
			}
		}

		if default_value != nil && len(names) > 1 {
			error(p, p.curr_tok.pos, "Default parameters can only be applied to single values")
		}

		if allowed_flags == ast.Field_Flags_Struct && default_value != nil {
			error(p, default_value.pos, "Default parameters are not allowed for structs")
			default_value = nil
		}

		if is_type_ellipsis(type) {
			if seen_ellipsis^ {
				error_node(p, type, "Extra variadic parameter after ellipsis")
			}
			seen_ellipsis^ = true
			if len(names) != 1 {
				error_node(p, type, "Variadic parameters can only have one field name")
			}
		} else if seen_ellipsis^ && default_value == nil {
			error(p, p.curr_tok.pos, "Extra parameter after ellipsis without a default value")
		}

		if type != nil && default_value == nil {
			if p.curr_tok.kind == .String {
				tag = expect_token(p, .String)
				if .Tags not_in allowed_flags {
					error(p, tag.pos, "Field tags are only allowed within structures")
				}
			}
		}

		// C++ Reference: src/parser.cpp:4656
		ok := allow_field_separator(p)

		field := new_ast_field(names, type, default_value)
		field.tag     = tag
		field.docs    = docs
		field.flags   = flags
		field.comment = p.line_comment
		append(fields, field)

		return ok
	}


	// C++ Reference: src/parser.cpp:4455-4457
	prev_allow_newline := p.allow_newline
	defer p.allow_newline = prev_allow_newline
	p.allow_newline = file_allow_newline(p)

	start_tok := p.curr_tok

	docs := p.lead_comment

	fields: [dynamic]^ast.Field

	list: [dynamic]Expr_And_Flags
	defer delete(list)

	seen_ellipsis := false

	allow_typeid_token := .Typeid_Token in allowed_flags
	allow_poly_names := allow_typeid_token

	for p.curr_tok.kind != follow &&
	    p.curr_tok.kind != .Colon &&
	    p.curr_tok.kind != .EOF {
		prefix_flags := parse_field_prefixes(p)
		param := parse_var_type(p, allowed_flags & {.Typeid_Token, .Ellipsis})
		if _, ok := param.derived.(^ast.Ellipsis); ok {
			if seen_ellipsis {
				error(p, param.pos, "Extra variadic parameter after ellipsis")
			}
			seen_ellipsis = true
		} else if seen_ellipsis {
			error(p, param.pos, "Extra parameter after ellipsis")
		}

		eaf := Expr_And_Flags{param, prefix_flags}
		append(&list, eaf)
		allow_field_separator(p) or_break
	}

	if p.curr_tok.kind != .Colon {
		for eaf in list {
			type := eaf.expr
			tok: tokenizer.Token
			tok.pos = type.pos
			if .Results not_in allowed_flags {
				tok.text = "_"
			}

			names := make([]^ast.Expr, 1)
			names[0] = ast.new(ast.Ident, tok.pos, end_pos(tok))
			#partial switch ident in names[0].derived_expr {
			case ^ast.Ident:
				ident.name = tok.text
			case:
				unreachable()
			}

			flags := check_field_flag_prefixes(p, len(list), allowed_flags, eaf.flags)

			field := new_ast_field(names, type, nil)
			field.docs    = docs
			field.flags   = flags
			field.comment = p.line_comment
			append(&fields, field)
		}
	} else {
		names := convert_to_ident_list(p, list[:], true, allow_poly_names)
		if len(names) == 0 {
			error(p, p.curr_tok.pos, "Empty field declaration")
		}

		set_flags: ast.Field_Flags
		if len(list) > 0 {
			set_flags = list[0].flags
		}
		total_name_count += len(names)

		// C++ Reference: src/parser.cpp:4585-4600 --
		//     bool more_fields = allow_field_separator(f);
		//     ... build and add the param ...
		//     if (!more_fields) { ...; return ast_field_list(f, start_token, params); }
		//     while (f->curr_token.kind != follow &&
		//            f->curr_token.kind != Token_EOF &&
		//            f->curr_token.kind != Token_Semicolon) { ... }
		//
		// LEDGER #303: the port DISCARDED handle_field's result here. handle_field ends in
		// allow_field_separator and returns whether a separator was actually consumed, so
		// dropping it meant a field with NO separator after its type still fell into the loop
		// below, which then read the next token as the start of another field's NAME LIST.
		// `a: int int, b: int` therefore parsed as `a: int` plus a two-name field `int, b: int`
		// and the port reported errors=0 where the reference reports three syntax errors --
		// an UNDER-REJECTION, confirmed by dumping the AST (names=2 on the second field).
		// The trailing call at the bottom of the loop already had `or_break`; only this first
		// one was missing the check, which is why it needed a field list of at least two
		// entries to show.
		more_fields := handle_field(p, &seen_ellipsis, &fields, docs, names, allowed_flags, set_flags)

		// C++ returns the list outright when the first field had no separator. Guarding the
		// loop is the same thing here, since the field list is constructed after it.
		if more_fields {
			// The `.Semicolon` guard is C++'s too (parser.cpp:4596) and was likewise absent.
			for p.curr_tok.kind != follow &&
			    p.curr_tok.kind != .EOF &&
			    p.curr_tok.kind != .Semicolon {
				docs = p.lead_comment
				set_flags = parse_field_prefixes(p)
				names = parse_ident_list(p, allow_poly_names)

				total_name_count += len(names)
				handle_field(p, &seen_ellipsis, &fields, docs, names, allowed_flags, set_flags) or_break
			}
		}
	}

	field_list = ast.new(ast.Field_List, start_tok.pos, p.curr_tok.pos)
	field_list.list = fields[:]
	return
}


parse_results :: proc(p: ^Parser) -> (list: ^ast.Field_List, diverging: bool) {
	if !allow_token(p, .Arrow_Right) {
		return
	}

	if allow_token(p, .Not) {
		diverging = true
		return
	}

	prev_level := p.expr_level
	defer p.expr_level = prev_level

	if p.curr_tok.kind != .Open_Paren {
		type := parse_type(p)
		field := new_ast_field(nil, type, nil)

		list = ast.new(ast.Field_List, field.pos, field.end)
		list.list = make([]^ast.Field, 1)
		list.list[0] = field
		return
	}

	expect_token(p, .Open_Paren)
	list, _ = parse_field_list(p, .Close_Paren, ast.Field_Flags_Signature_Results)
	// C++ Reference: src/parser.cpp:4028
	if file_allow_newline(p) {
		skip_possible_newline(p)
	}
	expect_token_after(p, .Close_Paren, "parameter list")
	return
}


// string_to_calling_convention decides whether a proc type's convention string names a real
// calling convention, returning nil when it does not.
//
// C++ Reference: src/parser.cpp:4136-4143 (parse_proc_type):
//
//     if (f->curr_token.kind == Token_String) {
//         Token token = expect_token(f, Token_String);
//         auto c = string_to_calling_convention(string_value_from_token(f, token));
//         if (c == ProcCC_Invalid) {
//             syntax_error(token, "Unknown procedure calling convention: '%.*s'", LIT(token.string));
//         } else {
//             cc = c;
//         }
//     }
//
// The port's version tested only that the token LOOKED like a non-empty string literal and
// then returned the text verbatim, so the guard below it could never fire and every unknown
// convention fell through to the checker instead -- reported one phase late, at the `proc`
// keyword rather than the string, as a plain Error rather than a Syntax Error, and with an
// invented message. probe_cc_neg had all four differences at once.
//
// C++ leaves cc as ProcCC_Invalid after reporting, so the declaration falls back to
// default_calling_convention(). Returning nil here reproduces that: the checker's
// `switch v in calling_convention` matches no case and keeps its .Odin default, and it does
// NOT report a second time.
//
// NOTE: the name set below and the name->enum switch in the checker's
// string_to_calling_convention (core/odin/checker/check_stmt.odin) are the same list in two
// places, because only the checker can resolve "system" (target-dependent) and only the
// parser runs early enough to report. Probe ccpos exercises every name through both, so a
// drift between them fails the corpus rather than going quiet -- the checker's own comment
// records that an earlier inline copy diverged in three ways. LEDGER #372.
string_to_calling_convention :: proc(s: string) -> ast.Proc_Calling_Convention {
	if s[0] != '"' && s[0] != '`' {
		return nil
	}
	if len(s) == 2 {
		return nil
	}
	switch s[1:len(s) - 1] {
	case "odin", "contextless", "cdecl", "c", "stdcall", "std", "fastcall", "fast",
	     "none", "naked", "win64", "sysv", "system",
	     "preserve/none", "preserve/most", "preserve/all":
		return s
	}
	return nil
}

// C++ Reference: src/parser.cpp:2062 parse_proc_tags, and check_proc_add_tag at 2055.
//
// #217. The port recognised 4 of C++'s 7 tags, its unknown-tag case was EMPTY, and it checked
// duplicates only for the bounds_check pair -- with wording C++ does not use. ast.Proc_Tag
// already declared all seven, so Type_Assert, No_Type_Assert and Require_Results were
// declared-but-never-set: another instance of the pattern in #212.
//
// Diagnostic positions differ between the two kinds and are load-bearing: the per-tag errors
// report at the tag's own '#' (probe ptag: 3:35, 4:22), while the pair checks report at
// f->curr_token AFTER the whole tag list (5:54).
parse_proc_tags :: proc(p: ^Parser) -> (tags: ast.Proc_Tags) {
	add_tag :: proc(p: ^Parser, tags: ^ast.Proc_Tags, hash: tokenizer.Token, tag: ast.Proc_Tag, name: string) {
		if tag in tags^ {
			error(p, hash.pos, "Procedure tag already used: %s", name)
		}
		tags^ += {tag}
	}

	for p.curr_tok.kind == .Hash {
		hash := expect_token(p, .Hash)
		ident := expect_token(p, .Ident)

		switch name := ident.text; name {
		case "optional_ok":              add_tag(p, &tags, hash, .Optional_Ok, name)
		case "optional_allocator_error": add_tag(p, &tags, hash, .Optional_Allocator_Error, name)
		case "require_results":          add_tag(p, &tags, hash, .Require_Results, name)
		case "bounds_check":             add_tag(p, &tags, hash, .Bounds_Check, name)
		case "no_bounds_check":          add_tag(p, &tags, hash, .No_Bounds_Check, name)
		case "type_assert":              add_tag(p, &tags, hash, .Type_Assert, name)
		case "no_type_assert":           add_tag(p, &tags, hash, .No_Type_Assert, name)
		case:
			error(p, hash.pos, "Unknown procedure type tag #%s", name)
		}
	}

	if .Bounds_Check in tags && .No_Bounds_Check in tags {
		error(p, p.curr_tok.pos, "You cannot apply both #bounds_check and #no_bounds_check to a procedure")
	}
	if .Type_Assert in tags && .No_Type_Assert in tags {
		error(p, p.curr_tok.pos, "You cannot apply both #type_assert and #no_type_assert to a procedure")
	}

	return
}

is_expr_generic :: proc(expr : ^ast.Expr) -> bool {
	is_generic := false
	if expr != nil {
		#partial switch e in expr.derived_expr {
		case ^ast.Typeid_Type:
			is_generic = e.specialization != nil
		case ^ast.Poly_Type:
			is_generic = true
		case ^ast.Proc_Type:
			is_generic = e.generic
		case ^ast.Pointer_Type:
			is_generic = is_expr_generic(e.elem)
		case ^ast.Multi_Pointer_Type:
			is_generic = is_expr_generic(e.elem)
		case ^ast.Array_Type:
			is_generic = is_expr_generic(e.len) || is_expr_generic(e.elem)
		case ^ast.Dynamic_Array_Type:
			is_generic = is_expr_generic(e.elem)
		case ^ast.Fixed_Capacity_Dynamic_Array_Type:
			is_generic = is_expr_generic(e.capacity) || is_expr_generic(e.elem)
		case ^ast.Bit_Set_Type:
			is_generic = is_expr_generic(e.elem)
		case ^ast.Map_Type:
			is_generic = is_expr_generic(e.key) || is_expr_generic(e.value)
		case ^ast.Matrix_Type:
			is_generic = is_expr_generic(e.row_count) || is_expr_generic(e.column_count) || is_expr_generic(e.elem)
		}
	}
	return is_generic
}

is_field_list_generic :: proc(field_list : ^ast.Field_List, check_names : bool) -> bool {
	is_generic := false
	loop: for param in field_list.list {
		if is_expr_generic(param.type) {
			is_generic = true
			break loop
		}
		if !check_names || param.type == nil {
			continue
		}
		for name in param.names {
			if _, ok := name.derived.(^ast.Poly_Type); ok {
				is_generic = true
				break loop
			}
		}
	}
	return is_generic
}

parse_proc_type :: proc(p: ^Parser, tok: tokenizer.Token) -> ^ast.Proc_Type {
	cc: ast.Proc_Calling_Convention
	if p.curr_tok.kind == .String {
		str := expect_token(p, .String)
		cc = string_to_calling_convention(str.text)
		if cc == nil {
			// C++ prints token.string -- the RAW token text, quotes included -- even though
			// it looked the name up through string_value_from_token, which strips them. That
			// is why the oracle shows two layers of quoting:
			//     Unknown procedure calling convention: '"not_a_real_convention"'
			error(p, str.pos, "Unknown procedure calling convention: '%s'", str.text)
		}
	}

	if cc == nil && p.in_foreign_block {
		cc = .Foreign_Block_Default
	}

	expect_token(p, .Open_Paren)
	p.expr_level += 1
	params, _ := parse_field_list(p, .Close_Paren, ast.Field_Flags_Signature_Params)
	p.expr_level -= 1
	expect_closing_parentheses_of_field_list(p)
	results, diverging := parse_results(p)

	is_generic := is_field_list_generic(params, true)
	if !is_generic && results != nil {
		is_generic = is_field_list_generic(results, false)
	}

	end := end_pos(p.prev_tok)
	pt := ast.new(ast.Proc_Type, tok.pos, end)
	pt.tok = tok
	pt.calling_convention = cc
	pt.params = params
	pt.results = results
	pt.diverging = diverging
	pt.generic = is_generic
	return pt
}

parse_inlining_or_tailing_operand :: proc(p: ^Parser, lhs: bool, tok: tokenizer.Token) -> ^ast.Expr {
	expr := parse_unary_expr(p, lhs)

	pi := ast.Proc_Inlining.None
	pt := ast.Proc_Tailing.None
	#partial switch tok.kind {
	case .Inline:
		pi = .Inline
	case .No_Inline:
		pi = .No_Inline
	case .Ident:
		switch tok.text {
		case "force_inline":
			pi = .Inline
		case "force_no_inline":
			pi = .No_Inline
		case "must_tail":
			pt = .Must_Tail
		}
	}

	// LEDGER #321. Restructured to parser.cpp:2170-2217's shape. Four divergences fixed:
	//
	//  1. The ASSIGNMENTS WERE UNCONDITIONAL. C++ guards each with `if (pi != none)` /
	//     `if (pt != none)`; the port wrote `e.inlining = pi; e.tailing = pt` on every path. So
	//     in the stacked form `#force_no_inline #must_tail f()` the inner directive sets
	//     tailing, then the OUTER one -- whose pt is None -- wrote it straight back to None.
	//     A directive silently erasing its neighbour.
	//  2. The kind check now happens FIRST and bails, as C++ does, instead of falling out of a
	//     switch into a trailing error.
	//  3. Three messages were reworded. C++'s are "Cannot apply both '#force_inline' and
	//     '#force_no_inline' to a procedure literal/call", and the bail names the node kind it
	//     actually got and reports at `expr`, not at the directive token.
	//  4. C++'s must-tail-on-a-literal message says **'#must_call'**, not '#must_tail'. That is
	//     an upstream naming slip, and the port had "corrected" it. Parity means reproducing it
	//     -- same reasoning as #131. Do not re-fix it here; fix it upstream or not at all.
	stripped := expr != nil ? ast.strip_or_return_expr(expr) : nil
	if stripped == nil {
		return expr
	}

	#partial switch e in stripped.derived_expr {
	case ^ast.Proc_Lit:
		if pi != .None {
			if e.inlining != .None && e.inlining != pi {
				error_node(p, expr, "Cannot apply both '#force_inline' and '#force_no_inline' to a procedure literal")
			}
			e.inlining = pi
		}
		if pt != .None {
			error_node(p, expr, "'#must_call' can only be applied to a procedure call, not the procedure literal")
			e.tailing = pt
		}
		return expr
	case ^ast.Call_Expr:
		if pi != .None {
			if e.inlining != .None && e.inlining != pi {
				error_node(p, expr, "Cannot apply both '#force_inline' and '#force_no_inline' to a procedure call")
			}
			e.inlining = pi
		}
		if pt != .None {
			e.tailing = pt
		}
		return expr
	}

	error_node(p, expr, "%s must be followed by a procedure literal or call, got %s", tok.text, ast.node_kind_string(stripped))
	return ast.new(ast.Bad_Expr, tok.pos, expr)
}

// check_basic_literal_value reports the literals the compiler cannot turn into an exact value.
//
// C++ Reference: parser.cpp:793-827, exact_value_from_token, which parse_operand calls on
// every Token_Integer/Float/Imag/Rune/String before it builds the Ast_BasicLit:
//
//     ExactValue value = exact_value_from_basic_literal(token.kind, s);
//     if (value.kind == ExactValue_Invalid) {
//         switch (token.kind) {
//         case Token_Integer: syntax_error(token, "Invalid integer literal"); break;
//         case Token_Float:
//             // NOTE(Jeroen): Could be an integer, see `exact_value_float_from_string`
//             if (!string_contains_char(s, '.') && !string_contains_char(s, '-')) {
//                 syntax_error(token, "Invalid integer literal");
//             } else {
//                 syntax_error(token, "Invalid float literal");
//             }
//             break;
//         default: syntax_error(token, "Invalid token literal"); break;
//         }
//     }
//
// The diagnostic belongs to the PARSER, not the checker. The port used to report an invalid
// literal from check_basic_lit as "Error: Invalid integer literal: 0b12" -- wrong phase,
// wrong severity label, and an extra ": %s" suffix C++ does not print. LEDGER #368.
//
// literal_value_is_valid below is the SUCCESS predicate of big_int_from_string
// (src/big_int.cpp:186-292) with the arithmetic removed, because whether a literal converts
// depends only on how its characters classify. See the ported big_int_from_string in
// core/odin/checker/exact_value.odin for the value side and for why the exponent's own
// failure flag does not count.
@(private)
check_basic_literal_value :: proc(p: ^Parser, tok: tokenizer.Token) {
	// The integer-conversion predicate: base from the prefix, then C++'s digit loop.
	// Returns false exactly where big_int_from_string sets *success = false and that
	// setting survives to the caller.
	integer_value_is_valid :: proc(s: string) -> bool {
		digit_value :: proc(r: u8) -> u64 {
			switch r {
			case '0' ..= '9':
				return u64(r - '0')
			case 'a' ..= 'f':
				return u64(r - 'a') + 10
			case 'A' ..= 'F':
				return u64(r - 'A') + 10
			}
			return 16
		}

		base := u64(10)
		has_prefix := false
		if len(s) > 2 && s[0] == '0' {
			switch s[1] {
			case 'b':
				base = 2
				has_prefix = true
			case 'o':
				base = 8
				has_prefix = true
			case 'd':
				base = 10
				has_prefix = true
			case 'z':
				base = 12
				has_prefix = true
			case 'x', 'h':
				base = 16
				has_prefix = true
			}
		}
		text := s
		if has_prefix {
			text = text[2:]
		}

		is_negative := false
		i := 0
		broke_on_exponent := false
		for ; i < len(text); i += 1 {
			r := text[i]
			if r == '-' {
				if is_negative {
					// NOTE(Jeroen): Can't have a doubly negative number.
					return false
				}
				is_negative = true
				continue
			}
			if r == '_' {
				continue
			}
			if digit_value(r) >= base {
				// NOTE(Jeroen): Can still be a valid integer if the next character is an
				// `e` or `E`.
				if r != 'e' && r != 'E' {
					return false
				}
				broke_on_exponent = true
				break
			}
		}
		if !broke_on_exponent || i >= len(text) {
			return true
		}

		// Inside the exponent, a non-digit sets *success = false and then
		// big_int_exp_u64 immediately overwrites it with its own result, so the ONLY
		// surviving failure is the 308 bound. `1e` and `1eff` are therefore valid.
		i += 1
		if i < len(text) && text[i] == '+' {
			i += 1
		}
		exp := 0
		for ; i < len(text); i += 1 {
			r := text[i]
			if r == '_' {
				continue
			}
			if r < '0' || r > '9' {
				break
			}
			exp = exp * 10 + int(r - '0')
			if exp > 308 {
				return false
			}
		}
		return true
	}

	// The float-conversion predicate: strtod must consume the WHOLE string once
	// underscores are removed (src/exact_value.cpp:228-232, `*success = *end_ptr == 0`).
	float_value_is_valid :: proc(s: string) -> bool {
		buf: [256]u8
		n := 0
		for i in 0 ..< len(s) {
			c := s[i]
			if c == '_' {
				continue
			}
			if c == 'E' {
				c = 'e'
			}
			if n >= len(buf) {
				return true // longer than any real literal; leave it to the checker
			}
			buf[n] = c
			n += 1
		}
		// strconv.parse_f64 reports ok=false on OVERFLOW, where strtod reports success and
		// returns HUGE_VAL -- C++ only looks at end_ptr. Using ok directly rejected
		// `1.0e309` and `1.5e400`, which the oracle accepts as infinities. Compare the
		// consumed length instead: that is `*end_ptr == '\0'`.
		_, nr, _ := strconv.parse_f64_prefix(string(buf[:n]))
		return nr == n
	}

	#partial switch tok.kind {
	case .Integer:
		if !integer_value_is_valid(tok.text) {
			error(p, tok.pos, "Invalid integer literal")
		}

	case .Float:
		// The `0h` hexadecimal bit-pattern form is handled before either predicate and is
		// never invalid (src/exact_value.cpp:335-360).
		if len(tok.text) > 2 && tok.text[0] == '0' && (tok.text[1] == 'h' || tok.text[1] == 'H') {
			return
		}
		has_point_or_minus := false
		for i in 0 ..< len(tok.text) {
			if tok.text[i] == '.' || tok.text[i] == '-' {
				has_point_or_minus = true
				break
			}
		}
		if !has_point_or_minus {
			// NOTE(Jeroen): Could be an integer, see `exact_value_float_from_string`.
			if !integer_value_is_valid(tok.text) {
				error(p, tok.pos, "Invalid integer literal")
			}
		} else if !float_value_is_valid(tok.text) {
			error(p, tok.pos, "Invalid float literal")
		}

	case .Rune:
		if !escapes_are_valid(tok.text) {
			error(p, tok.pos, "Invalid rune literal")
		}

	case .String:
		if !escapes_are_valid(tok.text) {
			error(p, tok.pos, "Invalid string literal")
		}
	}
}

// escapes_are_valid is the part of unquote_char (src/string.cpp:1024-1128) that the TOKENIZER
// does not already cover.
//
// C++ splits the work: the tokenizer accepts any well-formed `\u`/`\U` escape without looking
// at its value (scan_escape assigns `max` and never reads it), and unquote_char -- called from
// exact_value_from_token, i.e. at PARSE time -- applies the one bound that exists:
//
//     if (r > GB_RUNE_MAX) { return false; }
//
// Two things follow that the port had wrong, in opposite directions:
//
//   - There is NO SURROGATE CHECK. `"\ud800"` compiles. The port rejected it from the
//     tokenizer with an invented message.
//   - `\x` is exempt: unquote_char breaks out of the switch before the test, so `"\xFF"` is
//     always fine regardless of the byte value.
//
// A raw (backtick) string has no escapes at all. LEDGER #370.
@(private)
escapes_are_valid :: proc(text: string) -> bool {
	MAX_RUNE :: 0x0010ffff

	if len(text) > 0 && text[0] == '`' {
		return true
	}
	i := 0
	for i < len(text) {
		if text[i] != '\\' {
			i += 1
			continue
		}
		i += 1
		if i >= len(text) {
			return true // the tokenizer has already reported this
		}
		count := 0
		switch text[i] {
		case 'u':
			count = 4
		case 'U':
			count = 8
		case:
			// Everything else is either a single-character escape, an octal run, or `\x`,
			// none of which unquote_char range-checks.
			i += 1
			continue
		}
		i += 1
		r := 0
		digits := 0
		for digits < count && i < len(text) {
			d := -1
			switch c := text[i]; c {
			case '0' ..= '9':
				d = int(c - '0')
			case 'a' ..= 'f':
				d = int(c - 'a') + 10
			case 'A' ..= 'F':
				d = int(c - 'A') + 10
			}
			if d < 0 {
				break
			}
			r = r << 4 | d
			digits += 1
			i += 1
		}
		if digits == count && r > MAX_RUNE {
			return false
		}
	}
	return true
}

parse_operand :: proc(p: ^Parser, lhs: bool) -> ^ast.Expr {
	#partial switch p.curr_tok.kind {
	case .Ident:
		return parse_ident(p)

	case .Undef:
		tok := expect_token(p, .Undef)
		undef := ast.new(ast.Undef, tok.pos, end_pos(tok))
		undef.tok = tok.kind
		return undef

	case .Context:
		tok := expect_token(p, .Context)
		ctx := ast.new(ast.Implicit, tok.pos, end_pos(tok))
		ctx.tok = tok
		return ctx

	case .Integer, .Float, .Imag,
	     .Rune, .String:
		tok := advance_token(p)
		check_basic_literal_value(p, tok)
		bl := ast.new(ast.Basic_Lit, tok.pos, end_pos(tok))
		bl.tok = tok
		return bl

	case .Open_Brace:
		if !lhs {
			return parse_literal_value(p, nil)
		}

	case .Open_Paren:
		open := expect_token(p, .Open_Paren)
		prev_expr_level := p.expr_level
		// C++ Reference: src/parser.cpp:2398-2407
		prev_allow_newline := p.allow_newline
		if p.expr_level < 0 {
			p.allow_newline = false
		}
		p.expr_level = max(p.expr_level, 0) + 1
		expr := parse_expr(p, false)
		p.allow_newline = prev_allow_newline
		p.expr_level = prev_expr_level
		close := expect_token(p, .Close_Paren)

		pe := ast.new(ast.Paren_Expr, open.pos, end_pos(close))
		pe.open  = open.pos
		pe.expr  = expr
		pe.close = close.pos
		return pe

	case .Distinct:
		tok := advance_token(p)
		type := parse_type(p)
		dt := ast.new(ast.Distinct_Type, tok.pos, type)
		dt.tok  = tok.kind
		dt.type = type
		return dt

	case .Hash:
		tok := expect_token(p, .Hash)
		name := expect_token(p, .Ident)
		switch name.text {
		case "type":
			type := parse_type(p)
			hp := ast.new(ast.Helper_Type, tok.pos, type)
			hp.tok  = tok.kind
			hp.type = type
			return hp

		case "file", "directory", "line", "procedure", "caller_location":
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			bd.tok  = tok
			bd.name = name.text
			return bd

		case "caller_expression":
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			bd.tok  = tok
			bd.name = name.text

			if peek_token_kind(p, .Open_Paren) {
				return parse_call_expr(p, bd)
			}
			return bd

		// REMOVED (#221): an arm here listed location/exists/load/load_directory/load_hash/
		// hash/assert/panic/defined/config and called parse_call_expr UNCONDITIONALLY, so a
		// bare `#assert` demanded a '(' and died with "Expected '(', got 'newline'".
		//
		// C++ has no case for any of these. They fall through to the catch-all
		// `ast_basic_directive` (src/parser.cpp:2519) and the POSTFIX loop turns `#assert(...)`
		// into a Call_Expr when a '(' actually follows -- so the bare form parses fine and the
		// CHECKER reports "'#assert' must be used as a call". Probes bd1/bd2.

		case "soa":
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			bd.tok  = tok
			bd.name = name.text
			original_type := parse_type(p)
			type := ast.unparen_expr(original_type)
			#partial switch t in type.derived_expr {
			case ^ast.Array_Type:         t.tag = bd
			case ^ast.Dynamic_Array_Type: t.tag = bd
			case ^ast.Pointer_Type:       t.tag = bd
			case ^ast.Fixed_Capacity_Dynamic_Array_Type: t.tag = bd
			case:
				// C++ Reference: src/parser.cpp:2447 and its three siblings (2433, 2460,
				// 2488). All four were lowercase in the port and all four dropped C++'s
				// ", got %s" tail -- the node kind, from ast_strings[type->kind]. They were
				// written together and shared the same two defects; the enumerated-array one
				// also reported at `tok` rather than the type.
				//
				// C++ reports at `type` (the unparenthesised type), not `original_type`:
				// identical for a bare type, different for `#soa (T)`.
				error_node(p, type, "Expected an array or pointer type after #%s, got %s", name.text, ast.node_kind_string(type))
			}
			return original_type

		case "row_major", "column_major":
			// C++ Reference: src/parser.cpp:2451-2464. The tag is FOLDED INTO the matrix node
			// rather than wrapped as a Tag_Expr, so it never reaches the checker's tag
			// handler -- which is why neither checker has a #row_major case there. Without
			// this the port left a Tag_Expr and the checker rejected it with "Unknown tag
			// expression, #row_major" on code C++ accepts.
			original_type := parse_type(p)
			type := ast.unparen_expr(original_type)
			#partial switch t in type.derived_expr {
			case ^ast.Matrix_Type:
				t.is_row_major = name.text == "row_major"
			case:
				error_node(p, type, "Expected a matrix type after #%s, got %s", name.text, ast.node_kind_string(type))
			}
			return original_type

		case "simd":
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			bd.tok  = tok
			bd.name = name.text
			original_type := parse_type(p)
			type := ast.unparen_expr(original_type)
			#partial switch t in type.derived_expr {
			case ^ast.Array_Type:         t.tag = bd
			case:
				error_node(p, type, "Expected a fixed array type after #%s, got %s", name.text, ast.node_kind_string(type))
			}
			return original_type

		case "partial":
			tag := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			tag.tok = tok
			tag.name = name.text
			original_expr := parse_expr(p, lhs)
			expr := ast.unparen_expr(original_expr)
			// C++ Reference: src/parser.cpp:2468-2471. A separate, EARLIER branch for the
			// nil case, with its own message that has no ", got" tail -- there is no node
			// to name. The port had no nil guard at all here.
			if expr == nil {
				error(p, name.pos, "Expected a compound literal after #%s", name.text)
				be := ast.new(ast.Bad_Expr, tok.pos, end_pos(name))
				return be
			}
			#partial switch t in expr.derived_expr {
			case ^ast.Comp_Lit:
				t.tag = tag
			case ^ast.Array_Type:
				t.tag = tag
				error(p, tok.pos, "#%s has been replaced with #sparse for non-contiguous enumerated array types", name.text)
			case:
				// C++ Reference: src/parser.cpp:2477 -- reports at `expr`, not the tag token,
				// and carries the ", got %s" tail the port dropped.
				error_node(p, expr, "Expected a compound literal after #%s, got %s", name.text, ast.node_kind_string(expr))

			}
			return original_expr

		case "sparse":
			tag := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			tag.tok = tok
			tag.name = name.text
			original_type := parse_type(p)
			type := ast.unparen_expr(original_type)
			#partial switch t in type.derived_expr {
			case ^ast.Array_Type:
				t.tag = tag
			case:
				error_node(p, type, "Expected an enumerated array type after #%s, got %s", name.text, ast.node_kind_string(type))

			}
			return original_type

		case "bounds_check", "no_bounds_check", "type_assert", "no_type_assert":
			// C++ Reference: src/parser.cpp:2492-2504 -- all four names parse an expression and
			// hand it to parse_check_directive_for_statement, which owns the flag write, the
			// duplicate check, the conflict pair and the statement-kind validation. LEDGER #304.
			operand := parse_expr(p, lhs)
			flag: ast.Node_State_Flag
			switch name.text {
			case "bounds_check":    flag = .Bounds_Check
			case "no_bounds_check": flag = .No_Bounds_Check
			case "type_assert":     flag = .Type_Assert
			case "no_type_assert":  flag = .No_Type_Assert
			case: unimplemented()
			}
			return cast(^ast.Expr)parse_check_directive_for_statement(p, cast(^ast.Node)operand, name, flag)

		case "relative":
			// C++ Reference: parser.cpp:2504-2513. #relative types have been REMOVED from
			// the language; C++ still PARSES them so it can report the removal, and the
			// removal error is unconditional. The port parsed them and said nothing, so a
			// construct the reference compiler rejects outright was silently accepted.
			// Both diagnostics anchor at the tag, so when the paren is missing they land on
			// the same position and the existing same-position merge keeps only the first --
			// which is exactly what the oracle prints.
			tag := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			tag.tok = tok
			tag.name = name.text

			tag_call: ^ast.Expr = tag
			if p.curr_tok.kind != .Open_Paren {
				error(p, tag.pos, "expected #relative(<integer type>) <type>")
			} else {
				tag_call = parse_call_expr(p, tag)
			}
			type := parse_type(p)
			error(p, tag.pos, "#relative types have now been removed in favour of \"core:relative\"")

			rt := ast.new(ast.Relative_Type, tok.pos, type)
			rt.tag = tag_call
			rt.type = type
			return rt

		// "must_tail" belongs here too -- C++ parser.cpp:2514-2516 lists all THREE names at the
		// operand level, and the port had only two. LEDGER #321: that omission is why
		// `return #must_tail f()` (directive in EXPRESSION position) fell through to
		// ast_basic_directive and died with "Expected ';', got identifier", rejecting code the
		// reference accepts. The statement-level site (line ~1880) already had all three, which
		// is what made this look like a checker gap rather than a parser one.
		case "force_inline", "force_no_inline", "must_tail":
			return parse_inlining_or_tailing_operand(p, lhs, name)
		// C++ Reference: src/parser.cpp:2519 -- the Token_Hash arm ends with a bare
		// `return ast_basic_directive(f, token, name)`.
		//
		// #216: this port had a default that built an ast.Tag_Expr and PARSED A FOLLOWING
		// EXPRESSION, so any directive not on the whitelist above needed an operand after it
		// and otherwise died with "Expected an operand" -- a SYNTAX error where C++ produces a
		// semantic one. `#branch_location` could not be parsed at all (probe cloc), which is
		// why progress#196's checker arm for it was unreachable.
		//
		// C++ constructs a TagExpr in exactly one place, parse_proc_tags (parser.cpp:2067), for
		// procedure tags like #optional_ok -- never from parse_operand. This port's
		// parse_proc_tags accumulates a bit_set instead, so this arm was Tag_Expr's only
		// producer anywhere and the node kind is now unreachable. It is left declared: it is
		// part of the public core:odin/ast surface and C++ keeps its counterpart too.
		case:
			bd := ast.new(ast.Basic_Directive, tok.pos, end_pos(tok))
			bd.tok  = tok
			bd.name = name.text
			return bd
		}

	case .Inline, .No_Inline:
		tok := advance_token(p)
		return parse_inlining_or_tailing_operand(p, lhs, tok)

	case .Proc:
		tok := expect_token(p, .Proc)

		if p.curr_tok.kind == .Open_Brace {
			open := expect_token(p, .Open_Brace)

			args: [dynamic]^ast.Expr

			for p.curr_tok.kind != .Close_Brace &&
			    p.curr_tok.kind != .EOF {
				elem := parse_expr(p, false)

				if p.curr_tok.kind == .Where {
					tok_where := expect_token(p, .Where)
					cond := parse_expr(p, false)

					be := ast.new(ast.Binary_Expr, elem.pos, end_pos(p.prev_tok))
					be.left  = elem
					be.op    = tok_where
					be.right = cond
					elem = be
				}
				append(&args, elem)

				allow_field_separator(p) or_break
			}

			close := expect_closing_brace_of_field_list(p)

			if len(args) == 0 {
				// C++ parser.cpp:2550, reproduced VERBATIM including the "a least" typo and the
				// capital E. The port had silently corrected it to "expected at least 1 argument
				// in procedure group" -- three divergences at once (case, the typo, and a dropped
				// "a" before "procedure group"). Correcting upstream's prose is still a parity
				// break: the reference compiler's text IS the specification here (#171, #185).
				// Found by the spec suite, not by parity.sh -- no swept package contains an empty
				// procedure group, so the sweeps could never have reached this line. LEDGER #347.
				error(p, tok.pos, "Expected a least 1 argument in a procedure group")
			}

			pg := ast.new(ast.Proc_Group, tok.pos, end_pos(close))
			pg.tok   = tok
			pg.open  = open.pos
			pg.args  = args[:]
			pg.close = close.pos
			return pg
		}

		type := parse_proc_type(p, tok)
		tags: ast.Proc_Tags
		where_token: tokenizer.Token
		where_clauses: []^ast.Expr

		skip_possible_newline_for_literal(p)

		if p.curr_tok.kind == .Where {
			where_token = expect_token(p, .Where)
			prev_level := p.expr_level
			p.expr_level = -1
			where_clauses = parse_rhs_expr_list(p)
			p.expr_level = prev_level
		}
		tags = parse_proc_tags(p)
		// C++ Reference: src/parser.cpp:2573-2577. #require_results is still ACCEPTED by
		// parse_proc_tags -- so that a duplicate or a pair conflict involving it is reported
		// normally -- and is rejected and cleared here instead. Reporting it inside the loop
		// would put the error at the wrong position (the '#', not the token after the list).
		if .Require_Results in tags {
			error(p, p.curr_tok.pos, "#require_results has now been replaced as an attribute @(require_results) on the declaration")
			tags -= {.Require_Results}
		}
		type.tags = tags

		if p.allow_type && p.expr_level < 0 {
			if where_token.kind != .Invalid {
				error(p, where_token.pos, "'where' clauses are not allowed on procedure types")
			}
			return type
		}
		body: ^ast.Stmt

		skip_possible_newline_for_literal(p)

		if allow_token(p, .Undef) {
			body = nil
			if where_token.kind != .Invalid {
				error(p, where_token.pos, "'where' clauses are not allowed on procedure literals without a defined body (replaced with ---)")
			}
		} else if p.curr_tok.kind == .Open_Brace {
			prev_proc := p.curr_proc
			p.curr_proc = type
			body = parse_body(p)
			p.curr_proc = prev_proc
		} else if allow_token(p, .Do) {
			prev_proc := p.curr_proc
			p.curr_proc = type
			body = convert_stmt_to_body(p, parse_stmt(p))
			p.curr_proc = prev_proc
			// C++ Reference: src/parser.cpp:2620-2628. C++ does NOT route procedure bodies
			// through parse_do_body -- it rejects `do` outright, regardless of line. The port
			// accepted it silently on the same line and invented a same-line message
			// otherwise, so `f :: proc() do x := 1` was a plain under-rejection (probe do1).
			// `{}` is a format verb in Odin's fmt, so the literal braces must be escaped as
			// `{{}}`. Left unescaped this printed "prefer %!(MISSING ARGUMENT)".
			error(p, body.pos, "'do' for procedure bodies is not allowed, prefer {{}}")
		} else {
			return type
		}

		pl := ast.new(ast.Proc_Lit, tok.pos, end_pos(p.prev_tok))
		pl.type = type
		pl.body = body
		pl.tags = tags
		pl.where_token = where_token
		pl.where_clauses = where_clauses
		return pl

	case .Dollar:
		tok := advance_token(p)
		type := parse_ident(p)
		end := type.end

		specialization: ^ast.Expr
		if allow_token(p, .Quo) {
			specialization = parse_type(p)
			end = specialization.end
		}
		if is_blank_ident(type) {
			error(p, type.pos, "Invalid polymorphic type definition with a blank identifier")
		}

		pt := ast.new(ast.Poly_Type, tok.pos, end)
		pt.dollar = tok.pos
		pt.type = type
		pt.specialization = specialization
		return pt

	case .Typeid:
		tok := advance_token(p)
		ti := ast.new(ast.Typeid_Type, tok.pos, end_pos(tok))
		ti.tok = tok.kind
		ti.specialization = nil
		return ti

	case .Pointer:
		tok := expect_token(p, .Pointer)
		elem := parse_type(p)
		ptr := ast.new(ast.Pointer_Type, tok.pos, elem)
		ptr.pointer = tok.pos
		ptr.elem = elem
		return ptr

	case .Mul:
		// C++ Reference: parser.cpp:2668-2669. Deliberate: a leading `*` in TYPE position is
		// parsed as a unary expression so that check_type_expr can reject it by name and offer
		// '^T'. Without this arm the parser bailed first and the suggestion was unreachable.
		return parse_unary_expr(p, true)

	case .Open_Bracket:
		open := expect_token(p, .Open_Bracket)
		count: ^ast.Expr
		#partial switch p.curr_tok.kind {
		case .Pointer:
			tok := expect_token(p, .Pointer)
			close := expect_token(p, .Close_Bracket)
			elem := parse_type(p)
			t := ast.new(ast.Multi_Pointer_Type, open.pos, elem)
			t.open = open.pos
			t.pointer = tok.pos
			t.close = close.pos
			t.elem = elem
			return t
		case .Dynamic:
			tok := expect_token(p, .Dynamic)
			if allow_token(p, .Semicolon) {
				capacity := parse_expr(p, false)
				close := expect_token(p, .Close_Bracket)
				elem := parse_type(p)

				da := ast.new(ast.Fixed_Capacity_Dynamic_Array_Type, open.pos, elem)
				da.open = open.pos
				da.dynamic_pos = tok.pos
				da.capacity = capacity
				da.close = close.pos
				da.elem = elem
				return da
			}

			close := expect_token(p, .Close_Bracket)
			elem := parse_type(p)
			da := ast.new(ast.Dynamic_Array_Type, open.pos, elem)
			da.open = open.pos
			da.dynamic_pos = tok.pos
			da.close = close.pos
			da.elem = elem
			return da
		case .Question:
			tok := expect_token(p, .Question)
			q := ast.new(ast.Unary_Expr, tok.pos, end_pos(tok))
			q.op = tok
			count = q
		case:
			p.expr_level += 1
			count = parse_expr(p, false)
			p.expr_level -= 1
		case .Close_Bracket:
			// handle below
		}
		close := expect_token(p, .Close_Bracket)
		elem := parse_type(p)
		at := ast.new(ast.Array_Type, open.pos, elem)
		at.open  = open.pos
		at.len   = count
		at.close = close.pos
		at.elem  = elem
		return at

	case .Map:
		tok := expect_token(p, .Map)
		expect_token(p, .Open_Bracket)
		key := parse_type(p)
		expect_token(p, .Close_Bracket)
		value := parse_type(p)

		mt := ast.new(ast.Map_Type, tok.pos, value)
		mt.tok_pos = tok.pos
		mt.key = key
		mt.value = value
		return mt

	case .Struct:
		tok := expect_token(p, .Struct)

		poly_params:     ^ast.Field_List
		align:           ^ast.Expr
		min_field_align: ^ast.Expr
		max_field_align: ^ast.Expr
		is_packed:       bool
		is_raw_union:    bool
		is_no_copy:      bool
		is_all_or_none:  bool
		is_simple:       bool
		fields:          ^ast.Field_List
		name_count:      int

		if allow_token(p, .Open_Paren) {
			param_count: int
			poly_params, param_count = parse_field_list(p, .Close_Paren, ast.Field_Flags_Record_Poly_Params)
			if param_count == 0 {
				error(p, poly_params.pos, "Expected at least 1 polymorphic parameter")
				poly_params = nil
			}
			expect_token_after(p, .Close_Paren, "parameter list")
		}

		prev_level := p.expr_level
		p.expr_level = -1
		for allow_token(p, .Hash) {
			tag := expect_token_after(p, .Ident, "#")
			switch tag.text {
			case "packed":
				if is_packed {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				is_packed = true
			case "all_or_none":
				if is_all_or_none {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				is_all_or_none = true
			case "simple":
				if is_simple {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				is_simple = true
			case "align":
				if align != nil {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				align = parse_expr(p, true)
			case "field_align":
				if min_field_align != nil {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				warn(p, tag.pos, "#field_align has been deprecated in favour of #min_field_align")
				min_field_align = parse_expr(p, true)
			case "min_field_align":
				if min_field_align != nil {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				min_field_align = parse_expr(p, true)
			case "max_field_align":
				if max_field_align != nil {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				max_field_align = parse_expr(p, true)
			case "raw_union":
				if is_raw_union {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				is_raw_union = true
			case "no_copy":
				if is_no_copy {
					error(p, tag.pos, "Duplicate struct tag '#%s'", tag.text)
				}
				is_no_copy = true
			case:
				error(p, tag.pos, "Invalid struct tag '#%s'", tag.text)
			}
		}
		p.expr_level = prev_level

		if is_raw_union && is_all_or_none {
			is_all_or_none = false
			error(p, tok.pos, "'#raw_union' cannot also be '#all_or_none'")
		}

		where_token: tokenizer.Token
		where_clauses: []^ast.Expr

		skip_possible_newline_for_literal(p)

		if p.curr_tok.kind == .Where {
			where_token = expect_token(p, .Where)
			where_prev_level := p.expr_level
			p.expr_level = -1
			where_clauses = parse_rhs_expr_list(p)
			p.expr_level = where_prev_level
		}

		skip_possible_newline_for_literal(p)
		expect_token(p, .Open_Brace)
		fields, name_count = parse_field_list(p, .Close_Brace, ast.Field_Flags_Struct)
		close := expect_closing_brace_of_field_list(p)

		st := ast.new(ast.Struct_Type, tok.pos, end_pos(close))
		st.poly_params       = poly_params
		st.align             = align
		st.min_field_align   = min_field_align
		st.max_field_align   = max_field_align
		st.is_packed         = is_packed
		st.is_raw_union      = is_raw_union
		st.is_no_copy        = is_no_copy
		st.is_all_or_none    = is_all_or_none
		st.is_simple         = is_simple
		st.fields            = fields
		st.name_count        = name_count
		st.where_token       = where_token
		st.where_clauses     = where_clauses
		return st

	case .Union:
		tok := expect_token(p, .Union)
		poly_params: ^ast.Field_List
		align:       ^ast.Expr
		is_no_nil:     bool
		is_shared_nil: bool

		if allow_token(p, .Open_Paren) {
			param_count: int
			poly_params, param_count = parse_field_list(p, .Close_Paren, ast.Field_Flags_Record_Poly_Params)
			if param_count == 0 {
				error(p, poly_params.pos, "Expected at least 1 polymorphic parameter")
				poly_params = nil
			}
			expect_token_after(p, .Close_Paren, "parameter list")
		}

		prev_level := p.expr_level
		p.expr_level = -1
		for allow_token(p, .Hash) {
			tag := expect_token_after(p, .Ident, "#")
			switch tag.text {
			case "align":
				if align != nil {
					error(p, tag.pos, "Duplicate union tag '#%s'", tag.text)
				}
				align = parse_expr(p, true)
			case "maybe":
				error(p, tag.pos, "#%s functionality has now been merged with standard 'union' functionality", tag.text)
			case "no_nil":
				if is_no_nil {
					error(p, tag.pos, "Duplicate union tag '#%s'", tag.text)
				}
				is_no_nil = true
			case "shared_nil":
				if is_shared_nil {
					error(p, tag.pos, "Duplicate union tag '#%s'", tag.text)
				}
				is_shared_nil = true
			case:
				error(p, tag.pos, "Invalid union tag '#%s'", tag.text)
			}
		}
		p.expr_level = prev_level

		if is_no_nil && is_shared_nil {
			error(p, p.curr_tok.pos, "#shared_nil and #no_nil cannot be applied together")
		}

		union_kind := ast.Union_Type_Kind.Normal
		switch {
		case is_no_nil:     union_kind = .no_nil
		case is_shared_nil: union_kind = .shared_nil
		}

		where_token: tokenizer.Token
		where_clauses: []^ast.Expr

		skip_possible_newline_for_literal(p)

		if p.curr_tok.kind == .Where {
			where_token = expect_token(p, .Where)
			where_prev_level := p.expr_level
			p.expr_level = -1
			where_clauses = parse_rhs_expr_list(p)
			p.expr_level = where_prev_level
		}


		skip_possible_newline_for_literal(p)
		expect_token_after(p, .Open_Brace, "union")

		variants: [dynamic]^ast.Expr
		for p.curr_tok.kind != .Close_Brace && p.curr_tok.kind != .EOF {
			type := parse_type(p)
			if _, ok := type.derived.(^ast.Bad_Expr); !ok {
				append(&variants, type)
			}
			allow_field_separator(p) or_break
		}

		close := expect_closing_brace_of_field_list(p)



		ut := ast.new(ast.Union_Type, tok.pos, end_pos(close))
		ut.poly_params   = poly_params
		ut.variants      = variants[:]
		ut.align         = align
		ut.where_token   = where_token
		ut.where_clauses = where_clauses
		ut.kind          = union_kind

		return ut

	case .Enum:
		tok := expect_token(p, .Enum)
		base_type: ^ast.Expr
		if p.curr_tok.kind != .Open_Brace {
			base_type = parse_type(p)
		}

		skip_possible_newline_for_literal(p)
		open := expect_token(p, .Open_Brace)
		fields := parse_elem_list(p)
		close := expect_closing_brace_of_field_list(p)

		et := ast.new(ast.Enum_Type, tok.pos, end_pos(close))
		et.base_type = base_type
		et.open = open.pos
		et.fields = fields
		et.close = close.pos
		return et

	case .Bit_Set:
		tok := expect_token(p, .Bit_Set)
		open := expect_token(p, .Open_Bracket)
		elem, underlying: ^ast.Expr

		prev_allow_range := p.allow_range
		p.allow_range = true
		elem = parse_expr(p, false)
		p.allow_range = prev_allow_range

		if allow_token(p, .Semicolon) {
			underlying = parse_type(p)
		}


		close := expect_token(p, .Close_Bracket)

		bst := ast.new(ast.Bit_Set_Type, tok.pos, end_pos(close))
		bst.tok_pos = tok.pos
		bst.open = open.pos
		bst.elem = elem
		bst.underlying = underlying
		bst.close = close.pos
		return bst
		
	case .Matrix:
		tok := expect_token(p, .Matrix)
		expect_token(p, .Open_Bracket)
		row_count := parse_expr(p, false)
		expect_token(p, .Comma)
		column_count := parse_expr(p, false)
		expect_token(p, .Close_Bracket)
		elem := parse_type(p)

		mt := ast.new(ast.Matrix_Type, tok.pos, elem)
		mt.tok_pos = tok.pos
		mt.row_count = row_count
		mt.column_count = column_count
		mt.elem = elem
		return mt
	
	case .Bit_Field:
		tok := expect_token(p, .Bit_Field)

		backing_type := parse_type_or_ident(p)
		if backing_type == nil {
			token := advance_token(p)
			error(p, token.pos, "Expected a backing type for a 'bit_field'")
		}

		skip_possible_newline_for_literal(p)
		open := expect_token_after(p, .Open_Brace, "bit_field")

		fields: [dynamic]^ast.Bit_Field_Field
		for p.curr_tok.kind != .Close_Brace && p.curr_tok.kind != .EOF {
			docs := p.lead_comment

			name := parse_ident(p)
			expect_token(p, .Colon)
			type := parse_type(p)
			expect_token(p, .Or)
			bit_size := parse_expr(p, true)

			tag: tokenizer.Token
			if p.curr_tok.kind == .String {
				tag = expect_token(p, .String)
			}
			// C++ Reference: src/parser.cpp:2788
			ok := allow_field_separator(p)

			field := ast.new(ast.Bit_Field_Field, name.pos, bit_size)

			field.name     = name
			field.type     = type
			field.bit_size = bit_size
			field.tag      = tag
			field.docs     = docs
			field.comments = p.line_comment

			append(&fields, field)

			if !ok {
				break
			}
		}

		close := expect_closing_brace_of_field_list(p)

		bf := ast.new(ast.Bit_Field_Type, tok.pos, end_pos(close))

		bf.tok_pos      = tok.pos
		bf.backing_type = backing_type
		bf.open         = open.pos
		bf.fields       = fields[:]
		bf.close        = close.pos
		return bf

	case .Asm:
		tok := expect_token(p, .Asm)

		param_types: [dynamic]^ast.Expr
		return_type: ^ast.Expr
		if allow_token(p, .Open_Paren) {
			for p.curr_tok.kind != .Close_Paren && p.curr_tok.kind != .EOF {
				t := parse_type(p)
				append(&param_types, t)
				if p.curr_tok.kind != .Comma ||
				   p.curr_tok.kind == .EOF {
					break
				}
				advance_token(p)
			}
			expect_token(p, .Close_Paren)

			if allow_token(p, .Arrow_Right) {
				return_type = parse_type(p)
			}
		}

		has_side_effects := false
		is_align_stack := false
		dialect := ast.Inline_Asm_Dialect.Default
		for allow_token(p, .Hash) {
			if p.curr_tok.kind == .Ident {
				name := advance_token(p)
				// LEDGER #319. Two divergences from parser.cpp:3115-3147, both fixed here.
				//
				// ANCHOR: C++ reports at `token` -- the DIRECTIVE's own identifier. Every one of
				// these five reported at `tok.pos`, the `asm` keyword, so on
				// `asm(...) -> i32 #side_effects #side_effects {...}` the port pointed at column 7
				// where C++ points at column 43, the second directive. Same shape as #179, where a
				// wrong anchor accounted for 88/88 of the vet-mode divergences.
				//
				// MISSING DEFAULT: the `case:` arm below did not exist, so `#bogus` on an inline
				// asm expression was accepted in silence -- a real under-rejection. Probe n7_asmbad.
				switch name.text {
				case "side_effects":
					if has_side_effects {
						error(p, name.pos, "Duplicate directive on inline asm expression: '#side_effects'")
					}
					has_side_effects = true
				case "align_stack":
					if is_align_stack {
						error(p, name.pos, "Duplicate directive on inline asm expression: '#align_stack'")
					}
					is_align_stack = true
				case "att":
					if dialect == .ATT {
						error(p, name.pos, "Duplicate directive on inline asm expression: '#att'")
					} else if dialect != .Default {
						error(p, name.pos, "Conflicting asm dialects")
					} else {
						dialect = .ATT
					}
				case "intel":
					if dialect == .Intel {
						error(p, name.pos, "Duplicate directive on inline asm expression: '#intel'")
					} else if dialect != .Default {
						error(p, name.pos, "Conflicting asm dialects")
					} else {
						dialect = .Intel
					}
				case:
					error(p, name.pos, "Invalid directive on inline asm expression: '#%s'", name.text)
				}

			} else {
				error(p, p.curr_tok.pos, "Expected an identifier after hash")
			}
		}

		skip_possible_newline_for_literal(p)
		open := expect_token(p, .Open_Brace)
		asm_string := parse_expr(p, false)
		expect_token(p, .Comma)
		constraints_string := parse_expr(p, false)
		allow_token(p, .Comma)
		close := expect_closing_brace_of_field_list(p)

		e := ast.new(ast.Inline_Asm_Expr, tok.pos, end_pos(close))
		e.tok                = tok
		e.param_types        = param_types[:]
		e.return_type        = return_type
		e.constraints_string = constraints_string
		e.has_side_effects   = has_side_effects
		e.is_align_stack     = is_align_stack
		e.dialect            = dialect
		e.open               = open.pos
		e.asm_string         = asm_string
		e.close              = close.pos

		return e

	}

	return nil
}

is_literal_type :: proc(expr: ^ast.Expr) -> bool {
	val := ast.unparen_expr(expr)
	if val == nil {
		return false
	}
	#partial switch _ in val.derived_expr {
	case ^ast.Bad_Expr,
		^ast.Ident,
		^ast.Selector_Expr,
		^ast.Array_Type,
		^ast.Struct_Type,
		^ast.Union_Type,
		^ast.Enum_Type,
		^ast.Dynamic_Array_Type,
		^ast.Fixed_Capacity_Dynamic_Array_Type,
		^ast.Map_Type,
		^ast.Bit_Set_Type,
		^ast.Matrix_Type,
		^ast.Call_Expr,
		^ast.Bit_Field_Type:
		return true
	}
	return false
}

parse_value :: proc(p: ^Parser) -> ^ast.Expr {
	prev_allow_range := p.allow_range
	defer p.allow_range = prev_allow_range
	p.allow_range = true
	return parse_expr(p, false)
}

parse_elem_list :: proc(p: ^Parser) -> []^ast.Expr {
	elems: [dynamic]^ast.Expr

	for p.curr_tok.kind != .Close_Brace && p.curr_tok.kind != .EOF {
		elem := parse_value(p)
		if p.curr_tok.kind == .Eq {
			eq := expect_token(p, .Eq)
			value := parse_value(p)

			fv := ast.new(ast.Field_Value, elem.pos, value)
			fv.field = elem
			fv.sep   = eq.pos
			fv.value = value

			elem = fv
		}

		append(&elems, elem)

		allow_field_separator(p) or_break
	}

	return elems[:]
}

parse_literal_value :: proc(p: ^Parser, type: ^ast.Expr) -> ^ast.Comp_Lit {
	elems: []^ast.Expr
	open := expect_token(p, .Open_Brace)
	prev_expr_level := p.expr_level
	p.expr_level = 0
	if p.curr_tok.kind != .Close_Brace {
		elems = parse_elem_list(p)
	}
	p.expr_level = prev_expr_level

	skip_possible_newline(p)
	close := expect_closing_brace_of_field_list(p)

	pos := type.pos if type != nil else open.pos
	lit := ast.new(ast.Comp_Lit, pos, end_pos(close))
	lit.type  = type
	lit.open  = open.pos
	lit.elems = elems
	lit.close = close.pos
	return lit
}

parse_call_expr :: proc(p: ^Parser, operand: ^ast.Expr) -> ^ast.Expr {
	args: [dynamic]^ast.Expr

	ellipsis: tokenizer.Token

	prev_expr_level := p.expr_level
	// C++ Reference: src/parser.cpp:3198-3242
	prev_allow_newline := p.allow_newline
	p.expr_level = 0
	p.allow_newline = file_allow_newline(p)
	open := expect_token(p, .Open_Paren)

	seen_ellipsis := false
	for p.curr_tok.kind != .Close_Paren &&
		p.curr_tok.kind != .EOF {

		if p.curr_tok.kind == .Comma {
			error(p, p.curr_tok.pos, "expected an expression not ,")
		} else if p.curr_tok.kind == .Eq {
			error(p, p.curr_tok.pos, "expected an expression not =")
		}

		prefix_ellipsis := false
		if p.curr_tok.kind == .Ellipsis {
			prefix_ellipsis = true
			ellipsis = expect_token(p, .Ellipsis)
		}

		arg := parse_expr(p, false)
		if p.curr_tok.kind == .Eq {
			eq := expect_token(p, .Eq)

			if prefix_ellipsis {
				error(p, ellipsis.pos, "'..' must be applied to value rather than a field name")
			}

			value := parse_value(p)
			fv := ast.new(ast.Field_Value, arg.pos, value)
			fv.field = arg
			fv.sep   = eq.pos
			fv.value = value

			arg = fv
		} else if seen_ellipsis {
			error(p, arg.pos, "Positional arguments are not allowed after '..'")
		}

		append(&args, arg)

		if ellipsis.pos.line != 0 {
			seen_ellipsis = true
		}

		allow_field_separator(p) or_break
	}

	// C++ restores allow_newline BEFORE calling expect_closing, so the missing-comma message
	// is gated on the ENCLOSING context's setting, not the argument list's. Order matters.
	p.allow_newline = prev_allow_newline
	p.expr_level = prev_expr_level
	// C++ Reference: src/parser.cpp:3244 uses expect_closing, not the field-list helper.
	close := expect_closing(p, .Close_Paren, "argument list")

	ce := ast.new(ast.Call_Expr, operand.pos, end_pos(close))
	ce.expr     = operand
	ce.open     = open.pos
	ce.args     = args[:]
	ce.ellipsis = ellipsis
	ce.close    = close.pos

	o := ast.unparen_expr(operand)
	if se, ok := o.derived.(^ast.Selector_Expr); ok && se.op.kind == .Arrow_Right {
		sce := ast.new(ast.Selector_Call_Expr, ce.pos, ce)
		sce.expr = o
		sce.call = ce
		return sce
	}

	return ce
}

empty_selector_expr :: proc(tok: tokenizer.Token, operand: ^ast.Expr) -> ^ast.Selector_Expr {
	field := ast.new(ast.Ident, tok.pos, end_pos(tok))
	field.name = ""

	sel := ast.new(ast.Selector_Expr, operand.pos, field)
	sel.expr  = operand
	sel.op = tok
	sel.field = field

	return sel
}

parse_atom_expr :: proc(p: ^Parser, value: ^ast.Expr, lhs: bool) -> (operand: ^ast.Expr) {
	operand = value
	if operand == nil {
		if p.allow_type {
			return nil
		}
		error(p, p.curr_tok.pos, "Expected an operand")
		fix_advance_to_next_stmt(p)
		be := ast.new(ast.Bad_Expr, p.curr_tok.pos, end_pos(p.curr_tok))
		operand = be
	}

	loop := true
	is_lhs := lhs
	for loop {
		#partial switch p.curr_tok.kind {
		case:
			loop = false

		case .Open_Paren:
			operand = parse_call_expr(p, operand)

		case .Open_Bracket:
			prev_allow_range := p.allow_range
			defer p.allow_range = prev_allow_range
			p.allow_range = false

			indices: [2]^ast.Expr
			interval: tokenizer.Token
			is_slice_op := false

			p.expr_level += 1
			open := expect_token(p, .Open_Bracket)

			// C++ Reference: src/parser.cpp:3342-3355. An EMPTY index -- `a[]` -- has its own
			// branch which the port lacked entirely. C++ reports "Expected an operand, got ]",
			// CONSUMES the ']', builds an index expression with a nil index and breaks.
			//
			// Without it the port fell through to the general operand parse, emitted the
			// tail-less "Expected an operand" from parse_atom_expr, never consumed the ']',
			// and then cascaded a second error ("Expected ']', got ';'") that C++ never emits.
			// A recovery divergence, not a wording one.
			if p.curr_tok.kind == .Close_Bracket {
				error(p, p.curr_tok.pos, "Expected an operand, got ]")
				close := expect_token(p, .Close_Bracket)

				// NOT PORTED, and stated rather than silently dropped: C++ wraps this in an
				// ERROR_BLOCK and, when allow_type is set, appends
				//   "\tSuggestion: If a type was wanted, did you mean '[]%s'?"
				// using expr_to_string(operand) (parser.cpp:3347-3351). The port's parser
				// package has NEITHER facility -- it exposes only error/warn, with no
				// continuation channel and no expression printer; both live in the checker,
				// which the parser must not depend on. Adding them is a package-structure
				// change, not a one-liner. The primary diagnostic and, more importantly, the
				// RECOVERY (consuming the ']') are faithful. Filed as #204.

				ie := ast.new(ast.Index_Expr, operand.pos, end_pos(close))
				ie.expr  = operand
				ie.index = nil
				ie.open  = open.pos
				ie.close = close.pos
				operand = ie
				break
			}

			#partial switch p.curr_tok.kind {
			case .Colon, .Ellipsis, .Range_Half, .Range_Full:
				// NOTE(bill): Do not err yet
				break
			case:
				indices[0] = parse_expr(p, false)
			}

			#partial switch p.curr_tok.kind {
			case .Ellipsis, .Range_Half, .Range_Full:
				error(p, p.curr_tok.pos, "Expected a colon, not a range")
				fallthrough
			case .Colon, .Comma/*matrix index*/:
				interval = advance_token(p)
				is_slice_op = true
				if p.curr_tok.kind != .Close_Bracket && p.curr_tok.kind != .EOF {
					indices[1] = parse_expr(p, false)
				}
			}

			p.expr_level -= 1
			close := expect_token(p, .Close_Bracket)

			if is_slice_op {
				if interval.kind == .Comma {
					if indices[0] == nil || indices[1] == nil {
						error(p, p.curr_tok.pos, "Matrix index expressions require both row and column indices")
					}
					se := ast.new(ast.Matrix_Index_Expr, operand.pos, end_pos(close))
					se.expr = operand
					se.open = open.pos
					se.row_index = indices[0]
					se.column_index = indices[1]
					se.close = close.pos

					operand = se
				} else {
					se := ast.new(ast.Slice_Expr, operand.pos, end_pos(close))
					se.expr = operand
					se.open = open.pos
					se.low = indices[0]
					se.interval = interval
					se.high = indices[1]
					se.close = close.pos

					operand = se
				}
			} else {
				ie := ast.new(ast.Index_Expr, operand.pos, end_pos(close))
				ie.expr = operand
				ie.open = open.pos
				ie.index = indices[0]
				ie.close = close.pos

				operand = ie
			}


		case .Period:
			tok := expect_token(p, .Period)
			#partial switch p.curr_tok.kind {
			case .Ident:
				field := parse_ident(p)

				sel := ast.new(ast.Selector_Expr, operand.pos, field)
				sel.expr  = operand
				sel.op = tok
				sel.field = field

				operand = sel

			case .Open_Paren:
				open := expect_token(p, .Open_Paren)
				type := parse_type(p)
				close := expect_token(p, .Close_Paren)

				ta := ast.new(ast.Type_Assertion, operand.pos, end_pos(close))
				ta.expr  = operand
				ta.open  = open.pos
				ta.type  = type
				ta.close = close.pos

				operand = ta

			case .Question:
				question := expect_token(p, .Question)
				type := ast.new(ast.Unary_Expr, question.pos, end_pos(question))
				type.op = question
				type.expr = nil

				ta := ast.new(ast.Type_Assertion, operand.pos, type)
				ta.expr  = operand
				ta.type  = type

				operand = ta

			case:
				error(p, p.curr_tok.pos, "Expected a selector")
				operand = empty_selector_expr(tok, operand)
			}

		case .Arrow_Right:
			tok := expect_token(p, .Arrow_Right)
			#partial switch p.curr_tok.kind {
			case .Ident:
				field := parse_ident(p)

				sel := ast.new(ast.Selector_Expr, operand.pos, field)
				sel.expr  = operand
				sel.op = tok
				sel.field = field

				operand = sel
			case:
				error(p, p.curr_tok.pos, "Expected a selector")
				operand = empty_selector_expr(tok, operand)
			}

		case .Pointer:
			op := expect_token(p, .Pointer)
			deref := ast.new(ast.Deref_Expr, operand.pos, end_pos(op))
			deref.expr = operand
			deref.op   = op

			operand = deref

		case .Or_Return:
			token := expect_token(p, .Or_Return)
			oe := ast.new(ast.Or_Return_Expr, operand.pos, end_pos(token))
			oe.expr  = operand
			oe.token = token

			operand = oe

		case .Or_Break, .Or_Continue:
			token := advance_token(p)
			label: ^ast.Ident

			end := end_pos(token)
			if p.curr_tok.kind == .Ident {
				end = end_pos(p.curr_tok)
				label = parse_ident(p)
			}

			oe := ast.new(ast.Or_Branch_Expr, operand.pos, end)
			oe.expr  = operand
			oe.token = token
			oe.label = label

			operand = oe

		case .Open_Brace:
			if !is_lhs && is_literal_type(operand) && p.expr_level >= 0 {
				operand = parse_literal_value(p, operand)
			} else {
				loop = false
			}

		case .Increment, .Decrement:
			if !lhs {
				tok := advance_token(p)
				error(p, tok.pos, "Postfix '%s' operator is not supported", tok.text)
			} else {
				loop = false
			}
		}

		is_lhs = false
	}

	return operand

}

parse_expr :: proc(p: ^Parser, lhs: bool) -> ^ast.Expr {
	return parse_binary_expr(p, lhs, 0+1)
}
parse_unary_expr :: proc(p: ^Parser, lhs: bool) -> ^ast.Expr {
	#partial switch p.curr_tok.kind {
	case .Transmute, .Cast:
		tok := advance_token(p)
		open := expect_token(p, .Open_Paren)
		type := parse_type(p)
		close := expect_token(p, .Close_Paren)
		expr := parse_unary_expr(p, lhs)

		tc := ast.new(ast.Type_Cast, tok.pos, expr)
		tc.tok   = tok
		tc.open  = open.pos
		tc.type  = type
		tc.close = close.pos
		tc.expr  = expr
		return tc

	case .Auto_Cast:
		op := advance_token(p)
		expr := parse_unary_expr(p, lhs)

		ac := ast.new(ast.Auto_Cast, op.pos, expr)
		ac.op   = op
		ac.expr = expr
		return ac

	case .Add, .Sub,
	     .Not, .Xor,
	     .And,
	     .Mul_Mul,
	     .Mul: // C++ Reference: parser.cpp:3483 -- "Used for error handling when people do
	           // C-like things". `*T` must PARSE so the checker can reject it with the
	           // "Did you mean '^T'?" suggestion; the port omitted .Mul here and in
	           // parse_operand, so `b: *int` died in the parser with two syntax errors
	           // where C++ emits one checker diagnostic plus the suggestion.
		op := advance_token(p)
		if op.kind == .Not {
			// C++ Reference: parser.cpp:3486-3488.
			skip_possible_newline(p)
		}
		expr := parse_unary_expr(p, lhs)

		ue := ast.new(ast.Unary_Expr, op.pos, expr)
		ue.op   = op
		ue.expr = expr
		return ue

	case .Increment, .Decrement:
		op := advance_token(p)
		error(p, op.pos, "Unary '%s' operator is not supported", op.text)
		expr := parse_unary_expr(p, lhs)

		ue := ast.new(ast.Unary_Expr, op.pos, expr)
		ue.op   = op
		ue.expr = expr
		return ue

	case .Period:
		op := advance_token(p)
		field := parse_ident(p)
		ise := ast.new(ast.Implicit_Selector_Expr, op.pos, field)
		ise.field = field
		return ise

	}
	return parse_atom_expr(p, parse_operand(p, lhs), lhs)
}
parse_binary_expr :: proc(p: ^Parser, lhs: bool, prec_in: int) -> ^ast.Expr {
	expr := parse_unary_expr(p, lhs)

	// C++ Reference: src/parser.cpp:3573-3574. C++ takes parse_unary_expr's result and goes
	// straight into the operator loop; it never substitutes anything when the result is null,
	// and it can return null.
	//
	// The port had an INVENTED early return here that manufactured a Bad_Expr from a nil expr.
	// That is not a cosmetic difference: parse_atom_expr deliberately returns nil while
	// allow_type is set (matching C++ at parser.cpp:3273), which is how "no operand here" is
	// signalled to a type context. Converting that nil into a Bad_Expr destroyed the signal.
	//
	// The visible consequence was on `x: () = 1`. C++ leaves Paren_Expr.expr as nullptr, so the
	// checker's ParenExpr arm (check_type.cpp:3702) sees it and reports "Expected an expression
	// or type within the parentheses". The port stored a Bad_Expr instead, so its own equivalent
	// guard -- which is present and correct at check_type.odin:192 -- could never fire; checking
	// recursed into the Bad_Expr and fell through to the "'%s' is not a type" default arm.
	//
	// The operator loop below dereferences expr.pos for the ternary forms, so a nil expr
	// followed by a binary/ternary operator would fault -- but C++ has exactly the same shape
	// and the same exposure, and it is unreachable for the empty-paren case because ')' has no
	// precedence and the loop is never entered.
	for prec := token_precedence(p, p.curr_tok.kind); prec >= prec_in; prec -= 1 {
		loop: for {
			op := p.curr_tok
			op_prec := token_precedence(p, op.kind)
			if op_prec != prec {
				break loop
			}

			#partial switch op.kind {
			case .If, .When:
				if p.prev_tok.pos.line < op.pos.line {
					// NOTE(bill): Check to see if the `if` or `when` is on the same line of the `lhs` condition
					if p.expr_level <= 0 {
						break loop
					}
				}
			}

			expect_operator(p)

			#partial switch op.kind {
			case .Question:

				cond := expr
				x := parse_expr(p, lhs)
				colon := expect_token(p, .Colon)
				y := parse_expr(p, lhs)
				te := ast.new(ast.Ternary_If_Expr, expr.pos, end_pos(p.prev_tok))
				te.cond = cond
				te.op1  = op
				te.x    = x
				te.op2  = colon
				te.y    = y

				expr = te
			case .If:
				x := expr
				cond := parse_expr(p, lhs)
				else_tok := expect_token(p, .Else)
				y := parse_expr(p, lhs)
				te := ast.new(ast.Ternary_If_Expr, expr.pos, end_pos(p.prev_tok))
				te.x    = x
				te.op1  = op
				te.cond = cond
				te.op2  = else_tok
				te.y    = y

				expr = te
			case .When:
				x := expr
				cond := parse_expr(p, lhs)
				skip_possible_newline(p)
				else_tok := expect_token(p, .Else)
				y := parse_expr(p, lhs)
				te := ast.new(ast.Ternary_When_Expr, expr.pos, end_pos(p.prev_tok))
				te.x    = x
				te.op1  = op
				te.cond = cond
				te.op2  = else_tok
				te.y    = y

				expr = te
			case .Or_Else:
				x := expr
				y := parse_expr(p, lhs)
				oe := ast.new(ast.Or_Else_Expr, expr.pos, end_pos(p.prev_tok))
				oe.x     = x
				oe.token = op
				oe.y     = y

				expr = oe

			case:
				right := parse_binary_expr(p, false, prec+1)
				if right == nil {
					error(p, op.pos, "expected expression on the right-hand side of the binary operator")
				}
				be := ast.new(ast.Binary_Expr, expr.pos, end_pos(p.prev_tok))
				be.left  = expr
				be.op    = op
				be.right = right

				expr = be
			}
		}
	}

	return expr
}


parse_expr_list :: proc(p: ^Parser, lhs: bool) -> ([]^ast.Expr) {
	// C++ Reference: src/parser.cpp:3642-3656
	prev_allow_newline := p.allow_newline
	defer p.allow_newline = prev_allow_newline
	p.allow_newline = file_allow_newline(p)

	list: [dynamic]^ast.Expr
	for {
		expr := parse_expr(p, lhs)
		append(&list, expr)
		if p.curr_tok.kind != .Comma || p.curr_tok.kind == .EOF {
			break
		}
		advance_token(p)
	}

	return list[:]
}
parse_lhs_expr_list :: proc(p: ^Parser) -> []^ast.Expr {
	return parse_expr_list(p, true)
}
parse_rhs_expr_list :: proc(p: ^Parser) -> []^ast.Expr {
	return parse_expr_list(p, false)
}

parse_simple_stmt :: proc(p: ^Parser, flags: Stmt_Allow_Flags) -> ^ast.Stmt {
	start_tok := p.curr_tok
	docs := p.lead_comment

	lhs := parse_lhs_expr_list(p)
	op := p.curr_tok
	switch {
	case tokenizer.is_assignment_operator(op.kind):
		// LEDGER #325. C++ parser.cpp:3859-3862 has this guard LIVE. The port had it
		// COMMENTED OUT, and with a reworded message ("simple statements are not allowed at
		// the file scope" for C++'s "You cannot use a simple statement in the file scope").
		//
		// That is the mirror image of #171, where the port had LIVE a bail C++ has commented
		// out. The rule is the same in both directions: the reference decides, not the
		// comment. Commented-out code is not a neutral state -- here it silently disabled a
		// real rejection.
		//
		// Without it, `x = 2` at file scope was accepted in SILENCE -- errors=0, raw_diags=0
		// -- where C++ reports two diagnostics. Probe c25_filescope. Note the port already
		// had this exact shape LIVE in parse_for_stmt ("You cannot use a for statement in the
		// file scope"), so the pattern was never in doubt, only this instance of it.
		if p.curr_proc == nil {
			error(p, p.curr_tok.pos, "You cannot use a simple statement in the file scope")
			return ast.new(ast.Bad_Stmt, p.curr_tok.pos, end_pos(p.curr_tok))
		}
		advance_token(p)
		rhs := parse_rhs_expr_list(p)
		if len(rhs) == 0 {
			error(p, p.curr_tok.pos, "No right-hand side in assignment statement.")
			return ast.new(ast.Bad_Stmt, start_tok.pos, end_pos(p.curr_tok))
		}
		stmt := ast.new(ast.Assign_Stmt, lhs[0].pos, rhs[len(rhs)-1])
		stmt.lhs = lhs
		stmt.op = op
		stmt.rhs = rhs
		return stmt

	case op.kind == .In:
		if .In in flags {
			allow_token(p, .In)
			prev_allow_range := p.allow_range
			p.allow_range = true
			expr := parse_expr(p, false)
			p.allow_range = prev_allow_range

			rhs := make([]^ast.Expr, 1)
			rhs[0] = expr

			stmt := ast.new(ast.Assign_Stmt, lhs[0].pos, rhs[len(rhs)-1])
			stmt.lhs = lhs
			stmt.op = op
			stmt.rhs = rhs
			return stmt
		}
	case op.kind == .Colon:
		expect_token_after(p, .Colon, "identifier list")
		if .Label in flags && len(lhs) == 1 {
			is_partial := false
			is_reverse := false

			partial_token: tokenizer.Token
			if p.curr_tok.kind == .Hash {
				name := peek_token(p)
				if name.kind == .Ident && name.text == "partial" &&
				   peek_token(p, 1).kind == .Switch {
					partial_token = expect_token(p, .Hash)
					expect_token(p, .Ident)
					is_partial = true
				} else if name.kind == .Ident && name.text == "reverse" &&
				          peek_token(p, 1).kind == .For {
					partial_token = expect_token(p, .Hash)
					expect_token(p, .Ident)
					is_reverse = true
				}
			}

			#partial switch p.curr_tok.kind {
			case .Open_Brace, .If, .For, .Switch:
				label := lhs[0]
				stmt := parse_stmt(p)

				if stmt != nil {
					#partial switch n in stmt.derived_stmt {
					case ^ast.Block_Stmt:       n.label = label
					case ^ast.If_Stmt:          n.label = label
					case ^ast.For_Stmt:         n.label = label
					case ^ast.Switch_Stmt:      n.label = label
					case ^ast.Type_Switch_Stmt: n.label = label
					case ^ast.Range_Stmt:	    n.label = label
					}

					if is_partial {
						#partial switch n in stmt.derived_stmt {
						case ^ast.Switch_Stmt:      n.partial = true
						case ^ast.Type_Switch_Stmt: n.partial = true
						case:
							error(p, partial_token.pos, "Incorrect use of directive, use '%s: #partial switch'", partial_token.text)
						}
					}
					if is_reverse {
						#partial switch n in stmt.derived_stmt {
						case ^ast.Range_Stmt: n.reverse = true
						case:
							error(p, partial_token.pos, "incorrect use of directive, use '%s: #reverse for'", partial_token.text)
						}
					}
				}

				return stmt
			}
		}
		return parse_value_decl(p, lhs, docs)
	}

	if len(lhs) > 1 {
		error(p, op.pos, "expected 1 expression, got %d", len(lhs))
		return ast.new(ast.Bad_Stmt, start_tok.pos, end_pos(p.curr_tok))
	}

	#partial switch op.kind {
	case .Increment, .Decrement:
		advance_token(p)
		error(p, op.pos, "Postfix '%s' statement is not supported", op.text)
	}

	es := ast.new(ast.Expr_Stmt, lhs[0].pos, lhs[0])
	es.expr = lhs[0]
	return es
}

parse_value_decl :: proc(p: ^Parser, names: []^ast.Expr, docs: ^ast.Comment_Group) -> ^ast.Decl {
	is_mutable := true

	values: []^ast.Expr
	type := parse_type_or_ident(p)

	#partial switch p.curr_tok.kind {
	case .Eq, .Colon:
		sep := advance_token(p)
		is_mutable = sep.kind != .Colon

		values = parse_rhs_expr_list(p)
		if len(values) > len(names) {
			error(p, p.curr_tok.pos, "Too many values on the right hand side of the declaration")
		} else if len(values) < len(names) && !is_mutable {
			error(p, p.curr_tok.pos, "All constant declarations must be defined")
		} else if len(values) == 0 {
			error(p, p.curr_tok.pos, "Expected an expression for this declaration")
		}
	}

	if is_mutable {
		if type == nil && len(values) == 0 {
			error(p, p.curr_tok.pos, "Missing variable type or initialization")
			return ast.new(ast.Bad_Decl, names[0].pos, end_pos(p.curr_tok))
		}
	} else {
		if type == nil && len(values) == 0 && len(names) > 0 {
			error(p, p.curr_tok.pos, "Missing constant value")
			return ast.new(ast.Bad_Decl, names[0].pos, end_pos(p.curr_tok))
		}
	}

	end := p.prev_tok

	if p.expr_level >= 0 {
		end: ^ast.Expr
		if !is_mutable && len(values) > 0 {
			end = values[len(values)-1]
		}
		if p.curr_tok.kind == .Close_Brace &&
		   p.curr_tok.pos.line == p.prev_tok.pos.line {

		} else {
			expect_semicolon(p, end)
		}
	}

	if p.curr_proc == nil {
		if len(values) > 0 && len(names) != len(values) {
			// C++ Reference: src/parser.cpp:3822-3831. ONE diagnostic, whose format string
			// carries the Note as an embedded continuation line:
			//
			//     syntax_error(values[0],
			//         "Expected %td expressions on the right hand side, got %td\n"
			//         "\tNote: Global declarations do not allow for multi-valued expressions",
			//         names.count, values.count);
			//
			// The port had the wording lowercased and hyphenated ("expected ... right-hand
			// side") and dropped the Note entirely, so `a, b := 1` at file scope lost the one
			// line that explains WHY it is rejected there but allowed inside a procedure.
			// Probe bp_arity. LEDGER #376.
			error(
				p,
				values[0].pos,
				"Expected %d expressions on the right hand side, got %d\n" +
				"\tNote: Global declarations do not allow for multi-valued expressions",
				len(names),
				len(values),
			)
		}
	}

	decl := ast.new(ast.Value_Decl, names[0].pos, end_pos(end))
	decl.docs = docs
	decl.names = names
	decl.type = type
	decl.values = values
	decl.is_mutable = is_mutable
	return decl
}


parse_import_decl :: proc(p: ^Parser, kind := Import_Decl_Kind.Standard) -> ^ast.Import_Decl {
	docs := p.lead_comment
	tok := expect_token(p, .Import)

	import_name: tokenizer.Token
	is_using := kind != Import_Decl_Kind.Standard

	#partial switch p.curr_tok.kind {
	case .Ident:
		import_name = advance_token(p)
	case:
		import_name.pos = p.curr_tok.pos
	}

	path := expect_token_after(p, .String, "import")

	decl := ast.new(ast.Import_Decl, tok.pos, end_pos(path))
	decl.docs       = docs
	decl.is_using   = is_using
	decl.import_tok = tok
	decl.name       = import_name
	decl.relpath    = path
	decl.fullpath   = path.text

	if p.curr_proc != nil {
		error(p, decl.pos, "import declarations cannot be used within a procedure, it must be done at the file scope")
	} else {
		append(&p.file.imports, decl)
	}
	expect_semicolon(p, decl)
	decl.comment = p.line_comment

	return decl
}
