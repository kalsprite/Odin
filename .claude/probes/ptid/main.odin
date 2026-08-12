package ptid

// C++ check_comparison folds `Type == constant-typeid` to an untyped_bool CONSTANT.
// If the port leaves it Addressing_Value, #assert cannot accept it.
#assert(int == typeid_of(int))
#assert(int != typeid_of(f32))

main :: proc() {}
