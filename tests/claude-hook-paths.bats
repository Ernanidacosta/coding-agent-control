#!/usr/bin/env bats
#
# Claude Code runs each configured hook command through a shell with
# $CLAUDE_PROJECT_DIR set to the project path. A hook that fails to start does
# not block the host, so every command must start in a project whose path
# contains spaces, and reinstalling over an older configuration must leave
# exactly one copy of each coding-agent-control handler.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  SPACED="$BATS_TEST_TMPDIR/my project/the repo"
  mkdir -p "$SPACED"
  git -C "$SPACED" init -q
  git -C "$SPACED" config core.excludesFile /dev/null
}

package_commands() {
  jq -r '[.hooks[][].hooks[].command] | .[]' "$REPO/.claude/settings.json"
}

# The form every release before rc4 installed: $CLAUDE_PROJECT_DIR unquoted.
legacy_settings() {
  jq 'walk(if type == "string" then sub("^\"\\$CLAUDE_PROJECT_DIR\"/"; "$CLAUDE_PROJECT_DIR/") else . end)' "$1"
}

# stub_hooks DIR — every hook named by the package config, replaced by a stub
# that records which script started and the path it was started as.
stub_hooks() {
  local dir="$1" name
  mkdir -p "$dir/.claude/hooks"
  while IFS= read -r name; do
    printf '#!/bin/sh\nprintf "%%s %%s\\n" "%s" "$0" >> "$STARTED"\n' "$name" > "$dir/.claude/hooks/$name"
    chmod +x "$dir/.claude/hooks/$name"
  done < <(package_commands | sed 's#.*/##' | sort -u)
}

install_claude() {
  bash "$REPO/install.sh" --no-githooks --agent=claude "$SPACED"
}

@test "every configured Claude hook starts in a project whose path contains spaces" {
  stub_hooks "$SPACED"
  export STARTED="$BATS_TEST_TMPDIR/started"
  count=0
  while IFS= read -r command; do
    for shell in sh bash; do
      : > "$STARTED"
      (cd "$SPACED" && CLAUDE_PROJECT_DIR="$SPACED" "$shell" -c "$command" </dev/null)
      name=${command##*/}
      [ "$(cat "$STARTED")" = "$name $SPACED/.claude/hooks/$name" ]
    done
    count=$((count + 1))
  done < <(package_commands)
  [ "$count" -eq 11 ]
}

@test "without spaces each command starts the same script as the legacy unquoted form" {
  plain="$BATS_TEST_TMPDIR/plain"
  stub_hooks "$plain"
  export STARTED="$BATS_TEST_TMPDIR/started"
  legacy=$(legacy_settings "$REPO/.claude/settings.json" | jq -r '[.hooks[][].hooks[].command] | .[]')
  [ "$(printf '%s\n' "$legacy" | wc -l)" -eq "$(package_commands | wc -l)" ]
  while IFS= read -r command; do
    : > "$STARTED"
    (cd "$plain" && CLAUDE_PROJECT_DIR="$plain" sh -c "$command" </dev/null)
    current=$(cat "$STARTED")
    : > "$STARTED"
    (cd "$plain" && CLAUDE_PROJECT_DIR="$plain" sh -c "$(printf '%s' "$command" | sed 's#^"\$CLAUDE_PROJECT_DIR"/#$CLAUDE_PROJECT_DIR/#')" </dev/null)
    [ "$(cat "$STARTED")" = "$current" ]
  done < <(package_commands)
}

@test "an installed Claude project with spaces in its path enforces Stop, tool and child events" {
  install_claude
  mkdir -p "$SPACED/src/pkg"
  printf '[verify]\nlint = "false"\nlint_file = "false"\n\n[verify.policy]\nrequired = ["lint"]\n' > "$SPACED/agent-md.toml"
  touch "$SPACED/src/pkg/a.ts"
  run_event() {
    local event="$1" payload="$2" index="${3:-0}" command
    command=$(jq -er --arg event "$event" --argjson index "$index" \
      '[.hooks[$event][].hooks[].command][$index]' "$SPACED/.claude/settings.json")
    printf '%s' "$payload" | (cd "$SPACED/src/pkg" && CLAUDE_PROJECT_DIR="$SPACED" sh -c "$command")
  }

  run_event Stop '{"stop_hook_active":false}' |
    jq -e '.decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))'
  run_event PreToolUse '{"tool_input":{"command":"git reset --hard"}}' |
    jq -e '.hookSpecificOutput.permissionDecision == "deny"'
  run_event PostToolUse '{"tool_input":{"file_path":"a.ts"}}' |
    jq -e '.decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))'
  child='{"hook_event_name":"SubagentStart","session_id":"s","agent_id":"c","agent_type":"Explore"}'
  run_event SubagentStart "$child" 0
  run_event SubagentStart "$child" 1 | jq -e '.hookSpecificOutput.hookEventName == "SubagentStart"'
  run_event SubagentStop '{"hook_event_name":"SubagentStop","session_id":"s","agent_id":"c","stop_hook_active":false}' |
    jq -e '.decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))'
  run_event SessionEnd '{"hook_event_name":"SessionEnd","session_id":"s"}'
}

@test "reinstalling over the legacy unquoted configuration leaves one quoted copy of each handler" {
  install_claude
  legacy_settings "$SPACED/.claude/settings.json" |
    jq '.hooks.Stop += [{"hooks":[{"type":"command","command":"third-party stop"}]}]' > "$SPACED/legacy.json"
  mv "$SPACED/legacy.json" "$SPACED/.claude/settings.json"
  jq -e '[.hooks[][].hooks[].command | select(startswith("$CLAUDE_PROJECT_DIR/"))] | length == 11' \
    "$SPACED/.claude/settings.json"

  install_claude
  installed() { jq -r '[.hooks[][].hooks[].command] | .[]' "$SPACED/.claude/settings.json"; }
  [ "$(installed | grep -vx 'third-party stop' | sort)" = "$(package_commands | sort)" ]
  [ "$(installed | grep -cx 'third-party stop')" -eq 1 ]
  [ -z "$(installed | grep '^\$CLAUDE_PROJECT_DIR/')" ]
  jq -e '[.hooks.Stop[].hooks[] | select(.command | contains("stop-verify.sh")) | .timeout] | length == 1' \
    "$SPACED/.claude/settings.json"

  before=$(find "$SPACED" -name '*.bak*' | wc -l)
  run install_claude
  [[ "$output" == *"already current  .claude/settings.json"* ]]
  [ "$(find "$SPACED" -name '*.bak*' | wc -l)" -eq "$before" ]
}
