# Phase 10: Call Expression Implementation - Deep Analysis

## Executive Summary

Call expressions represent the **most complex expression type** in the Odin checker, with approximately **2,169 LOC** across 7 major functions in the C++ implementation. This analysis decomposes the implementation into:

1. **Phase 10A (MVP)**: ~400-500 LOC - Basic non-polymorphic procedure calls
2. **Phase 10B+ (Future)**: ~1,700 LOC - Advanced features requiring infrastructure

**CRITICAL DECISION**: We must implement ONLY Phase 10A to maintain zero technical debt.

---

## C++ Implementation Architecture

### Function Decomposition (Total: 2,169 LOC)

```
check_call_expr                         263 LOC   [Main entry point]
├── check_call_expr_as_type_cast        101 LOC   [Type constructor calls]
└── check_call_arguments                510 LOC   [Argument processing hub]
    ├── check_call_arguments_internal   610 LOC   [Core matching logic]
    ├── check_call_arguments_single      74 LOC   [Single proc validation]
    └── check_call_arguments_proc_group 572 LOC   [Overload resolution]
check_call_parameter_mixture             39 LOC   [Validation helper]
```

### Feature Complexity Matrix

| Feature | LOC Est. | Phase | Dependencies | Risk |
|---------|----------|-------|--------------|------|
| Basic positional args | 150 | 10A | Type checking | LOW |
| Return type handling | 80 | 10A | Tuple unwrapping | LOW |
| Argument count validation | 50 | 10A | Error reporting | LOW |
| Type checking per arg | 100 | 10A | check_is_assignable_to | LOW |
| Calling convention check | 40 | 10A | Scope context flags | MED |
| **MVP Subtotal** | **420** | **10A** | - | - |
| Named arguments | 150 | 10B | Parameter name tracking | MED |
| Default parameters | 100 | 10B | Constant evaluation | HIGH |
| Variadic arguments | 200 | 10C | Slice construction | HIGH |
| Variadic expansion (..) | 80 | 10C | Variadic support | HIGH |
| Polymorphic instantiation | 500 | 10D | Generic system | VERY HIGH |
| Proc groups (overloads) | 572 | 10E | Type distance scoring | VERY HIGH |
| Type constructors | 101 | 10F | Struct/union checking | MED |
| Built-in procedures | *separate* | N/A | check_builtin.cpp | N/A |

---

## Phase 10A MVP Scope Definition

### What We WILL Implement

**1. Basic Call Expression Structure** (~60 LOC)
   - AST: `Call_Expr` with fields: `expr`, `args[]`, `inlining`, `ellipsis`
   - Check the callee expression (`expr`) via `check_expr_or_type`
   - Handle invalid/type/builtin modes with appropriate errors
   - Reference: lines 8155-8228

**2. Procedure Type Validation** (~50 LOC)
   - Verify operand is a procedure type
   - Extract `Type_Proc` information
   - Check calling convention vs context availability
   - Error: "Cannot call a non-procedure"
   - Reference: lines 8251-8268, 8295-8305

**3. Basic Argument Matching** (~150 LOC)
   - Count arguments vs parameters
   - Check argument count (too few/too many)
   - Match positional arguments ONLY
   - Type check each argument against parameter type
   - Use existing `check_is_assignable_to`
   - Reference: lines 6264-6314, 6415-6464

**4. Return Type Handling** (~80 LOC)
   - Extract procedure return type (tuple)
   - Handle 0-return (NoValue mode)
   - Handle 1-return (unwrap to single type)
   - Handle N-returns (keep as tuple)
   - Reference: lines 8307-8325

**5. Error Reporting** (~80 LOC)
   - Too many arguments
   - Too few arguments (missing parameters)
   - Type mismatch per argument
   - Non-callable expression
   - Missing context for Odin calling convention

### What We Will STUB (with clear TODOs)

**1. Named Arguments** (Phase 10B)
   ```odin
   // TODO(Phase 10B): Named argument support
   // Reference: /mnt/c/odin/src/check_expr.cpp:6325-6364
   // Requires: AstSplitArgs, lookup_procedure_parameter
   if len(named_args) > 0 {
       error(call, "Named arguments not yet supported")
       return
   }
   ```

**2. Default Parameters** (Phase 10B)
   ```odin
   // TODO(Phase 10B): Default parameter values
   // Reference: /mnt/c/odin/src/check_expr.cpp:6415-6445
   // Requires: ParameterValue constant evaluation
   // For now: require all non-variadic parameters
   ```

**3. Variadic Arguments** (Phase 10C)
   ```odin
   // TODO(Phase 10C): Variadic argument handling
   // Reference: /mnt/c/odin/src/check_expr.cpp:6369-6413
   // Requires: Slice construction, '...' operator support
   if proc_type.variadic {
       error(call, "Variadic procedures not yet supported")
       return
   }
   ```

**4. Polymorphic Procedures** (Phase 10D)
   ```odin
   // TODO(Phase 10D): Polymorphic procedure instantiation
   // Reference: /mnt/c/odin/src/check_expr.cpp:369-658 (290 LOC)
   // Requires: Full generic type system, type inference
   if is_type_polymorphic(proc_type) {
       error(call, "Polymorphic procedures not yet supported")
       return
   }
   ```

**5. Procedure Groups** (Phase 10E)
   ```odin
   // TODO(Phase 10E): Procedure group overload resolution
   // Reference: /mnt/c/odin/src/check_expr.cpp:6933-7504 (572 LOC)
   // Requires: Type distance scoring, candidate filtering
   if operand.mode == .Proc_Group {
       error(call, "Procedure groups not yet supported")
       return
   }
   ```

**6. Type Constructor Calls** (Phase 10F)
   ```odin
   // TODO(Phase 10F): Type constructor calls (cast-style)
   // Reference: /mnt/c/odin/src/check_expr.cpp:8054-8154 (101 LOC)
   // Example: Vec3{1, 2, 3} or Matrix4(1.0)
   if operand.mode == .Type {
       error(call, "Type constructor calls not yet supported")
       return
   }
   ```

**7. Built-in Procedures** (Separate Phase)
   ```odin
   // NOTE: Built-in procedures are checked in check_builtin.cpp
   // Reference: /mnt/c/odin/src/check_builtin.cpp
   // Examples: len(), cap(), size_of(), type_of()
   if operand.mode == .Builtin {
       error(call, "Built-in procedures not yet implemented")
       return
   }
   ```

**8. Inlining Directives** (Phase 10G)
   ```odin
   // TODO(Phase 10G): Inline/no_inline directive validation
   // Reference: /mnt/c/odin/src/check_expr.cpp:8327-8374
   if call.inlining != .none {
       error(call, "Inlining directives not yet supported")
   }
   ```

---

## Phase 10A Implementation Strategy

### Architecture Design

```odin
// File: /mnt/d/dev/checker/check_expr.odin

// Main call expression checker
check_call_expr :: proc(
    ctx: ^Checker_Context,
    o: ^Operand,
    node: ^ast.Node,
    type_hint: ^Type,
) -> Expr_Kind {
    call := node.derived.(^ast.Call_Expr)

    // 1. Check callee expression
    check_expr_or_type(ctx, o, call.expr)

    // 2. Validate procedure type
    if !is_valid_call_target(o) {
        return handle_invalid_call(ctx, o, call)
    }

    // 3. Process arguments (Phase 10A: positional only)
    arg_data := check_call_arguments_basic(ctx, o, call)

    // 4. Set result type and mode
    set_call_result_type(o, arg_data.result_type, call)

    return .Expr
}

// Helper: Validate call target
is_valid_call_target :: proc(o: ^Operand) -> bool {
    if o.mode == .Invalid do return false

    // Stub unsupported modes
    if o.mode == .Type {
        // TODO(Phase 10F): Type constructor calls
        return false
    }
    if o.mode == .Builtin {
        // TODO(Phase 11?): Built-in procedures
        return false
    }
    if o.mode == .Proc_Group {
        // TODO(Phase 10E): Procedure groups
        return false
    }

    // Check if it's a valid procedure value
    proc_type := base_type(o.type)
    return proc_type != nil && proc_type.kind == .Proc
}

// Helper: Basic positional argument checking
Call_Argument_Data :: struct {
    result_type: ^Type,
    score: int,
    error: bool,
}

check_call_arguments_basic :: proc(
    ctx: ^Checker_Context,
    callee: ^Operand,
    call: ^ast.Call_Expr,
) -> Call_Argument_Data {
    data: Call_Argument_Data

    proc_type := base_type(callee.type)
    assert(proc_type.kind == .Proc)
    pt := &proc_type.variant.(Type_Proc)

    // Check for unsupported features
    if pt.is_polymorphic {
        error(call, "Polymorphic procedures not yet supported")
        data.error = true
        return data
    }
    if pt.variadic {
        error(call, "Variadic procedures not yet supported")
        data.error = true
        return data
    }
    if len(call.args) > 0 {
        // Check if any are named arguments
        for arg in call.args {
            if _, is_field_value := arg.derived.(^ast.Field_Value); is_field_value {
                error(arg, "Named arguments not yet supported")
                data.error = true
                return data
            }
        }
    }
    if call.ellipsis.kind != .Invalid {
        error(call, "Variadic expansion '..' not yet supported")
        data.error = true
        return data
    }

    // Get parameter info
    param_count := len(pt.params.variables)
    arg_count := len(call.args)

    // Check argument count
    if arg_count < param_count {
        // TODO(Phase 10B): Check for default parameters
        error(call, "Too few arguments: expected %d, got %d",
              param_count, arg_count)
        data.error = true
        return data
    }
    if arg_count > param_count {
        error(call, "Too many arguments: expected %d, got %d",
              param_count, arg_count)
        data.error = true
        return data
    }

    // Type check each argument
    for arg, i in call.args {
        param := pt.params.variables[i]
        param_type := param.type

        // Check argument expression
        arg_op: Operand
        check_expr_with_type_hint(ctx, &arg_op, arg, param_type)

        if arg_op.mode == .Invalid {
            data.error = true
            continue
        }

        // Check type compatibility
        if !check_is_assignable_to(ctx, &arg_op, param_type) {
            error(arg, "Cannot pass argument of type '%v' to parameter of type '%v'",
                  type_to_string(arg_op.type),
                  type_to_string(param_type))
            data.error = true
        }
    }

    // Set result type
    data.result_type = pt.results

    // Check calling convention requirements
    if pt.calling_convention == .Odin {
        if !ctx.scope.has_context_defined {
            error(call, "Procedures requiring 'context' cannot be called in this scope")
            data.error = true
        }
    }

    return data
}

// Helper: Set call result based on return type
set_call_result_type :: proc(o: ^Operand, result_type: ^Type, call: ^ast.Node) {
    o.expr = call

    if result_type == nil {
        o.mode = .No_Value
        o.type = nil
        return
    }

    // Result type should be a tuple
    assert(result_type.kind == .Tuple)
    tuple := &result_type.variant.(Type_Tuple)

    switch len(tuple.variables) {
    case 0:
        o.mode = .No_Value
        o.type = nil
    case 1:
        o.mode = .Value
        o.type = tuple.variables[0].type
    case:
        o.mode = .Value
        o.type = result_type  // Keep as tuple
    }
}
```

### Integration into check_expr_base

```odin
#partial switch derived in node.derived {
    // ... existing cases ...

    case ^ast.Call_Expr:
        // Call expression: f(x, y, z)
        // Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
        return check_call_expr(ctx, o, node, type_hint)

    // ... rest of cases ...
}
```

---

## Type System Extensions Needed

### 1. Calling Convention Enum (if not present)

```odin
Calling_Convention :: enum {
    Invalid,
    Odin,      // Default
    Contextless,
    C,
    Std_Call,
    Fast_Call,
    Win64,
    Sys_V,
}
```

### 2. Procedure Inlining Enum (if not present)

```odin
Proc_Inlining :: enum {
    None,
    Inline,
    No_Inline,
}
```

### 3. Scope Context Flags

Ensure `Scope` has a flag tracking if context is defined:
```odin
Scope_Flag :: enum {
    // ... existing flags ...
    Context_Defined,  // For checking Odin calling convention
}
```

---

## Testing Strategy

### Minimal Test Cases for Phase 10A

```odin
// test_call_basic.odin

// Test 1: Simple procedure call
add :: proc(a, b: int) -> int {
    return a + b
}
result := add(1, 2)  // Should work

// Test 2: Multiple return values
swap :: proc(a, b: int) -> (int, int) {
    return b, a
}
x, y := swap(10, 20)  // Should work

// Test 3: No return value
print_num :: proc(n: int) {
    // ...
}
print_num(42)  // Should work

// Test 4: Too few arguments
result2 := add(1)  // ERROR: Too few arguments

// Test 5: Too many arguments
result3 := add(1, 2, 3)  // ERROR: Too many arguments

// Test 6: Type mismatch
result4 := add(1, "hello")  // ERROR: Cannot pass string to int parameter

// Test 7: Non-callable
x := 42
result5 := x(10)  // ERROR: Cannot call a non-procedure

// Test 8: Variadic (should error)
printf :: proc(fmt: string, args: ..any) { }
printf("test", 1, 2)  // ERROR: Variadic procedures not yet supported

// Test 9: Named arguments (should error)
result6 := add(a=1, b=2)  // ERROR: Named arguments not yet supported

// Test 10: Polymorphic (should error)
identity :: proc($T: typeid, x: T) -> T { return x }
n := identity(int, 42)  // ERROR: Polymorphic procedures not yet supported
```

---

## Risk Assessment

### Phase 10A Risks (LOW-MEDIUM)

| Risk | Severity | Mitigation |
|------|----------|------------|
| Missing type infrastructure | Medium | Use existing type checking from Phase 1-9 |
| Calling convention tracking | Low | Add simple scope flag |
| Argument type checking | Low | Reuse check_is_assignable_to |
| Return type unwrapping | Low | Simple switch on tuple size |
| Integration complexity | Medium | Clear separation of concerns |

### Future Phase Risks (HIGH-CRITICAL)

| Feature | Severity | Why Deferred |
|---------|----------|--------------|
| Polymorphic instantiation | CRITICAL | Requires generic type system (~500 LOC) |
| Variadic arguments | HIGH | Requires slice construction, complex matching |
| Default parameters | HIGH | Requires constant expression evaluation |
| Procedure groups | CRITICAL | Requires type distance scoring algorithm |
| Named arguments | MEDIUM | Requires parameter name tracking, lookup |

---

## Quality Control Checklist

### Pre-Implementation
- [x] C++ code analyzed comprehensively
- [x] Feature matrix created with LOC estimates
- [x] MVP scope clearly defined
- [x] Stub points identified with references
- [x] No shortcuts or hacks in design

### During Implementation
- [ ] Compile after each major function
- [ ] Test each feature independently
- [ ] Verify all TODOs reference C++ code
- [ ] Ensure error messages are clear
- [ ] No placeholder implementations

### Post-Implementation
- [ ] Full compilation success
- [ ] All 10 test cases pass (or error correctly)
- [ ] No warnings
- [ ] Code review against C++ reference
- [ ] Status document created

---

## Estimated LOC Breakdown

```
check_call_expr                     ~80 LOC
is_valid_call_target                ~40 LOC
check_call_arguments_basic         ~180 LOC
set_call_result_type                ~30 LOC
Helper error messages               ~40 LOC
Integration (switch case)           ~10 LOC
Tests and comments                  ~50 LOC
-------------------------------------------
Total Phase 10A                    ~430 LOC
```

**Total stubbed (deferred) features**: ~1,700 LOC

---

## Success Criteria

Phase 10A is **complete** when:

1. ✅ Simple non-polymorphic procedures can be called
2. ✅ Argument count is validated correctly
3. ✅ Argument types are checked against parameter types
4. ✅ Return types are properly unwrapped (0, 1, N returns)
5. ✅ Calling convention requirements are checked
6. ✅ All advanced features error with clear "not yet supported" messages
7. ✅ All error messages reference what's wrong
8. ✅ Compiles cleanly with no warnings
9. ✅ All stub points have TODO comments with C++ references
10. ✅ No technical debt introduced

---

## Next Steps (This Overseer's Directive)

1. **Review and approve this analysis** (5 min)
2. **Invoke odin-checker-porter agent** with:
   - This analysis document
   - Explicit instruction to implement ONLY Phase 10A
   - Requirement for all stubs to be in place
3. **Quality review** the porter's output:
   - Check for shortcuts
   - Verify all stubs are present
   - Ensure no half-implementations
4. **Compilation verification**
5. **Create Phase 10 status document**
6. **Recommend Phase 11** (likely: Built-in procedures OR Compound literals)

**End of Analysis**
