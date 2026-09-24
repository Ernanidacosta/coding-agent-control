#!/usr/bin/env bats

load authority-helpers
bats_require_minimum_version 1.5.0

setup() {
  AUTHORITY="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority"
  ISSUER="$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-issuer"
  ROOT="$(mktemp -d)"
  WS="$(mktemp -d)"
  TOOLCHAIN="$(mktemp -d)"
  export AUTHORITY ISSUER ROOT WS TOOLCHAIN
  mkdir -p "$WS/.claude/hooks" "$WS/.agent-md/bin"
  git -C "$WS" init -q
  for hook in .claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh; do
    printf '#!/bin/bash\n' > "$WS/$hook"
  done
  printf '[tool.poetry]\nname = "fixture"\nversion = "0.1.0"\n' > "$WS/pyproject.toml"
  printf '# fixture lock\n' > "$WS/poetry.lock"
  bash "$AUTHORITY" install --root "$ROOT" >/dev/null
  bash "$AUTHORITY" install-key --root "$ROOT" >/dev/null
  EXEC_PATH="$(trusted_toolchain_path "$TOOLCHAIN")"
  export EXEC_PATH
  chmod u+w "$TOOLCHAIN/bin"
  cat > "$TOOLCHAIN/bin/poetry" <<'POETRY'
#!/bin/bash
set -eu
case "$1" in
  sync)
    [ ! -f PREP_FAIL ] || exit 7
    [ ! -f "${0%/*}/PREP_DENY" ] || exit 7
    [ ! -f PREP_TIMEOUT ] && [ ! -f "${0%/*}/PREP_TIMEOUT" ] || sleep 3
    [ ! -f "$POETRY_CACHE_DIR/poison" ] || exit 8
    if [ -f LOCK_WAIT ]; then
      mkfifo /runtime/lock-release
      touch /runtime/lock-ready
      cat /runtime/lock-release >/dev/null
    fi
    if [ -f PREP_ASSERT_BOUNDARY ]; then
      [ "$PYTHONPATH" = "$PWD" ] || exit 93
      base=${POETRY_VIRTUALENVS_PATH%/*}
      [ "$XDG_CACHE_HOME" = "$base/cache" ] || exit 94
      [ "$RUFF_CACHE_DIR" = "$base/ruff-cache" ] || exit 95
      [ "$PYTEST_ADDOPTS" = "-o cache_dir=$base/pytest-cache" ] || exit 96
      [ "$COVERAGE_FILE" = "$base/coverage" ] || exit 97
      for descriptor in /proc/self/fd/*; do
        target=$(/usr/bin/readlink "$descriptor" 2>/dev/null || true)
        case "$target" in *issuer-*.key) exit 91 ;; esac
      done
      /usr/bin/env | /bin/grep -E '^(GIT_|VIRTUAL_ENV=|HOME=/home/|.*PRIVATE.*=)' && exit 92
    fi
    if [ -f PREP_WRITE ]; then
      printf 'contaminated\n' > pyproject.toml
    fi
    mkdir -p "$POETRY_VIRTUALENVS_PATH/bin" "$POETRY_CACHE_DIR"
    printf '#!/bin/bash\nprintf "dependency-ready\\n"\n' > "$POETRY_VIRTUALENVS_PATH/bin/depcli"
    /bin/chmod 0555 "$POETRY_VIRTUALENVS_PATH/bin/depcli"
    ;;
  run)
    shift
    if [ "$1" = depcli ]; then
      exec "$POETRY_VIRTUALENVS_PATH/bin/depcli"
    fi
    exec "$@"
    ;;
  *) exit 2 ;;
esac
POETRY
  chmod 0555 "$TOOLCHAIN/bin/poetry" "$TOOLCHAIN/bin"
}

teardown() {
  chmod -R u+w "$ROOT" "$TOOLCHAIN" 2>/dev/null || true
  rm -rf "$ROOT" "$WS" "$TOOLCHAIN"
}

contract() {
  cat > "$WS/agent-md.toml" <<'TOML'
[verify]
lint = "poetry run depcli"
test = "poetry run depcli"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 10

[verify.preparation]
provider = "poetry"
command = "poetry sync --no-root"
timeout_seconds = 1
TOML
}

enroll() {
  bash "$AUTHORITY" enroll "$WS" --root "$ROOT" --exec-path "$EXEC_PATH" --yes >/dev/null
  PROJECT_ID=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  export PROJECT_ID
  [ "$(jq -r .status "$ROOT/var/lib/agent-md/projects/$PROJECT_ID/enrollment.json")" = eligible ]
}

evaluate() {
  run --separate-stderr bash -c \
    'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT"
}

seal_staging_project() {
  local project="$ROOT/var/lib/agent-md/projects/$PROJECT_ID"
  chmod 0444 "$project/enrollment.json" "$project/state.json"
  chmod 0555 "$project"
}

@test "approved preparation materializes an isolated runtime for each ordinary check" {
  contract
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '
    .status == "authenticated_pass" and (.checks | length) == 2 and
    all(.checks[]; .exit_code == 0 and .execution == "completed")
  ' >/dev/null
}

@test "Poetry no-root checks import project code only from the sealed snapshot" {
  contract
  mkdir -p "$WS/app"
  printf 'VALUE = "snapshot-module"\n' > "$WS/app/__init__.py"
  cat > "$WS/agent-md.toml" <<'TOML'
[verify]
test = "poetry run python3 -c 'import app; print(app.VALUE)'"

[verify.policy]
required = ["test"]
timeout_seconds = 10

[verify.preparation]
provider = "poetry"
command = "poetry sync --no-root"
timeout_seconds = 1
TOML
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "authenticated_pass" and .checks[0].exit_code == 0' >/dev/null
  [[ "$stderr" == *snapshot-module* ]]
}

@test "preparation failure refuses and publishes no receipt" {
  contract
  touch "$WS/PREP_FAIL"
  enroll
  evaluate
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '
    .reason_code == "REFUSED_PREPARATION_FAILED" and .receipt == null and
    (.checks | length) == 0
  ' >/dev/null
  [ "$(jq -r '.scopes.worktree.last_terminal.status' "$ROOT/var/lib/agent-md/projects/$PROJECT_ID/state.json")" = preparation_failed ]
}

@test "preparation failure supersedes a previous PASS without signing an ordinary FAIL" {
  contract
  enroll
  evaluate
  [ "$status" -eq 0 ]
  old_receipt=$(printf '%s' "$output" | jq -r '.receipt.path')
  old_identity=$(printf '%s' "$output" | jq -c '.identity')
  chmod u+w "$TOOLCHAIN/bin"
  touch "$TOOLCHAIN/bin/PREP_DENY"
  chmod 0555 "$TOOLCHAIN/bin"
  evaluate
  [ "$status" -eq 22 ]
  printf '%s' "$output" | jq -e --argjson old "$old_identity" '
    .reason_code == "REFUSED_PREPARATION_FAILED" and .receipt == null and .identity == $old
  ' >/dev/null
  [ -f "$old_receipt" ]
  state="$ROOT/var/lib/agent-md/projects/$PROJECT_ID/state.json"
  jq -e '
    .scopes.worktree.pending == null and
    .scopes.worktree.last_terminal.status == "preparation_failed" and
    .scopes.worktree.last_terminal.receipt == null and
    .scopes.worktree.last_terminal.sequence == 2 and
    .scopes.worktree.next_sequence == 3
  ' "$state" >/dev/null
  seal_staging_project
  run --separate-stderr bash "$BATS_TEST_DIRNAME/../examples/local-issuer/receipt-verify.sh" "$WS" worktree --root "$ROOT"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.status == "unauthenticated_terminal" and .authentic == false and .applicable == false' >/dev/null
}

@test "preparation timeout is infrastructure refusal" {
  contract
  enroll
  evaluate
  [ "$status" -eq 0 ]
  old_receipt=$(printf '%s' "$output" | jq -r '.receipt.path')
  chmod u+w "$TOOLCHAIN/bin"
  touch "$TOOLCHAIN/bin/PREP_TIMEOUT"
  chmod 0555 "$TOOLCHAIN/bin"
  evaluate
  printf 'timeout status=%s output=%s stderr=%s\n' "$status" "$output" "$stderr" >&2
  [ "$status" -eq 22 ]
  printf '%s' "$output" | jq -e '
    .reason_code == "REFUSED_PREPARATION_FAILED" and .receipt == null
  ' >/dev/null
  [ -f "$old_receipt" ]
  jq -e '.scopes.worktree.last_terminal.status == "preparation_failed" and .scopes.worktree.last_terminal.receipt == null' \
    "$ROOT/var/lib/agent-md/projects/$PROJECT_ID/state.json" >/dev/null
}

@test "changing preparation command changes the authenticated contract identity" {
  contract
  enroll
  evaluate
  [ "$status" -eq 0 ]
  before=$(bash "$AUTHORITY" identity-fingerprints "$PROJECT_ID" --root "$ROOT" | jq -r '.contract.value')
  sed -i 's/command = "poetry sync --no-root"/command = "poetry sync --no-root --no-interaction"/' "$WS/agent-md.toml"
  after=$(bash "$AUTHORITY" identity-fingerprints "$PROJECT_ID" --root "$ROOT" | jq -r '.contract.value')
  [ "$before" != "$after" ]
  seal_staging_project
  run --separate-stderr bash "$BATS_TEST_DIRNAME/../examples/local-issuer/receipt-verify.sh" "$WS" worktree --root "$ROOT"
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.applicable == false and .status != "reusable_ordinary"' >/dev/null
  evaluate
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.reason_code == "REFUSED_CONTRACT_CHANGED" and .sequence == null' >/dev/null
}

@test "preparation cannot write the sealed snapshot" {
  contract
  touch "$WS/PREP_WRITE"
  enroll
  evaluate
  [ "$status" -ne 0 ]
  printf '%s' "$output" | jq -e '.reason_code == "REFUSED_PREPARATION_FAILED" and .receipt == null' >/dev/null
  run_id=$(printf '%s' "$output" | jq -r '.run_id')
  snapshot="$ROOT/var/lib/agent-md/projects/$PROJECT_ID/runs/$run_id/snapshot/src"
  [ "$(cat "$snapshot/pyproject.toml")" = "$(cat "$WS/pyproject.toml")" ]
  [ ! -w "$snapshot" ]
}

@test "an earlier check cannot replace the later check's freshly prepared runtime" {
  contract
  sed -i 's|lint = "poetry run depcli"|lint = "rm $POETRY_VIRTUALENVS_PATH/bin/depcli \&\& printf poisoned > $POETRY_VIRTUALENVS_PATH/bin/depcli"|' "$WS/agent-md.toml"
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "authenticated_pass" and all(.checks[]; .exit_code == 0)' >/dev/null
  [[ "$stderr" == *dependency-ready* ]]
  [[ "$stderr" != *poisoned* ]]
}

@test "a poisoned check cache cannot influence the next check's preparation" {
  contract
  sed -i 's|lint = "poetry run depcli"|lint = "printf poisoned > $POETRY_CACHE_DIR/poison"|' "$WS/agent-md.toml"
  enroll
  evaluate
  [ "$status" -eq 0 ]
  printf '%s' "$output" | jq -e '.status == "authenticated_pass" and all(.checks[]; .exit_code == 0)' >/dev/null
  [[ "$stderr" == *dependency-ready* ]]
}

@test "neither preparation nor checks inherit signing descriptors or developer environment" {
  contract
  touch "$WS/PREP_ASSERT_BOUNDARY"
  enroll
  PYTHONPATH=/tmp/developer-module evaluate
  [ "$status" -eq 0 ]
  run_id=$(printf '%s' "$output" | jq -r '.run_id')
  jobs="$ROOT/var/lib/agent-md/projects/$PROJECT_ID/runs/$run_id/jobs"
  ! /bin/grep -R -E 'issuer-[[:xdigit:]]+\.key|PRIVATE_KEY' "$jobs"
}

@test "developer cache and virtualenv do not supply a missing runtime dependency" {
  contract
  sed -i 's|test = "poetry run depcli"|test = "poetry run missingdep"|' "$WS/agent-md.toml"
  dev_home=$(mktemp -d)
  mkdir -p "$dev_home/.cache/pypoetry" "$dev_home/.venv/bin"
  printf '#!/bin/bash\nexit 0\n' > "$dev_home/.venv/bin/missingdep"
  printf 'cached\n' > "$dev_home/.cache/pypoetry/missingdep"
  chmod +x "$dev_home/.venv/bin/missingdep"
  enroll
  HOME="$dev_home" evaluate
  rm -rf "$dev_home"
  [ "$status" -eq 1 ]
  printf '%s' "$output" | jq -e '.status == "authenticated_fail" and (.checks[] | select(.name == "test") | .exit_code) != 0' >/dev/null
}

@test "changing developer Poetry cache neither changes identity nor supplies a dependency" {
  contract
  dev_home=$(mktemp -d)
  mkdir -p "$dev_home/.cache/pypoetry"
  enroll
  first=$(bash "$AUTHORITY" identity-fingerprints "$PROJECT_ID" --root "$ROOT" | jq -r '.source.value')
  printf 'tampered\n' > "$dev_home/.cache/pypoetry/poison"
  second=$(bash "$AUTHORITY" identity-fingerprints "$PROJECT_ID" --root "$ROOT" | jq -r '.source.value')
  HOME="$dev_home" evaluate
  rm -rf "$dev_home"
  [ "$first" = "$second" ]
  [ "$status" -eq 0 ]
}

@test "a changed lockfile after snapshot capture cannot publish PASS" {
  contract
  sed -i '/^test =/d; s/required = \["lint", "test"\]/required = ["lint"]/' "$WS/agent-md.toml"
  touch "$WS/LOCK_WAIT"
  enroll
  bash -c 'printf "{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"%s\"}" "$1" | bash "$2" evaluate --root "$3"' \
    _ "$WS" "$ISSUER" "$ROOT" > "$ROOT/evaluation.json" 2> "$ROOT/evaluation.err" &
  evaluation=$!
  project_id=$(ls "$ROOT/var/lib/agent-md/projects" | head -1)
  scratch="$ROOT/var/tmp/agent-md-runner/$project_id/lint"
  deadline=$((SECONDS + 15))
  until [ -f "$scratch/lock-ready" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { cat "$ROOT/evaluation.err" >&2; return 1; }
    sleep 0.02
  done
  printf 'changed\n' >> "$WS/poetry.lock"
  printf release > "$scratch/lock-release"
  wait "$evaluation" || true
  cat "$ROOT/evaluation.json" "$ROOT/evaluation.err" >&2
  jq -e '.status == "identity_changed" and .receipt == null' "$ROOT/evaluation.json" >/dev/null
}
