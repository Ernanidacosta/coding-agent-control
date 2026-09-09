#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  cp "$BATS_TEST_DIRNAME/../AGENT.md" .
  cp "$BATS_TEST_DIRNAME/../CLAUDE.md" .
}

teardown() { teardown_repo; }

write_risk_config() {
  local runtime="${1:-}" independent="${2:-}" approval="${3:-}"
  {
    printf '[verify]\ntest = "true"\n'
    [ -z "$runtime" ] || printf 'runtime = "%s"\n' "$runtime"
    [ -z "$independent" ] || printf 'independent = "%s"\n' "$independent"
    [ -z "$approval" ] || printf 'approval = "%s"\n' "$approval"
    printf '\n[verify.policy]\nrequired = ["test"]\n'
    if [[ "$independent" == ./* ]] || [[ "$approval" == ./* ]]; then
      printf '\n[verify.attestation]\n'
      [[ "$independent" != ./* ]] || printf 'independent_files = []\n'
      [[ "$approval" != ./* ]] || printf 'approval_files = []\n'
    fi
  } > agent-md.toml
}

establish_control() {
  local risk="$1"
  cat > .project-control.toml <<EOF
schema = 1
risk = "$risk"
EOF
  git add .project-control.toml agent-md.toml
  git commit -q -m "control baseline"
}

commit_risk_baseline() {
  git add agent-md.toml memory/progress.md
  [ ! -d scripts ] || git add scripts
  git commit -q -m baseline
}

write_risk_verifier() {
  local path="$1" kind="$2" origin="$3" marker="${4:-}"
  mkdir -p "$(dirname "$path")"
  {
    printf '#!/bin/bash\n'
    [ -z "$marker" ] || printf 'touch %s\n' "$marker"
    printf 'target=$(git rev-parse HEAD)\n'
    printf 'printf '\''{"status":"pass","kind":"%s","origin":"%s","target":{"commit":"%%s"}}\\n'\'' "$target"\n' "$kind" "$origin"
  } > "$path"
  chmod +x "$path"
}

@test "low risk with required checks passing allows done" {
  write_risk_config
  write_progress done "Small internal fix" "" low
  establish_control low
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "medium risk with passing runtime evidence allows done" {
  write_risk_config true
  write_progress done "Change executable workflow" "" medium
  establish_control medium
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "medium risk without declared runtime applicability warns but does not block" {
  write_risk_config
  write_progress done "Change internal workflow" "" medium
  establish_control medium
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING RISK_RUNTIME_EVIDENCE_REQUIRED")' >/dev/null
}

@test "medium risk with applicable failing runtime blocks done" {
  write_risk_config false
  write_progress done "Change executable workflow" "" medium
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR RISK_RUNTIME_EVIDENCE_REQUIRED")' >/dev/null
}

@test "high risk without independent evidence blocks done" {
  write_risk_config true
  write_progress done "Harden authentication" "" high
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR RISK_INDEPENDENT_VERIFICATION_REQUIRED")' >/dev/null
}

@test "high risk with trusted independent verifier allows done" {
  write_risk_verifier scripts/independent.sh independent ci
  write_risk_config true ./scripts/independent.sh
  write_progress done "Harden authentication" "" high
  commit_risk_baseline
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "critical risk without human approval blocks done" {
  write_risk_verifier scripts/independent.sh independent ci
  write_risk_config true ./scripts/independent.sh
  write_progress done "Rotate production credentials" "" critical
  commit_risk_baseline
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR RISK_HUMAN_APPROVAL_REQUIRED")' >/dev/null
}

@test "critical risk with trusted independent and approval verifiers allows done" {
  write_risk_verifier scripts/independent.sh independent ci
  write_risk_verifier scripts/approval.sh approval human
  write_risk_config true ./scripts/independent.sh ./scripts/approval.sh
  write_progress done "Rotate production credentials" "" critical
  commit_risk_baseline
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "agent-authored human approval prose is never accepted as evidence" {
  write_risk_verifier scripts/independent.sh independent ci
  write_risk_config true ./scripts/independent.sh
  write_progress done "Rotate production credentials" "" critical
  commit_risk_baseline
  cat > memory/approval.md <<'EOF'
## Approval
Required: true
Status: approved
By: human
EOF
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("RISK_HUMAN_APPROVAL_REQUIRED")' >/dev/null
}

@test "approval verifier added by the implementing agent is not trusted" {
  write_risk_verifier scripts/independent.sh independent ci
  write_risk_config true ./scripts/independent.sh
  write_progress done "Rotate production credentials" "" critical
  commit_risk_baseline
  write_risk_config true ./scripts/independent.sh /bin/true
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("RISK_ATTESTATION_UNTRUSTED")' >/dev/null
  echo "$out" | jq -e '.reason | test("config-not-in-head")' >/dev/null
}

@test "missing risk on relevant legacy work warns without defaulting to low" {
  write_risk_config
  write_progress active "Legacy task"
  commit_risk_baseline
  mkdir -p src
  echo 'x = 1' > src/example.py
  write_progress active "Legacy task advanced"
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING RISK_NOT_DECLARED")' >/dev/null
  ! echo "$out" | grep -q "Declared Risk 'low'"
}

@test "invalid and duplicate risk declarations fail closed" {
  write_risk_config
  write_progress done "Invalid risk" "" extreme
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR RISK_INVALID")' >/dev/null

  sed -i '/Risk:/a Risk: low' memory/progress.md
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.reason | test("ERROR RISK_INVALID")' >/dev/null
}

@test "declared low plus auth signal warns about possible underrating" {
  write_risk_config
  write_progress active "Change auth" "" low
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline
  mkdir -p src/auth
  echo 'x = 1' > src/auth/token.py
  write_progress active "Change auth token" "" low
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING RISK_POSSIBLY_UNDERRATED")' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("auth")' >/dev/null
}

@test "risk result carries declared risk status signals and missing requirement" {
  write_risk_config
  write_progress active "Change auth" "" low
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline
  mkdir -p src/auth
  echo 'x = 1' > src/auth/token.py
  summary=$(bash -c '. .claude/hooks/_lib.sh; verify=$(run_verification_contract); run_risk_contract "$verify" worktree completion')
  echo "$summary" | jq -e '
    .risk == "low" and .current_status == "active" and
    (.observed_signals | index("auth")) and
    (.results[] | select(.code == "RISK_POSSIBLY_UNDERRATED") |
      .risk == "low" and .current_status == "active" and
      (.observed_signals | index("auth")) and .missing_requirement == "risk")
  ' >/dev/null
}

@test "destructive SQL is an observed signal but not an automatic classification" {
  write_risk_config
  write_progress active "Review migration" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline
  mkdir -p migrations
  echo 'DROP TABLE users;' > migrations/drop_users.sql
  run bash -c '. .claude/hooks/_lib.sh; files=$(risk_changed_files worktree); risk_signals_for_files "$files" worktree'
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^destructive-db$'
  echo "$output" | grep -q '^migration$'
}

@test "declared high plus auth signal has no false underrating warning" {
  write_risk_config
  write_progress active "Change auth" "" high
  git add agent-md.toml memory/progress.md
  git commit -q -m baseline
  mkdir -p src/auth
  echo 'x = 1' > src/auth/token.py
  write_progress active "Change auth token" "" high
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    ! echo "$out" | grep -q 'RISK_POSSIBLY_UNDERRATED'
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "active blocked and verifying high risk do not require final independent evidence" {
  write_risk_config true
  for status_value in active blocked verifying; do
    write_progress "$status_value" "Harden auth" "" high
    out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
    if [ -n "$out" ]; then
      echo "$out" | jq -e 'has("decision") | not' >/dev/null
      ! echo "$out" | grep -q 'RISK_INDEPENDENT_VERIFICATION_REQUIRED'
    fi
  done
}

@test "critical declaration and approval cannot bypass Safety fatal" {
  write_risk_config true /bin/true /bin/true
  write_progress done "Destructive production operation" "" critical
  commit_risk_baseline
  out=$(run_hook block-destructive.sh '{"tool_input":{"command":"git reset --hard"}}')
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecisionReason | test("FATAL SAFETY_DESTRUCTIVE_COMMAND")' >/dev/null
}

@test "legacy progress without Risk remains structurally valid" {
  write_progress active "Legacy task"
  run bash -c '. .claude/hooks/_lib.sh; validate_progress_content "$(cat memory/progress.md)"'
  [ "$status" -eq 0 ]
}

@test "doctor reports risk requirements without executing evidence commands" {
  write_risk_verifier scripts/independent.sh independent ci independent-ran
  write_risk_verifier scripts/approval.sh approval human approval-ran
  write_risk_config true ./scripts/independent.sh ./scripts/approval.sh
  write_progress done "Critical change" "" critical
  commit_risk_baseline
  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'declared:[[:space:]]+critical'
  echo "$output" | grep -Eq 'Independent verifier:'
  echo "$output" | grep -Eq 'Approval verifier:'
  [ "$(echo "$output" | grep -c 'trust: eligible')" -eq 2 ]
  [ ! -e independent-ran ]
  [ ! -e approval-ran ]
}

@test "verify.sh enforces high-risk independent evidence" {
  write_risk_config true
  write_progress done "High-risk change" "" high
  run bash .agent-md/bin/verify.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'RISK_INDEPENDENT_VERIFICATION_REQUIRED'
}

@test "pre-commit keeps final high-risk evidence advisory" {
  write_risk_config true
  write_progress done "High-risk change" "" high
  git add agent-md.toml memory/progress.md
  run bash .githooks/pre-commit
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q 'RISK_INDEPENDENT_VERIFICATION_REQUIRED'
}
