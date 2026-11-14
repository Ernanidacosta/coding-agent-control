# Progress

## Current

Status: done
Task: CAC-V1.0.2-PUBLISH: promote v1.0.2-rc1 (17c8c9d, dogfooded in ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot; readiness YES, no RC2) to stable v1.0.2. Release commit points the Stable Quickstart at v1.0.2 in both READMEs, the install.sh usage comment and tests/install.bats, and removes the promoted Release candidate block; no installer behavior, directive, mechanism, host config, policy, trust, authority or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- Release delta 17c8c9d..release commit: README.md, README.pt-BR.md, install.sh (comments only), tests/install.bats, memory/; directives, mechanism, authority programs, policy and trust material unchanged.
- This release commit needs its own CI, exact-SHA attestation and final verify.sh before tagging v1.0.2 (annotated, stable, Latest). v1.0.1, v1.0.2-rc1 and every existing tag stay untouched.
- Consumers stay on v1.0.2-rc1 until a separate owner task converges them on v1.0.2; the receipt snapshot includes install-provenance.json, so affiliate-status-bot needs a new receipt after converging.
- Known performance follow-up (backlog, not a blocker): under Risk high, attestation_trust_anchor_json and risk_evidence_command_trusted still read the policy outside the per-resolution reuse.
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-V1.0.2-READINESS: v1.0.2-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 704a978 (CI 42481999429, exact-SHA attestation), waha-operacional-tm2 c616991 (verify 50 -> 4 parses, Stop 56 -> 6) and affiliate-status-bot 6383530 (authority reinstalled and reapproved, receipt 206 reusable); outputs, strict parser and core/authority parity unchanged on 12 edge cases; clean install and reinstall idempotent.
- Published v1.0.2-rc1 (pre-release): release commit 17c8c9d6d9f5eea8caa75d3a47af6b9c31573a78 (CI 42454453010, exact-SHA attestation), annotated tag c5bffde26a17457a9e720b9ec83ebac58b901493.
- CAC-POST-1.0-PERF-TOML merged to main as 10795442ceee374fc9bda8a5e012d75e90249f9a (PR #4; main CI 42452350993, exact-SHA attestation, verify 4 passed): one parse per resolution; parses verify/Stop 54 -> 4, receipt-verify 200 -> 8; interleaved A/B same host: suite 571.2 -> 520.5 s (-8.9 %), framework verify -8 %, Stop -10 to -13 %, receipt-verify -18.6 %, representative authority test -5.6 %; process count unchanged (the saved work is the awk exec, not the subshell); full verify idle median 625.7 s vs baseline 658.7 s (within the baseline spread). Checkpoints 160af7e and f1c776a (CI 42410767506 and 42417084490, exact-SHA attestation each). Mechanism and authority programs changed: reinstall and local-authority reapproval needed; ships only through a new RC.
- CAC-POST-1.0-PERFORMANCE-BASELINE: docs/performance-baseline-v1.0.1.md; idle verify median 658.7 s (611.6-728.0) against 900 s, contention 3x VERIFY_TOTAL_TIMEOUT (uncapped about 1299 s); suite 84 %, authority tests 71.7 % of test time, about 1.4 M processes per verify, TOML reparsed 48-200 times per evaluation; verifying checkpoint e090d48 (CI 42401240304, exact-SHA attestation, verify 3 passed).
- Published v1.0.1 (stable, Latest): release commit 54e3d957872b6087aeb6f9e164fe5fecaf46780b (CI 41922202095, exact-SHA attestation, verify 4 passed), annotated tag 336dfdd7f366fd3aa1e95f454f70a29d2ebcf822; published Quickstart smoke PASS.
