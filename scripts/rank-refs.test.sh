#!/usr/bin/env bash
# rank-refs.test.sh — assertions for rank-refs.sh, each paired with a red proof.
#
# A passing assertion only means something if it can fail. So every load-bearing
# claim here is re-run against a deliberately broken copy of the script, and the
# test fails if the broken copy still passes. Run:
#
#     bash scripts/rank-refs.test.sh

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/rank-refs.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0

ok()   { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad()  { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

# ---------------------------------------------------------------------------
# Fixtures. Deliberately in the order a real API returns them: `git/matching-refs`
# and `git tag` sort LEXICALLY, so 0.10.0 arrives before 0.4.0 and the last line
# is an OLD release. Any fixture that lists refs in ascending order would let a
# `tail -1` implementation pass, which is the exact defect this suite exists for.
# ---------------------------------------------------------------------------

BUZZ_REFS='mobile-v0.10.0-rc.1
mobile-v0.10.0
mobile-v0.11.0-rc.1
mobile-v0.11.0-rc.2
mobile-v0.4.0
mobile-v0.9.0
mobile-v1.0.0-beta'

BUZZ_PATTERN='^mobile-v[0-9]+\.[0-9]+\.[0-9]+(-rc\.[0-9]+)?$'

OMNI_REFS='v0.10.0
v0.11.0
v0.12.0
v0.12.0.dev20260826
v0.13.0.dev20260902
v0.4.0
v0.4.0rc1
v0.9.0'

OMNI_PATTERN='^v[0-9]+\.[0-9]+\.[0-9]+$'

# run <script> <pattern> <prefix> <refs>  -> prints "stdout|exitcode"
run() {
    local script="$1" pattern="$2" prefix="$3" refs="$4" out rc
    out="$(printf '%s\n' "$refs" | bash "$script" --pattern "$pattern" --prefix "$prefix" 2>/dev/null)"
    rc=$?
    printf '%s|%s' "$out" "$rc"
}

# ---------------------------------------------------------------------------
# Assertions
# ---------------------------------------------------------------------------

# A1 — the lexical trap. 0.11.0-rc.2 is the newest; 0.4.0 is what a lexical
#      sort + tail -1 would return.
a1() {
    local script="${1:-$SCRIPT}" got want
    got="$(run "$script" "$BUZZ_PATTERN" 'mobile-v' "$BUZZ_REFS")"
    want='mobile-v0.11.0-rc.2	0.11.0	110002|0'
    [ "$got" = "$want" ] || { echo "want [$want] got [$got]"; return 1; }
}

# A2 — a plain release outranks its own release candidates (rc=99 sentinel).
a2() {
    local script="${1:-$SCRIPT}" got want
    got="$(run "$script" "$BUZZ_PATTERN" 'mobile-v' 'mobile-v0.10.0-rc.9
mobile-v0.10.0')"
    want='mobile-v0.10.0	0.10.0	100099|0'
    [ "$got" = "$want" ] || { echo "want [$want] got [$got]"; return 1; }
}

# A3 — the pattern excludes upstream's nightly (.devYYYYMMDD) and rcN tags,
#      so a stable-only caller never builds a nightly.
a3() {
    local script="${1:-$SCRIPT}" got want
    got="$(run "$script" "$OMNI_PATTERN" 'v' "$OMNI_REFS")"
    want='v0.12.0	0.12.0	120099|0'
    [ "$got" = "$want" ] || { echo "want [$want] got [$got]"; return 1; }
}

# A4 — no candidate matches: exit non-zero AND print nothing. A ranker that
#      emits a winner from an empty set makes the caller build garbage.
a4() {
    local script="${1:-$SCRIPT}" got
    got="$(run "$script" '^nothing-matches-this$' 'v' "$OMNI_REFS")"
    [ "$got" = "|1" ] || { echo "want [|1] got [$got]"; return 1; }
}

# A5 — empty input behaves the same as no match.
a5() {
    local script="${1:-$SCRIPT}" got
    got="$(run "$script" "$OMNI_PATTERN" 'v' '')"
    [ "$got" = "|1" ] || { echo "want [|1] got [$got]"; return 1; }
}

# A6 — the "rcN" spelling (no dot) parses too, for upstreams that use it.
a6() {
    local script="${1:-$SCRIPT}" got want
    got="$(run "$script" '^v[0-9]+\.[0-9]+\.[0-9]+(rc[0-9]+)?$' 'v' 'v0.5.0rc1
v0.5.0rc2')"
    want='v0.5.0rc2	0.5.0	50002|0'
    [ "$got" = "$want" ] || { echo "want [$want] got [$got]"; return 1; }
}

echo "rank-refs assertions:"
for t in a1 a2 a3 a4 a5 a6; do
    if msg="$($t)"; then ok "$t"; else bad "$t" "$msg"; fi
done

# ---------------------------------------------------------------------------
# Red proofs — break the script on purpose; the paired assertion MUST fail.
# If it still passes, the assertion was never testing what it claims.
# ---------------------------------------------------------------------------

# defect <name> <sed-expr> <assertion>
defect() {
    local name="$1" expr="$2" assertion="$3" broken="$WORK/broken-$1.sh"
    sed "$expr" "$SCRIPT" > "$broken"
    if cmp -s "$broken" "$SCRIPT"; then
        bad "red:$name" "sed changed nothing — the defect was not injected, so this proves nothing"
        return
    fi
    if "$assertion" "$broken" >/dev/null 2>&1; then
        bad "red:$name" "$assertion still PASSED against a broken script"
    else
        ok "red:$name ($assertion correctly went red)"
    fi
}

echo "red proofs:"
# Rank by the ref string instead of by the parsed version — the exact historical
# defect (0.10.0 sorts before 0.4.0, so the newest release is silently skipped).
#
# Note what does NOT work as a defect here: swapping `sort -n` for `sort`. The
# sort key is zero-padded to 12 digits, so the two orderings are identical and
# the assertion stays green. The padding is the protection, not the -n; a red
# proof that injects the -n alone would prove nothing, which is why it isn't one.
defect rank-by-ref    's/%012d/%s/; s/code, ref, v, code/ref, ref, v, code/'  a1
# rc sentinel 0 instead of 99 — a plain release would rank below its own rcs.
defect rc-sentinel    's/rc = 99/rc = 0/'              a2
# Empty candidate set no longer fails.
defect empty-passes   's/^    exit 1$/    exit 0/'     a4

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
