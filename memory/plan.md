# Plan

- Formalize one independent verification trust bootstrap procedure in docs/architecture.md; directives and README/provider documentation reference it.
- Distinguish core integrity against HEAD from the provider's first-parent check, owner-approved baseline from attestation, and the trust-changing SHA from a legitimate unchanged descendant.
- Public documentation is accepted and committed; implementation and policy remain unchanged. Owner authorized normal commits and pushes for active -> verifying -> done, with fresh CI and independent verification for every SHA and full verify.sh on the final HEAD. Do not execute a trust bootstrap or start the next roadmap item.
