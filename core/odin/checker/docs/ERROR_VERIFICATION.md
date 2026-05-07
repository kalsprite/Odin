# Error Reporting Implementation Verification Report

**Source:** C++ Reference `/mnt/c/odin/src/error.cpp` (1,033 lines)
**Target:** Odin Port `/mnt/d/dev/checker/error.odin` (298 lines)
**Date:** 2025-10-03

---

## Executive Summary

**STATUS: INCOMPLETE - Critical functionality missing (~29% ported)**

The Odin error reporting implementation provides basic error collection and reporting but is missing significant functionality from the C++ reference. The port implements approximately 29% of the original codebase by line count, with critical omissions in:

- Advanced error formatting with ANSI terminal colors
- Source code context display with intelligent line truncation
- Thread-safe error collection mechanisms
- Error block grouping for multi-line suggestions
- JSON error output format
- Error deduplication and merging
- Unicode/grapheme-aware error positioning

---

## 1. Implementation Status

### Line Count Comparison
- **C++ Implementation:** 1,033 lines
- **Odin Implementation:** 298 lines
- **Coverage:** ~29% (by line count)
- **Missing:** ~735 lines of functionality

### Functional Coverage

| Component | C++ | Odin | Status | Completeness |
|-----------|-----|------|--------|--------------|
| Basic error/warning reporting | ✓ | ✓ | PARTIAL | 60% |
| Error collection structures | ✓ | ✓ | PARTIAL | 50% |
| Thread-safe error handling | ✓ | ✗ | MISSING | 0% |
| ANSI terminal colors | ✓ | ✗ | MISSING | 0% |
| Source line display with squiggles | ✓ | ✗ | MISSING | 0% |
| Unicode/grapheme handling | ✓ | ✗ | MISSING | 0% |
| Error blocks (multi-line errors) | ✓ | ✗ | MISSING | 0% |
| JSON error output | ✓ | ✗ | MISSING | 0% |
| Error deduplication/merging | ✓ | ✗ | MISSING | 0% |
| Terse error mode | ✓ | ✗ | MISSING | 0% |
| Error article formatting | ✓ | ✗ | MISSING | 0% |
| End position tracking | ✓ | ✗ | MISSING | 0% |

---

## 2. Missing Features (with C++ References)

### 2.1 Thread-Safe Error Collection

**C++ Reference:** `/mnt/c/odin/src/error.cpp:14-26`
```cpp
struct ErrorCollector {
    std::atomic<i64>  count;
    std::atomic<i64>  warning_count;
    std::atomic<bool> in_block;
    RecursiveMutex    mutex;
    BlockingMutex     path_mutex;
    Array<ErrorValue> error_values;
    ErrorValue        curr_error_value;
    std::atomic<bool> curr_error_value_set;
};
```

**Missing in Odin:**
- Atomic counters for thread-safe increment
- Mutex-based synchronization for error collection
- Current error value tracking for thread-local error building
- Path mutex for file path string management

**Impact:** High - The C++ implementation supports multi-threaded type checking with safe error reporting. The Odin version is single-threaded only.

---

### 2.2 Error Block Mechanism (Multi-line Error Context)

**C++ Reference:** `/mnt/c/odin/src/error.cpp:214-225`
```cpp
gb_internal void begin_error_block(void) {
    mutex_lock(&global_error_collector.mutex);
    global_error_collector.in_block.store(true);
}

gb_internal void end_error_block(void) {
    pop_error_value();
    global_error_collector.in_block.store(false);
    mutex_unlock(&global_error_collector.mutex);
}

#define ERROR_BLOCK() begin_error_block(); defer (end_error_block())
```

**Usage in C++ (116 occurrences across 9 files):**
- `/mnt/c/odin/src/check_expr.cpp`: 40 uses
- `/mnt/c/odin/src/check_stmt.cpp`: 18 uses
- `/mnt/c/odin/src/checker.cpp`: 14 uses
- `/mnt/c/odin/src/check_builtin.cpp`: 11 uses
- `/mnt/c/odin/src/check_type.cpp`: 10 uses

**Missing in Odin:**
- `begin_error_block()` / `end_error_block()` functions
- Thread-safe error value push/pop mechanism
- Ability to append multiple lines to a single error before committing

**Impact:** Critical - Error blocks allow building complex, multi-line error messages with suggestions and context. Without this, suggestion generation and "did you mean" features cannot be properly implemented.

**Current Odin Workaround:** `/mnt/d/dev/checker/error.odin:186-194`
```odin
error_line :: proc(fmt_str: string, args: ..any) {
    // For now, just print directly to stderr
    // In the full implementation, this would append to the current error entry
    fmt.eprintf("       ")
    fmt.eprintf(fmt_str, ..args)
    fmt.eprintln()
}
```
This is a stub that prints immediately rather than appending to the current error.

---

### 2.3 Source Line Display with Visual Squiggles

**C++ Reference:** `/mnt/c/odin/src/error.cpp:282-516` (235 lines)

This is the most complex missing feature. The C++ implementation:

1. **Fetches source line** (`error.cpp:289`)
2. **Decodes Unicode grapheme clusters** (`error.cpp:308-332`)
3. **Handles line truncation intelligently** (`error.cpp:370-433`)
   - Keeps error position visible
   - Shows ellipses for long lines
   - Respects 80-column terminal width
4. **Prints source line with colors** (`error.cpp:444-445`)
5. **Generates visual squiggles** (`error.cpp:447-507`)
   - `^` at start and end of error range
   - `~` for multi-character errors
   - `... ` for errors spanning multiple lines
6. **Handles multi-width characters** (tabs, emoji, CJK characters)

**Example C++ Output:**
```
file.odin(10:5) Error: undeclared identifier 'foo'
    let x = foo + bar
            ^~~
```

**Missing in Odin:**
- Entire source line retrieval system
- Unicode grapheme cluster parsing
- Visual squiggle generation
- Intelligent line truncation
- End position tracking for error ranges

**Impact:** Critical - Users won't see WHERE in the source code the error occurred, making debugging significantly harder.

---

### 2.4 ANSI Terminal Color Support

**C++ Reference:** `/mnt/c/odin/src/error.cpp:236-279`
```cpp
enum TerminalStyle {
    TerminalStyle_Normal,
    TerminalStyle_Bold,
    TerminalStyle_Underline,
};

enum TerminalColour {
    TerminalColour_White,
    TerminalColour_Red,
    TerminalColour_Yellow,
    // ... (9 colors total)
};

gb_internal void terminal_set_colours(TerminalStyle style, TerminalColour foreground) {
    if (has_ansi_terminal_colours()) {
        // Emits ANSI escape codes
    }
}
```

**Usage:**
- Errors: Red text (`error.cpp:546, 555`)
- Warnings: Yellow text (`error.cpp:581, 590`)
- Position info: Bold white (`error.cpp:522`)
- Source code: White (`error.cpp:444`)
- Squiggles: Bold green (`error.cpp:492`)

**Missing in Odin:**
- All color support
- Style support (bold, underline)
- Terminal capability detection

**Impact:** Medium - Reduces visual clarity but doesn't affect functionality.

---

### 2.5 JSON Error Output Format

**C++ Reference:** `/mnt/c/odin/src/error.cpp:942-1008` (67 lines)

The C++ implementation can output errors as structured JSON for IDE integration:

```json
{
    "error_count": 2,
    "errors": [
        {
            "type": "error",
            "pos": {
                "file": "test.odin",
                "offset": 145,
                "line": 10,
                "column": 5,
                "end_column": 8
            },
            "msgs": [
                "undeclared identifier 'foo'",
                "Suggestion: Did you mean 'for'?"
            ]
        }
    ]
}
```

**Missing in Odin:**
- JSON output mode detection (`json_errors()`)
- JSON formatting logic
- Escape character handling for JSON strings
- Multi-message support per error

**Impact:** Medium - Required for IDE/LSP integration, but not needed for CLI usage.

---

### 2.6 Error Deduplication and Merging

**C++ Reference:** `/mnt/c/odin/src/error.cpp:902-937`

The C++ implementation merges errors at the same position:

```cpp
ErrorValue *prev_ev = nullptr;
for (isize i = 0; i < global_error_collector.error_values.count; /**/) {
    ErrorValue &ev = global_error_collector.error_values[i];

    if (prev_ev && prev_ev->pos == ev.pos) {
        // Skip duplicate position lines and merge suggestions
        String_Iterator it = {{ev.msg.data, ev.msg.count}, 0};
        for (isize lines_to_skip = default_lines_to_skip; lines_to_skip > 0; lines_to_skip -= 1) {
            String line = string_split_iterator(&it, '\n');
        }

        // Append unique suggestions to previous error
        String addition = {it.str.text+it.pos, it.str.len-it.pos};
        if (addition.len > 0 && !string_contains_string(current, addition)) {
            array_add_elems(&prev_ev->msg, addition.text, addition.len);
        }

        array_free(&ev.msg);
        array_ordered_remove(&global_error_collector.error_values, i);
    } else {
        prev_ev = &ev;
        i += 1;
    }
}
```

**Missing in Odin:**
- Error sorting by position (`error.cpp:899`)
- Duplicate detection logic
- Suggestion merging
- Smart line skipping to preserve suggestions while removing duplicate context

**Impact:** Medium - Without this, users may see the same error position reported multiple times with different suggestions, creating noise.

---

### 2.7 Terse Error Mode

**C++ Reference:** `/mnt/c/odin/src/error.cpp:198-209, 1023-1025`

The C++ implementation supports a "terse" mode that stops error message accumulation at the first newline:

```cpp
if (terse_errors()) {
    for (isize i = 0; i < n && !ev->seen_newline; i++) {
        u8 c = cast(u8)buf[i];
        if (c == '\n') {
            ev->seen_newline = true;
        }
        array_add(&ev->msg, c);
    }
} else {
    array_add_elems(&ev->msg, (u8 *)buf, n);
}
```

**Missing in Odin:**
- Terse mode flag
- Newline tracking in error values (`seen_newline` field)
- Single-line error output truncation

**Impact:** Low - Nice-to-have for cleaner CI output.

---

### 2.8 Error End Position Tracking

**C++ Reference:** `/mnt/c/odin/src/error.cpp:6-12`
```cpp
struct ErrorValue {
    ErrorValueKind kind;
    TokenPos       pos;      // Start position
    TokenPos       end;      // End position
    Array<u8>      msg;
    bool           seen_newline;
};
```

**Usage:** `/mnt/c/odin/src/error.cpp:450-480`
```cpp
if (end.file_id == pos.file_id) {
    if (end.line > pos.line) {
        // Error spans multiple lines
    } else if (end.line == pos.line && end.column > pos.column) {
        // Error has specific range on same line
        // Calculate squiggle length from pos to end
    }
} else {
    // Single-point error
    squiggle_length = 1;
}
```

**Missing in Odin:**
- `end` position field in `Error_Entry` (`error.odin:31-35`)
- End position parameter in error functions
- Range-based squiggle generation

**Impact:** High - Multi-character error ranges (e.g., highlighting an entire identifier) cannot be shown.

---

### 2.9 Error Article Formatting

**C++ Reference:** `/mnt/c/odin/src/error.cpp:834-861`

Provides grammatically correct indefinite articles for error messages:

```cpp
gb_global String error_article_table[][2] = {
    {str_lit("a "),  str_lit("bit_set literal")},
    {str_lit("a "),  str_lit("constant declaration")},
    {str_lit("an "), str_lit("'any' literal")},
    {str_lit("an "), str_lit("array literal")},
    // ... 14 entries total
};

gb_internal String error_article(String context_name) {
    for (int i = 0; i < gb_count_of(error_article_table); i += 1) {
        if (context_name == error_article_table[i][1]) {
            return error_article_table[i][0];
        }
    }
    return str_lit("");
}
```

**Usage Example:**
```
Error: Expected a constant declaration, got an expression
```

**Missing in Odin:**
- Article lookup table
- `error_article()` helper function

**Impact:** Low - Purely cosmetic, improves error message grammar.

---

### 2.10 Advanced Error Output Mechanism

**C++ Reference:** `/mnt/c/odin/src/error.cpp:188-234`

The C++ implementation uses a pluggable error output system:

```cpp
typedef ERROR_OUT_PROC(ErrorOutProc);
gb_global ErrorOutProc *error_out_va = default_error_out_va;

gb_internal void error_out(char const *fmt, ...) {
    va_list va;
    va_start(va, fmt);
    error_out_va(fmt, va);  // Calls function pointer
    va_end(va);
}
```

This allows:
- Appending to current error buffer instead of immediate stderr output
- Swapping output handlers for testing or custom formatting
- Building error messages incrementally

**Missing in Odin:**
- Function pointer-based output abstraction
- Buffered error message building
- Current error value tracking during construction

**Impact:** Critical - Required for error blocks and multi-line error formatting to work correctly.

---

### 2.11 File Path Thread-Safe Management

**C++ Reference:** `/mnt/c/odin/src/error.cpp:86-153`

```cpp
gb_internal bool set_file_path_string(i32 index, String const &path) {
    bool ok = false;
    mutex_lock(&global_files_mutex);

    if (index >= global_file_path_strings.count) {
        array_resize(&global_file_path_strings, index+1);
    }
    String prev = global_file_path_strings[index];
    if (prev.len == 0) {
        global_file_path_strings[index] = path;
        ok = true;
    }

    mutex_unlock(&global_files_mutex);
    return ok;
}
```

**Missing in Odin:**
- File path string array management
- Thread-safe file path lookup
- AST file pointer management

**Impact:** High for multi-threaded implementation - Required to safely access file paths from error positions during parallel type checking.

---

### 2.12 Syntax Error Variants

**C++ Reference:** `/mnt/c/odin/src/error.cpp:669-701, 794-799`

The C++ implementation has specialized syntax error functions:

```cpp
// Standard syntax error
gb_internal void syntax_error(TokenPos pos, char const *fmt, ...);

// Syntax error with verbose mode (shows squiggles even if disabled)
gb_internal void syntax_error_with_verbose(TokenPos pos, TokenPos end, char const *fmt, ...);

// Syntax warning (can be converted to error with -warnings-as-errors)
gb_internal void syntax_warning(Token const &token, char const *fmt, ...);
```

**Missing in Odin:**
- `syntax_error_with_verbose()` - forces error line display
- Proper `syntax_warning()` implementation (basic version exists but incomplete)

**Impact:** Low - Minor functional loss in parser error reporting.

---

## 3. Semantic Differences

### 3.1 Error Collection Strategy

**C++ Approach:**
- Errors are built incrementally using `push_error_value()` → `error_out()` → `pop_error_value()`
- Error message is accumulated in a dynamic byte array (`Array<u8> msg`)
- Error is only added to collection when popped
- Supports multi-line building with `ERROR_BLOCK()`

**Odin Approach:**
- Errors are formatted immediately with `fmt.tprintf()`
- Error message is cloned as a complete string
- Error is added to collection immediately
- No support for incremental building

**Consequence:** The Odin version cannot support error blocks or appending suggestions after the initial error is reported.

---

### 3.2 Error Message Formatting

**C++ Approach:**
```
file.odin(10:5) Error: undeclared identifier 'foo'
    let x = foo + bar
            ^~~
    Suggestion: Did you mean 'for'?
```

**Odin Approach (current):**
```
file.odin(10:5) Error: undeclared identifier 'foo'
```

**Missing:**
- Source line context
- Visual squiggles
- Color coding
- Inline suggestions

---

### 3.3 Thread Safety

**C++:** Full thread-safe implementation with atomic counters and mutexes
**Odin:** No thread safety - relies on single-threaded execution

**Consequence:** Odin implementation cannot support parallel type checking without race conditions in error reporting.

---

### 3.4 Error Limit Behavior

**C++ Reference:** `/mnt/c/odin/src/error.cpp:538-541`
```cpp
if (global_error_collector.count > MAX_ERROR_COLLECTOR_COUNT()) {
    print_all_errors();
    gb_exit(1);
}
```

**Odin Implementation:** `/mnt/d/dev/checker/error.odin:106-111`
```odin
if global_error_collector.max_errors > 0 &&
   global_error_collector.error_count > global_error_collector.max_errors {
    print_all_errors()
    fmt.eprintln("Too many errors, aborting")
    os.exit(1)
}
```

**Difference:** Odin uses configurable `max_errors` from initialization, C++ uses global `MAX_ERROR_COLLECTOR_COUNT()` function. Functionally similar but C++ ties it to build settings.

---

## 4. Critical Bugs

### 4.1 Incorrect Summary Printing

**Location:** `/mnt/d/dev/checker/error.odin:270-277`

```odin
} else if global_error_collector.warning_count > 0 {
    fmt.eprintln()
    if global_error_collector.warning_count == 1 {
        fmt.eprintln("1 warning")  // BUG: Uses eprintln instead of eprintf
    } else {
        fmt.eprintln("%d warnings", global_error_collector.warning_count)  // BUG: Formatted print
    }
}
```

**Issues:**
1. Line 273: Should be `fmt.eprintf("1 warning\n")` not `fmt.eprintln("1 warning")`
2. Line 275: `fmt.eprintln()` doesn't format - should be `fmt.eprintf("%d warnings\n", ...)`

**C++ Reference:** `/mnt/c/odin/src/error.cpp:1029-1030`
```cpp
gbFile *f = gb_file_get_standard(gbFileStandard_Error);
gb_file_write(f, res, gb_string_length(res));
```

The C++ version builds the entire output as a string first, then writes it. This avoids formatting bugs.

---

### 4.2 Missing Error Value Freeing

**Location:** `/mnt/d/dev/checker/error.odin:243-278`

The `print_all_errors()` function doesn't free error messages after printing.

**C++ Reference:** `/mnt/c/odin/src/error.cpp:866-872, 930, 1031-1032`
```cpp
// If previously printed and only warnings remain
for (ErrorValue &ev : global_error_collector.error_values) {
    array_free(&ev.msg);
}
array_clear(&global_error_collector.error_values);

// After merging
array_free(&ev.msg);

// Implicit: errors are cleared after final print
```

**Missing in Odin:**
- No freeing of error message strings after printing
- No clearing of entries array after print

**Impact:** Memory leak if `print_all_errors()` is called multiple times or if program continues after printing.

**Fix needed:** Add cleanup logic similar to C++.

---

### 4.3 Position Formatting Discrepancy

**Odin:** `/mnt/d/dev/checker/error.odin:223-228`
```odin
format_pos :: proc(pos: tokenizer.Pos) -> string {
    if pos.file == "" {
        return "<unknown>"
    }
    return fmt.tprintf("%s(%d:%d)", pos.file, pos.line, pos.column)
}
```

**C++ Reference:** `/mnt/c/odin/src/error.cpp:521-525`
```cpp
gb_internal void error_out_pos(TokenPos pos) {
    terminal_set_colours(TerminalStyle_Bold, TerminalColour_White);
    error_out("%s ", token_pos_to_string(pos));  // Note: space after position
    terminal_reset_colours();
}
```

**Issue:** The C++ version adds a space after the position string and uses bold white color. The Odin version returns a bare string that's printed directly. The Odin version should add a trailing space for consistency.

---

## 5. Stub Analysis

### 5.1 `error_line()` Function

**Location:** `/mnt/d/dev/checker/error.odin:186-194`

```odin
error_line :: proc(fmt_str: string, args: ..any) {
    // For now, just print directly to stderr
    // In the full implementation, this would append to the current error entry
    fmt.eprintf("       ")
    fmt.eprintf(fmt_str, ..args)
    fmt.eprintln()
}
```

**Status:** STUB - Comment explicitly states this is temporary

**C++ Reference:** `/mnt/c/odin/src/error.cpp:601-603, 765-770`
```cpp
gb_internal void error_line_va(char const *fmt, va_list va) {
    error_out_va(fmt, va);  // Appends to current error buffer
}

gb_internal void error_line(char const *fmt, ...) {
    va_list va;
    va_start(va, fmt);
    error_line_va(fmt, va);
    va_end(va);
}
```

**Correct Behavior:** Should append to the current error's message buffer, not print immediately.

**Impact:** High - Makes multi-line error messages and suggestions impossible.

---

### 5.2 Incomplete `print_error_entry()`

**Location:** `/mnt/d/dev/checker/error.odin:230-240`

```odin
print_error_entry :: proc(entry: Error_Entry) {
    pos_str := format_pos(entry.pos)

    switch entry.kind {
    case .Error:
        fmt.eprintf("%s Error: %s\n", pos_str, entry.message)
    case .Warning:
        fmt.eprintf("%s Warning: %s\n", pos_str, entry.message)
    }
}
```

**Missing compared to C++:**
- No source line context display
- No color coding
- No error range squiggles
- No handling of multi-line messages

**C++ Equivalent:** `/mnt/c/odin/src/error.cpp:1010-1027`
The C++ version iterates through lines in the error message and trims whitespace.

---

### 5.3 Simplified Initialization

**Location:** `/mnt/d/dev/checker/error.odin:56-70`

```odin
init_error_collector :: proc(
    max_errors := 0,
    warnings_as_errors := false,
    ignore_warnings := false,
    allocator := context.allocator,
) {
    global_error_collector.entries = make([dynamic]Error_Entry, allocator)
    global_error_collector.error_count = 0
    global_error_collector.warning_count = 0
    global_error_collector.max_errors = max_errors
    global_error_collector.warnings_as_errors = warnings_as_errors
    global_error_collector.ignore_warnings = ignore_warnings
    global_error_collector.show_error_lines = true  // Hardcoded but not implemented
    global_error_collector.allocator = allocator
}
```

**C++ Reference:** `/mnt/c/odin/src/error.cpp:73-77`
```cpp
gb_internal void init_global_error_collector(void) {
    array_init(&global_error_collector.error_values, heap_allocator());
    array_init(&global_file_path_strings, heap_allocator(), 1, 4096);
    array_init(&global_files,             heap_allocator(), 1, 4096);
}
```

**Missing:**
- File path string array initialization
- AST file array initialization
- Mutex initialization (not applicable if single-threaded)

**Note:** The Odin version sets `show_error_lines = true` but doesn't implement the feature.

---

## 6. Required Fixes (Prioritized)

### Priority 1: Critical Correctness Issues

#### 6.1 Fix Warning Summary Printing Bug
**File:** `/mnt/d/dev/checker/error.odin:275`

**Current:**
```odin
fmt.eprintln("%d warnings", global_error_collector.warning_count)
```

**Should be:**
```odin
fmt.eprintf("%d warnings\n", global_error_collector.warning_count)
```

**Reference:** None needed - `fmt.eprintln()` doesn't support format strings in Odin.

---

#### 6.2 Implement Error Message Cleanup
**File:** `/mnt/d/dev/checker/error.odin:243-278`

Add cleanup logic to `print_all_errors()`:

```odin
print_all_errors :: proc() {
    if len(global_error_collector.entries) == 0 {
        return
    }

    // Print all entries
    for entry in global_error_collector.entries {
        print_error_entry(entry)
    }

    // Print summary
    // ... existing code ...

    // MISSING: Free error messages and clear array
    for entry in global_error_collector.entries {
        delete(entry.message, global_error_collector.allocator)
    }
    clear(&global_error_collector.entries)
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:868-871`

---

#### 6.3 Add End Position to Error_Entry
**File:** `/mnt/d/dev/checker/error.odin:31-35`

**Current:**
```odin
Error_Entry :: struct {
    kind:    Error_Kind,
    pos:     tokenizer.Pos,
    message: string,
}
```

**Should be:**
```odin
Error_Entry :: struct {
    kind:    Error_Kind,
    pos:     tokenizer.Pos,
    end:     tokenizer.Pos,  // NEW: End position for ranges
    message: string,
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:6-12`

Update all error reporting functions to accept optional `end` parameter.

---

### Priority 2: Essential Features for Usability

#### 6.4 Implement Error Block Mechanism
**Files:** `/mnt/d/dev/checker/error.odin`

Add structures and functions:

```odin
// Add to Error_Collector
Error_Collector :: struct {
    // ... existing fields ...
    in_block:           bool,
    curr_error_building: ^Error_Entry,  // Error being built
}

begin_error_block :: proc() {
    global_error_collector.in_block = true
    // Create new error entry in building state
}

end_error_block :: proc() {
    if global_error_collector.curr_error_building != nil {
        append(&global_error_collector.entries, global_error_collector.curr_error_building^)
        free(global_error_collector.curr_error_building)
        global_error_collector.curr_error_building = nil
    }
    global_error_collector.in_block = false
}

// Fix error_line to append to current error
error_line :: proc(fmt_str: string, args: ..any) {
    if global_error_collector.in_block && global_error_collector.curr_error_building != nil {
        line := fmt.tprintf(fmt_str, ..args)
        global_error_collector.curr_error_building.message = strings.concatenate(
            {global_error_collector.curr_error_building.message, "\n       ", line},
            global_error_collector.allocator,
        )
    } else {
        fmt.eprintf("       ")
        fmt.eprintf(fmt_str, ..args)
        fmt.eprintln()
    }
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:214-225`

---

#### 6.5 Implement Basic Source Line Display
**Files:** `/mnt/d/dev/checker/error.odin`

Add simplified version without Unicode support initially:

```odin
// Add to settings
show_error_line :: proc() -> bool {
    return global_error_collector.show_error_lines
}

// Basic implementation (no Unicode, no truncation)
show_error_on_line :: proc(pos: tokenizer.Pos, end: tokenizer.Pos) {
    if !show_error_line() {
        return
    }

    // TODO: Implement file reading and line extraction
    // For now, this is a placeholder
    // 1. Read file at pos.file
    // 2. Extract line at pos.line
    // 3. Print line with tabs expanded
    // 4. Print squiggles at pos.column
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:282-516` (simplified version)

**Full Implementation:** This is a large task. Start with ASCII-only, fixed-width characters. Add Unicode support later.

---

#### 6.6 Implement Error Sorting and Deduplication
**Files:** `/mnt/d/dev/checker/error.odin`

Add to `print_all_errors()`:

```odin
import "core:slice"

print_all_errors :: proc() {
    if len(global_error_collector.entries) == 0 {
        return
    }

    // Sort errors by position
    slice.sort_by(global_error_collector.entries[:], proc(a, b: Error_Entry) -> bool {
        if a.pos.file != b.pos.file {
            return a.pos.file < b.pos.file
        }
        if a.pos.line != b.pos.line {
            return a.pos.line < b.pos.line
        }
        return a.pos.column < b.pos.column
    })

    // TODO: Add deduplication logic

    // Print all entries
    for entry in global_error_collector.entries {
        print_error_entry(entry)
    }

    // ... rest of function
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:899, 902-937`

---

### Priority 3: Nice-to-Have Enhancements

#### 6.7 Add ANSI Color Support
**Files:** `/mnt/d/dev/checker/error.odin`

```odin
Terminal_Style :: enum {
    Normal,
    Bold,
    Underline,
}

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

has_ansi_terminal_colours :: proc() -> bool {
    // Check TERM environment variable or OS capabilities
    return true  // Simplified
}

terminal_set_colours :: proc(style: Terminal_Style, foreground: Terminal_Colour) {
    if !has_ansi_terminal_colours() {
        return
    }

    style_code := "0"
    switch style {
    case .Normal:    style_code = "0"
    case .Bold:      style_code = "1"
    case .Underline: style_code = "4"
    }

    color_code := "37"
    switch foreground {
    case .White:  color_code = "37"
    case .Red:    color_code = "31"
    case .Yellow: color_code = "33"
    // ... etc
    }

    fmt.eprintf("\x1b[%s;%sm", style_code, color_code)
}

terminal_reset_colours :: proc() {
    if has_ansi_terminal_colours() {
        fmt.eprintf("\x1b[0m")
    }
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:236-279`

---

#### 6.8 Add JSON Error Output
**Files:** `/mnt/d/dev/checker/error.odin`

Add field to `Error_Collector`:
```odin
json_errors: bool,
```

Implement JSON formatting in `print_all_errors()`:

```odin
if global_error_collector.json_errors {
    // Build JSON structure
    fmt.eprintln("{")
    fmt.eprintf("  \"error_count\": %d,\n", len(global_error_collector.entries))
    fmt.eprintln("  \"errors\": [")

    for entry, i in global_error_collector.entries {
        fmt.eprintln("    {")
        fmt.eprintf("      \"type\": \"%s\",\n", entry.kind == .Error ? "error" : "warning")
        // ... etc
        fmt.eprintf("    }%s\n", i < len(global_error_collector.entries) - 1 ? "," : "")
    }

    fmt.eprintln("  ]")
    fmt.eprintln("}")
} else {
    // Normal text output
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:942-1008`

---

#### 6.9 Add Error Article Helper
**Files:** `/mnt/d/dev/checker/error.odin`

```odin
ERROR_ARTICLE_TABLE :: [][2]string {
    {"a ", "bit_set literal"},
    {"a ", "constant declaration"},
    {"a ", "dynamic array literal"},
    {"an ", "'any' literal"},
    {"an ", "array literal"},
    // ... etc
}

error_article :: proc(context_name: string) -> string {
    for entry in ERROR_ARTICLE_TABLE {
        if context_name == entry[1] {
            return entry[0]
        }
    }
    return ""
}
```

**Reference:** `/mnt/c/odin/src/error.cpp:834-861`

---

### Priority 4: Advanced Features

#### 6.10 Add Thread-Safe Error Collection
**Files:** `/mnt/d/dev/checker/error.odin`

**Note:** This requires adding mutex support and atomic operations. Defer until multi-threaded type checking is implemented.

**Reference:** `/mnt/c/odin/src/error.cpp:14-56`

---

#### 6.11 Implement Full Unicode/Grapheme Support
**Files:** `/mnt/d/dev/checker/error.odin`

**Note:** This is complex and requires Unicode grapheme cluster parsing library. Consider using existing Odin Unicode libraries or porting the C++ implementation.

**Reference:** `/mnt/c/odin/src/error.cpp:308-332`

---

## 7. Implementation Roadmap

### Phase 1: Correctness Fixes (1-2 days)
1. Fix warning summary printing bug (30 min)
2. Add error message cleanup to `print_all_errors()` (1 hour)
3. Add `end` position field to `Error_Entry` (2 hours)
4. Update all error reporting functions to track end position (3 hours)
5. Add error sorting (1 hour)

**Deliverable:** Bug-free basic error reporting with proper memory management.

---

### Phase 2: Error Block Support (2-3 days)
1. Add error block infrastructure (4 hours)
2. Implement `begin_error_block()` / `end_error_block()` (2 hours)
3. Fix `error_line()` to append to current error (2 hours)
4. Test with multi-line error examples (2 hours)
5. Add error deduplication logic (4 hours)

**Deliverable:** Support for building complex, multi-line errors with suggestions.

---

### Phase 3: Source Line Display (5-7 days)
1. Implement file reading and line extraction (1 day)
2. Add basic ASCII-only squiggle generation (2 days)
3. Add line truncation for long lines (1 day)
4. Test with various error positions (1 day)
5. Add Unicode grapheme support (2-3 days)

**Deliverable:** Visual source code context with squiggles pointing to errors.

---

### Phase 4: Visual Enhancements (2-3 days)
1. Implement ANSI color support (1 day)
2. Add terminal capability detection (4 hours)
3. Update all print functions to use colors (4 hours)
4. Add terse error mode (2 hours)
5. Test across different terminals (4 hours)

**Deliverable:** Colored, visually clear error output.

---

### Phase 5: IDE Integration (2-3 days)
1. Add JSON error output mode (1 day)
2. Implement JSON escaping (4 hours)
3. Add multi-message support (4 hours)
4. Test with IDE/LSP integration (1 day)

**Deliverable:** Machine-readable error output for tooling.

---

### Phase 6: Thread Safety (3-5 days)
1. Add mutex support to Error_Collector (1 day)
2. Add atomic counters (4 hours)
3. Implement thread-safe file path management (1 day)
4. Add thread-local error building (1 day)
5. Test with parallel type checking (1-2 days)

**Deliverable:** Thread-safe error reporting for parallel compilation.

---

### Estimated Total Time: 15-23 days

---

## 8. Verification Summary

### Overall Assessment

The Odin error reporting implementation is **INCOMPLETE** and represents approximately **29% of the C++ reference** by line count. While it provides basic error and warning collection, it lacks critical features that make the Odin compiler's error messages helpful:

**Working Features:**
- Basic error and warning reporting
- Error count tracking
- Simple position formatting
- Warnings-as-errors mode
- Max error limit enforcement
- Basic summary output

**Missing Critical Features:**
- Source line display with visual squiggles (235 lines of C++ code)
- Error block mechanism for multi-line messages (required by 116 call sites)
- Thread-safe error collection (required for parallel type checking)
- Error deduplication and merging
- End position tracking for error ranges
- ANSI terminal color support
- JSON error output for IDE integration
- Unicode/grapheme-aware error positioning

**Bugs Found:**
1. Warning summary uses non-formatting `eprintln()` instead of `eprintf()`
2. No memory cleanup after printing errors
3. Position formatting missing trailing space

---

### Functional Equivalence: 29% Complete

The Odin port captures the basic structure of error reporting but misses the sophisticated features that make compiler errors truly useful. The most critical omission is the **error block mechanism**, which is used 116 times across the C++ codebase to build multi-line error messages with suggestions.

---

### Recommendations

**Immediate Actions:**
1. Fix the warning summary printing bug (Priority 1.1)
2. Add error message cleanup (Priority 1.2)
3. Implement error block support (Priority 2.4)

**Next Steps:**
1. Add source line display with squiggles (Priority 2.5)
2. Implement error sorting and deduplication (Priority 2.6)
3. Add ANSI color support (Priority 3.7)

**Long-term Goals:**
1. Add JSON error output for IDE integration
2. Implement thread-safe error collection
3. Add full Unicode/grapheme support

---

### Design Patterns to Preserve

The C++ implementation uses several key design patterns:

1. **Buffered Error Building:** Errors are built incrementally before being committed
2. **Thread-Safe Collection:** Atomic counters and mutexes protect shared state
3. **Pluggable Output:** Function pointers allow swapping error output handlers
4. **Error Deduplication:** Merges errors at the same position to reduce noise
5. **Visual Context:** Shows source code with visual indicators of error location

The Odin port should preserve these patterns while adapting them to Odin's idioms (e.g., using slices instead of dynamic arrays where appropriate, using Odin's `defer` for RAII-style cleanup).

---

### References

All line numbers reference the C++ implementation at `/mnt/c/odin/src/error.cpp` unless otherwise noted.

Key function references:
- `error_va()`: lines 535-563
- `warning_va()`: lines 565-598
- `syntax_error_va()`: lines 637-667
- `show_error_on_line()`: lines 282-516
- `print_all_errors()`: lines 865-1033
- `ERROR_BLOCK()`: lines 214-225
- `terminal_set_colours()`: lines 254-274
- Error deduplication: lines 902-937
- JSON output: lines 942-1008

---

**Report Generated:** 2025-10-03
**Verification Tool:** Manual code analysis and cross-reference
**Methodology:** Line-by-line comparison with functional decomposition
