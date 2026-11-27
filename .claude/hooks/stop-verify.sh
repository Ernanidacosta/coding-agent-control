#!/bin/bash
# stop-verify.sh
# Runs when Claude tries to finish a task (Stop event).
# The agent cannot declare "Done!" until the project actually compiles,
# lints, and passes tests.
#
# Hook output contract (Claude Code):
#   exit 0 + JSON on stdout → Claude reads the structured decision.
#   We emit {decision:"block", reason:...} on stdout with exit 0.
#
# Design choice — no retry release:
#   Earlier versions broke out after N consecutive failing retries to
#   avoid trapping the agent in a loop. That escape hatch meant
#   "enforcement" was conditional on the agent's persistence — not
#   enforcement at all. We keep blocking until the commands actually
#   pass. `stop_hook_active=true` does NOT short-circuit a block; if the
#   agent retries without fixing anything, we block again.
#
#   The only way to finish with a failing contract is to satisfy it, fix
#   invalid enforcement configuration, or hand the task to the human through
#   a complete blocked checkpoint, which claims nothing (see _lib.sh).
#
#   `stop_hook_active` does bound advisory context: a warning carries no
#   decision to satisfy, so it is said once per stop cycle instead of on
#   every retry. See the stop-hook input contract in _lib.sh.
#
# Configuration:
#   agent-md.toml [verify] commands override heuristics. An optional
#   [verify.policy] required array and timeout_seconds scalar make the
#   completion contract explicit. Resolution and execution are shared with
#   doctor, agent-md-verify, and .githooks/pre-commit.

# shellcheck source=.claude/hooks/_lib.sh
. "$(dirname "$0")/_lib.sh"

HOOK_INPUT=$(cat)

if ! enter_project_root; then
  emit_stop_block "$(policy_human_message "$(project_root_unavailable_result)")"
  exit 0
fi

# A complete blocked checkpoint is a handoff, not a completion claim: it ends
# the stop cycle without running the completion contract. See _lib.sh.
HANDOFF=$(stop_handoff_checkpoint_json "$(state_file_snapshot memory/progress.md worktree)")
if [ "$(printf '%s' "$HANDOFF" | jq -r '.handoff')" = true ]; then
  emit_stop_advisory "$HOOK_INPUT" "$(stop_handoff_message "$HANDOFF")"
  exit 0
fi

completion_evaluation_begin
CONTEXT=$(completion_evaluation_context_json worktree host)
HOST=${CODING_AGENT_CONTROL_HOST:-claude}
HOST_EVENT=$(hook_input_stop_event "$HOOK_INPUT")
HOST_TIMEOUT=$(completion_host_timeout_seconds "$HOST" "" "$HOST_EVENT" 2>/dev/null || true)
HOST_PREFLIGHT=$(completion_host_preflight_json \
  "$(printf '%s' "$CONTEXT" | jq -c '.budget')" "$HOST" "$HOST_TIMEOUT" "$HOST_EVENT")
if [ "$(printf '%s' "$HOST_PREFLIGHT" | jq -r '.valid')" != true ]; then
  emit_stop_block "$(policy_human_message "$(printf '%s' "$HOST_PREFLIGHT" | jq -c '.result')")$(stop_handoff_hint "$HANDOFF")"
  exit 0
fi

# receipt-first: an authenticated evaluation that already covers this state is
# reused instead of running the ordinary contract again. Codex reaches this
# same handler, so both hosts get one semantics and not two.
EVALUATION=$(run_completion_evaluation "$CONTEXT" completion receipt-first)
SUMMARY=$(printf '%s' "$EVALUATION" | jq -c '.summary')
STATUS=$(printf '%s' "$SUMMARY" | jq -r '.status')

if [ "$STATUS" = fail ]; then
  REASON=$(verification_summary_human "$SUMMARY" nonpass)
  emit_stop_block "${REASON}$(stop_handoff_hint "$HANDOFF")"
  exit 0
fi

if [ "$STATUS" = warn ]; then
  MESSAGE=$(verification_summary_human "$SUMMARY" nonpass)
  emit_stop_advisory "$HOOK_INPUT" "$MESSAGE"
  exit 0
fi

exit 0
