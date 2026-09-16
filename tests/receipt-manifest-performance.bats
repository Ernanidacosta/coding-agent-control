#!/usr/bin/env bats
#
# The manifest rewrite is an architectural change: process spawning must stop
# scaling with the number of files. Wall-clock is reported as a diagnostic but
# is never the assertion, because a shared CI runner makes tight timing flaky.
# The binding guard is subprocess count, which is deterministic.

load helpers

setup() {
  setup_repo
  INSTRUMENT_DIR=$(mktemp -d)
  export INSTRUMENT_DIR
  # The mechanism manifest covers .agent-md/bin/verify.sh, so identity is only
  # valid when that tree is present too.
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
}
teardown() {
  rm -rf "$INSTRUMENT_DIR"
  teardown_repo
}

# Deterministic fixture: fixed content, no randomness, no per-file processes.
build_fixture() {
  local count="$1" i dir
  for dir in 0 1 2 3 4 5 6 7 8 9; do
    mkdir -p "src/d$dir"
  done
  i=0
  while [ "$i" -lt "$count" ]; do
    printf 'fixture content for file %s\n' "$i" > "src/d$((i % 10))/f$i.txt"
    i=$((i + 1))
  done
  git add -A
  git commit -qm "fixture $count"
}

# Counts executions of every external command the manifest can reach. The
# instrumentation deliberately lives outside the repository: wrappers written
# into the worktree would be enumerated, committed and then rewritten, and the
# resulting "modified" paths would add blob reads that belong to the harness
# rather than to the algorithm.
count_manifest_processes() {
  local bin counter real name
  bin="$INSTRUMENT_DIR/bin"
  counter="$INSTRUMENT_DIR/proc.count"
  mkdir -p "$bin"
  for name in git jq sha256sum shasum openssl mktemp xargs tr awk cut sed grep readlink dd wc rm cat; do
    real=$(command -v "$name" 2>/dev/null) || continue
    printf '#!/bin/bash\nprintf "%%s\\n" %s >> "$PROC_COUNT"\nexec %s "$@"\n' "$name" "$real" > "$bin/$name"
    chmod +x "$bin/$name"
  done
  : > "$counter"
  PATH="$bin:$PATH" PROC_COUNT="$counter" bash -c \
    '. .claude/hooks/_lib.sh; verification_receipt_source_manifest_json worktree >/dev/null'
  grep -c . "$counter"
}

@test "manifest process count does not scale with file count" {
  build_fixture 100
  small=$(count_manifest_processes)
  build_fixture 1000
  large=$(count_manifest_processes)

  echo "processes: 100 files -> $small, 1000 files -> $large" >&3

  # The pre-batching implementation spent about 29 processes per file, so a
  # linear algorithm would differ by tens of thousands here. Process count is
  # genuinely constant for this algorithm; the small allowance only covers
  # xargs splitting the digest batch on a host with a smaller ARG_MAX.
  [ "$((large - small))" -lt 10 ]

  # Absolute ceiling with roughly a fourfold margin over the 29 observed
  # locally, so a different coreutils or git build cannot make this flaky.
  [ "$large" -lt 120 ]
}

@test "identity stays within a loose wall-clock ceiling at 1000 files" {
  build_fixture 1000
  started=$SECONDS
  run bash -c '. .claude/hooks/_lib.sh; verification_receipt_identity_json worktree'
  elapsed=$((SECONDS - started))
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .valid == true and (.fingerprints.source.value | length) == 64
  ' >/dev/null
  echo "identity over 1000 files took ${elapsed}s" >&3

  # Locally this is about one second. The ceiling only has to catch a
  # regression to per-file processing, which took over a minute, so 30s is
  # deliberately far above any plausible slow runner.
  [ "$elapsed" -lt 30 ]
}
