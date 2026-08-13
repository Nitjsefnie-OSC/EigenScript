#!/bin/bash
# Regression: deeply nested prefix (`not`/`-`/`~`) and right-recursive `of`
# expressions must hit the parser depth guard and exit cleanly, never overflow
# the C stack (SIGSEGV rc 139). These recursion families bypassed the
# parse-depth guard before — a single malformed line crashed the runtime, which
# a public language must never do. A clean parse-error exit (rc 1) is correct.
set -u
TESTS_DIR="$(cd "$(dirname "$0")" && pwd)"
BIN="$(cd "$TESTS_DIR/.." && pwd)/src/eigenscript"

check_no_crash() {
    local name="$1" prog="$2"
    local f; f=$(mktemp /tmp/eigs_pd_XXXXXX.eigs)
    printf '%s' "$prog" > "$f"
    "$BIN" "$f" >/dev/null 2>&1; local rc=$?
    rm -f "$f"
    # 139 = SIGSEGV (stack overflow), 134 = SIGABRT. Anything else (0/1) is a
    # clean handle.
    if [ $rc -eq 139 ] || [ $rc -eq 134 ]; then
        echo "  FAIL: $name (crash rc=$rc)"
    else
        echo "  PASS: $name (clean rc=$rc, no crash)"
    fi
}

check_no_crash "unary 'not' nesting bomb" "x is $(printf 'not %.0s' $(seq 1 50000))1"
check_no_crash "unary '-' nesting bomb"   "x is $(printf -- '-%.0s' $(seq 1 200000))1"
check_no_crash "'of' relation nesting bomb" "x is $(printf 'f of %.0s' $(seq 1 100000))1"
check_no_crash "mixed prefix nesting bomb" "x is $(printf 'not -~%.0s' $(seq 1 40000))1"

# Iterative chains (postfix accessors, left-assoc binops) build a deep AST
# without recursing, so they bypassed the parse-depth guard and overflowed the
# recursive compiler / free_ast walkers — a distinct vector from the prefix
# bombs above. They must be bounded, not crash.
check_no_crash "postfix index chain bomb"  "x is a$(printf '[0]%.0s' $(seq 1 1000))"
check_no_crash "postfix dot chain bomb"    "x is a$(printf '.b%.0s' $(seq 1 100000))"
check_no_crash "binop '+' chain bomb"      "x is 1$(printf '+1%.0s' $(seq 1 100000))"
check_no_crash "binop '&' chain bomb"      "x is 1$(printf '&1%.0s' $(seq 1 100000))"
check_no_crash "logical 'and' chain bomb"  "x is 1$(printf ' and 1%.0s' $(seq 1 100000))"

# --- #926: the elif chain is a flat construct that recurses in C -----------
# Each `elif` desugars to a nested `if` by recursing in parse_statement, and
# that recursion never charged the shared parse-depth counter — so past
# ~12,800 arms the parser exhausted the C stack (SIGSEGV rc 139) before the
# compiler's depth limit could reject the program, and --lint (which never
# runs the compiler) had no depth protection on this path at any length. The
# recursion site now charges g_parse_depth BEFORE descending into the next
# arm and tests the bound against the post-charge depth — the depth that
# arm's condition expression actually parses at. (Testing pre-charge, the
# chain_too_deep order, is dead code at this site: parse_expression's own
# guard on the same counter trips one level earlier — measured zero fires
# at 14,000 arms — so error recovery, not the bound, ended the chain.)
# Consequences pinned here:
#   * well below the bound behaviour is byte-identical — a 200-arm chain
#     still parses and is still refused by the COMPILER's own 128 limit
#     (plain), and --lint still exits 0;
#   * approaching the bound (253–256 arms on this shape) the first things
#     to cross 256 are the arms' own expressions: each arm parses at the
#     depth charged for it, so `print of N` (and `-1` in the else) descends
#     a few levels deeper transiently and trips the EXPRESSION-level guard
#     — a few parse diagnostics, not a cascade;
#   * at the 257th arm the elif-site bound itself fires (post-charge depth
#     reaches 256): the error is recorded, the unread tail of the chain is
#     drained without further diagnostics, and the chain terminates — so a
#     258-arm chain and a 14,000-arm chain print the SAME small set of
#     errors, instead of ~41,000 cascade lines (and, past ~12,800 arms at
#     base, instead of SIGSEGV);
#   * the charge is released when the statement ends (parse_statement's
#     save/restore), so a chain leaks no depth into what follows it.

gen_elif_chain() {
    # gen_elif_chain N FILE — write an N-arm if/elif/else chain (#926 shape)
    local n="$1" f="$2"
    {
        echo "x is 0"
        echo "if x == 0:"
        echo "    print of 0"
        local i=1
        while [ "$i" -lt "$n" ]; do
            printf 'elif x == %d:\n    print of %d\n' "$i" "$i"
            i=$((i + 1))
        done
        echo "else:"
        echo "    print of -1"
    } > "$f"
}

check_rc_out() {
    # check_rc_out NAME WANT_RC WANT_SUBSTR RC OUT
    local name="$1" want_rc="$2" want_substr="$3" rc="$4" out="$5"
    if [ "$rc" -eq "$want_rc" ] && printf '%s' "$out" | grep -qF "$want_substr"; then
        echo "  PASS: $name (rc=$rc)"
    else
        echo "  FAIL: $name (rc=$rc, wanted rc=$want_rc and '$want_substr')"
        printf '%s\n' "$out" | head -3 | sed 's/^/    /'
    fi
}

ELIF_TMP=$(mktemp -d /tmp/eigs_elif_XXXXXX)

# Below the bound: unchanged behaviour, both modes.
gen_elif_chain 200 "$ELIF_TMP/c200.eigs"
OUT=$("$BIN" "$ELIF_TMP/c200.eigs" 2>&1); RC=$?
check_rc_out "200-arm chain: plain run still hits the COMPILE depth limit" 1 \
    "expression nesting too deep to compile (limit 128)" "$RC" "$OUT"
OUT=$("$BIN" --lint "$ELIF_TMP/c200.eigs" 2>&1); RC=$?
check_rc_out "200-arm chain: --lint still exits 0" 0 "no issues found" "$RC" "$OUT"

# Approaching the bound (this exact chain shape): 252 arms still parse
# cleanly — the deepest transient descent (the else block's `print of -1`,
# four levels below its arm's charged depth) reaches 255. At 253 arms that
# descent crosses 256 and the EXPRESSION-level guard fires — a parse error
# in both modes, from the expression guard rather than the elif bound.
gen_elif_chain 252 "$ELIF_TMP/c252.eigs"
OUT=$("$BIN" "$ELIF_TMP/c252.eigs" 2>&1); RC=$?
check_rc_out "251-elif chain: plain run still hits the COMPILE depth limit" 1 \
    "expression nesting too deep to compile (limit 128)" "$RC" "$OUT"
OUT=$("$BIN" --lint "$ELIF_TMP/c252.eigs" 2>&1); RC=$?
check_rc_out "251-elif chain: --lint still exits 0" 0 "no issues found" "$RC" "$OUT"
gen_elif_chain 253 "$ELIF_TMP/c253.eigs"
OUT=$("$BIN" "$ELIF_TMP/c253.eigs" 2>&1); RC=$?
check_rc_out "252-elif chain: plain run is a PARSE error" 1 \
    "parse error(s)" "$RC" "$OUT"
OUT=$("$BIN" --lint "$ELIF_TMP/c253.eigs" 2>&1); RC=$?
check_rc_out "252-elif chain: --lint is a PARSE error" 1 \
    "parse error(s) [E002]" "$RC" "$OUT"

# 257 elifs (258 arms): the elif-site bound fires refusing the 257th arm —
# the unread tail is drained and the chain terminates with a small, bounded
# set of parse diagnostics in BOTH modes, no longer reaching the compiler
# (and, past ~12,800 arms, no longer crashing).
gen_elif_chain 258 "$ELIF_TMP/c258.eigs"
OUT=$("$BIN" "$ELIF_TMP/c258.eigs" 2>&1); RC=$?
check_rc_out "257-elif chain: plain run is a PARSE error" 1 \
    "parse error(s)" "$RC" "$OUT"
if printf '%s' "$OUT" | grep -qF "too deep to compile"; then
    echo "  FAIL: 257-elif chain still reports the COMPILE depth limit"
    printf '%s\n' "$OUT" | head -3 | sed 's/^/    /'
else
    echo "  PASS: 257-elif chain no longer reaches the compiler"
fi
OUT=$("$BIN" --lint "$ELIF_TMP/c258.eigs" 2>&1); RC=$?
check_rc_out "257-elif chain: --lint is a PARSE error" 1 \
    "parse error(s) [E002]" "$RC" "$OUT"

# 14,000 arms was rc=139 (SIGSEGV) in both modes; now a clean refusal.
gen_elif_chain 14000 "$ELIF_TMP/c14000.eigs"
OUT=$("$BIN" "$ELIF_TMP/c14000.eigs" 2>&1); RC=$?
if [ "$RC" -eq 139 ] || [ "$RC" -eq 134 ] || [ "$RC" -eq 0 ]; then
    echo "  FAIL: 14000-arm chain plain run (crash or silent success, rc=$RC)"
elif printf '%s' "$OUT" | grep -qF "parse error(s)"; then
    echo "  PASS: 14000-arm chain plain run refused cleanly (rc=$RC)"
else
    echo "  FAIL: 14000-arm chain plain run lacks a parse diagnostic (rc=$RC)"
fi
OUT=$("$BIN" --lint "$ELIF_TMP/c14000.eigs" 2>&1); RC=$?
if [ "$RC" -eq 139 ] || [ "$RC" -eq 134 ] || [ "$RC" -eq 0 ]; then
    echo "  FAIL: 14000-arm chain --lint (crash or silent success, rc=$RC)"
elif printf '%s' "$OUT" | grep -qF "parse error(s) [E002]"; then
    echo "  PASS: 14000-arm chain --lint refused cleanly (rc=$RC)"
else
    echo "  FAIL: 14000-arm chain --lint lacks a parse diagnostic (rc=$RC)"
fi

# Depth is charged per statement: a chain just under the bound releases its
# charge when it ends, so the statement after it parses with a full budget.
# (--lint exercises the parser without the compiler's own 128 limit firing.)
gen_elif_chain 251 "$ELIF_TMP/leak1.eigs"
gen_elif_chain 251 "$ELIF_TMP/leak2.eigs"
cat "$ELIF_TMP/leak1.eigs" > "$ELIF_TMP/leak_next.eigs"
echo 'print of "after"' >> "$ELIF_TMP/leak_next.eigs"
OUT=$("$BIN" --lint "$ELIF_TMP/leak_next.eigs" 2>&1); RC=$?
check_rc_out "ordinary statement after a 250-elif chain parses normally" 0 \
    "no issues found" "$RC" "$OUT"
# A second full-length chain is the sharper probe: leaked depth from the
# first would trip the bound almost immediately in the second.
cat "$ELIF_TMP/leak1.eigs" "$ELIF_TMP/leak2.eigs" > "$ELIF_TMP/leak_2x.eigs"
OUT=$("$BIN" --lint "$ELIF_TMP/leak_2x.eigs" 2>&1); RC=$?
check_rc_out "second 250-elif chain parses too (no depth leaked)" 0 \
    "no issues found" "$RC" "$OUT"

rm -rf "$ELIF_TMP"

echo ""
