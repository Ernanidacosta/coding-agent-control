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

## Operational State Direction

The current `memory/` contract is preserved for compatibility in this phase,
but it is not the final state architecture.

Future design work should separate:

- **working state** — volatile current-task and handoff context that may remain
  local and unversioned by default; using a coding agent must not require a
  developer to publish evidence of that use in Git;
- **control state** — Risk, safety, verification, trust, approval, and
  completion inputs whose integrity and binding must be protected, but which
  need not necessarily be committed.

That separation needs an explicit integrity and binding design. This phase does
not rename `memory/`, add persistence, or weaken the existing Git/mtime-based
compatibility behavior.

### Priority gap: private control-state integrity

Current Risk is executor-editable in `memory/progress.md`, and the current
implementation does not compare Risk transitions against the previous trusted
state. Therefore, a Risk downgrade may be silent when deterministic risk
signals do not detect possible underrating. Risk is a declared control input;
signals can warn, and human/project direction remains authoritative, but the
current implementation does not provide a complete integrity mechanism for
private, non-versioned Risk state.

The first candidates for local, unversioned working state are:

- `memory/plan.md`;
- `memory/verify.md`;
- `memory/agents.md`;
- Task, Next, Blockers, and Recently Completed.

The following require an explicit control-state design before being untracked:

- Status;
- Risk;
- progress structure used by enforcement;
- gotchas structure, if deterministic validation remains required.

Scope remains an advisory focus mechanism and must not become a security
boundary. Volatile operational state should not require publication. Any state
that changes safety, verification, Risk, trust, approval, or completion
requirements needs an integrity and binding mechanism appropriate to the
guarantee it controls. Integrity-bound does not necessarily mean committed, but
private control state cannot be described as trustworthy until an actual trust
root exists.

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
