# Progress

## Current

Status: verifying
Task: Consolidate the approved Claude subagent lifecycle implementation through published checkpoints and exact-SHA external verification.
Risk: high

## Scope

- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Commit and publish this verifying checkpoint with normal hooks; require its CI and independent attestation before done. Then publish done, validate that exact SHA externally and run the full verify.sh entry point. No further implementation or roadmap work.

## Blockers

None

## Recently Completed

- Technical commit c08807bc3794143571bdc4dc157098a46d5ac469 published with normal hooks: lint, smoke, test and operational state passed; commit duration 684.45s. Its CI passed all four jobs: https://github.com/Ernanidacosta/coding-agent-control/actions/runs/37873929500. The established independent verifier returned pass, kind independent, origin ci, bound to that exact SHA.
- Owner-approved full local verify.sh passed before the technical commit: exit 0, 786.33s, 1001 tests passed, none failed/skipped, lint/smoke/test passed, zero gate warnings/blocking failures. Contract remains 750/900; evidence outside checkout: /tmp/cac-claude-official-gate.NujsJf/.
- Native allow, block/retry/recovery and internal-event exclusion passed with source-matched scripts; parent Stop stayed separate and global configuration unchanged. Evidence: .agent/claude-lifecycle-20261007/native-summary-hostfix.json. Focused coverage: 113 distinct cases; host-inheritance regression and Stop protocol also passed 41/41 under inherited codex with six jobs.
- Accepted limitations: orphan identities remain until termination is confirmed; failed Start registration diagnoses missing tracking but Claude cannot block creation at that event. No automatic identity expiry, directive injection or policy relaxation.
