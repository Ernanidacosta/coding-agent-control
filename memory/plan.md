# Plan

- Implement only owner-approved Claude SubagentStart/Stop correlation by session_id + agent_id; agent_type is diagnostic only. Reuse .agent scratch storage with atomic per-child publication.
- Reuse existing verification/state/advisory handlers, preserve the actual event and payload, parent Stop, tool safety and retry semantics; make preflight consult the child event when appropriate.
- Focused regressions cover configuration/install/upgrade/third-party preservation, event eligibility, payload, block/advisory, concurrency and preflight. Age expiry demonstrably releases unresolved blocks, so registered identities must not expire without confirmed termination.
- Use an isolated native fixture for real allow/block and retry evidence; never alter global configuration. Keep Instructions, SubagentStart context, Codex, policy, receipts and directive size out of scope.
- Preserve active/high. Stop before commit, push, full manual suite or operational consolidation.
