# Progress

## Current

Status: verifying
Task: CAC-STATE-PROGRESS-DELETION-1: stop STATE_PROGRESS_STALE from treating a staged deletion as a missing source under the gitignored-progress mtime fallback.
Risk: high

## Scope

- .claude/hooks/_lib.sh
- tests/state-enforcement.bats
- memory/progress.md

## Next

- Technical active checkpoint 6c38060ee0b411ced231ecee1e38f99a068ca388: pre-commit hooks passed (675s), CI 39999627723 passed all four jobs, exact-SHA independent verification passed. Full verify.sh before that commit passed (744s, 1021 tests).
- Remaining owner sequence: this verifying checkpoint with its own CI and independent verification, then verifying -> done with CI, independent verification and final verify.sh.
- ENROLLMENT-SOURCE-ELIGIBILITY-1 is parked in `git stash` (.gitignore /.agent/ + tests/authority-source-identity.bats 23-26). Restore it byte-identical only after this task is done, clean and synchronized; do not commit it in this round.

## Blockers

- Risk high needs independent verification bound to each pushed checkpoint SHA.

## Recently Completed

- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Approved active checkpoint 306c8eb14d80364d6fd9604202e32ed9b7efe971 published with normal hooks (599.67s, 1013/1013 tests), CI 38337666462 passing all four jobs and independent verification passing for that exact SHA. No implementation, policy or trust changes; no bypass.
- Verifying checkpoint 78a38b485ac8e6c37955e06bb94bcbce99d0fca4 published after the valid active-to-verifying transition, normal hooks (599.09s, 1013/1013 tests), CI 38340569473 passing all four jobs and exact-SHA independent verification. Final done acceptance requires this checkpoint's own external gates and verify.sh.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
