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

# The prototype receipt validator that used to live in the core is gone, and
# these cases went with it. What they were really asserting is now asserted
# against the artefact the authority actually issues, in
# tests/authority-receipt-validation.bats:
#
#   five protocol states        -> the nine validator statuses, cases 1-2, 26-34
#   payload tampering invalid   -> cases 8, 9, 13, 14
#   newer failure supersedes    -> case 26
#   no external Risk authority  -> case 43
#
# What remains here is the reconciliation itself: there must be exactly one
# receipt protocol, and no second acceptance path.

@test "the core carries no second receipt validator" {
  # A prototype that nothing called was still a second protocol: it described a
  # different artefact and would have accepted receipts no issuer can produce.
  local f
  for f in verification_receipt_state_json verification_receipt_payload_json \
           verification_receipt_payload_fingerprint_json; do
    run grep -n "^$f() {" "$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
    [ "$status" -ne 0 ]
  done
}

@test "the core offers no path that accepts a receipt" {
  # Nothing in the core decides that a receipt may be reused. That decision has
  # exactly one implementation, and it is not here.
  run bash -c "grep -vE '^[[:space:]]*#' '$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh' \
    | grep -nE 'authentic-current|insufficient-coverage|pkeyutl|reusable_pass'"
  [ "$status" -ne 0 ]
}

@test "the semantics the prototype carried are still here and still shared" {
  # Removing the prototype must not have removed the rules. The effective
  # requirements, the four fingerprints and the external-authority rule stay in
  # the core, and the authority vendors them verbatim.
  run bash -c '. .claude/hooks/_lib.sh; verification_receipt_identity_json worktree | jq -e "
    .valid == true and
    (.fingerprints | keys | sort) == [\"contract\",\"control\",\"mechanism\",\"source\"] and
    (.requirements | has(\"required\") and has(\"any_of\") and has(\"external\"))"'
  [ "$status" -eq 0 ]

  # Byte-for-byte the same rule in the vendored copy the validator uses.
  local core vendored
  # Anchored to the repository: these cases run inside a temporary fixture repo.
  local repo="$BATS_TEST_DIRNAME/.."
  core=$(sed -n '/^verification_receipt_requirements_json() {/,/^}/p' \
    "$repo/.claude/hooks/_lib.sh" | tail -n +2)
  vendored=$(sed -n '/^authority_pa_verification_receipt_requirements_json() {/,/^}/p' \
    "$repo/examples/local-issuer/phase-a-source.sh" | tail -n +2)
  [ -n "$core" ]
  [ "$core" = "$vendored" ]
}

@test "a receipt never satisfies independent verification or human approval" {
  # The rule the prototype encoded, asserted where it now lives.
  run bash -c '. .claude/hooks/_lib.sh
    contract=$(effective_verification_contract_json worktree)
    control=$(effective_control_requirements_json worktree)
    verification_receipt_requirements_json "$contract" "$control" \
      | jq -e "(.required | map(.name) | index(\"independent\")) == null
               and (.required | map(.name) | index(\"approval\")) == null"'
  [ "$status" -eq 0 ]
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
