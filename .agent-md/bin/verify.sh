#!/bin/bash
# verify.sh — execute the agent-md verification contract.
# Usage: ./.agent-md/bin/verify.sh

set -u

ROOT=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
LIB="$ROOT/.claude/hooks/_lib.sh"

if [ ! -f "$LIB" ]; then
  printf '[ERROR CONFIG_INVALID] Shared verification library is missing. Recovery: Reinstall agent-md.\n' >&2
  exit 1
fi

# shellcheck source=.claude/hooks/_lib.sh
. "$LIB"
cd "$ROOT" || exit 1

completion_evaluation_begin
CONTEXT=$(completion_evaluation_context_json worktree standalone)
CONTRACT=$(printf '%s' "$CONTEXT" | jq -c '.contract')
BUDGET=$(printf '%s' "$CONTEXT" | jq -c '.budget')

printf 'Verification:\n'
if [ "$(printf '%s' "$CONTRACT" | jq -r '.valid')" != true ]; then
  verification_result_human "$(printf '%s' "$CONTRACT" | jq -c '.error')"
  exit 1
fi

printf '  %-12s %-10s %-15s %s\n' check policy origin command
while IFS= read -r SPEC; do
  [ -n "$SPEC" ] || continue
  printf '  %-12s %-10s %-15s %s\n' \
    "$(printf '%s' "$SPEC" | jq -r '.name')" \
    "$(printf '%s' "$SPEC" | jq -r '.requirement')" \
    "$(printf '%s' "$SPEC" | jq -r '.origin')" \
    "$(printf '%s' "$SPEC" | jq -r 'if .command == "" then "-" else .command end')"
done < <(printf '%s' "$CONTRACT" | jq -c \
  '.checks[] | select(.name != "independent" and .name != "approval")')

ADVANCED_CONFIGURED=$(printf '%s' "$CONTRACT" | jq \
  '[.checks[] | select((.name == "independent" or .name == "approval") and .origin == "configured")] | length')
if [ "$ADVANCED_CONFIGURED" -gt 0 ]; then
  printf '\nAdvanced completion capabilities:\n'
  while IFS= read -r SPEC; do
    [ -n "$SPEC" ] || continue
    printf '  %-12s configured as %s\n' \
      "$(printf '%s' "$SPEC" | jq -r '.name')" \
      "$(printf '%s' "$SPEC" | jq -r '.command')"
  done < <(printf '%s' "$CONTRACT" | jq -c \
    '.checks[] | select((.name == "independent" or .name == "approval") and .origin == "configured")')
fi

TIMEOUT=$(printf '%s' "$CONTRACT" | jq -r '.timeout_seconds // "not configured"')
TOTAL_TIMEOUT=$(printf '%s' "$BUDGET" | jq -r '.seconds // "unbounded"')
TOTAL_SOURCE=$(printf '%s' "$BUDGET" | jq -r '.source')
printf '  per-check timeout: %s\n' "$TIMEOUT"
printf '  total completion timeout: %s (%s)\n\n' "$TOTAL_TIMEOUT" "$TOTAL_SOURCE"

EVALUATION=$(run_completion_evaluation "$CONTEXT" completion)
SUMMARY=$(printf '%s' "$EVALUATION" | jq -c '.summary')
printf 'Completion:\n'
printf '  declared risk: %s\n' "$(printf '%s' "$SUMMARY" | jq -r '.risk // "not declared"')"
printf '  current status: %s\n' "$(printf '%s' "$SUMMARY" | jq -r '.current_status // "absent"')"
printf '  observed signals: %s\n\n' "$(printf '%s' "$SUMMARY" | jq -r 'if (.observed_signals | length) == 0 then "none" else (.observed_signals | join(", ")) end')"
verification_summary_human "$SUMMARY" all

PASSED=$(printf '%s' "$SUMMARY" | jq '[.results[] | select(.status == "pass")] | length')
WARNED=$(printf '%s' "$SUMMARY" | jq '[.results[] | select(.status == "warn")] | length')
FAILED=$(printf '%s' "$SUMMARY" | jq '[.results[] | select(.status == "fail")] | length')
printf 'Summary: %s passed, %s warning, %s blocking failure.\n' "$PASSED" "$WARNED" "$FAILED"

[ "$(printf '%s' "$SUMMARY" | jq -r '.status')" != fail ]
