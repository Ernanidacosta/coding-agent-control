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

AUTHORITY_SCHEMA=6
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

owner_of() { stat -c %u "$1" 2>/dev/null || stat -f %u "$1" 2>/dev/null; }
group_of() { stat -c %g "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null; }

digit_has_write() { case "$1" in 2|3|6|7) return 0 ;; esac; return 1; }

world_writable() {
  local mode
  mode=$(mode_of "$1") || return 1
  digit_has_write "${mode: -1}"
}

group_of() { stat -c %g "$1" 2>/dev/null || stat -f %g "$1" 2>/dev/null; }

digit_has_write() { case "$1" in 2|3|6|7) return 0 ;; esac; return 1; }

world_writable() {
  local mode
  mode=$(mode_of "$1") || return 1
  digit_has_write "${mode: -1}"
}

digit_has_write() { case "$1" in 2|3|6|7) return 0 ;; esac; return 1; }

world_writable() {
  local mode
  mode=$(mode_of "$1") || return 1
  digit_has_write "${mode: -1}"
}

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

home_of_user() { passwd_field "$1" 6; }
gids_of_user() { id -G "$1" 2>/dev/null; }

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

gids_of_user() { id -G "$1" 2>/dev/null; }

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
  GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1 HOME=/nonexistent \
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
      digest=$(readlink "$dest/$path" | sha256_hex) || { rm -f "$entries"; return 1; }
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
# A staging root has no service accounts, so it falls back to the current user
# and says so. Production resolves the real runner and nothing else.
authority_runner_identity() {
  local user uid
  if getent passwd "$AUTHORITY_RUNNER_USER" >/dev/null 2>&1; then
    user="$AUTHORITY_RUNNER_USER"
    uid=$(passwd_field "$user" 3) || return 1
  elif is_real_root_prefix; then
    printf 'the %s service account does not exist' "$AUTHORITY_RUNNER_USER"
    return 1
  else
    user=$(id -un); uid=$(id -u)
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
