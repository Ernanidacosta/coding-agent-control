# Progress

## Current

Status: done
Task: CAC-GOLDEN-BASELINE-4: freeze the final baseline of the v1.0.0 release line after the stable publication (tag bbc48bc, release commit 6714cc9) and the promotion of ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot to v1.0.0. Record only: docs/golden-baseline.md (GB-4 section) and memory/. No code, hook, test, installer, policy, Risk, trust, tag, release or consumer change; no fix.
Risk: high

## Scope

- docs/golden-baseline.md
- memory/**

## Next

- v1.0.0 release line closed by GB-4 (2026-11-02): tag v1.0.0 bbc48bc6c3e648512c442fe33831fc6ace8bd053 peels to 6714cc9 (stable, Latest; CI 41369614661, exact-SHA attestation, verify 4 passed). Consumers promoted from rc4 without regression, no versioned change: ia-search-jobs d9161369 (high, verify 4 passed, independent), waha-operacional-tm2 c616991 (medium, 3 passed + 1 advisory), affiliate-status-bot 63835300 (medium, 3 passed, receipt 203 reusable_ordinary, no reapprove). Mechanism and trust material byte-identical to rc4.
- This checkpoint changes only docs/golden-baseline.md and memory/. It needs its own CI, exact-SHA attestation and final verify.sh.
- Never move or recreate the tag. No RC5, v1.0.1, consumer, policy or backlog change in this task; post-1.0 work is a new owner task.
- Post-1.0 backlog (GB-4 Accepted Limitations, none blocks the release): dry-run precision, .bak cleanup, global gitignore advisory, ubuntu-26.04, linked worktrees and staged issuance in local authority, doctor.sh and tdd-check.sh resolve from the cwd, Cursor/Windsurf directive budgets, no consolidated rollback procedure, rollback before rc4 doubles Claude handlers, authority reapproval on mechanism change, receipt snapshot includes install-provenance.json (tag promotion makes the previous receipt stale), Stop can issue a receipt at the end of a turn when none applies, an ignored progress.md is validated only when the relevant set changes. Also still deferred: VERIFY_UNAVAILABLE wording, .project-control.toml guidance, cherry-pick UX, verify timeout (CAC verify.sh exceeds its 900 s total budget when run alongside other heavy jobs), githooks NOT active message, provenance SHA line, truncation-check false positive, WAHA deploy margin (consumer), platform and limitations section in the README.

## Blockers

None

## Recently Completed

- Published v1.0.0 (stable, Latest): release commit 6714cc9a90327fb5fccd2f36db8bacc48d6a0222 (Quickstart ref bump only; CI 41369614661, exact-SHA attestation, verify 4 passed), annotated tag bbc48bc6c3e648512c442fe33831fc6ace8bd053; published Quickstart smoke PASS; rolled out to the three consumers without regression.
- CAC-GOLDEN-BASELINE-3 frozen at a36a86f7cdeb3293a972b4354c2255265558d64e on v1.0.0-rc4 (CI 41351043167, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; RC4 cwd blocker closed.
- Published v1.0.0-rc4: Quickstart ref bump 0fdf9a7 (CI 41298577221, exact-SHA attestation, verify 4 passed), annotated tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e peeling to 0fdf9a7, GitHub pre-release from the tag notes; rolled out to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot.
- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153) and C c7b185d done (CI 41279403503), each with exact-SHA attestation; final verify 4 passed.
- CAC-V1.0.0-READINESS (2026-10-31): CAC_V1_0_0_READY=NO, RC4_REQUIRED=YES. Single blocker: Stop resolves policy, state and checks from the session cwd (false PASS of a required check and of Risk high from a subdirectory, Claude and Codex). Install, upgrade, rollback, provenance, doctor, verify and the three GB-2 consumers PASS.
