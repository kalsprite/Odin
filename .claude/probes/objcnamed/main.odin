package objcnamed

// superclass is not a named type at all -> C++ check 1
@(objc_class="C", objc_implement, objc_superclass=int)
C :: struct {}

main :: proc() {}
