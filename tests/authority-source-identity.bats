#!/usr/bin/env bats
#
# The identity that a future receipt will carry has to be the Phase A source
# identity, because that is what a gate recomputes. The execution snapshot is
# not that: it is the final filesystem state the checks read, and it cannot
# express a staged change, a staged delete or an unstaged delete at all.
#
# So the authority produces the Phase A identity itself, from a vendored copy
# of the core's implementation. These tests are what keep the copy honest:
# for the same repository state the two must agree exactly, or both refuse.

setup() {
  CORE="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  VENDORED="$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh"
  export CORE VENDORED
  REPO="$(mktemp -d)"
  export REPO
  cd "$REPO"
  git init -q
  git config user.email t@t
  git config user.name t
  git config core.excludesFile /dev/null
}

teardown() {
  cd "$BATS_TEST_DIRNAME"
  rm -rf "$REPO"
}

core_manifest() { bash -c '. "$CORE"; verification_receipt_source_manifest_json "${1:-worktree}"' _ "${1:-worktree}"; }
authority_manifest() { bash -c '. "$VENDORED"; authority_pa_verification_receipt_source_manifest_json "${1:-worktree}"' _ "${1:-worktree}"; }

fingerprint() { jq -cS . | sha256sum | cut -d' ' -f1; }

# The whole contract in one place: identical identity, or both refuse.
assert_identity_parity() {
  local scope="${1:-worktree}" core auth core_fp auth_fp
  core=$(core_manifest "$scope")
  auth=$(authority_manifest "$scope")
  core_fp=$(printf '%s' "$core" | fingerprint)
  auth_fp=$(printf '%s' "$auth" | fingerprint)
  if [ "$core_fp" != "$auth_fp" ]; then
    printf 'identity differs for scope=%s\n--- core ---\n%s\n--- authority ---\n%s\n' \
      "$scope" "$(printf '%s' "$core" | jq -S .)" "$(printf '%s' "$auth" | jq -S .)" >&2
    return 1
  fi
  # Validity must agree too, so a fail-closed case fails closed on both sides.
  [ "$(printf '%s' "$core" | jq -r .valid)" = "$(printf '%s' "$auth" | jq -r .valid)" ]
}

seed() {
  printf 'v1\n' > tracked.txt
  git add -A
  git commit -qm seed
}

@test "1 clean tracked files" { seed; assert_identity_parity; }

@test "2 modified worktree" {
  seed
  printf 'changed\n' > tracked.txt
  assert_identity_parity
}

@test "3 staged modification" {
  seed
  printf 'staged\n' > tracked.txt
  git add tracked.txt
  assert_identity_parity
}

@test "4 staged and unstaged on the same path stay distinguishable" {
  seed
  printf 'staged\n' > tracked.txt
  git add tracked.txt
  printf 'unstaged\n' > tracked.txt
  assert_identity_parity
  # The two halves must genuinely differ; otherwise the case proves nothing.
  core_manifest | jq -e '
    .entries[] | select(.path == "tracked.txt")
    | .index.digest != .worktree.digest
  ' >/dev/null
}

@test "5 staged delete" {
  seed
  git rm -q --cached tracked.txt
  assert_identity_parity
  core_manifest | jq -e '
    .entries[] | select(.path == "tracked.txt")
    | .index.state == "absent" and .worktree.state == "present"
  ' >/dev/null
}

@test "6 unstaged delete" {
  seed
  rm tracked.txt
  assert_identity_parity
  core_manifest | jq -e '
    .entries[] | select(.path == "tracked.txt")
    | .index.state == "present" and .worktree.state == "absent"
  ' >/dev/null
}

@test "7 untracked but not ignored" {
  seed
  printf 'new\n' > untracked.txt
  assert_identity_parity
  core_manifest | jq -e '[.entries[].path] | index("untracked.txt") != null' >/dev/null
}

@test "8 ignored files stay out of the identity" {
  seed
  printf 'noise.log\n' > .gitignore
  printf 'noise\n' > noise.log
  git add .gitignore
  git commit -qm ignore
  assert_identity_parity
  core_manifest | jq -e '[.entries[].path] | index("noise.log") == null' >/dev/null
}

@test "9 executable bit" {
  seed
  chmod +x tracked.txt
  assert_identity_parity
  git add tracked.txt
  assert_identity_parity
}

@test "10 symlink target" {
  seed
  ln -s tracked.txt link.txt
  git add link.txt
  assert_identity_parity
  rm link.txt
  ln -s elsewhere.txt link.txt
  assert_identity_parity
}

@test "11 filenames with whitespace, tab and newline" {
  seed
  printf 'a\n' > 'with space.txt'
  printf 'b\n' > "$(printf 'with\ttab.txt')"
  printf 'c\n' > "$(printf 'with\nnewline.txt')"
  git add -A
  assert_identity_parity
}

@test "12 binary content with NUL bytes" {
  seed
  printf 'bin\000\001\377ary\000end' > blob.bin
  git add blob.bin
  assert_identity_parity
  printf 'bin\000changed\377' > blob.bin
  assert_identity_parity
}

@test "13 empty file" {
  seed
  : > empty.txt
  git add empty.txt
  assert_identity_parity
}

@test "14 structural exclusions are excluded on both sides" {
  seed
  mkdir -p .agent/verification memory
  printf '{"forged":true}\n' > .agent/verification/worktree.json
  printf 'progress\n' > memory/progress.md
  git add -f .agent/verification/worktree.json memory/progress.md
  assert_identity_parity
  core_manifest | jq -e '
    ([.entries[].path] | map(select(startswith(".agent/verification/") or . == "memory/progress.md")) | length) == 0
  ' >/dev/null
}

@test "15 an unmerged index fails closed on both sides" {
  seed
  git checkout -q -b other
  printf 'theirs\n' > tracked.txt
  git commit -qam theirs
  git checkout -q - 2>/dev/null || git checkout -q main 2>/dev/null || git checkout -q master
  printf 'ours\n' > tracked.txt
  git commit -qam ours
  run git merge other
  assert_identity_parity
  core_manifest | jq -e '.valid == false' >/dev/null
  authority_manifest | jq -e '.valid == false' >/dev/null
}

@test "16 a gitlink fails closed on both sides" {
  seed
  git update-index --add --cacheinfo 160000,"$(git rev-parse HEAD)",sub
  assert_identity_parity
  core_manifest | jq -e '.valid == false' >/dev/null
  authority_manifest | jq -e '.valid == false' >/dev/null
}

@test "17 the staged scope agrees as well" {
  seed
  printf 'staged\n' > tracked.txt
  git add tracked.txt
  printf 'unstaged\n' > tracked.txt
  assert_identity_parity staged
}

@test "18 the execution snapshot alone cannot express these states" {
  # The reason the authority computes the Phase A identity rather than
  # fingerprinting the snapshot it materialises.
  seed
  printf 'staged\n' > tracked.txt
  git add tracked.txt
  printf 'unstaged\n' > tracked.txt
  printf 'gone\n' > doomed.txt
  git add doomed.txt
  git commit -qm doomed
  rm doomed.txt

  local snap; snap=$(mktemp -d); rm -rf "$snap"
  bash -c '. "$1"
    paths=$(mktemp); authority_enumerate_paths "$PWD" > "$paths"
    authority_materialize_snapshot "$PWD" "$paths" "$2" >/dev/null
    authority_seal_snapshot "$2"
    authority_snapshot_manifest "$2"' \
    _ "$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh" "$snap" > "$snap.json"

  # The snapshot holds only the worktree side, and a deleted path is simply
  # absent from it, which is indistinguishable from never having existed.
  jq -e '[.[] | select(.path == "doomed.txt")] | length == 0' "$snap.json" >/dev/null
  jq -e 'any(.[]; .path == "tracked.txt")' "$snap.json" >/dev/null
  # Phase A keeps both distinctions.
  core_manifest | jq -e '
    (.entries[] | select(.path == "doomed.txt") | .index.state) == "present" and
    (.entries[] | select(.path == "tracked.txt") | .index.digest != .worktree.digest)
  ' >/dev/null
  chmod -R u+w "$snap" 2>/dev/null || true
  rm -rf "$snap" "$snap.json"
}

@test "19 global excludes cannot change source identity across developer and runner homes" {
  seed
  git config --unset core.excludesFile
  mkdir -p .agent-md "$REPO/runner-home"
  printf 'local source\n' > .agent-md/README.md
  printf '.agent-md/\n' > "$REPO/global-ignore"
  printf '[core]\n\texcludesFile = %s\n' "$REPO/global-ignore" > "$REPO/developer.gitconfig"

  local developer runner
  developer=$(GIT_CONFIG_GLOBAL="$REPO/developer.gitconfig" core_manifest)
  runner=$(HOME="$REPO/runner-home" GIT_CONFIG_GLOBAL=/dev/null authority_manifest)
  [ "$(printf '%s' "$developer" | fingerprint)" = "$(printf '%s' "$runner" | fingerprint)" ]
  printf '%s' "$developer" | jq -e 'any(.entries[]; .path == ".agent-md/README.md")' >/dev/null
}

@test "20 local info/exclude still excludes untracked host wiring" {
  seed
  git config --unset core.excludesFile
  mkdir -p .codex
  printf 'host config\n' > .codex/hooks.json
  printf '/.codex/hooks.json\n' >> .git/info/exclude
  printf '[core]\n\texcludesFile = %s\n' "$REPO/global-ignore" > "$REPO/developer.gitconfig"
  printf 'unrelated-global-only\n' > "$REPO/global-ignore"

  local developer runner
  developer=$(GIT_CONFIG_GLOBAL="$REPO/developer.gitconfig" core_manifest)
  runner=$(GIT_CONFIG_GLOBAL=/dev/null authority_manifest)
  [ "$(printf '%s' "$developer" | fingerprint)" = "$(printf '%s' "$runner" | fingerprint)" ]
  printf '%s' "$developer" | jq -e 'all(.entries[]; .path != ".codex/hooks.json")' >/dev/null
}

@test "21 a tracked path remains in the identity despite global exclusion" {
  seed
  git config --unset core.excludesFile
  mkdir -p .agent-md
  printf 'tracked source\n' > .agent-md/README.md
  git add -f .agent-md/README.md
  printf '.agent-md/\n' > "$REPO/global-ignore"
  printf '[core]\n\texcludesFile = %s\n' "$REPO/global-ignore" > "$REPO/developer.gitconfig"

  local developer runner
  developer=$(GIT_CONFIG_GLOBAL="$REPO/developer.gitconfig" core_manifest)
  runner=$(GIT_CONFIG_GLOBAL=/dev/null authority_manifest)
  [ "$(printf '%s' "$developer" | fingerprint)" = "$(printf '%s' "$runner" | fingerprint)" ]
  printf '%s' "$developer" | jq -e 'any(.entries[]; .path == ".agent-md/README.md" and .index.state == "present")' >/dev/null
}

@test "22 global autocrlf and attributes cannot change receipt identity" {
  seed
  printf 'worktree\r\n' > tracked.txt
  printf '*.txt text eol=crlf\n' > "$REPO/global-attributes"
  printf '[core]\n\tautocrlf = true\n\tattributesFile = %s\n' "$REPO/global-attributes" > "$REPO/developer.gitconfig"

  local developer runner
  developer=$(GIT_CONFIG_GLOBAL="$REPO/developer.gitconfig" core_manifest)
  runner=$(GIT_CONFIG_GLOBAL=/dev/null authority_manifest)
  [ "$(printf '%s' "$developer" | fingerprint)" = "$(printf '%s' "$runner" | fingerprint)" ]
  [ "$(printf '%s' "$developer" | jq -cS .)" = "$(printf '%s' "$runner" | jq -cS .)" ]
}
