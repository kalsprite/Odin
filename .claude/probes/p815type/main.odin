package p815type

// #815: @(deprecated) on a TYPE never warned -- e.deprecated_message was copied only on the
// PROCEDURE path (check_decl.odin), never in check_type_decl. C++ copies it in BOTH
// (check_decl.cpp:524). The attribute was collected and the warning emitter was complete; only
// the copy was missing, so the symptom was SILENCE. No other corpus member puts @(deprecated)
// on a type, which is why 324 green probes and two 323/323 parity sweeps all missed it.
@(deprecated="use Bar instead")
Foo :: struct { x: int }

grab :: proc() -> Foo { return Foo{} }

main :: proc() { _ = grab() }
