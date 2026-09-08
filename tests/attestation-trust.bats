#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  cp "$BATS_TEST_DIRNAME/../AGENT.md" .
  cp "$BATS_TEST_DIRNAME/../CLAUDE.md" .
  mkdir -p scripts
}

teardown() { teardown_repo; }

write_attestation_config() {
  local independent="${1:-}" approval="${2:-}"
  local independent_files="${3:-}" approval_files="${4:-}"
  local independent_capability="${5:-}" approval_capability="${6:-}"
  {
    printf '[verify]\ntest = "true"\nruntime = "true"\n'
    [ -z "$independent" ] || printf 'independent = "%s"\n' "$independent"
    [ -z "$approval" ] || printf 'approval = "%s"\n' "$approval"
    printf '\n[verify.policy]\nrequired = ["test"]\n'
    if [[ "$independent" == ./* ]] || [[ "$approval" == ./* ]] || [ -n "$independent_files$approval_files" ]; then
      printf '\n[verify.attestation]\n'
      if [[ "$independent" == ./* ]] || [ -n "$independent_files" ]; then
        if [ -n "$independent_files" ]; then printf 'independent_files = ["%s"]\n' "$independent_files"; else printf 'independent_files = []\n'; fi
      fi
      if [[ "$approval" == ./* ]] || [ -n "$approval_files" ]; then
        if [ -n "$approval_files" ]; then printf 'approval_files = ["%s"]\n' "$approval_files"; else printf 'approval_files = []\n'; fi
      fi
      [ -z "$independent_capability" ] || printf 'independent_capabilities = ["%s"]\n' "$independent_capability"
      [ -z "$approval_capability" ] || printf 'approval_capabilities = ["%s"]\n' "$approval_capability"
    fi
  } > agent-md.toml
}

write_verifier() {
  local path="$1" kind="$2" origin="$3" target_mode="${4:-current}" exit_code="${5:-0}"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/bin/bash\n'
    case "$target_mode" in
      current) printf 'target=$(git rev-parse HEAD)\n' ;;
      previous) printf 'target=$(git rev-parse HEAD^)\n' ;;
      wrong) printf 'target=0000000000000000000000000000000000000000\n' ;;
      missing) printf 'target=\n' ;;
    esac
    if [ "$target_mode" = invalid-json ]; then
      printf 'printf "not-json\\n"\n'
    elif [ "$target_mode" = unbound ]; then
      printf 'printf '\''{"status":"pass","kind":"%s","origin":"%s","target":{}}\\n'\''\n' "$kind" "$origin"
    else
      printf 'printf '\''{"status":"pass","kind":"%s","origin":"%s","target":{"commit":"%%s"}}\\n'\'' "$target"\n' "$kind" "$origin"
    fi
    [ "$exit_code" -eq 0 ] || printf 'printf "PASS\\n" >&2\nexit %s\n' "$exit_code"
  } > "$path"
  chmod +x "$path"
}

commit_attestation_baseline() {
  git add agent-md.toml memory/progress.md scripts
  git commit -q -m baseline
}

anchor_json() {
  bash -c '. .claude/hooks/_lib.sh; attestation_trust_anchor_json agent-md.toml "$1"' _ "$1"
}

@test "repo-local verifier clean against HEAD is eligible" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible and .location == "repo-local" and .integrity == "clean-vs-head" and .executable' >/dev/null
}

@test "repo-local verifier requires an explicit trusted dependency set" {
  write_verifier scripts/independent.sh independent ci
  {
    printf '[verify]\ntest = "true"\nruntime = "true"\n'
    printf 'independent = "./scripts/independent.sh"\n'
    printf '\n[verify.policy]\nrequired = ["test"]\n'
  } > agent-md.toml
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "trusted-files-not-declared"' >/dev/null
}

@test "repo-local verifier modified unstaged is untrusted" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline
  printf '\nexit 0\n' >> scripts/independent.sh

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "modified"' >/dev/null
}

@test "repo-local verifier modified staged is untrusted" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline
  printf '\nexit 0\n' >> scripts/independent.sh
  git add scripts/independent.sh

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "modified"' >/dev/null
}

@test "repo-local verifier created only in worktree is untrusted" {
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline
  write_verifier scripts/independent.sh independent ci

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "not-in-head"' >/dev/null
}

@test "missing repo-local verifier blocks high-risk completion" {
  write_attestation_config ./scripts/missing.sh
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_UNTRUSTED"))' >/dev/null
}

@test "modified declared verifier dependency is untrusted" {
  write_verifier scripts/independent.sh independent ci
  printf '# trusted helper\n' > scripts/attestation-lib.sh
  write_attestation_config ./scripts/independent.sh "" scripts/attestation-lib.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline
  printf '# changed helper\n' > scripts/attestation-lib.sh

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "trusted-file-modified"' >/dev/null
}

@test "invalid attestation JSON blocks" {
  write_verifier scripts/independent.sh independent ci invalid-json
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_INVALID"))' >/dev/null
}

@test "independent verifier cannot return approval kind" {
  write_verifier scripts/independent.sh approval human
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_KIND_MISMATCH"))' >/dev/null
}

@test "unrecognized attestation origin blocks" {
  write_verifier scripts/independent.sh independent self
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_ORIGIN_INVALID"))' >/dev/null
}

@test "attestation bound to previous commit is stale" {
  write_progress active "Baseline" "" high
  git add memory/progress.md
  git commit -q -m prior
  write_verifier scripts/independent.sh independent ci previous
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_STALE"))' >/dev/null
}

@test "attestation bound to exact clean HEAD passes" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "dirty operational worktree cannot use commit-bound attestation" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  mkdir -p src
  printf 'x = 1\n' > src/code.py
  commit_attestation_baseline
  printf 'x = 2\n' > src/code.py

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_UNBOUND"))' >/dev/null
}

@test "ignored metadata does not invalidate commit binding" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline
  printf 'notes\n' > notes.md

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "target without commit binding blocks" {
  write_verifier scripts/independent.sh independent ci unbound
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_UNBOUND"))' >/dev/null
}

@test "textual approval file created in worktree never satisfies critical" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "Critical change" "" critical
  commit_attestation_baseline
  printf '{"status":"pass","kind":"approval","origin":"human"}\n' > approval.json

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_HUMAN_APPROVAL_REQUIRED"))' >/dev/null
}

@test "critical with only independent still requires approval" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "Critical change" "" critical
  commit_attestation_baseline
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_HUMAN_APPROVAL_REQUIRED"))' >/dev/null
}

@test "critical with only approval still requires independent" {
  write_verifier scripts/approval.sh approval human
  write_attestation_config "" ./scripts/approval.sh
  write_progress done "Critical change" "" critical
  commit_attestation_baseline
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_INDEPENDENT_VERIFICATION_REQUIRED"))' >/dev/null
}

@test "critical with both valid distinct attestations passes" {
  write_verifier scripts/independent.sh independent ci
  write_verifier scripts/approval.sh approval human
  write_attestation_config ./scripts/independent.sh ./scripts/approval.sh
  write_progress done "Critical change" "" critical
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "verifier output saying PASS with nonzero exit still blocks" {
  write_verifier scripts/independent.sh independent ci current 1
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_INVALID"))' >/dev/null
}

@test "verifier that changes itself during execution becomes untrusted" {
  write_verifier scripts/independent.sh independent ci
  printf 'printf "# changed during execution\\n" >> "$0"\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_UNTRUSTED"))' >/dev/null
}

@test "symlink verifier is rejected even when committed" {
  write_verifier scripts/real.sh independent ci
  ln -s real.sh scripts/independent.sh
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "symlink"' >/dev/null
}

@test "path traversal verifier is rejected" {
  write_attestation_config ../outside-verifier
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "path-traversal"' >/dev/null
}

@test "external verifier is identified as environment-managed" {
  write_attestation_config /bin/true
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible and .location == "external" and .integrity == "environment-managed" and .executable' >/dev/null
}

@test "executor-writable external verifier is untrusted" {
  external_verifier="$BATS_TEST_TMPDIR/agent-md-external-verifier-$$"
  write_verifier "$external_verifier" independent ci
  write_attestation_config "$external_verifier"
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .location == "external" and .reason == "executor-writable"' >/dev/null
}

@test "active and verifying do not execute final attestation" {
  for state in active verifying; do
    write_verifier scripts/independent.sh independent ci
    printf 'touch attestation-ran\n' >> scripts/independent.sh
    write_attestation_config ./scripts/independent.sh
    write_progress "$state" "High-risk change" "" high
    git add agent-md.toml memory/progress.md scripts/independent.sh
    git commit -q -m "$state"

    out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
    [ ! -e attestation-ran ]
    if [ -n "$out" ]; then echo "$out" | jq -e 'has("decision") | not' >/dev/null; fi
  done
}

@test "doctor diagnoses trust without executing verifier" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch doctor-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'Independent verifier:'
  echo "$output" | grep -Eq 'integrity:[[:space:]]+clean-vs-head'
  echo "$output" | grep -Eq 'trust:[[:space:]]+eligible'
  [ ! -e doctor-ran ]
}

@test "verify.sh reports the trusted attestation and exact binding" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  run bash .agent-md/bin/verify.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'Trust anchor: .*independent.sh.*repo-local.*clean-vs-head.*eligible'
  echo "$output" | grep -Eq 'Attestation: independent from ci for commit [0-9a-f]{40}'
}

@test "pre-commit does not execute external attestations" {
  write_attestation_config /bin/false
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline

  run bash .githooks/pre-commit
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'RISK_INDEPENDENT_VERIFICATION_REQUIRED'
}

@test "pre-commit blocks a modified repo-local trust anchor without running it" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh
  write_progress done "High-risk change" "" high
  commit_attestation_baseline
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  git add scripts/independent.sh

  run bash .githooks/pre-commit
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'RISK_ATTESTATION_UNTRUSTED'
  [ ! -e verifier-ran ]
}

@test "high verifying warns when a declared verifier capability is unavailable without executing it" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress verifying "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING VERIFY_UNAVAILABLE")' >/dev/null
  [ ! -e verifier-ran ]
}

@test "high verifying reports a newly introduced trust anchor without blocking or executing it" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh
  write_progress verifying "Bootstrap verifier" "" high

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING RISK_ATTESTATION_UNTRUSTED")' >/dev/null
  [ ! -e verifier-ran ]

  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'WARNING RISK_ATTESTATION_UNTRUSTED'
  [ ! -e verifier-ran ]
}

@test "high done blocks when a declared verifier capability is unavailable" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress done "High-risk change" "" high
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("ERROR VERIFY_UNAVAILABLE"))' >/dev/null
  [ ! -e verifier-ran ]
}

@test "low risk does not require an unavailable independent capability" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress done "Low-risk change" "" low
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
  [ ! -e verifier-ran ]
}

@test "doctor reports missing verifier capability without executing verifier" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress verifying "High-risk change" "" high
  commit_attestation_baseline

  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'required for completion:[[:space:]]+yes'
  echo "$output" | grep -Eq 'required now:[[:space:]]+no'
  echo "$output" | grep -Eq 'blocking now:[[:space:]]+no'
  echo "$output" | grep -Eq 'capabilities:[[:space:]]+agent-md-capability-definitely-missing'
  echo "$output" | grep -Eq 'capability status:[[:space:]]+unavailable'
  echo "$output" | grep -Eq 'WARNING VERIFY_UNAVAILABLE'
  [ ! -e verifier-ran ]
}

@test "agent-md-verify reports a missing capability without blocking verifying work" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress verifying "High-risk change" "" high
  commit_attestation_baseline

  run bash .agent-md/bin/verify.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'WARNING VERIFY_UNAVAILABLE'
  echo "$output" | grep -Eq 'Summary: .* warning, 0 blocking failure'
  [ ! -e verifier-ran ]
}

@test "medium risk does not require an unavailable independent capability" {
  write_verifier scripts/independent.sh independent ci
  printf 'touch verifier-ran\n' >> scripts/independent.sh
  write_attestation_config ./scripts/independent.sh "" "" "" agent-md-capability-definitely-missing
  write_progress done "Medium-risk change" "" medium
  commit_attestation_baseline

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
  [ ! -e verifier-ran ]
}

@test "capability trust metadata changed after HEAD is untrusted" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh "" "" "" gh
  write_progress verifying "High-risk change" "" high
  commit_attestation_baseline
  sed -i 's/independent_capabilities = \["gh"\]/independent_capabilities = ["jq"]/g' agent-md.toml

  run anchor_json independent
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "capabilities-config-changed"' >/dev/null
}

@test "attestation capability metadata must be literal command names" {
  write_verifier scripts/independent.sh independent ci
  write_attestation_config ./scripts/independent.sh "" "" "" '../gh'
  write_progress verifying "High-risk change" "" high

  run bash -c '. .claude/hooks/_lib.sh; verification_contract_json agent-md.toml'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid == false and .error.code == "CONFIG_INVALID"' >/dev/null
}
