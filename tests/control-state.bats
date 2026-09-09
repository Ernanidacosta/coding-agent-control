#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  cp "$BATS_TEST_DIRNAME/../AGENT.md" .
  cp "$BATS_TEST_DIRNAME/../CLAUDE.md" .
}

teardown() { teardown_repo; }

write_control() {
  local risk="$1"
  cat > .project-control.toml <<EOF
schema = 1
risk = "$risk"
EOF
}

commit_control() {
  git add .project-control.toml
  git commit -q -m "control baseline"
}

control_json() {
  bash -c '. .claude/hooks/_lib.sh; effective_control_requirements_json "${1:-worktree}"' _ "$1"
}

@test ".project-control.toml accepts only the minimal valid schema" {
  write_control high
  run bash -c '. .claude/hooks/_lib.sh; project_control_json_from_content "$(cat .project-control.toml)"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid and .schema == 1 and .risk == "high"' >/dev/null
}

@test "baseline low plus proposed high resolves high immediately" {
  write_control low
  commit_control
  write_control high

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.baseline.risk == "low" and .proposal.risk == "high" and .effective.risk == "high" and .risk_downgrade == "none"' >/dev/null
}

@test "baseline high plus proposed low keeps high pending authority" {
  write_control high
  commit_control
  write_control low

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.baseline.risk == "high" and .proposal.risk == "low" and .effective.risk == "high" and .risk_downgrade == "pending"' >/dev/null
}

@test "baseline medium plus proposed low keeps medium" {
  write_control medium
  commit_control
  write_control low

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.effective.risk == "medium" and .risk_downgrade == "pending"' >/dev/null
}

@test "missing Risk is never represented as low" {
  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.baseline.risk == null and .proposal.risk == null and .effective.risk == null' >/dev/null
}

@test "invalid control Risk blocks a local done claim" {
  write_control high
  commit_control
  write_control impossible
  write_progress done "Invalid control proposal"

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("CONTROL_INVALID"))' >/dev/null
}

@test "editing working progress cannot lower the control baseline" {
  write_control high
  commit_control
  write_progress verifying "Try a local downgrade" "" low

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.baseline.risk == "high" and .proposal.risk == "high" and .effective.risk == "high"' >/dev/null
}

@test "working state may be absent during ordinary work" {
  write_control low
  commit_control

  run bash -c '. .claude/hooks/_lib.sh; v=$(run_effective_verification_contract worktree); r=$(run_risk_contract "$v" worktree completion); combine_policy_summaries "$v" "$r"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status != "fail" and .current_status == "absent" and .risk == "low"' >/dev/null
}

@test "local done claim still activates effective high guarantees" {
  write_control high
  commit_control
  write_progress done "Claim completion" "" low

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_INDEPENDENT_VERIFICATION_REQUIRED"))' >/dev/null
}

@test "removing an old required command keeps the baseline command required" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
[verify.policy]
required = ["test"]
EOF
  git add agent-md.toml
  git commit -q -m policy
  cat > agent-md.toml <<'EOF'
[verify.policy]
required = []
EOF

  run bash -c '. .claude/hooks/_lib.sh; run_effective_verification_contract worktree'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "fail" and any(.results[]; .check == "test" and .command == "false" and .requirement == "required")' >/dev/null
}

@test "a newly required command applies immediately" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
[verify.policy]
required = ["test"]
EOF
  git add agent-md.toml
  git commit -q -m policy
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
lint = "false"
[verify.policy]
required = ["test", "lint"]
EOF

  run bash -c '. .claude/hooks/_lib.sh; run_effective_verification_contract worktree'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.status == "fail" and any(.results[]; .check == "lint" and .requirement == "required")' >/dev/null
}

@test "visual required cannot be disabled by the same proposal" {
  cat > agent-md.toml <<'EOF'
[visual]
required = true
EOF
  git add agent-md.toml
  git commit -q -m visual
  cat > agent-md.toml <<'EOF'
[visual]
required = false
EOF
  printf '<main/>\n' > App.tsx

  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("VERIFY_REQUIRED_FAILED"))' >/dev/null
}

@test "new ignore patterns cannot reduce baseline source coverage" {
  write_progress active "Preserve coverage"
  git add memory/progress.md
  cat > agent-md.toml <<'EOF'
[state]
source_globs = ["src/**"]
ignore_globs = []
EOF
  git add agent-md.toml
  git commit -q -m coverage
  cat > agent-md.toml <<'EOF'
[state]
source_globs = ["src/**"]
ignore_globs = ["src/**"]
EOF
  mkdir -p src
  printf 'x = 1\n' > src/x.py

  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("src/x.py"))' >/dev/null
}

@test "invalid policy does not replace a valid baseline" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
[verify.policy]
required = ["test"]
EOF
  git add agent-md.toml
  git commit -q -m policy
  printf '[verify.policy]\nrequired = [test]\n' > agent-md.toml

  run bash -c '. .claude/hooks/_lib.sh; effective_control_requirements_json worktree'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.valid == false and any(.results[]; .code == "CONFIG_INVALID")' >/dev/null
}

@test "strong downgrade without a passing authority-separated approval stays pending" {
  mkdir -p scripts
  cat > scripts/approval.sh <<'EOF'
#!/bin/bash
exit 1
EOF
  chmod +x scripts/approval.sh
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
approval = "./scripts/approval.sh"
[verify.policy]
required = ["test"]
[verify.attestation]
approval_files = []
EOF
  write_control high
  git add agent-md.toml scripts/approval.sh .project-control.toml
  git commit -q -m baseline
  write_control low
  git add .project-control.toml
  git commit -q --no-verify -m "proposed downgrade"
  write_progress done "Evaluate strong downgrade"

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("RISK_ATTESTATION_INVALID"))' >/dev/null
}

@test "authority-separated approval bound to downgraded HEAD authorizes strong downgrade" {
  mkdir -p scripts
  cat > scripts/approval.sh <<'EOF'
#!/bin/bash
target=$(git rev-parse HEAD)
printf '{"status":"pass","kind":"approval","origin":"human","target":{"commit":"%s"}}\n' "$target"
EOF
  chmod +x scripts/approval.sh
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
approval = "./scripts/approval.sh"
[verify.policy]
required = ["test"]
[verify.attestation]
approval_files = []
EOF
  write_control high
  git add agent-md.toml scripts/approval.sh .project-control.toml
  git commit -q -m baseline
  write_control low
  git add .project-control.toml
  git commit -q --no-verify -m "approved downgrade target"
  write_progress done "Evaluate approved downgrade"

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  if [ -n "$out" ]; then
    echo "$out" | jq -e 'has("decision") | not' >/dev/null
  fi
}

@test "legacy tracked progress remains a compatible baseline" {
  write_progress active "Legacy baseline" "" high
  git add memory/progress.md
  git commit -q -m legacy

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.source == "legacy-progress" and .baseline.risk == "high" and .legacy' >/dev/null
}

@test "untracked progress can propose Risk but is never a trust root" {
  write_progress verifying "Local proposal" "" high

  run control_json worktree
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.baseline.risk == null and .proposal.risk == "high" and .source == "none"' >/dev/null
}

@test "doctor shows control working and completion resolution without executing evidence" {
  write_control high
  commit_control
  write_progress verifying "Inspect control"

  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q '^Control:'
  echo "$output" | grep -Eq 'baseline risk:[[:space:]]+high'
  echo "$output" | grep -Eq 'effective risk:[[:space:]]+high'
  echo "$output" | grep -q '^Working state:'
  echo "$output" | grep -q '^Completion:'
}

@test "staged and worktree snapshots resolve identically when their inputs match" {
  write_control high
  write_progress verifying "Shared resolution"
  git add .project-control.toml memory/progress.md

  staged=$(control_json staged)
  worktree=$(control_json worktree)
  [ "$(echo "$staged" | jq -S '{baseline,proposal,effective,risk_downgrade}')" = "$(echo "$worktree" | jq -S '{baseline,proposal,effective,risk_downgrade}')" ]
}
