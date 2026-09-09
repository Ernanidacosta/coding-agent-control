#!/bin/bash
# doctor.sh — check an agent-md installation for common wiring problems
# Usage: ./.agent-md/bin/doctor.sh

set -u

FAIL=0

ok() { printf 'ok  %s\n' "$*"; }
warn() { printf 'warn %s\n' "$*"; }
bad() { printf 'bad %s\n' "$*"; FAIL=1; }

have() {
  command -v "$1" >/dev/null 2>&1
}

have git || bad "git is not installed"
have jq || bad "jq is not installed; hooks need it for JSON parsing"
have bash || bad "bash is not installed"

SHARED_LIB=.claude/hooks/_lib.sh
if [ -f "$SHARED_LIB" ]; then
  # shellcheck source=.claude/hooks/_lib.sh
  . "$SHARED_LIB"
else
  bad "shared policy library missing: $SHARED_LIB"
fi

if [ -f AGENT.md ]; then
  ok "AGENT.md exists"
else
  bad "AGENT.md missing"
fi

if [ -f AGENT.md ] && [ -f CLAUDE.md ]; then
  if cmp -s AGENT.md CLAUDE.md; then
    ok "CLAUDE.md matches AGENT.md"
  else
    bad "CLAUDE.md drifted from AGENT.md"
  fi
fi

if [ -f AGENTS.md ]; then
  ok "AGENTS.md exists"
elif [ -d .codex ] || [ -d .cursor ] || [ -d .windsurf ]; then
  warn "AGENTS.md missing for an installed Codex/Cursor/Windsurf integration"
fi
if [ -f .claude/settings.json ]; then
  ok "Claude settings present"
elif [ -f CLAUDE.md ]; then
  warn "Claude settings missing for the installed Claude integration"
fi
if [ -f .codex/hooks.json ]; then
  ok "Codex hooks present"
elif [ -d .codex ]; then
  warn "Codex hooks missing for the installed Codex integration"
fi
if [ -f .codex/hooks.json ]; then
  for SHARED_HOOK in _lib.sh block-destructive.sh truncation-check.sh \
    stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
    if [ ! -f ".claude/hooks/$SHARED_HOOK" ]; then
      bad "Codex shared hook dependency missing: .claude/hooks/$SHARED_HOOK"
    fi
  done
fi
if [ -d .agent-md/bin ]; then ok "agent-md helpers present"; else warn ".agent-md/bin missing"; fi
if [ -d memory ]; then ok "memory directory present"; else warn "memory directory missing"; fi

if [ -f "$SHARED_LIB" ]; then
  CONTRACT=$(effective_verification_contract_json worktree)
  printf 'Verification:\n'
  if [ "$(printf '%s' "$CONTRACT" | jq -r '.valid')" != true ]; then
    bad "$(policy_human_message "$(printf '%s' "$CONTRACT" | jq -c '.error')")"
  else
    printf '  %-12s %-10s %-15s %s\n' check policy origin availability
    while IFS= read -r SPEC; do
      [ -n "$SPEC" ] || continue
      CHECK_NAME=$(printf '%s' "$SPEC" | jq -r '.name')
      REQUIREMENT=$(printf '%s' "$SPEC" | jq -r '.requirement')
      ORIGIN=$(printf '%s' "$SPEC" | jq -r '.origin')
      COMMAND=$(printf '%s' "$SPEC" | jq -r '.command')
      AVAILABILITY="not configured"
      if [ "$ORIGIN" != "not configured" ]; then
        if verification_command_preflight "$COMMAND"; then
          AVAILABILITY="available"
        else
          PREFLIGHT_STATUS=$?
          case "$PREFLIGHT_STATUS" in
            1) AVAILABILITY="unavailable" ;;
            2) AVAILABILITY="not preflighted" ;;
            *) AVAILABILITY="invalid" ;;
          esac
        fi
      fi
      printf '  %-12s %-10s %-15s %s\n' \
        "$CHECK_NAME" "$REQUIREMENT" "$ORIGIN" "$AVAILABILITY"
      if [ "$REQUIREMENT" = required ] && [ "$ORIGIN" = "not configured" ]; then
        bad "[ERROR VERIFY_UNAVAILABLE] Required check '$CHECK_NAME' has no command. Recovery: configure verify.$CHECK_NAME."
      elif [ "$AVAILABILITY" = unavailable ] || [ "$AVAILABILITY" = invalid ]; then
        if [ "$REQUIREMENT" = required ]; then
          bad "[ERROR VERIFY_UNAVAILABLE] Required check '$CHECK_NAME' is $AVAILABILITY. Recovery: fix or install its command."
        else
          warn "[WARNING VERIFY_UNAVAILABLE] Optional check '$CHECK_NAME' is $AVAILABILITY."
        fi
      fi
    done < <(printf '%s' "$CONTRACT" | jq -c \
      '.checks[] | select(.name != "independent" and .name != "approval")')
    TIMEOUT=$(printf '%s' "$CONTRACT" | jq -r '.timeout_seconds // empty')
    if [ -n "$TIMEOUT" ]; then
      if have timeout || have gtimeout; then
        ok "verification timeout is ${TIMEOUT}s"
      else
        bad "[ERROR VERIFY_UNAVAILABLE] timeout is configured but timeout/gtimeout is unavailable"
      fi
    elif [ "$(printf '%s' "$CONTRACT" | jq \
      '[.checks[] | select(.name != "independent" and .name != "approval" and .origin != "not configured")] | length')" -eq 0 ]; then
      ok "verification timeout is not applicable until a check is configured or inferred"
    else
      warn "verification timeout is not configured; host limits remain the only bound"
    fi
  fi
fi

if [ -f "$SHARED_LIB" ]; then
  CONTROL=$(effective_control_requirements_json worktree)
  CONTROL_SOURCE=$(printf '%s' "$CONTROL" | jq -r '.source')
  CONTROL_BASELINE_RISK=$(printf '%s' "$CONTROL" | jq -r '.baseline.risk // "not established"')
  CONTROL_PROPOSED_RISK=$(printf '%s' "$CONTROL" | jq -r '.proposal.risk // "not declared"')
  CONTROL_EFFECTIVE_RISK=$(printf '%s' "$CONTROL" | jq -r '.effective.risk // "not established"')
  CONTROL_DOWNGRADE=$(printf '%s' "$CONTROL" | jq -r '.risk_downgrade')
  CONTROL_POLICY_STATUS=$(printf '%s' "$CONTROL" | jq -r '.policy.status')
  printf 'Control:\n'
  printf '  source: %s\n' "$CONTROL_SOURCE"
  printf '  baseline risk: %s\n' "$CONTROL_BASELINE_RISK"
  printf '  proposed risk: %s\n' "$CONTROL_PROPOSED_RISK"
  printf '  effective risk: %s\n' "$CONTROL_EFFECTIVE_RISK"
  printf '  downgrade status: %s\n' "$CONTROL_DOWNGRADE"
  printf '  policy baseline/proposal: %s\n' "$CONTROL_POLICY_STATUS"
  if [ "$CONTROL_SOURCE" = legacy-progress ]; then
    printf '  legacy state: detected; migration recommended\n'
    printf '  Recovery: explicitly create and review .project-control.toml; no automatic migration is performed.\n'
  elif [ "$CONTROL_SOURCE" = none ]; then
    printf '  Recovery: create .project-control.toml before claiming completion; ordinary work may continue.\n'
  elif [ "$CONTROL_DOWNGRADE" = pending ]; then
    printf '  Recovery: establish the downgrade through out-of-band human review or authority-separated approval.\n'
  else
    printf '  Recovery: none.\n'
  fi

  printf 'Working state:\n'
  if [ -f memory/progress.md ]; then
    if git ls-files --error-unmatch memory/progress.md >/dev/null 2>&1; then
      printf '  progress: present, tracked, legacy-compatible\n'
    else
      printf '  progress: present, local/untracked\n'
    fi
    DOCTOR_PROGRESS_STATUS=$(progress_status_from_content "$(cat memory/progress.md)")
    DOCTOR_PROGRESS_STATUS=${DOCTOR_PROGRESS_STATUS:-invalid}
  else
    printf '  progress: absent; ordinary work remains available\n'
    DOCTOR_PROGRESS_STATUS=absent
  fi

  printf 'Completion:\n'
  printf '  claim state: %s\n' "$DOCTOR_PROGRESS_STATUS"
  printf '  currently required guarantees: Risk %s plus the effective verification policy\n' "$CONTROL_EFFECTIVE_RISK"
  if [ "$DOCTOR_PROGRESS_STATUS" = "done" ] && \
    { [ "$CONTROL_EFFECTIVE_RISK" = "not established" ] || [ "$(printf '%s' "$CONTROL" | jq -r '.valid')" != true ]; }; then
    printf '  blockers: control baseline is missing or invalid\n'
    printf '  Recovery: establish valid Git-bound control before asking for completion acceptance.\n'
  elif [ "$CONTROL_DOWNGRADE" = pending ]; then
    printf '  blockers: proposed downgrade does not reduce current requirements\n'
    printf '  Recovery: keep the baseline requirements or establish authorized downgrade authority.\n'
  else
    printf '  blockers: none detected by configuration-only diagnosis\n'
    printf '  Recovery: run agent-md verify to evaluate fresh evidence before accepting done.\n'
  fi
fi

if [ -f "$SHARED_LIB" ] && [ -f memory/progress.md ]; then
  PROGRESS_CONTENT=$(cat memory/progress.md)
  printf 'Risk:\n'
  if ! PROGRESS_ERROR=$(validate_progress_content "$PROGRESS_CONTENT"); then
    bad "[ERROR STATE_PROGRESS_INVALID] $PROGRESS_ERROR"
  else
    PROGRESS_STATUS=$(progress_status_from_content "$PROGRESS_CONTENT")
    RISK_VALUE=$(printf '%s' "$CONTROL" | jq -r '.effective.risk // empty')
    if [ -n "$RISK_VALUE" ]; then RISK_COUNT=1; else RISK_COUNT=0; fi
    RISK_FILES=$(risk_changed_files worktree || true)
    RISK_SIGNALS=$(risk_signals_for_files "$RISK_FILES" worktree)
    printf '  declared: %s\n' "${RISK_VALUE:-not declared}"
    printf '  status: %s\n' "$PROGRESS_STATUS"
    printf '  signals: %s\n' "$(if [ -n "$RISK_SIGNALS" ]; then printf '%s\n' "$RISK_SIGNALS" | awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print "" }'; else printf none; fi)"
    if [ "$RISK_COUNT" -eq 0 ]; then
      if [ -n "$RISK_FILES" ]; then
        warn "[WARNING RISK_NOT_DECLARED] Relevant work has no declared Risk; no low default was inferred."
      fi
      printf '  consistency: not declared\n'
    elif [ "$RISK_COUNT" -ne 1 ] || ! printf '%s\n' "$RISK_VALUE" | grep -Eq '^(low|medium|high|critical)$'; then
      bad "[ERROR RISK_INVALID] Risk must occur once and be low, medium, high, or critical."
      printf '  consistency: invalid\n'
    elif [ -n "$(risk_underrating_signals "$RISK_VALUE" "$RISK_SIGNALS")" ]; then
      warn "[WARNING RISK_POSSIBLY_UNDERRATED] Declared Risk may be inconsistent with observed signals."
      printf '  consistency: review suggested\n'
    else
      printf '  consistency: ok\n'
    fi

    if [ "$(printf '%s' "$CONTRACT" | jq -r '.valid')" = true ]; then
      printf 'Requirements:\n'
      REQUIRED_MISSING=$(printf '%s' "$CONTRACT" | jq '[.checks[] | select(.requirement == "required" and .origin == "not configured")] | length')
      if [ "$REQUIRED_MISSING" -eq 0 ]; then
        printf '  required checks: configured\n'
      else
        printf '  required checks: missing\n'
      fi
      RUNTIME_COUNT=$(printf '%s' "$CONTRACT" | jq '[.checks[] | select((.name == "runtime" or .name == "smoke") and .origin != "not configured")] | length')
      if [ "$RUNTIME_COUNT" -gt 0 ]; then
        printf '  runtime/smoke: configured\n'
      elif printf '%s\n' "$RISK_VALUE" | grep -Eq '^(medium|high|critical)$'; then
        printf '  runtime/smoke: not configured (applicability advisory)\n'
      else
        printf '  runtime/smoke: not required by current risk\n'
      fi

      for EVIDENCE_CHECK in independent approval; do
        EVIDENCE_ORIGIN=$(printf '%s' "$CONTRACT" | jq -r --arg check "$EVIDENCE_CHECK" '.checks[] | select(.name == $check) | .origin')
        EVIDENCE_CAPABILITIES=$(printf '%s' "$CONTRACT" | jq -r --arg check "$EVIDENCE_CHECK" \
          '.checks[] | select(.name == $check) | .capabilities | if length == 0 then "not declared" else join(", ") end')
        if [ "$EVIDENCE_CHECK" = independent ]; then
          EVIDENCE_HEADING="Independent verification"
          EVIDENCE_DETAIL_LABEL=Independent
          EVIDENCE_MISSING_CODE=RISK_INDEPENDENT_VERIFICATION_REQUIRED
          case "$RISK_VALUE" in high|critical) EVIDENCE_REQUIRED=yes ;; *) EVIDENCE_REQUIRED=no ;; esac
        else
          EVIDENCE_HEADING="Human approval"
          EVIDENCE_DETAIL_LABEL=Approval
          EVIDENCE_MISSING_CODE=RISK_HUMAN_APPROVAL_REQUIRED
          if [ "$RISK_VALUE" = critical ]; then EVIDENCE_REQUIRED=yes; else EVIDENCE_REQUIRED=no; fi
        fi
        EVIDENCE_REQUIRED_NOW=no
        if [ "$PROGRESS_STATUS" = "done" ] && [ "$EVIDENCE_REQUIRED" = yes ]; then
          EVIDENCE_REQUIRED_NOW=yes
        fi

        printf '%s:\n' "$EVIDENCE_HEADING"
        printf '  required for completion: %s\n' "$EVIDENCE_REQUIRED"
        printf '  required now: %s\n' "$EVIDENCE_REQUIRED_NOW"
        printf '  configured: %s\n' "$(if [ "$EVIDENCE_ORIGIN" = configured ]; then printf yes; else printf no; fi)"
        if [ "$EVIDENCE_ORIGIN" != configured ]; then
          printf '  status: not configured\n'
          printf '  blocking now: %s\n' "$EVIDENCE_REQUIRED_NOW"
          if [ "$EVIDENCE_REQUIRED_NOW" = yes ]; then
            printf '  Effect: completion is blocked; implementation work remains available.\n'
            printf '  Recovery: configure a trusted verify.%s command and provide the required external evidence.\n' "$EVIDENCE_CHECK"
            bad "[ERROR $EVIDENCE_MISSING_CODE] $EVIDENCE_HEADING is required before this ${RISK_VALUE}-risk task can be completed. Recovery: configure a trusted verify.$EVIDENCE_CHECK command and rerun agent-md verify."
          elif [ "$EVIDENCE_REQUIRED" = yes ]; then
            printf '  Effect: implementation work may continue; completion will require this capability.\n'
            printf '  Recovery: configure verify.%s before claiming done.\n' "$EVIDENCE_CHECK"
          else
            printf '  Effect: the current task does not require this capability.\n'
            printf '  Recovery: none; configure it only when project policy requires it.\n'
          fi
          continue
        fi

        EVIDENCE_ANCHOR=$(attestation_trust_anchor_json "$(toml_path)" "$EVIDENCE_CHECK")
        EVIDENCE_MISSING_CAPABILITIES=$(attestation_missing_capabilities "$CONTRACT" "$EVIDENCE_CHECK")
        if [ -n "$EVIDENCE_MISSING_CAPABILITIES" ]; then
          EVIDENCE_STATUS=unavailable
        elif [ "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.eligible')" != true ]; then
          EVIDENCE_STATUS=untrusted
        else
          EVIDENCE_STATUS=ready
        fi
        EVIDENCE_BLOCKING_NOW=no
        if [ "$EVIDENCE_REQUIRED_NOW" = yes ] && [ "$EVIDENCE_STATUS" != ready ]; then
          EVIDENCE_BLOCKING_NOW=yes
        fi
        printf '  status: %s\n' "$EVIDENCE_STATUS"
        printf '  blocking now: %s\n' "$EVIDENCE_BLOCKING_NOW"
        case "$EVIDENCE_STATUS:$EVIDENCE_REQUIRED_NOW:$EVIDENCE_REQUIRED" in
          ready:*:yes)
            printf '  Effect: no wiring blocker detected; verify/Stop still validate the external evidence.\n'
            printf '  Recovery: none for wiring; run agent-md verify when claiming completion.\n'
            ;;
          ready:*:no)
            printf '  Effect: the current task does not require this configured capability.\n'
            printf '  Recovery: none.\n'
            ;;
          unavailable:yes:*)
            printf '  Effect: completion is blocked; implementation work remains available.\n'
            printf '  Recovery: install or expose the declared provider capability, then rerun agent-md verify.\n'
            ;;
          unavailable:no:yes)
            printf '  Effect: implementation work may continue; completion will require this capability.\n'
            printf '  Recovery: install or expose the declared provider capability before claiming done.\n'
            ;;
          untrusted:yes:*)
            printf '  Effect: completion is blocked because the configured verifier is not trusted.\n'
            printf '  Recovery: restore the reviewed verifier and declared files to HEAD, then rerun doctor.\n'
            ;;
          untrusted:no:yes)
            printf '  Effect: implementation work may continue; completion will require a trusted verifier.\n'
            printf '  Recovery: establish and review the verifier baseline before claiming done.\n'
            ;;
          *)
            printf '  Effect: the current task does not require this capability.\n'
            printf '  Recovery: optional; fix the provider only before a task requires it.\n'
            ;;
        esac

        # Advanced trust details remain available after the simple status.
        printf '%s verifier:\n' "$EVIDENCE_DETAIL_LABEL"
        printf '  path: %s\n' "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.path')"
        printf '  origin: %s\n' "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.location')"
        printf '  integrity: %s\n' "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.integrity')"
        printf '  executable: %s\n' "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r 'if .executable then "yes" else "no" end')"
        printf '  trust: %s\n' "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.trust')"
        printf '  capabilities: %s\n' "$EVIDENCE_CAPABILITIES"
        if [ "$EVIDENCE_CAPABILITIES" = "not declared" ]; then
          printf '  capability status: not declared\n'
        elif [ -n "$EVIDENCE_MISSING_CAPABILITIES" ]; then
          printf '  capability status: unavailable\n'
          while IFS= read -r EVIDENCE_CAPABILITY; do
            [ -n "$EVIDENCE_CAPABILITY" ] || continue
            printf '  dependency %s: unavailable\n' "$EVIDENCE_CAPABILITY"
          done <<EOF
$EVIDENCE_MISSING_CAPABILITIES
EOF
          if [ "$EVIDENCE_REQUIRED_NOW" = yes ]; then
            bad "[ERROR VERIFY_UNAVAILABLE] $EVIDENCE_HEADING is required now, but a declared provider capability is unavailable. Recovery: install or expose the capability and rerun agent-md verify."
          elif [ "$EVIDENCE_REQUIRED" = yes ]; then
            warn "[WARNING VERIFY_UNAVAILABLE] $EVIDENCE_HEADING is unavailable, but it does not block the current status. Recovery: install or expose the capability before claiming done."
          fi
        else
          printf '  capability status: available\n'
        fi
        if [ "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.eligible')" != true ]; then
          if [ "$EVIDENCE_REQUIRED_NOW" = yes ]; then
            bad "[ERROR RISK_ATTESTATION_UNTRUSTED] $EVIDENCE_HEADING cannot be accepted because its verifier is not trusted: $(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.reason'). Recovery: restore the reviewed verifier baseline and rerun doctor."
          elif [ "$EVIDENCE_REQUIRED" = yes ]; then
            warn "[WARNING RISK_ATTESTATION_UNTRUSTED] $EVIDENCE_HEADING is not ready, but it does not block the current status: $(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.reason'). Recovery: review and commit the verifier baseline before claiming done."
          fi
        elif [ "$EVIDENCE_REQUIRED" = yes ] && \
          [ "$(printf '%s' "$EVIDENCE_ANCHOR" | jq -r '.location')" = external ]; then
          warn "$EVIDENCE_HEADING uses an environment-managed verifier; agent-md does not audit broader host ownership or parent directories."
        fi
      done
    fi
  fi
fi

# Semantic memory is optional. ICM is the current reference integration;
# detection is read-only and doctor never starts it or calls a daemon/API.
ICM_ENABLED=""
if [ -f "$SHARED_LIB" ]; then
  ICM_ENABLED=$(read_toml "$(toml_path)" integrations.icm enabled)
fi

printf 'Semantic memory:\n'
if [ "$ICM_ENABLED" = "true" ]; then
  printf '  provider: ICM\n'
  printf '  required now: no\n'
  if have icm; then
    printf '  status: available\n'
    printf '  blocking now: no\n'
    printf '  Effect: historical and semantic recall is available; operational correctness remains in Git and memory/.\n'
    printf '  Recovery: none.\n'
    ok "optional semantic memory provider is available"
  else
    printf '  status: unavailable\n'
    printf '  blocking now: no\n'
    printf '  Effect: historical recall is unavailable; core workflow unaffected.\n'
    printf '  Recovery: install ICM for recall, or disable [integrations.icm].\n'
    ICM_RESULT=$(policy_result_json \
      "warn" "warning" "INTEGRATION_ICM_UNAVAILABLE" \
      "The configured ICM semantic-memory integration is unavailable; core workflow unaffected." \
      "Install ICM for recall, or disable the optional [integrations.icm] declaration.")
    warn "$(policy_human_message "$ICM_RESULT")"
  fi
else
  printf '  provider: none\n'
  printf '  required now: no\n'
  printf '  status: not configured\n'
  printf '  blocking now: no\n'
  printf '  Effect: none; Git and memory/ provide the complete operational workflow.\n'
  printf '  Recovery: none; configure a provider only if historical recall is useful.\n'
  ok "semantic memory is optional and not configured"
fi

if git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  HOOKS_PATH=$(git config --get core.hooksPath || true)
  if [ "$HOOKS_PATH" = ".githooks" ]; then
    ok "git hook fallback is active"
  elif [ -f .githooks/pre-commit ]; then
    ok "optional git hook fallback is installed but not active"
  fi
else
  warn "not inside a git worktree"
fi

if [ "$FAIL" -eq 0 ]; then
  ok "agent-md doctor finished"
else
  bad "agent-md doctor found problems"
fi

exit "$FAIL"
