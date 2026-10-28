# Plan

- Direction: dogfood v1.0.0-rc2 gradually before any further CAC change. The annotated tag 239846b3f3ec675e3d4163b152457b51c70fcd45 (peeled bf43a0f5d1b92712851b939f942fa80268ba757d) and its GitHub pre-release stay immutable during this cycle.
- Sequence: ia-search-jobs (passed) -> operacional WAHA -> review findings that repeat across consumers -> minimal hardening -> evaluate v1.0.0.
- Operacional WAHA: install the pinned rc2 only after its own CLOUDFLARED-RELIABILITY-1 closes. Push to its main deploys automatically, so push and deploy are one owner decision; never pause timers or workflows to get around that.
- Each consumer rollout uses the documented pinned install (`--ref=v1.0.0-rc2`), preserves its customizations, reviews host hook trust and classifies every failure as consumer regression or CAC finding.
- No new CAC feature, rc3 or tag change until the owner moves the cycle to the findings review.
- Accepted limitations: Claude orphan registrations until confirmed termination; SubagentStart cannot block creation after registration failure; directive budget/truncation is post-adoption hardening; local authority does not support linked worktrees or staged issuance.
