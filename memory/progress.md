# Progress

## Current

Status: verifying
Task: CAC-POST-1.0-SIMPLICITY-GUARDRAILS: add advisory simplicity and design guardrails (simplicity ladder, root cause first, simplicity review, ceiling and revisit trigger, benchmark before optimizing) to AGENT.md section 6, subordinate to Risk, verification, completion, safety, trust and approval; consolidate duplicate directive text to stay within the 30720-byte budget; mirror aliases; one-line README summaries; directives test. No Ponytail dependency, mechanism, trust, policy, Risk, tag, release or consumer change. Branch feat/post-1.0-simplicity-guardrails from bda5c0b (GB-4 untouched).
Risk: high

## Scope

- AGENT.md
- CLAUDE.md
- README.md
- README.pt-BR.md
- tests/directives.bats
- memory/**

## Next

- Implementation ready: verify.sh on the changed tree 2026-11-02 PASS (lint, test, smoke; 11m48s alone). Commit on the feature branch, then CI on the branch (pull_request trigger) and exact-SHA independent attestation before done. Push or PR is an owner decision.
- Baseline verify.sh at bda5c0b on 2026-11-02: lint and smoke pass, required test hit VERIFY_TIMEOUT at 750 s (known deferred verify-timeout item); untimed baseline suite 1112 ok, 0 failures in 821 s while a Stop-hook suite ran concurrently, so the timeout was load, not a failure.
- After PASS: CAC-POST-1.0-PERFORMANCE-BASELINE (not started here).
- Post-1.0 backlog unchanged from GB-4 (see docs/golden-baseline.md Accepted Limitations and the deferred list there).

## Blockers

None

## Recently Completed

- CAC-GOLDEN-BASELINE-4 frozen at bda5c0b4d3dc582f57a88af0099d952a804dbd5f on v1.0.0 (tag bbc48bc peels to 6714cc9); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; v1.0.0 line closed.
- Published v1.0.0 (stable, Latest): release commit 6714cc9a90327fb5fccd2f36db8bacc48d6a0222 (Quickstart ref bump only; CI 41369614661, exact-SHA attestation, verify 4 passed), annotated tag bbc48bc6c3e648512c442fe33831fc6ace8bd053; published Quickstart smoke PASS; rolled out to the three consumers without regression.
- CAC-GOLDEN-BASELINE-3 frozen at a36a86f7cdeb3293a972b4354c2255265558d64e on v1.0.0-rc4 (CI 41351043167, exact-SHA attestation, verify 4 passed); consumers ia-search-jobs d916136, waha-operacional-tm2 c616991, affiliate-status-bot 6383530; RC4 cwd blocker closed.
- Published v1.0.0-rc4: Quickstart ref bump 0fdf9a7 (CI 41298577221, exact-SHA attestation, verify 4 passed), annotated tag 9c82227c57f0ff4c756d3637c2c2278e7886ce6e peeling to 0fdf9a7, GitHub pre-release from the tag notes; rolled out to ia-search-jobs, waha-operacional-tm2 and affiliate-status-bot.
- CAC-V1.0.0-RC4 implementation: completion hooks evaluate from the root of the Git worktree that owns them (no false PASS or false BLOCK from a subdirectory, Claude and Codex; non-Git blocks with VERIFY_UNAVAILABLE) and Claude hook commands quote $CLAUDE_PROJECT_DIR (installer replaces the legacy spelling). A 2379a1a owner-approved (diagnostic CI 41275596309), B 16a982b verifying (CI 41277806153) and C c7b185d done (CI 41279403503), each with exact-SHA attestation; final verify 4 passed.
