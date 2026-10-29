#!/usr/bin/env bats
#
# agent-md.toml is read strictly. Anything that is not valid TOML, or falls
# outside the small subset the policy uses, makes the whole contract
# CONFIG_INVALID: no key from an invalid file is ever applied, so no reader can
# disagree about what the file means.

load helpers

setup() {
  setup_repo
  FIXTURES="$BATS_TEST_DIRNAME/fixtures/toml"
  export FIXTURES
}

teardown() { teardown_repo; }

lib() { bash -c '. .claude/hooks/_lib.sh; "$@"' _ "$@"; }

contract() { lib verification_contract_json agent-md.toml; }

assert_invalid() {
  local expected="$1" out
  out=$(contract)
  jq -e '.valid == false and .error.code == "CONFIG_INVALID"' <<<"$out" >/dev/null \
    || { printf 'expected CONFIG_INVALID, got:\n%s\n' "$out" >&2; return 1; }
  [[ "$(jq -r '.error.message' <<<"$out")" == *"$expected"* ]] \
    || { printf 'message:\n%s\nexpected to contain: %s\n' "$(jq -r '.error.message' <<<"$out")" "$expected" >&2; return 1; }
  # Nothing from an invalid file is interpreted.
  [ "$(jq '.checks | length' <<<"$out")" -eq 0 ]
}

commit_all() {
  git add -A
  git -c core.hooksPath=/dev/null commit -qm "$1"
}

@test "a duplicate key is invalid instead of first-wins" {
  printf '[verify]\ntest = "true"\ntest = "pytest -x"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  assert_invalid 'Invalid agent-md.toml: line 3: duplicate key verify.test.'
}

@test "a duplicate table is invalid" {
  printf '[verify]\ntest = "pytest"\n\n[verify.policy]\nrequired = ["test"]\n\n[verify]\nlint = "true"\n' > agent-md.toml
  assert_invalid 'line 7: table [verify] is defined more than once'
}

@test "free prose is invalid" {
  printf '[verify]\ntest = "pytest"\nRun the tests before merging.\n' > agent-md.toml
  assert_invalid 'line 3: expected'
}

@test "malformed quoting is invalid" {
  printf '[verify]\ntest = "pytest -k \x27a\n' > agent-md.toml
  assert_invalid 'line 2: unterminated string'
  printf '[verify]\ntest = "pytest" -x\n' > agent-md.toml
  assert_invalid 'line 2: unexpected text after the value'
  printf '[verify.policy]\nrequired = ["test"\n' > agent-md.toml
  assert_invalid 'line 2: unterminated array'
}

@test "constructs outside the supported subset are refused explicitly" {
  printf 'verify.test = "pytest"\n' > agent-md.toml
  assert_invalid 'dotted keys are not supported'
  printf '[verify]\ntest = "grep -E \x27\\.py$\x27 files"\n' > agent-md.toml
  assert_invalid 'line 2: invalid escape sequence in a double-quoted string in verify.test'
  printf '[[verify]]\ntest = "x"\n' > agent-md.toml
  assert_invalid 'arrays of tables are not supported'
  printf '[verify]\ntest = { run = "x" }\n' > agent-md.toml
  assert_invalid 'inline tables are not supported'
  printf '[verify]\npolicy = 1\n\n[verify.policy]\nrequired = []\n' > agent-md.toml
  assert_invalid 'conflicts with a key of the same name'
}

@test "valid comments are accepted and do not change the contract" {
  printf '# policy\n[verify] # checks\n  test = "pytest"   # unit tests\n\n# required\n[verify.policy]\nrequired = [\n  "test", # only this\n]\n' > agent-md.toml
  run contract
  jq -e '.valid == true' <<<"$output" >/dev/null
  jq -e '[.checks[] | select(.name == "test")][0] | .command == "pytest" and .requirement == "required"' <<<"$output" >/dev/null
}

@test "a # inside a quoted value is preserved, not truncated" {
  printf '[verify]\ntest = "bats tests/ --filter \x27#smoke\x27"\nlint = \x27grep -q "#!" run.sh\x27\n\n[verify.policy]\nrequired = ["test", "lint"]\n' > agent-md.toml
  run contract
  jq -e '.valid == true' <<<"$output" >/dev/null
  [ "$(jq -r '.checks[] | select(.name == "test") | .command' <<<"$output")" = "bats tests/ --filter '#smoke'" ]
  [ "$(jq -r '.checks[] | select(.name == "lint") | .command' <<<"$output")" = 'grep -q "#!" run.sh' ]
}

@test "a valid escape sequence is validated but kept verbatim, as rc2 read it" {
  printf '[verify]\ntest = "printf \x27%%s\\\\n\x27 ok"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  run contract
  jq -e '.valid == true' <<<"$output" >/dev/null
  [ "$(jq -r '.checks[] | select(.name == "test") | .command' <<<"$output")" = "printf '%s\\\\n' ok" ]
}

@test "a valid policy resolves to exactly the contract rc2 produced" {
  cp "$FIXTURES/valid-rich.toml" agent-md.toml
  diff <(contract | jq -S .) "$FIXTURES/valid-rich.contract.json"
  [ "$(lib read_toml agent-md.toml verify lint_file)" = 'case {file} in *.py) ruff check {file} ;; esac' ]
  [ "$(lib read_toml agent-md.toml integrations.icm enabled)" = true ]
  lib state_globs_json agent-md.toml \
    | jq -e '.valid and .source_globs == ["src/**","tests/**","*.py"] and .ignore_globs == ["docs/**",".gitignore"]' >/dev/null
  lib visual_contract_from_config agent-md.toml \
    | jq -e '.valid and .required == false and .artifacts_dir == ".agent/visual" and .freshness_seconds == 3600' >/dev/null
}

@test "an invalid Git baseline blocks even when the worktree is valid" {
  printf '[verify]\ntest = "true"\ntest = "pytest"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  commit_all baseline
  printf '[verify]\ntest = "pytest"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  run lib effective_verification_contract_json worktree
  jq -e '.valid == false and .error.code == "CONFIG_INVALID"' <<<"$output" >/dev/null
  [[ "$(jq -r '.error.message' <<<"$output")" == *"agent-md.toml (HEAD baseline): line 3: duplicate key verify.test"* ]]
}

@test "an invalid worktree or staged proposal names its snapshot" {
  printf '[verify]\ntest = "pytest"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  commit_all baseline
  printf '[verify]\ntest = "pytest"\nnotes go here\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  run lib effective_verification_contract_json worktree
  jq -e '.valid == false and .error.code == "CONFIG_INVALID"' <<<"$output" >/dev/null
  [[ "$(jq -r '.error.message' <<<"$output")" == *"agent-md.toml (worktree): line 3:"* ]]
  git add agent-md.toml
  run lib effective_verification_contract_json staged
  [[ "$(jq -r '.error.message' <<<"$output")" == *"agent-md.toml (staged): line 3:"* ]]
}

@test "verify.sh blocks on an invalid policy" {
  printf '[verify]\ntest = "true"\ntest = "true"\n' > agent-md.toml
  mkdir -p .agent-md/bin
  cp "$BATS_TEST_DIRNAME/../.agent-md/bin/verify.sh" .agent-md/bin/
  run bash .agent-md/bin/verify.sh
  [ "$status" -ne 0 ]
  [[ "$output" == *"CONFIG_INVALID"* ]]
  [[ "$output" == *"duplicate key verify.test"* ]]
}

@test "state and visual readers refuse an invalid document" {
  printf '[state]\nsource_globs = ["src/**"]\nsource_globs = ["nothing"]\n\n[visual]\nrequired = true\n' > agent-md.toml
  lib state_globs_json agent-md.toml | jq -e '.valid == false and (.error | contains("duplicate key state.source_globs"))' >/dev/null
  lib visual_contract_from_config agent-md.toml | jq -e '.valid == false and (.error | contains("duplicate key state.source_globs"))' >/dev/null
}

@test "diagnostics name the line and cause without echoing file content" {
  printf '[verify]\ntest = "pytest"\napi_token = sk-live-SECRET123\n' > agent-md.toml
  run contract
  [[ "$output" == *"line 3:"* ]]
  [[ "$output" != *"SECRET123"* ]]
  printf '[verify]\ntest = "pytest"\nexport TOKEN=sk-live-SECRET456 and more prose\n' > agent-md.toml
  run contract
  [[ "$output" == *"line 3:"* ]]
  [[ "$output" != *"SECRET456"* ]]
}

@test "receipt reuse is never consulted for an invalid contract" {
  printf '[verify]\ntest = "true"\ntest = "true"\n\n[verify.policy]\nrequired = ["test"]\n' > agent-md.toml
  run bash -c '
    . .claude/hooks/_lib.sh
    run_receipt_first_verification_contract() {
      echo CONSULTED >&2
      jq -cn "{status:\"pass\",contract:{valid:true,checks:[]},results:[]}"
    }
    completion_evaluation_begin
    context=$(completion_evaluation_context_json worktree host)
    run_completion_evaluation "$context" completion receipt-first'
  [[ "$output" != *CONSULTED* ]]
  jq -e '.summary.status == "fail"' <<<"$(printf '%s\n' "$output" | tail -1)" >/dev/null
  [[ "$output" == *"CONFIG_INVALID"* ]]
}
