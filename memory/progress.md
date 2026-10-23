# Progress

## Current

Status: active
Task: ENROLLMENT-SOURCE-ELIGIBILITY-1: declare /.agent/ in the repository .gitignore so the local authority, which runs without the developer's global Git config, keeps hook scratch state out of source identity; tests/authority-source-identity.bats 23-26.
Risk: high

## Scope

- .gitignore
- tests/authority-source-identity.bats
- memory/progress.md

## Next

- Audit closed: without /.agent/ the authority identity of this repo is invalid (884 .agent/ entries, 9 nested repos as unsupported special entries); with it, valid with none. Tests 23-25 are coverage-only (pass at HEAD); 26 fails at HEAD and passes with the fix. No production change.
- Consolidate active -> verifying -> done with CI and exact-SHA independent verification at each checkpoint, then final verify.sh. stash@{0} is kept until done.
- Separate observation, not this task: full verify.sh took ~744s against the 750s per-check limit; harden only if it keeps reproducing.

## Blockers

None

## Recently Completed

- CAC-STATE-PROGRESS-DELETION-1: under the gitignored-progress mtime fallback a staged deletion (index D) uses HEAD commit time as its floor instead of counting as an unexplained missing source; 8 regressions. Active checkpoint 6c38060ee0b411ced231ecee1e38f99a068ca388 (CI 39999627723) and verifying checkpoint 801c13658a625d8dd7fb91ae6547a3f897cd5496 (CI 40002584968) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Owner approved v1.0.0-rc1 based on readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d, with zero concrete blockers. The published tag must target the final done operational descendant, not necessarily this original candidate.
- Readiness passed: fresh install, update/reinstall, Claude/Codex, idempotent hooks, doctor, verification contract, state/Risk, independent verification, optional local authority/receipts and existing-project upgrade; focused adoption tests 123/123, exit 0 in 63.72s.
- Approved active checkpoint 306c8eb14d80364d6fd9604202e32ed9b7efe971 published with normal hooks (599.67s, 1013/1013 tests), CI 38337666462 passing all four jobs and independent verification passing for that exact SHA. No implementation, policy or trust changes; no bypass.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
