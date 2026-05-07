# Viral State Flags Infrastructure Implementation

**Date**: 2025-10-03
**C++ Reference**: /mnt/c/odin/src/check_stmt.cpp:64-150, parser.hpp:323-339
**Implementation Location**: /mnt/d/dev/checker

## Overview

Implemented infrastructure for tracking control flow state that "propagates" (goes viral) through statement sequences. This is Phase 19.1 infrastructure required for proper or_break, or_return, and deferred procedure call tracking.

## Core Definitions

### State Flags (Downward Propagation)

Added in `/mnt/d/dev/checker/checker.odin` lines 62-72:

```odin
// State_Flag tracks context-level flags that affect checking behavior
// These propagate downward from parent to child statements
// C++ Reference: StateFlag enum in /mnt/c/odin/src/parser.hpp:323-333
State_Flag :: enum u8 {
	Bounds_Check,      // Enable bounds checking
	No_Bounds_Check,   // Disable bounds checking (mutually exclusive with Bounds_Check)
	Type_Assert,       // Enable type assertions
	No_Type_Assert,    // Disable type assertions (mutually exclusive with Type_Assert)
}

State_Flags :: bit_set[State_Flag; u8]
```

### Viral State Flags (Upward Propagation)

Added in `/mnt/d/dev/checker/checker.odin` lines 74-83:

```odin
// Viral_State_Flag tracks properties that propagate upward through the AST
// These "go viral" from child to parent expressions during checking
// C++ Reference: ViralStateFlag enum in /mnt/c/odin/src/parser.hpp:335-339
Viral_State_Flag :: enum u8 {
	Contains_Deferred_Procedure, // Contains a call to a deferred procedure
	Contains_Or_Break,           // Contains an or_break expression
	Contains_Or_Return,          // Contains an or_return expression
}

Viral_State_Flags :: bit_set[Viral_State_Flag; u8]
```

## Checker_Context Update

Updated `state_flags` field type in `/mnt/d/dev/checker/checker.odin` line 1039:

```odin
// Before:
state_flags: u32,

// After:
state_flags: State_Flags,
```

## check_stmt Signature Update

Updated `/mnt/d/dev/checker/check_stmt.odin` lines 579-613:

```odin
check_stmt :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	prev_state_flags := ctx.state_flags
	defer ctx.state_flags = prev_state_flags

	// TODO(Phase 19.1): Handle state_flags from AST node when available
	// AST nodes will have a state_flags field set by #bounds_check, #no_bounds_check pragmas
	// C++ Reference: check_stmt.cpp lines 647-668
	//
	// When implemented:
	// if node.state_flags != {} {
	//     in := node.state_flags
	//     out := ctx.state_flags
	//
	//     // Mutually exclusive flags - last one wins
	//     if .No_Bounds_Check in in {
	//         out += {.No_Bounds_Check}
	//         out -= {.Bounds_Check}
	//     } else if .Bounds_Check in in {
	//         out += {.Bounds_Check}
	//         out -= {.No_Bounds_Check}
	//     }
	//
	//     if .No_Type_Assert in in {
	//         out += {.No_Type_Assert}
	//         out -= {.Type_Assert}
	//     } else if .Type_Assert in in {
	//         out += {.Type_Assert}
	//         out -= {.No_Type_Assert}
	//     }
	//
	//     ctx.state_flags = out
	// }

	return check_stmt_internal(ctx, node, flags)
}
```

**Key Change**: Now returns `Viral_State_Flags` instead of nothing.

## check_stmt_internal Signature Update

Updated `/mnt/d/dev/checker/check_stmt.odin` lines 618-704:

```odin
check_stmt_internal :: proc(ctx: ^Checker_Context, node: ^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	mod_flags := flags - {.Fallthrough_Allowed}
	viral_flags: Viral_State_Flags = {}

	#partial switch stmt in node.derived {
	case ^ast.Empty_Stmt:
	// No-op - no viral flags

	case ^ast.Bad_Stmt:
	// No-op - no viral flags

	case ^ast.Bad_Decl:
	// No-op - no viral flags

	case ^ast.Expr_Stmt:
		// Expression statements may contain or_break/or_return/deferred procedures
		viral_flags = check_expr_stmt(ctx, node)

	case ^ast.Assign_Stmt:
		// Assignments may contain or_break/or_return in RHS/LHS expressions
		viral_flags = check_assign_stmt(ctx, node)

	case ^ast.Block_Stmt:
		check_open_scope(ctx, node)
		defer check_close_scope(ctx)

		check_label(ctx, stmt.label, node)
		viral_flags = check_stmt_list(ctx, stmt.stmts, flags)

	case ^ast.If_Stmt:
		viral_flags = check_if_stmt(ctx, node, mod_flags)

	case ^ast.When_Stmt:
		viral_flags = check_when_stmt(ctx, node, flags)

	case ^ast.Return_Stmt:
		viral_flags = check_return_stmt(ctx, node)

	case ^ast.For_Stmt:
		viral_flags = check_for_stmt(ctx, node, mod_flags)

	case ^ast.Switch_Stmt:
		viral_flags = check_switch_stmt(ctx, node, mod_flags)

	case ^ast.Type_Switch_Stmt:
		viral_flags = check_type_switch_stmt(ctx, node, mod_flags)

	case ^ast.Defer_Stmt:
		viral_flags = check_defer_stmt(ctx, node)

	case ^ast.Branch_Stmt:
		viral_flags = check_branch_stmt(ctx, node, flags)

	case ^ast.Using_Stmt:
		viral_flags = check_using_stmt(ctx, node, flags)

	case ^ast.Foreign_Block_Decl:
		viral_flags = check_foreign_block_decl(ctx, node)

	// ... other cases
	}

	return viral_flags
}
```

**Key Change**: Now accumulates and returns viral flags from child statements.

## check_stmt_list Update Plan

**Location**: `/mnt/d/dev/checker/check_stmt.odin` line 464
**Required Update**: Must return `Viral_State_Flags` and accumulate from checked statements

```odin
// Target implementation (not yet applied due to concurrent modifications):
check_stmt_list :: proc(ctx: ^Checker_Context, stmts: []^ast.Stmt, flags: Stmt_Flag) -> Viral_State_Flags {
	viral_flags: Viral_State_Flags = {}

	if len(stmts) == 0 {
		return viral_flags
	}

	// ... existing logic for finding max, max_non_constant_declaration ...

	// Check each statement and accumulate viral flags
	for i in 0 ..< max {
		stmt := stmts[i]

		// ... existing skip empty logic ...

		// Check statement and accumulate its viral flags
		stmt_viral := check_stmt(ctx, stmt, new_flags)
		viral_flags |= stmt_viral  // Accumulate viral flags

		// ... existing unreachable code checking ...
	}

	return viral_flags
}
```

## Remaining Work

### 1. Update All check_*_stmt Procedures

All statement checking procedures must be updated to return `Viral_State_Flags`:

**Currently Requiring Updates**:
- `check_expr_stmt` - return flags from expression evaluation
- `check_assign_stmt` - accumulate from LHS/RHS expressions
- `check_if_stmt` - accumulate from condition, then/else branches
- `check_when_stmt` - accumulate from checked branch
- `check_return_stmt` - accumulate from return expressions
- `check_for_stmt` - accumulate from init/cond/post/body (with boundary handling)
- `check_switch_stmt` - accumulate from init, tag, case bodies
- `check_type_switch_stmt` - accumulate from tag, case bodies
- `check_defer_stmt` - flags from body (special: set Contains_Deferred_Procedure)
- `check_branch_stmt` - set Contains_Or_Break if break statement
- `check_using_stmt` - return empty flags
- `check_foreign_block_decl` - accumulate from body statements

### 2. Boundary Handling

Certain statements must CLEAR specific viral flags to prevent incorrect propagation:

```odin
// For/Range loops - clear Break/Continue at boundary:
case ^ast.For_Stmt:
	body_viral := check_stmt(ctx, stmt.body, mod_flags)
	// Break/Continue don't propagate past loop boundary
	// But Contains_Deferred_Procedure and Contains_Or_Return do
	body_viral -= {.Contains_Or_Break}  // Clear break flags
	viral_flags |= body_viral
	return viral_flags

// Switch statements - similar boundary handling
```

### 3. Expression Viral Flags

Expression checking must also track and return viral flags. This requires updates to:
- `check_expr_base` - return viral flags
- Binary/unary expression checkers - propagate from operands
- Call expression checker - set Contains_Deferred_Procedure for deferred calls
- or_break/or_return handlers - set appropriate flags

### 4. Integration with check_has_break_expr

Update `/mnt/d/dev/checker/check_stmt.odin` lines 228-236:

```odin
// Current stub:
check_has_break_expr :: proc(expr: ^ast.Expr, label: string) -> bool {
	// TODO(Phase 19.1): Check viral_state_flags when available
	return false
}

// Target implementation:
check_has_break_expr :: proc(expr: ^ast.Expr, label: string, viral_flags: Viral_State_Flags) -> bool {
	return .Contains_Or_Break in viral_flags
}
```

### 5. AST Node state_flags Field

Currently AST nodes don't have a `state_flags` field. When added to the AST package:

```odin
// Add to ast.Stmt and ast.Expr base structures:
state_flags: State_Flags,  // Set by #bounds_check, etc. pragmas
```

Then uncomment the TODO code in `check_stmt` (lines 583-610) to handle AST node state flags.

## Architecture Notes

### Two Independent Flag Systems

1. **State_Flags** (Downward):
   - Flow from parent to child statements
   - Set by compiler pragmas (#bounds_check, #no_bounds_check, etc.)
   - Affect how child statements are checked
   - Stored in both `ctx.state_flags` (context) and `node.state_flags` (AST annotation)

2. **Viral_State_Flags** (Upward):
   - Flow from child to parent during checking
   - Track properties like or_break, or_return, deferred procedures
   - Used for control flow analysis
   - Returned from checking functions, accumulated by parents

### Propagation Logic

```
Parent Statement
    |
    | (State_Flags flow down via ctx.state_flags)
    v
Child Statement (checks expressions)
    |
    | (Viral_State_Flags flow up via return values)
    v
Parent accumulates viral flags: parent_flags |= child_flags
```

### Boundary Handling Example

```odin
// Loop boundary - break doesn't escape:
for {
    x := y or_break  // Sets Contains_Or_Break
}
// Contains_Or_Break is CLEARED here (doesn't propagate past loop)

// But deferred procedures DO propagate:
for {
    defer proc() { }  // Sets Contains_Deferred_Procedure
}
// Contains_Deferred_Procedure propagates up
```

## Testing Considerations

1. **State Flag Propagation**: Test that #bounds_check pragmas affect nested statements
2. **Viral Flag Accumulation**: Test that or_break in nested blocks propagates correctly
3. **Boundary Conditions**: Test that break/continue don't escape loops
4. **Deferred Procedure Tracking**: Test Contains_Deferred_Procedure flag propagation
5. **Multiple Flags**: Test combinations of viral flags

## C++ Reference Patterns

```cpp
// C++ viral flags usage (simplified from check_stmt.cpp)
u32 check_stmt(CheckerContext *ctx, Ast *node, u32 flags) {
    u32 mod_flags = 0;

    switch (node->kind) {
    case Ast_BlockStmt:
        for (Ast *stmt : node->BlockStmt.stmts) {
            mod_flags |= check_stmt(ctx, stmt, flags);  // Accumulate
        }
        break;

    case Ast_BranchStmt:
        if (node->BranchStmt.token.kind == Token_break) {
            mod_flags |= StateFlag_break;  // Set break flag
        }
        break;

    // Boundaries
    case Ast_ForStmt:
        u32 body_flags = check_stmt(ctx, node->ForStmt.body, flags);
        body_flags &= ~(StateFlag_break | StateFlag_continue);  // Clear at boundary
        mod_flags |= body_flags;
        break;
    }

    return mod_flags;
}
```

## Status

**Completed**:
- State_Flag and State_Flags enum/typedef definitions
- Viral_State_Flag and Viral_State_Flags enum/typedef definitions
- Checker_Context.state_flags type updated
- check_stmt signature updated to return Viral_State_Flags
- check_stmt_internal signature updated with viral flag accumulation logic
- Documentation of state flag propagation logic (for AST integration)

**Pending**:
- check_stmt_list return value and accumulation logic (blocked by concurrent file modifications)
- All check_*_stmt procedures return value updates
- Boundary handling for loops/switches
- Expression viral flag tracking
- AST node state_flags field addition
- Integration with check_has_break_expr
- Full testing

**Blocked**:
- File `/mnt/d/dev/checker/check_stmt.odin` is being actively modified by another process (linter or user edits)
- Cannot complete remaining updates until file stabilizes

## Next Steps

1. Let file modifications settle
2. Update check_stmt_list to return and accumulate Viral_State_Flags
3. Update all check_*_stmt procedures in bulk
4. Add boundary handling for loops/switches
5. Integrate with expression checking (check_expr infrastructure)
6. Add comprehensive tests

## Implementation Estimate

- Core infrastructure (completed): 25 LOC
- check_stmt_list update: 5 LOC
- All check_*_stmt updates: 50 LOC
- Boundary handling: 20 LOC
- Expression integration: 30 LOC
- Testing: 50 LOC

**Total**: ~180 LOC for complete implementation
