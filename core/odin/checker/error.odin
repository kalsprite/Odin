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

	// limit_reached latches once `count` exceeds `max_error_count`.
	//
	// DELIBERATE DIVERGENCE FROM C++ (see CPP_DEVIATIONS.md [EMBED-1]): the C++ compiler
	// prints everything collected so far and calls exit(1) at this point (error.cpp:535-563,
	// error.cpp:637-667) because there the checker *is* the process. This package is a
	// library, so instead of killing the host we latch this flag, drop further diagnostics,
	// and let the checking entry points unwind. Callers observe it via error_limit_reached()
	// and Package_Check_Result.limit_reached.
	//
	// Accessed from every checking thread; always read/written with sync.atomic_*, like
	// `count` and `warning_count`. A `bool` is a valid atomic type in Odin.
	limit_reached:        bool,

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
// tls_error_suppress_depth > 0 means diagnostics on this thread are being discarded.
// Balance every begin_suppress_errors with end_suppress_errors, ideally via `defer`.
@(thread_local) tls_error_suppress_depth: int

// begin_suppress_errors starts a region whose diagnostics are discarded (not counted, not
// collected). C++ achieves the same effect with dedicated no-error probe flags on the
// CheckerContext; the port needs a general mechanism because `error()` here is global.
begin_suppress_errors :: proc() {
	tls_error_suppress_depth += 1
}

end_suppress_errors :: proc() {
	assert(tls_error_suppress_depth > 0, "unbalanced end_suppress_errors")
	tls_error_suppress_depth -= 1
}

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
	sync.atomic_store(&global_error_collector.limit_reached, false)
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

// error_limit_reached reports whether the error cap (build_context.max_error_count) was hit
// during the current collector's lifetime.
//
// When this is true the diagnostics that were collected are a *truncated prefix* of the real
// diagnostics: everything reported after the cap was dropped, and the checking entry points
// stopped early. A result gathered under this condition must never be read as "clean" or as an
// accurate error count - it is incomplete by construction.
//
// C++ has no equivalent because it exits the process instead. See CPP_DEVIATIONS.md [EMBED-1].
error_limit_reached :: proc() -> bool {
	return sync.atomic_load(&global_error_collector.limit_reached)
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
//
// The returned slice BORROWS the collector's storage: it is invalidated by any further
// diagnostic (which may reallocate the backing array) and by destroy_error_collector (which
// frees every Error_Value.msg). To keep diagnostics past the collector's lifetime, use
// take_error_values instead.
get_error_values :: proc() -> []Error_Value {
	return global_error_collector.error_values[:]
}

// take_error_values transfers ownership of the accumulated diagnostics out of the global
// collector, so that they can outlive it.
//
// This exists because the collector is a process-global singleton whose lifetime is bounded by
// init_error_collector / destroy_error_collector, while a *result* handed back to an embedder
// has to remain readable afterwards. Copying would work but is unnecessary: the diagnostics are
// already a self-contained [dynamic]Error_Value (each Error_Value.msg is its own allocation),
// so the array is simply detached - no allocation, no copy.
//
// After this call the collector holds no diagnostics, and `count` / `warning_count` /
// `errors_already_printed` are reset to match: the errors left with the values, so claiming
// they are still here would make any_errors() true over an empty list. `limit_reached` is
// deliberately NOT cleared - it records that the cap was tripped during this collector's
// lifetime and that later diagnostics were dropped, which remains true no matter who owns the
// values (see CPP_DEVIATIONS.md [EMBED-1]).
//
// The caller owns the result and must free it with destroy_error_values.
take_error_values :: proc() -> (values: [dynamic]Error_Value) {
	sync.lock(&global_error_collector.mutex)
	defer sync.unlock(&global_error_collector.mutex)

	values = global_error_collector.error_values

	// A zero-length make performs no allocation; it only records the allocator, so the
	// collector stays usable and destroy_error_collector stays a no-op over it.
	global_error_collector.error_values = make([dynamic]Error_Value, 0, 0, global_error_collector.allocator)
	sync.atomic_store(&global_error_collector.count, 0)
	sync.atomic_store(&global_error_collector.warning_count, 0)
	errors_already_printed = false
	return
}

// destroy_error_values frees a diagnostic list obtained from take_error_values.
//
// Each Error_Value.msg is a separately allocated buffer, so freeing the array alone leaks every
// message - this mirrors what destroy_error_collector does for the collector-owned list.
destroy_error_values :: proc(values: ^[dynamic]Error_Value) {
	for &entry in values {
		delete(entry.msg)
	}
	delete(values^)
	values^ = nil
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
	// DELIBERATE DIVERGENCE FROM C++ (CPP_DEVIATIONS.md [EMBED-1]).
	// C++ error.cpp:535-563 does `print_all_errors(); exit(1);` here. That is correct for a
	// compiler that owns the process; it is wrong for a library, where it would kill the host
	// (e.g. the test binary in core/odin/checker/tests, taking the whole run with it).
	// Instead: latch the limit, stop recording, and let the caller unwind. Printing is the
	// host's job, not ours - see print_all_errors / exit_with_errors.

	// Fast path once the limit has been latched: no atomics-with-writes, no allocation, no
	// growth of error_values. The fact that the limit was hit is preserved in the flag.
	if error_limit_reached() {
		return
	}

	// Speculative probes (see begin_suppress_errors) discard diagnostics entirely: they
	// neither count nor reach the collector. Used where the checker evaluates an
	// expression purely to learn its type and will check it properly again later.
	if tls_error_suppress_depth > 0 {
		return
	}

	sync.atomic_add(&global_error_collector.count, 1)

	if sync.atomic_load(&global_error_collector.count) > build_context.max_error_count {
		// Latch and drop this diagnostic. C++ also drops it: it prints the *previously*
		// collected errors and exits before ever calling push_error_value.
		sync.atomic_store(&global_error_collector.limit_reached, true)
		return
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

// error_no_newline_va reports an error WITHOUT terminating its line, so a following
// error_line() continues on the same physical line.
//
// C++ Reference: error.cpp:605-631. Two things differ from error_va, and both are visible in
// the output:
//
//   1. The "Error: " label is emitted ONLY when the terminal supports ANSI colours. Under a
//      pipe it is omitted entirely, so the diagnostic reads `path(l:c) message`.
//   2. No trailing newline, and no source-line echo.
//
// That is why the oracle renders the singular forms of the unhandled-switch and
// unhandled-enumerated-array diagnostics as, for example:
//
//      sw/main.odin(16:2) Unhandled switch case: E5\tSuggestion: Was '#partial switch' wanted?
//
// It is one primitive, not a per-site quirk. LEDGER task 273.
error_no_newline_va :: proc(pos: tokenizer.Pos, format: string, args: ..any) {
	// Same collector bookkeeping as error_va; see the notes there on the library-safe
	// limit latch and on speculative probes.
	if error_limit_reached() {
		return
	}
	if tls_error_suppress_depth > 0 {
		return
	}

	sync.atomic_add(&global_error_collector.count, 1)

	if sync.atomic_load(&global_error_collector.count) > build_context.max_error_count {
		sync.atomic_store(&global_error_collector.limit_reached, true)
		return
	}

	push_error_value(pos, .Error)

	if pos.line == 0 {
		error_out_empty()
		error_out_coloured("Error: ", .Normal, .Red)
		error_out(format, ..args)
	} else {
		if json_errors() {
			error_out_empty()
		} else {
			error_out_pos(pos)
			if has_ansi_terminal_colours() {
				error_out_coloured("Error: ", .Normal, .Red)
			}
		}
		error_out(format, ..args)
	}

	try_pop_error_value()
}

error_no_newline :: proc(node: ^ast.Node, format: string, args: ..any) {
	error_no_newline_va(ast_token_pos(node), format, ..args)
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
	} else if !error_limit_reached() {
		// Fallback: print directly if no active error (shouldn't happen in normal use)
		fmt.eprintf(format, ..args)
	}
	// Once the error limit is latched, error_va/syntax_error_va return without pushing an
	// error value, so the `error(...)` that this line belongs to no longer exists. Emitting
	// the continuation on its own would spray headerless fragments at stderr, so drop it.
}

// syntax_error_va reports a syntax error with "Syntax Error:" prefix
// C++ Reference: error.cpp:637-667
syntax_error_va :: proc(pos: tokenizer.Pos, end: tokenizer.Pos, format: string, args: ..any) {
	// DELIBERATE DIVERGENCE FROM C++ (CPP_DEVIATIONS.md [EMBED-1]).
	// C++ error.cpp:637-667 does `print_all_errors(); exit(1);` here. Same reasoning as
	// error_va: a library must not terminate its host. Latch and unwind instead.
	if error_limit_reached() {
		return
	}

	sync.atomic_add(&global_error_collector.count, 1)

	if sync.atomic_load(&global_error_collector.count) > build_context.max_error_count {
		sync.atomic_store(&global_error_collector.limit_reached, true)
		return
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

// ast_token_pos returns the position C++ reports a diagnostic at for a given node.
//
// C++ Reference: parser_pos.cpp:1-110 (`ast_token`). Nearly every arm either returns the
// node's own first token or recurses leftward (BinaryExpr -> left, IndexExpr -> expr,
// OrReturnExpr -> expr, ...), all of which resolve to `node.pos`. Exactly TWO kinds have a
// representative token that is not the leftmost one, and for those `node.pos` is wrong:
//
//   Assign_Stmt  -> the operator      (parser_pos.cpp:64).  `y = f()` reports at the `=`.
//   Deref_Expr   -> the trailing `^`  (parser_pos.cpp:50).  Odin's deref is postfix.
//
// Found because cmp.sh started diffing diagnostic TEXT rather than counting: probe ud2
// matched on message and line but reported column 2 where the oracle reports column 4.
ast_token_pos :: proc(node: ^ast.Node) -> tokenizer.Pos {
	if node == nil {
		return tokenizer.Pos{}
	}
	#partial switch n in node.derived {
	case ^ast.Assign_Stmt:
		return n.op.pos
	case ^ast.Deref_Expr:
		return n.op.pos
	case ^ast.Implicit_Selector_Expr:
		// C++ parser_pos.cpp:35-39: reports at the SELECTOR, not the leading '.'.
		if n.field != nil {
			return n.field.pos
		}
	}
	return node.pos
}

error_node :: proc(node: ^ast.Node, format: string, args: ..any) {
	error_va(ast_token_pos(node), {}, format, ..args)
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
//
// HOST-DRIVER ONLY. Unlike error_va/syntax_error_va (see CPP_DEVIATIONS.md [EMBED-1]), this
// deliberately keeps the C++ exit(1) behaviour:
//   - It signals a violated internal invariant, not a diagnostic about the checked program.
//     Continuing past one produces garbage results rather than an incomplete-but-honest one,
//     so there is nothing meaningful to hand back to an embedder.
//   - It has no callers inside this package: internal invariants are enforced with `assert`
//     (which also aborts, but with a message and a trace - see check_deferred.odin:453).
// It must never be called from a library code path reachable while checking user code. If a
// recoverable condition ever needs reporting, use error()/syntax_error() instead.
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
//
// HOST-DRIVER ONLY. This keeps the C++ exit(1) because terminating *is* its entire contract:
// it exists so a command-line front end can end its own process after a failed check. It has
// no callers inside this package and must never acquire one. Embedders should call
// print_all_errors() / error_count() / error_limit_reached() and decide for themselves.
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

	// C++ Reference: error.cpp:897 - GB_ASSERT(any_errors() || any_warnings())
	//
	// KEPT, deliberately. This is a precondition, not a formality: every C++ call site guards
	// with `if (any_errors() || any_warnings())` (error.cpp:804, error.cpp:820) or has just
	// reported a diagnostic (error.cpp:539, 609, 641, 673). Reaching here with an empty global
	// collector means the caller believed there were diagnostics to print and was wrong -
	// almost always because the collector was torn down between reporting and printing. Making
	// that a silent no-op would hide the lifetime bug rather than expose it.
	//
	// Embedders holding their own diagnostics (take_error_values / Package_Check_Result) do NOT
	// come through here: print_error_values takes the list explicitly and has no global
	// precondition to violate, so printing an empty list there is a legitimate no-op.
	assert(
		any_errors() || any_warnings(),
		"print_all_errors called with no diagnostics in the global error collector - it was "+
		"either never populated or already destroyed. If you are printing the result of "+
		"check_package_from_path, use print_package_diagnostics(&result) instead: that result "+
		"owns its diagnostics and does not depend on the global collector still being alive.",
	)

	print_error_values(&global_error_collector.error_values)

	errors_already_printed = true
}

// print_error_values sorts, merges and prints a diagnostic list that the caller owns.
//
// This is the body of print_all_errors, parameterised over the storage. It exists so that
// diagnostics detached with take_error_values - which outlive the global collector - are
// printed by exactly the same code, rather than by a second, drifting implementation.
//
// Unlike print_all_errors this consults neither `errors_already_printed` nor any_errors(): both
// are properties of the global collector, and the list here is the caller's. An empty list
// prints nothing.
//
// The list is mutated in place (sorted, and neighbouring diagnostics at the same position are
// merged, freeing the absorbed entries), matching C++ behaviour.
print_error_values :: proc(values: ^[dynamic]Error_Value) {
	if len(values) == 0 {
		return
	}

	// Sort errors by position. STABLE, deliberately: the merge below keeps the FIRST
	// diagnostic at a given position and folds later ones into it, so the relative order of
	// diagnostics sharing a position decides which text survives. `slice.sort_by` is
	// unstable, which let that pair swap -- an undeclared name in type position printed
	// "'X' is not a type" (reported second) instead of "Undeclared name: X" (reported first),
	// diverging from C++. Emission order must be preserved for equal positions.
	slice.stable_sort_by(values[:], error_value_cmp)

	// Merge neighboring errors at the same position
	// C++ Reference: error.cpp:902-937
	{
		default_lines_to_skip := 1
		if show_error_line() {
			default_lines_to_skip += 2 // Two extra lines for source display
		}

		prev_ev: ^Error_Value = nil
		i := 0
		for i < len(values) {
			ev := &values[i]

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
				ordered_remove(values, i)
				// Don't increment i since we removed an element
			} else {
				prev_ev = ev
				i += 1
			}
		}
	}

	if json_errors() {
		print_errors_json(values[:])
	} else {
		print_errors_standard(values[:])
	}
}

// print_errors_standard outputs errors in standard format
// C++ Reference: error.cpp:1009-1027
print_errors_standard :: proc(error_values: []Error_Value) {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	for ev in error_values {
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
print_errors_json :: proc(error_values: []Error_Value) {
	sb := strings.builder_make(context.temp_allocator)
	defer strings.builder_destroy(&sb)

	strings.write_string(&sb, "{\n")
	fmt.sbprintf(&sb, "\t\"error_count\": %d,\n", len(error_values))
	strings.write_string(&sb, "\t\"errors\": [\n")

	for ev, i in error_values {
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
	sync.atomic_store(&global_error_collector.limit_reached, false)
	errors_already_printed = false
}

// ============================================================================
// Did You Mean - Suggestion System
// C++ Reference: common.cpp:921-962, check_expr.cpp:155-264
// ============================================================================

// Maximum edit distance to consider as a suggestion.
//
// C++ Reference: common.cpp:891 -- `MAX_SMALLEST_DID_YOU_MEAN_DISTANCE = 3-USE_DAMERAU_LEVENSHTEIN`,
// and USE_DAMERAU_LEVENSHTEIN is 1, so the real threshold is 2, not 3. The port used 3 to
// compensate for a distance function that could not express C++'s transposition term (see
// levenshtein_distance below); with that term restored, the constant must go back to 2 or the
// port suggests names C++ rejects.
MAX_DID_YOU_MEAN_DISTANCE :: 2

// Maximum number of suggestions printed before eliding the rest.
// C++ Reference: build_settings.cpp:12 DEFAULT_DID_YOU_MEAN_LIMIT, applied at main.cpp:1953.
DID_YOU_MEAN_LIMIT :: 10

// Distance_And_Target pairs a string distance with a target string
Distance_And_Target :: struct {
	distance: int,
	target:   string,
}

// levenshtein_distance computes the edit distance between two strings (case insensitive)
// C++ Reference: common.cpp:859-918 (levenstein_distance_case_insensitive)
levenshtein_distance :: proc(s1, s2: string) -> int {
	// C++ keeps the FULL matrix because its transposition term reads matrix[i-2][j-2] -- two
	// rows back. The port used a two-row rolling optimisation, which structurally cannot
	// express that term, so the term was simply absent and MAX_DID_YOU_MEAN_DISTANCE was
	// raised from 2 to 3 to compensate. The two are not equivalent: C++ scored "alph" against
	// "beta" at 2 (suggested), the port at 4 (rejected). Full matrix restored.
	//
	// NOTE(parity): C++'s transposition branch does NOT check that the two characters are
	// actually transposed -- it allows matrix[i-2][j-2]+1 whenever i > 1 && j > 1, which lets
	// ANY two-character block be repaired for the price of one edit. That is much weaker than
	// real Damerau-Levenshtein and is almost certainly a bug, but it is what decides which
	// suggestions the compiler prints, so it is reproduced exactly. Flagged upstream.
	//
	// C++ lowercases with gb_char_to_lower, which is ASCII-only; strings.to_lower is
	// Unicode-aware and can change the byte length, which would shift the matrix. Lowered
	// per byte here to match.
	lower :: proc(c: u8) -> u8 {
		return c + 32 if c >= 'A' && c <= 'Z' else c
	}

	w := len(s2) + 1
	h := len(s1) + 1
	d := make([]int, w * h, context.temp_allocator)
	for i in 0 ..= len(s1) {
		d[i * w + 0] = i
	}
	for j in 0 ..= len(s2) {
		d[0 * w + j] = j
	}

	for i in 1 ..= len(s1) {
		a_c := lower(s1[i - 1])
		for j in 1 ..= len(s2) {
			b_c := lower(s2[j - 1])
			if a_c == b_c {
				d[i * w + j] = d[(i - 1) * w + j - 1]
				continue
			}
			minimum := d[(i - 1) * w + j] + 1 // remove
			minimum = min(minimum, d[i * w + j - 1] + 1) // insert
			minimum = min(minimum, d[(i - 1) * w + j - 1] + 1) // substitute
			if i > 1 && j > 1 {
				// See NOTE(parity) above: deliberately unguarded, as in C++.
				minimum = min(minimum, d[(i - 2) * w + j - 2] + 1)
			}
			d[i * w + j] = minimum
		}
	}

	return d[len(s1) * w + len(s2)]
}

// gb_sort_by is a faithful port of gb_sort (src/gb/gb.h:3403-3455), the sort C++ uses for
// diagnostic candidate lists via array_sort.
//
// It matters because it is UNSTABLE: a median-of-3 quicksort down to runs of 8, then an
// insertion sort. For candidates that tie on distance, the order it produces is not the
// input order, and that order is what the compiler prints. Sorting the same list with a
// stable sort gave a suggestion list in declaration order where C++ prints Aaa, Bbb, Kkk,
// Jjj, Iii... -- same set, different first ten, and the first ten are all the user sees.
//
// The algorithm is deterministic, so this is reproducible; it just has to be the same
// algorithm. cmp returns <0, 0 or >0, as gbCompareProc does.
gb_sort_by :: proc(data: []$T, cmp: proc(a, b: T) -> int) {
	SORT_STACK_SIZE :: 64
	INSERT_SORT_THRESHOLD :: 8

	if len(data) < 2 {
		return
	}

	swap :: proc(data: []$E, a, b: int) {
		data[a], data[b] = data[b], data[a]
	}

	stack: [SORT_STACK_SIZE]int
	stack_ptr := 0

	base := 0
	limit := len(data) // exclusive, matching C++'s one-past-the-end `limit` pointer

	for {
		if limit - base > INSERT_SORT_THRESHOLD {
			i := base + 1
			j := limit - 1

			swap(data, (limit - base) / 2 + base, base)
			if cmp(data[i], data[j]) > 0 {
				swap(data, i, j)
			}
			if cmp(data[base], data[j]) > 0 {
				swap(data, base, j)
			}
			if cmp(data[i], data[base]) > 0 {
				swap(data, i, base)
			}

			for {
				for {
					i += 1
					if cmp(data[i], data[base]) >= 0 {
						break
					}
				}
				for {
					j -= 1
					if cmp(data[j], data[base]) <= 0 {
						break
					}
				}
				if i > j {
					break
				}
				swap(data, i, j)
			}

			swap(data, base, j)

			if j - base > limit - i {
				stack[stack_ptr] = base
				stack[stack_ptr + 1] = j
				stack_ptr += 2
				base = i
			} else {
				stack[stack_ptr] = i
				stack[stack_ptr + 1] = limit
				stack_ptr += 2
				limit = j
			}
		} else {
			j := base
			i := j + 1
			for i < limit {
				for cmp(data[j], data[j + 1]) > 0 {
					swap(data, j, j + 1)
					if j == base {
						break
					}
					j -= 1
				}
				j = i
				i += 1
			}

			if stack_ptr == 0 {
				break
			}
			stack_ptr -= 2
			base = stack[stack_ptr]
			limit = stack[stack_ptr + 1]
		}
	}
}

// did_you_mean_results sorts the candidates and keeps the prefix within the distance
// threshold, as C++ does: it scores EVERY candidate, sorts the whole array, then truncates.
// The port used to filter during collection instead, which is equivalent for the set but not
// for the ordering C++ produces.
// C++ Reference: common.cpp:912-925.
did_you_mean_results :: proc(suggestions: ^[dynamic]Distance_And_Target) -> []Distance_And_Target {
	// C++ Reference: common.cpp:913 -- array_sort, i.e. gb_sort, which is unstable.
	gb_sort_by(suggestions[:], proc(a, b: Distance_And_Target) -> int {
		return -1 if a.distance < b.distance else (1 if a.distance > b.distance else 0)
	})
	count := 0
	for s in suggestions {
		if s.distance > MAX_DID_YOU_MEAN_DISTANCE {
			break
		}
		count += 1
	}
	return suggestions[:count]
}

// check_did_you_mean_print renders the suggestion block.
// C++ Reference: check_expr.cpp:155-171.
//
// The port emitted every line WITHOUT a trailing newline, so the whole block rendered as one
// run-together line ("\tSuggestion: Did you mean?\t\t.Alpha"), and it had no limit, so a wide
// enum printed every candidate where C++ stops at ten and elides the rest.
check_did_you_mean_print :: proc(results: []Distance_And_Target, prefix := "") {
	if len(results) == 0 {
		return
	}
	error_line("\tSuggestion: Did you mean?\n")
	count := 0
	for r in results {
		error_line("\t\t%s%s\n", prefix, r.target)
		count += 1
		if DID_YOU_MEAN_LIMIT > 0 && count == DID_YOU_MEAN_LIMIT {
			// NOTE: C++ omits the trailing newline on this line specifically.
			error_line("\t\t... and %d more ...", len(results) - DID_YOU_MEAN_LIMIT)
			break
		}
	}
}

// check_did_you_mean_type prints suggestions for field/member names
// C++ Reference: check_expr.cpp:220-247
check_did_you_mean_type :: proc(name: string, fields: []^Entity, prefix := "") {
	if build_context.terse_errors {
		return
	}

	suggestions: [dynamic]Distance_And_Target
	defer delete(suggestions)

	for field in fields {
		if field == nil {
			continue
		}
		target := field.token.text
		if len(target) == 0 || target == "_" {
			continue
		}
		append(&suggestions, Distance_And_Target{levenshtein_distance(name, target), target})
	}

	check_did_you_mean_print(did_you_mean_results(&suggestions), prefix)
}

// check_did_you_mean_scope prints suggestions for names in a scope
// C++ Reference: check_expr.cpp:249-264
check_did_you_mean_scope :: proc(name: string, scope: ^Scope, prefix := "") {
	if build_context.terse_errors || scope == nil {
		return
	}

	suggestions: [dynamic]Distance_And_Target
	defer delete(suggestions)

	for _, entity in scope.elements {
		if entity == nil {
			continue
		}
		target := entity.token.text
		if len(target) == 0 || target == "_" {
			continue
		}
		append(&suggestions, Distance_And_Target{levenshtein_distance(name, target), target})
	}

	check_did_you_mean_print(did_you_mean_results(&suggestions), prefix)
}
