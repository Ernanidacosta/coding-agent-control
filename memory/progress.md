# Progress

## Current

Status: verifying
Task: GB1-CI-RUNNER-PIN-1: pin every CI job to ubuntu-24.04, the image v1.0.0-rc2 was verified on. `ubuntu-latest` moved to ubuntu-26.04, whose default ACLs on /usr/share and /usr/share/ca-certificates make the bats host trust prerequisite refuse system trust (run 40800488558). Baseline stabilization for CAC-GOLDEN-BASELINE-1, not hardening; .github/workflows/ci.yml is trust material, so this follows the independent verification trust bootstrap.
Risk: high

## Scope

- .github/workflows/ci.yml
- memory/progress.md

## Next

- CAC-GOLDEN-BASELINE-1 (owner-opened 2026-10-28): baseline candidate v1.0.0-rc2 at bf43a0f5d1b92712851b939f942fa80268ba757d; the tag stays immutable and campaign rules are in plan.md.
- Consumer state at the GB-1 audit: ia-search-jobs a83fd08 on rc2 with Risk high and exact-SHA CI attestation; waha-operacional-tm2 has CLOUDFLARED-RELIABILITY-1 deployed (39bc1d9) and rc2 installed, but its rollout is blocked because agent-md.toml is not Git-bound; affiliate-status-bot runs a pre-rc1 CAC snapshot with an active product task.
- Post-baseline backlog (not hardening during the campaign): VERIFY_UNAVAILABLE does not name the missing path/binary; upgrade leaves many `.bak` files; `.project-control.toml` guidance is unclear; a host global gitignore can hide newly installed hooks; cherry-pick does not carry progress.md.
- Trust bootstrap: trust-changing commit A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260 on ubuntu-24.04, all four jobs passed; the verifier refused to attest A itself) was approved by the owner on 2026-10-29 after external review of its diff and trust blobs: ci.yml 6286c2b69f06e2dee7fa82f373eeae166291027e, agent-md.toml d5a7c9781c55cd347efe501504dfa2b7c7fcf7d0, github-actions-independent.conf acbf583a6841c1e0f21f6c3d83a8d8419f3e70af, github-actions-independent.sh 4ce6a7dbfedb91a1d6439c65f3af54a3d1c56ad5. This verifying checkpoint is the descendant with unchanged trust material and needs its own CI and exact-SHA attestation; then done with its own gates and final verify.sh. Afterwards resume CAC-GOLDEN-BASELINE-1 at the CAC candidate validation.
- Post-GB-1 backlog: adapt the CI host trust prerequisite to ubuntu-26.04 default ACLs; do not do it during the campaign.
- Separate observation: full verify.sh took 522-744s against the 750s per-check limit; harden only if it keeps reproducing.

## Blockers

None

## Recently Completed

- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
- Stabilize release-aware installation and provenance: `install.sh --ref=<tag|full sha>` fetches archive/refs/tags/<tag> or archive/<sha> with no fallback and conflicts with source overrides; `.agent-md/install-provenance.json` (source, ref, sanitized source_url, archive-declared commit, no timestamp); doctor reports it and never fails without it; README Stable/Development. 24 new tests. Active 91ad8aa0f94b8c892634289120b407c9b14473c8 (CI 40169461124) and verifying 16799f880c81f5040ab9155d6d1eb859ca525770 (CI 40170800783) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- ENROLLMENT-SOURCE-ELIGIBILITY-1: /.agent/ is now ignored by the repository itself, so the authority (no global Git config) no longer enumerates hook scratch; its identity of this repo went from invalid (9 nested repos) to valid. Active f26f48c8c00bf5ec2814f73823e84f194927c8d2 (CI 40013382466) and verifying 4f1131d98ac0428b59a2e4aa79b1879ea5bc90a0 (CI 40015895471) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- CAC-STATE-PROGRESS-DELETION-1: under the gitignored-progress mtime fallback a staged deletion (index D) uses HEAD commit time as its floor instead of counting as an unexplained missing source; 8 regressions. Active checkpoint 6c38060ee0b411ced231ecee1e38f99a068ca388 (CI 39999627723) and verifying checkpoint 801c13658a625d8dd7fb91ae6547a3f897cd5496 (CI 40002584968) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
