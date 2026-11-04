# Progress

## Current

Status: done
Task: CAC-V1.0.1-PUBLISH: promote v1.0.1-rc1 (3caf863, dogfooded in ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot; readiness YES, no RC2) to stable v1.0.1. Release commit points the Stable Quickstart at v1.0.1 in both READMEs, the install.sh usage comment and tests/install.bats, and removes the promoted Release candidate block; no installer behavior, directive, mechanism, host config, policy, trust, authority or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- Release delta 3caf863..release commit: README.md, README.pt-BR.md, install.sh (comments only), tests/install.bats, memory/; directives and every operational path unchanged.
- This release commit needs its own CI, exact-SHA attestation and final verify.sh before tagging v1.0.1 (annotated, stable, Latest). v1.0.0, v1.0.1-rc1 and every existing tag stay untouched.
- Consumers stay on v1.0.1-rc1 until a separate owner task converges them on v1.0.1.
- Not started: CAC-POST-1.0-PERFORMANCE-BASELINE.
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-V1.0.1-READINESS: v1.0.1-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 470e441 (CI 41767016340, exact-SHA attestation, verify 4 passed), waha-operacional-tm2 c616991 and affiliate-status-bot 6383530 (receipt 204 reusable); the known limitations are the GB-4 accepted ones.
- Published v1.0.1-rc1 (pre-release): release commit 3caf86345a215b384e5656985686ef4fedb92139 (CI 41704649495, exact-SHA attestation, verify 4 passed), annotated tag 60c1bcd49b17080fd243c6a5ec53abfb05cf5be5; published Quickstart smoke PASS.
- CAC-POST-1.0-SIMPLICITY-GUARDRAILS merged to main as de2c1b44676dd7cf7a90b84c0b9c147ad82c3123 (PR #2; checkpoints f7c3bb8 and 10c0948, CI 41535915713 and 41540987103, main CI 41665658247, exact-SHA attestation each, verify 4 passed); advisory guardrails in AGENT.md section 6, AGENT.md 30714/30720 bytes; no mechanism, trust or policy change.
- CAC-GOLDEN-BASELINE-4 frozen at bda5c0b4d3dc582f57a88af0099d952a804dbd5f on v1.0.0 (tag bbc48bc peels to 6714cc9); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; v1.0.0 line closed.
- Published v1.0.0 (stable, Latest): release commit 6714cc9a90327fb5fccd2f36db8bacc48d6a0222 (Quickstart ref bump only; CI 41369614661, exact-SHA attestation, verify 4 passed), annotated tag bbc48bc6c3e648512c442fe33831fc6ace8bd053; published Quickstart smoke PASS; rolled out to the three consumers without regression.
