#!/bin/bash
# sensory-reminder.sh
# Stop hook for UI changes.
#
# Two modes, chosen via agent-md.toml:
#
#   [visual] required = false   (default)  → advisory reminder only.
#                                            Emits additionalContext
#                                            suggesting screenshot+VLM.
#
#   [visual] required = true               → blocking. Stop is denied
#                                            unless STRUCTURED evidence
#                                            exists under artifacts_dir:
#                                            a fresh markdown note that
#                                            references a fresh image by
#                                            filename. A lone screenshot
#                                            is NOT a verification claim
#                                            — the prose is the claim.
#
# No stop_hook_active bypass for blocks. A retry does not manufacture
# evidence. The only way out is to produce the artifact or establish a
# reviewed policy baseline that no longer requires it. A same-change flip
# cannot weaken it. The flag bounds advisory context only: the reminder and
# the evidence-found note carry no decision to satisfy, so they are said
# once per stop cycle rather than on every retry. See the stop-hook input
# contract in _lib.sh.

# shellcheck source=.claude/hooks/_lib.sh
. "$(dirname "$0")/_lib.sh"

HOOK_INPUT=$(cat)

git rev-parse --is-inside-work-tree &>/dev/null || exit 0

UI_PATTERN='\.(tsx|jsx|vue|svelte|astro|css|scss|sass|html)$'
UI_CHANGED=$(
  {
    git diff --name-only 2>/dev/null
    git diff --cached --name-only 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | grep -cE "$UI_PATTERN"
)
UI_CHANGED=${UI_CHANGED:-0}

if [ "$UI_CHANGED" -eq 0 ]; then
  exit 0
fi

VISUAL_CONTRACT=$(effective_visual_contract_json worktree)
if [ "$(printf '%s' "$VISUAL_CONTRACT" | jq -r '.valid')" != true ]; then
  RESULT=$(policy_result_json fail error CONFIG_INVALID \
    "$(printf '%s' "$VISUAL_CONTRACT" | jq -r '.error')" \
    "Fix the visual policy before claiming completion.")
  REASON=$(policy_human_message "$RESULT")
  emit_stop_block "$REASON"
  exit 0
fi
REQUIRED=$(printf '%s' "$VISUAL_CONTRACT" | jq -r '.required')
ART_DIR=$(printf '%s' "$VISUAL_CONTRACT" | jq -r '.artifacts_dir')
FRESH=$(printf '%s' "$VISUAL_CONTRACT" | jq -r '.freshness_seconds')

if [ "$REQUIRED" = "true" ]; then
  if visual_evidence_ok "$ART_DIR" "$FRESH"; then
    MSG="Visual validation: structured evidence found in ${ART_DIR} (markdown note + referenced image, both fresh). Confirm to the user which UI diff the evidence validates."
    emit_stop_advisory "$HOOK_INPUT" "$MSG"
    exit 0
  fi

  RESULT=$(policy_result_json \
    "fail" "error" "VERIFY_REQUIRED_FAILED" \
    "Visual validation is required for ${UI_CHANGED} changed UI file(s), but structured evidence is missing from ${ART_DIR}." \
    "Capture a fresh screenshot and add a fresh markdown note with Changed files, Route or URL, Viewport, Artifact, and Observed result; a screenshot alone is not verification.")
  REASON=$(policy_human_message "$RESULT")
  emit_stop_block "$REASON"
  exit 0
fi

# Reminder mode (default, advisory)
RESULT=$(policy_result_json \
  "warn" "warning" "QUALITY_VISUAL_EVIDENCE_RECOMMENDED" \
  "UI files changed (${UI_CHANGED}) without required visual evidence." \
  "Build and render the change, capture a screenshot, and record Changed files, Route or URL, Viewport, Artifact, and Observed result in a markdown note. Set [visual] required = true to make this blocking.")
MSG=$(policy_human_message "$RESULT")
emit_stop_advisory "$HOOK_INPUT" "$MSG"
exit 0
