# Progress

## Current

Status: done
Task: CAC-GOLDEN-BASELINE-2: freeze the second Golden Baseline on v1.0.0-rc3 (release commit 0f21e47d231120e82a47109c589c8c9f7b97e5e8) after the rc3 rollout in ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot. Baseline record only: no code, hook, installer, trust material, policy, test, tag or consumer change; no backlog work.
Risk: high

## Scope

- docs/golden-baseline.md
- memory/**

## Next

- GB-2 audit (2026-10-31): CAC tag v1.0.0-rc3 45b91f9 peels to 0f21e47 locally and on the remote; pre-release published; origin/main = 0f21e47; release CI 41127895279, exact-SHA attestation and verify 4 passed. Consumers PASS: ia-search-jobs 2a47dbb3376223306d6b86c0ac5572616c2a50b6 (verify 4 passed, CI 41217801565 attestation; production image 1ffcf51 untouched), waha-operacional-tm2 c616991c283b340a2b73d3ce65a99f1647eecad9 (verify 3 passed + accepted advisory; Pi marker c616991), affiliate-status-bot f3ee52e02ab2b36db469596c35ed3c82ca50f60f (verify 3 passed; rc3 authority, receipt 197 reusable; Pi marker = HEAD, containers not recreated, env hashes unchanged). Installed mechanism byte-identical to the tag in all three.
- This single checkpoint changes only docs/golden-baseline.md and memory/ (progress.md, plan.md). Its own CI, exact-SHA attestation and final verify.sh freeze GB-2.
- Next task: CAC-V1.0.0-READINESS. No v1.0.0, new tag, RC4, policy change, consumer change or backlog fix before it.
- Post-GB-2 finding: the Stop hook resolves checks from the session working directory and can fail outside the repository root (recorded as an accepted exception, not fixed).
- Post-GB-1 P1 backlog stays deferred: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, post-edit lint cwd, WAHA deploy margin (consumer).

## Blockers

None

## Recently Completed

- Published v1.0.0-rc3: Quickstart ref bump 0f21e47 (CI 41127895279, exact-SHA attestation, verify 4 passed), annotated tag 45b91f9fb42cebf0eadb32fd0e27011afa2239bb peeling to 0f21e47, GitHub pre-release from the tag notes.
- CAC-V1.0.0-RC3 implementation: RC3-4 6b10267 (never replace an existing core.hooksPath), RC3-2 d10fb12 (ignored critical files and CONTROL_NOT_GIT_BOUND diagnostics), RC3-3 d1ff260 (AGENT.md 30679 bytes under the Codex 32 KiB budget), RC3-1 trust-changing A 64ceb01 (strict agent-md.toml reader, receipt reuse only for a valid contract, vendored parity), owner-approved; B df048da verifying (CI 40948897652) and C 5ede8dc done (CI 40952445170), each with exact-SHA attestation; final verify 4 passed.
- CAC-GOLDEN-BASELINE-1 frozen by the owner on 2026-10-29. Audit: CAC HEAD 169d3d55b6c834beebe0b104f6f254ffc5854eaa with CI 40817783740 and exact-SHA attestation; ia-search-jobs verify 4 passed, 0 warnings, CI 40783009480 attestation; WAHA agent-md.toml versioned without its prose lines with an identical parsed contract, Risk medium in Git, deploy OK for c616991 after the first host run timed out, verify 3 passed, 1 accepted advisory.
- GB1-CI-RUNNER-PIN-1: every CI job pinned to ubuntu-24.04 because ubuntu-latest moved to 26.04, whose default ACLs failed the bats host trust prerequisite (run 40800488558). Trust-changing A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260) approved by the owner after external review of its trust blobs; verifying descendant 9706173acb8209049508a6c0cf46a735db6b4b9b passed normal hooks, CI 40815661296 and exact-SHA independent verification.
- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
