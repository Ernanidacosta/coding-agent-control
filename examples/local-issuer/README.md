# Local verification authority (slices C1-C2)

This directory holds the optional component that decides which projects may
ever receive an authenticated verification receipt. It is not required to use
coding-agent-control: with no authority installed, verification behaves exactly
as it does today and completion runs the full contract.

| File | Role |
|---|---|
| `agent-md-authority` | administrator CLI: `install`, `enroll`, `show` |
| `agent-md-issuer` | runtime: answers eligibility for a request |
| `authority-lib.sh` | shared implementation both programs source |

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

## What C1 and C2 deliberately do not do

No key generation, no signing, no receipt issuance, no check execution, no
sudo hop, no sequence allocation, and no change to `verify.sh` or the Stop
hook. An enrolled project behaves today exactly as an unenrolled one.
