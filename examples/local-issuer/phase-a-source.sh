# shellcheck shell=bash
# --- Phase A source identity, vendored --------------------------------------
#
# A library: its call sites are in the programs that source it, which linting a
# single file cannot see.
# shellcheck disable=SC2034,SC2317,SC2329
#
# The execution snapshot is not the same thing as the Phase A source identity.
# The snapshot is the final filesystem state the checks read; Phase A records
# the index and the worktree separately for every path, so it distinguishes a
# staged change from an unstaged one, an unstaged delete from an untracked
# absence, and a staged delete from either. A snapshot manifest cannot express
# any of that.
#
# A future receipt has to carry a fingerprint the core can recompute at a gate,
# so the authority produces the Phase A identity itself. This is a vendored
# copy of the core's implementation for the same reason the TOML reader is
# vendored: the authority must not read its definitions out of the repository
# it is judging. The golden parity tests are what keep the copy honest.

authority_pa_protocol_schema() {
  printf '1\n'
}

# The receipt cache and local working memory are never verification inputs.
# Their own validators remain responsible for completion claims and state.
authority_pa_path_is_structurally_excluded() {
  case "$1" in
    .git|.git/*|.agent/verification|.agent/verification/*|\
    memory/agents.md|memory/plan.md|memory/progress.md|memory/verify.md|memory/gotchas.md) return 0 ;;
    *) return 1 ;;
  esac
}

authority_pa_hash_algorithm() {
  printf 'sha256\n'
}

authority_pa_sha256_stream() {
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
authority_pa_stream_fingerprint_json() {
  local algorithm value
  algorithm=$(authority_pa_hash_algorithm) || return 1
  value=$(authority_pa_sha256_stream) || return 1
  jq -cn --arg algorithm "$algorithm" --arg value "$value" \
    '{algorithm:$algorithm,value:$value}'
}

authority_pa_json_fingerprint_json() {
  local value="$1" canonical
  canonical=$(printf '%s' "$value" | jq -cS . 2>/dev/null) || return 1
  printf '%s' "$canonical" | authority_pa_stream_fingerprint_json
}

# Hash the raw target bytes of a symlink without following it. readlink writes
# one terminator newline; dd removes exactly that byte while preserving any
# newline that is part of the target itself.
authority_pa_symlink_digest() {
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
  digest=$(authority_pa_sha256_stream < "$content_file") || {
    rm -f "$target_file" "$content_file"
    return 1
  }
  rm -f "$target_file" "$content_file"
  printf '%s\n' "$digest"
}

# authority_pa_conversion_is_inert <paths-file>
#
# True only when Git applies no content conversion to any enumerated path, so
# a clean worktree file is byte-identical to its index blob. This is a proof
# obligation rather than a heuristic: any configured attribute or autocrlf
# mode makes it false and the caller rehashes every blob itself.
authority_pa_conversion_is_inert() {
  local paths_file="$1" autocrlf
  autocrlf=$(git config --get core.autocrlf 2>/dev/null || printf 'false')
  case "$autocrlf" in true|input) return 1 ;; esac
  [ -s "$paths_file" ] || return 0
  git check-attr --stdin -z text eol crlf working-tree-encoding filter \
    < "$paths_file" 2>/dev/null \
    | tr '\000' '\n' \
    | awk 'NR % 3 == 0 && $0 != "unspecified" { bad = 1; exit } END { exit bad ? 1 : 0 }'
}

# authority_pa_worktree_scan <paths-file> <records-out> <pairs-out> <digests-out>
#
# Classifies every path with shell builtins. Entries that need no content hash,
# and the rare names sha256sum would escape, are written complete to
# <records-out> as six NUL separated fields: path, state, kind, mode, digest,
# error. Ordinary names are written to <pairs-out> as NUL separated
# path/mode pairs and digested by a single batched sha256 pass into
# <digests-out>, which the assembly step joins by name.
authority_pa_worktree_scan() {
  local paths_file="$1" records="$2" pairs="$3" digests="$4"
  local names path mode digest
  names=$(mktemp "${TMPDIR:-/tmp}/agent-md-wt-names.XXXXXX") || return 1
  : > "$records"; : > "$pairs"; : > "$digests"; : > "$names"

  while IFS= read -r -d '' path; do
    if [ -L "$path" ]; then
      if digest=$(authority_pa_symlink_digest "$path"); then
        printf '%s\000present\000symlink\000120000\000%s\000\000' "$path" "$digest" >> "$records"
      else
        printf '%s\000unsupported\000symlink\000\000\000symlink target could not be hashed\000' "$path" >> "$records"
      fi
    elif [ -f "$path" ]; then
      if [ -x "$path" ]; then mode=100755; else mode=100644; fi
      case "$path" in
        *[\\]*|*$'\n'*)
          # sha256sum escapes these names, so they never enter the batch.
          if digest=$(authority_pa_sha256_stream < "$path" 2>/dev/null); then
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

# authority_pa_unique_paths <raw-in> <out>
# Collapses the HEAD/index/untracked union to one occurrence per path. jq owns
# the deduplication so unusual byte sequences in pathnames survive intact.
authority_pa_unique_paths() {
  jq -Rsj '
    ([0] | implode) as $nul
    | split($nul) | map(select(length > 0)) | unique
    | map(. + $nul) | join("")
  ' < "$1" > "$2"
}

# authority_pa_manifest_jq <mode> <scope> <head> <inert> <files...>
# One jq program serves both passes so the reuse rule cannot drift between
# planning which blobs still need reading and assembling the final manifest.
authority_pa_manifest_jq() {
  local mode="$1" scope="$2" head="$3" inert="$4"
  local paths="$5" index="$6" records="$7" pairs="$8" shaout="$9" modified="${10}" resolved="${11}"
  jq -nj --arg mode "$mode" --arg scope "$scope" --arg head "$head" \
    --argjson schema "$(authority_pa_protocol_schema)" --argjson inert "$inert" \
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

# authority_pa_source_manifest_json [worktree|staged]
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
authority_pa_source_manifest_json() {
  local scope="${1:-worktree}" head="" inert=false path oid digest
  local raw filtered paths index records pairs shaout modified resolved plan manifest
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
    authority_pa_path_is_structurally_excluded "$path" && continue
    printf '%s\000' "$path" >> "$filtered"
  done < "$raw"
  authority_pa_unique_paths "$filtered" "$paths" || return 1

  git ls-files --stage -z > "$index" || return 1
  git diff-files -z --name-only > "$modified" 2>/dev/null || : > "$modified"
  if authority_pa_conversion_is_inert "$paths"; then inert=true; fi
  authority_pa_worktree_scan "$paths" "$records" "$pairs" "$shaout" || return 1

  authority_pa_manifest_jq plan "$scope" "$head" "$inert" \
    "$paths" "$index" "$records" "$pairs" "$shaout" "$modified" "$resolved" > "$plan" || return 1

  : > "$resolved"
  while IFS= read -r -d '' oid; do
    digest=$(git cat-file blob "$oid" 2>/dev/null | authority_pa_sha256_stream) || return 1
    [ -n "$digest" ] || return 1
    printf '%s\000%s\000' "$oid" "$digest" >> "$resolved"
  done < "$plan"

  manifest=$(authority_pa_manifest_jq assemble "$scope" "$head" "$inert" \
    "$paths" "$index" "$records" "$pairs" "$shaout" "$modified" "$resolved") || return 1
  printf '%s\n' "$manifest"
}

# authority_pa_file_size <path> — portable byte size (Linux + macOS).
authority_pa_file_size() {
  stat -c %s "$1" 2>/dev/null || stat -f %z "$1" 2>/dev/null
}
