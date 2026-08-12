package objcctx2

import "base:runtime"

Ctx :: struct {}

// signature C++ accepts: single pointer-to-self param, returns a context, contextless
provider :: proc "contextless" (self: ^Ctx) -> runtime.Context { return {} }

@(objc_class="NSCtx", objc_implement, objc_context_provider=provider)
Ctx2 :: struct {}

main :: proc() {}
