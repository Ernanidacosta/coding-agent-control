# Performance Baseline — v1.0.1

This records how fast coding-agent-control `v1.0.1` is on one reference host,
measured before any optimization. It is the reference workload for future A/B
comparisons: an optimization is accepted only against these numbers, re-measured
on the same host with the same commands. Nothing was optimized or reconfigured
to produce it.

| Field | Value |
|---|---|
| CAC release | `v1.0.1` (tag `336dfdd7f366fd3aa1e95f454f70a29d2ebcf822`) |
| Measured commit | `54e3d957872b6087aeb6f9e164fe5fecaf46780b` |
| Dates | 2026-11-06 to 2026-11-07 |
| Suite | 1113 bats tests in 57 files, `BATS_JOBS` default 6 |
| Policy | `agent-md.toml` as committed: lint, test (required), smoke (optional), independent; `timeout_seconds = 750`, `total_timeout_seconds = 900` |

Every figure below is either **observed** (measured directly) or **estimated**
(derived from observed counts multiplied by observed unit costs). Estimates are
labelled.

## Environment

| Item | Value |
|---|---|
| CPU | AMD Ryzen 5 5625U (laptop, U-series), 6 cores / 12 threads, 1 socket |
| RAM | 7.6 GiB, 2 GiB swap; about 2 GiB available at rest |
| OS | Arch Linux on WSL2, kernel 6.18.33.2-microsoft-standard-WSL2 |
| Filesystems | repository on ext4 (`/dev/sdd`); `/tmp` (bats temporary files) on tmpfs |
| Tools | bash 5.3.20, bats 1.14.0, GNU parallel 20260922, jq 1.8.2, Python 3.14.9, git 2.56.0, shellcheck (lint), zsh 5.9.2 (interactive shell) |
| Background | several idle agent sessions (about 1–2 % CPU each); the ia-search-jobs daily run (systemd timer, about 10 min) was allowed to finish before measuring |

Unit costs on this host (observed, 200 calls each): `jq` 2.2 ms, `awk` 1.8 ms,
`git rev-parse` 1.5 ms, `git status` 2.4 ms, `sha256sum` 2.0 ms, `bash -c :`
1.4 ms, an empty command substitution 0.4 ms, one `toml_document` parse of
`agent-md.toml` 2.8 ms, one `read_toml` lookup 6.0 ms. Process creation is the
dominant unit of cost everywhere below.

## Protocol

- **Entry point.** `./.agent-md/bin/verify.sh` from the repository root under
  `/usr/bin/time`, with a 5-second sampler of load average, `MemAvailable` and
  `SwapFree`. System-wide process creations are the delta of `processes` in
  `/proc/stat`.
- **A — idle.** No other CAC suite or verify running; load average below 0.5
  before the first run. Three consecutive full runs.
- **B — controlled contention.** Six CPU busy loops (`python3 -c 'while True:
  pass'`, half the hardware threads) plus one loop writing 256 MiB with
  `fdatasync` to the repository's ext4 filesystem. The writer also occupies
  about one core, so B is roughly seven busy cores plus sequential write I/O.
  Load starts 20 s before the first run and is stopped by a trap. Three
  consecutive full runs.
- **Breakdown.** Each configured check run alone, exactly as `verify.sh`
  would run it, once idle and once under B. The suite runs as `bats --jobs 6
  --timing --report-formatter junit`, which gives per-test and per-file times.
- **Framework overhead.** A disposable repository with `v1.0.1` installed and
  trivial checks (`lint`, `test` and `smoke` all `true`), so only CAC's own
  work is timed. Ten runs per entry point.
- **Instrumentation.** Kept outside the repository and never applied to the
  timed runs. A 30-line C shim on `PATH` logs each execution of 53 common
  binaries before `execv` (microseconds per call). A `BASH_ENV` file enables
  `xtrace` to a separate descriptor so stdout, stderr and exit codes are
  unchanged. Both runs reproduced their uninstrumented results, except where
  noted.

Scripts and summarized raw evidence (series logs, samples, JUnit reports,
execution counts) are kept outside Git under `.agent/perf-baseline-v1.0.1/`.

## Results: full verify

| Scenario | Run 1 | Run 2 | Run 3 | Min | Median | Max | Mean | Result |
|---|---|---|---|---|---|---|---|---|
| A idle | 728.0 s | 658.7 s | 611.6 s | 611.6 s | **658.7 s** | 728.0 s | 666.1 s (sd 58.5) | 3 × `4 passed, 0 warning, 0 blocking` |
| B contention | 900.9 s | 900.7 s | 901.4 s | 900.7 s | **900.9 s** | 901.4 s | 901.0 s | 3 × `VERIFY_TOTAL_TIMEOUT` in `check:test` |

- **Idle CPU.** Median user 1813 s and system 1466 s, about 5 CPU-seconds per
  wall second. System time is almost as large as user time: the work is
  process creation, not computation.
- **Idle processes.** About 1.40 million process creations per verify,
  identical across runs (1,405,180; 1,402,293; 1,401,551).
- **Idle variance.** Each run was faster than the one before. The visible
  signals do not explain it: load averaged 5.0, 5.1 and 4.9; available memory
  never fell below 1.8 GiB; swap did not grow. Thermal or power state of the
  laptop CPU and Windows host activity, invisible from WSL2, are the likely
  causes. They are not confirmed, so the spread is part of the baseline.
- **Contention.** All three runs hit the 900-second total budget during the
  test check, after lint and smoke had passed. CPU times for these runs are not
  meaningful, because `time` does not count killed children. Load averaged
  14–15, and free swap fell from 1066 MB to 866 MB over the three runs.
- **Uncapped contention estimate.** Lint 161.7 s, smoke 5.7 s, independent
  1.8 s, `bats --count` 7.9 s and the suite 1120.3 s sum to about **1299 s**
  under contention, against 609 s idle (×2.1).
- **Invalid run.** A first uncapped suite run under contention was discarded:
  the host suspended for 88,093 s during it, a single gap in the 5-second
  samples, which inflated its wall time to 89,144 s. The rerun showed no gap
  above 6 s, as did every other run.

## Breakdown by check (idle and contention)

| Check | Idle wall | Idle user / sys | Contention wall | Factor | Share of idle verify |
|---|---|---|---|---|---|
| test: `bats --jobs 6 tests/` | 512.1 s | 1662.6 / 1297.5 s | 1120.3 s | ×2.19 | 84.1 % |
| lint: `shellcheck -x …` (one process) | 86.5 s | 81.8 / 4.8 s | 161.7 s | ×1.87 | 14.2 % |
| test runner preamble: `bats --count tests/` | 4.6 s | 3.9 / 0.7 s | 7.9 s | ×1.74 | 0.8 % |
| smoke: `bash tests/smoke.sh` | 3.2 s | 2.2 / 1.3 s | 5.7 s | ×1.78 | 0.5 % |
| independent: GitHub attestation (network) | 1.6 s | 0.2 / 0.1 s | 1.8 s | ×1.14 | 0.3 % |
| CAC framework (state, Risk, contract, rendering) | ≈1.1 s (framework repo) | — | — | — | 0.2 % |
| **Sum** | **609.1 s** | | **≈1299 s** | ×2.1 | matches idle run 3 (611.6 s) |

Checks run sequentially. Lint's user time almost doubles under contention, so
the slowdown is shared cores (SMT siblings) and clock, not only run-queue
waiting. The GitHub-hosted CI runner, a different host, ran the same suite
(bats job) in 13 min 59 s and shellcheck in 1 min 49 s for run 41922202095.

### Suite by file

Summed test time is 2633 s idle and 6104 s under contention (×2.32). Every file
group slowed by the same factor. No test was skipped or failed in either run.

| Rank | File | Tests | Summed time | Share | Per test |
|---|---|---|---|---|---|
| 1 | `authority-receipt-validation.bats` | 71 | 562.0 s | 21.3 % | 7.92 s |
| 2 | `authority-receipts.bats` | 50 | 316.8 s | 12.0 % | 6.34 s |
| 3 | `authority-state-machine.bats` | 47 | 283.1 s | 10.8 % | 6.02 s |
| 4 | `authority-execution.bats` | 53 | 215.0 s | 8.2 % | 4.06 s |
| 5 | `authority-preparation.bats` | 13 | 109.1 s | 4.1 % | 8.40 s |
| 6 | `authority-evaluation.bats` | 15 | 87.4 s | 3.3 % | 5.82 s |
| 7 | `install-idempotence.bats` | 22 | 68.7 s | 2.6 % | 3.12 s |
| 8 | `hook-root.bats` | 19 | 67.2 s | 2.6 % | 3.54 s |
| 9 | `receipt-manifest-golden.bats` | 21 | 66.9 s | 2.5 % | 3.19 s |
| 10 | `authority-identity-binding.bats` | 12 | 66.6 s | 2.5 % | 5.55 s |

- **By group.** `authority-*` files take 71.7 % of summed test time, `install*`
  files 9.1 % and everything else 19.2 %.
- **Per test.** The median test takes 0.97 s, the 90th percentile 6.88 s and
  the slowest 24.2 s (`authority-state-machine.bats` 28 H, an interrupted state
  replacement). The other slowest tests are also authority state-machine,
  receipt and identity-transport tests between 14 and 19 s.
- **One authority test (observed).** Test 9 of `authority-evaluation.bats` is
  of median duration: 6.1 s and about 2975 process creations. It makes 348 `jq`
  calls, 332 `awk` calls (328 of them TOML), 198 `stat` calls (path-trust
  checks) and 87 `mktemp` calls.

## Framework overhead per entry point

Measured in the framework repository with trivial checks: ten runs each, idle.
Process creations are net of a calibration run.

| Entry point | Min | Median | Max | Processes (median) |
|---|---|---|---|---|
| `verify.sh` | 1125 ms | 1144 ms | 1229 ms | 959 |
| `.githooks/pre-commit` | 906 ms | 916 ms | 1039 ms | 742 |
| Claude `stop-verify.sh` (root) | 492 ms | 588 ms | 806 ms | 401 |
| Claude `stop-verify.sh` (subdirectory) | 493 ms | 502 ms | 621 ms | 401 |
| Codex `stop.sh` (subdirectory) | 513 ms | 516 ms | 573 ms | 411 |
| Claude `state-enforcement.sh` (Stop) | 113 ms | 118 ms | 130 ms | 94 |
| Claude `post-edit-verify.sh` | 43 ms | 46 ms | 66 ms | 55 |
| Codex `pre-tool-use.sh` | 25 ms | 26 ms | 27 ms | 20 |
| Claude `block-destructive.sh` | 22 ms | 23 ms | 24 ms | 17 |
| Claude `sensory-reminder.sh` / `tdd-check.sh` | 19–24 ms | 21–26 ms | 27–85 ms | 9–13 |
| `doctor.sh` | 844 ms | 874 ms | 957 ms | 714 |

- **Doctor exit 1.** In this repository it reported
  `VERIFY_HOST_TIMEOUT_INCOMPATIBLE`, because its total budget was raised after
  installing without rerunning the installer. The report was correct and the
  timing is still valid.
- **Local authority (production, observed).** `receipt-verify.sh` on
  affiliate-status-bot (347 tracked files) takes 3.0–3.8 s and about 1760
  process creations per call, over five read-only runs. That is the extra
  identity cost of a receipt-first Stop: the rollout measured Stop at 3.5 s
  there.

## Subprocesses

| Scope | Processes created | External executions by binary (observed) |
|---|---|---|
| Full verify (idle) | ≈1.40 M | see suite row |
| Suite under the shim (966 of 1113 tests passed, see note) | 1.28 M | 653,349 shimmed: `awk` 167,064 (25.6 %), `jq` 133,702 (20.5 %), `stat` 43,380, `dirname` 41,477, `mktemp` 38,798, `grep` 32,783, `git` 28,296, `cat` 23,267, `rm` 23,262, `chmod` 17,659, `sha256sum` 15,089, `sleep` 10,052, `flock` 2,157, `tr` 3,333, `timeout` 868, `sed` 193, `sudo` 169, `python3` 11, `parallel` 1 |
| One `verify.sh` (framework) | 959 | 393 shimmed: `jq` 207, `awk` 117, `grep` 18, `git` 15, `mktemp` 10, `timeout` 3; the other ≈566 are bash subshells and pipelines |
| One pre-commit (framework) | 761 | 333: `awk` 127, `jq` 120, `git` 32, `grep` 21 |
| One Claude Stop (framework) | 407 | 190: `awk` 98, `jq` 45, `grep` 18, `git` 11 |
| One `receipt-verify.sh` (affiliate) | ≈1760 | traced: `awk` 404, `jq` 198, `grep` 74, `mktemp` 59, `git` 46, `sha256sum` 17 |

**Shim run caveat.** The local issuer refuses tools that a directory earlier on
`PATH` shadows; that is a deliberate trust check. Under the shim, 147 tests in
eight `authority-*` files failed early, so the suite row undercounts the
authority path. The per-test trace above covers that path instead.

The 10,052 `sleep` calls are short polling waits (0.02–0.1 s) in the
authority tests and helpers. About 1.4 million process creations at
1.4–2.2 ms each (estimated) make up most of the suite's 2960 CPU-seconds.

## TOML and configuration parsing

Each `read_toml`, `read_toml_array` and `toml_key_present` call parses the
whole document again with `toml_document`, one `awk` process, and then
extracts the key with a second `awk`. The authority's vendored copy
(`authority_pa_*` in `phase-a-source.sh`) does the same.

| Entry point | `toml_document` parses (observed) | Distinct documents | Extraction calls | Other config reads |
|---|---|---|---|---|
| `verify.sh` | 54 (27 of the HEAD snapshot, 27 of the worktree snapshot) | 2 (`agent-md.toml` at HEAD and in the worktree; each of the 12 verify keys looked up twice) | 50 | `git show HEAD:agent-md.toml` ×3, `cat-file -e` ×3, `.project-control.toml` once per snapshot, `memory/progress.md` ×2 |
| Claude Stop | 48 (24 + 24) | 2 | 46 | `agent-md.toml` ×2 per snapshot, `.project-control.toml` once per snapshot |
| `receipt-verify.sh` | 200 | small and fixed (same file, snapshots) | 192 | — |
| One authority test (`evaluate`) | 168 | small and fixed | 160 | — |

- **Minimum.** Two parses per evaluation would suffice, one per snapshot.
- **Estimated share of time.** About 300 ms of the 1.14 s framework `verify.sh`
  (≈26 %), about 230 ms of the 0.5 s Stop (≈45 %), about 1.1 s of the 3.2 s
  `receipt-verify.sh` (≈35 %), and 15–18 % of a median authority test.
- **Suite (estimated).** Extrapolating from that test and from the `awk` share
  of the rest, repeated TOML parsing accounts for roughly 10–15 % of suite CPU.

## Identity and contract resolution

| Item | Per ordinary verify / Stop (observed) | With local authority (observed) | Recomputation |
|---|---|---|---|
| Project root (`project_root` / `rev-parse --show-toplevel`) | 1 | 1–2 | none |
| Contract resolution (`verification_contract_json`, merged by `effective_verification_contract_json`) | 2 snapshots, 1 merge | same inside the vendored copy | each key reparses the TOML (above) |
| Control (`project_control_json_from_content`) | 2 (HEAD, worktree) | 6 | minor |
| Risk (`run_risk_contract`, `risk_rank` ×6) | 1 | — | minor |
| Mechanism, contract, control and source fingerprints | not computed on the ordinary path | `receipt-verify.sh`: 17 `sha256sum`, 1508 structural-exclusion checks (in-process bash, no fork), 6 receipt manifest entries | no repeated hashing seen; cost is the per-path walk |
| Receipt validation | not used by `verify.sh` or pre-commit (by design) | ≈3.2 s per receipt-first Stop | one validation per Stop |

Identity has no cost in projects without local authority. Where an authority
exists, it is the largest per-Stop cost, and TOML reparsing inside it is the
largest repeated part.

## Filesystem and Git

- **Most read file.** `agent-md.toml`: two `git show` snapshots copied to
  temporary files, then each copy read 24–27 times by `awk`. Second are the
  per-path stats of authority trust checks (198 `stat` in one authority test).
- **Git queries.** 15 per framework verify and 11 per Stop. The only repeats
  are `show` and `cat-file -e` of `HEAD:agent-md.toml` (×3 and ×2), about
  30 ms in total. Git is not a hotspot.
- **Hashing.** It happens only on the authority path and is not repeated
  within one call.
- **Temporary files.** 10 `mktemp` per verify; 38,798 in the suite.

## Parallelism

- **Suite.** `tests/run.sh` runs `bats --jobs 6` through GNU parallel. Idle,
  6 jobs keep about 5.8 cores busy (2960 CPU-s over 512 s). Load averages 5,
  below the 12 hardware threads, so there is no oversubscription. Against the
  summed test time of 2633 s, the parallel speed-up is about ×5.1.
- **Checks.** They run sequentially inside one evaluation. Lint (single
  process, 86.5 s) does not overlap the suite, so a single core does that work
  while the others wait.
- **Contention.** Six jobs plus seven busy cores is 13 runnable tasks on 12
  threads: oversubscribed. Every file group slowed by the same ×2.3, and
  single-threaded lint user time rose ×1.9, so jobs share physical cores
  (SMT) and clock rather than waiting on I/O.
- **History.** The comment in `tests/run.sh` records 322–333 s at six jobs and
  360 s at four. The suite now takes 512 s at six. The comment's figure
  predates the current suite size.
- **No other values measured.** `BATS_JOBS` was not changed in this baseline.

## Timeout headroom

| Measure | Observed | Budget | Headroom |
|---|---|---|---|
| Verify, idle median | 658.7 s | 900 s total | 241 s (26.8 %) |
| Verify, idle best / worst | 611.6 / 728.0 s | 900 s | 288 s (32.0 %) / 172 s (19.1 %) |
| Test check, idle (`--count` + suite) | 516.7 s | 750 s per check | 233 s (31.1 %) |
| Test check, idle worst run (estimated: verify − lint − smoke − independent − framework) | ≈636 s | 750 s | ≈114 s (15 %) |
| Verify, contention | ≥ 900 s (3 × `VERIFY_TOTAL_TIMEOUT`); uncapped estimate ≈1299 s | 900 s | −399 s (−44 %) |
| Test check, contention | 1128 s | 750 s | −378 s (−50 %) |
| Host Stop envelopes | Claude 930 s, Codex 950 s | 900 s core | 30 s / 50 s transport reserve |

The checkpoint verify of the commit that added this document (`e090d48`, an
ordinary idle session, not part of the series) took 738 s, inside the
observed spread but within 27 s of the 765-second revisit threshold below.

**Ceiling.** The current suite and policy fit the budget only when this
repository's verify runs alone on an otherwise idle host of this class (6 cores
/ 12 threads). They do not fit under roughly two-fold CPU contention: another
suite, a consumer verify, or a comparable load. This matches the observed
`VERIFY_TOTAL_TIMEOUT` when a CAC verify overlapped a consumer verify (GB-4).

**Revisit when** any of these happens on the reference host:
- the idle verify median exceeds 765 s (85 % of the total budget);
- the idle test check exceeds 640 s (85 % of the per-check budget);
- any `VERIFY_TOTAL_TIMEOUT` occurs on an idle machine;
- a consumer reports a Stop overhead above 1 s without local authority, or a
  receipt-first Stop above 5 s.

## Optimization hypotheses

None of these is implemented. Each must win an A/B on the workloads in this
document, reporting gain, regressions and added complexity.

| # | Hypothesis | Evidence | Expected gain (estimated) | Complexity | Risk | Future A/B |
|---|---|---|---|---|---|---|
| 1 | Parse each TOML snapshot once per evaluation and answer every lookup from that one parse, using the same parser in the core and the vendored authority copy | 54 / 48 / 200 / 168 parses where 2 suffice; 99 % of an authority test's `awk` is TOML | Stop −35–45 % (≈200 ms), framework verify ≈−25 %, `receipt-verify` ≈−30 % (≈1 s), suite ≈−10–15 % | low–medium: the parser and its strictness stay; only reuse changes | stale result across snapshots or files if keyed wrongly; the vendored authority copy is mechanism, so affiliate-style projects need reapproval | framework entry-point bench (10 runs each), `receipt-verify` ×5, idle verify ×3; parse counts from `xtrace` |
| 2 | Run `shellcheck` per file in parallel, or overlap lint with the suite | lint 86.5 s in one process, 14 % of idle verify | ≈−60 s idle verify | low | `agent-md.toml` lint command is policy; overlap competes with bats for cores | lint ×3 and idle verify ×3 |
| 3 | Fewer `jq` calls in human-readable rendering | 207 `jq` per verify; about 106 in `verification_result_human`, `default_policy_human_message` and `verify.sh` rendering | ≈200 ms per verify, less per Stop (45 `jq`) | medium | message text and structured codes are pinned by tests and are a host-facing contract | framework bench and full suite |
| 4 | Cheaper authority test fixtures (shared enrollment per file) | `authority-*` = 71.7 % of test time, 6.1 s and ≈2975 processes per median test | largest possible (up to a third of the suite) | high | test isolation and coverage could weaken, which the policy forbids | per-file times ×3 plus coverage review |
| 5 | Fewer process creations generally | ≈1.4 M per verify; system ≈ user time; 1.4–2.2 ms per exec on WSL2 | spread across the above | varies | broad refactor; mixes objectives | measure as part of 1–4 |

## Simplicity review

- **Root cause.** Process creation is the dominant cost: about 1.4 million per
  verify on a host where one costs 1.4–2.2 ms. The largest share is the
  authority tests, 71.7 % of suite time.
- **Repeated work.** The clearest pure repetition is TOML reparsing: the same
  document is parsed 24–100 times per evaluation, on every entry point
  including the most frequent (Stop) and the authority receipt path.
- **Simplicity ladder.**
  - *No change* is acceptable while the ceiling holds.
  - *Existing code, small adaptation*: reuse one parse of each snapshot with
    the existing `toml_document` output (hypothesis 1).
  - A new parser, a Python or compiled helper, a daemon, or a persistent
    cache would be a new mechanism and is not justified by this data.
- **Overengineering risk.** A cross-process or on-disk cache with
  invalidation, a rewrite of JSON assembly in another language, or
  re-architecting the suite before measuring hypothesis 1. Each adds state or
  a parallel mechanism for gains this baseline does not show to be needed.
- **Benchmark before optimizing.** Any candidate is compared against this
  baseline on this host, with the same three idle full runs, the framework
  entry-point bench and the per-file suite report. The comparison reports
  gain, regressions and added complexity.
