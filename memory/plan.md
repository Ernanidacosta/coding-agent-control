# Plan

- Direction: CAC-GOLDEN-BASELINE-1 (opened by the owner 2026-10-28). Establish one auditable, reproducible baseline of v1.0.0-rc2 (annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45, peeled bf43a0f5d1b92712851b939f942fa80268ba757d) and its main real consumers. Golden Baseline means known and reproducible, not perfect.
- Campaign rules: no new CAC feature, no rc3, no tag move or recreation, no policy/timeout/Risk change unless the baseline itself needs it, no opportunistic hardening, no product task mixed with a CAC rollout. Nonblocking findings go to the post-baseline backlog.
- Required consumers: ia-search-jobs, waha-operacional-tm2, affiliate-status-bot. Others are only listed as candidates.
- Each consumer gets exactly one status: PASS, BLOCKED, DEFERRED or OUT_OF_SCOPE. Freeze requires the CAC candidate valid, ia-search-jobs and WAHA PASS, affiliate-status-bot PASS or explicitly justified DEFERRED, and no unknown divergence.
- On freeze, the manifesto is `docs/golden-baseline.md` (ID GB-1); it is proposed to the owner before any commit.
- Consumer rollouts use the documented pinned install (`--ref=v1.0.0-rc2`), preserve customizations, review host hook trust and classify every failure as consumer regression or CAC finding. In WAHA, push to main deploys automatically, so push and deploy are one owner decision.
- Accepted limitations: Claude orphan registrations until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation is post-adoption hardening; local authority does not support linked worktrees or staged issuance.
