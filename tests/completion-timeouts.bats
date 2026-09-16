#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
}

teardown() { teardown_repo; }

write_policy() {
  local body="$1"
  printf '%s\n' "$body" > agent-md.toml
}

run_evaluation() {
  local scope="${1:-worktree}" context="${2:-standalone}" boundary="${3:-completion}"
  bash -c '. .claude/hooks/_lib.sh
    completion_evaluation_begin
    context=$(completion_evaluation_context_json "$1" "$2")
    run_completion_evaluation "$context" "$3"' _ "$scope" "$context" "$boundary"
}

write_done_progress() {
  local risk="$1"
  write_progress done "Completion timeout fixture" "" "$risk"
}

install_immediate_timeout() {
  mkdir -p fake-bin
  cat > fake-bin/timeout <<'SH'
#!/bin/bash
if [ "$1" = -s ]; then shift 2; fi
printf '%s\n' "$1" >> "$FAKE_TIMEOUT_CALLS"
if printf '%s\n' "$*" | grep -q -- "$FAKE_TIMEOUT_MATCH"; then
  [ -z "${FAKE_TIMEOUT_TOUCH:-}" ] || printf '%s\n' "$1" > "$FAKE_TIMEOUT_TOUCH"
  exit 124
fi
shift
exec "$@"
SH
  chmod +x fake-bin/timeout
  export PATH="$PWD/fake-bin:$PATH"
  export FAKE_TIMEOUT_CALLS="$PWD/fake-timeout-calls"
}

@test "timeout_seconds remains a per-check timeout" {
  write_policy '[verify]
test = "trap : TERM; while :; do sleep 1; done"
[verify.policy]
required = ["test"]
timeout_seconds = 1
total_timeout_seconds = 5'

  run run_evaluation
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .summary.status == "fail" and
    any(.summary.results[]; .code == "VERIFY_TIMEOUT" and .check == "test") and
    (any(.summary.results[]; .code == "VERIFY_TOTAL_TIMEOUT") | not)
  ' >/dev/null
}

@test "remaining total budget bounds an optional check and stops later checks" {
  # The deadline expiring at smoke is forced by the injected timeout, not by a
  # race between the real clock and contract resolution. timeout_seconds stays
  # far above total_timeout_seconds so the bound is always the remaining total.
  install_immediate_timeout
  export FAKE_TIMEOUT_MATCH=smoke-finished
  write_policy '[verify]
lint = "true"
smoke = "touch smoke-finished"
test = "touch test-ran"
[verify.policy]
required = ["lint", "test"]
timeout_seconds = 120
total_timeout_seconds = 20'

  run run_evaluation
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .summary.status == "fail" and
    any(.summary.results[];
      .code == "VERIFY_TOTAL_TIMEOUT" and
      .check == "smoke" and
      .timeout_stage == "check:smoke" and
      .total_timeout_seconds == 20 and
      .unchecked_checks == ["test"])
  ' >/dev/null
  [ ! -e smoke-finished ]
  [ ! -e test-ran ]
  ! grep -qx '120s' "$FAKE_TIMEOUT_CALLS"
}

@test "ordinary optional failure remains advisory when the total evaluation completes" {
  write_policy '[verify]
smoke = "exit 137"
[verify.policy]
required = []
timeout_seconds = 2
total_timeout_seconds = 5'

  run run_evaluation
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .summary.status == "warn" and
    any(.summary.results[]; .code == "VERIFY_OPTIONAL_FAILED" and .status == "warn" and .exit_code == 137) and
    (any(.summary.results[]; .code == "VERIFY_TOTAL_TIMEOUT") | not)
  ' >/dev/null
}

@test "Risk shares the deadline and incomplete evaluation blocks" {
  write_policy '[verify]
test = "true"
[verify.policy]
required = ["test"]
timeout_seconds = 5
total_timeout_seconds = 1'
  write_progress verifying "Risk deadline fixture" "" medium

  run bash -c '. .claude/hooks/_lib.sh
    completion_evaluation_begin
    context=$(completion_evaluation_context_json worktree standalone)
    contract=$(printf %s "$context" | jq -c .contract)
    control=$(printf %s "$context" | jq -c .control)
    verification=$(run_resolved_verification_contract "$contract")
    completion_deadline_configure 1
    AGENT_MD_COMPLETION_STARTED_SECONDS=$((SECONDS - 1))
    export AGENT_MD_COMPLETION_STARTED_SECONDS
    risk=$(run_risk_contract "$verification" worktree completion "$control")
    combine_policy_summaries "$verification" "$risk"'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '
    .status == "fail" and
    any(.results[]; .code == "VERIFY_TOTAL_TIMEOUT" and .timeout_stage == "risk" and .check == "risk")
  ' >/dev/null

  run bash -c '. .claude/hooks/_lib.sh
    completion_evaluation_begin
    completion_deadline_configure 1
    AGENT_MD_COMPLETION_STARTED_SECONDS=$((SECONDS - 1))
    risk_signals_for_files source.py worktree'
  [ "$status" -eq 124 ]
}

@test "independent provider receives remaining total budget" {
  write_done_progress high
  install_immediate_timeout
  export FAKE_TIMEOUT_MATCH=independent.sh
  export FAKE_TIMEOUT_TOUCH="$PWD/independent-started"
  cat > independent.sh <<'SH'
#!/bin/bash
printf '{"status":"pass","kind":"independent","origin":"trusted-local-verifier","target":{"commit":"%s"}}\n' "$(git rev-parse HEAD)"
SH
  chmod +x independent.sh
  # timeout_seconds stays far above total_timeout_seconds, so the bound handed
  # to the provider can only come from the remaining total.
  write_policy '[verify]
test = "true"
independent = "./independent.sh"
[verify.policy]
required = ["test"]
timeout_seconds = 120
total_timeout_seconds = 20
[verify.attestation]
independent_files = []'
  git add .
  git commit -qm baseline

  run run_evaluation
  [ "$status" -eq 0 ]
  [ -e independent-started ]
  grep -Eq '^([1-9]|1[0-9]|20)s$' independent-started
  echo "$output" | jq -e '
    .summary.status == "fail" and
    any(.summary.results[];
      .code == "VERIFY_TOTAL_TIMEOUT" and .check == "independent" and
      .timeout_stage == "provider:independent")
  ' >/dev/null
}

@test "approval provider is not skipped or accepted when only partial budget remains" {
  write_done_progress critical
  install_immediate_timeout
  export FAKE_TIMEOUT_MATCH=approval.sh
  export FAKE_TIMEOUT_TOUCH="$PWD/approval-started"
  cat > independent.sh <<'SH'
#!/bin/bash
printf '{"status":"pass","kind":"independent","origin":"trusted-local-verifier","target":{"commit":"%s"}}\n' "$(git rev-parse HEAD)"
SH
  cat > approval.sh <<'SH'
#!/bin/bash
printf '{"status":"pass","kind":"approval","origin":"human","target":{"commit":"%s"}}\n' "$(git rev-parse HEAD)"
SH
  chmod +x independent.sh approval.sh
  write_policy '[verify]
test = "true"
independent = "./independent.sh"
approval = "./approval.sh"
[verify.policy]
required = ["test"]
timeout_seconds = 120
total_timeout_seconds = 20
[verify.attestation]
independent_files = []
approval_files = []'
  git add .
  git commit -qm baseline

  run run_evaluation
  [ "$status" -eq 0 ]
  [ -e approval-started ]
  grep -Eq '^([1-9]|1[0-9]|20)s$' approval-started
  echo "$output" | jq -e '
    .summary.status == "fail" and
    any(.summary.results[];
      .code == "VERIFY_TOTAL_TIMEOUT" and .check == "approval" and
      .timeout_stage == "provider:approval")
  ' >/dev/null
}

@test "stop_hook_active does not release or extend a total timeout" {
  write_policy '[verify]
test = "sleep 3"
[verify.policy]
required = ["test"]
timeout_seconds = 10
total_timeout_seconds = 1'

  out=$(run_hook stop-verify.sh '{"stop_hook_active":true}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("VERIFY_TOTAL_TIMEOUT"))' >/dev/null
}

@test "baseline and proposal retain the stricter explicit total" {
  write_policy '[verify]
test = "true"
[verify.policy]
required = ["test"]
timeout_seconds = 10
total_timeout_seconds = 5'
  git add agent-md.toml
  git commit -qm baseline

  sed -i 's/total_timeout_seconds = 5/total_timeout_seconds = 9/' agent-md.toml
  contract=$(bash -c '. .claude/hooks/_lib.sh; effective_verification_contract_json worktree')
  echo "$contract" | jq -e '.total_timeout_seconds == 5' >/dev/null

  sed -i 's/total_timeout_seconds = 9/total_timeout_seconds = 2/' agent-md.toml
  contract=$(bash -c '. .claude/hooks/_lib.sh; effective_verification_contract_json worktree')
  echo "$contract" | jq -e '.total_timeout_seconds == 2' >/dev/null
}

@test "legacy total is derived from per-check stages plus deterministic overhead" {
  write_policy '[verify]
lint = "true"
test = "true"
[verify.policy]
required = ["lint", "test"]
timeout_seconds = 7'

  budget=$(bash -c '. .claude/hooks/_lib.sh
    contract=$(effective_verification_contract_json worktree)
    control=$(effective_control_requirements_json worktree)
    completion_budget_json "$contract" "$control" standalone')
  echo "$budget" | jq -e '
    .source == "legacy-derived" and .potential_subprocesses == 2 and
    .per_check_seconds == 7 and .seconds == 44
  ' >/dev/null
}

@test "legacy contract without either timeout is explicit about standalone and Stop behavior" {
  write_policy '[verify]
test = "true"
[verify.policy]
required = ["test"]'

  standalone=$(bash -c '. .claude/hooks/_lib.sh
    c=$(effective_verification_contract_json worktree)
    r=$(effective_control_requirements_json worktree)
    completion_budget_json "$c" "$r" standalone')
  host=$(bash -c '. .claude/hooks/_lib.sh
    c=$(effective_verification_contract_json worktree)
    r=$(effective_control_requirements_json worktree)
    completion_budget_json "$c" "$r" host')
  echo "$standalone" | jq -e '.bounded == false and .seconds == null and .source == "legacy-unbounded"' >/dev/null
  echo "$host" | jq -e '.bounded == true and .seconds == 300 and .source == "legacy-stop-compatibility"' >/dev/null
}

@test "Claude rejects an incompatible envelope before a costly check" {
  export CODING_AGENT_CONTROL_HOST=claude
  # An arbitrary environment claim cannot replace the installed host envelope.
  export CODING_AGENT_CONTROL_HOST_TIMEOUT_SECONDS=999
  write_policy '[verify]
test = "touch costly-check-ran"
[verify.policy]
required = ["test"]
total_timeout_seconds = 2'
  jq '(.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))).timeout = 31' \
    .claude/settings.json > settings.tmp
  mv settings.tmp .claude/settings.json

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block" and (.reason | test("VERIFY_HOST_TIMEOUT_INCOMPATIBLE"))' >/dev/null
  [ ! -e costly-check-ran ]
}

@test "Codex rejects an incompatible serial envelope before a costly check" {
  write_policy '[verify]
test = "touch costly-check-ran"
[verify.policy]
required = ["test"]
total_timeout_seconds = 2'
  jq '(.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh"))).timeout = 51' \
    .codex/hooks.json > hooks.tmp
  mv hooks.tmp .codex/hooks.json

  run bash .codex/hooks/stop.sh <<<'{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.decision == "block" and (.reason | test("VERIFY_HOST_TIMEOUT_INCOMPATIBLE"))' >/dev/null
  [ ! -e costly-check-ran ]
}

@test "Codex applies separate state and sensory reservations" {
  # The handler reservations are fixed constants. Declaring a tiny total here
  # only raced stop-verify into a VERIFY_TOTAL_TIMEOUT block, which made the
  # wrapper exit before the handlers it is meant to exercise ever ran.
  write_policy '[verify]
test = "true"
[verify.policy]
required = ["test"]'
  mkdir -p fake-bin
cat > fake-bin/timeout <<'SH'
#!/bin/bash
if [ "$1" = -s ]; then shift 2; fi
printf '%s\n' "$1" >> "$TIMEOUT_CALLS"
if [ -n "${TIMEOUT_FAIL_HOOK:-}" ] && [[ "$*" == *"$TIMEOUT_FAIL_HOOK"* ]]; then
  exit 124
fi
shift
exec "$@"
SH
  chmod +x fake-bin/timeout
  export TIMEOUT_CALLS="$PWD/timeout-calls"

  run env PATH="$PWD/fake-bin:$PATH" bash .codex/hooks/stop.sh <<<'{"stop_hook_active":false}'
  [ "$status" -eq 0 ]
  [ "$(grep -c '^10s$' "$TIMEOUT_CALLS")" -eq 2 ]

  for handler in state-enforcement.sh sensory-reminder.sh; do
    run env PATH="$PWD/fake-bin:$PATH" TIMEOUT_FAIL_HOOK="$handler" \
      bash .codex/hooks/stop.sh <<<'{"stop_hook_active":false}'
    [ "$status" -eq 0 ]
    echo "$output" | jq -e --arg handler "$handler" '
      .decision == "block" and
      (.reason | contains("STOP_HANDLER_TIMEOUT") and contains($handler))
    ' >/dev/null
  done
}

@test "verify.sh reports a structured total timeout without a host" {
  install_immediate_timeout
  export FAKE_TIMEOUT_MATCH='sleep 3'
  write_policy '[verify]
test = "sleep 3"
[verify.policy]
required = ["test"]
timeout_seconds = 10
total_timeout_seconds = 1'

  run bash .agent-md/bin/verify.sh
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'ERROR VERIFY_TOTAL_TIMEOUT'
}

@test "pre-commit blocks when the staged evaluation exhausts its total" {
  install_immediate_timeout
  export FAKE_TIMEOUT_MATCH='sleep 3'
  write_policy '[verify]
test = "sleep 3"
[verify.policy]
required = ["test"]
timeout_seconds = 10
total_timeout_seconds = 1'
  git add agent-md.toml

  run bash .githooks/pre-commit
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'ERROR VERIFY_TOTAL_TIMEOUT'
}

@test "an executor-written receipt remains inactive and Stop still runs the check" {
  write_policy '[verify]
test = "touch verifier-ran"
[verify.policy]
required = ["test"]
total_timeout_seconds = 5'
  mkdir -p .agent/verification
  printf '{"status":"pass"}\n' > .agent/verification/latest.json

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -e verifier-ran ]
  [ -z "$out" ]
}

@test "short checks do not acquire an artificial delay" {
  # The guarantee is that a fast check is not padded out to the declared
  # budget. Asserting that against a large budget keeps the property exact
  # while leaving the margin well clear of ordinary scheduling noise.
  write_policy '[verify]
test = "true"
[verify.policy]
required = ["test"]
total_timeout_seconds = 60'

  started=$SECONDS
  run run_evaluation
  elapsed=$((SECONDS - started))
  [ "$status" -eq 0 ]
  [ "$elapsed" -lt 30 ]
}
