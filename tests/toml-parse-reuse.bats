#!/usr/bin/env bats
#
# A policy document is parsed once per resolution, not once per key. The reader
# stays the same strict parser; only the reuse of its output changes, so every
# answer must equal what a fresh parse would give, and nothing may outlive the
# resolution that loaded it.

load helpers

setup() {
  setup_repo
  CORE="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  VENDORED="$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh"
  PARSES="$BATS_TEST_TMPDIR/parses"
  # Counts executions of the parser program, which is the only awk program that
  # defines fail_at, and forwards every call to the real awk unchanged.
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat > "$BATS_TEST_TMPDIR/bin/awk" <<EOF
#!/bin/bash
case "\$*" in *'function fail_at('*) printf 'parse\n' >> "$PARSES" ;; esac
exec $(command -v awk) "\$@"
EOF
  chmod +x "$BATS_TEST_TMPDIR/bin/awk"
  export CORE VENDORED PARSES
  cat > agent-md.toml <<'EOF'
[verify]
lint = "shellcheck -x a.sh # not a comment"
test = "printf '\t%s' ok"
independent = "./verifier.sh"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 60
total_timeout_seconds = 120

[verify.attestation]
independent_files = ["verifier.conf"]

[state]
source_globs = ["src/**"]
ignore_globs = ["docs/**"]

[visual]
required = false
freshness_seconds = 600
EOF
}

teardown() { teardown_repo; }

counted() {
  : > "$PARSES"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$CORE"; "$@"' _ "$@"
}
parses() { wc -l < "$PARSES" | tr -d ' '; }

@test "the verification contract parses its document once" {
  counted verification_contract_json agent-md.toml > out.json
  [ "$(parses)" -eq 1 ]
  jq -e '.valid == true' out.json >/dev/null
}

@test "the state and visual readers parse their document once" {
  counted state_globs_json agent-md.toml > state.json
  [ "$(parses)" -eq 1 ]
  jq -e '.valid == true and .source_globs == ["src/**"] and .ignore_globs == ["docs/**"]' state.json >/dev/null
  counted visual_contract_from_config agent-md.toml > visual.json
  [ "$(parses)" -eq 1 ]
  jq -e '.valid == true and .freshness_seconds == 600' visual.json >/dev/null
}

@test "the vendored authority contract parses its document once" {
  : > "$PARSES"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH" bash -c '. "$VENDORED"; authority_pa_verification_contract_json agent-md.toml' > out.json
  [ "$(parses)" -eq 1 ]
  jq -e '.valid == true' out.json >/dev/null
}

@test "reuse answers exactly what a fresh parse answers" {
  local key fresh reused
  bash -c '. "$CORE"; verification_contract_json agent-md.toml' > reused.json
  # Each value read on its own, with nothing loaded, is the reference.
  for key in lint test independent; do
    fresh=$(bash -c '. "$CORE"; read_toml agent-md.toml verify "$1"' _ "$key")
    reused=$(jq -r --arg k "$key" '.checks[] | select(.name == $k) | .command' reused.json)
    [ "$fresh" = "$reused" ] || { printf '%s: fresh [%s] reused [%s]\n' "$key" "$fresh" "$reused" >&2; false; }
  done
  # A # inside a string and a kept escape survive reuse verbatim.
  [ "$(jq -r '.checks[] | select(.name == "lint") | .command' reused.json)" = 'shellcheck -x a.sh # not a comment' ]
  [ "$(jq -r '.checks[] | select(.name == "test") | .command' reused.json)" = "printf '\\t%s' ok" ]
}

@test "a loaded document never answers for another file" {
  printf '[verify]\nlint = "other-lint"\n' > other.toml
  run bash -c '. "$CORE"
    probe() {
      local toml_cache_file toml_cache_records toml_cache_status
      toml_document_cache agent-md.toml
      read_toml other.toml verify lint
    }
    probe'
  [ "$status" -eq 0 ]
  [ "$output" = other-lint ]
}

@test "nothing loaded outlives the resolution that loaded it" {
  run bash -c '. "$CORE"
    verification_contract_json agent-md.toml >/dev/null
    printf "[verify]\nlint = \"changed\"\n" > agent-md.toml
    verification_contract_json agent-md.toml | jq -r ".checks[] | select(.name == \"lint\") | .command"'
  [ "$status" -eq 0 ]
  [ "$output" = changed ]
}

@test "an invalid document stays invalid when its parse is reused" {
  printf '[verify]\ntest = "true"\ntest = "pytest -x"\n' > agent-md.toml
  counted verification_contract_json agent-md.toml > out.json
  [ "$(parses)" -eq 1 ]
  jq -e '.valid == false and .error.code == "CONFIG_INVALID"' out.json >/dev/null
  [ "$(jq -r '.error.message' out.json)" = 'Invalid agent-md.toml: line 3: duplicate key verify.test.' ]
}

@test "the vendored TOML reader is the core reader" {
  # Code only: the two copies may word a comment differently.
  local core vendored
  core=$(sed -n '/^toml_document() {/,/^toml_key_present() {/p' "$CORE" | grep -v '^[[:space:]]*#')
  vendored=$(sed -n '/^authority_pa_toml_document() {/,/^authority_pa_toml_key_present() {/p' "$VENDORED" \
    | sed 's/authority_pa_//g' | grep -v '^[[:space:]]*#')
  [ -n "$core" ]
  [ "$core" = "$vendored" ]
}
