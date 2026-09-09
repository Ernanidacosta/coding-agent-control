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

install_agent_md() {
  bash "$BATS_TEST_DIRNAME/../install.sh" --no-githooks "$@" "$TARGET_DIR"
}

@test "default Claude merge preserves third-party hooks and is idempotent" {
  mkdir -p "$TARGET_DIR/.claude"
  cat > "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(git status)"]},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "third-party start"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "third-party pre"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "third-party post"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "third-party prompt"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]
  }
}
EOF
  install_agent_md --agent=claude
  install_agent_md --agent=claude

  jq -e '.permissions.allow == ["Bash(git status)"]' "$TARGET_DIR/.claude/settings.json" >/dev/null
  for command in start pre post prompt stop; do
    [ "$(jq --arg command "third-party $command" '[.hooks[]?[]?.hooks[]? | select(.command == $command)] | length' "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  done
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))] | length' "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
}

@test "default Codex merge preserves third-party hooks and is idempotent" {
  mkdir -p "$TARGET_DIR/.codex"
  cat > "$TARGET_DIR/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "third-party start"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "third-party pre"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "third-party post"}]}],
    "UserPromptSubmit": [{"hooks": [{"type": "command", "command": "third-party prompt"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]
  }
}
EOF
  install_agent_md --agent=codex
  install_agent_md --agent=codex

  for command in start pre post prompt stop; do
    [ "$(jq --arg command "third-party $command" '[.hooks[]?[]?.hooks[]? | select(.command == $command)] | length' "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
  done
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh"))] | length' "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
}

@test "Codex-only install includes every shared hook dependency" {
  install_agent_md --agent=codex
  [ -x "$TARGET_DIR/.claude/hooks/_lib.sh" ]
  [ -x "$TARGET_DIR/.claude/hooks/block-destructive.sh" ]
  [ -x "$TARGET_DIR/.claude/hooks/truncation-check.sh" ]
  [ -x "$TARGET_DIR/.claude/hooks/stop-verify.sh" ]
  [ -x "$TARGET_DIR/.claude/hooks/state-enforcement.sh" ]
  [ -x "$TARGET_DIR/.claude/hooks/sensory-reminder.sh" ]
  [ -x "$TARGET_DIR/.agent-md/bin/verify.sh" ]
  out=$(cd "$TARGET_DIR" && echo '{"tool_input":{"command":"git reset --hard"}}' | bash .codex/hooks/pre-tool-use.sh)
  echo "$out" | jq -e '.hookSpecificOutput.permissionDecision == "deny"' >/dev/null
}

@test "installed memory comes from clean templates, not fork progress" {
  install_agent_md --agent=cursor
  [ -f "$TARGET_DIR/memory/progress.md" ]
  ! grep -q "ICM coexistence implementation" "$TARGET_DIR/memory/progress.md"
  grep -q '^## Current' "$TARGET_DIR/memory/progress.md"
  grep -q '^Status: planned$' "$TARGET_DIR/memory/progress.md"
  ! grep -q '^Risk:' "$TARGET_DIR/memory/progress.md"
  ! grep -q '\*\*Rule\*\*:' "$TARGET_DIR/memory/gotchas.md"
  git -C "$TARGET_DIR" check-ignore -q memory/progress.md
  [ -z "$(git -C "$TARGET_DIR" status --short -- memory)" ]
  run bash -c "cd '$TARGET_DIR' && . .claude/hooks/_lib.sh && validate_progress_content \"\$(cat memory/progress.md)\" && validate_gotchas_content \"\$(cat memory/gotchas.md)\""
  [ "$status" -eq 0 ]
}

@test "Cursor-only fresh install permits private working state without weakening the shared classifier" {
  install_agent_md --agent=cursor
  [ -f "$TARGET_DIR/.claude/hooks/_lib.sh" ]
  echo 'export const x = 1' > "$TARGET_DIR/src.ts"
  git -C "$TARGET_DIR" add src.ts
  run bash -c "cd '$TARGET_DIR' && .githooks/pre-commit"
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TARGET_DIR" status --short -- memory)" ]
}

@test "ICM enabled but unavailable is a non-fatal doctor warning" {
  install_agent_md --agent=codex
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[integrations.icm]
enabled = true
EOF
  run env PATH=/usr/bin:/bin bash -c "cd '$TARGET_DIR' && ./.agent-md/bin/doctor.sh"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'WARNING INTEGRATION_ICM_UNAVAILABLE'
  echo "$output" | grep -q 'configured ICM semantic-memory integration is unavailable'
  echo "$output" | grep -q 'core workflow unaffected'
}

@test "invalid existing hook JSON is preserved and does not abort install" {
  mkdir -p "$TARGET_DIR/.claude"
  echo '{invalid json' > "$TARGET_DIR/.claude/settings.json"
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [ "$(cat "$TARGET_DIR/.claude/settings.json")" = '{invalid json' ]
  echo "$output" | grep -q 'merge failed.*existing file left unchanged'
}
