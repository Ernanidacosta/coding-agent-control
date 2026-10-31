# Golden Baselines

A Golden Baseline records a known, reproducible state of coding-agent-control
and the real consumers that run it. It is not a claim that this state is
perfect. Everything listed under exceptions is part of the baseline as it
stands. The newest baseline comes first; earlier ones stay as history.

## Golden Baseline 2 — v1.0.0-rc3

| Field | Value |
|---|---|
| ID | GB-2 |
| Date | 2026-10-31 |
| CAC release | `v1.0.0-rc3` (GitHub pre-release) |
| Tag object | `45b91f9fb42cebf0eadb32fd0e27011afa2239bb` |
| CAC release SHA (installed by consumers) | `0f21e47d231120e82a47109c589c8c9f7b97e5e8` |
| Release CI | GitHub Actions run 41127895279: static, shellcheck, bats and install-smoke passed |
| Independent verification | pass (`kind: independent`, `origin: ci`) for exactly `0f21e47d231120e82a47109c589c8c9f7b97e5e8` |
| Verify | `verify.sh`: 4 passed, 0 warnings, 0 blocking failures (status `done`) |
| CAC Risk | high (`.project-control.toml` declares medium; the stricter local proposal makes high effective) |

The audit found the tag unmoved and peeling to the release SHA, locally and on
the remote, with `origin/main` at the release SHA and a clean tree. The commit
that adds this section changes only this file and `memory/`; the installed
contract is the tagged commit.

### Consumers

| Consumer | Status | SHA | CAC | Risk | Verify | Independent/Authority | Production |
|---|---|---|---|---|---|---|---|
| ia-search-jobs | PASS | `2a47dbb3376223306d6b86c0ac5572616c2a50b6` on `feat/phase-17-6-admin-operations` | rc3, provenance `0f21e47` | high | 4 passed, 0 warnings | GitHub Actions run 41217801565, attestation for the exact SHA | container image revision `1ffcf51` (code of `37f538d`), started 2026-10-28, healthy; not touched by the rollout |
| waha-operacional-tm2 | PASS | `c616991c283b340a2b73d3ce65a99f1647eecad9` on `main` | rc3, provenance `0f21e47` | medium | 3 passed, 1 accepted advisory warning, 0 blocking | not configured (not required at medium) | Pi checkout and deploy marker at `c616991`; no container recreated; health, gateway monitor and deploy timers active |
| affiliate-status-bot | PASS | `f3ee52e02ab2b36db469596c35ed3c82ca50f60f` on `master` | rc3, provenance `0f21e47` | medium | 3 passed, 0 warnings | local authority reinstalled from rc3 and reapproved by the owner (approval id `57104fe5-e610-4e5c-831e-dc6b86805bce`); receipt 197 authenticated, current, reusable | deployed `f3ee52e` (deploy gate 3093 passed, 4 skipped); deploy marker = HEAD; containers healthy, not recreated, env hashes unchanged |

In all three consumers `agent-md.toml` and `.project-control.toml` are in Git,
doctor exits 0, the origin branch matches the audited SHA, and the installed
`_lib.sh`, `stop-verify.sh`, `verify.sh`, `doctor.sh`, `pre-commit` and
`commit-msg` are byte-identical to the tag.

- **ia-search-jobs:** since `1ffcf51` only CAC tooling, `.github/`, `memory/`
  and one integration test change. Stage A stays on the unpushed local branch
  `wip/phase-17-4-stage-a-v2`.
- **waha-operacional-tm2:** the rc3 rollout changed no versioned file. The
  rollout snapshot also recorded the Access configuration, gateway checks and
  `WORKING` session unchanged.
- **affiliate-status-bot:** the six installed authority files match the tag.
  The Amazon scheduler still runs at `02:30,18:30 UTC`. WAHA and Telegram
  publishing were preserved in the rollout snapshot.

### Accepted Exceptions

These limitations are already known and do not block GB-2. They are part of
the baseline, not work for this task.

- `--dry-run` messages are still imprecise.
- The installer leaves `.bak` files (20 in waha-operacional-tm2, 35 in
  affiliate-status-bot; six of these are untracked in its worktree).
- CI runs on `ubuntu-24.04`; `ubuntu-26.04` is not supported by the current
  bats host trust prerequisite.
- Local authority does not support linked worktrees; affiliate-status-bot still
  has `affiliate-status-bot-lab` on `lab/ml-catalog-lane`.
- Staged issuance is not supported.
- waha-operacional-tm2 warns `RISK_RUNTIME_EVIDENCE_REQUIRED` (no runtime or
  smoke check is declared) and has no per-check timeout.
- The global gitignore makes doctor warn `CRITICAL_FILE_IGNORED` for files kept
  local on purpose (1 in CAC, 7 in waha-operacional-tm2, 7 in
  affiliate-status-bot).
- The post-edit lint hook can depend on the session's working directory.
- The Stop hook resolves checks from the session's working directory and can
  fail outside the repository root. This is a post-GB-2 finding, not fixed here.
- Escape sequences in double-quoted `agent-md.toml` strings are validated but
  kept verbatim.
- Cursor and Windsurf directive budgets are implementation-dependent.
- Claude orphan lifecycle records can remain until termination is confirmed,
  and SubagentStart cannot block child creation when registration fails.

### Validity

GB-2 stays valid while all of the following hold:

- tag `v1.0.0-rc3` still peels to `0f21e47d231120e82a47109c589c8c9f7b97e5e8`
  and is neither moved nor recreated;
- each consumer keeps the listed SHA on its official branch, or a descendant
  that changes neither CAC files nor `.project-control.toml` nor
  `agent-md.toml`, and its provenance still names `v1.0.0-rc3` and `0f21e47`;
- each consumer's effective Risk and policy remain as listed;
- no CAC release after rc3 is adopted by a listed consumer.

Any change to the CAC code, a consumer's installed CAC, its Risk or its policy
ends GB-2. The next baseline gets a new ID.

## Golden Baseline 1 — v1.0.0-rc2

Historical record, superseded by GB-2.

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

### Consumers

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

### Baseline Exceptions

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

### Post-Baseline Backlog

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

### Validity

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
