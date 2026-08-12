package sel288
T :: struct { field: int }
main :: proc() {
	t: T
	t->field()          // C++ check_stmt.cpp:2452 -- selector-call whose proc is not a procedure
}
