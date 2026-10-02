# Definition of Done

## P1 — TLS Probe Port Race

- Preserve normal certificate/hostname validation, trusted success, untrusted
  rejection, fail-closed, diagnostics, cleanup and containment.
- The competing-bind regression must fail on the old random-port implementation
  and pass with allocation/reservation during the server's own bind.
- Keep initial Status active; require normal hooks, complete verification,
  exact-SHA external CI and independent evidence before final state transitions.
- Required policy remains lint and test, with configured smoke, per-check budget
  750 seconds and total budget 900 seconds. Local Risk high requires trusted
  independent evidence; focused checks do not replace the full contract.

## Accepted Focused Evidence

- WSL2/Linux, OpenSSL 3.6.3: trusted collision port 37190/PID 3759560 and
  untrusted collision port 32097/PID 3769101; both alive=no, exit_status=0,
  BIO_bind: Address already in use, doctor exit 1.
- New competing-bind Bats regression failed before the production fix and passed
  afterward; dead-server/invalid-readiness cases retain diagnostics and cleanup.
- Doctor 5/5, containment 10/10, system trust 18/18; relevant ShellCheck and
  git diff --check passed. Existing Bats SC2016 finding is excluded explicitly.
- 40 serial + 40 concurrent doctors passed, with 160 processes terminated and
  80 probe directories removed; /tmp/cac-tls-probe-investigation/fixed-repetition.json.
- README reviewed; local trusted/untrusted TLS behavior remains accurately described.

## Technical Checkpoint Evidence

- SHA d6b2a544991d4b2e6388704fe7fd0e345064ebb4: normal commit hooks passed
  lint, smoke, test and operational state; external CI 37042156831 passed all
  four jobs and 975 Bats tests, including all three new doctor regressions.
- Configured independent gate: VERIFY_PASSED, eligible trust anchor, origin ci,
  target.commit equal to that exact SHA. This evidence does not cover descendants.
- Audit records: /tmp/cac-p1-tls-checkpoint/technical-{commit.log,ci.json,independent.json}.

## Operational Checkpoint Evidence

- SHA 5ee4b993c44840b975dc6d483f02f8db779ae50b: normal hooks passed;
  external CI 37045495562 passed all four jobs and 975 Bats tests.
- Configured independent gate returned VERIFY_PASSED for that exact SHA with
  eligible trust anchor and origin ci. The final operational HEAD needs fresh
  CI and independent evidence plus the full verification entry point.
- Audit records: /tmp/cac-p1-tls-checkpoint/verifying-{commit.log,ci.json,independent.json}.
