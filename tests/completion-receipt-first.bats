#!/usr/bin/env bats
#
# Receipt-first completion.
#
# Completion consults an authenticated evaluation before running the ordinary
# contract. These cases cover the routing and the shape of what it produces.
# The end-to-end path, with a real authority, real accounts and a real sudo
# boundary, is proven in tests/integration/local-issuer-boundary.bash; it
# cannot be proven here because the validator and issuer live at fixed absolute
# paths on purpose. There is deliberately no environment variable that
# redirects them, because anything that could point completion at a different
# validator could also make it say that verification passed.

setup() {
  REPO="$BATS_TEST_DIRNAME/.."
  WORK="$(mktemp -d)"
  export REPO WORK
}

teardown() { rm -rf "$WORK"; }

lib() { bash -c '. "$1/.claude/hooks/_lib.sh"; shift; "$@"' _ "$REPO" "$@"; }

# A contract shaped like the resolver produces.
contract_json() {
  jq -cn '{valid:true,policy:"effective",timeout_seconds:60,total_timeout_seconds:300,
    checks:[
      {name:"lint",requirement:"required",origin:"configured",command:"true",trusted_files:[],capabilities:[]},
      {name:"test",requirement:"required",origin:"configured",command:"true",trusted_files:[],capabilities:[]},
      {name:"smoke",requirement:"optional",origin:"configured",command:"true",trusted_files:[],capabilities:[]}
    ]}'
}

# A receipt as the authority publishes one, written where a decision can name it.
write_receipt() {
  local path="$1" status="${2:-pass}" smoke_exit="${3:-0}"
  jq -cn --arg status "$status" --argjson smoke "$smoke_exit" '
    {schema:1,protocol:1,
     issuer:{kind:"local-authority",key_id:("a"*64)},
     project_id:"p",workspace:"/w",scope:"worktree",run_id:"r",
     attempt:{sequence:7},status:$status,
     fingerprints:{},
     checks:[
       {name:"lint",requirement:"required",origin:"configured",
        command_identity:("b"*64),execution:"completed",
        exit_code:(if $status == "fail" then 1 else 0 end)},
       {name:"test",requirement:"required",origin:"configured",
        command_identity:("c"*64),execution:"completed",exit_code:0},
       {name:"smoke",requirement:"optional",origin:"configured",
        command_identity:("d"*64),execution:"completed",exit_code:$smoke}
     ],
     authentication:{format:"ed25519-openssl-rawin",key_id:("a"*64),value:"x"}}' > "$path"
}

decision_json() {
  local status="$1" receipt="$2" external="${3:-[]}" ordinary="${4:-null}"
  jq -cn --arg status "$status" --arg receipt "$receipt" \
    --argjson external "$external" --argjson ordinary "$ordinary" '
    {schema:1,status:$status,reason:"fixture",
     authentic:true,current:true,applicable:true,
     project_id:"p",workspace:"/w",scope:"worktree",sequence:7,
     key_id:("a"*64),receipt:$receipt,ordinary:$ordinary,requires_external:$external}'
}

# --- what a reused result looks like -----------------------------------------

@test "1 a reusable pass produces a passing verification without running checks" {
  write_receipt "$WORK/r.json" pass
  run lib completion_receipt_verification_json \
    "$(decision_json reusable_ordinary "$WORK/r.json" '[]' '"pass"')" "$(contract_json)"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = pass ]
  # One result per check the receipt covered, named so Risk can still find them.
  [ "$(jq -r '[.results[].check] | sort | join(",")' <<<"$output")" = "lint,smoke,test" ]
  [ "$(jq -r '.results | all(.[]; .origin == "authenticated receipt")' <<<"$output")" = true ]
  [ "$(jq -r '.results | all(.[]; .code == "VERIFY_RECEIPT_REUSED")' <<<"$output")" = true ]
}

@test "2 a reused failure fails the verification" {
  write_receipt "$WORK/r.json" fail
  run lib completion_receipt_verification_json \
    "$(decision_json current_fail "$WORK/r.json" '[]' '"fail"')" "$(contract_json)"
  [ "$status" -eq 0 ]
  [ "$(jq -r .status <<<"$output")" = fail ]
  [ "$(jq -r '[.results[] | select(.check=="lint")] | first | .status' <<<"$output")" = fail ]
  [ "$(jq -r '[.results[] | select(.check=="lint")] | first | .severity' <<<"$output")" = error ]
}

@test "3 a failing optional check does not fail the verification" {
  write_receipt "$WORK/r.json" pass 1
  run lib completion_receipt_verification_json \
    "$(decision_json reusable_ordinary "$WORK/r.json" '[]' '"pass"')" "$(contract_json)"
  [ "$(jq -r .status <<<"$output")" = pass ]
  [ "$(jq -r '[.results[] | select(.check=="smoke")] | first | .severity' <<<"$output")" = warning ]
}

@test "4 runtime and smoke evidence survives reuse so Risk can still see it" {
  # Risk at medium or above looks for a passing runtime or smoke result. A
  # reused verification that dropped them would silently lose that evidence.
  write_receipt "$WORK/r.json" pass 0
  run lib completion_receipt_verification_json \
    "$(decision_json reusable_ordinary "$WORK/r.json" '[]' '"pass"')" "$(contract_json)"
  [ "$(jq -r '[.results[] | select((.check=="runtime" or .check=="smoke") and .status=="pass")] | length' <<<"$output")" -ge 1 ]
}

@test "5 a decision naming no readable receipt produces nothing" {
  run lib completion_receipt_verification_json \
    "$(decision_json reusable_ordinary "$WORK/absent.json")" "$(contract_json)"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

# --- the notice --------------------------------------------------------------

@test "6 a reused result is labelled as reused, never as a fresh run" {
  run lib completion_receipt_notice_result_json \
    "$(decision_json reusable_ordinary x '[]' '"pass"')" info VERIFY_RECEIPT_REUSED "reused" ""
  [ "$(jq -r .code <<<"$output")" = VERIFY_RECEIPT_REUSED ]
  [ "$(jq -r .check <<<"$output")" = receipt ]
  [ "$(jq -r .status <<<"$output")" = pass ]
}

@test "7 outstanding external guarantees are carried into the summary" {
  run lib completion_receipt_notice_result_json \
    "$(decision_json reusable_ordinary x '["independent","approval"]' '"pass"')" \
    info VERIFY_RECEIPT_REUSED "reused" ""
  [ "$(jq -r '.requires_external | sort | join(",")' <<<"$output")" = "approval,independent" ]
}

# --- capability and legacy ---------------------------------------------------

@test "8 without an installed authority the router declines and legacy runs" {
  # This machine has no authority installed, which is the ordinary case.
  run lib completion_receipt_capability_available
  [ "$status" -ne 0 ]
  run lib run_receipt_first_verification_contract "$(contract_json)" "$WORK"
  [ "$status" -ne 0 ]
  [ -z "$output" ]
}

@test "9 the fixed paths are absolute and not redirectable" {
  run lib completion_receipt_validator_path
  [ "$output" = /usr/local/lib/agent-md/receipt-verify.sh ]
  run lib completion_receipt_issuer_path
  [ "$output" = /usr/local/lib/agent-md/agent-md-issuer ]
  # No environment variable reaches either path.
  run bash -c "sed -n '/^COMPLETION_AUTHORITY_LIB_DIR=/,/^}/p' '$REPO/.claude/hooks/_lib.sh' | head -1"
  [ "$output" = "COMPLETION_AUTHORITY_LIB_DIR=/usr/local/lib/agent-md" ]
  run bash -c "grep -nE 'COMPLETION_AUTHORITY_LIB_DIR=\\\$\\{|AGENT_MD_(VALIDATOR|AUTHORITY|ISSUER)' '$REPO/.claude/hooks/_lib.sh'"
  [ "$status" -ne 0 ]
}

# --- the boundary it is wired at ---------------------------------------------

@test "10 only the Stop handler asks for receipt-first" {
  run grep -c 'run_completion_evaluation "$CONTEXT" completion receipt-first' \
    "$REPO/.claude/hooks/stop-verify.sh"
  [ "$output" = "1" ]
  # An explicit verification request verifies; it does not consult a cache.
  run grep -n 'receipt-first' "$REPO/.agent-md/bin/verify.sh"
  [ "$status" -ne 0 ]
  run grep -n 'receipt-first' "$REPO/.githooks/pre-commit"
  [ "$status" -ne 0 ]
}

@test "11 both hosts reach the same handler, so the semantics cannot diverge" {
  # Codex runs the Claude Stop handler rather than carrying its own router.
  run grep -c 'stop-verify.sh' "$REPO/.codex/hooks/stop.sh"
  [ "$output" -ge 1 ]
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO/.codex/hooks/stop.sh' \
    | grep -nE 'receipt-verify|pkeyutl|reusable_ordinary|current_fail'"
  [ "$status" -ne 0 ]
}

@test "12 receipt-first is confined to the worktree scope" {
  run bash -c "sed -n '/receipt_mode\" = receipt-first/,+2p' '$REPO/.claude/hooks/_lib.sh'"
  [[ "$output" == *"worktree"* ]]
}

# --- no new capability -------------------------------------------------------

@test "13 completion introduces no way to issue or sign anything" {
  run bash -c "grep -vE '^[[:space:]]*#' '$REPO/.claude/hooks/_lib.sh' \
    | grep -nE -- '--refresh|--issue|--sign|verify-and-sign|pkeyutl'"
  [ "$status" -ne 0 ]
  # Evidence is produced by the existing evaluation capability and nothing else:
  # the only subcommand completion ever hands the issuer is evaluate.
  run bash -c "grep -oE '\\\$issuer\" [a-z-]+' '$REPO/.claude/hooks/_lib.sh' | sort -u"
  [ "$output" = '$issuer" evaluate' ]
}

@test "14 the authority is never invoked interactively" {
  # A completion handler that waited for a password would hang the host.
  run bash -c "grep -n 'sudo' '$REPO/.claude/hooks/_lib.sh' | grep -v '^[0-9]*:[[:space:]]*#'"
  [ "$status" -eq 0 ]
  while IFS= read -r line; do
    [[ "$line" == *"sudo -n"* ]] || [[ "$line" == *"command -v sudo"* ]] || return 1
  done <<<"$output"
}
