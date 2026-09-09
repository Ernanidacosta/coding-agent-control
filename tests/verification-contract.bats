#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  cp "$BATS_TEST_DIRNAME/../AGENT.md" .
  cp "$BATS_TEST_DIRNAME/../CLAUDE.md" .
}

teardown() { teardown_repo; }

write_contract() {
  local command="$1" required="$2" timeout="${3:-}"
  cat > agent-md.toml <<EOF
[verify]
test = "$command"

[verify.policy]
required = [$required]
EOF
  [ -z "$timeout" ] || printf 'timeout_seconds = %s\n' "$timeout" >> agent-md.toml
}

@test "required configured check passes" {
  write_contract "true" '"test"'
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "required configured check failure blocks with structured evidence" {
  write_contract "printf PASS; exit 1" '"test"'
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_REQUIRED_FAILED")' >/dev/null
  echo "$out" | jq -e '.reason | test("test.*required.*configured"; "i")' >/dev/null
  echo "$out" | jq -e '.reason | test("Exit code: 1")' >/dev/null
  echo "$out" | jq -e '.reason | test("PASS")' >/dev/null
}

@test "optional configured check passes silently" {
  write_contract "true" ''
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "optional configured check failure warns without blocking" {
  write_contract "false" ''
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING VERIFY_OPTIONAL_FAILED")' >/dev/null
}

@test "missing required check blocks as unavailable" {
  cat > agent-md.toml <<'EOF'
[verify.policy]
required = ["runtime"]
EOF
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_UNAVAILABLE")' >/dev/null
  echo "$out" | jq -e '.reason | test("runtime")' >/dev/null
}

@test "configured required command missing from PATH blocks" {
  write_contract "agent-md-command-that-does-not-exist" '"test"'
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_UNAVAILABLE")' >/dev/null
}

@test "missing optional command warns without blocking" {
  write_contract "agent-md-command-that-does-not-exist" ''
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING VERIFY_UNAVAILABLE")' >/dev/null
}

@test "required timeout blocks and names the check" {
  write_contract "sleep 2" '"test"' 1
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_TIMEOUT")' >/dev/null
  echo "$out" | jq -e '.reason | test("test")' >/dev/null
}

@test "optional timeout warns without blocking" {
  write_contract "sleep 2" '' 1
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext | test("WARNING VERIFY_TIMEOUT")' >/dev/null
}

@test "exit zero remains authoritative even when output says FAIL" {
  write_contract "printf FAIL; exit 0" '"test"'
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "empty configured command is invalid and fail-closed" {
  cat > agent-md.toml <<'EOF'
[verify]
lint = ""
EOF
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR CONFIG_INVALID")' >/dev/null
}

@test "unknown required check is invalid and fail-closed" {
  cat > agent-md.toml <<'EOF'
[verify.policy]
required = ["everything"]
EOF
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR CONFIG_INVALID")' >/dev/null
}

@test "verification result codes and evidence fields are stable" {
  write_contract "printf evidence; exit 1" '"test"'
  summary=$(bash -c '. .claude/hooks/_lib.sh; run_verification_contract')
  echo "$summary" | jq -e '
    .status == "fail" and
    (.results[0] | .status == "fail" and .severity == "error" and
      .code == "VERIFY_REQUIRED_FAILED" and .check == "test" and
      .requirement == "required" and .origin == "configured" and
      .command == "printf evidence; exit 1" and .exit_code == 1 and
      .evidence == "evidence" and (.suggestion | length > 0))
  ' >/dev/null
}

@test "configured command takes precedence over inferred command" {
  touch tsconfig.json
  cat > agent-md.toml <<'EOF'
[verify]
typecheck = "true"
EOF
  contract=$(bash -c '. .claude/hooks/_lib.sh; verification_contract_json')
  echo "$contract" | jq -e '.checks[] | select(.name == "typecheck") | .origin == "configured" and .command == "true"' >/dev/null
}

@test "doctor reports requirement origin and configuration without executing checks" {
  touch tsconfig.json
  cat > agent-md.toml <<'EOF'
[verify]
lint = "touch doctor-must-not-run"

[verify.policy]
required = ["lint"]
EOF
  run bash .agent-md/bin/doctor.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -Eq 'lint[[:space:]]+required[[:space:]]+configured'
  echo "$output" | grep -Eq 'typecheck[[:space:]]+required[[:space:]]+inferred'
  echo "$output" | grep -Eq 'runtime[[:space:]]+optional[[:space:]]+not configured'
  [ ! -e doctor-must-not-run ]
}

@test "doctor fails visibly for unavailable required command" {
  write_contract "agent-md-command-that-does-not-exist" '"test"'
  run bash .agent-md/bin/doctor.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'ERROR VERIFY_UNAVAILABLE'
}

@test "agent-md-verify exits nonzero for required failure" {
  write_contract "false" '"test"'
  run bash .agent-md/bin/verify.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'VERIFY_REQUIRED_FAILED'
}

@test "agent-md-verify allows optional failure and reports warning" {
  write_contract "false" ''
  run bash .agent-md/bin/verify.sh
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'VERIFY_OPTIONAL_FAILED'
}

@test "pre-commit blocks required checks and allows optional failures" {
  write_contract "false" '"test"'
  git add agent-md.toml
  run bash .githooks/pre-commit
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'VERIFY_REQUIRED_FAILED'

  write_contract "false" ''
  git add agent-md.toml
  run bash .githooks/pre-commit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'VERIFY_OPTIONAL_FAILED'
}

@test "done is blocked by failed required verification while verifying remains valid state" {
  write_progress done "Ready to finish"
  write_contract "false" '"test"'
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null

  write_progress verifying "Run required checks"
  run bash -c '. .claude/hooks/_lib.sh; validate_progress_content "$(cat memory/progress.md)"'
  [ "$status" -eq 0 ]
}

@test "legacy verify config remains required" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("VERIFY_REQUIRED_FAILED")' >/dev/null
}
