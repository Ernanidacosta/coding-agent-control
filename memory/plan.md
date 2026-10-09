# Plan

- Consolidate only the approved Claude lifecycle implementation; no further code changes or roadmap work.
- Technical active checkpoint c08807bc3794143571bdc4dc157098a46d5ac469 is published with passing hooks, external CI and exact-SHA independent attestation.
- Verifying checkpoint a8deaa76cb398472fe1604557abc5d5cafc66fb6 is published with passing hooks, CI and exact-SHA independent verification. Final acceptance requires the published done checkpoint's own CI, independent attestation and full verify.sh, with clean, synchronized Git state.
- Preserve Risk high, policy 750/900 and accepted limitations: retain orphans until confirmed termination; Start registration failure is diagnostic because the host cannot block creation. Keep directive injection/truncation, Codex and new roadmap items out of scope.
