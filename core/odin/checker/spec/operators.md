# Odin Operator Semantics

*Extracted from: src/check_expr.cpp*

## 1. Unary Operators

### 1.1 Numeric Unary (`+`, `-`)

| Operator | Allowed Types | Notes |
|----------|---------------|-------|
| `+` (unary plus) | Numeric | Identity operation |
| `-` (unary minus) | Numeric | Negation |

Applies to: integers, floats, complex, quaternion, arrays of numeric types.

### 1.2 Bitwise Not (`~`)

| Operator | Allowed Types | Notes |
|----------|---------------|-------|
| `~` | Integer, Boolean, bit_set | Bitwise complement |

Note: For booleans, flips all bits (not logical not).

### 1.3 Logical Not (`!`)

| Operator | Allowed Types | Notes |
|----------|---------------|-------|
| `!` | Boolean (scalar only) | Logical negation |

**Not allowed on arrays of booleans.**

Common error: Using `!` on integers. Suggestions:
- Use `x == 0` for zero test
- Use `~x` for bitwise not

### 1.4 Dereference (`^`)

| Operator | Allowed Types | Notes |
|----------|---------------|-------|
| `^` (postfix) | Pointer types | Dereference |

Note: Odin uses postfix `^` not prefix `*`.

### 1.5 Address-of (`&`)

| Operator | Allowed Types | Notes |
|----------|---------------|-------|
| `&` | Addressable lvalues | Take address |

---

## 2. Binary Arithmetic Operators

### 2.1 Addition (`+`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Numeric + Numeric | Numeric | Standard addition |
| bit_set + bit_set | bit_set | Union |
| string + string | string | **Constant strings only** |

String concatenation requires both operands to be compile-time constants.

### 2.2 Subtraction (`-`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Numeric - Numeric | Numeric | Standard subtraction |
| bit_set - bit_set | bit_set | Difference |

### 2.3 Multiplication (`*`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Numeric * Numeric | Numeric | Standard multiplication |
| bit_set * bit_set | bit_set | Intersection |
| matrix * matrix | matrix | Matrix multiplication |
| matrix * vector | vector | Matrix-vector multiply |
| vector * matrix | vector | Vector-matrix multiply |

### 2.4 Division (`/`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Numeric / Numeric | Numeric | Division |
| **Not allowed** | matrix | Cannot divide matrices |
| **Not allowed** | #simd integer | Cannot divide SIMD integers |

### 2.5 Modulo (`%`, `%%`)

| Operator | Operand Types | Result | Notes |
|----------|---------------|--------|-------|
| `%` | Integer % Integer | Integer | Truncated modulo |
| `%%` | Integer %% Integer | Integer | Floored modulo |

**Not allowed with:**
- Matrix types
- #simd types

---

## 3. Bitwise Binary Operators

### 3.1 Bitwise AND (`&`)

| Operand Types | Result |
|---------------|--------|
| Integer & Integer | Integer |
| Boolean & Boolean | Boolean |
| bit_set & bit_set | bit_set (intersection) |

### 3.2 Bitwise OR (`|`)

| Operand Types | Result |
|---------------|--------|
| Integer \| Integer | Integer |
| Boolean \| Boolean | Boolean |
| bit_set \| bit_set | bit_set (union) |

### 3.3 Bitwise XOR (`~`)

| Operand Types | Result |
|---------------|--------|
| Integer ~ Integer | Integer |
| Boolean ~ Boolean | Boolean |
| bit_set ~ bit_set | bit_set (symmetric difference) |

### 3.4 AND NOT (`&~`)

| Operand Types | Result |
|---------------|--------|
| Integer &~ Integer | Integer |
| bit_set &~ bit_set | bit_set (difference) |

---

## 4. Shift Operators

### 4.1 Left Shift (`<<`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Integer << Integer | Integer | Shift left |

### 4.2 Right Shift (`>>`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Integer >> Integer | Integer | Arithmetic shift right (signed) |
| Integer >> Integer | Integer | Logical shift right (unsigned) |

---

## 5. Logical Operators

### 5.1 Logical AND (`&&`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Boolean && Boolean | Boolean | Short-circuit AND |

### 5.2 Logical OR (`||`)

| Operand Types | Result | Notes |
|---------------|--------|-------|
| Boolean \|\| Boolean | Boolean | Short-circuit OR |

---

## 6. Comparison Operators

### 6.1 Equality (`==`, `!=`)

| Operand Types | Requirement |
|---------------|-------------|
| T == T | T must be comparable |
| T != T | T must be comparable |

**Comparable types include:**
- Basic types (integers, floats, booleans, strings)
- Pointers
- Enums
- Structs/unions with comparable fields
- Arrays of comparable types

**Not comparable:**
- Procedures (use `rawptr` cast)
- Types with padding that can't be memcmp'd

### 6.2 Ordering (`<`, `<=`, `>`, `>=`)

| Operand Types | Requirement |
|---------------|-------------|
| T < T | T must be ordered |

**Ordered types include:**
- Integers
- Floats
- Strings (lexicographic)
- Pointers
- Runes
- Enums

---

## 7. Range Operators

### 7.1 Half-Open Range (`..<`)

```odin
for i in 0..<10 { }  // 0 to 9
```

### 7.2 Inclusive Range (`..=`)

```odin
for i in 0..=10 { }  // 0 to 10
```

---

## 8. Compound Assignment Operators

Each binary operator has a compound assignment form:

| Operator | Equivalent |
|----------|------------|
| `+=` | `x = x + y` |
| `-=` | `x = x - y` |
| `*=` | `x = x * y` |
| `/=` | `x = x / y` |
| `%=` | `x = x % y` |
| `%%=` | `x = x %% y` |
| `&=` | `x = x & y` |
| `\|=` | `x = x \| y` |
| `~=` | `x = x ~ y` |
| `&~=` | `x = x &~ y` |
| `<<=` | `x = x << y` |
| `>>=` | `x = x >> y` |
| `&&=` | `x = x && y` |
| `\|\|=` | `x = x \|\| y` |

---

## 9. Array Programming

Most binary operators support **array programming** (element-wise operations):

```odin
a: [4]int = {1, 2, 3, 4}
b: [4]int = {5, 6, 7, 8}
c := a + b  // {6, 8, 10, 12}
```

**Exceptions** (not allowed with arrays):
- `&&`, `||` (logical operators)
- `!` (logical not)

### 9.1 Scalar Broadcasting

```odin
a: [4]int = {1, 2, 3, 4}
b := a * 2  // {2, 4, 6, 8}
```

---

## 10. Matrix Operations

### 10.1 Matrix Multiplication

```odin
A: matrix[2, 3]f32
B: matrix[3, 4]f32
C := A * B  // matrix[2, 4]f32
```

### 10.2 Matrix-Vector Multiplication

```odin
M: matrix[3, 3]f32
v: [3]f32
result := M * v  // [3]f32
```

### 10.3 Restricted Operations

| Operation | Allowed |
|-----------|---------|
| Matrix + Matrix | Yes (element-wise) |
| Matrix - Matrix | Yes (element-wise) |
| Matrix * Matrix | Yes (matrix multiply) |
| Matrix / Matrix | **No** |
| Matrix % Matrix | **No** |

---

## 11. Bit Set Operations Summary

| Operation | Meaning |
|-----------|---------|
| `a + b` | Union |
| `a - b` | Difference |
| `a * b` | Intersection |
| `a & b` | Intersection |
| `a \| b` | Union |
| `a ~ b` | Symmetric difference |
| `a &~ b` | Difference |
| `~a` | Complement |

---

## 12. Operator Precedence

From highest to lowest:

1. Postfix: `()`, `[]`, `.`, `^`, `?`
2. Unary: `+`, `-`, `~`, `!`, `&`, `cast`, `auto_cast`, `transmute`
3. Multiplicative: `*`, `/`, `%`, `%%`, `&`, `&~`, `<<`, `>>`
4. Additive: `+`, `-`, `|`, `~`
5. Comparison: `==`, `!=`, `<`, `<=`, `>`, `>=`
6. Logical AND: `&&`
7. Logical OR: `||`
8. Ternary: `? :`
9. Assignment: `=`, `+=`, `-=`, etc.

---

## 13. Type Promotion Rules

When operands have different types:

1. **Untyped constants** convert to the typed operand's type
2. **Integers** of different sizes: smaller promotes to larger
3. **Mixed integer/float**: integer converts to float
4. **Complex/Quaternion**: real converts to complex/quaternion

See `conversions.md` for detailed rules.
