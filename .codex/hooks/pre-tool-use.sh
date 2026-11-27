#!/bin/bash
# Codex PreToolUse wrapper. Reuses the Claude Bash safety policy because
# Codex accepts the same permissionDecision deny shape for PreToolUse.
#
# The policy is located next to this wrapper, not through the session's
# working directory: a session outside the worktree must still be checked.

ROOT=$(cd "$(dirname "$0")/../.." && pwd) || exit 1
bash "$ROOT/.claude/hooks/block-destructive.sh"
