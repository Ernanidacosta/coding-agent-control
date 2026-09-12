#!/bin/bash
# install.sh — coding-agent-control installer
#
# Usage:
#   ./install.sh                                    # current dir, auto-detect agents
#   ./install.sh /path/to/project                   # specific target, all agents
#   ./install.sh --agent=claude /path/to/project    # Claude Code only
#   ./install.sh --agent=codex,cursor .             # multiple specific
#   ./install.sh --no-githooks /path/to/project     # skip git-hooks fallback
#   ./install.sh --dry-run .                        # show what would change
#   ./install.sh --no-overwrite .                   # never replace existing files
#   ./install.sh --claude-settings=merge .          # default: idempotent hook merge
#   ./install.sh --claude-settings=replace .        # back up + overwrite
#   ./install.sh --codex-hooks=skip .               # preserve existing .codex/hooks.json unchanged
#
# Or via curl (from inside your project dir):
#   curl -fsSL https://raw.githubusercontent.com/Ernanidacosta/coding-agent-control/main/install.sh | bash
#
# Agents supported: claude, codex, cursor, windsurf, all (default)
#
# Defaults (safe by design):
#   --agent=all
#   --no-overwrite OFF — we WILL replace AGENT.md etc., but always back
#     up the old copy to *.bak first.
#   Claude and Codex hook configs are merged by default. Third-party
#     handlers stay in place; coding-agent-control handlers are refreshed without
#     duplication. Explicit skip and replace modes remain available.
#   memory/ files are never overwritten (user state).
#   .githooks/ (pre-commit + commit-msg) is installed but NOT activated on
#     curl|bash. You get a printed command to activate it manually.
#   .agent/ is auto-added to .gitignore (hook scratch + visual evidence).

set -e

AGENT="all"
TARGET=""
GITHOOKS="ask"
DRY_RUN=0
NO_OVERWRITE=0
CLAUDE_SETTINGS="merge"
CODEX_HOOKS="merge"

for ARG in "$@"; do
  case $ARG in
    --agent=*)     AGENT="${ARG#*=}" ;;
    --githooks)    GITHOOKS="yes" ;;
    --no-githooks) GITHOOKS="no" ;;
    --dry-run)     DRY_RUN=1 ;;
    --no-overwrite) NO_OVERWRITE=1 ;;
    --claude-settings=*) CLAUDE_SETTINGS="${ARG#*=}" ;;
    --codex-hooks=*) CODEX_HOOKS="${ARG#*=}" ;;
    --help|-h)
      sed -n '2,30p' "$0"; exit 0 ;;
    *)
      [ -z "$TARGET" ] && TARGET="$ARG"
      ;;
  esac
done

case "$CLAUDE_SETTINGS" in
  skip|replace|merge) ;;
  *) echo "Error: --claude-settings must be skip|replace|merge (got '$CLAUDE_SETTINGS')"; exit 1 ;;
esac

case "$CODEX_HOOKS" in
  skip|replace|merge) ;;
  *) echo "Error: --codex-hooks must be skip|replace|merge (got '$CODEX_HOOKS')"; exit 1 ;;
esac

TARGET="${TARGET:-.}"

if [ ! -d "$TARGET" ]; then
  echo "Error: target directory does not exist: $TARGET"; exit 1
fi

# Validate agent list early (don't silently skip unknown names)
VALID_AGENTS="claude codex cursor windsurf all auto"
for A in $(echo "$AGENT" | tr ',' ' '); do
  if ! echo " $VALID_AGENTS " | grep -q " $A "; then
    echo "Error: unknown agent '$A'. Valid: $VALID_AGENTS"; exit 1
  fi
done

# Locate source
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"

if [ ! -f "$SCRIPT_DIR/AGENT.md" ]; then
  # Running via curl pipe — download the package
  echo "▸ Downloading coding-agent-control..."
  TMP=$(mktemp -d)
  curl -fsSL https://github.com/Ernanidacosta/coding-agent-control/archive/main.tar.gz | tar -xz -C "$TMP"
  if [ -d "$TMP/coding-agent-control-main" ]; then
    SCRIPT_DIR="$TMP/coding-agent-control-main"
  fi
fi

if [ ! -f "$SCRIPT_DIR/AGENT.md" ]; then
  echo "Error: cannot locate AGENT.md in $SCRIPT_DIR"
  exit 1
fi

if ! command -v jq &>/dev/null; then
  echo "  ! jq not found. Hooks require jq for JSON parsing; install jq before relying on enforcement."
fi

# Shared timing constants keep installer materialization aligned with runtime
# preflight. Sourcing the library defines functions only; it performs no hook
# or verification action.
if [ -f "$SCRIPT_DIR/.claude/hooks/_lib.sh" ]; then
  # shellcheck source=.claude/hooks/_lib.sh
  . "$SCRIPT_DIR/.claude/hooks/_lib.sh"
fi

# Detect curl|bash (stdin not a tty). We use this to keep defaults safe.
NON_INTERACTIVE=0
[ ! -t 0 ] && NON_INTERACTIVE=1

# Resolve which agents to install for
if [ "$AGENT" = "all" ] || [ "$AGENT" = "auto" ]; then
  AGENT_LIST="claude codex cursor windsurf"
else
  AGENT_LIST=$(echo "$AGENT" | tr ',' ' ')
fi

echo "▸ Installing coding-agent-control directives → $TARGET"
echo "▸ Target agents: $AGENT_LIST"
[ "$DRY_RUN" -eq 1 ] && echo "▸ DRY RUN — no files will be changed"
echo ""

# --- Helpers ---
skip_existing() {
  # Return 0 if we should SKIP (file exists and --no-overwrite)
  if [ "$NO_OVERWRITE" -eq 1 ] && [ -e "$1" ]; then
    echo "  · skip (exists)    $(basename "$1")"
    return 0
  fi
  return 1
}

backup_if_exists() {
  [ "$DRY_RUN" -eq 1 ] && return 0
  if [ -f "$1" ] && [ ! -L "$1" ]; then
    # Avoid clobbering an existing *.bak
    local BAK="$1.bak"
    local N=1
    while [ -f "$BAK" ]; do BAK="$1.bak.$N"; N=$((N + 1)); done
    mv "$1" "$BAK"
    echo "  ! backed up $(basename "$1") → $(basename "$BAK")"
  fi
}

copy_file() {
  # src, dst, label
  local src="$1" dst="$2" label="$3"
  skip_existing "$dst" && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  → would write     $label"
    return 0
  fi
  backup_if_exists "$dst"
  cp "$src" "$dst"
  echo "  ✓ $label"
}

copy_with_agent_body() {
  # dst, label, header
  local dst="$1" label="$2" header="$3"
  skip_existing "$dst" && return 0
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  → would write     $label"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  backup_if_exists "$dst"
  {
    printf '%s\n\n' "$header"
    cat "$SCRIPT_DIR/AGENT.md"
  } > "$dst"
  echo "  ✓ $label"
}

merge_hook_config() {
  # src, dst, label, mode. In merge mode, command strings identify the
  # handlers owned by coding-agent-control. Existing copies of those handlers are
  # refreshed; every other top-level key, event, group, and handler is
  # preserved byte-for-byte at the JSON-value level.
  local src="$1" dst="$2" label="$3" mode="$4"

  if [ ! -f "$dst" ]; then
    if [ "$DRY_RUN" -eq 1 ]; then
      echo "  → would write     $label"
    else
      cp "$src" "$dst"
      echo "  ✓ $label"
    fi
    return 0
  fi

  if [ "$NO_OVERWRITE" -eq 1 ]; then
    echo "  · skip (exists)    $label"
    return 0
  fi

  case "$mode" in
    skip)
      echo "  · $label exists — not touched"
      ;;
    replace)
      if [ "$DRY_RUN" -eq 1 ]; then
        echo "  → would back up + replace $label"
      else
        backup_if_exists "$dst"
        cp "$src" "$dst"
        echo "  ✓ $label (replaced, backup kept)"
      fi
      ;;
    merge)
      if ! command -v jq &>/dev/null; then
        echo "  ! jq required to merge $label — existing file left unchanged"
      elif [ "$DRY_RUN" -eq 1 ]; then
        echo "  → would merge     $label (idempotent, third-party hooks preserved)"
      else
        local merged
        merged=$(mktemp)
        if jq -s '
          .[0] as $existing | .[1] as $agent_md |

          def commands($groups):
            [$groups[]?.hooks[]?.command // empty];

          def remove_owned($groups; $owned):
            [$groups[]? |
              . as $group |
              if ($group | has("hooks")) then
                ($group.hooks | map(
                  select((.command // "") as $command |
                    ($owned | index($command)) == null)
                )) as $remaining |
                if ($remaining | length) > 0
                then $group * {hooks: $remaining}
                else empty
                end
              else $group
              end
            ];

          (($existing * ($agent_md | del(.hooks)))) as $result |
          (((($existing.hooks // {}) | keys) +
            (($agent_md.hooks // {}) | keys)) | unique) as $events |
          $result |
          .hooks = reduce $events[] as $event ({};
            (commands($agent_md.hooks[$event] // [])) as $owned |
            .[$event] = (
              remove_owned($existing.hooks[$event] // []; $owned) +
              ($agent_md.hooks[$event] // [])
            )
          )
        ' "$dst" "$src" > "$merged" 2>/dev/null; then
          backup_if_exists "$dst"
          mv "$merged" "$dst"
          echo "  ✓ $label (merged; third-party hooks preserved)"
        else
          rm -f "$merged"
          echo "  ! merge failed for $label — existing file left unchanged"
        fi
      fi
      ;;
  esac
}

INSTALL_COMPLETION_CONTEXT=""
materialize_stop_timeout() {
  # dst, host, mode. Resolve the target once with the same effective core
  # resolver used at runtime, including legacy derived/compatibility budgets.
  local dst="$1" host="$2" mode="$3" total reserve desired needle updated
  [ "$mode" != skip ] || return 0
  [ "$NO_OVERWRITE" -eq 0 ] || return 0
  command -v jq >/dev/null 2>&1 || return 0
  if [ -z "$INSTALL_COMPLETION_CONTEXT" ]; then
    INSTALL_COMPLETION_CONTEXT=$(
      cd "$TARGET" || exit 1
      AGENT_MD_TOML=agent-md.toml completion_evaluation_context_json worktree host
    ) || return 0
  fi
  if ! printf '%s' "$INSTALL_COMPLETION_CONTEXT" | jq -e \
    '.contract.valid and .control.valid and .budget.valid and .budget.bounded' >/dev/null; then
    echo "  ! completion budget is invalid — runtime verification remains fail-closed"
    return 0
  fi
  total=$(printf '%s' "$INSTALL_COMPLETION_CONTEXT" | jq -r '.budget.seconds')
  reserve=$(completion_host_reservation_seconds "$host")
  desired=$((total + reserve))
  case "$host" in
    claude) needle='.claude/hooks/stop-verify.sh' ;;
    codex) needle='.codex/hooks/stop.sh' ;;
    *) return 1 ;;
  esac
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  → would set       ${host} Stop timeout to ${desired}s (${total}s core + ${reserve}s reserved)"
    return 0
  fi
  [ -f "$dst" ] || return 0
  updated=$(mktemp)
  if jq --arg needle "$needle" --argjson desired "$desired" '
    .hooks.Stop |= map(
      .hooks |= map(
        if ((.command // "") | contains($needle)) then .timeout = $desired else . end
      )
    )
  ' "$dst" > "$updated"; then
    mv "$updated" "$dst"
    echo "  ✓ ${host} Stop timeout (${desired}s = ${total}s core + ${reserve}s reserved)"
  else
    rm -f "$updated"
    echo "  ! could not materialize ${host} Stop timeout — runtime preflight will fail closed"
  fi
}

# --- Master file ---
copy_file "$SCRIPT_DIR/AGENT.md" "$TARGET/AGENT.md" "AGENT.md"

# --- Agent-specific instruction files ---
if echo " $AGENT_LIST " | grep -qE " (codex|cursor|windsurf) "; then
  copy_file "$SCRIPT_DIR/AGENT.md" "$TARGET/AGENTS.md" "AGENTS.md        (Codex / Cursor / Windsurf)"
fi

for TOOL in $AGENT_LIST; do
  case "$TOOL" in
    claude)
      copy_file "$SCRIPT_DIR/AGENT.md" "$TARGET/CLAUDE.md" "CLAUDE.md        (Claude Code)"
      ;;
    codex)
      if [ "$DRY_RUN" -eq 0 ]; then
        mkdir -p "$TARGET/.codex/hooks" "$TARGET/.agents/skills"
      fi
      merge_hook_config "$SCRIPT_DIR/.codex/hooks.json" "$TARGET/.codex/hooks.json" ".codex/hooks.json" "$CODEX_HOOKS"
      materialize_stop_timeout "$TARGET/.codex/hooks.json" codex "$CODEX_HOOKS"
      for H in "$SCRIPT_DIR/.codex/hooks/"*.sh; do
        [ -f "$H" ] || continue
        copy_file "$H" "$TARGET/.codex/hooks/$(basename "$H")" ".codex/hooks/$(basename "$H")"
      done
      if [ "$DRY_RUN" -eq 0 ]; then
        chmod +x "$TARGET/.codex/hooks/"*.sh 2>/dev/null || true
      fi

      # Codex wrappers intentionally reuse the host-neutral policies under
      # .claude/hooks. A Codex-only installation still needs those scripts,
      # but does not need or install Claude settings.
      if ! echo " $AGENT_LIST " | grep -q " claude "; then
        [ "$DRY_RUN" -eq 0 ] && mkdir -p "$TARGET/.claude/hooks"
        for H in _lib.sh block-destructive.sh truncation-check.sh \
          stop-verify.sh state-enforcement.sh sensory-reminder.sh; do
          copy_file "$SCRIPT_DIR/.claude/hooks/$H" "$TARGET/.claude/hooks/$H" ".claude/hooks/$H (shared core)"
        done
        if [ "$DRY_RUN" -eq 0 ]; then
          chmod +x "$TARGET/.claude/hooks/"*.sh 2>/dev/null || true
        fi
      fi
      for S in "$SCRIPT_DIR/.agents/skills/"*; do
        [ -d "$S" ] || continue
        SKILL_NAME=$(basename "$S")
        [ "$DRY_RUN" -eq 0 ] && mkdir -p "$TARGET/.agents/skills/$SKILL_NAME"
        for F in "$S"/*; do
          [ -f "$F" ] || continue
          copy_file "$F" "$TARGET/.agents/skills/$SKILL_NAME/$(basename "$F")" ".agents/skills/$SKILL_NAME/$(basename "$F")"
        done
      done
      ;;
    cursor)
      copy_with_agent_body "$TARGET/.cursor/rules/agent-md.mdc" ".cursor/rules/agent-md.mdc (Cursor)" "---"$'\n'"alwaysApply: true"$'\n'"---"
      ;;
    windsurf)
      copy_with_agent_body "$TARGET/.windsurf/rules/agent-md.md" ".windsurf/rules/agent-md.md (Windsurf)" "---"$'\n'"trigger: always_on"$'\n'"---"
      ;;
  esac
done

# --- Claude Code hooks ---
if echo " $AGENT_LIST " | grep -q " claude "; then
  [ "$DRY_RUN" -eq 0 ] && mkdir -p "$TARGET/.claude/hooks"

  # settings.json handling is explicit and non-destructive. Merge is the
  # default so coding-agent-control works on first install without replacing manually
  # wired third-party hooks.
  SETTINGS_SRC="$SCRIPT_DIR/.claude/settings.json"
  SETTINGS_DST="$TARGET/.claude/settings.json"
  if [ -f "$SETTINGS_SRC" ]; then
    merge_hook_config "$SETTINGS_SRC" "$SETTINGS_DST" ".claude/settings.json" "$CLAUDE_SETTINGS"
    materialize_stop_timeout "$SETTINGS_DST" claude "$CLAUDE_SETTINGS"
  fi

  if [ "$DRY_RUN" -eq 0 ]; then
    for H in "$SCRIPT_DIR/.claude/hooks/"*.sh; do
      [ -f "$H" ] || continue
      copy_file "$H" "$TARGET/.claude/hooks/$(basename "$H")" ".claude/hooks/$(basename "$H")"
    done
    chmod +x "$TARGET/.claude/hooks/"*.sh 2>/dev/null || true
    HOOK_COUNT=$(find "$TARGET/.claude/hooks" -maxdepth 1 -name '*.sh' 2>/dev/null | wc -l | tr -d ' ')
    echo "  ✓ .claude/hooks/   (${HOOK_COUNT} hooks)"
  else
    echo "  → would write     .claude/hooks/*.sh"
  fi
fi

# --- Memory system (never overwrite user's state) ---
MEMORY_TEMPLATE_DIR="$SCRIPT_DIR/.agent-md/templates/memory"
if [ ! -d "$MEMORY_TEMPLATE_DIR" ]; then
  # Compatibility for source archives produced before templates were
  # separated from this repository's own operational state.
  MEMORY_TEMPLATE_DIR="$SCRIPT_DIR/memory"
fi
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET/memory"
  for F in agents.md plan.md progress.md verify.md gotchas.md; do
    if [ ! -f "$TARGET/memory/$F" ] && [ -f "$MEMORY_TEMPLATE_DIR/$F" ]; then
      cp "$MEMORY_TEMPLATE_DIR/$F" "$TARGET/memory/$F"
    fi
  done
  echo "  ✓ memory/          (local working state; existing files preserved)"
else
  echo "  → would populate  memory/ (only missing files)"
fi

# Fresh-install working state is private by default. Use the repository-local
# exclude file rather than a committed .gitignore entry: this avoids publishing
# evidence of agent usage and does not affect legacy files already tracked.
if [ "$DRY_RUN" -eq 0 ] && git -C "$TARGET" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
  GIT_DIR=$(git -C "$TARGET" rev-parse --absolute-git-dir 2>/dev/null || true)
  if [ -n "$GIT_DIR" ]; then
    LOCAL_EXCLUDE="$GIT_DIR/info/exclude"
    mkdir -p "$(dirname "$LOCAL_EXCLUDE")"
    LOCAL_MARKER='# local working state added by coding-agent-control'
    if ! grep -qF "$LOCAL_MARKER" "$LOCAL_EXCLUDE" 2>/dev/null; then
      printf '\n%s\n' "$LOCAL_MARKER" >> "$LOCAL_EXCLUDE"
    fi
    for LOCAL_STATE_PATH in /memory/agents.md /memory/plan.md /memory/progress.md /memory/verify.md /memory/gotchas.md; do
      grep -qxF "$LOCAL_STATE_PATH" "$LOCAL_EXCLUDE" 2>/dev/null \
        || printf '%s\n' "$LOCAL_STATE_PATH" >> "$LOCAL_EXCLUDE"
    done
    echo "  ✓ local Git exclude (working memory stays unversioned by default)"
  fi
fi

# --- compatibility helper scripts (.agent-md) ---
if [ "$DRY_RUN" -eq 0 ]; then
  mkdir -p "$TARGET/.agent-md/bin"
  if [ -f "$SCRIPT_DIR/.agent-md/README.md" ]; then
    copy_file "$SCRIPT_DIR/.agent-md/README.md" "$TARGET/.agent-md/README.md" ".agent-md/README.md"
  fi
  for F in "$SCRIPT_DIR/.agent-md/bin/"*; do
    [ -f "$F" ] || continue
    DST="$TARGET/.agent-md/bin/$(basename "$F")"
    copy_file "$F" "$DST" ".agent-md/bin/$(basename "$F")"
  done
  chmod +x "$TARGET/.agent-md/bin/"*.sh 2>/dev/null || true
  echo "  ✓ .agent-md/bin/   (plain helper scripts)"
else
  echo "  → would write     .agent-md/bin/*"
fi

# --- Config template (never overwrite a real agent-md.toml) ---
if [ -f "$SCRIPT_DIR/agent-md.toml.example" ]; then
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  → would write     agent-md.toml.example"
  elif [ ! -f "$TARGET/agent-md.toml" ]; then
    cp "$SCRIPT_DIR/agent-md.toml.example" "$TARGET/agent-md.toml.example"
    echo "  ✓ agent-md.toml.example  (copy to agent-md.toml to declare verify commands)"
  else
    echo "  · agent-md.toml already present — not touched"
  fi
fi

if [ "$DRY_RUN" -eq 1 ]; then
  echo "  → project control  create .project-control.toml explicitly before completion"
elif [ -f "$TARGET/.project-control.toml" ]; then
  echo "  · .project-control.toml already present — not touched"
else
  echo "  · project control not created automatically — declare Risk explicitly before completion"
fi

# --- .gitignore seeding for hook scratch state ---
# Hooks write to .agent/ for scratch state and visual evidence artifacts.
# None of that is source — keep it out of commits.
if [ "$DRY_RUN" -eq 0 ]; then
  GI="$TARGET/.gitignore"
  # shellcheck disable=SC2016
  MARKER='# added by agent-md installer'
  if [ ! -f "$GI" ]; then
    printf '%s\n' "$MARKER" > "$GI"
  elif ! grep -qF "$MARKER" "$GI"; then
    printf '\n%s\n' "$MARKER" >> "$GI"
  fi
  if ! grep -q '^\.agent/$' "$GI"; then
    if [ -f "$GI" ]; then
      printf '.agent/\n' >> "$GI"
    else
      printf '%s\n.agent/\n' "$MARKER" > "$GI"
    fi
    echo "  ✓ .gitignore       (added .agent/)"
  fi
fi

# --- Universal git hook fallback ---
IN_GIT=0
if git -C "$TARGET" rev-parse --is-inside-work-tree &>/dev/null; then IN_GIT=1; fi

if [ "$IN_GIT" -eq 1 ]; then
  if [ "$DRY_RUN" -eq 0 ]; then
    # Cursor/Windsurf rely on the universal pre-commit fallback. Install
    # the shared classifier even when neither Claude nor Codex was chosen.
    if ! echo " $AGENT_LIST " | grep -qE " (claude|codex) "; then
      mkdir -p "$TARGET/.claude/hooks"
      copy_file "$SCRIPT_DIR/.claude/hooks/_lib.sh" "$TARGET/.claude/hooks/_lib.sh" ".claude/hooks/_lib.sh (shared state core)"
      chmod +x "$TARGET/.claude/hooks/_lib.sh"
    fi
    mkdir -p "$TARGET/.githooks"
    for H in pre-commit commit-msg; do
      copy_file "$SCRIPT_DIR/.githooks/$H" "$TARGET/.githooks/$H" ".githooks/$H"
      chmod +x "$TARGET/.githooks/$H"
    done
  fi

  if [ "$GITHOOKS" = "ask" ]; then
    if [ "$NON_INTERACTIVE" -eq 1 ]; then
      # Safe default for curl|bash: do NOT auto-activate repository git hooks.
      GITHOOKS="no"
    else
      printf "▸ Activate .githooks/ now (pre-commit + commit-msg, run on every git commit)? [y/N] "
      read -r REPLY
      REPLY="${REPLY:-N}"
      case "$REPLY" in Y|y|yes|Yes) GITHOOKS="yes" ;; *) GITHOOKS="no" ;; esac
    fi
  fi

  if [ "$GITHOOKS" = "yes" ]; then
    [ "$DRY_RUN" -eq 0 ] && (cd "$TARGET" && git config core.hooksPath .githooks)
    echo "  ✓ .githooks/       (active — core.hooksPath=.githooks)"
  else
    echo "  ✓ .githooks/       (installed, NOT active)"
    echo "    → enable with:   git config core.hooksPath .githooks"
  fi
fi

echo ""
if [ "$DRY_RUN" -eq 1 ]; then
  echo "▸ Dry run complete. No files changed."
else
  echo "▸ Installation complete."
fi
echo ""
echo "Next steps:"
echo "  1. (Recommended) Run: $TARGET/.agent-md/bin/doctor.sh"
echo "  2. Start your agent and work normally — no CI, gh, or memory provider is required"
echo "  3. (Optional) Copy agent-md.toml.example to agent-md.toml when you want explicit project checks"
echo "  4. (Optional) Review $TARGET/AGENT.md before adding project-specific directives"
NEXT_STEP=5
if [ "$IN_GIT" -eq 1 ] && [ "$GITHOOKS" = "no" ]; then
  echo "  ${NEXT_STEP}. (Optional) Enable universal hooks: git config core.hooksPath .githooks"
  NEXT_STEP=$((NEXT_STEP + 1))
fi
if echo " $AGENT_LIST " | grep -q " codex "; then
  echo "  ${NEXT_STEP}. (Codex) Confirm hook support with: codex features list"
fi
