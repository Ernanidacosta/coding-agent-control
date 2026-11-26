# Progress

## Current

Status: active
Task: CAC-CORRECTIVE-V1.0.3 — one corrective campaign: baseline fixture recovery, blocked-task Stop lifecycle, destructive-command target integrity, pre-commit equivalence-or-refusal; validated together before a single release candidate.
Risk: high

## Scope

- tests/**
- memory/progress.md

## Next

- Baseline fixture recovery: TLS fixtures declare SKI/AKI through one shared generator (tests/tls-fixture.bash, also used by the integration harness) and the suite runner drops the invoking hook's host identity. Push the campaign branch for CI and exact-SHA independent attestation; local verify is not the recovery evidence. CI on 75ea70a found the host-isolation probe defined with a leading test keyword inside a heredoc, which bats preprocesses (1125 collected, 1124 executed); the probe is now written with printf and checked under Bats 1.10 and 1.14.
- Then, in order: blocked-task Stop lifecycle, destructive-command target integrity, pre-commit equivalence-or-refusal. Each with RED/GREEN on short synthetic fixtures; integrated verify before any release candidate. No tags, releases, merge to main or consumer change in this campaign until reviewed.

## Blockers

None

## Recently Completed

- Published v1.0.2 (stable): release commit e0da28103f8d1bcaebad8383eb915486f78a2cf8 (CI 43569526357), annotated tag f4287fedfafb718cd4e1906c19eb60d0d4275ba8.
- CAC-V1.0.2-READINESS: v1.0.2-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 704a978 (CI 42481999429, exact-SHA attestation), waha-operacional-tm2 c616991 (verify 50 -> 4 parses, Stop 56 -> 6) and affiliate-status-bot 6383530 (authority reinstalled and reapproved, receipt 206 reusable); outputs, strict parser and core/authority parity unchanged on 12 edge cases; clean install and reinstall idempotent.
- Published v1.0.2-rc1 (pre-release): release commit 17c8c9d6d9f5eea8caa75d3a47af6b9c31573a78 (CI 42454453010, exact-SHA attestation), annotated tag c5bffde26a17457a9e720b9ec83ebac58b901493.
- CAC-POST-1.0-PERF-TOML merged to main as 10795442ceee374fc9bda8a5e012d75e90249f9a (PR #4; main CI 42452350993, exact-SHA attestation, verify 4 passed): one parse per resolution; parses verify/Stop 54 -> 4, receipt-verify 200 -> 8; interleaved A/B same host: suite 571.2 -> 520.5 s (-8.9 %), framework verify -8 %, Stop -10 to -13 %, receipt-verify -18.6 %, representative authority test -5.6 %; process count unchanged (the saved work is the awk exec, not the subshell); full verify idle median 625.7 s vs baseline 658.7 s (within the baseline spread). Checkpoints 160af7e and f1c776a (CI 42410767506 and 42417084490, exact-SHA attestation each). Mechanism and authority programs changed: reinstall and local-authority reapproval needed; ships only through a new RC.
- CAC-POST-1.0-PERFORMANCE-BASELINE: docs/performance-baseline-v1.0.1.md; idle verify median 658.7 s (611.6-728.0) against 900 s, contention 3x VERIFY_TOTAL_TIMEOUT (uncapped about 1299 s); suite 84 %, authority tests 71.7 % of test time, about 1.4 M processes per verify, TOML reparsed 48-200 times per evaluation; verifying checkpoint e090d48 (CI 42401240304, exact-SHA attestation, verify 3 passed).
