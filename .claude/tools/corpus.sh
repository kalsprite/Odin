#!/usr/bin/env bash
# corpus.sh <PORT_BIN> [PROBE_ROOT] -- run cmpfull.py over the CURATED probe corpus.
#
# WHY THIS EXISTS. The corpus was previously "every directory in the scratchpad that contains a
# .odin file", reconstructed by hand each time. That is not a corpus, it is a guess, and on
# 2026-08-03 it silently swept in eleven directories that were never probes: Foundation bisect
# scratch from #277, C-style-type scratch from #261, and four vet-mode probes that need the
# -vet harness. They reported FULL-DIFFER, which looks exactly like a regression. It took a
# run of the PRE-change binary to show all eleven differed identically before the change.
#
# The membership list below is therefore explicit, and every exclusion is NAMED WITH ITS REASON.
# An excluded probe is an UNMEASURED probe, not a clean one -- the exclusions are printed.
#
# Add a probe by adding its directory name to CORPUS. Do not re-derive this list from a glob.

set -o pipefail
PORT="$1"
ROOT="${2:-/tmp/claude-1000/-home-kalsprite-dev-odin/5ae0f352-0d85-4f59-825d-514e4ce56a75/scratchpad}"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- Curated corpus: plain-mode probes, compared with `odin build` on both sides -------------
CORPUS=(
  an1 fieldvet filevet gx_all4 gx_base gx_plus_fixed
  gx_plus_soa gx_plus_string gy_empty_variadic gy_one_value gy_two_values matcnt1
  matcnt2 p_ap1 p_ap2 p_clob p_cte2 p_cte3
  p_grpC polycyc pp1 p_pv p_pv2 probe_size
  probe_size_ctl p_ti px_group px_group2 px_variadic soa_mina
  soa_minb soa_minc swval sx_slice_badfld sx_soa_arr_bad sx_soa_badfld
  sx_soa_dyn_bad sx_soa_goodfld sx_soa_ok ti1 ti2 typearg
  vetstyle mxidx trunc divwarn finidis objcsuper objcimpl objcnamed objcctx2 dupdefault sel288 sel288b u288 objcdup objcdup2 instty3 instty5 p_cte p_cte1 fieldclose sepgap postdir2 pd3 bcval dirw
  # #579 (merge a64cb7bfd / PR #7227) overload-scoring refinements. These two exist because the
  # 323-package parity corpus could NOT distinguish "ported correctly" from "ported nothing":
  # both changes are inert across every package, so a clean sweep proved neither. Each probe goes
  # AMBIGUOUS on the pre-#579 checker and resolves on the post-merge oracle, so they can fail --
  # which is what makes them worth running.
  # Both are compared with `odin build`, so both need a `main` -- a probe without one scores as a
  # difference on the entry-point error alone, which is a comparator artefact and not a finding.
  #   p579def  untyped constant prefers its DEFAULT type: f(1) over f(int)/f(i64) picks int
  #   p579val  candidate ordering: proc($S: string) beats proc(x: $T)
  #   p579def2 dummy_argument_count, default arm: h(1) picks proc(x: int) over proc(x: int, y := 0)
  #   p579vard dummy_argument_count, variadic arm: v(1) picks proc(x: int) over proc(x: int, ..int)
  p579def p579val p579def2 p579vard
  # #571. Constant string slicing: an inverted constant range (the "[%d > %d]" message) and a
  # non-constant index into a constant string (which the port used to accept silently).
  # NOT added: the sibling probe `S :: "hello"; x := S[3:1]`, which the ORACLE cannot check --
  # it dies on src/string.cpp(77) `lo <= hi && hi <= max`. A probe whose reference side aborts
  # cannot be a corpus member; the port's guarded behaviour there is a documented divergence.
  p571sl
  # #584. check_index: three divergences in one probe -- the 'Cannot index a constant' message
  # and its Suggestion, and an INVENTED `if !index_ok { .Invalid; return }` bail that suppressed
  # the assignment diagnostic on the following line (oracle 3 diagnostics, port 2).
  p584a
  # #305 file-tag parsing. One probe per distinct path through parse_file_tag /
  # parse_vet_tag / parse_feature_tag, not one per syntactic variation:
  #   vettag  bare `#+vet` turns every vet check on
  #   vettag2 invalid vet flag name + the 13-line list
  #   vettag3 `!` negation, and the Unknown-tag catch-all
  #   vettag4 "Expected a space after #+vet", and the feature-flag list
  #   vettag6 a bad tag in ONE file suppresses the WHOLE package's semantic pass
  #   vt_b    a delimiter rune is returned as its own token and reported as a bad name
  #   vt_c    a bare `!` with no name after it
  #   vt_e    two integer-division-by-zero flags at once
  #   vt_f    notting a flag that does not support it
  #   vt_m    a comma is a bad flag name, NOT a separator
  #   vt_n    tags are case-sensitive, and the message carries the whole tag text
  vettag vettag2 vettag3 vettag4 vettag6 vt_b vt_c vt_e vt_f vt_m vt_n
  # #307. Only vt_nopkg is a corpus member -- see EXCLUDED for its two siblings.
  #   vt_nopkg  a lone package-less file: used to SEGFAULT the checker 20/20; now reports
  #             "Expected a package declaration at the beginning of the file" and nothing else
  vt_nopkg
  # #306 build-tag diagnostics, one probe per C++ error condition in parse_build_tag /
  # parse_build_project_directory_tag. Each a.odin carries the malformed tag plus a package
  # clause; b.odin keeps the package resolvable and supplies main.
  #   bt_space  "Expected a space after #+build"          (#+buildlinux)
  #   bt_bang   "Expected a build platform after '!'"     (#+build !)
  #   bt_comma  "Invalid build tag: Missing ',' before"   (#+build linux windows)
  #   bt_subt   "Invalid subtarget"                       (#+build darwin:bogussub)
  #   bt_plat   "Invalid build tag platform"              (#+build bogusplatform)
  #   bt_projb  "Expected a build-project-name after '!'" -- ALSO the #24 use-after-free repro:
  #             this segfaulted 15/15 on three pre-change binaries
  #   bt_dbg    two malformed tags in one file, so the pass is proven not to stop at the first
  bt_space bt_bang bt_comma bt_subt bt_plat bt_projb bt_dbg
  # #385. The two named-argument LABEL sites in check_call_arguments_proc_group. Both used to
  # index split_args.named with a counter that did not track the operand -- one never incremented
  # at all, one shared with the comma counter -- reproducing C++ faithfully at the time (#156).
  # Upstream rewrote the lambda; these probes pin the corrected labelling so it cannot drift back.
  #   nameidx   the "Given argument types:" block -- must print `alpha =` then `beta =`
  #   nameidx2  the try_addr "Suggestion:" line -- same, with a leading positional and an `&`
  nameidx nameidx2
  # #385/#225. The integer-literal exponent branch, one line per rejected form in a.odin and
  # the accepted contrast set in b.odin. Upstream replaced two GB_ASSERTs (`base == 10`,
  # `text[i] != '-'`) that ABORTED the compiler with early `success = false` returns, so forms
  # like `0b1e5` and `0d1e-5` went from "no oracle behaviour to match" to a syntax error. The
  # port had accepted them silently, which became a real under-rejection the moment the
  # assertions went away. The predicate lives in TWO places -- the parser's
  # integer_value_is_valid and the checker's big_int_from_string -- so this probe pins both.
  intlit
  # #386. Upstream PR #7208 deleted the "polymorphic procedure as default value"
  # short-circuit from check_is_assignable_to_with_score. It returned true with score 1 for
  # ANY polymorphic procedure assigned to ANY concrete proc type, on the promise that it
  # "will be properly instantiated when actually used" -- so a polymorphic procedure that
  # could never instantiate to the target was accepted without complaint. a.odin holds one
  # rejected shape per declaration (arity 2v1, arity 1v2, result 0v1); b.odin holds the
  # accepted contrast, a polymorphic proc that DOES fit, used both as the default and passed
  # explicitly. Nothing in the plain corpus or either parity sweep reached this site.
  polydef
  # #388/#389, the two parse_package/parse_stmt error-path defects found by triaging the 22
  # oracle-nonzero packages that #331 had deferred.
  #   rsvpkg  `package builtin` then a bare `typeid`. The reserved-name error must NOT suppress
  #           the file body: C++ raises it through the file-UNAWARE syntax_error(Token), which
  #           cannot bump f->error_count, and the decl loop is gated on that count.
  #   unktag  `#bogus` at file scope -- the statement-level unknown-tag catch-all. The port used
  #           to build a Tag_Stmt silently and let the file-scope check reject it with a
  #           different message.
  rsvpkg unktag
  # #390 the `#define` and `#include` arms of parse_stmt's tag dispatch. One probe per distinct
  # path through the arm, not per syntactic variation:
  #   defprobe  `#define FOO 1`      object-like with a body -> the expr_to_string Suggestion
  #   defexpr   `#define FOO 1 + 2*3`  same path, but pins the printer past a single literal
  #   defcall   `#define FOO(x) x*2`   adjacent paren -> call_like -> Note, NOT a Suggestion
  #   defcall3  `#define FOO()`        empty arg list; also the nil-operand parse_call_expr crash
  #   defbare   `#define FOO`          ident, no body -> Note
  #   defspc    `#define FOO (x)`      paren NOT adjacent, so NOT call_like -> Suggestion
  #   defnum    `#define 123`          next token is not an ident; message anchors on it anyway
  #   defnone   `#define`              nothing on the line -> the '#'-anchored fallback branch
  #   definc    `#include "stdio.h"`   the sibling arm: text, anchor and fix_advance all differed
  defprobe defexpr defcall defcall3 defbare defspc defnum defnone definc
  # #390 also unblocked the `Foo[]` Suggestion (parser.cpp:3369-3373), declined twice before
  # for want of a continuation channel (#307 added it) and an expression printer (#390 did).
  #   opidx   `x: Foo[]` in a type position -- allow_type set, so the Suggestion IS emitted.
  #           The POSITIVE control: without it this probe still passes at 1 line.
  #   opidx2  `v[]` on a value -- allow_type clear, so the Suggestion must NOT appear
  #   opidx3  `Bar :: Foo[]` -- also 1 line; pins that the gate is allow_type and not merely
  #           "the operand names a type"
  opidx opidx2 opidx3
  # #391 proc-group candidacy with an INVALID argument. C++ (check_expr.cpp:6954-6958) skips an
  # invalid operand instead of scoring it, so every candidate survives and the group reports
  # "Ambiguous procedure group call". The port had that guard on its named-argument path only,
  # so a positional call rejected every candidate and reported "No procedures or ambiguous
  # call" plus a package-qualified overload list.
  #   pgbad   a failed `#load` passed to a two-member group -- the whole divergence in 3 lines
  pgbad
  # #392 `context` as a default parameter value (check_type.cpp:1807-1809).
  #   ctxdef  `proc(ctx := context)` -- LEGAL, and vendor/libc-shim's set_context is this
  #           exact shape. The port rejected it ("Default parameter must be a constant, got
  #           context") and then cascaded a bogus missing-parameter error at every call.
  #   pandep  a `#panic` in a DEPENDENCY package plus two type errors in the dependent. Both
  #           compilers report all three. Kept as the standing refutation of "a compile-time
  #           panic upstream suppresses downstream diagnostics" -- hypothesis 3 of #335 -- so
  #           that it does not get re-derived.
  ctxdef pandep
  # #401 fix_advance_to_next_stmt's progress test was INVERTED, so recovery skipped the very
  # statement-start token it should have stopped on.
  #   soarec  `soa_zip :: proc(slices: ...) -> #soa[]Struct ---` -- the base/builtin.odin:349
  #           shape. Three agreed diagnostics, then the oracle recovers onto `#soa` and reports
  #           the unknown tag; the port used to skip it. This is also the last residual of
  #           #337/#388 -- base/builtin is byte-identical at 15/15 with it fixed.
  soarec
  # #308 tag ORDER. C++ walks a file's tags in source order and stops at the first EXCLUDING one.
  #   bt_order   `#+build windows` then `#+vet bogusname` -- excluded first, so silent
  #   bt_order2  `#+vet bogusname` then `#+build windows` -- vet reported, THEN excluded
  bt_order bt_order2
  # #309 fixed-capacity dynamic array compound literals (found via the #7 newdiag worklist).
  #   n7_fixok   `[dynamic; 4]int = {1, 2}` -- LEGAL; the port used to reject it outright
  #   n7_fixcap  `[dynamic; 2]int = {1,2,3}` -- capacity overflow + the index out-of-bounds line
  n7_fixok n7_fixcap
  # #310 bit-set operators and the default-parameter message (from the #7 newdiag worklist).
  #   n7_bs_m       `a * b` on bit sets -- REJECTED now; the port used to accept it
  #   n7_bs_q       `a / b` -- bit-set-specific message, not the numeric one
  #   n7_bs_s/p     `a - b` / `a + b` -- still legal (difference / union), guards the fix
  #   n7_bs_nonnum  non-numeric non-bit_set -- plain "numeric expressions", no "or bit_sets"
  #   n7_dashdash   `x: int = ---` as a DEFAULT PARAMETER has its own message
  n7_bs_m n7_bs_q n7_bs_s n7_bs_p n7_bs_nonnum n7_dashdash
  # #311 size_of(&x) warning -- ALSO the regression guard for warning_node's caret range, which
  # #302 fixed for error_node and missed here. The oracle underlines `&x` with `^^`.
  n7_sizeof
  # #312 struct #simple field validation.
  #   n7_simp1/2  a non-nearly-simple field (string, []int) is rejected
  #   n7_simp3    all-valid fields stay clean -- the over-reach guard
  #   n7_simp4    a #simple struct nested in another, which exercises the is_simple early-out
  n7_simp1 n7_simp2 n7_simp3 n7_simp4
  # #314 check_shift rebuilt from C++, plus the three simd Suggestion lines.
  #   n7_sshl    `v << s` on #simd with a SIGNED amount -- the whole point: C++ faults the
  #              AMOUNT and suggests simd.shl; the port used to fault the OPERAND instead
  #   n7_stern   a #simd condition in a ternary -> "Use 'simd.select'"
  #   n7_sidx    indexing a #simd vector -> "Use 'simd.extract' or 'simd.replace'"
  #   n7_shctl / n7_tectl / n7_ixctl  the same three shapes on NON-simd types: the
  #              over-reach guards, proving the Suggestion is gated and not unconditional
  #   n7_sh2000  shift amount above MAX_BIG_INT_SHIFT -> "must be <= 1024"
  #   n7_shneg   negative shift amount -> "cannot be negative" (expression, not value)
  #   n7_shhint  untyped constant shift against a non-integer type_hint
  n7_sshl n7_stern n7_sidx n7_shctl n7_tectl n7_ixctl n7_sh2000 n7_shneg n7_shhint
  # #316 label-as-expression, and the directive-call inlining/tailing diagnostics.
  #   n7_label    `x := loop` on a loop label -- was accepted silently
  #   n7_inldir   `#force_inline #config(...)` -> "Inlining directives ..."
  #   n7_inldir2  recognised name whose HANDLER fails -- the check still fires
  #   n7_inlord   `#force_inline #load(missing)` -- pins that only the inlining error appears
  #   n7_inlbi    `#force_inline len(...)` -- the "Inlining OPERATORS" sibling, already
  #               ported; kept as the guard that the two messages stay distinct
  n7_label n7_inldir n7_inldir2 n7_inlord n7_inlbi
  # #319 inline-asm directive validation.
  #   n7_asmbad  `#bogus` on an asm expression -- was accepted in silence
  #   n7_asmdup  duplicate #side_effects and conflicting #att/#intel: the ANCHOR probe.
  #              All five messages pointed at the `asm` keyword, not the offending directive.
  n7_asmbad n7_asmdup
  # #320 the inline-asm PROC TYPE. n7_asmok was an EXCLUDED #320 repro; it is a corpus member
  # now that the arm builds a Type_Proc with the .Inline_Asm convention.
  #   n7_asmok    valid asm bound to a variable -> "Invalid use of inline asm in variable
  #               declaration". This is the probe that was dead: the check existed and was
  #               faithful, but is_type_asm_proc could never be true.
  #   n7_asmpb    asm at FILE scope -> "only allowed within a procedure body"
  #   n7_asmstr   a non-constant asm string -> "Expected a constant string for the inline asm
  #               main parameter" (the port used to word this differently)
  #   n7_asmpt    an undefined PARAMETER type -- the port never checked param types at all
  n7_asmok n7_asmpb n7_asmstr n7_asmpt
  # #321 `#must_tail`: parser dispatch + the checker's type-identity diagnostic.
  #   n7_mtail3  VALID #must_tail, types match -- oracle is SILENT and the port used to emit a
  #              syntax error. The over-rejection, and the reason this was not "just" a missing
  #              diagnostic.
  #   n7_mtail2  types differ -> the message plus "Call type: ..., parent type: ..."
  #   n7_mtail   the STACKED form `#force_no_inline #must_tail f()`, which also proves the
  #              outer directive no longer erases the inner one's tailing flag
  n7_mtail n7_mtail2 n7_mtail3
  # #322 the parser's span-carrying error channel. These three were EXCLUDED one tick earlier
  # with the correct message at the correct position and a one-column caret; they are members
  # now that error_node/err_range exist, and they are what proves the channel end-to-end.
  #   n7_mtailpl    #must_tail on a procedure literal
  #   n7_mtailbad   #must_tail on a non-callable, naming the node kind
  #   n7_mtailboth  #force_inline #force_no_inline on one literal
  n7_mtailpl n7_mtailbad n7_mtailboth
  # #322 part 2 -- node-anchored parser diagnostics converted to error_node.
  #   c22_blockstmt  "Expected a normal statement rather than a block statement"
  #   c22_do         "'do' has been disallowed" under -strict-style
  #   c22_paren      "Expected a type within the parentheses"
  c22_blockstmt c22_do c22_paren
  # #323 the Ellipsis node's position. c22_vararg2 was EXCLUDED one tick earlier -- the span
  # #322 added made a pre-existing off-by-two anchor visible.
  #   c22_vararg2   "Extra variadic parameter after ellipsis", now anchored at the `..`
  #   c23_varname   "Variadic parameters can only have one field name", the sibling site
  #   c23_varok     a VALID variadic proc -- the over-reach guard, since the position change
  #                 touches EVERY Ellipsis node, not just the two that carry diagnostics
  c22_vararg2 c23_varname c23_varok
  # #324 the last three node-anchored parser sites. Two needed only the span; the third
  # needed the ANCHOR changed as well -- see the ledger.
  #   c24_blank    "Invalid polymorphic type definition with a blank identifier"
  #   c24_complit  "Expected a compound literal after #partial, got ..."
  #   c24_tid      "Specialization of typeid is not allowed without polymorphic names",
  #                written PARENTHESISED so the type-vs-unparen'd-tt anchor is exercised
  c24_blank c24_complit c24_tid
  # #315 the blank-assignment path. n7_biglit / n7_sh200 / n7_sh100 were EXCLUDED as #315
  # repros since #314; they are members now.
  #   c15_blank  `_ = X` with X = 2^200 -- the repro
  #   c15_typed  `x: int = 2^200` -- already matched, kept as the discriminator that proved
  #              the expressibility check itself was fine
  #   c15_arg    `f(X)` -- likewise, the call-site path
  #   c15_ctl    a plain valid `_ = y` -- the over-reach guard, since removing the skip makes
  #              check_assignment_variable run for EVERY blank assignment
  c15_blank c15_typed c15_arg c15_ctl n7_biglit n7_sh200 n7_sh100
  # #325 part 1: the file-scope simple-statement guard, which the port had COMMENTED OUT.
  #   c25_filescope  `x = 2` at file scope -- was accepted in silence
  #   c25_ok         valid file-scope decls AND in-proc =, +=, *= -- the over-reach guard,
  #                  since the restored guard sits on EVERY assignment operator
  #   c25_ops        `y += 1` at file scope, the compound-operator form
  c25_filescope c25_ok c25_ops
  # #326: parse_setup_file_decls, the post-parse file-scope walk the port never had.
  #   c26_exprstmt  `f()` at file scope -- "Only declarations are allowed at file scope, got
  #                 expression statement", the phase's own diagnostic
  #   c26_when      the SAME call inside `when true { }`. This one is why the phase needs
  #                 parse_setup_file_when_stmt: a when body's stmts never enter file.decls, so a
  #                 flat loop over decls cannot see them and the port was silent here.
  #   c26_dirstmt   `#assert(1 == 1)` at file scope -- SILENT on both sides. The over-reach guard:
  #                 the gate must let a directive ExprStmt through (it feeds directive_count),
  #                 so this probe fails the moment the exemption is dropped.
  c26_exprstmt c26_when c26_dirstmt
  # #327: import-path validation in that phase, plus the foreign-import decl's three C++ branches.
  #   c27_absimp   import "/usr/lib/whatever" -- was reported by the CHECKER as "Unable to find
  #                package", i.e. wrong message, wrong stage, wrong severity
  #   c27_winimp   import "C:/some/path" -- the same defect via the drive-letter rule, and the
  #                probe that pins is_import_path_absolute as NOT platform-conditional: the
  #                reference rejects a Windows path while running on Linux
  #   c27_fgnabs   foreign import lib "/abs/libfoo.a" -- port was SILENT, a pure under-rejection
  #   c27_fgnzero  foreign import lib {} -- anchor was at `import`, not the library name; also
  #                the probe that caught the DOUBLE report when the zero-path arm returned a real
  #                decl instead of C++'s Bad_Decl
  #   c27_fgnproc  foreign import inside a procedure body -- the whole branch was missing
  c27_absimp c27_winimp c27_fgnabs c27_fgnzero c27_fgnproc
  # #328: slice-checking arms. n8_forsemi is deliberately ABSENT -- it was my bad probe, both
  # compilers emit the same recovery there, so it tests nothing.
  #   n8_enumslice    slicing a [E]int -- message wording, the missing 'slice.enumerated_array'
  #                   Suggestion, and the o->expr anchor, all three at one site
  #   n8_fixcapslice  `f()[:]` on a [dynamic; N]T return -- the addressability guard the port's
  #                   own comment cited and never wrote
  n8_enumslice n8_fixcapslice
  # #331 simd reduce predicate + the #unroll Suggestion.
  #   n9_simdbool  #simd[4]f32 -- the message, now naming boolean OR integer
  #   n9_simdint   #simd[4]i32 -- THE over-rejection probe: legal to the reference, the port
  #                used to reject it. This is the member that would catch a narrowing regression;
  #                n9_simdbool alone would not.
  #   n9_unroll    #unroll for over a slice -- the conditional Suggestion line
  #   n9_unrollctl #332: `#unroll for x in a` over a fixed [3]int -- LEGAL. Was rejected as "not
  #                known at compile time" because the port's guard dropped C++'s inline_for_depth
  #                conjunct. It was NOT a corpus member while it failed; it is one now.
  n9_simdbool n9_simdint n9_unroll n9_unrollctl
  # #334 the polymorphic type-to-value Suggestion.
  #   na_polytype  `f(int)` where `f :: proc(x: $T)` -- error + Suggestion
  #   na_polyval   `f(1, "s")` -- a genuine VALUE mismatch: error and NO Suggestion. The
  #                over-reach guard, since C++ gates the line on operand.mode == Type.
  # #335 the #c_vararg pair, now fixed and both members.
  #   na_cvararg  naming a `#c_vararg` param directly -> error + c_va_start Suggestion. Also the
  #               regression guard for the REMOVED body/foreign over-rejection: if that check
  #               came back, this probe would report it instead.
  #   na_cvok     `intrinsics.c_va_start(&list, args)` -- names the SAME parameter legally and
  #               must stay SILENT. This is what proves allow_c_vararg_param is wired; without it
  #               the new check rejects here. NOTE: the first version of this probe used
  #               `c.va_start`, which does not exist -- both sides failed identically on an
  #               undeclared name and the control was VACUOUS while appearing to pass.
  na_polytype na_polyval na_cvararg na_cvok
  # #336 address-of an undetermined type -- one C++ site, two worklist messages.
  #   nb_addr   `x := &x` -- error WITHOUT the Suggestion (operand is undeclared, not a Variable)
  #   nb_addr2  `a := &b; b := &a` -- exercises the gate BOTH ways in one file: bare error for
  #             'b', error+Suggestion for 'a'. An unconditional Suggestion fails this, and so
  #             does a Suggestion that never fires.
  nb_addr nb_addr2
  # #337 convert_stmt_to_expr's anchor: statement start vs current token.
  #   nb_forsemi   `for x := 0 x < 3 {` -- the shape that exposed it
  #   nb_ifsimple  `if x := 1 {`        -- the SAME helper via a different caller
  nb_forsemi nb_ifsimple
  # #338 deferred-procedure chaining.
  #   nc_defchain  a -> b -> c : rejected. Was accepted in SILENCE.
  #   nc_defok     a -> b      : still accepted -- guards against an over-eager chaining check
  nc_defchain nc_defok
  # #339 `for init; ; {` -- a missing diagnostic plus a truncated one.
  #   nd_forsemi2 / nd_fordo  the two trigger tokens C++ names ({ and do)
  #   nd_forok    a normal 3-clause for AND one with an empty post but a real condition; both
  #               must stay silent, so an over-eager check fails here
  nd_forsemi2 nd_fordo nd_forok
  # #317 the Basic_Directive node's END, and the Unknown-directive anchor. All three were
  # EXCLUDED #317 repros; they are members now.
  #   n7_inlctl    "Failed to `#load` file" -- caret marks the `#`, not `#load`
  #   n7_inldir3   "Unknown directive: #x" -- anchored at the DIRECTIVE, not the call
  #   n7_inlscope  two #loads, one inlined -- the second load's caret
  n7_inlctl n7_inldir3 n7_inlscope
)

# --- Deliberate exclusions, each with the reason it is not a corpus member --------------------
# name                reason
EXCLUDED=(
  # All five re-probed 2026-08-04 (LEDGER #378). probe.sh reports MATCH for four of them; cmpfull.py
  # reports FULL-DIFFER for the same four. cmpfull is right and probe.sh is the looser instrument --
  # see the ledger. Reasons below are what the FULL comparison actually shows, not what probe.sh says.
  "fb|Foundation bisect scratch (#277/#278). probe.sh says MATCH; the FULL diff is 16 lines. Still excluded."
  "fb2|Foundation bisect scratch, deliberately truncated: SEL/BOOL/UInteger are USED but never DECLARED. 19 diagnostics each side at identical positions, differing on which of Undeclared-name vs is-not-a-type 4 of them get. The plain undeclared-name path MATCHES in isolation, in a foreign block, and in a proc type -- so this is recovery CLASSIFICATION after a cascade in a fragment with no declaration source, not an isolable rule."
  "fbisect|as fb; FULL diff is 15 lines."
  # SINGLE-quoted deliberately. This note names two commands, and in a DOUBLE-quoted array
  # element bash command-substitutes the backticks AT CONSTRUCTION time -- the exclusion
  # block then printed ~40 lines of `odin` usage text, twice, burying the list of what was
  # NOT measured. Cosmetic in effect, but it is command execution from a data string, and
  # this block exists precisely to stay legible. Keep single quotes for any note with ` or $.
  'objchang|#277 scratch. Message text and position divergences FIXED in #378. The residual is a HARNESS MISMATCH, not a port defect (#379): cmpfull.py runs the oracle as `odin build`, triage_st sets command_kind={.Check}, and C++ suppresses "only works on darwin" under Command_check/Command_doc (check_builtin.cpp:284). Oracle as `odin check` emits 0 of them, same as the port. Excluded until the comparators agree on which command they emulate.'
  "p_ppp|#196 scratch: the oracle emits a <nopos> Note continuation block the port does not. #155 records that the older comparator could not even SEE continuation lines; cmpfull can, and they are genuinely absent."
  "shadowparam|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "shadowvar|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "vetctl|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "vetmap|vet-mode probe -- a member of the VET corpus (corpus_vet.sh), which now exists and runs it; TEXT-MATCH as of #384. Excluded HERE only because this harness is the plain one."
  "objcctx|#285 UPSTREAM: the ORACLE segfaults on this 6/6 (zero-param @(objc_context_provider)). Port is correct; kept on disk as the repro"
  "vt_nopkg2|#307: the ORACLE is nondeterministic on the 'Suggestion: Add package ...' line -- it emitted it in 3/20 runs here (C++ parser.cpp:6863 calls this a race itself). Port is deterministic and matches the 17/20 majority; a fixed-expectation comparator cannot score it"
  "vt_nopkg3|#307: as vt_nopkg2, from the other side -- oracle emits the Suggestion in 19/20 runs, port always does, so it matches the majority but differs on the odd run"
)

if [ -z "$PORT" ]; then echo "usage: corpus.sh <PORT_BIN> [PROBE_ROOT]" >&2; exit 2; fi

dirs=()
missing=0
for p in "${CORPUS[@]}"; do
  if [ -d "$ROOT/$p" ]; then dirs+=("$ROOT/$p"); else
    printf "MISSING-PROBE %s\n" "$p"; missing=$((missing+1))
  fi
done

# The comparator's exit status is CHECKED, and the summary below is not printed without it.
# Until 2026-08-04 this call was unguarded: if cmpfull.py died, it printed nothing, the shell
# carried on, and "CORPUS-DONE members=176" appeared exactly as it does on a clean run. I hit that
# for real while A/B-testing a modified comparator -- the copy resolved its repo root from its own
# path, could not find ./odin, and threw on every single probe. The run reported 176 members and
# had compared ZERO. Same species as #275/#367/#369/#370: a summary that looks like a result for
# work that did not happen. LEDGER #380.
# Capture the status into a variable FIRST. `if ! cmd; then ... $? ...` reports the IF's status,
# not the command's, so the first version of this guard printed "exit 0" while aborting -- the same
# read-$?-through-a-construct mistake that gave a wrong answer twice today through pipelines.
python3 "$HERE/cmpfull.py" "$PORT" "${dirs[@]}"
cmp_rc=$?
if [ $cmp_rc -ne 0 ]; then
  echo "CORPUS-ABORTED comparator failed (exit $cmp_rc) -- NOTHING below is a measurement" >&2
  exit 1
fi

echo "--- exclusions (UNMEASURED, not clean) ---"
for e in "${EXCLUDED[@]}"; do printf "  %-14s %s\n" "${e%%|*}" "${e#*|}"; done
echo "CORPUS-DONE members=${#CORPUS[@]} missing=$missing excluded=${#EXCLUDED[@]}"
