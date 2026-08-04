package linkpfx

foreign import lib "system:c"

// inherited prefix + own link_name -> ACCEPTED (prefix dropped)
@(link_prefix="CF", default_calling_convention="c")
foreign lib {
	@(link_name="__CFMakeThing")
	MakeThing :: proc(x: i32) -> i32 ---

	// no link_name: inherited prefix still applies
	OtherThing :: proc(x: i32) -> i32 ---
}

// prefix and link_name on the SAME declaration -> genuine conflict, still REJECTED
@(default_calling_convention="c")
foreign lib {
	@(link_prefix="XX", link_name="__both")
	BothOnOne :: proc(x: i32) -> i32 ---
}

// same for suffix
@(link_suffix="_v2", default_calling_convention="c")
foreign lib {
	@(link_name="__CFSuffixed")
	Suffixed :: proc(x: i32) -> i32 ---
}

main :: proc() {
	_ = MakeThing(1)
	_ = OtherThing(2)
	_ = BothOnOne(3)
	_ = Suffixed(4)
}
