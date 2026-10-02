# Progress

## Current

Status: active
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

- Consolidate the accepted TLS fix in a normal technical commit with hooks active.
- Obtain complete verification, exact-SHA external CI and independent evidence before active -> verifying.
- Close P1 through verifying -> done after the applicable evidence passes; do not start P2.

## Blockers

None

## Recently Completed

- Demonstrated occupied-port collisions before OpenSSL bind in both trusted and untrusted probes, with BIO_bind: Address already in use.
- Replaced random port selection with kernel allocation/reservation at bind to 127.0.0.1:0; readiness reads the bound ACCEPT endpoint. Retry/timeout budgets and TLS/containment controls are unchanged.
- Focused doctor 5/5, containment 10/10, system trust 18/18, relevant ShellCheck and git diff --check passed.
- Repeated 40 serial and 40 concurrent doctors; verified 160 TLS processes terminated and 80 temporary directories removed.
