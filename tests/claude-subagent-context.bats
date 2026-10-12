#!/usr/bin/env bats

load helpers
setup() {
  setup_repo
  export CLAUDE_PROJECT_DIR="$REPO_DIR"
  cp "$BATS_TEST_DIRNAME/../AGENT.md" .
}
teardown() { teardown_repo; }

start_context() {
  jq -cn --arg type "$1" '{hook_event_name:"SubagentStart",session_id:"session",
    agent_id:"child",agent_type:$type}' | bash .claude/hooks/subagent-context.sh
}
assert_context() {
  local out
  out=$(start_context "$1")
  jq -e '.hookSpecificOutput.hookEventName == "SubagentStart" and
    (.hookSpecificOutput.additionalContext | contains("CAC delegated-agent context")) and
    (has("decision") | not)' <<< "$out"
}

@test "Claude general-purpose receives only the bounded supplement, without changing its directives" {
  cp AGENT.md CLAUDE.md
  assert_context general-purpose
  cmp AGENT.md CLAUDE.md
}
@test "Claude Explore receives essential context" { assert_context Explore; }
@test "Claude Plan receives essential context" { assert_context Plan; }
@test "Claude custom omitClaudeMd name needs no privileged type allowlist" { assert_context custom-omitted; }

@test "Claude context derives literal canonical excerpts within the explicit budget" {
  out=$(start_context Explore)
  jq -r '.hookSpecificOutput.additionalContext' <<< "$out" > context
  [ "$(wc -c < context)" -le 2561 ]
  [ "$(wc -l < context)" -le 48 ]
  for rule in 'human owner' 'Security and reliability invariants' 'Scope' \
    'Operational handoff' 'flag the blocker and wait' 'reduce required verification' \
    'Committing and pushing'; do
    grep -q "$rule" context
  done
  for excluded in 'Status: done' 'Recently Completed' 'README Stewardship' \
    'timeout_seconds' 'Root-of-Trust Bootstrap' 'Co-Authored-By'; do
    ! grep -q "$excluded" context
  done
  # Every injected rule line is canonical; only the orientation header is new.
  while IFS= read -r line; do
    [ -z "$line" ] || grep -Fxq -- "$line" AGENT.md
  done < <(tail -n +2 context)
  [ "$(wc -c < context)" -lt "$(wc -c < AGENT.md)" ]
}

@test "Claude context follows canonical edits instead of a second policy copy" {
  sed -i 's/flag the blocker and wait/flag the blocker and wait: CANONICAL_CANARY/' AGENT.md
  start_context Plan | jq -e '.hookSpecificOutput.additionalContext | contains("CANONICAL_CANARY")'
}

@test "Claude context budget counts UTF-8 bytes and lines without truncation" {
  for budget in bytes lines; do
    {
      printf '<!-- CAC:delegated:start -->\n'
      if [ "$budget" = bytes ]; then
        for ((i=0; i<1300; i++)); do printf 'é'; done
        printf '\n'
      else
        for ((i=0; i<49; i++)); do printf 'rule\n'; done
      fi
      printf '<!-- CAC:delegated:end -->\n'
    } > AGENT.md
    run start_context Explore
    [ "$status" -ne 0 ]
    [[ "$output" == *'exceeds 2560 bytes or 48 lines'* ]]
    [[ "$output" != *additionalContext* ]]
  done
}

@test "Claude context rejects missing malformed and oversized sources visibly" {
  cp AGENT.md canonical
  for bad in missing unclosed oversized; do
    cp canonical AGENT.md
    case "$bad" in
      missing) rm AGENT.md ;;
      unclosed) sed -i '0,/<!-- CAC:delegated:end -->/s///' AGENT.md ;;
      oversized) { printf '<!-- CAC:delegated:start -->\n'; head -c 2561 /dev/zero | tr '\0' x; printf '\n<!-- CAC:delegated:end -->\n'; } > AGENT.md ;;
    esac
    run start_context Explore
    [ "$status" -ne 0 ]
    [[ "$output" == *CLAUDE_CONTEXT_UNAVAILABLE* ]]
    [[ "$output" != *additionalContext* ]]
  done
}

@test "Claude internal Stop parent Stop and invalid Start never receive child context" {
  for event in SubagentStop Stop SessionEnd; do
    out=$(jq -cn --arg event "$event" '{hook_event_name:$event,session_id:"session",agent_id:"child",agent_type:"Explore"}' |
      bash .claude/hooks/subagent-context.sh)
    [ -z "$out" ]
  done
  run bash -c 'printf "%s" '\''{"hook_event_name":"SubagentStart","agent_type":"Explore"}'\'' | bash .claude/hooks/subagent-context.sh'
  [ "$status" -ne 0 ]
  [[ "$output" != *additionalContext* ]]
}

@test "Claude context and registration failures are independent" {
  mkdir -p .agent
  printf obstructed > .agent/claude-subagents
  assert_context Explore
  rm .agent/claude-subagents AGENT.md
  run start_context Explore
  [ "$status" -ne 0 ]
  printf '%s' '{"hook_event_name":"SubagentStart","session_id":"session","agent_id":"child","agent_type":"Explore"}' |
    bash .claude/hooks/subagent-lifecycle.sh
  [ -f .agent/claude-subagents/session/child.json ]
}

@test "Claude context hook is separate from unchanged lifecycle and parent settings" {
  jq -e '[.hooks.SubagentStart[].hooks[].command] == [
    "$CLAUDE_PROJECT_DIR/.claude/hooks/subagent-lifecycle.sh",
    "$CLAUDE_PROJECT_DIR/.claude/hooks/subagent-context.sh"] and
    .hooks.SubagentStop[0].hooks[0].command == "$CLAUDE_PROJECT_DIR/.claude/hooks/subagent-lifecycle.sh" and
    ([.hooks.Stop[].hooks[].command] | index("$CLAUDE_PROJECT_DIR/.claude/hooks/subagent-context.sh") | not)' .claude/settings.json
}
