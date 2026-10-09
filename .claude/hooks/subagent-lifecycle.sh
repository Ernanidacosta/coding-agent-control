#!/bin/bash

# Correlation is ephemeral routing state, not a receipt or a trust anchor.
# A warning can continue Claude's finish cycle, so keep the identity until
# all handlers are silent; a block must retain it through every retry.
# shellcheck source=.claude/hooks/_lib.sh
. "$(dirname "$0")/_lib.sh"

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
case "$EVENT" in SubagentStart|SubagentStop|SessionEnd) ;; *) exit 0 ;; esac

CODING_AGENT_CONTROL_HOST=claude
export CODING_AGENT_CONTROL_HOST

diagnostic() {
  printf '[ERROR %s] %s\n' "$1" "$2" >&2
}
storage_failure() {
  if [ "$EVENT" = SubagentStop ]; then
    emit_stop_block '[ERROR CLAUDE_LIFECYCLE_UNAVAILABLE] Child lifecycle storage is unavailable. Recovery: Restore the private .agent/claude-subagents directory before retrying.'
    exit 0
  else
    diagnostic CLAUDE_LIFECYCLE_UNAVAILABLE 'Lifecycle tracking was not established/cleaned. Check .agent/claude-subagents permissions. SubagentStart cannot prevent child creation.'
  fi
  exit 1
}

if ! printf '%s' "$INPUT" | jq -e --arg event "$EVENT" '
  def identifier: type == "string" and test("^[A-Za-z0-9_-]{1,128}$");
  (.session_id | identifier) and
  (if $event == "SessionEnd" then true else (.agent_id | identifier) end)
' >/dev/null 2>&1; then
  diagnostic CLAUDE_LIFECYCLE_INVALID 'Missing or invalid session_id/agent_id; event cannot be correlated.'
  exit 1
fi
SESSION=$(printf '%s' "$INPUT" | jq -r '.session_id')
AGENT=$(printf '%s' "$INPUT" | jq -r '.agent_id // empty')
ROOT=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
STORE="$ROOT/.agent/claude-subagents"
DIR="$STORE/$SESSION"
RECORD="$DIR/$AGENT.json"
umask 077

for path in "$ROOT/.agent" "$STORE" "$DIR"; do
  [ ! -L "$path" ] || storage_failure
  if [ -e "$path" ] && { [ ! -d "$path" ] || [ ! -O "$path" ]; }; then
    storage_failure
  fi
done

case "$EVENT" in
  SubagentStart)
    mkdir -p "$DIR" || storage_failure
    chmod 700 "$STORE" "$DIR" || storage_failure
    touch "$DIR" || storage_failure
    # Age cannot prove a session ended: never expire a registered identity.
    # Only incomplete writes and empty directories can be reaped by age.
    find "$STORE" -type f -name '.pending.*' -mmin +10080 -delete || storage_failure
    find "$STORE" -mindepth 1 -type d -empty -mmin +10080 -delete || storage_failure
    TEMP=$(mktemp "$DIR/.pending.XXXXXX") || storage_failure
    trap 'rm -f "$TEMP"' EXIT
    printf '%s' "$INPUT" | jq -c '{session_id,agent_id,agent_type:(.agent_type // "")}' > "$TEMP" || storage_failure
    [ ! -L "$RECORD" ] || storage_failure
    mv -f "$TEMP" "$RECORD" || storage_failure
    ;;
  SessionEnd)
    [ -d "$DIR" ] || exit 0
    find "$DIR" -maxdepth 1 -type f \( -name '*.json' -o -name '.pending.*' \) -delete || storage_failure
    rmdir "$DIR" 2>/dev/null || true
    ;;
  SubagentStop)
    [ ! -L "$RECORD" ] || storage_failure
    # No matching Start is normal for internal agents, even with a named type.
    [ -e "$RECORD" ] || exit 0
    if ! jq -e --arg session "$SESSION" --arg agent "$AGENT" \
      '.session_id == $session and .agent_id == $agent' "$RECORD" >/dev/null 2>&1; then
      emit_stop_block '[ERROR CLAUDE_LIFECYCLE_INVALID] The child registration is corrupt. Recovery: Restore the matching SubagentStart registration before retrying.'
      exit 0
    fi
    touch "$RECORD" || storage_failure
    MESSAGES=""
    for HOOK in stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
      OUTPUT=$(mktemp "${TMPDIR:-/tmp}/agent-md-claude-child.XXXXXX") || storage_failure
      case "$HOOK" in
        state-enforcement.sh) BUDGET=$(completion_state_handler_budget_seconds) ;;
        sensory-reminder.sh) BUDGET=$(completion_sensory_handler_budget_seconds) ;;
        *) BUDGET="" ;;
      esac
      if [ -z "$BUDGET" ]; then
        printf '%s' "$INPUT" | bash "$ROOT/.claude/hooks/$HOOK" > "$OUTPUT"
        RESULT=$?
      else
        # shellcheck disable=SC2016
        completion_execute_bounded_command "$BUDGET" bash -c 'printf %s "$1" | bash "$2"' _ \
          "$INPUT" "$ROOT/.claude/hooks/$HOOK" > "$OUTPUT"
        RESULT=$?
      fi
      OUT=$(cat "$OUTPUT")
      rm -f "$OUTPUT"
      if [ "$RESULT" -ne 0 ] || { [ -n "$OUT" ] && ! printf '%s' "$OUT" | jq -e 'type == "object"' >/dev/null 2>&1; }; then
        emit_stop_block "[ERROR STOP_HANDLER_FAILED] Claude child ${HOOK} failed (exit ${RESULT}) or returned invalid output. Recovery: Fix the handler before retrying completion."
        exit 0
      fi
      [ -n "$OUT" ] || continue
      if printf '%s' "$OUT" | jq -e '.decision == "block"' >/dev/null; then
        printf '%s\n' "$OUT"
        exit 0
      fi
      MSG=$(printf '%s' "$OUT" | jq -r '.hookSpecificOutput.additionalContext // empty')
      if [ -n "$MSG" ]; then
        MESSAGES="${MESSAGES}${MESSAGES:+

}${MSG}"
      fi
    done
    if [ -n "$MESSAGES" ]; then
      emit_stop_advisory "$INPUT" "$MESSAGES"
    else
      rm -f "$RECORD" || storage_failure
    fi
    ;;
esac
