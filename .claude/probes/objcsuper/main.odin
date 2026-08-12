package objcsuper

@(objc_class="NSBase")
Base :: struct {}

// superclass is not a named struct
@(objc_class="NSBad", objc_superclass=int)
Bad :: struct {}

// superclass is a named struct but not an Objective-C class
Plain :: struct {}

@(objc_class="NSPlainSub", objc_superclass=Plain)
PlainSub :: struct {}

main :: proc() {}
