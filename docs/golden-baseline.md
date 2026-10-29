# Golden Baseline GB-1

A Golden Baseline records a known, reproducible state of coding-agent-control
and the real consumers that run it. It is not a claim that this state is
perfect. Everything listed under exceptions is part of the baseline as it
stands.

| Field | Value |
|---|---|
| ID | GB-1 |
| Date | 2026-10-29 |
| CAC release | `v1.0.0-rc2` (GitHub pre-release) |
| Tag object | `239846b3f3ec675e3d4163b152457b51c70fcd45` |
| CAC SHA (installed by consumers) | `bf43a0f5d1b92712851b939f942fa80268ba757d` |
| CAC repository HEAD audited for the freeze | `169d3d55b6c834beebe0b104f6f254ffc5854eaa` (CI 40817783740, exact-SHA independent attestation) |

That HEAD differs from the release commit only by `memory/` and by pinning
every CI job to `ubuntu-24.04`. The commit that adds this file records the
freeze and changes nothing else outside `memory/`. The installed contract is
the tagged commit.

## Consumers

| Consumer | Branch | Consumer SHA | CAC | Risk | Control | Doctor | Verify | Independent | Status |
|---|---|---|---|---|---|---|---|---|---|
| ia-search-jobs | `feat/phase-17-6-admin-operations` | `a83fd08ea0e22e178c71b7fffea97905e404386e` | rc2, provenance `bf43a0f` | high | `.project-control.toml` and `agent-md.toml` in Git | pass | 4 passed, 0 warnings | GitHub Actions run 40783009480, attestation for the exact SHA | PASS |
| waha-operacional-tm2 | `main` | `c616991c283b340a2b73d3ce65a99f1647eecad9` | rc2, provenance `bf43a0f` | medium | `.project-control.toml` and `agent-md.toml` in Git | pass, 1 warning | 3 passed, 1 advisory warning, 0 blocking | not configured (not required at medium) | PASS |
| affiliate-status-bot | `master` | `9922c754b5c87e8495d9962e459aa9b208ad018f` | pre-rc1 snapshot, no provenance | medium | `.project-control.toml` and `agent-md.toml` in Git | pass | not run | not configured | DEFERRED |

- **ia-search-jobs:** production runs `37f538d`. Between it and the baseline
  SHA only `.github/`, hooks, `memory/` and two inert configuration files
  change.
- **waha-operacional-tm2:** `c616991` is deployed on the host. The deploy
  marker is `c616991`, `deploy OK` was logged with health 200, and the app
  container is healthy.
- **affiliate-status-bot:** deferred because a product task
  (`AMAZON-SCHEDULE-1`) is active. Its installed CAC predates rc1, with files
  matching between `ca7ed61` and `da0fe3d`. Converging means a pinned
  `--ref=v1.0.0-rc2` install, a review of its customizations and `.bak` files,
  and a `verify.sh` on rc2, after the product task closes.

## Baseline Exceptions

These facts are needed to reproduce the current state. They are not defects to
fix inside GB-1.

**Host**
- The global gitignore (`~/.gitignore_global`) ignores `.agent-md/`, `.claude/`,
  `.githooks/`, `AGENT.md`, `CLAUDE.md` and `agent-md.toml`. CAC files enter Git
  only with `git add -f`.
- No local authority is installed. Enrollment remains an optional owner step.

**CAC**
- CI requires `ubuntu-24.04`. `ubuntu-26.04` default ACLs fail the bats host
  trust prerequisite.
- A full `verify.sh` takes 522–744 s against a 750 s per-check limit.

**ia-search-jobs**
- Two CI tests are skipped by design (`test_compose_port_binding.py` needs
  `deploy/secrets`).
- Stage A lives only on the local branch `wip/phase-17-4-stage-a-v2`, which is
  not pushed.
- 20 installer `.bak` files.

**waha-operacional-tm2**
- CAC files other than `agent-md.toml` and `.project-control.toml` are not
  versioned.
- `memory/` is local only.
- No per-check timeout is configured; doctor reports the legacy completion
  budget.
- No runtime or smoke check is declared, so a medium done claim warns
  `RISK_RUNTIME_EVIDENCE_REQUIRED`. The owner accepted this advisory warning
  for GB-1; the policy stays unchanged.
- The superseded pre-commit customization stays as `.githooks/pre-commit.bak`.
- The host deploy takes about 14m40s against `TimeoutStartSec=15min`. The first
  run for `c616991` timed out; the next run deployed it.
- 19 installer `.bak` files.

**affiliate-status-bot**
- Pre-rc1 CAC without provenance.
- `memory/` is local only.
- A linked worktree, `affiliate-status-bot-lab`, exists on
  `lab/ml-catalog-lane`.
- 10 installer `.bak` files.

## Post-Baseline Backlog

Nothing here is a GB-1 blocker.

- `VERIFY_UNAVAILABLE` does not name the missing path or binary.
- Upgrades leave many `.bak` files.
- `.project-control.toml` guidance is unclear.
- A host global gitignore can hide newly installed hooks (seen in two consumers).
- `git cherry-pick` does not carry operational state or `progress.md`.
- Directive budget and truncation.
- Local authority with linked worktrees.
- Staged issuance.
- Verification timeout hardening.
- Adapt the CI host trust prerequisite to `ubuntu-26.04`.
- Productize, Ponytail, Failure Ratchet and evals.
- WAHA host deploy timeout margin (consumer-side, owner decision).

## Validity

GB-1 stays valid while all of the following hold:

- tag `v1.0.0-rc2` still peels to `bf43a0f5d1b92712851b939f942fa80268ba757d`
  and is neither moved nor recreated;
- each PASS consumer keeps the listed SHA on its official branch, or a
  descendant that changes neither CAC files nor `.project-control.toml` nor
  `agent-md.toml`, and its provenance still names `v1.0.0-rc2` and
  `bf43a0f`;
- each consumer's effective Risk and policy remain as listed;
- no new CAC release, rc3 or CAC feature is adopted by a listed consumer.

Any change to the CAC code, a consumer's installed CAC, its Risk or its policy
ends GB-1. The next baseline gets a new ID. A DEFERRED consumer joins only
through that new baseline or an explicit amendment.
