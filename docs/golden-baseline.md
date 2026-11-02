# Golden Baselines

A Golden Baseline records a known, reproducible state of coding-agent-control
and the real consumers that run it. It is not a claim that this state is
perfect. Everything listed under exceptions is part of the baseline as it
stands. The newest baseline comes first; earlier ones stay as history.

## Golden Baseline 4 — v1.0.0 Final

| Field | Value |
|---|---|
| ID | GB-4 |
| Date | 2026-11-02 |
| CAC release | `v1.0.0` (stable GitHub release, marked Latest) |
| Tag object | `bbc48bc6c3e648512c442fe33831fc6ace8bd053` |
| CAC release SHA (installed by consumers) | `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` |
| Release CI | GitHub Actions run 41369614661: static, shellcheck, bats and install-smoke passed |
| Independent verification | pass (`kind: independent`, `origin: ci`) for exactly `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` |
| Verify | `verify.sh`: 4 passed, 0 warnings, 0 blocking failures (status `done`) |
| CAC Risk | high (`.project-control.toml` declares medium; the stricter local proposal makes high effective) |

GB-4 closes the v1.0.0 release line. The audit found the tag unmoved and
peeling to the release SHA, locally and on the remote, with `origin/main` at
the release SHA, a clean tree, an empty index and no stash. The release is
neither a draft nor a pre-release, and its notes carry the known limitations
and the rollback note for releases before rc4. Doctor exits 0. The commit that
adds this section changes only this file and `memory/`; the installed contract
is the tagged commit.

### Consumers

| Consumer | SHA | CAC | Risk | Verify | Independent/Authority | Production |
|---|---|---|---|---|---|---|
| ia-search-jobs | `d9161369a9230daf88c05421e66b03b3068284ab` on `feat/phase-17-6-admin-operations` | `v1.0.0`, provenance `github-ref`, `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` | high | 4 passed, 0 warnings | independent verification passed for the exact consumer SHA (GitHub Actions run 41325650214) | not touched by the rollout; no deploy needed |
| waha-operacional-tm2 | `c616991c283b340a2b73d3ce65a99f1647eecad9` on `main` | `v1.0.0`, provenance `github-ref`, `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` | medium | 3 passed, 1 accepted advisory warning, 0 blocking | not configured (not required at medium) | Pi checkout at `c616991`; nothing pushed, no deploy; the Pi snapshots before and after the rollout match |
| affiliate-status-bot | `63835300264eb45e0028cf69022c663b3c3f398c` on `master` | `v1.0.0`, provenance `github-ref`, `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` | medium | 3 passed, 0 warnings | local authority, approval id `57104fe5-e610-4e5c-831e-dc6b86805bce`, no reapprove needed; receipt 203 authentic, current and applicable (`reusable_ordinary`) | deploy marker `63835300264eb45e0028cf69022c663b3c3f398c`; containers not recreated, env hashes unchanged; WAHA, Telegram and the `02:30,18:30 UTC` scheduler preserved |

In all three consumers the origin branch matches the audited SHA, the tracked
tree, index and stash are clean (affiliate-status-bot keeps its six untracked
`.bak` files from earlier installs), `agent-md.toml` and
`.project-control.toml` are in Git and unchanged against HEAD, and doctor exits
0. The 19 package files under `.claude/hooks/`, `.codex/hooks/`,
`.agent-md/bin/` and `.githooks/` are byte-identical to the tag.
`.claude/settings.json` and `.codex/hooks.json` differ from the tag only in the
Stop envelope timeouts. Each `.claude/settings.json` has the 11 package
handlers, all quoted. The promotion changed no versioned file in any consumer.

### Equivalence With RC4

`v1.0.0` introduces no behavior change over `v1.0.0-rc4`:

- between `0fdf9a7` and `6714cc9` nothing changes under `.claude/`, `.codex/`,
  `.agent-md/`, `.githooks/`, `.github/`, `examples/`, `AGENT.md`,
  `agent-md.toml` or `.project-control.toml`;
- the mechanism is byte-identical and the trust material is identical;
- the difference is release metadata: the pinned Quickstart ref in both
  READMEs, the `install.sh` usage comment, the test that keeps them in sync,
  this manifesto and `memory/`.

No broad behavioral dogfood was needed for the final. The three consumers were
promoted from rc4 to `v1.0.0` without regression. Only provenance changed. In
affiliate-status-bot that made receipt 201 stale, because the receipt snapshot
includes `install-provenance.json`; receipt 203 covers the promoted state.

### Release Lineage

`v1.0.0-rc1` → `v1.0.0-rc2` → `v1.0.0-rc3` → `v1.0.0-rc4` → `v1.0.0`

- **rc1** (`25943d7`): first candidate for real dogfooding: Claude Code and
  Codex hooks, safety, state and Risk, the verification contract, subagent
  completion, independent verification and the optional local authority.
- **rc2** (`bf43a0f`): release-pinned installation (`--ref`) with recorded
  provenance; frozen in GB-1.
- **rc3** (`0f21e47`): strict `agent-md.toml`, ignored critical files
  reported, directive budget and an existing `core.hooksPath` preserved;
  frozen in GB-2.
- **rc4** (`0fdf9a7`): completion evaluated from the canonical repository root
  and quoted `$CLAUDE_PROJECT_DIR`; frozen in GB-3.
- **v1.0.0** (`6714cc9`): promoted from rc4 after GB-3 and a passing
  CAC-V1.0.0-READINESS, with no RC5 needed.

### Final Invariants

- **Completion fails closed:** a failing, unavailable or timed-out required
  check, invalid configuration or missing final evidence blocks a `done`
  claim; outside a Git worktree Stop blocks with `VERIFY_UNAVAILABLE`.
- **Root canonicalization:** Claude Code and Codex reach the same completion
  decision at the repository root and in any subdirectory.
- **Strict policy:** the whole `agent-md.toml` is validated before use; an
  invalid document is `CONFIG_INVALID` and never weakens the contract.
- **Independent verification:** high and critical Risk need an attestation
  bound to the exact HEAD from a reviewed verifier, with no self-approval.
- **Local authority:** an owner-approved issuer runs the reviewed checks
  outside the agent; a mechanism change needs reapproval.
- **Authenticated receipts:** Stop reuses a receipt only when it is authentic,
  current and applicable to the exact state.
- **Provenance:** every consumer records source, ref and archive commit.
- **Git binding:** policy and control state are read from Git, and doctor
  reports control files hidden by ignore rules.
- **Safe upgrade:** reinstalling is idempotent, preserves third-party handlers
  and customizations, never replaces an existing `core.hooksPath`, and leaves
  one quoted copy of each Claude handler.
- **Tested consumers:** a high-Risk project with CI attestation
  (ia-search-jobs), an operational deployment (waha-operacional-tm2) and a
  local-authority project with authenticated receipts (affiliate-status-bot).

### Accepted Limitations

These are post-1.0 backlog items. None blocks GB-4 or the release.

| # | Limitation | Class |
|---|---|---|
| 1 | `--dry-run` can describe more writes than the install makes | installer UX |
| 2 | The installer can leave `.bak` files | installer UX |
| 3 | The global gitignore makes doctor warn `CRITICAL_FILE_IGNORED` for files kept local on purpose | advisory diagnostic |
| 4 | CI runs on `ubuntu-24.04`; `ubuntu-26.04` is outside the baseline | platform support |
| 5 | Local authority does not support linked worktrees | authority scope |
| 6 | Staged issuance is not supported | authority scope |
| 7 | `doctor.sh` can raise a false alarm when run from a subdirectory | diagnostic, cwd-dependent |
| 8 | `tdd-check.sh` resolves from the working directory; it is only a nudge | quality nudge, cwd-dependent |
| 9 | Cursor and Windsurf directive budgets depend on the host implementation | host-dependent |
| 10 | There is no consolidated rollback procedure | documentation |
| 11 | Rolling back to a release before rc4 can keep both the quoted and unquoted Claude handlers, so hooks run twice; no false PASS, and reinstalling rc4 or later restores one copy | rollback, documented in the release notes |
| 12 | Local authority needs reapproval when the mechanism changes | authority UX, by design |
| 13 | The receipt snapshot includes `install-provenance.json`, so promoting a tag makes the previous receipt stale even with an identical mechanism | authority UX, by design |
| 14 | When no applicable receipt exists, Stop can issue one at the end of a turn | documented authority and host behavior, not a trust failure |
| 15 | A `progress.md` ignored by Git is validated by the state gate only when an operationally relevant change exists or the file itself is in the relevant set | state-gate scope |

At medium Risk, runtime evidence stays advisory: waha-operacional-tm2 warns
`RISK_RUNTIME_EVIDENCE_REQUIRED` because it declares no runtime or smoke check.

### Validity

GB-4 stays valid while all of the following hold:

- tag `v1.0.0` still peels to `6714cc9a90327fb5fccd2f36db8bacc48d6a0222` and
  is neither moved nor recreated;
- each consumer keeps the listed SHA on its official branch, or a descendant
  that changes neither CAC files nor `.project-control.toml` nor
  `agent-md.toml`, and its provenance still names `v1.0.0` and `6714cc9`;
- each consumer's effective Risk and policy remain as listed;
- no CAC release after `v1.0.0` is adopted by a listed consumer.

Any change to the CAC code, a consumer's installed CAC, its Risk or its policy
ends GB-4. Work after `v1.0.0` is post-1.0 backlog, not a condition of this
release.

## Golden Baseline 3 — v1.0.0-rc4

Historical record, superseded by GB-4.

| Field | Value |
|---|---|
| ID | GB-3 |
| Date | 2026-11-01 |
| CAC release | `v1.0.0-rc4` (GitHub pre-release) |
| Tag object | `9c82227c57f0ff4c756d3637c2c2278e7886ce6e` |
| CAC release SHA (installed by consumers) | `0fdf9a7a9f43767c85e2156ab30c9c59809213de` |
| Release CI | GitHub Actions run 41298577221: static, shellcheck, bats and install-smoke passed |
| Independent verification | pass (`kind: independent`, `origin: ci`) for exactly `0fdf9a7a9f43767c85e2156ab30c9c59809213de` |
| Verify | `verify.sh`: 4 passed, 0 warnings, 0 blocking failures (status `done`) |
| CAC Risk | high (`.project-control.toml` declares medium; the stricter local proposal makes high effective) |

The audit found the tag unmoved and peeling to the release SHA, locally and on
the remote, with `origin/main` at the release SHA, a clean tree, an empty index
and no stash. Doctor exits 0. The commit that adds this section changes only
this file and `memory/`; the installed contract is the tagged commit.

### Consumers

| Consumer | Status | SHA | CAC | Risk | Verify | Independent/Authority | Production |
|---|---|---|---|---|---|---|---|
| ia-search-jobs | PASS | `d9161369a9230daf88c05421e66b03b3068284ab` on `feat/phase-17-6-admin-operations` | rc4, provenance `0fdf9a7` | high | 4 passed, 0 warnings | GitHub Actions run 41325650214, attestation for the exact SHA | container image revision `1ffcf51` (code of `37f538d`), started 2026-10-28, healthy; not touched by the rollout |
| waha-operacional-tm2 | PASS | `c616991c283b340a2b73d3ce65a99f1647eecad9` on `main` | rc4, provenance `0fdf9a7` | medium | 3 passed, 1 accepted advisory warning, 0 blocking | not configured (not required at medium) | Pi checkout at `c616991`, clean; health and ready 200, gateway ok, WAHA session `WORKING`; the rollout snapshots before and after match |
| affiliate-status-bot | PASS | `63835300264eb45e0028cf69022c663b3c3f398c` on `master` | rc4, provenance `0fdf9a7` | medium | 3 passed, 0 warnings | local authority programs match the tag, reapproved by the owner for the rc4 mechanism (approval id `57104fe5-e610-4e5c-831e-dc6b86805bce`); receipt 201 authenticated for the committed state and reused by Stop | deployed `6383530` (deploy gate 3097 passed, 4 skipped); deploy marker = HEAD; containers healthy, not recreated, env hashes unchanged |

In all three consumers `agent-md.toml` and `.project-control.toml` are in Git
and unchanged against HEAD, doctor exits 0, and the origin branch matches the
audited SHA. The 19 package files under `.claude/hooks/`, `.codex/hooks/`,
`.agent-md/bin/` and `.githooks/` are byte-identical to the tag.
`.claude/settings.json` and `.codex/hooks.json` differ from the tag only in the
Stop envelope timeouts, which the installer synchronizes from each consumer's
completion budget. Each `.claude/settings.json` has the 11 package handlers,
all quoted, and none in the legacy spelling.

- **ia-search-jobs:** the rollout added `cb60531` (CAC rc4), `d23aec4` (a CI
  test that holds the CI Python to the image's) and `d916136` (closing state).
  Since `1ffcf51` only CAC tooling, agent directives, `.github/`, `memory/`,
  tests and the inert `agent-md.toml` and `.project-control.toml` change; none
  needs a deploy. Stage A stays on the unpushed local branch
  `wip/phase-17-4-stage-a-v2` (`81655ed`), not merged.
- **waha-operacional-tm2:** the rc4 rollout changed no versioned file and
  pushed nothing. The Access configuration, gateway inventory, monitor state
  and timers are unchanged between the snapshots.
- **affiliate-status-bot:** `6383530` adds one test and no product change. The
  installed `_lib.sh` and `stop-verify.sh` are the rc4 mechanism the authority
  was reapproved for; `verify.sh` and the contract fingerprint are unchanged
  from rc3. The Amazon scheduler still runs at `02:30,18:30 UTC`; WAHA and
  Telegram publishing were preserved. Maintenance reported `needs_attention`
  for one offer without an affiliate link and one enrichment error. That state
  predates the rc4 deploy and is not a CAC result.

### RC4 Blocker Closure

GB-2 recorded that the Stop hook resolved checks from the session's working
directory. CAC-V1.0.0-READINESS reproduced a false PASS of a required check
and of a Risk high completion from a subdirectory, in Claude Code and Codex.
rc4 closes it:

- Stop no longer depends on the working directory. Completion hooks resolve
  the root of the Git worktree that owns them; outside a Git worktree Stop
  blocks with `VERIFY_UNAVAILABLE`.
- Checks run from that root, exactly as configured.
- Claude Code and Codex reach the same decision at the root and in any
  subdirectory.
- Policy and operational state are read from the root, never from a decoy
  `agent-md.toml` or `memory/` in a subdirectory.
- Claude hook commands quote `$CLAUDE_PROJECT_DIR`, so every hook starts in a
  path that contains spaces.
- Upgrading replaces the legacy unquoted handlers with one quoted copy of each
  and preserves third-party handlers.

Evidence:

- **CAC:** `tests/hook-root.bats` fails 19 of 19 on the rc3 tree and passes on
  rc4; `tests/claude-hook-paths.bats` covers spaces and the legacy upgrade.
  Throwaway rc3 and rc4 installs reproduce the false PASS on rc3 and identical
  root and subdirectory decisions on rc4, with root output unchanged from rc3.
- **ia-search-jobs:** isolated fixtures give the same Claude and Codex Stop
  decision at the root, `src/` and `src/pkg/` for Risk high without evidence
  (block) and for a failing and a passing required check, with decoys in
  `src/` ignored; path with spaces and the rc3 to rc4 upgrade with a
  third-party handler pass.
- **waha-operacional-tm2:** fixtures reproduce the rc3 false PASS and BLOCK
  and the exit 127 with spaces, and give identical decisions on rc4. Its
  checks mount the working directory and need the root `pyproject.toml`, so
  they pass only when run from the root.
- **affiliate-status-bot:** Claude and Codex Stop from `tests/` and
  `app/services/` match the root; invalid state and a failing required check
  block from a subdirectory.
- **Freeze audit:** on each committed `done` state the real configured Stop,
  started from a subdirectory, allows: ia-search-jobs from `apps/jobs` (Claude)
  and `apps` (Codex) with the exact-SHA attestation; waha-operacional-tm2 from
  `app/services` and `app`; affiliate-status-bot from `app/services` and
  `tests` through the authenticated receipt. No consumer changed.

### Accepted Exceptions

These limitations are already known and do not block GB-3. They are part of
the baseline, not work for this task.

- `--dry-run` messages are still imprecise.
- The installer leaves `.bak` files (26 in waha-operacional-tm2; 41 in
  affiliate-status-bot, six of them untracked in its worktree; ia-search-jobs
  moves them under `.agent/backup/`).
- CI runs on `ubuntu-24.04`; `ubuntu-26.04` is outside the supported baseline.
- Local authority does not support linked worktrees; affiliate-status-bot still
  has `affiliate-status-bot-lab` on `lab/ml-catalog-lane`.
- Staged issuance is not supported.
- Cursor and Windsurf directive budgets are implementation-dependent.
- At medium Risk, runtime evidence is advisory: waha-operacional-tm2 warns
  `RISK_RUNTIME_EVIDENCE_REQUIRED` because it declares no runtime or smoke
  check.
- waha-operacional-tm2 configures no per-check timeout.
- The global gitignore makes doctor warn `CRITICAL_FILE_IGNORED` for files kept
  local on purpose (1 in CAC, 7 in waha-operacional-tm2, 7 in
  affiliate-status-bot).
- `doctor.sh` resolves from the working directory and reports missing files
  when run from a subdirectory.
- `tdd-check.sh` resolves tracked status from the working directory.
- Auxiliary hooks (state reminder, sensory reminder, post-edit lint) stay
  silent when they cannot resolve the root; Stop fails closed in that case.
- The post-edit lint dependence on the working directory recorded in GB-2 is
  fixed in rc4 and is no longer an exception.
- There is no consolidated rollback procedure.

### Validity

GB-3 stays valid while all of the following hold:

- tag `v1.0.0-rc4` still peels to `0fdf9a7a9f43767c85e2156ab30c9c59809213de`
  and is neither moved nor recreated;
- each consumer keeps the listed SHA on its official branch, or a descendant
  that changes neither CAC files nor `.project-control.toml` nor
  `agent-md.toml`, and its provenance still names `v1.0.0-rc4` and `0fdf9a7`;
- each consumer's effective Risk and policy remain as listed;
- no CAC release after rc4 is adopted by a listed consumer.

Any change to the CAC code, a consumer's installed CAC, its Risk or its policy
ends GB-3. The next baseline gets a new ID.

## Golden Baseline 2 — v1.0.0-rc3

Historical record, superseded by GB-3.

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
