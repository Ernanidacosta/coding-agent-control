# Progress

## Current

Status: verifying
Task: CAC-POST-1.0-PERF-TOML: parse each policy document once per resolution instead of once per key, reusing the existing strict toml_document output through function-local variables (no persistent cache, no new parser, helper or dependency); core _lib.sh and the vendored authority phase-a-source.sh change identically. A/B against docs/performance-baseline-v1.0.1.md; no policy, Risk, timeout, Stop, receipt-format, trust-boundary or installer change.
Risk: high

## Scope

- .claude/hooks/_lib.sh
- examples/local-issuer/phase-a-source.sh
- tests/toml-parse-reuse.bats
- memory/**

## Next

- Mechanism changes (.claude/hooks/_lib.sh) and so do the authority programs (examples/local-issuer/phase-a-source.sh): consumers need a reinstall and local-authority projects (affiliate-status-bot) a reapproval. Distribution goes through a new RC, as a separate owner task.
- Checkpoint verifying, then CI, exact-SHA attestation and verify.sh; close with Status done and the same evidence. PR merges only with owner authorization.
- Consumers stay on v1.0.1; no release.
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-POST-1.0-PERFORMANCE-BASELINE: docs/performance-baseline-v1.0.1.md; idle verify median 658.7 s (611.6-728.0) against 900 s, contention 3x VERIFY_TOTAL_TIMEOUT (uncapped about 1299 s); suite 84 %, authority tests 71.7 % of test time, about 1.4 M processes per verify, TOML reparsed 48-200 times per evaluation; verifying checkpoint e090d48 (CI 42401240304, exact-SHA attestation, verify 3 passed).
- Published v1.0.1 (stable, Latest): release commit 54e3d957872b6087aeb6f9e164fe5fecaf46780b (CI 41922202095, exact-SHA attestation, verify 4 passed), annotated tag 336dfdd7f366fd3aa1e95f454f70a29d2ebcf822; published Quickstart smoke PASS.
- CAC-V1.0.1-READINESS: v1.0.1-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 470e441 (CI 41767016340, exact-SHA attestation, verify 4 passed), waha-operacional-tm2 c616991 and affiliate-status-bot 6383530 (receipt 204 reusable); the known limitations are the GB-4 accepted ones.
- Published v1.0.1-rc1 (pre-release): release commit 3caf86345a215b384e5656985686ef4fedb92139 (CI 41704649495, exact-SHA attestation, verify 4 passed), annotated tag 60c1bcd49b17080fd243c6a5ec53abfb05cf5be5; published Quickstart smoke PASS.
- CAC-POST-1.0-SIMPLICITY-GUARDRAILS merged to main as de2c1b44676dd7cf7a90b84c0b9c147ad82c3123 (PR #2; checkpoints f7c3bb8 and 10c0948, CI 41535915713 and 41540987103, main CI 41665658247, exact-SHA attestation each, verify 4 passed); advisory guardrails in AGENT.md section 6, AGENT.md 30714/30720 bytes; no mechanism, trust or policy change.
