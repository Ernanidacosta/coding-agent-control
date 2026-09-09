#!/usr/bin/env bats

setup() {
  TARGET_DIR="$(mktemp -d)"
  export TARGET_DIR
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
}

teardown() {
  rm -rf "$TARGET_DIR"
}

install_basic() {
  bash "$BATS_TEST_DIRNAME/../install.sh" --no-githooks --agent=codex "$TARGET_DIR"
}

write_progress_state() {
  local status_value="$1" risk_value="$2"
  cat > "$TARGET_DIR/memory/progress.md" <<EOF
# Progress

## Current

Status: $status_value
Task: Exercise the simple capability path.
Risk: $risk_value

## Next

None

## Blockers

None

## Recently Completed

None
EOF
}

make_provider_free_path() {
  local tool tool_path
  PROVIDER_FREE_BIN="$TARGET_DIR/provider-free-bin"
  export PROVIDER_FREE_BIN
  mkdir -p "$PROVIDER_FREE_BIN"
  for tool in bash git jq cmp awk grep tr sed sort head tail wc cut cat dirname \
    basename find stat readlink sha256sum mktemp rm timeout; do
    tool_path=$(command -v "$tool" 2>/dev/null || true)
    [ -z "$tool_path" ] || ln -s "$tool_path" "$PROVIDER_FREE_BIN/$tool"
  done
}

run_doctor_without_providers() {
  run env PATH="$PROVIDER_FREE_BIN" /bin/bash -c \
    "cd '$TARGET_DIR' && ./.agent-md/bin/doctor.sh"
}

@test "fresh install needs no advanced config or provider" {
  run install_basic
  [ "$status" -eq 0 ]
  [[ "$output" == *"Installing coding-agent-control directives"* ]]
  [[ "$output" == *"(Recommended) Run:"*"/.agent-md/bin/doctor.sh"* ]]
  [[ "$output" == *"work normally — no CI, gh, or memory provider is required"* ]]
  make_provider_free_path

  [ ! -f "$TARGET_DIR/agent-md.toml" ]
  [ ! -e "$PROVIDER_FREE_BIN/icm" ]
  [ ! -e "$PROVIDER_FREE_BIN/gh" ]
  [ -z "$(git -C "$TARGET_DIR" diff --cached --name-only)" ]
  [ -z "$(git -C "$TARGET_DIR" ls-files memory)" ]
  [ -f "$TARGET_DIR/memory/plan.md" ]
  [ -f "$TARGET_DIR/memory/progress.md" ]
  [ -f "$TARGET_DIR/memory/verify.md" ]

  run_doctor_without_providers
  [ "$status" -eq 0 ]
  [[ "$output" != *"warn Claude settings missing"* ]]
  [[ "$output" == *"ok  verification timeout is not applicable until a check is configured or inferred"* ]]
  [[ "$output" == *"ok  optional git hook fallback is installed but not active"* ]]
  [[ "$output" != *"INTEGRATION_ICM_UNAVAILABLE"* ]]
  [[ "$output" == *$'Semantic memory:\n  provider: none\n  required now: no\n  status: not configured\n  blocking now: no'* ]]
  [[ "$output" == *$'Independent verification:\n  required for completion: no\n  required now: no\n  configured: no'* ]]
}

@test "low-risk completion works without external providers" {
  install_basic >/dev/null
  write_progress_state "done" low
  make_provider_free_path

  run env PATH="$PROVIDER_FREE_BIN" /bin/bash -c \
    "cd '$TARGET_DIR' && ./.agent-md/bin/verify.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 blocking failure"* ]]
  [[ "$output" != *"Advanced completion capabilities"* ]]
  [[ "$output" != *"RISK_INDEPENDENT_VERIFICATION_REQUIRED"* ]]
  [[ "$output" != *"RISK_HUMAN_APPROVAL_REQUIRED"* ]]
}

@test "absent local working state does not break ordinary verification" {
  install_basic >/dev/null
  rm -rf "$TARGET_DIR/memory"
  make_provider_free_path

  run env PATH="$PROVIDER_FREE_BIN" /bin/bash -c \
    "cd '$TARGET_DIR' && ./.agent-md/bin/verify.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"current status: absent"* ]]
  [[ "$output" == *"0 blocking failure"* ]]
}

@test "missing gh stays non-blocking when independent verification is not required" {
  install_basic >/dev/null
  write_progress_state "done" low
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
independent = "/bin/true"

[verify.attestation]
independent_capabilities = ["gh"]
EOF
  make_provider_free_path

  run_doctor_without_providers
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Independent verification:\n  required for completion: no\n  required now: no\n  configured: yes\n  status: unavailable\n  blocking now: no'* ]]
  [[ "$output" != *"WARNING VERIFY_UNAVAILABLE"* ]]
  [[ "$output" != *"uses an environment-managed verifier"* ]]
}

@test "declared ICM absence warns but does not affect ordinary completion" {
  install_basic >/dev/null
  write_progress_state "done" low
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[integrations.icm]
enabled = true
EOF
  make_provider_free_path

  run_doctor_without_providers
  [ "$status" -eq 0 ]
  [[ "$output" == *"WARNING INTEGRATION_ICM_UNAVAILABLE"* ]]
  [[ "$output" == *"core workflow unaffected"* ]]

  run env PATH="$PROVIDER_FREE_BIN" /bin/bash -c \
    "cd '$TARGET_DIR' && ./.agent-md/bin/verify.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"0 blocking failure"* ]]
}

@test "high-risk verifying diagnoses missing independent verifier without blocking" {
  install_basic >/dev/null
  write_progress_state verifying high
  make_provider_free_path

  run_doctor_without_providers
  [ "$status" -eq 0 ]
  [[ "$output" == *$'Independent verification:\n  required for completion: yes\n  required now: no\n  configured: no\n  status: not configured\n  blocking now: no'* ]]
  [[ "$output" == *"Effect: implementation work may continue"* ]]
}

@test "high-risk done reports missing independent verifier as blocking with recovery" {
  install_basic >/dev/null
  write_progress_state "done" high
  make_provider_free_path

  run_doctor_without_providers
  [ "$status" -ne 0 ]
  [[ "$output" == *$'Independent verification:\n  required for completion: yes\n  required now: yes\n  configured: no\n  status: not configured\n  blocking now: yes'* ]]
  [[ "$output" == *"ERROR RISK_INDEPENDENT_VERIFICATION_REQUIRED"* ]]
  [[ "$output" == *"Recovery:"* ]]

  run env PATH="$PROVIDER_FREE_BIN" /bin/bash -c \
    "cd '$TARGET_DIR' && ./.agent-md/bin/verify.sh"
  [ "$status" -ne 0 ]
  [[ "$output" == *"Independent verification is required before this high-risk task can be completed"* ]]
  [[ "$output" == *"Recovery:"* ]]
}

@test "critical done reports human approval as a separate blocking capability" {
  install_basic >/dev/null
  write_progress_state "done" critical
  make_provider_free_path

  run_doctor_without_providers
  [ "$status" -ne 0 ]
  [[ "$output" == *$'Human approval:\n  required for completion: yes\n  required now: yes\n  configured: no\n  status: not configured\n  blocking now: yes'* ]]
  [[ "$output" == *"ERROR RISK_HUMAN_APPROVAL_REQUIRED"* ]]
  [[ "$output" == *"Recovery:"* ]]
}

@test "public identity, attribution, and standalone source URL are explicit" {
  grep -Fxq '# coding-agent-control' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq '**Developer control for coding agents.**' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'A repository-local control, verification, and trust layer for coding agents.' \
    "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq '[Português (Brasil)](README.pt-BR.md)' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'iamfakeguru/agent-md' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fxq '# coding-agent-control' "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  grep -Fq '[English](README.md)' "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  grep -Fq 'iamfakeguru/agent-md' "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  run grep -R -n 'iamfakeguru/agent-md' "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -ne 0 ]

  grep -q 'Ernanidacosta/coding-agent-control/main/install.sh' \
    "$BATS_TEST_DIRNAME/../README.md"
  grep -q 'Ernanidacosta/coding-agent-control/main/install.sh' \
    "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  grep -q 'Ernanidacosta/coding-agent-control/archive/main.tar.gz' \
    "$BATS_TEST_DIRNAME/../install.sh"
  grep -q 'coding-agent-control-main' "$BATS_TEST_DIRNAME/../install.sh"
  ! grep -q 'Ernanidacosta/agent-md' "$BATS_TEST_DIRNAME/../install.sh"
  grep -Fxq 'repository=Ernanidacosta/coding-agent-control' \
    "$BATS_TEST_DIRNAME/../examples/github-actions/github-actions-independent.conf"
}

@test "legacy interfaces and future state boundary are documented without migration" {
  grep -Fq '`agent-md.toml`, `.agent-md/`, `memory/`, `$agent-md-verify`' \
    "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq '**working state**' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq '**control state**' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq 'must not require a' "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq 'developer to publish evidence of that use in Git' \
    "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq 'Current Risk is executor-editable' \
    "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq 'a Risk downgrade may be silent' \
    "$BATS_TEST_DIRNAME/../docs/architecture.md"
  grep -Fq 'private control state cannot be described as trustworthy' \
    "$BATS_TEST_DIRNAME/../docs/architecture.md"
}

@test "public wording reflects repository state and acceptance semantics" {
  grep -Fq 'substantially evolved into an independent project' \
    "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'substancialmente evoluído para um projeto independente' \
    "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  grep -Fq 'retained compatibility interfaces in the current architecture' \
    "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'accepted only when' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'authority-separated from the executor' "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq 'só são aceitas quando possuem' "$BATS_TEST_DIRNAME/../README.pt-BR.md"
  grep -Fq 'autoridade separada do executor' "$BATS_TEST_DIRNAME/../README.pt-BR.md"
}

@test "successful evidence does not render a contradictory missing requirement" {
  cd "$BATS_TEST_DIRNAME/.."
  . .claude/hooks/_lib.sh
  result=$(risk_result_json pass info VERIFY_PASSED \
    "Independent verification passed." "" high "done" "" "" independent)
  message=$(policy_human_message "$result")

  [[ "$message" == *"Independent verification passed."* ]]
  [[ "$message" != *"Missing: independent"* ]]
}
