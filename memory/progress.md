# Progress

## Current

Status: done
Task: CAC-V1.0.1-RC1-PUBLISH: publish pre-release v1.0.1-rc1 from main de2c1b4 carrying only the simplicity and design guardrails. Release commit adds a Release candidate Quickstart block beside the unchanged v1.0.0 stable block in both READMEs, the install.sh usage comment and tests/install.bats; no installer behavior, mechanism, host config, policy, trust, authority or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- Release delta v1.0.0..de2c1b4: AGENT.md, CLAUDE.md, README.md, README.pt-BR.md, docs/golden-baseline.md, tests/directives.bats, memory/; no .claude, .codex, .agent-md, .githooks, examples, install.sh, agent-md.toml, .project-control.toml or .github change.
- This release commit needs its own CI, exact-SHA attestation and final verify.sh before tagging v1.0.1-rc1 (annotated, pre-release, not Latest). v1.0.0 and every existing tag stay untouched; RCs are immutable.
- Distribution: canary ia-search-jobs first, then representative consumers; stable only after dogfood. Consumer rollout is a separate owner task.
- Not started: CAC-POST-1.0-PERFORMANCE-BASELINE.
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-POST-1.0-SIMPLICITY-GUARDRAILS merged to main as de2c1b44676dd7cf7a90b84c0b9c147ad82c3123 (PR #2; checkpoints f7c3bb8 and 10c0948, CI 41535915713 and 41540987103, main CI 41665658247, exact-SHA attestation each, verify 4 passed); advisory guardrails in AGENT.md section 6, AGENT.md 30714/30720 bytes; no mechanism, trust or policy change.
- CAC-GOLDEN-BASELINE-4 frozen at bda5c0b4d3dc582f57a88af0099d952a804dbd5f on v1.0.0 (tag bbc48bc peels to 6714cc9); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; v1.0.0 line closed.
- Published v1.0.0 (stable, Latest): release commit 6714cc9a90327fb5fccd2f36db8bacc48d6a0222 (Quickstart ref bump only; CI 41369614661, exact-SHA attestation, verify 4 passed), annotated tag bbc48bc6c3e648512c442fe33831fc6ace8bd053; published Quickstart smoke PASS; rolled out to the three consumers without regression.
- CAC-GOLDEN-BASELINE-3 frozen at a36a86f7cdeb3293a972b4354c2255265558d64e on v1.0.0-rc4 (CI 41351043167, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; RC4 cwd blocker closed.
- Published v1.0.0-rc4: Quickstart ref bump 0fdf9a7 (CI 41298577221, exact-SHA attestation, verify 4 passed), annotated tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e peeling to 0fdf9a7, GitHub pre-release from the tag notes; rolled out to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot.
