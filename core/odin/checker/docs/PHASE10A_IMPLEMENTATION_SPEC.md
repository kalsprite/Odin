# Phase 10A Implementation Specification

## CRITICAL DIRECTIVE TO PORTER AGENT

This is a **PHASE 10A MVP ONLY** implementation. You are implementing:

**WHAT TO IMPLEMENT**:
- Basic non-polymorphic procedure call support
- Positional arguments ONLY
- Simple type checking and argument count validation
- Return type handling (0, 1, N returns)
- Basic calling convention validation

**WHAT TO STUB** (with clear TODO markers):
- Named arguments (Phase 10B)
- Default parameters (Phase 10B)
- Variadic arguments (Phase 10C)
- Polymorphic procedures (Phase 10D)
- Procedure groups/overloads (Phase 10E)
- Type constructor calls (Phase 10F)
- Built-in procedures (separate phase)
- Inlining directives (Phase 10G)

**ABSOLUTE REQUIREMENTS**:
1. ✅ NO half-implementations - features are either complete or stubbed
2. ✅ ALL stubs must have TODO comments with C++ reference line numbers
3. ✅ MUST compile cleanly with no warnings
4. ✅ Error messages must be clear and specific
5. ✅ Code must match the architecture in PHASE10_ANALYSIS.md

---

## Source Code References

### Primary Reference
- **File**: `/mnt/c/odin/src/check_expr.cpp`
- **Main function**: `check_call_expr` (lines 8155-8418)
- **Supporting functions**:
  - `check_call_arguments` (lines 7505-7615)
  - `check_call_arguments_internal` (lines 6249-6669)
  - `check_call_arguments_single` (lines 6859-6932)

### AST Definition
- **File**: `/mnt/c/odin/core/odin/ast/ast.odin`
- **Struct**: `Call_Expr` (lines 242-250)
  ```odin
  Call_Expr :: struct {
      using node: Expr,
      inlining: Proc_Inlining,
      expr:     ^Expr,
      open:     tokenizer.Pos,
      args:     []^Expr,
      ellipsis: tokenizer.Token,
      close:    tokenizer.Pos,
  }
  ```

---

## Implementation Tasks

### Task 1: Main Call Expression Handler (~80 LOC)

**File**: `/mnt/d/dev/checker/check_expr.odin`

Add this case to `check_expr_base`:

```odin
case ^ast.Call_Expr:
    // Call expression: f(x, y, z)
    // Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
    return check_call_expr(ctx, o, node, type_hint)
```

Implement `check_call_expr`:

```odin
// Reference: /mnt/c/odin/src/check_expr.cpp:8155-8418
check_call_expr :: proc(
    ctx: ^Checker_Context,
    o: ^Operand,
    node: ^ast.Node,
    type_hint: ^Type,
) -> Expr_Kind {
    call := node.derived.(^ast.Call_Expr)

    // Step 1: Check the callee expression (the thing being called)
    // Reference: lines 8189-8194
    check_expr_or_type(ctx, o, call.expr)

    // Step 2: Handle invalid operands early
    // Reference: lines 8196-8207
    if o.mode == .Invalid {
        // Check arguments anyway to find more errors
        for arg in call.args {
            arg_op: Operand
            check_expr_base(ctx, &arg_op, arg, nil)
        }
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Step 3: Handle type constructor calls (STUB)
    // Reference: lines 8209-8211
    if o.mode == .Type {
        // TODO(Phase 10F): Type constructor calls
        // Reference: /mnt/c/odin/src/check_expr.cpp:8054-8154
        error(ctx, call.expr, "Type constructor calls not yet supported")
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Step 4: Handle built-in procedures (STUB)
    // Reference: lines 8213-8227
    if o.mode == .Builtin {
        // TODO(Phase 11?): Built-in procedure calls
        // Reference: /mnt/c/odin/src/check_builtin.cpp
        error(ctx, call.expr, "Built-in procedures not yet implemented")
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Step 5: Handle procedure groups (STUB)
    // Reference: lines 8229-8268
    if o.mode == .Proc_Group {
        // TODO(Phase 10E): Procedure group overload resolution
        // Reference: /mnt/c/odin/src/check_expr.cpp:6933-7504
        error(ctx, call.expr, "Procedure groups not yet supported")
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Step 6: Validate it's actually a procedure type
    // Reference: lines 8251-8268
    proc_type := base_type(o.type)
    if proc_type == nil || proc_type.kind != .Proc {
        // Error: trying to call something that's not a procedure
        error(ctx, call.expr, "Cannot call a non-procedure: '%v' of type '%v'",
              expr_to_string(call.expr), type_to_string(o.type))
        o.mode = .Invalid
        o.expr = node
        return .Stmt
    }

    // Step 7: Check the call arguments
    // Reference: lines 8270-8279
    arg_data := check_call_arguments_basic(ctx, o, call)

    if arg_data.error {
        o.mode = .Invalid
        o.type = t_invalid
        o.expr = node
        return .Stmt
    }

    // Step 8: Check calling convention requirements
    // Reference: lines 8295-8305
    pt := &proc_type.variant.(Type_Proc)
    if pt.calling_convention == .Odin {
        // Odin calling convention requires context to be defined
        if .Context_Defined not_in ctx.scope.flags {
            error(ctx, node, "Procedures requiring 'context' cannot be called in this scope")
            o.mode = .Invalid
            o.expr = node
            return .Stmt
        }
    }

    // Step 9: Set result type based on procedure return type
    // Reference: lines 8307-8325
    set_call_result_type(o, arg_data.result_type, node)

    // TODO(Phase 10G): Inlining directive validation
    // Reference: lines 8327-8374
    if call.inlining != .none {
        // For now, just ignore inlining directives
        // Future: validate compatibility
    }

    return .Expr
}
```

**Porter Instructions**:
1. Port the structure above exactly
2. Use existing helper functions (check_expr_or_type, error, etc.)
3. Keep all TODO comments with line references
4. Ensure all error messages are informative

---

### Task 2: Argument Checking (~180 LOC)

Implement the core argument validation logic:

```odin
// Data structure for call argument processing
Call_Argument_Data :: struct {
    result_type: ^Type,  // Procedure's return type
    score:       int,    // For future overload resolution
    error:       bool,   // True if any errors occurred
}

// Reference: /mnt/c/odin/src/check_expr.cpp:7505-7615 (simplified)
check_call_arguments_basic :: proc(
    ctx: ^Checker_Context,
    callee: ^Operand,
    call: ^ast.Call_Expr,
) -> Call_Argument_Data {
    data: Call_Argument_Data
    data.error = false

    proc_type := base_type(callee.type)
    assert(proc_type.kind == .Proc, "check_call_arguments_basic expects procedure type")

    pt := &proc_type.variant.(Type_Proc)

    // Check 1: Polymorphic procedures not supported (STUB)
    // Reference: lines 369-658
    if pt.is_polymorphic {
        // TODO(Phase 10D): Polymorphic procedure instantiation
        // Reference: /mnt/c/odin/src/check_expr.cpp:369-658
        error(ctx, call.expr, "Polymorphic procedures not yet supported")
        data.error = true
        data.result_type = pt.results  // Set anyway for consistency
        return data
    }

    // Check 2: Variadic procedures not supported (STUB)
    // Reference: lines 6369-6413
    if pt.variadic {
        // TODO(Phase 10C): Variadic argument handling
        // Reference: /mnt/c/odin/src/check_expr.cpp:6369-6413
        error(ctx, call.expr, "Variadic procedures not yet supported")
        data.error = true
        data.result_type = pt.results
        return data
    }

    // Check 3: Variadic expansion not supported (STUB)
    // Reference: lines 6274-6288
    if call.ellipsis.kind != .Invalid {
        // TODO(Phase 10C): Variadic expansion (..) support
        // Reference: /mnt/c/odin/src/check_expr.cpp:6274-6288
        error(ctx, call, "Variadic expansion '..' not yet supported")
        data.error = true
        data.result_type = pt.results
        return data
    }

    // Check 4: Named arguments not supported (STUB)
    // Reference: lines 6325-6364, 7569-7601
    for arg in call.args {
        if _, is_field := arg.derived.(^ast.Field_Value); is_field {
            // TODO(Phase 10B): Named argument support
            // Reference: /mnt/c/odin/src/check_expr.cpp:6325-6364
            error(ctx, arg, "Named arguments not yet supported")
            data.error = true
            data.result_type = pt.results
            return data
        }
    }

    // Now we can proceed with basic positional argument checking

    // Get parameter count
    param_count := len(pt.params.variables)
    arg_count := len(call.args)

    // Check 5: Argument count validation
    // Reference: lines 6304-6314
    if arg_count > param_count {
        error(ctx, call, "Too many arguments for this procedure: expected %d, got %d",
              param_count, arg_count)
        data.error = true
        data.result_type = pt.results
        return data
    }

    // Check 6: Too few arguments (considering default parameters)
    // Reference: lines 6415-6464
    if arg_count < param_count {
        // TODO(Phase 10B): Check for default parameter values
        // Reference: /mnt/c/odin/src/check_expr.cpp:6415-6464
        // For now, we require all parameters to be provided
        error(ctx, call, "Too few arguments for this procedure: expected %d, got %d",
              param_count, arg_count)
        data.error = true
        data.result_type = pt.results
        return data
    }

    // Check 7: Type check each positional argument
    // Reference: lines 6316-6319, 6480-6850 (simplified)
    for arg, i in call.args {
        param := pt.params.variables[i]
        param_type := param.type

        // Check the argument expression
        arg_op: Operand
        check_expr_with_type_hint(ctx, &arg_op, arg, param_type)

        if arg_op.mode == .Invalid {
            data.error = true
            continue
        }

        // Validate type compatibility
        // Reference: check_call_arguments_internal lines 6480+
        if !check_is_assignable_to(ctx, &arg_op, param_type) {
            error(ctx, arg,
                  "Cannot pass argument of type '%v' to parameter '%v' of type '%v'",
                  type_to_string(arg_op.type),
                  param.token.text,
                  type_to_string(param_type))
            data.error = true
        }
    }

    // Set result type
    data.result_type = pt.results

    return data
}
```

**Porter Instructions**:
1. Implement exactly as specified above
2. Ensure all TODOs are present with line references
3. Use existing check_expr_with_type_hint and check_is_assignable_to
4. Error messages must include helpful context

---

### Task 3: Result Type Handling (~30 LOC)

```odin
// Reference: /mnt/c/odin/src/check_expr.cpp:8307-8325
set_call_result_type :: proc(o: ^Operand, result_type: ^Type, call_node: ^ast.Node) {
    o.expr = call_node

    if result_type == nil {
        // Procedure returns nothing
        o.mode = .No_Value
        o.type = nil
        return
    }

    // Result type should always be a tuple
    if result_type.kind != .Tuple {
        // Defensive: shouldn't happen with valid procedure types
        o.mode = .Invalid
        o.type = t_invalid
        return
    }

    tuple := &result_type.variant.(Type_Tuple)

    switch len(tuple.variables) {
    case 0:
        // No return values
        o.mode = .No_Value
        o.type = nil

    case 1:
        // Single return value - unwrap from tuple
        o.mode = .Value
        o.type = tuple.variables[0].type

    case:
        // Multiple return values - keep as tuple
        o.mode = .Value
        o.type = result_type
    }
}
```

**Porter Instructions**:
1. Port exactly as shown
2. This is straightforward - no stubs needed
3. Keep defensive checks

---

### Task 4: Type System Checks

Verify these types exist in `/mnt/d/dev/checker/types.odin`:

1. **Calling_Convention enum**:
   ```odin
   Calling_Convention :: enum {
       Invalid,
       Odin,      // Default, requires context
       Contextless,
       C,
       Std_Call,
       Fast_Call,
       Win64,
       Sys_V,
   }
   ```

2. **Proc_Inlining enum** (should already exist in AST):
   ```odin
   Proc_Inlining :: enum {
       none,
       inline,
       no_inline,
   }
   ```

3. **Scope_Flag for context** in `/mnt/d/dev/checker/scope.odin`:
   ```odin
   Scope_Flag :: enum {
       // ... existing flags ...
       Context_Defined,  // Set when context is available
   }
   ```

**Porter Instructions**:
1. Check if these exist
2. Add only if missing
3. If unsure about placement, add to appropriate files with comments

---

### Task 5: Integration Checklist

Before considering the task complete:

1. ✅ Add `case ^ast.Call_Expr:` to `check_expr_base` switch
2. ✅ Implement `check_call_expr` (~80 LOC)
3. ✅ Implement `check_call_arguments_basic` (~180 LOC)
4. ✅ Implement `set_call_result_type` (~30 LOC)
5. ✅ Define `Call_Argument_Data` struct
6. ✅ Verify/add necessary type enums
7. ✅ All TODOs have C++ line references
8. ✅ Compile check: `cd /mnt/d/dev/checker && odin check . -file`
9. ✅ No warnings
10. ✅ Error messages are clear

---

## Quality Control Requirements

### Code Quality
- [ ] Every stub has a TODO comment with C++ reference
- [ ] Error messages are specific and helpful
- [ ] No placeholder implementations
- [ ] No commented-out code
- [ ] Proper Odin formatting

### Completeness
- [ ] All 8 stub points are documented
- [ ] Basic call path is fully implemented
- [ ] Type checking uses existing infrastructure
- [ ] Return type handling covers all cases (0, 1, N)

### Compilation
- [ ] Code compiles with `odin check . -file`
- [ ] No compiler warnings
- [ ] No undefined symbols
- [ ] No type errors

---

## Expected Test Behavior

After implementation, these should be the results:

```odin
// Should work:
add :: proc(a, b: int) -> int { return a + b }
x := add(1, 2)  // ✅ OK

// Should error:
y := add(1, 2, 3)  // ❌ ERROR: Too many arguments
z := add(1)        // ❌ ERROR: Too few arguments
w := add(1, "hi")  // ❌ ERROR: Type mismatch

// Should error with "not yet supported":
print :: proc(args: ..any) { }
print(1, 2, 3)     // ❌ ERROR: Variadic not supported

identity :: proc($T: typeid, x: T) -> T { return x }
n := identity(int, 5)  // ❌ ERROR: Polymorphic not supported

result := add(a=1, b=2)  // ❌ ERROR: Named arguments not supported
```

---

## Final Deliverable

Provide:
1. Modified `/mnt/d/dev/checker/check_expr.odin` with call expression support
2. Any additions to `/mnt/d/dev/checker/types.odin` or `/mnt/d/dev/checker/scope.odin`
3. Compilation verification output
4. List of all stub points (should be 8)

---

## Porter Agent Final Checklist

Before submitting your implementation:

- [ ] Read PHASE10_ANALYSIS.md completely
- [ ] Implement ONLY Phase 10A features
- [ ] ALL advanced features are stubbed with TODOs
- [ ] Code compiles cleanly
- [ ] No shortcuts or half-implementations
- [ ] Error messages are clear and helpful
- [ ] All C++ references are accurate
- [ ] You can defend every design decision
- [ ] Zero technical debt introduced

**Remember**: Quality over speed. A perfect Phase 10A MVP is better than a buggy full implementation.

---

**Implementation Overseer Approval Required**: This specification has been reviewed and approved for implementation.

**End of Specification**
