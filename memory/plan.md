# Plan

- Consolidate only the approved Claude lifecycle implementation; no further code changes or roadmap work.
- Technical active checkpoint c08807bc3794143571bdc4dc157098a46d5ac469 is published with passing hooks, external CI and exact-SHA independent attestation.
- Publish verifying with normal hooks and require CI plus independent verification of that SHA before done. Publish done the same way, then run verify.sh on the final HEAD and confirm clean, synchronized Git state.
- Preserve Risk high, policy 750/900 and accepted limitations: retain orphans until confirmed termination; Start registration failure is diagnostic because the host cannot block creation. Keep directive injection/truncation, Codex and new roadmap items out of scope.
