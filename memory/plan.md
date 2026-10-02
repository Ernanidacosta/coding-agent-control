# Current Plan

## P1 — TLS Probe Port Race

The owner accepted the demonstrated race and its regression: a random port
remained unreserved until OpenSSL bound it. Both doctor listeners now allocate
and reserve their port during bind to 127.0.0.1:0 and retain that socket.

The technical commit passed normal hooks, exact-SHA CI and independent
verification. Establish the operational active -> verifying baseline, then
require fresh external evidence before verifying -> done. Each new HEAD needs
its own CI and independent evidence before final acceptance. Stop after P1.

Preserve Risk high, trusted/untrusted validation, fail-closed, startup diagnostics,
cleanup, retry/timeout budgets and containment. Do not change project policy.
