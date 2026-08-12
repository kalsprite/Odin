package main
c_proc :: proc() {}
@(deferred_none=c_proc)
b_proc :: proc() {}
@(deferred_none=b_proc)
a_proc :: proc() {}
main :: proc() { a_proc() }
