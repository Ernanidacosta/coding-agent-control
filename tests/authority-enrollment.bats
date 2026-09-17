#!/usr/bin/env bats
#
# C1 enrollment authority. The workspace is untrusted input throughout: these
# tests pin that the authority reads it, hashes it and refuses it, but never
# executes anything out of it.

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  MARKER="$(mktemp -u)"
  export AUTHORITY ROOT WS MARKER
  build_workspace
  run_authority install --root "$ROOT"
}

teardown() {
  rm -rf "$ROOT" "$WS"
  rm -f "$MARKER"
}

run_authority() {
  run bash "$AUTHORITY" "$@"
}

# A workspace that looks real enough to enroll, and whose helper files would
# announce themselves loudly if anything ever executed them.
build_workspace() {
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  cat > "$WS/agent-md.toml" <<'TOML'
[verify]
lint = "shellcheck ."
test = "bats tests/"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 360
total_timeout_seconds = 540
TOML
  local hook
  for hook in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\ntouch "%s"\n' "$MARKER" > "$WS/$hook"
    chmod +x "$WS/$hook"
  done
  printf '#!/bin/bash\ntouch "%s"\n' "$MARKER" > "$WS/install.sh"
  chmod +x "$WS/install.sh"
}

enrollment_file() {
  local id
  id=$(bash "$AUTHORITY" show --workspace "$WS" --root "$ROOT" 2>/dev/null | awk '/^project id:/ { print $3 }')
  printf '%s/var/lib/agent-md/projects/%s/enrollment.json' "$ROOT" "$id"
}

@test "1 a hostile workspace helper is never executed" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "2 a symlinked authority state path is refused" {
  local elsewhere
  elsewhere=$(mktemp -d)
  rm -rf "$ROOT/var/lib/agent-md/projects"
  ln -s "$elsewhere" "$ROOT/var/lib/agent-md/projects"
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"symlink"* ]]
  rm -rf "$elsewhere"
}

@test "3 a world-writable authority directory is refused" {
  chmod 0777 "$ROOT/var/lib/agent-md/projects"
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"world-writable"* ]]
}

@test "4 a duplicate enrollment does not create ambiguous authority" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"already enrolled"* ]]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 1 ]
}

@test "5 a clone at another path does not inherit enrollment" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  local clone
  clone=$(mktemp -d)
  cp -a "$WS/." "$clone/"
  run_authority show --workspace "$clone" --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no enrollment"* ]]
  rm -rf "$clone"
}

@test "6 a developer-writable PATH entry makes the project ineligible" {
  local devbin
  devbin=$(mktemp -d)
  run_authority enroll "$WS" --root "$ROOT" --exec-path "/usr/bin:$devbin" --yes
  [ "$status" -eq 0 ]
  [[ "$output" == *"ineligible"* ]]
  jq -e '.status == "ineligible" and (.reasons | length) > 0' "$(enrollment_file)" >/dev/null
  jq -e '[.path_eligibility[] | select(.status == "ineligible")] | length == 1' "$(enrollment_file)" >/dev/null
  rm -rf "$devbin"
}

@test "7 a PATH of trusted system directories is eligible" {
  run_authority enroll "$WS" --root "$ROOT" --exec-path "/usr/bin:/bin" --yes
  [ "$status" -eq 0 ]
  jq -e '.status == "eligible" and (.reasons | length) == 0' "$(enrollment_file)" >/dev/null
  jq -e 'all(.path_eligibility[]; .status == "eligible")' "$(enrollment_file)" >/dev/null
}

@test "8 credential-like variables are refused, never recorded" {
  run_authority enroll "$WS" --root "$ROOT" --env GITHUB_TOKEN=secret --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"refusing to record"* ]]
  run_authority enroll "$WS" --root "$ROOT" --env SSH_AUTH_SOCK=/tmp/agent.sock --yes
  [ "$status" -ne 0 ]
  run_authority enroll "$WS" --root "$ROOT" --env LD_PRELOAD=/tmp/evil.so --yes
  [ "$status" -ne 0 ]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 0 ]
}

@test "9 an ambient variable is captured only when explicitly declared" {
  PROJECT_FLAVOUR=ambient run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  jq -e '[.approved_environment[].name] | index("PROJECT_FLAVOUR") == null' "$(enrollment_file)" >/dev/null

  rm -rf "$ROOT/var/lib/agent-md/projects"/*
  run_authority enroll "$WS" --root "$ROOT" --env PROJECT_FLAVOUR=declared --yes
  [ "$status" -eq 0 ]
  jq -e '
    any(.approved_environment[]; .name == "PROJECT_FLAVOUR" and .value == "declared")
  ' "$(enrollment_file)" >/dev/null
}

@test "10 an unusable agent-md.toml fails closed" {
  printf 'this is not a verification contract\n' > "$WS/agent-md.toml"
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 0 ]

  rm -f "$WS/agent-md.toml"
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
}

@test "11 a missing mechanism file fails closed" {
  rm -f "$WS/.agent-md/bin/verify.sh"
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 0 ]
}

@test "12 a symlinked workspace is canonicalized before approval" {
  local link
  link="$(mktemp -u)"
  ln -s "$WS" "$link"
  run_authority enroll "$link" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  jq -e --arg ws "$(realpath "$WS")" '.workspace == $ws' "$(enrollment_file)" >/dev/null
  rm -f "$link"
}

@test "13 install is idempotent and keeps safe modes" {
  run_authority install --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already current"* ]]
  [ "$(stat -c %a "$ROOT/var/lib/agent-md/keys")" = "700" ]
  [ "$(stat -c %a "$ROOT/var/lib/agent-md/projects")" = "755" ]
  [ "$(stat -c %a "$ROOT/usr/local/lib/agent-md/agent-md-authority")" = "755" ]
}

@test "14 show never prints private material" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  printf 'PRIVATE-KEY-MATERIAL-SENTINEL\n' > "$ROOT/var/lib/agent-md/keys/issuer.key"
  chmod 0600 "$ROOT/var/lib/agent-md/keys/issuer.key"
  run_authority show --workspace "$WS" --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"SENTINEL"* ]]
  [[ "$output" != *"PRIVATE"* ]]
}

@test "15 enrollment writes nothing into the workspace" {
  local before after
  before=$(find "$WS" -path "$WS/.git" -prune -o -print | sort | sha256sum)
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  after=$(find "$WS" -path "$WS/.git" -prune -o -print | sort | sha256sum)
  [ "$before" = "$after" ]
}

@test "16 a dry run presents the decision and writes nothing" {
  run_authority enroll "$WS" --root "$ROOT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"dry run"* ]]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 0 ]
}

@test "17 the enrollment record carries a versioned schema" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  jq -e '
    .schema == 6 and
    (.project_id | length) > 0 and
    (.workspace | startswith("/")) and
    (.execution.user | length) > 0 and
    (.execution.uid | type) == "number" and
    (.execution.user | type) == "string" and
    (.approved_contract.checks | length) == 2 and
    (.approved_contract.required | sort) == ["lint","test"] and
    (.approved_contract.required_declared == true) and
    (.approved_contract.excluded_conditional | type) == "array" and
    (.approved_contract_fingerprint | length) == 64 and
    (.approved_mechanism | length) == 3 and
    all(.approved_mechanism[]; (.digest | length) == 64) and
    (.approved_environment | length) >= 2 and
    (.approved_tools | length) == 3 and
    all(.approved_tools[]; (.path | startswith("/"))) and
    ([.approved_tools[].name] | sort) == ["bash","env","timeout"] and
    (.path_eligibility | type) == "array" and
    (.status == "eligible" or .status == "ineligible") and
    (.metadata.created | length) > 0
  ' "$(enrollment_file)" >/dev/null
}

@test "18 the initial sequence state carries no usable history" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  local id state
  id=$(bash "$AUTHORITY" show --workspace "$WS" --root "$ROOT" | awk '/^project id:/ { print $3 }')
  state="$ROOT/var/lib/agent-md/projects/$id/state.json"
  jq -e '.schema == 6 and .last_terminal == null and .pending == null' "$state" >/dev/null
}
