# Verification

- Effective Risk is high (`.project-control.toml` declares medium; progress proposes high). Policy stays 750/900; do not change timeouts, policy, hooks or trust material to make a gate pass.
- Each operational checkpoint commits with normal Git hooks (pre-commit runs the full suite), is pushed, and must pass all four CI jobs (static, shellcheck, bats, install-smoke) for that exact SHA.
- Then `./examples/github-actions/github-actions-independent.sh` must pass with a clean worktree and `target.commit` equal to HEAD. An earlier commit's attestation never carries over.
- A done HEAD additionally passes `./.agent-md/bin/verify.sh` with clean worktree, empty index and HEAD equal to origin/main. Validate progress structure and declared transitions; `git diff --check` must pass. No bypass or automatic retry after a hook failure.
- Published tags are never moved or recreated; release notes live in the tag annotation. Confirm local tag resolution and the remote peeled SHA after any tag operation.
- Consumer rollouts verify the pinned install: `.agent-md/install-provenance.json` records source github-ref, the tag and archive commit bf43a0f5d1b92712851b939f942fa80268ba757d, and doctor reports it.
