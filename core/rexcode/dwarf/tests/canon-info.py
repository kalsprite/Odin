#!/usr/bin/env python3
"""Canonicalise an llvm-dwarfdump --debug-info dump into a comparable DIE tree.

One line per DIE in pre-order:

    <depth>\t<TAG>\t<attr>=<value>\t...

Type references become the target's pre-order INDEX rather than its section
offset, because an index is what a builder can act on and an offset is an
artefact of the encoding this is trying to see past.

Attributes are compared by VALUE, never by form: a byte size the reference wrote
as data1 and we write as udata is the same fact. Attributes that cannot be
compared are EXCLUDED BY NAME and tallied to stderr -- a parity number with
silent drops in it is worse than no number.

Usage: canon-info.py <dump> <outdir>   -> writes cu0.canon, cu1.canon, ...
"""
import re, sys, collections

# Compared. Everything else is excluded and reported.
INCLUDE = {
    'name', 'producer', 'comp_dir', 'linkage_name',
    'byte_size', 'alignment', 'encoding', 'decl_line', 'language',
    'bit_size', 'data_bit_offset', 'address_class', 'data_member_location',
    'count', 'upper_bound', 'const_value',
    'external', 'prototyped', 'declaration',
    'type',
}

# Excluded on purpose, with the reason, so the tally is readable rather than a
# list of surprises.
EXCLUDED_REASON = {
    'decl_file':     'the reference resolves it to a PATH through its line table; a bare CU has only the number',
    'stmt_list':     'a section-relative reference, checked by decode-check instead',
    'low_pc':        'a relocation; zero in every relocatable object, so comparing it proves nothing',
    'high_pc':       'paired with low_pc',
    'location':      'an expression; exercised behaviourally by gdb-check',
    'frame_base':    'an expression; exercised behaviourally by gdb-check',
    'GNU_pubnames':  'a vendor extension this package does not emit',
    'ranges':        'not emitted',
}

LANG = {'DW_LANG_C89': 1, 'DW_LANG_C99': 0x0c, 'DW_LANG_C11': 0x1d, 'DW_LANG_C': 2}
ATE = {'DW_ATE_address': 1, 'DW_ATE_boolean': 2, 'DW_ATE_float': 4, 'DW_ATE_signed': 5,
       'DW_ATE_signed_char': 6, 'DW_ATE_unsigned': 7, 'DW_ATE_unsigned_char': 8,
       'DW_ATE_UTF': 0x10}

def unescape(s):
    out, i = [], 0
    while i < len(s):
        if s[i] == '\\' and i + 1 < len(s):
            nxt = s[i + 1]
            out.append({'n': '\n', 't': '\t', 'r': '\r', '"': '"', '\\': '\\'}.get(nxt, nxt))
            i += 2
        else:
            out.append(s[i])
            i += 1
    return ''.join(out)

def parse_value(attr, raw):
    """-> (kind, value) where kind is 'str' | 'num' | 'flag' | 'ref' | None."""
    v = raw.strip()
    if not (v.startswith('(') and v.endswith(')')):
        return None, None
    v = v[1:-1]
    m = re.match(r'^(0x[0-9a-f]+)\s+"', v)          # a reference: offset plus a name
    if m:
        return 'ref', int(m[1], 16)
    if v.startswith('"') and v.endswith('"'):
        # UNESCAPE. Odin type names really do contain double quotes --
        # `proc"contextless"(a: int) -> bool` is one type's name -- and the
        # dumper escapes them on the way out. Leaving the backslashes in makes
        # the round trip re-escape what was already escaped, which reads as a
        # mismatch in the library and is a defect in this script.
        return 'str', unescape(v[1:-1])
    if v == 'true':
        return 'flag', 1
    if attr == 'language' and v in LANG:
        return 'num', LANG[v]
    if attr == 'encoding' and v in ATE:
        return 'num', ATE[v]
    m = re.match(r'^-?(0x[0-9a-f]+|\d+)$', v)
    if m:
        return 'num', int(v, 16) if 'x' in v else int(v)
    return None, None

def main():
    dump_path, outdir = sys.argv[1], sys.argv[2]
    lines = open(dump_path, errors='replace').read().splitlines()

    cus, cur = [], None
    for ln in lines:
        if 'Compile Unit:' in ln:
            cur = []
            cus.append(cur)
            continue
        if cur is not None:
            cur.append(ln)

    excluded = collections.Counter()
    written = 0
    for n, body in enumerate(cus):
        dies = []           # (depth, tag, offset, [(attr, kind, value)])
        cur_die = None
        for ln in body:
            m = re.match(r'^(0x[0-9a-f]+):(\s*)(DW_TAG_\w+|NULL)\s*$', ln)
            if m:
                if m[3] == 'NULL':
                    cur_die = None
                    continue
                depth = len(m[2]) // 2
                cur_die = [depth, m[3], int(m[1], 16), []]
                dies.append(cur_die)
                continue
            m = re.match(r'^\s+DW_AT_(\w+)\s+(\(.*\))\s*$', ln)
            if m and cur_die is not None:
                attr = m[1]
                if attr not in INCLUDE:
                    excluded[attr] += 1
                    continue
                kind, value = parse_value(attr, m[2])
                if kind is None:
                    excluded[attr + ' (unparsed value)'] += 1
                    continue
                cur_die[3].append((attr, kind, value))
        if not dies:
            continue

        index_of = {d[2]: i for i, d in enumerate(dies)}
        out = []
        for depth, tag, _off, attrs in dies:
            parts = [str(depth), tag]
            for attr, kind, value in sorted(attrs):
                if attr == 'const_value' and kind == 'num':
                    # Normalise to the 64-bit pattern. The reference writes
                    # NEGATIVE constants in an unsigned form -- AT_FDCWD is
                    # 18446744073709551516, not -100 -- and this library writes
                    # sdata, so the two print differently while meaning the same
                    # bits. Comparing the pattern keeps this a value comparison;
                    # comparing the text would make it a form comparison, which
                    # is explicitly not what this instrument is for. A genuine
                    # sign error still differs, because -100 and -101 do.
                    value = value & 0xffff_ffff_ffff_ffff
                if kind == 'ref':
                    if value not in index_of:
                        excluded['type (out-of-unit reference)'] += 1
                        continue
                    parts.append(f'type={index_of[value]}')
                elif kind == 'flag':
                    parts.append(f'{attr}=1')
                else:
                    parts.append(f'{attr}={value}')
            out.append('\t'.join(parts))
        open(f'{outdir}/cu{n}.canon', 'w').write('\n'.join(out) + '\n')
        written += 1

    for name, count in sorted(excluded.items()):
        reason = EXCLUDED_REASON.get(name, 'not in the compared set')
        print(f'excluded {name} x{count} -- {reason}', file=sys.stderr)
    print(written)

main()
