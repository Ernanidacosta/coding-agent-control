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

### Administrative policy bootstrap

This is the canonical procedure for establishing a legitimately reviewed policy
when the current baseline can prevent its own replacement. It is an exceptional
owner-controlled administrative act, not an alternative verification path.
Use normal commit hooks whenever they can establish the reviewed policy.

The conservative resolver remains unchanged. For example, a baseline with
`timeout_seconds = 600` and an approved proposal with `750` still resolves to
`600` before establishment. Non-deterministic timeouts under that ceiling can
block the very commit that would make `750` the baseline. An executor may report
this obstruction; it cannot authorize an exception for itself.

Only the human project owner may explicitly authorize the following procedure.
Approval to edit a policy is not approval to skip a commit gate. A hook's
`--no-verify` hint is diagnostic, not authorization.

1. **Identify the prior baseline and obstruction.** Record the full previous
   `HEAD` SHA, the affected policy requirements and the evidence that the old
   baseline obstructs establishment. Preserve any failed check's command, exit
   status and diagnostic; never relabel it as passing. This procedure does not
   excuse an unrelated failing check or an invalid replacement policy.
2. **Prepare the bounded proposal.** Stage only the reviewed policy changes and
   necessary checkpoint metadata, following the project's tracking policy.
   Keep `memory/progress.md` in `verifying` once the proposal is ready; preserve
   valid state and Risk declarations. Do not disable, rename or repoint hooks,
   or change hook-selection configuration to make the commit possible.
3. **Capture the exact authorization target.** Save the complete staged patch
   against the prior SHA, including paths, content and modes, and the proposed
   commit message. For example, with `previous_head` set to that recorded SHA:

   ```bash
   git diff --cached --no-ext-diff --no-textconv --binary --full-index "$previous_head"
   ```

   Keep this patch and the obstruction evidence in the project's review record.
4. **Obtain explicit owner approval.** The owner's record must name the prior
   SHA, exact patch or its immutable reference, policy change and reason,
   reviewed message, and permission for **one** establishment commit using
   `git commit --no-verify`. It must acknowledge that both `pre-commit` and
   `commit-msg` are skipped and that complete verification follows. Record the
   owner and approval reference in the audit trail; an executor-written note,
   boolean or hash is not owner authorization or an approval attestation.
5. **Recheck the binding immediately before execution.** Compare current `HEAD`
   with the approved prior SHA and repeat the staged diff above. Inspect the
   actual message and authorship as well, because `commit-msg` will not run.
   If the SHA, patch or message differs, stop and obtain new approval. No
   unrelated change, automatic amend or retry is covered by this authorization.
6. **Establish once.** The owner performs the act, or explicitly authorizes the
   executor to perform that exact invocation. With `approved_message_file`
   naming the reviewed message, the permitted Git operation is:

   ```bash
   git commit --no-verify -F "$approved_message_file"
   ```

   The exception expires with this one invocation. It creates no persistent
   bypass setting and grants no permission to push. Host/repository protections
   and fatal Safety results remain in force.
7. **Audit what was established.** Record the full created SHA, its parent,
   actual message and committed patch, and compare them with the authorization:

   ```bash
   git rev-parse HEAD HEAD^
   git show -s --format=fuller HEAD
   git diff --no-ext-diff --no-textconv --binary --full-index "$previous_head" HEAD
   ```

   Preserve the owner-approval reference and all differences or errors. Git
   binds content and history; it does not prove human authorship. Any mismatch
   remains unaccepted and requires owner review, not silent correction.
8. **Do not manufacture evidence.** Commit exit zero proves only that Git
   created a commit. The exception and its audit record are not PASS, receipt,
   independent evidence or approval attestation. They cannot satisfy required
   verification or authorize a completion claim.
9. **Verify under the established baseline.** Keep `verifying` and run
   `./.agent-md/bin/verify.sh` with normal enforcement for the created SHA,
   without unreviewed operational changes. An unchanged proposal
   now matches the new `HEAD`; any further proposal still merges conservatively.
   Complete applicable runtime/smoke, state, Risk, independent and approval gates
   with evidence bound to the resulting SHA. If final Risk evidence is deferred
   until `done` by the core, obtain it before requesting that transition and
   validate the final done claim normally. Any new operational SHA needs its own
   applicable evidence. A failure, timeout or unavailable required capability
   stays blocking; the commit exception cannot be reused to accept it.

This administrative approval does not replace a configured `verify.approval`
verifier for Risk downgrades or critical completion. Introducing or modifying a
trust anchor still follows the separate [root-of-trust bootstrap](../README.md#root-of-trust-bootstrap): it cannot
attest its own introduction. Necessary adapter synchronization must preserve
normal enforcement; see [Completion deadline and host envelopes](#completion-deadline-and-host-envelopes).

The execution choice stays limited to Git's per-invocation option. The previously
rejected alternatives remain outside this procedure:

| Alternative | Why it is not the administrative mechanism |
|---|---|
| Change `core.hooksPath`, including a command-local override | Changes which hooks run and obscures the intended commit-gate exception |
| Rename or remove a hook | Alters enforcement files and introduces restoration risk |
| Change the baseline/proposal resolver | Weakens the conservative boundary for ordinary work |
| Add a special variable or flag to coding-agent-control | Creates a generic product bypass interface |
| Use Git plumbing to create a commit and advance refs | Avoids the normal commit interface and makes the exception harder to audit |

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

The same separation applies to the optimization for repeated ordinary
verification. [Authenticated verification receipts](authenticated-verification-receipts.md)
bind check results to canonical worktree/control/contract identity, but only an
authority-separated issuer can prove that those checks executed. The optional
[local issuer](../examples/local-issuer/README.md) supplies authenticated worktree
receipts that Stop can reuse for ordinary results. If neither an applicable
receipt nor a fresh issuer evaluation supplies reusable evidence, Stop runs the
complete contract. Independent verification and approval remain separate
requirements.

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
decision. Receipt reuse requires authority-separated authenticated evidence;
Phase A fingerprints alone never prove execution.

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
