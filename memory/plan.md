# Plan

- Scope: advisory instructions only; preserve lifecycle correlation, tool safety, completion gates, policy and timeouts.
- Extract literal marked excerpts from canonical AGENT.md; synchronize existing mirrors. No separate hand-maintained policy text. Bound output to 2560 UTF-8 bytes and 48 lines.
- Use a separate SubagentStart hook, independent of registration storage. Send the small context on every valid Start because the host exposes no loaded-directives flag; agent_type is not authority. Internal Stop alone receives nothing.
- Essential: human authority/ambiguity, invariants over convenience, current operational handoff, scope, plan-only intent/blocker escalation, evidence and no reduced verification, commit/push consent. Exclude mechanical hook rules, parent checkpoint maintenance, examples/history/editorial guidance.
- Technical implementation and evidence accepted: 122 distinct focused tests and four native serialized-context/canary proofs. Complete the full gate, normal technical commit, CI/independent per SHA, active -> verifying -> done checkpoints, then final verify.sh and clean synchronized Git state. Stop on a failed gate; no bypass or automatic commit retry.
- Next task after this closure: Stabilize recommended CAC baseline, then dogfood affiliate-status-bot before gradual rollout. No new features. Directive truncation/budget, linked worktrees and staged issuance are post-adoption hardening; Productize CAC and other roadmap capabilities remain deferred.
