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
#   ./install.sh --no-overwrite .                   # create what is missing, never replace
#   ./install.sh --claude-settings=merge .          # default: idempotent hook merge
#   ./install.sh --claude-settings=replace .        # back up + overwrite
#   ./install.sh --codex-hooks=skip .               # leave an existing .codex/hooks.json unchanged
#
# Or via curl (from inside your project dir):
#   curl -fsSL https://raw.githubusercontent.com/Ernanidacosta/coding-agent-control/main/install.sh | bash
#
# Agents supported: claude, codex, cursor, windsurf, all (default)
#
# Defaults (safe by design):
#   --agent=all
#   --no-overwrite OFF — we WILL replace AGENT.md etc., backing up the old
#     copy to *.bak first. A file that already matches is left untouched, so
#     reinstalling does not pile up redundant backups.
#   The source package is the directory of this script when it is run from a
#     real file that carries the package markers; piped execution (curl|bash)
#     always fetches the official archive instead of reusing the target.
#   Claude and Codex hook configs are merged by default. Third-party
#     handlers stay in place; coding-agent-control handlers are refreshed without
#     duplication. Explicit skip and replace modes remain available.
#   skip, replace and --no-overwrite all decide what happens to a host config
#     that ALREADY EXISTS. On a target that has none, the file is created
#     complete either way, carrying this project's effective Stop timeout.
#     Whenever one of those choices stops the installer from writing, it says
#     so and reports any Stop envelope it therefore could not synchronize.
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

# --- Locate source package ---
# An already-installed project also carries AGENT.md, so the presence of
# AGENT.md never proves a directory is the installer's source package. Identity
# is decided by the files only the package ships, and the package directory is
# adopted only when this script is running from a real file inside it. Piped
# execution (curl | bash) has no source file, so it always fetches the archive
# instead of mistaking the target project for the package.
SOURCE_ARCHIVE_URL="${CODING_AGENT_CONTROL_SOURCE_URL:-https://github.com/Ernanidacosta/coding-agent-control/archive/main.tar.gz}"
SOURCE_ARCHIVE_FILE="${CODING_AGENT_CONTROL_SOURCE_ARCHIVE:-}"
PACKAGE_MARKERS="install.sh AGENT.md .claude/hooks/_lib.sh .agent-md/bin/doctor.sh agent-md.toml.example"

is_source_package() {
  local dir="$1" marker
  [ -n "$dir" ] && [ -d "$dir" ] || return 1
  for marker in $PACKAGE_MARKERS; do
    [ -f "$dir/$marker" ] || return 1
  done
  return 0
}

INSTALL_TMPDIR=""
INSTALL_HOOK_CANDIDATE=""
cleanup_install_tmpdir() {
  # Only ever removes a directory this script created with mktemp -d, and
  # leaves the caller's exit status untouched.
  if [ -n "$INSTALL_HOOK_CANDIDATE" ] && [ -f "$INSTALL_HOOK_CANDIDATE" ]; then
    rm -f "$INSTALL_HOOK_CANDIDATE"
  fi
  if [ -n "$INSTALL_TMPDIR" ] && [ -d "$INSTALL_TMPDIR" ]; then
    rm -rf "$INSTALL_TMPDIR"
  fi
}
trap cleanup_install_tmpdir EXIT

fetch_source_package() {
  # Assigns SCRIPT_DIR directly. Returning the path on stdout would mix it with
  # the progress lines printed here.
  local archive extracted dir
  command -v tar >/dev/null 2>&1 || { echo "Error: tar is required to unpack the source package"; exit 1; }
  INSTALL_TMPDIR=$(mktemp -d) || { echo "Error: cannot create a temporary directory for the source package"; exit 1; }
  if [ -n "$SOURCE_ARCHIVE_FILE" ]; then
    [ -f "$SOURCE_ARCHIVE_FILE" ] || { echo "Error: source archive not found: $SOURCE_ARCHIVE_FILE"; exit 1; }
    echo "▸ Unpacking coding-agent-control source archive..."
    archive="$SOURCE_ARCHIVE_FILE"
  else
    command -v curl >/dev/null 2>&1 || { echo "Error: curl is required to download the source package"; exit 1; }
    echo "▸ Downloading coding-agent-control..."
    archive="$INSTALL_TMPDIR/package.tar.gz"
    # Download to a file rather than piping into tar: a piped curl failure is
    # hidden behind tar's exit status.
    curl -fsSL "$SOURCE_ARCHIVE_URL" -o "$archive" \
      || { echo "Error: cannot download or unpack $SOURCE_ARCHIVE_URL"; exit 1; }
  fi
  tar -xzf "$archive" -C "$INSTALL_TMPDIR" \
    || { echo "Error: cannot unpack the coding-agent-control source archive"; exit 1; }
  extracted=""
  if is_source_package "$INSTALL_TMPDIR"; then
    extracted="$INSTALL_TMPDIR"
  else
    for dir in "$INSTALL_TMPDIR"/*; do
      if is_source_package "$dir"; then extracted="$dir"; break; fi
    done
  fi
  [ -n "$extracted" ] || { echo "Error: the fetched archive is not a complete coding-agent-control package"; exit 1; }
  SCRIPT_DIR="$extracted"
}

SCRIPT_DIR=""
INSTALL_SOURCE_MODE="package"
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
  if SCRIPT_CANDIDATE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd 2>/dev/null)"; then
    :
  else
    SCRIPT_CANDIDATE=""
  fi
  if is_source_package "$SCRIPT_CANDIDATE"; then
    SCRIPT_DIR="$SCRIPT_CANDIDATE"
  fi
fi

if [ -z "$SCRIPT_DIR" ]; then
  INSTALL_SOURCE_MODE="archive"
  fetch_source_package
fi

if ! is_source_package "$SCRIPT_DIR"; then
  echo "Error: cannot locate a complete coding-agent-control source package in $SCRIPT_DIR"
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
  # shellcheck disable=SC1091
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
if [ "$INSTALL_SOURCE_MODE" = archive ]; then
  echo "▸ Source: fetched package archive"
else
  echo "▸ Source: $SCRIPT_DIR"
fi
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

# Same-file guard. `-ef` compares device and inode, so it recognizes an
# identical file reached through a different path, a symlink, or a hard link.
# Backing up a destination that IS the source would move the source away and
# leave nothing to copy, so every writer consults this first.
same_file() {
  [ -e "$1" ] && [ -e "$2" ] && [ "$1" -ef "$2" ]
}

report_same_file() {
  echo "  · already current  $1 (source is the target file)"
}

copy_file() {
  # src, dst, label
  local src="$1" dst="$2" label="$3"
  skip_existing "$dst" && return 0
  if same_file "$src" "$dst"; then
    report_same_file "$label"
    return 0
  fi
  if [ ! -f "$src" ]; then
    echo "Error: installer source file is missing: $src"
    exit 1
  fi
  # Reinstalling an unchanged file must not manufacture another backup.
  if [ -f "$dst" ] && cmp -s "$src" "$dst"; then
    echo "  · already current  $label"
    return 0
  fi
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
  local dst="$1" label="$2" header="$3" body="$SCRIPT_DIR/AGENT.md" staged mode_bits
  skip_existing "$dst" && return 0
  if same_file "$body" "$dst"; then
    report_same_file "$label"
    return 0
  fi
  if [ "$DRY_RUN" -eq 1 ]; then
    echo "  → would write     $label"
    return 0
  fi
  mkdir -p "$(dirname "$dst")"
  # Compose into a temporary file first: a redirection straight onto $dst would
  # truncate it before AGENT.md is read if the two ever resolved to one file.
  staged=$(mktemp)
  {
    printf '%s\n\n' "$header"
    cat "$body"
  } > "$staged"
  if [ -f "$dst" ] && cmp -s "$staged" "$dst"; then
    rm -f "$staged"
    echo "  · already current  $label"
    return 0
  fi
  # New local rules remain private; replacing an existing regular file keeps
  # the mode its owner chose, just like the hook transport configurations.
  if [ -f "$dst" ] && [ ! -L "$dst" ]; then
    mode_bits=$(stat -c '%a' "$dst" 2>/dev/null || stat -f '%Lp' "$dst" 2>/dev/null) \
      || { rm -f "$staged"; echo "Error: cannot read mode of $dst" >&2; exit 1; }
    chmod "$mode_bits" "$staged" \
      || { rm -f "$staged"; echo "Error: cannot preserve mode of $dst" >&2; exit 1; }
  fi
  backup_if_exists "$dst"
  mv "$staged" "$dst"
  echo "  ✓ $label"
}

# --- Hook transport configuration ---
#
# Claude settings.json and Codex hooks.json are installed through a staged
# candidate. The candidate is resolved completely — merged with what is already
# installed, then materialized with the target's effective Stop envelope —
# before the installed file is read for comparison or moved aside.
#
# The order matters. Merging straight onto the target imports the *package's*
# Stop timeout, which materialization then has to recompute from the *target's*
# completion budget. Comparing the post-merge file against the target therefore
# always differed, so every reinstall took a backup, wrote the package
# envelope, and recomputed the target envelope right back: one new .bak per run
# holding byte-identical content. Resolving the candidate first makes the
# comparison answer the only question worth asking — does the effective result
# change?

hook_config_merge() {
  # existing, package, out. Command strings identify the handlers owned by
  # coding-agent-control. Existing copies of those handlers are refreshed; every
  # other top-level key, event, group, and handler is preserved byte-for-byte
  # at the JSON-value level.
  local existing="$1" package="$2" out="$3"
  jq -s '
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
  ' "$existing" "$package" > "$out" 2>/dev/null
}

hook_config_equivalent() {
  # Object key order carries no meaning in these configs; handler array order
  # does, and `jq -S` sorts keys while leaving arrays alone. Canonicalizing for
  # the comparison only keeps the persisted file in its authored order, so a
  # pure reordering never manufactures a backup and a real edit always does.
  # A file that will not parse is never declared equivalent.
  local a="$1" b="$2" canonical_a canonical_b
  [ -f "$a" ] && [ -f "$b" ] || return 1
  cmp -s "$a" "$b" && return 0
  canonical_a=$(jq -S . "$a" 2>/dev/null) || return 1
  canonical_b=$(jq -S . "$b" 2>/dev/null) || return 1
  [ "$canonical_a" = "$canonical_b" ]
}

INSTALL_COMPLETION_CONTEXT=""
INSTALL_COMPLETION_CONTEXT_STATE=""

install_completion_budget_seconds() {
  # Resolve the target's effective completion budget once per run with the same
  # core resolver used at runtime, including legacy derived and explicit total
  # budgets. Both the value and the reason it is unavailable are cached so each
  # host reports one consistent diagnosis.
  if [ -z "$INSTALL_COMPLETION_CONTEXT_STATE" ]; then
    if ! command -v completion_evaluation_context_json >/dev/null 2>&1; then
      INSTALL_COMPLETION_CONTEXT_STATE=missing
    elif ! INSTALL_COMPLETION_CONTEXT=$(
      cd "$TARGET" || exit 1
      AGENT_MD_TOML=agent-md.toml completion_evaluation_context_json worktree host
    ); then
      INSTALL_COMPLETION_CONTEXT_STATE=unresolved
    elif ! printf '%s' "$INSTALL_COMPLETION_CONTEXT" | jq -e \
      '.contract.valid and .control.valid and .budget.valid and .budget.bounded' >/dev/null; then
      INSTALL_COMPLETION_CONTEXT_STATE=invalid
    else
      INSTALL_COMPLETION_CONTEXT_STATE=ok
    fi
  fi
  [ "$INSTALL_COMPLETION_CONTEXT_STATE" = ok ] || return 1
  printf '%s' "$INSTALL_COMPLETION_CONTEXT" | jq -r '.budget.seconds'
}

INSTALL_STOP_ENVELOPE_NOTE=""
materialize_stop_timeout() {
  # candidate, host. Rewrites the staged candidate so the Stop handler carries
  # the envelope this target resolves to. The package ships its own envelope;
  # leaving it in place would install one project's budget into another.
  # Failure leaves the candidate as it is and is reported, never silently
  # downgraded.
  local candidate="$1" host="$2" total reserve desired needle updated
  INSTALL_STOP_ENVELOPE_NOTE=""
  case "$host" in
    claude) needle='.claude/hooks/stop-verify.sh' ;;
    codex) needle='.codex/hooks/stop.sh' ;;
    *) return 1 ;;
  esac
  command -v jq >/dev/null 2>&1 || return 0
  if ! total=$(install_completion_budget_seconds); then
    case "$INSTALL_COMPLETION_CONTEXT_STATE" in
      missing)
        echo "  ! shared budget resolver unavailable — ${host} Stop timeout left unchanged" ;;
      invalid)
        echo "  ! completion budget is invalid — runtime verification remains fail-closed" ;;
    esac
    return 0
  fi
  reserve=$(completion_host_reservation_seconds "$host")
  desired=$((total + reserve))
  updated=$(mktemp)
  if jq --arg needle "$needle" --argjson desired "$desired" '
    .hooks.Stop |= map(
      .hooks |= map(
        if ((.command // "") | contains($needle)) then .timeout = $desired else . end
      )
    )
  ' "$candidate" > "$updated"; then
    mv "$updated" "$candidate"
    INSTALL_STOP_ENVELOPE_NOTE="${host} Stop timeout (${desired}s = ${total}s core + ${reserve}s reserved)"
  else
    rm -f "$updated"
    echo "  ! could not materialize ${host} Stop timeout — runtime preflight will fail closed"
  fi
  return 0
}

warn_unsynchronized_envelope() {
  # host. Called when a user policy told the installer to leave an existing
  # host config alone. Declining to write also means declining to synchronize
  # the Stop envelope, and staying quiet would let the run read as "installed
  # and compatible" when the installer never made it so. Only a real mismatch
  # is reported; an envelope that already matches stays silent.
  local host="$1" total reserve desired installed
  command -v jq >/dev/null 2>&1 || return 0
  total=$(install_completion_budget_seconds) || return 0
  reserve=$(completion_host_reservation_seconds "$host")
  desired=$((total + reserve))
  installed=$(completion_host_timeout_seconds "$host" "$TARGET" 2>/dev/null) || installed=""
  if [ -z "$installed" ]; then
    echo "    ! ${host} Stop timeout not synchronized by your policy — this project needs ${desired}s and none is resolvable"
  elif [ "$installed" -ne "$desired" ]; then
    echo "    ! ${host} Stop timeout not synchronized by your policy — installed ${installed}s, this project needs ${desired}s"
  fi
}

install_hook_config() {
  # src, dst, label, mode, host.
  local src="$1" dst="$2" label="$3" mode="$4" host="$5"
  local candidate outcome mode_bits

  if same_file "$src" "$dst"; then
    report_same_file "$label"
    return 0
  fi
  if [ ! -f "$src" ]; then
    echo "Error: installer source file is missing: $src"
    exit 1
  fi

  # Stage beside the destination so the final mv is a same-filesystem rename
  # and the target is never left partially written. A dry run may reach here
  # before the directory exists, and never moves anything, so it falls back to
  # the ordinary temp area.
  if [ -d "$(dirname "$dst")" ]; then
    candidate=$(mktemp "$(dirname "$dst")/.$(basename "$dst").install.XXXXXX")
  else
    candidate=$(mktemp)
  fi
  INSTALL_HOOK_CANDIDATE="$candidate"
  if [ ! -f "$dst" ]; then
    # Nothing installed yet, so there is nothing for skip or --no-overwrite to
    # protect: both govern replacing a file that already exists. The package
    # file is the candidate and it is finished like any other write, because a
    # config created half-configured is not what either flag asks for.
    cp "$src" "$candidate"
    outcome=""
  else
    if [ "$NO_OVERWRITE" -eq 1 ]; then
      rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
      echo "  · skip (exists)    $label"
      warn_unsynchronized_envelope "$host"
      return 0
    fi
    case "$mode" in
      skip)
        rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
        echo "  · $label exists — not touched"
        warn_unsynchronized_envelope "$host"
        return 0
        ;;
      replace)
        cp "$src" "$candidate"
        outcome="replaced, backup kept"
        ;;
      merge)
        if ! command -v jq >/dev/null 2>&1; then
          rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
          echo "  ! jq required to merge $label — existing file left unchanged"
          return 0
        fi
        if ! hook_config_merge "$dst" "$src" "$candidate"; then
          rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
          echo "  ! merge failed for $label — existing file left unchanged"
          return 0
        fi
        outcome="merged; third-party hooks preserved"
        ;;
    esac
  fi

  materialize_stop_timeout "$candidate" "$host"

  if hook_config_equivalent "$candidate" "$dst"; then
    rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
    echo "  · already current  $label"
    [ -z "$INSTALL_STOP_ENVELOPE_NOTE" ] || echo "  · $INSTALL_STOP_ENVELOPE_NOTE"
    return 0
  fi

  if [ "$DRY_RUN" -eq 1 ]; then
    rm -f "$candidate"
    INSTALL_HOOK_CANDIDATE=""
    if [ -z "$outcome" ]; then
      echo "  → would write     $label"
    else
      echo "  → would write     $label ($outcome)"
    fi
    [ -z "$INSTALL_STOP_ENVELOPE_NOTE" ] || echo "  → would set       $INSTALL_STOP_ENVELOPE_NOTE"
    return 0
  fi

  # mktemp creates the candidate 0600. Every other installed file arrives
  # through cp, which follows the umask, so an existing file keeps the mode the
  # project gave it and a new one gets the ordinary default instead of
  # inheriting a mode private to whoever ran the installer.
  if [ -f "$dst" ]; then
    mode_bits=$(stat -c '%a' "$dst" 2>/dev/null || stat -f '%Lp' "$dst" 2>/dev/null || echo "")
  else
    mode_bits=$(printf '%o' "$((0666 & ~0$(umask)))")
  fi
  [ -z "$mode_bits" ] || chmod "$mode_bits" "$candidate"
  backup_if_exists "$dst"
  mv "$candidate" "$dst"
  INSTALL_HOOK_CANDIDATE=""
  if [ -z "$outcome" ]; then
    echo "  ✓ $label"
  else
    echo "  ✓ $label ($outcome)"
  fi
  [ -z "$INSTALL_STOP_ENVELOPE_NOTE" ] || echo "  ✓ $INSTALL_STOP_ENVELOPE_NOTE"
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
      install_hook_config "$SCRIPT_DIR/.codex/hooks.json" "$TARGET/.codex/hooks.json" ".codex/hooks.json" "$CODEX_HOOKS" codex
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
    install_hook_config "$SETTINGS_SRC" "$SETTINGS_DST" ".claude/settings.json" "$CLAUDE_SETTINGS" claude
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
    if [ ! -f "$TARGET/memory/$F" ] && [ -f "$MEMORY_TEMPLATE_DIR/$F" ] \
      && ! same_file "$MEMORY_TEMPLATE_DIR/$F" "$TARGET/memory/$F"; then
      cp "$MEMORY_TEMPLATE_DIR/$F" "$TARGET/memory/$F"
    fi
  done
  echo "  ✓ memory/          (local working state; existing files preserved)"
else
  echo "  → would populate  memory/ (only missing files)"
fi

# Local working state and host wiring stay untracked by default. Git's local
# exclude never hides paths already in the index from Phase A source identity.
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
    LOCAL_MARKER='# local host wiring added by coding-agent-control'
    if ! grep -qF "$LOCAL_MARKER" "$LOCAL_EXCLUDE" 2>/dev/null; then
      printf '%s\n' "$LOCAL_MARKER" >> "$LOCAL_EXCLUDE"
    fi
    for LOCAL_STATE_PATH in \
      '/.claude/settings.json' '/.claude/settings.json.bak*' \
      '/.codex/hooks.json' '/.codex/hooks.json.bak*' \
      '/.cursor/rules/agent-md.mdc' '/.cursor/rules/agent-md.mdc.bak*' \
      '/.windsurf/rules/agent-md.md' '/.windsurf/rules/agent-md.md.bak*'; do
      grep -qxF "$LOCAL_STATE_PATH" "$LOCAL_EXCLUDE" 2>/dev/null \
        || printf '%s\n' "$LOCAL_STATE_PATH" >> "$LOCAL_EXCLUDE"
    done
    echo "  ✓ local Git exclude (working memory and host wiring stay unversioned by default)"
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
    if same_file "$SCRIPT_DIR/agent-md.toml.example" "$TARGET/agent-md.toml.example"; then
      report_same_file "agent-md.toml.example"
    else
      cp "$SCRIPT_DIR/agent-md.toml.example" "$TARGET/agent-md.toml.example"
      echo "  ✓ agent-md.toml.example  (copy to agent-md.toml to declare verify commands)"
    fi
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
