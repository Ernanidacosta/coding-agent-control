#!/bin/bash
# receipt-verify.sh — unprivileged validation of an authenticated receipt.
#
# Answers exactly one question:
#
#   "is there an authenticated receipt that is current, applicable to the
#    workspace as it is right now, and therefore reusable as a PASS?"
#
# Everything here runs as the ordinary developer. It never uses sudo, never
# calls the issuer, never reads private key material, and never writes
# anything. Its only inputs are a workspace path and a scope; the receipt, the
# project, the key and the fingerprints are all derived, never supplied.
#
# The two things it adds on top of Phase A's semantics are cryptographic
# authenticity and authority-side freshness. The fingerprint and coverage
# semantics themselves are Phase A's, used through the vendored copy rather
# than reimplemented, so there is one set of rules and not two.
#
# Why the vendored copy and not the workspace's own hooks: deciding whether to
# trust a receipt by running code out of the repository the receipt describes
# would let that repository decide its own verdict, and would execute it before
# any check had a chance to object. The mechanism fingerprint covers those
# files, but a fingerprint is checked after loading, which is too late.

# PROGRAM and ROOT are consumed by authority-lib.sh. shellcheck only follows a
# sourced file when invoked with -x, so these directives keep the program clean
# under either invocation.
# shellcheck disable=SC2034
set -u
PROGRAM=${0##*/}

AUTHORITY_SELF_DIR=$(cd "$(dirname "$(realpath "$0")")" && pwd)
# shellcheck source=examples/local-issuer/authority-lib.sh
# shellcheck disable=SC1091
. "$AUTHORITY_SELF_DIR/authority-lib.sh"
# shellcheck source=examples/local-issuer/phase-a-source.sh
# shellcheck disable=SC1091
. "$AUTHORITY_SELF_DIR/phase-a-source.sh"

RECEIPT_VALIDATION_SCHEMA=1

# Exit 0 means exactly one thing: the ordinary verification may be reused
# because it passed for this state. It never means completion passed, because
# a receipt cannot speak for independent verification, human approval or the
# current Risk level; requires_external says what is still outstanding.
#
# An authenticated failure is reusable evidence too, but it keeps its own
# non-zero code. A caller that routes on the exit status alone must never read
# a failure as a success, and the structured result carries the distinction
# for callers that read it properly.
EX_REUSABLE=0
EX_USAGE=2
EX_CURRENT_FAIL=3
EX_STALE_IDENTITY=4
EX_UNRESOLVED_PENDING=5
EX_UNAUTHENTICATED_TERMINAL=6
EX_INVALID_RECEIPT=7
EX_NO_EVIDENCE=8
EX_UNAVAILABLE=9
EX_INSUFFICIENT_COVERAGE=10

RV_PROJECT_ID=null
RV_WORKSPACE=null
RV_SCOPE=null
RV_SEQUENCE=null
RV_KEY_ID=null
RV_RECEIPT_PATH=null
RV_AUTHENTIC=false
RV_CURRENT=false
RV_APPLICABLE=false
RV_EXTERNAL='[]'
RV_ORDINARY=null

usage() {
  cat <<'USAGE'
Usage:
  receipt-verify.sh WORKSPACE SCOPE [--root PREFIX]

Answers whether an authenticated receipt is current and reusable as a PASS.

WORKSPACE  path to the repository
SCOPE      worktree

Nothing else is accepted. The receipt, its sequence, the project, the signing
key and the expected fingerprints are all derived from the authority's own
state; a caller that could name them could choose its own verdict.
USAGE
}

# stdout carries exactly one control-plane object and nothing else. Human
# diagnostics go to stderr, so no future caller is ever tempted to parse prose.
answer() {
  local status="$1" reason="$2" exit_code="$3"
  jq -nc \
    --argjson schema "$RECEIPT_VALIDATION_SCHEMA" \
    --arg status "$status" --arg reason "$reason" \
    --argjson project_id "$RV_PROJECT_ID" --argjson workspace "$RV_WORKSPACE" \
    --argjson scope "$RV_SCOPE" --argjson sequence "$RV_SEQUENCE" \
    --argjson key_id "$RV_KEY_ID" --argjson receipt "$RV_RECEIPT_PATH" \
    --argjson authentic "$RV_AUTHENTIC" --argjson current "$RV_CURRENT" \
    --argjson applicable "$RV_APPLICABLE" --argjson external "$RV_EXTERNAL" \
    --argjson ordinary "$RV_ORDINARY" '
      {schema: $schema, status: $status, reason: $reason,
       # authentic: the signature verified under the project trusted key.
       # current:   the authority state names this exact receipt as latest.
       # applicable: the live workspace still matches what was signed.
       # A receipt can be authentic without being current, and current
       # without being applicable; only all three make it reusable.
       authentic: $authentic, current: $current, applicable: $applicable,
       project_id: $project_id, workspace: $workspace, scope: $scope,
       sequence: $sequence, key_id: $key_id, receipt: $receipt,
       # What the ordinary verification concluded for this exact state, once
       # it is established that the receipt may speak for it at all: "pass",
       # "fail", or null when no reusable conclusion was reached.
       ordinary: $ordinary,
       # Guarantees a receipt can never supply, as the current Risk level
       # requires them. A consumer reads this rather than re-deriving Risk.
       requires_external: $external}'
  [ "$exit_code" -eq 0 ] || printf '%s: %s\n' "$PROGRAM" "$reason" >&2
  exit "$exit_code"
}

# --- filesystem trust --------------------------------------------------------
#
# Anything read as evidence has to be something the caller could not have
# written. These checks are expressed as "this user cannot write it", which is
# the property that actually matters and the one a test can reproduce without a
# real service account.

trusted_file() {
  local path="$1" want_mode="${2:-}" mode
  [ -e "$path" ] || { printf 'is absent'; return 1; }
  [ -L "$path" ] && { printf 'is a symlink'; return 1; }
  path_has_symlink "$path" && { printf 'path traverses a symlink'; return 1; }
  [ -f "$path" ] || { printf 'is not a regular file'; return 1; }
  [ -w "$path" ] && { printf 'is writable by this user'; return 1; }
  local dir; dir=$(dirname "$path")
  [ -w "$dir" ] && { printf 'sits in a directory this user can write'; return 1; }
  if [ -n "$want_mode" ]; then
    mode=$(mode_of "$path") || { printf 'has no readable mode'; return 1; }
    [ "${mode: -3}" = "$want_mode" ] || { printf 'mode is %s, expected %s' "$mode" "$want_mode"; return 1; }
  fi
  return 0
}

# --- resolution --------------------------------------------------------------

rv_resolve_project() {
  local workspace="$1" projects canonical matches count
  projects=$(projects_dir)
  [ -d "$projects" ] || answer unavailable \
    "no verification authority is installed on this machine" "$EX_UNAVAILABLE"
  local safety
  if ! safety=$(authority_dir_safety "$projects"); then
    answer unavailable "the authority store is not usable: $safety" "$EX_UNAVAILABLE"
  fi

  canonical=$(realpath "$workspace" 2>/dev/null) \
    || answer no_evidence "the workspace path does not resolve" "$EX_NO_EVIDENCE"
  [ -d "$canonical" ] || answer no_evidence "the workspace is not a directory" "$EX_NO_EVIDENCE"
  RV_WORKSPACE=$(json_string "$canonical")
  RV_CANONICAL="$canonical"

  matches=$(authority_find_projects "$canonical")
  count=$(printf '%s' "$matches" | grep -c . || true)
  [ "$count" -eq 0 ] && answer no_evidence \
    "this workspace is not enrolled with the authority" "$EX_NO_EVIDENCE"
  [ "$count" -gt 1 ] && answer unavailable \
    "more than one enrollment claims this workspace; the authority state is ambiguous" "$EX_UNAVAILABLE"

  RV_PID=$(printf '%s' "$matches" | head -1)
  case "$RV_PID" in */*|..|.|*[!a-zA-Z0-9-]*)
    answer unavailable "the enrollment names an unusable project id" "$EX_UNAVAILABLE" ;;
  esac
  RV_PROJECT_ID=$(json_string "$RV_PID")

  local enrollment reason
  enrollment="$(projects_dir)/$RV_PID/enrollment.json"
  if ! reason=$(trusted_file "$enrollment"); then
    answer unavailable "the enrollment record $reason" "$EX_UNAVAILABLE"
  fi
  # The enrollment must agree that it describes this workspace. Finding it by
  # workspace and then not checking the binding would make a rename enough.
  [ "$(jq -r '.workspace // empty' "$enrollment")" = "$canonical" ] || answer unavailable \
    "the enrollment does not bind this workspace" "$EX_UNAVAILABLE"
}

rv_read_state() {
  local file reason
  file=$(authority_state_file "$RV_PID")
  if ! reason=$(trusted_file "$file"); then
    answer unavailable "the authority state $reason" "$EX_UNAVAILABLE"
  fi
  if ! RV_STATE=$(authority_state_read "$RV_PID"); then
    answer unavailable "the authority state is not usable: $RV_STATE" "$EX_UNAVAILABLE"
  fi
}

# --- freshness, decided by the state and nothing else ------------------------

rv_resolve_terminal() {
  local scope="$RV_SCOPE_NAME" entry
  entry=$(jq -c --arg s "$scope" '.scopes[$s]' <<<"$RV_STATE")
  [ "$entry" = null ] && answer unavailable \
    "the authority state carries no line for this scope" "$EX_UNAVAILABLE"

  # A reservation outstanding means an attempt exists whose outcome the
  # authority could not close. Whatever sits underneath it is not current, and
  # reaching past it to an older pass is exactly the resurrection this design
  # exists to prevent.
  if [ "$(jq -r '.pending | type' <<<"$entry")" != null ]; then
    RV_SEQUENCE=$(jq -c '.pending.sequence' <<<"$entry")
    answer unresolved_pending \
      "an evaluation is outstanding, so no earlier result is current" "$EX_UNRESOLVED_PENDING"
  fi

  [ "$(jq -r '.last_terminal | type' <<<"$entry")" = null ] && answer no_evidence \
    "the authority has recorded no terminal result for this scope" "$EX_NO_EVIDENCE"

  RV_TERMINAL=$(jq -c '.last_terminal' <<<"$entry")
  RV_SEQUENCE=$(jq -c '.sequence' <<<"$RV_TERMINAL")

  if [ "$(jq -r '.receipt | type' <<<"$RV_TERMINAL")" = null ]; then
    answer unauthenticated_terminal \
      "the current terminal result predates receipts and was never signed" "$EX_UNAUTHENTICATED_TERMINAL"
  fi
  RV_KEY_ID=$(jq -c '.key_id' <<<"$RV_TERMINAL")
  RV_RECEIPT_PATH=$(jq -c '.receipt.path' <<<"$RV_TERMINAL")
}

# --- the receipt itself ------------------------------------------------------

rv_load_receipt() {
  local path reason raw canonical expected
  path=$(jq -r '.receipt.path' <<<"$RV_TERMINAL")

  # The state names the receipt. The state also says where receipts live, so a
  # path pointing anywhere else is a state that has been tampered with.
  expected=$(authority_receipt_path "$RV_PID" "$RV_SCOPE_NAME" \
               "$(jq -r '.sequence' <<<"$RV_TERMINAL")")
  [ "$path" = "$expected" ] || answer invalid_receipt \
    "the state names a receipt outside the receipt store" "$EX_INVALID_RECEIPT"

  if ! reason=$(trusted_file "$path" 444); then
    answer invalid_receipt "the receipt $reason" "$EX_INVALID_RECEIPT"
  fi

  raw=$(cat "$path" 2>/dev/null) || answer invalid_receipt \
    "the receipt cannot be read" "$EX_INVALID_RECEIPT"
  jq -e . >/dev/null 2>&1 <<<"$raw" || answer invalid_receipt \
    "the receipt is not valid JSON" "$EX_INVALID_RECEIPT"

  # The published form is canonical. Requiring it to still be canonical closes
  # duplicate keys, reordering and alternate spellings in one comparison
  # instead of hunting for them field by field.
  canonical=$(jq -cS . <<<"$raw")
  [ "$raw" = "$canonical" ] || answer invalid_receipt \
    "the receipt is not in the canonical form it was published in" "$EX_INVALID_RECEIPT"
  RV_RECEIPT="$canonical"
}

rv_validate_schema() {
  if ! jq -e '
    type == "object" and .schema == 1 and (.protocol | type) == "number" and
    (.issuer | type) == "object" and .issuer.kind == "local-authority" and
    (.issuer.key_id | type) == "string" and (.issuer.key_id | test("^[0-9a-f]{64}$")) and
    (.project_id | type) == "string" and (.project_id | length) > 0 and
    (.workspace | type) == "string" and (.workspace | startswith("/")) and
    (.scope == "worktree" or .scope == "staged") and
    (.run_id | type) == "string" and (.run_id | length) > 0 and
    (.attempt | type) == "object" and (.attempt.sequence | type) == "number" and
    (.attempt.sequence | floor) == .attempt.sequence and .attempt.sequence >= 1 and
    (.status == "pass" or .status == "fail") and
    (.fingerprints | type) == "object" and
    ([.fingerprints.source,.fingerprints.contract,.fingerprints.control,.fingerprints.mechanism]
      | all(.[]; type == "object" and .algorithm == "sha256"
                 and (.value | type) == "string" and (.value | test("^[0-9a-f]{64}$")))) and
    (.checks | type) == "array" and
    all(.checks[];
      (.name | type) == "string" and (.name | length) > 0 and
      (.requirement == "required" or .requirement == "optional") and
      (.origin | type) == "string" and
      (.command_identity | type) == "string" and (.command_identity | test("^[0-9a-f]{64}$")) and
      (.execution | type) == "string" and
      ((.exit_code | type) == "number" or (.exit_code | type) == "null") and
      ((. | keys) - ["name","requirement","origin","command_identity","execution","exit_code"] | length) == 0) and
    (.authentication | type) == "object" and
    .authentication.format == "ed25519-openssl-rawin" and
    (.authentication.key_id | type) == "string" and (.authentication.key_id | test("^[0-9a-f]{64}$")) and
    (.authentication.value | type) == "string" and (.authentication.value | length) > 0 and
    ((.authentication | keys) - ["format","key_id","value"] | length) == 0 and
    ((. | keys) - ["schema","protocol","issuer","project_id","workspace","scope",
                   "run_id","attempt","status","fingerprints","checks","authentication"]
      | length) == 0
  ' >/dev/null 2>&1 <<<"$RV_RECEIPT"; then
    answer invalid_receipt "the receipt does not match the supported schema" "$EX_INVALID_RECEIPT"
  fi
  # A check name may appear once. Two entries for one name would let a passing
  # duplicate cover for a failing one.
  if [ "$(jq -r '[.checks[].name] | length' <<<"$RV_RECEIPT")" \
     != "$(jq -r '[.checks[].name] | unique | length' <<<"$RV_RECEIPT")" ]; then
    answer invalid_receipt "the receipt lists a check more than once" "$EX_INVALID_RECEIPT"
  fi
}

# --- authenticity ------------------------------------------------------------

rv_verify_signature() {
  local key_id pub reason computed payload sig value
  key_id=$(jq -r '.issuer.key_id' <<<"$RV_RECEIPT")

  # Every place the key is named has to agree, including the state, so that a
  # receipt cannot be validated under a key the authority never used for it.
  [ "$(jq -r '.authentication.key_id' <<<"$RV_RECEIPT")" = "$key_id" ] || answer invalid_receipt \
    "the receipt is signed under a different key than it claims" "$EX_INVALID_RECEIPT"
  [ "$(jq -r '.key_id' <<<"$RV_TERMINAL")" = "$key_id" ] || answer invalid_receipt \
    "the authority state names a different signing key" "$EX_INVALID_RECEIPT"

  pub=$(authority_trusted_key_path "$RV_PID" "$key_id")
  if ! reason=$(trusted_file "$pub" 444); then
    answer invalid_receipt "the trusted key for this receipt $reason" "$EX_INVALID_RECEIPT"
  fi

  # The file name is not evidence. The key is what it hashes to.
  computed=$(authority_key_id_from_public "$pub") || answer invalid_receipt \
    "the trusted key cannot be read as a public key" "$EX_INVALID_RECEIPT"
  [ "$computed" = "$key_id" ] || answer invalid_receipt \
    "the trusted key does not hash to the key id it is filed under" "$EX_INVALID_RECEIPT"
  openssl pkey -pubin -in "$pub" -noout -text 2>/dev/null | grep -qi 'ED25519' || answer invalid_receipt \
    "the trusted key is not an Ed25519 key" "$EX_INVALID_RECEIPT"

  payload=$(mktemp "${TMPDIR:-/tmp}/agent-md-rv-payload.XXXXXX") || answer unavailable \
    "cannot stage the payload" "$EX_UNAVAILABLE"
  sig=$(mktemp "${TMPDIR:-/tmp}/agent-md-rv-sig.XXXXXX") || { rm -f "$payload"
    answer unavailable "cannot stage the signature" "$EX_UNAVAILABLE"; }

  # Exactly the bytes the issuer signed: the receipt without its envelope, in
  # canonical form, with no trailing newline.
  jq -cS 'del(.authentication)' <<<"$RV_RECEIPT" | tr -d '\n' > "$payload"
  value=$(jq -r '.authentication.value' <<<"$RV_RECEIPT")
  if ! printf '%s' "$value" | base64 -d > "$sig" 2>/dev/null; then
    rm -f "$payload" "$sig"
    answer invalid_receipt "the signature is not valid base64" "$EX_INVALID_RECEIPT"
  fi
  [ "$(wc -c < "$sig")" -eq 64 ] || { rm -f "$payload" "$sig"
    answer invalid_receipt "the signature is not an Ed25519 signature" "$EX_INVALID_RECEIPT"; }

  if ! openssl pkeyutl -verify -pubin -inkey "$pub" -rawin -in "$payload" -sigfile "$sig" \
       >/dev/null 2>&1; then
    rm -f "$payload" "$sig"
    # A receipt that is present but does not verify is bad evidence, never
    # "no evidence": silently degrading would hide exactly the tampering the
    # signature exists to expose.
    answer invalid_receipt "the receipt signature does not verify" "$EX_INVALID_RECEIPT"
  fi
  rm -f "$payload" "$sig"
  RV_AUTHENTIC=true
  RV_KEY_ID=$(json_string "$key_id")
}

# --- bindings ----------------------------------------------------------------

rv_check_bindings() {
  local want_status
  # The receipt has to be the one the state published, in every field that
  # identifies it. Cryptographic validity says who signed it, not what it is
  # current for.
  [ "$(jq -r '.attempt.sequence' <<<"$RV_RECEIPT")" = "$(jq -r '.sequence' <<<"$RV_TERMINAL")" ] \
    || answer stale "the receipt is authentic but is not the sequence the authority calls latest" "$EX_STALE_IDENTITY"
  [ "$(jq -r '.run_id' <<<"$RV_RECEIPT")" = "$(jq -r '.run_id' <<<"$RV_TERMINAL")" ] \
    || answer invalid_receipt "the receipt belongs to a different run than the state records" "$EX_INVALID_RECEIPT"
  [ "$(jq -r '.scope' <<<"$RV_RECEIPT")" = "$(jq -r '.scope' <<<"$RV_TERMINAL")" ] \
    || answer invalid_receipt "the receipt records a different scope than the state" "$EX_INVALID_RECEIPT"
  [ "$(jq -cS '.fingerprints' <<<"$RV_RECEIPT")" = "$(jq -cS '.fingerprints' <<<"$RV_TERMINAL")" ] \
    || answer invalid_receipt "the receipt fingerprints differ from the state's record" "$EX_INVALID_RECEIPT"

  # The authority's internal vocabulary maps onto the receipt's public one.
  case "$(jq -r '.status' <<<"$RV_TERMINAL")" in
    candidate_pass) want_status=pass ;;
    candidate_fail) want_status=fail ;;
    *) answer invalid_receipt "the state records a terminal status that publishes no receipt" "$EX_INVALID_RECEIPT" ;;
  esac
  [ "$(jq -r '.status' <<<"$RV_RECEIPT")" = "$want_status" ] || answer invalid_receipt \
    "the receipt result disagrees with the authority's record of it" "$EX_INVALID_RECEIPT"

  # A receipt copied from another project, clone or scope stays perfectly
  # signed; it simply is not about this workspace.
  [ "$(jq -r '.project_id' <<<"$RV_RECEIPT")" = "$RV_PID" ] || answer invalid_receipt \
    "the receipt was issued for a different project" "$EX_INVALID_RECEIPT"
  [ "$(jq -r '.workspace' <<<"$RV_RECEIPT")" = "$RV_CANONICAL" ] || answer invalid_receipt \
    "the receipt was issued for a different workspace path" "$EX_INVALID_RECEIPT"
  [ "$(jq -r '.scope' <<<"$RV_RECEIPT")" = "$RV_SCOPE_NAME" ] || answer invalid_receipt \
    "the receipt was issued for a different scope" "$EX_INVALID_RECEIPT"

  RV_CURRENT=true

  # A current authenticated failure is a real result and is reusable evidence,
  # so it is not concluded here: it still has to survive the live identity and
  # the structural coverage check before anyone may act on it. Re-running 861
  # tests to rediscover a failure that is already signed and still current is
  # exactly the waste this is meant to remove.
  RV_ORDINARY=$(jq -c '.status' <<<"$RV_RECEIPT")
}

# --- live state --------------------------------------------------------------

# The four fingerprints of the workspace as it is now. Computed through the
# vendored Phase A functions, which are the same ones the authority used to
# produce the receipt, so a difference means the workspace moved and not that
# two implementations disagree.
rv_live_identity() {
  ( cd "$RV_CANONICAL" || exit 1
    authority_export_git_workspace_env "$RV_CANONICAL"
    jq -nc \
      --argjson source "$(authority_pa_verification_receipt_source_manifest_json "$RV_SCOPE_NAME")" \
      --argjson contract "$(authority_pa_effective_verification_contract_json "$RV_SCOPE_NAME")" \
      --argjson control "$(authority_pa_effective_control_requirements_json "$RV_SCOPE_NAME")" \
      --argjson mechanism "$(authority_pa_verification_receipt_mechanism_manifest_json "$RV_SCOPE_NAME")" \
      '{source:$source,contract:$contract,control:$control,mechanism:$mechanism}' )
}

rv_check_applicable() {
  local first second fp

  first=$(mktemp "${TMPDIR:-/tmp}/agent-md-rv-id.XXXXXX") || answer unavailable \
    "cannot stage the workspace identity" "$EX_UNAVAILABLE"
  if ! rv_live_identity > "$first" 2>/dev/null || ! jq -e . "$first" >/dev/null 2>&1; then
    rm -f "$first"
    answer unavailable "the current workspace identity could not be computed" "$EX_UNAVAILABLE"
  fi
  local part
  for part in source contract control mechanism; do
    if ! jq -e --arg p "$part" '.[$p].valid == true' "$first" >/dev/null 2>&1; then
      rm -f "$first"
      answer unavailable "the current workspace $part identity is not usable" "$EX_UNAVAILABLE"
    fi
  done

  fp=$(authority_identity_fingerprints "$first")
  if [ "$(jq -cS . <<<"$fp")" != "$(jq -cS '.fingerprints' <<<"$RV_RECEIPT")" ]; then
    rm -f "$first"
    # Still authentic, simply no longer about this tree.
    answer stale "the workspace has changed since this receipt was issued" "$EX_STALE_IDENTITY"
  fi

  rv_check_coverage "$first"

  # The bracket. Everything above was decided against one sample of a tree the
  # developer can edit at any moment. Recomputing afterwards means a workspace
  # that moved during validation produces a stale answer rather than a pass
  # granted for a tree that no longer exists. It does not lock anything: the
  # developer is never blocked, the answer is simply "try again".
  second=$(mktemp "${TMPDIR:-/tmp}/agent-md-rv-id2.XXXXXX") || { rm -f "$first"
    answer unavailable "cannot stage the second identity sample" "$EX_UNAVAILABLE"; }
  if ! rv_live_identity > "$second" 2>/dev/null || ! jq -e . "$second" >/dev/null 2>&1; then
    rm -f "$first" "$second"
    answer unavailable "the workspace identity could not be re-read" "$EX_UNAVAILABLE"
  fi
  if [ "$(jq -cS . "$first")" != "$(jq -cS . "$second")" ]; then
    rm -f "$first" "$second"
    answer stale "the workspace changed while it was being validated" "$EX_STALE_IDENTITY"
  fi
  rm -f "$first" "$second"
  RV_APPLICABLE=true
}

# Coverage is Phase A's rule, applied to the contract as it is now rather than
# as it was when the receipt was written. The receipt says a pass; this decides
# whether that pass still covers what the project currently requires.
#
# The receipt signs command_identity rather than the literal command, so the
# comparison recomputes the digest of the command the current contract declares.
# That keeps one source of truth: the command set is authenticated by the
# contract fingerprint, and the identity is derived from it.
rv_check_coverage() {
  local identity="$1" requirements missing groups
  requirements=$(authority_pa_verification_receipt_requirements_json \
    "$(jq -c '.contract' "$identity")" "$(jq -c '.control' "$identity")") \
    || answer unavailable "the current requirements could not be derived" "$EX_UNAVAILABLE"

  [ "$(jq -r '.valid' <<<"$requirements")" = true ] || answer unavailable \
    "the current contract or control record is not usable" "$EX_UNAVAILABLE"

  # Two modes, one rule. A pass must show every currently required check
  # completed and green. A failure must show every currently required check
  # completed against the same contract, whatever it exited with: that is what
  # makes the recorded failure a statement about this contract rather than a
  # stale or partial run. Either way the command identity must match, so a
  # receipt cannot cover a check whose command has since changed.
  local require_green=true
  [ "$(jq -r '. // "null"' <<<"$RV_ORDINARY")" = fail ] && require_green=false

  missing=$(jq -c --argjson receipt "$RV_RECEIPT" --argjson green "$require_green" '
    def covered($expected):
      any($receipt.checks[];
        .name == $expected.name and
        .requirement == $expected.requirement and
        .origin == $expected.origin and
        .execution == "completed" and
        (if $green then .exit_code == 0 else true end) and
        .command_identity == $expected.command_digest);
    [.required[] | select(covered(.) | not) | .name]' \
    <<<"$(rv_requirements_with_digests "$requirements")")

  if [ "$(jq -r 'length' <<<"$missing")" != 0 ]; then
    answer insufficient_coverage \
      "the receipt does not cover every currently required check: $(jq -r 'join(", ")' <<<"$missing")" \
      "$EX_INSUFFICIENT_COVERAGE"
  fi

  groups=$(jq -c --argjson receipt "$RV_RECEIPT" --argjson green "$require_green" '
    def covered($expected):
      any($receipt.checks[];
        .name == $expected.name and .execution == "completed" and
        (if $green then .exit_code == 0 else true end) and
        .command_identity == $expected.command_digest);
    [.any_of[] | select([.checks[] | select(covered(.))] | length == 0) | .name]' \
    <<<"$(rv_requirements_with_digests "$requirements")")

  if [ "$(jq -r 'length' <<<"$groups")" != 0 ]; then
    answer insufficient_coverage \
      "the receipt does not satisfy a required check group: $(jq -r 'join(", ")' <<<"$groups")" \
      "$EX_INSUFFICIENT_COVERAGE"
  fi

  # Independent verification and human approval are never ordinary receipt
  # checks, and no receipt may ever stand in for them.
  #
  # They do not, however, invalidate the ordinary half. A receipt that covers
  # the ordinary contract still spares those checks from running again; what it
  # cannot do is finish the job. So the requirement is reported rather than
  # used to refuse, and the exit status deliberately does not mean "completion
  # passed" -- only "the ordinary verification may be reused". A caller reads
  # requires_external to learn what it must still satisfy itself.
  RV_EXTERNAL=$(jq -c '.external' <<<"$requirements")
}

# Annotates each expected check with the digest of its command, which is what
# the receipt actually carries.
rv_requirements_with_digests() {
  local requirements="$1" out entry name digest
  out=$(jq -c '{required:[],any_of:[],external:.external}' <<<"$requirements")
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    digest=$(printf '%s' "$(jq -r '.command' <<<"$entry")" | sha256_hex)
    out=$(jq -c --argjson e "$entry" --arg d "$digest" \
      '.required += [$e + {command_digest:$d}]' <<<"$out")
  done <<EOF
$(jq -c '.required[]' <<<"$requirements")
EOF
  while IFS= read -r entry; do
    [ -n "$entry" ] || continue
    name=$(jq -r '.name' <<<"$entry")
    local checks='[]' c
    while IFS= read -r c; do
      [ -n "$c" ] || continue
      digest=$(printf '%s' "$(jq -r '.command' <<<"$c")" | sha256_hex)
      checks=$(jq -c --argjson c "$c" --arg d "$digest" '. + [$c + {command_digest:$d}]' <<<"$checks")
    done <<INNER
$(jq -c '.checks[]' <<<"$entry")
INNER
    out=$(jq -c --arg n "$name" --argjson ch "$checks" '.any_of += [{name:$n,checks:$ch}]' <<<"$out")
  done <<EOF
$(jq -c '.any_of[]' <<<"$requirements")
EOF
  printf '%s' "$out"
}

# --- entry point -------------------------------------------------------------

main() {
  local workspace="" scope=""
  while [ $# -gt 0 ]; do
    case "$1" in
      --root) ROOT=${2%/}; shift 2 ;;
      -h|--help) usage; exit 0 ;;
      -*) printf '%s: unknown option: %s\n' "$PROGRAM" "$1" >&2; usage >&2; exit "$EX_USAGE" ;;
      *)
        if [ -z "$workspace" ]; then workspace="$1"
        elif [ -z "$scope" ]; then scope="$1"
        else printf '%s: unexpected argument: %s\n' "$PROGRAM" "$1" >&2; exit "$EX_USAGE"
        fi
        shift ;;
    esac
  done
  [ -n "$workspace" ] && [ -n "$scope" ] || { usage >&2; exit "$EX_USAGE"; }

  command -v jq >/dev/null 2>&1 || { printf '%s: jq is required\n' "$PROGRAM" >&2; exit "$EX_UNAVAILABLE"; }
  command -v openssl >/dev/null 2>&1 || { printf '%s: openssl is required\n' "$PROGRAM" >&2; exit "$EX_UNAVAILABLE"; }

  case "$scope" in
    worktree) ;;
    staged) printf '%s: the staged scope is not supported yet\n' "$PROGRAM" >&2; exit "$EX_USAGE" ;;
    *) printf '%s: unknown scope: %s\n' "$PROGRAM" "$scope" >&2; exit "$EX_USAGE" ;;
  esac
  RV_SCOPE_NAME="$scope"
  RV_SCOPE=$(json_string "$scope")

  rv_resolve_project "$workspace"
  rv_read_state
  rv_resolve_terminal
  rv_load_receipt
  rv_validate_schema
  rv_verify_signature
  rv_check_bindings
  rv_check_applicable

  if [ "$(jq -r '. // "null"' <<<"$RV_ORDINARY")" = fail ]; then
    answer current_fail \
      "the ordinary verification failed for this exact state, and that result is authenticated and current" \
      "$EX_CURRENT_FAIL"
  fi
  answer reusable_ordinary \
    "the ordinary verification passed for this state and may be reused; any external guarantee is reported separately" \
    "$EX_REUSABLE"
}

main "$@"
