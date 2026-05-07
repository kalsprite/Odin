# Odin Language Specification (Derived from C++ Implementation)

This specification was mechanistically extracted from the C++ compiler source
(`src/`) to serve as a reference for the Odin checker implementation.

## Extraction Statistics

| Category | Count | Source File(s) |
|----------|-------|----------------|
| Error messages | ~1,100 | check_*.cpp, checker.cpp |
| Built-in procedures | 278 | checker_builtin_procs.hpp |
| Type categories | 25+ | types.cpp |
| Operators | 30+ | check_expr.cpp |
| Hash directives | 35+ | check_expr.cpp, check_type.cpp |
| Attributes | 50+ | checker.cpp |
| Parameter flags | 8 | check_type.cpp |
| Keywords | 40 | tokenizer.cpp |
| Control flow forms | 15+ | check_stmt.cpp, parser.cpp |
| Indexing rules | 10+ | check_expr.cpp, check_type.cpp |

## Specification Files

| File | Description | Status |
|------|-------------|--------|
| `types.md` | Type system (BasicKind, flags, composites) | ✓ Complete |
| `errors.md` | Error messages by category (50 per category) | ✓ Complete |
| `all_errors.txt` | Full error message dump (1,103 unique) | ✓ Complete |
| `builtins.md` | 278 built-in procedures with signatures | ✓ Complete |
| `operators.md` | Operator semantics and type rules | ✓ Complete |
| `conversions.md` | Type conversion/cast/transmute rules | ✓ Complete |
| `indexing.md` | Array access, enumerated arrays, slicing, matrices | ✓ Complete |
| `directives.md` | Hash directives, attributes, parameter flags | ✓ Complete |
| `semantics.md` | Keywords, control flow, scopes, context system | ✓ Complete |
| `advanced.md` | Polymorphism, FFI, bit types, SOA, SIMD | ✓ Complete |
| `runtime.md` | or_*, RTTI, bounds checking, TLS, build flags | ✓ Complete |

## Extraction Strategy

### Mechanistically Extracted:
1. **Error Messages** - Rule violations in natural language
2. **Type Definitions** - Type enum, flags, structures
3. **Built-in Procedures** - Names, argument counts, packages
4. **Operator Tables** - Valid operand types per operator
5. **Basic Type Flags** - Numeric, ordered, comparable, etc.
6. **Conversion Rules** - What converts to what
7. **Hash Directives** - #packed, #align, #partial, etc.
8. **Attributes** - @(init), @(export), @(private), etc.
9. **Parameter Flags** - #no_alias, #any_int, #by_ptr, etc.
10. **Keywords** - Reserved words and contextual identifiers
11. **Control Flow** - if/for/switch forms, do syntax, scopes
12. **Context System** - Implicit context, allocators
13. **Polymorphism** - $T parameters, where clauses, specialization
14. **Procedure Groups** - Overloading, resolution rules
15. **FFI** - Foreign imports, calling conventions, #c_vararg
16. **Bit Types** - bit_set, bit_field rules and restrictions
17. **SOA/SIMD** - #soa structs, #simd vectors, operations
18. **Indexing** - Array/slice/map access, enumerated arrays, #sparse

### Requires Interpretation:
1. Control flow (when rules apply)
2. Implicit rules (what passes silently)
3. Feature interactions
4. Evaluation order

## Usage

These files document the expected behavior of the Odin semantic checker.
Use them to:

1. Verify checker behavior matches C++ implementation
2. Write test cases covering documented error conditions
3. Understand type system rules without reading C++ source
