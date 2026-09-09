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
#   pass. `stop_hook_active=true` does NOT short-circuit us; if the
#   agent retries without fixing anything, we block again.
#
#   The only way out is to satisfy the required verification contract or
#   fix invalid enforcement configuration.
#
# Configuration:
#   agent-md.toml [verify] commands override heuristics. An optional
#   [verify.policy] required array and timeout_seconds scalar make the
#   completion contract explicit. Resolution and execution are shared with
#   doctor, agent-md-verify, and .githooks/pre-commit.

# shellcheck source=.claude/hooks/_lib.sh
. "$(dirname "$0")/_lib.sh"

# Read and discard stdin — Claude sends JSON but we don't branch on it.
cat > /dev/null

VERIFY_SUMMARY=$(run_effective_verification_contract worktree)
RISK_SUMMARY=$(run_risk_contract "$VERIFY_SUMMARY" worktree completion)
SUMMARY=$(combine_policy_summaries "$VERIFY_SUMMARY" "$RISK_SUMMARY")
STATUS=$(printf '%s' "$SUMMARY" | jq -r '.status')

if [ "$STATUS" = fail ]; then
  REASON=$(verification_summary_human "$SUMMARY" nonpass)
  jq -n --arg r "$REASON" '{decision: "block", reason: $r}'
  exit 0
fi

if [ "$STATUS" = warn ]; then
  MESSAGE=$(verification_summary_human "$SUMMARY" nonpass)
  jq -n --arg m "$MESSAGE" '{hookSpecificOutput: {hookEventName: "Stop", additionalContext: $m}}'
  exit 0
fi

exit 0
