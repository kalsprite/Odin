package dupdefault

Val :: union { int, string }

main :: proc() {
	x := 1
	switch x {          // value switch: C++ check_stmt.cpp:1201
	case 1:
	case:
	case:
	}

	v: Val = 1
	switch t in v {     // type switch: C++ check_stmt.cpp:1478
	case int:
	case:
	case:
	}
}
