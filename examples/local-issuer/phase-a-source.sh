# shellcheck shell=bash
# --- Core identity computations, vendored ------------------------------------
#
# A receipt has to carry fingerprints a gate can recompute, so the authority
# must produce exactly what the core produces for source, contract, control and
# mechanism. It cannot read those definitions out of the repository it is
# judging, and it must not execute the repository's code, so the core's
# implementations are vendored here and installed with the authority.
#
# Every function keeps the name of the core function it mirrors, prefixed with
# authority_pa_, so a reader can always find the original. The golden parity
# tests are what keep this copy honest; if the core changes, they fail.
#
# A library: its call sites are in the programs that source it, which linting a
# single file cannot see.
# shellcheck disable=SC2034,SC2317,SC2329

# authority_pa_read_toml <file> <section> <key>
# Prints the value or nothing. Handles `key = "value"` or `key = value`.
# Skips lines after `#`. Not a full TOML parser — just enough for our use.
authority_pa_read_toml() {
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

# authority_pa_read_toml_array <file> <section> <key>
# Prints one quoted string per line. Return codes distinguish a valid key
# (0, including an empty array), a missing key/file (1), and malformed
# input (2). This intentionally implements only the string-array subset
# agent-md exposes; it is not a general TOML parser.
authority_pa_read_toml_array() {
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

# authority_pa_toml_key_present <file> <section> <key>
# Distinguishes an absent scalar from a deliberately empty one. The latter
# matters for executable verification commands: `lint = ""` is invalid,
# not equivalent to an omitted optional check.
authority_pa_toml_key_present() {
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

# authority_pa_toml_path — location of the config file (override with AGENT_MD_TOML env)
authority_pa_toml_path() {
  echo "${AGENT_MD_TOML:-agent-md.toml}"
}

authority_pa_project_control_path() {
  printf '%s\n' '.project-control.toml'
}

# authority_pa_file_exists_in_snapshot <path> <worktree|staged|head|parent>
authority_pa_file_exists_in_snapshot() {
  local path="$1" scope="${2:-worktree}"
  case "$scope" in
    worktree) [ -f "$path" ] ;;
    staged) git cat-file -e ":${path}" 2>/dev/null ;;
    head) git cat-file -e "HEAD:${path}" 2>/dev/null ;;
    parent) git cat-file -e "HEAD^:${path}" 2>/dev/null ;;
    *) return 1 ;;
  esac
}

# authority_pa_file_snapshot <path> <worktree|staged|head|parent>
authority_pa_file_snapshot() {
  local path="$1" scope="${2:-worktree}"
  case "$scope" in
    worktree) [ -f "$path" ] && cat "$path" ;;
    staged) git show ":${path}" 2>/dev/null ;;
    head) git show "HEAD:${path}" 2>/dev/null ;;
    parent) git show "HEAD^:${path}" 2>/dev/null ;;
  esac
}

# authority_pa_snapshot_to_temp <path> <scope> <destination>
# Materializes a snapshot for the deliberately small parsers. An absent file
# becomes an empty config, preserving the existing no-config heuristic mode.
authority_pa_snapshot_to_temp() {
  local path="$1" scope="$2" destination="$3"
  : > "$destination"
  authority_pa_file_exists_in_snapshot "$path" "$scope" || return 0
  authority_pa_file_snapshot "$path" "$scope" > "$destination"
}

authority_pa_verification_receipt_protocol_schema() {
  printf '1\n'
}

# The receipt cache and local working memory are never verification inputs.
# Their own validators remain responsible for completion claims and state.
authority_pa_verification_receipt_path_is_structurally_excluded() {
  case "$1" in
    .git|.git/*|.agent/verification|.agent/verification/*|\
    memory/agents.md|memory/plan.md|memory/progress.md|memory/verify.md|memory/gotchas.md) return 0 ;;
    *) return 1 ;;
  esac
}

authority_pa_verification_receipt_hash_algorithm() {
  printf 'sha256\n'
}

authority_pa_verification_receipt_sha256_stream() {
  local output
  if command -v sha256sum >/dev/null 2>&1; then
    output=$(sha256sum) || return 1
    printf '%s\n' "${output%% *}"
  elif command -v shasum >/dev/null 2>&1; then
    output=$(shasum -a 256) || return 1
    printf '%s\n' "${output%% *}"
  elif command -v openssl >/dev/null 2>&1; then
    output=$(openssl dgst -sha256) || return 1
    printf '%s\n' "${output##* }"
  else
    return 127
  fi
}

# Hashes a byte stream with the dependency-light SHA-256 implementation
# available on the host. The digest supplies deterministic identity, not
# authority; absence of a supported implementation fails identity construction.
authority_pa_verification_receipt_stream_fingerprint_json() {
  local algorithm value
  algorithm=$(authority_pa_verification_receipt_hash_algorithm) || return 1
  value=$(authority_pa_verification_receipt_sha256_stream) || return 1
  jq -cn --arg algorithm "$algorithm" --arg value "$value" \
    '{algorithm:$algorithm,value:$value}'
}

authority_pa_verification_receipt_json_fingerprint_json() {
  local value="$1" canonical
  canonical=$(printf '%s' "$value" | jq -cS . 2>/dev/null) || return 1
  printf '%s' "$canonical" | authority_pa_verification_receipt_stream_fingerprint_json
}

# Hash the raw target bytes of a symlink without following it. readlink writes
# one terminator newline; dd removes exactly that byte while preserving any
# newline that is part of the target itself.
authority_pa_verification_receipt_symlink_digest() {
  local path="$1" target_file content_file target_size digest
  target_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-link-target.XXXXXX") || return 1
  content_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-link-content.XXXXXX") || {
    rm -f "$target_file"
    return 1
  }
  if ! readlink "./$path" > "$target_file"; then
    rm -f "$target_file" "$content_file"
    return 1
  fi
  target_size=$(authority_pa_file_size "$target_file") || {
    rm -f "$target_file" "$content_file"
    return 1
  }
  if [ "$target_size" -lt 1 ]; then
    rm -f "$target_file" "$content_file"
    return 1
  fi
  if ! dd if="$target_file" of="$content_file" bs=1 count=$((target_size - 1)) 2>/dev/null; then
    rm -f "$target_file" "$content_file"
    return 1
  fi
  digest=$(authority_pa_verification_receipt_sha256_stream < "$content_file") || {
    rm -f "$target_file" "$content_file"
    return 1
  }
  rm -f "$target_file" "$content_file"
  printf '%s\n' "$digest"
}

authority_pa_verification_receipt_index_blob_digest() {
  local oid="$1" blob_file digest
  blob_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-index-blob.XXXXXX") || return 1
  if ! git cat-file blob "$oid" > "$blob_file"; then
    rm -f "$blob_file"
    return 1
  fi
  digest=$(authority_pa_verification_receipt_sha256_stream < "$blob_file") || {
    rm -f "$blob_file"
    return 1
  }
  rm -f "$blob_file"
  printf '%s\n' "$digest"
}

authority_pa_verification_receipt_index_state_json() {
  local path="$1" records_file record prefix mode="" oid="" digest="" stage="" count=0
  records_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-index-state.XXXXXX") || return 1
  if ! git --literal-pathspecs ls-files --stage -z -- "$path" > "$records_file"; then
    rm -f "$records_file"
    return 1
  fi
  while IFS= read -r -d '' record; do
    prefix=${record%%$'\t'*}
    read -r mode oid stage <<< "$prefix"
    count=$((count + 1))
  done < "$records_file"
  rm -f "$records_file"

  if [ "$count" -eq 0 ]; then
    jq -cn '{valid:true,state:"absent"}'
  elif [ "$count" -ne 1 ] || [ "$stage" != 0 ]; then
    jq -cn '{valid:false,state:"conflicted",error:"index contains unresolved stages"}'
  else
    case "$mode" in
      100644|100755) ;;
      120000) ;;
      160000)
        jq -cn --arg mode "$mode" --arg oid "$oid" \
          '{valid:false,state:"unsupported",mode:$mode,oid:$oid,error:"gitlinks are not supported by receipt protocol v1"}'
        return 0
        ;;
      *)
        jq -cn --arg mode "$mode" --arg oid "$oid" \
          '{valid:false,state:"unsupported",mode:$mode,oid:$oid,error:"unsupported index mode"}'
        return 0
        ;;
    esac
    digest=$(authority_pa_verification_receipt_index_blob_digest "$oid") || return 1
    jq -cn --arg mode "$mode" --arg oid "$oid" --arg digest "$digest" \
      '{valid:true,state:"present",mode:$mode,oid:$oid,digest:$digest}'
  fi
}

authority_pa_verification_receipt_worktree_state_json() {
  local path="$1" mode digest
  if [ -L "$path" ]; then
    digest=$(authority_pa_verification_receipt_symlink_digest "$path") || {
      jq -cn '{valid:false,state:"unsupported",error:"symlink target could not be hashed"}'
      return 0
    }
    jq -cn --arg digest "$digest" \
      '{valid:true,state:"present",kind:"symlink",mode:"120000",digest:$digest}'
  elif [ -f "$path" ]; then
    if [ -x "$path" ]; then mode=100755; else mode=100644; fi
    digest=$(authority_pa_verification_receipt_sha256_stream < "$path") || {
      jq -cn '{valid:false,state:"unreadable",error:"file content could not be hashed"}'
      return 0
    }
    jq -cn --arg mode "$mode" --arg digest "$digest" \
      '{valid:true,state:"present",kind:"file",mode:$mode,digest:$digest}'
  elif [ -e "$path" ]; then
    jq -cn '{valid:false,state:"unsupported",error:"special filesystem entries are not supported by receipt protocol v1"}'
  else
    jq -cn '{valid:true,state:"absent"}'
  fi
}

authority_pa_verification_receipt_manifest_entry_json() {
  local path="$1" scope="$2" index_state worktree_state
  index_state=$(authority_pa_verification_receipt_index_state_json "$path") || return 1
  if [ "$scope" = staged ]; then
    jq -cn --arg path "$path" --argjson index "$index_state" \
      '{valid:$index.valid,path:$path,index:$index}'
    return 0
  fi
  worktree_state=$(authority_pa_verification_receipt_worktree_state_json "$path") || return 1
  jq -cn --arg path "$path" --argjson index "$index_state" --argjson worktree "$worktree_state" \
    '{valid:($index.valid and $worktree.valid),path:$path,index:$index,worktree:$worktree}'
}

# authority_pa_verification_receipt_conversion_is_inert <paths-file>
#
# True only when Git applies no content conversion to any enumerated path, so
# a clean worktree file is byte-identical to its index blob. This is a proof
# obligation rather than a heuristic: any configured attribute or autocrlf
# mode makes it false and the caller rehashes every blob itself.
authority_pa_verification_receipt_conversion_is_inert() {
  local paths_file="$1" autocrlf
  autocrlf=$(git config --get core.autocrlf 2>/dev/null || printf 'false')
  case "$autocrlf" in true|input) return 1 ;; esac
  [ -s "$paths_file" ] || return 0
  git check-attr --stdin -z text eol crlf working-tree-encoding filter \
    < "$paths_file" 2>/dev/null \
    | tr '\000' '\n' \
    | awk 'NR % 3 == 0 && $0 != "unspecified" { bad = 1; exit } END { exit bad ? 1 : 0 }'
}

# authority_pa_verification_receipt_worktree_scan <paths-file> <records-out> <pairs-out> <digests-out>
#
# Classifies every path with shell builtins. Entries that need no content hash,
# and the rare names sha256sum would escape, are written complete to
# <records-out> as six NUL separated fields: path, state, kind, mode, digest,
# error. Ordinary names are written to <pairs-out> as NUL separated
# path/mode pairs and digested by a single batched sha256 pass into
# <digests-out>, which the assembly step joins by name.
authority_pa_verification_receipt_worktree_scan() {
  local paths_file="$1" records="$2" pairs="$3" digests="$4"
  local names path mode digest
  names=$(mktemp "${TMPDIR:-/tmp}/agent-md-wt-names.XXXXXX") || return 1
  : > "$records"; : > "$pairs"; : > "$digests"; : > "$names"

  while IFS= read -r -d '' path; do
    if [ -L "$path" ]; then
      if digest=$(authority_pa_verification_receipt_symlink_digest "$path"); then
        printf '%s\000present\000symlink\000120000\000%s\000\000' "$path" "$digest" >> "$records"
      else
        printf '%s\000unsupported\000symlink\000\000\000symlink target could not be hashed\000' "$path" >> "$records"
      fi
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      case "$path" in
        *[\\]*|*$'\n'*)
          # sha256sum escapes these names, so they never enter the batch.
          if digest=$(authority_pa_verification_receipt_sha256_stream < "$path" 2>/dev/null); then
            printf '%s\000present\000file\000%s\000%s\000\000' "$path" "$mode" "$digest" >> "$records"
          else
            printf '%s\000unreadable\000file\000\000\000file content could not be hashed\000' "$path" >> "$records"
          fi
          ;;
        *)
          printf '%s\000%s\000' "$path" "$mode" >> "$pairs"
          printf '%s\000' "$path" >> "$names"
          ;;
      esac
    elif [ -e "$path" ]; then
      printf '%s\000unsupported\000special\000\000\000special filesystem entries are not supported by receipt protocol v1\000' "$path" >> "$records"
    else
      printf '%s\000absent\000\000\000\000\000' "$path" >> "$records"
    fi
  done < "$paths_file"

  if [ -s "$names" ]; then
    xargs -0 sha256sum -- < "$names" > "$digests" 2>/dev/null || :
  fi
  rm -f "$names"
  return 0
}

# authority_pa_verification_receipt_unique_paths <raw-in> <out>
# Collapses the HEAD/index/untracked union to one occurrence per path. jq owns
# the deduplication so unusual byte sequences in pathnames survive intact.
authority_pa_verification_receipt_unique_paths() {
  jq -Rsj '
    ([0] | implode) as $nul
    | split($nul) | map(select(length > 0)) | unique
    | map(. + $nul) | join("")
  ' < "$1" > "$2"
}

# authority_pa_verification_receipt_manifest_jq <mode> <scope> <head> <inert> <files...>
# One jq program serves both passes so the reuse rule cannot drift between
# planning which blobs still need reading and assembling the final manifest.
authority_pa_verification_receipt_manifest_jq() {
  local mode="$1" scope="$2" head="$3" inert="$4"
  local paths="$5" index="$6" records="$7" pairs="$8" shaout="$9" modified="${10}" resolved="${11}"
  jq -nj --arg mode "$mode" --arg scope "$scope" --arg head "$head" \
    --argjson schema "$(authority_pa_verification_receipt_protocol_schema)" --argjson inert "$inert" \
    --rawfile paths "$paths" --rawfile index "$index" --rawfile records "$records" \
    --rawfile pairs "$pairs" --rawfile shaout "$shaout" --rawfile modified "$modified" \
    --rawfile resolved "$resolved" '
    def nulsplit($s; $nul): if $s == "" then [] else ($s | split($nul) | map(select(length > 0))) end;
    def chunk($n): . as $a | [range(0; ($a | length); $n) | $a[.:. + $n]];
    ([0] | implode) as $nul
    | ([9] | implode) as $tab
    | ($shaout | split("\n") | map(select(length > 0))
        | map({key: .[66:], value: .[0:64]}) | from_entries) as $BATCH
    | ((if $records == "" then [] else ($records | split($nul)) end | chunk(6)
         | map(select(length == 6))
         | map({key: .[0], value: {state: .[1], kind: .[2], mode: .[3], digest: .[4], error: .[5]}}))
       + (if $pairs == "" then [] else ($pairs | split($nul)) end | chunk(2)
         | map(select(length == 2))
         | map(. as $p | {key: $p[0], value: (
             if ($BATCH[$p[0]] // "") == "" then
               {state: "unreadable", kind: "file", mode: "", digest: "", error: "file content could not be hashed"}
             else
               {state: "present", kind: "file", mode: $p[1], digest: $BATCH[$p[0]], error: ""}
             end)}))
       | from_entries) as $WT
    | (nulsplit($modified; $nul) | map({key: ., value: true}) | from_entries) as $MOD
    | (nulsplit($resolved; $nul) | chunk(2) | map(select(length == 2))
        | map({key: .[0], value: .[1]}) | from_entries) as $RESOLVED
    | (nulsplit($index; $nul) | map(
         (index($tab)) as $t
         | (.[0:$t] | split(" ")) as $f
         | {path: .[$t+1:], mode: $f[0], oid: $f[1], stage: $f[2]})
       | group_by(.path)
       | map({key: .[0].path, value: .}) | from_entries) as $IDX
    | def reusable($e):
        $inert
        and ($MOD[$e.path] != true)
        and (($WT[$e.path].state // "") == "present")
        and (($WT[$e.path].kind // "") == "file")
        and (($WT[$e.path].mode // "") == $e.mode)
        and (($WT[$e.path].digest // "") != "");
      def supported($m): $m == "100644" or $m == "100755" or $m == "120000";
      def needs_read: [ $IDX | to_entries[] | .value
          | select(length == 1) | .[0]
          | select(.stage == "0") | select(supported(.mode))
          | select(reusable(.) | not) | .oid ] | unique;
      def index_state($p):
        ($IDX[$p] // []) as $r
        | if ($r | length) == 0 then {valid: true, state: "absent"}
          elif ($r | length) != 1 or $r[0].stage != "0" then
            {valid: false, state: "conflicted", error: "index contains unresolved stages"}
          else $r[0] as $e
            | if $e.mode == "160000" then
                {valid: false, state: "unsupported", mode: $e.mode, oid: $e.oid,
                 error: "gitlinks are not supported by receipt protocol v1"}
              elif supported($e.mode) then
                {valid: true, state: "present", mode: $e.mode, oid: $e.oid,
                 digest: (if reusable($e) then $WT[$e.path].digest else $RESOLVED[$e.oid] end)}
              else
                {valid: false, state: "unsupported", mode: $e.mode, oid: $e.oid,
                 error: "unsupported index mode"}
              end
          end;
      def worktree_state($p):
        ($WT[$p] // {state: "absent"}) as $w
        | if $w.state == "absent" then {valid: true, state: "absent"}
          elif $w.state == "present" and $w.kind == "symlink" then
            {valid: true, state: "present", kind: "symlink", mode: "120000", digest: $w.digest}
          elif $w.state == "present" then
            {valid: true, state: "present", kind: "file", mode: $w.mode, digest: $w.digest}
          elif $w.state == "unreadable" then
            {valid: false, state: "unreadable", error: $w.error}
          else {valid: false, state: "unsupported", error: $w.error}
          end;
      if $mode == "plan" then
        (needs_read | map(. + $nul) | join(""))
      else
        (nulsplit($paths; $nul) | map(
           . as $p
           | index_state($p) as $ix
           | if $scope == "staged" then {valid: $ix.valid, path: $p, index: $ix}
             else worktree_state($p) as $wt
               | {valid: ($ix.valid and $wt.valid), path: $p, index: $ix, worktree: $wt}
             end)
         | sort_by(.path)) as $entries
        | {valid: ($entries | all(.valid == true)),
           schema: $schema,
           scope: $scope,
           head: (if $head == "" then null else $head end),
           exclusions: [".git/**", ".agent/verification/**", "memory/agents.md",
                        "memory/plan.md", "memory/progress.md", "memory/verify.md",
                        "memory/gotchas.md"],
           entries: $entries}
      end
  '
}

# authority_pa_verification_receipt_source_manifest_json [worktree|staged]
#
# HEAD supplies the factual base. The manifest enumerates the complete HEAD and
# index path sets (not only `git diff` output), plus non-ignored untracked files
# for worktree scope. This catches deletes, mode changes, staged/unstaged
# divergence, and assume-unchanged paths. JSON escaping plus canonical sorting
# provide unambiguous framing for unusual pathnames.
#
# Every Git query and every digest pass is batched, so process count is
# bounded by the number of stages rather than by the number of files. Blob
# contents are only re-read from the object database when Git cannot already
# prove the worktree file is byte-identical to the blob.
authority_pa_verification_receipt_source_manifest_json() {
  local scope="${1:-worktree}" head="" inert=false path oid digest
  local raw filtered paths index records pairs shaout modified resolved plan manifest
  local GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_ATTR_NOSYSTEM=1
  export GIT_CONFIG_GLOBAL GIT_CONFIG_NOSYSTEM GIT_ATTR_NOSYSTEM
  case "$scope" in
    worktree|staged) ;;
    *)
      jq -cn --arg scope "$scope" \
        '{valid:false,schema:1,scope:$scope,error:"receipt scope must be worktree or staged"}'
      return 0
      ;;
  esac
  if ! git rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    jq -cn --arg scope "$scope" \
      '{valid:false,schema:1,scope:$scope,error:"verification receipts require a Git worktree"}'
    return 0
  fi

  raw=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-raw.XXXXXX") || return 1
  filtered=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-filtered.XXXXXX") || return 1
  paths=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-paths.XXXXXX") || return 1
  index=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-index.XXXXXX") || return 1
  records=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-records.XXXXXX") || return 1
  pairs=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-pairs.XXXXXX") || return 1
  shaout=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-sha.XXXXXX") || return 1
  modified=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-modified.XXXXXX") || return 1
  resolved=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-resolved.XXXXXX") || return 1
  plan=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-plan.XXXXXX") || return 1
  # shellcheck disable=SC2064 # The paths are fixed at trap installation time.
  trap "rm -f '$raw' '$filtered' '$paths' '$index' '$records' '$pairs' '$shaout' '$modified' '$resolved' '$plan'" RETURN

  head=$(git rev-parse --verify HEAD 2>/dev/null || true)
  : > "$raw"
  if [ -n "$head" ]; then
    git ls-tree -r -z --name-only HEAD >> "$raw" || return 1
  fi
  git ls-files -z --cached >> "$raw" || return 1
  if [ "$scope" = worktree ]; then
    git ls-files -z --others --exclude-standard >> "$raw" || return 1
  fi

  : > "$filtered"
  while IFS= read -r -d '' path; do
    authority_pa_verification_receipt_path_is_structurally_excluded "$path" && continue
    printf '%s\000' "$path" >> "$filtered"
  done < "$raw"
  authority_pa_verification_receipt_unique_paths "$filtered" "$paths" || return 1

  git ls-files --stage -z > "$index" || return 1
  git diff-files -z --name-only > "$modified" 2>/dev/null || : > "$modified"
  if authority_pa_verification_receipt_conversion_is_inert "$paths"; then inert=true; fi
  authority_pa_verification_receipt_worktree_scan "$paths" "$records" "$pairs" "$shaout" || return 1

  authority_pa_verification_receipt_manifest_jq plan "$scope" "$head" "$inert" \
    "$paths" "$index" "$records" "$pairs" "$shaout" "$modified" "$resolved" > "$plan" || return 1

  : > "$resolved"
  while IFS= read -r -d '' oid; do
    digest=$(git cat-file blob "$oid" 2>/dev/null | authority_pa_verification_receipt_sha256_stream) || return 1
    [ -n "$digest" ] || return 1
    printf '%s\000%s\000' "$oid" "$digest" >> "$resolved"
  done < "$plan"

  manifest=$(authority_pa_verification_receipt_manifest_jq assemble "$scope" "$head" "$inert" \
    "$paths" "$index" "$records" "$pairs" "$shaout" "$modified" "$resolved") || return 1
  printf '%s\n' "$manifest"
}

authority_pa_verification_receipt_mechanism_manifest_json() {
  local scope="${1:-worktree}" files_file path entry files valid=false
  files_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-mechanism.XXXXXX") || return 1
  : > "$files_file"
  for path in \
    .claude/hooks/_lib.sh \
    .claude/hooks/stop-verify.sh \
    .agent-md/bin/verify.sh; do
    entry=$(authority_pa_verification_receipt_manifest_entry_json "$path" "$scope") || {
      rm -f "$files_file"
      return 1
    }
    printf '%s\n' "$entry" >> "$files_file"
  done
  files=$(jq -sc 'sort_by(.path)' "$files_file")
  rm -f "$files_file"
  if [ "$scope" = staged ]; then
    valid=$(printf '%s' "$files" | jq 'all(.[]; .valid and .index.state == "present")')
  else
    valid=$(printf '%s' "$files" | jq 'all(.[]; .valid and .worktree.state == "present")')
  fi
  jq -cn --argjson schema "$(authority_pa_verification_receipt_protocol_schema)" \
    --arg scope "$scope" --argjson valid "$valid" --argjson files "$files" \
    '{valid:$valid,schema:$schema,scope:$scope,files:$files}'
}

authority_pa_risk_rank() {
  case "$1" in
    low) printf '1\n' ;;
    medium) printf '2\n' ;;
    high) printf '3\n' ;;
    critical) printf '4\n' ;;
    *) printf '0\n' ;;
  esac
}

authority_pa_stricter_risk() {
  local first="${1:-}" second="${2:-}"
  if [ "$(authority_pa_risk_rank "$first")" -ge "$(authority_pa_risk_rank "$second")" ]; then
    printf '%s\n' "$first"
  else
    printf '%s\n' "$second"
  fi
}

# authority_pa_project_control_json_from_content <toml>
# Parses only the root-level schema and risk fields intentionally exposed by
# .project-control.toml. This is not a general TOML parser.
authority_pa_project_control_json_from_content() {
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

# authority_pa_file_size <path> — portable byte size (Linux + macOS).
authority_pa_file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null
}

# authority_pa_policy_result_json <status> <severity> <code> <message> <suggestion> [paths]
# Builds the small internal result contract shared by agent-md controls.
# Paths are newline-delimited so filenames containing spaces remain intact.
# Hook wrappers translate this result to each host's existing JSON shape.
authority_pa_policy_result_json() {
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

# authority_pa_detect_pm — prints the detected Node package manager based on lockfile,
# or nothing. Order: pnpm > yarn > bun > npm > (nothing).
authority_pa_detect_pm() {
  if   [ -f "pnpm-lock.yaml" ];                       then echo pnpm
  elif [ -f "yarn.lock" ];                            then echo yarn
  elif [ -f "bun.lockb" ] || [ -f "bun.lock" ];       then echo bun
  elif [ -f "package-lock.json" ] || [ -f "package.json" ]; then echo npm
  fi
}

# authority_pa_npm_test_cmd — prints the test-runner invocation for the detected PM,
# or nothing if no JS project was detected.
authority_pa_npm_test_cmd() {
  case "$(authority_pa_detect_pm)" in
    pnpm) echo "pnpm test --silent" ;;
    yarn) echo "yarn test --silent" ;;
    bun)  echo "bun test" ;;
    npm)  echo "npm test --silent" ;;
    *)    echo "" ;;
  esac
}

# authority_pa_has_npm_test_script — returns 0 if package.json declares a real test script.
authority_pa_has_npm_test_script() {
  [ -f "package.json" ] || return 1
  local t
  t=$(jq -r '.scripts.test // empty' package.json 2>/dev/null)
  [ -n "$t" ] && [ "$t" != 'echo "Error: no test specified" && exit 1' ]
}

authority_pa_verification_check_names() {
  printf '%s\n' typecheck lint test integration smoke runtime independent approval
}

# authority_pa_infer_verification_command <check>
# Heuristics are deliberately small and observable. Explicit [verify]
# commands always win. Empty output means no fallback was detected.
authority_pa_infer_verification_command() {
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
      npm_command=$(authority_pa_npm_test_cmd)
      if [ -n "$npm_command" ] && authority_pa_has_npm_test_script; then
        printf '%s\n' "$npm_command"
      elif [ -f pytest.ini ] || grep -q '\[tool.pytest' pyproject.toml 2>/dev/null; then
        printf '%s\n' 'pytest --tb=short -q'
      elif [ -f Cargo.toml ]; then
        printf '%s\n' 'cargo test'
      fi
      ;;
  esac
}

authority_pa_verification_invalid_contract_json() {
  local message="$1" suggestion="${2:-Fix agent-md.toml before running verification.}"
  local result
  result=$(authority_pa_policy_result_json fail error CONFIG_INVALID "$message" "$suggestion")
  jq -cn --argjson error "$result" '{valid:false, checks:[], error:$error}'
}

# authority_pa_verification_contract_json [config]
# Resolves the complete, deterministic contract without executing checks.
# The intentionally small schema uses only existing scalar/string-array
# parser support:
#   [verify] <check> = "command"
#   [verify.policy] required = ["lint", "test"]
#   [verify.policy] timeout_seconds = 300
#   [verify.policy] total_timeout_seconds = 420
# Without `required`, resolved checks retain the legacy required behavior.
authority_pa_verification_contract_json() {
  local config="${1:-$(authority_pa_toml_path)}" required_values required_status
  local required_declared=0 timeout_value="" total_timeout_value="" rows='[]' check command origin requirement
  local seen_required="" value row trusted_values trusted_status trusted_files
  local capability_values capability_status capabilities
  local preparation='null' preparation_command="" preparation_timeout="" preparation_provider=""

  required_values=$(authority_pa_read_toml_array "$config" verify.policy required)
  required_status=$?
  case "$required_status" in
    0) required_declared=1 ;;
    1) required_values="" ;;
    *)
      authority_pa_verification_invalid_contract_json \
        "Invalid ${config}: verify.policy.required must be an array of quoted check names."
      return 0
      ;;
  esac

  while IFS= read -r value; do
    [ -n "$value" ] || continue
    case "$value" in
      typecheck|lint|test|integration|smoke|runtime) ;;
      *)
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: unknown required verification check '${value}'."
        return 0
        ;;
    esac
    if printf '%s\n' "$seen_required" | grep -qxF "$value"; then
      authority_pa_verification_invalid_contract_json \
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

  if authority_pa_toml_key_present "$config" verify.policy timeout_seconds; then
    timeout_value=$(authority_pa_read_toml "$config" verify.policy timeout_seconds)
    case "$timeout_value" in
      ''|*[!0-9]*|0)
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: verify.policy.timeout_seconds must be a positive integer."
        return 0
        ;;
    esac
  fi

  if authority_pa_toml_key_present "$config" verify.policy total_timeout_seconds; then
    total_timeout_value=$(authority_pa_read_toml "$config" verify.policy total_timeout_seconds)
    case "$total_timeout_value" in
      ''|*[!0-9]*|0)
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: verify.policy.total_timeout_seconds must be a positive integer."
        return 0
        ;;
    esac
  fi

  if authority_pa_toml_key_present "$config" verify.preparation command \
    || authority_pa_toml_key_present "$config" verify.preparation timeout_seconds \
    || authority_pa_toml_key_present "$config" verify.preparation provider; then
    preparation_command=$(authority_pa_read_toml "$config" verify.preparation command)
    preparation_timeout=$(authority_pa_read_toml "$config" verify.preparation timeout_seconds)
    preparation_provider=$(authority_pa_read_toml "$config" verify.preparation provider)
    case "$preparation_timeout" in
      ''|*[!0-9]*|0)
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: verify.preparation.timeout_seconds must be a positive integer."
        return 0 ;;
    esac
    if [ -z "$preparation_command" ] || [ -z "$preparation_provider" ] \
      || ! bash -n -c "$preparation_command" >/dev/null 2>&1; then
      authority_pa_verification_invalid_contract_json \
        "Invalid ${config}: verify.preparation requires a provider and a valid nonempty command."
      return 0
    fi
    preparation=$(jq -cn --arg provider "$preparation_provider" \
      --arg command "$preparation_command" --argjson timeout "$preparation_timeout" \
      '{provider:$provider,command:$command,timeout_seconds:$timeout}')
    if [ -n "$total_timeout_value" ] \
      && [ "$preparation_timeout" -gt "$total_timeout_value" ]; then
      authority_pa_verification_invalid_contract_json \
        "Invalid ${config}: preparation timeout exceeds the total evaluation budget."
      return 0
    fi
  fi

  while IFS= read -r check; do
    command=""
    origin="not configured"
    trusted_files='[]'
    capabilities='[]'
    if authority_pa_toml_key_present "$config" verify "$check"; then
      command=$(authority_pa_read_toml "$config" verify "$check")
      if [ -z "$command" ]; then
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: verify.${check} is configured with an empty command."
        return 0
      fi
      if ! bash -n -c "$command" >/dev/null 2>&1; then
        authority_pa_verification_invalid_contract_json \
          "Invalid ${config}: verify.${check} is not valid shell syntax."
        return 0
      fi
      origin="configured"
    else
      command=$(authority_pa_infer_verification_command "$check")
      [ -z "$command" ] || origin="inferred"
    fi

    if [ "$check" = independent ] || [ "$check" = approval ]; then
      requirement="conditional"
      trusted_values=$(authority_pa_read_toml_array "$config" verify.attestation "${check}_files")
      trusted_status=$?
      case "$trusted_status" in
        0)
          while IFS= read -r value; do
            [ -n "$value" ] || continue
            case "$value" in
              /*|..|../*|*/../*|*/..)
                authority_pa_verification_invalid_contract_json \
                  "Invalid ${config}: verify.attestation.${check}_files must contain repository-relative paths without traversal."
                return 0
                ;;
            esac
            if printf '%s' "$trusted_files" | jq -e --arg value "$value" 'index($value) != null' >/dev/null; then
              authority_pa_verification_invalid_contract_json \
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
          authority_pa_verification_invalid_contract_json \
            "Invalid ${config}: verify.attestation.${check}_files must be an array of quoted repository-relative paths."
          return 0
          ;;
      esac

      capability_values=$(authority_pa_read_toml_array "$config" verify.attestation "${check}_capabilities")
      capability_status=$?
      case "$capability_status" in
        0)
          if [ "$origin" != configured ]; then
            authority_pa_verification_invalid_contract_json \
              "Invalid ${config}: verify.attestation.${check}_capabilities requires verify.${check}."
            return 0
          fi
          while IFS= read -r value; do
            [ -n "$value" ] || continue
            if ! printf '%s\n' "$value" | grep -Eq '^[A-Za-z0-9][A-Za-z0-9._+-]*$'; then
              authority_pa_verification_invalid_contract_json \
                "Invalid ${config}: verify.attestation.${check}_capabilities must contain literal command names, not paths or shell expressions."
              return 0
            fi
            if printf '%s' "$capabilities" | jq -e --arg value "$value" 'index($value) != null' >/dev/null; then
              authority_pa_verification_invalid_contract_json \
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
          authority_pa_verification_invalid_contract_json \
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
$(authority_pa_verification_check_names)
EOF

  jq -cn \
    --argjson checks "$rows" \
    --argjson preparation "$preparation" \
    --arg timeout "$timeout_value" \
    --arg total_timeout "$total_timeout_value" \
    --arg mode "$(if [ "$required_declared" -eq 1 ]; then printf explicit; else printf legacy; fi)" '
      {
        valid: true,
        policy: $mode,
        timeout_seconds: (if $timeout == "" then null else ($timeout | tonumber) end),
        total_timeout_seconds: (if $total_timeout == "" then null else ($total_timeout | tonumber) end),
        checks: $checks
      }
      | if $preparation == null then . else .preparation = $preparation end
    '
}

# authority_pa_merge_verification_contracts <baseline-json> <proposal-json>
# Established configured commands remain conservative across policy changes:
# distinct configured commands for the same check both run. Inferred commands
# are fallback only; when an explicit configured command exists for that check,
# the inferred fallback does not compete with it. Conditional attestation
# declarations remain singular and continue through their existing HEAD trust
# validation.
authority_pa_merge_verification_contracts() {
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
      | group_by(.name)
      | map(
          . as $same_name
          | (if any($same_name[]; .origin == "configured")
             then [$same_name[] | select(.origin == "configured")]
             else $same_name
             end)
          | group_by(.command)
          | map(
              . as $group
              | $group[0]
              | .requirement = (if any($group[]; .requirement == "required") then "required" else "optional" end)
              | .origin = (if any($group[]; .origin == "configured") then "configured"
                           elif any($group[]; .origin == "inferred") then "inferred"
                           else "not configured" end)
            )
        )
      | add // [];
    def spec($contract; $name):
      [$contract.checks[] | select(.name == $name)][0];
    def attestation($name):
      (spec($baseline; $name)) as $old
      | (spec($proposal; $name)) as $new
      | if $old.origin == "configured" and $new.origin != "configured" then $old
        else $new
        end;
    ([ $baseline.timeout_seconds, $proposal.timeout_seconds ] | map(select(. != null))) as $timeouts
    | ([ $baseline.total_timeout_seconds, $proposal.total_timeout_seconds ] | map(select(. != null))) as $total_timeouts
    | {
        valid: true,
        policy: "effective",
        timeout_seconds: (if ($timeouts | length) == 0 then null else ($timeouts | min) end),
        total_timeout_seconds: (if ($total_timeouts | length) == 0 then null else ($total_timeouts | min) end),
        checks: (ordinary + [attestation("independent"), attestation("approval")]),
        baseline_contract: $baseline,
        proposal_contract: $proposal
      }
      | if $proposal.preparation == null then . else .preparation = $proposal.preparation end
  '
}

# authority_pa_effective_verification_contract_json [worktree|staged]
authority_pa_effective_verification_contract_json() {
  local scope="${1:-worktree}" config baseline_file proposal_file
  local baseline proposal merged
  config=$(authority_pa_toml_path)

  # A config outside the repository cannot be a Git-bound baseline. It remains
  # supported as a proposal for compatibility, but never erases the empty
  # baseline contract.
  case "$config" in
    /*|*'..'*)
      baseline=$(authority_pa_verification_contract_json /dev/null)
      proposal=$(authority_pa_verification_contract_json "$config")
      authority_pa_merge_verification_contracts "$baseline" "$proposal"
      return 0
      ;;
  esac

  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-config.XXXXXX") || return 1
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-config.XXXXXX") || {
    rm -f "$baseline_file"
    return 1
  }
  authority_pa_snapshot_to_temp "$config" head "$baseline_file"
  authority_pa_snapshot_to_temp "$config" "$scope" "$proposal_file"
  baseline=$(authority_pa_verification_contract_json "$baseline_file")
  proposal=$(authority_pa_verification_contract_json "$proposal_file")
  rm -f "$baseline_file" "$proposal_file"
  merged=$(authority_pa_merge_verification_contracts "$baseline" "$proposal")
  printf '%s\n' "$merged"
}

authority_pa_progress_risk_count_from_content() {
  local content="$1"
  printf '%s\n' "$content" | awk '
    /^## Current$/ { current = 1; next }
    /^## / { current = 0 }
    current && /^Risk:/ { count++ }
    END { print count + 0 }
  '
}

authority_pa_progress_risk_from_content() {
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

authority_pa_progress_risk_candidate_json() {
  local content="$1" count risk
  if [ -z "$content" ]; then
    jq -cn '{present:false,valid:true,risk:null}'
    return 0
  fi
  count=$(authority_pa_progress_risk_count_from_content "$content")
  risk=$(authority_pa_progress_risk_from_content "$content")
  if [ "$count" -eq 0 ]; then
    jq -cn '{present:false,valid:true,risk:null}'
  elif [ "$count" -eq 1 ] && printf '%s\n' "$risk" | grep -Eq '^(low|medium|high|critical)$'; then
    jq -cn --arg risk "$risk" '{present:true,valid:true,risk:$risk}'
  else
    jq -cn --arg risk "$risk" \
      '{present:true,valid:false,risk:(if $risk == "" then null else $risk end),error:"Risk must occur once and be low, medium, high, or critical."}'
  fi
}

authority_pa_snapshot_relation_to_head() {
  local path="$1" scope="${2:-worktree}" baseline_file proposal_file relation
  baseline_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-baseline-file.XXXXXX") || return 1
  proposal_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-proposal-file.XXXXXX") || {
    rm -f "$baseline_file"
    return 1
  }
  if authority_pa_file_exists_in_snapshot "$path" head; then
    authority_pa_file_snapshot "$path" head > "$baseline_file"
    if ! authority_pa_file_exists_in_snapshot "$path" "$scope"; then
      relation=deleted
    else
      authority_pa_file_snapshot "$path" "$scope" > "$proposal_file"
      if cmp -s "$baseline_file" "$proposal_file"; then relation=established; else relation=proposed; fi
    fi
  elif authority_pa_file_exists_in_snapshot "$path" "$scope"; then
    relation=proposed
  else
    relation=absent
  fi
  rm -f "$baseline_file" "$proposal_file"
  printf '%s\n' "$relation"
}

# authority_pa_effective_control_requirements_json [worktree|staged] [resolved-contract]
# Resolves Git-bound baseline plus current proposal without executing checks or
# external verifiers. A caller that already resolved the effective verification
# contract may pass it to avoid parsing the same baseline/proposal twice. Git
# proves content/binding, not human authorship.
authority_pa_effective_control_requirements_json() {
  local scope="${1:-worktree}" resolved_contract="${2:-}" control_path progress_path config
  local baseline_source=none baseline_risk="" baseline_valid=true legacy=false
  local head_declared_risk="" parent_risk="" baseline_authority="git-bound"
  local proposal_control_risk="" proposal_progress_risk="" proposal_risk=""
  local proposal_valid=true control_content progress_content parsed candidate
  local effective_risk="" downgrade=none downgrade_authority=none results='[]' result contract policy_status
  control_path=$(authority_pa_project_control_path)
  progress_path=memory/progress.md
  config=$(authority_pa_toml_path)

  if authority_pa_file_exists_in_snapshot "$control_path" head; then
    control_content=$(authority_pa_file_snapshot "$control_path" head)
    parsed=$(authority_pa_project_control_json_from_content "$control_content")
    baseline_source=project-control
    if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
      baseline_risk=$(printf '%s' "$parsed" | jq -r '.risk')
      head_declared_risk="$baseline_risk"
    else
      baseline_valid=false
      result=$(authority_pa_policy_result_json fail error CONTROL_INVALID \
        "The Git-bound .project-control.toml baseline is invalid: $(printf '%s' "$parsed" | jq -r '.error')." \
        "Restore a reviewed schema = 1 control record with one valid risk value." "$control_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  elif authority_pa_file_exists_in_snapshot "$progress_path" head; then
    progress_content=$(authority_pa_file_snapshot "$progress_path" head)
    candidate=$(authority_pa_progress_risk_candidate_json "$progress_content")
    if [ "$(printf '%s' "$candidate" | jq -r '.valid')" = true ] \
      && [ "$(printf '%s' "$candidate" | jq -r '.present')" = true ]; then
      baseline_source="legacy-progress"
      baseline_risk=$(printf '%s' "$candidate" | jq -r '.risk')
      legacy=true
    elif [ "$(printf '%s' "$candidate" | jq -r '.valid')" != true ]; then
      baseline_valid=false
      result=$(authority_pa_policy_result_json fail error CONTROL_INVALID \
        "The legacy tracked progress Risk baseline is invalid." \
        "Correct the tracked legacy Risk or explicitly establish .project-control.toml." "$progress_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  fi

  if authority_pa_file_exists_in_snapshot "$control_path" "$scope"; then
    control_content=$(authority_pa_file_snapshot "$control_path" "$scope")
    parsed=$(authority_pa_project_control_json_from_content "$control_content")
    if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
      proposal_control_risk=$(printf '%s' "$parsed" | jq -r '.risk')
    else
      proposal_valid=false
      result=$(authority_pa_policy_result_json fail error CONTROL_INVALID \
        "The proposed .project-control.toml is invalid: $(printf '%s' "$parsed" | jq -r '.error')." \
        "Use only schema = 1 and one quoted risk value: low, medium, high, or critical." "$control_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    fi
  elif [ "$baseline_source" = project-control ]; then
    result=$(authority_pa_policy_result_json warn warning CONTROL_BASELINE_REQUIRED \
      "The Git-bound project control record is absent from the current proposal; its guarantees remain effective." \
      "Restore .project-control.toml or establish a reviewed replacement baseline." "$control_path")
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  if authority_pa_file_exists_in_snapshot "$progress_path" "$scope"; then
    progress_content=$(authority_pa_file_snapshot "$progress_path" "$scope")
    candidate=$(authority_pa_progress_risk_candidate_json "$progress_content")
    if [ "$(printf '%s' "$candidate" | jq -r '.valid')" != true ]; then
      proposal_valid=false
      result=$(authority_pa_policy_result_json fail error RISK_INVALID \
        "The local completion claim contains an invalid Risk proposal." \
        "Correct or remove the local Risk field; it cannot override the Git-bound baseline." "$progress_path")
      results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
    elif [ "$(printf '%s' "$candidate" | jq -r '.present')" = true ]; then
      proposal_progress_risk=$(printf '%s' "$candidate" | jq -r '.risk')
    fi
  fi

  proposal_risk=$(authority_pa_stricter_risk "$proposal_control_risk" "$proposal_progress_risk")
  effective_risk=$(authority_pa_stricter_risk "$baseline_risk" "$proposal_risk")
  if [ -n "$baseline_risk" ] && [ -n "$proposal_risk" ] \
    && [ "$(authority_pa_risk_rank "$proposal_risk")" -lt "$(authority_pa_risk_rank "$baseline_risk")" ]; then
    downgrade=pending
    result=$(authority_pa_policy_result_json warn warning CONTROL_RISK_DOWNGRADE_PENDING \
      "The proposed Risk downgrade does not reduce the effective requirements." \
      "Establish the lower Risk through a reviewed Git baseline or an authority-separated approval verifier." "$control_path")
    results=$(printf '%s' "$results" | jq -c --argjson result "$result" '. + [$result]')
  fi

  if [ -n "$resolved_contract" ]; then
    contract="$resolved_contract"
  else
    contract=$(authority_pa_effective_verification_contract_json "$scope")
  fi
  policy_status=$(authority_pa_snapshot_relation_to_head "$config" "$scope")
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
    if authority_pa_file_exists_in_snapshot "$control_path" parent; then
      parsed=$(authority_pa_project_control_json_from_content "$(authority_pa_file_snapshot "$control_path" parent)")
      if [ "$(printf '%s' "$parsed" | jq -r '.valid')" = true ]; then
        parent_risk=$(printf '%s' "$parsed" | jq -r '.risk')
      fi
    elif authority_pa_file_exists_in_snapshot "$progress_path" parent; then
      candidate=$(authority_pa_progress_risk_candidate_json "$(authority_pa_file_snapshot "$progress_path" parent)")
      if [ "$(printf '%s' "$candidate" | jq -r '.valid and .present')" = true ]; then
        parent_risk=$(printf '%s' "$candidate" | jq -r '.risk')
      fi
    fi
    if [ -n "$parent_risk" ] \
      && [ "$(authority_pa_risk_rank "$head_declared_risk")" -lt "$(authority_pa_risk_rank "$parent_risk")" ]; then
      if [ "$(printf '%s' "$contract" | jq -r '[.checks[] | select(.name == "approval")][0].origin // "not configured"')" = configured ]; then
        baseline_risk="$parent_risk"
        proposal_risk=$(authority_pa_stricter_risk "$head_declared_risk" "$proposal_progress_risk")
        effective_risk=$(authority_pa_stricter_risk "$baseline_risk" "$proposal_risk")
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

# Ordinary coverage is calculated separately from external authority. A valid
# local receipt can never satisfy the independent or approval arrays.
authority_pa_verification_receipt_requirements_json() {
  local contract="$1" control="$2"
  jq -cn --argjson contract "$contract" --argjson control "$control" '
    def ordinary_spec:
      {name,requirement,origin,command};
    ($control.effective.risk // null) as $risk
    | ([ $contract.checks[] |
          select(.name != "independent" and .name != "approval" and .requirement == "required") |
          ordinary_spec ] | sort_by(.name,.command,.origin,.requirement)) as $required
    | ([ $contract.checks[] |
          select((.name == "runtime" or .name == "smoke") and .origin != "not configured") |
          ordinary_spec ] | sort_by(.name,.command,.origin,.requirement)) as $runtime
    | {
        valid:($contract.valid == true and $control.valid == true),
        required:$required,
        any_of:(if (($risk == "medium" or $risk == "high" or $risk == "critical") and ($runtime | length) > 0)
                then [{name:"runtime-or-smoke",checks:$runtime}]
                else [] end),
        external:([if ($risk == "high" or $risk == "critical") then "independent" else empty end,
                   if ($risk == "critical" or
                       ($control.risk_downgrade == "pending" and $control.downgrade_authority == "approval"))
                   then "approval" else empty end] | unique)
      }
  '
}
