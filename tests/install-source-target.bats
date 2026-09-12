#!/usr/bin/env bats
#
# Source-package versus target-project separation.
#
# An installed project carries AGENT.md too, so AGENT.md in the working
# directory never identifies the installer's source package. These tests pin
# that distinction and the same-file guard that keeps a writer from moving its
# own source aside.

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  export REPO
  TARGET_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  export TARGET_DIR WORK
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
}

teardown() {
  rm -rf "$TARGET_DIR" "$WORK"
}

# A package tree copied out of the repository, standing in for the published
# archive. Tests never reach the network.
package_copy() {
  local dest="$1"
  mkdir -p "$dest"
  tar -cf - -C "$REPO" --exclude=.git . | tar -xf - -C "$dest"
}

build_source_archive() {
  local stage="$WORK/stage"
  mkdir -p "$stage"
  package_copy "$stage/coding-agent-control-main"
  tar -czf "$WORK/package.tar.gz" -C "$stage" coding-agent-control-main
  printf '%s\n' "$WORK/package.tar.gz"
}

install_from_file() {
  bash "$REPO/install.sh" --no-githooks "$@" "$TARGET_DIR"
}

# Script arrives on stdin with no source file, exactly like curl | bash.
install_from_stdin() {
  local archive="$1"
  shift
  cat "$REPO/install.sh" \
    | CODING_AGENT_CONTROL_SOURCE_ARCHIVE="$archive" bash -s -- --no-githooks "$@"
}

# Installed content only. Backups are excluded because they record history
# rather than installed state, and JSON is compared by value: the hook merge
# emits event keys in sorted order, which is a formatting difference from the
# first install's plain copy, not a difference in installed configuration.
tree_checksum() {
  local root="$1" f
  while IFS= read -r -d '' f; do
    printf '%s\n' "${f#"$root"}"
    case "$f" in
      *.json) jq -S . "$f" 2>/dev/null || cat "$f" ;;
      *) cat "$f" ;;
    esac
  done < <(find "$root" -path "$root/.git" -prune -o -type f \
    ! -name '*.bak' ! -name '*.bak.*' -print0 | LC_ALL=C sort -z) | sha256sum
}

plain_backup_count() {
  find "$1" -name '*.bak' -o -name '*.bak.*' \
    | grep -vE '/(settings\.json|hooks\.json)\.bak' | wc -l
}

@test "fresh install from a local script populates the target" {
  install_from_file --agent=all
  grep -q "coding-agent-control Directives" "$TARGET_DIR/AGENT.md"
  [ -f "$TARGET_DIR/.claude/hooks/_lib.sh" ]
  [ -f "$TARGET_DIR/.agent-md/bin/doctor.sh" ]
  [ -f "$TARGET_DIR/.githooks/commit-msg" ]
  [ ! -f "$TARGET_DIR/AGENT.md.bak" ]
}

@test "reinstall from a local script is stable and keeps the source intact" {
  install_from_file --agent=all
  first=$(tree_checksum "$TARGET_DIR")
  install_from_file --agent=all
  second=$(tree_checksum "$TARGET_DIR")
  [ "$first" = "$second" ]
  [ -f "$REPO/AGENT.md" ]
  [ -f "$REPO/install.sh" ]
}

@test "two consecutive full reinstalls produce a stable result" {
  install_from_file --agent=all
  install_from_file --agent=all
  before=$(tree_checksum "$TARGET_DIR")
  install_from_file --agent=all
  [ "$before" = "$(tree_checksum "$TARGET_DIR")" ]
}

@test "reinstalling unchanged plain files reports them current and creates no backup" {
  install_from_file --agent=all
  run install_from_file --agent=all
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already current"
  # AGENT.md, CLAUDE.md, hooks and git hooks must not accumulate backups.
  [ "$(plain_backup_count "$TARGET_DIR")" -eq 0 ]
  [ ! -f "$TARGET_DIR/AGENT.md.bak" ]
  [ ! -f "$TARGET_DIR/.claude/hooks/_lib.sh.bak" ]
  [ ! -f "$TARGET_DIR/.githooks/commit-msg.bak" ]
}

@test "fresh install from stdin resolves the source from the package archive" {
  archive=$(build_source_archive)
  run install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "Source: fetched package archive"
  grep -q "coding-agent-control Directives" "$TARGET_DIR/AGENT.md"
  [ -f "$TARGET_DIR/.claude/hooks/_lib.sh" ]
}

@test "stdin reinstall into a target that already has AGENT.md updates it without losing the source" {
  archive=$(build_source_archive)
  printf 'PRE-EXISTING PROJECT DIRECTIVES\n' > "$TARGET_DIR/AGENT.md"

  cd "$TARGET_DIR"
  run install_from_stdin "$archive" --agent=all .
  [ "$status" -eq 0 ]

  # The reported failure mode was a vanished source and a stat error.
  ! echo "$output" | grep -q "cannot stat"
  ! echo "$output" | grep -q "No such file or directory"

  # AGENT.md updated from the package, previous content preserved in a backup.
  grep -q "coding-agent-control Directives" "$TARGET_DIR/AGENT.md"
  [ -f "$TARGET_DIR/AGENT.md.bak" ]
  grep -q "PRE-EXISTING PROJECT DIRECTIVES" "$TARGET_DIR/AGENT.md.bak"

  # Nothing in the target was consumed as if it were the source.
  [ -f "$TARGET_DIR/.claude/hooks/_lib.sh" ]
  [ ! -f "$TARGET_DIR/install.sh" ]
}

@test "stdin execution never adopts the working directory as the source package" {
  # Make the working directory look like a complete package, including the one
  # marker an installed project would not normally have.
  cp "$REPO/AGENT.md" "$TARGET_DIR/AGENT.md"
  cp "$REPO/install.sh" "$TARGET_DIR/install.sh"
  cp "$REPO/agent-md.toml.example" "$TARGET_DIR/agent-md.toml.example"
  mkdir -p "$TARGET_DIR/.claude/hooks" "$TARGET_DIR/.agent-md/bin"
  cp "$REPO/.claude/hooks/_lib.sh" "$TARGET_DIR/.claude/hooks/_lib.sh"
  cp "$REPO/.agent-md/bin/doctor.sh" "$TARGET_DIR/.agent-md/bin/doctor.sh"

  cd "$TARGET_DIR"
  run bash -c "cat '$REPO/install.sh' | CODING_AGENT_CONTROL_SOURCE_URL='file:///nonexistent/package.tar.gz' bash -s -- --no-githooks ."

  # It must fail reaching for the official package rather than silently
  # treating the target project as the source.
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cannot download or unpack"
  [ -f "$TARGET_DIR/AGENT.md" ]
  [ ! -f "$TARGET_DIR/AGENT.md.bak" ]
}

@test "a source package separate from the target installs without touching the package" {
  package_copy "$WORK/package"
  before=$(tree_checksum "$WORK/package")
  bash "$WORK/package/install.sh" --no-githooks --agent=all "$TARGET_DIR"
  [ "$before" = "$(tree_checksum "$WORK/package")" ]
  grep -q "coding-agent-control Directives" "$TARGET_DIR/AGENT.md"
}

@test "self install where src equals dst never removes the source" {
  package_copy "$WORK/package"
  git -C "$WORK/package" init -q
  run bash "$WORK/package/install.sh" --no-githooks --agent=all "$WORK/package"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already current"

  # Every file the same-file guard protects is still present and not renamed.
  for f in AGENT.md install.sh agent-md.toml.example \
    .claude/hooks/_lib.sh .agent-md/bin/doctor.sh .githooks/commit-msg; do
    [ -f "$WORK/package/$f" ]
    [ ! -f "$WORK/package/$f.bak" ]
  done
  grep -q "coding-agent-control Directives" "$WORK/package/AGENT.md"
}

@test "self install leaves a Cursor rule file and its AGENT.md body intact" {
  package_copy "$WORK/package"
  git -C "$WORK/package" init -q
  bash "$WORK/package/install.sh" --no-githooks --agent=cursor "$WORK/package"
  [ -f "$WORK/package/AGENT.md" ]
  grep -q "coding-agent-control Directives" "$WORK/package/.cursor/rules/agent-md.mdc"
  grep -q "alwaysApply: true" "$WORK/package/.cursor/rules/agent-md.mdc"
}

@test "backup still happens when source and target differ" {
  printf 'OLD PROJECT CONTENT\n' > "$TARGET_DIR/AGENT.md"
  install_from_file --agent=all
  [ -f "$TARGET_DIR/AGENT.md.bak" ]
  grep -q "OLD PROJECT CONTENT" "$TARGET_DIR/AGENT.md.bak"
  ! grep -q "OLD PROJECT CONTENT" "$TARGET_DIR/AGENT.md"
}

@test "dry run changes nothing in the target" {
  install_from_file --agent=all
  before=$(tree_checksum "$TARGET_DIR")
  run install_from_file --dry-run --agent=all
  [ "$status" -eq 0 ]
  [ "$before" = "$(tree_checksum "$TARGET_DIR")" ]
}

@test "dry run on a fresh target writes no files at all" {
  run install_from_file --dry-run --agent=all
  [ "$status" -eq 0 ]
  [ ! -f "$TARGET_DIR/AGENT.md" ]
  [ ! -d "$TARGET_DIR/.claude" ]
  [ ! -d "$TARGET_DIR/memory" ]
}

@test "no-overwrite preserves existing files and creates no backup" {
  printf 'MINE\n' > "$TARGET_DIR/AGENT.md"
  install_from_file --no-overwrite --agent=all
  grep -q "MINE" "$TARGET_DIR/AGENT.md"
  [ ! -f "$TARGET_DIR/AGENT.md.bak" ]
}

@test "existing memory working state survives a stdin reinstall" {
  archive=$(build_source_archive)
  mkdir -p "$TARGET_DIR/memory"
  printf 'Status: active\n' > "$TARGET_DIR/memory/progress.md"
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  grep -q "Status: active" "$TARGET_DIR/memory/progress.md"
}

@test "commit-msg authorship hook is installed byte-identical from stdin" {
  archive=$(build_source_archive)
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  [ -f "$TARGET_DIR/.githooks/commit-msg" ]
  cmp -s "$REPO/.githooks/commit-msg" "$TARGET_DIR/.githooks/commit-msg"
}

@test "timeout envelopes are still materialized from a stdin install" {
  archive=$(build_source_archive)
  cat > "$TARGET_DIR/agent-md.toml" <<'EOF'
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 3
total_timeout_seconds = 7
EOF
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"

  [ "$(jq '[.hooks.Stop[]?.hooks[]? |
    select(.command | contains("stop-verify.sh")) | .timeout] | unique | .[0]' \
    "$TARGET_DIR/.claude/settings.json")" -eq 37 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? |
    select(.command | contains(".codex/hooks/stop.sh")) | .timeout] | unique | .[0]' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 57 ]
}

@test "hook merges stay idempotent across a stdin reinstall" {
  archive=$(build_source_archive)
  mkdir -p "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  cat > "$TARGET_DIR/.claude/settings.json" <<'EOF'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]}}
EOF
  cat > "$TARGET_DIR/.codex/hooks.json" <<'EOF'
{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]}}
EOF
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"

  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command == "third-party stop")] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains("stop-verify.sh"))] | length' \
    "$TARGET_DIR/.claude/settings.json")" -eq 1 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command == "third-party stop")] | length' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
  [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command | contains(".codex/hooks/stop.sh"))] | length' \
    "$TARGET_DIR/.codex/hooks.json")" -eq 1 ]
}

@test "the fetched archive temporary directory is removed on success and on failure" {
  archive=$(build_source_archive)
  before=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
  install_from_stdin "$archive" --agent=all "$TARGET_DIR"
  run install_from_stdin "/nonexistent/package.tar.gz" --agent=all "$TARGET_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "source archive not found"
  after=$(find "${TMPDIR:-/tmp}" -maxdepth 1 -name 'tmp.*' -type d 2>/dev/null | wc -l)
  [ "$after" -le "$before" ]
}
