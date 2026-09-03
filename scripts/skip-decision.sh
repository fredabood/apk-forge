#!/usr/bin/env bash
# skip-decision.sh — decide whether a path filter should skip a build.
#
# Pure: takes the two already-fetched commit shas and the previous release tag,
# and prints "skip" or "build" plus a reason. The network lives in the action;
# the decision lives here so it can be tested against fixtures.
#
#     skip-decision.sh --new <sha> --old <sha> --last-tag <tag> --path <path> --ref <ref>
#
# Prints "<verdict>\t<reason>" and exits 0. Exits 2 on a usage error — an
# undecidable call must not silently read as "build".
#
# The rule, and why each branch is the way round it is:
#
#   no previous release      -> build. Nothing to compare against; skipping here
#                               would mean a repo could never cut its first release.
#   sha_new empty            -> build. The path may not exist at that ref, or the
#                               API may have failed. Both are "don't know", and a
#                               skip on "don't know" silently stops shipping.
#   sha_new == sha_old       -> skip.  The interesting subtree is byte-identical.
#   otherwise                -> build.
#
# Note the asymmetry: every uncertain case builds. A wrong build costs CI minutes
# and a redundant release; a wrong skip means an app silently stops updating and
# nobody finds out until they look.

set -euo pipefail

NEW='' OLD='' LAST_TAG='' PATH_FILTER='' REF=''

while [ $# -gt 0 ]; do
    case "$1" in
        --new)      NEW="${2:-}";          shift 2 ;;
        --old)      OLD="${2:-}";          shift 2 ;;
        --last-tag) LAST_TAG="${2:-}";     shift 2 ;;
        --path)     PATH_FILTER="${2:-}";  shift 2 ;;
        --ref)      REF="${2:-}";          shift 2 ;;
        -h|--help)  sed -n '2,30p' "$0"; exit 0 ;;
        *) echo "skip-decision: unknown argument: $1" >&2; exit 2 ;;
    esac
done

[ -n "$PATH_FILTER" ] || { echo "skip-decision: --path is required" >&2; exit 2; }
[ -n "$REF" ] || { echo "skip-decision: --ref is required" >&2; exit 2; }

if [ -z "$LAST_TAG" ]; then
    printf 'build\tno previous release to compare against\n'
    exit 0
fi

if [ -z "$NEW" ]; then
    printf 'build\tcould not resolve a commit for %s at %s — building rather than guessing\n' \
        "$PATH_FILTER" "$REF"
    exit 0
fi

if [ "$NEW" = "$OLD" ]; then
    printf 'skip\t%s unchanged between %s and %s (both at %s)\n' \
        "$PATH_FILTER" "$LAST_TAG" "$REF" "${NEW:0:9}"
    exit 0
fi

printf 'build\t%s changed: %s %s -> %s %s\n' \
    "$PATH_FILTER" "$LAST_TAG" "${OLD:0:9}" "$REF" "${NEW:0:9}"
