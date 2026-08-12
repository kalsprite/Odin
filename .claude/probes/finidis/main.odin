package finidis

@(init, disabled=true)
setup :: proc "contextless" () {}     // C++ DOES warn for init

@(fini, disabled=true)
teardown :: proc "contextless" () {}  // C++ has no fini disabled-warning

main :: proc() {}
