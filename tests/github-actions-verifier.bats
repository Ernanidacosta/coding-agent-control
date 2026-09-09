#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  mkdir -p examples/github-actions .github/workflows fake-bin no-gh-bin
  cp "$BATS_TEST_DIRNAME/../examples/github-actions/github-actions-independent.sh" examples/github-actions/
  cp "$BATS_TEST_DIRNAME/../examples/github-actions/github-actions-independent.conf" examples/github-actions/
  printf 'name: ci\non: [push]\n' > .github/workflows/ci.yml
  chmod +x examples/github-actions/github-actions-independent.sh
  ln -s "$(command -v git)" no-gh-bin/git
  ln -s "$(command -v jq)" no-gh-bin/jq
  write_fake_gh
  git add examples .github/workflows/ci.yml
  git commit -q -m anchor
  mkdir -p src
  printf 'baseline\n' > src/example.txt
  git add src/example.txt
  git commit -q -m target
  HEAD_SHA=$(git rev-parse HEAD)
  export HEAD_SHA
  GH_RESPONSE="$BATS_TEST_TMPDIR/github-runs-$$.json"
  GH_CALL_LOG="$BATS_TEST_TMPDIR/github-call-$$.log"
  export GH_RESPONSE GH_CALL_LOG
}

teardown() { teardown_repo; }

write_fake_gh() {
  cat > fake-bin/gh <<'EOF'
#!/bin/bash
case "${1:-} ${2:-}" in
  "auth status")
    [ "${GH_FAKE_AUTH:-missing}" = ok ]
    ;;
  "api --method")
    printf '%s\n' "$*" > "$GH_FAKE_CALL_LOG"
    [ "${GH_FAKE_API_STATUS:-0}" -eq 0 ] || exit "$GH_FAKE_API_STATUS"
    cat "$GH_FAKE_RESPONSE"
    ;;
  *) exit 2 ;;
esac
EOF
  chmod +x fake-bin/gh
}

write_single_run() {
  local sha="$1" status_value="$2" conclusion="$3" id="${4:-100}"
  jq -cn --arg sha "$sha" --arg status "$status_value" \
    --arg conclusion "$conclusion" --argjson id "$id" '
      {workflow_runs:[{
        id:$id,
        created_at:"2026-09-08T12:00:00Z",
        run_attempt:1,
        head_sha:$sha,
        status:$status,
        conclusion:(if $conclusion == "null" then null else $conclusion end),
        path:".github/workflows/ci.yml@main",
        html_url:("https://github.example/actions/runs/" + ($id | tostring))
      }]}
    ' > "$GH_RESPONSE"
}

run_reference() {
  local verifier="${1:-examples/github-actions/github-actions-independent.sh}"
  run env \
    PATH="$REPO_DIR/fake-bin:/usr/bin:/bin" \
    GH_FAKE_AUTH="${GH_FAKE_AUTH:-ok}" \
    GH_FAKE_API_STATUS="${GH_FAKE_API_STATUS:-0}" \
    GH_FAKE_RESPONSE="$GH_RESPONSE" \
    GH_FAKE_CALL_LOG="$GH_CALL_LOG" \
    "$verifier"
}

@test "verifier committed in the baseline can attest a later exact HEAD success" {
  write_single_run "$HEAD_SHA" completed success

  run_reference
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg sha "$HEAD_SHA" '
    . == {
      status:"pass",
      kind:"independent",
      origin:"ci",
      target:{commit:$sha},
      reference:"https://github.example/actions/runs/100"
    }
  ' >/dev/null
  [ "${#HEAD_SHA}" -eq 40 ]
  grep -Fq "repos/Ernanidacosta/coding-agent-control/actions/workflows/ci.yml/runs" "$GH_CALL_LOG"
  grep -Fq "head_sha=$HEAD_SHA" "$GH_CALL_LOG"
}

@test "failed workflow does not attest" {
  write_single_run "$HEAD_SHA" completed failure
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "run for another SHA does not attest" {
  write_single_run 0000000000000000000000000000000000000000 completed success
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "queued workflow remains pending and does not attest" {
  write_single_run "$HEAD_SHA" queued null
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "cancelled workflow does not attest" {
  write_single_run "$HEAD_SHA" completed cancelled
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "missing workflow run does not attest" {
  printf '{"workflow_runs":[]}\n' > "$GH_RESPONSE"
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "missing authentication fails without exposing a token" {
  write_single_run "$HEAD_SHA" completed success
  GH_FAKE_AUTH=missing GH_TOKEN=do-not-print run_reference
  [ "$status" -ne 0 ]
  echo "$output" | grep -qi 'authentication'
  ! echo "$output" | grep -q 'do-not-print'
}

@test "missing gh capability fails clearly" {
  write_single_run "$HEAD_SHA" completed success
  run env PATH="$REPO_DIR/no-gh-bin" /bin/bash examples/github-actions/github-actions-independent.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'gh CLI is required'
}

@test "invalid GitHub API JSON does not attest" {
  printf 'not-json\n' > "$GH_RESPONSE"
  run_reference
  [ "$status" -ne 0 ]
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "newest run deterministically wins over an older success" {
  jq -cn --arg sha "$HEAD_SHA" '{workflow_runs:[
    {id:100,created_at:"2026-09-08T10:00:00Z",run_attempt:1,head_sha:$sha,status:"completed",conclusion:"success",path:".github/workflows/ci.yml@main",html_url:"https://github.example/actions/runs/100"},
    {id:101,created_at:"2026-09-08T11:00:00Z",run_attempt:1,head_sha:$sha,status:"completed",conclusion:"failure",path:".github/workflows/ci.yml@main",html_url:"https://github.example/actions/runs/101"}
  ]}' > "$GH_RESPONSE"

  run_reference
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'run 101'
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "newest successful run supplies the deterministic reference" {
  jq -cn --arg sha "$HEAD_SHA" '{workflow_runs:[
    {id:100,created_at:"2026-09-08T10:00:00Z",run_attempt:1,head_sha:$sha,status:"completed",conclusion:"failure",path:".github/workflows/ci.yml@main",html_url:"https://github.example/actions/runs/100"},
    {id:101,created_at:"2026-09-08T11:00:00Z",run_attempt:2,head_sha:$sha,status:"completed",conclusion:"success",path:".github/workflows/ci.yml@main",html_url:"https://github.example/actions/runs/101"}
  ]}' > "$GH_RESPONSE"

  run_reference
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.reference == "https://github.example/actions/runs/101"' >/dev/null
}

@test "commit that modifies target workflow cannot attest itself" {
  printf 'name: weakened-ci\non: [push]\n' > .github/workflows/ci.yml
  git add .github/workflows/ci.yml
  git commit -q -m change-workflow
  HEAD_SHA=$(git rev-parse HEAD)
  write_single_run "$HEAD_SHA" completed success

  run_reference
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'cannot bootstrap trust'
  ! echo "$output" | grep -q '"status":"pass"'
}

@test "green CI cannot let a commit bootstrap the verifier it introduces" {
  mkdir -p examples/bootstrap-verifier
  cp "$BATS_TEST_DIRNAME/../examples/github-actions/github-actions-independent.sh" examples/bootstrap-verifier/
  cp "$BATS_TEST_DIRNAME/../examples/github-actions/github-actions-independent.conf" examples/bootstrap-verifier/
  chmod +x examples/bootstrap-verifier/github-actions-independent.sh
  git add examples/bootstrap-verifier
  git commit -q -m introduce-verifier
  HEAD_SHA=$(git rev-parse HEAD)
  write_single_run "$HEAD_SHA" completed success

  run_reference examples/bootstrap-verifier/github-actions-independent.sh
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'cannot bootstrap trust'
}

@test "modified verifier remains rejected by generic trust logic" {
  cat > agent-md.toml <<'EOF'
[verify]
independent = "./examples/github-actions/github-actions-independent.sh"

[verify.attestation]
independent_files = [
  "examples/github-actions/github-actions-independent.conf",
  ".github/workflows/ci.yml",
]
independent_capabilities = ["gh"]
EOF
  git add agent-md.toml
  git commit -q -m configure-verifier
  printf '\nexit 0\n' >> examples/github-actions/github-actions-independent.sh

  run bash -c '. .claude/hooks/_lib.sh; attestation_trust_anchor_json agent-md.toml independent'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible == false and .reason == "modified"' >/dev/null
}

@test "reviewed bootstrap baseline becomes eligible for a later commit" {
  cat > agent-md.toml <<'EOF'
[verify]
independent = "./examples/github-actions/github-actions-independent.sh"

[verify.attestation]
independent_files = [
  "examples/github-actions/github-actions-independent.conf",
  ".github/workflows/ci.yml",
]
independent_capabilities = ["gh"]
EOF
  git add agent-md.toml
  git commit -q -m configure-reviewed-anchor
  printf 'future\n' >> src/example.txt
  git add src/example.txt
  git commit -q -m future-change
  HEAD_SHA=$(git rev-parse HEAD)
  write_single_run "$HEAD_SHA" completed success

  run bash -c '. .claude/hooks/_lib.sh; attestation_trust_anchor_json agent-md.toml independent'
  [ "$status" -eq 0 ]
  echo "$output" | jq -e '.eligible and .location == "repo-local" and .integrity == "clean-vs-head"' >/dev/null

  run_reference
  [ "$status" -eq 0 ]
  echo "$output" | jq -e --arg sha "$HEAD_SHA" \
    '.status == "pass" and .kind == "independent" and .target.commit == $sha' >/dev/null
}

@test "provider configuration example is valid TOML" {
  run python3 -c 'import sys, tomllib; tomllib.load(open(sys.argv[1], "rb"))' \
    "$BATS_TEST_DIRNAME/../examples/github-actions/agent-md.toml.example"
  [ "$status" -eq 0 ]
}
