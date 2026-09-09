#!/bin/bash
# _lib.sh — shared helpers for agent-md hooks.
# Source this from other hooks:  . "$(dirname "$0")/_lib.sh"
#
# Kept minimal on purpose — shell, not Python, so hooks stay dependency-free.
# All functions are safe to call with `set -u` enabled.

# read_toml <file> <section> <key>
# Prints the value or nothing. Handles `key = "value"` or `key = value`.
# Skips lines after `#`. Not a full TOML parser — just enough for our use.
read_toml() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 0
  awk -v section="$section" -v key="$key" '
    BEGIN { in_sec = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      sec = $0
      sub(/^[[:space:]]*\[/, "", sec); sub(/\][[:space:]]*$/, "", sec)
      gsub(/[[:space:]]/, "", sec)
      in_sec = (sec == section) ? 1 : 0
      next
    }
    in_sec && index($0, "=") > 0 {
      k = substr($0, 1, index($0, "=") - 1)
      v = substr($0, index($0, "=") + 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", k)
      sub(/[[:space:]]*#.*$/, "", v)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", v)
      if (k == key) {
        if (v ~ /^".*"$/)      { gsub(/^"|"$/, "", v) }
        else if (v ~ /^'\''.*'\''$/) { gsub(/^'\''|'\''$/, "", v) }
        print v
        exit
      }
    }
  ' "$file"
}

# read_toml_array <file> <section> <key>
# Prints one quoted string per line. Return codes distinguish a valid key
# (0, including an empty array), a missing key/file (1), and malformed
# input (2). This intentionally implements only the string-array subset
# agent-md exposes; it is not a general TOML parser.
read_toml_array() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 1
  awk -v wanted_section="$section" -v wanted_key="$key" '
    function invalid() { bad = 1 }

    function parse_value(text,    i, c) {
      for (i = 1; i <= length(text); i++) {
        c = substr(text, i, 1)

        if (done) {
          if (c == "#") return
          if (c !~ /[[:space:]]/) invalid()
          continue
        }

        if (quoted) {
          if (escaped) {
            value = value c
            escaped = 0
          } else if (quote == "\"" && c == "\\") {
            escaped = 1
          } else if (c == quote) {
            print value
            value = ""
            quoted = 0
            need_separator = 1
          } else {
            value = value c
          }
          continue
        }

        if (c == "#") return
        if (c ~ /[[:space:]]/) continue

        if (!opened) {
          if (c == "[") opened = 1
          else invalid()
          continue
        }

        if (need_separator) {
          if (c == ",") need_separator = 0
          else if (c == "]") done = 1
          else invalid()
          continue
        }

        if (c == "\"" || c == "\047") {
          quoted = 1
          quote = c
        } else if (c == "]") {
          done = 1
        } else {
          invalid()
        }
      }
    }

    BEGIN { in_section = 0 }

    found && !done {
      parse_value($0)
      next
    }

    /^[[:space:]]*#/ { next }

    /^[[:space:]]*\[/ {
      current = $0
      sub(/^[[:space:]]*\[/, "", current)
      sub(/\][[:space:]]*(#.*)?$/, "", current)
      gsub(/[[:space:]]/, "", current)
      in_section = (current == wanted_section)
      next
    }

    in_section && index($0, "=") > 0 {
      candidate = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
      if (candidate == wanted_key) {
        found = 1
        parse_value(substr($0, index($0, "=") + 1))
      }
    }

    END {
      if (bad || (found && (!opened || !done || quoted))) exit 2
      if (!found) exit 1
    }
  ' "$file"
}

# toml_key_present <file> <section> <key>
# Distinguishes an absent scalar from a deliberately empty one. The latter
# matters for executable verification commands: `lint = ""` is invalid,
# not equivalent to an omitted optional check.
toml_key_present() {
  local file="$1" section="$2" key="$3"
  [ -f "$file" ] || return 1
  awk -v section="$section" -v key="$key" '
    BEGIN { in_sec = 0 }
    /^[[:space:]]*#/ { next }
    /^[[:space:]]*\[/ {
      sec = $0
      sub(/^[[:space:]]*\[/, "", sec); sub(/\][[:space:]]*(#.*)?$/, "", sec)
      gsub(/[[:space:]]/, "", sec)
      in_sec = (sec == section)
      next
    }
    in_sec && index($0, "=") > 0 {
      candidate = substr($0, 1, index($0, "=") - 1)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", candidate)
      if (candidate == key) { found = 1; exit }
    }
    END { exit (found ? 0 : 1) }
  ' "$file"
}

# toml_path — location of the config file (override with AGENT_MD_TOML env)
toml_path() {
  echo "${AGENT_MD_TOML:-agent-md.toml}"
}

project_control_path() {
  printf '%s\n' '.project-control.toml'
}

# file_exists_in_snapshot <path> <worktree|staged|head|parent>
file_exists_in_snapshot() {
  local path="$1" scope="${2:-worktree}"
  case "$scope" in
    worktree) [ -f "$path" ] ;;
    staged) git cat-file -e ":${path}" 2>/dev/null ;;
    head) git cat-file -e "HEAD:${path}" 2>/dev/null ;;
    parent) git cat-file -e "HEAD^:${path}" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# file_snapshot <path> <worktree|staged|head|parent>
file_snapshot() {
  local path="$1" scope="${2:-worktree}"
  case "$scope" in
    worktree) [ -f "$path" ] && cat "$path" ;;
    staged) git show ":${path}" 2>/dev/null ;;
    head) git show "HEAD:${path}" 2>/dev/null ;;
    parent) git show "HEAD^:${path}" 2>/dev/null ;;
  esac
}

# snapshot_to_temp <path> <scope> <destination>
# Materializes a snapshot for the deliberately small parsers. An absent file
# becomes an empty config, preserving the existing no-config heuristic mode.
snapshot_to_temp() {
  local path="$1" scope="$2" destination="$3"
  : > "$destination"
  file_exists_in_snapshot "$path" "$scope" || return 0
  file_snapshot "$path" "$scope" > "$destination"
}

risk_rank() {
  case "$1" in
    low) printf '1\n' ;;
    medium) printf '2\n' ;;
    high) printf '3\n' ;;
    critical) printf '4\n' ;;
    *) printf '0\n' ;;
  esac
}

stricter_risk() {
  local first="${1:-}" second="${2:-}"
  if [ "$(risk_rank "$first")" -ge "$(risk_rank "$second")" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# project_control_json_from_content <toml>
# Parses only the root-level schema and risk fields intentionally exposed by
# .project-control.toml. This is not a general TOML parser.
project_control_json_from_content() {
  local content="$1" parsed valid schema risk error
  parsed=$(printf '%s\n' "$content" | awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function fail(message) {
      if (error == "") error = message
    }
    /^[[:space:]]*($|#)/ { next }
    {
      line = $0
      sub(/[[:space:]]*#.*$/, "", line)
      if (line ~ /^[[:space:]]*schema[[:space:]]*=/) {
        schema_count++
        value = line
        sub(/^[[:space:]]*schema[[:space:]]*=[[:space:]]*/, "", value)
        schema = trim(value)
      } else if (line ~ /^[[:space:]]*risk[[:space:]]*=/) {
        risk_count++
        value = line
        sub(/^[[:space:]]*risk[[:space:]]*=[[:space:]]*/, "", value)
        value = trim(value)
        if (value ~ /^"[^"]*"$/ || value ~ /^\047[^\047]*\047$/) {
          risk = substr(value, 2, length(value) - 2)
        } else {
          fail("risk must be a quoted string")
        }
      } else {
        fail("only schema and risk are allowed")
      }
    }
    END {
      if (schema_count != 1 || schema != "1") fail("schema must occur exactly once with value 1")
      if (risk_count != 1) fail("risk must occur exactly once")
      if (risk !~ /^(low|medium|high|critical)$/) fail("risk must be low, medium, high, or critical")
      if (error == "") print "ok\t" schema "\t" risk
      else print "error\t\t\t" error
    }
  ')
  valid=${parsed%%$'\t'*}
  if [ "$valid" = ok ]; then
    schema=$(printf '%s' "$parsed" | cut -f2)
    risk=$(printf '%s' "$parsed" | cut -f3)
    jq -cn --arg risk "$risk" --argjson schema "$schema" \
      '{valid:true, schema:$schema, risk:$risk}'
  else
    error=$(printf '%s' "$parsed" | cut -f4-)
    jq -cn --arg error "$error" \
      '{valid:false, schema:null, risk:null, error:$error}'
  fi
}

# stat_mtime <path> — portable mtime in epoch seconds (Linux + macOS).
stat_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null
}

# file_size <path> — portable byte size (Linux + macOS).
file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null
}

# policy_result_json <status> <severity> <code> <message> <suggestion> [paths]
# Builds the small internal result contract shared by agent-md controls.
# Paths are newline-delimited so filenames containing spaces remain intact.
# Hook wrappers translate this result to each host's existing JSON shape.
policy_result_json() {
  local result_status="$1" severity="$2" code="$3" message="$4"
  local suggestion="$5" paths="${6:-}" paths_json
  paths_json=$(printf '%s' "$paths" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -cn \
    --arg status "$result_status" \
    --arg severity "$severity" \
    --arg code "$code" \
    --arg message "$message" \
    --arg suggestion "$suggestion" \
    --argjson paths "$paths_json" '
      {
        status: $status,
        severity: $severity,
        code: $code,
        message: $message,
        suggestion: $suggestion
      } + if ($paths | length) > 0 then {paths: $paths} else {} end
    '
}

# policy_human_message <policy-result-json>
# Keeps hook output readable while exposing stable severity/code tokens.
policy_human_message() {
  local result="$1" result_status severity code message suggestion paths rendered
  local risk current_status signals missing_requirement
  severity=$(printf '%s' "$result" | jq -r '.severity | ascii_upcase')
  code=$(printf '%s' "$result" | jq -r '.code')
  message=$(printf '%s' "$result" | jq -r '.message')
  suggestion=$(printf '%s' "$result" | jq -r '.suggestion // empty')
  paths=$(printf '%s' "$result" | jq -r '(.paths // []) | join(", ")')
  risk=$(printf '%s' "$result" | jq -r '.risk // empty')
  current_status=$(printf '%s' "$result" | jq -r '.current_status // empty')
  signals=$(printf '%s' "$result" | jq -r '(.observed_signals // []) | join(", ")')
  missing_requirement=$(printf '%s' "$result" | jq -r '.missing_requirement // empty')
  result_status=$(printf '%s' "$result" | jq -r '.status')

  rendered="[${severity} ${code}] ${message}"
  [ -z "$risk" ] || rendered="${rendered} Risk: ${risk}."
  [ -z "$current_status" ] || rendered="${rendered} Current status: ${current_status}."
  [ -z "$signals" ] || rendered="${rendered} Signals: ${signals}."
  if [ "$result_status" != pass ] && [ -n "$missing_requirement" ]; then
    rendered="${rendered} Missing: ${missing_requirement}."
  fi
  [ -z "$paths" ] || rendered="${rendered} Paths: ${paths}."
  [ -z "$suggestion" ] || rendered="${rendered} Recovery: ${suggestion}"
  printf '%s\n' "$rendered"
}

# detect_pm — prints the detected Node package manager based on lockfile,
# or nothing. Order: pnpm > yarn > bun > npm > (nothing).
detect_pm() {
  if   [ -f "pnpm-lock.yaml" ];                       then echo pnpm
  elif [ -f "yarn.lock" ];                            then echo yarn
  elif [ -f "bun.lockb" ] || [ -f "bun.lock" ];       then echo bun
  elif [ -f "package-lock.json" ] || [ -f "package.json" ]; then echo npm
  fi
}

# npm_test_cmd — prints the test-runner invocation for the detected PM,
# or nothing if no JS project was detected.
npm_test_cmd() {
  case "$(detect_pm)" in
    pnpm) echo "pnpm test --silent" ;;
    yarn) echo "yarn test --silent" ;;
    bun)  echo "bun test" ;;
    npm)  echo "npm test --silent" ;;
    *)    echo "" ;;
  esac
}

# has_npm_test_script — returns 0 if package.json declares a real test script.
has_npm_test_script() {
  [ -f "package.json" ] || return 1
  local t
  t=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  [ -n "$t" ] && [ "$t" != 'echo "Error: no test specified" && exit 1' ]
}

verification_check_names() {
  printf '%s\n' typecheck lint test integration smoke runtime independent approval
}

# infer_verification_command <check>
# Heuristics are deliberately small and observable. Explicit [verify]
# commands always win. Empty output means no fallback was detected.
infer_verification_command() {
  local check="$1" npm_command
  case "$check" in
    typecheck)
      if [ -f tsconfig.json ]; then
        printf '%s\n' 'npx --no-install tsc --noEmit'
      elif [ -f mypy.ini ] || grep -q '\[tool.mypy\]' pyproject.toml 2>/dev/null; then
        printf '%s\n' 'mypy .'
      elif [ -f Cargo.toml ]; then
        printf '%s\n' 'cargo check'
      fi
      ;;
    lint)
      if compgen -G '.eslintrc*' >/dev/null || compgen -G 'eslint.config.*' >/dev/null; then
        printf '%s\n' 'npx --no-install eslint .'
      elif [ -f ruff.toml ] || [ -f .ruff.toml ] \
        || grep -q '\[tool.ruff' pyproject.toml 2>/dev/null; then
        printf '%s\n' 'ruff check .'
      fi
      ;;
    test)
      npm_command=$(npm_test_cmd)
      if [ -n "$npm_command" ] && has_npm_test_script; then
        printf '%s\n' "$npm_command"
      elif [ -f pytest.ini ] || grep -q '\[tool.pytest' pyproject.toml 2>/dev/null; then
        printf '%s\n' 'pytest --tb=short -q'
      elif [ -f Cargo.toml ]; then
        printf '%s\n' 'cargo test'
      fi
      ;;
  esac
}

verification_invalid_contract_json() {
  local message="$1" suggestion="${2:-Fix agent-md.toml before running verification.}"
  local result
  result=$(policy_result_json fail error CONFIG_INVALID "$message" "$suggestion")
  jq -cn --argjson error "$result" '{valid:false, checks:[], error:$error}'
}

# verification_contract_json [config]
# Resolves the complete, deterministic contract without executing checks.
# The intentionally small schema uses only existing scalar/string-array
# parser support:
#   [verify] <check> = "command"
#   [verify.policy] required = ["lint", "test"]
#   [verify.policy] timeout_seconds = 300
# Without `required`, resolved checks retain the legacy required behavior.
verification_contract_json() {
  local config="${1:-$(toml_path)}" required_values required_status
  local required_declared=0 timeout_value="" rows='[]' check command origin requirement
  local seen_required="" value row trusted_values trusted_status trusted_files
  local capability_values capability_status capabilities

  required_values=$(read_toml_array "$config" verify.policy required)
  required_status=$?
  case "$required_status" in
    0) required_declared=1 ;;
    1) required_values="" ;;
    *)
      verification_invalid_contract_json \
        "Invalid ${config}: verify.policy.required must be an array of quoted check names."
      return 0
      ;;
  esac

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    case "$value" in
      typecheck|lint|test|integration|smoke|runtime) ;;
      *)
        verification_invalid_contract_json \
          "Invalid ${config}: unknown required verification check '${value}'."
        return 0
        ;;
    esac
    if printf '%s\n' "$seen_required" | grep -qxF "$value"; then
      verification_invalid_contract_json \
        "Invalid ${config}: required verification check '${value}' is duplicated."
      return 0
    fi
    if [ -n "$seen_required" ]; then
      seen_required="${seen_required}
${value}"
    else
      seen_required="$value"
    fi
  done <<EOF
$required_values
EOF

  if toml_key_present "$config" verify.policy timeout_seconds; then
    timeout_value=$(read_toml "$config" verify.policy timeout_seconds)
    case "$timeout_value" in
      ''|*[!0-9]*|0)
        verification_invalid_contract_json \
          "Invalid ${config}: verify.policy.timeout_seconds must be a positive integer."
        return 0
        ;;
    esac
  fi

  while IFS= read -r check; do
    command=""
    origin="not configured"
    trusted_files='[]'
    capabilities='[]'
    if toml_key_present "$config" verify "$check"; then
      command=$(read_toml "$config" verify "$check")
      if [ -z "$command" ]; then
        verification_invalid_contract_json \
          "Invalid ${config}: verify.${check} is configured with an empty command."
        return 0
      fi
      if ! bash -n -c "$command" >/dev/null 2>&1; then
        verification_invalid_contract_json \
          "Invalid ${config}: verify.${check} is not valid shell syntax."
        return 0
      fi
      origin="configured"
    else
      command=$(infer_verification_command "$check")
      [ -z "$command" ] || origin="inferred"
    fi

    if [ "$check" = independent ] || [ "$check" = approval ]; then
      requirement="conditional"
      trusted_values=$(read_toml_array "$config" verify.attestation "${check}_files")
      trusted_status=$?
      case "$trusted_status" in
        0)
          while IFS= read -r value; do
            [ -n "$value" ] || continue
            case "$value" in
              /*|..|../*|*/../*|*/..)
                verification_invalid_contract_json \
                  "Invalid ${config}: verify.attestation.${check}_files must contain repository-relative paths without traversal."
                return 0
                ;;
            esac
            if printf '%s' "$trusted_files" | jq -e --arg value "$value" 'index($value) != null' >/dev/null; then
              verification_invalid_contract_json \
                "Invalid ${config}: trusted attestation file '${value}' is duplicated for ${check}."
              return 0
            fi
            trusted_files=$(printf '%s' "$trusted_files" | jq -c --arg value "$value" '. + [$value]')
          done <<EOF
$trusted_values
EOF
          ;;
        1) ;;
        *)
          verification_invalid_contract_json \
            "Invalid ${config}: verify.attestation.${check}_files must be an array of quoted repository-relative paths."
          return 0
          ;;
      esac

      capability_values=$(read_toml_array "$config" verify.attestation "${check}_capabilities")
      capability_status=$?
      case "$capability_status" in
        0)
          if [ "$origin" != configured ]; then
            verification_invalid_contract_json \
              "Invalid ${config}: verify.attestation.${check}_capabilities requires verify.${check}."
            return 0
          fi
          while IFS= read -r value; do
            [ -n "$value" ] || continue
            if ! printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'; then
              verification_invalid_contract_json \
                "Invalid ${config}: verify.attestation.${check}_capabilities must contain literal command names, not paths or shell expressions."
              return 0
            fi
            if printf '%s' "$capabilities" | jq -e --arg value "$value" 'index($value) != null' >/dev/null; then
              verification_invalid_contract_json \
                "Invalid ${config}: attestation capability '${value}' is duplicated for ${check}."
              return 0
            fi
            capabilities=$(printf '%s' "$capabilities" | jq -c --arg value "$value" '. + [$value]')
          done <<EOF
$capability_values
EOF
          ;;
        1) ;;
        *)
          verification_invalid_contract_json \
            "Invalid ${config}: verify.attestation.${check}_capabilities must be an array of quoted command names."
          return 0
          ;;
      esac
    elif [ "$required_declared" -eq 1 ]; then
      if printf '%s\n' "$required_values" | grep -qxF "$check"; then
        requirement="required"
      else
        requirement="optional"
      fi
    elif [ "$origin" = "not configured" ]; then
      requirement="optional"
    else
      requirement="required"
    fi

    row=$(jq -cn \
      --arg name "$check" \
      --arg requirement "$requirement" \
      --arg origin "$origin" \
      --arg command "$command" \
      --argjson trusted_files "$trusted_files" \
      --argjson capabilities "$capabilities" \
      '{name:$name, requirement:$requirement, origin:$origin, command:$command,
        trusted_files:$trusted_files, capabilities:$capabilities}')
    rows=$(printf '%s' "$rows" | jq -c --argjson row "$row" '. + [$row]')
  done <<EOF
$(verification_check_names)
EOF

  jq -cn \
    --argjson checks "$rows" \
    --arg timeout "$timeout_value" \
    --arg mode "$(if [ "$required_declared" -eq 1 ]; then printf explicit; else printf legacy; fi)" '
      {
        valid: true,
        policy: $mode,
        timeout_seconds: (if $timeout == "" then null else ($timeout | tonumber) end),
        checks: $checks
      }
    '
}

# merge_verification_contracts <baseline-json> <proposal-json>
# Required commands from either side remain required. Distinct required
# commands for the same check both run; this avoids guessing whether a command
# replacement weakens or strengthens the guarantee. Conditional attestation
# declarations remain singular and continue through their existing HEAD trust
# validation.
merge_verification_contracts() {
  local baseline="$1" proposal="$2"
  if [ "$(printf '%s' "$baseline" | jq -r '.valid')" != true ]; then
    printf '%s\n' "$baseline"
    return 0
  fi
  if [ "$(printf '%s' "$proposal" | jq -r '.valid')" != true ]; then
    printf '%s\n' "$proposal"
    return 0
  fi

  jq -cn --argjson baseline "$baseline" --argjson proposal "$proposal" '
    def ordinary:
      [($baseline.checks + $proposal.checks)[] |
        select(.name != "independent" and .name != "approval")]
      | group_by([.name, .command])
      | map(
          . as $group
          | $group[0]
          | .requirement = (if any($group[]; .requirement == "required") then "required" else "optional" end)
          | .origin = (if any($group[]; .origin == "configured") then "configured"
                       elif any($group[]; .origin == "inferred") then "inferred"
                       else "not configured" end)
        );
    def spec($contract; $name):
      [$contract.checks[] | select(.name == $name)][0];
    def attestation($name):
      (spec($baseline; $name)) as $old
      | (spec($proposal; $name)) as $new
      | if $old.origin == "configured" and $new.origin != "configured" then $old
        else $new
        end;
    ([ $baseline.timeout_seconds, $proposal.timeout_seconds ] | map(select(. != null))) as $timeouts
    | {
        valid: true,
        policy: "effective",
        timeout_seconds: (if ($timeouts | length) == 0 then null else ($timeouts | min) end),
        checks: (ordinary + [attestation("independent"), attestation("approval")]),
        baseline_contract: $baseline,
        proposal_contract: $proposal
      }
  '
}

# effective_verification_contract_json [worktree|staged]
effective_verification_contract_json() {
  local scope="${1:-worktree}" config baseline_file proposal_file
  local baseline proposal merged
  config=$(toml_path)

  # A config outside the repository cannot be a Git-bound baseline. It remains
  # supported as a proposal for compatibility, but never erases the empty
  # baseline contract.
  case "$config" in
    /*|*'..'*)
      baseline=$(verification_contract_json /dev/null)
      proposal=$(verification_contract_json "$config")
      merge_verification_contracts "$baseline" "$proposal"
      return 0
      ;;
  esac

  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-config.XXXXXX") || return 1
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-config.XXXXXX") || {
    rm -f "$baseline_file"
    return 1
  }
  snapshot_to_temp "$config" head "$baseline_file"
  snapshot_to_temp "$config" "$scope" "$proposal_file"
  baseline=$(verification_contract_json "$baseline_file")
  proposal=$(verification_contract_json "$proposal_file")
  rm -f "$baseline_file" "$proposal_file"
  merged=$(merge_verification_contracts "$baseline" "$proposal")
  printf '%s\n' "$merged"
}

# verification_command_preflight <command>
# Returns 0 for an obviously available direct command, 1 for an obviously
# unavailable one, 2 when safe static inspection cannot decide, and 3 for
# invalid shell syntax. It never executes the configured check.
verification_command_preflight() {
  local command="$1" first rest
  bash -n -c "$command" >/dev/null 2>&1 || return 3
  rest="$command"
  while :; do
    first=${rest%%[[:space:]]*}
    [ "$first" = "$rest" ] && rest="" || rest=${rest#"$first"}
    rest=${rest#"${rest%%[![:space:]]*}"}
    case "$first" in
      *=*) [ -n "$rest" ] || return 2 ;;
      ''|'!'|'('|'{') return 2 ;;
      *) break ;;
    esac
  done
  first=${first#\"}; first=${first%\"}
  first=${first#\'}; first=${first%\'}
  # shellcheck disable=SC2016 # case patterns intentionally match literal shell syntax.
  case "$first" in
    *'$('*|*'`'*|*'|'*|*'&'*|*';'*|*'<'*|*'>'*) return 2 ;;
  esac
  command -v "$first" >/dev/null 2>&1 && return 0
  [ -x "$first" ] && return 0
  return 1
}

verification_result_json() {
  local status="$1" severity="$2" code="$3" message="$4" suggestion="$5"
  local check="$6" requirement="$7" origin="$8" command="$9"
  local exit_code="${10:-}" evidence="${11:-}" truncated="${12:-false}"
  jq -cn \
    --arg status "$status" --arg severity "$severity" --arg code "$code" \
    --arg message "$message" --arg suggestion "$suggestion" \
    --arg check "$check" --arg requirement "$requirement" \
    --arg origin "$origin" --arg command "$command" \
    --arg exit_code "$exit_code" --arg evidence "$evidence" \
    --argjson truncated "$truncated" '
      {
        status:$status, severity:$severity, code:$code,
        message:$message, suggestion:$suggestion,
        check:$check, requirement:$requirement, origin:$origin,
        command:$command, evidence:$evidence, truncated:$truncated
      } + if $exit_code == "" then {} else {exit_code:($exit_code | tonumber)} end
    '
}

run_verification_check() {
  local spec="$1" timeout_seconds="${2:-}" name requirement origin command
  local output_file exit_code evidence line_count truncated=false timeout_command="" label
  local status severity code message suggestion
  name=$(printf '%s' "$spec" | jq -r '.name')
  requirement=$(printf '%s' "$spec" | jq -r '.requirement')
  origin=$(printf '%s' "$spec" | jq -r '.origin')
  command=$(printf '%s' "$spec" | jq -r '.command')
  label=$(printf '%s' "$name" | tr '[:lower:]' '[:upper:]')

  if [ "$origin" = "not configured" ]; then
    verification_result_json \
      "$(if [ "$requirement" = required ]; then printf fail; else printf warn; fi)" \
      "$(if [ "$requirement" = required ]; then printf error; else printf warning; fi)" \
      VERIFY_UNAVAILABLE \
      "$(if [ "$requirement" = required ]; then printf Required; else printf Optional; fi) verification check '${name}' has no configured or inferred command." \
      "Configure verify.${name} in agent-md.toml and rerun agent-md-verify." \
      "$name" "$requirement" "$origin" "" "" "No command was resolved."
    return 0
  fi

  output_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-verify.XXXXXX") || {
    verification_result_json fail error VERIFY_UNAVAILABLE \
      "Verification check '${name}' could not create diagnostic output storage." \
      "Check temporary-directory permissions and rerun agent-md-verify." \
      "$name" "$requirement" "$origin" "$command" "" "The check did not run."
    return 0
  }

  if [ -n "$timeout_seconds" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout_command=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_command=gtimeout
    else
      rm -f "$output_file"
      verification_result_json \
        "$(if [ "$requirement" = required ]; then printf fail; else printf warn; fi)" \
        "$(if [ "$requirement" = required ]; then printf error; else printf warning; fi)" \
        VERIFY_UNAVAILABLE \
        "Verification check '${name}' requires a timeout utility, but neither timeout nor gtimeout is available." \
        "Install a compatible timeout utility or remove verify.policy.timeout_seconds, then rerun agent-md-verify." \
        "$name" "$requirement" "$origin" "$command" "" "The check did not run."
      return 0
    fi
    if "$timeout_command" "${timeout_seconds}s" bash -c "$command" >"$output_file" 2>&1; then
      exit_code=0
    else
      exit_code=$?
    fi
  elif bash -c "$command" >"$output_file" 2>&1; then
    exit_code=0
  else
    exit_code=$?
  fi

  line_count=$(wc -l < "$output_file" | tr -d ' ')
  evidence=$(awk 'NR <= 30' "$output_file")
  if [ -z "$evidence" ]; then
    evidence="No output; exit code ${exit_code}."
  fi
  if [ "${line_count:-0}" -gt 30 ]; then truncated=true; fi
  rm -f "$output_file"

  if [ "$exit_code" -eq 0 ]; then
    status=pass; severity=info; code=VERIFY_PASSED
    message="Verification check '${name}' (${label}, ${requirement}, ${origin}) passed."
    suggestion=""
  elif [ "$exit_code" -eq 124 ]; then
    code=VERIFY_TIMEOUT
    message="Verification check '${name}' (${label}, ${requirement}, ${origin}) exceeded ${timeout_seconds} seconds."
    suggestion="Inspect the hanging check and rerun agent-md-verify."
    if [ "$requirement" = required ]; then status=fail; severity=error; else status=warn; severity=warning; fi
  elif [ "$exit_code" -eq 126 ] || [ "$exit_code" -eq 127 ]; then
    code=VERIFY_UNAVAILABLE
    message="Verification check '${name}' (${label}, ${requirement}, ${origin}) was not executable."
    suggestion="Install or correct the command, then rerun agent-md-verify."
    if [ "$requirement" = required ]; then status=fail; severity=error; else status=warn; severity=warning; fi
  else
    if [ "$requirement" = required ]; then
      status=fail; severity=error; code=VERIFY_REQUIRED_FAILED
      message="Required verification check '${name}' (${label}, ${origin}) failed."
    else
      status=warn; severity=warning; code=VERIFY_OPTIONAL_FAILED
      message="Optional verification check '${name}' (${label}, ${origin}) failed."
    fi
    suggestion="Fix the failing check and rerun agent-md-verify."
  fi

  verification_result_json "$status" "$severity" "$code" "$message" "$suggestion" \
    "$name" "$requirement" "$origin" "$command" "$exit_code" "$evidence" "$truncated"
}

# run_resolved_verification_contract <contract-json>
# Returns one JSON summary. Exit status is intentionally always zero so hook
# wrappers can translate results without `set -e` surprises; `.status` is the
# authoritative control signal.
run_resolved_verification_contract() {
  local contract="$1" error_result results_file
  local spec result timeout_seconds resolved_count=0 results status
  if [ "$(printf '%s' "$contract" | jq -r '.valid')" != true ]; then
    error_result=$(printf '%s' "$contract" | jq -c '.error')
    jq -cn --argjson contract "$contract" --argjson result "$error_result" \
      '{status:"fail", contract:$contract, results:[$result]}'
    return 0
  fi

  timeout_seconds=$(printf '%s' "$contract" | jq -r '.timeout_seconds // empty')
  results_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-results.XXXXXX") || {
    error_result=$(policy_result_json fail error VERIFY_UNAVAILABLE \
      "Verification could not create result storage." \
      "Check temporary-directory permissions and rerun agent-md-verify.")
    jq -cn --argjson contract "$contract" --argjson result "$error_result" \
      '{status:"fail", contract:$contract, results:[$result]}'
    return 0
  }

  while IFS= read -r spec; do
    [ -n "$spec" ] || continue
    if [ "$(printf '%s' "$spec" | jq -r '.requirement')" = conditional ]; then
      continue
    elif [ "$(printf '%s' "$spec" | jq -r '.origin')" != "not configured" ]; then
      resolved_count=$((resolved_count + 1))
      result=$(run_verification_check "$spec" "$timeout_seconds")
      printf '%s\n' "$result" >> "$results_file"
    elif [ "$(printf '%s' "$spec" | jq -r '.requirement')" = required ]; then
      result=$(run_verification_check "$spec" "$timeout_seconds")
      printf '%s\n' "$result" >> "$results_file"
    fi
  done < <(printf '%s' "$contract" | jq -c '.checks[]')

  if [ "$resolved_count" -eq 0 ] && [ ! -s "$results_file" ]; then
    result=$(verification_result_json warn warning VERIFY_NOT_CONFIGURED \
      "No verification checks were configured or inferred; completion is unverified." \
      "Declare verification commands in agent-md.toml." \
      contract optional "not configured" "" "" "No checks ran.")
    printf '%s\n' "$result" >> "$results_file"
  fi

  results=$(jq -sc '.' "$results_file")
  rm -f "$results_file"
  status=$(printf '%s' "$results" | jq -r '
    if any(.[]; .status == "fail") then "fail"
    elif any(.[]; .status == "warn") then "warn"
    else "pass" end
  ')
  jq -cn --arg status "$status" --argjson contract "$contract" --argjson results "$results" \
    '{status:$status, contract:$contract, results:$results}'
}

# run_verification_contract [config]
# Backward-compatible single-config entry point used by downstream installs.
run_verification_contract() {
  local config="${1:-$(toml_path)}" contract
  contract=$(verification_contract_json "$config")
  run_resolved_verification_contract "$contract"
}

# run_effective_verification_contract [worktree|staged]
# Shared entry point for Stop, pre-commit, verify, and doctor. It executes the
# conservative union of the Git baseline and the current proposal.
run_effective_verification_contract() {
  local scope="${1:-worktree}" contract
  contract=$(effective_verification_contract_json "$scope")
  run_resolved_verification_contract "$contract"
}

verification_result_human() {
  local result="$1" base check requirement origin command exit_code evidence truncated
  local anchor_path anchor_location anchor_integrity anchor_trust attestation_kind attestation_origin attestation_commit
  base=$(policy_human_message "$result")
  check=$(printf '%s' "$result" | jq -r '.check // empty')
  requirement=$(printf '%s' "$result" | jq -r '.requirement // empty')
  origin=$(printf '%s' "$result" | jq -r '.origin // empty')
  command=$(printf '%s' "$result" | jq -r '.command // empty')
  exit_code=$(printf '%s' "$result" | jq -r '.exit_code // empty')
  evidence=$(printf '%s' "$result" | jq -r '.evidence // empty')
  truncated=$(printf '%s' "$result" | jq -r '.truncated // false')
  printf '%s\n' "$base"
  [ -z "$check" ] || printf 'Check: %s (%s, %s)\n' "$check" "$requirement" "$origin"
  [ -z "$command" ] || printf 'Command: %s\n' "$command"
  [ -z "$exit_code" ] || printf 'Exit code: %s\n' "$exit_code"
  if [ -n "$evidence" ]; then
    printf 'Evidence:\n%s\n' "$evidence"
  fi
  if [ "$truncated" = true ]; then
    printf 'Evidence truncated to 30 lines; rerun the command above for complete output.\n'
  fi
  anchor_path=$(printf '%s' "$result" | jq -r '.trust_anchor.path // empty')
  if [ -n "$anchor_path" ]; then
    anchor_location=$(printf '%s' "$result" | jq -r '.trust_anchor.location // "unknown"')
    anchor_integrity=$(printf '%s' "$result" | jq -r '.trust_anchor.integrity // "unknown"')
    anchor_trust=$(printf '%s' "$result" | jq -r '.trust_anchor.trust // "unknown"')
    printf 'Trust anchor: %s (%s, %s, %s)\n' \
      "$anchor_path" "$anchor_location" "$anchor_integrity" "$anchor_trust"
  fi
  attestation_kind=$(printf '%s' "$result" | jq -r '.attestation.kind // empty')
  if [ -n "$attestation_kind" ]; then
    attestation_origin=$(printf '%s' "$result" | jq -r '.attestation.origin // "unknown"')
    attestation_commit=$(printf '%s' "$result" | jq -r '.attestation.target.commit // "unbound"')
    printf 'Attestation: %s from %s for commit %s\n' \
      "$attestation_kind" "$attestation_origin" "$attestation_commit"
  fi
}

verification_summary_human() {
  local summary="$1" selector="${2:-all}" result
  while IFS= read -r result; do
    [ -n "$result" ] || continue
    verification_result_human "$result"
    printf '\n'
  done < <(printf '%s' "$summary" | jq -c --arg selector "$selector" '
    .results[] |
    select($selector == "all" or .status == $selector or
      ($selector == "nonpass" and .status != "pass"))
  ')
}

# Defaults intentionally favor executable product/test code. Metadata and
# agent infrastructure are excluded separately. scripts/** and tools/**
# are not ignored: executable files there match the extension globs below.
default_source_globs() {
  printf '%s\n' \
    'src/**' 'app/**' 'apps/**' 'lib/**' 'packages/**' \
    'test/**' 'tests/**' 'spec/**' \
    '*.c' '*.cc' '*.cpp' '*.cxx' '*.h' '*.hpp' '*.cs' \
    '*.go' '*.java' '*.kt' '*.kts' '*.php' '*.py' '*.pyi' \
    '*.rb' '*.rs' '*.scala' '*.swift' \
    '*.sh' '*.bash' '*.zsh' '*.bats' \
    '*.js' '*.jsx' '*.mjs' '*.cjs' '*.ts' '*.tsx' \
    '*.vue' '*.svelte' '*.astro' '*.html' \
    '*.css' '*.scss' '*.sass' '*.less' \
    '*.sql' '*.graphql' '*.gql' '*.proto' '*.tf'
}

default_ignore_globs() {
  printf '%s\n' \
    'memory/**' 'docs/**' '.agent/**' '.agent-md/**' '.agents/**' \
    '.claude/**' '.codex/**' '.cursor/**' '.githooks/**' \
    '.github/**' '.windsurf/**' \
    '*.md' 'LICENSE' 'LICENSE.*' \
    '.gitignore' '.gitattributes' '.editorconfig' '.ai-memory.toml' \
    '.project-control.toml' \
    'agent-md.toml' 'agent-md.toml.example'
}

state_globs_json() {
  local config="$1" sources ignores parsed status source_json ignore_json
  parsed=$(read_toml_array "$config" state source_globs)
  status=$?
  case "$status" in
    0) sources="$parsed" ;;
    1) sources=$(default_source_globs) ;;
    *)
      jq -cn --arg error "Invalid ${config}: state.source_globs must be an array of quoted strings." \
        '{valid:false,error:$error,source_globs:[],ignore_globs:[]}'
      return 0
      ;;
  esac

  parsed=$(read_toml_array "$config" state ignore_globs)
  status=$?
  case "$status" in
    0) ignores="$parsed" ;;
    1) ignores=$(default_ignore_globs) ;;
    *)
      jq -cn --arg error "Invalid ${config}: state.ignore_globs must be an array of quoted strings." \
        '{valid:false,error:$error,source_globs:[],ignore_globs:[]}'
      return 0
      ;;
  esac

  source_json=$(printf '%s' "$sources" | jq -Rsc 'split("\n") | map(select(length > 0))')
  ignore_json=$(printf '%s' "$ignores" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -cn --argjson sources "$source_json" --argjson ignores "$ignore_json" \
    '{valid:true,source_globs:$sources,ignore_globs:$ignores}'
}

# load_state_globs — populates the two newline-delimited globals below.
# A configured key replaces its default independently. Empty arrays are
# therefore meaningful and must not be confused with absent keys.
load_state_globs() {
  local config resolved
  config=$(toml_path)
  AGENT_MD_STATE_ERROR=""
  resolved=$(state_globs_json "$config")
  if [ "$(printf '%s' "$resolved" | jq -r '.valid')" != true ]; then
    AGENT_MD_STATE_ERROR=$(printf '%s' "$resolved" | jq -r '.error')
    return 2
  fi
  AGENT_MD_SOURCE_GLOBS=$(printf '%s' "$resolved" | jq -r '.source_globs[]')
  AGENT_MD_IGNORE_GLOBS=$(printf '%s' "$resolved" | jq -r '.ignore_globs[]')
}

# load_effective_state_globs [worktree|staged]
# Keeps separate classifiers and treats a path as relevant when either the
# established baseline or the current proposal considers it relevant.
load_effective_state_globs() {
  local scope="${1:-worktree}" config baseline_file proposal_file baseline proposal
  config=$(toml_path)
  AGENT_MD_STATE_ERROR=""
  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-state.XXXXXX") || return 2
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-state.XXXXXX") || {
    rm -f "$baseline_file"
    return 2
  }
  case "$config" in
    /*|*'..'*) : > "$baseline_file"; cp "$config" "$proposal_file" 2>/dev/null || : > "$proposal_file" ;;
    *) snapshot_to_temp "$config" head "$baseline_file"; snapshot_to_temp "$config" "$scope" "$proposal_file" ;;
  esac
  baseline=$(state_globs_json "$baseline_file")
  proposal=$(state_globs_json "$proposal_file")
  if [ "$(printf '%s' "$baseline" | jq -r '.valid')" != true ]; then
    AGENT_MD_STATE_ERROR=$(printf '%s' "$baseline" | jq -r '.error')
    AGENT_MD_STATE_ERROR=${AGENT_MD_STATE_ERROR//$baseline_file/$config}
    rm -f "$baseline_file" "$proposal_file"
    return 2
  fi
  if [ "$(printf '%s' "$proposal" | jq -r '.valid')" != true ]; then
    AGENT_MD_STATE_ERROR=$(printf '%s' "$proposal" | jq -r '.error')
    AGENT_MD_STATE_ERROR=${AGENT_MD_STATE_ERROR//$proposal_file/$config}
    rm -f "$baseline_file" "$proposal_file"
    return 2
  fi
  rm -f "$baseline_file" "$proposal_file"
  AGENT_MD_BASELINE_SOURCE_GLOBS=$(printf '%s' "$baseline" | jq -r '.source_globs[]')
  AGENT_MD_BASELINE_IGNORE_GLOBS=$(printf '%s' "$baseline" | jq -r '.ignore_globs[]')
  AGENT_MD_PROPOSAL_SOURCE_GLOBS=$(printf '%s' "$proposal" | jq -r '.source_globs[]')
  AGENT_MD_PROPOSAL_IGNORE_GLOBS=$(printf '%s' "$proposal" | jq -r '.ignore_globs[]')
}

path_matches_globs() {
  local path="$1" patterns="$2" pattern
  while IFS= read -r pattern; do
    [ -n "$pattern" ] || continue
    # shellcheck disable=SC2254
    case "$path" in
      $pattern) return 0 ;;
    esac
  done <<EOF
$patterns
EOF
  return 1
}

path_is_operationally_relevant() {
  local path="$1"
  path_matches_globs "$path" "$AGENT_MD_IGNORE_GLOBS" && return 1
  path_matches_globs "$path" "$AGENT_MD_SOURCE_GLOBS"
}

path_is_effectively_relevant() {
  local path="$1"
  if ! path_matches_globs "$path" "$AGENT_MD_BASELINE_IGNORE_GLOBS" \
    && path_matches_globs "$path" "$AGENT_MD_BASELINE_SOURCE_GLOBS"; then
    return 0
  fi
  if ! path_matches_globs "$path" "$AGENT_MD_PROPOSAL_IGNORE_GLOBS" \
    && path_matches_globs "$path" "$AGENT_MD_PROPOSAL_SOURCE_GLOBS"; then
    return 0
  fi
  return 1
}

changed_files() {
  local scope="${1:-worktree}"
  if [ "$scope" = "staged" ]; then
    git diff --cached --name-only -- 2>/dev/null
    return
  fi
  {
    git diff --name-only -- 2>/dev/null
    git diff --cached --name-only -- 2>/dev/null
    git ls-files --others --exclude-standard 2>/dev/null
  } | sort -u
}

filter_operationally_relevant_files() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if path_is_operationally_relevant "$file"; then
      printf '%s\n' "$file"
    fi
  done
}

filter_effectively_relevant_files() {
  local file
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if path_is_effectively_relevant "$file"; then
      printf '%s\n' "$file"
    fi
  done
}

# validate_progress_content <markdown>
# Validates the deliberately small operational-state format. This is a
# line-oriented contract checker, not a general Markdown parser.
validate_progress_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function fail(message) {
      if (!bad) print message
      bad = 1
    }
    function body_item(line, section_name) {
      if (line == "None") return 1
      if (line ~ /^- [^[:space:]]/) return 1
      fail(section_name " must contain list items or the literal None.")
      return 0
    }

    BEGIN { stage = 0; section = "preamble" }

    /^<!--/ { if ($0 !~ /-->/) in_comment = 1; next }
    in_comment { if ($0 ~ /-->/) in_comment = 0; next }

    /^# / {
      h1_count++
      if ($0 != "# Progress") fail("The document must start with exactly # Progress.")
      next
    }

    /^## / {
      heading = substr($0, 4)
      if (heading == "Current") {
        current_count++
        if (stage != 0) fail("## Current must be the first section.")
        stage = 1; section = "current"
      } else if (heading == "Scope") {
        scope_count++
        if (stage != 1) fail("Optional ## Scope must follow ## Current.")
        stage = 2; section = "scope"
      } else if (heading == "Next") {
        next_count++
        if (stage != 1 && stage != 2) fail("## Next must follow ## Current or ## Scope.")
        stage = 3; section = "next"
      } else if (heading == "Blockers") {
        blockers_count++
        if (stage != 3) fail("## Blockers must follow ## Next.")
        stage = 4; section = "blockers"
      } else if (heading == "Recently Completed") {
        recent_section_count++
        if (stage != 4) fail("## Recently Completed must follow ## Blockers.")
        stage = 5; section = "recent"
      } else {
        fail("Unknown progress section: ## " heading ".")
        section = "unknown"
      }
      next
    }

    /^[[:space:]]*$/ { next }

    {
      if (section == "current") {
        if ($0 ~ /^Status:/) {
          status_count++
          status_value = trim(substr($0, 8))
        } else if ($0 ~ /^Task:/) {
          task_count++
          task_value = trim(substr($0, 6))
        } else if ($0 ~ /^Risk:/) {
          risk_count++
          risk_value = trim(substr($0, 6))
        } else {
          fail("## Current accepts only Status, Task, and Risk fields.")
        }
      } else if (section == "scope") {
        if ($0 ~ /^- [^[:space:]]/) scope_item_count++
        else fail("## Scope must contain non-empty list items.")
      } else if (section == "next") {
        if (body_item($0, "## Next")) next_item_count++
      } else if (section == "blockers") {
        if (body_item($0, "## Blockers")) blocker_item_count++
      } else if (section == "recent") {
        if (body_item($0, "## Recently Completed")) {
          recent_body_count++
          if ($0 ~ /^- /) recent_item_count++
        }
      } else if (section == "preamble") {
        fail("Only blank lines are allowed before ## Current.")
      } else {
        fail("Content appears under an invalid progress section.")
      }
    }

    END {
      if (h1_count != 1) fail("The document must contain exactly one # Progress heading.")
      if (current_count != 1 || next_count != 1 || blockers_count != 1 || recent_section_count != 1 || stage != 5)
        fail("Required sections are ## Current, optional ## Scope, ## Next, ## Blockers, and ## Recently Completed in that order.")
      if (scope_count > 1) fail("The document may contain at most one ## Scope section.")
      if (status_count != 1) fail("## Current must contain exactly one Status field.")
      if (status_value !~ /^(planned|active|blocked|verifying|done)$/)
        fail("Status must be planned, active, blocked, verifying, or done.")
      if (task_count > 1) fail("## Current may contain at most one Task field.")
      if (status_value ~ /^(active|blocked|verifying)$/ && (task_count != 1 || task_value == ""))
        fail("Task is required when Status is active, blocked, or verifying.")
      if (scope_count == 1 && scope_item_count == 0) fail("Remove an empty ## Scope section or add at least one path glob.")
      if (next_item_count == 0) fail("## Next must explicitly contain list items or None.")
      if (blocker_item_count == 0) fail("## Blockers must explicitly contain list items or None.")
      if (recent_body_count == 0) fail("## Recently Completed must explicitly contain list items or None.")
      if (recent_item_count > 5) fail("## Recently Completed may contain at most five items.")
      exit (bad ? 1 : 0)
    }
  '
}

progress_status_from_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^## Current$/ { current = 1; next }
    /^## / { current = 0 }
    current && /^Status:/ {
      value = substr($0, 8)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  '
}

progress_scope_from_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^## Scope$/ { scope = 1; next }
    /^## / { scope = 0 }
    scope && /^- [^[:space:]]/ { print substr($0, 3) }
  '
}

progress_risk_count_from_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^## Current$/ { current = 1; next }
    /^## / { current = 0 }
    current && /^Risk:/ { count++ }
    END { print count + 0 }
  '
}

progress_risk_from_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^## Current$/ { current = 1; next }
    /^## / { current = 0 }
    current && /^Risk:/ {
      value = substr($0, 6)
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      print value
      exit
    }
  '
}

progress_risk_candidate_json() {
  local content="$1" count risk
  if [ -z "$content" ]; then
    jq -cn '{present:false,valid:true,risk:null}'
    return 0
  fi
  count=$(progress_risk_count_from_content "$content")
  risk=$(progress_risk_from_content "$content")
  if [ "$count" -eq 0 ]; then
    jq -cn '{present:false,valid:true,risk:null}'
  elif [ "$count" -eq 1 ] && printf '%s\n' "$risk" | grep -Eq '^(low|medium|high|critical)$'; then
    jq -cn --arg risk "$risk" '{present:true,valid:true,risk:$risk}'
  else
    jq -cn --arg risk "$risk" \
      '{present:true,valid:false,risk:(if $risk == "" then null else $risk end),error:"Risk must occur once and be low, medium, high, or critical."}'
  fi
}

snapshot_relation_to_head() {
  local path="$1" scope="${2:-worktree}" baseline_file proposal_file relation
  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-file.XXXXXX") || return 1
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-file.XXXXXX") || {
    rm -f "$baseline_file"
    return 1
  }
  if file_exists_in_snapshot "$path" head; then
    file_snapshot "$path" head > "$baseline_file"
    if ! file_exists_in_snapshot "$path" "$scope"; then
      relation=deleted
    else
      file_snapshot "$path" "$scope" > "$proposal_file"
      if cmp -s "$baseline_file" "$proposal_file"; then relation=established; else relation=proposed; fi
    fi
  elif file_exists_in_snapshot "$path" "$scope"; then
    relation=proposed
  else
    relation=absent
  fi
  rm -f "$baseline_file" "$proposal_file"
  printf '%s\n' "$relation"
}

# effective_control_requirements_json [worktree|staged]
# Resolves Git-bound baseline plus current proposal without executing checks or
# external verifiers. Git proves content/binding, not human authorship.
effective_control_requirements_json() {
  local scope="${1:-worktree}" control_path progress_path config
  local baseline_source=none baseline_risk="" baseline_valid=true legacy=false
  local head_declared_risk="" parent_risk="" baseline_authority="git-bound"
  local proposal_control_risk="" proposal_progress_risk="" proposal_risk=""
  local proposal_valid=true control_content progress_content parsed candidate
  local effective_risk="" downgrade=none downgrade_authority=none results='[]' result contract policy_status
  control_path=$(project_control_path)
  progress_path=memory/progress.md
  config=$(toml_path)

  if file_exists_in_snapshot "$control_path" head; then
    control_content=$(file_snapshot "$control_path" head)
    parsed=$(project_control_json_from_content "$control_content")
    baseline_source=project-control
    if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
      baseline_risk=$(printf '%s' "$parsed" | jq -r '.risk')
      head_declared_risk="$baseline_risk"
    else
      baseline_valid=false
      result=$(policy_result_json fail error CONTROL_INVALID \
        "The Git-bound .project-control.toml baseline is invalid: $(printf '%s' "$parsed" | jq -r '.error')." \
        "Restore a reviewed schema = 1 control record with one valid risk value." "$control_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  elif file_exists_in_snapshot "$progress_path" head; then
    progress_content=$(file_snapshot "$progress_path" head)
    candidate=$(progress_risk_candidate_json "$progress_content")
    if [ "$(printf '%s' "$candidate" | jq -r '.valid')" = true ] \
      && [ "$(printf '%s' "$candidate" | jq -r '.present')" = true ]; then
      baseline_source="legacy-progress"
      baseline_risk=$(printf '%s' "$candidate" | jq -r '.risk')
      legacy=true
    elif [ "$(printf '%s' "$candidate" | jq -r '.valid')" != true ]; then
      baseline_valid=false
      result=$(policy_result_json fail error CONTROL_INVALID \
        "The legacy tracked progress Risk baseline is invalid." \
        "Correct the tracked legacy Risk or explicitly establish .project-control.toml." "$progress_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  fi

  if file_exists_in_snapshot "$control_path" "$scope"; then
    control_content=$(file_snapshot "$control_path" "$scope")
    parsed=$(project_control_json_from_content "$control_content")
    if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
      proposal_control_risk=$(printf '%s' "$parsed" | jq -r '.risk')
    else
      proposal_valid=false
      result=$(policy_result_json fail error CONTROL_INVALID \
        "The proposed .project-control.toml is invalid: $(printf '%s' "$parsed" | jq -r '.error')." \
        "Use only schema = 1 and one quoted risk value: low, medium, high, or critical." "$control_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  elif [ "$baseline_source" = project-control ]; then
    result=$(policy_result_json warn warning CONTROL_BASELINE_REQUIRED \
      "The Git-bound project control record is absent from the current proposal; its guarantees remain effective." \
      "Restore .project-control.toml or establish a reviewed replacement baseline." "$control_path")
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  if file_exists_in_snapshot "$progress_path" "$scope"; then
    progress_content=$(file_snapshot "$progress_path" "$scope")
    candidate=$(progress_risk_candidate_json "$progress_content")
    if [ "$(printf '%s' "$candidate" | jq -r '.valid')" != true ]; then
      proposal_valid=false
      result=$(policy_result_json fail error RISK_INVALID \
        "The local completion claim contains an invalid Risk proposal." \
        "Correct or remove the local Risk field; it cannot override the Git-bound baseline." "$progress_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    elif [ "$(printf '%s' "$candidate" | jq -r '.present')" = true ]; then
      proposal_progress_risk=$(printf '%s' "$candidate" | jq -r '.risk')
    fi
  fi

  proposal_risk=$(stricter_risk "$proposal_control_risk" "$proposal_progress_risk")
  effective_risk=$(stricter_risk "$baseline_risk" "$proposal_risk")
  if [ -n "$baseline_risk" ] && [ -n "$proposal_risk" ] \
    && [ "$(risk_rank "$proposal_risk")" -lt "$(risk_rank "$baseline_risk")" ]; then
    downgrade=pending
    result=$(policy_result_json warn warning CONTROL_RISK_DOWNGRADE_PENDING \
      "The proposed Risk downgrade does not reduce the effective requirements." \
      "Establish the lower Risk through a reviewed Git baseline or an authority-separated approval verifier." "$control_path")
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  contract=$(effective_verification_contract_json "$scope")
  policy_status=$(snapshot_relation_to_head "$config" "$scope")
  if [ "$(printf '%s' "$contract" | jq -r '.valid')" != true ]; then
    result=$(printf '%s' "$contract" | jq -c '.error')
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  # When a strong approval verifier is configured, a downgrade committed in
  # HEAD relative to its parent remains pending until that verifier approves
  # the exact HEAD target. Without such a provider, HEAD is an explicitly
  # human-established/out-of-band baseline; Git binds content but cannot prove
  # who authored it.
  if [ -n "$head_declared_risk" ] && git rev-parse --verify HEAD^ >/dev/null 2>&1; then
    if file_exists_in_snapshot "$control_path" parent; then
      parsed=$(project_control_json_from_content "$(file_snapshot "$control_path" parent)")
      if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
        parent_risk=$(printf '%s' "$parsed" | jq -r '.risk')
      fi
    elif file_exists_in_snapshot "$progress_path" parent; then
      candidate=$(progress_risk_candidate_json "$(file_snapshot "$progress_path" parent)")
      if [ "$(printf '%s' "$candidate" | jq -r '.valid and .present')" = true ]; then
        parent_risk=$(printf '%s' "$candidate" | jq -r '.risk')
      fi
    fi
    if [ -n "$parent_risk" ] \
      && [ "$(risk_rank "$head_declared_risk")" -lt "$(risk_rank "$parent_risk")" ]; then
      if [ "$(printf '%s' "$contract" | jq -r '[.checks[] | select(.name == "approval")][0].origin // "not configured"')" = configured ]; then
        baseline_risk="$parent_risk"
        proposal_risk=$(stricter_risk "$head_declared_risk" "$proposal_progress_risk")
        effective_risk=$(stricter_risk "$baseline_risk" "$proposal_risk")
        downgrade=pending
        downgrade_authority=approval
        baseline_authority="approval-required"
      else
        baseline_authority="human-established-out-of-band"
      fi
    fi
  fi

  jq -cn \
    --arg source "$baseline_source" --arg baseline_risk "$baseline_risk" \
    --arg proposal_risk "$proposal_risk" --arg effective_risk "$effective_risk" \
    --arg downgrade "$downgrade" --arg downgrade_authority "$downgrade_authority" \
    --arg baseline_authority "$baseline_authority" --arg policy_status "$policy_status" \
    --argjson baseline_valid "$baseline_valid" --argjson proposal_valid "$proposal_valid" \
    --argjson legacy "$legacy" --argjson contract "$contract" --argjson results "$results" '
      {
        valid: ($baseline_valid and $proposal_valid and $contract.valid),
        source: $source,
        legacy: $legacy,
        baseline: {risk:(if $baseline_risk == "" then null else $baseline_risk end), authority:$baseline_authority},
        proposal: {risk:(if $proposal_risk == "" then null else $proposal_risk end)},
        effective: {risk:(if $effective_risk == "" then null else $effective_risk end)},
        risk_downgrade: $downgrade,
        downgrade_authority: $downgrade_authority,
        policy: {status:$policy_status, contract:$contract},
        results: $results
      }
    '
}

risk_result_json() {
  local result_status="$1" severity="$2" code="$3" message="$4"
  local suggestion="$5" risk="$6" current_status="$7" signals="${8:-}"
  local paths="${9:-}" missing_requirement="${10:-}" base signals_json
  base=$(policy_result_json "$result_status" "$severity" "$code" "$message" "$suggestion" "$paths")
  signals_json=$(printf '%s' "$signals" | jq -Rsc 'split("\n") | map(select(length > 0))')
  jq -cn \
    --argjson base "$base" --arg risk "$risk" --arg current_status "$current_status" \
    --arg missing_requirement "$missing_requirement" --argjson signals "$signals_json" '
      $base + {
        risk: (if $risk == "" then null else $risk end),
        current_status: $current_status,
        observed_signals: $signals
      } + if $missing_requirement == "" then {} else {missing_requirement:$missing_requirement} end
    '
}

risk_changed_files() {
  local scope="${1:-worktree}" modified_files
  load_effective_state_globs "$scope" || return 2
  modified_files=$(changed_files "$scope")
  printf '%s\n' "$modified_files" | filter_effectively_relevant_files
}

risk_file_has_destructive_sql() {
  local file="$1" scope="${2:-worktree}" diff_content
  case "$file" in *.sql) ;; *) return 1 ;; esac
  if [ "$scope" = staged ]; then
    diff_content=$(git diff --cached --unified=0 -- "$file" 2>/dev/null)
  elif git ls-files --error-unmatch "$file" >/dev/null 2>&1; then
    diff_content=$(git diff HEAD --unified=0 -- "$file" 2>/dev/null)
  elif [ -f "$file" ]; then
    diff_content=$(sed 's/^/+/' "$file")
  else
    return 1
  fi
  printf '%s\n' "$diff_content" \
    | grep -Eiv '^\+\+\+' \
    | grep -Eiq '^\+.*(DROP[[:space:]]+TABLE|TRUNCATE([[:space:]]+TABLE)?|DELETE[[:space:]]+FROM)'
}

# risk_signals_for_files <newline-paths> [worktree|staged]
# Signals are audit hints, never an automatic risk classification.
risk_signals_for_files() {
  local files="$1" scope="${2:-worktree}" file lower signals=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    lower=$(printf '%s' "$file" | tr '[:upper:]' '[:lower:]')
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(auth|authentication|authorization)([/_.-]|$)'; then
      signals="${signals}\nauth"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(permission|permissions|rbac|acl)([/_.-]|$)'; then
      signals="${signals}\npermissions"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(credential|credentials|secret|secrets|vault)([/_.-]|$)'; then
      signals="${signals}\ncredentials"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(production|prod)([/_.-]|$)'; then
      signals="${signals}\nproduction"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(payment|payments|billing|checkout|invoice)([/_.-]|$)'; then
      signals="${signals}\npayments"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(migration|migrations|schema)([/_.-]|$)'; then
      signals="${signals}\nmigration"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(infra|infrastructure|terraform|deploy|deployment|k8s|helm)([/_.-]|$)|\.tf$'; then
      signals="${signals}\ninfrastructure"
    fi
    if printf '%s\n' "$lower" | grep -Eq '(^|[/_.-])(openapi|swagger|public-api|public_api)([/_.-]|$)|(^|/)public/api/|(^|/)api/public/'; then
      signals="${signals}\npublic-api"
    fi
    if risk_file_has_destructive_sql "$file" "$scope"; then
      signals="${signals}\ndestructive-db"
    fi
  done <<EOF
$files
EOF
  printf '%b\n' "$signals" | awk 'NF' | sort -u
}

risk_underrating_signals() {
  local risk="$1" signals="$2" signal
  while IFS= read -r signal; do
    [ -n "$signal" ] || continue
    case "$risk:$signal" in
      low:*|medium:*|high:credentials|high:production|high:destructive-db|\
      high:payments|high:public-api) printf '%s\n' "$signal" ;;
    esac
  done <<EOF
$signals
EOF
}

# The verifier declaration itself is trusted only when its exact command was
# already present in the factual HEAD version of agent-md.toml. Full trust also
# requires attestation_trust_anchor_json: this helper remains public for legacy
# callers that only need the config-provenance predicate.
risk_evidence_command_trusted() {
  local config="$1" check="$2" head_config head_command current_command
  case "$config" in /*|*'..'*) return 1 ;; esac
  git rev-parse --verify HEAD >/dev/null 2>&1 || return 1
  git cat-file -e "HEAD:${config}" 2>/dev/null || return 1
  head_config=$(mktemp "${TMPDIR:-/tmp}/agent-md-head-config.XXXXXX") || return 1
  if ! git show "HEAD:${config}" > "$head_config" 2>/dev/null; then
    rm -f "$head_config"
    return 1
  fi
  if ! toml_key_present "$head_config" verify "$check"; then
    rm -f "$head_config"
    return 1
  fi
  head_command=$(read_toml "$head_config" verify "$check")
  current_command=$(read_toml "$config" verify "$check")
  rm -f "$head_config"
  [ -n "$head_command" ] && [ "$head_command" = "$current_command" ]
}

# attestation_anchor_result_json <eligible> <check> <command> <path>
#   <location> <integrity> <executable> <reason> <trusted-files-json>
attestation_anchor_result_json() {
  local eligible="$1" check="$2" command="$3" path="$4" location="$5"
  local integrity="$6" executable="$7" reason="$8" trusted_files="${9:-[]}"
  jq -cn \
    --argjson eligible "$eligible" --arg check "$check" --arg command "$command" \
    --arg path "$path" --arg location "$location" --arg integrity "$integrity" \
    --argjson executable "$executable" --arg reason "$reason" \
    --argjson trusted_files "$trusted_files" '
      {
        eligible:$eligible,
        check:$check,
        command:$command,
        path:$path,
        location:$location,
        integrity:$integrity,
        executable:$executable,
        trust:(if $eligible then "eligible" else "untrusted" end),
        reason:$reason,
        trusted_files:$trusted_files
      }
    '
}

attestation_command_is_direct_path() {
  local command="$1"
  [ -n "$command" ] || return 1
  case "$command" in
    *[[:space:]]*|*';'*|*'|'*|*'&'*|*'<'*|*'>'*|*'`'*|*'$'*|*'('*|*')'*|*'{'*|*'}'*) return 1 ;;
  esac
  return 0
}

attestation_path_has_traversal() {
  case "$1" in ..|../*|*/../*|*/..) return 0 ;; esac
  return 1
}

attestation_file_world_writable() {
  local mode
  mode=$(stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1" 2>/dev/null) || return 1
  case "$mode" in *[2367]) return 0 ;; esac
  return 1
}

# attestation_trust_anchor_json <config> <independent|approval>
# Performs read-only trust-anchor validation. Repo-local anchors and their
# explicitly declared files must be ordinary, unchanged HEAD blobs. External
# anchors are environment-managed: agent-md checks direct-path executability,
# rejects symlinks and detectable executor/world-writable files or immediate
# directories, but does not pretend to audit the wider host filesystem.
attestation_trust_anchor_json() {
  local config="$1" check="$2" command="" root path="" relative="" location="unknown"
  local integrity="unknown" executable=false reason="" head_config current_files head_files
  local current_status head_status trusted_files='[]' file mode resolved
  local current_capabilities head_capabilities current_capability_status head_capability_status

  case "$check" in independent|approval) ;;
    *)
      attestation_anchor_result_json false "$check" "" "" unknown invalid false invalid-kind
      return 0
      ;;
  esac

  command=$(read_toml "$config" verify "$check")
  if [ -z "$command" ]; then
    attestation_anchor_result_json false "$check" "" "" unknown missing false not-configured
    return 0
  fi
  if ! risk_evidence_command_trusted "$config" "$check"; then
    attestation_anchor_result_json false "$check" "$command" "$command" unknown config-changed false config-not-in-head
    return 0
  fi
  if ! attestation_command_is_direct_path "$command"; then
    attestation_anchor_result_json false "$check" "$command" "$command" unknown invalid false not-direct-path
    return 0
  fi
  if attestation_path_has_traversal "$command"; then
    attestation_anchor_result_json false "$check" "$command" "$command" unknown invalid false path-traversal
    return 0
  fi

  head_config=$(mktemp "${TMPDIR:-/tmp}/agent-md-head-config.XXXXXX") || {
    attestation_anchor_result_json false "$check" "$command" "$command" unknown unavailable false temp-unavailable
    return 0
  }
  if ! git show "HEAD:${config}" > "$head_config" 2>/dev/null; then
    rm -f "$head_config"
    attestation_anchor_result_json false "$check" "$command" "$command" unknown config-changed false config-not-in-head
    return 0
  fi
  current_files=$(read_toml_array "$config" verify.attestation "${check}_files")
  current_status=$?
  head_files=$(read_toml_array "$head_config" verify.attestation "${check}_files")
  head_status=$?
  current_capabilities=$(read_toml_array "$config" verify.attestation "${check}_capabilities")
  current_capability_status=$?
  head_capabilities=$(read_toml_array "$head_config" verify.attestation "${check}_capabilities")
  head_capability_status=$?
  rm -f "$head_config"
  if [ "$current_status" -ne "$head_status" ] || [ "$current_files" != "$head_files" ]; then
    attestation_anchor_result_json false "$check" "$command" "$command" unknown config-changed false trusted-files-config-changed
    return 0
  fi
  if [ "$current_capability_status" -ne "$head_capability_status" ] \
    || [ "$current_capabilities" != "$head_capabilities" ]; then
    attestation_anchor_result_json false "$check" "$command" "$command" unknown config-changed false capabilities-config-changed
    return 0
  fi
  if [ "$current_status" -eq 0 ]; then
    trusted_files=$(printf '%s' "$current_files" | jq -Rsc 'split("\n") | map(select(length > 0))')
  fi

  root=$(git rev-parse --show-toplevel 2>/dev/null) || {
    attestation_anchor_result_json false "$check" "$command" "$command" unknown unavailable false not-in-git
    return 0
  }
  root=$(cd "$root" 2>/dev/null && pwd -P) || {
    attestation_anchor_result_json false "$check" "$command" "$command" unknown unavailable false root-unavailable
    return 0
  }

  case "$command" in
    /*) path="$command" ;;
    */*) path="$root/${command#./}" ;;
    *)
      resolved=$(command -v "$command" 2>/dev/null || true)
      case "$resolved" in /*) path="$resolved" ;; *) path="$command" ;; esac
      ;;
  esac

  case "$path" in
    "$root"/*)
      location="repo-local"
      relative=${path#"$root"/}
      if [ "$current_status" -ne 0 ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" undeclared false trusted-files-not-declared "$trusted_files"
        return 0
      fi
      if [ -L "$path" ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" symlink false symlink "$trusted_files"
        return 0
      fi
      if [ ! -f "$path" ]; then
        reason=missing
        git cat-file -e "HEAD:${relative}" 2>/dev/null || reason=not-in-head
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" missing false "$reason" "$trusted_files"
        return 0
      fi
      if ! git cat-file -e "HEAD:${relative}" 2>/dev/null; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" worktree-only false not-in-head "$trusted_files"
        return 0
      fi
      mode=$(git ls-tree HEAD -- "$relative" | awk 'NR == 1 { print $1 }')
      if [ "$mode" != 100755 ] || [ ! -x "$path" ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" mode-mismatch false not-executable "$trusted_files"
        return 0
      fi
      if ! git diff --quiet HEAD -- "$relative"; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" modified true modified "$trusted_files"
        return 0
      fi
      integrity="clean-vs-head"
      executable=true
      ;;
    *)
      location="external"
      if [ -L "$path" ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" symlink false symlink "$trusted_files"
        return 0
      fi
      if [ ! -f "$path" ] || [ ! -x "$path" ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" unavailable false missing-or-not-executable "$trusted_files"
        return 0
      fi
      if attestation_file_world_writable "$path"; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" world-writable true world-writable "$trusted_files"
        return 0
      fi
      if [ -w "$path" ] || [ -w "$(dirname "$path")" ]; then
        attestation_anchor_result_json false "$check" "$command" "$path" "$location" executor-writable true executor-writable "$trusted_files"
        return 0
      fi
      integrity="environment-managed"
      executable=true
      ;;
  esac

  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if attestation_path_has_traversal "$file"; then
      attestation_anchor_result_json false "$check" "$command" "$path" "$location" trusted-file-invalid "$executable" trusted-file-traversal "$trusted_files"
      return 0
    fi
    file=${file#./}
    if [ -L "$root/$file" ]; then
      attestation_anchor_result_json false "$check" "$command" "$path" "$location" trusted-file-symlink "$executable" trusted-file-symlink "$trusted_files"
      return 0
    fi
    if [ ! -f "$root/$file" ] || ! git cat-file -e "HEAD:${file}" 2>/dev/null; then
      attestation_anchor_result_json false "$check" "$command" "$path" "$location" trusted-file-missing "$executable" trusted-file-not-in-head "$trusted_files"
      return 0
    fi
    if ! git diff --quiet HEAD -- "$file"; then
      attestation_anchor_result_json false "$check" "$command" "$path" "$location" trusted-file-modified "$executable" trusted-file-modified "$trusted_files"
      return 0
    fi
  done <<EOF
$current_files
EOF

  attestation_anchor_result_json true "$check" "$command" "$path" "$location" "$integrity" "$executable" eligible "$trusted_files"
}

attestation_current_target_json() {
  local scope="${1:-worktree}" relevant_files status head
  head=$(git rev-parse --verify HEAD 2>/dev/null) || {
    jq -cn '{eligible:false, binding:"none", reason:"head-unavailable", relevant_paths:[]}'
    return 0
  }
  relevant_files=$(risk_changed_files "$scope")
  status=$?
  if [ "$status" -ne 0 ]; then
    jq -cn '{eligible:false, binding:"none", reason:"classifier-unavailable", relevant_paths:[]}'
    return 0
  fi
  if [ -n "$relevant_files" ]; then
    jq -cn --arg commit "$head" \
      --argjson paths "$(printf '%s' "$relevant_files" | jq -Rsc 'split("\n") | map(select(length > 0))')" \
      '{eligible:false, binding:"unsupported-dirty-worktree", reason:"operational-worktree-dirty",
        commit:$commit, relevant_paths:$paths}'
    return 0
  fi
  jq -cn --arg commit "$head" \
    '{eligible:true, binding:"commit", commit:$commit, relevant_paths:[]}'
}

attestation_execution_json() {
  local anchor="$1" timeout_seconds="${2:-}" path stdout_file stderr_file exit_code
  local timeout_command="" stdout stderr stdout_lines stderr_lines truncated=false
  path=$(printf '%s' "$anchor" | jq -r '.path')
  stdout_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-attestation-out.XXXXXX") || return 1
  stderr_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-attestation-err.XXXXXX") || {
    rm -f "$stdout_file"
    return 1
  }
  if [ -n "$timeout_seconds" ]; then
    if command -v timeout >/dev/null 2>&1; then
      timeout_command=timeout
    elif command -v gtimeout >/dev/null 2>&1; then
      timeout_command=gtimeout
    else
      rm -f "$stdout_file" "$stderr_file"
      jq -cn '{exit_code:127, stdout:"", stderr:"timeout utility unavailable", truncated:false}'
      return 0
    fi
    if "$timeout_command" "${timeout_seconds}s" "$path" >"$stdout_file" 2>"$stderr_file"; then
      exit_code=0
    else
      exit_code=$?
    fi
  elif "$path" >"$stdout_file" 2>"$stderr_file"; then
    exit_code=0
  else
    exit_code=$?
  fi
  stdout_lines=$(wc -l < "$stdout_file" | tr -d ' ')
  stderr_lines=$(wc -l < "$stderr_file" | tr -d ' ')
  stdout=$(awk 'NR <= 30' "$stdout_file")
  stderr=$(awk 'NR <= 30' "$stderr_file")
  if [ "${stdout_lines:-0}" -gt 30 ] || [ "${stderr_lines:-0}" -gt 30 ]; then truncated=true; fi
  rm -f "$stdout_file" "$stderr_file"
  jq -cn --argjson exit_code "$exit_code" --arg stdout "$stdout" --arg stderr "$stderr" \
    --argjson truncated "$truncated" \
    '{exit_code:$exit_code, stdout:$stdout, stderr:$stderr, truncated:$truncated}'
}

attestation_risk_result_json() {
  local result_status="$1" severity="$2" code="$3" message="$4" suggestion="$5"
  local risk="$6" current_status="$7" signals="$8" check="$9" anchor="${10}"
  local target="${11:-null}" attestation="${12:-null}" execution="${13:-null}" base
  base=$(risk_result_json "$result_status" "$severity" "$code" "$message" "$suggestion" \
    "$risk" "$current_status" "$signals" "" "$check")
  jq -cn --argjson base "$base" --arg check "$check" --argjson anchor "$anchor" \
    --argjson target "$target" --argjson attestation "$attestation" --argjson execution "$execution" '
      $base + {
        check:$check,
        requirement:"required",
        origin:$anchor.location,
        command:$anchor.command,
        trust_anchor:$anchor
      }
      + if $target == null then {} else {current_target:$target} end
      + if $attestation == null then {} else {attestation:$attestation} end
      + if $execution == null then {} else {
          exit_code:$execution.exit_code,
          evidence:([$execution.stdout, $execution.stderr] | map(select(length > 0)) | join("\n")),
          truncated:$execution.truncated
        } end
    '
}

# attestation_missing_capabilities <verification-contract-json> <check>
# Prints configured command capabilities that are absent from PATH. Capability
# names are diagnostic metadata only: providers remain outside the generic core.
attestation_missing_capabilities() {
  local contract="$1" check="$2" capability
  while IFS= read -r capability; do
    [ -n "$capability" ] || continue
    command -v "$capability" >/dev/null 2>&1 || printf '%s\n' "$capability"
  done < <(printf '%s' "$contract" | jq -r --arg check "$check" \
    '.checks[] | select(.name == $check) | .capabilities[]?')
}

risk_attestation_capability_warning() {
  local contract="$1" check="$2" risk="$3" current_status="$4" signals="$5"
  local spec origin missing message suggestion label
  spec=$(printf '%s' "$contract" | jq -c --arg check "$check" '.checks[] | select(.name == $check)')
  origin=$(printf '%s' "$spec" | jq -r '.origin // "not configured"')
  [ "$origin" = configured ] || return 0
  missing=$(attestation_missing_capabilities "$contract" "$check")
  [ -n "$missing" ] || return 0
  if [ "$check" = independent ]; then label="Independent verification"; else label="Human approval"; fi
  message="${label} is configured but currently unavailable because a provider capability is missing: $(printf '%s' "$missing" | awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print "" }'). Ordinary work may continue."
  suggestion="Install or expose the declared capability before claiming completion; agent-md will not install provider tools automatically."
  risk_result_json warn warning VERIFY_UNAVAILABLE "$message" "$suggestion" \
    "$risk" "$current_status" "$signals" "" "${check}-capability"
}

risk_attestation_integrity_result() {
  local contract="$1" check="$2" risk="$3" current_status="$4" signals="$5" config="$6"
  local spec origin anchor message suggestion label
  spec=$(printf '%s' "$contract" | jq -c --arg check "$check" '.checks[] | select(.name == $check)')
  origin=$(printf '%s' "$spec" | jq -r '.origin')
  [ "$origin" = configured ] || return 0
  anchor=$(attestation_trust_anchor_json "$config" "$check")
  [ "$(printf '%s' "$anchor" | jq -r '.eligible')" = true ] && return 0
  if [ "$check" = independent ]; then label="Independent verification"; else label="Human approval"; fi
  message="${label} cannot be accepted because its configured verifier or reviewed files are not in a trusted state: $(printf '%s' "$anchor" | jq -r '.reason')."
  suggestion="Restore the verifier and declared files to reviewed HEAD content before committing. Use doctor for trust details."
  attestation_risk_result_json fail error RISK_ATTESTATION_UNTRUSTED "$message" "$suggestion" \
    "$risk" "$current_status" "$signals" "$check" "$anchor"
}

risk_attestation_integrity_warning() {
  local contract="$1" check="$2" risk="$3" current_status="$4" signals="$5" config="$6"
  local spec origin anchor message suggestion label
  spec=$(printf '%s' "$contract" | jq -c --arg check "$check" '.checks[] | select(.name == $check)')
  origin=$(printf '%s' "$spec" | jq -r '.origin')
  [ "$origin" = configured ] || return 0
  anchor=$(attestation_trust_anchor_json "$config" "$check")
  [ "$(printf '%s' "$anchor" | jq -r '.eligible')" = true ] && return 0
  if [ "$check" = independent ]; then label="Independent verification"; else label="Human approval"; fi
  message="${label} is not ready yet because its configured verifier or reviewed files changed: $(printf '%s' "$anchor" | jq -r '.reason'). Ordinary work may continue."
  suggestion="Commit and review the verifier as a baseline before using it for completion evidence."
  attestation_risk_result_json warn warning RISK_ATTESTATION_UNTRUSTED "$message" "$suggestion" \
    "$risk" "$current_status" "$signals" "$check" "$anchor"
}

risk_evidence_result() {
  local contract="$1" check="$2" code="$3" risk="$4" current_status="$5"
  local signals="$6" config="$7" scope="${8:-worktree}" spec origin timeout_seconds
  local message suggestion anchor anchor_after target execution attestation value expected_commit missing label
  if [ "$check" = independent ]; then label="Independent verification"; else label="Human approval"; fi
  spec=$(printf '%s' "$contract" | jq -c --arg check "$check" '.checks[] | select(.name == $check)')
  origin=$(printf '%s' "$spec" | jq -r '.origin')
  if [ "$origin" != configured ]; then
    message="${label} is required before this ${risk}-risk task can be completed, but no verifier is configured."
    suggestion="Configure a trusted verify.${check} command in a reviewed baseline, provide the external evidence, and rerun agent-md verify."
    risk_result_json fail error "$code" "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "" "$check"
    return 0
  fi

  anchor=$(attestation_trust_anchor_json "$config" "$check")
  if [ "$(printf '%s' "$anchor" | jq -r '.eligible')" != true ]; then
    message="${label} cannot be accepted because its configured verifier is not trusted: $(printf '%s' "$anchor" | jq -r '.reason')."
    suggestion="Restore the reviewed verifier and declared files to their HEAD content, or configure a trusted external verifier. Use doctor for details."
    attestation_risk_result_json fail error RISK_ATTESTATION_UNTRUSTED "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor"
    return 0
  fi

  missing=$(attestation_missing_capabilities "$contract" "$check")
  if [ -n "$missing" ]; then
    message="${label} is required before completion, but a provider capability is unavailable: $(printf '%s' "$missing" | awk 'BEGIN { first=1 } { if (!first) printf ", "; printf "%s", $0; first=0 } END { print "" }')."
    suggestion="Install or expose the declared capability and rerun agent-md verify; agent-md will not install provider tools automatically."
    attestation_risk_result_json fail error VERIFY_UNAVAILABLE "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor"
    return 0
  fi

  target=$(attestation_current_target_json "$scope")
  if [ "$(printf '%s' "$target" | jq -r '.eligible')" != true ]; then
    message="${label} cannot cover the current work while operationally relevant changes are uncommitted."
    suggestion="Commit the reviewed operational change, obtain an attestation for that exact commit, and rerun verification."
    attestation_risk_result_json fail error RISK_ATTESTATION_UNBOUND "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target"
    return 0
  fi

  timeout_seconds=$(printf '%s' "$contract" | jq -r '.timeout_seconds // empty')
  execution=$(attestation_execution_json "$anchor" "$timeout_seconds") || {
    message="The '${check}' attestation verifier could not create diagnostic output storage."
    suggestion="Check temporary-directory permissions and rerun verification."
    attestation_risk_result_json fail error RISK_ATTESTATION_INVALID "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target"
    return 0
  }
  anchor_after=$(attestation_trust_anchor_json "$config" "$check")
  if [ "$(printf '%s' "$anchor_after" | jq -r '.eligible')" != true ]; then
    message="The verify.${check} trust anchor changed while its attestation was being evaluated."
    suggestion="Restore the reviewed verifier and declared files to HEAD, then rerun verification without concurrent modification."
    attestation_risk_result_json fail error RISK_ATTESTATION_UNTRUSTED "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor_after" "$target" null "$execution"
    return 0
  fi
  if [ "$(printf '%s' "$execution" | jq -r '.exit_code')" -ne 0 ]; then
    message="${label} did not pass because the configured verifier exited nonzero."
    suggestion="Recover the external evidence for the current commit and rerun agent-md verify. Output text cannot override the exit status."
    attestation_risk_result_json fail error RISK_ATTESTATION_INVALID "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" null "$execution"
    return 0
  fi

  attestation=$(printf '%s' "$execution" | jq -r '.stdout' \
    | jq -c -s 'if length == 1 and (.[0] | type) == "object" then .[0] else empty end' 2>/dev/null)
  if [ -z "$attestation" ] || [ "$(printf '%s' "$attestation" | jq -r '.status // empty')" != pass ]; then
    message="${label} did not produce valid structured evidence for the current commit."
    suggestion="Emit exactly one JSON object with status, kind, origin, and target for the current commit."
    attestation_risk_result_json fail error RISK_ATTESTATION_INVALID "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" null "$execution"
    return 0
  fi

  value=$(printf '%s' "$attestation" | jq -r '.kind // empty')
  if [ "$value" != "$check" ]; then
    message="The '${check}' verifier emitted kind '${value:-missing}', which cannot satisfy '${check}'."
    suggestion="Return kind '${check}'; independent evidence and human approval are distinct requirements."
    attestation_risk_result_json fail error RISK_ATTESTATION_KIND_MISMATCH "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" "$attestation" "$execution"
    return 0
  fi

  value=$(printf '%s' "$attestation" | jq -r '.origin // empty')
  case "$check:$value" in
    independent:ci|independent:reviewer|independent:human|independent:external-harness|independent:trusted-local-verifier|approval:human) ;;
    *)
      message="The '${check}' attestation origin '${value:-missing}' is not allowed for this requirement."
      suggestion="Use an allowed structured origin backed by the configured trust anchor."
      attestation_risk_result_json fail error RISK_ATTESTATION_ORIGIN_INVALID "$message" "$suggestion" \
        "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" "$attestation" "$execution"
      return 0
      ;;
  esac

  expected_commit=$(printf '%s' "$target" | jq -r '.commit')
  value=$(printf '%s' "$attestation" | jq -r '.target.commit // empty')
  if [ -z "$value" ]; then
    message="The '${check}' attestation has no supported target.commit binding."
    suggestion="Bind the attestation to the exact full HEAD commit and rerun verification."
    attestation_risk_result_json fail error RISK_ATTESTATION_UNBOUND "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" "$attestation" "$execution"
    return 0
  fi
  if [ "$value" != "$expected_commit" ]; then
    message="The '${check}' attestation targets a different commit and is stale for the current state."
    suggestion="Obtain fresh evidence bound to commit ${expected_commit}."
    attestation_risk_result_json fail error RISK_ATTESTATION_STALE "$message" "$suggestion" \
      "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" "$attestation" "$execution"
    return 0
  fi

  message="${label} passed for commit ${expected_commit}."
  attestation_risk_result_json pass info VERIFY_PASSED "$message" "" \
    "$risk" "$current_status" "$signals" "$check" "$anchor" "$target" "$attestation" "$execution"
}

risk_summary_json() {
  local results="$1" risk="$2" current_status="$3" signals="$4" status
  status=$(printf '%s' "$results" | jq -r '
    if any(.[]; .status == "fail") then "fail"
    elif any(.[]; .status == "warn") then "warn"
    else "pass" end
  ')
  jq -cn --arg status "$status" --arg risk "$risk" --arg current_status "$current_status" \
    --argjson results "$results" \
    --argjson signals "$(printf '%s' "$signals" | jq -Rsc 'split("\n") | map(select(length > 0))')" '
      {status:$status, risk:(if $risk == "" then null else $risk end),
       current_status:$current_status, observed_signals:$signals, results:$results}
    '
}

# run_risk_contract <verification-summary> [worktree|staged] [completion|advisory]
# Risk changes required evidence; it never claims that the implementation is
# safe. Final requirements apply only to Status: done at a completion boundary.
run_risk_contract() {
  local verification_summary="$1" scope="${2:-worktree}" boundary="${3:-completion}"
  local progress_content progress_error current_status=absent risk="" relevant_files relevant_status
  local signals="" underrated="" results='[]' result contract config runtime_configured runtime_passed
  local control control_source control_valid downgrade downgrade_authority control_result

  progress_content=$(state_file_snapshot memory/progress.md "$scope")
  if [ -n "$progress_content" ]; then
    if ! progress_error=$(validate_progress_content "$progress_content"); then
      result=$(policy_result_json fail error STATE_PROGRESS_INVALID "$progress_error" \
        "Restore the documented progress.md structure before claiming completion." memory/progress.md)
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      risk_summary_json "$results" "" "invalid" ""
      return 0
    fi
    current_status=$(progress_status_from_content "$progress_content")
  fi

  control=$(effective_control_requirements_json "$scope")
  control_source=$(printf '%s' "$control" | jq -r '.source')
  control_valid=$(printf '%s' "$control" | jq -r '.valid')
  risk=$(printf '%s' "$control" | jq -r '.effective.risk // empty')
  downgrade=$(printf '%s' "$control" | jq -r '.risk_downgrade')
  downgrade_authority=$(printf '%s' "$control" | jq -r '.downgrade_authority')
  while IFS= read -r control_result; do
    [ -n "$control_result" ] || continue
    # Verification-contract errors are already present in the verification
    # summary; keep the control-specific diagnostics here.
    if [ "$(printf '%s' "$control_result" | jq -r '.code')" != CONFIG_INVALID ]; then
      results=$(printf '%s' "$results" | jq -c --argjson result "$control_result" '. + [$result]')
    fi
  done < <(printf '%s' "$control" | jq -c '.results[]')

  relevant_files=$(risk_changed_files "$scope")
  relevant_status=$?
  if [ "$relevant_status" -ne 0 ]; then
    if [ "$relevant_status" -eq 2 ]; then
      result=$(policy_result_json fail error CONFIG_INVALID "$AGENT_MD_STATE_ERROR" \
        "Fix the state classifier before evaluating Risk.")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      risk_summary_json "$results" "" "$current_status" ""
      return 0
    fi
  fi
  signals=$(risk_signals_for_files "$relevant_files" "$scope")

  if [ -z "$risk" ]; then
    if [ "$current_status" = "done" ]; then
      result=$(risk_result_json fail error CONTROL_BASELINE_REQUIRED \
        "Completion cannot be accepted without a Git-bound Risk baseline." \
        "Create and review .project-control.toml with schema = 1 and an explicit risk, then establish it in Git." \
        "" "$current_status" "$signals" "$(project_control_path)" risk)
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    elif [ -n "$relevant_files" ]; then
      result=$(risk_result_json warn warning RISK_NOT_DECLARED \
        "Operationally relevant work has no effective Risk; coding-agent-control will not silently assume low." \
        "Create .project-control.toml explicitly before claiming completion." \
        "" "$current_status" "$signals" "$relevant_files" risk)
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
    risk_summary_json "$results" "" "$current_status" "$signals"
    return 0
  fi

  if [ "$current_status" = "done" ] && [ "$control_source" = "none" ]; then
    if [ "$boundary" = completion ]; then
      result=$(risk_result_json fail error CONTROL_BASELINE_REQUIRED \
        "The Risk proposal is local working state and is not an established control baseline." \
        "Review and commit .project-control.toml before asking for completion acceptance." \
        "$risk" "$current_status" "$signals" "$(project_control_path)" risk-baseline)
    else
      result=$(risk_result_json warn warning CONTROL_BASELINE_REQUIRED \
        "The staged Risk is not yet an established Git-bound control baseline." \
        "Review and commit .project-control.toml before asking for completion acceptance." \
        "$risk" "$current_status" "$signals" "$(project_control_path)" risk-baseline)
    fi
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  if [ "$control_valid" != true ]; then
    risk_summary_json "$results" "$risk" "$current_status" "$signals"
    return 0
  fi

  if [ "$downgrade" = "pending" ] && [ "$current_status" = "done" ]; then
    if [ "$downgrade_authority" = approval ]; then
      contract=$(printf '%s' "$verification_summary" | jq -c '.contract')
      config=$(toml_path)
      result=$(risk_evidence_result "$contract" approval \
        CONTROL_RISK_DOWNGRADE_PENDING "$risk" "$current_status" "$signals" "$config" "$scope")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      if [ "$(printf '%s' "$result" | jq -r '.status')" = pass ]; then
        risk=$(printf '%s' "$control" | jq -r '.proposal.risk')
        downgrade=authorized
      else
        risk_summary_json "$results" "$risk" "$current_status" "$signals"
        return 0
      fi
    else
      result=$(risk_result_json fail error CONTROL_RISK_DOWNGRADE_PENDING \
        "The completion claim proposes a lower Risk, but the previous Git-bound requirements remain effective." \
        "Establish the downgrade through human out-of-band review or an authority-separated approval bound to the resulting commit." \
        "$risk" "$current_status" "$signals" "$(project_control_path)" risk-downgrade-authority)
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  fi

  if [ "$control_source" = legacy-progress ] && [ "$(printf '%s' "$control" | jq -r '.legacy')" = true ]; then
    if [ -n "$relevant_files" ]; then
      result=$(risk_result_json warn warning CONTROL_LEGACY_STATE \
        "Risk is still sourced from tracked legacy memory/progress.md." \
        "Migrate explicitly to .project-control.toml; no automatic migration is performed." \
        "$risk" "$current_status" "$signals" memory/progress.md control-baseline)
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  fi

  underrated=$(risk_underrating_signals "$risk" "$signals")
  if [ -n "$underrated" ]; then
    result=$(risk_result_json warn warning RISK_POSSIBLY_UNDERRATED \
      "Declared Risk '${risk}' may be inconsistent with observed sensitive paths or operations." \
      "Review the declared Risk; signals are advisory and never rewrite it automatically." \
      "$risk" "$current_status" "$underrated" "$relevant_files" risk)
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  # Missing provider tooling is diagnostic while work is active/verifying.
  # It becomes blocking only when Status: done claims the corresponding
  # high/critical guarantee. The core knows command capabilities, not providers.
  contract=$(printf '%s' "$verification_summary" | jq -c '.contract')
  if [ "$current_status" != "done" ] && [ "$(printf '%s' "$contract" | jq -r '.valid')" = true ]; then
    case "$risk" in
      high|critical)
        config=$(toml_path)
        result=$(risk_attestation_integrity_warning "$contract" independent \
          "$risk" "$current_status" "$signals" "$config")
        [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
        result=$(risk_attestation_capability_warning "$contract" independent \
          "$risk" "$current_status" "$signals")
        [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
        ;;
    esac
    if [ "$risk" = critical ]; then
      result=$(risk_attestation_integrity_warning "$contract" approval \
        "$risk" "$current_status" "$signals" "$config")
      [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      result=$(risk_attestation_capability_warning "$contract" approval \
        "$risk" "$current_status" "$signals")
      [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  fi

  if [ "$boundary" != completion ]; then
    if [ "$boundary" = advisory ] && [ "$current_status" = "done" ] \
      && [ "$(printf '%s' "$verification_summary" | jq -r '.status')" != fail ]; then
      contract=$(printf '%s' "$verification_summary" | jq -c '.contract')
      config=$(toml_path)
      case "$risk" in
        high|critical)
          result=$(risk_attestation_integrity_result "$contract" independent \
            "$risk" "$current_status" "$signals" "$config")
          [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
          ;;
      esac
      if [ "$risk" = critical ]; then
        result=$(risk_attestation_integrity_result "$contract" approval \
          "$risk" "$current_status" "$signals" "$config")
        [ -z "$result" ] || results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      fi
    fi
    risk_summary_json "$results" "$risk" "$current_status" "$signals"
    return 0
  fi

  if [ "$current_status" != "done" ] \
    || [ "$(printf '%s' "$verification_summary" | jq -r '.status')" = fail ]; then
    risk_summary_json "$results" "$risk" "$current_status" "$signals"
    return 0
  fi

  contract=$(printf '%s' "$verification_summary" | jq -c '.contract')
  config=$(toml_path)
  case "$risk" in
    medium|high|critical)
      runtime_configured=$(printf '%s' "$contract" | jq '[.checks[] | select((.name == "runtime" or .name == "smoke") and .origin != "not configured")] | length')
      runtime_passed=$(printf '%s' "$verification_summary" | jq '[.results[] | select((.check == "runtime" or .check == "smoke") and .status == "pass")] | length')
      if [ "$runtime_configured" -eq 0 ]; then
        result=$(risk_result_json warn warning RISK_RUNTIME_EVIDENCE_REQUIRED \
          "Risk '${risk}' has no declared runtime or smoke check; applicability cannot be determined automatically." \
          "Review runtime applicability and configure verify.runtime or verify.smoke when executable behavior is in scope." \
          "$risk" "$current_status" "$signals" "" runtime-or-smoke)
        results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      elif [ "$runtime_passed" -eq 0 ]; then
        result=$(risk_result_json fail error RISK_RUNTIME_EVIDENCE_REQUIRED \
          "Risk '${risk}' declares applicable runtime/smoke verification, but none passed." \
          "Fix and rerun the configured runtime or smoke check before marking the task done." \
          "$risk" "$current_status" "$signals" "" runtime-or-smoke)
        results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      fi
      ;;
  esac

  case "$risk" in
    high|critical)
      result=$(risk_evidence_result "$contract" independent \
        RISK_INDEPENDENT_VERIFICATION_REQUIRED "$risk" "$current_status" "$signals" "$config" "$scope")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
      ;;
  esac

  if [ "$risk" = critical ]; then
    result=$(risk_evidence_result "$contract" approval \
      RISK_HUMAN_APPROVAL_REQUIRED "$risk" "$current_status" "$signals" "$config" "$scope")
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  risk_summary_json "$results" "$risk" "$current_status" "$signals"
}

combine_policy_summaries() {
  local first="$1" second="$2"
  jq -cn --argjson first "$first" --argjson second "$second" '
    ($first.results + $second.results) as $results |
    {
      status: (if any($results[]; .status == "fail") then "fail"
               elif any($results[]; .status == "warn") then "warn"
               else "pass" end),
      contract: $first.contract,
      risk: ($second.risk // null),
      current_status: ($second.current_status // null),
      observed_signals: ($second.observed_signals // []),
      results: $results
    }
  '
}

progress_transition_allowed() {
  local previous="$1" current="$2"
  [ "$previous" = "$current" ] && return 0
  case "${previous}:${current}" in
    planned:active|active:blocked|active:verifying|blocked:active|\
    verifying:active|verifying:done|done:planned|done:active) return 0 ;;
    *) return 1 ;;
  esac
}

state_file_snapshot() {
  local path="$1" scope="${2:-worktree}"
  if [ "$scope" = staged ]; then
    file_snapshot "$path" staged
  else
    file_snapshot "$path" worktree
  fi
}

validate_gotchas_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    function trim(value) {
      gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
      return value
    }
    function fail(code, message) {
      if (!bad) print code "|" message
      bad = 1
    }
    function finish_item() {
      if (!in_item) return
      if (rule_count == 0) fail("STATE_GOTCHA_RULE_MISSING", "Gotcha " title " is missing a required Rule field.")
      else if (rule_count > 1) fail("STATE_GOTCHA_INVALID", "Gotcha " title " has multiple Rule fields.")
      else if (why_count != 1) fail("STATE_GOTCHA_INVALID", "Gotcha " title " must contain exactly one non-empty Why field.")
    }

    /^<!--/ { if ($0 !~ /-->/) in_comment = 1; next }
    in_comment { if ($0 ~ /-->/) in_comment = 0; next }

    /^# / {
      h1_count++
      if ($0 != "# Active Gotchas") fail("STATE_GOTCHA_INVALID", "The document must start with # Active Gotchas.")
      next
    }

    /^## / {
      finish_item()
      title = substr($0, 4)
      if (trim(title) == "") fail("STATE_GOTCHA_INVALID", "Gotcha headings must be non-empty.")
      in_item = 1
      item_count++
      rule_count = 0
      why_count = 0
      next
    }

    in_item && /^\*\*Rule(:\*\*|\*\*:)/ {
      value = $0
      sub(/^\*\*Rule:\*\*[[:space:]]*/, "", value)
      sub(/^\*\*Rule\*\*:[[:space:]]*/, "", value)
      rule_count++
      if (trim(value) == "") fail("STATE_GOTCHA_RULE_MISSING", "Gotcha " title " has an empty Rule field.")
      next
    }

    in_item && /^\*\*Why(:\*\*|\*\*:)/ {
      value = $0
      sub(/^\*\*Why:\*\*[[:space:]]*/, "", value)
      sub(/^\*\*Why\*\*:[[:space:]]*/, "", value)
      why_count++
      if (trim(value) == "") fail("STATE_GOTCHA_INVALID", "Gotcha " title " has an empty Why field.")
      next
    }

    !in_item && /^- / {
      fail("STATE_GOTCHA_RULE_MISSING", "Gotcha entries must use ## headings and include Rule and Why fields.")
    }

    END {
      finish_item()
      if (h1_count != 1) fail("STATE_GOTCHA_INVALID", "The document must contain exactly one # Active Gotchas heading.")
      exit (bad ? 1 : 0)
    }
  '
}

# state_enforcement_result [worktree|staged] — emits one structured result:
# the highest-priority Integrity failure, otherwise a Quality scope warning.
# Prints nothing when no action is needed.
state_enforcement_result() {
  local scope="${1:-worktree}"
  git rev-parse --is-inside-work-tree &>/dev/null || return 0

  local modified_files working_state_files relevant_files relevant_count progress_changed gotchas_changed
  local progress_content progress_error previous_content previous_status current_status
  local gotchas_content gotchas_error gotchas_code gotchas_message

  if ! load_effective_state_globs "$scope"; then
    policy_result_json \
      "fail" "error" "CONFIG_INVALID" \
      "$AGENT_MD_STATE_ERROR" \
      "Fix the enforcement configuration before finishing."
    return 0
  fi

  modified_files=$(changed_files "$scope")
  # Control and policy resolution use the requested Git snapshot, but progress
  # and gotchas are working state. Pre-commit must therefore inspect their local
  # worktree versions without requiring users to publish them in the index.
  working_state_files=$(changed_files worktree)

  gotchas_changed=$(printf '%s\n' "$working_state_files" | grep -c '^memory/gotchas\.md$' || true)
  gotchas_changed=${gotchas_changed:-0}
  if [ "$gotchas_changed" -gt 0 ]; then
    gotchas_content=$(state_file_snapshot memory/gotchas.md worktree)
    if [ -n "$gotchas_content" ] && ! gotchas_error=$(validate_gotchas_content "$gotchas_content"); then
      gotchas_code=${gotchas_error%%|*}
      gotchas_message=${gotchas_error#*|}
      policy_result_json \
        "fail" "error" "$gotchas_code" \
        "$gotchas_message" \
        "Keep only reusable gotchas and add non-empty Rule and Why fields." \
        "memory/gotchas.md"
      return 0
    fi
  fi

  [ -f "memory/progress.md" ] || return 0

  relevant_files=$(printf '%s\n' "$modified_files" | filter_effectively_relevant_files)
  relevant_count=$(printf '%s\n' "$relevant_files" | grep -c . || true)
  relevant_count=${relevant_count:-0}
  progress_changed=$(printf '%s\n' "$working_state_files" | grep -c '^memory/progress\.md$' || true)
  progress_changed=${progress_changed:-0}

  if [ "$relevant_count" -gt 0 ] || [ "$progress_changed" -gt 0 ]; then
    progress_content=$(state_file_snapshot memory/progress.md worktree)
    if ! progress_error=$(validate_progress_content "$progress_content"); then
      policy_result_json \
        "fail" "error" "STATE_PROGRESS_INVALID" \
        "$progress_error" \
        "Restore the documented progress.md structure before continuing." \
        "memory/progress.md"
      return 0
    fi

    if [ "$progress_changed" -gt 0 ]; then
      previous_content=$(git show HEAD:memory/progress.md 2>/dev/null || true)
      if [ -n "$previous_content" ] \
         && validate_progress_content "$previous_content" >/dev/null 2>&1; then
        previous_status=$(progress_status_from_content "$previous_content")
        current_status=$(progress_status_from_content "$progress_content")
        if ! progress_transition_allowed "$previous_status" "$current_status"; then
          policy_result_json \
            "warn" "warning" "STATE_TRANSITION_INVALID" \
            "The observed progress status change from ${previous_status} to ${current_status} is not a declared direct transition." \
            "Review the transition or capture the required intermediate operational state." \
            "memory/progress.md"
          return 0
        fi
      fi
    fi
  fi

  [ "$relevant_count" -eq 0 ] && return 0

  # Repos may gitignore memory/ (e.g. a global ~/.gitignore excluding it).
  # git diff/ls-files never sees those edits, so progress_changed would be
  # stuck at 0 forever once any relevant file changes. Fall back to mtime:
  # progress.md newer than every modified relevant file counts as updated.
  if [ "$progress_changed" -eq 0 ] && git check-ignore -q memory/progress.md 2>/dev/null; then
    local progress_mtime newest_source_mtime file file_mtime all_sources_exist
    progress_mtime=$(stat_mtime memory/progress.md)
    progress_mtime=${progress_mtime:-0}
    newest_source_mtime=0
    all_sources_exist=1
    while IFS= read -r file; do
      [ -z "$file" ] && continue
      if [ ! -e "$file" ]; then
        all_sources_exist=0
        continue
      fi
      file_mtime=$(stat_mtime "$file")
      file_mtime=${file_mtime:-0}
      if [ "$file_mtime" -gt "$newest_source_mtime" ]; then
        newest_source_mtime=$file_mtime
      fi
    done <<EOF
$relevant_files
EOF
    if [ "$all_sources_exist" -eq 1 ] \
       && [ "$progress_mtime" -ge "$newest_source_mtime" ]; then
      progress_changed=1
    fi
  fi

  if [ "$progress_changed" -eq 0 ]; then
    local paths
    paths=$(printf '%s\n' "$relevant_files" | awk 'NR <= 10')
    policy_result_json \
      "fail" "error" "STATE_PROGRESS_STALE" \
      "${relevant_count} operationally relevant file(s) changed but memory/progress.md was not updated." \
      "Update memory/progress.md to reflect the current task state before finishing." \
      "$paths"
    return 0
  fi

  local task_scope_globs out_of_scope_files out_of_scope_count file
  task_scope_globs=$(progress_scope_from_content "$progress_content")
  [ -n "$task_scope_globs" ] || return 0

  out_of_scope_files=""
  while IFS= read -r file; do
    [ -n "$file" ] || continue
    if ! path_matches_globs "$file" "$task_scope_globs"; then
      if [ -n "$out_of_scope_files" ]; then
        out_of_scope_files="${out_of_scope_files}
${file}"
      else
        out_of_scope_files="$file"
      fi
    fi
  done <<EOF
$relevant_files
EOF

  out_of_scope_count=$(printf '%s\n' "$out_of_scope_files" | grep -c . || true)
  out_of_scope_count=${out_of_scope_count:-0}
  if [ "$out_of_scope_count" -gt 0 ]; then
    policy_result_json \
      "warn" "warning" "QUALITY_OUT_OF_SCOPE_CHANGE" \
      "${out_of_scope_count} operationally relevant file(s) changed outside the declared task Scope." \
      "Review whether Scope or the implementation plan should be adjusted; Scope is not a safety boundary." \
      "$out_of_scope_files"
  fi
}

# state_enforcement_reason [worktree|staged] — backward-compatible human
# adapter used by Claude/Codex Stop hooks and the pre-commit fallback.
state_enforcement_reason() {
  local result result_status
  result=$(state_enforcement_result "${1:-worktree}")
  [ -n "$result" ] || return 0
  result_status=$(printf '%s' "$result" | jq -r '.status')
  [ "$result_status" = "fail" ] && policy_human_message "$result"
}

# Backward-compatible name used by existing Stop wrappers and downstream
# integrations copied from earlier agent-md releases.
progress_stale_reason() {
  state_enforcement_reason worktree
}

visual_contract_from_config() {
  local config="$1" required artifacts freshness
  required=$(read_toml "$config" visual required)
  artifacts=$(read_toml "$config" visual artifacts_dir)
  freshness=$(read_toml "$config" visual freshness_seconds)
  required=${required:-false}
  artifacts=${artifacts:-.agent/visual}
  freshness=${freshness:-3600}
  if [ "$required" != true ] && [ "$required" != false ]; then
    jq -cn --arg error "Invalid ${config}: visual.required must be true or false." \
      '{valid:false,error:$error}'
    return 0
  fi
  case "$freshness" in
    ''|*[!0-9]*|0)
      jq -cn --arg error "Invalid ${config}: visual.freshness_seconds must be a positive integer." \
        '{valid:false,error:$error}'
      return 0
      ;;
  esac
  jq -cn --argjson required "$required" --arg artifacts "$artifacts" \
    --argjson freshness "$freshness" \
    '{valid:true,required:$required,artifacts_dir:$artifacts,freshness_seconds:$freshness}'
}

effective_visual_contract_json() {
  local scope="${1:-worktree}" config baseline_file proposal_file baseline proposal
  config=$(toml_path)
  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-visual.XXXXXX") || return 1
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-visual.XXXXXX") || {
    rm -f "$baseline_file"
    return 1
  }
  case "$config" in
    /*|*'..'*) : > "$baseline_file"; cp "$config" "$proposal_file" 2>/dev/null || : > "$proposal_file" ;;
    *) snapshot_to_temp "$config" head "$baseline_file"; snapshot_to_temp "$config" "$scope" "$proposal_file" ;;
  esac
  baseline=$(visual_contract_from_config "$baseline_file")
  proposal=$(visual_contract_from_config "$proposal_file")
  rm -f "$baseline_file" "$proposal_file"
  if [ "$(printf '%s' "$baseline" | jq -r '.valid')" != true ]; then printf '%s\n' "$baseline"; return 0; fi
  if [ "$(printf '%s' "$proposal" | jq -r '.valid')" != true ]; then printf '%s\n' "$proposal"; return 0; fi
  jq -cn --argjson baseline "$baseline" --argjson proposal "$proposal" '
    if $baseline.required then
      $baseline + {source:"baseline",baseline:$baseline,proposal:$proposal}
    else
      $proposal + {source:(if $proposal.required then "proposal" else "default/proposal" end),baseline:$baseline,proposal:$proposal}
    end
  '
}

# visual_evidence_ok <artifacts_dir> <freshness_seconds>
# Returns 0 when there's at least one fresh, non-empty markdown evidence
# file in <artifacts_dir> that mentions the filename of at least one
# fresh, non-empty image in the same directory. The markdown must also
# include the minimum verification fields agent-md asks for.
#
# This is deliberately opinionated — the agent must write prose about
# what it verified, not just drop a screenshot. A screenshot alone is
# a photo of something, not a verification claim.
visual_evidence_ok() {
  local dir="$1" fresh="$2"
  [ -d "$dir" ] || return 1
  local now
  now=$(date +%s)

  local md img img_name md_mtime img_mtime md_size img_size
  while IFS= read -r md; do
    [ -z "$md" ] && continue
    md_size=$(file_size "$md")
    [ "${md_size:-0}" -gt 0 ] || continue
    md_mtime=$(stat_mtime "$md")
    [ -z "$md_mtime" ] && continue
    [ $((now - md_mtime)) -le "$fresh" ] || continue
    grep -Eiq 'changed files?:' "$md" || continue
    grep -Eiq '(route|url):' "$md" || continue
    grep -Eiq 'viewport:' "$md" || continue
    grep -Eiq '(observed|result):' "$md" || continue

    while IFS= read -r img; do
      [ -z "$img" ] && continue
      img_size=$(file_size "$img")
      [ "${img_size:-0}" -gt 0 ] || continue
      img_mtime=$(stat_mtime "$img")
      [ -z "$img_mtime" ] && continue
      [ $((now - img_mtime)) -le "$fresh" ] || continue
      img_name=$(basename "$img")
      if grep -qF "$img_name" "$md" 2>/dev/null; then
        return 0
      fi
    done < <(find "$dir" -type f \( -name '*.png' -o -name '*.jpg' \
      -o -name '*.jpeg' -o -name '*.webp' -o -name '*.gif' \) 2>/dev/null)
  done < <(find "$dir" -type f -name '*.md' 2>/dev/null)

  return 1
}
