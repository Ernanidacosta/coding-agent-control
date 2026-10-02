# Progress

## Current

Status: done
Task: P1 — eliminate the local authority doctor TLS probe port race.
Risk: high

## Scope

- examples/local-issuer/authority-lib.sh
- tests/authority-system-trust.bats
- memory/progress.md
- memory/plan.md
- memory/verify.md
- memory/gotchas.md

## Next

- Obtain fresh CI and independent evidence for the final operational SHA, then run the full verification entry point before accepting this done claim.
- Stop after P1. Any future HEAD requires its own applicable evidence; do not start P2.

## Blockers

None

## Recently Completed

- Verifying checkpoint 5ee4b993c44840b975dc6d483f02f8db779ae50b passed normal hooks, all four CI jobs (37045495562), 975 Bats tests and exact-SHA independent verification.
- Technical commit d6b2a544991d4b2e6388704fe7fd0e345064ebb4 passed normal hooks, all four CI jobs (37042156831), 975 Bats tests and exact-SHA independent verification.
- Demonstrated trusted/untrusted occupied-port collisions before OpenSSL bind; kernel allocation/reservation at 127.0.0.1:0 eliminated that race and the regression passed. TLS validation, fail-closed, diagnostics, containment and retry/timeout budgets are unchanged.
- Focused doctor 5/5, containment 10/10, system trust 18/18, relevant ShellCheck and git diff --check passed.
- Repeated 40 serial and 40 concurrent doctors; verified 160 TLS processes terminated and 80 temporary directories removed.
