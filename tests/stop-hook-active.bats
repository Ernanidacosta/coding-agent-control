#!/usr/bin/env bats
#
# Stop-hook input contract.
#
# Claude Code sets stop_hook_active on every stop attempt that follows an
# earlier one a hook already answered in the same cycle. These tests pin
# the split the flag is allowed to make:
#
#   decision: block        → unconditional, retry or not
#   advisory context       → once per stop cycle, silent on a retry
#
# The convergence tests deliberately run more stop attempts than any host
# loop guard would tolerate, so a pass proves the hooks settle on their
# own rather than being rescued by CLAUDE_CODE_STOP_HOOK_BLOCK_CAP.

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

stop_input() {
  printf '{"session_id":"s1","hook_event_name":"%s","stop_hook_active":%s}' \
    "${2:-Stop}" "$1"
}

# Feeds raw bytes to a hook without echo's trailing newline, so empty and
# malformed payloads stay exactly as written.
run_hook_raw() {
  local hook="$1" input="$2"
  printf '%s' "$input" | bash ".claude/hooks/$hook"
}

advisory_verify_config() {
  cat > agent-md.toml <<'EOF'
[verify]
lint = "true"
test = "true"

[verify.policy]
required = ["lint", "test"]
EOF
}

# A low declared Risk plus an auth-shaped change is the advisory-only
# state the reported loop was stuck in: a warning with no decision to
# satisfy and no executable action left.
underrated_risk_change() {
  cat > .project-control.toml <<'EOF'
schema = 1
risk = "low"
EOF
  mkdir -p src
  echo 'def login(password): return True' > src/auth.py
  write_progress active "Touch auth"
  git add -A
  git commit -q -m baseline
  echo 'def login(password, token): return check_permission(token)' > src/auth.py
  write_progress active "Touch auth again"
}

# --- stop-verify: advisory ------------------------------------------------

@test "stop-verify emits advisory context on a first stop attempt" {
  advisory_verify_config
  underrated_risk_change
  out=$(run_hook stop-verify.sh "$(stop_input false)")
  echo "$out" | jq -e 'has("decision") | not' >/dev/null
  echo "$out" | jq -e '
    .hookSpecificOutput.additionalContext |
    test("RISK_POSSIBLY_UNDERRATED")
  ' >/dev/null
}

@test "stop-verify stays silent when the same advisory repeats on a retry" {
  advisory_verify_config
  underrated_risk_change
  first=$(run_hook stop-verify.sh "$(stop_input false)")
  echo "$first" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
  retry=$(run_hook stop-verify.sh "$(stop_input true)")
  [ -z "$retry" ]
}

@test "stop-verify advisory converges and leaves no state behind" {
  advisory_verify_config
  underrated_risk_change
  before=$(git status --porcelain)

  emitted=0
  for _ in 1 2 3 4; do
    out=$(run_hook stop-verify.sh "$(stop_input true)")
    [ -z "$out" ] || emitted=$((emitted + 1))
  done
  [ "$emitted" -eq 0 ]

  # Depth beyond this is settled by the emitter case below rather than by
  # more invocations: the handler keeps no retry state, so attempt five is
  # indistinguishable from attempt five hundred.
  [ "$(git status --porcelain)" = "$before" ]
}

@test "stop-verify unconfigured-check advisory is bounded the same way" {
  out=$(run_hook stop-verify.sh "$(stop_input false)")
  echo "$out" | jq -e '
    .hookSpecificOutput.additionalContext | test("VERIFY_NOT_CONFIGURED")
  ' >/dev/null
  out=$(run_hook stop-verify.sh "$(stop_input true)")
  [ -z "$out" ]
}

# --- emitter: convergence at arbitrary depth ------------------------------

@test "the advisory emitter converges at any retry depth" {
  . .claude/hooks/_lib.sh
  emitted=0
  # Far past any host loop guard. This is cheap because it exercises the
  # shared emitter directly instead of re-running a whole policy contract,
  # and it is the case that rules out dependence on a consecutive-block cap.
  for _ in $(seq 1 40); do
    out=$(emit_stop_advisory "$(stop_input true)" "a repeated advisory")
    [ -z "$out" ] || emitted=$((emitted + 1))
  done
  [ "$emitted" -eq 0 ]

  # The same emitter still speaks once when the cycle is new.
  out=$(emit_stop_advisory "$(stop_input false)" "a repeated advisory")
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext == "a repeated advisory"' >/dev/null
}

@test "the block emitter never converges" {
  . .claude/hooks/_lib.sh
  for _ in $(seq 1 40); do
    out=$(emit_stop_block "a guarantee is unsatisfied")
    echo "$out" | jq -e '.decision == "block"' >/dev/null
  done
}

# --- stop-verify: blocking ------------------------------------------------

@test "stop-verify blocks a required failure on the first attempt" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  out=$(run_hook stop-verify.sh "$(stop_input false)")
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_REQUIRED_FAILED")' >/dev/null
}

@test "stop-verify keeps blocking while the failure persists" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  previous=""
  for _ in 1 2 3 4; do
    out=$(run_hook stop-verify.sh "$(stop_input true)")
    echo "$out" | jq -e '.decision == "block"' >/dev/null
    echo "$out" | jq -e '.reason | test("ERROR VERIFY_REQUIRED_FAILED")' >/dev/null
    # Identical answers prove the block does not decay with retry count.
    [ -z "$previous" ] || [ "$out" = "$previous" ]
    previous="$out"
  done
}

@test "stop-verify releases only when the blocking condition is fixed" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  out=$(run_hook stop-verify.sh "$(stop_input false)")
  echo "$out" | jq -e '.decision == "block"' >/dev/null

  cat > agent-md.toml <<'EOF'
[verify]
test = "true"

[verify.policy]
required = ["test"]
EOF
  out=$(run_hook stop-verify.sh "$(stop_input true)")
  [ -z "$out" ]
}

# --- stop-verify: clean and malformed input -------------------------------

@test "stop-verify is silent with no warning and no block" {
  cat > agent-md.toml <<'EOF'
[verify]
lint = "true"
test = "true"

[verify.policy]
required = ["lint", "test"]
EOF
  [ -z "$(run_hook stop-verify.sh "$(stop_input false)")" ]
  [ -z "$(run_hook stop-verify.sh "$(stop_input true)")" ]
}

@test "absent stop_hook_active reads as a first attempt" {
  out=$(run_hook stop-verify.sh '{"hook_event_name":"Stop"}')
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null
}

# Payload shapes are a property of the parser, so they are checked against the
# parser. Running a whole policy contract per malformed string would cost the
# suite seconds to re-prove routing that the handler cases above already cover.
@test "only an exact boolean true reads as a retry" {
  . .claude/hooks/_lib.sh
  for payload in '{"stop_hook_active":true}' '{ "stop_hook_active" : true }'; do
    hook_input_is_retry "$payload"
  done
  for payload in '{"stop_hook_active":false}' '{"stop_hook_active":"true"}' \
    '{"stop_hook_active":1}' '{"stop_hook_active":null}' '{"hook_event_name":"Stop"}' \
    'not json at all' '' '[1,2,3]' '"a string"' 'null'; do
    ! hook_input_is_retry "$payload"
  done
}

@test "the stop event name falls back to Stop for anything unrecognized" {
  . .claude/hooks/_lib.sh
  [ "$(hook_input_stop_event '{"hook_event_name":"SubagentStop"}')" = SubagentStop ]
  [ "$(hook_input_stop_event '{"hook_event_name":"Stop"}')" = Stop ]
  for payload in '{"hook_event_name":"Nonsense"}' '{"hook_event_name":null}' \
    '{}' 'not json at all' '' '[1,2,3]'; do
    [ "$(hook_input_stop_event "$payload")" = Stop ]
  done
}

@test "a malformed payload never releases a real block" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  out=$(run_hook_raw stop-verify.sh 'not json at all')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  out=$(run_hook_raw stop-verify.sh '')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
}

# --- SubagentStop ---------------------------------------------------------

@test "advisory context names the stop event it was invoked for" {
  out=$(run_hook stop-verify.sh "$(stop_input false SubagentStop)")
  echo "$out" | jq -e '.hookSpecificOutput.hookEventName == "SubagentStop"' >/dev/null
}

@test "SubagentStop retries suppress advisory and keep blocks" {
  out=$(run_hook stop-verify.sh "$(stop_input true SubagentStop)")
  [ -z "$out" ]
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  out=$(run_hook stop-verify.sh "$(stop_input true SubagentStop)")
  echo "$out" | jq -e '.decision == "block"' >/dev/null
}

# --- state-enforcement ----------------------------------------------------

@test "state-enforcement out-of-scope warning is emitted once per cycle" {
  write_progress active "Implement auth" 'src/auth/**'
  git add memory/progress.md
  git commit -q -m "baseline progress"
  mkdir -p src/payments
  echo 'x = 1' > src/payments/charge.py
  write_progress active "Implement auth behavior" 'src/auth/**'

  out=$(run_hook state-enforcement.sh "$(stop_input false)")
  echo "$out" | jq -e '
    .hookSpecificOutput.additionalContext |
    test("WARNING QUALITY_OUT_OF_SCOPE_CHANGE")
  ' >/dev/null

  # state-enforcement is the cheapest of the three handlers, so this is the
  # one end-to-end case that runs past the host loop guard.
  for _ in $(seq 1 12); do
    [ -z "$(run_hook state-enforcement.sh "$(stop_input true)")" ]
  done
}

@test "state-enforcement keeps blocking a stale progress claim on retries" {
  write_progress active "Exercise state enforcement"
  git add memory/progress.md
  git commit -q -m "init progress"
  echo 'x = 1' > src.py

  out=$(run_hook state-enforcement.sh "$(stop_input false)")
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  for _ in $(seq 1 12); do
    out=$(run_hook state-enforcement.sh "$(stop_input true)")
    echo "$out" | jq -e '.decision == "block"' >/dev/null
  done
}

@test "state-enforcement invalid configuration blocks on retries" {
  write_progress active "Exercise state enforcement"
  git add memory/progress.md
  git commit -q -m "init progress"
  cat > agent-md.toml <<'EOF'
[state]
source_globs = [src/**]
EOF
  out=$(run_hook state-enforcement.sh "$(stop_input true)")
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("ERROR CONFIG_INVALID")' >/dev/null
}

# --- sensory-reminder -----------------------------------------------------

@test "sensory-reminder visual reminder is emitted once per cycle" {
  echo "<div/>" > App.tsx
  out=$(run_hook sensory-reminder.sh "$(stop_input false)")
  echo "$out" | jq -e '
    .hookSpecificOutput.additionalContext |
    test("WARNING QUALITY_VISUAL_EVIDENCE_RECOMMENDED")
  ' >/dev/null
  for _ in 1 2 3 4; do
    [ -z "$(run_hook sensory-reminder.sh "$(stop_input true)")" ]
  done
}

@test "sensory-reminder keeps blocking missing visual evidence on retries" {
  cat > agent-md.toml <<'EOF'
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  for _ in 1 2 3 4; do
    out=$(run_hook sensory-reminder.sh "$(stop_input true)")
    echo "$out" | jq -e '.decision == "block"' >/dev/null
    echo "$out" | jq -e '.reason | test("ERROR VERIFY_REQUIRED_FAILED")' >/dev/null
  done
}

# --- whole Stop group -----------------------------------------------------

@test "the full Stop hook group converges on an advisory-only worktree" {
  advisory_verify_config
  underrated_risk_change
  echo "<div/>" > App.tsx

  first=""
  for HOOK in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
    first="${first}$(run_hook "$HOOK" "$(stop_input false)")"
  done
  [ -n "$first" ]

  # Every later attempt in the same cycle must produce nothing at all: no
  # block, and no context that could restart the agent. Depth past the host
  # loop guard is proved per handler above; this case proves the three go
  # quiet together, so it stays short to keep the suite well inside the
  # configured verification timeout.
  for _ in 1 2 3; do
    for HOOK in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
      [ -z "$(run_hook "$HOOK" "$(stop_input true)")" ]
    done
  done
}

@test "codex stop wrapper forwards the retry flag to the shared policies" {
  advisory_verify_config
  underrated_risk_change

  out=$(printf '%s' "$(stop_input false)" | bash .codex/hooks/stop.sh)
  echo "$out" | jq -e '.systemMessage | test("RISK_POSSIBLY_UNDERRATED")' >/dev/null

  out=$(printf '%s' "$(stop_input true)" | bash .codex/hooks/stop.sh)
  [ -z "$out" ]
}

@test "codex stop wrapper still emits blocking decisions on a retry" {
  cat > agent-md.toml <<'EOF'
[verify]
typecheck = "false"
EOF
  out=$(printf '%s' "$(stop_input true)" | bash .codex/hooks/stop.sh)
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("TYPECHECK")' >/dev/null
}
