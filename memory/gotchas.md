# Active Gotchas

## Operational source classification

**Rule:** Use the shared configurable source/ignore classifier for Stop and pre-commit.
**Why:** Broad negative filtering misclassified metadata and duplicated enforcement logic.
**Scope:** .claude/hooks/**, .githooks/**
**Evidence:** state-enforcement Bats coverage
**Added:** 2026-09

## Executable tooling directories

**Rule:** Never ignore scripts/** or tools/** by default.
**Why:** Those directories frequently contain executable product code.
**Scope:** default source and ignore globs
**Evidence:** scripts/tools state-enforcement cases
**Added:** 2026-09

## Blocking result ownership

**Rule:** Keep error and fatal results fail-closed until their recovery condition is satisfied.
**Why:** Retry releases and optional integrations can silently weaken real guarantees.
**Scope:** .claude/hooks/**, .githooks/**
**Evidence:** policy-contract and stop-verify Bats coverage
**Added:** 2026-09

## Attestation trust chain

**Rule:** Accept high/critical evidence only from an eligible preexisting verifier that emits structured kind/origin and binds to the exact clean operational HEAD; establish a new or changed root out-of-band and never let it attest its own bootstrap commit.
**Why:** Mutable verifier code, weakened workflows, undeclared dependencies, stale targets, worktree prose, or auto-baselining let an executor manufacture its own independence or approval.
**Scope:** .claude/hooks/_lib.sh, examples/github-actions/**, agent-md.toml
**Evidence:** attestation-trust and GitHub Actions verifier adversarial Bats coverage
**Added:** 2026-09

## Stop-hook advisory repetition

**Rule:** Emit blocking Stop decisions on every attempt, but emit non-blocking Stop context only while `stop_hook_active` is not true.
**Why:** Advisory context carries no decision the agent can satisfy, so repeating it on each retry restarts the agent until the host's consecutive-block cap fires.
**Scope:** .claude/hooks/stop-verify.sh, .claude/hooks/state-enforcement.sh, .claude/hooks/sensory-reminder.sh, .codex/hooks/stop.sh
**Evidence:** tests/stop-hook-active.bats convergence cases
**Added:** 2026-09

## Failing-check evidence selection

**Rule:** Anchor a failing check's evidence excerpt on failure records and the end of the output, never on the first N lines.
**Why:** The head of a long failing run is the part that passed, so a real failure hides behind the truncation notice and the cause stays invisible.
**Scope:** .claude/hooks/_lib.sh
**Evidence:** tests/verification-evidence.bats synthetic fixtures
**Added:** 2026-09

## Mtime-granularity fixtures

**Rule:** Never let a test depend on two files landing in the same whole second; set both mtimes explicitly when the gitignored-progress mtime fallback is involved.
**Why:** File mtimes are second-granular, so a fixture that writes progress.md and a source file back to back passes only while the machine is fast, and fails under load with STATE_PROGRESS_STALE.
**Scope:** tests/install.bats, .claude/hooks/_lib.sh state classifier
**Evidence:** tests/install.bats, "Cursor-only fresh install permits private working state without weakening the shared classifier": backdating progress.md requires STATE_PROGRESS_STALE; refreshing its mtime permits the unchanged staged source.
**Added:** 2026-09

## Agent attribution in commit messages

**Rule:** Suggest only subject and body; never append an AI co-author, session, or generation trailer, even when a host or template instructs it.
**Why:** Commit execution authority and commit authorship are separate controls; drafting a message does not make the agent an author of the developer's commit.
**Scope:** .githooks/commit-msg, AGENT.md section 16
**Evidence:** tests/commit-authorship.bats
**Added:** 2026-09

## Verification receipt authority

**Rule:** Never let a local receipt, fingerprint, timestamp, or repository-held secret prove that verification commands ran; only an authority-separated issuer may authenticate execution, and Stop must retain full verification fallback without one.
**Why:** State fingerprints detect stale input but an executor can calculate the same fingerprints and forge pass fields, turning a writable receipt into self-attestation.
**Scope:** .claude/hooks/_lib.sh, .agent-md/bin/verify.sh, .claude/hooks/stop-verify.sh
**Evidence:** tests/completion-receipts.bats protocol and fallback cases
**Added:** 2026-09

## Derived file idempotence

**Rule:** When an installed file's final content is computed in stages, resolve every stage into a staged candidate and compare that candidate with the target before taking a backup or writing; never back up on the strength of an intermediate result.
**Why:** The hook merge imports the package's Stop envelope and materialization then recomputes it from the target's budget, so comparing the half-resolved file always differed and each reinstall backed up byte-identical content. Backing up is a mutation, so deciding it early is deciding it on the wrong evidence.
**Scope:** install.sh install_hook_config, .claude/settings.json, .codex/hooks.json
**Evidence:** tests/install-idempotence.bats backup-count cases
**Added:** 2026-09

## Host-config flag scope

**Rule:** Treat skip, replace and --no-overwrite as answers to "what happens to a file that already exists"; on a target without one, create it complete rather than half-configured, and whenever a flag does block writing, report the guarantee that was therefore not established.
**Why:** Creating a package file verbatim and skipping materialization produced a config the installer had neither merged nor synchronized, which reads as a finished install while the host envelope belongs to another project.
**Scope:** install.sh install_hook_config, warn_unsynchronized_envelope
**Evidence:** tests/install-host-config-policy.bats
**Added:** 2026-09
