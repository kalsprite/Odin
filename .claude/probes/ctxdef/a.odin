package ctxdef
set_context :: proc(ctx := context) { _ = ctx }
main :: proc() { set_context() }
