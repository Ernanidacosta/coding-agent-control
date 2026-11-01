# Progress

## Current

Status: done
Task: CAC-V1.0.0-RC4: fix the single CAC-V1.0.0-READINESS blocker. Completion hooks resolve policy, state and checks from the session working directory instead of the canonical repository root, so Claude Code and Codex Stop give false PASS and false BLOCK from a subdirectory. RC4-1 canonical hook root, RC4-2 checks run from the root, RC4-3 post-edit lint on the same primitive, plus the owner-added quoting of $CLAUDE_PROJECT_DIR in the Claude hook commands. No P1 backlog, policy, Risk, tag, release or consumer change.
Risk: high

## Scope

- .claude/hooks/**
- .codex/hooks/**
- .claude/settings.json
- install.sh
- tests/**
- README.md
- README.pt-BR.md
- memory/**

## Next

- RC4 implementation complete: A 2379a1affe363f310078a9a88d734976f1bdc4ce (owner-approved; on top of the unapproved first A 0bdb293), B 16a982b1e2da5f0cffd270a28645b2a35a0f5d98 verifying (CI 41277806153, exact-SHA attestation), this C done with its own CI and exact-SHA attestation, then verify.sh.
- Publication is a separate owner-authorized task: release commit and tag v1.0.0-rc4, rollout to ia-search-jobs, WAHA and affiliate-status-bot (reinstall rewrites settings.json to the quoted handlers; affiliate needs authority reinstall and reapprove), freeze GB-3, rerun CAC-V1.0.0-READINESS.
- Behavior change by design: a non-Git installation now blocks Stop instead of evaluating the session directory.
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), doctor.sh resolves from the cwd (reports missing files from a subdirectory), tdd-check.sh resolves tracked status from the cwd.

## Blockers

None

## Recently Completed

- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153, exact-SHA attestation).
- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
- CAC-GOLDEN-BASELINE-2 frozen at 79b78d5bffef0b6b5bf7b5b13fd51d7fa98a0649 on v1.0.0-rc3 (CI 41235813091, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs 2a47dbb, waha-operacional-tm2 c616991, affiliate-status-bot f3ee52e.
- Published v1.0.0-rc3: Quickstart ref bump 0f21e47 (CI 41127895279, exact-SHA attestation, verify 4 passed), annotated tag 45b91f9fb42cebf0eadb32fd0e27011afa2239bb peeling to 0f21e47, GitHub pre-release from the tag notes.
- CAC-V1.0.0-RC3 implementation: RC3-4 6b10267 (never replace an existing core.hooksPath), RC3-2 d10fb12 (ignored critical files and CONTROL_NOT_GIT_BOUND diagnostics), RC3-3 d1ff260 (AGENT.md 30679 bytes under the Codex 32 KiB budget), RC3-1 trust-changing A 64ceb01 (strict agent-md.toml reader, receipt reuse only for a valid contract, vendored parity), owner-approved; B df048da verifying (CI 40948897652) and C 5ede8dc done (CI 40952445170), each with exact-SHA attestation; final verify 4 passed.
