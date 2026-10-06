# Progress

## Current

Status: done
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

- Publish this done checkpoint after normal hooks, obtain its own exact-SHA CI plus independent verification and run full verify.sh on final HEAD. Confirm a clean tree and synchronized local/remote before reporting completion; stop on gate failure without bypass or automatic retry.

## Blockers

None

## Recently Completed

- Technical checkpoint d4695f9e66fed21cade17dc93e2227f1eb6cbfcf passed normal commit hooks (lint, smoke, test and state), was pushed, and passed CI run 37334944925 plus independent verification bound to that exact SHA. Verifying checkpoint a3827689026264e29113917399ffca9c4e7ae58d also passed normal hooks, was pushed and passed CI run 37422262351 plus exact-SHA independent verification. This records verifying -> done; the final SHA still requires fresh external evidence.
- Containment incident 42/43 investigated and closed without a technical change: both isolated cases, containment 10/10 with six jobs and technical-SHA CI passed; the authorized verifying retry also passed. Identity coincidence is a deliberate staging --root warning, including on passing runs. Historical cause remains indeterminate; no implementation or policy change is justified. Evidence: /tmp/cac-containment-diagnosis-u_4723vi/.
- Focused checks passed: Codex hooks 9/9, install/config/idempotence 39/39, Stop protocol 24/24, existing installer cases 4/4, envelope checks 2/2, wording 1/1 and ShellCheck. Eight new regressions cover installation, dispatch and child semantics; parent Stop and tool hooks remain unchanged.
- Owner approved only the exact fixture SubagentStop hash through native /hooks. Real children proved allowed completion and two repeated STATE_PROGRESS_INVALID blocks (retry false/true), followed by success only after valid fixture state was restored. Registry confirms other hooks unchanged; global config unchanged and temporary auth removed. Evidence: .agent/codex-subagent-stop-20261004/verification.md (ignored).
- Budget diagnosis closed: the previous 900s timeout was not reproduced. Two complete suites passed 983/983 in 548.29s and 495.02s, with 351.71s and 404.98s margins; observed external concurrency prevents attributing the prior timeout to an exact cause. Policy remains 750/900 unchanged; no further profiling or performance work. Evidence: /tmp/cac-budget-diagnosis-20261004-qkqqnlp7/report.md.
