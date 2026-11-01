# Progress

## Current

Status: done
Task: CAC-V1.0.0-RC4-PUBLISH: owner-authorized publication of v1.0.0-rc4. Point the pinned Quickstart install command at v1.0.0-rc4 (both READMEs, the install.sh usage header, and the test that keeps them in sync), checkpoint it, then tag and publish a pre-release on that exact HEAD. No code, mechanism, hook, policy, Risk, installer behavior or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- The rc4 implementation closed in C c7b185df9c54b54e0176527297eeb682b4a85424 (CI 41279403503, exact-SHA attestation, final verify 4 passed). The owner authorized publication on 2026-11-01.
- This commit only changes the pinned release ref from v1.0.0-rc3 to v1.0.0-rc4 (install.sh change is in its usage comment). It needs its own CI and exact-SHA attestation plus a final verify.sh; it then becomes the release commit for the annotated tag v1.0.0-rc4 and a GitHub pre-release.
- Never move or recreate the tag. Consumer rollout is a separate task: reinstall in ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot (rewrites settings.json to the quoted handlers; affiliate needs authority reinstall and reapprove), freeze GB-3, rerun CAC-V1.0.0-READINESS.
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), doctor.sh resolves from the cwd (reports missing files from a subdirectory), tdd-check.sh resolves tracked status from the cwd.

## Blockers

None

## Recently Completed

- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153) and C c7b185d done (CI 41279403503), each with exact-SHA attestation; final verify 4 passed.
- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
- CAC-GOLDEN-BASELINE-2 frozen at 79b78d5bffef0b6b5bf7b5b13fd51d7fa98a0649 on v1.0.0-rc3 (CI 41235813091, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs 2a47dbb, waha-operacional-tm2 c616991, affiliate-status-bot f3ee52e.
- Published v1.0.0-rc3: Quickstart ref bump 0f21e47 (CI 41127895279, exact-SHA attestation, verify 4 passed), annotated tag 45b91f9fb42cebf0eadb32fd0e27011afa2239bb peeling to 0f21e47, GitHub pre-release from the tag notes.
- CAC-V1.0.0-RC3 implementation: RC3-4 6b10267 (never replace an existing core.hooksPath), RC3-2 d10fb12 (ignored critical files and CONTROL_NOT_GIT_BOUND diagnostics), RC3-3 d1ff260 (AGENT.md 30679 bytes under the Codex 32 KiB budget), RC3-1 trust-changing A 64ceb01 (strict agent-md.toml reader, receipt reuse only for a valid contract, vendored parity), owner-approved; B df048da verifying (CI 40948897652) and C 5ede8dc done (CI 40952445170), each with exact-SHA attestation; final verify 4 passed.
