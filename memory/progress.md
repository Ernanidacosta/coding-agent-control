# Progress

## Current

Status: done
Task: ENROLLMENT-SOURCE-ELIGIBILITY-1: declare /.agent/ in the repository .gitignore so the local authority, which runs without the developer's global Git config, keeps hook scratch state out of source identity; tests/authority-source-identity.bats 23-26.
Risk: high

## Scope

- .gitignore
- tests/authority-source-identity.bats
- memory/progress.md

## Next

- Owner step, optional: `sudo ./examples/local-issuer/agent-md-authority enroll /home/ernani/agent-md`, stopping at the approval prompt; expected status eligible.
- Next separate task: Stabilize release-aware installation and provenance.
- Separate observation: full verify.sh took ~744s against the 750s per-check limit; harden only if it keeps reproducing.

## Blockers

None

## Recently Completed

- ENROLLMENT-SOURCE-ELIGIBILITY-1: /.agent/ is now ignored by the repository itself, so the authority (no global Git config) no longer enumerates hook scratch; its identity of this repo went from invalid (9 nested repos) to valid. Active f26f48c8c00bf5ec2814f73823e84f194927c8d2 (CI 40013382466) and verifying 4f1131d98ac0428b59a2e4aa79b1879ea5bc90a0 (CI 40015895471) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- CAC-STATE-PROGRESS-DELETION-1: under the gitignored-progress mtime fallback a staged deletion (index D) uses HEAD commit time as its floor instead of counting as an unexplained missing source; 8 regressions. Active checkpoint 6c38060ee0b411ced231ecee1e38f99a068ca388 (CI 39999627723) and verifying checkpoint 801c13658a625d8dd7fb91ae6547a3f897cd5496 (CI 40002584968) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
