# Current Plan

## Current Phase

Make the basic agent-md path understandable without weakening advanced
verification, Risk, or attestation guarantees.

## Implementation Slices

1. [x] Fix the fork Quickstart and make install-to-work the first documented
   path with no advanced capability requirement.
2. [x] Generalize semantic-memory language while preserving
   `[integrations.icm]` compatibility as the reference integration.
3. [x] Make doctor and hook messages state current effect, blocking status, and
   recovery before exposing trust details.
4. [x] Run the focused UX regressions and complete verification contract.

## Decisions Still In Force

- Baseline safety, operational state, and declared required checks remain
  standalone and provider-independent.
- Optional capabilities affect only the action or transition that requires
  their guarantee; no silent fallback is introduced.
- Semantic memory is a generic optional capability; ICM remains the compatible
  reference integration under `[integrations.icm]`.
- Advanced trust detail remains available in doctor and structured results,
  while normal messages lead with effect and recovery.

## Deferred / Out of Scope

- Policy profiles, autonomy modes, Risk semantic changes, or decision engines.
- Plugin frameworks, provider orchestration, or new runtime dependencies.
- Renaming `.agent-md`, `agent-md.toml`, or existing public configuration.
- Weakening fail-closed safety, verification, or trust enforcement.

## Open Questions

None.
