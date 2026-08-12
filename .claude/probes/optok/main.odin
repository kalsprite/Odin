package optok

// unnamed second return, not boolean
f1 :: proc() -> (int, int) #optional_ok { return 0, 0 }

// NAMED second return, not boolean -- the anchor difference should be clearest here
f2 :: proc() -> (v: int, ok: rune) #optional_ok { return 0, 0 }

main :: proc() {}
