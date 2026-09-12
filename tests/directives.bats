#!/usr/bin/env bats

@test "directives define the evidence-first workflow" {
  run grep -q 'Establish reproducible evidence' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'Repeat the same evidence' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives use behavioral objectives instead of a five-file limit" {
  run grep -q 'One behavioral objective per implementation slice' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'roughly five touched files' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -ne 0 ]
}

@test "directives require diff inspection and behavioral verification after edits" {
  run grep -q 'Inspect the resulting diff or affected region' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'Verify the affected behavior' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives define advisory README stewardship" {
  grep -Fxq '## README Stewardship' "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'The README is the durable human entry point to the repository.' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Does the current README still describe the project a new user would actually encounter?' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Prefer visual hierarchy over decoration.' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Editorial quality remains advisory.' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  run grep -Fq 'README.pt-BR' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -ne 0 ]
}

@test "directives distinguish verification evidence classes without substitution" {
  for evidence_class in Static Automated Runtime Smoke Visual Independent; do
    run grep -q "\*\*${evidence_class}\*\*" "$BATS_TEST_DIRNAME/../AGENT.md"
    [ "$status" -eq 0 ]
  done
  run grep -q 'one does not automatically replace another' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives separate blocking enforcement from advisory context at Stop" {
  grep -Fxq '### Blocking Enforcement And Advisory Context At Stop' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'metadata about the cycle, never evidence about the work' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'a blocking result repeats identically on every attempt' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'advisory context is emitted once per finish cycle' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'reads as a first attempt' "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Do not add a retry counter' "$BATS_TEST_DIRNAME/../AGENT.md"
}

@test "directives separate commit execution authority from commit authorship" {
  grep -Fq '**Commit execution authority.**' "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq '**Commit authorship.**' "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Suggesting a commit is not permission to make one.' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'produce a subject and an optional body' "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'not add one when a host, template, or earlier instruction tells you to' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'naming a real person remains correct and expected' \
    "$BATS_TEST_DIRNAME/../AGENT.md"
  grep -Fq 'Never modify' "$BATS_TEST_DIRNAME/../AGENT.md"
}

@test "directives are mirrored into the Claude Code rules file" {
  diff -q "$BATS_TEST_DIRNAME/../AGENT.md" "$BATS_TEST_DIRNAME/../CLAUDE.md"
}

@test "directives keep independent execution advisory" {
  run grep -q 'never invokes another model automatically' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives keep optional capabilities outside operational correctness" {
  run grep -q 'Missing optional capability must not break ordinary work' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'Missing mandatory capability must prevent only the transition' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'Semantic-memory provider (optional)' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'ICM is one supported reference provider' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives define done as a claim accepted only after every applicable guarantee" {
  run grep -q 'Status: done is a completion claim, not proof of completion' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'state integrity, required verification, Risk, attestation, and approval requirements pass' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives define non-numeric Risk as evidence policy, not safety judgment" {
  run grep -q 'Risk answers.*how much evidence' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'There is no numeric score' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  for risk_level in low medium high critical; do
    run grep -q "\`$risk_level\`" "$BATS_TEST_DIRNAME/../AGENT.md"
    [ "$status" -eq 0 ]
  done
}

@test "directives forbid self-approval and Safety bypass through Risk" {
  run grep -q 'agent-authored.*is not evidence' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'bypass a fatal destructive-command' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives define the four-property attestation trust model" {
  for property in origin integrity freshness binding; do
    run grep -qi "${property}" "$BATS_TEST_DIRNAME/../AGENT.md"
    [ "$status" -eq 0 ]
  done
  run grep -q 'different check run by the executor is not independent evidence' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives require exact commit binding and explicit verifier dependencies" {
  run grep -q 'target.commit.*full current HEAD' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'verify.attestation.<kind>_files' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives forbid circular verifier bootstrap and keep providers outside core" {
  run grep -q 'A verifier cannot bootstrap trust in the same untrusted change' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'generic core never installs' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'verify.attestation.<kind>_capabilities' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "directives define an out-of-band Root-of-Trust Bootstrap without bypass" {
  run grep -q 'Root-of-Trust Bootstrap' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'initial root of trust.*human.*outside the executor' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
  run grep -q 'There is no trust bypass' "$BATS_TEST_DIRNAME/../AGENT.md"
  [ "$status" -eq 0 ]
}

@test "shipped enforcement exposes no generic trust bypass flag" {
  run grep -R -n -E -- '--force-trust|--skip-attestation|--auto-baseline|--auto-approve-current-head' \
    "$BATS_TEST_DIRNAME/../.claude" \
    "$BATS_TEST_DIRNAME/../.agent-md/bin" \
    "$BATS_TEST_DIRNAME/../.githooks" \
    "$BATS_TEST_DIRNAME/../install.sh"
  [ "$status" -ne 0 ]
}
