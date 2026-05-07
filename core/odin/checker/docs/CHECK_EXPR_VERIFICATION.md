# Expression Checking Verification Report
## check_expr.odin vs check_expr.cpp

**Date:** 2025-10-03
**C++ Reference:** `/mnt/c/odin/src/check_expr.cpp` (12,574 lines, 381KB)
**Odin Implementation:** `/mnt/d/dev/checker/check_expr.odin` (6,130 lines, 163KB)
**Line Count Ratio:** 48.7% (Odin is roughly half the size of C++)

---

## Executive Summary

**Status: INCOMPLETE - Major Gaps Identified**

The Odin port implements approximately **40-50% of the C++ expression checking functionality**. While core expression types are partially handled, critical features are missing or stubbed, including:

- **Procedure literals** (lambda/closure support)
- **Implicit context values**
- **Basic directives** (#load, #assert, #panic, etc.)
- **Polymorphic procedure resolution** (generics/overloading)
- **Matrix expressions and indexing**
- **Inline assembly expressions**
- **Selector call expressions** (x->y syntax)
- **Dereference expressions** (explicit pointer dereferencing)
- **Full constant evaluation**
- **Complete type distance calculation**

The implementation contains **197 TODO/STUB markers**, indicating numerous incomplete features. This is a work-in-progress MVP implementation focusing on basic expressions.

---

## Section 1: Coverage Analysis

### AST Node Handler Coverage

| Category | C++ Handlers | Odin Handlers | Coverage % |
|----------|--------------|---------------|------------|
| Expression nodes | 93 | 34 | 36.6% |
| Core expressions | 25 | 19 | 76.0% |
| Advanced expressions | 20 | 3 | 15.0% |
| Type expressions | 18 | 0 | 0% |
| Special nodes | 30 | 12 | 40.0% |

### Function Coverage

| Function Category | C++ Functions | Odin Functions | Coverage % |
|-------------------|---------------|----------------|------------|
| Expression checking | 45 | 28 | 62.2% |
| Type validation | 15 | 8 | 53.3% |
| Constant evaluation | 12 | 3 | 25.0% |
| Operator checking | 8 | 5 | 62.5% |
| Call validation | 18 | 4 | 22.2% |
| **Total** | **98** | **48** | **49.0%** |

---

## Section 2: Per-Expression-Type Status Table

| Expression Type | C++ Location | Odin Location | Status | Notes |
|-----------------|--------------|---------------|--------|-------|
| **Basic Literals** | 11422-11444 | 563-652 | ✅ COMPLETE | All basic types supported |
| **Identifiers** | 11411-11413, 1743-1923 | 156-560 | ✅ COMPLETE | Full scope resolution |
| **Binary Expressions** | 11608-11614, 4026-4965 | 762-902 | ⚠️ PARTIAL | Missing matrix ops, bit sets |
| **Unary Expressions** | 11592-11605, 2697-2914 | 903-964 | ⚠️ PARTIAL | Basic ops only |
| **Call Expressions** | 11643-11645, 8155-8418 | 5801-5914 | ⚠️ PARTIAL | No overloads, no variadic |
| **Index Expressions** | 11629-11631, 11009-11137 | 3197-3355 | ⚠️ PARTIAL | Basic indexing only |
| **Slice Expressions** | 11633-11635, 11138-11341 | 3356-3601 | ⚠️ PARTIAL | No open ranges |
| **Selector Expressions** | 11616-11620 | 2654-2961 | ⚠️ PARTIAL | No swizzle, no SOA |
| **Type Assertions** | 11540-11542, 10733-10861 | 3755-3987 | ⚠️ PARTIAL | Basic support only |
| **Type Casts** | 11544-11575, 3525-3659 | 4546-4582 | ⚠️ PARTIAL | Basic casts only |
| **Auto Cast** | 11577-11590 | 4584-4605 | ✅ COMPLETE | Full support |
| **Transmute** | 3660-3790 | 5300-5440 | ⚠️ PARTIAL | Size checks missing |
| **Compound Literals** | 11520-11522, 9763-10728 | check_compound_lit.odin | ⚠️ PARTIAL | Separate file, partial |
| **Ternary If** | 11499-11501, 9124-9207 | 3602-3705 | ✅ COMPLETE | Full support |
| **Ternary When** | 11503-11505, 9208-9234 | 3706-3754 | ✅ COMPLETE | Compile-time only |
| **Or Else** | 11507-11509, 9235-9360 | 4174-4276 | ⚠️ PARTIAL | Basic support |
| **Or Return** | 11511-11514, 9362-9442 | 4277-4380 | ⚠️ PARTIAL | Basic support |
| **Or Branch** | 11516-11518, 9445-9545 | 4381-4506 | ⚠️ PARTIAL | Basic support |
| **Paren Expressions** | 11524-11528 | 4668-4675 | ✅ COMPLETE | Full support |
| **Tag Expressions** | 11530-11538 | 4677-4689 | ✅ COMPLETE | Error reporting |
| **Implicit Selectors** | 11625-11627, 8743-8797 | 3988-4046 | ⚠️ PARTIAL | Type hint required |
| **Procedure Literals** | 11455-11497 | - | ❌ MISSING | Not implemented |
| **Implicit Context** | 11382-11409 | - | ❌ MISSING | Not implemented |
| **Uninit Literals** | 11415-11419 | - | ❌ MISSING | Not implemented |
| **Basic Directives** | 11446-11448, 8994-9123 | - | ❌ MISSING | #load, #assert, etc. |
| **Proc Groups** | 11450-11453 | - | ❌ MISSING | Overload resolution |
| **Dereference** | 11647-11689 | - | ❌ MISSING | Explicit deref (^) |
| **Matrix Index** | 11637-11641, 8841-8993 | - | ❌ MISSING | Matrix[i,j] syntax |
| **Inline Assembly** | 11691-11736 | - | ❌ MISSING | Platform-specific |
| **Selector Call** | 11621-11623, 10862-11008 | - | ❌ MISSING | x->proc() syntax |
| **Bad Expressions** | 11378-11380 | 4691-4693 | ✅ COMPLETE | Error recovery |

**Legend:**
- ✅ COMPLETE: Fully implemented with equivalent behavior
- ⚠️ PARTIAL: Basic implementation, missing advanced features
- ❌ MISSING: Not implemented at all

---

## Section 3: Type Inference Analysis

### Type Inference Completeness: **55%**

**Implemented:**
- ✅ Basic literal type inference (int, float, string, bool)
- ✅ Binary expression type inference (arithmetic, logical)
- ✅ Unary expression type inference (negation, not, address-of)
- ✅ Function call return type inference
- ✅ Index expression type inference (array element types)
- ✅ Selector expression type inference (field types)
- ✅ Type assertion result type inference
- ✅ Ternary expression type inference

**Missing/Incomplete:**
- ❌ Polymorphic type instantiation (generics)
  - **C++ Ref:** Lines 650-660, 862-866 (polymorphic matching)
  - **Impact:** Cannot use generic procedures/types
- ❌ Procedure group overload resolution
  - **C++ Ref:** Lines 6933-7504 (572 LOC of scoring logic)
  - **Impact:** Cannot disambiguate overloaded procedures
- ⚠️ Untyped constant promotion (partial)
  - **C++ Ref:** Lines 714-823 (complete untyped rules)
  - **Odin Impl:** Lines 1558-1705, 5503-5600 (simplified)
  - **Missing:** Complex/quaternion handling, array element conversion
- ⚠️ Matrix type inference (missing)
  - **C++ Ref:** Lines 3853-3971, 8841-8993
  - **Impact:** No matrix operations
- ⚠️ SOA pointer inference (missing)
  - **C++ Ref:** Lines 11667-11669
  - **Impact:** No Structure-of-Arrays support
- ❌ Enum value to base type conversion
  - **C++ Ref:** Lines 826-830
  - **Impact:** Enum operations limited

### Untyped Value Conversion: **40%**

**C++ Implementation:** Lines 2107-2363 (check_representable_as_constant)
**Odin Implementation:** Lines 1762-2167 (partial)

**Gaps:**
- ❌ Complex number range validation (lines 2284-2320)
- ❌ Quaternion range validation (lines 2321-2336)
- ❌ String to cstring conversion validation
- ❌ Procedure constant validation
- ⚠️ Float16/Float32 precision checking (simplified)
- ⚠️ Integer 128-bit support (missing BigInt integration)

---

## Section 4: Operator Coverage

### Arithmetic Operators

| Operator | C++ Support | Odin Support | Status | Notes |
|----------|-------------|--------------|--------|-------|
| `+` (Add) | Full | Partial | ⚠️ | Missing bit set union |
| `-` (Sub) | Full | Partial | ⚠️ | Missing bit set difference |
| `*` (Mul) | Full | Partial | ⚠️ | Missing matrix multiply |
| `/` (Div) | Full | Partial | ⚠️ | Missing matrix restrictions |
| `%` (Mod) | Full | Basic | ⚠️ | Missing SIMD checks |
| `%%` (Mod-Mod) | Full | Basic | ⚠️ | Missing SIMD checks |

**C++ Ref:** Lines 2004-2077 (binary_op validation)
**Odin Impl:** Lines 655-713 (simplified)

**Missing from Odin:**
- Bit set operations (union, intersection, difference)
- Matrix operation restrictions
- SIMD vector integer division checks
- Assignment operator variants (+=, -=, etc.)

### Bitwise Operators

| Operator | C++ Support | Odin Support | Status |
|----------|-------------|--------------|--------|
| `&` (And) | Full | Basic | ⚠️ |
| `|` (Or) | Full | Basic | ⚠️ |
| `~` (Xor) | Full | Basic | ⚠️ |
| `&~` (And-Not) | Full | Basic | ⚠️ |

**Missing:** Bit set type validation (C++ lines 2056-2085)

### Comparison Operators

| Operator | C++ Support | Odin Support | Status |
|----------|-------------|--------------|--------|
| `==`, `!=` | Full | Partial | ⚠️ |
| `<`, `<=`, `>`, `>=` | Full | Partial | ⚠️ |

**C++ Ref:** Lines 2915-3141 (check_comparison - 226 LOC)
**Odin Impl:** Lines 717-760 (stub - 43 LOC)

**Missing from Odin:**
- Constant comparison evaluation
- Complex/quaternion comparison validation
- Pointer comparison rules
- Type distance scoring for mismatched types

### Shift Operators

| Operator | C++ Support | Odin Support | Status |
|----------|-------------|--------------|--------|
| `<<`, `>>` | Full | ❌ Missing | ❌ |

**C++ Ref:** Lines 3142-3245 (check_shift - 103 LOC)
**Not implemented in Odin**

**Missing:**
- Unsigned right operand validation
- Constant shift amount checking
- SIMD shift restrictions
- Matrix shift prohibition

### Logical Operators

| Operator | C++ Support | Odin Support | Status |
|----------|-------------|--------------|--------|
| `&&`, `||` | Full | Basic | ✅ |

**Implemented** but missing constant folding

---

## Section 5: Critical Missing Features

### Priority 1: MUST-FIX (Compiler Broken Without These)

1. **Procedure Literals (Lambdas/Closures)**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11455-11497` (42 LOC)
   - **Status:** ❌ Not implemented
   - **Impact:** Cannot define anonymous procedures, nested procedures
   - **Complexity:** HIGH (requires scope handling, type checking, deferred checking)
   - **Dependencies:** check_procedure_type, check_procedure_later, nested_proc_lits tracking

2. **Basic Directives (#load, #assert, #panic, etc.)**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11446-11448, 8994-9123` (130 LOC)
   - **Status:** ❌ Not implemented
   - **Impact:** Cannot use compiler directives, file loading broken
   - **Builtins Affected:** #load, #load_directory, #assert, #panic, #defined, #config
   - **Dependencies:** check_basic_directive_expr, is_load_directive_call

3. **Implicit Context Value**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11382-11409` (28 LOC)
   - **Status:** ❌ Not implemented
   - **Impact:** Cannot access `context` variable, Odin calling convention broken
   - **Dependencies:** ScopeFlag_ContextDefined, init_core_context

4. **Procedure Groups (Overload Resolution)**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:6933-7504` (572 LOC)
   - **Status:** ❌ Not implemented
   - **Impact:** Cannot use overloaded procedures
   - **Complexity:** VERY HIGH (polymorphic scoring, candidate filtering)
   - **Dependencies:** check_distance_between_types, polymorphic type matching

5. **Dereference Expressions**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11647-11689` (42 LOC)
   - **Status:** ❌ Not implemented
   - **Impact:** Cannot explicitly dereference pointers with `^`
   - **Affects:** Pointer dereferencing, SOA pointers

### Priority 2: HIGH (Major Features Missing)

6. **Polymorphic Type Resolution**
   - **C++ Occurrences:** 140 references
   - **Odin Occurrences:** 31 references (partial stubs)
   - **Gap:** 109 missing polymorphic handling sites
   - **Impact:** Generics broken, type parameters not resolved
   - **Key Functions Missing:**
     - `find_polymorphic_record_entity` (C++ line 124)
     - `check_polymorphic_procedure_assignment` (C++ line 650)
     - `is_polymorphic_type_assignable` (C++ line 864)

7. **Complete Type Distance Calculation**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:667-1004` (337 LOC)
   - **Odin Impl:** `/mnt/d/dev/checker/check_expr.odin:5441-5800` (359 LOC)
   - **Coverage:** ~60% (missing subtype checking, interface satisfaction, array programming)
   - **Missing:**
     - `check_is_assignable_to_using_subtype` (C++ line 835)
     - Interface type satisfaction
     - Array programming mode scoring
     - Union variant distance calculation

8. **Full Constant Evaluation**
   - **C++ Ref:** Multiple locations, evaluation engine
   - **Odin Status:** Stubs only, no constant folding
   - **Missing:**
     - Constant binary operation evaluation
     - Constant unary operation evaluation
     - Constant comparison evaluation
     - Constant type conversions
   - **Impact:** Compile-time expressions broken

9. **Call Argument Validation (Advanced)**
   - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:6799-8014` (1215 LOC)
   - **Odin Impl:** `/mnt/d/dev/checker/check_expr.odin:5916-6130` (214 LOC)
   - **Coverage:** ~18%
   - **Missing:**
     - Named arguments (C++ lines 6799-6858)
     - Variadic arguments (C++ lines 6861-7014)
     - Default parameters (C++ lines 7015-7120)
     - Polymorphic argument scoring (C++ lines 7121-7504)
     - Field value arguments (struct literals in calls)

10. **Uninit Literal (---)**
    - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11415-11419` (4 LOC)
    - **Status:** ❌ Not implemented
    - **Impact:** Cannot use explicit uninitialized values

### Priority 3: MEDIUM (Advanced Features)

11. **Matrix Expressions**
    - **C++ Refs:**
      - Matrix index: Lines 11637-11641, 8841-8993 (152 LOC)
      - Matrix binary ops: Lines 3853-3971 (118 LOC)
    - **Status:** ❌ Not implemented
    - **Impact:** Matrix types unusable

12. **Inline Assembly Expressions**
    - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11691-11736` (45 LOC)
    - **Status:** ❌ Not implemented
    - **Impact:** Cannot use inline asm

13. **Selector Call Expressions (x->proc())**
    - **C++ Ref:** `/mnt/c/odin/src/check_expr.cpp:11621-11623, 10862-11008` (146 LOC)
    - **Status:** ❌ Not implemented
    - **Impact:** Method call syntax broken

14. **SOA (Structure of Arrays) Support**
    - **C++ Refs:** Multiple locations
    - **Status:** Stubs only
    - **Missing:**
      - SOA pointer dereferencing (C++ line 11667)
      - SOA type completion (C++ line 126)
      - SOA struct generation

15. **Shift Operators**
    - **C++ Ref:** Lines 3142-3245 (103 LOC)
    - **Status:** ❌ Not implemented
    - **Impact:** Cannot use `<<` or `>>`

### Priority 4: LOW (Polish/Edge Cases)

16. **Viral State Flags Tracking**
    - **C++:** Extensive viral flag propagation
    - **Odin:** All viral flag updates commented out with TODO
    - **Impact:** Optimization flags not propagated

17. **Error Suggestion System**
    - **C++ Refs:** Lines 2364-2493 (check_assignment_error_suggestion)
    - **Odin:** Minimal suggestions
    - **Impact:** Poor error messages

18. **"Did You Mean" System**
    - **C++ Refs:** Lines 155-249 (check_did_you_mean_*)
    - **Odin:** Not implemented
    - **Impact:** No typo suggestions

---

## Section 6: Semantic Differences

### Behavior Changes (Intentional or Bugs?)

1. **Untyped Constant Handling**
   - **C++ Behavior:** Complex multi-stage promotion with exact value tracking
   - **Odin Behavior:** Simplified type category matching
   - **Assessment:** Likely causes bugs with edge cases (e.g., untyped float to i8 should fail if value too large)
   - **Location:** `/mnt/d/dev/checker/check_expr.odin:5503-5600` vs C++ lines 714-823

2. **Type Distance Scoring**
   - **C++ Scoring:** Detailed scores (0-9 scale with special values)
   - **Odin Scoring:** Simplified scoring, missing many categories
   - **Impact:** Overload resolution will pick wrong candidates
   - **Missing Scores:**
     - Subtype distance (C++ lines 835-839)
     - Interface satisfaction (not implemented)
     - Array programming conversions (missing)

3. **Operator Validation**
   - **C++:** Comprehensive checks for each operator+type combination
   - **Odin:** Basic type category checks only
   - **Example Difference:**
     - C++ prohibits `/` on matrices (line 2016)
     - C++ prohibits `%` on SIMD vectors (line 2073)
     - Odin allows these (will crash later)

4. **Error Recovery**
   - **C++:** Continues checking arguments even on errors
   - **Odin:** Early returns on first error
   - **Impact:** Fewer errors reported per compilation

### Good Simplifications

1. **String Handling**
   - Odin uses native string type instead of C++ String struct
   - Cleaner, more idiomatic

2. **AST Access**
   - Odin uses derived_node pattern matching
   - More type-safe than C++ macros

3. **Memory Management**
   - No manual allocation in Odin (GC handles it)
   - Simpler, less error-prone

### Questionable Omissions

1. **Missing Addressing Mode Tracking**
   - C++ tracks precise addressing modes (Constant, Value, Variable, etc.)
   - Odin has enum but doesn't use all modes consistently
   - **Example:** SoaVariable mode not set (C++ line 11668)

2. **Incomplete add_type_and_value Calls**
   - Many sites in Odin have TODO comments instead of calls
   - AST won't have complete type information
   - **Impact:** Backend passes may fail

---

## Section 7: Constant Evaluation Status

### Constant Evaluation: **15% Complete**

**C++ Infrastructure:**
- ExactValue system with multiple value types
- check_representable_as_constant (lines 2107-2363)
- Constant folding for all operators
- Compile-time expression evaluation

**Odin Implementation:**
- Basic ExactValue support (lines 1762-2167)
- No constant folding
- No compile-time evaluation
- Only literal constants tracked

### Missing Constant Operations

1. **Binary Constant Folding**
   - **C++ Ref:** Integrated in check_binary_expr
   - **Status:** ❌ Not implemented
   - **Impact:** `const X = 2 + 3` doesn't fold to 5

2. **Unary Constant Folding**
   - **C++ Ref:** Integrated in check_unary_expr
   - **Status:** ❌ Not implemented
   - **Impact:** `const X = -5` doesn't fold

3. **Constant Comparison**
   - **C++ Ref:** Lines 2915-3141 (check_comparison)
   - **Odin Impl:** Line 724 (TODO comment)
   - **Status:** ❌ Not implemented
   - **Impact:** `const B = 5 > 3` doesn't evaluate

4. **Constant Type Conversion**
   - **C++ Ref:** Lines 2107-2363
   - **Odin Impl:** Lines 1762-2167 (partial)
   - **Status:** ⚠️ Partial (missing complex/quaternion)

5. **Compile-Time When Evaluation**
   - **C++ Ref:** check_ternary_when_expr (lines 9208-9234)
   - **Odin Impl:** Lines 3706-3754
   - **Status:** ⚠️ Partial (condition evaluation stubbed)

### Exact Value Support

| Value Type | C++ Support | Odin Support | Status |
|------------|-------------|--------------|--------|
| Integer | Full | Full | ✅ |
| Float | Full | Partial | ⚠️ |
| Complex | Full | Stub | ⚠️ |
| Quaternion | Full | Missing | ❌ |
| String | Full | Full | ✅ |
| Boolean | Full | Full | ✅ |
| Pointer | Full | Stub | ⚠️ |
| Compound | Full | Missing | ❌ |
| Procedure | Full | Missing | ❌ |

---

## Section 8: Addressing Mode Tracking

### Addressing Mode Coverage: **60%**

**C++ Modes (AddressingMode enum):**
```cpp
Addressing_Invalid
Addressing_NoValue
Addressing_Value
Addressing_Constant
Addressing_Variable
Addressing_Immutable
Addressing_SoaVariable
Addressing_Context
Addressing_Type
Addressing_Builtin
Addressing_ProcGroup
Addressing_OptionalOk
Addressing_OptionalOkPtr
Addressing_SoaVariable_Value
Addressing_SwizzleValue
Addressing_SwizzleVariable
Addressing_BitField
Addressing_BitFieldValue
```

**Odin Modes Defined:**
```odin
Invalid
No_Value
Value
Immutable
Variable
Constant
Type
Builtin
Proc_Group
Context
Optional_Ok
Optional_Ok_Ptr
Soa_Variable
```

**Missing Modes:**
- ❌ SwizzleValue (vector swizzling)
- ❌ SwizzleVariable
- ❌ BitField (bit field access)
- ❌ BitFieldValue
- ❌ SoaVariable_Value

### Mode Setting Correctness

**Correct Usage:**
- ✅ Invalid mode set on errors
- ✅ Constant mode for literals
- ✅ Type mode for type expressions
- ✅ Value mode for procedure calls
- ✅ Variable mode for mutable values

**Missing/Incorrect:**
- ⚠️ Context mode never set (context value missing)
- ⚠️ SoaVariable mode not used (SOA support incomplete)
- ⚠️ OptionalOk modes used but not fully implemented
- ❌ Swizzle modes not implemented
- ❌ BitField modes not implemented

### Lvalue/Rvalue Tracking

**C++ Approach:**
- Precise distinction via addressing modes
- Variable/Immutable for lvalues
- Value/Constant for rvalues
- Validates assignment targets

**Odin Approach:**
- Basic distinction implemented
- Missing validation in many places
- TODO comments indicate incomplete tracking

**Example Gap:**
```odin
// C++ line 2584-2696: check_is_not_addressable (112 LOC)
// Validates lvalue requirements
// Odin: Not implemented
```

---

## Section 9: Call Expression Completeness

### Call Expression: **30% Complete**

**C++ Implementation:** Lines 8155-8418 (263 LOC)
**Odin Implementation:** Lines 5801-5914 (113 LOC)

### Implemented Features

✅ **Basic Positional Arguments**
- Parameter count checking
- Type compatibility validation
- Simple argument passing

✅ **Builtin Procedure Dispatch**
- Redirects to check_builtin_procedure
- Handles builtin IDs correctly

✅ **Calling Convention Checks**
- Validates context availability for Odin CC
- Basic CC validation

### Missing Features

❌ **Named Arguments**
- **C++ Ref:** Lines 6799-6858 (59 LOC)
- **Impact:** Cannot use `proc(x = 5, y = 10)` syntax
- **Complexity:** Medium

❌ **Variadic Arguments**
- **C++ Ref:** Lines 6861-7014 (153 LOC)
- **Impact:** Cannot use `..` or `..Type` parameters
- **Includes:** Variadic expand, #soa, tuple unpacking

❌ **Default Parameters**
- **C++ Ref:** Integrated in argument matching
- **Impact:** Cannot omit parameters with defaults

❌ **Procedure Group Resolution**
- **C++ Ref:** Lines 6933-7504 (572 LOC)
- **Impact:** Overload resolution broken
- **Requires:** Type distance scoring, candidate filtering

❌ **Polymorphic Instantiation**
- **C++ Ref:** Lines 7121-7504 (polymorphic scoring)
- **Impact:** Generic procedures broken
- **Requires:** Type parameter inference

❌ **Field Value Arguments**
- **C++ Ref:** Integrated in compound literal calls
- **Impact:** Cannot use struct literal syntax in calls
- **Example:** `make_vec(.x = 1, .y = 2)`

❌ **Inlining Directives**
- **C++ Ref:** Lines 8327-8374 (47 LOC)
- **Impact:** `inline`, `no_inline` tags ignored
- **Status:** Stubbed with TODO

❌ **Type Constructor Calls**
- **C++ Ref:** Lines 8054-8154 (100 LOC)
- **Impact:** `Vec3(1, 2, 3)` syntax broken
- **Function:** check_call_expr_as_type_cast

❌ **Deferred Procedure Tracking**
- **C++ Ref:** Lines 8233-8239
- **Impact:** Defer semantics incomplete

### Argument Checking Subsystems

| Subsystem | C++ LOC | Odin LOC | Status |
|-----------|---------|----------|--------|
| Positional args | ~150 | ~100 | ⚠️ Partial |
| Named args | 59 | 0 | ❌ Missing |
| Variadic args | 153 | 0 | ❌ Missing |
| Polymorphic args | 383 | 0 | ❌ Missing |
| Default params | ~50 | 0 | ❌ Missing |
| Field values | ~80 | 0 | ❌ Missing |
| **Total** | **~875** | **~100** | **11.4%** |

### Argument Validation Depth

**C++ Validation:**
1. Parameter count matching
2. Named/positional separation
3. Variadic expansion handling
4. Type distance scoring per argument
5. Polymorphic parameter inference
6. Default parameter filling
7. Implicit conversions
8. Const parameter validation

**Odin Validation:**
1. Parameter count matching ✅
2. Basic type compatibility ✅
3. (Everything else missing) ❌

---

## Section 10: Recommended Implementation Order

### Phase 1: Core Stability (Week 1-2)

**Goal:** Make basic expressions fully functional

1. **Fix Addressing Mode Tracking**
   - **Effort:** 2-3 days
   - **Files:** check_expr.odin
   - **Actions:**
     - Audit all operand mode assignments
     - Implement check_is_not_addressable
     - Fix lvalue/rvalue validation

2. **Complete add_type_and_value Calls**
   - **Effort:** 1-2 days
   - **Files:** check_expr.odin
   - **Actions:**
     - Remove all TODO comments for add_type_and_value
     - Ensure every expression annotates AST
     - Test backend compatibility

3. **Implement Shift Operators**
   - **Effort:** 1 day
   - **C++ Ref:** Lines 3142-3245
   - **Actions:**
     - Add check_shift procedure
     - Integrate in binary expression handler
     - Validate unsigned right operand

4. **Fix Operator Coverage Gaps**
   - **Effort:** 2-3 days
   - **Actions:**
     - Add bit set operations to binary_op
     - Add matrix operation restrictions
     - Add SIMD validation checks
     - Implement assignment operators (+=, -=, etc.)

### Phase 2: Critical Features (Week 3-4)

**Goal:** Enable fundamental Odin features

5. **Implement Implicit Context**
   - **Effort:** 1 day
   - **C++ Ref:** Lines 11382-11409
   - **Dependencies:** init_core_context, ScopeFlag_ContextDefined
   - **Priority:** CRITICAL (Odin CC broken without it)

6. **Implement Dereference Expressions**
   - **Effort:** 1 day
   - **C++ Ref:** Lines 11647-11689
   - **Actions:**
     - Add Deref_Expr case to check_expr_base
     - Handle pointer and SOA pointer types
     - Add error suggestions

7. **Implement Uninit Literal**
   - **Effort:** 0.5 days
   - **C++ Ref:** Lines 11415-11419
   - **Actions:** 4 lines of code, trivial

8. **Implement Procedure Literals**
   - **Effort:** 3-5 days
   - **C++ Ref:** Lines 11455-11497
   - **Dependencies:**
     - check_procedure_type (may exist)
     - check_procedure_later (may exist)
     - nested_proc_lits tracking
   - **Complexity:** HIGH
   - **Priority:** CRITICAL

9. **Implement Basic Directives**
   - **Effort:** 3-4 days
   - **C++ Ref:** Lines 8994-9123, 11446-11448
   - **Actions:**
     - Implement check_basic_directive_expr
     - Handle #load, #assert, #panic, #defined, #config
     - Integrate with builtin system
   - **Priority:** CRITICAL

### Phase 3: Advanced Features (Week 5-8)

**Goal:** Enable polymorphism and overloading

10. **Implement Type Distance Completion**
    - **Effort:** 5-7 days
    - **C++ Ref:** Lines 667-1004
    - **Actions:**
      - Implement check_is_assignable_to_using_subtype
      - Add interface satisfaction checking
      - Add array programming mode
      - Complete union variant matching

11. **Implement Constant Evaluation**
    - **Effort:** 7-10 days
    - **Actions:**
      - Binary constant folding
      - Unary constant folding
      - Constant comparisons
      - Type conversion validation
    - **Complexity:** HIGH

12. **Implement Polymorphic Type Resolution**
    - **Effort:** 10-15 days
    - **C++ Refs:** 140 references across file
    - **Actions:**
      - Implement find_polymorphic_record_entity
      - Implement check_polymorphic_procedure_assignment
      - Implement is_polymorphic_type_assignable
      - Type parameter inference
    - **Complexity:** VERY HIGH
    - **Priority:** CRITICAL for generics

13. **Implement Procedure Group Resolution**
    - **Effort:** 10-15 days
    - **C++ Ref:** Lines 6933-7504 (572 LOC)
    - **Dependencies:** Type distance, polymorphic resolution
    - **Actions:**
      - Candidate filtering
      - Scoring system
      - Ambiguity detection
      - Best match selection
    - **Complexity:** VERY HIGH
    - **Priority:** CRITICAL for overloads

### Phase 4: Call Arguments (Week 9-11)

**Goal:** Complete call expression handling

14. **Named Arguments**
    - **Effort:** 3-4 days
    - **C++ Ref:** Lines 6799-6858

15. **Variadic Arguments**
    - **Effort:** 5-7 days
    - **C++ Ref:** Lines 6861-7014

16. **Default Parameters**
    - **Effort:** 2-3 days
    - **Integrated with argument matching**

17. **Polymorphic Arguments**
    - **Effort:** 7-10 days
    - **C++ Ref:** Lines 7121-7504
    - **Requires:** Polymorphic resolution from Phase 3

### Phase 5: Specialized Features (Week 12-14)

**Goal:** Matrix, SOA, and advanced features

18. **Matrix Expressions**
    - **Effort:** 5-7 days
    - **C++ Refs:** Lines 3853-3971, 8841-8993

19. **SOA Support**
    - **Effort:** 7-10 days
    - **Multiple locations**

20. **Selector Call Expressions**
    - **Effort:** 3-4 days
    - **C++ Ref:** Lines 10862-11008

21. **Inline Assembly**
    - **Effort:** 2-3 days
    - **C++ Ref:** Lines 11691-11736
    - **Priority:** LOW (platform-specific)

### Phase 6: Polish (Week 15+)

22. **Error Suggestions**
    - **Effort:** 3-5 days
    - **C++ Refs:** Lines 2364-2493, 155-249

23. **Viral State Flags**
    - **Effort:** 2-3 days
    - **Actions:** Uncomment and enable all viral flag tracking

24. **Edge Case Hardening**
    - **Effort:** Ongoing
    - **Actions:** Test suite expansion, bug fixes

---

## Critical Path Dependencies

```
Phase 1 (Core Stability)
    ↓
Phase 2 (Critical Features) ← Must do before Phase 3
    ↓
Phase 3 (Type Distance + Polymorphic) ← Blocking for Phase 4
    ↓
Phase 4 (Call Arguments)
    ↓
Phase 5 (Specialized Features)
    ↓
Phase 6 (Polish)
```

**Blocking Relationships:**
- Procedure groups REQUIRE type distance scoring
- Polymorphic arguments REQUIRE polymorphic resolution
- Many features REQUIRE constant evaluation
- SOA features REQUIRE addressing mode fixes

---

## Summary Statistics

| Metric | C++ | Odin | Coverage |
|--------|-----|------|----------|
| Lines of Code | 12,574 | 6,130 | 48.7% |
| Expression Handlers | 93 | 34 | 36.6% |
| Functions | 98 | 48 | 49.0% |
| TODO/Stubs | ~0 | 197 | N/A |
| Polymorphic Refs | 140 | 31 | 22.1% |
| Complete Features | ~90% | ~40% | 44.4% |

**Overall Assessment: 40-45% COMPLETE**

The Odin implementation is a solid MVP foundation but requires significant work to achieve feature parity. The missing procedure literals, context value, basic directives, and polymorphic resolution are critical blockers for a functional Odin compiler.

**Estimated Effort to Completion:** 15-20 weeks of focused development

---

## Files Referenced

### C++ Source
- `/mnt/c/odin/src/check_expr.cpp` - Main expression checking (12,574 lines)

### Odin Source
- `/mnt/d/dev/checker/check_expr.odin` - Main expression checking (6,130 lines)
- `/mnt/d/dev/checker/check_compound_lit.odin` - Compound literals
- `/mnt/d/dev/checker/check_builtin.odin` - Builtin procedures

### Key Line References (C++)
- 667-1004: Type distance calculation
- 1743-1923: Identifier resolution
- 1997-2104: Binary operator validation
- 2107-2363: Constant representability
- 2697-2914: Unary expressions
- 2915-3141: Comparison operators
- 3142-3245: Shift operators
- 3525-3659: Type casting
- 3660-3790: Transmute
- 4026-4965: Binary expressions
- 6799-8014: Call argument validation
- 8155-8418: Call expressions
- 9763-10728: Compound literals
- 11342-11761: Expression dispatcher

---

**End of Report**
