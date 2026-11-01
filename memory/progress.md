# Progress

## Current

Status: active
Task: CAC-V1.0.0-RC4: fix the single CAC-V1.0.0-READINESS blocker. Completion hooks resolve policy, state and checks from the session working directory instead of the canonical repository root, so Claude Code and Codex Stop give false PASS and false BLOCK from a subdirectory. RC4-1 canonical hook root, RC4-2 checks run from the root, RC4-3 post-edit lint on the same primitive. No P1 backlog, policy, Risk, tag, release or consumer change.
Risk: high

## Scope

- .claude/hooks/**
- .codex/hooks/**
- tests/**
- README.md
- README.pt-BR.md
- memory/**

## Next

- RC4-1/2/3 cwd fix: shared project_root/enter_project_root in .claude/hooks/_lib.sh (root of the Git worktree that owns the hooks, never the session cwd); stop-verify.sh, state-enforcement.sh, sensory-reminder.sh and post-edit-verify.sh enter it; Codex and SubagentStop reach the same handlers. Hooks outside a Git repository block with VERIFY_UNAVAILABLE. tests/hook-root.bats: 19 RED on the rc3 tree, 19 GREEN.
- First commit A 0bdb293 (CI 41268248125) was not approved: the owner added the unquoted $CLAUDE_PROJECT_DIR finding to RC4. .claude/settings.json now quotes it for all 11 Claude handlers; install.sh treats the pre-rc4 unquoted spelling as owned, so an upgrade leaves one quoted copy of each handler and keeps third-party handlers. tests/claude-hook-paths.bats: 3 RED, 4 GREEN (the identity check for paths without spaces passes on both).
- Dogfood with real local installs: RC4 root == src/pkg for Claude and Codex; root output byte-identical to RC3; RC3 -> RC4 upgrade with and without spaces leaves one quoted copy per handler, Stop blocks from src/pkg, reinstall reports already current.
- Mechanism-changing: the new commit A carries the complete RC4 and gets diagnostic CI, then external owner review of its SHA and blobs. No B, C, tag or release before that approval. Consumers with local authority need reapproval after RC4.
- Behavior change by design: a non-Git installation now blocks Stop instead of evaluating the session directory.
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), doctor.sh resolves from the cwd (reports missing files from a subdirectory), tdd-check.sh resolves tracked status from the cwd.

## Blockers

None

## Recently Completed

- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
- CAC-GOLDEN-BASELINE-2 frozen at 79b78d5bffef0b6b5bf7b5b13fd51d7fa98a0649 on v1.0.0-rc3 (CI 41235813091, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs 2a47dbb, waha-operacional-tm2 c616991, affiliate-status-bot f3ee52e.
- Published v1.0.0-rc3: Quickstart ref bump 0f21e47 (CI 41127895279, exact-SHA attestation, verify 4 passed), annotated tag 45b91f9fb42cebf0eadb32fd0e27011afa2239bb peeling to 0f21e47, GitHub pre-release from the tag notes.
- CAC-V1.0.0-RC3 implementation: RC3-4 6b10267 (never replace an existing core.hooksPath), RC3-2 d10fb12 (ignored critical files and CONTROL_NOT_GIT_BOUND diagnostics), RC3-3 d1ff260 (AGENT.md 30679 bytes under the Codex 32 KiB budget), RC3-1 trust-changing A 64ceb01 (strict agent-md.toml reader, receipt reuse only for a valid contract, vendored parity), owner-approved; B df048da verifying (CI 40948897652) and C 5ede8dc done (CI 40952445170), each with exact-SHA attestation; final verify 4 passed.
- CAC-GOLDEN-BASELINE-1 frozen by the owner on 2026-10-29. Audit: CAC HEAD 169d3d55b6c834beebe0b104f6f254ffc5854eaa with CI 40817783740 and exact-SHA attestation; ia-search-jobs verify 4 passed, 0 warnings, CI 40783009480 attestation; WAHA agent-md.toml versioned without its prose lines with an identical parsed contract, Risk medium in Git, deploy OK for c616991 after the first host run timed out, verify 3 passed, 1 accepted advisory.
