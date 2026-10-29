# Progress

## Current

Status: done
Task: GB1-CI-RUNNER-PIN-1: pin every CI job to ubuntu-24.04, the image v1.0.0-rc2 was verified on. `ubuntu-latest` moved to ubuntu-26.04, whose default ACLs on /usr/share and /usr/share/ca-certificates make the bats host trust prerequisite refuse system trust (run 40800488558). Baseline stabilization for CAC-GOLDEN-BASELINE-1, not hardening; .github/workflows/ci.yml is trust material, so this follows the independent verification trust bootstrap.
Risk: high

## Scope

- .github/workflows/ci.yml
- memory/progress.md

## Next

- CAC-GOLDEN-BASELINE-1 (owner-opened 2026-10-28): baseline candidate v1.0.0-rc2 at bf43a0f5d1b92712851b939f942fa80268ba757d; the tag stays immutable and campaign rules are in plan.md.
- Consumer state at the GB-1 audit: ia-search-jobs a83fd08 on rc2 with Risk high and exact-SHA CI attestation; waha-operacional-tm2 has CLOUDFLARED-RELIABILITY-1 deployed (39bc1d9) and rc2 installed, but its rollout is blocked because agent-md.toml is not Git-bound; affiliate-status-bot runs a pre-rc1 CAC snapshot with an active product task.
- Post-baseline backlog (not hardening during the campaign): VERIFY_UNAVAILABLE does not name the missing path/binary; upgrade leaves many `.bak` files; `.project-control.toml` guidance is unclear; a host global gitignore can hide newly installed hooks; cherry-pick does not carry progress.md.
- Resume CAC-GOLDEN-BASELINE-1 at the CAC candidate validation: the HEAD now has passing CI on ubuntu-24.04 and exact-SHA attestation again.
- Post-GB-1 backlog: adapt the CI host trust prerequisite to ubuntu-26.04 default ACLs; do not do it during the campaign.
- Separate observation: full verify.sh took 522-744s against the 750s per-check limit; harden only if it keeps reproducing.

## Blockers

None

## Recently Completed

- GB1-CI-RUNNER-PIN-1: every CI job pinned to ubuntu-24.04 because ubuntu-latest moved to 26.04, whose default ACLs failed the bats host trust prerequisite (run 40800488558). Trust-changing A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260) approved by the owner after external review of its trust blobs; verifying descendant 9706173acb8209049508a6c0cf46a735db6b4b9b passed normal hooks, CI 40815661296 and exact-SHA independent verification.
- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
- Stabilize release-aware installation and provenance: `install.sh --ref=<tag|full sha>` fetches archive/refs/tags/<tag> or archive/<sha> with no fallback and conflicts with source overrides; `.agent-md/install-provenance.json` (source, ref, sanitized source_url, archive-declared commit, no timestamp); doctor reports it and never fails without it; README Stable/Development. 24 new tests. Active 91ad8aa0f94b8c892634289120b407c9b14473c8 (CI 40169461124) and verifying 16799f880c81f5040ab9155d6d1eb859ca525770 (CI 40170800783) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- ENROLLMENT-SOURCE-ELIGIBILITY-1: /.agent/ is now ignored by the repository itself, so the authority (no global Git config) no longer enumerates hook scratch; its identity of this repo went from invalid (9 nested repos) to valid. Active f26f48c8c00bf5ec2814f73823e84f194927c8d2 (CI 40013382466) and verifying 4f1131d98ac0428b59a2e4aa79b1879ea5bc90a0 (CI 40015895471) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
