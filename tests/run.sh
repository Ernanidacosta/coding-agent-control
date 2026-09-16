#!/bin/bash
# tests/run.sh — run the bats suite with bounded parallelism.
#
# bats exits 0 after executing nothing when GNU parallel is missing, so a
# plain `bats --jobs N` in the verification contract would let the required
# test check report success without running a single test. This runner
# refuses to report success unless every collected test reported a result,
# and it never falls back to a serial run on its own.

set -u

ROOT=$(cd "$(dirname "$0")/.." && pwd) || exit 1
cd "$ROOT" || exit 1

JOBS=${BATS_JOBS:-4}
case "$JOBS" in
  ''|*[!0-9]*|0)
    printf 'BATS_JOBS must be a positive integer; got %s\n' "$JOBS" >&2
    exit 2
    ;;
esac

if [ "$JOBS" -gt 1 ] && ! command -v parallel >/dev/null 2>&1; then
  printf 'GNU parallel is required for BATS_JOBS=%s. Install it, or set BATS_JOBS=1.\n' "$JOBS" >&2
  exit 127
fi

expected=$(bats --count tests/) || exit 1
case "$expected" in
  ''|*[!0-9]*|0)
    printf 'Could not determine the expected test count (got %s).\n' "$expected" >&2
    exit 1
    ;;
esac

log=$(mktemp "${TMPDIR:-/tmp}/agent-md-bats.XXXXXX") || exit 1
trap 'rm -f "$log"' EXIT

if [ "$JOBS" -gt 1 ]; then
  bats --jobs "$JOBS" tests/ 2>&1 | tee "$log"
else
  bats tests/ 2>&1 | tee "$log"
fi
status=${PIPESTATUS[0]}

executed=$(grep -cE '^(ok|not ok) ' "$log")
if [ "$executed" -ne "$expected" ]; then
  printf 'Suite reported %s of %s collected tests; an incomplete run is not success.\n' \
    "$executed" "$expected" >&2
  exit 1
fi

exit "$status"
