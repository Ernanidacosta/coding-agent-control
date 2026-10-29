# Progress

## Current

Status: done
Task: CAC-GOLDEN-BASELINE-1: freeze GB-1, one auditable and reproducible baseline of v1.0.0-rc2 and its real consumers, recorded in docs/golden-baseline.md. No code, tag, release, policy, Risk or consumer change.
Risk: high

## Scope

- docs/golden-baseline.md
- memory/progress.md

## Next

- GB-1 is frozen: CAC v1.0.0-rc2 at bf43a0f5d1b92712851b939f942fa80268ba757d; ia-search-jobs PASS at a83fd08ea0e22e178c71b7fffea97905e404386e; waha-operacional-tm2 PASS at c616991c283b340a2b73d3ce65a99f1647eecad9; affiliate-status-bot DEFERRED (active product task, pre-rc1 CAC). Validity criteria, baseline exceptions and backlog are in docs/golden-baseline.md.
- The WAHA advisory RISK_RUNTIME_EVIDENCE_REQUIRED is an accepted baseline exception; its policy stays unchanged.
- Post-GB-1 backlog, only after the owner opens it: VERIFY_UNAVAILABLE does not name the missing path/binary; upgrade leaves many `.bak` files; `.project-control.toml` guidance is unclear; a host global gitignore can hide newly installed hooks; cherry-pick does not carry progress.md; directive budget/truncation; linked worktrees and local authority; staged issuance; verify.sh timeout margin (522-744s against 750s); adapt CI to ubuntu-26.04 default ACLs; WAHA host deploy margin (~14m40s against TimeoutStartSec=15min, consumer-side); Productize/Ponytail/Failure Ratchet/evals.
- affiliate-status-bot joins only through a later baseline or an explicit amendment, after AMAZON-SCHEDULE-1 closes.

## Blockers

None

## Recently Completed

- CAC-GOLDEN-BASELINE-1 frozen by the owner on 2026-10-29. Audit: CAC HEAD 169d3d55b6c834beebe0b104f6f254ffc5854eaa with CI 40817783740 and exact-SHA attestation; ia-search-jobs verify 4 passed, 0 warnings, CI 40783009480 attestation; WAHA agent-md.toml versioned without its prose lines with an identical parsed contract, Risk medium in Git, deploy OK for c616991 after the first host run timed out, verify 3 passed, 1 accepted advisory.
- GB1-CI-RUNNER-PIN-1: every CI job pinned to ubuntu-24.04 because ubuntu-latest moved to 26.04, whose default ACLs failed the bats host trust prerequisite (run 40800488558). Trust-changing A e4edc6bb276ca348f156b28f89b20444f21a7549 (diagnostic CI 40802737260) approved by the owner after external review of its trust blobs; verifying descendant 9706173acb8209049508a6c0cf46a735db6b4b9b passed normal hooks, CI 40815661296 and exact-SHA independent verification.
- Published v1.0.0-rc2: annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 on bf43a0f5d1b92712851b939f942fa80268ba757d and a GitHub pre-release from the tag notes. The documented pinned curl install was proven against the published tag (provenance github-ref, archive commit bf43a0f).
- Stabilize release-aware installation and provenance: `install.sh --ref=<tag|full sha>` fetches archive/refs/tags/<tag> or archive/<sha> with no fallback and conflicts with source overrides; `.agent-md/install-provenance.json` (source, ref, sanitized source_url, archive-declared commit, no timestamp); doctor reports it and never fails without it; README Stable/Development. 24 new tests. Active 91ad8aa0f94b8c892634289120b407c9b14473c8 (CI 40169461124) and verifying 16799f880c81f5040ab9155d6d1eb859ca525770 (CI 40170800783) each passed normal hooks, all four CI jobs and exact-SHA independent verification.
- Accepted nonblocking limitations: Claude orphan lifecycle records until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation hardening; local authority without linked worktrees; staged issuance unsupported.
