
Checking Odin:

`odin check . -vet -strict-style -no-entry-point`

Do not make git commits, we want to get the AST modifiactions fully working prior to commiting.

The checker is in the final stretch.. do not implement 'simplified' versions of functions. The objective is to reach 100% parity for semantic analysis with the C++ checker, including multi-threaded operation.