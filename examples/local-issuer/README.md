# Local verification authority (slices C1-C2)

This directory holds the optional component that decides which projects may
ever receive an authenticated verification receipt. It is not required to use
coding-agent-control: with no authority installed, verification behaves exactly
as it does today and completion runs the full contract.

| File | Role |
|---|---|
| `agent-md-authority` | administrator CLI: `install`, `enroll`, `show` |
| `agent-md-issuer` | runtime: answers eligibility for a request |
| `run-check` | executes one approved command as the enrolled developer |
| `authority-lib.sh` | shared implementation all three programs source |

Executing checks, signing, sequence allocation and receipt persistence are
later slices and are deliberately absent. Nothing here can produce a PASS.

## Why the authority lives outside the repository

The executing agent and the repository are inside the same untrusted boundary.
Anything the agent can write, it can write in its own favour. So the record of
what may be verified, which commands may run, and in which environment, is kept
where the agent cannot reach it:

```text
repository config may REQUEST capability
repository config cannot GRANT capability to itself
```

## Installation

Real installation is a deliberate, privileged, human step. It is never
performed by `install.sh`, and never by an agent:

```bash
sudo ./examples/local-issuer/agent-md-authority install
```

Inspect it first with `--dry-run`. Use `--root PREFIX` to build a staging tree
under an alternate prefix; that mode creates no service account and is what the
test suite uses.

The layout it produces:

| Path | Owner | Mode |
|---|---|---|
| `/usr/local/lib/agent-md/` | root | 0755 |
| `/usr/local/lib/agent-md/agent-md-authority` | root | 0755 |
| `/var/lib/agent-md/` | root | 0755 |
| `/var/lib/agent-md/projects/` | agentmd | 0755 |
| `/var/lib/agent-md/keys/` | agentmd | 0700 |

Enrollment records are world-readable on purpose: a later slice validates
receipts with the enrolled public key without needing any privileged call. That
is also why an enrollment record must never contain secret material.

No sudoers rule is installed yet. C1 has no runtime privilege boundary to
cross — `enroll` is run by an administrator and `show` is read-only. The
`dev -> agentmd` and `agentmd -> dev` rules arrive with the issuer in C3, where
they can be reviewed against the code that actually uses them.

## Enrolling a project

```bash
sudo ./examples/local-issuer/agent-md-authority enroll /path/to/repo
```

It prints exactly what is being approved — the commands, the mechanism digests,
the execution environment and the PATH verdict — and writes nothing until a
human confirms. `--yes` accepts non-interactively; it is a command-line flag on
purpose, so no environment variable can silently approve an enrollment.

Review it later with:

```bash
./examples/local-issuer/agent-md-authority show --workspace /path/to/repo
```

## The workspace is hostile input

While enrolling, the authority may run as root against a repository an agent
controls. It therefore never sources, imports or executes anything from the
workspace, and never runs `git` inside it — a `.git/config` can declare hooks,
aliases or `core.fsmonitor` that execute code. "Is this a Git repository?" is
answered by stat-ing `.git`, not by asking git.

The authority reads files as data, hashes them, and parses `agent-md.toml` with
its own reader, installed outside the repository. The repository's own parser
lives in the repository, so it cannot be trusted to describe the repository.

## A developer-writable PATH is disqualifying

If any entry of the approved execution PATH is writable by the execution user —
`~/.local/bin`, an in-repo `.venv/bin`, anything group- or world-writable — the
project is recorded as **ineligible**. This is a refusal, not a warning.

The reason is concrete: the developer could replace a real tool with one that
exits 0, collect an authenticated PASS, and restore the tool afterwards. The
source fingerprint would not notice, because the directory sits outside the
repository.

Projects that depend on developer-writable toolchains keep working normally;
they simply do not get accelerated receipts. Attesting such toolchains is a
later problem and is not approximated here.

## The execution environment is an allowlist

The approved environment is small and explicit. It is not a snapshot of
whatever happened to be exported when someone ran `enroll`:

- `HOME`, derived from the execution user's passwd entry;
- `PATH`, the approved value;
- `LANG` and `LC_*` when present.

Anything else requires `--env NAME=VALUE` and appears in the review output.
Credential-shaped names (`*TOKEN*`, `*SECRET*`, `AWS_*`, `GITHUB_*`, `GH_*`,
`OPENAI_*`, `ANTHROPIC_*`, and similar) are refused outright, as are loader
variables (`LD_PRELOAD`, `LD_LIBRARY_PATH`, `BASH_ENV`, `PYTHONPATH`, …).
`SSH_AUTH_SOCK` and `DOCKER_HOST` are refused too; if they are ever supported
they will be explicit, separately approved capabilities rather than defaults.

## Enrollment schema, version 1

```jsonc
{
  "schema": 1,
  "project_id": "<uuid generated by the authority>",
  "workspace": "/canonical/path",
  "execution": { "user": "dev", "uid": 1000 },
  "approved_contract": { "checks": [...], "required": [...],
                         "timeout_seconds": 360, "total_timeout_seconds": 540 },
  "approved_contract_fingerprint": "<sha256>",
  "approved_mechanism": [ { "path": "...", "algorithm": "sha256", "digest": "..." } ],
  "approved_environment": [ { "name": "PATH", "value": "..." } ],
  "path_eligibility": [ { "entry": "...", "resolved": "...", "status": "...", "reason": "..." } ],
  "status": "eligible" | "ineligible",
  "reasons": [ "..." ],
  "metadata": { "created": "<iso8601>" }
}
```

`project_id` is generated by the authority. It is not derived from the path or
from anything in the repository, so creating a directory with a particular name
inherits nothing. The workspace is a binding, not an identity: moving or cloning
the repository does not carry the enrollment with it.

Timestamps in `metadata` are descriptive. Freshness and ordering come from the
sequence state, never from a clock.

`approved_contract` covers the ordinary checks only. `independent` and
`approval` are separate Risk requirements answered by their own authority, and a
receipt issuer must never run them.

## Blast radius

Compromising the authority account is serious and should be stated accurately:

```text
agentmd compromise
  -> receipt authority compromised
  -> issuer state and signing key compromised
  -> once C3 lands, the descending sudo rule also gives limited
     execution as the developer user
  -> NOT root
```

That is still materially better than a root supervisor, where the same
compromise would yield the whole machine. It is the reason the supervisor is a
dedicated service account rather than root.

## The issuer runtime

`agent-md-issuer` answers exactly one question: does the authority still
recognise this project, and would it be authorised to attempt verification in a
later slice? `eligible` is not a verification result, and the vocabulary avoids
`passed`, `verified` and `success` on purpose.

Request — one JSON object on stdin, and no other field is accepted:

```json
{"protocol": 1, "scope": "worktree", "workspace": "/absolute/path"}
```

A request carrying `command`, `checks`, `fingerprints`, `project_id`, `status`,
`sequence` or anything else is rejected rather than ignored. The caller never
states what should be executed, verified or attested; all of that is derived
from the enrollment.

Response — one JSON object on stdout, diagnostics on stderr:

```json
{
  "protocol": 1,
  "status": "eligible",
  "reason_code": "ELIGIBLE",
  "reason": "...",
  "project_id": "...",
  "workspace": "/canonical/path",
  "scope": "worktree",
  "contract": {"state": "current"},
  "mechanism": {"state": "current"},
  "environment": {"state": "current"}
}
```

Exit codes stay meaningful on their own, and refusal is never `0`:

| Code | Meaning |
|---|---|
| 0 | eligible |
| 2 | malformed request |
| 3 | unsupported protocol |
| 4 | unsupported scope |
| 5 | not enrolled |
| 6 | ambiguous enrollment |
| 7 | contract changed |
| 8 | mechanism changed |
| 9 | environment changed |
| 10 | enrollment corrupt |
| 11 | authority state unsafe |
| 12 | workspace unsupported |
| 13 | enrollment approved as ineligible |
| 20 | internal error |

Every refusal means the same thing downstream: no receipt, and full
verification.

## Revalidation on every request

- **Contract.** The current `agent-md.toml` is read as data, canonicalised with
  the authority's own reader and compared to the approved fingerprint. A
  difference is `REFUSED_CONTRACT_CHANGED`; the old approved contract is never
  executed instead, and the enrollment is never updated automatically.
- **Mechanism.** Files are compared against the authority-side approved
  digests, never against HEAD — HEAD lives inside the repository the executor
  controls. States are `current`, `changed`, `missing` and `unsupported`; only
  `current` continues.
- **Environment.** Every approved PATH entry must still exist, still resolve to
  the same directory, and still be untouchable by the execution user. A PATH
  entry that became writable is `REFUSED_ENV_CHANGED`, never a warning. The
  approved variable names are re-checked against today's forbidden list, so an
  enrollment that predates a rule cannot smuggle it in.

## Git worktree policy

`.git` as a directory is supported. `.git` as a file — a linked worktree — is
refused as unsupported rather than followed; resolving `gitdir:` is a later
decision. A missing `.git` is refused. Git is never invoked inside a workspace,
here or during enrollment.

## Parser strictness and the parity invariant

The authority parses `agent-md.toml` with its own reader, installed outside the
repository, so a privileged program never runs the repository's code. That
creates a risk the two readers disagree, so the invariant is one-directional
and pinned by golden tests:

```text
authority accepts  =>  the core accepts, and both describe the same contract
authority refuses  =>  ineligible, and no receipt is ever possible
```

The authority may be stricter; it may never accept a contract the core reads
differently. It deliberately refuses four constructs the core tolerates:

| Construct | Core | Authority | Why |
|---|---|---|---|
| duplicate `verify.<check>` key | keeps the first | refuses | meaning would depend on reader order |
| `#` inside a command value | truncates at the `#` | refuses | the core silently shortens the command |
| single-quoted command | accepted | refuses | one unambiguous string form |
| absent `verify.policy.required` | legacy inference | refuses | inference cannot be reproduced without guessing |

One further divergence runs in the safe direction: a `required` name with no
configured command leaves the core's contract valid and becomes a
`VERIFY_UNAVAILABLE` failure when the check runs, while the authority refuses
to approve a contract it could not fully execute. The project simply never
accelerates.

## Enrollment schema 2

C2 changed the canonical contract representation, so the record carries
`schema: 2`. A schema-1 enrollment written by C1 is refused with a clear
instruction to re-enroll rather than being silently reinterpreted.

`approved_contract` now records `excluded_conditional` — `independent` and
`approval` commands that are configured but which the issuer must never run,
because they answer separate Risk authority — and `required_declared`.

## Read-only guarantee

The issuer writes nothing. Not the repository, not the enrollment, not the
authority state, not any sequence state. A test hashes the workspace and the
whole authority tree before and after a request and requires them byte-identical.

## The execution boundary

Checks never run in the live worktree, and they never run as the developer.

```text
dev / executor        untrusted: repo, .git, HOME, its own processes
      | request
agentmd               authority: enrollment, state, key, snapshot preparation
      | sudo, fixed RunAs
agentmd-runner        execution only: no key, no state write, no snapshot write
      |
sealed snapshot       read-only source identity the checks observe
```

### Why the live worktree cannot be used

A fingerprint taken before and after a run only samples two instants. The
developer owns the worktree, so they can hold a failing tree X, swap in a
passing tree Y for the duration of the checks, and restore X before the second
sample. `BEFORE(X)` equals `AFTER(X)` while the checks observed Y.

The identity is therefore the snapshot's, not the live tree's. The authority
copies first and hashes the copy, so the manifest describes exactly the bytes
the checks will see. A snapshot captured mid-mutation is internally consistent
but will not match the live worktree when a gate later recomputes it, so
transient substitution becomes a fallback rather than a forgery.

### Snapshot

`agent-md-authority prepare-job <id> --check <name>` materialises it:

1. the worktree path set is enumerated — tracked plus untracked-not-ignored;
2. every path is validated as relative and free of `..`;
3. a symlinked directory component refuses the whole snapshot, because it would
   let the developer redirect the copy at anything the authority can read;
4. symlinks are copied as links and never followed; executable bits are kept;
5. structural exclusions match the Phase A protocol: `.git`, the receipt cache
   and the working-memory files;
6. the tree is sealed — directories `0555`, files `0444` or `0555` — so a later
   write needs a chmod on a directory neither the runner nor the developer owns;
7. the manifest is taken from the sealed copy and fingerprinted.

Enumeration is the one place a repository's own Git configuration is read, so
it crosses into the execution-only account first. A repository that manages to
execute code through `.git/config` reaches the runner, never the authority. A
staging root has no such account and says so rather than hiding the gap.

### What the child gets

```text
env -i
  + the approved allowlist (PATH, LANG/LC_*, declared extras)
  + HOME     = ephemeral, created per run, never the developer's
  + TMPDIR   = scratch outside the snapshot
  + PYTHONNOUSERSITE=1
  + trusted absolute env, timeout and bash
  + cwd      = the sealed snapshot, revalidated after chdir
  + stdin    = /dev/null
  + fd 3     closed
```

A check that needs to write source is incompatible with accelerated receipts
and simply fails; the snapshot is not weakened to accommodate it. Legitimate
build output belongs in `TMPDIR`.

### Sudo rule

```text
Defaults!ALIAS env_reset, secure_path="/usr/local/bin:/usr/bin:/bin"
Cmnd_Alias ALIAS = /usr/local/lib/agent-md/run-check <project-id>,
                   /usr/local/lib/agent-md/agent-md-authority enumerate *
agentmd ALL=(agentmd-runner) NOPASSWD: ALIAS
```

Fixed RunAs, literal project id, no wildcard command, no rule targeting root or
any developer. The rule no longer varies per developer, because checks no
longer run as one.

### Nothing trusted runs after the command starts

`run-check` validates the job, the snapshot, the tools and the environment,
enters the snapshot, and then **execs** the command. It does not call the
command and resume afterwards. After that line no code of ours is left running
under the same uid as the project's own code, so there is nothing to tamper
with and nothing to post-process a verdict.

The status the supervisor observes is whatever the kernel reports back through
sudo. The decision rule for this slice is deliberately blunt:

```text
exit 0       execution returned zero
exit != 0    no candidate PASS
```

A refusal exits `125`, and a check may also legitimately exit `125`. That
collision is accepted here because both are non-zero and both are fail-closed:
neither can become an authenticated PASS. Carrying a separate infrastructure
verdict over an inherited file descriptor was tried and rejected — sudo closes
descriptors above stderr, and re-opening that path with `closefrom_override`
would widen descriptor inheritance exactly at the privileged boundary for a
diagnostics gain, not a trust one. The sudo policy is asserted to contain no
such override.

Check output on stdout and stderr is untrusted data: passed through, never
parsed, unable to change the exit status.

### Timeout

The service account cannot signal a process belonging to another account, so
the deadline is enforced inside the execution by a trusted absolute `timeout`
rather than by widening the supervisor's privilege. It sends SIGTERM and
escalates to SIGKILL after a grace period.

GNU `timeout` reports `124` when the term was enough and `137` when it had to
escalate. Both are non-zero and neither can become a PASS. The core collapses
both to `124` by rewriting the status after the command returns, which is
precisely the post-processing `exec` forbids here; a supervisor running as its
own account can classify them later.

### Toolchain limits

`bash`, `timeout` and `env` are absolute paths recorded at enrollment and
revalidated immediately before execution: not symlinks, executable, and not
writable by the execution user. They are not content-pinned, because every
distribution security update would otherwise invalidate every enrollment;
permissions, not digests, are what stop a substitution.

Transitive influence is bounded where a switch exists and documented where it
does not. An interpreter reached through the approved PATH gets an ephemeral
HOME and, for Python, `PYTHONNOUSERSITE=1`. Where an interpreter offers no such
control, isolation is not proven, and the honest position is refusal rather
than assumed safety.

A project whose verification depends on a developer-writable `.venv`,
`~/.local`, the Docker socket, an SSH agent or other mutable developer-owned
resources is incompatible with accelerated receipts in this version. Full
verification stays available and unchanged.

## What C1-C3a deliberately do not do

No key generation, no signing, no receipt issuance, no sequence allocation, no
`dev -> agentmd` entry hop, and no change to `verify.sh` or the Stop hook. An
exit status of 0 from `run-check` means the command exited 0 and nothing more:
it is not a receipt, not an attestation and not a PASS.

## Integration evidence

The unit suite runs every role as one user, which cannot show that a developer
is unable to reach the execution account, the authority state or the key. That
evidence comes from a disposable container with three real principals:

```bash
bash tests/integration/local-issuer-boundary.bash
```

It creates `dev`, `agentmd` and `agentmd-runner` with distinct uids, installs
the production layout, validates the generated policy with `visudo`, runs the
boundary matrix and destroys everything on exit. It changes nothing on the
host, and it is deliberately not part of `tests/run.sh`: it needs Docker and
has its own runtime.

A row only counts when the operation actually ran; a step that could not be
exercised is reported as such rather than as a pass.
