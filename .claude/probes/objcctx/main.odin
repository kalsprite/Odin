package objcctx

provider :: proc "contextless" () -> ^int { return nil }

// exercises procs_with_objc_context_provider_to_check, whose producer only became
// reachable once @(objc_implement) was recognised (#283)
@(objc_class="NSCtx", objc_implement, objc_context_provider=provider)
Ctx :: struct {}

main :: proc() {}
