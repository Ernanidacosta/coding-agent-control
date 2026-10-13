# Verification

- Owner approved v1.0.0-rc1 readiness at 42499a8f23aedcc0cf6f929677f633745fbf688d: 123/123 focused adoption tests, CI 38314001771, exact-SHA independent verification and final official verify.sh (exit 0, 709.78s). Zero concrete blockers; known limitations accepted.
- Active checkpoint 306c8eb14d80364d6fd9604202e32ed9b7efe971 passed normal hooks (599.67s, 1013 tests), external CI 38337666462 and exact-SHA independent verification. Verifying and done acceptance require their own gates, never this earlier attestation.
- Verifying checkpoint 78a38b485ac8e6c37955e06bb94bcbce99d0fca4 passed normal hooks (599.09s, 1013 tests), CI 38340569473 and exact-SHA independent verification. Done acceptance and tag publication remain conditional on the final checkpoint's own gates and clean synchronized Git.
- Each operational checkpoint must pass normal Git hooks, external CI and the pre-established independent verifier bound to that exact SHA. Validate progress structure, declared transitions and effective high Risk; git diff --check must pass. No bypass or automatic retry after a hook failure.
- Final done HEAD must additionally pass ./.agent-md/bin/verify.sh with clean working tree, empty index and synchronized origin/main. Policy 750/900, implementation, hooks and trust material remain unchanged.
- Publish annotated v1.0.0-rc1 only after those gates, targeting the final done checkpoint. Confirm local tag resolution and remote peeled SHA; never move/recreate the published tag. Release notes belong to the tag annotation.
