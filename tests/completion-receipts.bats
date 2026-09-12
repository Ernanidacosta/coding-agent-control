#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" .
  mkdir -p src
  printf '#!/bin/sh\nprintf ok\\n\n' > src/app.sh
  chmod +x src/app.sh
  printf '.cache/\n' > .gitignore
  cat > agent-md.toml <<'EOF'
[verify]
test = "true"

[verify.policy]
required = ["test"]
timeout_seconds = 30
EOF
  cat > .project-control.toml <<'EOF'
schema = 1
risk = "low"
EOF
  git add .
  git commit -qm "receipt fixture baseline"
}

teardown() { teardown_repo; }

receipt_identity() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_identity_json "$1"' _ "${1:-worktree}"
}

receipt_manifest() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_source_manifest_json "$1"' _ "${1:-worktree}"
}

receipt_payload_fingerprint() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_payload_fingerprint_json "$1"' _ "$1"
}

make_pass_receipt() {
  local identity="$1" sequence="${2:-1}" checks
  checks=$(printf '%s' "$identity" | jq -c \
    '[.requirements.required[] | . + {status:"pass",exit_code:0}]')
  jq -cn --argjson identity "$identity" --arg sequence "$sequence" --argjson checks "$checks" '
    {
      schema:1,
      scope:$identity.scope,
      attempt:{issuer:"test-validator-fixture",sequence:$sequence},
      fingerprints:$identity.fingerprints,
      status:"pass",
      checks:$checks,
      authentication:{format:"fixture-only",value:"not-an-authority"}
    }
  '
}

make_failed_receipt() {
  local identity="$1" sequence="${2:-2}" checks
  checks=$(printf '%s' "$identity" | jq -c \
    '[.requirements.required[] | . + {status:"fail",exit_code:1}]')
  jq -cn --argjson identity "$identity" --arg sequence "$sequence" --argjson checks "$checks" '
    {
      schema:1,
      scope:$identity.scope,
      attempt:{issuer:"test-validator-fixture",sequence:$sequence},
      fingerprints:$identity.fingerprints,
      status:"fail",
      checks:$checks,
      authentication:{format:"fixture-only",value:"not-an-authority"}
    }
  '
}

# This fixture represents the already-trusted output of a future provider
# validator. It is passed only to the pure state function and is never wired to
# Stop or treated as a real issuer.
provider_validation_fixture() {
  local receipt="$1" latest="${2:-true}" payload
  payload=$(receipt_payload_fingerprint "$receipt")
  jq -cn --argjson receipt "$receipt" --argjson latest "$latest" --argjson payload "$payload" '
    {
      schema:1,
      status:"pass",
      authentic:true,
      latest:$latest,
      issuer:$receipt.attempt.issuer,
      sequence:$receipt.attempt.sequence,
      payload_fingerprint:$payload
    }
  '
}

receipt_state() {
  bash -c '. .claude/hooks/_lib.sh; verification_receipt_state_json "$1" "$2" "$3"' \
    _ "$1" "$2" "$3"
}

@test "worktree manifest and identity are deterministic" {
  first_manifest=$(receipt_manifest worktree)
  second_manifest=$(receipt_manifest worktree)
  first_identity=$(receipt_identity worktree)
  second_identity=$(receipt_identity worktree)

  [ "$first_manifest" = "$second_manifest" ]
  [ "$first_identity" = "$second_identity" ]
  printf '%s' "$first_manifest" | jq -e '
    .valid and .scope == "worktree" and .head != null and
    (.entries | length) > 0
  ' >/dev/null
  printf '%s' "$first_identity" | jq -e '
    .valid and
    (.fingerprints | keys == ["contract","control","mechanism","source"]) and
    (all(.fingerprints[]; .algorithm == "sha256")) and
    (.requirements.required | length) == 1
  ' >/dev/null

  unusual_path=$'untracked\nname.txt'
  printf unusual > "$unusual_path"
  unusual_manifest=$(receipt_manifest worktree)
  printf '%s' "$unusual_manifest" | jq -e --arg path "$unusual_path" '
    any(.entries[]; .path == $path and .worktree.state == "present")
  ' >/dev/null
}

@test "worktree identity changes for tracked content and index state" {
  baseline=$(receipt_identity worktree)
  printf '#!/bin/sh\nprintf changed\\n\n' > src/app.sh
  unstaged=$(receipt_identity worktree)
  git add src/app.sh
  staged=$(receipt_identity worktree)

  [ "$(printf '%s' "$baseline" | jq -r '.fingerprints.source.value')" != \
    "$(printf '%s' "$unstaged" | jq -r '.fingerprints.source.value')" ]
  [ "$(printf '%s' "$unstaged" | jq -r '.fingerprints.source.value')" != \
    "$(printf '%s' "$staged" | jq -r '.fingerprints.source.value')" ]
}

@test "manifest records deletes modes and symlink targets" {
  chmod -x src/app.sh
  mode_manifest=$(receipt_manifest worktree)
  printf '%s' "$mode_manifest" | jq -e '
    .entries[] | select(.path == "src/app.sh") | .worktree.mode == "100644"
  ' >/dev/null

  rm src/app.sh
  ln -s first-target src/app.sh
  first_link=$(receipt_manifest worktree)
  rm src/app.sh
  ln -s second-target src/app.sh
  second_link=$(receipt_manifest worktree)
  [ "$(printf '%s' "$first_link" | jq -r '.entries[] | select(.path == "src/app.sh") | .worktree.digest')" != \
    "$(printf '%s' "$second_link" | jq -r '.entries[] | select(.path == "src/app.sh") | .worktree.digest')" ]

  rm src/app.sh
  deleted=$(receipt_manifest worktree)
  printf '%s' "$deleted" | jq -e '
    .entries[] | select(.path == "src/app.sh") | .worktree.state == "absent"
  ' >/dev/null
}

@test "non-ignored untracked files invalidate while structural and ignored paths do not" {
  baseline=$(receipt_identity worktree)
  mkdir -p .cache .agent/verification memory
  printf ignored > .cache/output
  printf forged > .agent/verification/worktree.json
  printf 'Status: done\n' > memory/progress.md
  excluded=$(receipt_identity worktree)
  [ "$(printf '%s' "$baseline" | jq -r '.fingerprints.source.value')" = \
    "$(printf '%s' "$excluded" | jq -r '.fingerprints.source.value')" ]

  printf relevant > untracked-input.txt
  relevant=$(receipt_identity worktree)
  [ "$(printf '%s' "$excluded" | jq -r '.fingerprints.source.value')" != \
    "$(printf '%s' "$relevant" | jq -r '.fingerprints.source.value')" ]
}

@test "contract control and mechanism have separate invalidation fingerprints" {
  baseline=$(receipt_identity worktree)

  sed -i 's/timeout_seconds = 30/timeout_seconds = 20/' agent-md.toml
  contract_changed=$(receipt_identity worktree)
  [ "$(printf '%s' "$baseline" | jq -r '.fingerprints.contract.value')" != \
    "$(printf '%s' "$contract_changed" | jq -r '.fingerprints.contract.value')" ]

  sed -i 's/risk = "low"/risk = "high"/' .project-control.toml
  control_changed=$(receipt_identity worktree)
  [ "$(printf '%s' "$contract_changed" | jq -r '.fingerprints.control.value')" != \
    "$(printf '%s' "$control_changed" | jq -r '.fingerprints.control.value')" ]

  printf '\n# mechanism proposal\n' >> .claude/hooks/stop-verify.sh
  mechanism_changed=$(receipt_identity worktree)
  [ "$(printf '%s' "$control_changed" | jq -r '.fingerprints.mechanism.value')" != \
    "$(printf '%s' "$mechanism_changed" | jq -r '.fingerprints.mechanism.value')" ]
}

@test "worktree and staged identities remain distinct scopes" {
  printf '#!/bin/sh\nprintf unstaged\\n\n' > src/app.sh
  worktree=$(receipt_identity worktree)
  staged=$(receipt_identity staged)

  printf '%s' "$worktree" | jq -e '.scope == "worktree"' >/dev/null
  printf '%s' "$staged" | jq -e '.scope == "staged"' >/dev/null
  [ "$(printf '%s' "$worktree" | jq -r '.fingerprints.source.value')" != \
    "$(printf '%s' "$staged" | jq -r '.fingerprints.source.value')" ]
}

@test "receipt validator exposes all five protocol states" {
  identity=$(receipt_identity worktree)
  receipt=$(make_pass_receipt "$identity")
  validation=$(provider_validation_fixture "$receipt" true)

  [ "$(receipt_state '' "$identity" '' | jq -r '.state')" = absent ]
  [ "$(receipt_state '{}' "$identity" '{}' | jq -r '.state')" = invalid ]
  [ "$(receipt_state "$receipt" "$identity" '' | jq -r '.state')" = invalid ]
  [ "$(receipt_state "$receipt" "$identity" "$validation" | jq -r '.state')" = authentic-current ]

  printf changed > src/app.sh
  changed_identity=$(receipt_identity worktree)
  [ "$(receipt_state "$receipt" "$changed_identity" "$validation" | jq -r '.state')" = stale ]

  empty_receipt=$(printf '%s' "$receipt" | jq -c '.checks = []')
  empty_validation=$(provider_validation_fixture "$empty_receipt" true)
  [ "$(receipt_state "$empty_receipt" "$identity" "$empty_validation" | jq -r '.state')" = insufficient-coverage ]
}

@test "payload tampering is invalid even when state fingerprints still match" {
  identity=$(receipt_identity worktree)
  receipt=$(make_pass_receipt "$identity")
  validation=$(provider_validation_fixture "$receipt" true)
  tampered=$(printf '%s' "$receipt" | jq -c '.checks[0].exit_code = 7')

  result=$(receipt_state "$tampered" "$identity" "$validation")
  printf '%s' "$result" | jq -e '
    .state == "invalid" and (.reason | contains("does not authenticate"))
  ' >/dev/null
}

@test "latest authenticated failure supersedes an earlier pass for the same identity" {
  identity=$(receipt_identity worktree)
  old_pass=$(make_pass_receipt "$identity" 1)
  old_validation=$(provider_validation_fixture "$old_pass" false)
  latest_failure=$(make_failed_receipt "$identity" 2)
  failure_validation=$(provider_validation_fixture "$latest_failure" true)

  [ "$(receipt_state "$old_pass" "$identity" "$old_validation" | jq -r '.state')" = stale ]
  [ "$(receipt_state "$latest_failure" "$identity" "$failure_validation" | jq -r '.state')" = insufficient-coverage ]
}

@test "ordinary authentic-current receipt does not claim external Risk authority" {
  sed -i 's/risk = "low"/risk = "high"/' .project-control.toml
  identity=$(receipt_identity worktree)
  receipt=$(make_pass_receipt "$identity")
  validation=$(provider_validation_fixture "$receipt" true)
  result=$(receipt_state "$receipt" "$identity" "$validation")

  printf '%s' "$result" | jq -e '
    .state == "authentic-current" and .coverage.external == ["independent"]
  ' >/dev/null
}

@test "Stop ignores executor-written receipt and keeps full verification fallback" {
  mkdir -p .agent/verification
  printf '{"schema":1,"status":"pass"}\n' > .agent/verification/worktree.json
  cat > agent-md.toml <<'EOF'
[verify]
test = "touch full-verification-ran; exit 1"

[verify.policy]
required = ["test"]
EOF

  out=$(run_hook stop-verify.sh '{"stop_hook_active":false}')
  [ -e full-verification-ran ]
  printf '%s' "$out" | jq -e '
    .decision == "block" and (.reason | contains("VERIFY_REQUIRED_FAILED"))
  ' >/dev/null
}
