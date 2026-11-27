#!/bin/bash
# block-destructive.sh
# PreToolUse hook for Bash commands.
# Blocks obviously destructive operations before they execute.
#
# Scope: this is a SEATBELT, not a security boundary. It catches the
# most common accidental foot-guns (rm -rf /, a recursive rm whose target is
# unbound or not recoverable from Git, find -delete, git clean, DROP TABLE,
# force push, .env reads). It does NOT catch every destructive path — e.g.
# non-recursive rm, `dd`, shell aliases, obfuscated invocations, or anything
# you `chmod +x` and run. For real isolation, run the agent in a container
# or VM.

# shellcheck source=.claude/hooks/_lib.sh
. "$(dirname "$0")/_lib.sh"

deny() {
  # $1 = stable code, $2 = failure, $3 = recovery guidance
  local result reason
  result=$(policy_result_json "fail" "fatal" "$1" "$2" "$3")
  reason=$(policy_human_message "$result")
  jq -n --arg r "$reason" '{
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "deny",
      permissionDecisionReason: $r
    }
  }'
  exit 0
}

# --- Recursive deletion target integrity ---------------------------------
#
# A recursive rm is authorized automatically only when its target is bound
# before it runs and everything under it is recoverable from Git: tracked and
# unmodified, or absent. Untracked, ignored or modified data is protected, and
# a target outside any Git worktree is unverified, however temporary it looks.
#
# Supported grammar: simple commands joined by ; && || | & or newlines, with
# single and double quotes, backslash escapes, comments and redirections. A
# directory change binds later commands only through an unbroken && chain.
# Anything else that carries a recursive rm (expansions, subshells, groups,
# nested shells, xargs, heredocs) is indeterminate. This is a pre-execution
# check against the filesystem as it is now, not a sandbox.

RM_REC_RE='(^|[^[:alnum:]_-])rm[[:space:]]+(.*[[:space:]])?(-[[:alnum:]]*[rR][[:alnum:]]*|--recursive)([[:space:]]|$)'

# rm_tokenize <text> — fills TOK_KIND (W word, O operator, R redirection),
# TOK_FLAGS (d expansion, g glob, t leading tilde, q quoted) and TOK_TEXT.
rm_tokenize() {
  local s="$1" n i=0 j c nx word="" have=0 flags="" depth
  n=${#s}
  TOK_KIND=(); TOK_FLAGS=(); TOK_TEXT=(); TOK_UNSUPPORTED=0
  rm_flush() {
    [ "$have" = 1 ] && { TOK_KIND+=(W); TOK_FLAGS+=("$flags"); TOK_TEXT+=("$word"); }
    word=""; have=0; flags=""
  }
  rm_op() { rm_flush; TOK_KIND+=(O); TOK_FLAGS+=(""); TOK_TEXT+=("$1"); }
  while [ "$i" -lt "$n" ]; do
    c=${s:i:1}; nx=${s:i+1:1}
    case "$c" in
      ' '|$'\t') rm_flush ;;
      $'\n'|';') rm_op ';' ;;
      '&')
        if [ "$nx" = '&' ]; then rm_op '&&'; i=$((i + 1))
        elif [ "$nx" = '>' ]; then rm_flush; TOK_KIND+=(R); TOK_FLAGS+=(""); TOK_TEXT+=(""); i=$((i + 1))
        else rm_op '&'; fi ;;
      '|')
        if [ "$nx" = '|' ]; then rm_op '||'; i=$((i + 1)); else rm_op '|'; fi ;;
      '('|')') TOK_UNSUPPORTED=1; rm_op "$c" ;;
      '<'|'>')
        if [ "$have" = 1 ] && [ -z "$flags" ] && [[ "$word" =~ ^[0-9]+$ ]]; then word=""; have=0; else rm_flush; fi
        [ "$c$nx" = '<<' ] && TOK_UNSUPPORTED=1
        while [[ "${s:i+1:1}" == [\<\>\&\|] ]]; do i=$((i + 1)); done
        TOK_KIND+=(R); TOK_FLAGS+=(""); TOK_TEXT+=("") ;;
      "'")
        have=1; flags="${flags}q"; j=$((i + 1))
        while [ "$j" -lt "$n" ] && [ "${s:j:1}" != "'" ]; do word+=${s:j:1}; j=$((j + 1)); done
        [ "$j" -lt "$n" ] || TOK_UNSUPPORTED=1
        i=$j ;;
      '"')
        have=1; flags="${flags}q"; j=$((i + 1))
        while [ "$j" -lt "$n" ] && [ "${s:j:1}" != '"' ]; do
          case "${s:j:1}" in
            \\) j=$((j + 1)); word+=${s:j:1} ;;
            '$'|'`') flags="${flags}d"; word+=${s:j:1} ;;
            *) word+=${s:j:1} ;;
          esac
          j=$((j + 1))
        done
        [ "$j" -lt "$n" ] || TOK_UNSUPPORTED=1
        i=$j ;;
      \\)
        if [ "$nx" = $'\n' ]; then i=$((i + 1)); else have=1; word+=$nx; i=$((i + 1)); fi ;;
      '$')
        have=1; flags="${flags}d"; word+='$'
        if [ "$nx" = '(' ] || [ "$nx" = '{' ]; then
          depth=0; j=$((i + 1))
          while [ "$j" -lt "$n" ]; do
            case "${s:j:1}" in
              '('|'{') depth=$((depth + 1)) ;;
              ')'|'}') depth=$((depth - 1)) ;;
            esac
            word+=${s:j:1}
            [ "$depth" -eq 0 ] && break
            j=$((j + 1))
          done
          i=$j
        fi ;;
      '`')
        have=1; flags="${flags}d"; j=$((i + 1))
        while [ "$j" -lt "$n" ] && [ "${s:j:1}" != '`' ]; do word+=${s:j:1}; j=$((j + 1)); done
        i=$j ;;
      '*'|'?'|'[') have=1; flags="${flags}g"; word+=$c ;;
      '~') [ "$have" = 0 ] && flags="${flags}t"; have=1; word+=$c ;;
      '#')
        if [ "$have" = 0 ]; then
          while [ "$i" -lt "$n" ] && [ "${s:i+1:1}" != $'\n' ]; do i=$((i + 1)); done
        else
          word+=$c
        fi ;;
      *) have=1; word+=$c ;;
    esac
    i=$((i + 1))
  done
  rm_flush
}

# rm_git <dir> <args...> — Git without inherited repository selection or locks.
rm_git() {
  local dir="$1"; shift
  env -u GIT_DIR -u GIT_WORK_TREE -u GIT_INDEX_FILE -u GIT_PREFIX GIT_OPTIONAL_LOCKS=0 \
    git -C "$dir" "$@"
}

# rm_check_target <word> <flags> <cwd|""> — sets RM_VERDICT and RM_DETAIL.
rm_check_target() {
  local text="$1" flags="$2" cwd="$3" path trail=0 phys probe top rel status
  case "$flags" in *d*) RM_VERDICT=indeterminate; RM_DETAIL="'${text}' depends on shell expansion"; return ;; esac
  path=$text
  case "$flags" in
    *t*)
      case "$path" in
        \~|\~/*) path="${HOME}${path#\~}" ;;
        *) RM_VERDICT=indeterminate; RM_DETAIL="'${text}' names another user's home"; return ;;
      esac ;;
  esac
  case "$flags" in
    *g*)
      path=${path%%[\*\?\[]*}
      case "$path" in */*) path="${path%/*}/" ;; *) path="./" ;; esac ;;
  esac
  if [ "${path#/}" = "$path" ]; then
    if [ -z "$cwd" ]; then
      RM_VERDICT=indeterminate
      RM_DETAIL="'${text}' is relative to a directory that an earlier step may not have entered"
      return
    fi
    path="$cwd/$path"
  fi
  case "$path" in */) trail=1 ;; esac
  path=$(realpath -m -s -- "$path") || { RM_VERDICT=indeterminate; RM_DETAIL="'${text}' cannot be resolved"; return; }
  if [ "$trail" = 1 ]; then
    phys=$(realpath -m -- "$path")
  else
    phys="$(realpath -m -- "$(dirname -- "$path")")/$(basename -- "$path")"
    [ "$path" = / ] && phys=/
  fi
  if [ ! -e "$phys" ] && [ ! -L "$phys" ]; then RM_VERDICT=allow; return; fi
  probe=$phys
  { [ -d "$phys" ] && { [ ! -L "$phys" ] || [ "$trail" = 1 ]; }; } || probe=$(dirname -- "$phys")
  if ! top=$(rm_git "$probe" rev-parse --show-toplevel 2>/dev/null) || [ -z "$top" ]; then
    RM_VERDICT=unverified; RM_DETAIL=$phys; return
  fi
  top=$(realpath -- "$top") || { RM_VERDICT=indeterminate; RM_DETAIL="the worktree of '${text}' cannot be resolved"; return; }
  if [ "$phys" = "$top" ] || [[ "$top/" == "$phys/"* ]]; then
    RM_VERDICT=protected; RM_DETAIL="${phys}: it contains the whole Git worktree"; return
  fi
  rel=${phys#"$top"/}
  case "$rel" in .git|.git/*) RM_VERDICT=protected; RM_DETAIL="${phys}: it is Git's own data"; return ;; esac
  if ! status=$(rm_git "$top" status --porcelain=v1 --untracked-files=normal --ignored=traditional \
      -- ":(literal)$rel" 2>/dev/null); then
    RM_VERDICT=indeterminate; RM_DETAIL="Git cannot report the state of '${text}'"; return
  fi
  if [ -n "$status" ]; then
    RM_VERDICT=protected
    RM_DETAIL="${rel}: it holds data Git cannot restore ($(printf '%s\n' "$status" | head -n 3 | cut -c1-120 | paste -sd ',' - | sed 's/,/, /g'))"
    return
  fi
  RM_VERDICT=allow
}

# rm_target_verdict <command> <session-cwd> — sets RM_VERDICT (allow,
# indeterminate, protected, unverified) and RM_DETAIL for the first refusal.
rm_target_verdict() {
  local command="$1" cwd="$2" k=0 total kind text flags cmd_words=() cmd_flags=()
  local cd_seen=0 skip_next=0
  RM_VERDICT=allow; RM_DETAIL=""
  { [ -n "$cwd" ] && [ "${cwd#/}" != "$cwd" ] && [ -d "$cwd" ]; } || cwd=$PWD
  rm_tokenize "$command"
  if [ "$TOK_UNSUPPORTED" = 1 ] && printf '%s' "$command" | grep -qE "$RM_REC_RE"; then
    RM_VERDICT=indeterminate; RM_DETAIL="it runs inside a subshell, group or heredoc"; return
  fi
  total=${#TOK_KIND[@]}
  while [ "$k" -le "$total" ]; do
    kind=${TOK_KIND[k]:-O}; text=${TOK_TEXT[k]:-;}; flags=${TOK_FLAGS[k]:-}
    if [ "$kind" = R ]; then skip_next=1; k=$((k + 1)); continue; fi
    if [ "$kind" = W ]; then
      if [ "$skip_next" = 1 ]; then skip_next=0; else cmd_words+=("$text"); cmd_flags+=("$flags"); fi
      k=$((k + 1)); continue
    fi
    # An operator ends a simple command. A directory change keeps binding the
    # following commands only while every connector after it is &&.
    if [ "${#cmd_words[@]}" -gt 0 ]; then
      rm_simple_command
      [ "$RM_VERDICT" = allow ] || return
    fi
    if [ "$cd_seen" = 1 ] && [ "$text" != '&&' ]; then cwd=""; fi
    cmd_words=(); cmd_flags=(); skip_next=0
    k=$((k + 1))
  done
}

# rm_simple_command — reads cmd_words/cmd_flags/cwd/cd_seen of the caller.
rm_simple_command() {
  local w=0 name i rest target=0 recursive=0 targets=() target_flags=()
  while [ "$w" -lt "${#cmd_words[@]}" ]; do
    case "${cmd_flags[w]}:${cmd_words[w]}" in
      *:[A-Za-z_]*=*) w=$((w + 1)) ;;
      *:sudo|*:command|*:builtin|*:exec|*:nohup|*:nice|*:time|*:env) w=$((w + 1))
        while [ "$w" -lt "${#cmd_words[@]}" ] && [[ "${cmd_words[w]}" == -* ]]; do
          case "${cmd_words[w]}" in -u|-g|-C|-D|-n|-p) w=$((w + 1)) ;; esac
          w=$((w + 1))
        done ;;
      *) break ;;
    esac
  done
  [ "$w" -lt "${#cmd_words[@]}" ] || return 0
  case "${cmd_words[w]}" in '{'|'}')
    rest="${cmd_words[*]}"
    if printf '%s' "$rest" | grep -qE "$RM_REC_RE"; then RM_VERDICT=indeterminate; RM_DETAIL="it runs inside a command group"; fi
    return 0 ;;
  esac
  name=${cmd_words[w]##*/}
  case "$name" in
    cd|pushd)
      cd_seen=1
      if [ -z "$cwd" ]; then return 0; fi
      if [ $((w + 1)) -ge "${#cmd_words[@]}" ]; then cwd=$HOME; return 0; fi
      case "${cmd_flags[w+1]}" in *d*|*g*|*t*) cwd=""; return 0 ;; esac
      case "${cmd_words[w+1]}" in
        -) cwd="" ;;
        /*) cwd=$(realpath -m -s -- "${cmd_words[w+1]}") ;;
        *) cwd=$(realpath -m -s -- "$cwd/${cmd_words[w+1]}") ;;
      esac
      return 0 ;;
    popd) cd_seen=1; cwd=""; return 0 ;;
    rm)
      for ((i = w + 1; i < ${#cmd_words[@]}; i++)); do
        if [ "$target" = 0 ] && [[ "${cmd_flags[i]}" != *d* ]]; then
          case "${cmd_words[i]}" in
            --) target=1; continue ;;
            --recursive) recursive=1; continue ;;
            --*) continue ;;
            -?*) [[ "${cmd_words[i]}" == *[rR]* ]] && recursive=1; continue ;;
          esac
        fi
        targets+=("${cmd_words[i]}"); target_flags+=("${cmd_flags[i]}")
      done
      [ "$recursive" = 1 ] || return 0
      for ((i = 0; i < ${#targets[@]}; i++)); do
        rm_check_target "${targets[i]}" "${target_flags[i]}" "$cwd"
        [ "$RM_VERDICT" = allow ] || return 0
      done
      return 0 ;;
    bash|sh|zsh|dash|ksh|fish|eval|xargs|su|ssh|timeout|watch|flock|parallel|script)
      rest="${cmd_words[*]:w+1}"
      if printf '%s' "$rest" | grep -qE "$RM_REC_RE"; then
        RM_VERDICT=indeterminate; RM_DETAIL="it is passed to '${name}', which runs it outside this command"
      fi
      return 0 ;;
    *) return 0 ;;
  esac
}

INPUT=$(cat)
COMMAND=$(echo "$INPUT" | jq -r '.tool_input.command // empty')

if [ -z "$COMMAND" ]; then
  exit 0
fi

# Note: the regex patterns below use single quotes intentionally.
# shellcheck disable=SC2016

# Block recursive deletion of root, cwd, home, or parent directory
if echo "$COMMAND" | grep -qE 'rm\s+(-[a-zA-Z]*f[a-zA-Z]*\s+|(-[a-zA-Z]*\s+)*)(/($|[[:space:];&|])|(~|\$HOME|\.\.)(/|$|[[:space:];&|])|\.($|[[:space:];&|]))'; then
  deny "SAFETY_PATH_VIOLATION" \
    "Blocked destructive rm command targeting root, home, or a parent path." \
    "Run the command manually only after validating the exact target and recovery plan."
fi

# Block a recursive deletion whose target is not bound or not recoverable.
if echo "$COMMAND" | grep -qE '(^|[^[:alnum:]_-])rm([[:space:]]|$)'; then
  rm_target_verdict "$COMMAND" "$(echo "$INPUT" | jq -r '.cwd // empty' 2>/dev/null)"
  case "$RM_VERDICT" in
    indeterminate)
      deny "SAFETY_TARGET_INDETERMINATE" \
        "Blocked recursive deletion whose target cannot be determined before it runs: ${RM_DETAIL}." \
        "Bind the target first (a literal path, and a directory change joined to the deletion only by &&), or run the deletion yourself after confirming the exact target." ;;
    protected)
      deny "SAFETY_TARGET_PROTECTED" \
        "Blocked recursive deletion of ${RM_DETAIL}." \
        "Move or back up that data, or run the deletion yourself after confirming it is disposable." ;;
    unverified)
      deny "SAFETY_TARGET_UNVERIFIED" \
        "Blocked recursive deletion of ${RM_DETAIL}: it is outside any Git worktree, so nothing shows its data is recoverable." \
        "Run the deletion yourself after confirming the target is disposable." ;;
  esac
fi

# Block find -delete / find -exec rm chains
if echo "$COMMAND" | grep -qE 'find\s+.*(-delete|-exec\s+rm)'; then
  deny "SAFETY_DESTRUCTIVE_COMMAND" \
    "Blocked find -delete / find -exec rm." \
    "Run the command manually only after validating its exact targets."
fi

# Block git clean -fdx (wipes untracked + ignored files)
if echo "$COMMAND" | grep -qE 'git\s+clean\s+.*-[a-z]*[fx][a-z]*'; then
  deny "SAFETY_DESTRUCTIVE_COMMAND" \
    "Blocked git clean with force or ignored-file removal; it can wipe untracked or ignored files." \
    "Inspect the candidate paths and run the command manually only if intentional."
fi

# Block database destruction
if echo "$COMMAND" | grep -qiE 'DROP\s+(TABLE|DATABASE)|TRUNCATE\s+TABLE|DELETE\s+FROM\s+\S+\s*;?\s*$'; then
  deny "SAFETY_DESTRUCTIVE_COMMAND" \
    "Blocked destructive database command." \
    "Validate the target, backup, and recovery path, then run it manually if intentional."
fi

# Block force pushes and hard resets against shared refs
if echo "$COMMAND" | grep -qE 'git\s+push\s+.*--force|git\s+push\s+-f([[:space:]]|$)|git\s+reset\s+--hard([[:space:]]|$)'; then
  deny "SAFETY_DESTRUCTIVE_COMMAND" \
    "Blocked force push or hard reset." \
    "Use a recoverable Git operation, or run manually after confirming the affected refs."
fi

# Block .env file reads (credential exposure).
# Match `.env` as a standalone token — NOT `.env.example`, `.environment`, etc.
# After `.env` we require end-of-string, whitespace, or a shell metachar.
if echo "$COMMAND" | grep -qE '(^|[[:space:];&|])(cat|less|head|tail|more|source|grep|sed|awk|bat)([[:space:]][^;&|>]*)?[[:space:]]([^[:space:];&|>]*/)?\.env([[:space:];&|>]|$)|echo.*\$\(.*([^[:space:];&|>]*/)?\.env([[:space:];&|>]|$)'; then
  deny "SAFETY_PATH_VIOLATION" \
    "Blocked .env file access because it can expose credentials." \
    "Use documented variable names or a redacted example instead of reading secrets."
fi

exit 0
