# Progress

## Current

Status: active
Task: CAC-CORRECTIVE-V1.0.3 — one corrective campaign (baseline fixtures, CAC-001 destructive-command targets, CAC-002 pre-commit equivalence, CAC-003 blocked-task Stop lifecycle, CAC-004 host hook activation), validated together before a single release candidate.
Risk: high

## Scope

- tests/**
- .claude/hooks/**
- .codex/hooks/**
- .githooks/**
- .agent-md/bin/**
- install.sh
- AGENT.md
- CLAUDE.md
- README.md
- memory/progress.md

## Next

- Real Codex sessions on the owner-approved fixture passed at e35deec: A (Stop ran verification once), B (blocked handoff, Stop ran, 0 verifications, one turn), C (PreToolUse FATAL SAFETY_TARGET_INDETERMINATE, data intact).
- Readiness corrections in one commit: doctor matches the CAC handlers by event, matcher and command; handoff currency scans every relevant change and the README states its ceiling. Then CI, exact-SHA attestation, verify.sh and the A/B/C rerun on the new SHA.

## Blockers

None

## Recently Completed

- Published v1.0.2 (stable): release commit e0da28103f8d1bcaebad8383eb915486f78a2cf8 (CI 43569526357), annotated tag f4287fedfafb718cd4e1906c19eb60d0d4275ba8.
- CAC-V1.0.2-READINESS: v1.0.2-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 704a978 (CI 42481999429, exact-SHA attestation), waha-operacional-tm2 c616991 (verify 50 -> 4 parses, Stop 56 -> 6) and affiliate-status-bot 6383530 (authority reinstalled and reapproved, receipt 206 reusable); outputs, strict parser and core/authority parity unchanged on 12 edge cases; clean install and reinstall idempotent.
- Published v1.0.2-rc1 (pre-release): release commit 17c8c9d6d9f5eea8caa75d3a47af6b9c31573a78 (CI 42454453010, exact-SHA attestation), annotated tag c5bffde26a17457a9e720b9ec83ebac58b901493.
- CAC-POST-1.0-PERF-TOML merged to main as 10795442ceee374fc9bda8a5e012d75e90249f9a (PR #4; main CI 42452350993, exact-SHA attestation, verify 4 passed): one parse per resolution; parses verify/Stop 54 -> 4, receipt-verify 200 -> 8; interleaved A/B same host: suite 571.2 -> 520.5 s (-8.9 %), framework verify -8 %, Stop -10 to -13 %, receipt-verify -18.6 %, representative authority test -5.6 %; process count unchanged (the saved work is the awk exec, not the subshell); full verify idle median 625.7 s vs baseline 658.7 s (within the baseline spread). Checkpoints 160af7e and f1c776a (CI 42410767506 and 42417084490, exact-SHA attestation each). Mechanism and authority programs changed: reinstall and local-authority reapproval needed; ships only through a new RC.
- CAC-POST-1.0-PERFORMANCE-BASELINE: docs/performance-baseline-v1.0.1.md; idle verify median 658.7 s (611.6-728.0) against 900 s, contention 3x VERIFY_TOTAL_TIMEOUT (uncapped about 1299 s); suite 84 %, authority tests 71.7 % of test time, about 1.4 M processes per verify, TOML reparsed 48-200 times per evaluation; verifying checkpoint e090d48 (CI 42401240304, exact-SHA attestation, verify 3 passed).
