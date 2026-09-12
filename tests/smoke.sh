#!/bin/bash
# Fast offline wiring smoke. This is intentionally not a .bats file, so the
# complete `bats tests/` regression suite does not execute it implicitly.

set -eu

ROOT=$(cd "$(dirname "$0")/.." && pwd)
SMOKE_REPO=$(mktemp -d "${TMPDIR:-/tmp}/coding-agent-control-smoke.XXXXXX")

cleanup() {
  rm -rf "$SMOKE_REPO"
}
trap cleanup EXIT HUP INT TERM

git -C "$SMOKE_REPO" init -q
git -C "$SMOKE_REPO" config user.name "Smoke Test"
git -C "$SMOKE_REPO" config user.email smoke@example.invalid
git -C "$SMOKE_REPO" config core.excludesFile /dev/null

bash "$ROOT/install.sh" --no-githooks --agent=all "$SMOKE_REPO" >/dev/null

cat > "$SMOKE_REPO/agent-md.toml" <<'TOML'
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 10
TOML

(
  cd "$SMOKE_REPO"
  ./.agent-md/bin/doctor.sh >/dev/null
)

HAPPY_OUTPUT=$(
  cd "$SMOKE_REPO"
  printf '%s' '{"stop_hook_active":false}' | bash .claude/hooks/stop-verify.sh
)
if [ -n "$HAPPY_OUTPUT" ]; then
  printf 'happy-path Stop unexpectedly emitted output:\n%s\n' "$HAPPY_OUTPUT" >&2
  exit 1
fi

cat > "$SMOKE_REPO/agent-md.toml" <<'TOML'
[verify]
test = "false"

[verify.policy]
required = ["test"]
timeout_seconds = 10
TOML

BLOCK_OUTPUT=$(
  cd "$SMOKE_REPO"
  printf '%s' '{"stop_hook_active":false}' | bash .codex/hooks/stop.sh
)
if ! printf '%s' "$BLOCK_OUTPUT" | jq -e '
  .decision == "block" and (.reason | test("ERROR VERIFY_REQUIRED_FAILED"))
' >/dev/null; then
  printf 'blocking-path Stop did not return the expected structured decision:\n%s\n' "$BLOCK_OUTPUT" >&2
  exit 1
fi

printf 'coding-agent-control smoke: pass\n'
