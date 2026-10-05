# Plan

- Focused Codex child-termination wiring is implemented through the existing completion/state wrapper; parent Stop, tool safety, child payload, advisory and retries are preserved.
- Installer source/merge/materialization and child-specific transport preflight are covered by regressions; no new enforcement system, policy, receipts or other host changes.
- Establish trust only for the exact isolated-fixture SubagentStop through owner review in native /hooks; capture real child callback, allowed completion, controlled gate block and advisory/retry semantics. No automatic trust/bypass or global configuration changes.
- Accepted implementation stays unchanged. After native proof, normal commit/push and exact-SHA CI plus independent verification precede each operational transition active -> verifying -> done; run full verify.sh at final HEAD. A failed commit hook stops consolidation without retry.
- Evidence: .agent/codex-subagent-stop-20261004/verification.md. No next roadmap item.
