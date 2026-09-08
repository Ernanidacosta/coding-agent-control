# Definition of Done

## Required Checks

- [x] Focused UX tests cover standalone installs and capability timing.
- [x] `bats tests/` passes with all prior trust and enforcement regressions.
- [x] ShellCheck, JSON/TOML validation, alias sync, and `git diff --check` pass.

## Runtime Evidence

- [x] Fresh install works without ICM, `gh`, CI, or attestation configuration.
- [x] Doctor distinguishes configured, available, required now, blocking now,
  effect, and recovery without executing providers.
- [x] Claude/Codex and installer smoke tests remain green.

## Task-Specific Criteria

- [x] Quickstart and curl fallback install this fork, not upstream.
- [x] Basic workflow requires no advanced provider configuration.
- [x] Semantic memory is generic; ICM remains an optional compatible reference.
- [x] Blocking messages include concrete recovery while structured codes remain stable.
- [x] Existing high/critical completion requirements remain fail-closed.

## Independent Evidence

- Not required for this medium-risk UX phase; configured runtime/smoke evidence
  and the required verification contract remain applicable.
