# Progress

## Current

Status: done
Task: CAC-V1.0.0-RC3-PUBLISH: owner-authorized publication of v1.0.0-rc3. Point the pinned Quickstart install command at v1.0.0-rc3 (both READMEs, the install.sh usage header, and the test that keeps them in sync), checkpoint it, then tag and publish a pre-release on that exact HEAD. No code, mechanism, policy, Risk or consumer change.
Risk: high

## Scope

- README.md
- README.pt-BR.md
- install.sh
- tests/install.bats
- memory/**

## Next

- The rc3 implementation closed in C 5ede8dc6c101fb5ffc34a9141acdb5a44fad9c53 (CI 40952445170, exact-SHA attestation, final verify 4 passed). The owner authorized publication on 2026-10-30.
- This commit only changes the pinned release ref from v1.0.0-rc2 to v1.0.0-rc3 (install.sh change is in its usage comment). It needs its own CI and exact-SHA attestation plus a final verify.sh; it then becomes the release commit for the annotated tag v1.0.0-rc3 and a GitHub pre-release.
- Never move or recreate the tag. Consumer rollout is a separate task: dogfood ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot (authority reinstall + reapprove there), freeze GB-2, then CAC-V1.0.0-READINESS.
- Post-GB-1 P1 backlog stays out of RC3: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer).

## Blockers

None

## Recently Completed

- CAC-V1.0.0-RC3 implementation: RC3-4 6b10267 (never replace an existing core.hooksPath), RC3-2 d10fb12 (ignored critical files and CONTROL_NOT_GIT_BOUND diagnostics), RC3-3 d1ff260 (AGENT.md 30679 bytes under the Codex 32 KiB budget), RC3-1 trust-changing A 64ceb01 (strict agent-md.toml reader, receipt reuse only for a valid contract, vendored parity), owner-approved; B df048da verifying (CI 40948897652) and C 5ede8dc done (CI 40952445170), each with exact-SHA attestation; final verify 4 passed.
- CAC-GOLDEN-BASELINE-1 frozen by the owner on 2026-10-29. Audit: CAC HEAD 169d3d55b6c834beebe0b104f6f254ffc5854eaa with CI 40817783740 and exact-SHA attestation; ia-search-jobs verify 4 passed, 0 warnings, CI 40783009480 attestation; WAHA agent-md.toml versioned without its prose lines with an identical parsed contract, Risk medium in Git, deploy OK for c616991 after the first host run timed out, verify 3 passed, 1 accepted advisory.
- GB1-CI-RUNNER-PIN-1: every CI job pinned to ubuntu-24.04 because ubuntu-latest moved to 26.04, whose default ACLs failed the bats host trust prerequisite (run 40800488558). Trust-changing A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260) approved by the owner after external review of its trust blobs; verifying descendant 9706173acb8209049508a6c0cf46a735db6b4b9b passed normal hooks, CI 40815661296 and exact-SHA independent verification.
- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
