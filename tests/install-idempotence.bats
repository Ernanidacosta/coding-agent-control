#!/usr/bin/env bats
#
# Reinstall idempotence for the hook transport configurations.
#
# .claude/settings.json and .codex/hooks.json are the only installed files
# whose final content the installer computes rather than copies: the merge
# imports the package's Stop envelope and materialization then recomputes it
# from the target's own completion budget. While those two steps ran against
# the installed file in sequence, every reinstall backed up byte-identical
# content. These tests pin the contract that a reinstall which changes nothing
# effective writes nothing and backs up nothing, and that a reinstall which
# does change something still takes exactly one backup.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  TARGET_DIR="$(mktemp -d)"
  export TARGET_DIR
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
}

teardown() {
  rm -rf "$TARGET_DIR"
}

install_agent_md() {
  bash "$REPO/install.sh" --no-githooks "$@" "$TARGET_DIR"
}

# Backups of the two computed transport configs, at any generation.
hook_backup_count() {
  find "$TARGET_DIR" \
    \( -name 'settings.json.bak' -o -name 'settings.json.bak.*' \
    -o -name 'hooks.json.bak' -o -name 'hooks.json.bak.*' \) | wc -l
}

backup_count() {
  find "$TARGET_DIR" \( -name '*.bak' -o -name '*.bak.*' \) | wc -l
}

# Installed state by value, ignoring backups. JSON compares canonically
# because object key order carries no meaning in these configs.
tree_state() {
  local f
  while IFS= read -r -d '' f; do
    printf '%s\n' "${f#"$TARGET_DIR"}"
    case "$f" in
      *.json) jq -S . "$f" 2>/dev/null || cat "$f" ;;
      *) cat "$f" ;;
    esac
  done < <(find "$TARGET_DIR" -path "$TARGET_DIR/.git" -prune -o -type f \
    ! -name '*.bak' ! -name '*.bak.*' -print0 | LC_ALL=C sort -z) | sha256sum
}

stop_timeout() {
  case "$1" in
    claude) jq '[.hooks.Stop[]?.hooks[]? |
      select(.command | contains("stop-verify.sh")) | .timeout] | unique | .[0]' \
      "$TARGET_DIR/.claude/settings.json" ;;
    codex) jq '[.hooks.Stop[]?.hooks[]? |
      select(.command | contains(".codex/hooks/stop.sh")) | .timeout] | unique | .[0]' \
      "$TARGET_DIR/.codex/hooks.json" ;;
  esac
}

write_explicit_budget() {
  cat > "$TARGET_DIR/agent-md.toml" <<EOF
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 3
total_timeout_seconds = $1
EOF
}

@test "fresh install creates both transport configs and backs up nothing" {
  install_agent_md --agent=all
  [ -f "$TARGET_DIR/.claude/settings.json" ]
  [ -f "$TARGET_DIR/.codex/hooks.json" ]
  jq -e . "$TARGET_DIR/.claude/settings.json" >/dev/null
  jq -e . "$TARGET_DIR/.codex/hooks.json" >/dev/null
  [ "$(backup_count)" -eq 0 ]
}

@test "a second install with no effective change creates no backup" {
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(hook_backup_count)" -eq 0 ]
  [ "$(backup_count)" -eq 0 ]
}

@test "a second install reports both transport configs already current" {
  install_agent_md --agent=all
  run install_agent_md --agent=all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'already current  \.claude/settings\.json'
  echo "$output" | grep -q 'already current  \.codex/hooks\.json'
  echo "$output" | grep -vq 'backed up settings\.json'
  echo "$output" | grep -vq 'backed up hooks\.json'
}

@test "three consecutive reinstalls stay byte-stable and never accumulate backups" {
  install_agent_md --agent=all
  install_agent_md --agent=all
  settings_after_second=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  hooks_after_second=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$settings_after_second" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$hooks_after_second" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "a drifted owned handler is repaired with exactly one backup" {
  install_agent_md --agent=all
  [ "$(hook_backup_count)" -eq 0 ]

  # Drop a handler coding-agent-control owns. The merge has to put it back, which is
  # a real change and must cost exactly one backup.
  jq 'del(.hooks.PreToolUse)' "$TARGET_DIR/.claude/settings.json" \
    > "$TARGET_DIR/.claude/settings.next"
  mv "$TARGET_DIR/.claude/settings.next" "$TARGET_DIR/.claude/settings.json"

  install_agent_md --agent=all
  [ "$(jq '[.hooks.PreToolUse[]?.hooks[]? |
    select(.command | contains("block-destructive.sh"))] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)" -eq 1 ]

  # And the repaired state is itself stable.
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)" -eq 1 ]
}

@test "adding a third-party hook is preserved and is not a reason to rewrite" {
  install_agent_md --agent=all
  jq '.hooks.SessionStart = [{"hooks":[{"type":"command","command":"third-party added later"}]}]' \
    "$TARGET_DIR/.claude/settings.json" > "$TARGET_DIR/.claude/settings.next"
  mv "$TARGET_DIR/.claude/settings.next" "$TARGET_DIR/.claude/settings.json"
  settled=$(jq -S . "$TARGET_DIR/.claude/settings.json")

  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(jq --arg c 'third-party added later' \
    '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$settled" = "$(jq -S . "$TARGET_DIR/.claude/settings.json")" ]
  [ "$(hook_backup_count)" -eq 0 ]
}

@test "a changed effective total budget rewrites the envelope with one backup" {
  write_explicit_budget 7
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(stop_timeout claude)" -eq 37 ]
  [ "$(stop_timeout codex)" -eq 57 ]
  [ "$(hook_backup_count)" -eq 0 ]

  write_explicit_budget 9
  run install_agent_md --agent=all
  [ "$status" -eq 0 ]
  [ "$(stop_timeout claude)" -eq 39 ]
  [ "$(stop_timeout codex)" -eq 59 ]
  [ "$(hook_backup_count)" -eq 2 ]

  # Settled again: the new envelope does not churn either.
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(hook_backup_count)" -eq 2 ]
}

@test "an explicit total budget stays materialized across repeated installs" {
  write_explicit_budget 7
  install_agent_md --agent=all
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(stop_timeout claude)" -eq 37 ]
  [ "$(stop_timeout codex)" -eq 57 ]
  [ "$(hook_backup_count)" -eq 0 ]
}

@test "a legacy derived budget stays materialized across repeated installs" {
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
lint = "true"
test = "true"
[verify.policy]
required = ["lint", "test"]
timeout_seconds = 3
EOF
  install_agent_md --agent=all
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$(stop_timeout claude)" -eq 66 ]
  [ "$(stop_timeout codex)" -eq 86 ]
  [ "$(hook_backup_count)" -eq 0 ]
}

@test "third-party Claude hooks survive repeated installs without backup churn" {
  mkdir -p "$TARGET_DIR/.claude"
  cat > "$TARGET_DIR/.claude/settings.json" <<'EOF'
{
  "permissions": {"allow": ["Bash(git status)"]},
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "third-party start"}]}],
    "PreToolUse": [{"hooks": [{"type": "command", "command": "third-party pre"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]
  }
}
EOF
  install_agent_md --agent=claude
  first=$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)
  install_agent_md --agent=claude
  install_agent_md --agent=claude

  jq -e '.permissions.allow == ["Bash(git status)"]' "$TARGET_DIR/.claude/settings.json" >/dev/null
  for command in start pre stop; do
    [ "$(jq --arg c "third-party $command" \
      '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length' \
      "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  done
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  # The very first install merges onto a pre-existing file; nothing after it
  # may add another backup.
  [ "$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)" -eq "$first" ]
}

@test "third-party Codex hooks survive repeated installs without backup churn" {
  mkdir -p "$TARGET_DIR/.codex"
  cat > "$TARGET_DIR/.codex/hooks.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [{"hooks": [{"type": "command", "command": "third-party start"}]}],
    "PostToolUse": [{"hooks": [{"type": "command", "command": "third-party post"}]}],
    "Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]
  }
}
EOF
  install_agent_md --agent=codex
  first=$(find "$TARGET_DIR" -name 'hooks.json.bak*' | wc -l)
  install_agent_md --agent=codex
  install_agent_md --agent=codex

  for command in start post stop; do
    [ "$(jq --arg c "third-party $command" \
      '[.hooks[]?[]?.hooks[]? | select(.command == $c)] | length' \
      "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
  done
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh"))] | length' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
  [ "$(find "$TARGET_DIR" -name 'hooks.json.bak*' | wc -l)" -eq "$first" ]
}

@test "a pure object-key reorder is not treated as a change" {
  install_agent_md --agent=all
  # Reverse top-level and event key order without touching any handler array,
  # which is the one ordering these files do treat as meaningful.
  for config in "$TARGET_DIR/.claude/settings.json" "$TARGET_DIR/.codex/hooks.json"; do
    jq '. as $o
      | reduce ($o | keys_unsorted | reverse)[] as $k ({}; .[$k] = $o[$k])
      | .hooks |= (. as $h
        | reduce ($h | keys_unsorted | reverse)[] as $k ({}; .[$k] = $h[$k]))' \
      "$config" > "$config.reordered"
    mv "$config.reordered" "$config"
  done
  reordered_settings=$(sha256sum < "$TARGET_DIR/.claude/settings.json")

  run install_agent_md --agent=all
  [ "$status" -eq 0 ]
  [ "$(hook_backup_count)" -eq 0 ]
  echo "$output" | grep -q 'already current  \.claude/settings\.json'
  echo "$output" | grep -q 'already current  \.codex/hooks\.json'
  # No write happened, so the project's own ordering is left alone.
  [ "$reordered_settings" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
}

@test "a reordered handler array is a real change and is rewritten" {
  install_agent_md --agent=all
  # Handler execution order is meaningful, so the canonical comparison must not
  # normalize it away. The Stop group ships several owned handlers in a fixed
  # order; reversing them is a genuine difference the installer has to repair.
  [ "$(jq '[.hooks.Stop[]?.hooks[]?] | length' "$TARGET_DIR/.claude/settings.json")" -gt 1 ]
  jq '.hooks.Stop |= map(.hooks |= reverse)' "$TARGET_DIR/.claude/settings.json" \
    > "$TARGET_DIR/.claude/settings.next"
  mv "$TARGET_DIR/.claude/settings.next" "$TARGET_DIR/.claude/settings.json"

  install_agent_md --agent=all
  [ "$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)" -eq 1 ]
  [ "$(jq -c '[.hooks.Stop[]?.hooks[]?.command]' "$TARGET_DIR/.claude/settings.json")" \
    = "$(jq -c '[.hooks.Stop[]?.hooks[]?.command]' "$REPO/.claude/settings.json")" ]
}

@test "invalid existing hook JSON is still preserved and still creates no backup" {
  mkdir -p "$TARGET_DIR/.claude"
  echo '{invalid json' > "$TARGET_DIR/.claude/settings.json"
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [ "$(cat "$TARGET_DIR/.claude/settings.json")" = '{invalid json' ]
  echo "$output" | grep -q 'merge failed.*existing file left unchanged'
  [ "$(backup_count)" -eq 0 ]
}

@test "dry run after a real change reports it and writes nothing" {
  install_agent_md --agent=all
  write_explicit_budget 9
  before=$(tree_state)
  run install_agent_md --agent=all --dry-run
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'would set .*claude Stop timeout'
  [ "$before" = "$(tree_state)" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "no-overwrite leaves an existing transport config untouched" {
  install_agent_md --agent=all
  before_settings=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  before_hooks=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  write_explicit_budget 9
  run install_agent_md --agent=all --no-overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'skip (exists)    \.claude/settings\.json'
  [ "$before_settings" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$before_hooks" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "codex-hooks=skip leaves an existing Codex config untouched" {
  install_agent_md --agent=codex
  before=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  write_explicit_budget 9
  run install_agent_md --agent=codex --codex-hooks=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not touched'
  [ "$before" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "claude-settings=replace still backs up and replaces" {
  install_agent_md --agent=claude
  jq '.permissions = {"allow": ["Bash(git status)"]}' "$TARGET_DIR/.claude/settings.json" \
    > "$TARGET_DIR/.claude/settings.next"
  mv "$TARGET_DIR/.claude/settings.next" "$TARGET_DIR/.claude/settings.json"
  run install_agent_md --agent=claude --claude-settings=replace
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'replaced, backup kept'
  [ "$(find "$TARGET_DIR" -name 'settings.json.bak*' | wc -l)" -eq 1 ]
  [ "$(jq 'has("permissions")' "$TARGET_DIR/.claude/settings.json")" = false ]
}

@test "staging leaves no temporary candidate beside the transport configs" {
  # The candidate is staged next to its destination so the final move is a
  # same-filesystem rename. Nothing may survive that, on any path through the
  # installer.
  install_agent_md --agent=all
  install_agent_md --agent=all
  mkdir -p "$TARGET_DIR/.claude"
  echo '{invalid json' > "$TARGET_DIR/.claude/settings.json"
  install_agent_md --agent=all
  install_agent_md --agent=all --dry-run
  install_agent_md --agent=all --no-overwrite
  [ "$(find "$TARGET_DIR" -name '.*.install.*' | wc -l)" -eq 0 ]
}

@test "reinstalling changes nothing else in the installed tree" {
  install_agent_md --agent=all
  printf 'local note\n' >> "$TARGET_DIR/memory/progress.md"
  before=$(tree_state)
  before_progress=$(sha256sum < "$TARGET_DIR/memory/progress.md")
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$before" = "$(tree_state)" ]
  [ "$before_progress" = "$(sha256sum < "$TARGET_DIR/memory/progress.md")" ]
  [ "$(backup_count)" -eq 0 ]
}
