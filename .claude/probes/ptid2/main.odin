package ptid2
T :: typeid_of(int)          // a CONSTANT typeid declaration
#assert(int == T)            // Type vs constant-typeid -> C++ folds to constant true
V := int == T                // non-assert form, always legal
main :: proc() { _ = V }
