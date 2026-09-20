#!/usr/bin/env bats
#
# C4d: unprivileged validation of an authenticated receipt.
#
# The validator answers one question — "is there an authenticated receipt that
# is current and still applies?" — and it must answer it without privilege,
# without writing anything, and without ever letting the receipt, the file
# system layout or the caller choose the answer.
#
# A note on the fixture. In production the authority store is owned by the
# service account, so the developer simply cannot write it. A single-user
# staging tree has no second account, so the same property is reproduced the
# way the rest of this suite reproduces it: the store is made read-only for the
# user running the test. That is the exact condition the validator checks
# ("this user cannot write it"), and the integration harness proves it again
# with real separate accounts.

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  VERIFY="$BATS_TEST_DIRNAME/../examples/local-issuer/receipt-verify.sh"
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  TOOLCHAIN="$(mktemp -d)"
  export AUTHORITY ISSUER VERIFY LIB ROOT WS TOOLCHAIN

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
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  KEYS="$ROOT/var/lib/agent-md/keys"
  KEY_ID=$(cat "$KEYS/current")
  export KEYS KEY_ID

  FLAG="$ROOT/flag"; export FLAG
  printf 'ok\n' > "$FLAG"
  printf '[verify]\ntest = "cat %s"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 30\ntotal_timeout_seconds = 120\n' \
    "$FLAG" > "$WS/agent-md.toml"

  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  PROJ="$ROOT/var/lib/agent-md/projects/$PID"
  export PID PROJ
  seal
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

# Makes the authority store unwritable by this user, which is what separate
# accounts achieve in production.
# The directory matters as much as the files: anything the user can write into
# can be replaced, so the validator refuses evidence that sits in a writable
# directory. Sealing has to restore the directory too.
seal() {
  chmod 0444 "$PROJ/enrollment.json" "$PROJ/state.json" 2>/dev/null || true
  chmod 0555 "$PROJ" 2>/dev/null || true
}
unseal() { chmod u+w "$PROJ" "$PROJ/enrollment.json" "$PROJ/state.json" 2>/dev/null || true; }

evaluate() {
  unseal
  printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$WS" \
    | bash "$ISSUER" evaluate --root "$ROOT" 2>/dev/null
  local rc=$?
  seal
  return $rc
}

verify() { bash "$VERIFY" "$WS" worktree --root "$ROOT" 2>/dev/null; }
verify_status() { verify | jq -r .status; }
verify_rc() { verify >/dev/null 2>&1; echo $?; }

receipt_of() { printf '%s/receipts/worktree/%s.json' "$PROJ" "$1"; }
state_file() { printf '%s/state.json' "$PROJ"; }

# Rewrites a published receipt in place, which the authority's own permissions
# would forbid; used to prove the validator rejects what it is handed.
rewrite_receipt() {
  local seq="$1" filter="$2" path; path=$(receipt_of "$seq")
  chmod u+w "$PROJ/receipts/worktree" "$path"
  jq -cS "$filter" "$path" > "$path.tmp" && mv "$path.tmp" "$path"
  chmod 0444 "$path"; chmod 0555 "$PROJ/receipts/worktree"
}

rewrite_state() {
  unseal
  jq -c "$@" "$(state_file)" > "$(state_file).tmp" && mv "$(state_file).tmp" "$(state_file)"
  seal
}

# --- the answer it is for ----------------------------------------------------

@test "1 a current authenticated pass is reusable" {
  evaluate >/dev/null
  run verify
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
  [ "$(jq -r .authentic <<<"$output")" = true ]
  [ "$(jq -r .current <<<"$output")" = true ]
  [ "$(jq -r .applicable <<<"$output")" = true ]
  [ "$(verify_rc)" -eq 0 ]
}

@test "2 a current authenticated failure is not reusable" {
  rm -f "$FLAG"
  evaluate >/dev/null || true
  run verify
  [ "$(jq -r .status <<<"$output")" = current_fail ]
  [ "$(jq -r .authentic <<<"$output")" = true ]
  [ "$(verify_rc)" -ne 0 ]
}

@test "3 only reusable_pass exits zero" {
  evaluate >/dev/null
  [ "$(verify_rc)" -eq 0 ]
  printf 'MUTATED\n' > "$WS/marker.txt"
  [ "$(verify_rc)" -ne 0 ]
}

@test "4 stdout is exactly one control-plane object" {
  evaluate >/dev/null
  run bash -c "bash '$VERIFY' '$WS' worktree --root '$ROOT' 2>/dev/null | jq -s 'length'"
  [ "$output" = "1" ]
  run bash -c "bash '$VERIFY' '$WS' worktree --root '$ROOT' 2>/dev/null | jq -e '.schema == 1 and (.status|type)==\"string\"'"
  [ "$status" -eq 0 ]
}

# --- the caller supplies nothing ---------------------------------------------

@test "5 the caller cannot name the receipt, sequence, key or project" {
  evaluate >/dev/null
  local opt
  for opt in --receipt --sequence --key --project-id --fingerprint --trust; do
    run bash "$VERIFY" "$WS" worktree "$opt" x --root "$ROOT"
    [ "$status" -eq 2 ]
  done
}

@test "6 no such option exists in the program at all" {
  run grep -nE -- '--receipt\b|--sequence\b|--key\b|--project-id\b|--fingerprint\b|--trust\b' "$VERIFY"
  [ "$status" -ne 0 ]
}

@test "7 an unsupported scope is refused" {
  evaluate >/dev/null
  run bash "$VERIFY" "$WS" staged --root "$ROOT"
  [ "$status" -eq 2 ]
  run bash "$VERIFY" "$WS" nonsense --root "$ROOT"
  [ "$status" -eq 2 ]
}

# --- signature and key -------------------------------------------------------

@test "8 a modified signature is invalid evidence, not absent evidence" {
  evaluate >/dev/null
  rewrite_receipt 1 '.authentication.value = "AAAA" + (.authentication.value[4:])'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
  [ "$(jq -r .authentic <<<"$output")" = false ]
}

@test "9 a modified payload is invalid" {
  evaluate >/dev/null
  rewrite_receipt 1 '.status = "pass" | .run_id = .run_id'
  # A no-op rewrite keeps it valid; a real change must not.
  [ "$(verify_status)" = reusable_pass ]
  rewrite_receipt 1 '.attempt.sequence = 1 | .workspace = .workspace + ""'
  [ "$(verify_status)" = reusable_pass ]
  rewrite_receipt 1 '.checks[0].exit_code = 0 | .protocol = 2'
  [ "$(verify_status)" = invalid_receipt ]
}

@test "10 a substituted trusted key is rejected by its own hash" {
  evaluate >/dev/null
  local pub="$PROJ/trusted-keys/$KEY_ID.pub"
  chmod u+w "$PROJ/trusted-keys" "$pub"
  openssl genpkey -algorithm ed25519 -out "$ROOT/o.key" 2>/dev/null
  openssl pkey -in "$ROOT/o.key" -pubout -out "$pub" 2>/dev/null
  chmod 0444 "$pub"; chmod 0555 "$PROJ/trusted-keys"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
  [[ "$(jq -r .reason <<<"$output")" == *"hash"* ]]
}

@test "11 a receipt claiming a different key_id is rejected" {
  evaluate >/dev/null
  rewrite_receipt 1 '.issuer.key_id = "0000000000000000000000000000000000000000000000000000000000000000"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "12 the envelope key_id must match the signed key_id" {
  evaluate >/dev/null
  rewrite_receipt 1 '.authentication.key_id = "0000000000000000000000000000000000000000000000000000000000000000"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "13 a non-Ed25519 trusted key is refused" {
  evaluate >/dev/null
  local pub="$PROJ/trusted-keys/$KEY_ID.pub"
  chmod u+w "$PROJ/trusted-keys" "$pub"
  openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out "$ROOT/r.key" 2>/dev/null
  openssl pkey -in "$ROOT/r.key" -pubout -out "$pub" 2>/dev/null
  chmod 0444 "$pub"; chmod 0555 "$PROJ/trusted-keys"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "14 the validator never reads the private key directory" {
  evaluate >/dev/null
  run grep -nE 'keys_dir|authority_private_key_path|issuer-.*\.key' "$VERIFY"
  [ "$status" -ne 0 ]
  # And it still works when that directory is unreadable.
  chmod 0000 "$KEYS"
  run verify
  chmod 0700 "$KEYS"
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
}

# --- filesystem trust --------------------------------------------------------

@test "15 a receipt that is a symlink is refused" {
  evaluate >/dev/null
  local path; path=$(receipt_of 1)
  cp "$path" "$ROOT/elsewhere.json"
  chmod u+w "$PROJ/receipts/worktree"; rm -f "$path"
  ln -s "$ROOT/elsewhere.json" "$path"
  chmod 0555 "$PROJ/receipts/worktree"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "16 a state that is a symlink is refused" {
  evaluate >/dev/null
  unseal
  cp "$(state_file)" "$ROOT/state-elsewhere.json"
  rm -f "$(state_file)"; ln -s "$ROOT/state-elsewhere.json" "$(state_file)"
  run verify
  [ "$(jq -r .status <<<"$output")" = unavailable ]
}

@test "17 a state this user can write is refused" {
  evaluate >/dev/null
  chmod u+w "$(state_file)"
  run verify
  [ "$(jq -r .status <<<"$output")" = unavailable ]
  [[ "$(jq -r .reason <<<"$output")" == *"writable"* ]]
}

@test "18 a receipt this user can write is refused" {
  evaluate >/dev/null
  chmod u+w "$PROJ/receipts/worktree" "$(receipt_of 1)"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "19 an enrollment this user can write is refused" {
  evaluate >/dev/null
  chmod u+w "$PROJ/enrollment.json"
  run verify
  [ "$(jq -r .status <<<"$output")" = unavailable ]
}

@test "20 a trusted key this user can write is refused" {
  evaluate >/dev/null
  chmod u+w "$PROJ/trusted-keys" "$PROJ/trusted-keys/$KEY_ID.pub"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

# --- bindings ----------------------------------------------------------------

@test "21 a receipt issued for another project is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.project_id = "00000000-0000-0000-0000-000000000000"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "22 a receipt issued for another workspace path is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.workspace = "/somewhere/else"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "23 a receipt issued for another scope is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.scope = "staged"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "24 a receipt from a different run than the state records is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.run_id = "00000000-0000-0000-0000-000000000000"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "25 a clone at a different path does not inherit the receipt" {
  evaluate >/dev/null
  local clone; clone=$(mktemp -d)
  cp -r "$WS/." "$clone/"
  run bash "$VERIFY" "$clone" worktree --root "$ROOT"
  [ "$(jq -r .status <<<"$output")" = no_evidence ]
  rm -rf "$clone"
}

# --- freshness ---------------------------------------------------------------

@test "26 a pass superseded by a newer failure is not reusable" {
  evaluate >/dev/null
  local pass_seq; pass_seq=$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")
  rm -f "$FLAG"
  evaluate >/dev/null || true
  local fail_seq; fail_seq=$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")
  [ "$fail_seq" -gt "$pass_seq" ]

  run verify
  [ "$(jq -r .status <<<"$output")" = current_fail ]
  # The older pass receipt is still on disk and still verifies cryptographically.
  [ -f "$(receipt_of "$pass_seq")" ]
  run bash -c ". '$LIB'; ROOT='$ROOT'; authority_verify_receipt_signature '$(receipt_of "$pass_seq")' '$KEYS/issuer-$KEY_ID.pub'"
  [ "$status" -eq 0 ]
}

@test "27 a pending reservation suppresses an otherwise perfect pass" {
  evaluate >/dev/null
  [ "$(verify_status)" = reusable_pass ]
  unseal
  bash -c ". '$LIB'; ROOT='$ROOT'; PROGRAM=t; authority_state_reserve '$PID' worktree crash-run" >/dev/null
  seal
  run verify
  [ "$(jq -r .status <<<"$output")" = unresolved_pending ]
  [ "$(verify_rc)" -ne 0 ]
}

@test "28 recovery after a pending restores a reusable answer" {
  evaluate >/dev/null
  unseal
  bash -c ". '$LIB'; ROOT='$ROOT'; PROGRAM=t; authority_state_reserve '$PID' worktree crash-run" >/dev/null
  seal
  [ "$(verify_status)" = unresolved_pending ]
  evaluate >/dev/null
  run verify
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
}

@test "29 an orphan receipt is never adopted" {
  evaluate >/dev/null
  local first; first=$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")

  # A receipt on disk for a reserved sequence the state never published.
  unseal
  bash -c ". '$LIB'; ROOT='$ROOT'; PROGRAM=t; authority_state_reserve '$PID' worktree orphan-run" >/dev/null
  local orphan; orphan=$(jq -r '.scopes.worktree.pending.sequence' "$(state_file)")
  jq -cS --argjson s "$orphan" '.attempt.sequence = $s' "$(receipt_of "$first")" > "$ROOT/orphan.json"
  bash -c ". '$LIB'; ROOT='$ROOT'; PROGRAM=t; authority_publish_receipt '$PID' worktree '$orphan' '$ROOT/orphan.json'"
  seal
  [ -f "$(receipt_of "$orphan")" ]

  [ "$(verify_status)" = unresolved_pending ]

  # After recovery the orphan is still not the answer.
  evaluate >/dev/null
  local newest; newest=$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")
  [ "$newest" -gt "$orphan" ]
  run verify
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
  [ "$(jq -r .sequence <<<"$output")" = "$newest" ]
  [ -f "$(receipt_of "$orphan")" ]
}

@test "30 a legacy unauthenticated terminal is never reusable" {
  evaluate >/dev/null
  rewrite_state '.schema = 2
    | .scopes.worktree.last_terminal = (.scopes.worktree.last_terminal | del(.receipt) | del(.key_id))'
  run verify
  [ "$(jq -r .status <<<"$output")" = unauthenticated_terminal ]
  [ "$(verify_rc)" -ne 0 ]
}

@test "31 no terminal result at all is no evidence" {
  run verify
  [ "$(jq -r .status <<<"$output")" = no_evidence ]
}

@test "32 the state decides latest, not the newest file" {
  evaluate >/dev/null
  local current; current=$(jq -r '.scopes.worktree.last_terminal.sequence' "$(state_file)")
  # A later-numbered, newer receipt appears on disk. The state still names the
  # old one, and the state is what counts.
  local future=$(( current + 5 ))
  jq -cS --argjson s "$future" '.attempt.sequence = $s' "$(receipt_of "$current")" > "$ROOT/future.json"
  unseal
  bash -c ". '$LIB'; ROOT='$ROOT'; PROGRAM=t; authority_publish_receipt '$PID' worktree '$future' '$ROOT/future.json'"
  seal
  run verify
  [ "$(jq -r .sequence <<<"$output")" = "$current" ]
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
}

@test "33 a state naming a receipt outside the receipt store is refused" {
  evaluate >/dev/null
  cp "$(receipt_of 1)" "$ROOT/moved.json"; chmod 0444 "$ROOT/moved.json"
  rewrite_state '.scopes.worktree.last_terminal.receipt.path = $p' --arg p "$ROOT/moved.json"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "34 a sequence mismatch between state and receipt is stale" {
  evaluate >/dev/null
  rewrite_state '.scopes.worktree.next_sequence = 9
    | .scopes.worktree.last_terminal.sequence = 7'
  run verify
  # The state now points at receipts/worktree/7.json, which does not exist.
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

# --- live identity -----------------------------------------------------------

@test "35 a changed source makes the receipt stale but still authentic" {
  evaluate >/dev/null
  printf 'MUTATED\n' > "$WS/marker.txt"
  run verify
  [ "$(jq -r .status <<<"$output")" = stale ]
  [ "$(jq -r .authentic <<<"$output")" = true ]
  [ "$(jq -r .current <<<"$output")" = true ]
  [ "$(jq -r .applicable <<<"$output")" = false ]
}

@test "36 restoring the source makes it reusable again" {
  evaluate >/dev/null
  printf 'MUTATED\n' > "$WS/marker.txt"
  [ "$(verify_status)" = stale ]
  printf 'ORIGINAL\n' > "$WS/marker.txt"
  [ "$(verify_status)" = reusable_pass ]
}

@test "37 a changed contract makes the receipt stale" {
  evaluate >/dev/null
  printf '[verify]\ntest = "cat %s"\nlint = "true"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 30\ntotal_timeout_seconds = 120\n' \
    "$FLAG" > "$WS/agent-md.toml"
  run verify
  [ "$(jq -r .status <<<"$output")" = stale ]
}

@test "38 a changed mechanism makes the receipt stale" {
  evaluate >/dev/null
  printf '#!/bin/bash\n# changed\n' > "$WS/.claude/hooks/_lib.sh"
  run verify
  [ "$(jq -r .status <<<"$output")" = stale ]
}

@test "39 a changed control record makes the receipt stale" {
  evaluate >/dev/null
  printf 'schema = 1\nrisk = "low"\n' > "$WS/.project-control.toml"
  run verify
  [ "$(jq -r .status <<<"$output")" = stale ]
}

# --- coverage ----------------------------------------------------------------

@test "40 a receipt missing a currently required check is insufficient" {
  evaluate >/dev/null
  rewrite_receipt 1 '.checks = []'
  run verify
  # The receipt no longer matches what the state signed, so it fails earlier.
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "41 a required check that did not return zero cannot cover" {
  evaluate >/dev/null
  # Recompute what a real receipt with a non-zero required check looks like by
  # asking the authority for one, then confirming it is not a pass.
  rm -f "$FLAG"
  evaluate >/dev/null || true
  run verify
  [ "$(jq -r .status <<<"$output")" = current_fail ]
}

@test "42 a check whose command identity does not match is not coverage" {
  evaluate >/dev/null
  [ "$(verify_status)" = reusable_pass ]
  # Changing the command changes both the contract fingerprint and the expected
  # identity, so the receipt stops applying.
  printf '[verify]\ntest = "cat %s "\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 30\ntotal_timeout_seconds = 120\n' \
    "$FLAG" > "$WS/agent-md.toml"
  run verify
  [ "$(jq -r .status <<<"$output")" = stale ]
}

@test "43 independent and approval are never satisfied by a receipt" {
  evaluate >/dev/null
  [ "$(verify_status)" = reusable_pass ]
  # Raising the risk to critical adds external requirements a receipt cannot
  # supply. The contract change makes it stale first, which is also correct;
  # what matters is that it never becomes reusable.
  printf 'schema = 1\nrisk = "critical"\n' > "$WS/.project-control.toml"
  run verify
  [ "$(jq -r .status <<<"$output")" != reusable_pass ]
  [ "$(verify_rc)" -ne 0 ]
}

# --- malformed input ---------------------------------------------------------

@test "44 a receipt that is not JSON is invalid" {
  evaluate >/dev/null
  local path; path=$(receipt_of 1)
  chmod u+w "$PROJ/receipts/worktree" "$path"
  printf 'not json\n' > "$path"
  chmod 0444 "$path"; chmod 0555 "$PROJ/receipts/worktree"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "45 a receipt in a non-canonical serialization is refused" {
  evaluate >/dev/null
  local path; path=$(receipt_of 1)
  chmod u+w "$PROJ/receipts/worktree" "$path"
  jq . "$path" > "$path.tmp" && mv "$path.tmp" "$path"   # pretty-printed
  chmod 0444 "$path"; chmod 0555 "$PROJ/receipts/worktree"
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
  [[ "$(jq -r .reason <<<"$output")" == *"canonical"* ]]
}

@test "46 an unsupported receipt schema is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.schema = 2'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "47 an unknown top-level field is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '. + {extra: "field"}'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "48 an unknown field inside a check is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.checks[0] += {sneaky: true}'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "49 a duplicated check name is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.checks += [.checks[0]]'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

@test "50 a candidate vocabulary inside a receipt is refused" {
  evaluate >/dev/null
  rewrite_receipt 1 '.status = "candidate_pass"'
  run verify
  [ "$(jq -r .status <<<"$output")" = invalid_receipt ]
}

# --- read-only and unprivileged ----------------------------------------------

@test "51 the validator writes nothing" {
  evaluate >/dev/null
  local before after
  before=$(find "$PROJ" -type f -exec sha256sum {} \; | sort | sha256sum)
  verify >/dev/null
  after=$(find "$PROJ" -type f -exec sha256sum {} \; | sort | sha256sum)
  [ "$before" = "$after" ]

  # The digest above is weak on its own: a sealed store makes a write fail
  # whether or not the program attempts one. So also require that no line
  # redirects into, creates in, or removes from the authority store. The only
  # paths the program writes are its own temporary files.
  run bash -c "grep -vE '^[[:space:]]*#' '$VERIFY' \
    | grep -nE '(>|>>)[[:space:]]*\"?\\$\(projects_dir|(>|>>)[[:space:]]*\"?\\$(PROJ|RV_RECEIPT_PATH)|\
authority_state_write|authority_publish_receipt|authority_publish_trusted_key|\
\bmkdir\b|\btee\b|\bchmod\b|\bchown\b|\bmv\b[^|]*projects_dir'"
  [ "$status" -ne 0 ]
}

@test "52 the validator never calls sudo or the issuer" {
  # The header says it does none of this. The executable lines are the evidence.
  run bash -c "grep -vE '^[[:space:]]*#' '$VERIFY' | grep -nE '\bsudo\b|agent-md-issuer|prepare-run|install-key'"
  [ "$status" -ne 0 ]
}

@test "53 the validator does not source the workspace's own hooks" {
  # Trusting a receipt by running code out of the repository it describes would
  # let that repository decide its own verdict.
  run grep -nE '\$\{?WS\}?/\.claude|workspace.*/\.claude/hooks|\. .*\$workspace' "$VERIFY"
  [ "$status" -ne 0 ]
  # It uses the vendored copy instead.
  run grep -c 'phase-a-source.sh' "$VERIFY"
  [ "$output" -ge 1 ]
}

@test "54 a hostile workspace hook is never executed during validation" {
  local marker; marker="$ROOT/EXECUTED"
  evaluate >/dev/null
  printf '#!/bin/bash\ntouch "%s"\n' "$marker" > "$WS/.claude/hooks/_lib.sh"
  verify >/dev/null || true
  [ ! -e "$marker" ]
}

@test "55 validation works with no write access anywhere in the store" {
  evaluate >/dev/null
  chmod -R a-w "$PROJ" 2>/dev/null || true
  run verify
  [ "$(jq -r .status <<<"$output")" = reusable_pass ]
  chmod -R u+w "$PROJ" 2>/dev/null || true
}

@test "56 an authority that is not installed reports unavailable, not a pass" {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT/var/lib/agent-md/projects"
  run verify
  [ "$(jq -r .status <<<"$output")" = unavailable ]
  [ "$(verify_rc)" -ne 0 ]
}
