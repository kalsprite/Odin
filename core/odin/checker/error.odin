package checker

/*
Package error provides error reporting infrastructure for the type checker.

This is a comprehensive port of the C++ error reporting system from:
/mnt/c/odin/src/error.cpp

The error reporting system provides:
- Error and warning collection with position tracking
- Formatted error output with source line context and Unicode grapheme support
- Error staging mechanism for batched reporting
- Error merging and deduplication
- Multiple output modes: standard, JSON, terse
- Terminal color support with ANSI codes
- Thread-safe error accumulation

ARCHITECTURE:

The error system uses a staging mechanism where errors are:
1. Pushed onto the current error value (push_error_value)
2. Content is appended via error_out()
3. The error is committed to the global list (pop_error_value)

This allows multi-line errors and error blocks to be composed atomically.

ERROR BLOCKS:

Error blocks (begin_error_block/end_error_block) allow multiple error_out()
calls to be accumulated before committing, useful for complex error messages
with suggestions and context.

C++ REFERENCE: /mnt/c/odin/src/error.cpp
*/

import "base:runtime"
import "core:fmt"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:os"
import "core:slice"
import "core:strings"
import "core:sync"
import "core:unicode/utf8"

// ============================================================================
// Error Value Types
// ============================================================================

// Error_Value_Kind distinguishes errors from warnings
// C++ Reference: error.cpp:1-4
Error_Value_Kind :: enum u32 {
	Error,
	Warning,
}

// Error_Value represents a single error or warning with its message buffer
// C++ Reference: error.cpp:6-12
Error_Value :: struct {
	kind:         Error_Value_Kind,
	pos:          tokenizer.Pos,
	end:          tokenizer.Pos, // Optional end position for error ranges
	msg:          [dynamic]u8, // Message buffer accumulated via error_out()
	seen_newline: bool, // For terse mode: stop at first newline
}

// Error_Collector accumulates errors and warnings during checking
// C++ Reference: error.cpp:14-26
Error_Collector :: struct {
	count:                int, // Total error count
	warning_count:        int, // Total warning count

	// Error storage (shared across threads, protected by mutex)
	error_values:         [dynamic]Error_Value,

	// Settings
	max_error_count:      int,
	allocator:            runtime.Allocator,

	// Checker info for source line extraction
	info:                 ^Checker_Info,

	// Thread safety
	mutex:                sync.Mutex, // C++ error.cpp:6 - protects error_values access
}

// ============================================================================
// Global Error Collector
// ============================================================================

// Global error collector for the checker
// C++ Reference: error.cpp:28
global_error_collector: Error_Collector

// Thread-local state for error building
// Each thread has its own current error being constructed
// This prevents race conditions when multiple threads report errors simultaneously
@(thread_local) tls_curr_error_value: Error_Value
@(thread_local) tls_curr_error_value_set: bool
@(thread_local) tls_in_block: bool

// errors_already_printed tracks if print_all_errors has been called
// C++ Reference: error.cpp:863
errors_already_printed: bool = false

// ============================================================================
// Build Settings (simplified - full impl uses build_context)
// ============================================================================

// Error_Pos_Style, Build_Settings, build_settings, and accessor functions
// are defined in build_settings.odin

// ============================================================================
// Error Collector Management
// ============================================================================

// init_error_collector initializes the error reporting system
// C++ Reference: error.cpp:73-77
init_error_collector :: proc(max_errors := 100, warnings_as_errors := false, ignore_warnings := false, allocator := context.allocator) {
	global_error_collector.error_values = make([dynamic]Error_Value, allocator)
	sync.atomic_store(&global_error_collector.count, 0)
	sync.atomic_store(&global_error_collector.warning_count, 0)
	global_error_collector.max_error_count = max_errors
	global_error_collector.allocator = allocator
	global_error_collector.info = nil
	// Note: Mutex is zero-initialized in Odin, no explicit init needed
	// Thread-local state (tls_curr_error_value, tls_curr_error_value_set, tls_in_block)
	// is automatically zero-initialized per thread

	build_context.warnings_as_errors = warnings_as_errors
	build_context.ignore_warnings = ignore_warnings
	build_context.max_error_count = max_errors

	errors_already_printed = false
}

// set_error_collector_info sets the Checker_Info for source line extraction
// Should be called after init_error_collector when Checker_Info is available
set_error_collector_info :: proc(info: ^Checker_Info) {
	global_error_collector.info = info
}

// destroy_error_collector frees error collector resources
destroy_error_collector :: proc() {
	for &entry in global_error_collector.error_values {
		delete(entry.msg)
	}
	delete(global_error_collector.error_values)
	// Clean up thread-local state if set (only affects calling thread)
	if tls_curr_error_value_set {
		delete(tls_curr_error_value.msg)
		tls_curr_error_value = {}
		tls_curr_error_value_set = false
	}
	tls_in_block = false
	// Note: Mutex requires no cleanup in Odin
	global_error_collector = {}
}

// any_errors returns true if any errors have been reported
// C++ Reference: error.cpp:65-67
any_errors :: proc() -> bool {
	return sync.atomic_load(&global_error_collector.count) != 0
}

// any_warnings returns true if any warnings have been reported
// C++ Reference: error.cpp:68-70
any_warnings :: proc() -> bool {
	return sync.atomic_load(&global_error_collector.warning_count) != 0
}

// error_count returns the number of errors reported
error_count :: proc() -> int {
	return sync.atomic_load(&global_error_collector.count)
}

// warning_count returns the number of warnings reported
warning_count :: proc() -> int {
	return sync.atomic_load(&global_error_collector.warning_count)
}

// ============================================================================
// Error Value Staging
// ============================================================================

// push_error_value stages an error value for batched reporting
// C++ Reference: error.cpp:31-38
push_error_value :: proc(pos: tokenizer.Pos, kind: Error_Value_Kind = .Error) {
	assert(!tls_curr_error_value_set, "Nested error push detected - did you forget to pop a previous error?")

	ev := Error_Value {
		kind         = kind,
		pos          = pos,
		end          = {},
		msg          = make([dynamic]u8, global_error_collector.allocator),
		seen_newline = false,
	}

	tls_curr_error_value = ev
	tls_curr_error_value_set = true
}

// pop_error_value commits the staged error to the error list
// C++ Reference: error.cpp:40-49
pop_error_value :: proc() {
	if tls_curr_error_value_set {
		// Lock to safely append to the shared error list
		sync.lock(&global_error_collector.mutex)
		append(&global_error_collector.error_values, tls_curr_error_value)
		sync.unlock(&global_error_collector.mutex)

		// Clear thread-local state
		tls_curr_error_value = {}
		tls_curr_error_value_set = false
	}
}

// try_pop_error_value conditionally pops the error if not in a block
// C++ Reference: error.cpp:52-56
try_pop_error_value :: proc() {
	if !tls_in_block {
		pop_error_value()
	}
}

// get_error_value returns the current staged error value
// C++ Reference: error.cpp:58-61
get_error_value :: proc() -> ^Error_Value {
	assert(tls_curr_error_value_set, "No current error value to write to - error_out called without push_error_value")
	return &tls_curr_error_value
}

// get_error_values returns the current list of accumulated errors
// Used for test infrastructure to capture and verify error messages
// Note: Caller should hold test_error_mutex if called from tests
get_error_values :: proc() -> []Error_Value {
	return global_error_collector.error_values[:]
}

// ============================================================================
// Error Blocks
// ============================================================================

// begin_error_block starts a batched error reporting block
// Errors reported within the block are accumulated and flushed together
// C++ Reference: error.cpp:214-217
begin_error_block :: proc() {
	tls_in_block = true
}

// end_error_block ends a batched error reporting block and flushes accumulated errors
// C++ Reference: error.cpp:219-223
end_error_block :: proc() {
	pop_error_value()
	tls_in_block = false
}

// ============================================================================
// Terminal Colors
// ============================================================================

// Terminal_Style controls text styling in terminal output
// C++ Reference: error.cpp:236-240
Terminal_Style :: enum {
	Normal,
	Bold,
	Underline,
}

// Terminal_Colour defines available terminal colors for error output
// C++ Reference: error.cpp:242-252
Terminal_Colour :: enum {
	White,
	Red,
	Yellow,
	Green,
	Cyan,
	Blue,
	Purple,
	Black,
	Grey,
}

// terminal_set_colours sets the terminal text color and style using ANSI codes
// C++ Reference: error.cpp:254-274
terminal_set_colours :: proc(style: Terminal_Style, foreground: Terminal_Colour) {
	if !has_ansi_terminal_colours() {
		return
	}

	ss: string
	switch style {
	case .Normal:
		ss = "0"
	case .Bold:
		ss = "1"
	case .Underline:
		ss = "4"
	}

	switch foreground {
	case .White:
		error_out("\x1b[%s;37m", ss)
	case .Red:
		error_out("\x1b[%s;31m", ss)
	case .Yellow:
		error_out("\x1b[%s;33m", ss)
	case .Green:
		error_out("\x1b[%s;32m", ss)
	case .Cyan:
		error_out("\x1b[%s;36m", ss)
	case .Blue:
		error_out("\x1b[%s;34m", ss)
	case .Purple:
		error_out("\x1b[%s;35m", ss)
	case .Black:
		error_out("\x1b[%s;30m", ss)
	case .Grey:
		error_out("\x1b[%s;90m", ss)
	}
}

// terminal_reset_colours resets terminal colors to default
// C++ Reference: error.cpp:275-279
terminal_reset_colours :: proc() {
	if has_ansi_terminal_colours() {
		error_out("\x1b[0m")
	}
}

// ============================================================================
// Error Output
// ============================================================================

// error_out appends formatted text to the current error message
// This is the core output function that all error messages go through
// C++ Reference: error.cpp:229-234 (error_out) and error.cpp:191-210 (default_error_out_va)
error_out :: proc(format: string, args: ..any) {
	// Safety check: if no active error value, print directly to stderr
	if !tls_curr_error_value_set {
		fmt.eprintf(format, ..args)
		return
	}

	ev := get_error_value()
	buf := fmt.tprintf(format, ..args)

	if terse_errors() {
		// In terse mode, only append until the first newline
		for i := 0; i < len(buf) && !ev.seen_newline; i += 1 {
			c := buf[i]
			if c == '\n' {
				ev.seen_newline = true
			}
			append(&ev.msg, c)
		}
	} else {
		// Append entire message
		for i := 0; i < len(buf); i += 1 {
			append(&ev.msg, buf[i])
		}
	}
}

// error_out_empty outputs an empty string (used for structure)
// C++ Reference: error.cpp:518-520
error_out_empty :: proc() {
	error_out("")
}

// error_out_pos outputs a formatted position
// C++ Reference: error.cpp:521-525
error_out_pos :: proc(pos: tokenizer.Pos) {
	terminal_set_colours(.Bold, .White)
	error_out("%s ", token_pos_to_string(pos))
	terminal_reset_colours()
}

// error_out_coloured outputs colored text
// C++ Reference: error.cpp:527-531
error_out_coloured :: proc(str: string, style: Terminal_Style, foreground: Terminal_Colour) {
	terminal_set_colours(style, foreground)
	error_out(str)
	terminal_reset_colours()
}

// ============================================================================
// Token Position Formatting
// ============================================================================

// token_pos_to_string formats a token position for display
// C++ Reference: build_settings.cpp:1688-1701
token_pos_to_string :: proc(pos: tokenizer.Pos) -> string {
	// Note: pos.file contains the file path string directly in Odin
	file := pos.file

	#partial switch build_context.ODIN_ERROR_POS_STYLE {
	case .Default:
		return fmt.tprintf("%s(%d:%d)", file, pos.line, pos.column)
	case .Unix:
		return fmt.tprintf("%s:%d:%d:", file, pos.line, pos.column)
	}

	return fmt.tprintf("%s(%d:%d)", file, pos.line, pos.column)
}

// ============================================================================
// Source Line Extraction
// ============================================================================

// get_file_line_as_string extracts the line containing the error position
// C++ Reference: parser.cpp:57-130
// Returns the line text and sets error_start_index to the column offset within that line
get_file_line_as_string :: proc(info: ^Checker_Info, pos: tokenizer.Pos, error_start_index: ^int) -> string {
	if info == nil {
		return ""
	}

	// Look up file from info.files map using file path
	file, ok := info.files[pos.file]
	if !ok || file == nil {
		return ""
	}

	src := file.src
	if len(src) == 0 {
		return ""
	}

	// Calculate offset if not provided (using line/column)
	offset := pos.offset
	if pos.line != 0 && offset == 0 {
		// Navigate to the line by counting newlines
		for i := 1; i < pos.line; i += 1 {
			for offset < len(src) {
				c := src[offset]
				offset += 1
				if c == '\n' {
					break
				}
			}
		}
		// Navigate to column within the line (UTF-8 aware)
		for i := 1; i < pos.column; i += 1 {
			if offset >= len(src) {
				break
			}
			c := src[offset]
			if c & 0x80 != 0 {
				// Multi-byte UTF-8 character
				_, width := utf8.decode_rune_in_string(src[offset:])
				offset += width
			} else {
				offset += 1
			}
		}
	}

	// Bounds check
	if offset >= len(src) {
		return ""
	}

	pos_offset := offset

	// Find line start (scan backwards to newline or start of file)
	line_start := pos_offset
	line_end := pos_offset

	// Special case: if we're at a newline, step back one
	if offset > 0 && src[line_start] == '\n' {
		line_start -= 1
	}

	// Scan backwards to find line start
	for line_start >= 0 {
		if src[line_start] == '\n' {
			line_start += 1
			break
		}
		line_start -= 1
	}
	if line_start < 0 {
		line_start = 0
	}

	// Scan forwards to find line end
	for line_end < len(src) {
		if src[line_end] == '\n' {
			break
		}
		line_end += 1
	}

	// Extract the line and trim whitespace
	the_line := src[line_start:line_end]
	the_line = strings.trim_space(the_line)

	// Calculate error column within the trimmed line
	if error_start_index != nil {
		// Find where pos_offset appears in the trimmed line
		original_line := src[line_start:line_end]
		trim_left := len(original_line) - len(strings.trim_left_space(original_line))
		error_start_index^ = pos_offset - line_start - trim_left
		if error_start_index^ < 0 {
			error_start_index^ = 0
		}
	}

	return strings.clone(the_line, context.temp_allocator)
}

// ============================================================================
// Show Error On Line
// ============================================================================

// show_error_on_line displays the source line with the error highlighted
// C++ Reference: error.cpp:282-516
// Implements full Unicode grapheme cluster support using core:unicode/utf8
show_error_on_line :: proc(pos: tokenizer.Pos, end: tokenizer.Pos) -> int {
	get_error_value().end = end

	if !show_error_line() {
		return -1
	}

	// Check if we have checker info for source line extraction
	info := global_error_collector.info
	if info == nil {
		// Fallback: no source available
		return -1
	}

	// Extract the source line
	error_start_index_bytes: int = 0
	the_line := get_file_line_as_string(info, pos, &error_start_index_bytes)

	if len(the_line) == 0 {
		terminal_set_colours(.Normal, .Grey)
		error_out("\t( empty line )\n")
		terminal_reset_colours()
		return -1
	}

	// Decode grapheme clusters for proper visual width calculation
	// C++ Reference: error.cpp:308-332
	graphemes, line_length_graphemes, _, line_width :=
		utf8.decode_grapheme_clusters(the_line, true, context.temp_allocator)

	// Line display constants (C++ Reference: error.cpp:335-345)
	MAX_LINE_LENGTH :: 80
	ELLIPSIS_PADDING :: 8   // `...  ...`
	MIN_LEFT_VIEW :: 8
	MAX_INSERTED_WIDTH :: 8 + ELLIPSIS_PADDING
	MAX_LINE_LENGTH_PADDED :: MAX_LINE_LENGTH - MAX_INSERTED_WIDTH

	// Find error start in grapheme indices
	// C++ Reference: error.cpp:347-361
	error_start_index_graphemes := 0
	for i := 0; i < line_length_graphemes; i += 1 {
		if graphemes[i].byte_index == error_start_index_bytes {
			error_start_index_graphemes = i
			break
		}
	}

	// Edge case: error at end of line
	if error_start_index_graphemes == 0 && error_start_index_bytes != 0 && line_length_graphemes != 0 {
		error_start_index_graphemes = line_length_graphemes
	}

	error_out("\t")

	show_right_ellipsis := false
	squiggle_padding := 0
	window_open_bytes := 0
	window_close_bytes := len(the_line)

	// Line truncation with windowing (C++ Reference: error.cpp:370-433)
	if line_width > MAX_LINE_LENGTH_PADDED {
		// Compose a visual window to display the error
		window_size_left := 0
		window_size_right := 0
		window_open_graphemes := 0

		// Scan left from error to find window start
		for i := error_start_index_graphemes - 1; i > 0; i -= 1 {
			window_size_left += graphemes[i].width
			if window_size_left >= MIN_LEFT_VIEW {
				window_open_graphemes = i
				window_open_bytes = graphemes[i].byte_index
				break
			}
		}

		// Scan right from error to find window end
		for i := error_start_index_graphemes; i < line_length_graphemes; i += 1 {
			window_size_right += graphemes[i].width
			if window_size_right >= MAX_LINE_LENGTH_PADDED - MIN_LEFT_VIEW {
				window_close_bytes = graphemes[i].byte_index
				break
			}
		}
		if window_close_bytes == 0 {
			window_close_bytes = len(the_line)
		}

		// Expand backwards if we hit end of string early on right side
		if window_size_right < MAX_LINE_LENGTH_PADDED - MIN_LEFT_VIEW {
			for i := window_open_graphemes - 1; i > 0; i -= 1 {
				window_size_left += graphemes[i].width
				if window_size_left + window_size_right >= MAX_LINE_LENGTH_PADDED {
					window_open_graphemes = i
					window_open_bytes = graphemes[i].byte_index
					break
				}
			}
		}

		if window_close_bytes != len(the_line) {
			show_right_ellipsis = true
		}

		// Add left ellipsis if needed
		if window_open_bytes > 0 {
			error_out("... ")
			squiggle_padding += 4
		}
	}

	// Calculate squiggle padding from grapheme widths
	// C++ Reference: error.cpp:154-159
	for i := error_start_index_graphemes - 1; i >= 0; i -= 1 {
		if graphemes[i].byte_index == window_open_bytes {
			break
		}
		squiggle_padding += graphemes[i].width
	}

	// Display the line (possibly windowed)
	// C++ Reference: error.cpp:163-164
	line_text := the_line[window_open_bytes:window_close_bytes]
	terminal_set_colours(.Normal, .White)
	error_out("%s", line_text)

	// Calculate squiggle length
	// C++ Reference: error.cpp:166-199
	squiggle_length := 0
	trailing_squiggle := false

	if end.file == pos.file {
		if end.line > pos.line {
			// Error spans to next line - show ellipsis
			show_right_ellipsis = true
			for i := error_start_index_graphemes; i < line_length_graphemes; i += 1 {
				squiggle_length += graphemes[i].width
				trailing_squiggle = true
			}
		} else if end.line == pos.line && end.column > pos.column {
			// Error terminates on same line
			adjusted_end_index := 0
			if error_start_index_graphemes < line_length_graphemes {
				adjusted_end_index = graphemes[error_start_index_graphemes].byte_index + (end.column - pos.column)
			}

			for i := error_start_index_graphemes; i < line_length_graphemes; i += 1 {
				if graphemes[i].byte_index >= adjusted_end_index {
					break
				} else if graphemes[i].byte_index >= window_close_bytes {
					trailing_squiggle = true
					break
				}
				squiggle_length += graphemes[i].width
			}
		}
	} else {
		// Single point error
		squiggle_length = 1
	}

	// Add right ellipsis if needed
	// C++ Reference: error.cpp:201-203
	if show_right_ellipsis {
		error_out(" ...")
	}

	// Output squiggle line
	// C++ Reference: error.cpp:205-226
	error_out("\n\t")
	for i := 0; i < squiggle_padding; i += 1 {
		error_out(" ")
	}

	terminal_set_colours(.Bold, .Green)
	if squiggle_length > 0 {
		error_out("^")
		squiggle_length -= 1
	}
	for ; squiggle_length > 1; squiggle_length -= 1 {
		error_out("~")
	}
	if squiggle_length > 0 {
		if trailing_squiggle {
			error_out("~ ...")
		} else {
			error_out("^")
		}
	}
	error_out("\n")
	terminal_reset_colours()

	return squiggle_padding
}

// ============================================================================
// Core Error/Warning Functions
// ============================================================================

// error_va is the core error reporting function (variadic version)
// C++ Reference: error.cpp:535-563
error_va :: proc(pos: tokenizer.Pos, end: tokenizer.Pos, format: string, args: ..any) {
	sync.atomic_add(&global_error_collector.count, 1)

	if sync.atomic_load(&global_error_collector.count) > build_context.max_error_count {
		print_all_errors()
		os.exit(1)
	}

	push_error_value(pos, .Error)

	if pos.line == 0 {
		error_out_empty()
		error_out_coloured("Error: ", .Normal, .Red)
		error_out(format, ..args)
		error_out("\n")
	} else {
		if json_errors() {
			error_out_empty()
		} else {
			error_out_pos(pos)
			error_out_coloured("Error: ", .Normal, .Red)
		}
		error_out(format, ..args)
		error_out("\n")
		show_error_on_line(pos, end)
	}

	try_pop_error_value()
}

// warning_va is the core warning reporting function (variadic version)
// C++ Reference: error.cpp:565-598
warning_va :: proc(pos: tokenizer.Pos, end: tokenizer.Pos, format: string, args: ..any) {
	if global_warnings_as_errors() {
		error_va(pos, end, format, ..args)
		return
	}
	if build_context.ignore_warnings {
		return
	}

	sync.atomic_add(&global_error_collector.warning_count, 1)

	push_error_value(pos, .Warning)

	if pos.line == 0 {
		error_out_empty()
		error_out_coloured("Warning: ", .Normal, .Yellow)
		error_out(format, ..args)
		error_out("\n")
	} else {
		if json_errors() {
			error_out_empty()
		} else {
			error_out_pos(pos)
			error_out_coloured("Warning: ", .Normal, .Yellow)
		}
		error_out(format, ..args)
		error_out("\n")
		show_error_on_line(pos, end)
	}

	try_pop_error_value()
}

// error_line_va outputs a continuation line for multi-line errors
// C++ Reference: error.cpp:601-603
error_line_va :: proc(format: string, args: ..any) {
	// Safety check: only output if there's an active error value
	// This prevents crashes if error_line is called standalone
	if tls_curr_error_value_set {
		error_out(format, ..args)
	} else {
		// Fallback: print directly if no active error (shouldn't happen in normal use)
		fmt.eprintf(format, ..args)
	}
}

// syntax_error_va reports a syntax error with "Syntax Error:" prefix
// C++ Reference: error.cpp:637-667
syntax_error_va :: proc(pos: tokenizer.Pos, end: tokenizer.Pos, format: string, args: ..any) {
	sync.atomic_add(&global_error_collector.count, 1)

	if sync.atomic_load(&global_error_collector.count) > build_context.max_error_count {
		print_all_errors()
		os.exit(1)
	}

	push_error_value(pos, .Warning) // Note: C++ uses Warning kind for syntax errors

	if pos.line == 0 {
		error_out_empty()
		error_out_coloured("Syntax Error: ", .Normal, .Red)
		error_out(format, ..args)
		error_out("\n")
	} else {
		if json_errors() {
			error_out_empty()
		} else {
			error_out_pos(pos)
		}
		error_out_coloured("Syntax Error: ", .Normal, .Red)
		error_out(format, ..args)
		error_out("\n")
		show_error_on_line(pos, end)
	}

	try_pop_error_value()
}

// syntax_warning_va reports a syntax warning
// C++ Reference: error.cpp:704-738
syntax_warning_va :: proc(pos: tokenizer.Pos, end: tokenizer.Pos, format: string, args: ..any) {
	if global_warnings_as_errors() {
		syntax_error_va(pos, end, format, ..args)
		return
	}
	if build_context.ignore_warnings {
		return
	}

	sync.atomic_add(&global_error_collector.warning_count, 1)

	push_error_value(pos, .Warning)

	if pos.line == 0 {
		error_out_empty()
		error_out_coloured("Syntax Warning: ", .Normal, .Yellow)
		error_out(format, ..args)
		error_out("\n")
	} else {
		if json_errors() {
			error_out_empty()
		} else {
			error_out_pos(pos)
		}
		error_out_coloured("Syntax Warning: ", .Normal, .Yellow)
		error_out(format, ..args)
		error_out("\n")
		// Note: C++ doesn't show line for syntax warnings
	}

	try_pop_error_value()
}

// ============================================================================
// Public Error/Warning API
// ============================================================================

// warning reports a warning at a token
// C++ Reference: error.cpp:742-747
warning :: proc {
	warning_token,
	warning_pos,
	warning_node,
}

warning_token :: proc(token: tokenizer.Token, format: string, args: ..any) {
	warning_va(token.pos, {}, format, ..args)
}

warning_pos :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	warning_va(pos, {}, format, ..args)
}

warning_node :: proc(node: ^ast.Node, format: string, args: ..any) {
	pos := node.pos if node != nil else tokenizer.Pos{}
	warning_va(pos, {}, format, ..args)
}

// error reports an error at a token/position/node
// C++ Reference: error.cpp:749-763
error :: proc {
	error_token,
	error_pos,
	error_node,
}

error_token :: proc(token: tokenizer.Token, format: string, args: ..any) {
	error_va(token.pos, {}, format, ..args)
}

error_pos :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	error_va(pos, {}, format, ..args)
}

error_node :: proc(node: ^ast.Node, format: string, args: ..any) {
	pos := node.pos if node != nil else tokenizer.Pos{}
	error_va(pos, {}, format, ..args)
}

// error_line outputs a continuation line for a multi-line error
// C++ Reference: error.cpp:765-770
error_line :: proc(format: string, args: ..any) {
	error_line_va(format, ..args)
}

// syntax_error reports a syntax error
// C++ Reference: error.cpp:773-785
syntax_error :: proc {
	syntax_error_token,
	syntax_error_pos,
}

syntax_error_token :: proc(token: tokenizer.Token, format: string, args: ..any) {
	syntax_error_va(token.pos, {}, format, ..args)
}

syntax_error_pos :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	syntax_error_va(pos, {}, format, ..args)
}

// syntax_warning reports a syntax warning
// C++ Reference: error.cpp:787-792
syntax_warning :: proc {
	syntax_warning_token,
	syntax_warning_pos,
}

syntax_warning_token :: proc(token: tokenizer.Token, format: string, args: ..any) {
	syntax_warning_va(token.pos, {}, format, ..args)
}

syntax_warning_pos :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	syntax_warning_va(pos, {}, format, ..args)
}

// compiler_error reports a fatal internal compiler error and exits
// C++ Reference: error.cpp:803-816
compiler_error :: proc(format: string, args: ..any) {
	if any_errors() || any_warnings() {
		print_all_errors()
	}

	fmt.eprintf("Internal Compiler Error: ")
	fmt.eprintf(format, ..args)
	fmt.eprintln()
	os.exit(1)
}

// exit_with_errors prints all errors and exits if there are any
// C++ Reference: error.cpp:819-824
exit_with_errors :: proc() {
	if any_errors() || any_warnings() {
		print_all_errors()
	}
	os.exit(1)
}

// ============================================================================
// Error Comparison and Sorting
// ============================================================================

// error_value_cmp compares two error values by position for sorting
// C++ Reference: error.cpp:828-832
error_value_cmp :: proc(a, b: Error_Value) -> bool {
	// Compare file_id first
	if a.pos.file != b.pos.file {
		return a.pos.file < b.pos.file
	}
	// Then offset
	if a.pos.offset != b.pos.offset {
		return a.pos.offset < b.pos.offset
	}
	// Then line
	if a.pos.line != b.pos.line {
		return a.pos.line < b.pos.line
	}
	// Then column
	if a.pos.column != b.pos.column {
		return a.pos.column < b.pos.column
	}
	return false
}

// positions_equal checks if two positions are equal
// Used for error merging to detect duplicate positions
// C++ Reference: error.cpp:913 - prev_ev->pos == ev.pos
positions_equal :: proc(a, b: tokenizer.Pos) -> bool {
	return a.file == b.file &&
	       a.offset == b.offset &&
	       a.line == b.line &&
	       a.column == b.column
}

// ============================================================================
// Error Article Table (for grammatically correct error messages)
// ============================================================================

// Error_Article_Entry maps context names to their appropriate articles
// C++ Reference: error.cpp:834-851
Error_Article_Entry :: struct {
	article:      string,
	context_name: string,
}

// error_article_table provides grammatically correct articles for error messages
error_article_table := [?]Error_Article_Entry {
	{"a ", "bit_set literal"},
	{"a ", "constant declaration"},
	{"a ", "dynamic array literal"},
	{"a ", "map index"},
	{"a ", "map literal"},
	{"a ", "matrix literal"},
	{"a ", "polymorphic type argument"},
	{"a ", "procedure argument"},
	{"a ", "simd vector literal"},
	{"a ", "slice literal"},
	{"a ", "structure literal"},
	{"a ", "variable declaration"},
	{"an ", "'any' literal"},
	{"an ", "array literal"},
	{"an ", "enumerated array literal"},
}

// error_article returns the appropriate article ("a ", "an ", or "") for a context name
// C++ Reference: error.cpp:854-861
error_article :: proc(context_name: string) -> string {
	for entry in error_article_table {
		if context_name == entry.context_name {
			return entry.article
		}
	}
	return ""
}

// ============================================================================
// Print All Errors
// ============================================================================

// escape_char escapes a character for JSON output
// C++ Reference: error.cpp:877-895
escape_char :: proc(sb: ^strings.Builder, c: u8) {
	switch c {
	case '\n':
		strings.write_string(sb, "\\n")
	case '"':
		strings.write_string(sb, "\\\"")
	case '\\':
		strings.write_string(sb, "\\\\")
	case '\b':
		strings.write_string(sb, "\\b")
	case '\f':
		strings.write_string(sb, "\\f")
	case '\r':
		strings.write_string(sb, "\\r")
	case '\t':
		strings.write_string(sb, "\\t")
	case:
		if c >= 0x00 && c <= 0x1f {
			fmt.sbprintf(sb, "\\u%04x", c)
		} else {
			strings.write_byte(sb, c)
		}
	}
}

// print_all_errors outputs all accumulated errors and warnings
// C++ Reference: error.cpp:865-1033
print_all_errors :: proc() {
	if errors_already_printed {
		// If all errors are warnings, clear them and reset
		if sync.atomic_load(&global_error_collector.warning_count) == len(global_error_collector.error_values) {
			for &ev in global_error_collector.error_values {
				delete(ev.msg)
			}
			clear(&global_error_collector.error_values)
			errors_already_printed = false
		}
		return
	}

	assert(any_errors() || any_warnings())

	// Sort errors by position
	slice.sort_by(global_error_collector.error_values[:], error_value_cmp)

	// Merge neighboring errors at the same position
	// C++ Reference: error.cpp:902-937
	{
		default_lines_to_skip := 1
		if show_error_line() {
			default_lines_to_skip += 2 // Two extra lines for source display
		}

		prev_ev: ^Error_Value = nil
		i := 0
		for i < len(global_error_collector.error_values) {
			ev := &global_error_collector.error_values[i]

			// Check if this error is at the same position as the previous one
			if prev_ev != nil && positions_equal(prev_ev.pos, ev.pos) {
				// Skip the default lines from the current error message
				msg := string(ev.msg[:])
				lines_skipped := 0
				pos := 0

				// Skip default_lines_to_skip lines
				for lines_skipped < default_lines_to_skip && pos < len(msg) {
					if msg[pos] == '\n' {
						lines_skipped += 1
					}
					pos += 1
				}

				// Extract the remaining text after skipping the default lines
				addition := msg[pos:]

				// Merge additional text into previous error if not already present
				if len(addition) > 0 {
					current := string(prev_ev.msg[:])
					if !strings.contains(current, addition) {
						// Append the additional text to the previous error
						for j := 0; j < len(addition); j += 1 {
							append(&prev_ev.msg, addition[j])
						}
					}
				}

				// Free the current error's message and remove it
				delete(ev.msg)
				ordered_remove(&global_error_collector.error_values, i)
				// Don't increment i since we removed an element
			} else {
				prev_ev = ev
				i += 1
			}
		}
	}

	if json_errors() {
		print_errors_json()
	} else {
		print_errors_standard()
	}

	errors_already_printed = true
}

// print_errors_standard outputs errors in standard format
// C++ Reference: error.cpp:1009-1027
print_errors_standard :: proc() {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	for ev in global_error_collector.error_values {
		// Split message into lines and output
		msg := string(ev.msg[:])
		lines := strings.split_lines(msg, context.temp_allocator)

		for line, line_idx in lines {
			if len(line) == 0 {
				break
			}
			// Trim trailing whitespace
			line_trimmed := strings.trim_right_space(line)
			strings.write_string(&sb, line_trimmed)
			strings.write_string(&sb, " \n")

			if line_idx == 0 && terse_errors() {
				break
			}
		}
	}

	output := strings.to_string(sb)
	os.write_string(os.stderr, output)
}

// print_errors_json outputs errors in JSON format
// C++ Reference: error.cpp:942-1008
print_errors_json :: proc() {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "{\n")
	fmt.sbprintf(&sb, "\t\"error_count\": %d,\n", len(global_error_collector.error_values))
	strings.write_string(&sb, "\t\"errors\": [\n")

	for ev, i in global_error_collector.error_values {
		strings.write_string(&sb, "\t\t{\n")

		// Type
		strings.write_string(&sb, "\t\t\t\"type\": \"")
		if ev.kind == .Warning {
			strings.write_string(&sb, "warning")
		} else {
			strings.write_string(&sb, "error")
		}
		strings.write_string(&sb, "\",\n")

		// Position
		if ev.pos.file != "" {
			strings.write_string(&sb, "\t\t\t\"pos\": {\n")
			strings.write_string(&sb, "\t\t\t\t\"file\": \"")
			for j := 0; j < len(ev.pos.file); j += 1 {
				escape_char(&sb, ev.pos.file[j])
			}
			strings.write_string(&sb, "\",\n")
			fmt.sbprintf(&sb, "\t\t\t\t\"offset\": %d,\n", ev.pos.offset)
			fmt.sbprintf(&sb, "\t\t\t\t\"line\": %d,\n", ev.pos.line)
			fmt.sbprintf(&sb, "\t\t\t\t\"column\": %d,\n", ev.pos.column)
			end_column := max(ev.end.column, ev.pos.column)
			fmt.sbprintf(&sb, "\t\t\t\t\"end_column\": %d\n", end_column)
			strings.write_string(&sb, "\t\t\t},\n")
		} else {
			strings.write_string(&sb, "\t\t\t\"pos\": null,\n")
		}

		// Messages
		strings.write_string(&sb, "\t\t\t\"msgs\": [\n")

		msg := string(ev.msg[:])
		lines := strings.split_lines(msg, context.temp_allocator)

		if len(lines) > 0 {
			strings.write_string(&sb, "\t\t\t\t\"")

			for line, j in lines {
				for k := 0; k < len(line); k += 1 {
					escape_char(&sb, line[k])
				}
				if j + 1 < len(lines) {
					strings.write_string(&sb, "\",\n")
					strings.write_string(&sb, "\t\t\t\t\"")
				}
			}
			strings.write_string(&sb, "\"\n")
		}

		strings.write_string(&sb, "\t\t\t]\n")
		strings.write_string(&sb, "\t\t}")

		if i + 1 != len(global_error_collector.error_values) {
			strings.write_string(&sb, ",")
		}
		strings.write_string(&sb, "\n")
	}

	strings.write_string(&sb, "\t]\n")
	strings.write_string(&sb, "}\n")

	output := strings.to_string(sb)
	os.write_string(os.stderr, output)
}

// ============================================================================
// Utility Functions
// ============================================================================

// clear_errors clears all accumulated errors (for testing)
clear_errors :: proc() {
	for &entry in global_error_collector.error_values {
		delete(entry.msg)
	}
	clear(&global_error_collector.error_values)
	sync.atomic_store(&global_error_collector.count, 0)
	sync.atomic_store(&global_error_collector.warning_count, 0)
	errors_already_printed = false
}

// ============================================================================
// Did You Mean - Suggestion System
// C++ Reference: common.cpp:921-962, check_expr.cpp:155-264
// ============================================================================

// Maximum edit distance to consider as a suggestion
MAX_DID_YOU_MEAN_DISTANCE :: 3

// Distance_And_Target pairs a string distance with a target string
Distance_And_Target :: struct {
	distance: int,
	target:   string,
}

// levenshtein_distance computes the edit distance between two strings (case insensitive)
// C++ Reference: common.cpp:859-918 (levenstein_distance_case_insensitive)
levenshtein_distance :: proc(s1, s2: string) -> int {
	// Convert to lowercase for case-insensitive comparison
	s1_lower := strings.to_lower(s1, context.temp_allocator)
	s2_lower := strings.to_lower(s2, context.temp_allocator)

	len1 := len(s1_lower)
	len2 := len(s2_lower)

	if len1 == 0 {
		return len2
	}
	if len2 == 0 {
		return len1
	}

	// Use two rows instead of full matrix for space efficiency
	prev_row := make([]int, len2 + 1, context.temp_allocator)
	curr_row := make([]int, len2 + 1, context.temp_allocator)

	// Initialize first row
	for j in 0 ..= len2 {
		prev_row[j] = j
	}

	// Fill in the rest
	for i in 1 ..= len1 {
		curr_row[0] = i
		for j in 1 ..= len2 {
			cost := 0 if s1_lower[i - 1] == s2_lower[j - 1] else 1
			curr_row[j] = min(
				prev_row[j] + 1, // deletion
				curr_row[j - 1] + 1, // insertion
				prev_row[j - 1] + cost, // substitution
			)
		}
		// Swap rows
		prev_row, curr_row = curr_row, prev_row
	}

	return prev_row[len2]
}

// check_did_you_mean_type prints suggestions for field/member names
// C++ Reference: check_expr.cpp:220-247
check_did_you_mean_type :: proc(name: string, fields: []^Entity, prefix := "") {
	if build_context.terse_errors {
		return
	}

	suggestions: [dynamic]Distance_And_Target
	defer delete(suggestions)

	// Calculate distances for all fields
	for field in fields {
		if field == nil {
			continue
		}
		target := field.token.text
		if len(target) == 0 || target == "_" {
			continue
		}
		distance := levenshtein_distance(name, target)
		if distance <= MAX_DID_YOU_MEAN_DISTANCE {
			append(&suggestions, Distance_And_Target{distance, target})
		}
	}

	if len(suggestions) == 0 {
		return
	}

	// Sort by distance
	slice.sort_by(suggestions[:], proc(a, b: Distance_And_Target) -> bool {
		return a.distance < b.distance
	})

	// Print suggestions
	error_line("\tSuggestion: Did you mean?")
	for s in suggestions {
		error_line("\t\t%s%s", prefix, s.target)
	}
}

// check_did_you_mean_scope prints suggestions for names in a scope
// C++ Reference: check_expr.cpp:249-264
check_did_you_mean_scope :: proc(name: string, scope: ^Scope, prefix := "") {
	if build_context.terse_errors || scope == nil {
		return
	}

	suggestions: [dynamic]Distance_And_Target
	defer delete(suggestions)

	// Calculate distances for all scope elements
	for _, entity in scope.elements {
		if entity == nil {
			continue
		}
		target := entity.token.text
		if len(target) == 0 || target == "_" {
			continue
		}
		distance := levenshtein_distance(name, target)
		if distance <= MAX_DID_YOU_MEAN_DISTANCE {
			append(&suggestions, Distance_And_Target{distance, target})
		}
	}

	if len(suggestions) == 0 {
		return
	}

	// Sort by distance
	slice.sort_by(suggestions[:], proc(a, b: Distance_And_Target) -> bool {
		return a.distance < b.distance
	})

	// Print suggestions
	error_line("\tSuggestion: Did you mean?")
	for s in suggestions {
		error_line("\t\t%s%s", prefix, s.target)
	}
}
