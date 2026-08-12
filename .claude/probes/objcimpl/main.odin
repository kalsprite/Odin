package objcimpl

Plain :: struct {}

// WITH objc_implement: C++ runs the whole superclass validation chain
@(objc_class="NSPlainSub", objc_implement, objc_superclass=Plain)
PlainSub :: struct {}

main :: proc() {}
