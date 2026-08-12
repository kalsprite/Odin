package nontype

import "core:mem"

gv := 1
GC :: 7

// Ident in type position, resolving to a VALUE -> C++ ident default arm
a: gv
b: GC
// Selector in type position, resolving to a VALUE -> C++ selector default arm
c: mem.zero

main :: proc() {}
