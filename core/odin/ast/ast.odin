// Abstract Syntax Tree for the `Odin` parser packages.
package odin_ast

import "core:container/queue"
import "core:odin/tokenizer"

Proc_Tag :: enum {
	Bounds_Check,
	No_Bounds_Check,
	Type_Assert,
	No_Type_Assert,
	Require_Results,
	Optional_Ok,
	Optional_Allocator_Error,
}
Proc_Tags :: distinct bit_set[Proc_Tag; u32]

Proc_Inlining :: enum u32 {
	None      = 0,
	Inline    = 1,
	No_Inline = 2,
}

Proc_Tailing :: enum u32 {
	None      = 0,
	Must_Tail = 1,
}

Proc_Calling_Convention_Extra :: enum i32 {
	Foreign_Block_Default,
}
Proc_Calling_Convention :: union {
	string,
	Proc_Calling_Convention_Extra,
}

Node_State_Flag :: enum {
	Bounds_Check,
	No_Bounds_Check,
	Type_Assert,
	No_Type_Assert,
	Selector_Call_Expr,
	Directive_Was_False,
	Been_Handled,
}
Node_State_Flags :: distinct bit_set[Node_State_Flag]

Node_Viral_State_Flag :: enum u8 {
	Contains_Deferred_Procedure,
	Contains_Or_Break,
	Contains_Or_Return,
}
Node_Viral_State_Flags :: distinct bit_set[Node_Viral_State_Flag;u8]

// File-level flags from directives (#private, #load, etc.)
File_Flag :: enum u32 {
	Is_Private_Pkg     = 0,  // From #private
	Is_Private_File    = 1,  // From #private file
	Is_Lazy            = 4,  // From #load with lazy flag
	No_Instrumentation = 5,  // From #no_instrumentation
}
File_Flags :: bit_set[File_Flag; u32]

// Vet flags for code quality warnings (#vet)
Vet_Flag_Bit :: enum {
	Shadowing           = 0,
	Using_Stmt          = 1,
	Using_Param         = 2,
	Style               = 3,
	Semicolon           = 4,
	Unused_Variables    = 5,
	Unused_Imports      = 6,
	Deprecated          = 7,
	Cast                = 8,
	Tabs                = 9,
	Unused_Procedures   = 10,
	Explicit_Allocators = 11,
}
Vet_Flags :: distinct bit_set[Vet_Flag_Bit; u64]

// Feature flags for opt-in language features (#feature)
Feature_Flag_Bit :: enum {
	Dynamic_Literals                  = 0,
	Global_Context                    = 1,
	Integer_Division_By_Zero_Trap     = 2,
	Integer_Division_By_Zero_Zero     = 3,
	Integer_Division_By_Zero_Self     = 4,
	Integer_Division_By_Zero_All_Bits = 5,
}
Feature_Flags :: distinct bit_set[Feature_Flag_Bit; u64]

Node :: struct {
	pos:         tokenizer.Pos,
	end:         tokenizer.Pos,
	state_flags: Node_State_Flags,
	derived:     Any_Node,

	// Semantic Analysis Fields
	viral_state_flags: Node_Viral_State_Flags, // Flags that propagate up the tree
	file_id:           i32,                     // File ID for this node
	tav:               Type_And_Value, 
}

Comment_Group :: struct {
	using node: Node,
	list: []tokenizer.Token,
}

Package_Kind :: enum {
	Normal,
	Runtime,
	Init,
}

// Package_Exported_Entity represents an exported entity from a package.
// Used for multi-threaded entity collection during semantic analysis.
Package_Exported_Entity :: struct {
	identifier: ^Node,   // Identifier node for the exported entity
	entity:     ^Entity, // The exported entity itself
}

Package :: struct {
	using node: Node,
	kind:     Package_Kind,
	id:       int,
	name:     string,
	fullpath: string,
	files:    map[string]^File,

	user_data: rawptr,

	// Semantic Analysis Fields
	order:      int,        // Package order for dependency resolution
	scope:      ^Scope,     // Package-level scope
	decl_info:  ^Decl_Info, // Package declaration info
	is_extra:   bool,       // Extra package flag (runtime, vendor, etc.)

	// Exported entity queue for multi-threaded entity collection
	exported_entity_queue: queue.MPMC_Queue(Package_Exported_Entity),
}

File :: struct {
	using node: Node,
	id: int,
	pkg: ^Package,

	fullpath: string,
	src:      string,

	tags: [dynamic]tokenizer.Token,
	docs: ^Comment_Group, // possibly nil

	pkg_decl:  ^Package_Decl,
	pkg_token: tokenizer.Token,
	pkg_name:  string,

	decls:   [dynamic]^Stmt,
	imports: [dynamic]^Import_Decl,
	directive_count: int,

	comments: [dynamic]^Comment_Group,

	syntax_warning_count: int,
	syntax_error_count:   int,

	// Semantic Analysis Fields
	scope: ^Scope, // File-level lexical scope

	flags:             File_Flags,  // File-level directive flags
	vet_flags:         Vet_Flags,   // Vet directive flags
	feature_flags:     Feature_Flags, // Feature directive flags
	vet_flags_set:     bool,        // Whether vet flags were explicitly set
	feature_flags_set: bool,        // Whether feature flags were explicitly set

	// Delayed declaration queues (temporary checker working state)
	delayed_decls_import:        [dynamic]^Stmt,  // Deferred import processing
	delayed_decls_foreign_block: [dynamic]^Stmt,  // Deferred foreign block processing
	delayed_decls_expr:          [dynamic]^Expr,  // Deferred directive expression processing
}


// Base Types

Expr :: struct {
	using expr_base: Node,
	derived_expr: Any_Expr,
}
Stmt :: struct {
	using stmt_base: Node,
	derived_stmt: Any_Stmt,
}
Decl :: struct {
	using decl_base: Stmt,
}

// Expressions

Bad_Expr :: struct {
	using node: Expr,
}

Ident :: struct {
	using node: Expr,
	name: string,

	// Semantic Analysis Fields
	entity: ^Entity, 
}

Implicit :: struct {
	using node: Expr,
	tok: tokenizer.Token,
}


Undef :: struct {
	using node: Expr,
	tok:  tokenizer.Token_Kind,
}

Basic_Lit :: struct {
	using node: Expr,
	tok: tokenizer.Token,
}

Basic_Directive :: struct {
	using node: Expr,
	tok:  tokenizer.Token,
	name: string,
}

Ellipsis :: struct {
	using node: Expr,
	tok:  tokenizer.Token_Kind,
	expr: ^Expr, // possibly nil
}

Proc_Lit :: struct {
	using node: Expr,
	type:          ^Proc_Type,
	body:          ^Stmt, // nil when it represents a foreign procedure
	tags:          Proc_Tags,
	inlining:      Proc_Inlining,
	tailing:       Proc_Tailing,
	where_token:   tokenizer.Token,
	where_clauses: []^Expr,

	// Semantic Analysis Fields
	decl: ^Decl_Info, // Declaration information for this procedure
}

Comp_Lit :: struct {
	using node: Expr,
	type:  ^Expr, // nil when type is inferred
	open:  tokenizer.Pos,
	elems: []^Expr,
	close: tokenizer.Pos,
	tag:   ^Expr, // possibly nil
}


Tag_Expr :: struct {
	using node: Expr,
	op:      tokenizer.Token,
	name:    string,
	expr:    ^Expr,
}

Unary_Expr :: struct {
	using node: Expr,
	op:   tokenizer.Token,
	expr: ^Expr, // nil in the case of `[?]T` or `x.?`
}

Binary_Expr :: struct {
	using node: Expr,
	left:  ^Expr,
	op:    tokenizer.Token,
	right: ^Expr,
}

Paren_Expr :: struct {
	using node: Expr,
	open:  tokenizer.Pos,
	expr:  ^Expr,
	close: tokenizer.Pos,
}

Selector_Expr :: struct {
	using node: Expr,
	expr:  ^Expr,
	op:    tokenizer.Token,
	field: ^Ident,
}

Implicit_Selector_Expr :: struct {
	using node: Expr,
	field: ^Ident,
}

Selector_Call_Expr :: struct {
	using node: Expr,
	expr: ^Expr,
	call: ^Call_Expr,
	modified_call: bool,
}

Index_Expr :: struct {
	using node: Expr,
	expr:  ^Expr,
	open:  tokenizer.Pos,
	index: ^Expr,
	close: tokenizer.Pos,
}

Deref_Expr :: struct {
	using node: Expr,
	expr: ^Expr,
	op:   tokenizer.Token,
}

Slice_Expr :: struct {
	using node: Expr,
	expr:     ^Expr,
	open:     tokenizer.Pos,
	low:      ^Expr,         // possibly nil
	interval: tokenizer.Token,
	high:     ^Expr,         // possibly nil
	close:    tokenizer.Pos,
}

Matrix_Index_Expr :: struct {
	using node: Expr,
	expr:         ^Expr,
	open:         tokenizer.Pos,
	row_index:    ^Expr,
	column_index: ^Expr,
	close:        tokenizer.Pos,
}

Call_Expr :: struct {
	using node: Expr,
	inlining: Proc_Inlining,
	tailing:  Proc_Tailing,
	expr:     ^Expr,
	open:     tokenizer.Pos,
	args:     []^Expr,
	ellipsis: tokenizer.Token,
	close:    tokenizer.Pos,

	// Semantic Analysis Fields
	entity_procedure_of: ^Entity, // Entity of the procedure being called
}

Field_Value :: struct {
	using node: Expr,
	field:   ^Expr,
	sep:     tokenizer.Pos,
	value:   ^Expr,
	docs:    ^Comment_Group, // possibly nil
	comment: ^Comment_Group, // possibly nil
}

Ternary_If_Expr :: struct {
	using node: Expr,
	x:    ^Expr,
	op1:  tokenizer.Token,
	cond: ^Expr,
	op2:  tokenizer.Token,
	y:    ^Expr,
}

Ternary_When_Expr :: struct {
	using node: Expr,
	x:    ^Expr,
	op1:  tokenizer.Token,
	cond: ^Expr,
	op2:  tokenizer.Token,
	y:    ^Expr,
}

Or_Else_Expr :: struct {
	using node: Expr,
	x:     ^Expr,
	token: tokenizer.Token,
	y:     ^Expr,
}

Or_Return_Expr :: struct {
	using node: Expr,
	expr:  ^Expr,
	token: tokenizer.Token,
}

Or_Branch_Expr :: struct {
	using node: Expr,
	expr:  ^Expr,
	token: tokenizer.Token,
	label: ^Expr, // possibly nil when not used
}

Type_Assertion :: struct {
	using node: Expr,
	expr:  ^Expr,
	dot:   tokenizer.Pos,
	open:  tokenizer.Pos,
	type:  ^Expr,
	close: tokenizer.Pos,

	// Semantic Analysis Fields
	type_hint: ^Type, // Resolved type hint for optimization
	ignores:   [2]bool, // Mark which values are ignored in optional-ok unpacking (backend optimization)
}

Type_Cast :: struct {
	using node: Expr,
	tok:   tokenizer.Token,
	open:  tokenizer.Pos,
	type:  ^Expr,
	close: tokenizer.Pos,
	expr:  ^Expr,
}

Auto_Cast :: struct {
	using node: Expr,
	op:   tokenizer.Token,
	expr: ^Expr,
}

Inline_Asm_Dialect :: enum u8 {
	Default = 0,
	ATT     = 1,
	Intel   = 2,
}


Inline_Asm_Expr :: struct {
	using node: Expr,
	tok:                tokenizer.Token,
	param_types:        []^Expr,
	return_type:        ^Expr,
	has_side_effects:   bool,
	is_align_stack:     bool,
	dialect:            Inline_Asm_Dialect,
	open:               tokenizer.Pos,
	constraints_string: ^Expr,
	asm_string:         ^Expr,
	close:              tokenizer.Pos,
}




// Statements

Bad_Stmt :: struct {
	using node: Stmt,
}

Empty_Stmt :: struct {
	using node: Stmt,
	semicolon: tokenizer.Pos, // Position of the following ';'
}

Expr_Stmt :: struct {
	using node: Stmt,
	expr: ^Expr,
}

Tag_Stmt :: struct {
	using node: Stmt,
	op:      tokenizer.Token,
	name:    string,
	stmt:    ^Stmt,
}

Assign_Stmt :: struct {
	using node: Stmt,
	lhs:    []^Expr,
	op:     tokenizer.Token,
	rhs:    []^Expr,
}


Block_Stmt :: struct {
	using node: Stmt,
	label: ^Expr,
	open:  tokenizer.Pos,
	stmts: []^Stmt,
	close: tokenizer.Pos,
	uses_do: bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this block
}

If_Stmt :: struct {
	using node: Stmt,
	label:     ^Expr, // possibly nil
	if_pos:    tokenizer.Pos,
	init:      ^Stmt, // possibly nil
	cond:      ^Expr,
	body:      ^Stmt,
	else_pos:  tokenizer.Pos,
	else_stmt: ^Stmt, // possibly nil

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this if statement
}

When_Stmt :: struct {
	using node: Stmt,
	when_pos:  tokenizer.Pos,
	cond:      ^Expr,
	body:      ^Stmt,
	else_stmt: ^Stmt, // possibly nil

	// Semantic Analysis Fields
	is_cond_determined: bool, // Whether condition has been evaluated
	determined_cond:    bool, // Result of condition evaluation
}

Return_Stmt :: struct {
	using node: Stmt,
	results: []^Expr,
}

Defer_Stmt :: struct {
	using node: Stmt,
	stmt: ^Stmt,
}

For_Stmt :: struct {
	using node: Stmt,
	label:     ^Expr, // possibly nil
	for_pos:   tokenizer.Pos,
	init:      ^Stmt, // possibly nil
	cond:      ^Expr, // possibly nil
	post:      ^Stmt, // possibly nil
	body:      ^Stmt,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this for loop
}

Range_Stmt :: struct {
	using node: Stmt,
	label:     ^Expr, // possibly nil
	init:      ^Stmt,
	for_pos:   tokenizer.Pos,
	vals:      []^Expr,
	in_pos:    tokenizer.Pos,
	expr:      ^Expr,
	body:      ^Stmt,
	reverse:   bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this range loop
}

Inline_Range_Stmt :: Unroll_Range_Stmt

Unroll_Range_Stmt :: struct {
	using node: Stmt,
	label:     ^Expr, // possibly nil
	unroll_pos: tokenizer.Pos,
	args:       []^Expr,
	for_pos:    tokenizer.Pos,
	val0:       ^Expr,
	val1:       ^Expr, // possibly nil
	in_pos:     tokenizer.Pos,
	expr:       ^Expr,
	body:       ^Stmt,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this unroll range loop
}




Case_Clause :: struct {
	using node: Stmt,
	case_pos:   tokenizer.Pos,
	list:       []^Expr,
	terminator: tokenizer.Token,
	body:       []^Stmt,

	// Semantic Analysis Fields
	scope:          ^Scope,  // Lexical scope for this case clause
	implicit_entity: ^Entity, // Implicit variable entity for type switch cases
}

Switch_Stmt :: struct {
	using node: Stmt,
	label:      ^Expr, // possibly nil
	switch_pos: tokenizer.Pos,
	init:       ^Stmt, // possibly nil
	cond:       ^Expr,
	body:       ^Stmt,
	partial:    bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this switch statement
}

Type_Switch_Stmt :: struct {
	using node: Stmt,
	label:      ^Expr, // possibly nil
	switch_pos: tokenizer.Pos,
	tag:        ^Stmt,
	expr:       ^Expr,
	body:       ^Stmt,
	partial:    bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for this type switch statement
}

Branch_Stmt :: struct {
	using node: Stmt,
	tok:   tokenizer.Token,
	label: ^Ident, // possibly nil
}

Using_Stmt :: struct {
	using node: Stmt,
	list: []^Expr,
}


// Declarations

Bad_Decl :: struct {
	using node: Decl,
}

Value_Decl :: struct {
	using node: Decl,
	docs:       ^Comment_Group, // possibly nil
	attributes: [dynamic]^Attribute, // dynamic as parsing will add to them lazily
	names:      []^Expr,
	type:       ^Expr, // possibly nil
	values:     []^Expr,
	comment:    ^Comment_Group, // possibly nil
	is_using:   bool,
	is_mutable: bool,
}

Package_Decl :: struct {
	using node: Decl,
	docs:    ^Comment_Group, // possibly nil
	token:   tokenizer.Token,
	name:    string,
	comment: ^Comment_Group, // possibly nil
}

Import_Decl :: struct {
	using node: Decl,
	docs:       ^Comment_Group, // possibly nil
	attributes:  [dynamic]^Attribute, // dynamic as parsing will add to them lazily
	is_using:    bool,
	import_tok:  tokenizer.Token,
	name:        tokenizer.Token,
	relpath:     tokenizer.Token,
	fullpath:    string,
	comment:     ^Comment_Group, // possibly nil

	// Semantic Analysis Fields
	pkg: ^Package, // The resolved package this import refers to
}

Foreign_Block_Decl :: struct {
	using node: Decl,
	docs:            ^Comment_Group, // possibly nil
	attributes:      [dynamic]^Attribute, // dynamic as parsing will add to them lazily
	tok:             tokenizer.Token,
	foreign_library: ^Expr, // possibly nil
	body:            ^Stmt, // possibly nil
}

Foreign_Import_Decl :: struct {
	using node: Decl,
	docs:            ^Comment_Group, // possibly nil
	attributes:      [dynamic]^Attribute, // dynamic as parsing will add to them lazily
	foreign_tok:     tokenizer.Token,
	import_tok:      tokenizer.Token,
	name:            ^Ident, // possibly nil
	collection_name: string,
	fullpaths:       []^Expr,
	comment:         ^Comment_Group, // possibly nil
}



// Other things
unparen_expr :: proc(expr: ^Expr) -> (val: ^Expr) {
	val = expr
	if expr == nil {
		return
	}
	for {
		e := val.derived.(^Paren_Expr) or_break
		if e.expr == nil {
			break
		}
		val = e.expr
	}
	return
}

strip_or_return_expr :: proc(expr: ^Expr) -> (val: ^Expr) {
	val = expr
	if expr == nil {
		return
	}
	for {
		inner: ^Expr
		#partial switch e in val.derived {
		case ^Or_Return_Expr:
			inner = e.expr
		case ^Or_Branch_Expr:
			inner = e.expr
		case ^Paren_Expr:
			inner = e.expr
		}
		if inner == nil {
			break
		}
		val = inner
	}
	return
}

Field_Flags :: distinct bit_set[Field_Flag]

Field_Flag :: enum {
	Invalid,
	Unknown,

	Ellipsis,
	Using,
	No_Alias,
	C_Vararg,
	Const,
	Any_Int,
	Subtype,
	By_Ptr,
	No_Broadcast,
	No_Capture,

	Results,
	Tags,
	Default_Parameters,
	Typeid_Token,
}

field_flag_strings := [Field_Flag]string{
	.Invalid            = "",
	.Unknown            = "",

	.Ellipsis           = "..",
	.Using              = "using",
	.No_Alias           = "#no_alias",
	.C_Vararg           = "#c_vararg",
	.Const              = "#const",
	.Any_Int            = "#any_int",
	.Subtype            = "#subtype",
	.By_Ptr             = "#by_ptr",
	.No_Broadcast       = "#no_broadcast",
	.No_Capture         = "#no_capture",

	.Results            = "results",
	.Tags               = "field tag",
	.Default_Parameters = "default parameters",
	.Typeid_Token       = "typeid",
}

field_hash_flag_strings := []struct{key: string, flag: Field_Flag}{
	{"no_alias",     .No_Alias},
	{"c_vararg",     .C_Vararg},
	{"const",        .Const},
	{"any_int",      .Any_Int},
	{"subtype",      .Subtype},
	{"by_ptr",       .By_Ptr},
	{"no_broadcast", .No_Broadcast},
	{"no_capture",   .No_Capture},
}


Field_Flags_Struct :: Field_Flags{
	.Using,
	.Tags,
	.Subtype,
}
Field_Flags_Record_Poly_Params :: Field_Flags{
	.Typeid_Token,
	.Default_Parameters,
}
Field_Flags_Signature :: Field_Flags{
	.Ellipsis,
	.Using,
	.No_Alias,
	.C_Vararg,
	.Const,
	.Any_Int,
	.By_Ptr,
	.No_Broadcast,
	.Default_Parameters,
}

Field_Flags_Signature_Params  :: Field_Flags_Signature | {Field_Flag.Typeid_Token}
Field_Flags_Signature_Results :: Field_Flags_Signature


Proc_Group :: struct {
	using node: Expr,
	tok:   tokenizer.Token,
	open:  tokenizer.Pos,
	args:  []^Expr,
	close: tokenizer.Pos,
}

Attribute :: struct {
	using node: Node,
	tok:   tokenizer.Token_Kind,
	open:  tokenizer.Pos,
	elems: []^Expr,
	close: tokenizer.Pos,
}

Field :: struct {
	using node: Node,
	docs:          ^Comment_Group, // possibly nil
	names:         []^Expr, // Could be polymorphic
	type:          ^Expr,
	default_value: ^Expr, // possibly nil
	tag:           tokenizer.Token,
	flags:         Field_Flags,
	comment:       ^Comment_Group, // possibly nil
}

Field_List :: struct {
	using node: Node,
	open:  tokenizer.Pos,
	list:  []^Field,
	close: tokenizer.Pos,
}


// Types
Typeid_Type :: struct {
	using node: Expr,
	tok:            tokenizer.Token_Kind,
	specialization: ^Expr, // possibly nil
}

Helper_Type :: struct {
	using node: Expr,
	tok:  tokenizer.Token_Kind,
	type: ^Expr,
}

Distinct_Type :: struct {
	using node: Expr,
	tok:  tokenizer.Token_Kind,
	type: ^Expr,
}

Poly_Type :: struct {
	using node: Expr,
	dollar:         tokenizer.Pos,
	type:           ^Ident,
	specialization: ^Expr, // possibly nil
}

Proc_Type :: struct {
	using node: Expr,
	tok:       tokenizer.Token,
	calling_convention: Proc_Calling_Convention,
	params:    ^Field_List,
	arrow:     tokenizer.Pos,
	results:   ^Field_List,
	tags:      Proc_Tags,
	generic:   bool,
	diverging: bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for procedure type parameters
}

Pointer_Type :: struct {
	using node: Expr,
	tag:     ^Expr, // possibly nil
	pointer: tokenizer.Pos,
	elem:    ^Expr,
}

Multi_Pointer_Type :: struct {
	using node: Expr,
	open:    tokenizer.Pos,
	pointer: tokenizer.Pos,
	close:   tokenizer.Pos,
	elem:    ^Expr,
}

Array_Type :: struct {
	using node: Expr,
	open:  tokenizer.Pos,
	tag:   ^Expr, // possibly nil
	len:   ^Expr, // Unary_Expr node for [?]T array types, nil for slice types
	close: tokenizer.Pos,
	elem:  ^Expr,
}

Dynamic_Array_Type :: struct {
	using node: Expr,
	tag:         ^Expr, // possibly nil
	open:        tokenizer.Pos,
	dynamic_pos: tokenizer.Pos,
	close:       tokenizer.Pos,
	elem:        ^Expr,
}

Fixed_Capacity_Dynamic_Array_Type :: struct {
	using node:  Expr,
	tag:         ^Expr, // possibly nil
	open:        tokenizer.Pos,
	dynamic_pos: tokenizer.Pos,
	capacity:    ^Expr,
	close:       tokenizer.Pos,
	elem:        ^Expr,
}

Struct_Type :: struct {
	using node: Expr,
	tok_pos:         tokenizer.Pos,
	poly_params:     ^Field_List, // possibly nil
	align:           ^Expr,       // possibly nil
	min_field_align: ^Expr,       // possibly nil
	max_field_align: ^Expr,       // possibly nil
	where_token:     tokenizer.Token,
	where_clauses:   []^Expr,
	is_packed:       bool,
	is_raw_union:    bool,
	is_no_copy:      bool,
	is_all_or_none:  bool,
	is_simple:       bool,
	fields:          ^Field_List,
	name_count:      int,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for struct fields and polymorphic parameters
}

Union_Type_Kind :: enum u8 {
	Normal,
	maybe,
	no_nil,
	shared_nil,
}

Union_Type :: struct {
	using node: Expr,
	tok_pos:       tokenizer.Pos,
	poly_params:   ^Field_List, // possibly nil
	align:         ^Expr,       // possibly nil
	kind:          Union_Type_Kind,
	where_token:   tokenizer.Token,
	where_clauses: []^Expr,
	variants:      []^Expr,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for union variants and polymorphic parameters
}

Enum_Type :: struct {
	using node: Expr,
	tok_pos:  tokenizer.Pos,
	base_type: ^Expr, // possibly nil
	open:      tokenizer.Pos,
	fields:    []^Expr,
	close:     tokenizer.Pos,

	is_using:  bool,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for enum fields
}

Bit_Set_Type :: struct {
	using node: Expr,
	tok_pos:    tokenizer.Pos,
	open:       tokenizer.Pos,
	elem:       ^Expr,
	underlying: ^Expr, // possibly nil
	close:      tokenizer.Pos,
}

Map_Type :: struct {
	using node: Expr,
	tok_pos: tokenizer.Pos,
	key:     ^Expr,
	value:   ^Expr,
}


Relative_Type :: struct {
	using node: Expr,
	tag:  ^Expr,
	type: ^Expr,
}

Matrix_Type :: struct {
	using node: Expr,
	tok_pos:      tokenizer.Pos,
	row_count:    ^Expr,
	column_count: ^Expr,
	elem:         ^Expr,
}

Bit_Field_Type :: struct {
	using node:   Expr,
	tok_pos:      tokenizer.Pos,
	backing_type: ^Expr,
	open:         tokenizer.Pos,
	fields:       []^Bit_Field_Field,
	close:        tokenizer.Pos,

	// Semantic Analysis Fields
	scope: ^Scope, // Lexical scope for bit field fields
}

Bit_Field_Field :: struct {
	using node: Node,
	docs:       ^Comment_Group, // possibly nil
	name:       ^Expr,
	type:       ^Expr,
	bit_size:   ^Expr,
	tag:        tokenizer.Token,
	comments:   ^Comment_Group, // possibly nil
}

Any_Node :: union {
	^Package,
	^File,
	^Comment_Group,

	^Bad_Expr,
	^Ident,
	^Implicit,
	^Undef,
	^Basic_Lit,
	^Basic_Directive,
	^Ellipsis,
	^Proc_Lit,
	^Comp_Lit,
	^Tag_Expr,
	^Unary_Expr,
	^Binary_Expr,
	^Paren_Expr,
	^Selector_Expr,
	^Implicit_Selector_Expr,
	^Selector_Call_Expr,
	^Index_Expr,
	^Deref_Expr,
	^Slice_Expr,
	^Matrix_Index_Expr,
	^Call_Expr,
	^Field_Value,
	^Ternary_If_Expr,
	^Ternary_When_Expr,
	^Or_Else_Expr,
	^Or_Return_Expr,
	^Or_Branch_Expr,
	^Type_Assertion,
	^Type_Cast,
	^Auto_Cast,
	^Inline_Asm_Expr,

	^Proc_Group,

	^Typeid_Type,
	^Helper_Type,
	^Distinct_Type,
	^Poly_Type,
	^Proc_Type,
	^Pointer_Type,
	^Multi_Pointer_Type,
	^Array_Type,
	^Dynamic_Array_Type,
	^Fixed_Capacity_Dynamic_Array_Type,
	^Struct_Type,
	^Union_Type,
	^Enum_Type,
	^Bit_Set_Type,
	^Map_Type,
	^Relative_Type,
	^Matrix_Type,
	^Bit_Field_Type,

	^Bad_Stmt,
	^Empty_Stmt,
	^Expr_Stmt,
	^Tag_Stmt,
	^Assign_Stmt,
	^Block_Stmt,
	^If_Stmt,
	^When_Stmt,
	^Return_Stmt,
	^Defer_Stmt,
	^For_Stmt,
	^Range_Stmt,
	^Inline_Range_Stmt,
	^Case_Clause,
	^Switch_Stmt,
	^Type_Switch_Stmt,
	^Branch_Stmt,
	^Using_Stmt,

	^Bad_Decl,
	^Value_Decl,
	^Package_Decl,
	^Import_Decl,
	^Foreign_Block_Decl,
	^Foreign_Import_Decl,

	^Attribute,
	^Field,
	^Field_List,
	^Bit_Field_Field,
}


Any_Expr :: union {
	^Bad_Expr,
	^Ident,
	^Implicit,
	^Undef,
	^Basic_Lit,
	^Basic_Directive,
	^Ellipsis,
	^Proc_Lit,
	^Comp_Lit,
	^Tag_Expr,
	^Unary_Expr,
	^Binary_Expr,
	^Paren_Expr,
	^Selector_Expr,
	^Implicit_Selector_Expr,
	^Selector_Call_Expr,
	^Index_Expr,
	^Deref_Expr,
	^Slice_Expr,
	^Matrix_Index_Expr,
	^Call_Expr,
	^Field_Value,
	^Ternary_If_Expr,
	^Ternary_When_Expr,
	^Or_Else_Expr,
	^Or_Return_Expr,
	^Or_Branch_Expr,
	^Type_Assertion,
	^Type_Cast,
	^Auto_Cast,
	^Inline_Asm_Expr,

	^Proc_Group,

	^Typeid_Type,
	^Helper_Type,
	^Distinct_Type,
	^Poly_Type,
	^Proc_Type,
	^Pointer_Type,
	^Multi_Pointer_Type,
	^Array_Type,
	^Dynamic_Array_Type,
	^Fixed_Capacity_Dynamic_Array_Type,
	^Struct_Type,
	^Union_Type,
	^Enum_Type,
	^Bit_Set_Type,
	^Map_Type,
	^Relative_Type,
	^Matrix_Type,
	^Bit_Field_Type,
}


Any_Stmt :: union {
	^Bad_Stmt,
	^Empty_Stmt,
	^Expr_Stmt,
	^Tag_Stmt,
	^Assign_Stmt,
	^Block_Stmt,
	^If_Stmt,
	^When_Stmt,
	^Return_Stmt,
	^Defer_Stmt,
	^For_Stmt,
	^Range_Stmt,
	^Inline_Range_Stmt,
	^Case_Clause,
	^Switch_Stmt,
	^Type_Switch_Stmt,
	^Branch_Stmt,
	^Using_Stmt,

	^Bad_Decl,
	^Value_Decl,
	^Package_Decl,
	^Import_Decl,
	^Foreign_Block_Decl,
	^Foreign_Import_Decl,
}
