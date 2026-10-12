# Plan

- Close only the approved Claude essential context: canonical excerpts, independent Start hook, unchanged lifecycle/safety/completion and policy 750/900.
- Technical baseline 50a8d743f3f6c67d7b10944c9fc041cd0471ea65 is published with passing normal hooks, external CI and exact-SHA independent verification. ShellCheck 0.9 portability failure is resolved by the minimal explicit-if guard.
- Current checkpoint: active -> verifying. Publish/verify this SHA, then verifying -> done with its own CI/independent and final verify.sh; require clean synchronized Git. No bypass or automatic commit retry.
- After this closure, stop. The next task is Stabilize recommended CAC baseline, then dogfood affiliate-status-bot before gradual rollout. Directive truncation/budget, linked worktrees and staged issuance are post-adoption hardening; Productize CAC and new capabilities remain deferred.
