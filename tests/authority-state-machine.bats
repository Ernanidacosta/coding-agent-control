#!/usr/bin/env bats
#
# C4b: the authority-side evaluation state machine.
#
# What is being proven is one property and its behaviour under a crash:
#
#   PASS n, then FAIL n+1  =>  PASS n is stale
#
# Nothing here signs, reads a key or writes a receipt. candidate_pass in the
# state file is an authority-side terminal result; it is not evidence, and the
# last tests in this file assert that no code treats it as any.

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  RUNCHECK="$BATS_TEST_DIRNAME/../examples/local-issuer/run-check"
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  TOOLCHAIN="$(mktemp -d)"
  export AUTHORITY ISSUER RUNCHECK LIB ROOT WS TOOLCHAIN

  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  git -C "$WS" config user.email t@example.invalid
  git -C "$WS" config user.name Test
  printf '#!/bin/bash\n' > "$WS/.claude/hooks/_lib.sh"
  printf '#!/bin/bash\n' > "$WS/.claude/hooks/stop-verify.sh"
  printf '#!/bin/bash\n' > "$WS/.agent-md/bin/verify.sh"
  printf 'ORIGINAL\n' > "$WS/marker.txt"

  EXEC_PATH="$(trusted_toolchain_path "$TOOLCHAIN")"
  export EXEC_PATH
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

write_contract() {
  printf '[verify]\ntest = "%s"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = %s\n' \
    "$1" "${2:-20}" > "$WS/agent-md.toml"
}

# A workspace is enrolled once. Outcomes are then steered with trigger files
# that live OUTSIDE the workspace, so the approved contract and the workspace
# identity both stay fixed: re-enrolling would either be refused or would reset
# the sequence line these tests are about.
#
#   FLAG present   -> the required check passes
#   FLAG absent    -> it fails
#   SLOW present   -> it stays in execution long enough to be killed
#   MUTATE present -> it writes into the live workspace, so revalidation diverges
steerable_contract() {
  FLAG="$ROOT/flag"; SLOW="$ROOT/slow"; MUTATE="$ROOT/mutate"; RUNNING="$ROOT/running"
  export FLAG SLOW MUTATE RUNNING
  printf 'ok\n' > "$FLAG"
  write_contract "touch $RUNNING; cat $FLAG || exit 1; if [ -e $MUTATE ]; then printf x >> $WS/marker.txt; fi; if [ -e $SLOW ]; then sleep 40; fi; true" "${1:-60}"
}

unseal() { chmod u+w "$ROOT/var/lib/agent-md/projects/$PID" 2>/dev/null || true; }

# Puts a terminal result on the line without running an evaluation, for the
# cases that need a previous result to supersede but must not re-enroll.
seed_terminal() {
  libcall authority_state_reserve "$PID" worktree "seed-$1" >/dev/null
  libcall authority_state_commit_terminal "$PID" worktree "$1" "seed-$1" \
    '{"source":{"algorithm":"sha256","value":"seed"}}' >/dev/null
}

enroll() {
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PID
  [ "$(jq -r .status "$ROOT/var/lib/agent-md/projects/$PID/enrollment.json")" = eligible ] || {
    enrollment_diagnosis "$ROOT/var/lib/agent-md/projects/$PID/enrollment.json" >&2
    return 1
  }
}

state_file() { printf '%s/var/lib/agent-md/projects/%s/state.json' "$ROOT" "$PID"; }
wt() { jq -c --arg k "$1" '.scopes.worktree[$k]' "$(state_file)"; }
next_seq() { jq -r '.scopes.worktree.next_sequence' "$(state_file)"; }
pending_seq() { jq -r '.scopes.worktree.pending.sequence // "none"' "$(state_file)"; }
terminal_seq() { jq -r '.scopes.worktree.last_terminal.sequence // "none"' "$(state_file)"; }
terminal_status() { jq -r '.scopes.worktree.last_terminal.status // "none"' "$(state_file)"; }

request() { printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$WS"; }
evaluate() { request | bash "$ISSUER" evaluate --root "$ROOT" 2>/dev/null; }

# Runs the library in-process against the staging root, for the state-layer
# cases that do not need a whole evaluation.
libcall() {
  ROOT="$ROOT" bash -c '
    set -u
    . "$1"
    ROOT="$2"
    PROGRAM=test
    shift 2
    "$@"
  ' _ "$LIB" "$ROOT" "$@"
}

# --- schema and validation ---------------------------------------------------

@test "1 enrollment creates empty sequence lines for both scopes" {
  write_contract "cat marker.txt"; enroll
  [ "$(jq -r '.schema' "$(state_file)")" = 2 ]
  [ "$(jq -r '.scopes.worktree.next_sequence' "$(state_file)")" = 1 ]
  [ "$(jq -r '.scopes.staged.next_sequence' "$(state_file)")" = 1 ]
  [ "$(jq -r '.scopes.worktree.pending' "$(state_file)")" = null ]
  [ "$(jq -r '.scopes.staged.last_terminal' "$(state_file)")" = null ]
}

@test "2 a corrupt state file fails closed rather than reading as empty" {
  write_contract "cat marker.txt"; enroll
  printf 'not json\n' > "$(state_file)"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = refused ]
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "3 a missing state file fails closed rather than being recreated" {
  write_contract "cat marker.txt"; enroll
  rm -f "$(state_file)"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = refused ]
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
  [ ! -e "$(state_file)" ]
}

@test "4 a pending at or above next_sequence is rejected" {
  write_contract "cat marker.txt"; enroll
  jq -c '.scopes.worktree.pending = {sequence: 9, run_id: "r", scope: "worktree"}' \
    "$(state_file)" > "$(state_file).new" && mv "$(state_file).new" "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "5 a last_terminal with an unknown status is rejected" {
  write_contract "cat marker.txt"; enroll
  jq -c '.scopes.worktree.next_sequence = 5
    | .scopes.worktree.last_terminal = {sequence: 4, run_id: "r", scope: "worktree",
                                        status: "authenticated_pass", fingerprints: {}}' \
    "$(state_file)" > "$(state_file).new" && mv "$(state_file).new" "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "6 a non-integer next_sequence is rejected" {
  write_contract "cat marker.txt"; enroll
  jq -c '.scopes.worktree.next_sequence = 1.5' "$(state_file)" > "$(state_file).new" \
    && mv "$(state_file).new" "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "7 state is never reconstructed from run directories" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  local before; before=$(terminal_seq)
  unseal
  rm -f "$(state_file)"
  # The runs and their identities are all still on disk.
  [ -n "$(ls "$ROOT/var/lib/agent-md/projects/$PID/runs")" ]
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
  [ ! -e "$(state_file)" ]
  [ -n "$before" ]
}

# --- migration ---------------------------------------------------------------

@test "8 the known earlier state migrates deterministically" {
  write_contract "cat marker.txt"; enroll
  printf '{"schema":7,"last_terminal":null,"pending":null}\n' > "$(state_file)"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_pass ]
  [ "$(jq -r '.schema' "$(state_file)")" = 2 ]
  [ "$(terminal_seq)" = 1 ]
  [ "$(jq -r '.scopes.staged.next_sequence' "$(state_file)")" = 1 ]
}

@test "9 an earlier state carrying a result that version never wrote is refused" {
  write_contract "cat marker.txt"; enroll
  printf '{"schema":7,"last_terminal":{"sequence":4},"pending":null}\n' > "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "10 an unknown schema is refused rather than guessed at" {
  write_contract "cat marker.txt"; enroll
  printf '{"schema":99,"whatever":true}\n' > "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "11 re-enrolling does not restart the sequence" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  [ "$(next_seq)" = 2 ]
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null 2>&1 || true
  [ "$(next_seq)" = 2 ]
}

# --- the central property ----------------------------------------------------

@test "12 PASS n then FAIL n+1 leaves the failure as the latest" {
  steerable_contract; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_pass ]
  local pass_seq; pass_seq=$(terminal_seq)

  rm -f "$FLAG"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_fail ]

  [ "$(terminal_status)" = candidate_fail ]
  [ "$(terminal_seq)" -gt "$pass_seq" ]
  [ "$(jq -r '.scopes.worktree.pending' "$(state_file)")" = null ]
}

@test "13 sequences are monotonic and never reused" {
  write_contract "cat marker.txt"; enroll
  local seen=""
  local i
  for i in 1 2 3; do
    local out; out=$(evaluate)
    local s; s=$(jq -r .sequence <<<"$out")
    case " $seen " in *" $s "*) return 1 ;; esac
    seen="$seen $s"
  done
  # strictly increasing
  local prev=0 s
  for s in $seen; do
    [ "$s" -gt "$prev" ] || return 1
    prev=$s
  done
  [ "$(next_seq)" -gt "$prev" ]
}

@test "14 next_sequence never decreases across a failed evaluation" {
  steerable_contract; enroll
  evaluate >/dev/null
  local before; before=$(next_seq)
  rm -f "$FLAG"
  evaluate >/dev/null || true
  [ "$(next_seq)" -gt "$before" ]
}

# --- scope independence ------------------------------------------------------

@test "15 worktree and staged carry independent sequence lines" {
  write_contract "cat marker.txt"; enroll
  libcall authority_state_reserve "$PID" staged run-s1 >/dev/null
  libcall authority_state_commit_terminal "$PID" staged candidate_pass run-s1 '{}' >/dev/null
  [ "$(jq -r '.scopes.staged.last_terminal.sequence' "$(state_file)")" = 1 ]
  [ "$(jq -r '.scopes.worktree.next_sequence' "$(state_file)")" = 1 ]
  [ "$(jq -r '.scopes.worktree.last_terminal' "$(state_file)")" = null ]

  evaluate >/dev/null
  [ "$(terminal_seq)" = 1 ]
  [ "$(jq -r '.scopes.staged.next_sequence' "$(state_file)")" = 2 ]
  [ "$(jq -r '.scopes.staged.last_terminal.sequence' "$(state_file)")" = 1 ]
}

@test "16 a staged pending does not suppress the worktree line" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  libcall authority_state_reserve "$PID" staged run-s1 >/dev/null
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = terminal ]
  run libcall authority_state_latest "$PID" staged
  [ "$(jq -r .state <<<"$output")" = unresolved ]
}

# --- pending suppression -----------------------------------------------------

@test "17 a pending suppresses the previous terminal for latest purposes" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  [ "$(terminal_status)" = candidate_pass ]
  libcall authority_state_reserve "$PID" worktree run-x >/dev/null
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
  [ "$(jq -r .suppressed.status <<<"$output")" = candidate_pass ]
}

@test "18 a pending is never reported as a pass" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  libcall authority_state_reserve "$PID" worktree run-x >/dev/null
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r '.state' <<<"$output")" != terminal ]
  [ "$(jq -r '.terminal // "absent"' <<<"$output")" = absent ]
}

# --- crash matrix ------------------------------------------------------------
#
# These kill a real process with SIGKILL at a synchronised point. Nothing in the
# production path knows it is being tested: the synchronisation is a sentinel
# the approved check itself writes, and the state on disk is what is inspected.

# Starts an evaluation in its own process group so the whole tree can be killed.
start_evaluation() {
  setsid bash -c 'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"$1\"}" \
    | bash "$2" evaluate --root "$3" >/dev/null 2>&1' _ "$WS" "$ISSUER" "$ROOT" &
  EVAL_PID=$!
  export EVAL_PID
}

# setsid forks, so the session it creates is not the job's own pid. The whole
# tree is killed by its process group id, which is what actually stops the
# check as well as the issuer.
kill_evaluation() {
  local pgid
  pgid=$(ps -o pgid= -p "$EVAL_PID" 2>/dev/null | tr -d ' ')
  if [ -n "$pgid" ]; then kill -9 -"$pgid" 2>/dev/null || true; fi
  kill -9 "$EVAL_PID" 2>/dev/null || true
  wait "$EVAL_PID" 2>/dev/null || true
}

wait_for() {
  local i
  for i in $(seq 1 300); do
    if eval "$1"; then return 0; fi
    sleep 0.1
  done
  return 1
}

@test "19 A: a crash before any reservation leaves the state untouched" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  local before; before=$(cat "$(state_file)")
  # Kill during request resolution, before a sequence can be reserved.
  start_evaluation
  kill_evaluation
  sleep 0.3
  [ "$(cat "$(state_file)")" = "$before" ] || {
    # A reservation may have won the race; then this case did not apply.
    [ "$(pending_seq)" != none ]
  }
  [ "$(terminal_status)" = candidate_pass ]
}

@test "20 B: a crash just after the reservation is durable leaves the pending" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal_seq)

  start_evaluation
  wait_for '[ "$(pending_seq)" != none ]'
  kill_evaluation

  [ "$(pending_seq)" != none ]
  [ "$(pending_seq)" -gt "$pass_seq" ]
  # The previous pass is suppressed while the pending stands.
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
}

@test "21 C: a crash while a check is executing leaves the pending" {
  steerable_contract; enroll
  touch "$SLOW"
  start_evaluation
  wait_for '[ -e "$RUNNING" ]'
  kill_evaluation

  [ "$(pending_seq)" != none ]
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
}

@test "22 C2: a crash during checks never leaves an older pass current" {
  steerable_contract; enroll
  evaluate >/dev/null
  [ "$(terminal_status)" = candidate_pass ]

  touch "$SLOW"; rm -f "$RUNNING"
  start_evaluation
  wait_for '[ -e "$RUNNING" ]'
  kill_evaluation

  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
  [ "$(jq -r .suppressed.status <<<"$output")" = candidate_pass ]
}

@test "23 D: a controlled incomplete burns the sequence and keeps the previous terminal" {
  # A total budget too small to finish is detected by the live process, which
  # is still holding the lock and knows nothing was verified.
  printf '[verify]\ntest = "sleep 6"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 30\ntotal_timeout_seconds = 2\n' \
    > "$WS/agent-md.toml"
  enroll
  seed_terminal candidate_pass
  local pass_seq before_next
  pass_seq=$(terminal_seq); before_next=$(next_seq)

  run evaluate
  [ "$(jq -r .status <<<"$output")" = refused ]

  [ "$(pending_seq)" = none ]
  [ "$(terminal_seq)" = "$pass_seq" ]
  [ "$(terminal_status)" = candidate_pass ]
  [ "$(next_seq)" -gt "$before_next" ]
}

@test "24 E: candidate_fail becomes the terminal and clears the pending" {
  write_contract "false"; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_fail ]
  [ "$(terminal_status)" = candidate_fail ]
  [ "$(pending_seq)" = none ]
  [ "$(terminal_seq)" = "$(jq -r .sequence <<<"$output")" ]
}

@test "25 F: candidate_pass becomes the terminal and clears the pending" {
  write_contract "cat marker.txt"; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_pass ]
  [ "$(terminal_status)" = candidate_pass ]
  [ "$(pending_seq)" = none ]
}

@test "26 G: identity_changed is terminal, supersedes, and is not candidate_fail" {
  write_contract "printf CHANGED > $WS/marker.txt"; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = identity_changed ]
  [ "$(terminal_status)" = identity_changed ]
  [ "$(terminal_status)" != candidate_fail ]
  [ "$(pending_seq)" = none ]
}

@test "27 G2: identity_changed supersedes a previous pass" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal_seq)
  [ "$(terminal_status)" = candidate_pass ]

  touch "$MUTATE"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = identity_changed ]
  [ "$(terminal_seq)" -gt "$pass_seq" ]
  [ "$(terminal_status)" = identity_changed ]
}

@test "28 H: an interrupted state replacement never leaves partial JSON" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  # Whatever is on disk must always parse and always validate.
  local i
  for i in 1 2 3; do
    evaluate >/dev/null
    jq -e . "$(state_file)" >/dev/null
  done
  run libcall authority_state_read "$PID"
  [ "$status" -eq 0 ]
  # No temporary state file is ever left behind next to it.
  run bash -c "ls -A '$ROOT/var/lib/agent-md/projects/$PID' | grep -c '^\\.agent-md-state'"
  [ "$output" = "0" ]
}

@test "29 I: a later evaluation takes over an abandoned pending atomically" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal_seq)

  touch "$SLOW"; rm -f "$RUNNING"
  start_evaluation
  wait_for '[ -e "$RUNNING" ]'
  kill_evaluation
  local abandoned; abandoned=$(pending_seq)
  [ "$abandoned" != none ]

  # Recovery: a new evaluation replaces the pending rather than clearing it.
  rm -f "$SLOW"
  run evaluate
  local recovered_seq; recovered_seq=$(jq -r .sequence <<<"$output")
  [ "$recovered_seq" -gt "$abandoned" ]
  [ "$(terminal_seq)" = "$recovered_seq" ]
  [ "$(pending_seq)" = none ]
  # The abandoned number was never handed out again.
  [ "$recovered_seq" != "$abandoned" ]
  [ "$pass_seq" -lt "$abandoned" ]
}

@test "30 I2: recovery never republishes the old terminal under the old sequence" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal_seq)

  touch "$SLOW"; rm -f "$RUNNING"
  start_evaluation
  wait_for '[ -e "$RUNNING" ]'
  kill_evaluation

  # Throughout recovery the old pass is never the answer.
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
  [ "$(jq -r '.terminal // "absent"' <<<"$output")" = absent ]
  [ "$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")" = "$pass_seq" ]
}

# --- concurrency -------------------------------------------------------------

@test "31 a second concurrent evaluation is refused and reserves nothing" {
  write_contract "touch $WS/running && sleep 20" 40; enroll
  start_evaluation
  wait_for '[ -e "$WS/running" ]'
  local held_next held_pending
  held_next=$(next_seq); held_pending=$(pending_seq)

  run evaluate
  [ "$(jq -r .status <<<"$output")" = refused ]
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_EVALUATION_IN_PROGRESS ]
  [ "$(jq -r .sequence <<<"$output")" = null ]

  # It changed nothing.
  [ "$(next_seq)" = "$held_next" ]
  [ "$(pending_seq)" = "$held_pending" ]

  kill_evaluation
}

@test "32 the refused evaluation creates no run of its own" {
  write_contract "touch $WS/running && sleep 20" 40; enroll
  start_evaluation
  wait_for '[ -e "$WS/running" ]'
  local before; before=$(ls "$ROOT/var/lib/agent-md/projects/$PID/runs" | wc -l)
  evaluate >/dev/null || true
  [ "$(ls "$ROOT/var/lib/agent-md/projects/$PID/runs" | wc -l)" = "$before" ]
  kill_evaluation
}

# --- reserved is not published ----------------------------------------------

@test "33 a reserved sequence is consumed even when it never becomes terminal" {
  write_contract "cat marker.txt"; enroll
  local before; before=$(next_seq)
  libcall authority_state_reserve "$PID" worktree run-burn >/dev/null
  libcall authority_state_release_pending "$PID" worktree run-burn
  [ "$(next_seq)" -gt "$before" ]
  [ "$(pending_seq)" = none ]
  [ "$(terminal_seq)" = none ]
}

@test "34 sequences may have gaps" {
  write_contract "cat marker.txt"; enroll
  libcall authority_state_reserve "$PID" worktree burn-1 >/dev/null
  libcall authority_state_release_pending "$PID" worktree burn-1
  libcall authority_state_reserve "$PID" worktree burn-2 >/dev/null
  libcall authority_state_release_pending "$PID" worktree burn-2
  run evaluate
  [ "$(jq -r .sequence <<<"$output")" = 3 ]
  [ "$(terminal_seq)" = 3 ]
  # 1 and 2 were consumed and never published.
  [ "$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")" != 1 ]
}

@test "35 a terminal commit refuses a run that does not hold the reservation" {
  write_contract "cat marker.txt"; enroll
  libcall authority_state_reserve "$PID" worktree run-a >/dev/null
  run libcall authority_state_commit_terminal "$PID" worktree candidate_pass run-b '{}'
  [ "$status" -ne 0 ]
  [ "$(pending_seq)" != none ]
}

@test "36 a release refuses a run that does not hold the reservation" {
  write_contract "cat marker.txt"; enroll
  libcall authority_state_reserve "$PID" worktree run-a >/dev/null
  run libcall authority_state_release_pending "$PID" worktree run-b
  [ "$status" -ne 0 ]
  [ "$(pending_seq)" != none ]
}

@test "37 an unknown terminal status cannot be committed" {
  write_contract "cat marker.txt"; enroll
  libcall authority_state_reserve "$PID" worktree run-a >/dev/null
  run libcall authority_state_commit_terminal "$PID" worktree authenticated_pass run-a '{}'
  [ "$status" -ne 0 ]
}

# --- filesystem safety -------------------------------------------------------

@test "38 the state file is authority-owned and not world-writable" {
  write_contract "cat marker.txt"; enroll
  local mode; mode=$(stat -c %a "$(state_file)")
  [ "$mode" = 644 ]
  case "$mode" in *[2367]) return 1 ;; esac
}

@test "39 a symlinked state file is refused" {
  write_contract "cat marker.txt"; enroll
  local target="$ROOT/elsewhere.json"
  cp "$(state_file)" "$target"
  rm -f "$(state_file)"
  ln -s "$target" "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

@test "40 the project directory is left sealed after a state write" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  local mode; mode=$(stat -c %a "$ROOT/var/lib/agent-md/projects/$PID")
  [ "$mode" = 555 ]
}

# --- no signing, key or receipt capability entered C4b -----------------------

@test "41 the issuer still does not read, name or open the key" {
  run grep -nE 'keys_dir|issuer-.*\.key|authority_current_key_id|pkeyutl|genpkey' "$ISSUER"
  [ "$status" -ne 0 ]
}

@test "42 run-check still does not touch the key or the state" {
  run grep -nE 'keys_dir|issuer-.*\.key|pkeyutl|openssl|state\.json|next_sequence' "$RUNCHECK"
  [ "$status" -ne 0 ]
}

@test "43 the state file carries no key material and no key id" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  run grep -qE 'BEGIN |PRIVATE|key_id|issuer-' "$(state_file)"
  [ "$status" -ne 0 ]
}

@test "44 no signature or receipt field entered the state" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  run bash -c "jq -r '[paths|join(\".\")]|join(\"\n\")' '$(state_file)' | grep -cE 'signature|receipt|signed|authenticated'"
  [ "$output" = "0" ]
}

@test "45 candidate_pass is never described as evidence or a receipt" {
  write_contract "cat marker.txt"; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = candidate_pass ]
  [ "$(jq -r '.status | test("authentic|attested|verified|signed|receipt")' <<<"$output")" = false ]
  [[ "$(jq -r .reason <<<"$output")" == *"not evidence"* ]]
}

@test "46 no key was created or read by an evaluation" {
  write_contract "cat marker.txt"; enroll
  evaluate >/dev/null
  # C4b runs without a key at all; nothing in the flow requires one.
  [ -z "$(ls -A "$ROOT/var/lib/agent-md/keys")" ]
}

@test "47 the issuer declares no signing exit code or status" {
  run grep -nE 'EX_[A-Z_]*SIGN|authenticated_pass|receipt_published' "$ISSUER"
  [ "$status" -ne 0 ]
}
