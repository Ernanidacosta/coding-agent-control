# Progress

## Current

Status: done
Task: CAC-V1.0.2-RC1-PUBLISH: publish pre-release v1.0.2-rc1 from main 1079544 carrying only the TOML parse reuse (PR #4). Release commit adds a Release candidate Quickstart block beside the unchanged v1.0.1 stable block in both READMEs, the install.sh usage comment and tests/install.bats; no installer behavior, host config, policy, trust or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- Release delta v1.0.1..1079544: .claude/hooks/_lib.sh, examples/local-issuer/phase-a-source.sh, tests/toml-parse-reuse.bats, docs/performance-baseline-v1.0.1.md, memory/; verifier, attestation files, workflow, agent-md.toml, .project-control.toml and the other authority programs unchanged.
- This release commit needs its own CI, exact-SHA attestation and final verify.sh before tagging v1.0.2-rc1 (annotated, pre-release, not Latest). v1.0.1 stays stable and Latest; every existing tag stays untouched; RCs are immutable.
- Upgrade impact: mechanism and authority programs changed, so consumers reinstall and local-authority projects (affiliate-status-bot) reinstall the authority and reapprove; receipts issued under v1.0.1 go stale. Consumer rollout, canary first, is a separate owner task.
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-POST-1.0-PERF-TOML merged to main as 10795442ceee374fc9bda8a5e012d75e90249f9a (PR #4; main CI 42452350993, exact-SHA attestation, verify 4 passed): one parse per resolution; parses verify/Stop 54 -> 4, receipt-verify 200 -> 8; interleaved A/B same host: suite 571.2 -> 520.5 s (-8.9 %), framework verify -8 %, Stop -10 to -13 %, receipt-verify -18.6 %, representative authority test -5.6 %; process count unchanged (the saved work is the awk exec, not the subshell); full verify idle median 625.7 s vs baseline 658.7 s (within the baseline spread). Checkpoints 160af7e and f1c776a (CI 42410767506 and 42417084490, exact-SHA attestation each). Mechanism and authority programs changed: reinstall and local-authority reapproval needed; ships only through a new RC.
- CAC-POST-1.0-PERFORMANCE-BASELINE: docs/performance-baseline-v1.0.1.md; idle verify median 658.7 s (611.6-728.0) against 900 s, contention 3x VERIFY_TOTAL_TIMEOUT (uncapped about 1299 s); suite 84 %, authority tests 71.7 % of test time, about 1.4 M processes per verify, TOML reparsed 48-200 times per evaluation; verifying checkpoint e090d48 (CI 42401240304, exact-SHA attestation, verify 3 passed).
- Published v1.0.1 (stable, Latest): release commit 54e3d957872b6087aeb6f9e164fe5fecaf46780b (CI 41922202095, exact-SHA attestation, verify 4 passed), annotated tag 336dfdd7f366fd3aa1e95f454f70a29d2ebcf822; published Quickstart smoke PASS.
- CAC-V1.0.1-READINESS: v1.0.1-rc1 ready to promote, no RC2; rolled out to ia-search-jobs 470e441 (CI 41767016340, exact-SHA attestation, verify 4 passed), waha-operacional-tm2 c616991 and affiliate-status-bot 6383530 (receipt 204 reusable); the known limitations are the GB-4 accepted ones.
