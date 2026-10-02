# Progress

## Current

Status: verifying
Task: Isolate enrollment fixtures from host state and obtain external verification for the resulting checkpoint.
Risk: high

## Scope

- memory/progress.md
- tests/authority-enrollment.bats

## Next

- Establish the fixture correction with normal commit hooks, then publish the exact resulting main SHA only with a clean checkout and unchanged trust files.
- Require all four external CI jobs to pass for that exact SHA before running the configured independent verifier; stop on failure without an automatic correction or retry.
- Present ordinary and independent evidence before any completion claim. Keep the historical TLS intermittence separate; no TLS change is authorized in this task.

## Blockers

- External CI for 23082db failed eight enrollment cases. The corrected fixtures passed focused local checks, but external confirmation for the new commit and independent verification remain pending.
- A later Stop reported VERIFY_REQUIRED_FAILED in the system-trust doctor test: BIO_bind: Address already in use, observed port 50889, probe process dead. This establishes an occupied-bind failure in that execution, not the identity of the competing process or a general cause of all intermittence.

## Recently Completed

- Established the reviewed timeout baseline in administrative commit 8503adf: per-check 750 seconds, total 900 seconds; bootstrap is complete.
- Promoted main by fast-forward without losing the existing local diffs.
- Consolidated CI/runtime hardening, reseal coverage, TLS diagnostics, jq contract batching and fixtures/harness in technical commit da0fe3d; memory stayed outside that commit.
- The owner reviewed da0fe3d as the human trust baseline; operational commit 23082db was published with its workflow, verifier, config and policy unchanged. This review is not independent attestation.
- Corrected the eight fixtures without changing production controls: enrollment 38/38, related cases 5/5 and the adverse-environment model 8/8; ShellCheck passed. The initial normal commit attempt passed lint, smoke and test but was blocked by STATE_PROGRESS_STALE; the owner authorized this progress update and resumption.
