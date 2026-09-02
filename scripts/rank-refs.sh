#!/usr/bin/env bash
# rank-refs.sh — pick the newest upstream ref from a list, semver-aware.
#
# Reads candidate refs on stdin (one per line), filters them to a pattern,
# ranks them numerically, and prints the winner as:
#
#     <ref>\t<version>\t<versionCode>
#
# Exits 1 and prints NOTHING when no candidate matches. That is deliberate:
# a ranker that emits a "winner" from an empty set is worse than one that
# fails, because the caller then builds whatever fell out of the pipe.
#
# Why this exists at all, rather than `sort | tail -1`:
#
#   `git/matching-refs` and `git tag` return refs LEXICALLY sorted, so
#   "0.10.0" sorts BEFORE "0.4.0" ('1' < '4') and `tail -1` picks 0.4.0 —
#   an older release, silently. That cost a release cycle on fredabood/buzz
#   (homelab#1207 post-mortem). Rank numerically or not at all.
#
# versionCode = maj*1000000 + min*10000 + pat*100 + rc
# with rc = 99 for a plain release, so 1.2.3 outranks every 1.2.3-rc.N and the
# code is monotonic across both.

set -euo pipefail

PATTERN=''
PREFIX=''

usage() {
    cat >&2 <<'EOF'
usage: rank-refs.sh --pattern <ERE> [--prefix <str>] < refs

  --pattern  extended regex a ref must match in full to be a candidate
  --prefix   leading string stripped from the ref to get the version
             (e.g. "v" for v0.12.0, "mobile-v" for mobile-v0.11.0-rc.2)

Prints "<ref>\t<version>\t<versionCode>" for the highest-ranked candidate.
Exits 1 with no output when nothing matches.
EOF
}

while [ $# -gt 0 ]; do
    case "$1" in
        --pattern) PATTERN="${2:-}"; shift 2 ;;
        --prefix)  PREFIX="${2:-}";  shift 2 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "rank-refs: unknown argument: $1" >&2; usage; exit 2 ;;
    esac
done

[ -n "$PATTERN" ] || { echo "rank-refs: --pattern is required" >&2; exit 2; }

# grep -E returns 1 on no match; under `set -e` that would abort before the
# explicit empty check below, which is where the useful message lives.
candidates=$(grep -E "$PATTERN" || true)

[ -n "$candidates" ] || {
    echo "rank-refs: no ref matched pattern $PATTERN" >&2
    exit 1
}

# Rank: emit "<code> <ref> <version>" per candidate, numeric-sort, take the top.
printf '%s\n' "$candidates" | awk -v prefix="$PREFIX" '
    {
        ref = $0
        v = ref
        if (prefix != "" && index(v, prefix) == 1) {
            v = substr(v, length(prefix) + 1)
        }
        rc = 99
        # Accept both "-rc.N" (buzz) and "rcN" (omnigent-style) spellings.
        if (match(v, /-rc\.[0-9]+$/)) {
            rc = substr(v, RSTART + 4)
            v = substr(v, 1, RSTART - 1)
        } else if (match(v, /rc[0-9]+$/)) {
            rc = substr(v, RSTART + 2)
            v = substr(v, 1, RSTART - 1)
        }
        n = split(v, p, ".")
        if (n < 3) next
        code = p[1] * 1000000 + p[2] * 10000 + p[3] * 100 + rc
        printf "%012d\t%s\t%s\t%d\n", code, ref, v, code
    }
' | sort -n | tail -1 | cut -f2,3,4
