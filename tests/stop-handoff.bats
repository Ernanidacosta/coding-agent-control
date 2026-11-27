#!/usr/bin/env bats
#
# A finish attempt is not always a completion claim. A task the agent cannot
# finish is handed to the human through a blocked checkpoint in progress.md,
# and that handoff must end the stop cycle on every host without running the
# completion contract again. Everything that claims or approves completion
# keeps its contract: done, verify.sh and pre-commit still evaluate and
# still block on a failing required check.

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" "$REPO_DIR/"
  RUNS="$BATS_TEST_TMPDIR/verify-runs"
  : > "$RUNS"
  printf "[verify]\nlint = 'printf x >> \"%s\"; exit 1'\n\n[verify.policy]\nrequired = [\"lint\"]\n" \
    "$RUNS" > agent-md.toml
  printf 'schema = 1\nrisk = "low"\n' > .project-control.toml
  write_progress active "Integrate the provider"
  git add -A
  git commit -q -m baseline
}

teardown() { teardown_repo; }

# checkpoint [blockers-body] [next-body] [status] — a blocked progress document.
checkpoint() {
  local blockers="${1:-- The provider sandbox rejects the test credentials; the owner must issue new ones.}"
  local next_steps="${2:-- Resume the integration tests once new credentials are installed.}"
  local status="${3:-blocked}"
  printf '# Progress\n\n## Current\n\nStatus: %s\nTask: Integrate the provider\n\n## Next\n\n%s\n\n## Blockers\n\n%s\n\n## Recently Completed\n\nNone\n' \
    "$status" "$next_steps" "$blockers" > memory/progress.md
}

stop_payload() {
  printf '{"session_id":"s","hook_event_name":"%s","stop_hook_active":%s}' "${2:-Stop}" "$1"
}

claude_stop() { stop_payload "$@" | bash .claude/hooks/stop-verify.sh; }
codex_stop()  { stop_payload "$@" | bash .codex/hooks/stop.sh; }
runs() { wc -c < "$RUNS" | tr -d ' '; }

is_block() { jq -e '.decision == "block"' >/dev/null 2>&1 <<<"$1"; }
blocks_with() { jq -e --arg c "$2" '.decision == "block" and (.reason | contains($c))' >/dev/null <<<"$1"; }
# The handoff message travels as Claude additionalContext or Codex systemMessage.
hands_off() {
  jq -e '(has("decision") | not) and
    ((.hookSpecificOutput.additionalContext // .systemMessage // "") |
      contains("[INFO STOP_HANDOFF_BLOCKED]") and contains("not a completion claim"))' >/dev/null <<<"$1"
}

@test "a complete blocked checkpoint hands control to the human on both hosts without verification" {
  checkpoint
  for host in claude codex; do
    out=$("${host}_stop" false)
    hands_off "$out" || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
  done
  [ "$(runs)" -eq 0 ]
}

@test "a retry on an unchanged blocked checkpoint is silent and runs nothing on both hosts" {
  checkpoint
  for host in claude codex; do
    for attempt in 1 2 3; do
      out=$("${host}_stop" true)
      [ -z "$out" ] || { printf '%s retry %s: %s\n' "$host" "$attempt" "$out" >&2; return 1; }
    done
  done
  [ "$(runs)" -eq 0 ]
}

@test "the handoff also ends a SubagentStop cycle on both hosts" {
  checkpoint
  for host in claude codex; do
    out=$("${host}_stop" false SubagentStop)
    hands_off "$out" || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
  done
  [ "$(runs)" -eq 0 ]
}

@test "blocked without a concrete blocker is not a handoff and keeps the completion block" {
  checkpoint None
  for host in claude codex; do
    out=$("${host}_stop" true)
    blocks_with "$out" VERIFY_REQUIRED_FAILED || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    blocks_with "$out" STOP_HANDOFF_INCOMPLETE
    blocks_with "$out" '## Blockers'
  done
  [ "$(runs)" -eq 2 ]
}

@test "blocked without pending work is not a handoff and keeps the completion block" {
  checkpoint "" None
  for host in claude codex; do
    out=$("${host}_stop" false)
    blocks_with "$out" VERIFY_REQUIRED_FAILED || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    blocks_with "$out" STOP_HANDOFF_INCOMPLETE
    blocks_with "$out" '## Next'
  done
  [ "$(runs)" -eq 2 ]
}

@test "an inconsistent blocked checkpoint is not a handoff" {
  checkpoint
  printf '\n## Notes\n\n- not a progress section\n' >> memory/progress.md
  for host in claude codex; do
    out=$("${host}_stop" false)
    is_block "$out" || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    ! hands_off "$out"
  done
}

@test "work changed after the checkpoint was written is not handed off until the checkpoint is refreshed" {
  checkpoint
  touch -d '2 minutes ago' memory/progress.md
  mkdir -p src
  echo 'export const later = 1' > src/later.ts
  for host in claude codex; do
    out=$("${host}_stop" true)
    blocks_with "$out" VERIFY_REQUIRED_FAILED || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    blocks_with "$out" STOP_HANDOFF_INCOMPLETE
    blocks_with "$out" 'src/later.ts'
  done
  [ "$(runs)" -eq 2 ]
  checkpoint
  for host in claude codex; do
    out=$("${host}_stop" false)
    hands_off "$out" || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
  done
  [ "$(runs)" -eq 2 ]
}

@test "done without evidence still blocks on every attempt on both hosts" {
  checkpoint "None" "None" done
  for host in claude codex; do
    for active in false true true; do
      out=$("${host}_stop" "$active")
      blocks_with "$out" VERIFY_REQUIRED_FAILED || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    done
  done
  [ "$(runs)" -eq 6 ]
}

@test "resuming the task re-evaluates completion and a material change is never silent" {
  checkpoint
  claude_stop false >/dev/null
  [ "$(runs)" -eq 0 ]
  checkpoint "None" "- Finish the integration." active
  for host in claude codex; do
    out=$("${host}_stop" true)
    blocks_with "$out" VERIFY_REQUIRED_FAILED || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
    ! blocks_with "$out" STOP_HANDOFF
  done
  [ "$(runs)" -eq 2 ]
  # The committed policy stays required until a new baseline replaces it.
  printf '[verify]\nlint = "true"\n\n[verify.policy]\nrequired = ["lint"]\n' > agent-md.toml
  git add agent-md.toml memory/progress.md
  git commit -q -m 'fix the failing check'
  for host in claude codex; do
    out=$("${host}_stop" false)
    ! is_block "$out" || { printf '%s: %s\n' "$host" "$out" >&2; return 1; }
  done
}

@test "a blocked checkpoint approves no commit and does not satisfy verify.sh" {
  checkpoint
  echo change > feature.txt
  git add feature.txt
  run bash .githooks/pre-commit
  [ "$status" -ne 0 ]
  [[ "$output" == *VERIFY_REQUIRED_FAILED* ]]
  run bash .agent-md/bin/verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *VERIFY_REQUIRED_FAILED* ]]
  [ "$(runs)" -eq 2 ]
}

@test "the handoff keeps the declared Risk and never reports a pass" {
  checkpoint
  printf 'schema = 1\nrisk = "high"\n' > .project-control.toml
  for host in claude codex; do
    out=$("${host}_stop" false)
    hands_off "$out"
    ! grep -q 'VERIFY_PASSED\|All required checks passed' <<<"$out"
  done
  grep -qx 'risk = "high"' .project-control.toml
}

@test "later work is found however many earlier changes precede it" {
  mkdir -p src
  for i in $(seq -w 1 60); do echo "export const v$i = 1" > "src/a$i.ts"; done
  touch -d '10 minutes ago' src/a*.ts
  checkpoint
  touch -d '2 minutes ago' memory/progress.md
  echo 'export const later = 1' > src/zz-later.ts
  out=$(claude_stop false)
  blocks_with "$out" STOP_HANDOFF_INCOMPLETE || { printf '%s\n' "$out" >&2; return 1; }
  blocks_with "$out" 'src/zz-later.ts'
}
