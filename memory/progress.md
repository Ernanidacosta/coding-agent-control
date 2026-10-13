# Progress

## Current

Status: done
Task: Consolidate the approved v1.0.0-rc1 recommended baseline through normal operational checkpoints and publish an immutable tag at the final done SHA.
Risk: high

## Scope

- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Publish the annotated v1.0.0-rc1 tag at this final done checkpoint only after its own CI, independent verification and final verify.sh pass with clean synchronized Git. Next separate task: Roll out v1.0.0-rc1 to affiliate-status-bot; do not begin that rollout here.

## Blockers

None

## Recently Completed

- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Approved active checkpoint 306c8eb14d80364d6fd9604202e32ed9b7efe971 published with normal hooks (599.67s, 1013/1013 tests), CI 38337666462 passing all four jobs and independent verification passing for that exact SHA. No implementation, policy or trust changes; no bypass.
- Verifying checkpoint 78a38b485ac8e6c37955e06bb94bcbce99d0fca4 published after the valid active-to-verifying transition, normal hooks (599.09s, 1013/1013 tests), CI 38340569473 passing all four jobs and exact-SHA independent verification. Final done acceptance requires this checkpoint's own external gates and verify.sh.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
