#!/usr/bin/env bats
#
# The Codex Stop wrapper exports CODING_AGENT_CONTROL_HOST so the shared Stop
# handler selects the Codex envelope. Verification inherits that environment,
# and so does the suite it runs. Each test must instead start from its own host
# context: a Claude fixture installed without Codex wiring otherwise fails host
# preflight before it reaches the behavior it asserts.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURE="$BATS_TEST_TMPDIR/suite"
  mkdir -p "$FIXTURE/tests"
  cp "$REPO/tests/run.sh" "$FIXTURE/tests/run.sh"
  cat > "$FIXTURE/tests/probe.bats" <<'BATS'
@test "host identity is not inherited from the invoking hook" {
  [ -z "${CODING_AGENT_CONTROL_HOST+set}" ]
}
BATS
}

@test "the suite runner does not pass the invoking hook's host identity to tests" {
  for host in codex claude; do
    run env CODING_AGENT_CONTROL_HOST="$host" BATS_JOBS=1 bash "$FIXTURE/tests/run.sh"
    [ "$status" -eq 0 ] || { printf 'host=%s\n%s\n' "$host" "$output" >&2; return 1; }
    [[ "$output" == *'ok 1 host identity is not inherited from the invoking hook'* ]]
  done
}
