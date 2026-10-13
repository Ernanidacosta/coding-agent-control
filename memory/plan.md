# Plan

- Task: consolidate the owner-approved v1.0.0-rc1 baseline. Readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d has zero concrete blockers; preserve effective high Risk and policy 750/900.
- Active 306c8eb14d80364d6fd9604202e32ed9b7efe971 and verifying 78a38b485ac8e6c37955e06bb94bcbce99d0fca4 are published with passing normal hooks, their own CI and exact-SHA independent evidence. Record the direct verifying-to-done transition; its own hooks, external gates and final verify.sh remain required before tag publication.
- Run official verify.sh on the final clean done HEAD; confirm local/remote synchronization. Only then create and publish immutable annotated v1.0.0-rc1 pointing to that final done SHA, with readiness and known limitations in the tag message.
- Accepted limitations: Claude orphan registrations until confirmed termination; Start cannot block creation after registration failure; directive budget/truncation is post-adoption hardening; local authority does not support linked worktrees or staged issuance.
- Stop after publishing and checking the tag. Next separate task: Roll out v1.0.0-rc1 to affiliate-status-bot. Preserve customizations, use a pinned package, review host hook trust and classify dogfooding failures before further rollout. No consumer upgrade or new feature here.
