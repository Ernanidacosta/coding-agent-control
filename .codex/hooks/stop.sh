#!/bin/bash
# Codex Stop wrapper.
#
# Codex launches matching hook handlers concurrently. For Stop checks we
# want deterministic ordering and at most one continuation prompt, so this
# wrapper runs the shared policies serially and emits the first block.
#
# The payload is forwarded verbatim, so the shared stop-hook input contract
# applies here too: a block is emitted on every attempt, and advisory
# context is emitted only while the host reports this is not a retry. A
# host that does not send stop_hook_active reads as a first attempt on
# every stop, which is the behavior Codex had before the contract existed.

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
INPUT=$(cat)
MESSAGES=""

# shellcheck source=.claude/hooks/_lib.sh
. "$ROOT/.claude/hooks/_lib.sh"

CODING_AGENT_CONTROL_HOST=codex
export CODING_AGENT_CONTROL_HOST

run_shared_stop_hook() {
  local hook="$1" budget="${2:-}" output_file exit_code
  if [ -z "$budget" ]; then
    printf '%s' "$INPUT" | bash "$ROOT/.claude/hooks/$hook"
    return 0
  fi
  output_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-codex-hook.XXXXXX") || {
    emit_stop_block "[ERROR VERIFY_UNAVAILABLE] Codex could not create temporary hook output storage. Recovery: Check temporary-directory permissions and retry."
    return 0
  }
  if ! completion_timeout_utility_available; then
    rm -f "$output_file"
    emit_stop_block "[ERROR VERIFY_UNAVAILABLE] Codex cannot enforce the reserved ${hook} budget because timeout/gtimeout is unavailable. Recovery: Install a compatible timeout utility before retrying completion."
    return 0
  fi
  # shellcheck disable=SC2016 # Positional parameters expand in the child shell.
  if completion_execute_bounded_command "$budget" bash -c 'printf %s "$1" | bash "$2"' _ \
    "$INPUT" "$ROOT/.claude/hooks/$hook" >"$output_file"; then
    exit_code=0
  else
    exit_code=$?
  fi
  if [ "$exit_code" -eq 124 ]; then
    rm -f "$output_file"
    emit_stop_block "[ERROR STOP_HANDLER_TIMEOUT] Codex ${hook} exceeded its ${budget}-second reserved handler budget. Recovery: Inspect the hanging policy hook before retrying completion."
    return 0
  fi
  cat "$output_file"
  rm -f "$output_file"
}

for HOOK in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
  case "$HOOK" in
    state-enforcement.sh) HOOK_BUDGET=$(completion_state_handler_budget_seconds) ;;
    sensory-reminder.sh) HOOK_BUDGET=$(completion_sensory_handler_budget_seconds) ;;
    *) HOOK_BUDGET="" ;;
  esac
  OUT=$(run_shared_stop_hook "$HOOK" "$HOOK_BUDGET")
  [ -z "$OUT" ] && continue

  if echo "$OUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    printf '%s\n' "$OUT"
    exit 0
  fi

  MSG=$(echo "$OUT" | jq -r '.hookSpecificOutput.additionalContext // .systemMessage // empty' 2>/dev/null || true)
  if [ -n "$MSG" ]; then
    if [ -n "$MESSAGES" ]; then
      MESSAGES="${MESSAGES}

${MSG}"
    else
      MESSAGES="$MSG"
    fi
  fi
done

if [ -n "$MESSAGES" ]; then
  jq -n --arg m "$MESSAGES" '{systemMessage: $m}'
fi
