#!/usr/bin/env bats
#
# C3b orchestration. The authority can now run an approved contract against one
# sealed snapshot and report what happened. It still cannot turn that into
# evidence: no signature, no sequence, no receipt.

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  RUNCHECK="$BATS_TEST_DIRNAME/../examples/local-issuer/run-check"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  export AUTHORITY ISSUER RUNCHECK ROOT WS
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  printf 'ORIGINAL\n' > "$WS/marker.txt"
  local hook
  for hook in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\n' > "$WS/$hook"
  done
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  TOOLCHAIN="$(mktemp -d)"
  EXEC_PATH="$(trusted_toolchain_path "$TOOLCHAIN")"
  export TOOLCHAIN EXEC_PATH
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

contract() { printf '%s\n' "$1" > "$WS/agent-md.toml"; }

enroll() {
  chmod -R u+w "$ROOT/var/lib/agent-md/projects" 2>/dev/null || true
  rm -rf "${ROOT:?}/var/lib/agent-md/projects"; mkdir -p "$ROOT/var/lib/agent-md/projects"
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PROJECT_ID
  # A refusal further down is almost always an ineligible enrollment; say why.
  if [ "$(jq -r .status "$(project_dir)/enrollment.json")" != eligible ]; then
    enrollment_diagnosis "$(project_dir)/enrollment.json" >&2
    return 1
  fi
}

evaluate() {
  run --separate-stderr bash -c \
    'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT"
}

project_dir() { printf '%s/var/lib/agent-md/projects/%s' "$ROOT" "$PROJECT_ID"; }

@test "1 an approved contract that passes yields candidate_pass" {
  contract '[verify]
lint = "true"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .status == "candidate_pass" and
    (.checks | length) == 2 and
    all(.checks[]; .exit_code == 0 and .execution == "completed")
  ' >/dev/null
}

@test "2 a failing required check yields candidate_fail and still runs the rest" {
  contract '[verify]
lint = "exit 3"
test = "true"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '
    .status == "candidate_fail" and
    (.checks[] | select(.name == "lint") | .exit_code) == 3 and
    (.checks[] | select(.name == "test") | .exit_code) == 0
  ' >/dev/null
}

@test "3 a failing optional check does not block, matching the core" {
  contract '[verify]
test = "true"
smoke = "exit 9"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .status == "candidate_pass" and
    (.checks[] | select(.name == "smoke") | .requirement) == "optional" and
    (.checks[] | select(.name == "smoke") | .exit_code) == 9
  ' >/dev/null
}

@test "4 checks execute in the core's canonical order" {
  contract '[verify]
typecheck = "true"
lint = "true"
test = "true"
integration = "true"
smoke = "true"
runtime = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    [.checks[].name] == ["typecheck","lint","test","integration","smoke","runtime"]
  ' >/dev/null
}

@test "5 every check of one evaluation observes the same snapshot" {
  contract '[verify]
lint = "cat marker.txt"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  local run; run=$(printf '%s' "$output" | jq -r .run_id)
  # One run directory, one snapshot, one manifest for the whole evaluation.
  [ "$(find "$(project_dir)/runs" -maxdepth 1 -mindepth 1 -type d | wc -l)" -eq 1 ]
  [ -f "$(project_dir)/runs/$run/snapshot/manifest.json" ]
  [ "$(find "$(project_dir)/runs/$run/jobs" -name '*.json' | wc -l)" -eq 2 ]
  # Both jobs point at the same sealed tree.
  [ "$(jq -r '.snapshot' "$(project_dir)/runs/$run/jobs/lint.json")" \
    = "$(jq -r '.snapshot' "$(project_dir)/runs/$run/jobs/test.json")" ]
  [ "$(jq -r '.snapshot_fingerprint' "$(project_dir)/runs/$run/jobs/lint.json")" \
    = "$(jq -r '.snapshot_fingerprint' "$(project_dir)/runs/$run/jobs/test.json")" ]
}

@test "6 mutating the worktree during an evaluation never changes what checks see" {
  # The checks read a sealed snapshot, so a mutation cannot reach them.
  #
  # This used to sleep one second and hope the mutation landed after the
  # capture. On a loaded machine the capture starts later than that, the
  # snapshot then legitimately contains the mutation, and the case proved
  # nothing while failing intermittently. The mutation is now ordered against
  # the check's own execution instead of against the clock: nothing is touched
  # until a check has signalled that it is running, which can only happen once
  # the snapshot is sealed.
  local running="$ROOT/running" hold="$ROOT/hold"
  rm -f "$running"; : > "$hold"
  contract "[verify]
test = \"touch $running; while [ -e $hold ]; do sleep 0.2; done; cat marker.txt\"

[verify.policy]
required = [\"test\"]
timeout_seconds = 60
total_timeout_seconds = 180"
  enroll

  local out; out=$(mktemp)
  ( printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$WS" \
      | bash "$ISSUER" evaluate --root "$ROOT" > "$out" 2>/dev/null ) &
  local evaluation=$!

  local i started=no
  for i in $(seq 1 600); do
    if [ -e "$running" ]; then started=yes; break; fi
    sleep 0.1
  done
  [ "$started" = yes ]

  # The snapshot is sealed and a check is executing. Now tamper.
  printf 'TAMPERED\n' > "$WS/marker.txt"
  rm -f "$hold"
  # identity_changed exits non-zero, which is the expected outcome here.
  wait "$evaluation" || true
  local response; response=$(cat "$out"); rm -f "$out"

  [ "$(cat "$WS/marker.txt")" = TAMPERED ]

  # The sealed tree the checks read holds the original, not the tampering.
  [ "$(cat "$(project_dir)/runs/$(cat "$(project_dir)/current-run")/snapshot/src/marker.txt")" = ORIGINAL ]
  # And the check really did read it: cat succeeded against the sealed copy.
  [ "$(printf '%s' "$response" | jq -r '.checks[] | select(.name == "test") | .exit_code')" = 0 ]

  # The workspace no longer matches what was captured, so the authority
  # supersedes the attempt and publishes nothing. What must never happen is a
  # pass whose checks observed the tampered content, and that is excluded by
  # the snapshot assertion above.
  [ "$(printf '%s' "$response" | jq -r .status)" = identity_changed ]
}

@test "7 a second evaluation gets a fresh run and the old one is released" {
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  local first; first=$(printf '%s' "$output" | jq -r .run_id)
  evaluate
  local second; second=$(printf '%s' "$output" | jq -r .run_id)
  [ "$first" != "$second" ]
  [ "$(cat "$(project_dir)/current-run")" = "$second" ]
  [ ! -d "$(project_dir)/runs/$first" ]
  [ -d "$(project_dir)/runs/$second" ]
}

@test "8 a concurrent preparation is refused rather than racing" {
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  # Hold the project lock the way a running evaluation would.
  exec 8>"$(project_dir)/.lock"
  flock -x 8
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  exec 8>&-
  [ "$status" -ne 0 ]
  [[ "$output" == *"already preparing"* ]]
}

@test "9 an exhausted budget cannot produce a candidate pass" {
  contract '[verify]
lint = "sleep 3"
test = "true"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 10
total_timeout_seconds = 2'
  enroll
  evaluate
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '
    .status == "refused" and .reason_code == "REFUSED_BUDGET_EXHAUSTED" and
    .budget.exhausted == true and
    any(.checks[]; .execution == "not_run")
  ' >/dev/null
}

@test "10 a caller that is not the enrolled developer is refused" {
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  local file; file="$(project_dir)/enrollment.json"
  chmod u+w "$(project_dir)" "$file"
  jq '.execution.uid = 4242 | .execution.user = "someone-else"' "$file" > "$file.tmp"
  mv "$file.tmp" "$file"
  evaluate
  [ "$status" -eq 15 ]
  printf '%s' "$output" | jq -e '
    .status == "refused" and .reason_code == "REFUSED_CALLER_MISMATCH"
  ' >/dev/null
}

@test "11 the request may not carry commands, checks or a project id" {
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  local field
  for field in '"command":"true"' '"checks":[]' '"project_id":"x"' '"caller":{"uid":0}'; do
    run --separate-stderr bash -c \
      'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\",%s}" "$1" "$2" | bash "$3" evaluate --root "$4"' \
      _ "$WS" "$field" "$ISSUER" "$ROOT"
    [ "$status" -eq 2 ]
    printf '%s' "$output" | jq -e '.reason_code == "REFUSED_MALFORMED_REQUEST"' >/dev/null
  done
}

@test "12 a changed contract refuses before anything executes" {
  contract '[verify]
test = "touch /tmp/agent-md-should-not-run.$$"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  evaluate
  [ "$status" -eq 7 ]
  printf '%s' "$output" | jq -e '.reason_code == "REFUSED_CONTRACT_CHANGED"' >/dev/null
  [ ! -e "/tmp/agent-md-should-not-run.$$" ]
}

@test "13 stdout carries exactly one JSON object on every outcome" {
  contract '[verify]
test = "echo noise on stdout; exit 4"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  printf '%s' "$output" | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null
  printf '%s' "$output" | jq -e '.status == "candidate_fail"' >/dev/null
}

@test "14 the result never claims evidence it cannot produce" {
  contract '[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 20'
  enroll
  evaluate
  # A sequence is reserved from C4b onwards, so the response carries one. It is
  # an allocation, not a verdict and not a receipt number: what must stay absent
  # is anything that would claim the result was authenticated.
  printf '%s' "$output" | jq -e '
    (.status | test("authentic|attested|verified|signed|receipt") | not) and
    (has("signature") | not) and (has("receipt") | not) and
    (has("key_id") | not) and (.sequence | type) == "number"
  ' >/dev/null
  [[ "$(printf '%s' "$output" | jq -r .reason)" == *"not evidence"* ]]
}

@test "15 no component reads a key, signs, or writes a receipt" {
  # Sequence allocation exists from C4b and is covered by the state machine
  # suite. Key use, signing and receipt persistence are still absent, and that
  # is what this pins.
  local f
  for f in "$ISSUER" "$RUNCHECK" "$AUTHORITY"; do
    ! grep -qE 'issuer-.*\.key|openssl[[:space:]]+(pkeyutl|dgst[[:space:]]+-sign)' "$f"
    ! grep -qE '\.agent/verification|publish_receipt|sign_payload' "$f"
  done
  [ -z "$(ls -A "$ROOT/var/lib/agent-md/keys")" ]
}
