#!/usr/bin/env bats
#
# The pre-commit gate runs its checks in the worktree. Their results describe
# the commit only when the worktree is a checkout of the staged snapshot, so
# the gate establishes that correspondence against the effective index first
# and refuses explicitly when it cannot. It never stashes, stages or rewrites
# files, and it rereads the snapshot before deciding.

load helpers

setup() {
  setup_repo
  RUNS="$BATS_TEST_TMPDIR/runs"
  MUTATE="$BATS_TEST_TMPDIR/mutate"
  RESTAGE="$BATS_TEST_TMPDIR/restage"
  : > "$RUNS"
  cat > agent-md.toml <<TOML
[verify]
test = 'printf x >> "$RUNS"; if [ -f "$MUTATE" ]; then echo changed >> README.md; fi; if [ -f "$RESTAGE" ]; then echo s > src/restaged.sh; git add src/restaged.sh; fi; grep -qx VALID README.md'

[verify.policy]
required = ["test"]

[state]
source_globs = ["src/**", "README.md"]
ignore_globs = ["memory/**"]
TOML
  printf 'schema = 1\nrisk = "low"\n' > .project-control.toml
  mkdir -p src
  echo 'echo a' > src/a.sh
  echo VALID > README.md
  bump_progress
  git add -A
  git commit -q -m baseline
  git config core.hooksPath .githooks
}

teardown() { teardown_repo; }

bump_progress() {
  write_progress active "Edit the document $((++PROGRESS_N))"
  [ ! -d .git ] || git add -f memory/progress.md
}

runs() { wc -c < "$RUNS" | tr -d ' '; }

# snapshot — HEAD, index tree, worktree status and bytes, stash count.
snapshot() {
  printf '%s %s %s\n' "$(git rev-parse -q --verify HEAD || echo none)" "$(git write-tree)" \
    "$(git stash list | wc -l)"
  git status --porcelain=v1 --untracked-files=all
  git ls-files -co --exclude-standard -z | xargs -0 sha256sum 2>/dev/null
}

commit() { run git commit -m change "$@"; }

refused_for() {
  [ "$status" -ne 0 ] || { echo "commit was accepted" >&2; return 1; }
  [[ "$output" == *"[ERROR $1]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" != *VERIFY_REQUIRED_FAILED* ]]
}

@test "A: an equivalent valid snapshot runs the checks and commits" {
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  before=$(git rev-parse HEAD)
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(runs)" -eq 1 ]
  [ "$(git rev-parse HEAD^)" = "$before" ]
}

@test "B: an invalid staged document is refused when the worktree diverges" {
  printf 'INVALID\n' > README.md
  bump_progress
  git add README.md
  echo VALID > README.md
  before=$(snapshot)
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *README.md* ]]
  [ "$(runs)" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
  [ "$(git show :README.md)" = INVALID ]
}

@test "C: a valid staged document is refused for divergence, not for the worktree's content" {
  printf '# doc\nVALID\n' > README.md
  bump_progress
  git add README.md
  printf '# doc\nINVALID\n' > README.md
  before=$(snapshot)
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [ "$(runs)" -eq 0 ]
  [ "$(snapshot)" = "$before" ]
}

@test "D: an invalid snapshot equal to the worktree is blocked by the checks" {
  printf 'INVALID\n' > README.md
  bump_progress
  git add README.md
  before=$(git rev-parse HEAD)
  commit
  [ "$status" -ne 0 ]
  [[ "$output" == *VERIFY_REQUIRED_FAILED* ]]
  [[ "$output" != *PRECOMMIT_SNAPSHOT* ]]
  [ "$(runs)" -eq 1 ]
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "additions, deletions and renames must be staged as they appear in the worktree" {
  echo 'echo new' > src/new.sh
  bump_progress
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *src/new.sh* ]]
  git add src/new.sh
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  mv src/new.sh src/moved.sh
  bump_progress
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  git add -A src
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  # A staged deletion whose file is still in the worktree diverges.
  git rm -q --cached src/moved.sh
  bump_progress
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *src/moved.sh* ]]
  # A worktree-only deletion diverges; a staged one does not.
  git reset -q src/moved.sh
  mv src/a.sh "$BATS_TEST_TMPDIR/a.sh"
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *src/a.sh* ]]
  git rm -q --cached src/a.sh
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "an unstaged mode change diverges" {
  chmod +x src/a.sh
  echo 'echo m' >> README.md
  bump_progress
  git add README.md
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *src/a.sh* ]]
}

@test "only the five local working-state files may differ from the staged snapshot" {
  echo note > memory/notes.md
  printf '# Plan\n\nlocal\n' > memory/plan.md
  bump_progress
  git add -f memory/notes.md memory/plan.md
  git commit -q -m 'track memory files'
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  write_progress active "Locally refined, not staged"
  printf '# Plan\n\nrefined locally\n' > memory/plan.md
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }

  echo 'echo c' > src/a.sh
  bump_progress
  git add src/a.sh
  echo edited >> memory/notes.md
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *memory/notes.md* ]]
}

@test "an untracked file outside the declared sources is reported, not refused" {
  echo scratch > notes.txt
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"[WARNING PRECOMMIT_SNAPSHOT_UNTRACKED]"* ]]
  [[ "$output" == *notes.txt* ]]
}

@test "unstaged or untracked policy and control files diverge" {
  printf '\n# reviewed later\n' >> agent-md.toml
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *agent-md.toml* ]]
  git checkout -q -- agent-md.toml
  git rm -q --cached .project-control.toml
  commit
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *.project-control.toml* ]]
}

@test "the effective index decides: a partial commit diverges and commit -a does not" {
  echo 'echo b' > src/a.sh
  echo VALID > README.md
  echo 'more' >> README.md
  bump_progress
  run git commit -m partial -o src/a.sh memory/progress.md
  refused_for PRECOMMIT_SNAPSHOT_DIVERGENT
  [[ "$output" == *README.md* ]]
  run git commit -a -m all
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [ "$(runs)" -eq 1 ]
}

@test "a declared checkout conversion is equivalent, not divergent" {
  printf '*.txt text eol=crlf\n' > .gitattributes
  printf 'one\ntwo\n' > data.txt
  bump_progress
  git add .gitattributes data.txt
  git commit -q -m attrs
  rm data.txt
  git checkout -q -- data.txt
  grep -q $'\r' data.txt
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  commit
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

@test "a worktree change during the checks is refused before the decision" {
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  touch "$MUTATE"
  before=$(git rev-parse HEAD)
  commit
  refused_for PRECOMMIT_SNAPSHOT_CHANGED
  [[ "$output" == *README.md* ]]
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "an index change during the checks is refused before the decision" {
  echo 'echo b' > src/a.sh
  bump_progress
  git add src/a.sh
  touch "$RESTAGE"
  before=$(git rev-parse HEAD)
  commit
  refused_for PRECOMMIT_SNAPSHOT_CHANGED
  [ "$(git rev-parse HEAD)" = "$before" ]
}

@test "the first commit of a repository is checked the same way" {
  fresh="$BATS_TEST_TMPDIR/fresh"
  mkdir -p "$fresh"
  cp -r .claude .githooks agent-md.toml .project-control.toml README.md src "$fresh/"
  cd "$fresh"
  git init -q
  git config user.email t@t
  git config user.name t
  git config core.excludesFile /dev/null
  git config core.hooksPath .githooks
  bump_progress
  git add -A
  run git commit -m first
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}
