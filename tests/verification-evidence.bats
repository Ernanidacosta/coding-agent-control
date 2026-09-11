#!/usr/bin/env bats
#
# Verification evidence excerpts.
#
# A failing check's excerpt has to show why it failed. Head-of-output is the
# wrong answer for a long run: the beginning is the part that passed, which is
# how a real failure stayed invisible behind a truncation notice.
#
# These cases use synthetic fixtures and call the selector directly, so they
# add no hook or git process cost to the suite.

setup() {
  LIB="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"
  FIXTURE_DIR="$(mktemp -d)"
  FIXTURE="$FIXTURE_DIR/output.txt"
}

teardown() { rm -rf "$FIXTURE_DIR"; }

evidence() {
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  bash -c '. "$1"; verification_evidence "$2" "$3"' _ "$LIB" "$FIXTURE" "$1"
}

max_lines() {
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  bash -c '. "$1"; verification_evidence_max_lines' _ "$LIB"
}

# Content lines are everything the excerpt kept. Gap markers are bookkeeping
# and are deliberately outside the budget.
content_line_count() { grep -cv '^\.\.\. (' <<< "$1"; }

# $2 labels the run so a fixture can tell its head apart from its tail.
passing_log() {
  local count="$1" label="${2:-some}" i
  for ((i = 1; i <= count; i++)); do printf 'ok %d %s passing description\n' "$i" "$label"; done
}

# --- short output ---------------------------------------------------------

@test "short failing output is preserved whole" {
  printf 'first line\nsecond line\nnot ok 1 broke\n' > "$FIXTURE"
  out=$(evidence 1)
  [ "$out" = "$(printf 'first line\nsecond line\nnot ok 1 broke')" ]
}

@test "failing output without a trailing newline is preserved" {
  printf 'evidence' > "$FIXTURE"
  [ "$(evidence 1)" = "evidence" ]
}

@test "empty output yields an empty excerpt" {
  : > "$FIXTURE"
  [ -z "$(evidence 1)" ]
}

@test "output exactly at the budget is not excerpted" {
  passing_log "$(max_lines)" > "$FIXTURE"
  out=$(evidence 1)
  [ "$(content_line_count "$out")" -eq "$(max_lines)" ]
  ! grep -q '^\.\.\. (' <<< "$out"
}

# --- long output, failure far past the head -------------------------------

@test "failure near the end of a long run is visible" {
  {
    echo "1..312"
    passing_log 286
    echo "not ok 287 the test that actually failed"
    echo "# (in test file tests/example.bats, line 88)"
    passing_log 25 trailing
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'not ok 287 the test that actually failed' <<< "$out"
  grep -q 'in test file tests/example.bats' <<< "$out"
  # The head of a long passing run must not be what we show. One line of
  # context immediately above the failure is kept on purpose, so the check
  # is against the head itself, not against every passing line.
  ! grep -q '^1\.\.312$' <<< "$out"
  ! grep -q '^ok 1 some passing description$' <<< "$out"
  ! grep -q '^ok 100 some passing description$' <<< "$out"
}

@test "the diagnostic block that follows a failure record is included" {
  # What explains a failure is what comes after it. An excerpt that stops two
  # lines past the record names the failing test and hides its cause.
  {
    passing_log 100
    echo "not ok 101 the failing case"
    echo "# (in test file tests/example.bats, line 100)"
    local i
    for ((i = 1; i <= 20; i++)); do printf '# diagnostic line %d\n' "$i"; done
    passing_log 40 trailing
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'not ok 101 the failing case' <<< "$out"
  grep -q '# diagnostic line 1$' <<< "$out"
  grep -q '# diagnostic line 10$' <<< "$out"
  grep -q '# diagnostic line 15$' <<< "$out"
}

@test "every failure record is named before any of them gets context" {
  local i
  : > "$FIXTURE"
  passing_log 50 >> "$FIXTURE"
  for ((i = 1; i <= 12; i++)); do
    printf 'not ok %d failure number %d\n' "$i" "$i" >> "$FIXTURE"
    printf 'filler after failure %d\n' "$i" >> "$FIXTURE"
  done
  passing_log 50 trailing >> "$FIXTURE"
  out=$(evidence 1)
  for ((i = 1; i <= 12; i++)); do
    grep -q "not ok $i failure number $i\$" <<< "$out"
  done
  [ "$(content_line_count "$out")" -le "$(max_lines)" ]
}

@test "the end of the output is always kept" {
  {
    passing_log 300
    echo "final summary line"
  } > "$FIXTURE"
  grep -q 'final summary line' <<< "$(evidence 1)"
}

@test "multiple failures are each represented" {
  {
    passing_log 40
    echo "not ok 41 first failure"
    passing_log 40
    echo "not ok 82 second failure"
    passing_log 40
    echo "not ok 123 third failure"
    passing_log 40
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'not ok 41 first failure' <<< "$out"
  grep -q 'not ok 82 second failure' <<< "$out"
  grep -q 'not ok 123 third failure' <<< "$out"
}

@test "long output with no recognizable marker falls back to the end" {
  {
    passing_log 200
    echo "quiet last line"
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'quiet last line' <<< "$out"
  ! grep -q '^ok 1 some passing description$' <<< "$out"
}

@test "generic error words are used only when no explicit record exists" {
  # 'FAIL' appears inside a passing description here. It must not anchor the
  # excerpt while a real failure record exists.
  {
    passing_log 100
    echo "ok 101 exit zero remains authoritative even when output says FAIL"
    passing_log 100
    echo "not ok 202 the real failure"
    passing_log 50
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'not ok 202 the real failure' <<< "$out"
  ! grep -q 'exit zero remains authoritative' <<< "$out"
}

# --- runner shapes other than TAP -----------------------------------------

@test "python traceback anchors the excerpt" {
  {
    passing_log 60
    echo "Traceback (most recent call last):"
    echo '  File "app.py", line 12, in main'
    echo "ValueError: bad input"
    passing_log 10
  } > "$FIXTURE"
  out=$(evidence 1)
  grep -q 'Traceback (most recent call last)' <<< "$out"
  grep -q 'ValueError: bad input' <<< "$out"
}

@test "go panic anchors the excerpt" {
  { passing_log 60; echo "panic: runtime error: index out of range"; passing_log 10; } > "$FIXTURE"
  grep -q 'panic: runtime error' <<< "$(evidence 1)"
}

@test "compiler style error lines anchor the excerpt" {
  { passing_log 60; echo "src/app.ts(10,5): error TS2322: Type mismatch."; passing_log 10; } > "$FIXTURE"
  grep -q 'error TS2322' <<< "$(evidence 1)"
}

@test "pytest FAILED summary anchors the excerpt" {
  { passing_log 60; echo "FAILED tests/test_app.py::test_login - AssertionError"; passing_log 10; } > "$FIXTURE"
  grep -q 'FAILED tests/test_app.py' <<< "$(evidence 1)"
}

# --- budget ---------------------------------------------------------------

@test "the evidence budget is respected however many failures exist" {
  local i
  : > "$FIXTURE"
  for ((i = 1; i <= 400; i++)); do printf 'not ok %d failure number %d\n' "$i" "$i" >> "$FIXTURE"; done
  out=$(evidence 1)
  [ "$(content_line_count "$out")" -le "$(max_lines)" ]
}

@test "the evidence budget is respected for unmarked output" {
  passing_log 400 > "$FIXTURE"
  [ "$(content_line_count "$(evidence 1)")" -le "$(max_lines)" ]
}

# --- passing checks are unchanged ----------------------------------------

@test "a passing check still shows the first lines" {
  { echo "starting build"; passing_log 400; } > "$FIXTURE"
  out=$(evidence 0)
  [ "$(printf '%s\n' "$out" | head -1)" = "starting build" ]
  [ "$(printf '%s\n' "$out" | wc -l)" -eq "$(max_lines)" ]
  ! grep -q '^\.\.\. (' <<< "$out"
}

@test "a short passing output is unchanged" {
  printf 'all good\n' > "$FIXTURE"
  [ "$(evidence 0)" = "all good" ]
}
