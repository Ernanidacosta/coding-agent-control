#!/usr/bin/env bats
#
# A global, repository or local ignore rule can hide the policy, the control
# record or the installed tooling from Git. The installer and doctor say so,
# name the rule and its scope, and never change ignore rules themselves.

setup() {
  TARGET_DIR="$(mktemp -d)"
  export TARGET_DIR
  HOST_DIR="$(mktemp -d)"
  export HOST_DIR
  : > "$HOST_DIR/global-ignore"
  printf '[core]\n\texcludesFile = %s\n[user]\n\temail = t@t\n\tname = t\n' \
    "$HOST_DIR/global-ignore" > "$HOST_DIR/gitconfig"
  export GIT_CONFIG_GLOBAL="$HOST_DIR/gitconfig"
  git -C "$TARGET_DIR" init -q
}

teardown() {
  rm -rf "$TARGET_DIR" "$HOST_DIR"
}

install_agent_md() {
  bash "$BATS_TEST_DIRNAME/../install.sh" --no-githooks "$@" "$TARGET_DIR" </dev/null
}

doctor() {
  (cd "$TARGET_DIR" && bash .agent-md/bin/doctor.sh)
}

ignore_snapshot() {
  cat "$HOST_DIR/global-ignore" "$TARGET_DIR/.git/info/exclude" 2>/dev/null
  cat "$TARGET_DIR/.gitignore" 2>/dev/null || true
}

@test "installer reports critical files hidden by a global ignore and leaves the rule alone" {
  printf '.claude/\n.agent-md/\nagent-md.toml\nAGENT.md\nCLAUDE.md\n' > "$HOST_DIR/global-ignore"
  before=$(cat "$HOST_DIR/global-ignore")
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [ "$(cat "$HOST_DIR/global-ignore")" = "$before" ]
  [[ "$output" == *"ignored by Git    agent-md.toml (global/host ignore: $HOST_DIR/global-ignore:3: agent-md.toml)"* ]]
  [[ "$output" == *"ignored by Git    AGENT.md (global/host ignore:"* ]]
  [[ "$output" == *"ignored by Git    .claude/hooks/_lib.sh (global/host ignore: $HOST_DIR/global-ignore:1: .claude/)"* ]]
  [[ "$output" == *"ignored by Git    .agent-md/bin/verify.sh (global/host ignore:"* ]]
  [[ "$output" == *"Ignore rules were not changed"* ]]
  [[ "$output" == *"git add -f "*" agent-md.toml"* ]]
  [[ "$output" != *"ignored by Git    .project-control.toml"* ]]
}

@test "installer distinguishes a repository .gitignore from a local exclude" {
  printf 'agent-md.toml\n' > "$TARGET_DIR/.gitignore"
  printf '.project-control.toml\n' >> "$TARGET_DIR/.git/info/exclude"
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored by Git    agent-md.toml (repository .gitignore: .gitignore:1: agent-md.toml)"* ]]
  [[ "$output" == *"ignored by Git    .project-control.toml (repository-local exclude, this clone only: .git/info/exclude:"* ]]
}

@test "installer stays quiet when nothing critical is ignored" {
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignored by Git"* ]]
}

@test "a negated rule that re-includes a file is not reported" {
  printf '*.toml\n!agent-md.toml\n' > "$HOST_DIR/global-ignore"
  run install_agent_md --agent=claude
  [ "$status" -eq 0 ]
  [[ "$output" != *"ignored by Git    agent-md.toml"* ]]
  [[ "$output" == *"ignored by Git    .project-control.toml"* ]]
}

@test "dry-run reports ignored critical files without changing anything" {
  printf 'agent-md.toml\n.githooks/\n' > "$HOST_DIR/global-ignore"
  before_ignores=$(ignore_snapshot)
  before_config=$(cat "$TARGET_DIR/.git/config")
  run install_agent_md --agent=claude --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"ignored by Git    agent-md.toml (global/host ignore:"* ]]
  [[ "$output" == *"ignored by Git    .githooks/pre-commit (global/host ignore:"* ]]
  [ "$(ignore_snapshot)" = "$before_ignores" ]
  [ "$(cat "$TARGET_DIR/.git/config")" = "$before_config" ]
  [ -z "$(ls -A "$TARGET_DIR" | grep -v '^\.git$')" ]
}

@test "doctor warns that a worktree-only policy and control record are not Git-bound" {
  install_agent_md --agent=claude
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > "$TARGET_DIR/agent-md.toml"
  printf 'schema = 1\nrisk = "medium"\n' > "$TARGET_DIR/.project-control.toml"
  run doctor
  [[ "$output" == *"warn [WARNING CONTROL_NOT_GIT_BOUND] agent-md.toml exists only in the worktree; its policy is a local proposal, not a Git-bound baseline."* ]]
  [[ "$output" == *"warn [WARNING CONTROL_NOT_GIT_BOUND] .project-control.toml exists only in the worktree; its Risk is a local proposal, not a Git-bound baseline."* ]]
  [[ "$output" == *"git add agent-md.toml"* ]]
}

@test "doctor reports staged control files as not yet established" {
  install_agent_md --agent=claude
  printf 'schema = 1\nrisk = "medium"\n' > "$TARGET_DIR/.project-control.toml"
  git -C "$TARGET_DIR" add .project-control.toml
  run doctor
  [[ "$output" == *"warn [WARNING CONTROL_NOT_GIT_BOUND] .project-control.toml is staged but not committed; it is not a Git-bound baseline yet."* ]]
}

@test "doctor reports Git-bound control files without a warning" {
  install_agent_md --agent=claude
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > "$TARGET_DIR/agent-md.toml"
  printf 'schema = 1\nrisk = "medium"\n' > "$TARGET_DIR/.project-control.toml"
  git -C "$TARGET_DIR" add agent-md.toml .project-control.toml
  git -C "$TARGET_DIR" -c core.hooksPath=/dev/null commit -qm control
  run doctor
  [[ "$output" == *"  agent-md.toml: Git-bound (HEAD)"* ]]
  [[ "$output" == *"  .project-control.toml: Git-bound (HEAD)"* ]]
  [[ "$output" != *"CONTROL_NOT_GIT_BOUND"* ]]
}

@test "doctor names the ignore rule and the explicit recovery for an ignored policy" {
  printf 'agent-md.toml\n.claude/\n' > "$HOST_DIR/global-ignore"
  install_agent_md --agent=claude
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > "$TARGET_DIR/agent-md.toml"
  before=$(cat "$HOST_DIR/global-ignore")
  run doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"warn [WARNING CONTROL_NOT_GIT_BOUND] agent-md.toml exists only in the worktree; its policy is a local proposal, not a Git-bound baseline. It is ignored by Git (global/host ignore: $HOST_DIR/global-ignore:1: agent-md.toml)."* ]]
  [[ "$output" == *"git add -f agent-md.toml"* ]]
  [[ "$output" == *"warn [WARNING CRITICAL_FILE_IGNORED] .claude/hooks/_lib.sh is ignored by Git (global/host ignore: $HOST_DIR/global-ignore:2: .claude/)"* ]]
  [ "$(cat "$HOST_DIR/global-ignore")" = "$before" ]
}

@test "doctor does not report a tracked file that an ignore pattern also matches" {
  install_agent_md --agent=claude
  git -C "$TARGET_DIR" add AGENT.md
  git -C "$TARGET_DIR" -c core.hooksPath=/dev/null commit -qm directives
  printf 'AGENT.md\n' > "$HOST_DIR/global-ignore"
  run doctor
  [[ "$output" != *"AGENT.md is ignored by Git"* ]]
}
