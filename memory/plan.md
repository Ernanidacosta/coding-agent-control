# Current Plan

## Current Phase

The owner approved completion of technical checkpoint
17be88ea1502deabca963b4c034dd2922813f0bc after its ordinary, external CI and
independent gates passed. Record operational closure with Status done and
Risk high; use normal hooks and push, without changing technical policy.

Local issuance, authenticated receipts, Stop reuse, isolated execution and
system trust are implemented. Their architecture is not being reopened.

## Remaining Work

No technical work remains in this checkpoint. The operational closure commit
must pass normal hooks and receive fresh external evidence for its own SHA;
17be88e's attestation cannot cover a descendant. No extra manual suite is
authorized beyond what the hooks require.

The historical TLS bind failure remains a known observation, not a current
reproduced blocker or a claimed fix. See memory/gotchas.md.

## Decisions Still In Force

- The local Risk proposal remains high; the Git-bound control record is not
  changed automatically.
- A fingerprint proves state identity, never command execution.
- Only an authority-separated provider may authenticate a receipt.
- Without a trusted issuer, Stop executes the complete contract exactly as it
  does today.
- The latest authenticated attempt for the same state identity is authoritative;
  a later failure supersedes an earlier pass.
- Worktree and staged identities are distinct. Staged issuance is not supported;
  pre-commit continues full staged verification without receipt reuse.
- Preserve isolated-execution-v1 / bubblewrap-v1 containment, immutable system
  trust, normal TLS validation and fail-closed infrastructure refusal.
- Preserve the source, contract, control and mechanism manifests and the two
  independent identity samples used during receipt validation. Do not cache
  across samples or hide concurrent workspace mutation.
- Ordinary receipts never satisfy independent verification or approval.
- Local working memory remains outside receipt identity. Its authorized closure
  commit is separate from technical changes and never supplies attestation.

## Deferred / Out of Scope

- Staged issuance and its snapshot materialization.
- Further performance investigation, timeout changes or architectural redesign
  without new concrete evidence and owner direction; the budget is now 750/900.
- Technical code, CI, external documentation or trust-anchor changes during
  operational closure.
- Further TLS changes without new evidence and owner direction.
- Hook bypasses, force push or reuse of a previous SHA's independent evidence.

## Operational Warning

The earlier done-to-verifying warning belonged to the reopened 32eab15
baseline. Operational commits established verifying; the current owner-approved
transition is verifying -> done. No intermediate status is fabricated.
