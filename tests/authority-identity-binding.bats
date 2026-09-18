#!/usr/bin/env bats
#
# The identity a future receipt will carry has to describe the tree the checks
# actually read. These tests pin that binding: the bound identity equals what
# the core computes, the sealed tree matches it entry by entry, and a workspace
# that moves during capture refuses instead of producing a run whose identity
# and snapshot disagree.

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  CORE="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  TOOLCHAIN="$(mktemp -d)"
  export AUTHORITY ISSUER LIB CORE ROOT WS TOOLCHAIN
  EXEC_PATH="$(trusted_toolchain_path "$TOOLCHAIN")"
  export EXEC_PATH

  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  # A runner has no global identity and no reason to inherit the host's ignore
  # rules, so the fixture states both rather than depending on the machine.
  git -C "$WS" config user.email fixture@example.invalid
  git -C "$WS" config user.name fixture
  git -C "$WS" config core.excludesFile /dev/null
  printf 'ORIGINAL\n' > "$WS/marker.txt"
  local hook
  for hook in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\n' > "$WS/$hook"
  done
  cat > "$WS/agent-md.toml" <<'TOML'
[verify]
lint = "cat marker.txt"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20
TOML
  git -C "$WS" add -A >/dev/null 2>&1
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PROJECT_ID
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

project_dir() { printf '%s/var/lib/agent-md/projects/%s' "$ROOT" "$PROJECT_ID"; }
run_dir() { printf '%s/runs/%s' "$(project_dir)" "$(cat "$(project_dir)/current-run")"; }
core_fingerprint() {
  bash -c 'cd "$1"; . "$2"; verification_receipt_source_manifest_json worktree | jq -cS . | sha256sum | cut -d" " -f1' \
    _ "$WS" "$CORE"
}
bound_fingerprint() { jq -cS . "$(run_dir)/source-identity.json" | sha256sum | cut -d' ' -f1; }

@test "1 the bound identity is the identity the core computes" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(bound_fingerprint)" = "$(core_fingerprint)" ]
}

@test "2 the bound identity keeps both halves the snapshot cannot hold" {
  printf 'STAGED\n' > "$WS/marker.txt"
  git -C "$WS" add marker.txt
  printf 'UNSTAGED\n' > "$WS/marker.txt"
  printf 'doomed\n' > "$WS/doomed.txt"
  git -C "$WS" add doomed.txt
  git -C "$WS" commit -qm doomed
  rm "$WS/doomed.txt"

  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(bound_fingerprint)" = "$(core_fingerprint)" ]

  # Staged and unstaged stay distinct in the identity.
  jq -e '.entries[] | select(.path == "marker.txt")
    | .index.digest != .worktree.digest' "$(run_dir)/source-identity.json" >/dev/null
  # An unstaged delete is visible as index-present, worktree-absent.
  jq -e '.entries[] | select(.path == "doomed.txt")
    | .index.state == "present" and .worktree.state == "absent"' "$(run_dir)/source-identity.json" >/dev/null
  # The executed tree holds the unstaged content and not the deleted path.
  [ "$(cat "$(run_dir)/snapshot/src/marker.txt")" = UNSTAGED ]
  [ ! -e "$(run_dir)/snapshot/src/doomed.txt" ]
}

@test "3 the sealed tree matches the bound identity entry by entry" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  run bash -c '. "$1"; . "$2"; authority_snapshot_matches_identity "$3" "$4"' \
    _ "$LIB" "$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh" \
    "$(run_dir)/source-identity.json" "$(run_dir)/snapshot/src"
  [ "$status" -eq 0 ]
}

@test "4 a sealed tree that does not match the identity is refused" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  # Tamper the sealed tree the way a successful race would have left it.
  chmod -R u+w "$(run_dir)/snapshot/src"
  printf 'SUBSTITUTED\n' > "$(run_dir)/snapshot/src/marker.txt"
  run bash -c '. "$1"; . "$2"; authority_snapshot_matches_identity "$3" "$4"' \
    _ "$LIB" "$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh" \
    "$(run_dir)/source-identity.json" "$(run_dir)/snapshot/src"
  [ "$status" -ne 0 ]
  [[ "$output" == *"does not match the source identity"* ]]
}

@test "5 a workspace that moves during capture never yields an inconsistent run" {
  # Enough files that the capture takes measurable time, and a mutator running
  # throughout it. Whatever happens, the two must never disagree.
  local i
  for i in $(seq 1 300); do printf 'content %s\n' "$i" > "$WS/bulk$i.txt"; done
  git -C "$WS" add -A >/dev/null 2>&1

  ( for i in $(seq 1 60); do printf 'MUTATED %s\n' "$i" > "$WS/marker.txt"; sleep 0.05; done ) &
  local mutator=$!
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  local prepared="$status"
  wait "$mutator" 2>/dev/null || true

  if [ "$prepared" -eq 0 ]; then
    # It succeeded, so the sealed tree must be exactly what the identity says.
    run bash -c '. "$1"; . "$2"; authority_snapshot_matches_identity "$3" "$4"' \
      _ "$LIB" "$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh" \
      "$(run_dir)/source-identity.json" "$(run_dir)/snapshot/src"
    [ "$status" -eq 0 ]
  else
    # It refused, which is the other acceptable outcome. It must not have left
    # a usable run behind.
    [ ! -e "$(project_dir)/current-run" ] || [ ! -d "$(run_dir)/snapshot/src" ]
  fi
}

@test "6 every check of a run shares one snapshot and one bound identity" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  local lint test_job
  lint=$(jq -r '.snapshot' "$(run_dir)/jobs/lint.json")
  test_job=$(jq -r '.snapshot' "$(run_dir)/jobs/test.json")
  [ "$lint" = "$test_job" ]
  [ "$lint" = "$(run_dir)/snapshot/src" ]
  [ "$(jq -r .run_id "$(run_dir)/jobs/lint.json")" = "$(jq -r .run_id "$(run_dir)/jobs/test.json")" ]
  # One identity file for the run, not one per check.
  [ "$(find "$(run_dir)" -maxdepth 1 -name 'source-identity.json' | wc -l)" -eq 1 ]
}

@test "7 the evaluation reports the bound identity, and it is the core's" {
  run --separate-stderr bash -c \
    'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "candidate_pass"' >/dev/null
  [ "$(printf '%s' "$output" | jq -r '.source.phase_a.value')" = "$(core_fingerprint)" ]
  # The snapshot identity is reported too, and is a different thing.
  printf '%s' "$output" | jq -e '.source.snapshot.value != .source.phase_a.value' >/dev/null
}

# --- current-run is scratch, not evidence -----------------------------------

@test "8 a run carries no authority of its own" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  # Nothing in a run is signed, sequenced or presented as proof.
  ! jq -e 'has("signature") or has("sequence") or has("authentic")' "$(run_dir)/source-identity.json" >/dev/null
  ! grep -qE 'signature|authentic|attested|receipt' "$(run_dir)/jobs/lint.json"
}

@test "9 re-presenting an old run does not make it current" {
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  local old_run old_identity
  old_run=$(cat "$(project_dir)/current-run")
  old_identity=$(mktemp)
  cp "$(run_dir)/source-identity.json" "$old_identity"

  # A second run supersedes it and the old directory is released.
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [ "$(cat "$(project_dir)/current-run")" != "$old_run" ]
  [ ! -d "$(project_dir)/runs/$old_run" ]

  # Putting the old identity back where a run would live grants nothing: the
  # pointer is authority-owned and still names the newer run.
  mkdir -p "$(project_dir)/runs/$old_run"
  cp "$old_identity" "$(project_dir)/runs/$old_run/source-identity.json"
  [ "$(cat "$(project_dir)/current-run")" != "$old_run" ]
  rm -f "$old_identity"
}

@test "10 no component accepts a run summary as input" {
  # A future signing step must be a continuation of an eligible evaluation, not
  # an operation that signs whatever summary it finds.
  ! grep -qE 'summary|source-identity\.json' "$ISSUER" || \
    grep -qE 'identity_file="\$run_dir/source-identity.json"' "$ISSUER"
  ! grep -qE '(--summary|--receipt|--sign)' "$ISSUER" "$AUTHORITY"
}
