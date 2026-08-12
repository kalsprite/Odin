package p
B :: bit_set[0..<8]
main :: proc() {
  a, b: B
  c := a - b
  _ = c
}
