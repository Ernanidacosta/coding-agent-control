#!/usr/bin/env bats
#
# A receipt has to carry fingerprints a gate can recompute. Source parity was
# settled earlier; these cover the other three the protocol requires. For every
# repository state the authority's vendored implementation and the core must
# agree exactly, or both must refuse.

setup() {
  CORE="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  VENDORED="$BATS_TEST_DIRNAME/../examples/local-issuer/phase-a-source.sh"
  export CORE VENDORED
  REPO="$(mktemp -d)"
  export REPO
  cd "$REPO"
  git init -q
  git config user.email fixture@example.invalid
  git config user.name fixture
  git config core.excludesFile /dev/null
  mkdir -p .claude/hooks .agent-md/bin memory
  printf '#!/bin/bash\n' > .claude/hooks/_lib.sh
  printf '#!/bin/bash\n' > .claude/hooks/stop-verify.sh
  printf '#!/bin/bash\n' > .agent-md/bin/verify.sh
}

teardown() { cd "$BATS_TEST_DIRNAME"; rm -rf "$REPO"; }

core_fp() {
  bash -c '. "$CORE"; '"$1"' worktree | jq -cS . | sha256sum | cut -d" " -f1'
}
auth_fp() {
  bash -c '. "$VENDORED"; authority_pa_'"$1"' worktree | jq -cS . | sha256sum | cut -d" " -f1'
}
core_json() { bash -c '. "$CORE"; '"$1"' worktree'; }

# Both sides must agree on whether a state is usable, and for a usable state
# they must produce the same fingerprint.
#
# For an unusable state the agreement is the refusal itself, not the digest: the
# core's invalid-contract diagnostic embeds the mktemp path of the snapshot it
# read, so two runs of the core alone already disagree. That is harmless here
# because an invalid contract can never yield a candidate pass, but it means no
# stable fingerprint exists for one, on either side.
assert_parity() {
  local fn="$1" cv av c a
  cv=$(bash -c '. "$CORE"; '"$fn"' worktree | jq -r ".valid"')
  av=$(bash -c '. "$VENDORED"; authority_pa_'"$fn"' worktree | jq -r ".valid"')
  if [ "$cv" != "$av" ]; then
    printf '%s: core valid=%s but authority valid=%s\n' "$fn" "$cv" "$av" >&2
    return 1
  fi
  [ "$cv" = true ] || return 0
  c=$(core_fp "$fn"); a=$(auth_fp "$fn")
  if [ "$c" != "$a" ]; then
    printf '%s differs\n--- core ---\n%s\n--- authority ---\n%s\n' "$fn" \
      "$(bash -c '. "$CORE"; '"$fn"' worktree | jq -S .')" \
      "$(bash -c '. "$VENDORED"; authority_pa_'"$fn"' worktree | jq -S .')" >&2
    return 1
  fi
}

contract_parity() { assert_parity effective_verification_contract_json; }
control_parity() { assert_parity effective_control_requirements_json; }
mechanism_parity() { assert_parity verification_receipt_mechanism_manifest_json; }

write_contract() { printf '%s\n' "$1" > agent-md.toml; }
commit_all() { git add -A >/dev/null 2>&1; git commit -qm "$1" >/dev/null 2>&1; }

BASIC='[verify]
lint = "true"
test = "true"

[verify.policy]
required = ["lint", "test"]'

# --- contract ---------------------------------------------------------------

@test "contract 1 baseline only" {
  write_contract "$BASIC"; commit_all base
  rm agent-md.toml
  contract_parity
}

@test "contract 2 proposal only" {
  commit_all empty
  write_contract "$BASIC"
  contract_parity
}

@test "contract 3 identical baseline and proposal" {
  write_contract "$BASIC"; commit_all base
  contract_parity
}

@test "contract 4 a stricter required check in the proposal" {
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = "true"
test = "true"
smoke = "true"

[verify.policy]
required = ["lint", "test", "smoke"]'
  contract_parity
}

@test "contract 5 a required check removed from the proposal" {
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = "true"

[verify.policy]
required = ["lint"]'
  contract_parity
}

@test "contract 6 a changed command" {
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = "echo other"
test = "true"

[verify.policy]
required = ["lint", "test"]'
  contract_parity
}

@test "contract 7 timeout_seconds" {
  write_contract "$BASIC"; commit_all base
  write_contract "$BASIC
timeout_seconds = 120"
  contract_parity
}

@test "contract 8 total_timeout_seconds" {
  write_contract "$BASIC
timeout_seconds = 60
total_timeout_seconds = 300"; commit_all base
  contract_parity
}

@test "contract 9 a legacy-derived total" {
  write_contract "$BASIC
timeout_seconds = 45"; commit_all base
  contract_parity
}

@test "contract 10 an invalid proposal" {
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = ""

[verify.policy]
required = ["lint"]'
  contract_parity
  core_json effective_verification_contract_json | jq -e '.valid == false' >/dev/null
}

@test "contract 11 a missing proposal with no baseline" {
  commit_all empty
  contract_parity
}

@test "contract 12 optional checks" {
  write_contract '[verify]
lint = "true"
test = "true"
smoke = "true"

[verify.policy]
required = ["test"]'; commit_all base
  contract_parity
  core_json effective_verification_contract_json | jq -e '
    any(.checks[]; .name == "smoke" and .requirement == "optional")
  ' >/dev/null
}

@test "contract 13 an unknown required check" {
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = "true"

[verify.policy]
required = ["lint", "nonsense"]'
  contract_parity
  core_json effective_verification_contract_json | jq -e '.valid == false' >/dev/null
}

@test "contract 14 a malformed config" {
  write_contract "$BASIC"; commit_all base
  printf 'this is not a contract\n[verify\n' > agent-md.toml
  contract_parity
}

# --- control ----------------------------------------------------------------

write_control() { printf 'schema = 1\nrisk = "%s"\n' "$1" > .project-control.toml; }
write_progress() {
  printf '# Progress\n\n## Current\n\nStatus: %s\nTask: t\n%s\n## Next\n\nNone\n\n## Blockers\n\nNone\n\n## Recently Completed\n\nNone\n' \
    "$1" "${2:-}" > memory/progress.md
}

@test "control 1 medium baseline and medium proposal" {
  write_contract "$BASIC"; write_control medium; write_progress verifying; commit_all base
  control_parity
}

@test "control 2 medium raised to high" {
  write_contract "$BASIC"; write_control medium; write_progress verifying; commit_all base
  write_control high
  control_parity
}

@test "control 3 high lowered to low stays pending" {
  write_contract "$BASIC"; write_control high; write_progress verifying; commit_all base
  write_control low
  control_parity
  core_json effective_control_requirements_json | jq -e '
    .effective.risk == "high" and .risk_downgrade == "pending"
  ' >/dev/null
}

@test "control 4 low raised to high" {
  write_contract "$BASIC"; write_control low; write_progress verifying; commit_all base
  write_control high
  control_parity
  core_json effective_control_requirements_json | jq -e '.effective.risk == "high"' >/dev/null
}

@test "control 5 a missing control record" {
  write_contract "$BASIC"; write_progress verifying; commit_all base
  control_parity
}

@test "control 6 an invalid risk value" {
  write_contract "$BASIC"; write_control medium; write_progress verifying; commit_all base
  printf 'schema = 1\nrisk = "enormous"\n' > .project-control.toml
  control_parity
  core_json effective_control_requirements_json | jq -e '.valid == false' >/dev/null
}

@test "control 7 a local Risk proposal only tightens" {
  write_contract "$BASIC"; write_control medium; write_progress verifying; commit_all base
  write_progress verifying 'Risk: high'
  control_parity
  core_json effective_control_requirements_json | jq -e '.effective.risk == "high"' >/dev/null
}

@test "control 8 a local Risk proposal cannot loosen" {
  write_contract "$BASIC"; write_control high; write_progress verifying; commit_all base
  write_progress verifying 'Risk: low'
  control_parity
  core_json effective_control_requirements_json | jq -e '.effective.risk == "high"' >/dev/null
}

@test "control 9 no proposal at all" {
  write_contract "$BASIC"; write_control medium; write_progress verifying; commit_all base
  rm .project-control.toml
  control_parity
}

@test "control 10 a legacy tracked Risk baseline" {
  write_contract "$BASIC"; write_progress verifying 'Risk: medium'; commit_all base
  control_parity
  core_json effective_control_requirements_json | jq -e '.source == "legacy-progress"' >/dev/null
}

# --- mechanism --------------------------------------------------------------

@test "mechanism 1 clean" {
  write_contract "$BASIC"; commit_all base
  mechanism_parity
}

@test "mechanism 2 a modified worktree mechanism file" {
  write_contract "$BASIC"; commit_all base
  printf '#!/bin/bash\n# changed\n' > .claude/hooks/_lib.sh
  mechanism_parity
}

@test "mechanism 3 a staged modification" {
  write_contract "$BASIC"; commit_all base
  printf '#!/bin/bash\n# staged\n' > .claude/hooks/stop-verify.sh
  git add .claude/hooks/stop-verify.sh
  mechanism_parity
}

@test "mechanism 4 index and worktree diverge on the same file" {
  write_contract "$BASIC"; commit_all base
  printf '#!/bin/bash\n# staged\n' > .agent-md/bin/verify.sh
  git add .agent-md/bin/verify.sh
  printf '#!/bin/bash\n# unstaged\n' > .agent-md/bin/verify.sh
  mechanism_parity
  core_json verification_receipt_mechanism_manifest_json | jq -e '
    .files[] | select(.path == ".agent-md/bin/verify.sh")
    | .index.digest != .worktree.digest
  ' >/dev/null
}

@test "mechanism 5 a deleted mechanism file fails closed on both sides" {
  write_contract "$BASIC"; commit_all base
  rm .claude/hooks/_lib.sh
  mechanism_parity
  core_json verification_receipt_mechanism_manifest_json | jq -e '.valid == false' >/dev/null
}

@test "mechanism 6 an executable mode change" {
  write_contract "$BASIC"; commit_all base
  chmod +x .claude/hooks/_lib.sh
  mechanism_parity
  git add .claude/hooks/_lib.sh
  mechanism_parity
}

@test "mechanism 7 a symlinked mechanism file" {
  write_contract "$BASIC"; commit_all base
  rm .claude/hooks/stop-verify.sh
  ln -s _lib.sh .claude/hooks/stop-verify.sh
  mechanism_parity
}

@test "mechanism 8 a file absent from the start fails closed" {
  rm .agent-md/bin/verify.sh
  write_contract "$BASIC"; commit_all base
  mechanism_parity
  core_json verification_receipt_mechanism_manifest_json | jq -e '.valid == false' >/dev/null
}

@test "mechanism 9 an unrelated file does not enter the mechanism identity" {
  write_contract "$BASIC"; commit_all base
  local before; before=$(core_fp verification_receipt_mechanism_manifest_json)
  printf '#!/bin/bash\n' > .claude/hooks/extra.sh
  git add -A >/dev/null 2>&1
  mechanism_parity
  [ "$(core_fp verification_receipt_mechanism_manifest_json)" = "$before" ]
}

@test "contract 15 an invalid contract has no stable fingerprint, on either side" {
  # Recorded rather than worked around. The core embeds the temp path of the
  # config snapshot it read into the diagnostic, so the same invalid state
  # fingerprints differently on consecutive runs of the core alone. A receipt
  # can never carry one, because an invalid contract cannot reach a candidate
  # pass; this pins the fact so a later slice does not assume otherwise.
  write_contract "$BASIC"; commit_all base
  write_contract '[verify]
lint = ""

[verify.policy]
required = ["lint"]'
  local first second
  first=$(core_fp effective_verification_contract_json)
  second=$(core_fp effective_verification_contract_json)
  [ "$first" != "$second" ]
  core_json effective_verification_contract_json | jq -e '
    .valid == false and (.error.message | test("^Invalid /"))
  ' >/dev/null
  contract_parity
}
