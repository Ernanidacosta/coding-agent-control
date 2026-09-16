# tests/reference-manifest.bash
#
# Frozen copy of the pre-batching receipt manifest implementation. It exists
# only so the golden compatibility tests can assert that the batched
# implementation in _lib.sh produces byte-identical manifests, fingerprints
# and error states for the same repository state. It is never sourced by
# product code and must not be "improved"; its whole value is being the old
# behavior verbatim.
#
# It reuses the unchanged primitives from _lib.sh: verification_receipt_sha256_stream,
# verification_receipt_path_is_structurally_excluded, verification_receipt_protocol_schema
# and file_size.

reference_receipt_symlink_digest() {
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
  target_size=$(file_size "$target_file") || {
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
  digest=$(verification_receipt_sha256_stream < "$content_file") || {
    rm -f "$target_file" "$content_file"
    return 1
  }
  rm -f "$target_file" "$content_file"
  printf '%s\n' "$digest"
}

reference_receipt_index_blob_digest() {
  local oid="$1" blob_file digest
  blob_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-index-blob.XXXXXX") || return 1
  if ! git cat-file blob "$oid" > "$blob_file"; then
    rm -f "$blob_file"
    return 1
  fi
  digest=$(verification_receipt_sha256_stream < "$blob_file") || {
    rm -f "$blob_file"
    return 1
  }
  rm -f "$blob_file"
  printf '%s\n' "$digest"
}

reference_receipt_index_state_json() {
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
    digest=$(reference_receipt_index_blob_digest "$oid") || return 1
    jq -cn --arg mode "$mode" --arg oid "$oid" --arg digest "$digest" \
      '{valid:true,state:"present",mode:$mode,oid:$oid,digest:$digest}'
  fi
}

reference_receipt_worktree_state_json() {
  local path="$1" mode digest
  if [ -L "$path" ]; then
    digest=$(reference_receipt_symlink_digest "$path") || {
      jq -cn '{valid:false,state:"unsupported",error:"symlink target could not be hashed"}'
      return 0
    }
    jq -cn --arg digest "$digest" \
      '{valid:true,state:"present",kind:"symlink",mode:"120000",digest:$digest}'
  elif [ -f "$path" ]; then
    if [ -x "$path" ]; then mode=100755; else mode=100644; fi
    digest=$(verification_receipt_sha256_stream < "$path") || {
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

reference_receipt_manifest_entry_json() {
  local path="$1" scope="$2" index_state worktree_state
  index_state=$(reference_receipt_index_state_json "$path") || return 1
  if [ "$scope" = staged ]; then
    jq -cn --arg path "$path" --argjson index "$index_state" \
      '{valid:$index.valid,path:$path,index:$index}'
    return 0
  fi
  worktree_state=$(reference_receipt_worktree_state_json "$path") || return 1
  jq -cn --arg path "$path" --argjson index "$index_state" --argjson worktree "$worktree_state" \
    '{valid:($index.valid and $worktree.valid),path:$path,index:$index,worktree:$worktree}'
}

reference_receipt_source_manifest_json() {
  local scope="${1:-worktree}" head="" paths_file entries_file path entry entries valid entry_error=0
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

  head=$(git rev-parse --verify HEAD 2>/dev/null || true)
  paths_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-paths.XXXXXX") || return 1
  entries_file=$(mktemp "${TMPDIR:-/tmp}/agent-md-receipt-entries.XXXXXX") || {
    rm -f "$paths_file"
    return 1
  }
  : > "$paths_file"
  : > "$entries_file"
  if [ -n "$head" ]; then
    git ls-tree -r -z --name-only HEAD >> "$paths_file" || {
      rm -f "$paths_file" "$entries_file"
      return 1
    }
  fi
  git ls-files -z --cached >> "$paths_file" || {
    rm -f "$paths_file" "$entries_file"
    return 1
  }
  if [ "$scope" = worktree ]; then
    git ls-files -z --others --exclude-standard >> "$paths_file" || {
      rm -f "$paths_file" "$entries_file"
      return 1
    }
  fi

  while IFS= read -r -d '' path; do
    verification_receipt_path_is_structurally_excluded "$path" && continue
    entry=$(reference_receipt_manifest_entry_json "$path" "$scope") || {
      entry_error=1
      break
    }
    printf '%s\n' "$entry" >> "$entries_file"
  done < "$paths_file"
  rm -f "$paths_file"
  if [ "$entry_error" -ne 0 ]; then
    rm -f "$entries_file"
    return 1
  fi

  # Duplicate paths arise from the HEAD/index union. Identical observations are
  # collapsed; disagreement means the repository changed during enumeration.
  entries=$(jq -sc '
    sort_by(.path) | group_by(.path) | map(
      if (map(del(.path)) | unique | length) == 1 then .[0]
      else {valid:false,path:.[0].path,error:"path changed while the manifest was being built"}
      end
    )
  ' "$entries_file")
  rm -f "$entries_file"
  valid=$(printf '%s' "$entries" | jq 'all(.[]; .valid == true)')
  jq -cn --argjson schema "$(verification_receipt_protocol_schema)" \
    --arg scope "$scope" --arg head "$head" --argjson entries "$entries" --argjson valid "$valid" '
      {
        valid:$valid,
        schema:$schema,
        scope:$scope,
        head:(if $head == "" then null else $head end),
        exclusions:[
          ".git/**",
          ".agent/verification/**",
          "memory/agents.md",
          "memory/plan.md",
          "memory/progress.md",
          "memory/verify.md",
          "memory/gotchas.md"
        ],
        entries:$entries
      }
    '
}
