# Current Plan

## P1 — TLS Probe Port Race

The owner accepted the demonstrated race and its regression: a random port
remained unreserved until OpenSSL bound it. Both doctor listeners now allocate
and reserve their port during bind to 127.0.0.1:0 and retain that socket.

Consolidate the existing fix without further TLS changes. Commit with active
state and normal hooks, push origin/main, then require complete verification,
external CI and independent evidence for each exact checkpoint SHA. Establish
active -> verifying before verifying -> done. Stop after P1; do not start P2.

Preserve Risk high, trusted/untrusted validation, fail-closed, startup diagnostics,
cleanup, retry/timeout budgets and containment. Do not change project policy.
