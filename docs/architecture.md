# Architecture

`coding-agent-control` is a repository-local control, verification, and trust
layer for coding agents. Coding agents execute work; the developer and project
retain authority over what is allowed, what evidence is required, and when a
completion claim is accepted.

## Authority Boundaries

| Component | Authority and responsibility |
|---|---|
| Developer / project | Intent, project policy, final Risk direction, and critical approval |
| coding-agent-control | Deterministic guardrails, current operational-state validation, verification requirements, and evidence validation on supported host surfaces |
| Coding agent / LLM | Proposes and executes work within the host capabilities; cannot silently redefine mandatory guarantees |
| Host | Sandbox, filesystem and process permissions, hook lifecycle, and whether configured hooks are actually invoked |
| Git | Factual code state and history |
| External verifier | Authority-separated evidence bound to the current target |
| Semantic-memory provider | Optional historical and semantic recall, with no authority over correctness or completion |

The project does not control model reasoning and cannot provide enforcement on
a host surface that does not invoke a blocking mechanism. It is not a sandbox,
agent runtime, orchestrator, CI service, Git replacement, or semantic-memory
system.

## Current Repository Interfaces

The product identity is `coding-agent-control`. The following
historical names remain supported interfaces because renaming them would add
migration risk without improving a guarantee:

- `agent-md.toml` and `agent-md.toml.example`;
- `.agent-md/` helper and template paths;
- `memory/` operational-state files;
- `$agent-md-verify` and installed rule filenames;
- existing Claude, Codex, Cursor, Windsurf, and pre-commit integration paths.

These names are retained compatibility interfaces in the current architecture.
No removal is planned as part of this transition. They do not make the upstream
project a dependency.

## Working State And Control State

The state boundary is hybrid and intentionally small:

- **working state** lives in `memory/` for current-task context and handoff. A
  fresh Git install adds these paths only to the repository-local
  `.git/info/exclude`; they are not staged or published automatically. Working
  state may be absent and is never a trust root;
- **control state** lives in the agent-neutral `.project-control.toml`. Version
  1 contains exactly `schema = 1` and one `risk` value;
- **project policy** remains in the versioned `agent-md.toml`, because its
  classifier, required checks, visual requirement, and attestation declarations
  can change the guarantees applied to completion.

`Status`, `Task`, `Next`, `Blockers`, `Recently Completed`, and `Scope` remain
local working state. `Status: done` is only a completion claim: acceptance is
calculated from current evidence and is never persisted as a pass. Scope is an
advisory focus mechanism, not a safety boundary. `gotchas.md` is likewise
working guidance; mandatory invariants belong in versioned policy or
directives.

Existing tracked `memory/` files remain compatible. A tracked legacy
`memory/progress.md` Risk can supply the compatibility baseline only when no
`.project-control.toml` exists. An untracked or ignored progress file may
propose a stricter Risk but cannot become a more permissive trust root. No
legacy state is migrated automatically.

### Effective control requirements

Stop and `verify.sh` resolve the committed `HEAD` baseline against the current
worktree. Pre-commit resolves the same baseline against the index. The resolver
is conservative at the guarantee boundary:

- effective Risk is the stricter of baseline and proposal;
- required verification from either policy snapshot remains required;
- a path remains relevant when either classifier covers it;
- `visual.required = true` remains effective when either snapshot requires it;
- invalid or absent control inputs never silently become `low` or produce a
  more permissive policy.

A local completion claim can therefore activate requirements but cannot lower
Risk, verification, trust, approval, path coverage, or visual requirements.
Working state can be removed without erasing the Git-bound control baseline.

### Downgrade authority

A lower proposal remains pending under the previous requirements. The portable
basic mechanism is an explicitly reviewed checkpoint that establishes a new
Git baseline out of band. Git supplies content binding and review visibility;
it does not prove who authored or approved the commit. Protection against Git
hook bypass, rewritten history, or an executor advancing an unreviewed baseline
belongs to host and repository policy.

When a project configures the existing approval verifier, a downgrade commit is
accepted at its completion boundary only with structured, authority-separated
approval bound to that exact `HEAD`. Executor-written prose, booleans, local
hashes, or sidecars are not approval. No local cryptography, database, daemon,
or private trust store is introduced.

This is deliberately not a general private control-state system. Projects that
require deterministic authorship or durable approval provenance must supply an
external authority and repository protections appropriate to that guarantee.

## Optional Capabilities

External capabilities are conditional. Missing optional capability must not
break ordinary work; missing mandatory capability blocks only the action or
transition that requires its guarantee.

ICM is one optional semantic-memory integration. It can improve historical and
cross-agent recall, but hooks, safety, verification, Risk, trust, approval, and
completion do not depend on it. Git remains factual truth and current local
operational state remains the deterministic handoff source.

GitHub Actions is likewise a reference source of independent evidence, not a
core dependency. The core validates a provider-neutral attestation contract;
provider-specific API access stays outside the core.

The same separation applies to the planned optimization for repeated ordinary
verification. [Authenticated verification receipts](authenticated-verification-receipts.md)
bind check results to canonical worktree/control/contract identity, but only an
authority-separated issuer can prove that those checks executed. Until such an
issuer is configured, Stop continues to run the complete contract.

## Completion deadline and host envelopes

Full fallback verification has an internal core deadline independent of host
transport limits. `verify.policy.timeout_seconds` bounds one check/provider;
`verify.policy.total_timeout_seconds` bounds the entire completion evaluation,
starting before contract/control resolution and ending only after the structured
decision exists. Each subprocess receives `min(per-check, remaining-total)`.
Total exhaustion produces blocking `VERIFY_TOTAL_TIMEOUT`, records the stage and
still-unchecked checks when available, and never converts an incomplete optional
check into an advisory result.

Bounded commands are forcibly terminated at the deadline, even if they ignore
SIGTERM. The runner preserves canonical timeout status 124; commands must not
depend on completing cleanup after their execution budget has expired.

Baseline and proposal totals merge by taking the lower explicit value. Removing
or increasing a reviewed total in the same proposal therefore cannot enlarge
the effective completion window. A legacy per-check policy derives a total from
all ordinary checks and Risk-applicable configured providers plus deterministic
core overhead. A legacy standalone execution with no finite check limit remains
explicitly unbounded; its Stop compatibility path retains the historical finite
budget rather than depending on the host to kill it without a policy result.

Claude gives verification its own handler envelope. Codex has one serial wrapper,
so its envelope also reserves bounded state and sensory execution. Both adapters
must leave finalization margin beyond the core budget and validate compatibility
before checks start. Adapter limits never decide whether verification passes.
They only ensure the host remains alive long enough for the core to return its
decision. This budget model does not consume or trust Phase A receipts.

## Enforcement Vocabulary

- **Enforced** — a deterministic mechanism can block the relevant action or
  transition, the host invokes it, and integration or smoke coverage proves the
  wiring.
- **Advisory** — guidance or a warning without a proven blocking mechanism.
- **Unsupported** — no deterministic integration covers the surface.
- **Experimental** — an integration exists but does not yet support a stable
  public enforcement claim.

A rule written only in `AGENT.md` is advisory. Public claims must remain scoped
to the host and surface actually covered.

## Implementation Boundary

Shell remains the current implementation because it is portable across the
supported repository workflows and the existing test suite covers its behavior.
A language migration, dedicated CLI, plugin framework, Policy Profiles,
Autonomy, and state redesign are separate future decisions—not prerequisites
for a distinct product identity.
