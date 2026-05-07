# Odin Directives and Attributes

*Extracted from: src/check_expr.cpp, src/checker.cpp, src/check_type.cpp*

## 1. Hash Directives

Hash directives (`#name`) modify declarations, types, or expressions.

### 1.1 Compile-Time Constants

| Directive | Context | Description |
|-----------|---------|-------------|
| `#file` | Expression | Current source file path (string) |
| `#directory` | Expression | Directory of current source file (string) |
| `#line` | Expression | Current source line number (int) |
| `#procedure` | Expression | Current procedure name (string) |

### 1.2 Location Directives

| Directive | Context | Description |
|-----------|---------|-------------|
| `#location()` | Call | Source_Code_Location of call site |
| `#caller_location` | Default param | Location of caller |
| `#caller_expression(param)` | Default param | String of caller's argument expression |
| `#branch_location` | In defer | Location where defer was triggered |

### 1.3 Compile-Time Evaluation

| Directive | Context | Description |
|-----------|---------|-------------|
| `#assert(cond)` | Statement | Compile-time assertion |
| `#assert(cond, msg)` | Statement | Compile-time assertion with message |
| `#config(name, default)` | Expression | Build configuration value |
| `#defined(ident)` | Expression | Check if identifier is defined |
| `#exists(path)` | Expression | Check if file exists (bool) |

### 1.4 File Loading

| Directive | Context | Description |
|-----------|---------|-------------|
| `#load(path)` | Expression | Load file contents as []u8 |
| `#load(path, T)` | Expression | Load file as type T |
| `#load_hash(path)` | Expression | Load file and return hash |
| `#load_or(path, default)` | Expression | Load or return default |
| `#load_directory(path)` | Expression | Load directory listing |

### 1.5 Struct Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#packed` | Struct | No padding between fields |
| `#raw_union` | Struct | All fields share same memory |
| `#align(N)` | Struct | Custom alignment |
| `#min_field_align(N)` | Struct | Minimum field alignment |
| `#max_field_align(N)` | Struct | Maximum field alignment |
| `#all_or_none` | Struct | Must assign all or no fields |

### 1.6 Union Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#no_nil` | Union | Union cannot be nil (requires ≥2 variants) |
| `#shared_nil` | Union | Variants share nil representation |
| `#align(N)` | Union | Custom alignment |

### 1.7 Procedure Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#force_inline` | Proc | Always inline |
| `#force_no_inline` | Proc | Never inline |
| `#optional_ok` | Proc type | Second return is optional bool |
| `#optional_allocator_error` | Proc type | Second return is optional Allocator_Error |

### 1.8 Control Flow Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#partial` | switch | Allow non-exhaustive enum/union switch |
| `#reverse` | for | Iterate in reverse order |
| `#unroll` | for | Unroll loop at compile time |
| `#unroll(N)` | for | Unroll loop N times |

### 1.9 Type Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#soa` | Array/Struct | Structure of Arrays layout |
| `#simd` | Array | SIMD vector type |
| `#type` | Expression | Force type interpretation |

### 1.10 Pointer Modifiers

| Directive | Context | Description |
|-----------|---------|-------------|
| `#soa ^T` | Pointer | SOA pointer type |

---

## 2. Parameter/Field Flags

Applied to procedure parameters or struct fields.

### 2.1 Procedure Parameters

| Flag | Applies To | Description |
|------|------------|-------------|
| `#no_alias` | Pointers | Pointer doesn't alias other params |
| `#any_int` | Integers | Accept any integer type |
| `#by_ptr` | Non-pointers | Pass by pointer implicitly |
| `#c_vararg` | Last param | C-style variadic (foreign only) |
| `#const` | Any | Compile-time constant required |
| `#no_broadcast` | Arrays/SIMD | Don't allow scalar broadcast |
| `#no_capture` | Pointers | Pointer won't be stored (reserved) |
| `#subtype` | Subtypes | Explicit subtype parameter |

### 2.2 Struct Fields

| Flag | Applies To | Description |
|------|------------|-------------|
| `using` | Fields | Promote field's members |

---

## 3. Attributes

Attributes (`@(name)` or `@(name=value)`) provide metadata.

### 3.1 Procedure Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(init)` | - | Run at program startup |
| `@(fini)` | - | Run at program shutdown |
| `@(export)` | bool | Export symbol |
| `@(linkage)` | string | Symbol linkage type |
| `@(link_name)` | string | Custom link name |
| `@(link_prefix)` | string | Prefix for link name |
| `@(link_suffix)` | string | Suffix for link name |
| `@(require)` | bool | Always include in binary |
| `@(require_results)` | - | Caller must use return values |
| `@(deprecated)` | string | Mark as deprecated with message |
| `@(disabled)` | bool | Disable procedure |
| `@(cold)` | - | Mark as unlikely to be called |
| `@(optimization_mode)` | string | "none", "minimal", "size", "speed" |
| `@(test)` | - | Mark as test procedure |
| `@(private)` | - | Package-private (file scope only) |
| `@(private="file")` | - | File-private |

### 3.2 Deferred Procedure Attributes

| Attribute | Description |
|-----------|-------------|
| `@(deferred)` | Call after scope exits |
| `@(deferred_none)` | Call with no arguments |
| `@(deferred_in)` | Call with input arguments |
| `@(deferred_out)` | Call with output arguments |
| `@(deferred_in_out)` | Call with both in/out |
| `@(deferred_in_by_ptr)` | Call with input by pointer |
| `@(deferred_out_by_ptr)` | Call with output by pointer |
| `@(deferred_in_out_by_ptr)` | Call with both by pointer |

### 3.3 Variable Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(static)` | - | Static storage duration |
| `@(thread_local)` | string | Thread-local storage (model) |
| `@(rodata)` | - | Place in read-only data section |
| `@(link_section)` | string | Custom link section |
| `@(export)` | bool | Export symbol |
| `@(linkage)` | string | Symbol linkage type |
| `@(link_name)` | string | Custom link name |
| `@(link_prefix)` | string | Prefix for link name |
| `@(link_suffix)` | string | Suffix for link name |
| `@(require)` | bool | Always include in binary |

### 3.4 Type Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(private)` | - | Package-private |
| `@(private="file")` | - | File-private |

### 3.5 Foreign Block Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(default_calling_convention)` | string | Default CC for block |
| `@(link_prefix)` | string | Prefix for all symbols |
| `@(link_suffix)` | string | Suffix for all symbols |
| `@(private)` | - | All symbols private |
| `@(require_results)` | - | All procs require results |

### 3.6 Objective-C Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(objc_class)` | string | ObjC class name |
| `@(objc_name)` | string | ObjC method name |
| `@(objc_is_class_method)` | bool | Class method vs instance |
| `@(objc_type)` | type | ObjC type |
| `@(objc_implement)` | - | Implement ObjC class |
| `@(objc_selector)` | string | ObjC selector |
| `@(objc_superclass)` | type | ObjC superclass |
| `@(objc_ivar)` | - | ObjC instance variable |
| `@(objc_context_provider)` | - | Context provider |

### 3.7 Target Feature Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(require_target_feature)` | string | Require CPU feature |
| `@(enable_target_feature)` | string | Enable CPU feature |

### 3.8 Instrumentation Attributes

| Attribute | Description |
|-----------|-------------|
| `@(instrumentation_enter)` | Entry instrumentation hook |
| `@(instrumentation_exit)` | Exit instrumentation hook |
| `@(no_instrumentation)` | Skip instrumentation |

### 3.9 Sanitizer Attributes

| Attribute | Description |
|-----------|-------------|
| `@(no_sanitize_address)` | Disable ASAN |
| `@(no_sanitize_memory)` | Disable MSAN |

### 3.10 Debugging Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(raddbg_type_view)` | string | RAD debugger type view |

### 3.11 Foreign Import Attributes

| Attribute | Value | Description |
|-----------|-------|-------------|
| `@(require)` | bool | Always link library |
| `@(export)` | bool | Re-export library |
| `@(force)` | - | Force link |
| `@(priority_index)` | int | Link order priority |
| `@(extra_linker_flags)` | string | Additional linker flags |
| `@(ignore_duplicates)` | - | Ignore duplicate symbols |

### 3.12 Custom Attributes

Custom attributes can be used with build flags:
- `-ignore-unknown-attributes` - Ignore all unknown attributes
- `-custom-attribute:name` - Allow specific custom attribute

Access custom attributes via reflection at runtime.

---

## 4. Spread Operator

### 4.1 Array/Slice Spread (`..`)

Expand array or slice elements:

```odin
arr := [3]int{1, 2, 3}
call(..arr)  // Expands to call(1, 2, 3)
```

### 4.2 Struct Spread

Expand struct fields in initialization:

```odin
Point :: struct { x, y: int }
p1 := Point{1, 2}
p2 := Point{..p1, y = 10}  // x=1, y=10
```

---

## 5. Range Operators

| Operator | Meaning | Example |
|----------|---------|---------|
| `..` | Exclusive upper (legacy) | `0..10` = 0 to 9 |
| `..<` | Exclusive upper | `0..<10` = 0 to 9 |
| `..=` | Inclusive | `0..=10` = 0 to 10 |

---

## 6. Directive Restrictions

### 6.1 Location Context Restrictions

| Directive | Valid Context |
|-----------|---------------|
| `#caller_location` | Default parameter only |
| `#caller_expression` | Default parameter only |
| `#branch_location` | Inside `defer` only |
| `#procedure` | Inside procedure only |

### 6.2 Struct Directive Conflicts

- `#packed` conflicts with `#align`, `#min_field_align`, `#max_field_align`
- `#min_field_align(N)` must be ≤ `#max_field_align(M)`
- `#align(N)` must be between min and max field align

### 6.3 Union Directive Requirements

- `#no_nil` requires at least 2 variants
- `#shared_nil` requires all variants to have nil value

### 6.4 Parameter Flag Restrictions

| Flag | Restriction |
|------|-------------|
| `#c_vararg` | Last parameter only, foreign procs only |
| `#no_alias` | Pointer/multi-pointer types only |
| `#by_ptr` | Non-pointer types only |
| `#any_int` | Integer types only |
| `#no_capture` | Pointer-like types only (reserved) |

---

## 7. Attribute Value Types

| Expected Type | Example |
|---------------|---------|
| None | `@(init)` |
| Boolean | `@(export)`, `@(export=true)`, `@(export=false)` |
| String | `@(link_name="foo")` |
| Integer | `@(priority_index=10)` |
| Type | `@(objc_type=MyClass)` |
