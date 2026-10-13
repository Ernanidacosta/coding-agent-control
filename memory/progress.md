# Progress

## Current

Status: active
Task: Consolidate the approved v1.0.0-rc1 recommended baseline through normal operational checkpoints and publish an immutable tag at the final done SHA.
Risk: high

## Scope

- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Publish the approved active checkpoint after normal hooks and obtain its exact-SHA CI/independent evidence; advance through verifying and done, run final verify.sh, then publish the annotated tag. Roll out v1.0.0-rc1 to affiliate-status-bot only in the next separate task.

## Blockers

None

## Recently Completed

- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Candidate CI 38314001771 and exact-SHA independent verification passed; final official verify.sh exited 0 in 709.78s with policy 750/900 and no summary warnings or blocking failures.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
