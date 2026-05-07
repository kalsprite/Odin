# Bug: complex()/quaternion() type inference panic in union return context

**Location:** src/types.cpp:1863 (`base_complex_elem_type`)

## Minimal Reproduction

```odin
package repro

Value :: union {
	bool,
	f64,
	complex128,
}

make_complex :: proc(r, i: f64) -> Value {
	return complex(r, i)  // PANIC
}

main :: proc() {
	_ = make_complex(1.0, 2.0)
}
```

```
$ odin build repro.odin -file
src/types.cpp(1863): Panic: Invalid complex type
```

## Root Cause

In `lb_build_builtin_proc` (llvm_backend_proc.cpp:2370), when building `BuiltinProc_complex`:
```cpp
Type *ft = base_complex_elem_type(tv.type);
```

`tv.type` is inferred as the union type instead of `complex128`.

## Workaround

```odin
make_complex :: proc(r, i: f64) -> Value {
	c: complex128 = complex(r, i)
	return c  // OK
}
```
