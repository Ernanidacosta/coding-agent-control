# Progress

## Current

Status: active
Task: CAC-V1.0.0-RC3: prepare v1.0.0-rc3 with exactly four fixes from the post-GB-1 triage (RC3-1 strict agent-md.toml parser, RC3-2 ignored critical files diagnostics, RC3-3 directive budget, RC3-4 protect an existing core.hooksPath). No tag, release, policy, Risk or consumer change; no P1 backlog.
Risk: high

## Scope

- .claude/hooks/_lib.sh
- .agent-md/bin/doctor.sh
- install.sh
- AGENT.md
- CLAUDE.md
- README.md
- README.pt-BR.md
- docs/**
- examples/local-issuer/README.md
- tests/**
- memory/**

## Next

- RC3-4 done in 6b10267: --githooks writes core.hooksPath only when unset; .githooks is idempotent; any other local or global value is left unchanged with guidance (tests/install-hookspath.bats).
- RC3-2: installer (dry-run included) reports ignored critical files with rule and scope (global/host, repository .gitignore, local exclude); doctor warns CONTROL_NOT_GIT_BOUND and CRITICAL_FILE_IGNORED (tests/ignored-critical-files.bats). Commit next.
- RC3-3: AGENT.md under the 32 KiB Codex project-doc budget with a size test (TDD).
- RC3-1 (trust/mechanism-changing, commit A): strict agent-md.toml parser, CONFIG_INVALID for invalid TOML, receipt reuse only for a valid contract. Push for diagnostic CI, then stop for the owner's external review of A's SHA and mechanism hashes before descendant B (verifying) and closing C (done).
- Post-GB-1 P1 backlog stays out of RC3: VERIFY_UNAVAILABLE wording, .bak cleanup, .project-control.toml guidance, cherry-pick UX, linked worktrees, staged issuance, ubuntu-26.04, verify timeout, githooks NOT active message, dry-run precision, authority reapproval UX, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer).

## Blockers

None

## Recently Completed

- CAC-GOLDEN-BASELINE-1 frozen by the owner on 2026-10-29. Audit: CAC HEAD 169d3d55b6c834beebe0b104f6f254ffc5854eaa with CI 40817783740 and exact-SHA attestation; ia-search-jobs verify 4 passed, 0 warnings, CI 40783009480 attestation; WAHA agent-md.toml versioned without its prose lines with an identical parsed contract, Risk medium in Git, deploy OK for c616991 after the first host run timed out, verify 3 passed, 1 accepted advisory.
- GB1-CI-RUNNER-PIN-1: every CI job pinned to ubuntu-24.04 because ubuntu-latest moved to 26.04, whose default ACLs failed the bats host trust prerequisite (run 40800488558). Trust-changing A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260) approved by the owner after external review of its trust blobs; verifying descendant 9706173acb8209049508a6c0cf46a735db6b4b9b passed normal hooks, CI 40815661296 and exact-SHA independent verification.
- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
- Stabilize release-aware installation and provenance: `install.sh --ref=<tag|full sha>` fetches archive/refs/tags/<tag> or archive/<sha> with no fallback and conflicts with source overrides; `.agent-md/install-provenance.json` (source, ref, sanitized source_url, archive-declared commit, no timestamp); doctor reports it and never fails without it; README Stable/Development. 24 new tests. Active 91ad8aa0f94b8c892634289120b407c9b14473c8 (CI 40169461124) and verifying 16799f880c81f5040ab9155d6d1eb859ca525770 (CI 40170800783) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
