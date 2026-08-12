package main

main :: proc() {
	arr: [dynamic]int
	shrink(&arr)
	shrink(&arr, 2)
	m: map[int]int
	shrink(&m)
}
