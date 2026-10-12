# Progress

## Current

Status: active
Task: Supply minimal canonical CAC advisory context to Claude delegated children that omit CLAUDE.md, independently of lifecycle tracking.
Risk: high

## Scope

- AGENT.md
- CLAUDE.md
- .claude/settings.json
- .claude/hooks/subagent-context.sh
- .gitignore
- tests/claude-subagent-context.bats
- tests/install-host-config-policy.bats
- README.md
- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Commit the minimal ShellCheck 0.9 portability correction with normal hooks, obtain exact-SHA CI/independent, then active -> verifying -> done checkpoints and final verify.sh. Stop before starting stabilization.

## Blockers

- Initial technical CI rejected SC2015 in the context budget guard (ShellCheck 0.9.0 versus local 0.11.0); corrected guard passes both versions. Replacement checkpoint external gates remain pending.

## Recently Completed

- Independent SubagentStart context hook extracts seven literal AGENT.md excerpts: 1698 UTF-8 bytes / 32 lines, bounded at 2560 bytes / 48 lines; canonical rule text unchanged, mirrors synchronized. All valid Starts receive the supplement because the host does not expose directive-loading state.
- Claude 2.1.296 native proof: general-purpose retains complete rules; Explore, Plan and omitClaudeMd lack CLAUDE.md but each receives one exact hook_additional_context attachment. All four execute the fixture scope blocker printf without file reads or scope expansion; parent prompts contain no blocker tag.
- Existing safety observes each native child tool call; each child passes the unchanged three completion gates. Profile/global configuration hashes preserved and temporary credentials removed. Evidence: .agent/claude-context-20261011/report.md; updated proof after portability fix: .agent/claude-context-20261012-final/native-summary.json.
- Focused checks: 122 distinct cases passed (context, lifecycle/Stop/retry, tool safety, settings/upgrade/idempotence and installer); ShellCheck, diff check, mirrors and done-to-active validation passed. Official verify.sh passed: exit 0, 629.53s, 1013/1013 tests. Technical 0eeca1fb16790c05382fc4ba139e2b77bb712fa6 normal hooks passed (648.76s) and published; CI 38284866938 rejected only the context guard SC2015. Minimal explicit-if correction preserves both bounds; policy/750-900 timeouts and existing handlers unchanged.
- Start cannot prevent creation when context extraction fails; diagnostics remain explicit. Lifecycle orphan/registration limitations are unchanged; general directive omission/truncation is outside scope.
