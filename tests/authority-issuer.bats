#!/usr/bin/env bats
#
# C2 issuer runtime. It answers eligibility and nothing stronger: there is no
# path here that executes a command, signs, allocates a sequence or writes a
# receipt. These tests pin the refusals, the read-only guarantee, and the
# absence of those capabilities.

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  MARKER="$(mktemp -u)"
  export AUTHORITY ISSUER ROOT WS MARKER
  build_workspace
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
}

teardown() {
  chmod -R u+w "$ROOT" 2>/dev/null || true
  rm -rf "$ROOT" "$WS"
  rm -f "$MARKER"
}

build_workspace() {
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  cat > "$WS/agent-md.toml" <<'TOML'
[verify]
lint = "shellcheck ."
test = "bats tests/"

[verify.policy]
required = ["lint", "test"]
TOML
  local hook
  for hook in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\ntouch "%s"\n' "$MARKER" > "$WS/$hook"
    chmod +x "$WS/$hook"
  done
}

enroll() { bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --yes "$@" >/dev/null; }

ask() {
  local body="${1:-}"
  [ -n "$body" ] || body=$(printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$(realpath "$WS")")
  # Separate streams: stdout must hold exactly one JSON object, and the human
  # diagnostic belongs on stderr.
  run --separate-stderr bash -c 'printf "%s" "$1" | bash "$2" eligibility --root "$3"' _ "$body" "$ISSUER" "$ROOT"
}

project_dir() {
  find "$ROOT/var/lib/agent-md/projects" -maxdepth 1 -mindepth 1 -type d | head -1
}

# stdout must always be exactly one JSON object.
assert_single_object() {
  printf '%s' "$output" | jq -e -s 'length == 1 and (.[0] | type) == "object"' >/dev/null
}

assert_refused() {
  local code="$1"
  [ "$status" -ne 0 ]
  [ -n "$stderr" ]
  assert_single_object
  printf '%s' "$output" | jq -e --arg c "$code" '.status == "refused" and .reason_code == $c' >/dev/null
}

@test "1 a request carrying a command is rejected" {
  enroll
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s","command":"true"}' "$(realpath "$WS")")"
  assert_refused REFUSED_MALFORMED_REQUEST
  [ "$status" -eq 2 ]
}

@test "2 a request carrying checks is rejected" {
  enroll
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s","checks":[{"command":"true"}]}' "$(realpath "$WS")")"
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "3 a request carrying fingerprints is rejected" {
  enroll
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s","fingerprints":{"source":"deadbeef"}}' "$(realpath "$WS")")"
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "4 a request naming a project id is rejected" {
  enroll
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s","project_id":"anything"}' "$(realpath "$WS")")"
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "5 a relative workspace is rejected" {
  enroll
  ask '{"protocol":1,"scope":"worktree","workspace":"relative/path"}'
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "6 malformed JSON is rejected" {
  enroll
  ask '{"protocol":1,'
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "7 an array instead of an object is rejected" {
  enroll
  ask '[{"protocol":1,"scope":"worktree","workspace":"/tmp"}]'
  assert_refused REFUSED_MALFORMED_REQUEST
}

@test "8 an unsupported protocol is rejected" {
  enroll
  ask "$(printf '{"protocol":99,"scope":"worktree","workspace":"%s"}' "$(realpath "$WS")")"
  assert_refused REFUSED_UNSUPPORTED_PROTOCOL
  [ "$status" -eq 3 ]
}

@test "9 an unknown scope is rejected and staged is not supported yet" {
  enroll
  ask "$(printf '{"protocol":1,"scope":"nonsense","workspace":"%s"}' "$(realpath "$WS")")"
  assert_refused REFUSED_UNSUPPORTED_SCOPE
  [ "$status" -eq 4 ]
  ask "$(printf '{"protocol":1,"scope":"staged","workspace":"%s"}' "$(realpath "$WS")")"
  assert_refused REFUSED_UNSUPPORTED_SCOPE
}

@test "10 a symlinked workspace canonicalizes to the enrolled path" {
  enroll
  local link; link="$(mktemp -u)"
  ln -s "$WS" "$link"
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$link")"
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e --arg ws "$(realpath "$WS")" '.status == "eligible" and .workspace == $ws' >/dev/null
  rm -f "$link"
}

@test "11 a clone at another path is not enrolled" {
  enroll
  local clone; clone="$(mktemp -d)"
  cp -a "$WS/." "$clone/"
  ask "$(printf '{"protocol":1,"scope":"worktree","workspace":"%s"}' "$(realpath "$clone")")"
  assert_refused REFUSED_NOT_ENROLLED
  [ "$status" -eq 5 ]
  rm -rf "$clone"
}

@test "12 an ambiguous enrollment fails closed" {
  enroll
  local dir second
  dir=$(project_dir)
  second="$ROOT/var/lib/agent-md/projects/duplicate-id"
  mkdir -p "$second"
  jq '.project_id = "duplicate-id"' "$dir/enrollment.json" > "$second/enrollment.json"
  ask
  assert_refused REFUSED_AMBIGUOUS_ENROLLMENT
  [ "$status" -eq 6 ]
}

@test "13 a changed contract is refused" {
  enroll
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > "$WS/agent-md.toml"
  ask
  assert_refused REFUSED_CONTRACT_CHANGED
  [ "$status" -eq 7 ]
  printf '%s' "$output" | jq -e '.contract.state == "changed"' >/dev/null
}

@test "14 an unreadable current contract is refused" {
  enroll
  printf 'garbage\n' > "$WS/agent-md.toml"
  ask
  assert_refused REFUSED_CONTRACT_CHANGED
  printf '%s' "$output" | jq -e '.contract.state == "unreadable"' >/dev/null
}

@test "15 a changed mechanism file is refused" {
  enroll
  printf '#!/bin/bash\n# tampered\n' > "$WS/.claude/hooks/_lib.sh"
  ask
  assert_refused REFUSED_MECHANISM_CHANGED
  [ "$status" -eq 8 ]
  printf '%s' "$output" | jq -e '.mechanism.state == "changed"' >/dev/null
}

@test "16 a missing mechanism file is refused" {
  enroll
  rm -f "$WS/.agent-md/bin/verify.sh"
  ask
  assert_refused REFUSED_MECHANISM_CHANGED
  printf '%s' "$output" | jq -e '.mechanism.state == "missing"' >/dev/null
}

@test "17 a PATH entry that became developer-writable is refused" {
  local base="$WS/../toolchain.$$"
  mkdir -p "$base/bin"
  chmod 0555 "$base/bin"
  chmod 0555 "$base"
  enroll --exec-path "$(realpath "$base")/bin:/usr/bin"
  ask
  [ "$status" -eq 0 ]

  chmod 0755 "$base"
  chmod 0755 "$base/bin"
  ask
  assert_refused REFUSED_ENV_CHANGED
  [ "$status" -eq 9 ]
  printf '%s' "$output" | jq -e '.environment.state == "changed"' >/dev/null
  chmod -R u+w "$base"; rm -rf "$base"
}

@test "18 an enrollment carrying a forbidden variable is refused" {
  enroll
  local dir; dir=$(project_dir)
  jq '.approved_environment += [{"name":"LD_PRELOAD","value":"/tmp/evil.so"}]' \
    "$dir/enrollment.json" > "$dir/tmp" && mv "$dir/tmp" "$dir/enrollment.json"
  ask
  assert_refused REFUSED_ENV_CHANGED
  printf '%s' "$output" | jq -e '.environment.state == "forbidden"' >/dev/null
}

@test "19 a corrupt enrollment record is refused" {
  enroll
  local dir; dir=$(project_dir)
  printf 'not json at all\n' > "$dir/enrollment.json"
  ask
  [ "$status" -ne 0 ]
  assert_single_object
  printf '%s' "$output" | jq -e '.status == "refused"' >/dev/null
}

@test "20 a symlinked enrollment record never becomes authority" {
  enroll
  local dir; dir=$(project_dir)
  local elsewhere; elsewhere="$(mktemp)"
  cp "$dir/enrollment.json" "$elsewhere"
  rm -f "$dir/enrollment.json"
  ln -s "$elsewhere" "$dir/enrollment.json"
  ask
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.status == "refused"' >/dev/null
  rm -f "$elsewhere"
}

@test "21 an unsafe authority state directory is refused" {
  enroll
  chmod 0777 "$ROOT/var/lib/agent-md/projects"
  ask
  assert_refused REFUSED_AUTHORITY_STATE_UNSAFE
  [ "$status" -eq 11 ]
}

@test "22 a hostile workspace helper is never executed" {
  enroll
  ask
  [ "$status" -eq 0 ]
  [ ! -e "$MARKER" ]
}

@test "23 a linked worktree is refused as unsupported" {
  enroll
  rm -rf "$WS/.git"
  printf 'gitdir: /somewhere/else\n' > "$WS/.git"
  ask
  assert_refused REFUSED_WORKSPACE_UNSUPPORTED
  [ "$status" -eq 12 ]
}

@test "24 stdout is exactly one JSON object on every outcome" {
  enroll
  ask
  [ "$status" -eq 0 ]
  assert_single_object
  ask '{"protocol":1,'
  assert_single_object
  ask "$(printf '{"protocol":1,"scope":"bogus","workspace":"%s"}' "$(realpath "$WS")")"
  assert_single_object
}

@test "25 eligibility leaves the workspace and the authority byte-identical" {
  enroll
  local ws_before ws_after state_before state_after
  ws_before=$(find "$WS" -path "$WS/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
  state_before=$(find "$ROOT/var/lib/agent-md" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
  ask
  [ "$status" -eq 0 ]
  ws_after=$(find "$WS" -path "$WS/.git" -prune -o -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
  state_after=$(find "$ROOT/var/lib/agent-md" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum)
  [ "$ws_before" = "$ws_after" ]
  [ "$state_before" = "$state_after" ]
}

@test "26 the issuer has no capability to execute, sign or sequence" {
  # A structural check, not a behavioural one: these capabilities must not
  # exist in C2 at all, so their absence is asserted on the source.
  ! grep -qE '(^|[^_[:alnum:]])(eval|exec)[[:space:]]' "$ISSUER"
  ! grep -qE 'openssl[[:space:]]+(pkeyutl|dgst[[:space:]]+-sign)' "$ISSUER"
  ! grep -qE 'sudo|setpriv|runuser|su[[:space:]]-' "$ISSUER"
  ! grep -qE 'issuer\.key|private|sequence|last_terminal|receipt' "$ISSUER"
  ! grep -qE 'atomic_write|mkdir|rename|[[:space:]]>[[:space:]]*"\$' "$ISSUER"
  ! grep -qE '\.approved_contract\.checks\[\]\.command' "$ISSUER"
}
