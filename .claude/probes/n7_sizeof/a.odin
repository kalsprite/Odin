package n7_sizeof
main :: proc() {
  x := 42
  n := size_of(&x)
  _ = n
}
