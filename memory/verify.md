# Definition of Done

## Current Contract

- Verified technical checkpoint: 17be88ea1502deabca963b4c034dd2922813f0bc;
  the owner approved Status done with Risk high.
- agent-md.toml establishes per-check timeout 750 seconds and total timeout
  900 seconds. Required checks are lint and test; smoke is configured separately.
- Canonical test command: bash tests/run.sh; current collection is 972 tests.
- The local Risk proposal is high, stricter than the medium Git-bound baseline.
  Ordinary verification cannot satisfy its independent evidence requirement.

## Satisfied Technical Checkpoint Gates

- [x] Normal commit hooks passed lint, smoke, test and operational state for
  17be88e without bypass; all eight enrollment fixtures passed externally.
- [x] External CI for the exact technical SHA passed all four jobs and 972/972
  Bats tests with zero skips, including both doctor TLS tests.
- [x] The owner reviewed da0fe3d as the human trust baseline; unchanged trust
  files made 17be88e eligible for independent evidence.
- [x] The configured provider returned independent PASS for 17be88e; the core
  independent gate returned VERIFY_PASSED for that same SHA.
- [x] Main and origin/main matched 17be88e with clean working tree and index
  at owner approval; no known mandatory gate remained pending for that SHA.

The historical TLS intermittence is retained as a gotcha, not declared fixed.
The operational closure commit remains subject to normal hooks and fresh
SHA-bound external evidence; the results below do not attest any descendant.

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
- Memory remains outside receipt identity. Operational closure uses a separate
  normal commit and push; executor-written memory never supplies attestation.

## Final Technical Checkpoint Evidence

- SHA: 17be88ea1502deabca963b4c034dd2922813f0bc, parent 23082db.
- GitHub Actions run: https://github.com/Ernanidacosta/coding-agent-control/actions/runs/36968346146.
- External shellcheck, static and install-smoke: PASS. Bats: 972 PASS, 0 FAIL,
  0 skips; enrollment cases 28/29/31/32/33/35/37/38 all passed.
- Normal pre-commit: lint, smoke, test and state PASS; commit exit 0, without
  bypass. This is ordinary evidence, not independent verification.
- Provider: ./examples/github-actions/github-actions-independent.sh, exit 0;
  status pass, kind independent, origin ci, exact target.commit equal to the
  full SHA above and reference equal to the external run above.
- The existing core independent gate returned status pass, code VERIFY_PASSED,
  exit 0, with an eligible unchanged trust anchor and clean commit binding.
- No ordinary receipt, smoke result or pre-commit result substituted for that
  independent evidence. The owner then explicitly approved checkpoint closure.
- Audit sources: /tmp/cac-enrollment-fixtures-ii5ysqqn/ci-final.json,
  ci-test-summary.json, provider-attestation.json, independent-gate.json,
  successful-commit.json and final-integrity.json.

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

## Historical Later Verification — Stop Failure

- The later Stop reported VERIFY_REQUIRED_FAILED for bash tests/run.sh, exit 1.
  The failing test was tests/authority-system-trust.bats:298, "local issuer
  doctor proves trusted and untrusted HTTPS without public internet".
- Captured diagnostic: untrusted local TLS server did not start; PID 2196540,
  port 50889, alive=no; server.log contained BIO_bind: Address already in use
  and BIO_bind: unable to bind socket.
- Source: the subsequent Stop hook output supplied in the checkpoint handoff.
  This demonstrates a bind-occupied failure in that execution. The competing
  process/socket state and cause of any other intermittence remain unknown.
- That execution was not approved. Both doctor tests passed in the later
  final technical CI run above; this non-reproduction does not establish a fix.

## Independent Trust Establishment

- The former trusted-file-modified warning no longer reproduced after the
  workflow was committed. The owner reviewed da0fe3d's exact trust-file hashes
  out of band; that human review was not CI or independent attestation.
- Workflow, verifier, config and agent-md.toml remained unchanged through
  23082db and 17be88e. Independent evidence for 17be88e came from its own
  successful external CI run and the configured verifier, as recorded above.

## Historical State Warning

The reopened 32eab15 baseline declared done and its verifying proposal produced
an advisory historical transition warning. Later operational commits established
verifying. The owner now approves verifying -> done, an allowed transition;
no intermediate state is fabricated and no blocking guarantee is released.
