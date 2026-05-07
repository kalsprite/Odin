# C++ Odin Compiler Bugs and Discrepancies

This document tracks bugs and inconsistencies found in the C++ Odin compiler implementation at `/src/` during development of a native Odin Checker.

---

## 🟡 MODERATE: Switch Statement Init Check Bug

**Location**: `/src/check_stmt.cpp:226`

**Bug Description**:
The code uses `check_has_break_expr()` (for expressions) instead of `check_has_break()` (for statements) when checking the `init` field of a switch statement.

**Current**:
```cpp
case Ast_SwitchStmt:
    if (stmt->SwitchStmt.init && check_has_break_expr(stmt->SwitchStmt.init, label)) {
        return true;
    }
```

**Should Be**:
```cpp
case Ast_SwitchStmt:
    if (stmt->SwitchStmt.init && check_has_break(stmt->SwitchStmt.init, label, implicit)) {
        return true;
    }
```

**Why It's Wrong**:
The same file shows the correct pattern for other statement types:

**IfStmt (line 209)** - ✓ Correct:
```cpp
if (stmt->IfStmt.init && check_has_break(stmt->IfStmt.init, label, implicit)) {
    // 
if (stmt->IfStmt.cond && check_has_break_expr(stmt->IfStmt.cond, label)) {
    // 
```

**ForStmt (line 241, 244, 247)** - ✓ Correct:
```cpp
if (stmt->ForStmt.init && check_has_break(stmt->ForStmt.init, label, implicit)) {
    // init is a statement
if (stmt->ForStmt.cond && check_has_break_expr(stmt->ForStmt.cond, label)) {
    // cond is an expression
if (stmt->ForStmt.post && check_has_break(stmt->ForStmt.post, label, implicit)) {
    // post is a statement
```

The pattern is clear: `init` fields are statements and should use `check_has_break()`, while `cond` fields are expressions and should use `check_has_break_expr()`.

**Impact**:
May fail to detect invalid `break` statements in switch initialization. The `check_has_break_expr()` function expects an expression AST node, but receives a statement node, which could:
- Fail to properly traverse the statement tree
- Miss detecting break statements that should be flagged as errors
- Allow invalid code through the checker

---
