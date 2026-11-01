#!/usr/bin/env bats
#
# Hosts start hooks from the session's working directory, which can be any
# subdirectory of the project. Policy, state and checks belong to the
# repository root, so every completion hook must reach the same decision
# from the root, from src/ and from src/pkg/.

load helpers

setup() {
  setup_repo
  ORIGINAL_REPO_DIR="$REPO_DIR"
  export CLAUDE_PROJECT_DIR="$REPO_DIR"
  mkdir -p src/pkg
}

teardown() {
  REPO_DIR="$ORIGINAL_REPO_DIR"
  teardown_repo
}

outside_git() {
  [ "$(git -C "$1" rev-parse --is-inside-work-tree 2>/dev/null)" != true ]
}

configured() {
  local file="$1" event="$2"
  jq -er --arg event "$event" '.hooks[$event][0].hooks[0].command' "$file"
}

# claude_stop DIR — the configured Claude Stop gate, started from DIR.
claude_stop() {
  local command
  command=$(configured "$REPO_DIR/.claude/settings.json" Stop) || return
  (cd "$1" && printf '{"stop_hook_active":false}' | bash -c "$command")
}

# claude_state DIR — the configured Claude progress gate, started from DIR.
claude_state() {
  local command
  command=$(jq -er '.hooks.Stop[0].hooks[] | select(.command | contains("state-enforcement")) | .command' \
    "$REPO_DIR/.claude/settings.json") || return
  (cd "$1" && printf '{"stop_hook_active":false}' | bash -c "$command")
}

# codex_stop DIR — the configured Codex Stop wrapper, started from DIR.
codex_stop() {
  local command
  command=$(configured "$REPO_DIR/.codex/hooks.json" Stop) || return
  (cd "$1" && printf '{"stop_hook_active":false}' | bash -c "$command")
}

# same_from_every_dir GATE — the GATE output at the root, after asserting
# that src/ and src/pkg/ produce exactly the same output.
same_from_every_dir() {
  local gate="$1" root sub dir
  root=$("$gate" "$REPO_DIR")
  for dir in src src/pkg; do
    sub=$("$gate" "$REPO_DIR/$dir")
    if [ "$sub" != "$root" ]; then
      printf 'from %s:\n%s\n\nfrom the root:\n%s\n' "$dir" "$sub" "$root" >&2
      return 1
    fi
  done
  printf '%s' "$root"
}

blocks_with() {
  jq -e --arg code "$1" '.decision == "block" and (.reason | contains($code))' >/dev/null
}

does_not_block() {
  ! jq -e '.decision? == "block"' >/dev/null 2>&1 <<<"$1"
}

required_lint() {
  printf '[verify]\nlint = "%s"\n\n[verify.policy]\nrequired = ["lint"]\n' "$1" > "$REPO_DIR/agent-md.toml"
}

broken_shell_at_root() {
  required_lint "find . -name '*.sh' -not -path './.*' -exec sh -n {} +"
  printf 'if then\n' > "$REPO_DIR/broken.sh"
  printf 'echo ok\n' > "$REPO_DIR/src/pkg/fine.sh"
}

high_risk_done_without_independent() {
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > "$REPO_DIR/agent-md.toml"
  (cd "$REPO_DIR" && write_progress done "Harden authentication" "" high)
}

@test "Claude Stop: a check relative to . sees the whole repository from every directory" {
  required_lint "test -f ./agent-md.toml && test -d ./src/pkg"
  out=$(same_from_every_dir claude_stop)
  does_not_block "$out"
}

@test "Claude Stop: a required check that fails at the root fails from every directory" {
  broken_shell_at_root
  out=$(same_from_every_dir claude_stop)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
  [[ "$out" == *"broken.sh"* ]]
}

@test "Claude Stop: a required check that passes at the root passes from every directory" {
  required_lint "test -f agent-md.toml"
  out=$(same_from_every_dir claude_stop)
  does_not_block "$out"
}

@test "Claude Stop: Risk high done without independent evidence blocks from every directory" {
  high_risk_done_without_independent
  out=$(same_from_every_dir claude_stop)
  blocks_with RISK_INDEPENDENT_VERIFICATION_REQUIRED <<<"$out"
}

@test "Claude Stop: progress resolves the same file from every directory" {
  printf '[verify]\ntest = "true"\n' > agent-md.toml
  write_progress active
  out=$(same_from_every_dir claude_state)
  blocks_with STATE_ <<<"$out"
}

@test "Claude Stop: agent-md.toml resolves the same file from every directory" {
  printf '[verify]\ntest = "true"\ntest = "false"\n' > agent-md.toml
  out=$(same_from_every_dir claude_stop)
  blocks_with CONFIG_INVALID <<<"$out"
  [[ "$out" == *"duplicate key verify.test"* ]]
}

@test "Claude SubagentStop: a child gate decides from the root, not the child directory" {
  broken_shell_at_root
  command=$(configured .claude/settings.json SubagentStart)
  child() {
    jq -cn --arg event "$1" '{hook_event_name:$event,session_id:"s",agent_id:"c",stop_hook_active:false}'
  }
  stop=$(configured .claude/settings.json SubagentStop)
  for dir in . src src/pkg; do
    (cd "$dir" && child SubagentStart | bash -c "$command" >/dev/null)
    out=$(cd "$dir" && child SubagentStop | bash -c "$stop")
    blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
  done
}

@test "Codex Stop: a required check that fails at the root fails from every directory" {
  broken_shell_at_root
  out=$(same_from_every_dir codex_stop)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
}

@test "Codex Stop: a required check that passes at the root passes from every directory" {
  required_lint "test -f ./agent-md.toml && test -d ./src/pkg"
  out=$(same_from_every_dir codex_stop)
  does_not_block "$out"
}

@test "Codex Stop: Risk high done without independent evidence blocks from every directory" {
  high_risk_done_without_independent
  out=$(same_from_every_dir codex_stop)
  blocks_with RISK_INDEPENDENT_VERIFICATION_REQUIRED <<<"$out"
}

@test "Codex Stop: state and completion resolve the same progress from every directory" {
  printf '[verify]\ntest = "true"\n' > agent-md.toml
  write_progress active
  out=$(same_from_every_dir codex_stop)
  blocks_with STATE_ <<<"$out"
}

@test "a repository whose path contains spaces decides the same from every directory" {
  spaced="$BATS_TEST_TMPDIR/my project/the repo"
  mkdir -p "$spaced/src/pkg"
  cp -r .claude .codex "$spaced/"
  git -C "$spaced" init -q
  git -C "$spaced" config core.excludesFile /dev/null
  REPO_DIR="$spaced"
  CLAUDE_PROJECT_DIR="$spaced"

  broken_shell_at_root
  out=$(same_from_every_dir claude_stop)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
  out=$(same_from_every_dir codex_stop)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"

  rm "$spaced/broken.sh"
  high_risk_done_without_independent
  out=$(same_from_every_dir claude_stop)
  blocks_with RISK_INDEPENDENT_VERIFICATION_REQUIRED <<<"$out"
  out=$(same_from_every_dir codex_stop)
  blocks_with RISK_INDEPENDENT_VERIFICATION_REQUIRED <<<"$out"
}

@test "a session directory outside the repository still evaluates the project that owns the hooks" {
  broken_shell_at_root
  root=$(claude_stop "$REPO_DIR")
  blocks_with VERIFY_REQUIRED_FAILED <<<"$root"
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  outside_git "$outside"
  [ "$(claude_stop "$outside")" = "$root" ]
}

@test "a session inside another repository never evaluates that repository" {
  broken_shell_at_root
  root=$(claude_stop "$REPO_DIR")
  other="$BATS_TEST_TMPDIR/other"
  mkdir -p "$other"
  git -C "$other" init -q
  printf '[verify]\nlint = "true"\n\n[verify.policy]\nrequired = ["lint"]\n' > "$other/agent-md.toml"
  [ "$(claude_stop "$other")" = "$root" ]
}

@test "hooks outside a Git repository block explicitly instead of guessing a root" {
  plain="$BATS_TEST_TMPDIR/plain"
  mkdir -p "$plain/src/pkg"
  cp -r .claude .codex "$plain/"
  printf '[verify]\ntest = "true"\n' > "$plain/agent-md.toml"
  outside_git "$plain"
  for dir in "$plain" "$plain/src/pkg"; do
    out=$(cd "$dir" && printf '{}' | bash "$plain/.claude/hooks/stop-verify.sh")
    blocks_with VERIFY_UNAVAILABLE <<<"$out"
    [[ "$out" == *"not inside the root of a Git worktree"* ]]
  done
  out=$(cd "$plain" && printf '{}' | bash .codex/hooks/stop.sh)
  blocks_with VERIFY_UNAVAILABLE <<<"$out"
}

post_edit() {
  local dir="$1" path="$2" command
  command=$(jq -er '.hooks.PostToolUse[0].hooks[0].command' "$REPO_DIR/.claude/settings.json") || return
  jq -cn --arg path "$path" '{tool_input:{file_path:$path}}' | (cd "$dir" && bash -c "$command")
}

@test "post-edit: config is found at the root when the session is in a subdirectory" {
  printf '[verify]\nlint_file = "false"\n' > agent-md.toml
  touch src/pkg/a.ts
  out=$(post_edit src/pkg a.ts)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
}

@test "post-edit: {file} names the edited file and lint_file runs at the root" {
  printf '[verify]\nlint_file = "echo {file} >> lint-seen"\n' > agent-md.toml
  touch src/pkg/a.ts
  out=$(post_edit src/pkg a.ts)
  [ -z "$out" ]
  out=$(post_edit src/pkg "$REPO_DIR/src/pkg/a.ts")
  [ -z "$out" ]
  out=$(post_edit . src/pkg/a.ts)
  [ -z "$out" ]
  [ "$(cat lint-seen)" = "src/pkg/a.ts
$REPO_DIR/src/pkg/a.ts
src/pkg/a.ts" ]
  [ ! -e src/pkg/lint-seen ]
}

@test "post-edit: a relative lint_file command resolves from the root" {
  mkdir -p tools
  printf 'exit 3\n' > tools/lint.sh
  printf '[verify]\nlint_file = "sh tools/lint.sh {file}"\n' > agent-md.toml
  touch src/pkg/a.ts
  out=$(post_edit src/pkg a.ts)
  blocks_with VERIFY_REQUIRED_FAILED <<<"$out"
}

@test "post-edit: a file outside the repository is not linted as a project file" {
  printf '[verify]\nlint_file = "false"\n' > agent-md.toml
  outside="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$outside"
  touch "$outside/a.ts"
  out=$(post_edit . "$outside/a.ts")
  [ -z "$out" ]
  relative=$(python3 -c 'import os, sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))' \
    "$outside/a.ts" "$REPO_DIR/src/pkg")
  [[ "$relative" == ../* ]]
  out=$(post_edit src/pkg "$relative")
  [ -z "$out" ]
}
