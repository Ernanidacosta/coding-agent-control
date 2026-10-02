# Progress

## Current

Status: verifying
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

- Commit the operational active -> verifying checkpoint with normal hooks.
- Require fresh exact-SHA CI and independent evidence for that checkpoint before verifying -> done.
- Complete P1 only after the final checkpoint's applicable guarantees pass; do not start P2.

## Blockers

None

## Recently Completed

- Technical commit d6b2a544991d4b2e6388704fe7fd0e345064ebb4 passed normal hooks, all four CI jobs (37042156831), and the configured independent gate for that exact SHA.
- Demonstrated occupied-port collisions before OpenSSL bind in both trusted and untrusted probes, with BIO_bind: Address already in use.
- Replaced random port selection with kernel allocation/reservation at bind to 127.0.0.1:0; readiness reads the bound ACCEPT endpoint. Retry/timeout budgets and TLS/containment controls are unchanged.
- Focused doctor 5/5, containment 10/10, system trust 18/18, relevant ShellCheck and git diff --check passed.
- Repeated 40 serial and 40 concurrent doctors; verified 160 TLS processes terminated and 80 temporary directories removed.
