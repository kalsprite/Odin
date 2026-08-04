# Compiler segfaults on `@(objc_context_provider)` with a zero-parameter provider

**Component:** `src/` (Objective-C attribute checking)
**Severity:** **crash** — compiler dumps core, no diagnostic
**Status:** reproduced 3/3 on 2026-08-04 (and 6/6 when first found)

## Reproduction

`main.odin`:

```odin
package objcctx

provider :: proc "contextless" () -> ^int { return nil }

@(objc_class="NSCtx", objc_implement, objc_context_provider=provider)
Ctx :: struct {}

main :: proc() {}
```

```
$ odin check . -no-entry-point
<no output>
$ echo $?           # process terminated by signal; core dumped
```

Observed with `timeout` reporting `the monitored command dumped core`, 3 runs out of 3.

## What is wrong

The provider procedure takes **no parameters**. The checking path for
`objc_context_provider` appears to read the provider's first parameter without first
verifying that one exists, and dereferences past the end of an empty parameter tuple.

The expected behaviour is a diagnostic naming the constraint — something in the shape of the
other attribute-validation errors, e.g. *"'objc_context_provider' procedure must take a
`^Context` parameter"* — not a crash.

## Notes

- The crash is in the **checker**, before code generation: `odin check` alone is enough.
- A zero-parameter provider is a plausible user mistake, not a contrived input; the attribute
  form is otherwise well-formed and the class attributes around it are valid.
- A self-hosted Odin checker run over the same source rejects it with a diagnostic and exits
  normally, which is how the crash was isolated: the two compilers disagreed by one of them
  dying.

## Related

Filed alongside the objc attribute crashes tracked as `#161` in the porting notes (three objc
attributes reported as crashing when written without a value). Those need their own
reproductions re-established before filing — see `UPSTREAM-STATUS.md`.
