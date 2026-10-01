#!/usr/bin/env bats

load authority-helpers
bats_require_minimum_version 1.5.0

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  VERIFY="$BATS_TEST_DIRNAME/../examples/local-issuer/receipt-verify.sh"
  ROOT=$(mktemp -d)
  WS=$(mktemp -d)
  TOOLCHAIN=$(mktemp -d)
  export AUTHORITY ISSUER VERIFY ROOT WS TOOLCHAIN
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  for path in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\n' > "$WS/$path"
  done
  printf '[verify]\ntest = "true"\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 20\n' > "$WS/agent-md.toml"
  local exec_path
  exec_path=$(trusted_toolchain_path "$TOOLCHAIN")
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$exec_path" --yes >/dev/null
  local project_id
  project_id=$(jq -r .project_id "$ROOT"/var/lib/agent-md/projects/*/enrollment.json)
  RESEAL_PROJECT="$ROOT/var/lib/agent-md/projects/$project_id"
  RESEAL_KEY=$(cat "$ROOT/var/lib/agent-md/keys/current")
  export RESEAL_PROJECT RESEAL_KEY
  chmod 0555 "$RESEAL_PROJECT"
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN"
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

evaluate_with_reseal_failure() {
  RESEAL_PHASE="$1"
  export RESEAL_PHASE
  run --separate-stderr bash -c '
    fixture_root=$ROOT
    set -- --help
    . "$0" >/dev/null
    ROOT=$fixture_root
    chmod() {
      local fail=no
      if [ "$#" -eq 2 ] && [ "$1" = 555 ] && [ "$2" = "$RESEAL_PROJECT" ]; then
        case "$RESEAL_PHASE" in
          reservation) fail=yes ;;
          key) [ ! -f "$RESEAL_PROJECT/trusted-keys/$RESEAL_KEY.pub" ] || fail=yes ;;
          receipt) [ ! -f "$RESEAL_PROJECT/receipts/worktree/1.json" ] || fail=yes ;;
          terminal)
            if jq -e ".scopes.worktree.last_terminal != null" "$RESEAL_PROJECT/state.json" >/dev/null; then
              fail=yes
            fi ;;
        esac
      fi
      if [ "$fail" = yes ]; then
        printf "%s\n" "$RESEAL_PHASE" >> "$ROOT/reseal-failed"
        return 73
      fi
      command chmod "$@"
    }
    printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$WS" > "$ROOT/request.json"
    cmd_evaluate --root "$ROOT" < "$ROOT/request.json"
  ' "$ISSUER"
  [ -s "$ROOT/reseal-failed" ]
}

assert_not_reusable() {
  [ -w "$RESEAL_PROJECT" ]
  # Model separate ownership of the files without repairing the failed directory reseal.
  chmod 0444 "$RESEAL_PROJECT/enrollment.json" "$RESEAL_PROJECT/state.json"
  run --separate-stderr bash "$VERIFY" "$WS" worktree --root "$ROOT"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.status == "unavailable" and .applicable != true
    and (.reason | contains("directory this user can write"))' >/dev/null
}

@test "successful reseal permits a current authenticated receipt to be reused" {
  run bash -c '
    printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$WS" |
      bash "$ISSUER" evaluate --root "$ROOT"
  '
  [ "$status" -eq 0 ]
  [ "$(stat -c %a "$RESEAL_PROJECT")" = 555 ]
  chmod 0444 "$RESEAL_PROJECT/enrollment.json" "$RESEAL_PROJECT/state.json"
  run --separate-stderr bash "$VERIFY" "$WS" worktree --root "$ROOT"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "reusable_ordinary" and .authentic == true and .applicable == true' >/dev/null
}

@test "reseal failure during reservation refuses without publishing a terminal or receipt" {
  evaluate_with_reseal_failure reservation
  [ "$status" -eq 19 ]
  printf '%s' "$output" | jq -e '.status == "refused" and .reason_code == "REFUSED_STATE_UNUSABLE" and .receipt == null' >/dev/null
  [[ "$output" == *'cannot reseal the state directory'* ]]
  jq -e '.scopes.worktree.last_terminal == null' "$RESEAL_PROJECT/state.json" >/dev/null
  [ ! -e "$RESEAL_PROJECT/receipts/worktree/1.json" ]
  assert_not_reusable
}

@test "reseal failure after trusted key publication refuses before receipt or terminal publication" {
  evaluate_with_reseal_failure key
  [ "$status" -eq 21 ]
  printf '%s' "$output" | jq -e '.status == "refused" and .reason_code == "REFUSED_SIGNING_UNAVAILABLE" and .receipt == null' >/dev/null
  [ -f "$RESEAL_PROJECT/trusted-keys/$RESEAL_KEY.pub" ]
  [ ! -e "$RESEAL_PROJECT/receipts/worktree/1.json" ]
  jq -e '.scopes.worktree.last_terminal == null' "$RESEAL_PROJECT/state.json" >/dev/null
  assert_not_reusable
}

@test "reseal failure after receipt rename leaves an orphan rather than a published terminal" {
  evaluate_with_reseal_failure receipt
  [ "$status" -eq 21 ]
  printf '%s' "$output" | jq -e '.status == "refused" and .reason_code == "REFUSED_SIGNING_UNAVAILABLE" and .receipt == null' >/dev/null
  [[ "$output" == *'cannot reseal the receipt parent'* ]]
  [ -f "$RESEAL_PROJECT/receipts/worktree/1.json" ]
  jq -e '.scopes.worktree.last_terminal == null' "$RESEAL_PROJECT/state.json" >/dev/null
  assert_not_reusable
}

@test "reseal failure after terminal rename refuses and leaves authority state unsafe for reuse" {
  evaluate_with_reseal_failure terminal
  [ "$status" -eq 19 ]
  printf '%s' "$output" | jq -e '.status == "refused" and .reason_code == "REFUSED_STATE_UNUSABLE"' >/dev/null
  [[ "$output" == *'cannot reseal the state directory'* ]]
  jq -e '.scopes.worktree.last_terminal.status == "candidate_pass"' "$RESEAL_PROJECT/state.json" >/dev/null
  [ -f "$RESEAL_PROJECT/receipts/worktree/1.json" ]
  assert_not_reusable
}
