# GitHub Actions independent verifier

This is a provider-specific reference implementation of
coding-agent-control's generic attestation contract. GitHub and `gh` remain
outside the core.

The verifier asks the official GitHub Actions workflow-runs API, through
`gh api`, for runs of one configured workflow and exact full `HEAD` SHA. It
selects the newest matching run by `created_at`, then `run_attempt`, then `id`.
Only `status=completed` with `conclusion=success` emits an attestation. A newer
pending, failed, cancelled, timed-out, or otherwise non-successful run wins over
an older success and causes failure.

Official interfaces:

- [GitHub Actions workflow-runs REST API](https://docs.github.com/en/rest/actions/workflow-runs)
- [`gh api` manual](https://cli.github.com/manual/gh_api)
- [`gh` authentication](https://cli.github.com/manual/gh_auth)

## Configure the provider

Edit `github-actions-independent.conf` with a literal expected repository,
workflow filename, and workflow path. It contains no credentials and is parsed
as data rather than sourced as shell.

This repository's checked-in config names its standalone GitHub location,
`Ernanidacosta/coding-agent-control`. Changing the verifier config or trusted
workflow establishes a new trust-anchor baseline; the change cannot attest
itself.

Copy the verifier and config to a reviewed repo-local location, then merge the
provided [`agent-md.toml.example`](agent-md.toml.example) snippet into the
project policy:

```toml
[verify]
independent = "./examples/github-actions/github-actions-independent.sh"

[verify.attestation]
independent_files = [
  "examples/github-actions/github-actions-independent.conf",
  ".github/workflows/ci.yml",
]
independent_capabilities = ["gh"]
```

The executable is checked implicitly by core trust validation. The companion
config and workflow are explicit trusted dependencies. `gh` capability metadata
lets doctor/verify diagnose availability without teaching core about GitHub.

The verifier never installs or authenticates `gh`, stores a token, prints a
token, scrapes HTML, reads agent-produced result files, reruns tests locally, or
writes GitHub state. Authentication may come from a protected host login,
`GH_TOKEN`, or `GITHUB_TOKEN`; credential protection belongs to the host.

## Root-of-Trust Bootstrap

`A verifier cannot bootstrap trust in the same untrusted change that introduces
or modifies it.`

Follow the [canonical independent verification trust bootstrap procedure](../../docs/architecture.md#independent-verification-trust-bootstrap).
It binds the owner's baseline approval to the exact trust-changing SHA and
reviewed file hashes, then requires a legitimate descendant preserving that
chain, external CI and attestation for the descendant's own SHA. An empty commit
just to make the provider eligible is not permitted.

This root is established out-of-band. There is no force-trust, skip-attestation,
automatic-baseline, or self-approval mechanism. A bootstrap CI success is
useful information, but is not an independent attestation approving the trust
anchor that defines that evidence.

The same refusal applies when the current commit changes the target workflow.
This prevents replacing CI with a trivial success and using that workflow to
attest the weakening commit. It is intentionally conservative and checks the
current commit against its first parent.

## First future high-risk cycle

```text
Status: active, Risk: high
        -> implementation
        -> Status: verifying
        -> required local verification
        -> Status: done claim
        -> commit and push ABC123
        -> GitHub Actions completes successfully for exact ABC123
        -> this eligible verifier emits kind=independent
           with target.commit=ABC123
        -> coding-agent-control verify accepts the done claim
```

Commit is not completion, CI green is not automatically trusted, and a passing
attestation for another SHA is stale. A new commit or a change to this verifier,
its config, declared dependencies, or target workflow invalidates earlier
evidence. Exact state binding—not timestamp alone—is the freshness guarantee.

If `gh` is absent or authentication is invalid, the provider fails with a
recovery message and emits no passing attestation. That does not make `gh` a
core dependency: ordinary low/medium work and intermediate high/critical states
remain usable, while a high/critical `done` claim stays blocked when it requires
the unavailable guarantee. The verifier never installs or authenticates `gh`.

## Independence limits

GitHub Actions is potentially independent because execution and structured run
state live outside the local executor and are bound to an exact commit. Its
strength still depends on protected GitHub credentials, repository permissions,
workflow review, runner security, and appropriate branch policies.

The reference implementation targets one repository and one workflow. It does
not model every fork, pull-request, merge-queue, reusable-workflow, or GitHub
Enterprise topology. Other providers—GitLab CI, Jenkins, Buildkite, a human
review system, or an external harness—can emit the same generic JSON without
changing the coding-agent-control core.
