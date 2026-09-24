#!/usr/bin/env bats
#
# C4c: canonical payload, Ed25519 signature, receipt publication.
#
# The property this slice adds is that a completed evaluation produces an
# artefact someone who did not watch it happen can verify with a public key.
# The property it must not add is a way to ask the authority to sign anything
# else, so a good part of this file is about what cannot be reached.

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
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  KEYS="$ROOT/var/lib/agent-md/keys"
  KEY_ID=$(cat "$KEYS/current")
  PRIV="$KEYS/issuer-$KEY_ID.key"
  PUB="$KEYS/issuer-$KEY_ID.pub"
  export KEYS KEY_ID PRIV PUB

  CONTROLS=$(fixture_controls)
  FLAG="$CONTROLS/flag"; SLOW="$CONTROLS/slow"; MUTATE="$CONTROLS/mutate"; RUNNING=""
  export FLAG SLOW MUTATE RUNNING
  printf 'ok\n' > "$FLAG"
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

steerable_contract() {
  printf '[verify]\ntest = "%s"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 60\ntotal_timeout_seconds = 180\n' \
    "touch /runtime/running; cat $FLAG || exit 1; if [ -e $MUTATE ]; then mkfifo /runtime/mutation; cat /runtime/mutation >/dev/null; fi; if [ -e $SLOW ]; then sleep 40; fi; true" \
    > "$WS/agent-md.toml"
}

enroll() {
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PID
  RUNNING="$ROOT/var/tmp/agent-md-runner/$PID/test/running"
  export RUNNING
  PROJ="$ROOT/var/lib/agent-md/projects/$PID"
  export PROJ
  [ "$(jq -r .status "$PROJ/enrollment.json")" = eligible ] || {
    enrollment_diagnosis "$PROJ/enrollment.json" >&2; return 1; }
}

request() { printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$WS"; }
evaluate() { fixture_evaluate; }
state_file() { printf '%s/state.json' "$PROJ"; }
receipt_of() { printf '%s/receipts/worktree/%s.json' "$PROJ" "$1"; }
terminal() { jq -c --arg k "$1" '.scopes.worktree.last_terminal[$k]' "$(state_file)"; }
unseal() { chmod u+w "$PROJ" 2>/dev/null || true; }

libcall() {
  ROOT="$ROOT" bash -c '
    set -u; . "$1"; ROOT="$2"; PROGRAM=test; shift 2; "$@"
  ' _ "$LIB" "$ROOT" "$@"
}

verify_receipt() { libcall authority_verify_receipt_signature "$1" "$2"; }

# --- no signing oracle -------------------------------------------------------

@test "1 no subcommand or flag can ask the authority to sign something" {
  run bash -c "grep -nE -- '--sign(-run|-summary|-file)?\\b|--receipt-from-run' '$ISSUER' '$AUTHORITY' '$LIB'"
  [ "$status" -ne 0 ]
  run bash "$ISSUER" sign --root "$ROOT"
  [ "$status" -ne 0 ]
  run bash "$AUTHORITY" sign-receipt "$ROOT"
  [ "$status" -ne 0 ]
}

@test "2 signing happens only inside evaluate" {
  # The only call site of the signing step is the conclusion of an evaluation.
  run bash -c "grep -n 'issuer_publish_signed_terminal' '$ISSUER' | grep -v '^[0-9]*:#' | wc -l"
  [ "$output" -eq 3 ]
  run bash -c "sed -n '/^cmd_eligibility/,/^}/p' '$ISSUER' | grep -c 'issuer_publish_signed_terminal'"
  [ "$output" = "0" ]
}

@test "3 an existing run on disk cannot be turned into a receipt later" {
  steerable_contract; enroll
  evaluate >/dev/null
  local run_id; run_id=$(jq -r '.scopes.worktree.last_terminal.run_id' "$(state_file)")
  # There is no interface that accepts a run id and produces a receipt.
  run bash -c "grep -nE 'run.id' '$AUTHORITY' | grep -iE 'sign|receipt'"
  [ "$status" -ne 0 ]
  [ -n "$run_id" ]
}

@test "4 the caller cannot supply fingerprints, sequence, status or key_id" {
  steerable_contract; enroll
  local field
  for field in '"fingerprints":{}' '"sequence":99' '"status":"pass"' '"key_id":"x"' '"receipt":{}'; do
    run bash -c "printf '{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"$WS\",$field}' \
      | bash '$ISSUER' evaluate --root '$ROOT' 2>/dev/null"
    [ "$(jq -r .reason_code <<<"$output")" = REFUSED_MALFORMED_REQUEST ]
  done
}

# --- payload and signature ---------------------------------------------------

@test "5 a passing evaluation publishes a signed receipt" {
  steerable_contract; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = authenticated_pass ]
  local seq; seq=$(jq -r .sequence <<<"$output")
  [ -f "$(receipt_of "$seq")" ]
  verify_receipt "$(receipt_of "$seq")" "$PROJ/trusted-keys/$KEY_ID.pub"
}

@test "6 the receipt carries the signed payload schema and public vocabulary" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  [ "$(jq -r .schema "$r")" = 1 ]
  [ "$(jq -r .status "$r")" = pass ]
  [ "$(jq -r .issuer.kind "$r")" = local-authority ]
  [ "$(jq -r .issuer.key_id "$r")" = "$KEY_ID" ]
  [ "$(jq -r .attempt.sequence "$r")" = 1 ]
  [ "$(jq -r .scope "$r")" = worktree ]
  [ "$(jq -r .workspace "$r")" = "$WS" ]
  [ "$(jq -r .project_id "$r")" = "$PID" ]
}

@test "7 all four fingerprints are signed" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  jq -e '[.fingerprints.source, .fingerprints.contract, .fingerprints.control, .fingerprints.mechanism]
    | all(.[]; type == "object" and (.value | type == "string" and length == 64))' "$r" >/dev/null
}

@test "8 coverage is signed with command identity, not the literal command" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  jq -e '.checks | all(.[]; has("name") and has("requirement") and has("origin")
    and has("command_identity") and has("execution") and has("exit_code")
    and (has("command") | not))' "$r" >/dev/null
  # command_identity is reconstructible from the contract the fingerprint binds.
  local run_id identity expected actual
  run_id=$(jq -r '.scopes.worktree.last_terminal.run_id' "$(state_file)")
  identity="$PROJ/runs/$run_id/identity.json"
  expected=$(jq -r '.manifests.contract.checks[] | select(.name=="test") | .command' "$identity" \
    | tr -d '\n' | sha256sum | cut -d' ' -f1)
  actual=$(jq -r '.checks[] | select(.name=="test") | .command_identity' "$r")
  [ "$expected" = "$actual" ]
}

@test "9 no timestamp and no command output is signed" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  run bash -c "jq -r '[paths|join(\".\")]|join(\"\n\")' '$r' | grep -ciE 'time|date|stamp|output|excerpt|stdout|stderr'"
  [ "$output" = "0" ]
}

@test "10 the signature covers the payload without the authentication envelope" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  # Reconstructing the canonical bytes and verifying by hand agrees.
  local canonical sig
  canonical="$ROOT/canonical"; sig="$ROOT/sig.bin"
  jq -cS 'del(.authentication)' "$r" | tr -d '\n' > "$canonical"
  jq -r '.authentication.value' "$r" | base64 -d > "$sig"
  run openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$canonical" -sigfile "$sig"
  [ "$status" -eq 0 ]
}

@test "11 canonical bytes are deterministic across reconstructions" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r a b
  r=$(receipt_of 1)
  a=$(jq -cS 'del(.authentication)' "$r" | tr -d '\n' | sha256sum)
  b=$(jq -cS 'del(.authentication)' "$r" | tr -d '\n' | sha256sum)
  [ "$a" = "$b" ]
  # And no trailing newline crept into what is signed.
  [ "$(jq -cS 'del(.authentication)' "$r" | tr -d '\n' | tail -c1 | xxd -p)" != "0a" ]
}

@test "12 the authentication envelope names the same key it was signed with" {
  steerable_contract; enroll
  evaluate >/dev/null
  local r; r=$(receipt_of 1)
  [ "$(jq -r .authentication.key_id "$r")" = "$(jq -r .issuer.key_id "$r")" ]
  [ "$(jq -r .authentication.format "$r")" = ed25519-openssl-rawin ]
  [ "$(jq -r '.authentication.value | length' "$r")" = 88 ]
}

@test "13 a modified payload does not verify" {
  steerable_contract; enroll
  evaluate >/dev/null
  jq -c '.status = "fail"' "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
}

@test "14 a modified signature does not verify" {
  steerable_contract; enroll
  evaluate >/dev/null
  jq -c '.authentication.value = "AAAA" + (.authentication.value[4:])' "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
}

@test "15 the wrong public key does not verify" {
  steerable_contract; enroll
  evaluate >/dev/null
  openssl genpkey -algorithm ed25519 -out "$ROOT/other.key" 2>/dev/null
  openssl pkey -in "$ROOT/other.key" -pubout -out "$ROOT/other.pub" 2>/dev/null
  run verify_receipt "$(receipt_of 1)" "$ROOT/other.pub"
  [ "$status" -ne 0 ]
}

@test "16 a receipt claiming another key_id does not verify against it" {
  steerable_contract; enroll
  evaluate >/dev/null
  jq -c '.issuer.key_id = "0000000000000000000000000000000000000000000000000000000000000000"' \
    "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
}

# --- PASS / FAIL mapping -----------------------------------------------------

@test "17 a failing evaluation also publishes a signed receipt" {
  steerable_contract; enroll
  rm -f "$FLAG"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = authenticated_fail ]
  local seq; seq=$(jq -r .sequence <<<"$output")
  [ "$(jq -r .status "$(receipt_of "$seq")")" = fail ]
  verify_receipt "$(receipt_of "$seq")" "$PUB"
}

@test "18 an authenticated FAIL supersedes an earlier authenticated PASS" {
  steerable_contract; enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = authenticated_pass ]
  local pass_seq; pass_seq=$(jq -r .sequence <<<"$output")

  rm -f "$FLAG"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = authenticated_fail ]
  local fail_seq; fail_seq=$(jq -r .sequence <<<"$output")

  [ "$fail_seq" -gt "$pass_seq" ]
  [ "$(terminal sequence)" = "$fail_seq" ]
  [ "$(terminal status)" = '"candidate_fail"' ]
  # The earlier PASS receipt is still a valid signature. It is simply not
  # current any more, and the state is what says so.
  verify_receipt "$(receipt_of "$pass_seq")" "$PUB"
  [ "$(jq -r .status "$(receipt_of "$pass_seq")")" = pass ]
}

@test "19 identity_changed publishes no receipt and does not open the key" {
  steerable_contract; enroll
  touch "$MUTATE"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = identity_changed ]
  [ "$(jq -r .receipt <<<"$output")" = null ]
  [ ! -d "$PROJ/receipts" ] || [ -z "$(ls -A "$PROJ/receipts/worktree" 2>/dev/null)" ]
  [ "$(terminal receipt)" = null ]
  [ "$(terminal key_id)" = null ]
  # No trusted key was published either: nothing was signed.
  [ ! -d "$PROJ/trusted-keys" ] || [ -z "$(ls -A "$PROJ/trusted-keys" 2>/dev/null)" ]
}

@test "20 an incomplete evaluation publishes no receipt" {
  printf '[verify]\ntest = "sleep 6"\n\n[verify.policy]\nrequired = ["test"]\ntimeout_seconds = 30\ntotal_timeout_seconds = 2\n' \
    > "$WS/agent-md.toml"
  enroll
  run evaluate
  [ "$(jq -r .status <<<"$output")" = refused ]
  [ ! -d "$PROJ/receipts" ] || [ -z "$(ls -A "$PROJ/receipts/worktree" 2>/dev/null)" ]
  [ "$(jq -r '.scopes.worktree.last_terminal' "$(state_file)")" = null ]
}

# --- state ------------------------------------------------------------------

@test "21 last_terminal names the receipt and the key that signed it" {
  steerable_contract; enroll
  evaluate >/dev/null
  [ "$(terminal key_id)" = "\"$KEY_ID\"" ]
  [ "$(jq -r '.scopes.worktree.last_terminal.receipt.path' "$(state_file)")" = "$(receipt_of 1)" ]
  [ "$(jq -r '.scopes.worktree.last_terminal.receipt.schema' "$(state_file)")" = 1 ]
}

@test "22 the state carries no signature and no private material" {
  steerable_contract; enroll
  evaluate >/dev/null
  run grep -qE 'BEGIN |PRIVATE|authentication|signature' "$(state_file)"
  [ "$status" -ne 0 ]
}

@test "23 latest reports whether the terminal is authenticated" {
  steerable_contract; enroll
  evaluate >/dev/null
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = terminal ]
  [ "$(jq -r .authenticated <<<"$output")" = true ]
}

# --- migration from C4b ------------------------------------------------------

@test "24 a C4b terminal migrates without becoming authenticated" {
  steerable_contract; enroll
  unseal
  cat > "$(state_file)" <<'JSON'
{"schema":2,"scopes":{
  "worktree":{"next_sequence":8,"pending":null,
    "last_terminal":{"sequence":7,"run_id":"old","scope":"worktree",
                     "status":"candidate_pass","fingerprints":{}}},
  "staged":{"next_sequence":1,"pending":null,"last_terminal":null}}}
JSON
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = terminal ]
  [ "$(jq -r .authenticated <<<"$output")" = false ]
  [ "$(jq -r .terminal.receipt <<<"$output")" = null ]
  [ "$(jq -r .terminal.key_id <<<"$output")" = null ]
}

@test "25 migration preserves next_sequence and never reuses an old number" {
  steerable_contract; enroll
  unseal
  cat > "$(state_file)" <<'JSON'
{"schema":2,"scopes":{
  "worktree":{"next_sequence":8,"pending":null,
    "last_terminal":{"sequence":7,"run_id":"old","scope":"worktree",
                     "status":"candidate_pass","fingerprints":{}}},
  "staged":{"next_sequence":1,"pending":null,"last_terminal":null}}}
JSON
  run evaluate
  [ "$(jq -r .sequence <<<"$output")" = 8 ]
  [ "$(jq -r .status <<<"$output")" = authenticated_pass ]
  [ "$(jq -r '.schema' "$(state_file)")" = 3 ]
  [ "$(terminal sequence)" = 8 ]
  [ ! -e "$(receipt_of 7)" ]
}

@test "26 a legacy candidate_pass never becomes reusable without a new evaluation" {
  steerable_contract; enroll
  unseal
  cat > "$(state_file)" <<'JSON'
{"schema":2,"scopes":{
  "worktree":{"next_sequence":8,"pending":null,
    "last_terminal":{"sequence":7,"run_id":"old","scope":"worktree",
                     "status":"candidate_pass","fingerprints":{}}},
  "staged":{"next_sequence":1,"pending":null,"last_terminal":null}}}
JSON
  # Migrating alone publishes nothing.
  libcall authority_state_read "$PID" >/dev/null
  [ ! -d "$PROJ/receipts" ] || [ -z "$(ls -A "$PROJ/receipts/worktree" 2>/dev/null)" ]
}

@test "27 a legacy fail or identity_changed also stays unauthenticated" {
  steerable_contract; enroll
  unseal
  local st
  for st in candidate_fail identity_changed; do
    cat > "$(state_file)" <<JSON
{"schema":2,"scopes":{
  "worktree":{"next_sequence":8,"pending":null,
    "last_terminal":{"sequence":7,"run_id":"old","scope":"worktree",
                     "status":"$st","fingerprints":{}}},
  "staged":{"next_sequence":1,"pending":null,"last_terminal":null}}}
JSON
    run libcall authority_state_latest "$PID" worktree
    [ "$(jq -r .authenticated <<<"$output")" = false ]
  done
}

@test "28 a state naming a receipt without a key is refused" {
  steerable_contract; enroll
  unseal
  jq -c '.scopes.worktree.last_terminal = {sequence:1, run_id:"r", scope:"worktree",
    status:"candidate_pass", fingerprints:{}, receipt:{path:"/x",schema:1}, key_id:null}
    | .scopes.worktree.next_sequence = 2' "$(state_file)" > "$ROOT/s.json"
  cat "$ROOT/s.json" > "$(state_file)"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_STATE_UNUSABLE ]
}

# --- receipt persistence -----------------------------------------------------

@test "29 receipts are immutable and authority-owned" {
  steerable_contract; enroll
  evaluate >/dev/null
  [ "$(stat -c %a "$(receipt_of 1)")" = 444 ]
  [ "$(stat -c %a "$PROJ/receipts/worktree")" = 555 ]
  [ ! -L "$(receipt_of 1)" ]
}

@test "30 an existing sequence is never overwritten" {
  steerable_contract; enroll
  evaluate >/dev/null
  local before; before=$(sha256sum "$(receipt_of 1)" | cut -d' ' -f1)
  printf '{"tampered":true}\n' > "$ROOT/fake.json"
  run libcall authority_publish_receipt "$PID" worktree 1 "$ROOT/fake.json"
  [ "$status" -ne 0 ]
  [ "$(sha256sum "$(receipt_of 1)" | cut -d' ' -f1)" = "$before" ]
}

@test "31 the trusted key is published and hashes to its own name" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pub; pub="$PROJ/trusted-keys/$KEY_ID.pub"
  [ -f "$pub" ]
  [ "$(stat -c %a "$pub")" = 444 ]
  [ "$(openssl pkey -pubin -in "$pub" -outform DER | sha256sum | cut -d' ' -f1)" = "$KEY_ID" ]
  cmp -s "$pub" "$PUB"
}

@test "32 republishing an identical trusted key is a no-op" {
  steerable_contract; enroll
  evaluate >/dev/null
  local before; before=$(sha256sum "$PROJ/trusted-keys/$KEY_ID.pub" | cut -d' ' -f1)
  run libcall authority_publish_trusted_key "$PID" "$KEY_ID"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$PROJ/trusted-keys/$KEY_ID.pub" | cut -d' ' -f1)" = "$before" ]
}

@test "33 a different key under an existing key_id is refused" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pub; pub="$PROJ/trusted-keys/$KEY_ID.pub"
  chmod u+w "$PROJ/trusted-keys" "$pub"
  openssl genpkey -algorithm ed25519 -out "$ROOT/o.key" 2>/dev/null
  openssl pkey -in "$ROOT/o.key" -pubout -out "$pub" 2>/dev/null
  run libcall authority_publish_trusted_key "$PID" "$KEY_ID"
  [ "$status" -ne 0 ]
}

@test "34 a public key that does not hash to the key id is never published" {
  steerable_contract; enroll
  openssl genpkey -algorithm ed25519 -out "$ROOT/o.key" 2>/dev/null
  chmod u+w "$KEYS"
  openssl pkey -in "$ROOT/o.key" -pubout -out "$KEYS/issuer-$KEY_ID.pub" 2>/dev/null
  run libcall authority_publish_trusted_key "$PID" "$KEY_ID"
  [ "$status" -ne 0 ]
  [ ! -e "$PROJ/trusted-keys/$KEY_ID.pub" ]
}

# --- key lifecycle -----------------------------------------------------------

@test "35 the private key is not open while a check is running" {
  steerable_contract; enroll
  touch "$SLOW"; rm -f "$RUNNING"
  setsid bash -c 'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"$1\"}" \
    | bash "$2" evaluate --root "$3" >/dev/null 2>&1' _ "$WS" "$ISSUER" "$ROOT" &
  local bg=$!
  local i
  for i in $(seq 1 300); do [ -e "$RUNNING" ] && break; sleep 0.1; done
  # Nothing anywhere on this machine holds the private key open.
  local holders
  holders=$(find /proc -maxdepth 3 -path '*/fd/*' -lname "$PRIV" 2>/dev/null | wc -l)
  local pgid; pgid=$(ps -o pgid= -p "$bg" 2>/dev/null | tr -d ' ')
  [ -n "$pgid" ] && kill -9 -"$pgid" 2>/dev/null
  kill -9 "$bg" 2>/dev/null || true; wait "$bg" 2>/dev/null || true
  [ "$holders" -eq 0 ]
}

@test "36 signing is refused when the key is missing, and nothing is superseded" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq before_next
  pass_seq=$(terminal sequence); before_next=$(jq -r '.scopes.worktree.next_sequence' "$(state_file)")

  chmod u+w "$KEYS"; rm -f "$KEYS/current"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_SIGNING_UNAVAILABLE ]
  # Post-reservation infrastructure failure: burned sequence, pending resolved,
  # previous terminal untouched.
  [ "$(jq -r '.scopes.worktree.pending' "$(state_file)")" = null ]
  [ "$(terminal sequence)" = "$pass_seq" ]
  [ "$(jq -r '.scopes.worktree.next_sequence' "$(state_file)")" -gt "$before_next" ]
}

@test "37 an insecure key is refused rather than used" {
  steerable_contract; enroll
  chmod u+w "$KEYS"; chmod 0644 "$PRIV"
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_SIGNING_UNAVAILABLE ]
  [ ! -d "$PROJ/receipts" ] || [ -z "$(ls -A "$PROJ/receipts/worktree" 2>/dev/null)" ]
}

@test "38 a key filed under the wrong id is refused" {
  steerable_contract; enroll
  chmod u+w "$KEYS"
  openssl genpkey -algorithm ed25519 -out "$ROOT/o.key" 2>/dev/null
  openssl pkey -in "$ROOT/o.key" -pubout -out "$PUB" 2>/dev/null
  run evaluate
  [ "$(jq -r .reason_code <<<"$output")" = REFUSED_SIGNING_UNAVAILABLE ]
}

@test "39 an unsigned pass is never produced when signing is unavailable" {
  steerable_contract; enroll
  chmod u+w "$KEYS"; rm -f "$KEYS/current"
  run evaluate
  [ "$(jq -r .status <<<"$output")" != authenticated_pass ]
  [ "$(jq -r .status <<<"$output")" != candidate_pass ]
  [ "$(jq -r '.scopes.worktree.last_terminal' "$(state_file)")" = null ]
}

# --- crash matrix ------------------------------------------------------------

@test "40 D: an orphan receipt is not current and is never adopted" {
  steerable_contract; enroll
  evaluate >/dev/null

  # Exactly what a crash between the receipt rename and the state commit leaves:
  # a receipt on disk for a reserved sequence, with the pending still standing.
  local seq
  libcall authority_state_reserve "$PID" worktree orphan-run >/dev/null
  seq=$(jq -r '.scopes.worktree.pending.sequence' "$(state_file)")
  jq -c --argjson s "$seq" '.attempt.sequence = $s' "$(receipt_of 1)" > "$ROOT/orphan.json"
  libcall authority_publish_receipt "$PID" worktree "$seq" "$ROOT/orphan.json"
  [ -f "$(receipt_of "$seq")" ]

  # It is not current: the pending suppresses everything underneath it.
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]

  # A later evaluation does not adopt it; it reserves its own number.
  run evaluate
  local new_seq; new_seq=$(jq -r .sequence <<<"$output")
  [ "$new_seq" -gt "$seq" ]
  [ "$(terminal sequence)" = "$new_seq" ]
  [ "$(jq -r '.scopes.worktree.last_terminal.receipt.path' "$(state_file)")" = "$(receipt_of "$new_seq")" ]
  # The orphan is still on disk and still not current.
  [ -f "$(receipt_of "$seq")" ]
}

@test "41 A: a crash before the key is opened leaves the pending and no receipt" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal sequence)

  touch "$SLOW"; rm -f "$RUNNING"
  setsid bash -c 'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"$1\"}" \
    | bash "$2" evaluate --root "$3" >/dev/null 2>&1' _ "$WS" "$ISSUER" "$ROOT" &
  local bg=$!
  local i
  for i in $(seq 1 300); do [ -e "$RUNNING" ] && break; sleep 0.1; done
  local pgid; pgid=$(ps -o pgid= -p "$bg" 2>/dev/null | tr -d ' ')
  [ -n "$pgid" ] && kill -9 -"$pgid" 2>/dev/null
  kill -9 "$bg" 2>/dev/null || true; wait "$bg" 2>/dev/null || true

  [ "$(jq -r '.scopes.worktree.pending | type' "$(state_file)")" = object ]
  local abandoned; abandoned=$(jq -r '.scopes.worktree.pending.sequence' "$(state_file)")
  [ ! -e "$(receipt_of "$abandoned")" ]
  [ "$(terminal sequence)" = "$pass_seq" ]
  run libcall authority_state_latest "$PID" worktree
  [ "$(jq -r .state <<<"$output")" = unresolved ]
}

@test "42 E: the state file is always whole and always validates" {
  steerable_contract; enroll
  local i
  for i in 1 2 3; do
    evaluate >/dev/null || true
    jq -e . "$(state_file)" >/dev/null
    libcall authority_state_read "$PID" >/dev/null
  done
  run bash -c "ls -A '$PROJ' | grep -c '^\\.agent-md-state'"
  [ "$output" = "0" ]
}

@test "43 H: an identity change before signing leaves no receipt and burns nothing extra" {
  steerable_contract; enroll
  evaluate >/dev/null
  local pass_seq; pass_seq=$(terminal sequence)
  touch "$MUTATE"
  run evaluate
  [ "$(jq -r .status <<<"$output")" = identity_changed ]
  local seq; seq=$(jq -r .sequence <<<"$output")
  [ ! -e "$(receipt_of "$seq")" ]
  [ "$(terminal sequence)" = "$seq" ]
  [ "$(terminal sequence)" -gt "$pass_seq" ]
  [ "$(terminal receipt)" = null ]
}

# --- threat matrix -----------------------------------------------------------

@test "44 a receipt from another project cannot become current here" {
  steerable_contract; enroll
  evaluate >/dev/null
  # The receipt binds project_id; rewriting it invalidates the signature.
  jq -c '.project_id = "00000000-0000-0000-0000-000000000000"' "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
}

@test "45 a receipt from another scope cannot become current here" {
  steerable_contract; enroll
  evaluate >/dev/null
  jq -c '.scope = "staged"' "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
}

@test "46 a workspace path mismatch stays a signed mismatch" {
  steerable_contract; enroll
  evaluate >/dev/null
  jq -c '.workspace = "/somewhere/else"' "$(receipt_of 1)" > "$ROOT/t.json"
  run verify_receipt "$ROOT/t.json" "$PUB"
  [ "$status" -ne 0 ]
  # The genuine receipt still binds the real workspace.
  [ "$(jq -r .workspace "$(receipt_of 1)")" = "$WS" ]
}

@test "47 the receipt directory is not writable by the evaluated workspace" {
  steerable_contract; enroll
  evaluate >/dev/null
  # 0555 directory, 0444 file: a same-uid staging fixture still cannot append
  # or replace without first defeating the mode the authority set.
  [ "$(stat -c %a "$PROJ/receipts/worktree")" = 555 ]
  [ "$(stat -c %a "$(receipt_of 1)")" = 444 ]
}

@test "48 run-check has no receipt, signing or state capability" {
  run bash -c "grep -hvE '^[[:space:]]*#' '$RUNCHECK' \
    | grep -nE 'receipt|signature|openssl|state\\.json|next_sequence|pending|trusted-keys'"
  [ "$status" -ne 0 ]
}

@test "49 the private key is never named in a receipt or in the state" {
  steerable_contract; enroll
  evaluate >/dev/null
  run grep -qE 'BEGIN |PRIVATE|\.key' "$(receipt_of 1)"
  [ "$status" -ne 0 ]
  run grep -qE 'BEGIN |PRIVATE|\.key' "$(state_file)"
  [ "$status" -ne 0 ]
}

@test "50 the product reuses a receipt only through the validator" {
  # Reuse arrived with receipt-first completion. What must stay true is that no
  # hook verifies a signature, resolves latest, or judges coverage itself: the
  # decision has exactly one implementation and everything else consumes it.
  local hooks="$BATS_TEST_DIRNAME/../.claude/hooks"
  run bash -c "cat '$hooks/'*.sh '$BATS_TEST_DIRNAME/../.codex/hooks/'*.sh \
      '$BATS_TEST_DIRNAME/../.githooks/'* '$BATS_TEST_DIRNAME/../.agent-md/bin/'*.sh 2>/dev/null \
    | grep -vE '^[[:space:]]*#' \
    | grep -nE 'pkeyutl|authority_verify_receipt_signature|last_terminal|trusted-keys/'"
  [ "$status" -ne 0 ]

  # The one place completion consults is the validator, by its installed path.
  run bash -c "grep -vE '^[[:space:]]*#' '$hooks/_lib.sh' | grep -c 'receipt-verify.sh'"
  [ "$output" = "1" ]
}
