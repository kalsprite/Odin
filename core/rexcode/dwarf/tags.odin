package rexcode_dwarf

// DWARF tags, attributes and forms -- only what this package emits or is about
// to. Named exactly as the standard names them, because the value of a constant
// here is that a reader can check it against §7 without a translation step.

// -----------------------------------------------------------------------------
// Tags (§7.5.3, Table 7.3)
// -----------------------------------------------------------------------------

DW_TAG_array_type       :: u64(0x01)
DW_TAG_enumeration_type :: u64(0x04)
DW_TAG_formal_parameter :: u64(0x05)
DW_TAG_lexical_block    :: u64(0x0b)
DW_TAG_member           :: u64(0x0d)
DW_TAG_pointer_type     :: u64(0x0f)
DW_TAG_compile_unit     :: u64(0x11)
DW_TAG_structure_type   :: u64(0x13)
DW_TAG_subroutine_type  :: u64(0x15)
DW_TAG_typedef          :: u64(0x16)
DW_TAG_union_type       :: u64(0x17)
DW_TAG_unspecified_parameters :: u64(0x18)
DW_TAG_inlined_subroutine :: u64(0x1d)
DW_TAG_subrange_type    :: u64(0x21)
DW_TAG_base_type        :: u64(0x24)
DW_TAG_const_type       :: u64(0x26)
DW_TAG_enumerator       :: u64(0x28)
DW_TAG_subprogram       :: u64(0x2e)
DW_TAG_variable         :: u64(0x34)

DW_CHILDREN_no  :: u8(0)
DW_CHILDREN_yes :: u8(1)

// -----------------------------------------------------------------------------
// Attributes (§7.5.4, Table 7.5)
// -----------------------------------------------------------------------------

DW_AT_location      :: u64(0x02)
DW_AT_name          :: u64(0x03)
DW_AT_byte_size     :: u64(0x0b)
DW_AT_stmt_list     :: u64(0x10)
DW_AT_low_pc        :: u64(0x11)
DW_AT_high_pc       :: u64(0x12)
DW_AT_language      :: u64(0x13)
DW_AT_comp_dir      :: u64(0x1b)
DW_AT_const_value   :: u64(0x1c)
DW_AT_upper_bound   :: u64(0x2f)
DW_AT_producer      :: u64(0x25)
DW_AT_prototyped    :: u64(0x27)
DW_AT_count         :: u64(0x37)
DW_AT_data_member_location :: u64(0x38)
DW_AT_decl_file     :: u64(0x3a)
DW_AT_decl_line     :: u64(0x3b)
DW_AT_declaration   :: u64(0x3c)
DW_AT_encoding      :: u64(0x3e)
DW_AT_external      :: u64(0x3f)
DW_AT_frame_base    :: u64(0x40)
DW_AT_specification :: u64(0x47)
DW_AT_type          :: u64(0x49)
DW_AT_ranges        :: u64(0x55)

// Attributes the reference Odin compiler emits that the list above did not
// cover. `DW_AT_alignment` is the striking one: it appears 512 times in a
// two-object sample, more often than any attribute except name and type,
// because Odin's layout rules are explicit and the reference writes them down.
DW_AT_bit_size         :: u64(0x0d)
DW_AT_address_class    :: u64(0x33)
DW_AT_data_bit_offset  :: u64(0x6b)
DW_AT_linkage_name     :: u64(0x6e)
DW_AT_alignment        :: u64(0x88)

// -----------------------------------------------------------------------------
// Forms (§7.5.6, Table 7.6). DW_FORM_string / strp / line_strp / udata / data16
// are declared next to the line-header content types in dwarf.odin.
// -----------------------------------------------------------------------------

DW_FORM_addr         :: u64(0x01)
DW_FORM_block1       :: u64(0x0a)
DW_FORM_data1        :: u64(0x0b)
DW_FORM_data2        :: u64(0x05)
DW_FORM_data4        :: u64(0x06)
DW_FORM_data8        :: u64(0x07)
DW_FORM_sdata        :: u64(0x0d)
DW_FORM_ref4         :: u64(0x13)
DW_FORM_sec_offset   :: u64(0x17)
DW_FORM_exprloc      :: u64(0x18)
DW_FORM_flag_present :: u64(0x19)
DW_FORM_flag         :: u64(0x0c)

// -----------------------------------------------------------------------------
// Base-type encodings (§7.8, Table 7.11)
// -----------------------------------------------------------------------------

DW_ATE_address        :: u64(0x01)
DW_ATE_boolean        :: u64(0x02)
DW_ATE_float          :: u64(0x04)
DW_ATE_signed         :: u64(0x05)
DW_ATE_signed_char    :: u64(0x06)
DW_ATE_unsigned       :: u64(0x07)
DW_ATE_unsigned_char  :: u64(0x08)
DW_ATE_UTF            :: u64(0x10)

// -----------------------------------------------------------------------------
// Source languages (§7.12). The reference Odin compiler reports C99, and this
// package defaults to the same: readers key name formatting, array indexing and
// expression syntax off this value, and every one of them knows C99. There is a
// registered code for Odin (0x0028, DWARF 6) but gdb 17 does not act on it.
// -----------------------------------------------------------------------------

DW_LANG_C89  :: u64(0x0001)
DW_LANG_C99  :: u64(0x000c)
DW_LANG_C11  :: u64(0x001d)

// Unit types, new in version 5 (§7.5.1). Version 4 has no such field.
DW_UT_compile :: u8(0x01)
