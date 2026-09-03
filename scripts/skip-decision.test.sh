#!/usr/bin/env bash
# skip-decision.test.sh — assertions for the path-filter decision, each paired
# with a red proof.
#
# Why this exists as a unit test rather than only a live run: the only upstream
# tag pairs whose android subtree is genuinely unchanged sit below the version
# that introduced -PversionCode support, so proving the skip against them live
# would mean first publishing a knowingly mis-versioned release. The live proof
# uses a different unchanged path; the branch logic is covered here.

set -uo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPT="$HERE/skip-decision.sh"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

PASS=0
FAIL=0
ok()  { PASS=$((PASS + 1)); printf '  ok   %s\n' "$1"; }
bad() { FAIL=$((FAIL + 1)); printf '  FAIL %s\n     %s\n' "$1" "$2"; }

SHA_A=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
SHA_B=bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb

verdict() {  # verdict <script> <args...> -> just the verdict word
    local s="$1"; shift
    bash "$s" "$@" 2>/dev/null | cut -f1
}

# A1 — identical shas means the subtree did not move: skip.
a1() {
    local s="${1:-$SCRIPT}" got
    got="$(verdict "$s" --new "$SHA_A" --old "$SHA_A" --last-tag v1.0.0 --path web/android --ref v1.1.0)"
    [ "$got" = "skip" ] || { echo "want skip, got [$got]"; return 1; }
}

# A2 — different shas: build.
a2() {
    local s="${1:-$SCRIPT}" got
    got="$(verdict "$s" --new "$SHA_A" --old "$SHA_B" --last-tag v1.0.0 --path web/android --ref v1.1.0)"
    [ "$got" = "build" ] || { echo "want build, got [$got]"; return 1; }
}

# A3 — no previous release: build. A repo must be able to cut its first release.
a3() {
    local s="${1:-$SCRIPT}" got
    got="$(verdict "$s" --new "$SHA_A" --old "" --last-tag "" --path web/android --ref v1.1.0)"
    [ "$got" = "build" ] || { echo "want build, got [$got]"; return 1; }
}

# A4 — the dangerous case, and the whole reason the empty-sha guard exists.
#      If BOTH lookups fail (a bad token, an API blip, a renamed path), the two
#      empty strings compare EQUAL, and a naive implementation reads that as
#      "unchanged" and skips — the app then silently stops shipping and nobody
#      notices until they look. Must build.
a4() {
    local s="${1:-$SCRIPT}" got
    got="$(verdict "$s" --new "" --old "" --last-tag v1.0.0 --path web/android --ref v1.1.0)"
    [ "$got" = "build" ] || { echo "want build, got [$got]"; return 1; }
}

# A6 — the milder uncertain case: the path resolves at the last release but not
#      at the new ref. Also builds.
a6() {
    local s="${1:-$SCRIPT}" got
    got="$(verdict "$s" --new "" --old "$SHA_A" --last-tag v1.0.0 --path web/android --ref v1.1.0)"
    [ "$got" = "build" ] || { echo "want build, got [$got]"; return 1; }
}

# A5 — an undecidable invocation is a usage error, not a default.
a5() {
    local s="${1:-$SCRIPT}" rc
    bash "$s" --new "$SHA_A" --old "$SHA_A" --last-tag v1.0.0 --ref v1.1.0 >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ] || { echo "want exit 2 for a missing --path, got $rc"; return 1; }
}

echo "skip-decision assertions:"
for t in a1 a2 a3 a4 a5 a6; do
    if msg="$($t)"; then ok "$t"; else bad "$t" "$msg"; fi
done

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
# Invert the equality test — the classic way to turn a skip rule into a build rule.
defect inverted-compare 's/if \[ "$NEW" = "$OLD" \]/if [ "$NEW" != "$OLD" ]/' a1
# Treat an unresolvable sha as "unchanged" — the wrong-skip failure this guards.
defect empty-skips      's/^if \[ -z "$NEW" \]; then/if false; then/' a4
# Drop the required-argument check.
defect no-usage-check   's/^\[ -n "$PATH_FILTER" \] || { echo "skip-decision: --path is required" >\&2; exit 2; }/PATH_FILTER="${PATH_FILTER:-x}"/' a5

echo
echo "passed: $PASS   failed: $FAIL"
[ "$FAIL" -eq 0 ]
