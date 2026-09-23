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
    .schema == 7 and
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
  # Both scope lines start empty: no reservation outstanding, no result to
  # supersede, and a sequence that has not yet issued a number.
  jq -e '.schema == 3
    and (.scopes | keys | sort) == ["staged","worktree"]
    and all(.scopes[]; .next_sequence == 1 and .pending == null and .last_terminal == null)' \
    "$state" >/dev/null
}

# --- what a clean host gets ---------------------------------------------------
#
# Installing has to leave a host able to actually run a check. An installation
# that creates the authority but not the account it drops to looks complete and
# cannot execute anything.

@test "19 install declares both accounts it will provision" {
  run bash "$AUTHORITY" install --root "$ROOT" --dry-run
  [ "$status" -eq 0 ]
  [[ "$output" == *"service account: agentmd"* ]]
  [[ "$output" == *"execution account: agentmd-runner"* ]]
}

@test "20 install ships every program the authority needs at runtime" {
  local lib="$ROOT/usr/local/lib/agent-md" name
  for name in authority-lib.sh phase-a-source.sh agent-md-authority \
              agent-md-issuer run-check receipt-verify.sh; do
    [ -f "$lib/$name" ] || { printf 'missing: %s\n' "$name" >&2; return 1; }
    [ -x "$lib/$name" ]
  done
}

@test "21 the validator completion looks for is installed where it looks" {
  # Completion resolves the validator by its installed path. Shipping the
  # authority without it degrades every completion to a full run in silence.
  local expected
  expected=$(bash -c '. "$1/.claude/hooks/_lib.sh"; completion_receipt_validator_path' \
    _ "$BATS_TEST_DIRNAME/.." 2>/dev/null)
  [ "$expected" = /usr/local/lib/agent-md/receipt-verify.sh ]
  [ -f "$ROOT/usr/local/lib/agent-md/receipt-verify.sh" ]
}

@test "22 install creates the execution scratch root" {
  [ -d "$ROOT/var/tmp/agent-md-runner" ]
  [ "$(stat -c %a "$ROOT/var/tmp/agent-md-runner")" = 700 ]
}

@test "23 the execution account is never the authority itself" {
  # Two accounts that are one account are no separation at all.
  run bash -c ". '$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh'
    [ \"\$AUTHORITY_SERVICE_USER\" != \"\$AUTHORITY_RUNNER_USER\" ]"
  [ "$status" -eq 0 ]
  run grep -n 'the service account and the execution account must be different' "$AUTHORITY"
  [ "$status" -eq 0 ]
}

@test "24 the execution account is provisioned with no home and no shell" {
  # It must not own a home the authority state could leak into, and it is never
  # meant to be logged into; run-check hands each check an ephemeral HOME.
  run bash -c "grep -A1 'useradd --system --no-create-home' '$AUTHORITY'"
  [ "$status" -eq 0 ]
  [[ "$output" == *"--home-dir /nonexistent"* ]]
  [[ "$output" == *"nologin"* ]]
  # And exactly one account is created that way.
  run bash -c "grep -c 'useradd --system --no-create-home' '$AUTHORITY'"
  [ "$output" = "1" ]
}

@test "25 a staging install creates no accounts at all" {
  # --root is for tests and staging; it must never touch the host's user table.
  run bash "$AUTHORITY" install --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"accounts are not created"* ]]
}

@test "26 staging enrollment never chowns host accounts and keeps modes" {
  run bash -c '
    chown() { touch "$MARKER"; return 1; }
    export -f chown
    bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --yes
  '
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
  local record dir
  record=$(enrollment_file); dir=${record%/*}
  [ "$(stat -c %a "$dir")" = 755 ]
  [ "$(stat -c %a "$record")" = 644 ]
  [ "$(stat -c %a "$dir/state.json")" = 644 ]
  [ "$(stat -c %u "$dir")" = "$(id -u)" ]
  [ "$(find "$dir" -name '.agent-md-*' | wc -l)" -eq 0 ]
}

@test "27 duplicate enrollment leaves existing sequence state byte-identical" {
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -eq 0 ]
  local record dir before
  record=$(enrollment_file); dir=${record%/*}
  jq '.scopes.worktree.next_sequence = 42 | .scopes.staged.next_sequence = 9' \
    "$dir/state.json" > "$dir/advanced.json"
  mv "$dir/advanced.json" "$dir/state.json"
  before=$(sha256sum "$dir/state.json" "$record")
  run_authority enroll "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *"already enrolled"* ]]
  [ "$(sha256sum "$dir/state.json" "$record")" = "$before" ]
}

@test "28 production chown failure leaves no published enrollment or success claim" {
  run bash -c '
    fixture_root=$ROOT
    set -- --help
    . "$AUTHORITY"
    ROOT=$fixture_root
    is_real_root_prefix() { return 0; }
    projects_dir() { printf "%s/var/lib/agent-md/projects" "$ROOT"; }
    authority_workspace_traversal_reasons() { printf "[]"; }
    chown() { return 1; }
    cmd_enroll "$WS" --root "$ROOT" --yes
  ' "$AUTHORITY"
  [ "$status" -ne 0 ]
  [[ "$output" == *"cannot assign enrollment ownership to agentmd"* ]]
  [[ "$output" != *$'\nenrolled '* ]]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name enrollment.json | wc -l)" -eq 0 ]
  [ "$(find "$ROOT/var/lib/agent-md/projects" -name '.agent-md-*' | wc -l)" -eq 0 ]
}

@test "29 production ownership normalization never rewrites existing state" {
  local dir="$ROOT/var/lib/agent-md/projects/preserved-state"
  mkdir "$dir"
  printf '{"schema":2,"scopes":{"worktree":{"next_sequence":42},"staged":{"next_sequence":9}}}\n' > "$dir/state.json"
  local before
  before=$(sha256sum "$dir/state.json")
  run bash -c '
    fixture_root=$ROOT
    set -- --help
    . "$AUTHORITY"
    ROOT=$fixture_root
    is_real_root_prefix() { return 0; }
    projects_dir() { printf "%s/var/lib/agent-md/projects" "$ROOT"; }
    authority_workspace_traversal_reasons() { printf "[]"; }
    new_uuid() { printf preserved-state; }
    chown() { printf "%s\n" "$@" > "$MARKER"; }
    cmd_enroll "$WS" --root "$ROOT" --yes
  ' "$AUTHORITY"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$dir/state.json")" = "$before" ]
  [ "$(sed -n '1p' "$MARKER")" = agentmd:agentmd ]
  [ "$(sed -n '2p' "$MARKER")" = "$dir" ]
  [ "$(sed -n '3p' "$MARKER")" = "$dir/state.json" ]
  [[ "$(sed -n '4p' "$MARKER")" == "$dir/.agent-md-enrollment."* ]]
  [ "$(wc -l < "$MARKER")" -eq 4 ]
  [ -f "$dir/enrollment.json" ]
}

@test "30 staging enrollment does not probe host runtime accounts" {
  run bash -c '
    runuser() { touch "$MARKER"; return 1; }
    export -f runuser
    bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path /usr/bin:/bin --yes
  '
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
  jq -e '.status == "eligible"' "$(enrollment_file)" >/dev/null
}

@test "31 service enrollment diagnoses an unreadable tracked source without changing its mode" {
  [ "$(id -u)" -ne 0 ] || skip "the real root/runner case is exercised by the integration harness"
  printf 'private tracked source\n' > "$WS/tracked-private.txt"
  git -C "$WS" add tracked-private.txt
  chmod 0000 "$WS/tracked-private.txt"
  run bash -c '
    fixture_root=$ROOT
    set -- --help
    . "$AUTHORITY" >/dev/null
    ROOT=$fixture_root
    is_real_root_prefix() { return 0; }
    chown() { return 0; }
    cmd_enroll "$WS" --root "$ROOT" --yes
  ' "$AUTHORITY"
  [ "$status" -eq 0 ]
  local record
  record=$(enrollment_file)
  [ "$(jq -r .status "$record")" = ineligible ]
  jq -e 'any(.reasons[]; contains("tracked-private.txt"))' "$record" >/dev/null
  [ "$(stat -c %a "$WS/tracked-private.txt")" = 0 ]
}
