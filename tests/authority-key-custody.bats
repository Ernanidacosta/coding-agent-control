#!/usr/bin/env bats
#
# C4a: custody of the issuer signing key.
#
# Nothing in this slice signs anything. These tests pin where the key lives,
# who can reach it, how it comes into existence and what a crash halfway
# through can leave behind. They also pin the absence of signing, so the next
# slice has to add it deliberately rather than inherit it.

load authority-helpers

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  RUNCHECK="$BATS_TEST_DIRNAME/../examples/local-issuer/run-check"
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  ROOT="$(mktemp -d)"
  export AUTHORITY ISSUER RUNCHECK LIB ROOT
  KEYS="$ROOT/var/lib/agent-md/keys"
  export KEYS
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
}

teardown() {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT"
}

install_key() {
  run bash "$AUTHORITY" install-key --root "$ROOT"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  KEY_ID=$(cat "$KEYS/current")
  PRIV="$KEYS/issuer-$KEY_ID.key"
  PUB="$KEYS/issuer-$KEY_ID.pub"
  export KEY_ID PRIV PUB
}

mode_of_path() { stat -c %a "$1"; }

# --- layout and derivation ---------------------------------------------------

@test "1 install does not create a key" {
  [ -d "$KEYS" ]
  [ -z "$(ls -A "$KEYS")" ]
}

@test "2 install-key creates exactly the private key, public key and pointer" {
  install_key
  [ "$(ls -A "$KEYS" | wc -l)" -eq 3 ]
  [ -f "$PRIV" ]
  [ -f "$PUB" ]
  [ -f "$KEYS/current" ]
}

@test "3 key id is the full sha256 of the DER SPKI" {
  install_key
  local expected
  expected=$(openssl pkey -pubin -in "$PUB" -outform DER | sha256sum | cut -d' ' -f1)
  [ "$KEY_ID" = "$expected" ]
}

@test "4 key id is 64 hex characters, not a truncation" {
  install_key
  [ "${#KEY_ID}" -eq 64 ]
  [[ "$KEY_ID" =~ ^[0-9a-f]{64}$ ]]
}

@test "5 the published public key is derived from the published private key" {
  install_key
  local derived published
  derived=$(openssl pkey -in "$PRIV" -pubout -outform DER | sha256sum | cut -d' ' -f1)
  published=$(openssl pkey -pubin -in "$PUB" -outform DER | sha256sum | cut -d' ' -f1)
  [ "$derived" = "$published" ]
}

@test "6 the pair actually works as an Ed25519 signing pair" {
  install_key
  printf 'payload' > "$ROOT/msg"
  openssl pkeyutl -sign -inkey "$PRIV" -rawin -in "$ROOT/msg" -out "$ROOT/sig"
  [ "$(stat -c %s "$ROOT/sig")" -eq 64 ]
  run openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$ROOT/msg" -sigfile "$ROOT/sig"
  [ "$status" -eq 0 ]
}

@test "7 a tampered payload does not verify under the published public key" {
  install_key
  printf 'payload' > "$ROOT/msg"
  openssl pkeyutl -sign -inkey "$PRIV" -rawin -in "$ROOT/msg" -out "$ROOT/sig"
  printf 'payloae' > "$ROOT/msg"
  run openssl pkeyutl -verify -pubin -inkey "$PUB" -rawin -in "$ROOT/msg" -sigfile "$ROOT/sig"
  [ "$status" -ne 0 ]
}

# --- permissions -------------------------------------------------------------

@test "8 the key directory is 0700" {
  install_key
  [ "$(mode_of_path "$KEYS")" = 700 ]
}

@test "9 the private key is 0600" {
  install_key
  [ "$(mode_of_path "$PRIV")" = 600 ]
}

@test "10 the public key is 0644" {
  install_key
  [ "$(mode_of_path "$PUB")" = 644 ]
}

@test "11 no key file is a symlink" {
  install_key
  [ ! -L "$PRIV" ]
  [ ! -L "$PUB" ]
  [ ! -L "$KEYS/current" ]
}

# --- the pointer -------------------------------------------------------------

@test "12 current names a key id and holds no key material" {
  install_key
  [ "$(cat "$KEYS/current")" = "$KEY_ID" ]
  run grep -q 'PRIVATE KEY' "$KEYS/current"
  [ "$status" -ne 0 ]
}

@test "13 there is no mutable current.pem" {
  install_key
  [ ! -e "$KEYS/current.pem" ]
  [ ! -e "$KEYS/issuer.key" ]
  [ ! -e "$KEYS/issuer.pem" ]
}

@test "14 a malformed pointer reads as no active key rather than as a path" {
  install_key
  printf '../../../etc/passwd\n' > "$KEYS/current"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no issuer key is installed"* ]]
}

@test "15 a truncated key id in the pointer is rejected" {
  install_key
  printf '%s\n' "${KEY_ID:0:16}" > "$KEYS/current"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
}

@test "16 a pointer that is a symlink is refused" {
  install_key
  rm "$KEYS/current"
  ln -s "$PRIV" "$KEYS/current"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
}

# --- idempotence -------------------------------------------------------------

@test "17 repeating install-key does not regenerate the key" {
  install_key
  local before_id before_material
  before_id="$KEY_ID"
  before_material=$(sha256sum "$PRIV" | cut -d' ' -f1)

  run bash "$AUTHORITY" install-key --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"already installed"* ]]

  [ "$(cat "$KEYS/current")" = "$before_id" ]
  [ "$(sha256sum "$KEYS/issuer-$before_id.key" | cut -d' ' -f1)" = "$before_material" ]
  [ "$(ls -A "$KEYS" | wc -l)" -eq 3 ]
}

@test "18 repeating install-key does not create a second key" {
  install_key
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  [ "$(ls "$KEYS"/issuer-*.key | wc -l)" -eq 1 ]
}

@test "19 an ordinary install after install-key leaves the key untouched" {
  install_key
  local before
  before=$(sha256sum "$PRIV" | cut -d' ' -f1)
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  [ "$(sha256sum "$PRIV" | cut -d' ' -f1)" = "$before" ]
  [ "$(cat "$KEYS/current")" = "$KEY_ID" ]
}

@test "20 install-key refuses when the key directory is absent" {
  rmdir "$KEYS"
  run bash "$AUTHORITY" install-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"run install first"* ]]
}

# --- partial creation --------------------------------------------------------

@test "21 key material without a pointer is not an active key" {
  install_key
  rm "$KEYS/current"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"no issuer key is installed"* ]]
}

@test "22 install-key refuses to disturb existing material it did not publish" {
  install_key
  # The pointer is gone but the material remains, which is what a crash between
  # the two renames leaves behind. A fresh key id would be generated and
  # published; the orphan must not be silently overwritten or adopted.
  rm "$KEYS/current"
  run bash "$AUTHORITY" install-key --root "$ROOT"
  [ "$status" -eq 0 ]
  local new_id
  new_id=$(cat "$KEYS/current")
  [ "$new_id" != "$KEY_ID" ]
  [ -f "$KEYS/issuer-$KEY_ID.key" ]
  [ "$(mode_of_path "$KEYS/issuer-$KEY_ID.key")" = 600 ]
}

@test "23 a published key that fails its custody check is refused, not used" {
  install_key
  chmod 0644 "$PRIV"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"mode"* ]]
}

@test "24 a published key whose private material vanished is refused" {
  install_key
  rm "$PRIV"
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"private key is absent"* ]]
}

@test "25 install-key leaves no staging directory behind" {
  install_key
  run bash -c "ls -A '$KEYS' | grep -c '^\\.'"
  [ "$output" = "0" ]
}

@test "26 a failed generation publishes nothing" {
  # An openssl that cannot produce a key stands in for any mid-generation
  # failure. The live layout must be exactly as install left it.
  local fake="$ROOT/fakebin"
  mkdir -p "$fake"
  printf '#!/bin/bash\nexit 1\n' > "$fake/openssl"
  chmod 0755 "$fake/openssl"
  run env PATH="$fake:$PATH" bash "$AUTHORITY" install-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [ -z "$(ls -A "$KEYS")" ]
}

# --- the key never leaves custody -------------------------------------------

@test "27 install-key never prints private key material" {
  install_key
  local body
  body=$(grep -v -- '-----' "$PRIV" | tr -d '\n')
  [ -n "$body" ]
  run bash "$AUTHORITY" install-key --root "$ROOT"
  [[ "$output" != *"$body"* ]]
  [[ "$output" != *"PRIVATE KEY"* ]]
}

@test "28 show-key never prints private key material" {
  install_key
  local body
  body=$(grep -v -- '-----' "$PRIV" | tr -d '\n')
  run bash "$AUTHORITY" show-key --root "$ROOT"
  [ "$status" -eq 0 ]
  [[ "$output" != *"$body"* ]]
  [[ "$output" != *"PRIVATE KEY"* ]]
}

@test "29 the private key never reaches a command line" {
  # openssl writes the key through its own -out. If the key were ever produced
  # on stdout and passed onward, it would be visible in a process listing.
  run grep -nE 'genpkey.*(\$\(|`)' "$LIB"
  [ "$status" -ne 0 ]
  run grep -n 'pkeyutl' "$LIB"
  [ "$status" -ne 0 ]
}

@test "29b the ordinary installer has no key logic at all" {
  # install.sh is the installer a user runs for the agent configuration. A key
  # must never come into existence through it.
  run grep -nE 'genpkey|install-key|issuer-.*\.key|keys/' "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -ne 0 ]
}

@test "30 no key material is committed to the repository" {
  run bash -c "git -C '$BATS_TEST_DIRNAME/..' ls-files | grep -E '\\.key$|issuer-.*\\.pub$'"
  [ "$status" -ne 0 ]
}

@test "31 the repository contains no PEM private key" {
  run bash -c "git -C '$BATS_TEST_DIRNAME/..' grep -l 'BEGIN PRIVATE KEY' -- . ':!tests/*'"
  [ "$status" -ne 0 ]
}

# --- rotation is prepared, not performed ------------------------------------

@test "32 rotate-key does not rotate" {
  install_key
  local before
  before=$(sha256sum "$PRIV" | cut -d' ' -f1)
  run bash "$AUTHORITY" rotate-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"not implemented"* ]]
  [ "$(cat "$KEYS/current")" = "$KEY_ID" ]
  [ "$(sha256sum "$PRIV" | cut -d' ' -f1)" = "$before" ]
  [ "$(ls "$KEYS"/issuer-*.key | wc -l)" -eq 1 ]
}

@test "33 rotate-key describes the model without a key installed" {
  run bash "$AUTHORITY" rotate-key --root "$ROOT"
  [ "$status" -ne 0 ]
  [[ "$output" == *"current key: none"* ]]
  [ -z "$(ls -A "$KEYS")" ]
}

@test "34 nothing rotates as a side effect of another command" {
  install_key
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  bash "$AUTHORITY" show-key --root "$ROOT" >/dev/null
  [ "$(cat "$KEYS/current")" = "$KEY_ID" ]
  [ "$(ls "$KEYS"/issuer-*.key | wc -l)" -eq 1 ]
}

# --- no signing capability yet ----------------------------------------------

@test "35 the issuer does not read, name or use the key" {
  run grep -nE 'keys_dir|issuer-.*\.key|authority_current_key_id|pkeyutl' "$ISSUER"
  [ "$status" -ne 0 ]
}

@test "36 run-check does not read, name or use the key" {
  run grep -nE 'keys_dir|issuer-.*\.key|authority_current_key_id|pkeyutl|openssl' "$RUNCHECK"
  [ "$status" -ne 0 ]
}

@test "37 no descending hop exists in the key custody path" {
  # The key is opened by install-key alone, which runs as the authority and
  # execs nothing. If a hop ever appeared in this path it would run with the
  # key already resolved.
  #
  # Comments and diagnostics are stripped first: install-key tells an operator
  # to re-run under sudo, which is advice to a human, not a hop this program
  # takes. What matters is whether one of these words is ever a command.
  run bash -c "sed -n '/^cmd_install_key/,/^}/p;/^cmd_show_key/,/^}/p;/^cmd_rotate_key/,/^}/p' '$AUTHORITY' \
    | grep -vE '^[[:space:]]*#' | sed 's/\"[^\"]*\"//g' \
    | grep -nE '(^|[;&|[:space:]])(sudo|exec|su)([[:space:]]|$)'"
  [ "$status" -ne 0 ]
}

@test "38 signing, sequence and receipts are still absent as capability" {
  # The issuer's comments say it does none of this. The comments are not the
  # evidence; the executable lines are.
  run bash -c "grep -hvE '^[[:space:]]*#' '$ISSUER' '$RUNCHECK' \
    | grep -nE 'last_terminal|sequence|receipt|signature'"
  [ "$status" -ne 0 ]
}
