#!/usr/bin/env python3
"""
resetaudit.py -- does reset_runtime_type_globals cover every CHECKER-OWNED type global?

WHY THIS EXISTS. mir's third condition on #566 (task #572) was "derive the reset list rather than
trust it". Trusting it had already cost one defect: t_fast_math_flags was built from the checker's
allocator and inserted into that checker's intrinsics_scope, yet was absent from the reset list --
sitting on the line directly BELOW t_atomic_memory_order, which is present. Two adjacent
declarations, two identical construction blocks, one reset. Eyeballing the list will not find that;
deriving it does.

THE RULE. A `t_*: ^Type` package global must be nil'd by reset_runtime_type_globals if and only if
it is assigned anywhere OTHER than init_basic_types. init_basic_types builds the target-derived
basics from build_context alone -- those legitimately outlive a Checker and are rebuilt per process,
not per checker. Everything else is resolved out of, or allocated into, some Checker's scopes, so
leaving it set after destroy_checker leaves a dangling pointer for the next session (LEDGER #368).

WHY "ASSIGNED OUTSIDE init_basic_types" AND NOT "MENTIONS allocator". The construction of a
checker-owned type is spread over several statements -- alloc_type_bit_set, create_scope,
alloc_entity_type_name, alloc_type_named -- and only some carry `allocator` on the same LINE as the
global's assignment. Keying on the enclosing PROCEDURE is what makes this robust; keying on the
assignment line's text is what would have missed t_fast_math_flags again.

FAILURE MODES THIS TOOL HAS. It is a static scan, so a global assigned through a pointer or an
alias would be invisible to it. No such site exists today (checked); if one appears, this tool will
quietly under-report -- which is why the counts are printed rather than just a verdict, per #483
(a gate that never fails proves nothing) and #405 (silent failure reads as success).

exit 0 = every checker-owned global is reset AND nothing target-derived is reset by mistake
exit 1 = a discrepancy in either direction

usage: resetaudit.py [CHECKER_DIR]
"""
import os, re, sys, glob, collections

CHECKER = sys.argv[1] if len(sys.argv) > 1 else "/home/kalsprite/dev/odin/core/odin/checker"

# The one procedure whose assignments are legitimately NOT reset.
TARGET_DERIVED_PROC = "init_basic_types"

DECL_RE = re.compile(r'^(t_[a-zA-Z_0-9, ]+):\s*\^Type')
PROC_RE = re.compile(r'^([a-zA-Z_][a-zA-Z_0-9]*)\s*::\s*proc')


def declared_globals(types_path):
    names = set()
    for line in open(types_path):
        m = DECL_RE.match(line)
        if m:
            for n in m.group(1).split(","):
                n = n.strip()
                if n:
                    names.add(n)
    return names


def reset_list(types_path):
    """Names nil'd inside reset_runtime_type_globals."""
    names, inside = set(), False
    for line in open(types_path):
        if line.startswith("reset_runtime_type_globals ::"):
            inside = True
            continue
        if inside:
            if line.startswith("}"):
                break
            m = re.match(r'\s*(t_[a-zA-Z_0-9]+)\s*=\s*nil', line)
            if m:
                names.add(m.group(1))
    return names


def assignment_procs(names):
    """global -> set of enclosing procedure names where it is assigned."""
    out = collections.defaultdict(set)
    pat = {n: re.compile(r'(?<![a-zA-Z_0-9])' + n + r'\s*=(?!=)') for n in names}
    for f in sorted(glob.glob(os.path.join(CHECKER, "*.odin"))):
        cur = "<file-scope>"
        for line in open(f):
            m = PROC_RE.match(line)
            if m:
                cur = m.group(1)
            if cur == "reset_runtime_type_globals":
                continue  # the nils themselves are not construction
            for n, p in pat.items():
                if p.search(line):
                    out[n].add(cur)
    return out


def main():
    types_path = os.path.join(CHECKER, "types.odin")
    declared = declared_globals(types_path)
    reset = reset_list(types_path)
    assigned = assignment_procs(declared)

    checker_owned, target_derived, unassigned = set(), set(), set()
    for n in declared:
        procs = assigned.get(n, set())
        if not procs:
            unassigned.add(n)
        elif procs == {TARGET_DERIVED_PROC}:
            target_derived.add(n)
        else:
            checker_owned.add(n)

    # Two failure directions, and only one of them is a defect.
    #
    #   missing  -- checker-owned but NOT reset. A dangling pointer into a destroyed checker.
    #   spurious -- reset although it is TARGET-DERIVED. Resetting one of those is an outright bug
    #               (init_basic_types is reached through a `t_int == nil` guard, so a nil'd global
    #               would never be rebuilt). This is what #577 fixed for t_equal_proc/t_hasher_proc.
    #
    # Globals that are reset but NEVER ASSIGNED AT ALL are neither: nil'ing a permanent nil is inert.
    # They are a real finding, but a different one (a missing writer -- see #577's tail, the 27
    # t_type_info_*_ptr slots C++ assigns in init_core_type_info and the port does not), so they are
    # reported as a NOTE and do NOT fail the gate. Gating on them would leave this tool permanently
    # red, which per #483 makes it prove exactly as little as one that never fails.
    missing = sorted(checker_owned - reset)
    spurious = sorted((reset & target_derived) - unassigned)

    print("RESETAUDIT declared=%d reset=%d checker_owned=%d target_derived=%d unassigned=%d"
          % (len(declared), len(reset), len(checker_owned), len(target_derived), len(unassigned)))

    if unassigned:
        print("  NOTE never-assigned globals (%d): %s" % (len(unassigned), " ".join(sorted(unassigned))))

    for n in missing:
        print("  MISSING-FROM-RESET %-32s assigned in: %s" % (n, ", ".join(sorted(assigned[n]))))
    for n in spurious:
        where = ", ".join(sorted(assigned.get(n, {"<nowhere>"})))
        print("  RESET-BUT-TARGET-DERIVED %-25s assigned in: %s" % (n, where))

    print("RESETAUDIT-DONE missing=%d spurious=%d" % (len(missing), len(spurious)))
    return 1 if (missing or spurious) else 0


if __name__ == "__main__":
    sys.exit(main())
