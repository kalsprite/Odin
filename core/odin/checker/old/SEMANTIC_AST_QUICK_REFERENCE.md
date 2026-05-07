# Semantic AST Quick Reference

## Quick Lookup: How to Access Semantic Data

This guide shows how to access semantic information after the refactoring from external maps to direct AST fields.

---

## 🔍 Finding Semantic Information

### Entity Access

**❌ Old way** (deleted):
```odin
entity := checker.info.ast_entity_map[rawptr(ident_node)]
```

**✅ New way**:
```odin
// Entity is stored directly on identifier nodes
entity := ident_node.entity  // ident_node is ^ast.Ident
```

---

### Type and Value Access

**❌ Old way** (deleted):
```odin
tav := checker.info.type_and_value_map[rawptr(node)]
// or
tav := ctx.type_and_value_map[rawptr(node)]
```

**✅ New way**:
```odin
// Type and value stored directly on nodes
tav := node.tav^  // node.tav is ^Type_And_Value
// Note: Dereference the pointer to get the value
```

---

### Scope Access

#### File Scope

**❌ Old way** (deleted):
```odin
file_scope := checker.info.scopes[file]
```

**✅ New way**:
```odin
// Scope stored directly on File
file_scope := file.scope  // file is ^ast.File
```

#### Statement/Type Scope

**❌ Old way** (deleted):
```odin
scope := checker.info.ast_scope_map[rawptr(node)]
```

**✅ New way**:
```odin
// Scopes stored directly on statement/type nodes

// Statements with scopes:
block_scope := block_stmt.scope          // ^ast.Block_Stmt
if_scope := if_stmt.scope                // ^ast.If_Stmt
for_scope := for_stmt.scope              // ^ast.For_Stmt
range_scope := range_stmt.scope          // ^ast.Range_Stmt
case_scope := case_clause.scope          // ^ast.Case_Clause
switch_scope := switch_stmt.scope        // ^ast.Switch_Stmt

// Types with scopes:
proc_scope := proc_type.scope            // ^ast.Proc_Type
struct_scope := struct_type.scope        // ^ast.Struct_Type
union_scope := union_type.scope          // ^ast.Union_Type
enum_scope := enum_type.scope            // ^ast.Enum_Type
bit_field_scope := bit_field_type.scope  // ^ast.Bit_Field_Type
```

---

### State Flags

**❌ Old way** (deleted):
```odin
flags := checker.info.ast_state_flags[rawptr(node)]
```

**✅ New way**:
```odin
// State flags stored directly on Node
flags := node.state_flags  // type: ast.Node_State_Flags

// Check specific flags:
if .Bounds_Check in node.state_flags { ... }
if .No_Bounds_Check in node.state_flags { ... }
if .Type_Assert in node.state_flags { ... }
if .Selector_Call_Expr in node.state_flags { ... }
```

---

### Viral State Flags

**❌ Old way** (deleted):
```odin
viral_flags := checker.info.ast_viral_flags[rawptr(node)]
```

**✅ New way**:
```odin
// Viral flags stored directly on Node
viral_flags := node.viral_state_flags  // type: ast.Node_Viral_State_Flags

// Check specific flags:
if .Contains_Deferred_Procedure in node.viral_state_flags { ... }
if .Contains_Or_Break in node.viral_state_flags { ... }
if .Contains_Or_Return in node.viral_state_flags { ... }
```

---

### When Statement Condition Memoization

**❌ Old way** (deleted):
```odin
is_determined := checker.info.when_cond_determined[when_stmt]
cond_value := checker.info.when_cond_value[when_stmt]
```

**✅ New way**:
```odin
// Condition result stored directly on When_Stmt
when_stmt: ^ast.When_Stmt = ...

if when_stmt.is_cond_determined {
    result := when_stmt.determined_cond
}
```

---

## 🗂️ File and Package Metadata (Still External)

These remain in external maps as checker-specific metadata:

### File Metadata

```odin
// These are still in Checker_Info:
flags := checker.info.file_flags[file]
vet_flags := checker.info.file_vet_flags[file]
feature_flags := checker.info.file_feature_flags[file]
vet_set := checker.info.file_vet_flags_set[file]
feature_set := checker.info.file_feature_flags_set[file]
```

### Package Metadata

```odin
// These are still in Checker_Info:
pkg_scope := checker.info.package_scopes[pkg]
decl_info := checker.info.package_decl_infos[pkg]
is_extra := checker.info.package_is_extra[pkg]
order := checker.info.package_order[pkg]
```

### Delayed Declaration Queues

```odin
// These are still in Checker_Info:
import_decls := checker.info.delayed_decls_import[file]
foreign_decls := checker.info.delayed_decls_foreign_block[file]
expr_decls := checker.info.delayed_decls_expr[file]
```

---

## 📝 Common Patterns

### Setting Entity on Identifier

```odin
ident: ^ast.Ident = ...
entity: ^Entity = ...

// Direct assignment to AST node
ident.entity = entity
```

### Setting Type and Value

```odin
node: ^ast.Node = ...
tav := Type_And_Value{
    type = some_type,
    mode = .Value,
    value = some_value,
}

// Allocate and assign
node.tav = new(Type_And_Value)
node.tav^ = tav
```

### Setting State Flags

```odin
node: ^ast.Node = ...

// Set flags directly on node
node.state_flags += {.Bounds_Check}
node.state_flags += {.Type_Assert}

// Check flags
if .Bounds_Check in node.state_flags {
    // Handle bounds checking...
}
```

### Setting Viral Flags

```odin
node: ^ast.Node = ...

// Set viral flags that propagate upward
node.viral_state_flags += {.Contains_Deferred_Procedure}

// Check viral flags
if .Contains_Or_Return in node.viral_state_flags {
    // Handle or_return propagation...
}
```

### Setting File Scope

```odin
file: ^ast.File = ...
file_scope: ^Scope = make_scope(...)

// Direct assignment to AST node
file.scope = file_scope
```

---

## 🚫 What NOT to Do

### ❌ Don't use rawptr casting for semantic data

```odin
// BAD - These maps don't exist anymore!
entity := checker.info.ast_entity_map[rawptr(node)]
tav := ctx.type_and_value_map[rawptr(node)]
scope := checker.info.ast_scope_map[rawptr(node)]
```

### ❌ Don't allocate external storage for semantic data

```odin
// BAD - Data should live on AST nodes, not in external maps
my_entity_map := make(map[^ast.Node]^Entity)  // Don't do this!
my_scope_map := make(map[rawptr]^Scope)       // Don't do this!
```

### ❌ Don't forget to dereference tav pointer

```odin
// BAD - node.tav is a pointer!
type := node.tav.type  // This doesn't work!

// GOOD
type := node.tav^.type  // Dereference first
```

---

## 🎯 Type Safety

The refactoring improved type safety:

**Before**: `map[rawptr]T` required casting, no compile-time checks

**After**: Direct field access with proper types

```odin
// Type-safe access to viral flags
viral_flags: ast.Node_Viral_State_Flags = node.viral_state_flags

// Type-safe flag operations
node.state_flags += {.Bounds_Check}  // Compiler knows these are valid flags

// Type-safe scope access
scope: ^Scope = block_stmt.scope  // No casting needed
```

---

## 📊 Performance Impact

**Before** (external map):
1. Compute hash of rawptr
2. Map lookup (with potential collision chain traversal)
3. Retrieve value

**After** (direct field):
1. Field access

**Result**: ~10-20x faster for hot-path semantic data access

---

## 🔗 Related Documentation

- **MAP_DELETION_PROGRESS.md** - Complete list of deleted maps
- **CPP_VS_ODIN_COMPARISON.md** - Comparison with C++ reference implementation
- **AST_CPP_PARITY_PROPOSAL.md** - Proposal for full C++ parity
- **SEMANTIC_AST_REFACTORING_COMPLETE.md** - Summary of refactoring

---

## ❓ FAQ

**Q: Why is `tav` a pointer on Node instead of by value?**

A: The C++ implementation uses by-value storage for performance (cache locality). This is a known optimization we haven't adopted yet. See AST_CPP_PARITY_PROPOSAL.md for details.

**Q: Why are file/package metadata maps still external?**

A: These represent checker-specific build configuration and working state, not universal semantic properties. See SEMANTIC_AST_REFACTORING_COMPLETE.md for the architectural rationale.

**Q: Can I add new external maps for semantic data?**

A: No. If the data is universal semantic information (entity, type, scope, flags), it should go on AST nodes. Only checker-specific tool metadata should use external maps.

**Q: How do I handle nil checks for semantic fields?**

A: Use standard nil checks:
```odin
if ident.entity != nil { ... }
if node.tav != nil { ... }
if file.scope != nil { ... }
```

**Q: What about thread safety?**

A: AST nodes with semantic fields can be accessed concurrently after initial population. For mutation during checking, use per-file or per-package mutexes (not global map mutexes).
