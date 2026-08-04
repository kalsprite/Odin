package bitsetrange_bad
S :: bit_set[0..<8; u8]
T :: bit_set[0..<9; u8]
U :: bit_set['a'..='z']
main :: proc() { _ = S{}; _ = T{}; _ = U{} }
