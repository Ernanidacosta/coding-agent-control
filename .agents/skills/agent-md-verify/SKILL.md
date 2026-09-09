---
name: agent-md-verify
description: Use when finishing work in a repository that has coding-agent-control installed; executes its required/optional verification contract, updates operational progress, and reports concrete evidence instead of self-grading.
---

# coding-agent-control Verification

Use this compatibility-named skill before claiming work is complete in a
coding-agent-control repository.

1. Read `memory/verify.md` for task-specific evidence and definition of done.
2. Read the established Risk in `.project-control.toml` and any stricter local/legacy proposal in `memory/progress.md`. Do not infer low, migrate state silently, or lower the effective value; observed signals are review warnings, not classifications.
3. Run `./.agent-md/bin/verify.sh`. It displays the effective Git-baseline-plus-worktree verification and Risk contracts, executes base checks, and applies additional completion requirements only when `Status: done`.
4. Do not skip a required failure, unavailable command, timeout, missing or untrusted high-risk independent verifier, invalid/stale/unbound attestation, or missing critical human-approval attestation. Fix the problem and rerun the same entry point. Optional failures remain visible warnings.
5. Execute evidence-specific checks not represented by the generic contract when applicable, such as required visual evidence. Medium/high/critical runtime applicability is advisory only when neither runtime nor smoke is declared.
6. For operationally relevant changes, keep local `memory/progress.md` in `verifying` while checks are pending. `Status: done` is a completion claim, never proof; accept that claim only after applicable state-integrity, required-verification, Risk, attestation, and approval requirements pass. Keep one current Task when required, immediate Next, explicit Blockers, and no more than five recent outcomes. Do not stage local working state automatically.
7. If no checks are configured or inferred, report the work as unverified and add a follow-up to define checks. Never convert “not verified” into “pass.”
8. Report concrete evidence: check name, command, exit status, and concise result. Do not infer success from output wording or code inspection.
9. Independent and approval evidence must come through pre-existing eligible trust anchors. Require one structured JSON attestation with the expected kind, allowed origin, and exact current HEAD target. Repo-local anchors and their declared files must match HEAD; a verifier cannot bootstrap trust in the same change that introduces or modifies it. External-anchor filesystem trust belongs to the host. Declared provider capabilities may warn while work is active/verifying but block a final guarantee when unavailable; never install or authenticate them automatically. This skill never writes an attestation or approval, treats prose as approval, invokes a reviewer/model automatically, or claims that another check run by the executor is independent.
10. Keep historical detail out of `memory/`. Git is factual code history; an optional semantic-memory provider may supply historical recall. `[integrations.icm] enabled = true` selects the compatible ICM reference integration, never a verification dependency.

Useful helper:

```bash
./.agent-md/bin/verify.sh
```
