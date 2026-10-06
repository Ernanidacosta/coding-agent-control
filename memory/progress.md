# Progress

## Current

Status: verifying
Task: Consolidate the accepted Codex SubagentStop wiring through normal commit and external verification checkpoints; preserve the separate native fixture evidence.
Risk: high

## Scope

- .codex/hooks.json
- .claude/hooks/_lib.sh
- .claude/hooks/stop-verify.sh
- install.sh
- tests/codex-hooks.bats
- tests/install-host-config-policy.bats
- tests/install-idempotence.bats
- README.md
- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Commit this verifying checkpoint with normal hooks, push and obtain its own exact-SHA CI plus independent verification before verifying -> done. Repeat those gates for done and run full verify.sh at final HEAD. Stop on hook failure without automatic retry or bypass.

## Blockers

None

## Recently Completed

- Technical checkpoint d4695f9e66fed21cade17dc93e2227f1eb6cbfcf passed normal commit hooks (lint, smoke, test and state), was pushed, and passed CI run 37334944925 plus independent verification bound to that exact SHA. This advances active -> verifying; each later SHA requires fresh external evidence.
- Added SubagentStop to the existing wrapper and installer target envelope. A separate failing test proved child preflight previously consulted Stop; it now selects the actual Codex event, retaining Stop defaults and event-specific diagnostics.
- Focused checks passed: Codex hooks 9/9, install/config/idempotence 39/39, Stop protocol 24/24, existing installer cases 4/4, envelope checks 2/2, wording 1/1 and ShellCheck. Eight new regressions cover installation, dispatch and child semantics; parent Stop and tool hooks remain unchanged.
- Owner approved only the exact fixture SubagentStop hash through native /hooks. Real children proved allowed completion and two repeated STATE_PROGRESS_INVALID blocks (retry false/true), followed by success only after valid fixture state was restored. Registry confirms other hooks unchanged; global config unchanged and temporary auth removed. Evidence: .agent/codex-subagent-stop-20261004/verification.md (ignored).
- Budget diagnosis closed: the previous 900s timeout was not reproduced. Two complete suites passed 983/983 in 548.29s and 495.02s, with 351.71s and 404.98s margins; observed external concurrency prevents attributing the prior timeout to an exact cause. Policy remains 750/900 unchanged; no further profiling or performance work. Evidence: /tmp/cac-budget-diagnosis-20261004-qkqqnlp7/report.md.
