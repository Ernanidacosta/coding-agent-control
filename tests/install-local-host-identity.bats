#!/usr/bin/env bats

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  TARGET_DIR=$(mktemp -d)
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
}

teardown() { rm -rf "$TARGET_DIR"; }

install_agents() { bash "$REPO/install.sh" --agent=all --no-githooks "$TARGET_DIR" >/dev/null; }

source_manifest() {
  bash -c 'cd "$1" && . "$2" && verification_receipt_source_manifest_json worktree' \
    _ "$TARGET_DIR" "$REPO/.claude/hooks/_lib.sh"
}

vendored_manifest() {
  bash -c 'cd "$1" && . "$2" && authority_pa_verification_receipt_source_manifest_json worktree' \
    _ "$TARGET_DIR" "$REPO/examples/local-issuer/phase-a-source.sh"
}

host_paths() {
  printf '%s\n' \
    .claude/settings.json .claude/settings.json.bak .claude/settings.json.bak.1 \
    .codex/hooks.json .codex/hooks.json.bak .codex/hooks.json.bak.1 \
    .cursor/rules/agent-md.mdc .cursor/rules/agent-md.mdc.bak \
    .cursor/rules/agent-md.mdc.bak.1 \
    .windsurf/rules/agent-md.md .windsurf/rules/agent-md.md.bak \
    .windsurf/rules/agent-md.md.bak.1
}

@test "installer host wiring and backups stay out of untracked worktree identity" {
  install_agents
  local path
  while IFS= read -r path; do
    case "$path" in *.bak|*.bak.1) cp -p "$TARGET_DIR/${path%%.bak*}" "$TARGET_DIR/$path" ;; esac
    chmod 0600 "$TARGET_DIR/$path"
  done < <(host_paths)

  source_manifest > "$TARGET_DIR/.git/core-source.json"
  vendored_manifest > "$TARGET_DIR/.git/authority-source.json"
  cmp "$TARGET_DIR/.git/core-source.json" "$TARGET_DIR/.git/authority-source.json"
  jq -e '.valid == true' "$TARGET_DIR/.git/core-source.json" >/dev/null
  while IFS= read -r path; do
    [ "$(stat -c %a "$TARGET_DIR/$path")" = 600 ]
    jq -e --arg path "$path" 'all(.entries[]; .path != $path)' \
      "$TARGET_DIR/.git/core-source.json" >/dev/null
    git -C "$TARGET_DIR" check-ignore -q "$path"
  done < <(host_paths)
  [ ! -e "$TARGET_DIR/.claude/settings.json.bak.2" ]
  [ ! -e "$TARGET_DIR/.codex/hooks.json.bak.2" ]
}

@test "indexed private host paths remain in both Phase A manifests" {
  install_agents
  local path
  while IFS= read -r path; do
    case "$path" in *.bak|*.bak.1) cp -p "$TARGET_DIR/${path%%.bak*}" "$TARGET_DIR/$path" ;; esac
    chmod 0600 "$TARGET_DIR/$path"
    git -C "$TARGET_DIR" add -f "$path"
  done < <(host_paths)
  source_manifest > "$TARGET_DIR/.git/core-source.json"
  vendored_manifest > "$TARGET_DIR/.git/authority-source.json"
  cmp "$TARGET_DIR/.git/core-source.json" "$TARGET_DIR/.git/authority-source.json"
  while IFS= read -r path; do
    jq -e --arg path "$path" 'any(.entries[]; .path == $path and .index.state == "present")' \
      "$TARGET_DIR/.git/core-source.json" >/dev/null
    [ "$(stat -c %a "$TARGET_DIR/$path")" = 600 ]
  done < <(host_paths)
}

@test "a tracked source file unreadable to the hashing account remains invalid" {
  install_agents
  printf 'private source\n' > "$TARGET_DIR/tracked-private.txt"
  git -C "$TARGET_DIR" add tracked-private.txt
  chmod 0000 "$TARGET_DIR/tracked-private.txt"
  source_manifest > "$TARGET_DIR/.git/core-source.json"
  vendored_manifest > "$TARGET_DIR/.git/authority-source.json"
  cmp "$TARGET_DIR/.git/core-source.json" "$TARGET_DIR/.git/authority-source.json"
  jq -e '.valid == false and
    any(.entries[]; .path == "tracked-private.txt" and .worktree.state == "unreadable")' \
    "$TARGET_DIR/.git/core-source.json" >/dev/null
  [ "$(stat -c %a "$TARGET_DIR/tracked-private.txt")" = 0 ]
}

@test "reinstall keeps private host config modes and repository excludes stable" {
  install_agents
  local path
  while IFS= read -r path; do chmod 0600 "$TARGET_DIR/$path"; done < <(
    printf '%s\n' .claude/settings.json .codex/hooks.json \
      .cursor/rules/agent-md.mdc .windsurf/rules/agent-md.md)
  local before
  before=$(sha256sum "$TARGET_DIR/.git/info/exclude")
  install_agents
  [ "$(sha256sum "$TARGET_DIR/.git/info/exclude")" = "$before" ]
  while IFS= read -r path; do [ "$(stat -c %a "$TARGET_DIR/$path")" = 600 ]; done < <(
    printf '%s\n' .claude/settings.json .codex/hooks.json \
      .cursor/rules/agent-md.mdc .windsurf/rules/agent-md.md)
}

@test "replacing existing Cursor and Windsurf rules preserves their chosen modes" {
  mkdir -p "$TARGET_DIR/.cursor/rules" "$TARGET_DIR/.windsurf/rules"
  printf 'older rule\n' > "$TARGET_DIR/.cursor/rules/agent-md.mdc"
  printf 'older rule\n' > "$TARGET_DIR/.windsurf/rules/agent-md.md"
  chmod 0644 "$TARGET_DIR/.cursor/rules/agent-md.mdc"
  chmod 0600 "$TARGET_DIR/.windsurf/rules/agent-md.md"
  install_agents
  [ "$(stat -c %a "$TARGET_DIR/.cursor/rules/agent-md.mdc")" = 644 ]
  [ "$(stat -c %a "$TARGET_DIR/.windsurf/rules/agent-md.md")" = 600 ]
  [ "$(stat -c %a "$TARGET_DIR/.cursor/rules/agent-md.mdc.bak")" = 644 ]
  [ "$(stat -c %a "$TARGET_DIR/.windsurf/rules/agent-md.md.bak")" = 600 ]
  local before
  before=$(sha256sum "$TARGET_DIR/.git/info/exclude")
  install_agents
  [ "$(sha256sum "$TARGET_DIR/.git/info/exclude")" = "$before" ]
  [ "$(stat -c %a "$TARGET_DIR/.cursor/rules/agent-md.mdc")" = 644 ]
  [ "$(stat -c %a "$TARGET_DIR/.windsurf/rules/agent-md.md")" = 600 ]
}
