# Authenticated Verification Receipts

Authenticated verification receipts are the planned optimization boundary
between an explicit verification run and a later completion gate. They allow a
gate to reuse ordinary check results only when an authority-separated provider
proves both execution and freshness.

This document defines protocol version 1. The current implementation provides
canonical identity, payload, coverage, and validation-state functions, but does
not configure an issuer, persist receipts, or consume them at Stop. Without a
trusted issuer, Stop continues to execute the complete verification contract.

## Security boundary

A fingerprint proves that data names a particular repository state. It does not
prove that a command ran or that its exit status was observed. A receipt file is
therefore always an untrusted envelope, regardless of where it is stored.

An authoritative issuer must be separated from the executor. Suitable designs
include a protected host capability or a previously trusted external executable
that the executor cannot modify and cannot ask to authenticate arbitrary
results. Repository scripts, file permissions controlled by the same user,
timestamps, local hashes, and secrets available to the executor do not supply
that authority.

The planned disposable location is `.agent/verification/`. It is not a trust
root and is structurally excluded from its own source identity. Deletion is
safe: it produces an absent receipt and invokes the safe fallback.

## Provider-neutral operations

A future provider adapter has two logical operations. The transport may be a
host capability or a direct external executable, but the JSON semantics remain
the same.

### Issue

The provider receives a canonical current identity and effective verification
contract. It must execute the declared checks itself or through a protected
execution path. It must fingerprint the state before and after execution and
must not issue a terminal attempt for mismatched states.

Every completed attempt is authenticated, including a failed attempt. This is
necessary so a later failure for state X can supersede an earlier pass for the
same state X.

The receipt envelope has this shape:

```json
{
  "schema": 1,
  "scope": "worktree",
  "attempt": {
    "issuer": "provider-defined-stable-id",
    "sequence": "provider-defined-monotonic-value"
  },
  "fingerprints": {
    "source": {"algorithm": "sha256", "value": "..."},
    "contract": {"algorithm": "sha256", "value": "..."},
    "control": {"algorithm": "sha256", "value": "..."},
    "mechanism": {"algorithm": "sha256", "value": "..."}
  },
  "status": "pass",
  "checks": [
    {
      "name": "test",
      "requirement": "required",
      "origin": "configured",
      "command": "bats tests/",
      "status": "pass",
      "exit_code": 0
    }
  ],
  "authentication": {
    "format": "provider-defined",
    "value": "opaque-authenticated-value"
  }
}
```

The authenticated payload is the complete receipt except the
`authentication` envelope itself. In particular, authentication covers:

- schema and scope;
- issuer and attempt sequence;
- every state fingerprint;
- overall attempt status;
- each check name, requirement, origin, command, status, and exit code.

Logs, conversational state, completion claims, timestamps, and working memory
do not belong in the receipt. Existing structured check output excerpts remain
human diagnostics, not reusable proof.

### Validate

The provider receives the receipt and current canonical identity. It validates
the authentication and its own authoritative attempt ordering, then returns one
structured result:

```json
{
  "schema": 1,
  "status": "pass",
  "authentic": true,
  "latest": true,
  "issuer": "provider-defined-stable-id",
  "sequence": "provider-defined-monotonic-value",
  "payload_fingerprint": {
    "algorithm": "sha256",
    "value": "..."
  }
}
```

The core must obtain this result by invoking an eligible provider. Caller-made
JSON has no authority. The core compares issuer, sequence, and canonical
payload fingerprint before using `latest`.

Sequence values are opaque strings to the core. They are never ordered by
lexical comparison, timestamps, filesystem mtime, or receipt discovery order.
The provider owns monotonic ordering and must report whether the exact receipt
is the latest authenticated terminal attempt for its state identity.

For example:

```text
state X → attempt 1 PASS → attempt 2 FAIL
```

Validation of attempt 1 must return `latest:false`. The authenticated failed
attempt 2 is current but has insufficient coverage. An old pass cannot be
replayed merely because the repository returned to state X.

## Canonical identity

Protocol version 1 separates four fingerprints:

| Fingerprint | Bound data |
|---|---|
| `source` | Explicit scope, HEAD base, index state, worktree state, tracked content, non-ignored untracked content, deletes, modes, and symlink targets |
| `contract` | Effective baseline-plus-proposal commands, requirements, origins, timeout, capabilities, and trusted-file declarations |
| `control` | Effective control validity, baseline/proposal/effective Risk, downgrade state, and project-policy relationship |
| `mechanism` | Protocol schema and the verification runner/gate implementation files |

The source manifest enumerates the complete HEAD and index path sets instead of
trusting diff output alone. Worktree scope also includes non-ignored untracked
files. Git produces NUL-delimited path input; JSON escaping and canonical key
and path ordering provide unambiguous framing before hashing. File entries
record index and worktree state separately.

Structural exclusions in version 1 are:

- `.git/**`;
- `.agent/verification/**`;
- the five local working-memory files under `memory/`.

The state classifier is not reused as a verification-input classifier. Ignored
untracked files remain outside the Git-visible boundary, so checks that depend
on such inputs need a future explicit input contract or authority-specific
environment binding. Gitlinks and special filesystem entries fail identity
construction in protocol version 1 rather than being approximated.

The digest uses SHA-256 through `sha256sum`, `shasum`, or `openssl`, whichever
the host already supplies. Index object contents are rehashed rather than
trusting a repository SHA-1 identifier as the only content identity. Absence of
a supported SHA-256 implementation makes receipt identity unavailable. A digest
provides deterministic content identity only; it is not authentication.

## Core validation states

The pure core validator returns one of five states:

| State | Meaning |
|---|---|
| `absent` | No receipt was supplied |
| `invalid` | Schema or authority-separated authentication is missing or inconsistent |
| `stale` | The authenticated attempt is superseded or its scope/fingerprints differ from current state |
| `insufficient-coverage` | The latest authentic current attempt lacks a passing current ordinary requirement |
| `authentic-current` | The latest authenticated attempt matches current identity and covers ordinary requirements |

`authentic-current` is not accepted completion. Risk, state enforcement,
independent verification, approval, visual requirements, and other applicable
gates remain separately calculated. An ordinary receipt never satisfies an
`independent` or `approval` requirement.

## Scope and fallback

Protocol version 1 models both `worktree` and `staged` identities, but this phase
does not issue or consume either. Worktree receipts can never satisfy staged
verification. Staged receipts remain unsupported until checks run against a
faithful materialization of the index rather than the normal worktree.

The mandatory fallback is:

```text
trusted issuer absent or unavailable
→ ignore any local receipt envelope
→ execute the complete effective verification contract
→ apply current Risk and state enforcement
```

There is no unsigned-receipt optimization and no fail-open path.
