#!/usr/bin/env bats
#
# Release-aware installation and install provenance.
#
# `--ref` pins the GitHub archive a consumer installs, and every real install
# records which source it used in .agent-md/install-provenance.json. The tests
# never reach the network: a fake curl serves fixture archives by exact URL and
# logs every URL it was asked for, so a fallback to another ref is observable.

GITHUB_ARCHIVE=https://github.com/Ernanidacosta/coding-agent-control/archive
PROVENANCE=.agent-md/install-provenance.json

setup_file() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$BATS_FILE_TMPDIR/fixtures"
  mkdir -p "$FIXTURES/stage/coding-agent-control-main" "$FIXTURES/git"
  tar -cf - -C "$REPO" --exclude=.git --exclude=.agent . \
    | tar -xf - -C "$FIXTURES/stage/coding-agent-control-main"

  # A plain tarball carries no commit metadata, like a hand-built archive.
  tar -czf "$FIXTURES/plain.tar.gz" -C "$FIXTURES/stage" coding-agent-control-main

  # git archive of a commit embeds that commit ID, like GitHub's archives.
  cp -R "$FIXTURES/stage/coding-agent-control-main/." "$FIXTURES/git"
  (
    cd "$FIXTURES/git" || exit 1
    export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
    git init -q
    git -c core.hooksPath=/dev/null add -A -f
    git -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -qm rc1
    git rev-parse HEAD > "$FIXTURES/rc1.commit"
    git archive --format=tar --prefix=coding-agent-control-1.0.0-rc1/ HEAD | gzip > "$FIXTURES/rc1.tar.gz"
    git -c core.hooksPath=/dev/null -c user.email=t@t -c user.name=t commit -q --allow-empty -m rc2
    git rev-parse HEAD > "$FIXTURES/rc2.commit"
    git archive --format=tar --prefix=coding-agent-control-1.0.0-rc2/ HEAD | gzip > "$FIXTURES/rc2.tar.gz"
  )
}

setup() {
  REPO="$(cd "$BATS_TEST_DIRNAME/.." && pwd)"
  FIXTURES="$BATS_FILE_TMPDIR/fixtures"
  TARGET_DIR="$(mktemp -d)"
  WORK="$(mktemp -d)"
  export REPO FIXTURES TARGET_DIR WORK
  unset CODING_AGENT_CONTROL_SOURCE_URL CODING_AGENT_CONTROL_SOURCE_ARCHIVE
  git -C "$TARGET_DIR" init -q
  git -C "$TARGET_DIR" config core.excludesFile /dev/null

  FAKE_CURL_ROUTES="$WORK/routes"
  FAKE_CURL_LOG="$WORK/curl.log"
  export FAKE_CURL_ROUTES FAKE_CURL_LOG
  mkdir -p "$WORK/bin" "$FAKE_CURL_ROUTES"
  cat > "$WORK/bin/curl" <<'EOF'
#!/bin/bash
out="" url=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift 2 ;;
    -*) shift ;;
    *) url="$1"; shift ;;
  esac
done
printf '%s\n' "$url" >> "$FAKE_CURL_LOG"
route="$FAKE_CURL_ROUTES/$(printf '%s' "$url" | sha256sum | cut -c1-32)"
if [ ! -f "$route" ]; then
  echo "curl: (22) The requested URL returned error: 404" >&2
  exit 22
fi
cp "$route" "$out"
EOF
  chmod +x "$WORK/bin/curl"
  PATH="$WORK/bin:$PATH"
}

teardown() {
  rm -rf "$TARGET_DIR" "$WORK"
}

serve() {
  cp "$2" "$FAKE_CURL_ROUTES/$(printf '%s' "$1" | sha256sum | cut -c1-32)"
}

requested_urls() {
  cat "$FAKE_CURL_LOG" 2>/dev/null || true
}

install_from_file() {
  bash "$REPO/install.sh" --no-githooks "$@" "$TARGET_DIR"
}

# No source file, exactly like curl | bash.
install_from_stdin() {
  bash -s -- --no-githooks "$@" "$TARGET_DIR" < "$REPO/install.sh"
}

provenance() {
  jq -r "$1" "$TARGET_DIR/$PROVENANCE"
}

run_doctor() {
  run bash -c 'cd "$1" && bash .agent-md/bin/doctor.sh' _ "$TARGET_DIR"
}

@test "--ref with a release tag fetches the unambiguous tag archive and records it" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  run install_from_file --ref=v1.0.0-rc2
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$(requested_urls)" = "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" ]
  echo "$output" | grep -q "Source: fetched package archive (github-ref v1.0.0-rc2)"
  [ "$(provenance .source)" = github-ref ]
  [ "$(provenance .ref)" = v1.0.0-rc2 ]
  [ "$(provenance .source_url)" = "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" ]
  grep -q "coding-agent-control Directives" "$TARGET_DIR/AGENT.md"
}

@test "--ref run from a local package still installs the remote ref, not the package" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  run install_from_file --ref=v1.0.0-rc2
  [ "$status" -eq 0 ]
  ! echo "$output" | grep -q "Source: $REPO"
  [ -s "$FAKE_CURL_LOG" ]
}

@test "--ref with a full commit SHA fetches the commit archive" {
  sha=$(cat "$FIXTURES/rc2.commit")
  serve "$GITHUB_ARCHIVE/$sha.tar.gz" "$FIXTURES/rc2.tar.gz"
  run install_from_stdin --ref="$sha"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$(requested_urls)" = "$GITHUB_ARCHIVE/$sha.tar.gz" ]
  [ "$(provenance .source)" = github-ref ]
  [ "$(provenance .ref)" = "$sha" ]
  [ "$(provenance .archive_commit)" = "$sha" ]
}

@test "a ref that cannot be fetched fails visibly and never falls back to main" {
  run install_from_file --ref=v9.9.9-missing
  [ "$status" -ne 0 ]
  echo "$output" | grep -q "cannot download or unpack $GITHUB_ARCHIVE/refs/tags/v9.9.9-missing.tar.gz"
  echo "$output" | grep -q "ref 'v9.9.9-missing' was not obtained; no fallback"
  [ "$(requested_urls)" = "$GITHUB_ARCHIVE/refs/tags/v9.9.9-missing.tar.gz" ]
  [ ! -e "$TARGET_DIR/AGENT.md" ]
}

@test "malformed refs are rejected before anything is fetched" {
  for ref in "" "../main" "-x" "v1..2" "tag/" "a b" "v1.lock" "v1?x=1"; do
    run install_from_file "--ref=$ref"
    [ "$status" -ne 0 ] || { printf 'accepted ref %q\n' "$ref" >&2; false; }
    echo "$output" | grep -q -- "--ref must be a release tag or a full commit SHA"
  done
  [ ! -s "$FAKE_CURL_LOG" ]
  [ ! -e "$TARGET_DIR/AGENT.md" ]
}

@test "--ref combined with a local source archive is a conflict" {
  run env CODING_AGENT_CONTROL_SOURCE_ARCHIVE="$FIXTURES/plain.tar.gz" \
    bash "$REPO/install.sh" --no-githooks --ref=v1.0.0-rc2 "$TARGET_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--ref cannot be combined with CODING_AGENT_CONTROL_SOURCE_ARCHIVE"
  [ ! -s "$FAKE_CURL_LOG" ]
  [ ! -e "$TARGET_DIR/AGENT.md" ]
}

@test "--ref combined with a source URL is a conflict" {
  run env CODING_AGENT_CONTROL_SOURCE_URL="file://$FIXTURES/plain.tar.gz" \
    bash "$REPO/install.sh" --no-githooks --ref=v1.0.0-rc2 "$TARGET_DIR"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q -- "--ref cannot be combined with CODING_AGENT_CONTROL_SOURCE_URL"
  [ ! -s "$FAKE_CURL_LOG" ]
  [ ! -e "$TARGET_DIR/AGENT.md" ]
}

@test "without --ref a piped install keeps the documented moving main archive" {
  serve "$GITHUB_ARCHIVE/main.tar.gz" "$FIXTURES/plain.tar.gz"
  run install_from_stdin
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ "$(requested_urls)" = "$GITHUB_ARCHIVE/main.tar.gz" ]
  echo "$output" | grep -q "development main"
  [ "$(provenance .source)" = development ]
  [ "$(provenance .ref)" = main ]
  [ "$(provenance .source_url)" = "$GITHUB_ARCHIVE/main.tar.gz" ]
}

@test "a local source package installs without fetching and records package" {
  run install_from_file
  [ "$status" -eq 0 ]
  [ ! -s "$FAKE_CURL_LOG" ]
  [ "$(provenance .source)" = package ]
  [ "$(provenance .ref)" = null ]
  [ "$(provenance .source_url)" = null ]
  [ "$(provenance .archive_commit)" = null ]
}

@test "a local source archive installs offline and records archive-local" {
  run env CODING_AGENT_CONTROL_SOURCE_ARCHIVE="$FIXTURES/rc1.tar.gz" \
    bash -s -- --no-githooks "$TARGET_DIR" < "$REPO/install.sh"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  [ ! -s "$FAKE_CURL_LOG" ]
  [ "$(provenance .source)" = archive-local ]
  [ "$(provenance .ref)" = null ]
  [ "$(provenance .source_url)" = null ]
  [ "$(provenance .archive_commit)" = "$(cat "$FIXTURES/rc1.commit")" ]
}

@test "dry run reports the source and ref but records no provenance" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  run install_from_file --dry-run --ref=v1.0.0-rc2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "would record     $PROVENANCE (github-ref v1.0.0-rc2)"
  [ ! -e "$TARGET_DIR/$PROVENANCE" ]
  [ ! -e "$TARGET_DIR/AGENT.md" ]
}

@test "provenance has a fixed schema of provable fields and no timestamp" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  install_from_file --ref=v1.0.0-rc2
  jq -e . "$TARGET_DIR/$PROVENANCE" >/dev/null
  [ "$(jq -c 'keys_unsorted' "$TARGET_DIR/$PROVENANCE")" = \
    '["schema","project","source","ref","source_url","archive_commit"]' ]
  [ "$(provenance .schema)" = 1 ]
  [ "$(provenance .project)" = coding-agent-control ]
  # A commit ID can contain any run of digits, so it is checked for its exact
  # shape and only the other fields are searched for a date or epoch.
  provenance '.archive_commit' | grep -Eq '^[0-9a-f]{40}$'
  jq -e '[to_entries[] | select(.key != "archive_commit") | .value | tostring]
    | any(test("[0-9]{4}-[0-9]{2}-[0-9]{2}|[0-9]{10}")) | not' \
    "$TARGET_DIR/$PROVENANCE" >/dev/null
}

@test "a valid archive commit is recorded as declared by the archive" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  install_from_file --ref=v1.0.0-rc2
  [ "$(provenance .archive_commit)" = "$(cat "$FIXTURES/rc2.commit")" ]
}

@test "an archive without commit metadata records no commit" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/plain.tar.gz"
  install_from_file --ref=v1.0.0-rc2
  [ "$(provenance .archive_commit)" = null ]
}

@test "reinstalling the same ref is idempotent and keeps provenance byte-identical" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  install_from_file --ref=v1.0.0-rc2
  cp "$TARGET_DIR/$PROVENANCE" "$WORK/first.json"
  run install_from_file --ref=v1.0.0-rc2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "already current  $PROVENANCE"
  cmp -s "$WORK/first.json" "$TARGET_DIR/$PROVENANCE"
  [ "$(find "$TARGET_DIR" \( -name '*.bak' -o -name '*.bak.*' \) | wc -l)" -eq 0 ]
}

@test "upgrading to another ref updates provenance and preserves project state" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc1.tar.gz" "$FIXTURES/rc1.tar.gz"
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  install_from_file --ref=v1.0.0-rc1
  printf 'Status: active\nLOCAL MEMORY\n' > "$TARGET_DIR/memory/progress.md"
  printf '[verify]\ntest = "true"\n' > "$TARGET_DIR/agent-md.toml"
  printf 'schema = 1\nrisk = "high"\n' > "$TARGET_DIR/.project-control.toml"
  for f in memory/progress.md agent-md.toml .project-control.toml; do
    cp "$TARGET_DIR/$f" "$WORK/$(basename "$f").before"
  done

  run install_from_file --ref=v1.0.0-rc2
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
  echo "$output" | grep -q "installed: github-ref v1.0.0-rc1 → target: github-ref v1.0.0-rc2"
  [ "$(provenance .ref)" = v1.0.0-rc2 ]
  [ "$(provenance .archive_commit)" = "$(cat "$FIXTURES/rc2.commit")" ]
  for f in memory/progress.md agent-md.toml .project-control.toml; do
    cmp -s "$WORK/$(basename "$f").before" "$TARGET_DIR/$f"
  done
}

@test "upgrading to another ref keeps third-party hooks" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc1.tar.gz" "$FIXTURES/rc1.tar.gz"
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  mkdir -p "$TARGET_DIR/.claude" "$TARGET_DIR/.codex"
  for f in .claude/settings.json .codex/hooks.json; do
    printf '{"hooks": {"Stop": [{"hooks": [{"type": "command", "command": "third-party stop"}]}]}}\n' \
      > "$TARGET_DIR/$f"
  done
  install_from_file --ref=v1.0.0-rc1
  install_from_file --ref=v1.0.0-rc2
  for f in .claude/settings.json .codex/hooks.json; do
    [ "$(jq '[.hooks.Stop[]?.hooks[]? | select(.command == "third-party stop")] | length' \
      "$TARGET_DIR/$f")" -eq 1 ]
  done
}

@test "a legacy install without provenance is upgraded and reported as unrecorded" {
  install_from_file
  rm "$TARGET_DIR/$PROVENANCE"
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  run install_from_file --ref=v1.0.0-rc2
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "installed: no provenance recorded"
  [ "$(provenance .ref)" = v1.0.0-rc2 ]
}

@test "doctor reports recorded provenance" {
  serve "$GITHUB_ARCHIVE/refs/tags/v1.0.0-rc2.tar.gz" "$FIXTURES/rc2.tar.gz"
  install_from_file --ref=v1.0.0-rc2
  run_doctor
  echo "$output" | grep -q "^Installation:"
  echo "$output" | grep -q "^  source: github-ref$"
  echo "$output" | grep -q "^  ref: v1.0.0-rc2$"
  echo "$output" | grep -q "^  archive commit: $(cat "$FIXTURES/rc2.commit") (declared by the archive, not verified)$"
  echo "$output" | grep -q "^  reproduce: install.sh --ref=v1.0.0-rc2$"
  echo "$output" | grep -q "not a receipt, attestation or trust anchor"
}

@test "doctor stays non-blocking when provenance is absent" {
  install_from_file
  run_doctor
  with_status=$status
  rm "$TARGET_DIR/$PROVENANCE"
  run_doctor
  [ "$status" -eq "$with_status" ]
  echo "$output" | grep -q "^  provenance: not recorded"
  ! echo "$output" | grep -q "^bad .*provenance"
}

@test "doctor warns without failing on unreadable provenance" {
  install_from_file
  run_doctor
  with_status=$status
  printf 'not json\n' > "$TARGET_DIR/$PROVENANCE"
  run_doctor
  [ "$status" -eq "$with_status" ]
  echo "$output" | grep -q "^warn install provenance is unreadable"
}

@test "a source URL that may carry credentials is never persisted" {
  for url in \
    "https://user:secret-token@example.invalid/cac.tar.gz" \
    "https://example.invalid/cac.tar.gz?token=secret-token" \
    "https://example.invalid/cac.tar.gz#secret-token"; do
    serve "$url" "$FIXTURES/plain.tar.gz"
    run env CODING_AGENT_CONTROL_SOURCE_URL="$url" \
      bash -s -- --no-githooks "$TARGET_DIR" < "$REPO/install.sh"
    [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; false; }
    [ "$(provenance .source)" = url ]
    [ "$(provenance .source_url)" = null ]
    ! grep -q secret-token "$TARGET_DIR/$PROVENANCE"
  done
}

@test "a plain source URL is recorded" {
  serve "https://mirror.example.invalid/cac.tar.gz" "$FIXTURES/plain.tar.gz"
  run env CODING_AGENT_CONTROL_SOURCE_URL="https://mirror.example.invalid/cac.tar.gz" \
    bash -s -- --no-githooks "$TARGET_DIR" < "$REPO/install.sh"
  [ "$status" -eq 0 ]
  [ "$(provenance .source)" = url ]
  [ "$(provenance .source_url)" = "https://mirror.example.invalid/cac.tar.gz" ]
}

@test "self install records no provenance in the source tree" {
  mkdir -p "$WORK/package"
  cp -R "$FIXTURES/stage/coding-agent-control-main/." "$WORK/package"
  git -C "$WORK/package" init -q
  run bash "$WORK/package/install.sh" --no-githooks "$WORK/package"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q "provenance not recorded (target is the source package)"
  [ ! -e "$WORK/package/$PROVENANCE" ]
}
