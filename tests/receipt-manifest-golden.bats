#!/usr/bin/env bats
#
# Golden compatibility: the batched manifest implementation in _lib.sh must
# produce byte-identical output to the frozen pre-batching reference for the
# same repository state. This is the contract that lets the rewrite be a pure
# performance change.

load helpers

setup() {
  setup_repo
  REFERENCE="$BATS_TEST_DIRNAME/reference-manifest.bash"
  export REFERENCE
}

teardown() { teardown_repo; }

reference_manifest() {
  bash -c '. .claude/hooks/_lib.sh; . "$REFERENCE"; reference_receipt_source_manifest_json "$1"' _ "${1:-worktree}"
}

current_manifest() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_source_manifest_json "$1"' _ "${1:-worktree}"
}

fingerprint_of() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_json_fingerprint_json "$1"' _ "$1"
}

# Asserts identical canonical JSON and identical fingerprint for both scopes.
assert_equivalent() {
  local scope ref new ref_fp new_fp
  for scope in worktree staged; do
    ref=$(reference_manifest "$scope")
    new=$(current_manifest "$scope")
    if [ "$(printf '%s' "$ref" | jq -S .)" != "$(printf '%s' "$new" | jq -S .)" ]; then
      printf 'scope=%s manifests differ\n--- reference ---\n%s\n--- current ---\n%s\n' \
        "$scope" "$(printf '%s' "$ref" | jq -S .)" "$(printf '%s' "$new" | jq -S .)" >&2
      return 1
    fi
    ref_fp=$(fingerprint_of "$ref")
    new_fp=$(fingerprint_of "$new")
    [ "$ref_fp" = "$new_fp" ] || {
      printf 'scope=%s fingerprints differ: %s vs %s\n' "$scope" "$ref_fp" "$new_fp" >&2
      return 1
    }
  done
}

seed_commit() {
  printf 'alpha\n' > a.txt
  mkdir -p pkg
  printf 'beta\n' > pkg/b.txt
  git add -A
  git commit -qm seed
}

@test "1 clean tracked files" {
  seed_commit
  assert_equivalent
}

@test "2 modified worktree" {
  seed_commit
  printf 'changed\n' > a.txt
  assert_equivalent
}

@test "3 staged changes" {
  seed_commit
  printf 'staged\n' > a.txt
  git add a.txt
  assert_equivalent
}

@test "4 staged and unstaged on the same path" {
  seed_commit
  printf 'staged\n' > a.txt
  git add a.txt
  printf 'then-unstaged\n' > a.txt
  assert_equivalent
}

@test "5 untracked file" {
  seed_commit
  printf 'new\n' > untracked.txt
  assert_equivalent
}

@test "6 ignored file stays outside the manifest" {
  seed_commit
  printf 'ignored.log\n' > .gitignore
  printf 'noise\n' > ignored.log
  git add .gitignore
  git commit -qm ignore
  assert_equivalent
  current_manifest worktree | jq -e '[.entries[].path] | index("ignored.log") == null' >/dev/null
}

@test "7 delete in worktree and in index" {
  seed_commit
  rm a.txt
  assert_equivalent
  git rm -q --cached pkg/b.txt
  assert_equivalent
}

@test "8 executable bit change" {
  seed_commit
  chmod +x a.txt
  assert_equivalent
  git add a.txt
  assert_equivalent
}

@test "9 symlink target" {
  seed_commit
  ln -s a.txt link.txt
  git add link.txt
  assert_equivalent
  rm link.txt
  ln -s pkg/b.txt link.txt
  assert_equivalent
}

@test "10 filename with a space" {
  seed_commit
  printf 'spaced\n' > 'with space.txt'
  git add -- 'with space.txt'
  assert_equivalent
}

@test "11 filename with tab and newline" {
  seed_commit
  printf 'tabbed\n' > "$(printf 'with\ttab.txt')"
  printf 'newlined\n' > "$(printf 'with\nnewline.txt')"
  git add -A
  assert_equivalent
}

@test "12 empty file" {
  seed_commit
  : > empty.txt
  git add empty.txt
  assert_equivalent
}

@test "13 binary content with NUL bytes" {
  seed_commit
  printf 'bin\000\001\002\377ary\000end' > blob.bin
  git add blob.bin
  assert_equivalent
  printf 'bin\000changed\377' > blob.bin
  assert_equivalent
}

@test "14 duplicate path observations collapse" {
  seed_commit
  # a.txt is in both HEAD and the index, so the union enumerates it twice.
  current_manifest worktree | jq -e '[.entries[] | select(.path == "a.txt")] | length == 1' >/dev/null
  assert_equivalent
}

@test "15 unmerged index fails closed" {
  seed_commit
  git checkout -q -b other
  printf 'theirs\n' > a.txt
  git commit -qam theirs
  git checkout -q main 2>/dev/null || git checkout -q master
  printf 'ours\n' > a.txt
  git commit -qam ours
  run git merge other
  assert_equivalent
  current_manifest worktree | jq -e '.valid == false' >/dev/null
  current_manifest worktree | jq -e '
    any(.entries[]; .index.state == "conflicted" and .valid == false)
  ' >/dev/null
}

@test "16 gitlink fails closed" {
  seed_commit
  git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",sub
  assert_equivalent
  current_manifest worktree | jq -e '.valid == false' >/dev/null
  current_manifest worktree | jq -e '
    any(.entries[]; .index.error == "gitlinks are not supported by receipt protocol v1")
  ' >/dev/null
}

@test "17 unsupported filesystem entry fails closed" {
  # Git never lists a fifo under --others, so the path has to be tracked for
  # the worktree classifier to see a special entry at all.
  seed_commit
  printf 'regular\n' > special
  git add special
  git commit -qm special
  rm special
  mkfifo special
  assert_equivalent
  current_manifest worktree | jq -e '
    any(.entries[]; .path == "special" and .valid == false and
        .worktree.state == "unsupported")
  ' >/dev/null
}

@test "18 structural exclusions are never enumerated" {
  seed_commit
  mkdir -p .agent/verification memory
  printf '{"forged":true}\n' > .agent/verification/worktree.json
  printf 'progress\n' > memory/progress.md
  printf 'plan\n' > memory/plan.md
  git add -f .agent/verification/worktree.json memory/progress.md memory/plan.md
  assert_equivalent
  current_manifest worktree | jq -e '
    ([.entries[].path] | map(select(startswith(".agent/verification/") or . == "memory/progress.md" or . == "memory/plan.md")) | length) == 0
  ' >/dev/null
}

@test "19 scope and repository guards are unchanged" {
  seed_commit
  ref=$(reference_manifest bogus)
  new=$(current_manifest bogus)
  [ "$(printf '%s' "$ref" | jq -S .)" = "$(printf '%s' "$new" | jq -S .)" ]
  printf '%s' "$new" | jq -e '.valid == false and .error == "receipt scope must be worktree or staged"' >/dev/null
}

@test "20 empty repository without HEAD" {
  assert_equivalent
  current_manifest worktree | jq -e '.head == null' >/dev/null
}

@test "21 identity assembles for a large manifest on both branches" {
  # Component manifests are megabytes in a large repository. Passing them to jq
  # as command-line arguments used to exceed ARG_MAX, so identity failed with
  # no output instead of returning a structured result.
  seed_commit
  i=0
  mkdir -p bulk
  while [ "$i" -lt 900 ]; do
    printf 'bulk %s\n' "$i" > "bulk/f$i.txt"
    i=$((i + 1))
  done
  git add -A
  git commit -qm bulk

  # Invalid branch: no .agent-md tree, so the mechanism manifest is invalid.
  run bash -c '. .claude/hooks/_lib.sh; verification_receipt_identity_json worktree'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .valid == false and
    .error == "current verification identity is invalid" and
    (.components.source.entries | length) > 900 and
    (.components.mechanism.valid == false)
  ' >/dev/null

  # Valid branch.
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  run bash -c '. .claude/hooks/_lib.sh; verification_receipt_identity_json worktree'
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .valid == true and (.fingerprints.source.value | length) == 64
  ' >/dev/null
}
