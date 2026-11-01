# Progress

## Current

Status: done
Task: CAC-GOLDEN-BASELINE-3: freeze the third Golden Baseline on v1.0.0-rc4 (release commit 0fdf9a7a9f43767c85e2156ab30c9c59809213de) after the rc4 rollout to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot. Baseline and freeze only: docs/golden-baseline.md and memory/. No code, hook, installer, test, policy, Risk, trust material, tag, release or consumer change.
Risk: high

## Scope

- docs/golden-baseline.md
- memory/**

## Next

- GB-3 audit (2026-11-01): tag v1.0.0-rc4 9c82227 peels to 0fdf9a7 locally and on origin; CAC doctor 0, verify 4 passed with exact-SHA attestation. Consumers PASS: ia-search-jobs d9161369a9230daf88c05421e66b03b3068284ab (verify 4 passed, CI 41325650214 attestation), waha-operacional-tm2 c616991c283b340a2b73d3ce65a99f1647eecad9 (verify 3 passed, 1 accepted advisory), affiliate-status-bot 63835300264eb45e0028cf69022c663b3c3f398c (verify 3 passed, authority programs = rc4, reapproved 57104fe5). Installed mechanism byte-identical to the tag; real Stop from subdirectories allows in all three. RC4 cwd blocker closed.
- This commit only adds the GB-3 section to docs/golden-baseline.md and updates memory/. It needs its own CI and exact-SHA attestation plus a final verify.sh; then GB-3 is frozen.
- Next task is exclusively CAC-V1.0.0-READINESS. No v1.0.0, new tag, RC5, consumer, policy or backlog change until the owner opens it.
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), doctor.sh resolves from the cwd (reports missing files from a subdirectory), tdd-check.sh resolves tracked status from the cwd.

## Blockers

None

## Recently Completed

- Published v1.0.0-rc4: Quickstart ref bump 0fdf9a7 (CI 41298577221, exact-SHA attestation, verify 4 passed), annotated tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e peeling to 0fdf9a7, GitHub pre-release from the tag notes; rolled out to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot.
- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153) and C c7b185d done (CI 41279403503), each with exact-SHA attestation; final verify 4 passed.
- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
- CAC-GOLDEN-BASELINE-2 frozen at 79b78d5bffef0b6b5bf7b5b13fd51d7fa98a0649 on v1.0.0-rc3 (CI 41235813091, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs 2a47dbb, waha-operacional-tm2 c616991, affiliate-status-bot f3ee52e.
- Published v1.0.0-rc3: Quickstart ref bump 0f21e47 (CI 41127895279, exact-SHA attestation, verify 4 passed), annotated tag 45b91f9fb42cebf0eadb32fd0e27011afa2239bb peeling to 0f21e47, GitHub pre-release from the tag notes.
