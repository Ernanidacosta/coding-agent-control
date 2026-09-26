# coding-agent-control

**Developer control for coding agents.**

A repository-local control, verification, and trust layer for coding agents.

[Português (Brasil)](README.pt-BR.md)

Claude Code, Codex, and other coding agents can execute the work while the
developer and project retain authority over what is allowed, what is required,
and what can be accepted as complete. The repository carries its rules,
operational state, verification contract, Risk requirements, and evidence
boundaries across supported agents and model vendors.

`Status: done` is a completion claim, not proof. The claim is accepted only
after the applicable state, verification, Risk, independent-evidence, and
approval requirements pass.

## The Problem

Coding-agent behavior otherwise depends heavily on whichever host, model, or
session is active. Project rules can be forgotten, handoffs lose current state,
and a confident completion message may have no reproducible evidence behind it.
`coding-agent-control` keeps the project contract repo-local and makes observable
guarantees deterministic where the host exposes a blocking integration.

## What It Does

- installs shared project directives and idempotently merged host hooks;
- blocks supported destructive-command, unsafe-path, and secret-boundary cases;
- maintains bounded current operational state for deterministic handoff;
- guides README maintenance as living documentation without semantic gating;
- runs declared verification and treats command exit status as authoritative;
- raises completion requirements according to the task's declared Risk;
- validates authority-separated, exact-SHA evidence for high/critical work;
- remains standalone when optional CI or semantic-memory capabilities are absent.

## What It Does Not Do

It does not control an LLM's internal reasoning, provide a complete sandbox,
replace host permissions, run agents, orchestrate models, replace Git or CI, or
act as a semantic-memory system. Markdown guidance alone is advisory. A control
is described as enforced only when a supported host invokes a deterministic
mechanism that can block the relevant action or transition and that integration
is covered by tests.

## Main Guarantees

- Git remains the factual source of truth.
- Safety and integrity controls fail closed on supported host surfaces.
- Required verification cannot be converted to pass by output wording.
- Risk increases evidence and approval requirements; it does not certify safety.
- Independent evidence and critical approval are accepted only when
  authority-separated from the executor.
- Missing optional capabilities do not break ordinary work.

## Supported Hosts

Claude Code and Codex receive rules plus native repository hooks. Cursor and
Windsurf receive rules and can use the optional pre-commit fallback. Other tools
can read the rules and run the repository helpers, but that alone is advisory.
See the detailed [enforcement matrix](#enforcement-matrix) before relying on a
specific blocking guarantee.

Public coverage terms are precise:

- **Enforced** — a tested deterministic integration can block the action or
  transition on that host.
- **Advisory** — a directive, warning, or review aid cannot prove a block.
- **Unsupported** — no corresponding deterministic host integration exists.
- **Experimental** — an integration exists, but does not yet support a stable
  public enforcement claim.

## Quickstart

```bash
# From inside your project directory
curl -fsSL https://raw.githubusercontent.com/Ernanidacosta/coding-agent-control/main/install.sh | bash
```

This downloads coding-agent-control from its standalone GitHub repository. It
is not the upstream installation URL.

The installer adds support for Claude Code, Codex, Cursor, and Windsurf by default.
No `agent-md.toml`, CI provider, `gh`, attestation verifier, approval system,
or semantic-memory provider is required to start.

## Basic Workflow

Start simple:

1. Install coding-agent-control in the project.
2. Optionally run `./.agent-md/bin/doctor.sh` to inspect wiring.
3. Work normally; local working state in `memory/` remains unversioned by
   default and may be absent.
4. Before claiming completion, explicitly create and review the small
   `.project-control.toml` Risk record.
5. Add deterministic project checks when they are useful. Enable advanced
   guarantees only when the task's Risk requires them.

The baseline includes destructive-command and path/secret protections,
configuration and state validation, evidence-first guidance, idempotent hook
merge, and declared required verification. It works offline and without an
external memory or CI provider when the current task does not require one.

### What Gets Installed

```text
your-project/
  AGENT.md                         # source of truth
  AGENTS.md                        # Codex / Cursor / Windsurf
  CLAUDE.md                        # Claude Code
  .project-control.toml            # create explicitly; not auto-installed
  agent-md.toml.example            # deterministic verification/state config

  .claude/
    settings.json
    hooks/                         # Claude Code enforcement

  .codex/
    hooks.json
    hooks/                         # Codex hook wrappers

  .agents/skills/                  # native Codex skills
    agent-md-verify/
    visual-evidence/

  .cursor/rules/agent-md.mdc       # Cursor project rule
  .windsurf/rules/agent-md.md      # Windsurf workspace rule

  .agent-md/
    bin/
      discover_helpers.sh
      doctor.sh
      playwright-capture.sh
      verify.sh

  memory/                          # local working state (locally excluded)
    agents.md
    plan.md
    progress.md
    verify.md
    gotchas.md

  .githooks/pre-commit             # optional fallback for any agent
  .githooks/commit-msg             # keeps Git authorship human
```

### Compatibility Names

The public project is `coding-agent-control`. Existing interfaces such as
`agent-md.toml`, `.agent-md/`, `memory/`, `$agent-md-verify`, and the installed
Cursor/Windsurf rule filenames retain their legacy names for compatibility.
They are retained compatibility interfaces in the current architecture. No
removal is planned as part of this transition.

## Verification

If the project already exposes test, lint, or type-check conventions,
coding-agent-control can infer a small fallback contract. For explicit guarantees, copy
`agent-md.toml.example` to `agent-md.toml` and declare the real commands. A
missing optional check is diagnostic; a missing or failing required check
blocks only the completion boundary that requires it.

Run the complete current contract with:

```bash
./.agent-md/bin/verify.sh
```

## Operational State

`memory/` records local status, plan, verification criteria, and still-useful
gotchas. It is a volatile handoff, not historical memory or a trust root. Fresh
installs list these files only in the repository-local `.git/info/exclude`, so
using coding agents does not require publishing them. Existing tracked memory
remains supported and is never silently rewritten.

`.project-control.toml` is the minimal agent-neutral control record. It is
created explicitly rather than inferred or installed automatically:

```toml
schema = 1
risk = "medium"
```

Git binds this declaration to project history and makes review visible; it does
not prove human authorship. `agent-md.toml` remains the versioned project policy.
See [Operational State Enforcement](#operational-state-enforcement).

## Advanced Guarantees

Ordinary projects are not incomplete because they lack CI, attestations, or an
approval system. These capabilities activate only when the current policy
requires their guarantee.

### Risk

`low` uses the normal required verification contract. `medium` can additionally
require declared runtime/smoke evidence. `high` requires independent evidence
at completion, and `critical` also requires external human approval. Missing
final evidence does not block `active` or `verifying` work.

### Independent Verification

Independent verification is conditional. GitHub Actions plus `gh` is one
reference provider, not a core dependency. Projects can use another CI,
reviewer, or external harness through the same generic verifier contract.

### Critical Approval

Human approval is separate from independent verification and is required only
for a `critical` completion claim. An agent cannot manufacture or validate its
own approval.

## Optional Semantic Memory

A semantic-memory provider can improve historical and cross-agent recall, but
never supplies operational truth or a completion guarantee. coding-agent-control remains
fully functional without one. ICM is the current reference integration and is
enabled explicitly with `[integrations.icm]`; leaving it undeclared creates no
expectation and no warning.

```toml
[integrations.icm]
enabled = true
```

This compatibility key declares one specific optional provider. It does not
make ICM—or any semantic-memory provider—a core dependency.

## Architecture And Reference

Project knowledge has three explicit authorities:

| Authority | Responsibility |
|---|---|
| coding-agent-control | Governance, safety, verification, active plan, current progress, relevant gotchas, and short handoff |
| Git | Factual truth for code and code history |
| Semantic-memory provider (optional) | Historical/semantic recall, older decisions, resolved errors, and cross-agent knowledge; ICM is one reference provider |

The core never calls a semantic-memory provider from hooks or runtime code.
Declaring ICM only selects that optional integration for recall and lets
`doctor.sh` report its availability. Safety, verification, Risk, trust, and
completion never depend on semantic-memory availability.

Capability policy is deliberately narrow:

> Missing optional capability must not break ordinary work. Missing mandatory
> capability must prevent only the transition or action that requires that
> guarantee. There is no silent fallback.

Agent guidance itself has two layers:

| Layer | Purpose | Reliability |
|---|---|---|
| Rules files | Judgment, planning, style, process | Advisory |
| Hooks/artifacts | Type-checks, tests, lint, state updates, visual evidence | Enforceable where supported |

If something can be forgotten or rationalized away, move it out of prose
and into a checked artifact.

The current architecture and compatibility boundaries are summarized in
[`docs/architecture.md`](docs/architecture.md).

## Policy Foundation

coding-agent-control applies this normative order:

1. Safety
2. Correctness
3. Reliability
4. Maintainability
5. Minimal surface area
6. Speed

Security and reliability invariants override autonomy, speed,
convenience, and token efficiency. Optional integrations cannot weaken
enforcement; failure of a safety or integrity mechanism must be visible.
Git remains factual truth, and coding-agent-control remains standalone and
dependency-light. The design rule is: **enforce facts; advise judgment**.

The shared internal hook result is intentionally small:

```json
{
  "status": "fail",
  "severity": "error",
  "code": "STATE_PROGRESS_STALE",
  "message": "Relevant source files changed without progress update.",
  "suggestion": "Update memory/progress.md.",
  "paths": ["src/example.py"]
}
```

Claude and Codex still receive their existing host-specific JSON
envelopes. The human-facing reason includes `[SEVERITY CODE]`; hosts do
not need to parse the internal result contract. `status` is `pass`,
`warn`, or `fail`; current hooks omit a result entirely on ordinary
success where that is what the host protocol expects.

| Severity | Meaning | Blocks? |
|---|---|---|
| `info` | Informational | Never |
| `warning` | Degraded condition or recommendation | No |
| `error` | Required correctness or integrity guarantee failed | Yes |
| `fatal` | Safety, integrity, or destructive-operation risk | Immediately |

There is no retry-based downgrade from `error` or `fatal`. Safety
violations, invalid enforcement configuration, state-integrity failures,
and failed required verification fail closed. Missing optional
integrations or diagnostics warn without blocking.

Stable codes currently emitted by controls are deliberately limited:

| Code | Category | Typical severity |
|---|---|---|
| `SAFETY_DESTRUCTIVE_COMMAND` | Safety | `fatal` |
| `SAFETY_PATH_VIOLATION` | Safety | `fatal` |
| `CONFIG_INVALID` | Integrity | `error` |
| `CONTROL_INVALID` | Integrity | `error` |
| `CONTROL_BASELINE_REQUIRED` | Integrity or migration | `error` at completion; otherwise `warning` |
| `CONTROL_RISK_DOWNGRADE_PENDING` | Integrity | `error` at completion; otherwise `warning` |
| `CONTROL_LEGACY_STATE` | Migration diagnostic | `warning` |
| `STATE_PROGRESS_INVALID` | Integrity | `error` |
| `STATE_PROGRESS_STALE` | Integrity | `error` |
| `STATE_TRANSITION_INVALID` | Quality | `warning` |
| `STATE_GOTCHA_RULE_MISSING` | Integrity | `error` |
| `STATE_GOTCHA_INVALID` | Integrity | `error` |
| `VERIFY_REQUIRED_FAILED` | Integrity | `error` |
| `VERIFY_OPTIONAL_FAILED` | Quality | `warning` |
| `VERIFY_UNAVAILABLE` | Integrity or Quality | `error` when required; otherwise `warning` |
| `VERIFY_TIMEOUT` | Integrity or Quality | `error` when required; otherwise `warning` |
| `VERIFY_NOT_CONFIGURED` | Diagnostic | `warning` |
| `VERIFY_PASSED` | Diagnostic evidence | `info` |
| `RISK_NOT_DECLARED` | Quality / migration | `warning` |
| `RISK_INVALID` | Integrity | `error` |
| `RISK_POSSIBLY_UNDERRATED` | Quality | `warning` |
| `RISK_RUNTIME_EVIDENCE_REQUIRED` | Integrity or Quality | `error` when applicable evidence fails; otherwise `warning` |
| `RISK_INDEPENDENT_VERIFICATION_REQUIRED` | Integrity | `error` |
| `RISK_HUMAN_APPROVAL_REQUIRED` | Integrity | `error` |
| `RISK_ATTESTATION_UNTRUSTED` | Integrity | `error` |
| `RISK_ATTESTATION_INVALID` | Integrity | `error` |
| `RISK_ATTESTATION_STALE` | Integrity | `error` |
| `RISK_ATTESTATION_UNBOUND` | Integrity | `error` |
| `RISK_ATTESTATION_KIND_MISMATCH` | Integrity | `error` |
| `RISK_ATTESTATION_ORIGIN_INVALID` | Integrity | `error` |
| `QUALITY_OUT_OF_SCOPE_CHANGE` | Quality | `warning` |
| `QUALITY_TDD_COVERAGE_RECOMMENDED` | Quality | `warning` |
| `QUALITY_VISUAL_EVIDENCE_RECOMMENDED` | Quality | `warning` |
| `DIAGNOSTIC_OUTPUT_TRUNCATED` | Diagnostic | `warning` |
| `INTEGRATION_ICM_UNAVAILABLE` | Diagnostic | `warning` |

Architectural non-goals constrain feature creep: coding-agent-control is not
semantic memory, a multi-agent orchestrator, a model router, a background
daemon, a project-management platform, a replacement for Git or CI, or a
general-purpose agent runtime. Basic users do not need to understand the
internal trust model, provider-specific infrastructure is not required for
ordinary work, semantic memory never supplies operational correctness, and the
core must not become a plugin or orchestration runtime.

## Runtime Lessons Applied

The production-agent lessons that fit this repo are applied as contracts,
not as copied API boilerplate:

- **Cost/context discipline** — concise directives, helper discovery, and
  bounded operational `memory/` files instead of giant repeated prompts.
- **Reliability** — structured hook JSON, deterministic checks,
  destructive-command blocks, and explicit unverified-state warnings.
- **Performance** — bounded work slices, selective context loading, safe
  parallel tool use, and truncation warnings.
- **Tool use** — structured tool-result guidance, validation before
  execution, and clear helper boundaries.
- **Output quality** — tests, runtime evidence, visual artifacts, and
  independent/adversarial verification.

API-specific features such as prompt caching, streaming display,
provider retries, idempotency keys, temperature tuning, and batch
processing belong in the application or host runtime. `coding-agent-control` tells
the coding agent to document and verify those choices when the project
uses them; it does not pretend to enforce provider behavior from a rules
file.

## Enforcement Matrix

| Check | Class / severity | Claude Code | Codex | Cursor / Windsurf / Other |
|---|---|---|---|---|
| Bash safety | Safety / `fatal` | Enforced via `.claude/hooks/block-destructive.sh` | Enforced via `.codex/hooks/pre-tool-use.sh` | Unsupported |
| Required verification at finish | Integrity / `error` | Enforced via `stop-verify.sh` | Enforced via `.codex/hooks/stop.sh` | Experimental via optional `.githooks/pre-commit` |
| Optional verification failure | Quality / `warning` | Advisory | Advisory | Advisory via optional pre-commit |
| Risk declaration/signals | Integrity or Quality | Enforced when invalid; signals advisory | Enforced when invalid; signals advisory | Experimental via optional pre-commit |
| High/critical final evidence | Integrity / `error` | Enforced for `done` | Enforced for `done` | Advisory at pre-commit |
| Operational state valid and updated | Integrity / `error` | Enforced via `state-enforcement.sh` | Enforced via `.codex/hooks/stop.sh` | Experimental via optional pre-commit |
| Operational change outside task Scope | Quality / `warning` | Advisory | Advisory | Advisory via optional pre-commit |
| UI visual evidence | Quality / `warning`, or Integrity / `error` when required | Advisory or enforced when configured required | Advisory or enforced when configured required | Advisory |
| New export without nearby test | Quality / `warning` | Advisory | Advisory | Advisory |
| Truncated Bash output | Diagnostic / `warning` | Advisory | Advisory | Unsupported |
| AI authorship metadata in a commit message | Integrity / `error` | Enforced via `.githooks/commit-msg` when activated | Enforced via `.githooks/commit-msg` when activated | Enforced via `.githooks/commit-msg` when activated |
| Planning, context, edit safety | Judgment / advisory | Advisory | Advisory | Advisory |

Codex hooks are repo-local. Use `codex features list` to confirm hook
support in the installed Codex version.

### Commit Authority and Commit Authorship

These are two controls, and neither substitutes for the other.

**Commit execution authority** answers who may run `git commit`. That stays
with the human. An agent may propose a message; proposing is not permission.
Nothing in this project grants an agent the right to commit or push.

**Commit authorship** answers whose name the history carries. An agent may
draft a subject and body, but the commit is the developer's work, and the
message must not say otherwise. `.githooks/commit-msg` enforces this.

`commit-msg` is the boundary because the final message does not exist
reliably any earlier. At `pre-commit` the editor has not run, and `-m`, `-F`,
templates, squashes and amends all arrive differently. By `commit-msg` the
message is a file on disk, exactly as it will be recorded.

The hook blocks a message that credits an agent: a `Co-Authored-By:` naming a
model or agent, an agent session trailer such as `Claude-Session:`, a
`Generated-By:` or `Generated-With:` trailer, or a standalone generation
footer or session link. It names the offending line and exits non-zero. It
never edits the message, and never touches `user.name` or `user.email`.
Removing the line is the human's step.

Detection is deliberately narrow, in two ways. A `Co-Authored-By:` naming a
real person is always allowed, because the rule is about agent attribution
and not about co-authorship. And only trailer-shaped lines and standalone
footers are inspected, never prose, so a commit whose body discusses Claude
Code or Copilot is not attribution and does not block. A `git commit
--verbose` diff below the scissors line is not part of the message either.

### Blocking Enforcement vs Advisory Context

Stop hooks answer a finish attempt in exactly one of two ways, and the two
are not interchangeable.

- **Blocking enforcement** is a `decision: "block"` with a reason. It says a
  guarantee is unsatisfied and names the action that would satisfy it: make
  the required check pass, fix invalid enforcement configuration, update
  operational state, produce the missing evidence. It repeats on every finish
  attempt for as long as the condition holds.
- **Advisory context** is a warning with no decision attached. It reports a
  condition worth reviewing, such as a possibly underrated Risk or a change
  outside the declared Scope, and never prevents finishing.

Claude Code sets `stop_hook_active` to `true` on any finish attempt that
follows one a hook already answered in the same cycle. coding-agent-control reads that
field and lets it separate the two classes, nothing more:

| | first attempt | retry (`stop_hook_active: true`) |
|---|---|---|
| Blocking enforcement | blocks | blocks, unchanged |
| Advisory context | emitted | silent |

The flag is not evidence and never releases a block. A failing required
check, invalid configuration, a stale completion claim, or missing Risk
evidence blocks identically on the first attempt and the twentieth. What the
flag bounds is repetition: an advisory carries no decision the agent can
satisfy, so re-sending it on every retry cannot change the outcome and only
feeds the agent into another turn. Saying it once per finish cycle ends that
loop without a retry counter and without depending on the host's
consecutive-block cap.

Warnings are not hidden. Every advisory still reaches the agent on the first
finish attempt, and a blocking reason always carries the full set of
non-passing results, advisories included.

A malformed, empty, or field-less payload reads as a first attempt. The
fail-safe direction is one extra advisory message, never a suppressed block.
The same contract covers `SubagentStop`, and `hookSpecificOutput` echoes back
whichever stop event was invoked. Codex reuses the shared handlers through
`.codex/hooks/stop.sh`, which forwards the payload verbatim: a host that
sends no `stop_hook_active` reads as a first attempt on every stop, which is
the behavior it had before the contract existed.

## Install Options

```bash
# All supported agents
./install.sh .

# Specific agents
./install.sh --agent=claude .
./install.sh --agent=codex,cursor .

# Git hook fallback
./install.sh --githooks .
./install.sh --no-githooks .

# Claude settings handling
./install.sh --claude-settings=skip .
./install.sh --claude-settings=merge .
./install.sh --claude-settings=replace .

# Codex hook-config handling
./install.sh --codex-hooks=skip .
./install.sh --codex-hooks=merge .
./install.sh --codex-hooks=replace .
```

The installer backs up existing top-level rule files before replacing
them, and leaves a file that already matches untouched, so reinstalling
does not accumulate redundant `*.bak` copies. When the script runs from a
real file it installs from that package directory; piped execution
(`curl | bash`) fetches the official archive rather than treating the
target project as the source, which matters because an already-installed
project also contains `AGENT.md`. Existing `memory/*.md` files are never
overwritten. Existing Claude and Codex hook configs are merged by default. Merge preserves
third-party events and handlers and refreshes only commands owned by
coding-agent-control. The merged result — including the Stop timeout envelope this
project resolves to — is computed in full and compared with what is installed
before anything is touched, so a reinstall that changes nothing writes nothing
and leaves no backup, and a real change costs exactly one. `skip` and `replace`
remain explicit options.

Host wiring in `.claude/settings.json`, `.codex/hooks.json`, the Cursor and
Windsurf `agent-md` rules, and their backups is listed in the
repository-local `.git/info/exclude`. Untracked copies therefore stay out of
the project's source identity; files already tracked remain in that identity.
The installer preserves existing file modes, including private `0600` configs.
Receipt source identity uses repository-local Git rules and the index, but
ignores system and user-global Git configuration. A developer's global ignore
patterns or line-ending settings therefore cannot make a receipt appear stale
when the authority reads the same workspace.

`skip`, `replace` and `--no-overwrite` all answer the same question: what
happens to a host config that **already exists**. On a target that has none
there is nothing for them to protect, so the file is created complete under
every mode, carrying the effective Stop timeout this project resolves to — a
config created half-configured would not serve any of them. When one of those
choices does stop the installer from writing, it says so, and reports any Stop
envelope it could therefore not synchronize:

```text
· .claude/settings.json exists — not touched
  ! claude Stop timeout not synchronized by your policy — installed 999s, this project needs 41s
```

An envelope that already matches stays silent. The installer never edits a file
your flags told it to leave alone, and never lets the run read as though it had
made the host compatible when it did not.

## Deterministic Verification

The completion question is: **what evidence proves this task is complete?**
coding-agent-control resolves one verification contract for Claude Stop, Codex Stop,
pre-commit, doctor, and `agent-md-verify`. Explicit commands take precedence;
heuristics remain a labeled fallback.

Configuration is optional. Copy the example only when the project wants to
make its own checks explicit:

```bash
cp agent-md.toml.example agent-md.toml
```

```toml
[verify]
typecheck = "npx --no-install tsc --noEmit"
lint      = "npx --no-install eslint ."
test      = "pnpm test"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 300
total_timeout_seconds = 420 # example policy; measure and choose per project
```

Runtime, smoke, visual, independent-verification, approval, and semantic-memory
configuration are advanced capabilities. Add them only when the project or
current task requires their guarantee.

Supported base completion checks are `typecheck`, `lint`, `test`,
`integration`, `smoke`, and `runtime`. `independent` and `approval` are
conditional Risk evidence verifiers. `lint_file` remains the fast PostToolUse
check and is not part of the completion contract.

When `[verify.policy].required` exists, listed checks are required and all
other configured or inferred checks are optional. A listed check with no
configured or inferred command is unavailable and blocks. When the array is
absent, every configured or inferred check preserves legacy required
behavior. This makes existing configurations compatible while allowing new
projects to mark optional diagnostics explicitly. An empty `required = []`
is valid.

| Result | Required | Optional |
|---|---|---|
| exit `0` | pass | pass |
| exit non-zero | `VERIFY_REQUIRED_FAILED`, blocks | `VERIFY_OPTIONAL_FAILED`, warns |
| exit `126`/`127` or no required command | `VERIFY_UNAVAILABLE`, blocks | `VERIFY_UNAVAILABLE`, warns |
| configured timeout exceeded | `VERIFY_TIMEOUT`, blocks | `VERIFY_TIMEOUT`, warns |

Exit status is the primary evidence for ordinary checks. Output containing
`PASS` cannot rescue exit 1, and output containing `FAIL` does not override
exit 0. Conditional attestation verifiers are stricter: exit 0 is necessary
but must also accompany the structured JSON contract documented below. Output
is captured only for concise diagnosis and is never evaluated as a command.
`agent-md.toml` is trusted project configuration containing executable shell
commands; do not populate it from untrusted external or natural-language
output.

Captured output is excerpted, never dumped, because it becomes agent context.
Which part survives depends on the exit status. A passing check keeps the
first lines, where a successful run says what it did. A failing check keeps
the diagnostic instead: recognized failure records wherever they appear, a
little context around each, and always the end of the output. When nothing
recognizable is found, the end of the output is the evidence. Omitted regions
are marked with their line count, and the command and exit status are always
reported alongside.

This matters because head-of-output is actively misleading for a long failing
run. The beginning of a 300-test suite is the part that passed, so a failure
at test 287 would otherwise hide behind a truncation notice. Selection is
runner-agnostic and recognizes the shapes real tools print, including TAP
`not ok`, pytest `FAILED` and tracebacks, Go panics, and compiler diagnostics.
It is not a parser for any single runner and does not affect pass or fail,
which remain decided by exit status alone.

`timeout_seconds` is a per-check/provider bound. `total_timeout_seconds` is a
separate core deadline covering contract/control resolution, every ordinary
check, Risk evaluation, applicable independent/approval providers, and the
structured completion decision. Before each subprocess the runner uses the
smaller of the per-check limit and the remaining total budget. Exhausting the
total is always blocking—even during an optional check—because completion was
not fully evaluated. Both bounds require `timeout` or `gtimeout`.

Claude and Codex timeouts are outer transport envelopes, not verification
policy. The installer uses the same effective budget resolver, including legacy
derived ceilings, to materialize them above the core total: Claude adds
30 seconds for finalization; the serial Codex wrapper additionally reserves 10
seconds each for state and sensory enforcement. Stop validates that relationship
before starting an expensive check and fails closed with
`VERIFY_HOST_TIMEOUT_INCOMPATIBLE` when an edited policy and installed adapter
are out of sync. Rerun the installer after changing the total budget.

Legacy configuration does not silently reinterpret 300 seconds per check as
300 seconds total. When only a per-check timeout exists, the core derives a
ceiling from every potentially executable ordinary/provider stage plus a
30-second resolution/finalization reserve. With neither timeout, standalone
`verify.sh`/pre-commit remain explicitly unbounded; Stop retains its historical
300-second core budget inside the larger host envelope. New configurations
should declare an intentional project-specific total.

Verification evidence has distinct classes:

- **static** — typecheck and lint;
- **automated** — unit and integration tests;
- **runtime** — the changed CLI, endpoint, service, script, or flow runs;
- **smoke** — a short end-to-end wiring check;
- **visual** — fresh structured UI evidence when applicable;
- **independent** — CI, another reviewer/agent, a human, or separate harness.

One category does not automatically prove another: lint is not behavior,
tests do not prove a CLI starts, and a screenshot does not prove backend
correctness. Independent verification is representable in the handoff but
is not required by default and never launches another model or orchestrator.

Run the complete declared contract with:

```bash
./.agent-md/bin/verify.sh
```

The helper first prints the ordinary configured/inferred checks. Advanced
independent/approval commands appear only when configured or when a blocking
result needs to explain them. It then reports name, status, exit code, command,
summarized evidence, and recovery. It exits non-zero only for invalid
configuration or blocking required results. Optional failures remain visible
warnings.

The core defines a provider-neutral protocol for
[authenticated verification receipts](docs/authenticated-verification-receipts.md),
including canonical worktree, contract, control, and mechanism identity. This
is not an unsigned local cache: without an authority-separated issuer, Stop
continues to execute the complete contract. A receipt file written by the
executor is never accepted as proof that checks ran.
The [local issuer](examples/local-issuer/README.md) can approve an explicit
Poetry runtime preparation in that contract and run it as the isolated runner
before each check. Authenticated local issuance requires bubblewrap and working
unprivileged user, mount and PID namespaces. Its Linux provider presents a
checked, read-only view of system CA certificates for HTTPS inside the sandbox;
the ordinary hooks and `verify.sh` do not.

`doctor.sh` validates contract configuration and wiring without executing the
suite or provider verifiers. For conditional capabilities it leads with:
configured, available, required for completion, required now, blocking now,
effect, and recovery. Trust-anchor detail follows only for a configured
verifier. Complex shell commands may be labeled “not preflighted”; the real
runner remains authoritative.

When no checks are configured or inferred, hooks allow completion but emit
`VERIFY_NOT_CONFIGURED`: the work is explicitly unverified, never silently
treated as verified.

## Risk Model

Risk controls the amount of evidence, review, and approval required for a
task. It does not decide whether code is safe and does not assign a numeric
score. The Git-bound declaration is deliberately small and agent-neutral:

```toml
# .project-control.toml
schema = 1
risk = "high"
```

The completion claim remains local working state:

```markdown
## Current

Status: verifying
Task: Harden auth token rotation
```

Allowed values are `low`, `medium`, `high`, and `critical`. A legacy/local
`Risk:` in progress remains readable as a proposal, but it is never a trust
root and cannot lower the effective Risk. Existing tracked progress can supply
a compatibility baseline until the project explicitly migrates; untracked or
ignored progress cannot. Risk is never silently defaulted to low.

The effective-control resolver compares the Git baseline with the worktree at
Stop/verify and with the index at pre-commit. Higher Risk applies immediately;
a lower proposal retains the previous requirements until a reviewed baseline
is established. When an approval verifier is configured, a downgrade requires
authority-separated approval bound to the exact resulting HEAD. A portable
human checkpoint is explicitly out-of-band: Git records content and review
visibility, not cryptographic proof of authorship.

| Risk | Additional completion requirement |
|---|---|
| `low` | Current required verification contract |
| `medium` | Required checks plus a passing configured runtime or smoke check when applicability is declared |
| `high` | Medium requirements plus trusted independent verification |
| `critical` | High requirements plus trusted explicit human approval |

When neither runtime nor smoke is configured for medium/high/critical,
coding-agent-control cannot determine semantic applicability. It emits an advisory
`RISK_RUNTIME_EVIDENCE_REQUIRED` warning and does not invent a command. When
either check is configured, at least one must pass before `done` is accepted.

Risk-sensitive evidence uses two conditional commands in the existing
verification section:

```toml
[verify]
test = "bats tests/"
runtime = "./scripts/runtime-smoke.sh"
independent = "./scripts/verify-ci-attestation.sh"
approval = "./scripts/verify-human-approval.sh"

[verify.policy]
required = ["test"]

[verify.attestation]
independent_files = ["scripts/attestation-lib.sh"]
approval_files = ["scripts/attestation-lib.sh"]
independent_capabilities = ["gh"]
```

`independent` and `approval` do not belong in `verify.policy.required`; Risk
activates them only for a final `Status: done`. A different command rerun by
the same executor is not automatically independent. Each verifier must be a
direct executable path whose exact declaration already exists unchanged in
the committed `agent-md.toml` at `HEAD`; shell pipelines, inline commands, and
free-form approval prose are not trust anchors.

### Attestation trust contract

An attestation must satisfy four properties:

- **origin** — a small allowed value identifies CI, reviewer, human, external
  harness, or trusted local verifier provenance;
- **integrity** — the executor cannot modify the verifier or its declared
  repo-local dependencies without invalidating trust;
- **freshness** — evidence for an earlier code state becomes stale;
- **binding** — evidence names the exact full HEAD commit it covers.

The verifier writes exactly one JSON object to stdout:

```json
{
  "status": "pass",
  "kind": "independent",
  "origin": "ci",
  "target": {
    "commit": "0123456789abcdef0123456789abcdef01234567"
  }
}
```

`kind` must match the configured slot. Independent origins are `ci`,
`reviewer`, `human`, `external-harness`, or `trusted-local-verifier`; approval
requires `origin: human`. Approval never substitutes for independent evidence,
so critical requires two valid attestations. The origin value is constrained
metadata, not proof by itself; the pre-established verifier remains responsible
for validating the real external authority. Optional `reference`, `message`,
and `timestamp` fields may aid diagnosis but timestamp is not binding.

For a repo-local verifier, the executable must be an ordinary executable blob
present and unchanged in HEAD. Symlinks, path traversal, worktree-only files,
mode changes, and staged or unstaged content changes are rejected. Because
coding-agent-control does not attempt unsafe shell-import analysis, every repo-local file
on which a verifier depends must be explicitly listed in the reviewed
`[verify.attestation]` array for that slot. The key is mandatory for a
repo-local verifier; `independent_files = []` explicitly asserts that only the
verifier executable is involved. Those arrays and files must also match HEAD.

An absolute verifier outside the repository is classified as `external`.
coding-agent-control verifies that it exists, is executable, is not a symlink, and is not
detectably world- or executor-writable (including its immediate directory).
Broader ownership, mount, package, and parent-directory security belong to the
host. `doctor.sh` reports this as `environment-managed`; it does not claim to
audit the host.

Binding is deliberately conservative. If the shared classifier sees any
uncommitted operationally relevant path, strong high/critical attestation is
`RISK_ATTESTATION_UNBOUND`; commit the reviewed change and obtain evidence for
that exact HEAD. Ignored metadata such as Markdown does not invalidate the
binding. The worktree fingerprint defined for future authenticated ordinary
receipts does not extend or replace this strong attestation contract. Until an
authority-separated receipt issuer exists, no local worktree artifact can skip
Stop verification. An attestation for a different commit is
`RISK_ATTESTATION_STALE`.

Adding `approval = "true"`, creating `approval.json`, writing `By: human`, or
claiming approval in chat is never accepted. Invalid JSON, missing target,
wrong kind/origin, nonzero exit, and a verifier changed before or during
evaluation all fail closed. Without reliable configured anchors, high or
critical completion remains blocked.

Migration from the earlier Risk Model is explicit: an exit-only verifier no
longer satisfies high/critical completion. Update it to emit the JSON contract;
for each repo-local verifier, add and review its corresponding
`verify.attestation.*_files` array (`[]` when there are no extra repo-local
dependencies), then commit that baseline before trusting it. Existing project
configuration is not rewritten automatically.

Provider dependencies may be declared as literal command names through
`verify.attestation.independent_capabilities` or
`verify.attestation.approval_capabilities`. This is generic diagnostic metadata,
not a provider schema and not a command for the core to execute. Doctor reports
availability without running the verifier. A missing capability is a warning
while work is `active`, `blocked`, or `verifying`; it blocks `done` only when
the current Risk requires that attestation. coding-agent-control never installs or
authenticates provider tooling automatically. Capability declarations are part
of the reviewed trust configuration and must match HEAD.

### GitHub Actions reference verifier

[`examples/github-actions/`](examples/github-actions/) contains a provider-side
reference implementation built on `gh api`. It asks the official workflow-runs
API for one explicitly configured workflow and the exact full current HEAD,
then deterministically selects the newest matching run. Only
`status=completed` with `conclusion=success` emits the generic independent
attestation. Pending, absent, failed, cancelled, timed-out, malformed, or
wrong-SHA results fail without a passing attestation.

GitHub-specific repository/workflow selection, authentication, and API parsing
stay in the example. The core still sees only a direct trust anchor, declared
repo-local dependencies, external command capabilities, and the generic JSON
attestation contract. There is no `[github]` section, hidden `curl` fallback,
HTML scraping, token persistence, or automatic `gh` installation.

#### Root-of-Trust Bootstrap

Bootstrap is deliberately out-of-band and non-circular: **a verifier cannot
bootstrap trust in the same untrusted change that introduces or modifies it.**

```text
untrusted verifier change
        -> human/operational review outside the executor
        -> checkpoint commit
        -> verifier, config, dependencies, and workflow become HEAD baseline
        -> future commit
        -> external CI
        -> exact-SHA attestation
        -> verification
```

The reference verifier rejects a HEAD commit that changes its executable,
provider config, or target workflow relative to `HEAD^`. CI for the bootstrap
commit may be useful smoke information, but cannot independently approve the
trust anchor that defines that CI evidence. Bootstrap is operationally accepted
only after external review creates the checkpoint and doctor observes the
committed anchor and dependencies clean in HEAD. There is no `--force-trust`,
`trust=true`, `skip-attestation`, automatic baseline, or self-approval path.

#### First future high-risk cycle

After that checkpoint, a future task uses the normal contract:

```text
Git-bound Risk: high; local Status: active
        -> implementation
        -> Status: verifying
        -> required local verification
        -> checkpoint commit ABC123 and push
        -> GitHub Actions verifies exact ABC123
        -> eligible trusted verifier queries CI
        -> kind=independent, target.commit=ABC123
        -> coding-agent-control verification
        -> done claim accepted
```

The agent may write the `done` claim before the final completion boundary, but
that text does not make it valid: commit is not done, CI green is not
automatically trusted, and an attestation for another SHA does not apply. A new
commit or any change to the verifier, its declared dependencies, or its workflow
invalidates the prior evidence. Binding to current state—not timestamp alone—is
the freshness guarantee.

GitHub Actions is potentially independent because execution and structured run
state live outside the local executor and bind to a commit SHA. Its real
strength still depends on protected credentials, workflow review, runner
security, repository permissions, and branch policies. See the
[provider README](examples/github-actions/README.md) for configuration,
credentials, the exact bootstrap cycle, and supported topology.

The defensive signal audit recognizes explicit path/content indicators for:

- authentication/authorization and permissions;
- credentials, secrets, and vaults;
- production/deployment and infrastructure/Terraform;
- migrations/schema and newly added destructive SQL;
- payments/billing;
- explicit OpenAPI/Swagger/public-API surfaces.

Signals can produce `RISK_POSSIBLY_UNDERRATED`, with signal names and paths,
but never rewrite Risk or prove a classification. Examples are guidance, not
an automatic safety verdict.

Final attestation requirements apply only to `done`. `active`, `blocked`, and
`verifying` remain usable while evidence is pending. Fatal Safety controls
always remain independent: critical Risk and valid approval cannot bypass a
destructive-command block. Stop and `verify.sh` enforce final Risk evidence;
pre-commit validates Risk syntax and trust-anchor integrity but deliberately
does not execute or require final independent/human attestations.

Doctor reports the current effect and recovery first, then the declaration,
status, observed signals, consistency, and configured verifier details. It
does not execute attestations, approve work, or call a reviewer. `verify.sh`
performs the full sequence:
validate working progress and effective control, run the base verification contract, apply final Risk
requirements, execute applicable trusted evidence verifiers, and return
non-zero for a blocking result.

## Operational State Enforcement

Stop and pre-commit share one effective-control resolver and deterministic
path classifier. Stop combines the committed baseline with the worktree;
pre-commit combines it with the index. A path remains relevant when either
baseline or proposal classifies it as relevant, so a same-change ignore cannot
reduce coverage. Working progress remains useful for handoff and freshness but
is not the control root.

`progress.md` has a deliberately small line-oriented format:

```markdown
# Progress

## Current

Status: verifying
Task: Preserve third-party Codex hooks

## Scope

- install.sh
- .codex/hooks/**
- tests/**

## Next

- Run the Codex-only smoke test
- Verify reinstall idempotency

## Blockers

None

## Recently Completed

- Shared classifier
- TOML arrays
```

The required sections are `Current`, `Next`, `Blockers`, and
`Recently Completed`, in that order; `Scope` is optional between Current
and Next. There must be exactly one status, at most one task, at most one
legacy-compatible local Risk proposal, explicit Next/Blockers content, and no
more than five recent completions. A task is required for `active`, `blocked`,
and `verifying`. Effective Risk comes from `.project-control.toml` plus any
stricter proposal. Malformed progress
blocks when it is itself changed or when relevant source changes depend
on it; absent working progress does not block ordinary work or reduce the
separate control requirements.

`verifying` means implementation is ready while applicable checks are still
pending or being evaluated. Status: done is a completion claim, not proof of completion.
A done claim is accepted only after all applicable state integrity, required verification, Risk, attestation, and approval requirements pass.
Stop/pre-commit/`verify.sh` execute the current required contract freshly.
coding-agent-control does not persist agent-authored `pass` lines in `progress.md`, which
would duplicate CI and could not prove that a command actually ran.

The installer still never overwrites an existing `memory/progress.md`. On a
fresh Git install it adds the five working files to `.git/info/exclude`, never
to a committed ignore file and never to the index.
A legacy file without this structure remains untouched, but the next
operational change reports `STATE_PROGRESS_INVALID` with migration
guidance. Migration is deliberate and manual; hooks do not silently
rewrite project state.

Allowed statuses and transitions are:

```text
planned -> active
active -> blocked
active -> verifying
blocked -> active
verifying -> active
verifying -> done
done -> planned
done -> active
```

An unchanged status is allowed. When Git has a valid previous
`progress.md`, the hook compares it with the current worktree or staged
snapshot. It does not infer semantic intent or persist a hidden state
history. An observed change outside the direct transition list warns
rather than blocks because Git cannot prove that no uncommitted
intermediate state existed.

`Scope` contains shell-style path globs. Relevant files inside it are
normal; relevant files outside it produce
`QUALITY_OUT_OF_SCOPE_CHANGE` with `warning` severity and their paths.
No Scope means no scope analysis. Files ignored by the existing source
classifier never enter scope analysis.

Scope is focus control, not a sandbox. It does not replace destructive
command protection, path protection, Git permissions, the host sandbox,
or human approval. No TOML keys were added for this feature.

Defaults cover conventional source/test directories and common code
extensions. Clear metadata and infrastructure such as `docs/**`,
`*.md`, `.gitignore`, `.ai-memory.toml`, `.github/**`, and agent runtime
directories are ignored. `scripts/**` and `tools/**` are deliberately
not ignored: executable code in them is relevant when it matches a
source glob.

Within one established policy snapshot, both keys are optional, a declared key
replaces its defaults, and `ignore_globs` wins. Across a policy change, baseline
and proposal coverage are combined conservatively: new source patterns apply
immediately while new ignores cannot erase baseline coverage in the same
change. Required checks from either policy remain required, and
`visual.required = true` remains required if either side sets it. Invalid or
unordered policy changes cannot create a more permissive completion contract.
An empty array remains valid. Values use case-sensitive shell-style globs.

### Python

```toml
[state]
source_globs = ["src/**", "tests/**", "*.py", "*.pyi"]
ignore_globs = ["docs/**", ".ai-memory.toml", ".gitignore"]
```

### Node / TypeScript

```toml
[state]
source_globs = [
  "src/**",
  "app/**",
  "packages/**",
  "tests/**",
  "*.js",
  "*.jsx",
  "*.ts",
  "*.tsx",
]
ignore_globs = ["docs/**", ".github/**", "*.md"]
```

### Hybrid project

```toml
[state]
source_globs = [
  "backend/**",
  "frontend/**",
  "scripts/**",
  "tools/**",
  "tests/**",
  "*.py",
  "*.ts",
  "*.tsx",
  "*.sh",
]
ignore_globs = ["docs/**", "generated/**", ".ai-memory.toml"]
```

Projects that consider all of `scripts/**` or `tools/**` non-operational
can add those paths to their own `ignore_globs`.

## Evidence-First Workflow

Before behavior changes, establish reproducible evidence of the current
or failing behavior. Appropriate evidence includes unit/integration
tests, CLI exit codes, HTTP responses, smoke tests, log assertions,
snapshots, and visual artifacts. Observe it, make the smallest change,
repeat the same evidence, then run regression checks. TDD remains the
preferred form when it is cheap and applicable; inspection alone is not
completion evidence.

## Visual Evidence

UI work needs more than passing tests. Capture a screenshot:

```bash
./.agent-md/bin/playwright-capture.sh http://localhost:3000 .agent/visual/home.png
```

Then write `.agent/visual/home.md`:

```markdown
# Visual Check

Changed files:
- src/app/page.tsx

Route: /
Viewport: 1280x800
Artifact: home.png
Observed result: layout renders without overlap at desktop width.
```

The strict visual hook requires a fresh non-empty markdown file that
references a fresh non-empty image by filename and includes the required
fields. `visual.required = true` remains fail-closed. Optional evidence only
warns, and visual evidence never substitutes for required static, automated,
runtime, or smoke checks.

## Local Working State

`memory/` is a small, local handoff surface for the current work. Fresh Git
installs exclude these paths through `.git/info/exclude`; the installer never
stages them, and their absence does not erase control requirements:

- `agents.md` — active agents, MCPs, tech stack, tooling
- `plan.md` — current direction, current phase, and decisions still in
  force; remove superseded decisions
- `progress.md` — one current task/status, optional scope, immediate next
  steps, explicit blockers, and at most five recent outcomes
- `verify.md` — current executable checks and definition of done
- `gotchas.md` — only reusable invariants and recurring, non-obvious
  failure modes that still apply

Do not turn these files into a development journal. Prune superseded
plans, old completions, and irrelevant gotchas. Git retains factual code
history; an optional semantic-memory provider can retain semantic and
cross-agent history. ICM is one supported reference provider.

Each gotcha uses a `##` title and requires non-empty `**Rule:**` and
`**Why:**` fields. `**Scope:**`, `**Evidence:**`, and `**Added:**` are
recommended. Do not record every correction; remove obsolete entries.

Operational handoff relies first on `progress.md`, `plan.md`,
`verify.md`, `gotchas.md`, and Git. A configured semantic-memory provider can
provide older context, but it is not needed to determine where work stands,
what remains, blockers, or the next action.

The agent-neutral control boundary is separate: `.project-control.toml`
declares established Risk, while `agent-md.toml` declares versioned project
policy. A local `Status: done` is only a claim evaluated against those effective
requirements and fresh evidence.

Installation templates live separately under
`.agent-md/templates/memory/`, so this repository's own operational state
is never copied into a new project.

## Helper Scripts vs Codex Skills

coding-agent-control intentionally separates plain helper scripts from Codex-native
skills.

- `.agent-md/bin/*` are shell helpers any agent can run.
- `.agents/skills/<name>/SKILL.md` are native Codex skills.

Discover helpers:

```bash
./.agent-md/bin/discover_helpers.sh
./.agent-md/bin/doctor.sh
./.agent-md/bin/verify.sh
```

Use Codex skills with `$agent-md-verify` or `$visual-evidence`.

## What This Does Not Fix

- A rules file cannot force judgment by itself.
- Hooks only cover events exposed by the host agent.
- Pre-commit hooks can be bypassed with `git commit --no-verify`.
- Bash safety hooks are guardrails, not a sandbox.
- Cursor and Windsurf get rules plus optional git-hook fallback, not
  native runtime enforcement from this repo.
- Path globs are a conservative heuristic, not semantic analysis. Task
  completion without a matching file change remains an advisory agent
  responsibility.
- The TOML reader implements only the scalar and quoted string-array
  subset used by coding-agent-control. It is intentionally not a general TOML
  parser.
- State globs use the shell's case-sensitive matching rather than a
  custom glob engine. Tests cover spaces, dotfiles, and nested package
  paths, but classification remains path-based.
- When `memory/progress.md` is gitignored, state enforcement falls back
  to file mtimes. That is a lower-reliability approximation than Git
  state and can be affected by clocks or file-copy tooling.
- Git-bound control supplies content binding and review visibility, not proof
  of human authorship. The portable downgrade checkpoint is out-of-band;
  deterministic authorship/approval guarantees require an authority-separated
  verifier plus suitable host/repository protections.
- Transition validation can compare only states captured by Git or its
  index. Uncaptured intermediate edits are not factual history and cannot
  be reconstructed without adding persistence, which this phase avoids.
- Command availability preflight is intentionally conservative. Doctor can
  prove a simple executable is present but may label compound shell commands
  “not preflighted”; actual exit status remains authoritative.
- Per-check and total completion deadlines depend on the portable environment
  providing `timeout` or `gtimeout`. Host timeouts are larger transport
  envelopes and are validated before full Stop verification starts.
- Risk signals are keyword/path/diff heuristics. They can flag possible
  underrating but cannot determine safety, intent, reversibility, or blast
  radius.
- A clean committed verifier plus its explicit trusted-file set protects only
  the declared chain. Projects remain responsible for listing every repo-local
  dependency and for making the anchor validate genuine external provenance.
- External-verifier filesystem checks are intentionally shallow and portable;
  the host remains responsible for ownership, mount integrity, package supply
  chain, and directories above the immediate parent.
- Strong attestation currently binds only to a clean operational HEAD. The
  separately defined worktree receipt fingerprint is not strong attestation
  and remains inactive until an authority-separated issuer is available.
- Runtime applicability cannot be inferred generally. No configured
  runtime/smoke command produces a warning rather than false enforcement.
- Independent evidence is conditional enforcement, not orchestration.
  Reviewer selection, automatic reviewer/model calls, profiles, and autonomy
  remain deferred.

## Development

```bash
bash tests/run.sh
shellcheck .claude/hooks/*.sh .codex/hooks/*.sh .agent-md/bin/*.sh examples/github-actions/*.sh .githooks/pre-commit install.sh
```

`tests/run.sh` is the required test runner. It runs the Bats suite in parallel
and refuses to report success unless every collected test reported a result,
because `bats --jobs` exits 0 after executing nothing when GNU parallel is
missing. It defaults to six jobs; set it per machine:

```bash
BATS_JOBS=8 bash tests/run.sh
```

GNU parallel is a development and CI dependency of this repository only. It is
not a dependency of coding-agent-control itself, and the installer never
installs it into a consuming project. `BATS_JOBS=1` runs the suite serially and
needs no parallel at all.

CI runs Bats, ShellCheck, JSON validation, alias-sync checks, and
installer smoke tests.

## Origin And Attribution

Originally derived from
[`iamfakeguru/agent-md`](https://github.com/iamfakeguru/agent-md) under the MIT
License and substantially evolved into an independent project. The original
copyright notice remains in [`LICENSE`](LICENSE), and the Git history is
preserved. The upstream project is acknowledged as the historical origin; it
is not a runtime or installation dependency.

## License

MIT. See [`LICENSE`](LICENSE).
