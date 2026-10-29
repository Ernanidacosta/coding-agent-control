#!/usr/bin/env bats
#
# Activating .githooks must never silently replace a hooks path another tool
# (Husky, a team hook manager, a global hook directory) already configured.

setup() {
  TARGET_DIR="$(mktemp -d)"
  export TARGET_DIR
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null
  GLOBAL_CONFIG="$(mktemp)"
  export GIT_CONFIG_GLOBAL="$GLOBAL_CONFIG"
}

teardown() {
  rm -rf "$TARGET_DIR" "$GLOBAL_CONFIG"
}

install_with() {
  bash "$BATS_TEST_DIRNAME/../install.sh" --agent=cursor "$@" "$TARGET_DIR" </dev/null
}

local_config_snapshot() {
  git config --file "$TARGET_DIR/.git/config" --list | sort
}

@test "unset core.hooksPath is activated when explicitly requested" {
  run install_with --githooks
  [ "$status" -eq 0 ]
  [ "$(git -C "$TARGET_DIR" config --get core.hooksPath)" = .githooks ]
  [[ "$output" == *"active — core.hooksPath=.githooks"* ]]
}

@test "unset core.hooksPath stays unset without the explicit request" {
  run install_with
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TARGET_DIR" config --get core.hooksPath || true)" ]
}

@test "an existing .githooks value is idempotent" {
  git -C "$TARGET_DIR" config core.hooksPath .githooks
  before=$(local_config_snapshot)
  run install_with --githooks
  [ "$status" -eq 0 ]
  [ "$(local_config_snapshot)" = "$before" ]
  [[ "$output" == *"already active — core.hooksPath=.githooks"* ]]
}

@test "a different local core.hooksPath is refused and left byte-identical" {
  git -C "$TARGET_DIR" config core.hooksPath .husky/_
  before=$(cat "$TARGET_DIR/.git/config")
  run install_with --githooks
  [ "$status" -eq 0 ]
  [ "$(cat "$TARGET_DIR/.git/config")" = "$before" ]
  [ "$(git -C "$TARGET_DIR" config --get core.hooksPath)" = .husky/_ ]
  [[ "$output" == *"NOT activated"* ]]
  [[ "$output" == *"core.hooksPath is already set to '.husky/_'"* ]]
  [[ "$output" == *"git config was not changed"* ]]
  [[ "$output" == *".githooks/pre-commit"* ]]
  # The installed hooks remain available for manual chaining.
  [ -x "$TARGET_DIR/.githooks/pre-commit" ]
  [ -x "$TARGET_DIR/.githooks/commit-msg" ]
}

@test "a hooks path inherited from global config is a conflict too" {
  git config --file "$GLOBAL_CONFIG" core.hooksPath /opt/team-hooks
  before=$(cat "$TARGET_DIR/.git/config")
  run install_with --githooks
  [ "$status" -eq 0 ]
  [ "$(cat "$TARGET_DIR/.git/config")" = "$before" ]
  [ "$(git config --file "$GLOBAL_CONFIG" --get core.hooksPath)" = /opt/team-hooks ]
  [[ "$output" == *"core.hooksPath is already set to '/opt/team-hooks'"* ]]
  [[ "$output" == *"NOT activated"* ]]
}

@test "the conflict is reported without the explicit request too" {
  git -C "$TARGET_DIR" config core.hooksPath .husky/_
  run install_with
  [ "$status" -eq 0 ]
  [ "$(git -C "$TARGET_DIR" config --get core.hooksPath)" = .husky/_ ]
  [[ "$output" != *"enable with:   git config core.hooksPath .githooks"* ]]
  [[ "$output" == *"core.hooksPath is already set to '.husky/_'"* ]]
}

@test "dry-run never changes git config and states what it would do" {
  run install_with --githooks --dry-run
  [ "$status" -eq 0 ]
  [ -z "$(git -C "$TARGET_DIR" config --get core.hooksPath || true)" ]
  [[ "$output" == *"would activate  .githooks/"* ]]

  git -C "$TARGET_DIR" config core.hooksPath .husky/_
  before=$(cat "$TARGET_DIR/.git/config")
  run install_with --githooks --dry-run
  [ "$status" -eq 0 ]
  [ "$(cat "$TARGET_DIR/.git/config")" = "$before" ]
  [[ "$output" == *"core.hooksPath is already set to '.husky/_'"* ]]
  [[ "$output" == *"NOT activated"* ]]
}
