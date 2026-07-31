package test_checker

import "core:fmt"
import "core:odin/ast"
import "core:odin/parser"
import "core:odin/tokenizer"
import "core:testing"
import checker ".."

@(test)
test_debug_enum :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator

    // Parse enum - similar to failing test
    src := `package test

Color :: enum {
	Red,
	Green,
	Blue,
}

c := Color.Red
`
    file := new(ast.File)
    file.fullpath = "test.odin"
    file.src = src

    p := parser.default_parser()
    p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
    p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

    ok := parser.parse_file(&p, file)
    if !ok {
        testing.fail(t)
        return
    }
    fmt.println("DEBUG: Parsed file OK")

    // Serialize access to global error collector to avoid race conditions
    checker_globals_ticket := lock_checker_globals(t)
    defer unlock_checker_globals(checker_globals_ticket)

    // Initialize checker
    c := &checker.Checker{}
    checker.init_checker(c)
    defer checker.destroy_checker(c)
    fmt.println("DEBUG: Checker initialized")

    // Initialize error collector
    checker.init_error_collector(100)
    defer checker.destroy_error_collector()
    fmt.println("DEBUG: Error collector initialized")

    // Create package
    pkg := new(ast.Package)
    pkg.fullpath = "test_package"
    pkg.name = "test"
    pkg.files = make(map[string]^ast.File)
    pkg.files[file.fullpath] = file
    file.pkg = pkg
    fmt.println("DEBUG: Package created")

    // Run check_files
    fmt.println("DEBUG: About to call check_files")
    result := checker.check_files(c, {file})
    fmt.println("DEBUG: check_files returned:", result)

    // Print error count
    err_count := checker.error_count()
    warn_count := checker.warning_count()
    fmt.println("DEBUG: Error count:", err_count)
    fmt.println("DEBUG: Warning count:", warn_count)

    // Print any errors
    if err_count > 0 || warn_count > 0 {
        checker.print_all_errors()
    }
}

@(test)
test_debug_no_alias :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator

    // Parse #no_alias - test directive handling (simple)
    src := `package test
copy :: proc(dst: #no_alias ^int, src: ^int) {
}
`
    file := new(ast.File)
    file.fullpath = "test.odin"
    file.src = src

    p := parser.default_parser()
    p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
    p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

    ok := parser.parse_file(&p, file)
    if !ok {
        fmt.println("DEBUG: Parse failed")
        testing.fail(t)
        return
    }
    fmt.println("DEBUG: Parsed file OK")

    // Serialize access to global error collector to avoid race conditions
    checker_globals_ticket := lock_checker_globals(t)
    defer unlock_checker_globals(checker_globals_ticket)

    // Initialize checker
    c := &checker.Checker{}
    checker.init_checker(c)
    defer checker.destroy_checker(c)

    // Initialize error collector
    checker.init_error_collector(100)
    defer checker.destroy_error_collector()

    // Create package
    pkg := new(ast.Package)
    pkg.fullpath = "test_package"
    pkg.name = "test"
    pkg.files = make(map[string]^ast.File)
    pkg.files[file.fullpath] = file
    file.pkg = pkg

    // Run check_files
    result := checker.check_files(c, {file})
    fmt.println("DEBUG no_alias: check_files returned:", result)

    // Print error count
    err_count := checker.error_count()
    warn_count := checker.warning_count()
    fmt.println("DEBUG no_alias: Error count:", err_count)
    fmt.println("DEBUG no_alias: Warning count:", warn_count)

    // Print any errors
    if err_count > 0 || warn_count > 0 {
        error_values := checker.get_error_values()
        for ev in error_values {
            fmt.println("  Line", ev.pos.line, ":", string(ev.msg[:]))
        }
    }
}

@(test)
test_debug_variable :: proc(t: ^testing.T) {
    context.allocator = context.temp_allocator

    // Parse simple code
    src := `package test

x: int = 42
`
    file := new(ast.File)
    file.fullpath = "test.odin"
    file.src = src

    p := parser.default_parser()
    p.err = proc(pos: tokenizer.Pos, format: string, args: ..any) {}
    p.warn = proc(pos: tokenizer.Pos, format: string, args: ..any) {}

    ok := parser.parse_file(&p, file)
    if !ok {
        testing.fail(t)
        return
    }
    fmt.println("DEBUG: Parsed file OK")

    // Debug: Print declarations
    fmt.println("DEBUG: Decl count:", len(file.decls))
    for decl, i in file.decls {
        fmt.println("DEBUG: Decl", i, "derived:", decl.derived_stmt)
        if vd, is_vd := decl.derived_stmt.(^ast.Value_Decl); is_vd {
            fmt.println("DEBUG:   is_mutable:", vd.is_mutable)
            fmt.println("DEBUG:   values count:", len(vd.values))
            for val, j in vd.values {
                fmt.println("DEBUG:   Value", j, ":", val)
                if bl, is_bl := val.derived.(^ast.Basic_Lit); is_bl {
                    fmt.println("DEBUG:     Basic_Lit tok:", bl.tok.kind, "text:", bl.tok.text)
                }
            }
        }
    }

    // Serialize access to global error collector to avoid race conditions
    checker_globals_ticket := lock_checker_globals(t)
    defer unlock_checker_globals(checker_globals_ticket)

    // Initialize checker
    c := &checker.Checker{}
    checker.init_checker(c)
    defer checker.destroy_checker(c)
    fmt.println("DEBUG: Checker initialized")

    // Initialize error collector
    checker.init_error_collector(100)
    defer checker.destroy_error_collector()
    fmt.println("DEBUG: Error collector initialized")

    // Create package
    pkg := new(ast.Package)
    pkg.fullpath = "test_package"
    pkg.name = "test"
    pkg.files = make(map[string]^ast.File)
    pkg.files[file.fullpath] = file
    file.pkg = pkg
    fmt.println("DEBUG: Package created")

    // Run check_files
    result := checker.check_files(c, {file})
    fmt.println("DEBUG: check_files returned:", result)

    // Print error count
    err_count := checker.error_count()
    warn_count := checker.warning_count()
    fmt.println("DEBUG: Error count:", err_count)
    fmt.println("DEBUG: Warning count:", warn_count)

    // Print any errors
    if err_count > 0 || warn_count > 0 {
        checker.print_all_errors()
    }
}
