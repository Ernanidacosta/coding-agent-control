# Progress

## Current

Status: done
Task: CAC-V1.0.0-PUBLISH: owner-authorized publication of the first stable release v1.0.0, promoted from v1.0.0-rc4 (0fdf9a7) frozen in GB-3 (a36a86f). Point the pinned Quickstart install command at v1.0.0 (both READMEs, the install.sh usage header, and the test that keeps them in sync), checkpoint it, then tag and publish a stable release on that exact HEAD. No code, mechanism, hook, policy, Risk, installer behavior, CI, trust material, GB-3 or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- CAC-V1.0.0-READINESS rerun (2026-11-01, audit only): CAC_V1_0_0_READY=YES, V1_0_0_CAN_PROMOTE_FROM_RC4=YES, RC5_REQUIRED=NO. Install, rc2->rc3->rc4 upgrade, idempotent reinstall, provenance, Claude and Codex Stop at the root and in subdirectories (pass, required fail, Risk high without evidence, CONFIG_INVALID), spaces, third-party handlers, authority, receipts and the three GB-3 consumers PASS. New P1 finding: rolling back to v1.0.0-rc3 leaves 23 Claude handlers because the rc3 installer treats the quoted spelling as third-party, so every CAC hook runs twice (no false PASS, third-party handler kept); returning to rc4 restores the clean configuration.
- This commit only changes the pinned release ref from v1.0.0-rc4 to v1.0.0 (install.sh change is in its usage comment). It needs its own CI and exact-SHA attestation plus a final verify.sh; it then becomes the release commit for the annotated tag v1.0.0 and a stable GitHub release whose notes list the known limitations, including the pre-rc4 rollback.
- Never move or recreate the tag. Consumer rollout of v1.0.0 is a separate task.
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), doctor.sh resolves from the cwd (reports missing files from a subdirectory), tdd-check.sh resolves tracked status from the cwd, rollback to a release before rc4 doubles the Claude handlers (the old installer keeps both spellings; returning to rc4 or later restores one copy), no consolidated rollback procedure or platform and limitations section in the README.

## Blockers

None

## Recently Completed

- CAC-GOLDEN-BASELINE-3 frozen at a36a86f7cdeb3293a972b4354c2255265558d64e on v1.0.0-rc4 (CI 41351043167, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; RC4 cwd blocker closed.
- Published v1.0.0-rc4: Quickstart ref bump 0fdf9a7 (CI 41298577221, exact-SHA attestation, verify 4 passed), annotated tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e peeling to 0fdf9a7, GitHub pre-release from the tag notes; rolled out to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot.
- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153) and C c7b185d done (CI 41279403503), each with exact-SHA attestation; final verify 4 passed.
- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
- CAC-GOLDEN-BASELINE-2 frozen at 79b78d5bffef0b6b5bf7b5b13fd51d7fa98a0649 on v1.0.0-rc3 (CI 41235813091, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs 2a47dbb, waha-operacional-tm2 c616991, affiliate-status-bot f3ee52e.
