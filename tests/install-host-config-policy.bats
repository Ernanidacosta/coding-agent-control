#!/usr/bin/env bats
#
# What skip, replace and --no-overwrite mean for the two host configs.
#
# All three decide what happens to a config that ALREADY EXISTS: `replace` and
# `merge` are meaningless without one, and the help has always described skip
# as preserving an existing file. A target that has no config yet therefore has
# nothing for them to protect, and the file is created complete — merged
# candidate plus this project's effective Stop envelope — under every mode.
#
# The matching obligation is honesty: whenever one of those choices stops the
# installer from writing, it must not leave the run looking like it made the
# host compatible. It reports any Stop envelope it could not synchronize.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  TARGET_DIR="$(mktemp -d)"
  export TARGET_DIR
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
  explicit_budget 11
}

teardown() {
  rm -rf "$TARGET_DIR"
}

install_agent_md() {
  bash "$REPO/install.sh" --no-githooks "$@" "$TARGET_DIR"
}

# total_timeout_seconds = N  ->  claude N+30, codex N+50.
explicit_budget() {
  cat > "$TARGET_DIR/agent-md.toml" <<EOF
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 3
total_timeout_seconds = $1
EOF
}

stop_timeout() {
  case "$1" in
    claude) jq -r '[.hooks.Stop[]?.hooks[]? |
      select(.command | contains("stop-verify.sh")) | .timeout][0] // "none"' \
      "$TARGET_DIR/.claude/settings.json" ;;
    codex) jq -r '[.hooks.Stop[]?.hooks[]? |
      select(.command | contains(".codex/hooks/stop.sh")) | .timeout][0] // "none"' \
      "$TARGET_DIR/.codex/hooks.json" ;;
  esac
}

backup_count() {
  find "$TARGET_DIR" \( -name '*.bak' -o -name '*.bak.*' \) | wc -l
}

seed_third_party() {
  mkdir -p "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  printf '%s\n' '{"permissions":{"allow":["Bash(git status)"]},"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"third-party start"}]}]}}' \
    > "$TARGET_DIR/.claude/settings.json"
  printf '%s\n' '{"hooks":{"SessionStart":[{"hooks":[{"type":"command","command":"third-party start"}]}]}}' \
    > "$TARGET_DIR/.codex/hooks.json"
}

stale_the_envelope() {
  jq '.hooks.Stop |= map(.hooks |= map(
    if (.command | contains("stop-verify.sh")) then .timeout = 999 else . end))' \
    "$TARGET_DIR/.claude/settings.json" > "$TARGET_DIR/.claude/next"
  mv "$TARGET_DIR/.claude/next" "$TARGET_DIR/.claude/settings.json"
}

@test "fresh Claude install carries this project's effective envelope" {
  install_agent_md --agent=claude
  [ "$(stop_timeout claude)" -eq 41 ]
  jq -e . "$TARGET_DIR/.claude/settings.json" >/dev/null
}

@test "fresh Codex install carries this project's effective envelope" {
  install_agent_md --agent=codex
  [ "$(stop_timeout codex)" -eq 61 ]
  jq -e . "$TARGET_DIR/.codex/hooks.json" >/dev/null
}

@test "fresh install under claude-settings=skip is created complete" {
  install_agent_md --agent=claude --claude-settings=skip
  [ -f "$TARGET_DIR/.claude/settings.json" ]
  jq -e . "$TARGET_DIR/.claude/settings.json" >/dev/null
  [ "$(stop_timeout claude)" -eq 41 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$(backup_count)" -eq 0 ]
}

@test "fresh install under codex-hooks=skip is created complete" {
  install_agent_md --agent=codex --codex-hooks=skip
  [ -f "$TARGET_DIR/.codex/hooks.json" ]
  jq -e . "$TARGET_DIR/.codex/hooks.json" >/dev/null
  [ "$(stop_timeout codex)" -eq 61 ]
  [ "$(backup_count)" -eq 0 ]
}

@test "fresh install under --no-overwrite is created complete" {
  install_agent_md --agent=all --no-overwrite
  [ "$(stop_timeout claude)" -eq 41 ]
  [ "$(stop_timeout codex)" -eq 61 ]
  [ "$(backup_count)" -eq 0 ]
}

@test "claude-settings=skip never touches an existing config" {
  install_agent_md --agent=claude
  explicit_budget 19
  before=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  run install_agent_md --agent=claude --claude-settings=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not touched'
  [ "$before" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "codex-hooks=skip never touches an existing config" {
  install_agent_md --agent=codex
  explicit_budget 19
  before=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  run install_agent_md --agent=codex --codex-hooks=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not touched'
  [ "$before" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "--no-overwrite preserves an existing config byte-for-byte with no backup" {
  install_agent_md --agent=all
  explicit_budget 19
  before_claude=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  before_codex=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  run install_agent_md --agent=all --no-overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'skip (exists)'
  [ "$before_claude" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$before_codex" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "a policy that blocks writing reports the envelope it could not synchronize" {
  install_agent_md --agent=claude
  stale_the_envelope
  run install_agent_md --agent=claude --claude-settings=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not synchronized by your policy'
  echo "$output" | grep -q 'installed 999s'
  echo "$output" | grep -q 'needs 41s'

  run install_agent_md --agent=claude --no-overwrite
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not synchronized by your policy'
}

@test "an envelope that already matches is not reported as a problem" {
  install_agent_md --agent=all
  run install_agent_md --agent=all --claude-settings=skip --codex-hooks=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not touched'
  echo "$output" | grep -vq 'not synchronized by your policy'
}

@test "skip and --no-overwrite never destroy third-party configuration" {
  seed_third_party
  for flags in "--claude-settings=skip --codex-hooks=skip" "--no-overwrite"; do
    before_claude=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
    before_codex=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
    # shellcheck disable=SC2086
    install_agent_md --agent=all $flags
    [ "$before_claude" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
    [ "$before_codex" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  done
  # And the default merge keeps them while installing the owned handlers.
  install_agent_md --agent=all
  jq -e '.permissions.allow == ["Bash(git status)"]' "$TARGET_DIR/.claude/settings.json" >/dev/null
  for config in "$TARGET_DIR/.claude/settings.json" "$TARGET_DIR/.codex/hooks.json"; do
    [ "$(jq '[.hooks[]?[]?.hooks[]? | select(.command == "third-party start")] | length' "$config")" -eq 1 ]
  done
}

@test "an explicit total budget is materialized under every host-config mode" {
  explicit_budget 7
  install_agent_md --agent=all
  [ "$(stop_timeout claude)" -eq 37 ]
  [ "$(stop_timeout codex)" -eq 57 ]
  rm -rf "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  install_agent_md --agent=all --claude-settings=skip --codex-hooks=skip
  [ "$(stop_timeout claude)" -eq 37 ]
  [ "$(stop_timeout codex)" -eq 57 ]
  rm -rf "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  install_agent_md --agent=all --no-overwrite
  [ "$(stop_timeout claude)" -eq 37 ]
  [ "$(stop_timeout codex)" -eq 57 ]
}

@test "a legacy derived budget is materialized under every host-config mode" {
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
lint = "true"
test = "true"
[verify.policy]
required = ["lint", "test"]
timeout_seconds = 3
EOF
  install_agent_md --agent=all --claude-settings=skip --codex-hooks=skip
  [ "$(stop_timeout claude)" -eq 66 ]
  [ "$(stop_timeout codex)" -eq 86 ]
  rm -rf "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  install_agent_md --agent=all --no-overwrite
  [ "$(stop_timeout claude)" -eq 66 ]
  [ "$(stop_timeout codex)" -eq 86 ]
}

@test "dry run describes the fresh write and its envelope without creating anything" {
  run install_agent_md --agent=all --dry-run --claude-settings=skip --codex-hooks=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'would write     .claude/settings.json'
  echo "$output" | grep -q 'would set       claude Stop timeout (41s'
  echo "$output" | grep -q 'would set       codex Stop timeout (61s'
  [ ! -f "$TARGET_DIR/.claude/settings.json" ]
  [ ! -f "$TARGET_DIR/.codex/hooks.json" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "dry run over an existing config reports the untouched policy decision" {
  install_agent_md --agent=all
  before=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  run install_agent_md --agent=all --dry-run --claude-settings=skip
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'not touched'
  [ "$before" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "repeated installs under every mode stay stable and free of backups" {
  install_agent_md --agent=all
  install_agent_md --agent=all
  install_agent_md --agent=all --claude-settings=skip --codex-hooks=skip
  install_agent_md --agent=all --no-overwrite
  settled_claude=$(sha256sum < "$TARGET_DIR/.claude/settings.json")
  settled_codex=$(sha256sum < "$TARGET_DIR/.codex/hooks.json")
  install_agent_md --agent=all
  install_agent_md --agent=all
  [ "$settled_claude" = "$(sha256sum < "$TARGET_DIR/.claude/settings.json")" ]
  [ "$settled_codex" = "$(sha256sum < "$TARGET_DIR/.codex/hooks.json")" ]
  [ "$(backup_count)" -eq 0 ]
}

@test "the installed envelope satisfies the host preflight it is resolved from" {
  install_agent_md --agent=all --claude-settings=skip --codex-hooks=skip
  cd "$TARGET_DIR"
  run bash -c 'printf "%s" "{\"stop_hook_active\":false}" | bash .claude/hooks/stop-verify.sh'
  [ "$status" -eq 0 ]
  echo "$output" | grep -vq 'VERIFY_HOST_TIMEOUT_INCOMPATIBLE'
}
