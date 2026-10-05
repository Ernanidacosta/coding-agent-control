# Verification

- Baseline evidence: seven new wiring/install/dispatch tests failed; four existing protocol/retry tests passed. One further failing test proved child preflight used the parent's transport envelope.
- Passing focused checks: Codex hooks 9/9, installation/config/idempotence 39/39, Stop protocol 24/24, existing installer cases 4/4, parent envelope checks 2/2 and public wording 1/1, all exit 0.
- ShellCheck passes for altered shell/Bats scripts; diff and shared progress validation pass. Git-baseline done -> active is accepted without warnings, high Risk preserved and parent Stop/tool hook definitions unchanged.
- Native proof passed after explicit owner approval through /hooks of only the exact fixture SubagentStop hash. Real children preserved event, child identity and retry flag; allowed completion called all three handlers, invalid active state blocked twice and valid-state restoration allowed completion. Native transcripts record both hook feedback messages and task_complete. Other hook trust and global config stayed unchanged; temporary auth removed. Advisory/retry suppression remains covered by focused protocol regressions.
- Consolidation requires normal commit hooks, push, exact-SHA external CI and independent verification for active, verifying and done checkpoints, followed by full verify.sh on final HEAD. Stop on commit-hook failure without retry or bypass. Final tree must be clean and local/remote synchronized.
- Evidence: .agent/codex-subagent-stop-20261004/verification.md. Accepted implementation remains unchanged.
