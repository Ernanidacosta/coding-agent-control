# tests/helpers.bash — shared setup for bats suites.

setup_repo() {
  local git_local_vars git_local_var
  git_local_vars=$(git rev-parse --local-env-vars) || return 1
  while IFS= read -r git_local_var; do
    unset "$git_local_var" || return 1
  done <<< "$git_local_vars"
  # Commit hooks also inherit identity outside Git's repository-local list.
  for git_local_var in "${!GIT_AUTHOR_@}" "${!GIT_COMMITTER_@}"; do
    unset "$git_local_var" || return 1
  done

  # Creates a scratch git repo in a temp dir, copies .claude/ from the
  # parent repo, cds into it. Stores the path in $REPO_DIR.
  REPO_DIR="$(mktemp -d)"
  export REPO_DIR
  cp -r "$BATS_TEST_DIRNAME/../.claude" "$REPO_DIR/"
  cp -r "$BATS_TEST_DIRNAME/../.codex" "$REPO_DIR/" 2>/dev/null || true
  cp -r "$BATS_TEST_DIRNAME/../.githooks" "$REPO_DIR/" 2>/dev/null || true
  cd "$REPO_DIR" || return 1
  git init -q
  git config user.email t@t
  git config user.name t
  # Tests must not inherit a developer's global ignore rules. In
  # particular, a global `memory/` entry makes progress.md impossible to
  # stage and hides the behavior these fixtures are meant to exercise.
  git config core.excludesFile /dev/null
}

write_progress() {
  local progress_status="$1" task="${2:-}" scope_globs="${3:-}" risk="${4:-}"
  mkdir -p memory
  {
    printf '# Progress\n\n## Current\n\nStatus: %s\n' "$progress_status"
    [ -z "$task" ] || printf 'Task: %s\n' "$task"
    [ -z "$risk" ] || printf 'Risk: %s\n' "$risk"
    if [ -n "$scope_globs" ]; then
      printf '\n## Scope\n\n'
      while IFS= read -r scope_glob; do
        [ -z "$scope_glob" ] || printf -- '- %s\n' "$scope_glob"
      done <<< "$scope_globs"
    fi
    printf '\n## Next\n\nNone\n\n## Blockers\n\nNone\n\n## Recently Completed\n\nNone\n'
  } > memory/progress.md
}

teardown_repo() {
  # shellcheck disable=SC2164
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$REPO_DIR"
}

# Run a hook with stdin JSON. $1 = hook name, $2 = JSON.
run_hook() {
  local hook="$1" input="$2"
  echo "$input" | bash ".claude/hooks/$hook"
}
