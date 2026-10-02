# Current Plan

## P1 — TLS Probe Port Race

The owner accepted the demonstrated race and its regression: a random port
remained unreserved until OpenSSL bound it. Both doctor listeners now allocate
and reserve their port during bind to 127.0.0.1:0 and retain that socket.

The technical and verifying checkpoints passed normal hooks, exact-SHA CI and
independent verification. Establish verifying -> done with normal hooks, then
require fresh CI, independent evidence and full verification for the final HEAD
before accepting the completion claim. Stop after P1; do not start P2.

Preserve Risk high, trusted/untrusted validation, fail-closed, startup diagnostics,
cleanup, retry/timeout budgets and containment. Do not change project policy.
