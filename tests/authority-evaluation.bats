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

@test "6 mutating the worktree during an evaluation does not change what checks see" {
  contract '[verify]
lint = "cat marker.txt"
test = "sleep 2; cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20'
  enroll
  ( sleep 1; printf 'TAMPERED\n' > "$WS/marker.txt" ) &
  local mutator=$!
  evaluate
  wait "$mutator"
  [ "$status" -eq 0 ]
  [ "$(cat "$WS/marker.txt")" = TAMPERED ]
  printf '%s' "$output" | jq -e '.status == "candidate_pass"' >/dev/null
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
  printf '%s' "$output" | jq -e '
    (.status | test("authentic|attested|verified|signed|receipt") | not) and
    (has("signature") | not) and (has("sequence") | not) and (has("receipt") | not)
  ' >/dev/null
}

@test "15 no component reads a key, allocates a sequence or writes a receipt" {
  local f
  for f in "$ISSUER" "$RUNCHECK" "$AUTHORITY"; do
    ! grep -qE 'issuer\.key|openssl[[:space:]]+(pkeyutl|dgst[[:space:]]+-sign)' "$f"
    ! grep -qE 'last_terminal|allocate_sequence|\.agent/verification' "$f"
  done
  [ ! -e "$ROOT/var/lib/agent-md/keys/issuer.key" ]
}
