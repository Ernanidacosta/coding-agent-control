#!/usr/bin/env bats
#
# C3a: the descending execution boundary. An authority-selected command runs as
# the enrolled developer, and the boundary observes its exit status. Nothing
# here produces a receipt, a signature or a sequence number, and exit 0 still
# means only "the command exited 0".

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  RUNCHECK="$BATS_TEST_DIRNAME/../examples/local-issuer/run-check"
  ROOT="$(mktemp -d)"
  export AUTHORITY RUNCHECK ROOT

  REPO_DIR="$(mktemp -d)"
  export REPO_DIR
  cp -r "$BATS_TEST_DIRNAME/../.claude" "$REPO_DIR/"
  mkdir -p "$REPO_DIR/.agent-md/bin"
  printf '#!/bin/bash\n' > "$REPO_DIR/.agent-md/bin/verify.sh"
  git -C "$REPO_DIR" init -q
  cd "$REPO_DIR"
  WORKSPACE=$(realpath "$REPO_DIR")
  export WORKSPACE

  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
}

teardown() {
  cd "$BATS_TEST_DIRNAME"
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT" "$REPO_DIR"
}

# printf, not a heredoc: an unquoted heredoc would expand the command under
# test before it ever reached the contract.
write_contract() {
  local command="$1" timeout="${2:-30}"
  printf '[verify]\ntest = "%s"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = %s\n' \
    "$command" "$timeout" > "$WORKSPACE/agent-md.toml"
}

# Re-enrols from scratch so each case approves exactly the command under test.
approve() {
  chmod -R u+w "$ROOT/var/lib/agent-md/projects" 2>/dev/null || true
  rm -rf "${ROOT:?}/var/lib/agent-md/projects"
  mkdir -p "$ROOT/var/lib/agent-md/projects"
  bash "$AUTHORITY" enroll "$WORKSPACE" --root "$ROOT" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PROJECT_ID
  bash "$AUTHORITY" prepare-job "$PROJECT_ID" --check test --root "$ROOT" >/dev/null
  chmod 0555 "$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
}

job_file() { printf '%s/var/lib/agent-md/projects/%s/job.json' "$ROOT" "$PROJECT_ID"; }

edit_job() {
  local dir="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  chmod u+w "$dir"; chmod u+w "$dir/job.json"
  jq "$@" "$dir/job.json" > "$dir/job.tmp" && mv "$dir/job.tmp" "$dir/job.json"
  chmod 0444 "$dir/job.json"; chmod 0555 "$dir"
}

run_check_capture() {
  RC_OUT=$(mktemp); RC_ERR=$(mktemp)
  set +e
  bash "$RUNCHECK" "$PROJECT_ID" --root "$ROOT" >"$RC_OUT" 2>"$RC_ERR"
  RC_STATUS=$?
  set -e
  export RC_STATUS
}

snapshot_dir() { printf '%s/var/lib/agent-md/snapshots/%s/src' "$ROOT" "$PROJECT_ID"; }

core_capture() {
  local command="$1" timeout="$2"
  CORE_OUT=$(mktemp); CORE_ERR=$(mktemp)
  set +e
  bash -c '. .claude/hooks/_lib.sh
    completion_execute_bounded_command "$1" bash -c "$2"' _ "$timeout" "$command" \
    >"$CORE_OUT" 2>"$CORE_ERR"
  CORE_STATUS=$?
  set -e
}

# The observable contract: same stdout and same exit classification.
assert_parity() {
  local command="$1" timeout="${2:-30}"
  write_contract "$command" "$timeout"
  approve
  core_capture "$command" "$timeout"
  run_check_capture
  if [ "$CORE_STATUS" != "$RC_STATUS" ]; then
    printf 'exit differs: core=%s run-check=%s for [%s]\n' "$CORE_STATUS" "$RC_STATUS" "$command" >&2
    return 1
  fi
  if ! cmp -s "$CORE_OUT" "$RC_OUT"; then
    printf 'stdout differs for [%s]\ncore:\n%s\nrun-check:\n%s\n' \
      "$command" "$(cat "$CORE_OUT")" "$(cat "$RC_OUT")" >&2
    return 1
  fi
}

@test "1 a simple command matches the core" { assert_parity 'echo hello'; }
@test "2 a shell builtin matches the core" { assert_parity "printf '%s\\n' builtin"; }
@test "3 a pipeline matches the core" { assert_parity "printf 'a\\nb\\n' | grep -c ."; }
@test "4 and-or chaining matches the core" { assert_parity 'true && echo yes || echo no'; }
@test "5 quoting is preserved exactly" { assert_parity "printf '%s|%s\\n' 'one two' three"; }
@test "6 spaces and arguments survive" { assert_parity 'echo    a     b   c'; }
@test "7 variable expansion matches the core" { assert_parity 'x=7; echo value=$x'; }
@test "8 a subshell matches the core" { assert_parity 'echo $( (echo nested) )'; }
@test "9 exit 0 stays 0" { assert_parity 'exit 0'; }
@test "10 a non-zero exit is preserved" { assert_parity 'exit 3'; }
@test "11 command not found never becomes success" {
  assert_parity 'definitely-not-a-real-command-xyz'
  [ "$RC_STATUS" -ne 0 ]
}
@test "12 a signal exit is preserved" { assert_parity 'kill -TERM $$'; }

@test "13 a timeout is 124 on both sides and never 0" {
  assert_parity 'sleep 30' 1
  [ "$RC_STATUS" -eq 124 ]
  [ "$CORE_STATUS" -eq 124 ]
}

@test "13b a command that ignores TERM still dies, and never reports success" {
  # Documented divergence. The core sends SIGKILL immediately and rewrites the
  # result to 124 after the command returns. run-check ends in exec, so nothing
  # of ours runs afterwards to rewrite anything: GNU timeout escalates to
  # SIGKILL after the grace period and reports 137. Both are non-zero and
  # neither can become a PASS; a supervisor running as its own account can
  # classify them later.
  write_contract 'trap : TERM; while :; do sleep 1; done' 1
  approve
  run_check_capture
  [ "$RC_STATUS" -ne 0 ]
  [ "$RC_STATUS" -eq 137 ] || [ "$RC_STATUS" -eq 124 ]
}

@test "14 a descendant that outlives its parent still times out" {
  write_contract 'trap : TERM; sleep 60 & wait' 1
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 124 ]
}

@test "15 the job cannot be rewritten to change the command" {
  write_contract 'echo approved'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  grep -q approved "$RC_OUT"
  # The job is read-only and its directory is not writable by this user, which
  # is the property that stops the substitution in production.
  run bash -c 'printf "{}" > "$1"' _ "$(job_file)"
  [ "$status" -ne 0 ]
}

@test "16 a symlinked job is refused" {
  write_contract 'echo hello'
  approve
  local dir="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  local elsewhere; elsewhere=$(mktemp)
  chmod u+w "$dir"
  cp "$dir/job.json" "$elsewhere"; rm -f "$dir/job.json"
  ln -s "$elsewhere" "$dir/job.json"
  chmod 0555 "$dir"
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "symlink" "$RC_ERR"
}

@test "17 a developer-writable job is refused" {
  write_contract 'echo hello'
  approve
  local dir="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  chmod u+w "$dir"; chmod 0644 "$dir/job.json"; chmod 0555 "$dir"
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "writable" "$RC_ERR"
}

@test "18 a job in a developer-writable directory is refused" {
  write_contract 'echo hello'
  approve
  chmod 0755 "$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "directory the execution user can write" "$RC_ERR"
}

@test "19 a job naming another project is refused" {
  write_contract 'echo hello'
  approve
  edit_job '.project_id = "00000000-0000-0000-0000-000000000000"'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "different project" "$RC_ERR"
}

@test "20 a job pointed at another snapshot is refused" {
  write_contract 'echo hello'
  approve
  local other; other=$(mktemp -d)
  edit_job --arg w "$other" '.snapshot = $w'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "writable by this account" "$RC_ERR"
  rm -rf "$other"
}

@test "21 a job addressed to another uid is refused" {
  write_contract 'echo hello'
  approve
  edit_job '.execution.uid = 65534'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "addressed to uid" "$RC_ERR"
}

@test "22 a job with unexpected fields is refused" {
  write_contract 'echo hello'
  approve
  edit_job '. + {"sequence": 7, "signature": "x"}'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "unexpected fields" "$RC_ERR"
}

@test "23 a malformed job is refused" {
  write_contract 'echo hello'
  approve
  local dir="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  chmod u+w "$dir"; chmod u+w "$dir/job.json"
  printf 'not json\n' > "$dir/job.json"
  chmod 0444 "$dir/job.json"; chmod 0555 "$dir"
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
}

@test "24 a PATH that became developer-writable is refused at execution time" {
  write_contract 'echo hello'
  approve
  local devbin; devbin=$(mktemp -d)
  edit_job --arg p "/usr/bin:$devbin" \
    '.environment = [.environment[] | if .name == "PATH" then .value = $p else . end]'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "not trustworthy" "$RC_ERR"
  rm -rf "$devbin"
}

@test "25 forbidden loader variables in a job are refused" {
  write_contract 'echo hello'
  approve
  edit_job '.environment += [{"name":"LD_PRELOAD","value":"/tmp/evil.so"}]'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "forbids" "$RC_ERR"

  edit_job '.environment = [.environment[] | select(.name != "LD_PRELOAD")]
            + [{"name":"BASH_ENV","value":"/tmp/evil.sh"}]'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
}

@test "26 the caller environment never reaches the child" {
  write_contract 'echo PATH=$PATH; echo LEAK=${LEAK_CANARY:-absent}; echo PP=${PYTHONPATH:-absent}'
  approve
  RC_OUT=$(mktemp); RC_ERR=$(mktemp)
  set +e
  LEAK_CANARY=leaked PYTHONPATH=/tmp/evil BASH_ENV=/tmp/evil.sh \
    bash "$RUNCHECK" "$PROJECT_ID" --root "$ROOT" >"$RC_OUT" 2>"$RC_ERR"
  RC_STATUS=$?
  set -e
  [ "$RC_STATUS" -eq 0 ]
  grep -q "LEAK=absent" "$RC_OUT"
  grep -q "PP=absent" "$RC_OUT"
  grep -q "PATH=/usr/local/bin:/usr/bin:/bin" "$RC_OUT"
}

@test "27 a hostile shell startup file is never sourced" {
  printf 'echo BASHRC_EXECUTED\n' > "$HOME/.bashrc.agent-md-test" 2>/dev/null || skip "no writable HOME"
  write_contract 'echo done'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  ! grep -q BASHRC_EXECUTED "$RC_OUT"
  rm -f "$HOME/.bashrc.agent-md-test"
}

@test "28 control-plane-looking output never changes the outcome" {
  # The quote character is built at runtime: the authority refuses a command
  # containing an embedded double quote, which is a documented divergence.
  write_contract 'q=$(printf \\042); echo {${q}status${q}:${q}eligible${q}}; exit 4'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 4 ]
  grep -q 'status' "$RC_OUT"
  grep -q 'eligible' "$RC_OUT"
}

@test "29 the command never receives the control plane on stdin" {
  write_contract 'if read -r line; then echo GOT:$line; else echo NOSTDIN; fi'
  approve
  RC_OUT=$(mktemp); RC_ERR=$(mktemp)
  set +e
  printf '{"project_id":"secret"}\n' | bash "$RUNCHECK" "$PROJECT_ID" --root "$ROOT" >"$RC_OUT" 2>"$RC_ERR"
  RC_STATUS=$?
  set -e
  grep -q NOSTDIN "$RC_OUT"
  ! grep -q secret "$RC_OUT"
}

@test "30 run-check refuses anything but a single project id" {
  write_contract 'echo hello'
  approve
  run bash "$RUNCHECK" "$PROJECT_ID" extra --root "$ROOT"
  [ "$status" -eq 125 ]
  run bash "$RUNCHECK" --root "$ROOT"
  [ "$status" -eq 125 ]
  run bash "$RUNCHECK" '../../etc/passwd' --root "$ROOT"
  [ "$status" -eq 125 ]
}

@test "31 run-check has no key, sequence or receipt capability" {
  ! grep -qE 'issuer\.key|last_terminal|receipt' "$RUNCHECK"
  ! grep -qE 'atomic_write|openssl' "$RUNCHECK"
  # sudo appears in comments explaining the boundary; it is never invoked.
  ! grep -qE '^[^#]*\bsudo\b' "$RUNCHECK"
}

@test "32 the generated sudo rule is minimal and bound to one project" {
  write_contract 'echo hello'
  approve
  run bash "$AUTHORITY" sudoers "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"run-check $PROJECT_ID"* ]]
  [[ "$output" != *"ALL=(ALL)"* ]]
  [[ "$output" != *"(root)"* ]]
  [[ "$output" == *"NOPASSWD"* ]]
}

@test "33 the generated sudo policy is syntactically valid" {
  command -v visudo >/dev/null 2>&1 || skip "visudo unavailable"
  write_contract 'echo hello'
  approve
  bash "$AUTHORITY" sudoers "$PROJECT_ID" --root "$ROOT" --write >/dev/null
  run visudo -cf "$ROOT/etc/sudoers.d/agent-md-$PROJECT_ID"
  [ "$status" -eq 0 ]
}

@test "34 each project gets its own literal rule and none is generic" {
  write_contract 'echo hello'
  approve
  local first="$PROJECT_ID"
  local first_policy; first_policy=$(bash "$AUTHORITY" sudoers "$first" --root "$ROOT")

  local second_ws; second_ws=$(mktemp -d)
  cp -a "$WORKSPACE/." "$second_ws/"
  bash "$AUTHORITY" enroll "$second_ws" --root "$ROOT" --yes >/dev/null
  local second; second=$(ls "$ROOT/var/lib/agent-md/projects" | grep -v "^$first\$" | head -1)
  local second_policy; second_policy=$(bash "$AUTHORITY" sudoers "$second" --root "$ROOT")

  [[ "$first_policy" != *"$second"* ]]
  [[ "$second_policy" != *"$first"* ]]
  # Both cross into the execution account, and neither can name a developer.
  [[ "$first_policy" == *"ALL=(agentmd-runner)"* ]]
  [[ "$second_policy" == *"ALL=(agentmd-runner)"* ]]
  rm -rf "$second_ws"
}

@test "35 a job is refused when the enrollment is not eligible" {
  local devbin; devbin=$(mktemp -d)
  write_contract 'echo hello'
  chmod -R u+w "$ROOT/var/lib/agent-md/projects" 2>/dev/null || true
  rm -rf "${ROOT:?}/var/lib/agent-md/projects"; mkdir -p "$ROOT/var/lib/agent-md/projects"
  bash "$AUTHORITY" enroll "$WORKSPACE" --root "$ROOT" --yes --exec-path "/usr/bin:$devbin" >/dev/null
  local pid; pid=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  run bash "$AUTHORITY" prepare-job "$pid" --check test --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not eligible"* ]]
  [ ! -e "$ROOT/var/lib/agent-md/projects/$pid/job.json" ]
  rm -rf "$devbin"
}

@test "36 a check outside the approved contract has no job" {
  write_contract 'echo hello'
  approve
  run bash "$AUTHORITY" prepare-job "$PROJECT_ID" --check lint --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not part of the approved contract"* ]]
}

# --- snapshot boundary -------------------------------------------------------

@test "37 checks run against the snapshot, not the live worktree" {
  printf 'ORIGINAL\n' > "$WORKSPACE/marker.txt"
  git -C "$WORKSPACE" add -A >/dev/null 2>&1 || true
  write_contract 'cat marker.txt'
  approve

  # The developer substitutes a different tree while the check would run.
  printf 'TAMPERED\n' > "$WORKSPACE/marker.txt"
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  grep -q ORIGINAL "$RC_OUT"
  ! grep -q TAMPERED "$RC_OUT"
}

@test "38 mutating the original during execution does not change the snapshot" {
  printf 'ORIGINAL\n' > "$WORKSPACE/marker.txt"
  git -C "$WORKSPACE" add -A >/dev/null 2>&1 || true
  # The check rewrites the live worktree mid-run and restores it afterwards,
  # which is exactly the substitution a before/after fingerprint cannot see.
  write_contract "printf TAMPERED > $WORKSPACE/marker.txt; cat marker.txt; printf ORIGINAL > $WORKSPACE/marker.txt"
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  grep -q ORIGINAL "$RC_OUT"
  ! grep -q TAMPERED "$RC_OUT"
  grep -q ORIGINAL "$(snapshot_dir)/marker.txt"
}

@test "39 the snapshot cannot be written by this account" {
  write_contract 'echo hello'
  approve
  run bash -c 'printf x > "$1/marker.txt"' _ "$(snapshot_dir)"
  [ "$status" -ne 0 ]
  run bash -c 'printf x > "$1/newfile"' _ "$(snapshot_dir)"
  [ "$status" -ne 0 ]
  [ ! -w "$(snapshot_dir)" ]
}

@test "40 a check that tries to modify the source fails and never passes" {
  printf 'ORIGINAL\n' > "$WORKSPACE/marker.txt"
  git -C "$WORKSPACE" add -A >/dev/null 2>&1 || true
  write_contract 'echo mutated > marker.txt'
  approve
  run_check_capture
  [ "$RC_STATUS" -ne 0 ]
  grep -q ORIGINAL "$(snapshot_dir)/marker.txt"
}

@test "41 scratch and temporary output stay writable and outside the snapshot" {
  write_contract 'echo ok > $TMPDIR/build.log; cat $TMPDIR/build.log; touch $HOME/x && echo HOME_OK=yes'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  grep -q ok "$RC_OUT"
  grep -q "HOME_OK=yes" "$RC_OUT"
}

@test "42 an ignored developer-writable toolchain never enters the snapshot" {
  mkdir -p "$WORKSPACE/.venv/bin"
  printf '#!/bin/sh\necho FAKE\n' > "$WORKSPACE/.venv/bin/python"
  chmod +x "$WORKSPACE/.venv/bin/python"
  printf '.venv\n' > "$WORKSPACE/.gitignore"
  git -C "$WORKSPACE" add -A >/dev/null 2>&1 || true
  write_contract 'test -e .venv/bin/python && echo PRESENT || echo ABSENT'
  approve
  run_check_capture
  grep -q ABSENT "$RC_OUT"
  [ ! -e "$(snapshot_dir)/.venv" ]
}

@test "43 the developer HOME is never the execution HOME" {
  write_contract 'echo HOME=$HOME; echo NOUSERSITE=$PYTHONNOUSERSITE'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 0 ]
  ! grep -q "HOME=$HOME\$" "$RC_OUT"
  grep -q "NOUSERSITE=1" "$RC_OUT"
}

# --- infrastructure result channel -------------------------------------------

@test "44 a refusal and a check exiting 125 are both fail-closed" {
  # This slice deliberately lets the two share an exit code. Both are non-zero,
  # both mean no authenticated PASS is possible, and neither is ever mistaken
  # for success. Separating them is a diagnostics improvement, not a trust one,
  # and mixing a control channel into the privileged boundary to get it was not
  # worth the file-descriptor inheritance surface.
  write_contract 'exit 125'
  approve
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  ! grep -q "refused" "$RC_ERR"

  edit_job '.project_id = "00000000-0000-0000-0000-000000000000"'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "refused" "$RC_ERR"
}

@test "45 no trusted code runs after the command starts" {
  # run-check ends in exec, so the command replaces it. Nothing of ours is left
  # under the same uid as project code to be tampered with or to post-process a
  # verdict.
  grep -qE '^exec "\$ENV_PATH" -i' "$RUNCHECK"
  ! grep -qE 'emit_result|>&3|RESULT_FD' "$RUNCHECK"
  ! grep -qE 'trap .* EXIT' "$RUNCHECK"
}

@test "46 the sudo policy does not widen descriptor inheritance" {
  write_contract 'echo hello'
  approve
  run bash "$AUTHORITY" sudoers "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"closefrom_override"* ]]
  [[ "$output" != *"preserve_fds"* ]]
  [[ "$output" == *"env_reset"* ]]
}

@test "47 a job addressed to another account is refused" {
  write_contract 'echo hello'
  approve
  edit_job '.execution.uid = 65534 | .execution.user = "nobody"'
  run_check_capture
  [ "$RC_STATUS" -eq 125 ]
  grep -q "addressed to uid 65534" "$RC_ERR"
}

# --- principals --------------------------------------------------------------

@test "48 the descending rule targets the execution account, never a developer" {
  write_contract 'echo hello'
  approve
  run bash "$AUTHORITY" sudoers "$PROJECT_ID" --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"ALL=(agentmd-runner)"* ]]
  [[ "$output" != *"ALL=(ALL)"* ]]
  [[ "$output" != *"(root)"* ]]
  [[ "$output" != *"ALL=($(id -un))"* ]]
  [[ "$output" == *"run-check $PROJECT_ID"* ]]
}

@test "49 run-check never reaches key or authority state" {
  ! grep -qE 'issuer\.key|keys_dir|enrollment\.json|last_terminal|receipt' "$RUNCHECK"
  ! grep -qE 'atomic_write|openssl' "$RUNCHECK"
  [ "$(stat -c %a "$ROOT/var/lib/agent-md/keys")" = "700" ]
}
