# Plan

- Direction: GB-3 is frozen on v1.0.0-rc4 (tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e, release commit 0fdf9a7a9f43767c85e2156ab30c9c59809213de) with ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot PASS; manifesto in `docs/golden-baseline.md`. Next task: CAC-V1.0.0-READINESS. The bullets below record the GB-1 campaign (v1.0.0-rc2) and stay as reference.
- Campaign rules: no new CAC feature, no rc3, no tag move or recreation, no policy/timeout/Risk change unless the baseline itself needs it, no opportunistic hardening, no product task mixed with a CAC rollout. Nonblocking findings go to the post-baseline backlog.
- Required consumers: ia-search-jobs, waha-operacional-tm2, affiliate-status-bot. Others are only listed as candidates.
- Each consumer gets exactly one status: PASS, BLOCKED, DEFERRED or OUT_OF_SCOPE. Freeze requires the CAC candidate valid, ia-search-jobs and WAHA PASS, affiliate-status-bot PASS or explicitly justified DEFERRED, and no unknown divergence.
- On freeze, the manifesto is `docs/golden-baseline.md` (ID GB-1); it is proposed to the owner before any commit.
- Consumer rollouts use the documented pinned install (`--ref=v1.0.0-rc2`), preserve customizations, review host hook trust and classify every failure as consumer regression or CAC finding. In WAHA, push to main deploys automatically, so push and deploy are one owner decision.
- Accepted limitations: Claude orphan registrations until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation is post-adoption hardening; local authority does not support linked worktrees or staged issuance.
