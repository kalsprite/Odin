package checker

/*
Exact value conversion and support functions.

This module implements compile-time constant type conversions, type promotion,
and component extraction following the Odin compiler's exact value system.

Ported from /mnt/c/odin/src/exact_value.cpp
*/

import "core:fmt"
import "core:hash"
import "core:math"
import "core:math/big"
import "core:odin/ast"
import "core:odin/tokenizer"
import "core:strconv"
import "core:strings"
import "core:unicode/utf8"

// ======================================================================================
// TYPE CONVERSION FUNCTIONS
// C++ Reference: exact_value.cpp:396-517
// ======================================================================================

// exact_value_to_integer converts an exact value to integer if possible
// C++ Reference: exact_value.cpp:396-421
exact_value_to_integer :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch val in v {
	case bool:
		// C++ line 398-403: Convert bool to BigInt (false=0, true=1)
		result: big.Int
		big.internal_int_set_from_integer(&result, i64(1) if val else i64(0), false)
		return result

	case big.Int:
		// C++ line 405-406: Already an integer
		return v

	case f64:
		// C++ line 407-413: Convert float if it's a whole number
		i := i64(val)
		f := f64(i)
		if f == val {
			result: big.Int
			big.internal_int_set_from_integer(&result, i, false)
			return result
		}
		// Not a whole number, return invalid
		return nil

	case Exact_Value_Pointer:
		// C++ line 416-417: Convert pointer to integer
		result: big.Int
		big.internal_int_set_from_integer(&result, val.address, false)
		return result
	}

	// C++ line 419: Invalid for complex, quaternion, procedure, typeid, compound, string
	return nil
}

// exact_value_to_float converts an exact value to float if possible
// C++ Reference: exact_value.cpp:423-432
exact_value_to_float :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch _ in v {
	case big.Int:
		// C++ line 425-426: Convert BigInt to f64 using big_int_to_f64
		temp := v.(big.Int)
		f, err := big.int_get_float(&temp)
		if err != nil {
			return nil
		}
		return f

	case f64:
		// C++ line 427-428: Already a float
		return v
	}

	// C++ line 430: Invalid for non-numeric types
	return nil
}

// exact_value_to_complex converts an exact value to complex if possible
// C++ Reference: exact_value.cpp:434-448
exact_value_to_complex :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch _ in v {
	case big.Int:
		// C++ line 436-437: Promote integer to complex with zero imaginary part
		temp := v.(big.Int)
		f, err := big.int_get_float(&temp)
		if err != nil {
			return nil
		}
		// Explicit type to avoid compiler bug with complex() in union return context
		c: complex128 = complex(f, 0)
		return c

	case f64:
		// C++ line 438-439: Promote float to complex with zero imaginary part
		f := v.(f64)
		c: complex128 = complex(f, 0)
		return c

	case complex128:
		// C++ line 440-441: Already complex
		return v
	}

	// C++ line 445: Invalid for quaternion, pointer, procedure, typeid, compound
	return nil
}

// exact_value_to_quaternion converts an exact value to quaternion if possible
// C++ Reference: exact_value.cpp:449-463
exact_value_to_quaternion :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch _ in v {
	case big.Int:
		// C++ line 451-452: Promote integer to quaternion (real component only)
		temp := v.(big.Int)
		f, err := big.int_get_float(&temp)
		if err != nil {
			return nil
		}
		// Explicit type to avoid compiler bug with quaternion() in union return context
		q: quaternion256 = quaternion256(quaternion(real = f, imag = 0, jmag = 0, kmag = 0))
		return q

	case f64:
		// C++ line 453-454: Promote float to quaternion (real component only)
		f := v.(f64)
		q: quaternion256 = quaternion256(quaternion(real = f, imag = 0, jmag = 0, kmag = 0))
		return q

	case complex128:
		// C++ line 455-456: Promote complex to quaternion (real and imag components)
		c := v.(complex128)
		q: quaternion256 = quaternion256(quaternion(real = real(c), imag = imag(c), jmag = 0, kmag = 0))
		return q

	case quaternion256:
		// C++ line 457-458: Already quaternion
		return v
	}

	// C++ line 460: Invalid for pointer, procedure, typeid, compound
	return nil
}

// ======================================================================================
// COMPONENT EXTRACTION FUNCTIONS
// C++ Reference: exact_value.cpp:465-517
// ======================================================================================

// exact_value_real extracts the real component
// C++ Reference: exact_value.cpp:465-477
exact_value_real :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch val in v {
	case big.Int, f64:
		// C++ line 467-469: Integer and float are already real
		return v

	case complex128:
		// C++ line 470-471: Extract real part of complex
		return real(val)

	case quaternion256:
		// C++ line 472-473: Extract real part of quaternion
		return real(val)
	}

	// C++ line 475: Invalid for other types
	return nil
}

// exact_value_imag extracts the imaginary (i) component
// C++ Reference: exact_value.cpp:479-491
exact_value_imag :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch val in v {
	case big.Int, f64:
		// C++ line 481-483: Integer/float have zero imaginary part
		result: big.Int
		big.internal_int_set_from_integer(&result, i64(0), false)
		return result

	case complex128:
		// C++ line 484-485: Extract imaginary part of complex
		return imag(val)

	case quaternion256:
		// C++ line 486-487: Extract i component of quaternion
		return imag(val)
	}

	// C++ line 489: Invalid for other types
	return nil
}

// exact_value_jmag extracts the j component (quaternion only)
// C++ Reference: exact_value.cpp:493-504
exact_value_jmag :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch val in v {
	case big.Int, f64, complex128:
		// C++ line 495-498: Non-quaternion types have zero j component
		result: big.Int
		big.internal_int_set_from_integer(&result, i64(0), false)
		return result

	case quaternion256:
		// C++ line 499-500: Extract j component of quaternion
		return jmag(val)
	}

	// C++ line 502: Invalid for other types
	return nil
}

// exact_value_kmag extracts the k component (quaternion only)
// C++ Reference: exact_value.cpp:506-517
exact_value_kmag :: proc(v: Exact_Value) -> Exact_Value {
	#partial switch val in v {
	case big.Int, f64, complex128:
		// C++ line 508-511: Non-quaternion types have zero k component
		result: big.Int
		big.internal_int_set_from_integer(&result, i64(0), false)
		return result

	case quaternion256:
		// C++ line 512-513: Extract k component of quaternion
		return kmag(val)
	}

	// C++ line 515: Invalid for other types
	return nil
}

// exact_value_to_i64 converts exact value to i64
// C++ Reference: exact_value.cpp:558-564
exact_value_to_i64 :: proc(v: Exact_Value) -> i64 {
	int_val := exact_value_to_integer(v)
	if int_val == nil {
		return 0
	}
	if bi, ok := int_val.(big.Int); ok {
		result, err := big.int_get_i64(&bi)
		if err != nil {
			return 0
		}
		return result
	}
	return 0
}

// exact_value_to_u64 converts exact value to u64
// C++ Reference: exact_value.cpp:565-571
exact_value_to_u64 :: proc(v: Exact_Value) -> u64 {
	int_val := exact_value_to_integer(v)
	if int_val == nil {
		return 0
	}
	if bi, ok := int_val.(big.Int); ok {
		result, err := big.int_get_u64(&bi)
		if err != nil {
			return 0
		}
		return result
	}
	return 0
}

// exact_value_to_f64 converts exact value to f64
// C++ Reference: exact_value.cpp:572-578
exact_value_to_f64 :: proc(v: Exact_Value) -> f64 {
	float_val := exact_value_to_float(v)
	if float_val == nil {
		return 0.0
	}
	if f, ok := float_val.(f64); ok {
		return f
	}
	return 0.0
}

// exact_value_to_bool extracts boolean value from an exact value
// C++ Reference: Used implicitly in checker.cpp:5563, 5602 (operand.value.kind == ExactValue_Bool && operand.value.value_bool)
// Checks if value is bool type and returns the boolean value
exact_value_to_bool :: proc(v: Exact_Value) -> bool {
	if b, ok := v.(bool); ok {
		return b
	}
	return false
}

// is_exact_value_zero checks if an exact value is zero
// C++ Reference: exact_value.cpp:580-610
is_exact_value_zero :: proc(v: Exact_Value) -> bool {
	if v == nil {
		return true
	}

	#partial switch val in v {
	case bool:
		return !val // false is considered zero
	case big.Int:
		// NOTE: big.is_zero needs a pointer, but `v` is passed by value, so the union payload
		// is not addressable. A local copy is equivalent here: any mutation the query performs
		// (clearing an uninitialized Int) was already being discarded through the by-value `v`.
		i := val
		is_zero, _ := big.is_zero(&i)
		return is_zero
	case f64:
		return val == 0.0
	case complex128:
		return real(val) == 0.0 && imag(val) == 0.0
	case quaternion256:
		return val.w == 0.0 && val.x == 0.0 && val.y == 0.0 && val.z == 0.0
	case string:
		return len(val) == 0
	case Exact_Value_Pointer:
		return val.address == 0
	}

	return false
}

// ======================================================================================
// EXACT VALUE CONSTRUCTORS
// C++ Reference: exact_value.cpp:132-187
// ======================================================================================

// exact_value_i64 creates an Exact_Value from i64
// C++ Reference: exact_value.cpp:132-137
exact_value_i64 :: proc(i: i64) -> Exact_Value {
	result: big.Int
	big.internal_int_set_from_integer(&result, i, false)
	return result
}

// exact_value_u64 creates an Exact_Value from u64
// C++ Reference: exact_value.cpp:139-144
exact_value_u64 :: proc(u: u64) -> Exact_Value {
	result: big.Int
	big.internal_int_set_from_integer(&result, u, false)
	return result
}

// exact_value_bool creates an Exact_Value from bool
// C++ Reference: exact_value.cpp:115-119
exact_value_bool :: proc(b: bool) -> Exact_Value {
	return b
}

// exact_value_float creates an Exact_Value from f64
// C++ Reference: exact_value.cpp:121-125
exact_value_float :: proc(f: f64) -> Exact_Value {
	return f
}

// exact_value_string creates an Exact_Value from string
// C++ Reference: exact_value.cpp:159-163
exact_value_string :: proc(s: string) -> Exact_Value {
	return s
}

// exact_value_typeid creates an Exact_Value for a typeid
// C++ Reference: /mnt/c/odin/src/exact_value.cpp:183-187
// Used by check_builtin_typeid_of to create compile-time typeid constants
exact_value_typeid :: proc(t: ^Type) -> Exact_Value {
	return Exact_Value_Typeid{type = t}
}

// ======================================================================================
// ARITHMETIC HELPER FUNCTIONS
// C++ Reference: exact_value.cpp:925-943
// ======================================================================================

// exact_value_sub subtracts two exact values
// C++ Reference: exact_value.cpp:928-930
exact_value_sub :: proc(x, y: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(.Sub, x, y)
}

// exact_value_increment_one increments exact value by 1
// C++ Reference: exact_value.cpp:941-943
exact_value_increment_one :: proc(x: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(.Add, x, exact_value_i64(1))
}

// exact_value_is_negative checks if an exact value is negative
// C++ Reference: big_int.cpp:318-322 (big_int_is_neg)
// Used in check_builtin.cpp:3036 for swizzle index validation
exact_value_is_negative :: proc(v: Exact_Value) -> bool {
	if v == nil {
		return false
	}
	if bi, ok := v.(big.Int); ok {
		return bi.sign == .Negative
	}
	if f, ok := v.(f64); ok {
		return f < 0
	}
	return false
}

// ======================================================================================
// BIG INTEGER OPERATIONS (Extended Operations)
// C++ Reference: big_int.cpp:400-492
// ======================================================================================

// big_int_euclidean_mod performs Euclidean modulo operation
// C++ Reference: big_int.cpp:400-413
big_int_euclidean_mod :: proc(z, x, y: ^big.Int) {
	// Euclidean mod: ensures result has same sign as divisor
	// C++ line 405: big_int_quo_rem(x, y, &q, z);
	q: big.Int
	defer big.int_destroy(&q)

	// Perform division and get remainder
	big.int_div(&q, x, y) // quotient
	big.int_mod(z, x, y) // remainder

	// C++ line 406-412: Adjust if remainder is negative
	if z.sign == .Negative {
		if y.sign == .Negative {
			// C++ line 408: big_int_sub(z, z, &y0);
			big.int_sub(z, z, y)
		} else {
			// C++ line 410: big_int_add(z, z, &y0);
			big.int_add(z, z, y)
		}
	}
}

// big_int_and performs bitwise AND on big integers
// C++ Reference: big_int.cpp:417-419 (uses mp_and from libtommath)
// Uses core:math/big.int_bit_and for 2's complement semantics
big_int_and :: proc(dst, x, y: ^big.Int) {
	err := big.int_bit_and(dst, x, y)
	if err != nil {
		// Fallback to 64-bit if library fails
		x_val, x_err := big.int_get_u64(x)
		y_val, y_err := big.int_get_u64(y)
		if x_err == nil && y_err == nil {
			result := x_val & y_val
			big.internal_int_set_from_integer(dst, result, false)
			return
		}
		panic("big_int_and: Bitwise AND operation failed")
	}
}

// big_int_or performs bitwise OR on big integers
// C++ Reference: big_int.cpp:489-491 (uses mp_or from libtommath)
// Uses core:math/big.int_bit_or for 2's complement OR
big_int_or :: proc(dst, x, y: ^big.Int) {
	err := big.int_bit_or(dst, x, y)
	if err != nil {
		// Fallback to 64-bit if library fails
		x_val, x_err := big.int_get_u64(x)
		y_val, y_err := big.int_get_u64(y)
		if x_err == nil && y_err == nil {
			result := x_val | y_val
			big.internal_int_set_from_integer(dst, result, false)
			return
		}
		panic("big_int_or: Bitwise OR operation failed")
	}
}

// big_int_xor performs bitwise XOR on big integers
// C++ Reference: big_int.cpp:484-486 (uses mp_xor from libtommath)
// Uses core:math/big.int_bit_xor for 2's complement XOR
big_int_xor :: proc(dst, x, y: ^big.Int) {
	err := big.int_bit_xor(dst, x, y)
	if err != nil {
		// Fallback to 64-bit if library fails
		x_val, x_err := big.int_get_u64(x)
		y_val, y_err := big.int_get_u64(y)
		if x_err == nil && y_err == nil {
			result := x_val ~ y_val
			big.internal_int_set_from_integer(dst, result, false)
			return
		}
		panic("big_int_xor: Bitwise XOR operation failed")
	}
}

// big_int_and_not performs bitwise AND-NOT (x & ~y) on big integers
// C++ Reference: big_int.cpp:421-482
// Computes x & ~y using complement and and operations
big_int_and_not :: proc(dst, x, y: ^big.Int) {
	// Compute ~y into a temp
	temp: big.Int
	defer big.int_destroy(&temp)

	err := big.int_bit_complement(&temp, y)
	if err != nil {
		// Fallback to 64-bit if library fails
		x_val, x_err := big.int_get_u64(x)
		y_val, y_err := big.int_get_u64(y)
		if x_err == nil && y_err == nil {
			result := x_val &~ y_val
			big.internal_int_set_from_integer(dst, result, false)
			return
		}
		panic("big_int_and_not: Bitwise AND-NOT operation failed")
	}

	// Compute x & temp
	err = big.int_bit_and(dst, x, &temp)
	if err != nil {
		panic("big_int_and_not: Bitwise AND operation failed")
	}
}

// big_int_not performs bitwise NOT on a big integer with precision
// C++ Reference: big_int.cpp:500-547 (uses mp_complement and masking)
// Uses core:math/big.int_bit_complement for 2's complement NOT
// The bit_count parameter specifies the fixed width for masking the result
big_int_not :: proc(dst, x: ^big.Int, bit_count: i32, is_signed: bool) {
	// For small bit counts, use direct computation for correctness
	if bit_count > 0 && bit_count <= 64 {
		// NOTE: read as SIGNED. int_get_u64 fails outright on a negative input, which sent every
		// `~x` where x < 0 down the arbitrary-precision path below.
		x_val, x_err := big.int_get_i64(x)
		if x_err == nil {
			// Mask for the bit count. Computed this way because `1 << 64` is not representable.
			mask: u64 = ~u64(0)
			if bit_count < 64 {
				mask = (u64(1) << uint(bit_count)) - 1
			}

			result := (~u64(x_val)) & mask

			// C++ Reference: big_int_not(dst, x, precision, signed) - the `signed` flag is what
			// makes the result wrap into the type rather than stay a bare magnitude.
			//
			// This function IGNORED is_signed and always stored the masked value as a positive
			// integer. `~i16(0x7fff)` therefore produced 32768 instead of -32768, and the caller's
			// check_is_expressible then reported "Numeric value '32768' from 'i16' cannot be
			// represented by 'i16'". core/c's whole INT*_MIN block is written as `~INT*_MAX`.
			if is_signed && (result & (u64(1) << uint(bit_count - 1))) != 0 {
				// Top bit set: two's-complement negative. Sign-extend into i64.
				signed_result := i64(result | ~mask)
				big.internal_int_set_from_integer(dst, signed_result, false)
			} else {
				big.internal_int_set_from_integer(dst, result, false)
			}
			return
		}
	}

	// Widths above 64 bits - i.e. i128/u128 - reach here.
	//
	// `int_bit_complement` alone is ARBITRARY-PRECISION two's complement: it turns 0 into -1 and
	// never masks to the type's width. So `~u128(0)` evaluated to -1 instead of 2^128-1, and the
	// caller's check_is_expressible then reported the self-contradictory
	// "Numeric value '-1' from 'u128' cannot be represented by 'u128'". base/runtime's i128
	// helpers are written with `~u128(0)` masks, so this reached every package that pulls the
	// runtime in - 338 of the 353 diagnostics in this class.
	//
	// C++'s big_int_not (big_int.cpp:500-547) complements and then masks to the precision. Do the
	// same arithmetically, which needs no bitwise ops on negative values:
	//
	//	mask   = 2^bit_count - 1
	//	folded = x mod 2^bit_count        (int_mod is Euclidean, so this is in [0, 2^bit_count))
	//	result = mask - folded            (== mask XOR folded for a value already inside the mask)
	//	if signed and the sign bit is set: result -= 2^bit_count
	if bit_count > 0 {
		two_n, mask, folded, res, one: big.Int
		defer big.destroy(&two_n, &mask, &folded, &res, &one)

		ok := true
		if err := big.internal_int_set_from_integer(&one, u64(1), false); err != nil { ok = false }
		if err := big.internal_int_power_of_two(&two_n, int(bit_count)); err != nil { ok = false }
		if ok {
			if err := big.int_sub(&mask, &two_n, &one); err != nil { ok = false }
		}
		if ok {
			if err := big.int_mod(&folded, x, &two_n); err != nil { ok = false }
		}
		if ok {
			if err := big.int_sub(&res, &mask, &folded); err != nil { ok = false }
		}
		if ok && is_signed {
			bit, bit_err := big.int_bitfield_extract_single(&res, int(bit_count) - 1)
			if bit_err != nil {
				ok = false
			} else if bit == 1 {
				if sub_err := big.int_sub(&res, &res, &two_n); sub_err != nil { ok = false }
			}
		}
		if ok {
			if err := big.int_copy(dst, &res); err == nil {
				return
			}
		}
	}

	// Unknown/zero width: fall back to the unmasked complement, as before.
	err := big.int_bit_complement(dst, x)
	if err != nil {
		panic("big_int_not: Bitwise NOT operation failed")
	}
}

// ======================================================================================
// TYPE PROMOTION SYSTEM
// C++ Reference: exact_value.cpp:662-753
// ======================================================================================

// Exact_Value_Order represents the type promotion precedence
// C++ Reference: exact_value.cpp:662 (return type)
Exact_Value_Order :: enum {
	Invalid     = 0, // ExactValue_Invalid, ExactValue_Compound
	Bool_String = 1, // ExactValue_Bool, ExactValue_String, ExactValue_String16
	Integer     = 2, // ExactValue_Integer
	Float       = 3, // ExactValue_Float
	Complex     = 4, // ExactValue_Complex
	Quaternion  = 5, // ExactValue_Quaternion
	Pointer     = 6, // ExactValue_Pointer
	Procedure   = 7, // ExactValue_Procedure
	Typeid      = 8, // ExactValue_Typeid
	Compound    = 9, // ExactValue_Compound
}

// exact_value_order returns the type promotion precedence
// C++ Reference: exact_value.cpp:662-688
exact_value_order :: proc(v: Exact_Value) -> Exact_Value_Order {
	if v == nil {
		// C++ line 664-666: Invalid returns 0
		return .Invalid
	}

	#partial switch _ in v {
	case bool, string, Exact_Value_String16:
		// C++ line 667-670: Bool, String, String16 return 1
		return .Bool_String

	case big.Int:
		// C++ line 671-672: Integer returns 2
		return .Integer

	case f64:
		// C++ line 673-674: Float returns 3
		return .Float

	case complex128:
		// C++ line 675-676: Complex returns 4
		return .Complex

	case quaternion256:
		// C++ line 677-678: Quaternion returns 5
		return .Quaternion

	case Exact_Value_Pointer:
		// C++ line 679-680: Pointer returns 6
		return .Pointer

	case Exact_Value_Procedure:
		// C++ line 681-682: Procedure returns 7
		return .Procedure

	case Exact_Value_Typeid:
		// C++ line 684: Typeid returns 8
		return .Typeid

	case Exact_Value_Compound:
		// C++ line 665: Compound returns 0 (same as Invalid)
		return .Invalid
	}

	// Should not reach here
	return .Invalid
}

// match_exact_values promotes two values to a common type
// C++ Reference: exact_value.cpp:690-753
match_exact_values :: proc(x, y: ^Exact_Value) {
	// C++ line 691-694: Ensure x has lower or equal order than y
	if exact_value_order(y^) < exact_value_order(x^) {
		match_exact_values(y, x)
		return
	}

	// At this point, x.order <= y.order

	if x^ == nil {
		// C++ line 697-699: Invalid propagates
		y^ = nil
		return
	}

	// C++ line 701-709: These types don't promote
	#partial switch _ in x^ {
	case bool, string, Exact_Value_String16, quaternion256, Exact_Value_Pointer, Exact_Value_Compound, Exact_Value_Procedure, Exact_Value_Typeid:
		return
	}

	// Handle integer promotion
	x_is_int := false
	#partial switch _ in x^ {
	case big.Int:
		x_is_int = true
	}

	if x_is_int {
		#partial switch _ in y^ {
		case big.Int:
			// C++ line 713-714: Integer to integer, no conversion
			return

		case f64:
			// C++ line 715-718: Promote integer to float
			if x_int, ok := &x^.(big.Int); ok {
				f, err := big.int_get_float(x_int)
				if err == nil {
					x^ = f
				}
			}
			return

		case complex128:
			// C++ line 719-721: Promote integer to complex
			if x_int, ok := &x^.(big.Int); ok {
				f, err := big.int_get_float(x_int)
				if err == nil {
					// Explicit type to avoid compiler bug with complex() in union assignment
					c: complex128 = complex(f, 0)
					x^ = c
				}
			}
			return

		case quaternion256:
			// C++ line 722-724: Promote integer to quaternion
			if x_int, ok := &x^.(big.Int); ok {
				f, err := big.int_get_float(x_int)
				if err == nil {
					x^ = quaternion256(quaternion(real = f, imag = 0, jmag = 0, kmag = 0))
				}
			}
			return
		}
		return
	}

	// Handle float promotion
	if _, x_ok := x^.(f64); x_ok {
		#partial switch _ in y^ {
		case f64:
			// C++ line 730-731: Float to float, no conversion
			return

		case complex128:
			// C++ line 732-734: Promote float to complex
			x^ = exact_value_to_complex(x^)
			return

		case quaternion256:
			// C++ line 735-737: Promote float to quaternion
			x^ = exact_value_to_quaternion(x^)
			return
		}
		return
	}

	// Handle complex promotion
	if _, x_ok := x^.(complex128); x_ok {
		#partial switch _ in y^ {
		case complex128:
			// C++ line 743-744: Complex to complex, no conversion
			return

		case quaternion256:
			// C++ line 745-747: Promote complex to quaternion
			x^ = exact_value_to_quaternion(x^)
			return
		}
		return
	}

	// C++ line 752: Should not reach here with correct logic
}

// ======================================================================================
// HASHING
// C++ Reference: exact_value.cpp:56-106
// ======================================================================================

// hash_exact_value computes a hash for an exact value
// C++ Reference: exact_value.cpp:56-106
hash_exact_value :: proc(v: Exact_Value) -> uintptr {
	if v == nil {
		// C++ line 63-64: Invalid returns 0
		return 0
	}

	res: uintptr

	#partial switch val in v {
	case bool:
		// C++ line 65-67: Hash bool value
		b_bytes := transmute([1]byte)val
		res = uintptr(hash.fnv32a(b_bytes[:]))

	case string:
		// C++ line 68-70: Hash string bytes
		res = uintptr(hash.fnv32a(transmute([]byte)val))

	case Exact_Value_String16:
		// C++ line 71-73: Hash UTF-16 string
		if val.text != nil && val.len > 0 {
			// Hash the UTF-16 data. C++: gb_fnv32a(text, len * size_of(u16)).
			//
			// This arrived at the right BYTE count by accident and via a nominally
			// out-of-bounds intermediate: `val.text[:val.len * size_of(u16)]` slices a
			// [^]u16 to `len*2` ELEMENTS (twice the data that exists), and the slice
			// transmute then reinterpreted those as `len*2` bytes. Only the first
			// `len*2` bytes were ever read, so the result was correct — but state it
			// directly rather than rely on two errors cancelling. See the big.Int arm.
			data := (cast([^]byte)val.text)[:val.len * size_of(u16)]
			res = uintptr(hash.fnv32a(data))
		} else {
			res = 0
		}

	case big.Int:
		// C++ line 74-79: Hash BigInt (hash the limbs and sign like C++)
		// C++: u32 key = gb_fnv32a(v.value_integer.dp, sizeof(*v.value_integer.dp) * v.value_integer.used);
		// C++: u8 last = (u8)v.value_integer.sign;
		// C++: res = (key ^ last) * 0x01000193;
		if val.used > 0 && val.digit != nil {
			// Hash the used limbs.
			//
			// NOTE: `transmute([]byte)val.digit[:val.used]` is WRONG and was the bug here.
			// Transmuting a slice reinterprets the element type but keeps the element
			// COUNT, so a []DIGIT of length N became a []byte of length N — hashing one
			// byte per limb instead of the whole limb. Every value whose low byte is zero
			// therefore hashed identically, and switch-case duplicate detection (which
			// relies on the hash alone, as C++ does) reported them all as duplicates of
			// each other. core/os/stat_linux.odin switches on linux.S_IFBLK/S_IFCHR/
			// S_IFDIR/... — all powers of two >= 4096, i.e. all with a zero low byte.
			//
			// C++ passes an explicit byte count:
			//   gb_fnv32a(v.value_integer.dp, gb_size_of(*v.value_integer.dp) * used)
			limb_bytes := (cast([^]byte)raw_data(val.digit))[:val.used * size_of(big.DIGIT)]
			key := hash.fnv32a(limb_bytes)
			last := u8(val.sign)
			res = uintptr((key ~ u32(last)) * 0x01000193)
		} else {
			// BigInt with used == 0 represents the value 0
			// Use a non-zero hash to distinguish from "no hash"
			res = 1
		}

	case f64:
		// C++ line 81-83: Hash float value
		f_bytes := transmute([8]byte)val
		res = uintptr(hash.fnv32a(f_bytes[:]))

	case Exact_Value_Pointer:
		// C++ line 84-86: Hash pointer using address
		res = uintptr(val.address) & 0x7fffffff

	case complex128:
		// C++ line 87-89: Hash complex value
		c_bytes := transmute([16]byte)val
		res = uintptr(hash.fnv32a(c_bytes[:]))

	case quaternion256:
		// C++ line 90-92: Hash quaternion value
		q_bytes := transmute([32]byte)val
		res = uintptr(hash.fnv32a(q_bytes[:]))

	case Exact_Value_Compound:
		// C++ line 93-95: Hash compound using pointer
		res = uintptr(val.expr) & 0x7fffffff

	case Exact_Value_Procedure:
		// C++ line 96-98: Hash procedure using pointer
		res = uintptr(val.expr) & 0x7fffffff

	case Exact_Value_Typeid:
		// C++ line 99-101: Hash typeid using pointer
		res = uintptr(val.type) & 0x7fffffff
	}

	// C++ line 105: Mask to ensure positive value
	return res & 0x7fffffff
}

// ======================================================================================
// BINARY OPERATOR EVALUATION
// C++ Reference: exact_value.cpp:755-923
// ======================================================================================

// exact_binary_operator_value evaluates binary operations on exact values
// C++ Reference: exact_value.cpp:755-923
exact_binary_operator_value :: proc(op: tokenizer.Token_Kind, x, y: Exact_Value) -> Exact_Value {
	// C++ line 756: Promote values to common type
	x_promoted := x
	y_promoted := y
	match_exact_values(&x_promoted, &y_promoted)

	// C++ line 758-760: Invalid propagates
	if x_promoted == nil {
		return x_promoted
	}

	#partial switch val in x_promoted {
	// C++ line 762-772: Boolean operations
	case bool:
		x_bool := val
		y_bool := y_promoted.(bool) or_else false

		#partial switch op {
		case .Cmp_And:
			// C++ line 764: &&
			return x_bool && y_bool
		case .Cmp_Or:
			// C++ line 765: ||
			return x_bool || y_bool
		case .And:
			// C++ line 766: &
			return x_bool & y_bool
		case .Or:
			// C++ line 767: |
			return x_bool | y_bool
		case .And_Not:
			// C++ line 768: &~
			return x_bool & !y_bool
		case .Xor:
			// C++ line 769: ~
			return (x_bool && !y_bool) || (!x_bool && y_bool)
		case:
			return nil
		}

	// C++ line 774-797: Integer operations
	case big.Int:
		a := x_promoted.(big.Int)
		b := y_promoted.(big.Int)
		c: big.Int
		// NOTE: Do NOT destroy c here - we're returning it and the caller owns it

		#partial switch op {
		case .Add:
			// C++ line 779
			big.int_add(&c, &a, &b)
		case .Sub:
			// C++ line 780
			big.int_sub(&c, &a, &b)
		case .Mul:
			// C++ line 781
			big.int_mul(&c, &a, &b)
		case .Quo:
			// Integer `/` never reaches here: check_binary_expr rewrites the token to
			// `.Quo_Eq` first (C++ check_expr.cpp:4734), which is where integer division
			// happens. C++'s own `.Quo` integer arm is `fmod` and is dead code for it.
			//
			// KNOWN DEVIATION, deliberate: this arm stays float DIVISION rather than
			// C++'s fmod, because the port does reach it where C++ cannot. The port
			// keeps a float-typed constant's exact value as a big.Int (`f64(7)` folds
			// with Integer exact values, not Float), so `f64(7) / f64(2)` lands in this
			// integer arm. C++ has converted the exact value to Float by then. Copying
			// the fmod verbatim makes that fold 1.0 instead of 3.5 -- verified. The real
			// fix is to convert exact values on float conversion; until then this arm
			// compensates. See LEDGER task 186.
			a_f, _ := big.int_get_float(&a)
			b_f, _ := big.int_get_float(&b)
			return exact_value_float(a_f / b_f)
		case .Quo_Eq:
			// C++ exact_value.cpp:797: integer (truncating) division
			big.int_div(&c, &a, &b)
		case .Mod:
			// C++ line 784: Remainder
			big.int_mod(&c, &a, &b)
		case .Mod_Mod:
			// C++ line 785: Euclidean modulo
			big_int_euclidean_mod(&c, &a, &b)
		case .And:
			// C++ line 786: Bitwise AND
			big_int_and(&c, &a, &b)
		case .Or:
			// C++ line 787: Bitwise OR
			big_int_or(&c, &a, &b)
		case .Xor:
			// C++ line 788: Bitwise XOR
			big_int_xor(&c, &a, &b)
		case .And_Not:
			// C++ line 789: Bitwise AND-NOT
			big_int_and_not(&c, &a, &b)
		case .Shl:
			// C++ line 790: Left shift
			// Convert b to int for shift amount
			shift_bits, _ := big.int_get_i64(&b)
			big.int_shl(&c, &a, int(shift_bits))
		case .Shr:
			// C++ line 791: Right shift
			shift_bits, _ := big.int_get_i64(&b)
			big.int_shr(&c, &a, int(shift_bits))
		case:
			return nil
		}
		return c

	// C++ line 799-810: Float operations
	case f64:
		a := x_promoted.(f64)
		b := y_promoted.(f64)

		#partial switch op {
		case .Add:
			// C++ line 803
			return a + b
		case .Sub:
			// C++ line 804
			return a - b
		case .Mul:
			// C++ line 805
			return a * b
		case .Quo:
			// C++ line 806
			return a / b
		case:
			return nil
		}

	// C++ line 812-843: Complex operations
	case complex128:
		y_complex := exact_value_to_complex(y_promoted)
		if y_complex == nil {
			return nil
		}

		x_c := x_promoted.(complex128)
		y_c := y_complex.(complex128)

		a := real(x_c)
		b := imag(x_c)
		cr := real(y_c)
		d := imag(y_c)

		result_real: f64
		result_imag: f64

		#partial switch op {
		case .Add:
			// C++ line 821-824
			result_real = a + cr
			result_imag = b + d
		case .Sub:
			// C++ line 825-828
			result_real = a - cr
			result_imag = b - d
		case .Mul:
			// C++ line 829-832
			result_real = (a * cr - b * d)
			result_imag = (b * cr + a * d)
		case .Quo:
			// C++ line 833-838
			s := cr * cr + d * d
			result_real = (a * cr + b * d) / s
			result_imag = (b * cr - a * d) / s
		case:
			return nil
		}
		// Explicit type to avoid compiler bug with complex() in union return context
		result: complex128 = complex(result_real, result_imag)
		return result

	// C++ line 845-893: Quaternion operations
	case quaternion256:
		y_quat := exact_value_to_quaternion(y_promoted)
		if y_quat == nil {
			return nil
		}

		x_q := x_promoted.(quaternion256)
		y_q := y_quat.(quaternion256)

		xr := real(x_q)
		xi := imag(x_q)
		xj := jmag(x_q)
		xk := kmag(x_q)
		yr := real(y_q)
		yi := imag(y_q)
		yj := jmag(y_q)
		yk := kmag(y_q)

		result_real: f64
		result_imag: f64
		result_jmag: f64
		result_kmag: f64

		#partial switch op {
		case .Add:
			// C++ line 863-868
			result_real = xr + yr
			result_imag = xi + yi
			result_jmag = xj + yj
			result_kmag = xk + yk
		case .Sub:
			// C++ line 869-874
			result_real = xr - yr
			result_imag = xi - yi
			result_jmag = xj - yj
			result_kmag = xk - yk
		case .Mul:
			// C++ line 875-880
			result_imag = xr * yi + xi * yr + xj * yk - xk * yj
			result_jmag = xr * yj - xi * yk + xj * yr + xk * yi
			result_kmag = xr * yk + xi * yj - xj * yi + xk * yr
			result_real = xr * yr - xi * yi - xj * yj - xk * yk
		case .Quo:
			// C++ line 881-888
			invmag2 := 1.0 / (yr * yr + yi * yi + yj * yj + yk * yk)
			result_imag = (xr * -yi + xi * +yr + xj * -yk - xk * -yj) * invmag2
			result_jmag = (xr * -yj - xi * -yk + xj * +yr + xk * -yi) * invmag2
			result_kmag = (xr * -yk + xi * -yj - xj * -yi + xk * +yr) * invmag2
			result_real = (xr * +yr - xi * -yi - xj * -yj - xk * -yk) * invmag2
		case:
			return nil
		}
		// Explicit type to avoid compiler bug with quaternion() in union return context
		q: quaternion256 = quaternion256(quaternion(real = result_real, imag = result_imag, jmag = result_jmag, kmag = result_kmag))
		return q

	// C++ line 895-906: String concatenation
	case string:
		if op != .Add {
			return nil
		}

		sx := x_promoted.(string)
		sy := y_promoted.(string) or_else ""

		// C++ line 899-905: Allocate and concatenate strings
		// Note: In Odin, string concatenation is simpler
		return fmt.aprint(sx, sy, sep = "")

	// C++ line 907-918: UTF-16 String concatenation
	case Exact_Value_String16:
		if op != .Add {
			return nil
		}

		// C++ line 910-917: Allocate and concatenate UTF-16 strings
		sx := x_promoted.(Exact_Value_String16)
		sy := y_promoted.(Exact_Value_String16)
		len := sx.len + sy.len

		// Allocate new UTF-16 buffer
		data := make([^]u16, len)

		// Copy first string
		if sx.text != nil && sx.len > 0 {
			sx_slice := sx.text[:sx.len]
			for i in 0 ..< sx.len {
				data[i] = sx_slice[i]
			}
		}

		// Copy second string
		if sy.text != nil && sy.len > 0 {
			sy_slice := sy.text[:sy.len]
			for i in 0 ..< sy.len {
				data[sx.len + i] = sy_slice[i]
			}
		}

		// Create new Exact_Value_String16
		result := Exact_Value_String16{text = data, len = len}
		return result
	}

	// C++ line 921: Error case
	return nil
}

// ======================================================================================
// UNARY OPERATOR EVALUATION
// C++ Reference: exact_value.cpp:585-659
// ======================================================================================

// exact_unary_operator_value evaluates unary operations on exact values
// C++ Reference: exact_value.cpp:585-659
exact_unary_operator_value :: proc(op: tokenizer.Token_Kind, v: Exact_Value, precision: i32, is_unsigned: bool) -> Exact_Value {
	#partial switch op {
	// C++ line 587-596: Unary plus (identity)
	case .Add:
		#partial switch _ in v {
		case nil, big.Int, f64, complex128, quaternion256:
			return v
		}

	// C++ line 599-627: Unary minus (negation)
	case .Sub:
		if v == nil {
			return v
		}

		#partial switch val in v {
		case big.Int:
			// C++ line 603-608
			result: big.Int
			temp := val
			big.int_neg(&result, &temp)
			return result

		case f64:
			// C++ line 609-613
			return -val

		case complex128:
			// C++ line 614-618
			// Explicit type to avoid compiler bug with complex() in union return context
			c: complex128 = complex(-real(val), -imag(val))
			return c

		case quaternion256:
			// C++ line 619-625
			// Explicit type to avoid compiler bug with quaternion() in union return context
			q: quaternion256 = quaternion256(quaternion(real = -real(val), imag = -imag(val), jmag = -jmag(val), kmag = -kmag(val)))
			return q
		}

	// C++ line 630-644: Bitwise NOT
	case .Xor:
		if v == nil {
			return v
		}

		#partial switch val in v {
		case big.Int:
			// C++ line 634-640
			assert(precision != 0, "Bitwise NOT requires precision") // C++ line 635
			result: big.Int
			temp := val
			big_int_not(&result, &temp, precision, !is_unsigned)
			return result
		case:
			return nil
		}

	// C++ line 646-653: Logical NOT
	case .Not:
		if v == nil {
			return v
		}

		if b, ok := v.(bool); ok {
			return !b
		}
	}

	// C++ line 656: Failure case
	return nil
}

// ======================================================================================
// COMPARISON OPERATIONS
// C++ Reference: exact_value.cpp:950-1062
// ======================================================================================

// Helper: compare f64 values (-1, 0, 1)
// C++ Reference: exact_value.cpp:946-948
cmp_f64 :: proc(a, b: f64) -> i32 {
	return i32((a > b) ? 1 : (a < b) ? -1 : 0)
}

// compare_string16 performs lexicographic comparison of UTF-16 strings
// C++ Reference: string.cpp:155-170
compare_string16 :: proc(a, b: Exact_Value_String16) -> int {
	// C++ line 156-157: Same pointer check
	if a.text == b.text {
		return int(a.len - b.len)
	}

	// C++ line 159-160: nil pointer checks
	if a.text == nil {
		return -1
	}
	if b.text == nil {
		return +1
	}

	// C++ line 166-167: Compare min(a.len, b.len) UTF-16 code units
	n := min(a.len, b.len)

	// Lexicographic comparison using memcmp equivalent
	// C++ line 167: int res = memcmp(a.text, b.text, n*gb_size_of(u16));
	a_slice := a.text[:n]
	b_slice := b.text[:n]

	for i in 0 ..< n {
		if a_slice[i] < b_slice[i] {
			return -1
		}
		if a_slice[i] > b_slice[i] {
			return +1
		}
	}

	// C++ line 168-170: If equal up to min length, compare lengths
	return int(a.len - b.len)
}

// compare_exact_values compares two exact values with an operator
// C++ Reference: exact_value.cpp:950-1062
compare_exact_values :: proc(op: tokenizer.Token_Kind, x, y: Exact_Value) -> bool {
	// C++ line 951: Promote values to common type
	x_promoted := x
	y_promoted := y
	match_exact_values(&x_promoted, &y_promoted)

	// C++ line 953-955: Invalid returns false
	if x_promoted == nil {
		return false
	}

	#partial switch val in x_promoted {
	// C++ line 957-962: Boolean comparison
	case bool:
		y_bool := y_promoted.(bool) or_else false
		#partial switch op {
		case .Cmp_Eq:
			return val == y_bool
		case .Not_Eq:
			return val != y_bool
		}

	// C++ line 964-975: Integer comparison
	case big.Int:
		y_int, y_ok := y_promoted.(big.Int)
		if !y_ok {
			// Types don't match after promotion (e.g., int vs string)
			return false
		}
		temp_val := val
		temp_y := y_int
		cmp, _ := big.int_cmp(&temp_val, &temp_y) // C++ line 965

		#partial switch op {
		case .Cmp_Eq:
			return cmp == 0
		case .Not_Eq:
			return cmp != 0
		case .Lt:
			return cmp < 0
		case .Lt_Eq:
			return cmp <= 0
		case .Gt:
			return cmp > 0
		case .Gt_Eq:
			return cmp >= 0
		}

	// C++ line 977-993: Float comparison
	case f64:
		y_float, y_ok := y_promoted.(f64)
		if !y_ok {
			// Types don't match after promotion
			return false
		}

		// C++ line 980-982: NaN handling
		if math.is_nan(val) || math.is_nan(y_float) {
			return op == .Not_Eq
		}

		#partial switch op {
		case .Cmp_Eq:
			return cmp_f64(val, y_float) == 0
		case .Not_Eq:
			return cmp_f64(val, y_float) != 0
		case .Lt:
			return cmp_f64(val, y_float) < 0
		case .Lt_Eq:
			return cmp_f64(val, y_float) <= 0
		case .Gt:
			return cmp_f64(val, y_float) > 0
		case .Gt_Eq:
			return cmp_f64(val, y_float) >= 0
		}

	// C++ line 995-1005: Complex comparison (equality only)
	case complex128:
		y_complex, y_ok := y_promoted.(complex128)
		if !y_ok {
			// Types don't match after promotion
			return false
		}
		a := real(val)
		b := imag(val)
		c := real(y_complex)
		d := imag(y_complex)

		#partial switch op {
		case .Cmp_Eq:
			return cmp_f64(a, c) == 0 && cmp_f64(b, d) == 0
		case .Not_Eq:
			return cmp_f64(a, c) != 0 || cmp_f64(b, d) != 0
		}

	// C++ line 1007-1019: String comparison
	case string:
		y_string := y_promoted.(string) or_else ""

		#partial switch op {
		case .Cmp_Eq:
			return val == y_string
		case .Not_Eq:
			return val != y_string
		case .Lt:
			return val < y_string
		case .Lt_Eq:
			return val <= y_string
		case .Gt:
			return val > y_string
		case .Gt_Eq:
			return val >= y_string
		}

	// C++ line 1020-1032: UTF-16 String comparison
	case Exact_Value_String16:
		y_string16, y_ok := y_promoted.(Exact_Value_String16)
		if !y_ok {
			// Types don't match after promotion
			return false
		}

		// C++ Reference: string.cpp:155-170 (string16_compare)
		cmp := compare_string16(val, y_string16)

		#partial switch op {
		case .Cmp_Eq:
			return cmp == 0
		case .Not_Eq:
			return cmp != 0
		case .Lt:
			return cmp < 0
		case .Lt_Eq:
			return cmp <= 0
		case .Gt:
			return cmp > 0
		case .Gt_Eq:
			return cmp >= 0
		}

	// C++ line 1034-1043: Pointer comparison
	case Exact_Value_Pointer:
		y_ptr, y_ok := y_promoted.(Exact_Value_Pointer)
		if !y_ok {
			// Types don't match after promotion
			return false
		}

		#partial switch op {
		case .Cmp_Eq:
			return val.address == y_ptr.address
		case .Not_Eq:
			return val.address != y_ptr.address
		case .Lt:
			return val.address < y_ptr.address
		case .Lt_Eq:
			return val.address <= y_ptr.address
		case .Gt:
			return val.address > y_ptr.address
		case .Gt_Eq:
			return val.address >= y_ptr.address
		}

	// C++ line 1045-1050: Typeid comparison
	case Exact_Value_Typeid:
		y_typeid, y_ok := y_promoted.(Exact_Value_Typeid)
		if !y_ok {
			// Types don't match after promotion
			return false
		}

		#partial switch op {
		case .Cmp_Eq:
			return val.type == y_typeid.type
		case .Not_Eq:
			return val.type != y_typeid.type
		}

	// C++ line 1052-1057: Procedure comparison
	case Exact_Value_Procedure:
		y_proc, y_ok := y_promoted.(Exact_Value_Procedure)
		if !y_ok {
			// Types don't match after promotion
			return false
		}

		#partial switch op {
		case .Cmp_Eq:
			return val.expr == y_proc.expr
		case .Not_Eq:
			return val.expr != y_proc.expr
		}
	}

	// C++ line 1060: Invalid comparison panic
	// Only reachable for invalid comparison operators on procedures
	return false
}

// compare_exact_values_compound_lit compares two compound literal exact values
// C++ Reference: exact_value.cpp:1060-1120
// This compares arrays and structs element-by-element for equality
compare_exact_values_compound_lit :: proc(ctx: ^Checker_Context, x, y: Exact_Value) -> bool {
	// Both must be compound values
	x_compound, x_ok := x.(Exact_Value_Compound)
	y_compound, y_ok := y.(Exact_Value_Compound)

	if !x_ok || !y_ok {
		return false
	}

	// Both must have expressions
	if x_compound.expr == nil || y_compound.expr == nil {
		return false
	}

	// Get the compound literals
	x_lit, x_is_lit := x_compound.expr.derived.(^ast.Comp_Lit)
	y_lit, y_is_lit := y_compound.expr.derived.(^ast.Comp_Lit)

	if !x_is_lit || !y_is_lit {
		return false
	}

	// Element counts must match
	if len(x_lit.elems) != len(y_lit.elems) {
		return false
	}

	// Compare each element
	for i := 0; i < len(x_lit.elems); i += 1 {
		x_elem := x_lit.elems[i]
		y_elem := y_lit.elems[i]

		if x_elem == nil || y_elem == nil {
			if x_elem != y_elem {
				return false
			}
			continue
		}

		// Handle Field_Value elements (named fields in structs)
		x_fv, x_is_fv := x_elem.derived.(^ast.Field_Value)
		y_fv, y_is_fv := y_elem.derived.(^ast.Field_Value)

		x_val := x_elem
		y_val := y_elem

		if x_is_fv && y_is_fv {
			x_val = x_fv.value
			y_val = y_fv.value
		} else if x_is_fv != y_is_fv {
			return false // One is named, other is not
		}

		// Get type_and_value for each element
		x_tv, x_found := tav_lookup(ctx.info, x_val)
		y_tv, y_found := tav_lookup(ctx.info, y_val)

		if !x_found || !y_found {
			return false
		}

		// Both must be constants
		if x_tv.mode != .Constant || y_tv.mode != .Constant {
			return false
		}

		// Recursively compare values
		if _, is_x_comp := x_tv.value.(Exact_Value_Compound); is_x_comp {
			if !compare_exact_values_compound_lit(ctx, x_tv.value, y_tv.value) {
				return false
			}
		} else {
			if !compare_exact_values(.Cmp_Eq, x_tv.value, y_tv.value) {
				return false
			}
		}
	}

	return true
}

// ======================================================================================
// HELPER ARITHMETIC FUNCTIONS
// C++ Reference: exact_value.cpp:925-943
// ======================================================================================

// exact_value_add adds two exact values
// C++ Reference: exact_value.cpp:925-927
exact_value_add :: proc(x, y: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(.Add, x, y)
}

// exact_value_mul multiplies two exact values
// C++ Reference: exact_value.cpp:931-933
exact_value_mul :: proc(x, y: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(.Mul, x, y)
}

// exact_value_quo divides two exact values
// C++ Reference: exact_value.cpp:934-936
exact_value_quo :: proc(x, y: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(.Quo, x, y)
}

// exact_value_shift performs shift operation (left or right)
// C++ Reference: exact_value.cpp:937-939
exact_value_shift :: proc(op: tokenizer.Token_Kind, x, y: Exact_Value) -> Exact_Value {
	return exact_binary_operator_value(op, x, y)
}

// ======================================================================================
// ADDITIONAL CONSTRUCTORS
// C++ Reference: exact_value.cpp:109-187
// ======================================================================================

// exact_value_compound creates a compound literal exact value
// C++ Reference: exact_value.cpp:109-113
exact_value_compound :: proc(node: ^ast.Expr) -> Exact_Value {
	return Exact_Value_Compound{expr = node}
}

// exact_value_procedure creates a procedure exact value
// C++ Reference: exact_value.cpp:176-180
exact_value_procedure :: proc(node: ^ast.Expr) -> Exact_Value {
	return Exact_Value_Procedure{expr = node}
}

// exact_value_pointer creates a pointer exact value
// C++ Reference: exact_value.cpp:170-174
exact_value_pointer :: proc(ptr: i64) -> Exact_Value {
	return Exact_Value_Pointer{address = ptr}
}

// exact_value_complex creates a complex exact value
// C++ Reference: exact_value.cpp:152-158
exact_value_complex :: proc(real, imag: f64) -> Exact_Value {
	// Explicit type to avoid compiler bug with complex() in union return context
	c: complex128 = complex(real, imag)
	return c
}

// exact_value_quaternion creates a quaternion exact value
// C++ Reference: exact_value.cpp:160-168
exact_value_quaternion :: proc(real, imag, jmag, kmag: f64) -> Exact_Value {
	// Explicit type to avoid compiler bug with quaternion() in union return context
	q: quaternion256 = quaternion256(quaternion(real = real, imag = imag, jmag = jmag, kmag = kmag))
	return q
}

// exact_value_string16 creates a UTF-16 string exact value
// C++ Reference: exact_value.cpp:126-130
exact_value_string16 :: proc(s: Exact_Value_String16) -> Exact_Value {
	return s
}

// ======================================================================================
// STRING PARSING FUNCTIONS
// C++ Reference: exact_value.cpp:190-394
// ======================================================================================

// exact_value_integer_from_string parses a string to create an integer exact value
// C++ Reference: exact_value.cpp:190-199
exact_value_integer_from_string :: proc(str: string) -> Exact_Value {
	// C++ line 191-192: Create result with zero-initialized BigInt
	result: big.Int

	// C++ line 193-194: Parse string to BigInt using int_atoi
	// The Odin API is: int_atoi :: proc(res: ^Int, input: string, radix := i8(10), allocator := context.allocator) -> (err: Error)
	err := big.int_atoi(&result, str, 10)

	// C++ line 195-197: Return invalid on failure
	if err != nil {
		return nil
	}

	return result
}

// float_from_string parses a string to f64
// C++ Reference: exact_value.cpp:203-321
// The C++ version has complex handling for underscores and exponents
// We delegate to Odin's strconv which handles the parsing correctly
float_from_string :: proc(str: string) -> (f64, bool) {
	// C++ line 204-243: Handle strings of various lengths
	// The C++ code removes underscores and normalizes 'E' to 'e'
	// Then calls strtod

	// Build a cleaned version of the string
	buf := make([dynamic]u8, 0, len(str), context.temp_allocator)

	for i := 0; i < len(str); i += 1 {
		c := str[i]
		// C++ line 209-210: Skip underscores
		if c == '_' {
			continue
		}
		// C++ line 212: Convert 'E' to 'e'
		if c == 'E' {
			append(&buf, 'e')
		} else {
			append(&buf, c)
		}
	}

	cleaned := string(buf[:])

	// C++ line 218-220: Parse using strtod equivalent
	value, ok := strconv.parse_f64(cleaned)
	return value, ok
}

// f16_to_f32 converts IEEE 754 half-precision (16-bit) float to f32
// C++ Reference: common.cpp:633-647
f16_to_f32 :: proc(value: u16) -> f32 {
	// Union type to allow bit manipulation between u32 and f32
	Fp32 :: struct #raw_union {
		u: u32,
		f: f32,
	}

	v: Fp32

	// C++ line 637: Magic number for exponent adjustment (254 - 15) << 23
	magic := Fp32{u = (254 - 15) << 23}

	// C++ line 638: Threshold for infinity/NaN (127 + 16) << 23
	inf_or_nan := Fp32{u = (127 + 16) << 23}

	// C++ line 640: Extract mantissa and exponent (mask sign bit, shift left 13 bits)
	v.u = u32(value & 0x7fff) << 13

	// C++ line 641: Scale the value using magic multiplier
	v.f *= magic.f

	// C++ line 642-644: Clamp to infinity/NaN if needed
	if v.f >= inf_or_nan.f {
		v.u |= 255 << 23
	}

	// C++ line 645: Add sign bit (shift from bit 15 to bit 31)
	v.u |= u32(value & 0x8000) << 16

	// C++ line 646: Return the f32 value
	return v.f
}

// exact_value_float_from_string parses a string to create a float exact value
// C++ Reference: exact_value.cpp:323-360
exact_value_float_from_string :: proc(str: string) -> Exact_Value {
	// C++ line 324-347: Handle hexadecimal float literals (0hXXXX)
	if len(str) > 2 && str[0] == '0' && str[1] == 'h' {
		// Count actual hex digits (ignoring underscores)
		digit_count := 0
		for i := 2; i < len(str); i += 1 {
			if str[i] != '_' {
				digit_count += 1
			}
		}

		// C++ line 332: Parse as u64
		u, ok := strconv.parse_u64_of_base(str, 16)
		if !ok {
			return nil
		}

		// C++ line 333-346: Convert based on digit count
		if digit_count == 4 {
			// C++ line 334-336: f16 format (4 hex digits)
			x := u16(u)
			f := f16_to_f32(x)
			return f64(f)
		} else if digit_count == 8 {
			// C++ line 337-339: f32 format (8 hex digits)
			x := u32(u)
			f := transmute(f32)x
			return f64(f)
		} else if digit_count == 16 {
			// C++ line 340-342: f64 format (16 hex digits)
			f := transmute(f64)u
			return f
		} else {
			// C++ line 344-346: Invalid digit count
			panic(fmt.tprintf("Invalid hexadecimal float, expected 4, 8 or 16 digits, got %d", digit_count))
		}
	}

	// C++ line 349-352: If no '.' or 'e', treat as integer
	if !strings.contains(str, ".") && !strings.contains(str, "e") && !strings.contains(str, "E") {
		return exact_value_integer_from_string(str)
	}

	// C++ line 354-359: Parse as float
	f, ok := float_from_string(str)
	if !ok {
		return nil
	}
	return f
}

// exact_value_from_basic_literal creates an exact value from a basic literal token
// C++ Reference: exact_value.cpp:363-394
exact_value_from_basic_literal :: proc(kind: tokenizer.Token_Kind, str: string) -> Exact_Value {
	#partial switch kind {
	// C++ line 365: String literal
	case .String:
		return exact_value_string(str)

	// C++ line 366: Integer literal
	case .Integer:
		return exact_value_integer_from_string(str)

	// C++ line 367: Float literal
	case .Float:
		return exact_value_float_from_string(str)

	// C++ line 368-380: Imaginary literal (i, j, k suffix)
	case .Imag:
		// C++ line 369-371: Extract suffix (last character)
		last_rune := rune(str[len(str) - 1])
		str_without_suffix := str[:len(str) - 1]

		// C++ line 372: Parse the numeric part
		imag := float_from_string(str_without_suffix) or_else 0.0

		// C++ line 374-379: Create complex or quaternion based on suffix
		switch last_rune {
		case 'i':
			return exact_value_complex(0, imag)
		case 'j':
			return exact_value_quaternion(0, 0, imag, 0)
		case 'k':
			return exact_value_quaternion(0, 0, 0, imag)
		case:
			panic("Invalid imaginary basic literal")
		}

	// C++ line 381-390: Rune literal
	case .Rune:
		// C++ line 382-387: Decode rune (single char or UTF-8)
		r: rune
		if len(str) == 1 {
			r = rune(str[0])
		} else {
			// Decode UTF-8 rune
			r, _ = utf8.decode_rune(str)
		}
		// C++ line 388: Return as i64
		return exact_value_i64(i64(r))
	}

	// C++ line 392: Invalid
	return nil
}

// ======================================================================================
// STRING FORMATTING / PRINTING
// C++ Reference: exact_value.cpp:1069-1128
// ======================================================================================

// write_exact_value_to_string formats an exact value to a string builder
// C++ Reference: exact_value.cpp:1069-1124
write_exact_value_to_string :: proc(buf: ^strings.Builder, v: Exact_Value, string_limit: int = 36) {
	if v == nil {
		// C++ line 1071-1072: Invalid returns empty
		return
	}

	#partial switch val in v {
	// C++ line 1073-1074: Boolean
	case bool:
		strings.write_string(buf, val ? "true" : "false")

	// C++ line 1075-1087: String
	case string:
		// C++ Reference: exact_value.cpp:1102-1112. quote_to_ascii supplies the
		// surrounding quote characters, so a string constant renders as
		// `"not an int"`.
		//
		// Both the limit test and the truncation operate on the QUOTED, ESCAPED
		// string, not the raw one: a 36-character source string quotes to 38 bytes
		// and is therefore truncated, and the reported character count is the quoted
		// length. The truncation splits raw bytes, so it can cut an escape in half.
		quoted := quote_to_ascii(val, context.temp_allocator)
		limit := max(string_limit, 36)
		if len(quoted) <= limit {
			strings.write_string(buf, quoted)
		} else {
			// C++ line 1107-1110: Truncate long strings
			n := limit / 5
			strings.write_string(buf, quoted[:n])
			fmt.sbprintf(buf, "\"..%d chars..\"", len(quoted) - (2 * n))
			strings.write_string(buf, quoted[len(quoted) - n:])
		}

	// C++ line 1089-1101: UTF-16 String
	case Exact_Value_String16:
		// C++ line 1090: Quote the UTF-16 string using quote_to_ascii
		limit := max(string_limit, 36)
		quoted := quote_to_ascii(val, context.temp_allocator)
		if len(quoted) <= limit {
			strings.write_string(buf, quoted)
		} else {
			// C++ line 1121-1124: Truncate long strings
			n := limit / 5
			strings.write_string(buf, quoted[:n])
			fmt.sbprintf(buf, "\"..%d chars..\"", len(quoted) - (2 * n))
			strings.write_string(buf, quoted[len(quoted) - n:])
		}

	// C++ line 1103-1107: Integer
	case big.Int:
		// C++ line 1104: Convert BigInt to string using int_itoa_string
		// The Odin API is: int_itoa_string :: proc(a: ^Int, radix := i8(10), zero_terminate := false, allocator := context.allocator) -> (res: string, err: Error)
		// NOTE: see is_exact_value_zero - `v` is by value, so take an addressable copy.
		i := val
		str, err := big.int_itoa_string(&i, 10, false, context.temp_allocator)
		if err == nil {
			strings.write_string(buf, str)
		}

	// C++ Reference: exact_value.cpp:1135-1141. The source writes "%.17g", but gb's own
	// formatter renders that as SEVENTEEN DECIMAL PLACES, not 17 significant digits -- the
	// oracle prints 1.5 as "1.50000000000000000" and 123.456 as "123.45600000000000304",
	// the latter showing the f64 rounding artifact at the 17th place. Observable behaviour
	// is what parity means here, so match the rendering rather than the format specifier.
	// The port previously used plain "%f" (3 decimals), losing that precision entirely.
	case f64:
		fmt.sbprintf(buf, "%.17f", val)

	// C++ line 1138
	case complex128:
		fmt.sbprintf(buf, "%.17f+%.17fi", real(val), imag(val))

	// C++ line 1140
	case quaternion256:
		fmt.sbprintf(buf, "%.17f+%.17fi+%.17fj+%.17fk", real(val), imag(val), jmag(val), kmag(val))

	// C++ line 1116-1117: Pointer
	case Exact_Value_Pointer:
		// Return empty for pointer
		return

	// C++ line 1118-1119: Compound
	case Exact_Value_Compound:
		write_expr_to_string(buf, val.expr, true)

	// C++ line 1120-1121: Procedure
	case Exact_Value_Procedure:
		write_expr_to_string(buf, val.expr, true)
	}
}

// exact_value_to_string formats an exact value to a string
// C++ Reference: exact_value.cpp:1126-1128
exact_value_to_string :: proc(v: Exact_Value, string_limit: int = 36) -> string {
	buf: strings.Builder
	strings.builder_init(&buf)
	write_exact_value_to_string(&buf, v, string_limit)
	return strings.to_string(buf)
}

// is_exact_value_float checks if an exact value is a floating-point value
// C++ Reference: exact_value.cpp (various locations)
is_exact_value_float :: proc(v: Exact_Value) -> bool {
	#partial switch _ in v {
	case f64:
		return true
	}
	return false
}
