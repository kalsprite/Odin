package main
b_proc :: proc() {}
@(deferred_none=b_proc)
a_proc :: proc() {}
main :: proc() { a_proc() }
