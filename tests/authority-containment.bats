#!/usr/bin/env bats

load authority-helpers
bats_require_minimum_version 1.5.0

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  RUN_CHECK="$BATS_TEST_DIRNAME/../examples/local-issuer/run-check"
  ROOT=$(mktemp -d)
  WS=$(mktemp -d)
  TOOLCHAIN=$(mktemp -d)
  export AUTHORITY ISSUER RUN_CHECK ROOT WS TOOLCHAIN
  EXEC_PATH=$(trusted_toolchain_path "$TOOLCHAIN")
  export EXEC_PATH
  git -C "$WS" init -q
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  for file in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\n' > "$WS/$file"
  done
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  contract true
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

contract() {
  printf '[verify]\ntest = "%s"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = %s\n' \
    "$1" "${2:-10}" > "$WS/agent-md.toml"
}

enroll() {
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  PROJECT="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  SCRATCH="$ROOT/var/tmp/agent-md-runner/$PROJECT_ID/test"
  export PROJECT_ID PROJECT SCRATCH
}

evaluate() {
  run --separate-stderr bash -c \
    'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT"
}

edit_enrollment() {
  jq "$@" "$PROJECT/enrollment.json" > "$PROJECT/enrollment.tmp"
  mv "$PROJECT/enrollment.tmp" "$PROJECT/enrollment.json"
}

@test "ordinary checks without preparation use a closed filesystem and private PID namespace" {
  cat > "$WS/probe.py" <<'PY'
import os
from pathlib import Path
assert os.getcwd() == '/workspace'
assert os.environ['HOME'] == '/runtime/home'
assert os.environ['TMPDIR'] == '/runtime/tmp'
assert os.environ['PYTHONNOUSERSITE'] == '1'
assert Path('/proc/1').exists()
assert not Path('/home').exists()
assert not Path('/var/lib/agent-md').exists()
assert not Path('/var/tmp/agent-md-runner').exists()
assert not Path('/runtime/../other-check').exists()
for path in ('/workspace/changed', '/var/lib/agent-md/state.json', '/other-check', '/usr/changed'):
    try:
        Path(path).write_text('bad')
    except OSError:
        pass
    else:
        raise AssertionError(path)
Path('/runtime/output').write_text('scratch-only')
Path('/dev/shm/output').write_text('scratch-shared-memory')
for fd in Path('/proc/self/fd').iterdir():
    try:
        target = os.readlink(fd)
    except OSError:
        continue
    assert 'issuer-' not in target and '.evaluation.lock' not in target
print('contained')
PY
  contract 'python3 probe.py'
  enroll
  evaluate
  [ "$status" -eq 0 ]
  jq -e '.status == "authenticated_pass" and .checks[0].exit_code == 0' <<<"$output" >/dev/null
  [ "$(cat "$SCRATCH/output")" = scratch-only ]
  [ "$(cat "$SCRATCH/shm/output")" = scratch-shared-memory ]
  [[ "$stderr" == *contained* ]]
}

@test "local issuer doctor diagnoses its explicit sandbox capability" {
  run bash "$AUTHORITY" doctor --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *'isolated-execution-v1 via bubblewrap-v1 ready'* ]]
  [[ "$output" == *'trusted local HTTPS passed; untrusted certificate rejected'* ]]
}

assert_descendants_contained() {
  local finish="$1"
  token="containment-$BATS_TEST_NUMBER-$$"
  cat > "$WS/tree.py" <<'PY'
import os
import signal
import sys
from pathlib import Path
ready_r, ready_w = os.pipe()
pid = os.fork()
if pid == 0:
    os.close(ready_r)
    os.setsid()
    signal.signal(signal.SIGTERM, signal.SIG_IGN)
    os.write(ready_w, b'ready')
    os.close(ready_w)
    while True:
        signal.pause()
os.close(ready_w)
assert os.read(ready_r, 5) == b'ready'
os.mkfifo('/runtime/release')
Path('/runtime/ready').write_text(str(pid))
with open('/runtime/release') as release:
    release.read()
PY
  contract "python3 tree.py $token" 5
  enroll
  bash "$AUTHORITY" prepare-job "$PROJECT_ID" --check test --root "$ROOT" >/dev/null
  bash "$RUN_CHECK" "$PROJECT_ID" test --root "$ROOT" > "$ROOT/stdout" 2> "$ROOT/stderr" &
  supervisor=$!
  # The child handshake precedes this sentinel; the deadline only bounds a
  # failed fixture, never determines whether process containment passed.
  deadline=$((SECONDS + 10))
  until [ -f "$SCRATCH/ready" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { cat "$ROOT/stderr"; return 1; }
    sleep 0.02
  done
  mapfile -t descendants < <(pgrep -f "^python3 tree.py $token$")
  [ "${#descendants[@]}" -eq 2 ]
  case "$finish" in
    exit) printf release > "$SCRATCH/release"; wait "$supervisor" ;;
    timeout) wait "$supervisor" && return 1; [ "$?" -eq 124 ] ;;
    kill) kill -KILL "$supervisor"; wait "$supervisor" && return 1; [ "$?" -eq 137 ] ;;
  esac
  for pid in "${descendants[@]}"; do
    deadline=$((SECONDS + 3))
    while kill -0 "$pid" 2>/dev/null; do
      [ "$SECONDS" -lt "$deadline" ] || { ps -o pid,ppid,stat,args -p "$pid"; return 1; }
      sleep 0.01
    done
  done
}

@test "a detached descendant is dead when the ordinary shell exits" {
  assert_descendants_contained exit
}

@test "a timeout kills even detached descendants that ignore TERM" {
  assert_descendants_contained timeout
}

@test "killing the supervisor also kills every sandbox descendant" {
  assert_descendants_contained kill
}

@test "kernel-disabled nested user namespaces refuse without executing a check" {
  enroll
  # Test-only outer namespace disables further namespaces in the kernel.
  # This is a fault injector; the product never binds the host root.
  run --separate-stderr /usr/bin/bwrap --unshare-user --disable-userns --bind / / --dev /dev -- \
    bash -c 'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT"
  printf 'exit=%s stdout=%s stderr=%s\n' "$status" "$output" "$stderr" >&2
  [ "$status" -eq 23 ]
  jq -e '.reason_code == "REFUSED_SANDBOX_UNAVAILABLE" and .receipt == null' <<<"$output" >/dev/null
  [[ "$stderr" == *'namespace'* ]]
}

@test "missing approved bwrap refuses without any signed verdict" {
  enroll
  edit_enrollment '(.approved_tools[] | select(.name == "bwrap") | .path) = "/absent/bwrap"'
  evaluate
  [ "$status" -eq 23 ]
  jq -e '.reason_code == "REFUSED_SANDBOX_UNAVAILABLE" and .receipt == null' <<<"$output" >/dev/null
  jq -e '.scopes.worktree.last_terminal.status == "execution_failed" and .scopes.worktree.pending == null' \
    "$PROJECT/state.json" >/dev/null
}

@test "failed namespace setup never runs the ordinary command or publishes a receipt" {
  chmod u+w "$TOOLCHAIN/bin"
  printf '#!/bin/bash\necho "user namespace: Operation not permitted" >&2\nexit 1\n' > "$TOOLCHAIN/bin/bwrap-denied"
  chmod 0555 "$TOOLCHAIN/bin/bwrap-denied" "$TOOLCHAIN/bin"
  contract 'echo SHOULD_NOT_EXECUTE'
  enroll
  edit_enrollment --arg path "$TOOLCHAIN/bin/bwrap-denied" \
    '(.approved_tools[] | select(.name == "bwrap") | .path) = $path'
  evaluate
  [ "$status" -eq 23 ]
  jq -e '.reason_code == "REFUSED_SANDBOX_UNAVAILABLE" and .receipt == null' <<<"$output" >/dev/null
  [[ "$stderr" == *'Operation not permitted'* ]]
  [[ "$stderr" != *SHOULD_NOT_EXECUTE* ]]
}

@test "runner-writable approved bwrap is refused immediately before use" {
  chmod u+w "$TOOLCHAIN/bin"
  printf '#!/bin/bash\nexit 0\n' > "$TOOLCHAIN/bin/bwrap-writable"
  chmod 0755 "$TOOLCHAIN/bin/bwrap-writable"
  chmod 0555 "$TOOLCHAIN/bin"
  enroll
  edit_enrollment --arg path "$TOOLCHAIN/bin/bwrap-writable" \
    '(.approved_tools[] | select(.name == "bwrap") | .path) = $path'
  evaluate
  [ "$status" -eq 23 ]
  [[ "$stderr" == *'writable by the execution user'* ]]
  jq -e '.receipt == null' <<<"$output" >/dev/null
}

@test "an older enrollment cannot execute until containment is reapproved with a new identity" {
  enroll
  evaluate
  [ "$status" -eq 0 ]
  previous_receipt="$PROJECT/receipts/worktree/1.json"
  previous_bytes=$(cat "$previous_receipt")
  chmod u+w "$PROJECT" "$PROJECT/enrollment.json"
  edit_enrollment 'del(.execution_boundary) | .approved_tools |= map(select(.name != "bwrap"))'
  original_state=$(cat "$PROJECT/state.json")
  evaluate
  [ "$status" -eq 23 ]
  jq -e '.reason_code == "REFUSED_EXECUTION_REAPPROVAL_REQUIRED" and .sequence == null' <<<"$output" >/dev/null
  run bash "$AUTHORITY" reapprove "$WS" --root "$ROOT" --yes
  [ "$status" -ne 0 ]
  [[ "$output" == *'old PASS could remain current'* ]]
  printf '# updated mechanism\n' >> "$WS/.claude/hooks/_lib.sh"
  bash "$AUTHORITY" reapprove "$WS" --root "$ROOT" --yes >/dev/null
  [ "$(cat "$PROJECT/state.json")" = "$original_state" ]
  [ "$(cat "$previous_receipt")" = "$previous_bytes" ]
  [ "$(jq -r .project_id "$PROJECT/enrollment.json")" = "$PROJECT_ID" ]
  chmod 0444 "$PROJECT/enrollment.json" "$PROJECT/state.json"
  chmod 0555 "$PROJECT"
  run --separate-stderr bash "$BATS_TEST_DIRNAME/../examples/local-issuer/receipt-verify.sh" "$WS" worktree --root "$ROOT"
  [ "$status" -ne 0 ]
  jq -e '.applicable == false' <<<"$output" >/dev/null
  chmod u+w "$PROJECT" "$PROJECT/enrollment.json" "$PROJECT/state.json"
  evaluate
  [ "$status" -eq 0 ]
  jq -e '.scopes.worktree.next_sequence == 3' "$PROJECT/state.json" >/dev/null
}
