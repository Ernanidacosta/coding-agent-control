# Progress

## Current

Status: done
Task: Simplify onboarding and capability diagnostics without weakening enforcement.
Risk: medium

## Scope

- README.md
- AGENT.md
- CLAUDE.md
- install.sh
- agent-md.toml.example
- .agent-md/README.md
- .agents/skills/agent-md-verify/**
- .agent-md/bin/doctor.sh
- .agent-md/bin/verify.sh
- .claude/hooks/_lib.sh
- tests/**
- memory/**
- memory/progress.md
- memory/verify.md

## Next

None

## Blockers

None

## Recently Completed

- Reordered README onboarding around Quickstart, basic workflow, and progressive disclosure.
- Made the basic install path independent of config, CI, `gh`, and semantic-memory providers.
- Generalized semantic-memory terminology while retaining ICM compatibility.
- Made doctor report capability timing, effect, blocking status, and recovery.
- Added focused UX regressions without changing Risk or fail-closed semantics.
