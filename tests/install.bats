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

@test "installer materializes coherent Claude and Codex transport envelopes" {
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 3
total_timeout_seconds = 7
EOF

  install_agent_md --agent=all >/dev/null
  install_agent_md --agent=all >/dev/null

  git -C "$TARGET_DIR" add agent-md.toml
  git -C "$TARGET_DIR" -c user.name=Test -c user.email=test@example.com commit -qm baseline
  sed -i 's/total_timeout_seconds = 7/total_timeout_seconds = 9/' "$TARGET_DIR/agent-md.toml"
  install_agent_md --agent=all >/dev/null

  claude_timeout=$(jq '[.hooks.Stop[]?.hooks[]? |
    select(.command | contains("stop-verify.sh")) | .timeout] | unique | .[0]' \
    "$TARGET_DIR/.claude/settings.json")
  codex_timeout=$(jq '[.hooks.Stop[]?.hooks[]? |
    select(.command | contains(".codex/hooks/stop.sh")) | .timeout] | unique | .[0]' \
    "$TARGET_DIR/.codex/hooks.json")
  [ "$claude_timeout" -eq 37 ]
  [ "$codex_timeout" -eq 57 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh"))] | length' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
}

@test "installer materializes the conservative legacy derived completion ceiling" {
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
lint = "true"
test = "true"
[verify.policy]
required = ["lint", "test"]
timeout_seconds = 3
EOF
  install_agent_md --agent=all >/dev/null
  install_agent_md --agent=all >/dev/null
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh")) | .timeout][0]' \
    "$TARGET_DIR/.claude/settings.json")" -eq 66 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh")) | .timeout][0]' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 86 ]
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
  # memory/ is gitignored on a fresh install, so the classifier cannot use the
  # index and falls back to comparing mtimes: progress.md must be at least as
  # new as the newest changed source. Second granularity made this test depend
  # on the install and the edit landing in the same whole second, which failed
  # roughly one run in ten under load. Both directions are now pinned.
  touch -t 202001010000 "$TARGET_DIR/memory/progress.md"
  run bash -c "cd '$TARGET_DIR' && .githooks/pre-commit"
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'STATE_PROGRESS_STALE'

  touch "$TARGET_DIR/memory/progress.md"
  run bash -c "cd '$TARGET_DIR' && .githooks/pre-commit"
  [ "$status" -eq 0 ] || { printf 'pre-commit exit %s:\n%s\n' "$status" "$output" >&2; false; }
  [ -z "$(git -C "$TARGET_DIR" status --short -- memory)" ]
}

@test "a fresh install receives both git hooks, executable" {
  install_agent_md --agent=cursor
  [ -x "$TARGET_DIR/.githooks/pre-commit" ]
  [ -x "$TARGET_DIR/.githooks/commit-msg" ]
  # Installed but not activated: execution authority stays with the human.
  [ -z "$(git -C "$TARGET_DIR" config --get core.hooksPath || true)" ]
}

@test "reinstalling leaves the commit-msg hook byte-identical" {
  install_agent_md --agent=cursor
  first=$(md5sum < "$TARGET_DIR/.githooks/commit-msg")
  install_agent_md --agent=cursor
  second=$(md5sum < "$TARGET_DIR/.githooks/commit-msg")
  [ "$first" = "$second" ]
  [ -x "$TARGET_DIR/.githooks/commit-msg" ]
}

@test "the installed commit-msg hook enforces human authorship in the target" {
  install_agent_md --agent=cursor
  git -C "$TARGET_DIR" config user.name "A Developer"
  git -C "$TARGET_DIR" config user.email dev@example.com
  printf 'fix: thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$TARGET_DIR/msg.txt"
  run bash -c "cd '$TARGET_DIR' && .githooks/commit-msg msg.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'COMMIT_AI_ATTRIBUTION'
  printf 'fix: thing\n' > "$TARGET_DIR/msg.txt"
  run bash -c "cd '$TARGET_DIR' && .githooks/commit-msg msg.txt"
  [ "$status" -eq 0 ]
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

@test "README stewardship reaches every installed agent target" {
  install_agent_md --agent=all >/dev/null

  for directives in \
    AGENT.md \
    AGENTS.md \
    CLAUDE.md \
    .cursor/rules/agent-md.mdc \
    .windsurf/rules/agent-md.md; do
    grep -Fxq '## README Stewardship' "$TARGET_DIR/$directives"
    grep -Fq 'Does the current README still describe the project a new user would actually encounter?' \
      "$TARGET_DIR/$directives"
  done
}

@test "installer preserves existing README and does not generate project docs" {
  printf '%s\n' '# Project-owned README' > "$TARGET_DIR/README.md"
  install_agent_md --agent=all >/dev/null

  [ "$(cat "$TARGET_DIR/README.md")" = '# Project-owned README' ]
  [ ! -d "$TARGET_DIR/docs" ]
}

@test "README Quickstart names the current installer and its local path succeeds" {
  quickstart_url='https://raw.githubusercontent.com/Ernanidacosta/coding-agent-control/main/install.sh'
  grep -Fq "curl -fsSL $quickstart_url | bash" "$BATS_TEST_DIRNAME/../README.md"
  grep -Fq "curl -fsSL $quickstart_url | bash" "$BATS_TEST_DIRNAME/../install.sh"

  run bash "$BATS_TEST_DIRNAME/../install.sh" --dry-run --no-githooks --agent=all "$TARGET_DIR"
  [ "$status" -eq 0 ]
  [[ "$output" == *"Target agents: claude codex cursor windsurf"* ]]
}
