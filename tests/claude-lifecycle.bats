#!/usr/bin/env bats

load helpers
setup() {
  setup_repo
  export CLAUDE_PROJECT_DIR="$REPO_DIR"
  printf '[verify]\ntest = "true"\n' > agent-md.toml
}
teardown() { teardown_repo; }

event() {
  jq -cn --arg event "$1" --arg session "${3:-session}" --arg child "${2:-child}" \
    --argjson retry "${4:-false}" '{hook_event_name:$event,session_id:$session,
      agent_id:$child,agent_type:"same-as-parent",stop_hook_active:$retry,
      agent_transcript_path:"unused.jsonl",last_assistant_message:"finished"}'
}
dispatch() {
  local command
  command=$(jq -er --arg event "$1" '.hooks[$event][0].hooks[0].command' .claude/settings.json) || return
  event "$@" | bash -c "$command"
}
record() { printf '.agent/claude-subagents/%s/%s.json' "${2:-session}" "${1:-child}"; }
stub_gates() {
  for hook in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
    cat > ".claude/hooks/$hook" <<'EOF'
#!/bin/bash
cat >> "$CLAUDE_PROJECT_DIR/calls"
printf '\n' >> "$CLAUDE_PROJECT_DIR/calls"
EOF
  done
}

@test "Claude Start records only identity metadata without running gates" {
  stub_gates
  dispatch SubagentStart
  jq -e '.session_id == "session" and .agent_id == "child" and .agent_type == "same-as-parent" and (keys | sort) == ["agent_id","agent_type","session_id"]' "$(record)"
  [ ! -e calls ]
}

@test "Claude correlated Stop preserves exact payload through all gates and cleans only that child" {
  stub_gates
  dispatch SubagentStart child
  dispatch SubagentStart other
  dispatch SubagentStop child
  [ "$(wc -l < calls)" -eq 3 ]
  jq -es --argjson expected "$(event SubagentStop)" 'all(.[]; . == $expected)' calls
  [ ! -e "$(record)" ]
  [ -f "$(record other)" ]
}

@test "Claude internal Stop with named type is ignored even between real child Start and Stop" {
  stub_gates
  dispatch SubagentStart
  [ -z "$(dispatch SubagentStop internal)" ]
  [ -z "$(dispatch SubagentStop child other-session)" ]
  [ ! -e calls ]
  [ -f "$(record)" ]
  dispatch SubagentStop
  [ "$(wc -l < calls)" -eq 3 ]
}

@test "Claude concurrent children with same type stop out of order without consuming each other" {
  stub_gates
  dispatch SubagentStart one & p1=$!
  dispatch SubagentStart two & p2=$!
  wait "$p1"; wait "$p2"
  dispatch SubagentStop two
  [ -f "$(record one)" ]
  [ ! -e "$(record two)" ]
  dispatch SubagentStop one
  [ "$(wc -l < calls)" -eq 6 ]
}

@test "Claude required failure blocks repeated retries until recovery then cleans" {
  printf '[verify]\ntest = "false"\n' > agent-md.toml
  dispatch SubagentStart
  for retry in false true true; do
    out=$(dispatch SubagentStop child session "$retry")
    jq -e '.decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))' <<< "$out"
    [ -f "$(record)" ]
  done
  printf '[verify]\ntest = "true"\n' > agent-md.toml
  [ -z "$(dispatch SubagentStop child session true)" ]
  [ ! -e "$(record)" ]
}

@test "Claude invalid state blocks the eligible child" {
  write_progress invalid "invalid child state"
  dispatch SubagentStart
  out=$(dispatch SubagentStop)
  jq -e '.decision == "block" and (.reason | contains("STATE_PROGRESS_INVALID"))' <<< "$out"
  [ -f "$(record)" ]
}

@test "Claude advisory remains nonblocking and retains identity until silent retry" {
  rm agent-md.toml
  dispatch SubagentStart
  out=$(dispatch SubagentStop)
  jq -e '(has("decision") | not) and .hookSpecificOutput.hookEventName == "SubagentStop" and (.hookSpecificOutput.additionalContext | length > 0)' <<< "$out"
  [ -f "$(record)" ]
  [ -z "$(dispatch SubagentStop child session true)" ]
  [ ! -e "$(record)" ]
}

@test "Claude session end cleans only its session including blocked children" {
  dispatch SubagentStart
  dispatch SubagentStart child another
  dispatch SessionEnd
  [ ! -e "$(record)" ]
  [ -f "$(record child another)" ]
}

@test "Claude old registration cannot authorize another identity and is not expired by age" {
  stub_gates
  dispatch SubagentStart orphan old-session
  touch -t 200001010000 "$(record orphan old-session)"
  dispatch SubagentStart current
  [ -f "$(record orphan old-session)" ]
  [ -z "$(dispatch SubagentStop arbitrary old-session)" ]
  [ ! -e calls ]
}

@test "Claude failed registration is explicit and never pretends to block creation" {
  mkdir -p .agent
  printf obstructed > .agent/claude-subagents
  run dispatch SubagentStart
  [ "$status" -ne 0 ]
  [[ "$output" == *CLAUDE_LIFECYCLE_UNAVAILABLE* ]]
  [[ "$output" != *'"decision"'* ]]
}

@test "Claude invalid identities do not traverse storage or execute gates" {
  stub_gates
  run dispatch SubagentStart ../outside
  [ "$status" -ne 0 ]
  [[ "$output" == *CLAUDE_LIFECYCLE_INVALID* ]]
  run dispatch SubagentStop ../outside
  [[ "$output" != *'"decision"'* ]]
  [ ! -e calls ]
}

@test "Claude corrupted eligible record fails visibly without becoming unknown" {
  dispatch SubagentStart
  printf broken > "$(record)"
  out=$(dispatch SubagentStop)
  jq -e '.decision == "block" and (.reason | contains("CLAUDE_LIFECYCLE_INVALID"))' <<< "$out"
}

@test "Claude failed handler fails closed and keeps registration" {
  dispatch SubagentStart
  printf '#!/bin/bash\nexit 1\n' > .claude/hooks/state-enforcement.sh
  out=$(dispatch SubagentStop)
  jq -e '.decision == "block" and (.reason | contains("STOP_HANDLER_FAILED"))' <<< "$out"
  [ -f "$(record)" ]
}

@test "Claude parent Stop and tool hooks retain their original commands" {
  jq -e '[.hooks.Stop[].hooks[].command] == [
    "$CLAUDE_PROJECT_DIR/.claude/hooks/stop-verify.sh",
    "$CLAUDE_PROJECT_DIR/.claude/hooks/state-enforcement.sh",
    "$CLAUDE_PROJECT_DIR/.claude/hooks/sensory-reminder.sh"] and
    .hooks.PreToolUse[0].hooks[0].command == "$CLAUDE_PROJECT_DIR/.claude/hooks/block-destructive.sh"' .claude/settings.json
}

@test "Claude child preflight reads its own event envelope not parent Stop" {
  # An outer Codex verification exports this into its test subprocesses.
  export CODING_AGENT_CONTROL_HOST=codex
  jq '.hooks.SubagentStop[0].hooks[0].timeout = 1' .claude/settings.json > next.json
  mv next.json .claude/settings.json
  dispatch SubagentStart
  out=$(dispatch SubagentStop)
  jq -e '.decision == "block" and (.reason | contains("VERIFY_HOST_TIMEOUT_INCOMPATIBLE")) and (.reason | contains("SubagentStop"))' <<< "$out"
  [ -f "$(record)" ]
  [ -z "$(event Stop | CODING_AGENT_CONTROL_HOST=claude bash .claude/hooks/stop-verify.sh)" ]
}

@test "Claude simultaneous Stops remove their own records and preserve another session" {
  stub_gates
  dispatch SubagentStart one
  dispatch SubagentStart two
  dispatch SubagentStart one other-session
  dispatch SubagentStop one & p1=$!
  dispatch SubagentStop two & p2=$!
  wait "$p1"; wait "$p2"
  [ ! -e "$(record one)" ]
  [ ! -e "$(record two)" ]
  [ -f "$(record one other-session)" ]
}

@test "Claude age cleanup cannot release an unresolved blocking retry" {
  printf '[verify]\ntest = "false"\n' > agent-md.toml
  dispatch SubagentStart blocked old-session
  out=$(dispatch SubagentStop blocked old-session)
  jq -e '.decision == "block"' <<< "$out"
  touch -t 200001010000 "$(record blocked old-session)"
  dispatch SubagentStart another new-session
  out=$(dispatch SubagentStop blocked old-session true)
  jq -e '.decision == "block"' <<< "$out"
}
