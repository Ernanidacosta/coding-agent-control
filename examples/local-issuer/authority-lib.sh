#!/bin/bash
# authority-lib.sh — shared implementation for the enrollment authority and the
# issuer runtime.
#
# Everything here treats a workspace as hostile input: files are resolved,
# stat-ed, read as data and hashed, never sourced, imported or executed, and
# git is never invoked inside a workspace.
#
# This file is installed alongside the programs that source it. When it runs
# from the installed location it is root-owned and not writable by the
# developer, which is what makes its verdicts meaningful; the copy in the
# repository is the distribution source.

# Constants and helpers below are consumed by the programs that source this
# file, so standalone linting cannot see their use sites. Older shellcheck
# reports the same situation as unreachable code (SC2317) and newer releases as
# an uninvoked function (SC2329); both are the same false positive.
# shellcheck disable=SC2034,SC2317,SC2329

AUTHORITY_SCHEMA=7
AUTHORITY_DEFAULT_EXEC_PATH=/usr/local/bin:/usr/bin:/bin
AUTHORITY_MECHANISM_FILES=".claude/hooks/_lib.sh .claude/hooks/stop-verify.sh .agent-md/bin/verify.sh"
AUTHORITY_ORDINARY_CHECKS="typecheck lint test integration smoke runtime"
# Execution order. This is verification_check_names order, which is what the
# core produces from a single configuration. The core's completion path merges
# a Git baseline with a worktree proposal and that merge reorders the result;
# the authority has one approved contract and no merge, so it follows the
# canonical order rather than reproducing a merge artefact. Order affects
# diagnostics only: every applicable check runs.
AUTHORITY_CHECK_ORDER="typecheck lint test integration smoke runtime"
AUTHORITY_LEGACY_OVERHEAD_SECONDS=30
AUTHORITY_CONDITIONAL_CHECKS="independent approval"
AUTHORITY_SERVICE_USER=agentmd
AUTHORITY_RUNNER_USER=agentmd-runner
AUTHORITY_REQUIRED_TOOLS="bash timeout env"
AUTHORITY_SCRATCH_ROOT=/var/tmp/agent-md-runner
AUTHORITY_TIMEOUT_GRACE_SECONDS=5

ROOT=""

die() { printf '%s: %s\n' "${PROGRAM:-agent-md-authority}" "$1" >&2; exit "${2:-1}"; }
note() { printf '%s\n' "$1"; }

lib_dir()      { printf '%s/usr/local/lib/agent-md' "$ROOT"; }
state_dir()    { printf '%s/var/lib/agent-md' "$ROOT"; }
projects_dir() { printf '%s/projects' "$(state_dir)"; }
keys_dir()     { printf '%s/keys' "$(state_dir)"; }
is_real_root_prefix() { [ -z "$ROOT" ]; }

path_has_symlink() {
  local p="$1"
  while [ -n "$p" ] && [ "$p" != "/" ] && [ "$p" != "." ]; do
    if [ -L "$p" ]; then return 0; fi
    p=$(dirname "$p")
  done
  return 1
}

mode_of() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null; }
owner_of() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }
group_of() { stat -c %g "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null; }

digit_has_write() { case "$1" in 2|3|6|7) return 0 ;; esac; return 1; }

world_writable() {
  local mode
  mode=$(mode_of "$1") || return 1
  digit_has_write "${mode: -1}"
}

assert_safe_dir() {
  local dir="$1"
  [ -e "$dir" ] || return 0
  if path_has_symlink "$dir"; then
    die "refusing to use '$dir': a path component is a symlink"
  fi
  if [ ! -d "$dir" ]; then
    die "refusing to use '$dir': it exists and is not a directory"
  fi
  if world_writable "$dir"; then
    die "refusing to use '$dir': it is world-writable"
  fi
}

atomic_write() {
  local target="$1" mode="$2" dir tmp
  dir=$(dirname "$target")
  tmp=$(mktemp "$dir/.agent-md-authority.XXXXXX") || die "cannot create temporary file in $dir"
  cat > "$tmp" || { rm -f "$tmp"; die "cannot write $target"; }
  chmod "$mode" "$tmp" || { rm -f "$tmp"; die "cannot set mode on $target"; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; die "cannot replace $target"; }
}

sha256_file() {
  local out
  if command -v sha256sum >/dev/null 2>&1; then
    out=$(sha256sum < "$1") || return 1
    printf '%s' "${out%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    out=$(shasum -a 256 < "$1") || return 1
    printf '%s' "${out%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    out=$(openssl dgst -sha256 < "$1") || return 1
    printf '%s' "${out##* }"
  else
    return 127
  fi
}

sha256_hex() {
  local tmp out
  tmp=$(mktemp) || return 1
  cat > "$tmp"
  out=$(sha256_file "$tmp"); rm -f "$tmp"
  printf '%s' "$out"
}

json_string() {
  printf '%s' "$1" | jq -Rs .
}

passwd_field() {
  local user="$1" field="$2" line
  line=$(getent passwd "$user" 2>/dev/null) || return 1
  printf '%s' "$line" | cut -d: -f"$field"
}

uid_of_user() { passwd_field "$1" 3; }
home_of_user() { passwd_field "$1" 6; }
gids_of_user() { id -G "$1" 2>/dev/null; }

# Root can probe both runtime principals without granting either more sudo
# capability. An unprivileged authority can only probe its own live access.
authority_workspace_traversal_reasons() {
  local workspace="$1" caller_uid user reason reasons='[]'
  is_real_root_prefix || { printf '[]'; return 0; }
  caller_uid=$(id -u)
  for user in "$AUTHORITY_SERVICE_USER" "$AUTHORITY_RUNNER_USER"; do
    reason=""
    if [ "$caller_uid" = 0 ]; then
      if ! command -v runuser >/dev/null 2>&1; then
        reason="cannot validate workspace traversal as $user: runuser is unavailable"
      elif ! runuser -u "$user" -- /usr/bin/test -x "$workspace" 2>/dev/null; then
        reason="$user cannot traverse workspace $workspace or its parent directories"
      fi
    elif [ "$caller_uid" = "$(uid_of_user "$user")" ]; then
      [ -x "$workspace" ] \
        || reason="$user cannot traverse workspace $workspace or its parent directories"
    else
      continue
    fi
    if [ -n "$reason" ]; then
      reasons=$(jq -c --arg reason "$reason" '. + [$reason]' <<<"$reasons")
    fi
  done
  printf '%s' "$reasons"
}

# A production root can ask the real runner for the same Phase A source view
# used by identity. A direct service enrollment can only prove its own view;
# it does not gain a new sudo capability to impersonate the runner.
authority_workspace_source_reasons() {
  local workspace="$1" source_file user="$AUTHORITY_RUNNER_USER" reasons result
  is_real_root_prefix || { printf '[]'; return 0; }
  source_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-enroll-source.XXXXXX") || return 1
  if [ "$(id -u)" = 0 ]; then
    # shellcheck disable=SC2016 # The child shell receives these as positional arguments.
    if ! command -v runuser >/dev/null 2>&1 ||
      ! runuser -u "$user" -- /bin/bash -c '
        . "$1"; . "$2"
        cd "$3" || exit 1
        authority_export_git_workspace_env "$3"
        authority_pa_verification_receipt_source_manifest_json worktree
      ' _ "$(lib_dir)/authority-lib.sh" "$(lib_dir)/phase-a-source.sh" "$workspace" \
        > "$source_file" 2>/dev/null; then
      rm -f "$source_file"
      return 1
    fi
  else
    user=$(id -un)
    if ! ( cd "$workspace" && authority_export_git_workspace_env "$workspace" &&
      authority_pa_verification_receipt_source_manifest_json worktree ) \
        > "$source_file" 2>/dev/null; then
      rm -f "$source_file"
      return 1
    fi
  fi
  if ! jq -e -s 'length == 1 and (.[0] | type) == "object" and
    (.[0].valid | type) == "boolean"' "$source_file" >/dev/null 2>&1; then
    rm -f "$source_file"
    return 1
  fi
  reasons=$(jq -c --arg user "$user" '
    [.entries[]? | select(.valid != true) |
      "\($user) cannot use source path \(.path): \(.worktree.error // .index.error // .error // "unusable source entry")"] as $bad
    | if .valid == true then []
      elif ($bad | length) == 0 then
        ["\($user) cannot compute source identity: \(.error // "unusable source manifest")"]
      else $bad[:8] + (if ($bad | length) > 8
        then ["\($user) has \(($bad | length) - 8) more unusable source paths"]
        else [] end)
      end' "$source_file")
  result=$?
  rm -f "$source_file"
  [ "$result" -eq 0 ] || return "$result"
  printf '%s' "$reasons"
}

# --- PATH eligibility --------------------------------------------------------
# A PATH entry the execution user can write is a way to replace a real tool with
# one that exits 0, collect an authenticated PASS and put the real tool back.
# The source fingerprint would not notice, because the directory is outside the
# repository. For the first provider this is disqualifying, not advisory.

dir_writable_by_user() {
  local dir="$1" uid="$2" gids="$3" owner group mode ugo gid
  owner=$(owner_of "$dir") || return 2
  group=$(group_of "$dir") || return 2
  mode=$(mode_of "$dir") || return 2
  ugo=${mode: -3}
  if digit_has_write "${ugo:2:1}"; then return 0; fi
  if [ "$owner" = "$uid" ] && digit_has_write "${ugo:0:1}"; then return 0; fi
  if digit_has_write "${ugo:1:1}"; then
    for gid in $gids; do
      [ "$gid" = "$group" ] && return 0
    done
  fi
  return 1
}

path_entry_report() {
  local entry="$1" uid="$2" gids="$3" resolved parent status reason
  status=eligible; reason=""
  if [ -z "$entry" ]; then
    printf '{"entry":"","resolved":null,"status":"ineligible","reason":"empty PATH entry means the current directory"}'
    return
  fi
  case "$entry" in
    /*) ;;
    *)
      printf '{"entry":%s,"resolved":null,"status":"ineligible","reason":"relative PATH entry"}' "$(json_string "$entry")"
      return
      ;;
  esac
  resolved=$(realpath "$entry" 2>/dev/null) || {
    printf '{"entry":%s,"resolved":null,"status":"ineligible","reason":"PATH entry does not resolve"}' "$(json_string "$entry")"
    return
  }
  if [ ! -d "$resolved" ]; then
    printf '{"entry":%s,"resolved":%s,"status":"ineligible","reason":"PATH entry is not a directory"}' \
      "$(json_string "$entry")" "$(json_string "$resolved")"
    return
  fi
  if dir_writable_by_user "$resolved" "$uid" "$gids"; then
    status=ineligible; reason="writable by the execution user"
  else
    parent=$(dirname "$resolved")
    if dir_writable_by_user "$parent" "$uid" "$gids"; then
      status=ineligible; reason="parent directory is writable by the execution user"
    fi
  fi
  printf '{"entry":%s,"resolved":%s,"status":%s,"reason":%s}' \
    "$(json_string "$entry")" "$(json_string "$resolved")" \
    "$(json_string "$status")" "$(json_string "$reason")"
}

env_name_is_forbidden() {
  case "$1" in
    *TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*PRIVATE*|*SESSION*) return 0 ;;
    *_KEY|*_KEYS|KEY|APIKEY|*APIKEY*|*ACCESS_KEY*) return 0 ;;
    AWS_*|GITHUB_*|GH_*|OPENAI_*|ANTHROPIC_*|GOOGLE_*|AZURE_*|NPM_*|PYPI_*) return 0 ;;
    SSH_AUTH_SOCK|DOCKER_HOST|SSH_AGENT_PID) return 0 ;;
    LD_PRELOAD|LD_LIBRARY_PATH|BASH_ENV|ENV|PYTHONPATH|PYTHONHOME|PERL5LIB|NODE_OPTIONS) return 0 ;;
  esac
  return 1
}

read_mechanism() {
  local workspace="$1" file digest entries='[]'
  for file in $AUTHORITY_MECHANISM_FILES; do
    [ -f "$workspace/$file" ] || return 1
    [ -L "$workspace/$file" ] && return 1
    digest=$(sha256_file "$workspace/$file") || return 1
    entries=$(printf '%s' "$entries" | jq -c --arg path "$file" --arg digest "$digest" \
      '. + [{path: $path, algorithm: "sha256", digest: $digest}]')
  done
  printf '%s' "$entries"
}

build_environment() {
  local home="$1" path="$2"; shift 2
  local pair name value entries
  entries=$(jq -nc --arg home "$home" --arg path "$path" \
    '[{name: "HOME", value: $home}, {name: "PATH", value: $path}]')
  for name in LANG LC_ALL LC_CTYPE LC_NUMERIC LC_TIME LC_COLLATE LC_MESSAGES; do
    value=$(printenv "$name" 2>/dev/null) || continue
    [ -n "$value" ] || continue
    entries=$(printf '%s' "$entries" | jq -c --arg name "$name" --arg value "$value" \
      '. + [{name: $name, value: $value}]')
  done
  for pair in "$@"; do
    case "$pair" in
      *=*) ;;
      *) die "--env expects NAME=VALUE, got: $pair" ;;
    esac
    name=${pair%%=*}; value=${pair#*=}
    if env_name_is_forbidden "$name"; then
      die "refusing to record '$name' in a world-readable enrollment; credential-like and loader variables are never captured"
    fi
    entries=$(printf '%s' "$entries" | jq -c --arg name "$name" --arg value "$value" \
      '. + [{name: $name, value: $value}]')
  done
  printf '%s' "$entries" | jq -cS 'sort_by(.name)'
}

build_path_report() {
  local path="$1" uid="$2" gids="$3" entry report='[]'
  local saved_ifs="$IFS"
  IFS=:
  for entry in $path; do
    IFS="$saved_ifs"
    report=$(printf '%s' "$report" | jq -c --argjson item "$(path_entry_report "$entry" "$uid" "$gids")" '. + [$item]')
    IFS=:
  done
  IFS="$saved_ifs"
  printf '%s' "$report"
}

find_project_by_workspace() {
  local canonical="$1" dir record
  local projects; projects=$(projects_dir)
  [ -d "$projects" ] || return 0
  for dir in "$projects"/*/; do
    [ -f "$dir/enrollment.json" ] || continue
    record=$(jq -r '.workspace // empty' "$dir/enrollment.json" 2>/dev/null) || continue
    if [ "$record" = "$canonical" ]; then
      jq -r '.project_id' "$dir/enrollment.json"
      return 0
    fi
  done
  return 0
}

# --- Verification contract, strict subset ------------------------------------
#
# The core's reader accepts constructs this one deliberately refuses, because a
# privileged program must never guess what a hostile file meant. The rule the
# golden parity tests enforce is one-directional:
#
#   authority accepts  =>  the core accepts and agrees
#   authority refuses  =>  ineligible, and no receipt is ever possible
#
# Refusing is always safe: it costs an acceleration, never a guarantee.

AUTHORITY_CONTRACT_ERROR=""

authority_parse_contract_lines() {
  awk -v ordinary="$AUTHORITY_ORDINARY_CHECKS" -v conditional="$AUTHORITY_CONDITIONAL_CHECKS" '
    function trim(s) { sub(/^[ \t]+/, "", s); sub(/[ \t]+$/, "", s); return s }
    function fail(msg) { print "ERROR:" msg; exited = 1; exit 1 }
    BEGIN {
      n = split(ordinary, o, " "); for (i = 1; i <= n; i++) known[o[i]] = "ordinary"
      n = split(conditional, c, " "); for (i = 1; i <= n; i++) known[c[i]] = "conditional"
    }
    /^[ \t]*$/ { next }
    /^[ \t]*#/ { next }
    /^[ \t]*\[/ {
      if (collecting) fail("required array is not terminated")
      line = $0
      sub(/^[ \t]*\[/, "", line)
      sub(/\][ \t]*(#.*)?$/, "", line)
      gsub(/[ \t]/, "", line)
      section = line
      next
    }
    collecting {
      buffer = buffer " " $0
      if (index($0, "]")) { collecting = 0; emit_required() }
      next
    }
    {
      pos = index($0, "=")
      if (pos == 0) next
      key = trim(substr($0, 1, pos - 1))
      raw = substr($0, pos + 1)

      if (section == "verify") {
        if (!(key in known)) next
        if (seen["verify." key]++) fail("duplicate key verify." key)
        value = trim(raw)
        if (index(value, "#")) fail("verify." key " contains a comment marker; the authority requires an unambiguous value")
        if (value !~ /^".*"$/) fail("verify." key " must be a double-quoted string")
        inner = substr(value, 2, length(value) - 2)
        if (index(inner, "\"")) fail("verify." key " contains an embedded quote")
        if (inner == "") fail("verify." key " is empty")
        print "KIND:" known[key]
        print "CHECK:" key
        print "VALUE:" inner
        next
      }

      if (section == "verify.policy") {
        if (key == "required") {
          if (seen["policy.required"]++) fail("duplicate key verify.policy.required")
          buffer = raw
          if (index(raw, "]")) { emit_required() } else { collecting = 1 }
          next
        }
        if (key == "timeout_seconds" || key == "total_timeout_seconds") {
          if (seen["policy." key]++) fail("duplicate key verify.policy." key)
          value = trim(raw)
          sub(/[ \t]*#.*$/, "", value)
          value = trim(value)
          if (value !~ /^[0-9]+$/) fail("verify.policy." key " must be a bare positive integer")
          if (value + 0 <= 0) fail("verify.policy." key " must be greater than zero")
          print (key == "timeout_seconds" ? "TIMEOUT:" : "TOTAL:") value
          next
        }
        next
      }
      next
    }
    function emit_required(   body, i, ch, item, state) {
      body = buffer
      sub(/^[ \t]*/, "", body)
      if (substr(body, 1, 1) != "[") fail("verify.policy.required must be an array")
      body = substr(body, 2)
      if (!index(body, "]")) fail("verify.policy.required is not terminated")
      sub(/\][ \t]*(#.*)?$/, "", body)
      state = "expect"
      item = ""
      for (i = 1; i <= length(body); i++) {
        ch = substr(body, i, 1)
        if (state == "instring") {
          if (ch == "\"") { print "REQUIRED:" item; item = ""; state = "separator" }
          else item = item ch
          continue
        }
        if (ch == " " || ch == "\t") continue
        if (state == "expect") {
          if (ch == "\"") { state = "instring"; continue }
          fail("verify.policy.required accepts double-quoted names only")
        }
        if (state == "separator") {
          if (ch == ",") { state = "expect"; continue }
          fail("verify.policy.required has a malformed separator")
        }
      }
      if (state == "instring") fail("verify.policy.required has an unterminated string")
      print "REQUIRED_END:"
      buffer = ""
    }
  ' "$1"
}

# authority_read_contract <file>
# Prints the canonical contract JSON, or fails with AUTHORITY_CONTRACT_ERROR set.
authority_read_contract() {
  local file="$1" lines kind name value
  local checks='[]' conditional='[]' required='[]' timeout=null total=null
  local required_seen=0
  AUTHORITY_CONTRACT_ERROR=""
  # The reason is also written to stderr. Callers read this function through a
  # command substitution, which runs in a subshell, so a variable alone would
  # never reach them and every refusal would arrive blank.
  if [ ! -f "$file" ]; then
    AUTHORITY_CONTRACT_ERROR="agent-md.toml is absent"
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi
  if [ -L "$file" ]; then
    AUTHORITY_CONTRACT_ERROR="agent-md.toml is a symlink"
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi
  lines=$(authority_parse_contract_lines "$file") || true
  if printf '%s\n' "$lines" | grep -q '^ERROR:'; then
    AUTHORITY_CONTRACT_ERROR=$(printf '%s\n' "$lines" | sed -n 's/^ERROR://p' | head -1)
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi

  kind=""
  name=""
  while IFS= read -r line; do
    case "$line" in
      KIND:*) kind=${line#KIND:} ;;
      CHECK:*) name=${line#CHECK:} ;;
      VALUE:*)
        value=${line#VALUE:}
        if [ "$kind" = ordinary ]; then
          checks=$(printf '%s' "$checks" | jq -c --arg n "$name" --arg c "$value" '. + [{name:$n,command:$c}]')
        else
          conditional=$(printf '%s' "$conditional" | jq -c --arg n "$name" --arg c "$value" '. + [{name:$n,command:$c}]')
        fi
        ;;
      REQUIRED:*)
        required_seen=1
        required=$(printf '%s' "$required" | jq -c --arg v "${line#REQUIRED:}" '. + [$v]')
        ;;
      REQUIRED_END:*) required_seen=1 ;;
      TIMEOUT:*) timeout=${line#TIMEOUT:} ;;
      TOTAL:*) total=${line#TOTAL:} ;;
    esac
  done <<EOF
$lines
EOF

  local name_list
  name_list=$(printf '%s' "$checks" | jq -r '.[].name')
  local entry
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    case " $AUTHORITY_ORDINARY_CHECKS " in
      *" $entry "*) ;;
      *)
        AUTHORITY_CONTRACT_ERROR="verify.policy.required names an unknown check '$entry'"
        printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
        ;;
    esac
    if ! printf '%s\n' "$name_list" | grep -qxF "$entry"; then
      AUTHORITY_CONTRACT_ERROR="verify.policy.required names '$entry', which has no configured command"
      printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
    fi
  done <<EOF
$(printf '%s' "$required" | jq -r '.[]')
EOF

  if [ "$(printf '%s' "$required" | jq 'length != (unique | length)')" = true ]; then
    AUTHORITY_CONTRACT_ERROR="verify.policy.required contains a duplicate"
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi
  if [ "$(printf '%s' "$checks" | jq 'length')" -eq 0 ]; then
    AUTHORITY_CONTRACT_ERROR="no ordinary verification command is configured"
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi
  # Without an explicit array the core falls back to legacy inference over
  # configured and heuristically discovered checks. The authority cannot
  # reproduce that without guessing, and guessing is the one thing it may never
  # do, so it requires the array to be declared.
  if [ "$required_seen" -ne 1 ]; then
    AUTHORITY_CONTRACT_ERROR="verify.policy.required must be declared explicitly for an approved contract"
    printf '%s\n' "$AUTHORITY_CONTRACT_ERROR" >&2
    return 1
  fi

  jq -nc --argjson checks "$checks" --argjson conditional "$conditional" \
    --argjson required "$required" --argjson required_declared "$([ "$required_seen" -eq 1 ] && echo true || echo false)" \
    --argjson timeout "$timeout" --argjson total "$total" '
    {
      checks: ($checks | sort_by(.name)),
      excluded_conditional: ($conditional | sort_by(.name)),
      required: ($required | sort),
      required_declared: $required_declared,
      timeout_seconds: $timeout,
      total_timeout_seconds: $total
    }'
}

# authority_git_state <workspace>
# Answers "is this a Git repository?" by stat-ing .git, never by running git.
# A .git/config can declare hooks, aliases or core.fsmonitor that execute code,
# and this program may run as root against a workspace an agent controls.
# A linked worktree (.git as a file holding "gitdir:") is not supported yet and
# is refused rather than followed.
authority_git_state() {
  local workspace="$1"
  if [ -d "$workspace/.git" ]; then printf 'directory'
  elif [ -f "$workspace/.git" ]; then printf 'file'
  else printf 'absent'
  fi
}

# authority_dir_safety <dir>
# Same rules as assert_safe_dir, but reports instead of exiting, so a runtime
# that must answer with structured JSON can do so.
authority_dir_safety() {
  local dir="$1"
  if [ ! -e "$dir" ]; then printf 'missing'; return 1; fi
  if path_has_symlink "$dir"; then printf 'symlinked path component'; return 1; fi
  if [ ! -d "$dir" ]; then printf 'not a directory'; return 1; fi
  if world_writable "$dir"; then printf 'world-writable'; return 1; fi
  return 0
}

# authority_find_projects <canonical-workspace>
# Prints every enrollment bound to this workspace. More than one line means the
# authority state is ambiguous and nothing may proceed.
authority_find_projects() {
  local canonical="$1" dir recorded projects
  projects=$(projects_dir)
  [ -d "$projects" ] || return 0
  for dir in "$projects"/*/; do
    [ -f "$dir/enrollment.json" ] || continue
    [ -L "$dir/enrollment.json" ] && continue
    recorded=$(jq -r '.workspace // empty' "$dir/enrollment.json" 2>/dev/null) || continue
    if [ "$recorded" = "$canonical" ]; then
      jq -r '.project_id // empty' "$dir/enrollment.json" 2>/dev/null
    fi
  done
}

# --- Trusted runtime tools ---------------------------------------------------
#
# The child must not reach its shell or its timeout through a PATH the
# developer can influence. Both are recorded as absolute paths at enrollment
# and revalidated immediately before execution.
#
# Trust here means "the execution user cannot replace this executable", not
# "this executable has a pinned content digest". A digest would be stronger,
# but every distribution security update to bash or coreutils would invalidate
# every enrollment, and an authority nobody can keep enrolled protects nothing.
# The ownership and permission checks are what actually stop a substitution.

authority_tool_trust() {
  local path="$1" uid="$2" gids="$3" resolved parent
  case "$path" in
    /*) ;;
    *) printf 'not an absolute path'; return 1 ;;
  esac
  if [ -L "$path" ]; then printf 'is a symlink'; return 1; fi
  resolved=$(realpath "$path" 2>/dev/null) || { printf 'does not resolve'; return 1; }
  if [ "$resolved" != "$path" ]; then printf 'resolves elsewhere'; return 1; fi
  if [ ! -f "$path" ] || [ ! -x "$path" ]; then printf 'is not an executable file'; return 1; fi
  if path_has_symlink "$path"; then printf 'path component is a symlink'; return 1; fi
  if dir_writable_by_user "$path" "$uid" "$gids" 2>/dev/null; then
    printf 'is writable by the execution user'; return 1
  fi
  parent=$(dirname "$path")
  if dir_writable_by_user "$parent" "$uid" "$gids"; then
    printf 'sits in a directory the execution user can write'; return 1
  fi
  return 0
}

# authority_discover_tools <uid> <gids>
# Emits the approved tool table, or fails with a reason on stdout.
authority_discover_tools() {
  local uid="$1" gids="$2" name path reason entries='[]'
  for name in $AUTHORITY_REQUIRED_TOOLS; do
    case "$name" in
      bash) path=/bin/bash; [ -x "$path" ] || path=/usr/bin/bash ;;
      timeout) path=/usr/bin/timeout; [ -x "$path" ] || path=/bin/timeout ;;
      env) path=/usr/bin/env; [ -x "$path" ] || path=/bin/env ;;
      *) printf 'unknown tool %s' "$name"; return 1 ;;
    esac
    path=$(realpath "$path" 2>/dev/null) || { printf 'cannot resolve %s' "$name"; return 1; }
    if ! reason=$(authority_tool_trust "$path" "$uid" "$gids"); then
      printf '%s at %s %s' "$name" "$path" "$reason"; return 1
    fi
    entries=$(printf '%s' "$entries" | jq -c --arg n "$name" --arg p "$path" '. + [{name:$n,path:$p}]')
  done
  printf '%s' "$entries" | jq -cS 'sort_by(.name)'
}

# authority_file_unwritable_by_effective_user <path>
# The control-plane rule for anything the execution user may read but must not
# influence. It is deliberately expressed as "this user cannot write it" rather
# than "it is owned by X", because that is the property that actually matters
# and the only one a fixture can reproduce without a real service account.
authority_file_unwritable_by_effective_user() {
  local path="$1"
  [ -e "$path" ] || { printf 'is absent'; return 1; }
  if [ -L "$path" ]; then printf 'is a symlink'; return 1; fi
  if path_has_symlink "$path"; then printf 'path component is a symlink'; return 1; fi
  if [ -w "$path" ]; then printf 'is writable by the execution user'; return 1; fi
  if [ -w "$(dirname "$path")" ]; then printf 'sits in a directory the execution user can write'; return 1; fi
  return 0
}

# --- Execution snapshot ------------------------------------------------------
#
# Checks never run in the live worktree. The developer owns that directory and
# can swap it to a passing state, let the checks observe that, and restore the
# original before and after any sampling the authority does. A before/after
# fingerprint only samples two instants and cannot see the substitution.
#
# The identity is therefore the snapshot's, not the live tree's. The authority
# copies first and hashes the copy, so the manifest describes exactly the bytes
# the checks will see. A snapshot captured mid-mutation is internally
# consistent but will simply never match the live worktree later, which makes
# transient substitution useless rather than dangerous.

authority_snapshot_root() { printf '%s/snapshots' "$(state_dir)"; }
authority_snapshot_dir() { printf '%s/%s' "$(authority_snapshot_root)" "$1"; }

# A path offered by the enumerator is data, not authority. It must stay inside
# the workspace and must not climb out of it.
authority_relative_path_is_safe() {
  case "$1" in
    ""|/*|.|..) return 1 ;;
    */../*|../*|*/..) return 1 ;;
    *$'\n'*) return 1 ;;
  esac
  return 0
}

# authority_enumerate_paths <workspace>
#
# Emits the NUL separated worktree path set: everything Git tracks plus
# everything untracked that is not ignored. Git has to answer this, because
# reproducing .gitignore semantics by hand would be a large and silently wrong
# surface.
#
# This is the one place a repository's own Git configuration is read, so it is
# meant to run as the execution-only account and never as the authority. The
# hardening below removes the obvious execution vectors; containment by uid is
# what actually bounds the damage.
authority_enumerate_paths() {
  local workspace="$1"
  # The enumerator runs as the execution account while the repository belongs
  # to the developer, so Git's dubious-ownership guard fires. The workspace is
  # named explicitly and narrowly: it is the path the authority already
  # canonicalised and approved, and the guard's purpose -- not trusting a
  # stranger's repository configuration -- is what the containment hop and the
  # hardening flags below are for.
  GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 HOME=/nonexistent \
  git -C "$workspace" --no-pager --no-optional-locks \
    -c "safe.directory=$workspace" \
    -c core.fsmonitor=false \
    -c core.hooksPath=/dev/null \
    -c core.pager=cat \
    -c protocol.ext.allow=never \
    ls-files -z --cached --others --exclude-standard
}

# authority_materialize_snapshot <workspace> <paths-file> <dest>
#
# Copies the enumerated paths into a tree the authority owns. Content is read
# once and written once; the manifest is then taken from the copy, so what was
# hashed is exactly what will execute.
authority_materialize_snapshot() {
  local workspace="$1" paths="$2" dest="$3" path target parent mode
  mkdir -p "$dest" || { printf 'cannot create snapshot directory'; return 1; }
  while IFS= read -r -d '' path; do
    verification_receipt_path_is_structurally_excluded_stub "$path" && continue
    if ! authority_relative_path_is_safe "$path"; then
      printf 'enumerated path is unsafe: %s' "$path"; return 1
    fi
    # A symlinked directory component would let the developer redirect the copy
    # at anything the authority can read, so the whole snapshot is refused.
    parent=$(dirname "$path")
    if [ "$parent" != "." ] && path_has_symlink "$workspace/$parent"; then
      printf 'workspace path component is a symlink: %s' "$parent"; return 1
    fi
    target="$dest/$path"
    mkdir -p "$(dirname "$target")" || { printf 'cannot create %s' "$(dirname "$target")"; return 1; }
    if [ -L "$workspace/$path" ]; then
      # Recorded as a link, never followed.
      cp -P "$workspace/$path" "$target" || { printf 'cannot copy symlink %s' "$path"; return 1; }
      continue
    fi
    if [ ! -f "$workspace/$path" ]; then
      # Deleted between enumeration and copy: absence is a legitimate state and
      # simply does not appear in the snapshot.
      continue
    fi
    cat < "$workspace/$path" > "$target" || { printf 'cannot copy %s' "$path"; return 1; }
    if [ -x "$workspace/$path" ]; then mode=0555; else mode=0444; fi
    chmod "$mode" "$target" || { printf 'cannot set mode on %s' "$path"; return 1; }
  done < "$paths"
  return 0
}

# Structural exclusions mirror the Phase A receipt protocol. The authority keeps
# its own copy rather than sourcing the repository's implementation.
verification_receipt_path_is_structurally_excluded_stub() {
  case "$1" in
    .git|.git/*|.agent/verification|.agent/verification/*|\
    memory/agents.md|memory/plan.md|memory/progress.md|memory/verify.md|memory/gotchas.md) return 0 ;;
    *) return 1 ;;
  esac
}

# authority_seal_snapshot <dest>
# Read and execute for everyone who can reach it, writable by nobody, including
# the owner. A later write therefore needs an explicit chmod, which neither the
# runner nor the developer can perform on a directory they do not own.
authority_seal_snapshot() {
  local dest="$1"
  find "$dest" -type d -exec chmod 0555 {} + 2>/dev/null
  find "$dest" -type f -perm -u+x -exec chmod 0555 {} + 2>/dev/null
  find "$dest" -type f ! -perm -u+x -exec chmod 0444 {} + 2>/dev/null
  chmod 0555 "$dest" 2>/dev/null
  return 0
}

# authority_snapshot_manifest <dest>
# The source identity, taken from the snapshot itself.
authority_snapshot_manifest() {
  local dest="$1" entries path kind digest mode
  entries=$(mktemp "${TMPDIR:-/tmp}/agent-md-snap.XXXXXX") || return 1
  : > "$entries"
  while IFS= read -r -d '' path; do
    path=${path#"$dest"/}
    if [ -L "$dest/$path" ]; then
      kind="symlink"; mode=120000
      # Phase A hashes the raw target bytes without readlink's terminator, so
      # the vendored primitive is used rather than a second, subtly different
      # implementation.
      digest=$(authority_pa_verification_receipt_symlink_digest "$path") || { rm -f "$entries"; return 1; }
    else
      kind="file"
      if [ -x "$dest/$path" ]; then mode=100755; else mode=100644; fi
      digest=$(sha256_file "$dest/$path") || { rm -f "$entries"; return 1; }
    fi
    jq -nc --arg p "$path" --arg k "$kind" --arg m "$mode" --arg d "$digest" \
      '{path:$p,kind:$k,mode:$m,digest:$d}' >> "$entries"
  done < <(find "$dest" \( -type f -o -type l \) -print0 | sort -z)
  jq -sc 'sort_by(.path)' "$entries"
  rm -f "$entries"
}

# --- Execution identity ------------------------------------------------------
#
# The developer and the runner are different principals and were conflated
# once already. The developer owns the repository and is untrusted: their write
# access is what disqualifies a PATH entry, and they stay in the enrollment for
# that. They are not the account a check runs as.
#
# Staging executes directly as its caller, regardless of host service accounts.
# Production resolves the real runner and nothing else.
authority_runner_identity() {
  local user uid
  if ! is_real_root_prefix; then
    user=$(id -un); uid=$(id -u)
  elif getent passwd "$AUTHORITY_RUNNER_USER" >/dev/null 2>&1; then
    user="$AUTHORITY_RUNNER_USER"
    uid=$(passwd_field "$user" 3) || return 1
  else
    printf 'the %s service account does not exist' "$AUTHORITY_RUNNER_USER"
    return 1
  fi
  jq -nc --arg u "$user" --argjson i "$uid" '{user:$u,uid:$i}'
}

# --- Evaluation runs ---------------------------------------------------------
#
# A run is the unit of isolation. Preparing a snapshot used to replace a single
# mutable directory, which would pull the ground out from under a check that
# was still executing. Every evaluation now materialises its own run, and the
# pointer to the current one is authority-owned so no caller can name a run.

authority_runs_root() { printf '%s/%s/runs' "$(projects_dir)" "$1"; }
authority_run_dir() { printf '%s/%s' "$(authority_runs_root "$1")" "$2"; }
authority_current_run_file() { printf '%s/%s/current-run' "$(projects_dir)" "$1"; }
authority_project_lock() { printf '%s/%s/.lock' "$(projects_dir)" "$1"; }

# Run identifiers are generated here and never accepted from a request. The
# charset is checked wherever one is read back, so a stored identifier can
# never become a path traversal or an option.
authority_run_id_is_safe() {
  case "$1" in
    ""|*[!a-f0-9-]*|-*|*-) return 1 ;;
  esac
  [ "${#1}" -eq 36 ]
}

# authority_derive_total_timeout <per-check> <stage-count> <declared-total>
# Mirrors the core's legacy derivation when a contract declares no total, so a
# project without one is still bounded rather than unbounded.
authority_derive_total_timeout() {
  local per_check="$1" stages="$2" declared="$3"
  if [ -n "$declared" ] && [ "$declared" != null ]; then
    printf '%s' "$declared"
    return 0
  fi
  printf '%s' "$(( stages * per_check + AUTHORITY_LEGACY_OVERHEAD_SECONDS ))"
}

# --- Source identity bound to the executed snapshot -------------------------
#
# The snapshot and the Phase A identity have to describe the same instant, or a
# receipt would claim that state X passed while the checks read state Y. The
# order below makes that provable rather than assumed:
#
#   1. compute the Phase A identity
#   2. materialise the snapshot from that identity's own path set
#   3. seal it
#   4. verify the sealed tree against the identity, entry by entry
#   5. recompute the identity and require it to be unchanged
#
# Step 4 is the strong one: the authority holds both sides, so a worktree that
# moved during the copy shows up as a mismatch. Step 5 additionally catches a
# change on the index side, which the snapshot cannot witness. Either failure
# refuses the run; neither can produce a candidate pass.

# authority_materialize_from_manifest <workspace> <manifest-file> <dest>
# Materialises exactly the paths the identity describes, so the tree and the
# fingerprint cannot disagree about which files were in scope.
authority_materialize_from_manifest() {
  local workspace="$1" manifest="$2" dest="$3" path kind mode entry parent
  mkdir -p "$dest" || { printf 'cannot create snapshot directory'; return 1; }
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    path=$(printf '%s' "$entry" | jq -r '.path')
    kind=$(printf '%s' "$entry" | jq -r '.worktree.kind // ""')
    mode=$(printf '%s' "$entry" | jq -r '.worktree.mode // ""')
    if ! authority_relative_path_is_safe "$path"; then
      printf 'enumerated path is unsafe: %s' "$path"; return 1
    fi
    parent=$(dirname "$path")
    if [ "$parent" != "." ] && path_has_symlink "$workspace/$parent"; then
      printf 'workspace path component is a symlink: %s' "$parent"; return 1
    fi
    mkdir -p "$(dirname "$dest/$path")" || { printf 'cannot create %s' "$(dirname "$path")"; return 1; }
    if [ "$kind" = symlink ]; then
      cp -P "$workspace/$path" "$dest/$path" || { printf 'cannot copy symlink %s' "$path"; return 1; }
      continue
    fi
    cat < "$workspace/$path" > "$dest/$path" || { printf 'cannot copy %s' "$path"; return 1; }
    if [ "$mode" = 100755 ]; then chmod 0555 "$dest/$path"; else chmod 0444 "$dest/$path"; fi
  done <<EOF
$(jq -c '.entries[] | select(.worktree.state == "present")' "$manifest")
EOF
  return 0
}

# authority_snapshot_matches_identity <manifest-file> <snapshot-dir>
# A bijection check: every present path in the identity is in the sealed tree
# with the same kind, mode and digest, and the tree holds nothing else.
authority_snapshot_matches_identity() {
  local manifest="$1" dest="$2" expected actual
  expected=$(jq -cS '[.entries[] | select(.worktree.state == "present")
    | {path: .path, kind: .worktree.kind, mode: .worktree.mode, digest: .worktree.digest}]
    | sort_by(.path)' "$manifest") || { printf 'cannot project the identity'; return 1; }
  actual=$(authority_snapshot_manifest "$dest" | jq -cS 'sort_by(.path)') \
    || { printf 'cannot read the sealed snapshot'; return 1; }
  if [ "$expected" != "$actual" ]; then
    printf 'the sealed snapshot does not match the source identity'
    return 1
  fi
  return 0
}

# authority_export_git_workspace_env <workspace>
# The same containment authority_enumerate_paths applies with -c flags, but
# expressed through the environment so that it reaches the vendored Phase A
# functions without editing their git invocations.
#
# Those invocations must stay byte-identical to the core they were copied from,
# because the parity tests compare the two implementations' output; rewriting
# call sites to add flags would make the vendored copy a different program.
# git reads GIT_CONFIG_COUNT/KEY/VALUE exactly as it reads -c, so the same
# narrow exception applies with no call site touched.
#
# safe.directory names the one canonicalised, approved workspace. It is never
# '*': the guard exists so that one user does not execute another user's
# repository configuration, and the only thing being waived is the ownership
# check for a path the authority already approved.
authority_export_git_workspace_env() {
  local workspace="$1"
  export GIT_CONFIG_GLOBAL=/dev/null
  export GIT_CONFIG_NOSYSTEM=1
  export GIT_ATTR_NOSYSTEM=1
  export GIT_CONFIG_COUNT=5
  export GIT_CONFIG_KEY_0=safe.directory   GIT_CONFIG_VALUE_0="$workspace"
  export GIT_CONFIG_KEY_1=core.fsmonitor   GIT_CONFIG_VALUE_1=false
  export GIT_CONFIG_KEY_2=core.hooksPath   GIT_CONFIG_VALUE_2=/dev/null
  export GIT_CONFIG_KEY_3=core.pager       GIT_CONFIG_VALUE_3=cat
  export GIT_CONFIG_KEY_4=protocol.ext.allow GIT_CONFIG_VALUE_4=never
}

# --- Issuer key custody ------------------------------------------------------
#
# The signing key is the only thing in this system that turns an observation
# into evidence, so its custody rules are stricter than anything else here.
#
# Layout under the key directory, which is 0700 and owned by the service user:
#
#   issuer-<key_id>.key   0600  the Ed25519 private key, PKCS#8 PEM
#   issuer-<key_id>.pub   0644  the public key derived from it, SPKI PEM
#   current               0644  one line: the key_id of the active key
#
# key_id is the full SHA-256 of the DER SPKI encoding of the public key. The
# full digest is used rather than a truncation: a truncated identifier invites
# a collision search against a value that selects which key validates a
# receipt, and the cost of carrying 64 hex characters is nothing.
#
# "current" holds an identifier, never key material and never a symlink to a
# key file. A mutable current.pem would make the active key a property of a
# path that could be relinked; an identifier makes it a property of the key's
# own content. Rotation therefore changes one short text file, and every
# previously issued receipt still names the key that signed it.
#
# Publication is the rename of "current". A key whose files exist but which no
# "current" names is not active and is not usable; a crash at any point before
# that rename leaves an unreferenced key, never a half-published one.

AUTHORITY_KEY_ALGORITHM=ed25519

# authority_fsync_path <path>
# Durability for a file or a directory. GNU coreutils syncs the named path;
# elsewhere a full sync is slower but strictly stronger. Either way the caller
# gets the ordering guarantee it asked for, so this never fails softly.
authority_fsync_path() {
  local path="$1"
  if sync -d "$path" 2>/dev/null; then return 0; fi
  sync 2>/dev/null || return 1
  return 0
}

# authority_key_id_from_public <public-pem>
# The identifier of a key: sha256 over the DER SPKI, which is the same bytes
# any validator can recompute from the public key alone.
authority_key_id_from_public() {
  local pub="$1" der out
  der=$(mktemp "${TMPDIR:-/tmp}/agent-md-spki.XXXXXX") || return 1
  if ! openssl pkey -pubin -in "$pub" -outform DER -out "$der" 2>/dev/null; then
    rm -f "$der"; return 1
  fi
  out=$(sha256_file "$der"); rm -f "$der"
  case "$out" in
    [0-9a-f]*) ;;
    *) return 1 ;;
  esac
  [ ${#out} -eq 64 ] || return 1
  printf '%s' "$out"
}

authority_key_id_is_safe() {
  case "$1" in
    *[!0-9a-f]*|"") return 1 ;;
  esac
  [ ${#1} -eq 64 ]
}

authority_private_key_path() { printf '%s/issuer-%s.key' "$(keys_dir)" "$1"; }
authority_public_key_path()  { printf '%s/issuer-%s.pub' "$(keys_dir)" "$1"; }
authority_current_key_file() { printf '%s/current' "$(keys_dir)"; }

# authority_current_key_id
# The active key, or nothing. A malformed or oversized pointer reads as no
# active key rather than as an identifier to go looking for.
authority_current_key_id() {
  local file id
  file=$(authority_current_key_file)
  [ -f "$file" ] || return 1
  [ -L "$file" ] && return 1
  IFS= read -r id < "$file" || return 1
  authority_key_id_is_safe "$id" || return 1
  printf '%s' "$id"
}

# authority_key_custody_report <key-id>
# Everything that must hold for a published key, as a reason on failure. The
# private key is never read here: custody is a property of the inode.
authority_key_custody_report() {
  local id="$1" keys priv pub mode
  keys=$(keys_dir)
  priv=$(authority_private_key_path "$id")
  pub=$(authority_public_key_path "$id")
  if path_has_symlink "$keys"; then printf 'key directory has a symlinked path component'; return 1; fi
  mode=$(mode_of "$keys") || { printf 'key directory is unreadable'; return 1; }
  [ "${mode: -3}" = 700 ] || { printf 'key directory mode is %s, expected 700' "$mode"; return 1; }
  [ -f "$priv" ] || { printf 'private key is absent'; return 1; }
  [ -L "$priv" ] && { printf 'private key is a symlink'; return 1; }
  mode=$(mode_of "$priv") || { printf 'private key is unreadable'; return 1; }
  [ "${mode: -3}" = 600 ] || { printf 'private key mode is %s, expected 600' "$mode"; return 1; }
  [ -f "$pub" ] || { printf 'public key is absent'; return 1; }
  [ -L "$pub" ] && { printf 'public key is a symlink'; return 1; }
  return 0
}

# authority_generate_key_into <staging-dir>
# Creates a key pair inside a private staging directory and prints its key_id.
# Nothing here writes into the key directory: the caller publishes, so a
# failure at any step leaves the live layout exactly as it was.
#
# The private key reaches the filesystem through openssl's own -out. It is
# never passed as an argument, never placed in the environment and never
# written to a descriptor this shell reads, so it cannot appear in a process
# listing or in captured output.
authority_generate_key_into() {
  local staging="$1" priv pub id
  priv="$staging/new.key"
  pub="$staging/new.pub"
  ( umask 077 && openssl genpkey -algorithm "$AUTHORITY_KEY_ALGORITHM" -out "$priv" >/dev/null 2>&1 ) \
    || { printf 'cannot generate an %s key' "$AUTHORITY_KEY_ALGORITHM"; return 1; }
  chmod 0600 "$priv" || { printf 'cannot restrict the generated key'; return 1; }
  openssl pkey -in "$priv" -pubout -out "$pub" >/dev/null 2>&1 \
    || { printf 'cannot derive the public key'; return 1; }
  chmod 0644 "$pub" || { printf 'cannot set the public key mode'; return 1; }
  id=$(authority_key_id_from_public "$pub") || { printf 'cannot compute the key identifier'; return 1; }
  printf '%s' "$id"
}

# authority_publish_key <staging-dir> <key-id> [owner]
# Moves a staged pair into the key directory and then, and only then, names it
# as current. Each step is durable before the next one is allowed to depend on
# it, so the orderings a crash can produce are limited to:
#
#   nothing            -> no key, no pointer
#   key files only     -> an unreferenced key, inert
#   key files, pointer -> published
#
# There is no ordering in which "current" names a key whose material is
# missing or partial.
authority_publish_key() {
  local staging="$1" id="$2" owner="${3:-}" keys priv pub tmp
  keys=$(keys_dir)
  priv=$(authority_private_key_path "$id")
  pub=$(authority_public_key_path "$id")

  authority_fsync_path "$staging/new.key" || { printf 'cannot flush the generated key'; return 1; }
  authority_fsync_path "$staging/new.pub" || { printf 'cannot flush the public key'; return 1; }

  if [ -n "$owner" ]; then
    chown "$owner":"$owner" "$staging/new.key" "$staging/new.pub" 2>/dev/null \
      || { printf 'cannot assign key ownership to %s' "$owner"; return 1; }
  fi

  mv -f "$staging/new.key" "$priv" || { printf 'cannot place the private key'; return 1; }
  mv -f "$staging/new.pub" "$pub" || { printf 'cannot place the public key'; return 1; }
  authority_fsync_path "$keys" || { printf 'cannot flush the key directory'; return 1; }

  tmp="$staging/current"
  printf '%s\n' "$id" > "$tmp" || { printf 'cannot stage the pointer'; return 1; }
  chmod 0644 "$tmp" || { printf 'cannot set the pointer mode'; return 1; }
  if [ -n "$owner" ]; then
    chown "$owner":"$owner" "$tmp" 2>/dev/null || { printf 'cannot assign pointer ownership'; return 1; }
  fi
  authority_fsync_path "$tmp" || { printf 'cannot flush the pointer'; return 1; }
  mv -f "$tmp" "$(authority_current_key_file)" || { printf 'cannot publish the pointer'; return 1; }
  authority_fsync_path "$keys" || { printf 'cannot flush the key directory'; return 1; }
  return 0
}

# --- Evaluation state machine ------------------------------------------------
#
# What this exists to make true:
#
#   PASS n, then FAIL n+1  =>  PASS n is stale
#
# and to keep that true across a crash at any point. The ordering comes from a
# sequence the authority allocates, never from a timestamp, an mtime, a file
# name or a lexical sort: every one of those is either attacker-influenced or
# unordered under concurrency, and none of them survives a clock change.
#
# The sequence line is keyed by (project_id, scope). worktree and staged are
# independent lines: a staged evaluation must not renumber, supersede or be
# superseded by a worktree one, because they describe different trees.
#
# The central rule is that a reservation happens BEFORE the checks run. If a
# sequence were taken only once a result existed, a crash between "the checks
# failed" and "record that they failed" would leave the previous PASS looking
# current, which is exactly the outcome this machine has to prevent. So:
#
#   pending != null  =>  last_terminal is SUPPRESSED for latest purposes
#
# A pending is never read as a pass. It means "an attempt was started whose
# outcome the authority could not close", and until a later evaluation resolves
# it, nothing earlier may be treated as current.
#
# Sequences are monotonic, not contiguous. A reserved sequence is consumed the
# moment it is allocated; if that evaluation never reaches a terminal result the
# number is simply burned. Gaps are normal and carry no meaning.
#
# Nothing here signs, reads a key or writes a receipt. candidate_pass in this
# file is an authority-side terminal result, not evidence and not a receipt.

AUTHORITY_STATE_SCHEMA=3
AUTHORITY_STATE_LEGACY_SCHEMA=7
AUTHORITY_STATE_UNISSUED_SCHEMA=2
AUTHORITY_RECEIPT_SCHEMA=1
AUTHORITY_SIGNATURE_FORMAT=ed25519-openssl-rawin
AUTHORITY_SCOPES="worktree staged"
AUTHORITY_TERMINAL_STATUSES="candidate_pass candidate_fail identity_changed"

# A fresh identifier for a run. Lives here because the issuer now names the run
# before it asks for one: the sequence is reserved against that name, and the
# reservation has to be durable before the snapshot is captured.
authority_new_id() {
  if [ -r /proc/sys/kernel/random/uuid ]; then
    cat /proc/sys/kernel/random/uuid
  elif command -v uuidgen >/dev/null 2>&1; then
    uuidgen | tr '[:upper:]' '[:lower:]'
  elif command -v openssl >/dev/null 2>&1; then
    openssl rand -hex 16
  else
    return 1
  fi
}

authority_state_file()      { printf '%s/%s/state.json' "$(projects_dir)" "$1"; }
authority_evaluation_lock() { printf '%s/%s/.evaluation.lock' "$(projects_dir)" "$1"; }

authority_scope_is_known() {
  local s
  for s in $AUTHORITY_SCOPES; do [ "$s" = "$1" ] && return 0; done
  return 1
}

authority_state_new_json() {
  jq -nc --argjson schema "$AUTHORITY_STATE_SCHEMA" --arg scopes "$AUTHORITY_SCOPES" '
    {schema: $schema,
     scopes: ($scopes | split(" ")
              | map({key: ., value: {next_sequence: 1, pending: null, last_terminal: null}})
              | from_entries)}'
}

# authority_state_validate <json>
# Every invariant the machine depends on, checked before the state is allowed to
# influence anything. A reason is printed on failure; there is no repair path.
authority_state_validate() {
  local json="$1" scope entry
  jq -e . >/dev/null 2>&1 <<<"$json" || { printf 'state is not valid JSON'; return 1; }
  [ "$(jq -r '.schema // empty' <<<"$json")" = "$AUTHORITY_STATE_SCHEMA" ] \
    || { printf 'state schema is not %s' "$AUTHORITY_STATE_SCHEMA"; return 1; }
  [ "$(jq -r '.scopes | type' <<<"$json")" = object ] \
    || { printf 'state carries no scope map'; return 1; }
  local have want
  have=$(jq -r '.scopes | keys_unsorted | sort | join(" ")' <<<"$json")
  want=$(printf '%s' "$AUTHORITY_SCOPES" | tr ' ' '\n' | sort | tr '\n' ' '); want=${want% }
  [ "$have" = "$want" ] || { printf 'state scopes are %s, expected %s' "$have" "$want"; return 1; }

  for scope in $AUTHORITY_SCOPES; do
    entry=$(jq -c --arg s "$scope" '.scopes[$s]' <<<"$json")
    if ! jq -e '(.next_sequence | type) == "number"
                and (.next_sequence | floor) == .next_sequence
                and .next_sequence >= 1' >/dev/null 2>&1 <<<"$entry"; then
      printf '%s: next_sequence is not a positive integer' "$scope"; return 1
    fi
    if [ "$(jq -r '.pending | type' <<<"$entry")" != "null" ]; then
      if ! jq -e '(.pending | type) == "object"
                  and (.pending.sequence | type) == "number"
                  and (.pending.sequence | floor) == .pending.sequence
                  and .pending.sequence >= 1
                  and (.pending.run_id | type) == "string"
                  and (.pending.scope | type) == "string"
                  and .pending.sequence < .next_sequence' >/dev/null 2>&1 <<<"$entry"; then
        printf '%s: pending is malformed or not below next_sequence' "$scope"; return 1
      fi
      [ "$(jq -r '.pending.scope' <<<"$entry")" = "$scope" ] \
        || { printf '%s: pending records a different scope' "$scope"; return 1; }
    fi
    if [ "$(jq -r '.last_terminal | type' <<<"$entry")" != "null" ]; then
      if ! jq -e '(.last_terminal | type) == "object"
                  and (.last_terminal.sequence | type) == "number"
                  and (.last_terminal.sequence | floor) == .last_terminal.sequence
                  and .last_terminal.sequence >= 1
                  and (.last_terminal.run_id | type) == "string"
                  and (.last_terminal.scope | type) == "string"
                  and (.last_terminal.status | type) == "string"
                  and (.last_terminal.fingerprints | type) == "object"
                  and (.last_terminal | has("receipt")) and (.last_terminal | has("key_id"))
                  and ((.last_terminal.receipt | type) == "null"
                       or ((.last_terminal.receipt | type) == "object"
                           and (.last_terminal.receipt.path | type) == "string"
                           and (.last_terminal.receipt.schema | type) == "number"))
                  and ((.last_terminal.key_id | type) == "null"
                       or ((.last_terminal.key_id | type) == "string"
                           and (.last_terminal.key_id | length) == 64))
                  and .last_terminal.sequence < .next_sequence' >/dev/null 2>&1 <<<"$entry"; then
        printf '%s: last_terminal is malformed or not below next_sequence' "$scope"; return 1
      fi
      # An authenticated terminal names both the receipt and the key that
      # signed it; one without the other is not a state this authority writes.
      if ! jq -e '((.last_terminal.receipt | type) == "null")
                  == ((.last_terminal.key_id | type) == "null")' >/dev/null 2>&1 <<<"$entry"; then
        printf '%s: last_terminal names a receipt without a key, or the reverse' "$scope"; return 1
      fi
      local status; status=$(jq -r '.last_terminal.status' <<<"$entry")
      case " $AUTHORITY_TERMINAL_STATUSES " in
        *" $status "*) ;;
        *) printf '%s: last_terminal carries an unknown status %s' "$scope" "$status"; return 1 ;;
      esac
      [ "$(jq -r '.last_terminal.scope' <<<"$entry")" = "$scope" ] \
        || { printf '%s: last_terminal records a different scope' "$scope"; return 1; }
    fi
  done
  return 0
}

# authority_state_migrate <json>
# The only recognised earlier state is the one enrollment wrote and nothing ever
# updated: schema 7 with both fields null. That is migrated deterministically to
# fresh sequence lines. Any other shape is refused rather than guessed at: a
# schema 7 file carrying a non-null pending or last_terminal was never produced
# by any released code, so it is evidence of tampering or corruption, not of an
# older version.
authority_state_migrate() {
  local json="$1" migrated

  # The pre-sequence state: schema 7 with both fields null, which is the only
  # shape enrollment ever wrote before the sequence line existed.
  if [ "$(jq -r '.schema // empty' <<<"$json")" = "$AUTHORITY_STATE_LEGACY_SCHEMA" ] \
     && [ "$(jq -r 'has("scopes")' <<<"$json")" = false ] \
     && [ "$(jq -r '.pending | type' <<<"$json")" = null ] \
     && [ "$(jq -r '.last_terminal | type' <<<"$json")" = null ]; then
    authority_state_new_json
    return 0
  fi

  # The sequence state that predates receipts. Its terminal results were real
  # evaluations, so their sequences stay consumed and next_sequence carries
  # forward untouched -- but they were never signed and no receipt exists for
  # them, so they are migrated with receipt and key_id explicitly null.
  #
  # That null is the whole point of the migration: it is what stops a
  # candidate_pass recorded before receipts existed from being read later as
  # authenticated evidence. Becoming authenticated requires a new evaluation
  # that actually signs something.
  if [ "$(jq -r '.schema // empty' <<<"$json")" = "$AUTHORITY_STATE_UNISSUED_SCHEMA" ] \
     && [ "$(jq -r '.scopes | type' <<<"$json")" = object ]; then
    migrated=$(jq -c --argjson schema "$AUTHORITY_STATE_SCHEMA" '
      .schema = $schema
      | .scopes |= with_entries(
          .value.last_terminal |= (
            if . == null then null
            else . + {receipt: null, key_id: null} end))' <<<"$json") || return 1
    printf '%s' "$migrated"
    return 0
  fi
  return 1
}

# authority_state_read <project-id>
# Prints the validated state, migrating a recognised earlier schema on the way.
# A missing, unreadable, corrupt or unrecognised state fails closed: it is never
# treated as an empty state, and it is never reconstructed from receipts, run
# directories or file names, because none of those can prove what was already
# consumed.
authority_state_read() {
  local project_id="$1" file json reason
  file=$(authority_state_file "$project_id")
  [ -e "$file" ] || { printf 'the authority holds no state for this project'; return 1; }
  [ -L "$file" ] && { printf 'the state file is a symlink'; return 1; }
  path_has_symlink "$file" && { printf 'the state path traverses a symlink'; return 1; }
  [ -f "$file" ] || { printf 'the state path is not a regular file'; return 1; }
  json=$(cat "$file" 2>/dev/null) || { printf 'the state file cannot be read'; return 1; }
  jq -e . >/dev/null 2>&1 <<<"$json" || { printf 'the state file is not valid JSON'; return 1; }

  if ! reason=$(authority_state_validate "$json"); then
    local migrated
    if migrated=$(authority_state_migrate "$json"); then
      printf '%s' "$migrated"; return 0
    fi
    printf '%s' "$reason"; return 1
  fi
  printf '%s' "$json"
}

# authority_state_write <project-id> <json>
# One rename, never a partial file. The content is flushed before it is named,
# and the directory entry is flushed before the call returns, so a reader after
# a crash sees either the previous state or this one and never a truncated JSON
# document.
authority_state_write() {
  local project_id="$1" json="$2" file dir tmp reason
  if ! reason=$(authority_state_validate "$json"); then
    printf 'refusing to persist an invalid state: %s' "$reason"; return 1
  fi
  file=$(authority_state_file "$project_id")
  dir=$(dirname "$file")

  # The project directory is sealed read-only between runs so that nothing can
  # introduce a file next to the pointer a check resolves through. The authority
  # owns it, so it unseals to write and seals again; the original mode is
  # restored on every path out, including failure.
  local dirmode; dirmode=$(mode_of "$dir")
  chmod u+w "$dir" 2>/dev/null || true
  _authority_state_reseal() { [ -n "$dirmode" ] && chmod "$dirmode" "$dir" 2>/dev/null || true; }

  tmp=$(mktemp "$dir/.agent-md-state.XXXXXX") || {
    _authority_state_reseal; printf 'cannot create a temporary state file'; return 1; }
  printf '%s\n' "$json" > "$tmp" || {
    rm -f "$tmp"; _authority_state_reseal; printf 'cannot write the state file'; return 1; }
  chmod 0644 "$tmp" || {
    rm -f "$tmp"; _authority_state_reseal; printf 'cannot set the state file mode'; return 1; }
  authority_fsync_path "$tmp" || {
    rm -f "$tmp"; _authority_state_reseal; printf 'cannot flush the state file'; return 1; }
  mv -f "$tmp" "$file" || {
    rm -f "$tmp"; _authority_state_reseal; printf 'cannot replace the state file'; return 1; }
  authority_fsync_path "$dir" || {
    _authority_state_reseal; printf 'cannot flush the state directory'; return 1; }
  _authority_state_reseal
  return 0
}

# authority_state_reserve <project-id> <scope> <run-id>
# Allocates the next sequence and makes it durable BEFORE any check runs.
# Prints "<sequence> <recovered>" where recovered is true when this call also
# took over an abandoned pending.
#
# Recovery is the same single write as an ordinary reservation, deliberately.
# Clearing an abandoned pending first and reserving afterwards would open a
# window in which pending is null and the old last_terminal reads as current
# again -- a crash in that window resurrects a stale PASS. Replacing the pending
# in one atomic transition means the previous terminal is suppressed from before
# the recovery starts until after it ends.
#
# The abandoned sequence stays consumed. It is never reused, and next_sequence
# never moves backwards.
authority_state_reserve() {
  local project_id="$1" scope="$2" run_id="$3" json seq recovered next updated reason
  authority_scope_is_known "$scope" || { printf 'unknown scope %s' "$scope"; return 1; }
  json=$(authority_state_read "$project_id") || { printf '%s' "$json"; return 1; }

  recovered=false
  [ "$(jq -r --arg s "$scope" '.scopes[$s].pending | type' <<<"$json")" = null ] || recovered=true
  seq=$(jq -r --arg s "$scope" '.scopes[$s].next_sequence' <<<"$json")
  next=$(( seq + 1 ))

  updated=$(jq -c --arg s "$scope" --argjson seq "$seq" --argjson next "$next" \
    --arg run "$run_id" '
      .scopes[$s].next_sequence = $next
      | .scopes[$s].pending = {sequence: $seq, run_id: $run, scope: $s}' <<<"$json") \
    || { printf 'cannot compute the reservation'; return 1; }

  if ! reason=$(authority_state_write "$project_id" "$updated"); then
    printf '%s' "$reason"; return 1
  fi
  printf '%s %s' "$seq" "$recovered"
}

# authority_state_commit_terminal <project-id> <scope> <status> <run-id> <fingerprints-json>
# The reserved sequence becomes the published terminal result and the pending is
# cleared, in one write. next_sequence is untouched: it already moved when the
# sequence was reserved.
authority_state_commit_terminal() {
  local project_id="$1" scope="$2" status="$3" run_id="$4" fingerprints="$5"
  local receipt="${6:-null}" key_id="${7:-null}"
  local json seq updated reason
  authority_scope_is_known "$scope" || { printf 'unknown scope %s' "$scope"; return 1; }
  case " $AUTHORITY_TERMINAL_STATUSES " in
    *" $status "*) ;;
    *) printf 'refusing to commit unknown terminal status %s' "$status"; return 1 ;;
  esac
  json=$(authority_state_read "$project_id") || { printf '%s' "$json"; return 1; }

  seq=$(jq -r --arg s "$scope" '.scopes[$s].pending.sequence // empty' <<<"$json")
  [ -n "$seq" ] || { printf 'there is no reserved sequence to conclude'; return 1; }
  [ "$(jq -r --arg s "$scope" '.scopes[$s].pending.run_id' <<<"$json")" = "$run_id" ] \
    || { printf 'the reserved sequence belongs to a different run'; return 1; }

  updated=$(jq -c --arg s "$scope" --argjson seq "$seq" --arg run "$run_id" \
    --arg status "$status" --argjson fp "$fingerprints" \
    --argjson receipt "$receipt" --argjson key_id "$key_id" '
      .scopes[$s].last_terminal = {sequence: $seq, run_id: $run, scope: $s,
                                   status: $status, fingerprints: $fp,
                                   receipt: $receipt, key_id: $key_id}
      | .scopes[$s].pending = null' <<<"$json") \
    || { printf 'cannot compute the terminal transition'; return 1; }

  if ! reason=$(authority_state_write "$project_id" "$updated"); then
    printf '%s' "$reason"; return 1
  fi
  printf '%s' "$seq"
}

# authority_state_release_pending <project-id> <scope> <run-id>
# The controlled incomplete path, and the only way a pending is cleared without
# producing a terminal result.
#
# It is sound only because the caller is alive, still holds the evaluation lock
# and established itself that this evaluation produced no verification result:
# the budget ran out, the run could not be prepared after the reservation, or
# the execution hop never started. In all of those the authority knows there is
# nothing to publish, so the reserved sequence is burned and the previous
# terminal legitimately stays current -- an incomplete attempt is not a verdict
# and must not supersede one.
#
# A process that dies cannot reach this path, which is the point: its pending
# survives and keeps the previous terminal suppressed until a later evaluation
# takes the pending over.
authority_state_release_pending() {
  local project_id="$1" scope="$2" run_id="$3" json updated reason
  authority_scope_is_known "$scope" || { printf 'unknown scope %s' "$scope"; return 1; }
  json=$(authority_state_read "$project_id") || { printf '%s' "$json"; return 1; }
  [ "$(jq -r --arg s "$scope" '.scopes[$s].pending | type' <<<"$json")" = null ] && return 0
  [ "$(jq -r --arg s "$scope" '.scopes[$s].pending.run_id' <<<"$json")" = "$run_id" ] \
    || { printf 'the pending reservation belongs to a different run'; return 1; }

  updated=$(jq -c --arg s "$scope" '.scopes[$s].pending = null' <<<"$json") \
    || { printf 'cannot compute the release'; return 1; }
  if ! reason=$(authority_state_write "$project_id" "$updated"); then
    printf '%s' "$reason"; return 1
  fi
  return 0
}

# authority_state_latest <project-id> <scope>
# What the state says is current, with the suppression rule applied. A pending
# reservation always wins: while one exists the answer is "unresolved", never
# the older terminal underneath it.
authority_state_latest() {
  local project_id="$1" scope="$2" json
  json=$(authority_state_read "$project_id") || { printf '%s' "$json"; return 1; }
  jq -c --arg s "$scope" '
    if (.scopes[$s].pending | type) != "null"
    then {state: "unresolved", pending: .scopes[$s].pending, suppressed: .scopes[$s].last_terminal}
    elif (.scopes[$s].last_terminal | type) != "null"
    then {state: "terminal", terminal: .scopes[$s].last_terminal,
          # A terminal recorded before receipts existed, or one that never
          # published a receipt, names no receipt and is not evidence.
          authenticated: ((.scopes[$s].last_terminal.receipt | type) != "null")}
    else {state: "none"} end' <<<"$json"
}

# Keep workspace-sized manifests out of exec arguments. The subshell owns all
# temporary files (including those of the producers), without changing caller
# traps, umask or TMPDIR. Emit nothing until all four producers and JSON pass.
authority_workspace_identity_json() (
  local scope="${1:-worktree}" identity_tmp
  umask 077
  identity_tmp=$(mktemp -d "${TMPDIR:-/tmp}/agent-md-identity-parts.XXXXXX") || return 1
  trap 'rm -rf -- "$identity_tmp"' EXIT
  trap 'exit 1' HUP INT TERM
  TMPDIR="$identity_tmp" authority_pa_verification_receipt_source_manifest_json "$scope" > "$identity_tmp/source.json" || return 1
  TMPDIR="$identity_tmp" authority_pa_effective_verification_contract_json "$scope" > "$identity_tmp/contract.json" || return 1
  TMPDIR="$identity_tmp" authority_pa_effective_control_requirements_json "$scope" > "$identity_tmp/control.json" || return 1
  TMPDIR="$identity_tmp" authority_pa_verification_receipt_mechanism_manifest_json "$scope" > "$identity_tmp/mechanism.json" || return 1
  jq -nec \
    --slurpfile source "$identity_tmp/source.json" \
    --slurpfile contract "$identity_tmp/contract.json" \
    --slurpfile control "$identity_tmp/control.json" \
    --slurpfile mechanism "$identity_tmp/mechanism.json" '
      if all([$source,$contract,$control,$mechanism][]; length == 1)
      then {source:$source[0],contract:$contract[0],control:$control[0],mechanism:$mechanism[0]}
      else error("each identity manifest must contain exactly one JSON value") end'
)

# authority_identity_fingerprints <identity-file>
# The four fingerprints of one identity document. Shared so that the value bound
# into a run and the value revalidated before a terminal result are produced by
# the same code rather than by two expressions that could drift apart.
authority_identity_fingerprints() {
  local identity="$1" s c k m
  s=$(jq -cS '.source' "$identity" | sha256_hex)
  c=$(jq -cS '.contract' "$identity" | sha256_hex)
  k=$(jq -cS '.control' "$identity" | sha256_hex)
  m=$(jq -cS '.mechanism' "$identity" | sha256_hex)
  jq -nc --arg s "$s" --arg c "$c" --arg k "$k" --arg m "$m" '
    {source:   {algorithm: "sha256", value: $s},
     contract: {algorithm: "sha256", value: $c},
     control:  {algorithm: "sha256", value: $k},
     mechanism:{algorithm: "sha256", value: $m}}'
}

# --- Authenticated receipts --------------------------------------------------
#
# A receipt is the only artefact in this system that can later be shown to
# something that did not watch the evaluation happen. Everything about how it is
# built is therefore about one question: what exactly did the authority commit
# to, and can a validator reconstruct those bytes without trusting anything but
# the public key?
#
# Canonical bytes. The signed value is `jq -cS` over the payload with the
# authentication envelope removed, with no trailing newline. That is this
# project's canonical form, already used for every fingerprint; it is not
# RFC 8785. A validator reproduces it with exactly the same expression.
#
# What is signed is everything that decides acceptance: who issued it, which
# key, which project, workspace, scope and run, the sequence, the terminal
# status, the four Phase A fingerprints, and the coverage. What is deliberately
# not signed is command output, excerpts and timestamps -- output because it is
# untrusted data the receipt should never carry authority for, timestamps
# because freshness here is a sequence, not a clock, and signing one would
# invite a validator to reason about time it cannot verify.
#
# checks[] carries command_identity, never the literal command. The command set
# is already authenticated by the contract fingerprint, which covers the
# contract manifest including each command string. Signing the literal too
# would create a second source of truth that could drift from the first; a
# validator instead recomputes sha256 over the contract's command for that check
# and compares it with command_identity, which is deterministic and needs no
# extra trust.

authority_receipts_dir()   { printf '%s/%s/receipts/%s' "$(projects_dir)" "$1" "$2"; }
authority_receipt_path()   { printf '%s/%s.json' "$(authority_receipts_dir "$1" "$2")" "$3"; }
authority_trusted_keys_dir()  { printf '%s/%s/trusted-keys' "$(projects_dir)" "$1"; }
authority_trusted_key_path()  { printf '%s/%s.pub' "$(authority_trusted_keys_dir "$1")" "$2"; }

# The public vocabulary. The authority's own bookkeeping keeps candidate_pass
# and candidate_fail because those describe an attempt it ran; a receipt states
# a result to someone else, so it says pass or fail and nothing hedged.
# identity_changed maps to no receipt at all.
authority_receipt_status_for() {
  case "$1" in
    candidate_pass) printf 'pass' ;;
    candidate_fail) printf 'fail' ;;
    *) return 1 ;;
  esac
}

# authority_resolve_signing_key
# Read at signing time, not earlier, so that a key swapped or broken during the
# evaluation is caught at the moment it would be used. Everything that makes the
# key usable is rechecked here: the pointer's shape, custody of both files, and
# that the published public key really is the one this key_id names.
authority_resolve_signing_key() {
  local id reason pub computed
  id=$(authority_current_key_id) || { printf 'no issuer key is installed'; return 1; }
  if ! reason=$(authority_key_custody_report "$id"); then
    printf 'the issuer key is not in a usable state: %s' "$reason"; return 1
  fi
  pub=$(authority_public_key_path "$id")
  computed=$(authority_key_id_from_public "$pub") || { printf 'the public key cannot be read'; return 1; }
  [ "$computed" = "$id" ] || { printf 'the key material does not match the key id it is filed under'; return 1; }
  printf '%s' "$id"
}

# authority_sign_canonical <payload-file> <key-id>
# Prints the base64 signature on one line with no embedded newline.
#
# This is the only place the private key is opened. It is opened after every
# descending hop has finished, after the checks, and after revalidation, so no
# child process can ever exist while it is readable. openssl reads it through
# -inkey; it is never an argument, an environment value or captured output.
authority_sign_canonical() {
  local payload="$1" id="$2" priv sig out
  priv=$(authority_private_key_path "$id")
  [ -f "$priv" ] || { printf 'the private key is absent'; return 1; }
  sig=$(mktemp "${TMPDIR:-/tmp}/agent-md-sig.XXXXXX") || { printf 'cannot create a temporary file'; return 1; }
  if ! openssl pkeyutl -sign -inkey "$priv" -rawin -in "$payload" -out "$sig" 2>/dev/null; then
    rm -f "$sig"; printf 'the payload could not be signed'; return 1
  fi
  [ "$(wc -c < "$sig")" -eq 64 ] || { rm -f "$sig"; printf 'the signature is not an Ed25519 signature'; return 1; }
  out=$(base64 -w0 < "$sig" 2>/dev/null || base64 < "$sig" | tr -d '\n')
  rm -f "$sig"
  printf '%s' "$out"
}

# authority_canonical_bytes <receipt-json-file>
# The exact bytes the signature covers, for signing and for verification. The
# authentication envelope is removed first, so a receipt always carries its own
# recipe for reproducing what was signed.
authority_canonical_bytes() {
  jq -cS 'del(.authentication)' "$1" | tr -d '\n'
}

# authority_verify_receipt_signature <receipt-file> <public-key>
# Provided so the round trip can be exercised. Nothing in the product validates
# receipts yet; that arrives with the unprivileged validator.
authority_verify_receipt_signature() {
  local receipt="$1" pub="$2" payload sig value ok
  value=$(jq -r '.authentication.value // empty' "$receipt") || return 1
  [ -n "$value" ] || return 1
  payload=$(mktemp "${TMPDIR:-/tmp}/agent-md-verify.XXXXXX") || return 1
  sig=$(mktemp "${TMPDIR:-/tmp}/agent-md-vsig.XXXXXX") || { rm -f "$payload"; return 1; }
  authority_canonical_bytes "$receipt" > "$payload"
  if ! printf '%s' "$value" | base64 -d > "$sig" 2>/dev/null; then
    rm -f "$payload" "$sig"; return 1
  fi
  if openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$payload" -sigfile "$sig" >/dev/null 2>&1; then
    ok=0
  else
    ok=1
  fi
  rm -f "$payload" "$sig"
  return "$ok"
}

# authority_publish_trusted_key <project-id> <key-id>
# Copies the public key next to the project so a validator never needs to reach
# into the key directory. The copy is only made after recomputing the key id
# from the material itself: filing a key under a name is not evidence that the
# name describes it.
#
# An existing entry is never overwritten. Byte-identical is a no-op; anything
# else is a refusal, because a project's trusted key changing underneath its
# receipts is exactly the substitution this whole design exists to prevent.
authority_publish_trusted_key() {
  local project_id="$1" id="$2" dir target src computed tmp dirmode parent
  src=$(authority_public_key_path "$id")
  [ -f "$src" ] || { printf 'the public key is absent'; return 1; }
  computed=$(authority_key_id_from_public "$src") || { printf 'the public key cannot be read'; return 1; }
  [ "$computed" = "$id" ] || { printf 'the public key does not hash to the key id'; return 1; }

  dir=$(authority_trusted_keys_dir "$project_id")
  target=$(authority_trusted_key_path "$project_id" "$id")
  if [ -e "$target" ]; then
    [ -L "$target" ] && { printf 'the published trusted key is a symlink'; return 1; }
    if cmp -s "$src" "$target"; then return 0; fi
    printf 'a different key is already published for this key id'; return 1
  fi

  parent=$(dirname "$dir")
  dirmode=$(mode_of "$parent")
  chmod u+w "$parent" 2>/dev/null || true
  mkdir -p "$dir" 2>/dev/null || { chmod "$dirmode" "$parent" 2>/dev/null || true
                                   printf 'cannot create the trusted key directory'; return 1; }
  chmod u+w "$dir" 2>/dev/null || true
  tmp=$(mktemp "$dir/.agent-md-key.XXXXXX") || { printf 'cannot stage the trusted key'; return 1; }
  cat < "$src" > "$tmp" || { rm -f "$tmp"; printf 'cannot copy the trusted key'; return 1; }
  chmod 0444 "$tmp" || { rm -f "$tmp"; printf 'cannot set the trusted key mode'; return 1; }
  authority_fsync_path "$tmp" || { rm -f "$tmp"; printf 'cannot flush the trusted key'; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; printf 'cannot publish the trusted key'; return 1; }
  authority_fsync_path "$dir" || true
  chmod 0555 "$dir" 2>/dev/null || true
  [ -n "$dirmode" ] && chmod "$dirmode" "$parent" 2>/dev/null || true
  return 0
}

# authority_publish_receipt <project-id> <scope> <sequence> <receipt-file>
# Durable before the state that will point at it. An existing sequence is
# refused rather than replaced: a receipt is history, and a sequence is issued
# exactly once.
authority_publish_receipt() {
  local project_id="$1" scope="$2" seq="$3" src="$4" dir target tmp parent dirmode
  authority_scope_is_known "$scope" || { printf 'unknown scope %s' "$scope"; return 1; }
  case "$seq" in ''|*[!0-9]*) printf 'the sequence is not a number'; return 1 ;; esac

  dir=$(authority_receipts_dir "$project_id" "$scope")
  target=$(authority_receipt_path "$project_id" "$scope" "$seq")
  parent="$(projects_dir)/$project_id"
  dirmode=$(mode_of "$parent")
  chmod u+w "$parent" 2>/dev/null || true
  mkdir -p "$dir" 2>/dev/null || { chmod "$dirmode" "$parent" 2>/dev/null || true
                                   printf 'cannot create the receipt directory'; return 1; }
  chmod u+w "$dir" 2>/dev/null || true

  if [ -e "$target" ]; then
    chmod 0555 "$dir" 2>/dev/null || true
    [ -n "$dirmode" ] && chmod "$dirmode" "$parent" 2>/dev/null || true
    printf 'a receipt already exists for sequence %s' "$seq"; return 1
  fi

  tmp=$(mktemp "$dir/.agent-md-receipt.XXXXXX") || { printf 'cannot stage the receipt'; return 1; }
  cat < "$src" > "$tmp" || { rm -f "$tmp"; printf 'cannot write the receipt'; return 1; }
  chmod 0444 "$tmp" || { rm -f "$tmp"; printf 'cannot set the receipt mode'; return 1; }
  authority_fsync_path "$tmp" || { rm -f "$tmp"; printf 'cannot flush the receipt'; return 1; }
  mv -f "$tmp" "$target" || { rm -f "$tmp"; printf 'cannot publish the receipt'; return 1; }
  authority_fsync_path "$dir" || { printf 'cannot flush the receipt directory'; return 1; }
  chmod 0555 "$dir" 2>/dev/null || true
  [ -n "$dirmode" ] && chmod "$dirmode" "$parent" 2>/dev/null || true
  return 0
}
