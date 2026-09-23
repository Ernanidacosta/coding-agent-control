#!/usr/bin/env bats

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  CORE="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  export AUTHORITY LIB CORE
  FIXTURE=$(mktemp -d)
  ROOT="$FIXTURE/root"
  WS="$FIXTURE/workspace"
  export FIXTURE ROOT WS
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin" "$FIXTURE/tmp"
  export TMPDIR="$FIXTURE/tmp"
  git -C "$WS" init -q
  git -C "$WS" config core.excludesFile /dev/null
  printf '#!/bin/bash\n' | tee "$WS/.claude/hooks/_lib.sh" \
    "$WS/.claude/hooks/stop-verify.sh" > "$WS/.agent-md/bin/verify.sh"
  printf '[verify]\ntest = "true"\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 20\n' > "$WS/agent-md.toml"
  printf 'schema = 1\nrisk = "low"\n' > "$WS/.project-control.toml"
  git -C "$WS" add -A
  mkdir "$FIXTURE/toolchain"
  local exec_path
  exec_path=$(trusted_toolchain_path "$FIXTURE/toolchain")
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$exec_path" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects")
  export PROJECT_ID
}

teardown() {
  chmod -R u+w "$FIXTURE"
  rm -rf "$FIXTURE"
}

@test "large workspace identity exceeds argv and preserves all core manifests and fingerprints" {
  local suffix i
  printf -v suffix '%0200d' 0
  mkdir "$WS/bulk"
  for ((i=0; i<400; i++)); do
    printf 'same content\n' > "$WS/bulk/$i-$suffix.txt"
  done
  git -C "$WS" add bulk
  bash -c '
    cd "$WS" || exit 1
    . "$CORE"
    verification_receipt_source_manifest_json worktree > "$FIXTURE/source.json"
    effective_verification_contract_json worktree > "$FIXTURE/contract.json"
    effective_control_requirements_json worktree > "$FIXTURE/control.json"
    verification_receipt_mechanism_manifest_json worktree > "$FIXTURE/mechanism.json"
  '
  local size
  size=$(wc -c < "$FIXTURE/source.json")
  printf 'source manifest: %s bytes; ARG_MAX: %s; page size: %s\n' \
    "$size" "$(getconf ARG_MAX)" "$(getconf PAGESIZE)" >&3
  [ "$size" -gt 131072 ]
  # Exercise the old exec boundary, not merely a size estimate.
  run bash -c 'jq -nc --argjson source "$(cat "$FIXTURE/source.json")" "$1"' _ '{source:$source}'
  [ "$status" -ne 0 ]
  [[ "$output" == *"Argument list too long"* ]]

  run bash -c '
    fixture_root=$ROOT
    set -- --help
    . "$AUTHORITY" >/dev/null
    ROOT=$fixture_root
    cmd_identity "$PROJECT_ID" > "$FIXTURE/identity.json"
  ' "$AUTHORITY"
  [ "$status" -eq 0 ]
  jq -nc --slurpfile source "$FIXTURE/source.json" --slurpfile contract "$FIXTURE/contract.json" \
    --slurpfile control "$FIXTURE/control.json" --slurpfile mechanism "$FIXTURE/mechanism.json" \
    '{source:$source[0],contract:$contract[0],control:$control[0],mechanism:$mechanism[0]}' \
    > "$FIXTURE/expected.json"
  cmp "$FIXTURE/expected.json" "$FIXTURE/identity.json"
  bash -c '
    . "$LIB"
    authority_identity_fingerprints "$FIXTURE/expected.json" > "$FIXTURE/expected-fp.json"
    authority_identity_fingerprints "$FIXTURE/identity.json" > "$FIXTURE/actual-fp.json"
  '
  cmp "$FIXTURE/expected-fp.json" "$FIXTURE/actual-fp.json"
  [ -z "$(ls -A "$TMPDIR")" ]

  # Staging capture and persistence must not reintroduce the same exec limit.
  run bash "$AUTHORITY" prepare-run "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  local project="$ROOT/var/lib/agent-md/projects/$PROJECT_ID" run_id
  run_id=$(cat "$project/current-run")
  jq -c '.manifests' "$project/runs/$run_id/identity.json" > "$FIXTURE/bound.json"
  cmp "$FIXTURE/expected.json" "$FIXTURE/bound.json"
  jq -c '.fingerprints' "$project/runs/$run_id/identity.json" > "$FIXTURE/bound-fp.json"
  cmp "$FIXTURE/expected-fp.json" "$FIXTURE/bound-fp.json"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "identity fails closed and cleans up when any producer fails or emits invalid JSON" {
  local part mode
  for part in source contract control mechanism; do
    for mode in fail invalid empty multiple; do
      run bash -c '
        fixture_root=$ROOT
        part=$1 mode=$2
        set -- --help
        . "$AUTHORITY" >/dev/null
        ROOT=$fixture_root
        emit_manifest() {
          if [ "$1" != "$part" ]; then printf "{\"valid\":true}"; return; fi
          case "$mode" in
            fail) printf "{\"valid\":true}"; return 7 ;;
            invalid) printf "{broken" ;;
            empty) : ;;
            multiple) printf "{} {}" ;;
          esac
        }
        authority_pa_verification_receipt_source_manifest_json() { emit_manifest source; }
        authority_pa_effective_verification_contract_json() { emit_manifest contract; }
        authority_pa_effective_control_requirements_json() { emit_manifest control; }
        authority_pa_verification_receipt_mechanism_manifest_json() { emit_manifest mechanism; }
        cmd_identity "$PROJECT_ID" > "$FIXTURE/failed.json"
      ' "$AUTHORITY" "$part" "$mode"
      [ "$status" -ne 0 ]
      [ ! -s "$FIXTURE/failed.json" ]
      [ -z "$(ls -A "$TMPDIR")" ]
    done
  done
}

@test "identity uses private temporary files and preserves caller TMPDIR umask and traps" {
  run bash -c '
    . "$LIB"
    umask 022
    trap ": caller trap" EXIT
    before=$(trap -p EXIT)
    original_tmp=$TMPDIR
    authority_pa_verification_receipt_source_manifest_json() {
      [ "$(dirname "$TMPDIR")" = "$original_tmp" ] || return 1
      [ "$(stat -c %a "$TMPDIR")" = 700 ] || return 1
      [ "$(stat -c %a "$TMPDIR/source.json")" = 600 ] || return 1
      printf "{\"valid\":false,\"error\":\"unsupported entry\"}"
    }
    authority_pa_effective_verification_contract_json() { printf "{\"valid\":true}"; }
    authority_pa_effective_control_requirements_json() { printf "{\"valid\":true}"; }
    authority_pa_verification_receipt_mechanism_manifest_json() { printf "{\"valid\":true}"; }
    authority_workspace_identity_json worktree > "$FIXTURE/private.json" || exit 1
    [ "$(umask)" = 0022 ] && [ "$TMPDIR" = "$original_tmp" ] && [ "$(trap -p EXIT)" = "$before" ]
  '
  [ "$status" -eq 0 ]
  jq -e '.source == {valid:false,error:"unsupported entry"}' "$FIXTURE/private.json"
  [ -z "$(ls -A "$TMPDIR")" ]
}

@test "identity creation failure and interruption emit nothing and remove temporary files" {
  local mode
  for mode in mkdir write signal; do
    run bash -c '
      . "$LIB"
      case "$1" in
        mkdir) mktemp() { return 1; } ;;
        write) mktemp() { local d; d=$(command mktemp "$@") || return 1; mkdir "$d/source.json"; printf "%s" "$d"; } ;;
      esac
      authority_pa_verification_receipt_source_manifest_json() { kill -TERM "$BASHPID"; }
      authority_workspace_identity_json > "$FIXTURE/interrupted.json"
    ' _ "$mode"
    [ "$status" -ne 0 ]
    [ ! -s "$FIXTURE/interrupted.json" ]
    [ -z "$(ls -A "$TMPDIR")" ]
  done
}
