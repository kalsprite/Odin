package u288
T :: struct { a: int }
main :: proc() {
	using _: T          // C++ check_stmt.cpp:2373 -- 'using' on a blank-named variable
}
