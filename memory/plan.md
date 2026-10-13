# Plan

- Task: consolidate the owner-approved v1.0.0-rc1 baseline. Readiness candidate 42499a8f23aedcc0cf6f929677f633745fbf688d has zero concrete blockers; preserve effective high Risk and policy 750/900.
- Commit the approved active checkpoint with normal hooks, publish normally and validate external CI plus independent verification for its exact SHA. Then record active-to-verifying and verifying-to-done in separate memory-only checkpoints, each with normal hooks and its own external evidence.
- Run official verify.sh on the final clean done HEAD; confirm local/remote synchronization. Only then create and publish immutable annotated v1.0.0-rc1 pointing to that final done SHA, with readiness and known limitations in the tag message.
- Accepted limitations: Claude orphan registrations until confirmed termination; Start cannot block creation after registration failure; directive budget/truncation is post-adoption hardening; local authority does not support linked worktrees or staged issuance.
- Stop after publishing and checking the tag. Next separate task: Roll out v1.0.0-rc1 to affiliate-status-bot. Preserve customizations, use a pinned package, review host hook trust and classify dogfooding failures before further rollout. No consumer upgrade or new feature here.
