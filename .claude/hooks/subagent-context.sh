#!/bin/bash

INPUT=$(cat)
EVENT=$(printf '%s' "$INPUT" | jq -r '.hook_event_name // empty' 2>/dev/null)
[ "$EVENT" = SubagentStart ] || exit 0

unavailable() {
  printf '[ERROR CLAUDE_CONTEXT_UNAVAILABLE] %s Context was not supplied; SubagentStart cannot block creation. Restore canonical AGENT.md before delegating.\n' "$1" >&2
  exit 1
}
printf '%s' "$INPUT" | jq -e '
  def identifier: type == "string" and test("^[A-Za-z0-9_-]{1,128}$");
  (.session_id | identifier) and (.agent_id | identifier)
' >/dev/null 2>&1 || unavailable 'Invalid child identity.'

ROOT=${CLAUDE_PROJECT_DIR:-$(git rev-parse --show-toplevel 2>/dev/null || pwd)}
[ -r "$ROOT/AGENT.md" ] || unavailable 'Missing source.'
# Literal excerpts avoid a second policy. Neither agent_type nor lifecycle
# storage proves whether CLAUDE.md loaded; valid Starts share this small budget.
CONTEXT=$(LC_ALL=C awk '
  BEGIN { print "CAC delegated-agent context (AGENT.md; working state under memory/):" }
  $0 == "<!-- CAC:delegated:start -->" {
    if (inside) bad=1
    inside=1; blocks++; next
  }
  $0 == "<!-- CAC:delegated:end -->" {
    if (!inside) bad=1
    inside=0; print ""; next
  }
  inside { print; lines++ }
  END { if (bad || inside || !blocks || !lines) exit 1 }
' "$ROOT/AGENT.md") || unavailable 'Malformed or absent excerpt markers.'
if ! [ "$(LC_ALL=C printf '%s' "$CONTEXT" | wc -c)" -le 2560 ] ||
  ! [ "$(printf '%s\n' "$CONTEXT" | wc -l)" -le 48 ]; then
  unavailable 'Excerpt exceeds 2560 bytes or 48 lines.'
fi

jq -cn --arg context "$CONTEXT" \
  '{hookSpecificOutput:{hookEventName:"SubagentStart",additionalContext:$context}}'
