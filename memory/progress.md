# Progress

## Current

Status: active
Task: Connect Claude SubagentStop to existing completion/state gates with safe event eligibility, focused regressions and isolated native allow/block proof.
Risk: high

## Scope

- .gitignore
- .claude/settings.json
- .claude/hooks/*.sh
- install.sh
- tests/*claude*.bats
- tests/install-*.bats
- tests/stop-hook-active.bats
- README.md
- memory/plan.md
- memory/progress.md
- memory/verify.md

## Next

- Review final focused and native evidence, then stop before commit or consolidation. Owner approved retaining orphan identities until confirmed termination; no automatic identity expiry or new liveness mechanism.

## Blockers

None

## Recently Completed

- Claude lifecycle wiring correlates exact session/child identities, preserves payload/retry behavior and ignores internal events. Focused checks cover 113 distinct cases; native allow, block/retry/recovery and internal exclusion passed again after the host-boundary fix with source-matched scripts and unchanged global configuration. Evidence: .agent/claude-lifecycle-20261007/native-summary-hostfix.json.
- Owner approved retaining orphan registrations until confirmed termination. A regression reproduced age-based release of an unresolved block; registered identities no longer expire. No instruction injection, policy change, commit or push.
- Required Stop verification exposed inherited CODING_AGENT_CONTROL_HOST=codex in the Claude preflight test. Reproduced deterministically, fixed by setting claude in the Claude lifecycle wrapper, and covered explicitly: lifecycle/Stop protocol 41/41 with inherited Codex host and six jobs. No budget change; the complete gate was not rerun manually.
- Claude 2.1.290 native audit completed: general-purpose received all 38,033 substantive directive bytes; Explore/Plan/omitClaudeMd had no CAC instruction attachment. All four children enforced the existing Bash safety canary and emitted SubagentStop, but no child completion/state handler ran; all three handlers ran only at parent Stop. Instructions D, tool safety A within the tested boundary, completion D. Evidence: .agent/claude-subagent-audit-20261006/audit.md (ignored).
- Focused checks passed 56/56 plus installer/reinstall/preservation 4/4. Global configuration and credentials unchanged, temporary credentials removed, no implementation change or full suite. Audit stops before any correction or commit.
