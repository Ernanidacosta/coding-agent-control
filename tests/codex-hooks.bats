#!/usr/bin/env bats

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

configured_stop_hook() {
  local event="$1" input="$2" command
  command=$(jq -er --arg event "$event" '
    [.hooks[$event][]?.hooks[]?.command] |
    select(length == 1) | .[0]
  ' .codex/hooks.json) || return
  printf '%s' "$input" | bash -c "$command"
}

@test "codex PreToolUse wrapper blocks destructive Bash" {
  out=$(echo '{"tool_input":{"command":"git reset --hard"}}' | bash .codex/hooks/pre-tool-use.sh)
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' > /dev/null
}

@test "codex Stop wrapper emits first blocking verification decision" {
  cat > agent-md.toml <<EOF
[verify]
typecheck = "false"
EOF
  out=$(echo '{"stop_hook_active":false}' | bash .codex/hooks/stop.sh)
  echo "$out" | jq -e '.decision == "block"' > /dev/null
  echo "$out" | jq -e '.reason | test("TYPECHECK")' > /dev/null
}

@test "codex Stop wrapper converts advisory context to systemMessage" {
  out=$(echo '{"stop_hook_active":false}' | bash .codex/hooks/stop.sh)
  echo "$out" | jq -e '.systemMessage | test("unverified")' > /dev/null
}

@test "codex SubagentStop is wired to the same completion wrapper as Stop" {
  jq -e '
    [.hooks.Stop[]?.hooks[]?.command] as $parent |
    [.hooks.SubagentStop[]?.hooks[]?.command] as $child |
    ($parent | length) == 1 and $child == $parent and
    ($child[0] | contains(".codex/hooks/stop.sh"))
  ' .codex/hooks.json >/dev/null
}

@test "codex configured SubagentStop preserves child payload in every shared handler" {
  export CAPTURE_DIR="$REPO_DIR/captured"
  mkdir -p "$CAPTURE_DIR"
  for hook in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
    cat > ".claude/hooks/$hook" <<'EOF'
#!/bin/bash
capture="$CAPTURE_DIR/$(basename "$0").json"
cat > "$capture"
event=$(jq -r '.hook_event_name' "$capture")
jq -n --arg event "$event" '{hookSpecificOutput: {
  hookEventName: $event, additionalContext: ($event + " advisory")
}}'
EOF
  done
  input='{"session_id":"parent","hook_event_name":"SubagentStop","agent_id":"child","agent_type":"worker","agent_transcript_path":"child.jsonl","stop_hook_active":false,"last_assistant_message":"finished"}'
  out=$(configured_stop_hook SubagentStop "$input")
  for hook in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
    [ "$(cat "$CAPTURE_DIR/$hook.json")" = "$input" ]
  done
  echo "$out" | jq -e '
    (has("decision") | not) and
    (.systemMessage | contains("SubagentStop advisory"))
  ' >/dev/null
}

@test "codex configured SubagentStop keeps required failures blocking on every retry" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "false"
EOF
  for retry in false true; do
    input="{\"hook_event_name\":\"SubagentStop\",\"agent_id\":\"child\",\"stop_hook_active\":$retry}"
    out=$(configured_stop_hook SubagentStop "$input")
    echo "$out" | jq -e '
      .decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))
    ' >/dev/null
  done
}

@test "codex configured SubagentStop blocks invalid operational state" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"
EOF
  write_progress invalid "Invalid child completion state"
  out=$(configured_stop_hook SubagentStop '{"hook_event_name":"SubagentStop","stop_hook_active":true}')
  echo "$out" | jq -e '
    .decision == "block" and (.reason | contains("STATE_PROGRESS_INVALID"))
  ' >/dev/null
}

@test "codex configured SubagentStop advisory remains nonblocking and silent on retry" {
  out=$(configured_stop_hook SubagentStop '{"hook_event_name":"SubagentStop","stop_hook_active":false}')
  echo "$out" | jq -e '
    (has("decision") | not) and (.systemMessage | test("unverified"))
  ' >/dev/null
  out=$(configured_stop_hook SubagentStop '{"hook_event_name":"SubagentStop","stop_hook_active":true}')
  [ -z "$out" ]
}

@test "codex SubagentStop checks its own transport envelope before running verification" {
  cat > agent-md.toml <<'EOF'
[verify]
test = "touch check-ran"
[verify.policy]
required = ["test"]
timeout_seconds = 3
total_timeout_seconds = 7
EOF
  jq '.hooks.SubagentStop[]?.hooks[]?.timeout = 1' .codex/hooks.json > child-config.json
  mv child-config.json .codex/hooks.json
  out=$(configured_stop_hook SubagentStop '{"hook_event_name":"SubagentStop","stop_hook_active":false}')
  echo "$out" | jq -e '
    .decision == "block" and
    (.reason | contains("VERIFY_HOST_TIMEOUT_INCOMPATIBLE")) and
    (.reason | contains("SubagentStop"))
  ' >/dev/null
  [ ! -e check-ran ]
  out=$(configured_stop_hook Stop '{"hook_event_name":"Stop","stop_hook_active":false}')
  [ -e check-ran ]
  [ -z "$out" ] || echo "$out" | jq -e 'has("decision") | not' >/dev/null
}
