# Definition of Done

## Current Contract

- Main HEAD: da0fe3d0631921cc93248f0ea6e0493c79ab79fe; status remains verifying.
- agent-md.toml establishes per-check timeout 750 seconds and total timeout
  900 seconds. Required checks are lint and test; smoke is configured separately.
- Canonical test command: bash tests/run.sh; current collection is 972 tests.
- The local Risk proposal is high, stricter than the medium Git-bound baseline.
  Ordinary verification cannot satisfy its independent evidence requirement.

## Remaining Completion Gates

- [ ] Resolve the observed doctor TLS startup failure through separately
  authorized focused work, without weakening TLS, system trust or fail-closed.
- [ ] Obtain current applicable ordinary verification with no required failure;
  use ./.agent-md/bin/verify.sh for official verification when authorized.
- [ ] Establish an eligible independent trust baseline through the supported
  reviewed procedure and obtain valid external evidence bound to the intended
  clean operational HEAD. Do not let an anchor attest its own bootstrap change.
- [x] Validate reconciled memory structure and git diff --check; retain visible
  historical transition warnings rather than manufacture an intermediate state.
- [ ] Satisfy all applicable state, Risk and completion requirements before
  claiming done. No completion claim is made in this reconciliation.

## Preserved Invariants

- Per-check and total deadlines retain their normal semantics; subprocesses
  receive the lesser of the per-check and remaining total budgets.
- Required failures and expiry remain blocking; optional checks cannot bypass
  total expiry. Host transport envelopes must remain compatible.
- Stop may reuse applicable authenticated ordinary evidence; absent or unusable
  evidence retains the safe fresh-verification path. Pre-commit and explicit
  verify.sh perform ordinary verification without receipt reuse.
- Preserve the four identity manifests and two independent validation samples,
  concurrent-mutation detection, containment, immutable system trust and normal
  certificate validation. Staged issuance remains unsupported.
- Ordinary receipts, smoke and pre-commit results are not independent evidence.
- Memory remains outside receipt identity and technical commits; this phase
  stages nothing, creates no commit and performs no push.

## Historical Evidence — Administrative Bootstrap

- Commit 8503adf9cf5780eb6873decc0cae654395abacd2, parent 32eab15, changed only
  agent-md.toml: per-check timeout became 750; total timeout remained 900.
- Official ./.agent-md/bin/verify.sh passed, exit 0, on that isolated content
  in a linked worktree. The local authority rejects linked worktrees, so this
  run did not reuse authority receipts and supplied no independent evidence.
- Source: /tmp/cac-timeout-750-establishment-gpiqr1cg/verification-result.json.
  Bootstrap and promotion are complete; this result is not verification of the
  subsequent technical commit.

## Historical Evidence — Technical Commit

- Commit da0fe3d consolidated CI/lint, reseal and its coverage, TLS diagnostics,
  jq contract batching and fixtures/harness; memory was excluded.
- Normal pre-commit ran with hooks active: lint PASS, smoke PASS, test PASS;
  972 tests collected. The git commit command exited 0 without hook bypass.
- Sources: /tmp/cac-technical-commit-hds8t9zh/commit.log, commit-result.json,
  commit-start.json and integrity.json. These are audit records, not attestations.
- This establishes the historical staged result only; it does not override the
  later Stop failure or satisfy independent verification. No push was performed.

## Later Verification — Stop Failure

- The later Stop reported VERIFY_REQUIRED_FAILED for bash tests/run.sh, exit 1.
  The failing test was tests/authority-system-trust.bats:298, "local issuer
  doctor proves trusted and untrusted HTTPS without public internet".
- Captured diagnostic: untrusted local TLS server did not start; PID 2196540,
  port 50889, alive=no; server.log contained BIO_bind: Address already in use
  and BIO_bind: unable to bind socket.
- Source: the subsequent Stop hook output supplied in the checkpoint handoff.
  This demonstrates a bind-occupied failure in that execution. The competing
  process/socket state and cause of any other intermittence remain unknown.
- The latest reported full verification was not approved. No rerun or technical
  fix is claimed by this memory reconciliation.

## Independent Verification — Pending

- Independent verification remains pending/untrusted. The last reported warning
  was RISK_ATTESTATION_UNTRUSTED / trusted-file-modified; its current cause has
  not been reassessed after the workflow was committed in da0fe3d.
- Review of the current verifier baseline and establishment procedure belongs
  to the next separate phase. No trust-anchor change or local attestation is
  authorized here, and no external SHA-bound evidence is claimed.

## Historical State Warning

HEAD:memory/progress.md still declares done for the previous task. The work was
reopened and the true local status is verifying. The direct HEAD-to-worktree
comparison can therefore still emit STATE_TRANSITION_INVALID until a new
operational baseline is established. This is an advisory history warning, not
permission to fabricate done -> active -> verifying or to release a real block.
