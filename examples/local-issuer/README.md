# Local verification authority (slices C1-C4d)

This directory holds the optional component that decides which projects may
ever receive an authenticated verification receipt. It is not required to use
coding-agent-control: with no authority installed, verification behaves exactly
as it does today and completion runs the full contract.

| File | Role |
|---|---|
| `agent-md-authority` | administrator CLI: install, key custody, enroll, run preparation |
| `agent-md-issuer` | runtime: answers eligibility for a request |
| `run-check` | executes one approved check inside a sealed run |
| `authority-lib.sh` | shared implementation all three programs source |
| `phase-a-source.sh` | vendored Phase A identity functions, used unmodified |
| `receipt-verify.sh` | unprivileged validation of a published receipt |

The authority can issue an authenticated receipt and validate one. What it
still does not do is *reuse* one: no hook and no verification entry point
consults the validator, so ordinary completion continues to run the full
contract exactly as it does today.

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

### The issuer key

`install` creates the key *directory* and nothing inside it. Creating the key
is a separate command:

```bash
sudo ./examples/local-issuer/agent-md-authority install-key
```

This is deliberate. Reinstalling the programs is routine and an operator may do
it on every upgrade; introducing the key that will authenticate every future
receipt is not, and must never happen as a side effect. Running `install-key`
again reports the existing key and generates nothing.

| Path | Owner | Mode | Contents |
|---|---|---|---|
| `issuer-<key_id>.key` | agentmd | 0600 | Ed25519 private key, PKCS#8 PEM |
| `issuer-<key_id>.pub` | agentmd | 0644 | public key derived from it, SPKI PEM |
| `current` | agentmd | 0644 | one line: the active `key_id` |

`key_id` is the full SHA-256 of the DER SPKI encoding of the public key, which
any validator can recompute from the public key alone. The full digest is used
rather than a truncation: a short identifier selects which key validates a
receipt, which makes it worth a collision search, and 64 characters cost
nothing.

`current` holds an identifier, never key material and never a symlink to a key
file. A mutable `current.pem` would make the active key a property of a path
somebody could relink; an identifier makes it a property of the key's own
content.

Publication is the rename of `current`. A key whose files exist but which no
`current` names is not active, so a crash during creation can leave an
unreferenced key but never a half-published one. The private key is written by
`openssl` through its own `-out`: it is never an argument, never an environment
value and never printed, so it cannot appear in a process listing or in
captured output.

`show-key` reports the active `key_id` and the public key path. `rotate-key`
exists as an interface and refuses: rotation only becomes meaningful once a
validator can be told which keys are acceptable and since when, and nothing
rotates on a schedule, on a threshold, or as a side effect of another command.

The sudoers rules a project needs are generated per enrollment by
`agent-md-authority sudoers PROJECT_ID`, and are reviewed against the code that
uses them under [Sudo rule](#sudo-rule). Installing the programs installs no
rule by itself.

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

## Validating a receipt

Validation is deliberately the unprivileged half. It runs as the ordinary
developer, uses no `sudo`, never calls the issuer, never touches the private
key directory and writes nothing:

```bash
./examples/local-issuer/receipt-verify.sh /path/to/repo worktree
```

It takes a workspace and a scope, and nothing else. There is no `--receipt`,
`--sequence`, `--key` or `--project-id`: a caller that could name those could
choose its own verdict. The receipt, its sequence, the project, the signing key
and the expected fingerprints are all derived from the authority's own records.

It prints exactly one JSON object on stdout and human diagnostics on stderr, so
a future caller routes on structure rather than on prose. Exit 0 means
`reusable_pass` and nothing else does:

| status | exit | meaning |
|---|---|---|
| `reusable_ordinary` | 0 | the ordinary verification passed for this state and may be reused |
| `current_fail` | 3 | the ordinary verification failed for this state, authenticated and current |
| `stale` | 4 | authentic, but the workspace has moved since |
| `unresolved_pending` | 5 | an attempt is outstanding; nothing older is current |
| `unauthenticated_terminal` | 6 | the current result predates receipts |
| `invalid_receipt` | 7 | present but not trustworthy |
| `no_evidence` | 8 | nothing has been issued for this workspace |
| `unavailable` | 9 | the authority or its store cannot be read safely |
| `insufficient_coverage` | 10 | the receipt does not cover what is required now |

Three properties are reported separately because they fail for different
reasons: `authentic` (the signature verifies under the project's trusted key),
`current` (the authority's state names this exact receipt) and `applicable`
(the live workspace still matches what was signed). A receipt can be authentic
without being current, and current without being applicable; only all three
make it reusable.

### What a consumer does with each status

This is fixed policy for the step that wires reuse into completion, recorded
now so that step implements a decision rather than inventing one.

| status | consumer action | why |
|---|---|---|
| `reusable_ordinary` | **reuse** — skip the ordinary checks, then satisfy `requires_external` | authentic, current, applicable and complete |
| `current_fail` | **reuse the failure** — do not re-run the ordinary checks | the same conditions hold; the answer is simply a failure |
| `stale` | fall back | authentic, no longer about this tree |
| `insufficient_coverage` | fall back | does not cover what is required now |
| `unresolved_pending` | fall back | an attempt is outstanding; nothing older is current |
| `unauthenticated_terminal` | fall back | predates receipts |
| `no_evidence` | fall back | nothing was ever issued |
| `invalid_receipt` | **warn**, then fall back | evidence exists and does not hold up |
| `unavailable` | **warn**, then fall back | the authority or its store cannot be read safely |

Exit 0 is reserved for `reusable_ordinary` alone. An authenticated failure is
reusable evidence and keeps its own code, because a caller that routes on the
exit status by itself must never read a failure as a success. Both are reusable;
only one is a pass.

Two of those carry a warning rather than silence, and the distinction is
deliberate: an absent receipt and a tampered one are not the same event. A
missing receipt is the ordinary case on any machine without an authority. A
receipt whose signature fails, whose trusted key is writable, or whose state is
corrupt means something that should not happen has happened, and falling back
without saying so would hide exactly what the signature exists to reveal.

None of them blocks. Blocking on a bad receipt would trade a stronger guarantee
for no guarantee: full verification does not depend on the authority at all, is
always available, and is strictly stronger than reusing a receipt. It would
also hand anyone who can corrupt a file a way to stop the developer working,
which is a denial of service dressed up as a security control. The warning
preserves the signal; the fallback preserves the guarantee.

### What reuse never covers

`reusable_ordinary` means the ordinary checks need not run again. It never
speaks for independent verification, for human approval, or for completion as a
whole.

Where the current Risk level requires an external guarantee, that does not
invalidate the ordinary half: the checks still do not need re-running. The
requirement is reported in `requires_external` and the caller satisfies it
itself. This is why the status is named after what it actually licenses, and
why exit 0 must never be read as "completion passed".

A change to Risk, to a downgrade, or to any policy requirement changes the
control fingerprint, which makes an existing receipt `stale` before coverage is
even considered. A receipt therefore cannot outlive the Risk level it was
issued under.

### Reusing a failure

An authenticated failure is evidence in exactly the way a pass is. When the
signature verifies, the state names it as current, the live identity still
matches and the coverage is structurally sound for the current contract, the
result means "the ordinary verification failed for this exact state", and
re-running it would only rediscover the same failure.

Coverage is judged slightly differently for a failure: every currently required
check must still appear, completed, against the same command identity, but the
exit codes may be non-zero. That is what separates a real failure of this
contract from a stale or partial run, which stays `stale` or
`insufficient_coverage` instead.

### How a consumer obtains evidence

This is the contract for the step that wires reuse into completion. It creates
no new capability: issuing evidence remains something only an authority-side
evaluation can do.

1. Run the validator.
2. `reusable_ordinary` — skip the ordinary verification and evaluate only what
   `requires_external` names.
3. `current_fail` — reuse the failure; do not re-run the ordinary checks.
4. `stale`, `no_evidence`, `insufficient_coverage`, `unauthenticated_terminal` —
   if a local issuer is installed and this workspace is enrolled, run the
   existing privileged evaluation (`sudo -n … agent-md-issuer evaluate`). That
   evaluation *is* the fresh verification, and it issues the next receipt.
   Otherwise run the ordinary full verification.
5. `unresolved_pending` — attempt the same issuer evaluation, which is also how
   an abandoned reservation is recovered. If one is already running, or the
   issuer is unavailable, fall back. Never reuse the terminal result underneath
   a pending one.
6. `invalid_receipt`, `unavailable` — warn where a human will see it, then run
   the full verification. Corruption is never quietly treated as absence.

There is deliberately no `--issue-receipt`, `--refresh-receipt` or `--sign-run`.
Evidence is produced by running the checks under the authority and nowhere
else; a command that manufactured a receipt on request would be the signing
oracle this design exists to avoid.

Freshness comes from the state file, never from the filesystem. The newest file
name, the highest sequence on disk and the most recent mtime decide nothing: an
orphan receipt left by a crash is inert, and a pending reservation suppresses
every older result underneath it.

The validator reads the workspace through the vendored Phase A functions rather
than the repository's own hooks. Deciding whether to trust a receipt by running
code out of the repository that receipt describes would let the repository
choose its verdict, and would run that code before any check could object.

## What these slices deliberately do not do

No change to `verify.sh`, the Stop hook, the Codex wrapper or the pre-commit
hook. Nothing in the product consults the validator, so a receipt currently
changes nothing about how completion behaves; wiring that up is a separate
step, deliberately taken after issuance and validation can each be reviewed on
their own.

An exit status of 0 from `run-check` still means the command exited 0 and
nothing more. `run-check` does not read the key, the state or any receipt, and
the test suite asserts that rather than trusting the comments that say so.

## Evaluating a project

```text
developer
  | sudo, one subcommand
authority (agentmd)
  | caller binding, eligibility, revalidation, run preparation
  | sudo, literal project id and check name
runner (agentmd-runner)
  | one approved check inside the sealed snapshot
```

The developer asks for an evaluation and says nothing about what should run:

```bash
printf '{"protocol":1,"scope":"worktree","workspace":"/abs/path"}' \
  | sudo -u agentmd /usr/local/lib/agent-md/agent-md-issuer evaluate
```

### Caller identity

The caller is never taken from the request. It comes from the boundary that was
actually crossed: sudo resets the environment and then sets `SUDO_UID` and
`SUDO_USER` itself, so a caller cannot supply them, and reaching `evaluate` at
all requires already running as the authority account. A direct invocation with
forged variables is refused because the process is not the authority.

The caller must then match the developer recorded in the enrollment. Nothing in
the repository — `agent-md.toml`, `.git`, hooks, HEAD — can turn one developer
into another, because the enrolled developer is authority-side state.

### Runs

Each evaluation materialises its own run:

```text
/var/lib/agent-md/projects/<id>/runs/<run-id>/
    snapshot/src        sealed, shared by every check of this evaluation
    snapshot/manifest.json
    jobs/<check>.json
/var/lib/agent-md/projects/<id>/current-run
```

The run identifier is generated by the authority and never accepted from a
caller, so no request can name a run or reach outside one. The pointer is
published only once a run is complete, and older runs are released only after
it moves, so a check can never lose the tree it is executing in. Preparation is
serialized per project with `flock`: a second evaluation is refused rather than
racing.

Every check of one evaluation reads the same sealed snapshot and the same
approved environment. Nothing is recaptured between checks.

### Order and coverage

Checks run in the core's canonical order — typecheck, lint, test, integration,
smoke, runtime — filtered to what the approved contract configures. Every
applicable check runs while the budget allows, as the core does, so a failing
check does not hide the diagnosis of the ones after it.

The core's completion path merges a Git baseline with a worktree proposal, and
that merge reorders the result; the authority has one approved contract and no
merge, so it follows the canonical order rather than reproducing a merge
artefact. Order affects diagnostics only.

`independent` and `approval` are never executed here. They answer separate
authorities and are recorded in the enrollment as excluded.

### What the result is, and is not

```text
candidate_pass   every required check returned zero for this snapshot
candidate_fail   a required check did not
refused / error  the authority would not or could not proceed
```

An optional check that fails is reported without blocking, which is the core's
semantics. Any non-zero required check, any check that could not run, and an
exhausted budget all make a candidate pass impossible.

This is structured output of the orchestration, not evidence. It carries no
signature, no sequence number and no receipt, and its vocabulary deliberately
avoids `authentic`, `attested`, `verified` and `receipt`. Until a later slice
adds signing, the authority can run a verification and observe it, and can do
nothing reusable with the result.

### Budget

Per-check and total timeouts come from the approved contract; a caller supplies
neither. A contract that declares no total gets the core's legacy derivation
rather than running unbounded. When the budget is exhausted the remaining
checks are recorded as not run and the evaluation is refused.

## Integration evidence

The unit suite runs every role as one user, which cannot show that a developer
is unable to reach the execution account, the authority state or the key. That
evidence comes from a disposable container with three real principals:

```bash
bash tests/integration/local-issuer-boundary.bash
```

It creates `dev`, `dev2`, `agentmd` and `agentmd-runner` with distinct uids,
installs the production layout, validates the generated policy with `visudo`,
exercises the whole chain from developer request to runner execution, runs the
boundary matrix and destroys everything on exit. It changes nothing on the
host, and it is deliberately not part of `tests/run.sh`: it needs Docker and
has its own runtime.

A row only counts when the operation actually ran; a step that could not be
exercised is reported as such rather than as a pass.
