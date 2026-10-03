# Plan

- Formalize one owner-controlled administrative policy bootstrap procedure in docs/architecture.md; existing directives and README point to it.
- Bind the single commit exception to the previous HEAD, exact approved diff and owner authorization; preserve all normal post-establishment gates and external authority requirements.
- Public documentation is accepted and committed; no implementation, policy values, hooks or tests changed. Owner authorized normal commits and pushes for active -> verifying -> done, with fresh CI and independent verification for every SHA and full verify.sh on the final HEAD. Do not execute an administrative exception or start the next task.
