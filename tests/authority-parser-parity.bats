#!/usr/bin/env bats
#
# Parser parity. The authority parses agent-md.toml with its own reader so that
# a privileged program never runs the repository's code. That creates a risk the
# two readers disagree about what was configured, so the invariant is
# one-directional and pinned here:
#
#   authority accepts  =>  the core accepts, and both describe the same contract
#   authority refuses  =>  ineligible, and no receipt is ever possible
#
# The authority is allowed to be stricter. It is never allowed to accept a
# contract the core reads differently.

load helpers

setup() {
  setup_repo
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  export LIB
}
teardown() { teardown_repo; }

core_contract() {
  bash -c '. .claude/hooks/_lib.sh; verification_contract_json agent-md.toml'
}

authority_contract() {
  bash -c '. "$LIB"; authority_read_contract agent-md.toml'
}

authority_error() {
  bash -c '. "$LIB"; authority_read_contract agent-md.toml >/dev/null 2>&1 || printf "%s" "$AUTHORITY_CONTRACT_ERROR"'
}

# Projects both readers onto the same observable contract so they can be
# compared: configured ordinary commands, the required set, and the timeouts.
core_projection() {
  core_contract | jq -S '{
    checks: [.checks[]
      | select(.origin == "configured")
      | select(.name != "independent" and .name != "approval")
      | {name, command}] | sort_by(.name),
    required: [.checks[]
      | select(.requirement == "required")
      | select(.name != "independent" and .name != "approval")
      | .name] | sort,
    timeout_seconds: (.timeout_seconds // null),
    total_timeout_seconds: (.total_timeout_seconds // null),
    preparation: (.preparation // null)
  }'
}

authority_projection() {
  authority_contract | jq -S '{
    checks: (.checks | sort_by(.name)),
    required: (.required | sort),
    timeout_seconds: .timeout_seconds,
    total_timeout_seconds: .total_timeout_seconds,
    preparation: (.preparation // null)
  }'
}

# The whole invariant in one place.
assert_parity() {
  if authority_contract >/dev/null 2>&1; then
    run core_contract
    [ "$status" -eq 0 ]
    printf '%s' "$output" | jq -e '.valid == true' >/dev/null \
      || { echo "authority accepted a contract the core rejects" >&2; return 1; }
    local core auth
    core=$(core_projection)
    auth=$(authority_projection)
    if [ "$core" != "$auth" ]; then
      printf 'core:\n%s\nauthority:\n%s\n' "$core" "$auth" >&2
      return 1
    fi
  else
    # Authority refused. That is always safe; record that it gave a reason.
    [ -n "$(authority_error)" ]
  fi
}

write_toml() { printf '%s\n' "$1" > agent-md.toml; }

@test "1 a plain contract agrees on both sides" {
  write_toml '[verify]
lint = "shellcheck ."
test = "bats tests/"

[verify.policy]
required = ["lint", "test"]'
  assert_parity
  [ "$(authority_projection | jq -r '.checks | length')" -eq 2 ]
}

@test "1a approved Poetry preparation has exact core and authority parity" {
  write_toml '[verify]
lint = "poetry run ruff check ."

[verify.policy]
required = ["lint"]
timeout_seconds = 20

[verify.preparation]
provider = "poetry"
command = "poetry sync --no-root"
timeout_seconds = 30'
  assert_parity
  authority_contract | jq -e '.preparation == {provider:"poetry",command:"poetry sync --no-root",timeout_seconds:30}' >/dev/null
}

@test "1b preparation alone cannot satisfy required ordinary coverage" {
  write_toml '[verify.policy]
required = ["lint"]
timeout_seconds = 20

[verify.preparation]
provider = "poetry"
command = "poetry sync --no-root"
timeout_seconds = 10'
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$output" == *"no configured command"* || "$output" == *"no ordinary verification command"* ]]
}

@test "2 every ordinary check name agrees" {
  write_toml '[verify]
typecheck = "tsc --noEmit"
lint = "eslint ."
test = "jest"
integration = "jest --int"
smoke = "./smoke.sh"
runtime = "./run.sh --help"

[verify.policy]
required = ["typecheck", "lint", "test"]'
  assert_parity
  [ "$(authority_projection | jq -r '.checks | length')" -eq 6 ]
}

@test "3 optional checks stay out of the required set" {
  write_toml '[verify]
lint = "shellcheck ."
smoke = "./smoke.sh"

[verify.policy]
required = ["lint"]'
  assert_parity
  authority_contract | jq -e '.required == ["lint"]' >/dev/null
}

@test "4 both timeouts agree" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test"]
timeout_seconds = 360
total_timeout_seconds = 540'
  assert_parity
  authority_contract | jq -e '.timeout_seconds == 360 and .total_timeout_seconds == 540' >/dev/null
}

@test "5 comments and whitespace do not change the contract" {
  write_toml '# leading comment

[verify]
   lint   =   "shellcheck ."
test = "bats tests/"   

# trailing comment
[verify.policy]
required = [ "lint" ,  "test" ]'
  assert_parity
}

@test "6 a multiline required array agrees" {
  write_toml '[verify]
lint = "shellcheck ."
test = "bats tests/"

[verify.policy]
required = [
  "lint",
  "test",
]'
  assert_parity
  authority_contract | jq -e '.required == ["lint","test"]' >/dev/null
}

@test "7 conditional verifiers are recorded but never executable" {
  write_toml '[verify]
test = "bats tests/"
independent = "./ci-attestation.sh"
approval = "./human-approval.sh"

[verify.policy]
required = ["test"]'
  assert_parity
  authority_contract | jq -e '
    ([.checks[].name] | index("independent")) == null and
    ([.checks[].name] | index("approval")) == null and
    (.excluded_conditional | length) == 2
  ' >/dev/null
}

@test "8 an empty verify section is refused by both" {
  write_toml '[verify]

[verify.policy]
required = []'
  run authority_contract
  [ "$status" -ne 0 ]
  assert_parity
}

@test "9 an unknown required name is refused by both" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test", "nonsense"]'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "10 a required name with no command is refused by the authority" {
  # Divergence in the safe direction. The core keeps the contract valid and
  # turns the missing command into a VERIFY_UNAVAILABLE failure when the check
  # runs. The authority will not approve a contract it cannot fully execute, so
  # it refuses at approval time and the project simply never accelerates.
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test", "lint"]'
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *"no configured command"* ]]

  run core_contract
  printf '%s' "$output" | jq -e '
    .valid == true and
    any(.checks[]; .name == "lint" and .requirement == "required" and .origin == "not configured")
  ' >/dev/null
  assert_parity
}

@test "11 an empty command is refused by both" {
  write_toml '[verify]
test = ""

[verify.policy]
required = ["test"]'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "12 a non-integer timeout is refused by both" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test"]
timeout_seconds = "soon"'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "13 a zero timeout is refused by both" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test"]
timeout_seconds = 0'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "14 a malformed required array is refused by both" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test"'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "15 a duplicate required entry is refused by both" {
  write_toml '[verify]
test = "bats tests/"

[verify.policy]
required = ["test", "test"]'
  run authority_contract
  [ "$status" -ne 0 ]
  run core_contract
  printf '%s' "$output" | jq -e '.valid == false' >/dev/null
}

@test "16 a duplicate verify key is refused by the authority" {
  # The core silently keeps the first value. The authority refuses rather than
  # approve a file whose meaning depends on reader order.
  write_toml '[verify]
test = "bats tests/"
test = "true"

[verify.policy]
required = ["test"]'
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *duplicate* ]]
  assert_parity
}

@test "17 a comment marker inside a command is refused by the authority" {
  # The core strips from the first # before removing quotes, which silently
  # truncates the command. The authority refuses the ambiguity instead.
  write_toml '[verify]
test = "bats tests/ # not a comment"

[verify.policy]
required = ["test"]'
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *"comment marker"* ]]
  assert_parity
}

@test "18 a single-quoted command is refused by the authority" {
  write_toml "[verify]
test = 'bats tests/'

[verify.policy]
required = [\"test\"]"
  run authority_contract
  [ "$status" -ne 0 ]
  assert_parity
}

@test "19 an absent required array is refused by the authority" {
  # The core falls back to legacy inference here. The authority will not
  # approximate it.
  write_toml '[verify]
test = "bats tests/"'
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *"must be declared explicitly"* ]]
  assert_parity
}

@test "20 nothing but garbage is refused by both" {
  write_toml 'not a contract at all'
  run authority_contract
  [ "$status" -ne 0 ]
  assert_parity
}

@test "21 an absent file is refused by the authority" {
  rm -f agent-md.toml
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *absent* ]]
}

@test "22 a symlinked contract is refused by the authority" {
  printf '[verify]\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > real.toml
  ln -s real.toml agent-md.toml
  run authority_contract
  [ "$status" -ne 0 ]
  [[ "$(authority_error)" == *symlink* ]]
}

@test "23 the repository's own contract has parity" {
  cp "$BATS_TEST_DIRNAME/../agent-md.toml" agent-md.toml
  assert_parity
}
