# Phase 30: Checker Completion Plan

**Total Estimated**: 2,211 LOC, 5.5 weeks
**Goal**: Complete all stubbed/MVP features to achieve production-ready checker

---

## Phase 30A: Critical Blockers (Estimated: 2 weeks, 1,150 LOC)

**Goal**: Enable checking of real-world Odin code with generics, variadic functions, and complete control flow analysis

**Why This Phase**:
- **Force Multiplier**: Polymorphic type binding enables 3+ features (generic calls, return types, constraints)
- **Business Value**: Blocks 80% of real Odin code currently
- **Dependencies**: Infrastructure exists (Phase 28 at 76%), just needs activation
- **Risk Mitigation**: Most code exists but is disabled - low implementation risk

### Group 1: Polymorphism Foundation (380 LOC)

**Files**:
- check_type.odin (160 LOC)
- check_expr.odin (200 LOC)
- check_poly_proc.odin (modifications)

**Implementation Tasks**:

1. **[A6] Implement Polymorphic Type Binding** (80 LOC)
   - Location: check_type.odin:2596-2601
   - Current: Comment "For MVP, we just validate compatibility" - function returns true without binding
   - Action: Create specialized types with $T replaced by concrete types
   - C++ Reference: check_type.cpp:2847-2901
   - Dependencies: None

2. **[A1] Enable Polymorphic Procedure Calls** (200 LOC)
   - Location: check_expr.odin:6319-6328
   - Current: `error(call.pos, "Polymorphic procedures not yet supported in MVP checker")`
   - Action: Remove error, call `find_or_generate_polymorphic_procedure` (already exists in check_poly_proc.odin)
   - Enable type substitution at check_type.odin:1782-1786
   - C++ Reference: check_expr.cpp:369-658
   - Dependencies: Task 1 (A6) complete

3. **[C2] Enable Polymorphic Return Types** (80 LOC)
   - Location: check_type.odin:2228-2230
   - Current: `error(node.pos, "Polymorphic return types not yet supported")`
   - Action: Remove error, allow $T in return position
   - C++ Reference: check_type.cpp:2536-2578
   - Dependencies: Task 1 (A6) complete

4. **[D1] Activate Where Clause Validation** (20 LOC)
   - Locations: check_type.odin:347, 1102, 3063-3067
   - Current: Function `evaluate_where_clauses` exists but calls are commented out
   - Action: Uncomment integration points, add nil guards
   - C++ Reference: check_type.cpp:314-337
   - Dependencies: None

**C++ References**:
- check_type.cpp:2847-2901 (type binding)
- check_expr.cpp:369-658 (polymorphic calls)
- check_type.cpp:2536-2578 (return types)
- check_type.cpp:314-337 (where clauses)

**Verification Criteria**:
- [ ] Can check generic procedures like `proc foo($T: typeid, x: T) -> T`
- [ ] Type parameters bound to concrete types at call sites
- [ ] Where clauses enforced (e.g., `where len($T) == 4`)
- [ ] Zero errors on generic container code

### Group 2: Procedure Call Completeness (420 LOC)

**Files**:
- check_expr.odin (420 LOC)
- check_type.odin (modifications)
- check_proc_group.odin (reuse existing code)

**Implementation Tasks**:

1. **[A2] Implement Variadic Procedures** (200 LOC)
   - Location: check_expr.odin:6331-6340
   - Current: `error(call.pos, "Variadic procedures not yet supported")`
   - Action: Create slice for `..any` parameters, validate minimum arg count
   - C++ Reference: check_expr.cpp:6369-6413
   - Dependencies: None

2. **[A3] Enable Named Arguments** (100 LOC)
   - Location: check_expr.odin:6355-6367
   - Current: `error(call.pos, "Named arguments not yet supported")`
   - Action: Reuse `split_call_arguments` from check_proc_group.odin:237-264 (Phase 29)
   - Map named args to parameters using `lookup_procedure_parameter`
   - Validate no duplicate parameters
   - C++ Reference: check_expr.cpp:6325-6364, 7569-7601
   - Dependencies: Phase 29 complete (DONE)

3. **[A5] Implement Default Parameter Values** (120 LOC)
   - Location: check_type.odin:1941-1944
   - Current: `error(node.pos, "Default parameter values not yet supported in MVP checker")`
   - Action: Store defaults in parameter entities, evaluate at call-site when omitted
   - Validate defaults are compile-time constants
   - C++ Reference: check_expr.cpp:6415-6464
   - Dependencies: None

**C++ References**:
- check_expr.cpp:6369-6413 (variadic)
- check_expr.cpp:6325-6364, 7569-7601 (named args)
- check_expr.cpp:6415-6464 (defaults)

**Verification Criteria**:
- [ ] Can check `fmt.println` and variadic functions
- [ ] Can check `foo(x=1, y=2)` named argument syntax
- [ ] Can check `proc bar(x: int = 42)` default parameters
- [ ] Variadic + named args combination works

### Group 3: Infrastructure Fixes (350 LOC)

**Files**:
- check_stmt.odin (200 LOC)
- check_expr.odin (150 LOC)
- exact_value.odin (20 LOC modifications)

**Implementation Tasks**:

1. **[Phase 24 Bug] Fix Viral State Flags Infrastructure** (200 LOC)
   - Location: check_stmt.odin:649 and 9 statement functions
   - Current: Type error - `check_stmt_list` returns void but assigned to `viral_flags`
   - Action: Update 9 statement functions to return `Viral_State_Flags`
   - Fix `check_stmt_list` return type
   - Ensure or_break/or_return flag propagation works
   - C++ Reference: check_stmt.cpp (viral flag patterns throughout)
   - Dependencies: None

2. **[C1] Implement Type Constructor Calls** (150 LOC)
   - Location: check_expr.odin:6126
   - Current: `error(call.pos, "Type constructor calls not yet supported")`
   - Action: Handle `Type{...}` syntax for explicit constructors
   - Note: Compound literals work (check_compound_lit.odin), this is for explicit type constructors
   - C++ Reference: check_expr.cpp:5847-5923
   - Dependencies: None

**C++ References**:
- check_stmt.cpp (viral flags throughout)
- check_expr.cpp:5847-5923 (type constructors)

**Verification Criteria**:
- [ ] or_break detection works in switch statements
- [ ] or_return detection works in defer statements
- [ ] Viral flags propagate through expression trees
- [ ] Type constructor syntax `Vec3{1,2,3}` works

**Phase 30A Completion Criteria**:
- [ ] All critical blocker errors removed
- [ ] Can check real Odin code with generics (core:fmt equivalent)
- [ ] Can check variadic functions
- [ ] Can check named arguments and defaults
- [ ] Control flow analysis working (or_break, or_return)
- [ ] Zero critical errors on core:runtime
- [ ] All verification tests pass

**Deliverables**:
- Polymorphic type system fully functional
- Complete procedure call support (variadic, named, defaults)
- Fixed control flow analysis
- Checker usable on real-world Odin codebases

---

## Phase 30B: High Priority Features (Estimated: 1 week, 330 LOC)

**Goal**: Feature parity for common Odin patterns and C FFI support

**Why This Phase**:
- **Builds on 30A**: Variadic expansion needs variadic procedures (A2)
- **C FFI Support**: Needed for library wrappers
- **Quick Wins**: Low complexity, high value
- **Bug Fixes**: Unblocks Phase 24 statement checking

### Group 1: Remaining Polymorphism & FFI (160 LOC)

**Files**:
- check_expr.odin (80 LOC)
- check_type.odin (80 LOC)

**Implementation Tasks**:

1. **[A4] Implement Variadic Expansion** (80 LOC)
   - Location: check_expr.odin:6343-6352
   - Current: `error(call.pos, "Variadic expansion '..' not yet supported")`
   - Action: Handle `foo(args..)` syntax - expand slice into variadic parameters
   - C++ Reference: check_expr.cpp:6274-6288
   - Dependencies: 30A Group 2 Task 1 (A2 - variadic procedures)

2. **[B1] Implement #c_vararg** (60 LOC)
   - Location: check_type.odin:2005-2008
   - Current: `error(tag.pos, "#c_vararg not yet supported")`
   - Action: Enable C variadic calling convention
   - C++ Reference: check_type.cpp:2214-2238
   - Dependencies: 30A Group 2 Task 1 (A2)

3. **[B3] Implement #any_int** (50 LOC)
   - Location: check_type.odin:2016-2018
   - Current: `error(tag.pos, "#any_int not yet supported")`
   - Action: Enable generic integer type constraint
   - C++ Reference: check_type.cpp:2253-2279
   - Dependencies: None

**C++ References**:
- check_expr.cpp:6274-6288 (variadic expansion)
- check_type.cpp:2214-2238 (c_vararg)
- check_type.cpp:2253-2279 (any_int)

**Verification Criteria**:
- [ ] Can check `foo(args..)` expansion syntax
- [ ] Can check C FFI wrappers with `#c_vararg`
- [ ] Can check generic integer procedures with `#any_int`

### Group 2: Build System Integration (40 LOC)

**Files**:
- check_builtin.odin (20 LOC)
- type_info.odin (20 LOC)

**Implementation Tasks**:

1. **[F3] Implement Build Flag Integration** (40 LOC)
   - Locations: check_builtin.odin:471, 547, type_info.odin:153
   - Current: TODO comments - "Check build_context.no_rtti when build system is implemented"
   - Action: Add `build_context.no_rtti` checking before RTTI operations
   - Error if RTTI used when disabled
   - C++ Reference: check_builtin.cpp:489-497
   - Dependencies: None

**C++ References**:
- check_builtin.cpp:489-497 (build flags)

**Verification Criteria**:
- [ ] `-no-rtti` flag honored
- [ ] Error when using `type_info_of` with `-no-rtti`

### Group 3: Phase 24 Bug Fixes (21 LOC)

**Files**:
- check_range_stmt_impl.odin (1 LOC)
- exact_value.odin (20 LOC)

**Implementation Tasks**:

1. **Fix check_range_stmt Ternary Operator** (1 LOC)
   - Location: check_range_stmt_impl.odin:189
   - Current: `plural := max_val_count == 1 ? "" : "s"` (C-style ternary - invalid Odin)
   - Action: Replace with `plural := "" if max_val_count == 1 else "s"`
   - Also fix lines 195, 242
   - Dependencies: None

2. **Implement Missing Exact Value Functions** (20 LOC)
   - Location: exact_value.odin (add after line 311)
   - Current: Compilation errors at check_stmt.odin:2174, 2178
   - Action: Implement `exact_value_sub` and `exact_value_increment_one`
   ```odin
   exact_value_sub :: proc(x, y: Exact_Value) -> Exact_Value {
       return exact_binary_operator_value(.Sub, x, y)
   }

   exact_value_increment_one :: proc(x: Exact_Value) -> Exact_Value {
       return exact_binary_operator_value(.Add, x, exact_value_i64(1))
   }
   ```
   - Dependencies: None

**Verification Criteria**:
- [ ] check_range_stmt compiles without errors
- [ ] check_unroll_range_stmt compiles without errors
- [ ] Range statements work correctly

**Phase 30B Completion Criteria**:
- [ ] All high-priority features complete
- [ ] C FFI code checkable
- [ ] Build flags honored
- [ ] Phase 24 compilation errors resolved
- [ ] All range/unroll statements work

**Deliverables**:
- Variadic expansion working
- C FFI support complete
- Build system integration
- Phase 24 bugs fixed

---

## Phase 30C: Medium Priority (Estimated: 1 week, 261 LOC)

**Goal**: Edge case coverage and advanced generic features

**Why This Phase**:
- **Advanced Features**: Lower usage but needed for library code
- **RTTI Completeness**: Edge cases in type introspection
- **Declaration Robustness**: Handle out-of-order code

### Group 1: Advanced Polymorphism (120 LOC)

**Files**:
- check_type.odin (120 LOC)

**Implementation Tasks**:

1. **[C3] Implement Polymorphic Constant Parameters** (120 LOC)
   - Location: check_type.odin:1916-1918
   - Current: `error(param.pos, "Polymorphic constant parameters ($Value) not yet supported")`
   - Action: Implement compile-time value parameters (e.g., `$N: int`)
   - Bind values at call-site
   - Validate values are compile-time constants
   - C++ Reference: check_type.cpp:2189-2276
   - Dependencies: 30A Group 1 Task 1 (A6 - type binding pattern)

**C++ References**:
- check_type.cpp:2189-2276 (constant parameters)

**Verification Criteria**:
- [ ] Can check `proc foo($N: int, arr: [$N]int)`
- [ ] Compile-time values bound correctly
- [ ] Error on non-constant values

### Group 2: Declaration Processing & RTTI (120 LOC)

**Files**:
- type_info.odin (40 LOC)
- check_collect.odin (80 LOC)

**Implementation Tasks**:

1. **[E3] Implement Type Alias RTTI Unwrapping** (40 LOC)
   - Location: type_info.odin:133
   - Current: TODO comment "Check if this is a type alias and unwrap if necessary"
   - Action: Detect type aliases and register base type for RTTI
   - C++ Reference: check_type.cpp:8934-8967
   - Dependencies: None

2. **[D3] Implement Delayed Declaration Processing** (80 LOC)
   - Location: check_collect.odin:200-245
   - Current: Comments "NOTE: Not implemented in MVP"
   - Action: Handle out-of-order declarations (use-before-define in some contexts)
   - C++ Reference: check_decl.cpp:1847-1923
   - Dependencies: None

**C++ References**:
- check_type.cpp:8934-8967 (type aliases)
- check_decl.cpp:1847-1923 (delayed declarations)

**Verification Criteria**:
- [ ] Type aliases tracked correctly in RTTI
- [ ] Out-of-order declarations work
- [ ] No false errors on valid code

**Phase 30C Completion Criteria**:
- [ ] All medium-priority features complete
- [ ] Advanced generic libraries checkable
- [ ] RTTI edge cases handled
- [ ] Declaration ordering robust

**Deliverables**:
- Compile-time value parameters ($N)
- Complete type alias support
- Robust declaration processing

---

## Phase 30D: Polish & Feature Parity (Estimated: 1.5 weeks, 470 LOC)

**Goal**: 100% C++ feature parity and production readiness

**Why This Phase**:
- **Completeness**: All features implemented
- **Platform Support**: Cross-platform correctness
- **Production Ready**: No known limitations

### Group 1: Parameter Flags (200 LOC)

**Files**:
- check_type.odin (200 LOC)

**Implementation Tasks**:

1. **[B2] Implement #no_alias** (40 LOC)
   - Location: check_type.odin:2012-2014
   - Current: `error(tag.pos, "#no_alias not yet supported")`
   - C++ Reference: check_type.cpp:2240-2251

2. **[B4] Implement #const** (40 LOC)
   - Location: check_type.odin:2020-2022
   - Current: `error(tag.pos, "#const not yet supported")`
   - C++ Reference: check_type.cpp:2281-2295

3. **[B5] Implement #by_ptr** (40 LOC)
   - Location: check_type.odin:2024-2026
   - Current: `error(tag.pos, "#by_ptr not yet supported")`
   - C++ Reference: check_type.cpp:2297-2311

4. **[B6] Implement #no_broadcast** (40 LOC)
   - Location: check_type.odin:2028-2030
   - Current: `error(tag.pos, "#no_broadcast not yet supported")`
   - C++ Reference: check_type.cpp:2313-2327

5. **[B7] Implement #no_capture** (40 LOC)
   - Location: check_type.odin:2032-2034
   - Current: `error(tag.pos, "#no_capture not yet supported")`
   - C++ Reference: check_type.cpp:2329-2343

**C++ References**:
- check_type.cpp:2240-2343 (all parameter flags)

**Verification Criteria**:
- [ ] All parameter flags accepted
- [ ] Flags validated correctly
- [ ] No regressions on existing code

### Group 2: RTTI Completion (140 LOC)

**Files**:
- type_info.odin (140 LOC)
- types.odin (helper additions)

**Implementation Tasks**:

1. **[E1] Implement Union Tag Helpers** (60 LOC)
   - Location: type_info.odin:305
   - Current: TODO "Implement union_tag_size and union_tag_type"
   - Action: Calculate tag size and type for union RTTI
   - C++ Reference: check_type.cpp:8723-8789
   - Dependencies: None

2. **[E2] Implement SOA Struct RTTI** (80 LOC)
   - Location: type_info.odin:334-344
   - Current: TODO "Handle SOA variants in type info"
   - Action: Generate type info for #soa struct layouts
   - C++ Reference: check_type.cpp:8834-8912
   - Dependencies: None

**C++ References**:
- check_type.cpp:8723-8789 (union tags)
- check_type.cpp:8834-8912 (SOA)

**Verification Criteria**:
- [ ] Union type info complete
- [ ] SOA type info complete
- [ ] RTTI works for all type kinds

### Group 3: Platform Features (120 LOC)

**Files**:
- check_builtin.odin (90 LOC)
- check_decl.odin (30 LOC)

**Implementation Tasks**:

1. **[F2] Implement Objective-C Platform Checks** (90 LOC)
   - Locations: check_builtin.odin:993, 1111, 1162
   - Current: TODO "Platform check - objc only works on darwin"
   - Action: Error if Objective-C builtins used on non-Darwin platforms
   - C++ Reference: check_builtin.cpp:1047-1063
   - Dependencies: None

2. **[F1] Implement @(thread_local) Validation** (30 LOC)
   - Location: check_decl.odin:304
   - Current: Commented out validation
   - Action: Validate thread_local on supported platforms
   - C++ Reference: check_decl.cpp:423-447
   - Dependencies: None

**C++ References**:
- check_builtin.cpp:1047-1063 (Objective-C)
- check_decl.cpp:423-447 (thread_local)

**Verification Criteria**:
- [ ] Objective-C errors on non-Darwin
- [ ] thread_local validated
- [ ] Platform-specific code correct

### Group 4: Workflow Integration (10 LOC)

**Files**:
- check_files.odin or main workflow (10 LOC)

**Implementation Tasks**:

1. **[D2] Activate Deferred Procedure Validation** (10 LOC)
   - Location: Main workflow (check_files when implemented)
   - Current: check_deferred.odin exists (Phase 26, 70% complete) but not called
   - Action: Integrate deferred procedure validation into main checking workflow
   - Call producer/consumer validation after entity checking
   - C++ Reference: checker.cpp:5823-5847
   - Dependencies: check_files implementation

**C++ References**:
- checker.cpp:5823-5847 (workflow integration)

**Verification Criteria**:
- [ ] @(deferred_in/out) attributes validated
- [ ] Deferred procedure errors detected

**Phase 30D Completion Criteria**:
- [ ] All features implemented
- [ ] 100% C++ feature parity
- [ ] All edge cases handled
- [ ] Platform-specific code correct
- [ ] Production ready
- [ ] Zero known limitations

**Deliverables**:
- All parameter flags working
- Complete RTTI for all types
- Platform-specific validation
- Full workflow integration

---

## Summary

| Phase | LOC | Time | Deliverable |
|-------|-----|------|-------------|
| 30A: Critical Blockers | 1,150 | 2 weeks | Real-world code checkable |
| 30B: High Priority | 330 | 1 week | C FFI + common features |
| 30C: Medium Priority | 261 | 1 week | Advanced generics + edge cases |
| 30D: Polish | 470 | 1.5 weeks | 100% feature parity |
| **TOTAL** | **2,211** | **5.5 weeks** | **Production ready** |

## Critical Path

1. **30A Group 1** → 30A Group 2, 30A Group 3 (parallel)
2. **30A Complete** → 30B Group 1 (depends on A2)
3. **30B Complete** → 30C, 30D (parallel possible)

## Force Multipliers

1. **A6 (Type Binding)** - 80 LOC unlocks A1, C2, C3
2. **A2 (Variadic)** - 200 LOC unlocks A4
3. **Phase 24 Viral Flags** - 200 LOC fixes all control flow

## Risk Assessment

- **Low Risk**: 30B, 30D (straightforward implementations)
- **Medium Risk**: 30A Group 1, 30C (polymorphism complexity)
- **High Risk**: None (infrastructure exists)
