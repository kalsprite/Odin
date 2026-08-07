#+feature using-stmt
package expprobe

@(export)
exported_var: int

@(export)
exported_proc :: proc() {}

plain_proc :: proc() {}

foreign import libc_stub "system:c"
@(default_calling_convention="c")
foreign libc_stub {
	some_foreign_proc :: proc(x: i32) -> i32 ---
}

// ---- #480: declarations added to exercise the remaining reachable flag bits ----------------
// Each is here to light up ONE bit that the five real packages docflag.sh sweeps do not reach.
// A bit that still does not appear after this is a genuine gap, not merely unexercised.

@(thread_local)
tl_var: int                        // -> Var_Thread_Local

@(private)
private_var: int                   // -> Private

Bits :: bit_field u32 {            // -> Bit_Field_Field (on the FIELDS)
	lo: u32 | 4,
	hi: u32 | 4,
}

Pt :: struct { x, y: int }

using_param :: proc(using p: Pt) -> int { return x + y }   // -> Param_Using

by_ptr_param :: proc(#by_ptr p: Pt) -> int { return p.x }  // -> Param_By_Ptr

// #508: `$N: int` is a POLYMORPHIC constant, which is not what Param_Const reads. Both C++
// (check_type.cpp:2362) and the port (check_type.odin:5224) set the flag from FieldFlag_const,
// i.e. the `#const` field directive. The original probe declared the wrong construct and the bit
// stayed absent, which read as a possible dead bit rather than a bad probe.
const_param :: proc(#const n: int) -> int { return n }     // -> Param_Const

static_local :: proc() -> int {
	@(static) counter: int         // -> Var_Static
	counter += 1
	return counter
}
