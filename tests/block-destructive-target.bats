#!/usr/bin/env bats
#
# A recursive deletion is authorized automatically only when its target is
# bound before it runs and its data is recoverable from Git. Every command
# here is only text on a PreToolUse entrypoint's stdin: nothing executes it,
# and the fixture is a disposable repository.

load helpers

setup() {
  setup_repo
  printf 'cache/\n' > .gitignore
  mkdir -p tracked/sub "tracked dir" data "dir with space" cache modified
  echo kept > tracked/sub/file
  echo kept > "tracked dir/file"
  echo kept > modified/file
  ln -s data tlink
  git add .gitignore tracked "tracked dir" modified tlink
  git commit -q -m fixture
  echo local-work > data/notes
  echo local-work > "dir with space/notes"
  echo generated > cache/blob
  echo edited >> modified/file
  mkdir -p tracked/deep-untracked
  echo local > tracked/deep-untracked/x
  OUTSIDE="$BATS_TEST_TMPDIR/outside"
  mkdir -p "$OUTSIDE/stuff"
  echo data > "$OUTSIDE/stuff/x"
}

teardown() { teardown_repo; }

# decide HOST COMMAND [CWD] — "<decision> <code>" from the host's entrypoint.
decide() {
  local host="$1" command="$2" cwd="${3:-$REPO_DIR}" payload out
  payload=$(jq -cn --arg c "$command" --arg d "$cwd" \
    '{hook_event_name:"PreToolUse",tool_name:"Bash",tool_input:{command:$c},cwd:$d}')
  if [ "$host" = claude ]; then
    out=$(printf '%s' "$payload" | (cd "$cwd" && bash "$REPO_DIR/.claude/hooks/block-destructive.sh"))
  else
    out=$(printf '%s' "$payload" | (cd "$cwd" && bash "$REPO_DIR/.codex/hooks/pre-tool-use.sh"))
  fi
  if [ -z "$out" ]; then echo none; return; fi
  printf '%s' "$out" | jq -r '
    .hookSpecificOutput as $h |
    if $h.hookEventName == "PreToolUse" and $h.permissionDecision == "deny" then
      "deny " + ($h.permissionDecisionReason | capture("\\[FATAL (?<c>[A-Z_]+)\\]").c)
    else "unexpected" end'
}

# expect WANT COMMAND [CWD] — both hosts reach the same structured decision.
expect() {
  local want="$1" command="$2" cwd="${3:-$REPO_DIR}" host got
  for host in claude codex; do
    got=$(decide "$host" "$command" "$cwd")
    [ "$got" = "$want" ] || { printf '%s: want <%s> got <%s> for: %s\n' "$host" "$want" "$got" "$command" >&2; return 1; }
  done
  [ -f data/notes ] && [ -f cache/blob ] && [ -f "$OUTSIDE/stuff/x" ]
}

@test "a deletion after a directory change that may fail is indeterminate" {
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'cd "prep dir that may not exist"; rm -rf data'
  expect 'deny SAFETY_TARGET_INDETERMINATE' $'cd prep\nrm -rf data'
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'mkdir -p prep && cd prep || true; rm -rf data'
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'cd prep & rm -rf data'
}

@test "local work, ignored data and modified tracked files are protected" {
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf data'
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -r cache'
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf modified'
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf "dir with space"'
  expect 'deny SAFETY_TARGET_PROTECTED' 'sudo rm -rf data'
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf tracked/sub data 2>/dev/null'
  expect 'deny SAFETY_TARGET_PROTECTED' "rm -rf $REPO_DIR/data"
}

@test "a target that depends on shell expansion or nested shells is indeterminate" {
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'rm -rf "$DIR"'
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'rm -rf $(cat targets)'
  expect 'deny SAFETY_TARGET_INDETERMINATE' "bash -c 'rm -rf data'"
  expect 'deny SAFETY_TARGET_INDETERMINATE' '(cd prep && rm -rf data)'
  expect 'deny SAFETY_TARGET_INDETERMINATE' 'printf data | xargs rm -rf'
}

@test "a target outside any Git worktree has no recovery evidence" {
  expect 'deny SAFETY_TARGET_UNVERIFIED' "rm -rf $OUTSIDE/stuff"
  expect 'deny SAFETY_TARGET_UNVERIFIED' 'rm -rf stuff' "$OUTSIDE"
}

@test "a trailing slash follows a link into the data it points to" {
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf tlink/'
  expect none 'rm -rf tlink'
}

@test "the session directory binds relative targets" {
  expect 'deny SAFETY_TARGET_PROTECTED' 'rm -rf deep-untracked' "$REPO_DIR/tracked"
  expect none 'rm -rf deep-untracked'
  expect none 'cd tracked && rm -rf sub'
  expect 'deny SAFETY_TARGET_PROTECTED' 'cd tracked && rm -rf deep-untracked'
}

@test "recoverable and absent targets and non-deletions stay allowed" {
  expect none 'rm -rf tracked/sub'
  expect none 'rm -rf "tracked dir"'
  expect none 'rm -rf ghost'
  expect none 'git status && rm -rf tracked/sub'
  expect none 'rm notes.txt'
  expect none 'ls -la data'
  expect none 'echo "rm -rf data"'
  expect none 'grep -r "rm -rf" docs'
}

@test "the earlier destructive rules keep their decisions" {
  expect 'deny SAFETY_PATH_VIOLATION' 'rm -rf /'
  expect 'deny SAFETY_PATH_VIOLATION' 'rm -rf ~/important'
  expect 'deny SAFETY_DESTRUCTIVE_COMMAND' 'git clean -fdx'
}
