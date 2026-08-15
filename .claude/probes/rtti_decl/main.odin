package rtti_decl

// #823. `-bedrock` implies `no_rtti`, and check_rtti_type_disallowed then rejects `any`.
// C++ has THREE call sites; the port had two. The missing one was the EXPRESSION path
// (check_expr.cpp:12806, "An expression is using a type, %s, which has been disallowed"),
// so before the fix the port emitted 1 error here where the oracle emits 2.
//
// This probe cannot live in corpus.sh: members there run plain `odin build` with no
// `-bedrock`, so `no_rtti` is false and the guard cannot fire. That is exactly why 326 green
// corpus probes and two 323-package parity sweeps never saw the defect.
//
// `v` is assigned to `_` so nothing here depends on require_results (crosstarget.sh's trap 2).
main :: proc() { v: any; _ = v }
