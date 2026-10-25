# Progress

## Current

Status: verifying
Task: Stabilize release-aware installation and provenance: `install.sh --ref=<tag|sha>` installs an immutable GitHub archive with no fallback, records `.agent-md/install-provenance.json`, and doctor reports it.
Risk: high

## Scope

- install.sh
- .agent-md/bin/doctor.sh
- README.md
- README.pt-BR.md
- tests/install-provenance.bats
- tests/install.bats
- memory/progress.md

## Next

- Active checkpoint 91ad8aa0f94b8c892634289120b407c9b14473c8: tests/install-provenance.bats failed 24/24 at 5cffe0f and passes 24/24; full verify.sh passed on the approved rerun (522s, 1049 tests) after a flaky test-only assertion was fixed; pre-commit hooks passed (544s), CI 40169461124 passed all four jobs, exact-SHA independent verification passed.
- Remaining: this verifying checkpoint with its own CI and independent verification, then verifying -> done with CI, independent verification and final verify.sh.
- README Quickstart names v1.0.0-rc2, which does not exist until the separate Publish v1.0.0-rc2 task tags it. Do not create the tag in this task.

## Blockers

None

## Recently Completed

- ENROLLMENT-SOURCE-ELIGIBILITY-1: /.agent/ is now ignored by the repository itself, so the authority (no global Git config) no longer enumerates hook scratch; its identity of this repo went from invalid (9 nested repos) to valid. Active f26f48c8c00bf5ec2814f73823e84f194927c8d2 (CI 40013382466) and verifying 4f1131d98ac0428b59a2e4aa79b1879ea5bc90a0 (CI 40015895471) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- CAC-STATE-PROGRESS-DELETION-1: under the gitignored-progress mtime fallback a staged deletion (index D) uses HEAD commit time as its floor instead of counting as an unexplained missing source; 8 regressions. Active checkpoint 6c38060ee0b411ced231ecee1e38f99a068ca388 (CI 39999627723) and verifying checkpoint 801c13658a625d8dd7fb91ae6547a3f897cd5496 (CI 40002584968) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
