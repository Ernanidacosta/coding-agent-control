#!/usr/bin/env bats

LIB="$BATS_TEST_DIRNAME/../.claude/hooks/_lib.sh"

resolve_language() {
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  env "$@" bash -c '. "$1"; diagnostic_language' _ "$LIB" 2>/dev/null
}

underrating_result() {
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  bash -c '. "$1"; risk_result_json warn warning RISK_POSSIBLY_UNDERRATED \
    "Declared Risk '\''medium'\'' may be inconsistent with observed sensitive paths or operations." \
    "Review the declared Risk; signals are advisory and never rewrite it automatically." \
    medium done migration "$2" risk' _ "$LIB" "$1"
}

runtime_result() {
  local status="$1" severity="$2"
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  bash -c '. "$1"; risk_result_json "$2" "$3" RISK_RUNTIME_EVIDENCE_REQUIRED \
    "Risk '\''medium'\'' runtime evidence diagnostic." \
    "Review runtime applicability." medium done migration "" runtime-or-smoke' \
    _ "$LIB" "$status" "$severity"
}

render_result() {
  local language="$1" result="$2"
  # shellcheck disable=SC2016 # Positional parameters belong to the child shell.
  CODING_AGENT_CONTROL_LANG="$language" bash -c \
    '. "$1"; policy_human_message "$2"' _ "$LIB" "$result"
}

@test "explicit pt-BR locale resolves to pt-BR" {
  run resolve_language CODING_AGENT_CONTROL_LANG=pt-BR LC_ALL=C LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "Portuguese locale variants resolve to pt-BR" {
  for locale in pt pt_BR.UTF-8 pt_BR.utf8; do
    run resolve_language CODING_AGENT_CONTROL_LANG="$locale"
    [ "$status" -eq 0 ]
    [ "$output" = pt-BR ]
  done
}

@test "English locale variants resolve to en" {
  for locale in en en_US.UTF-8 en_US.utf8 en-US; do
    run resolve_language CODING_AGENT_CONTROL_LANG="$locale"
    [ "$status" -eq 0 ]
    [ "$output" = en ]
  done
}

@test "C POSIX empty and unsupported locales fall back to en" {
  for locale in C POSIX '' fr_FR.UTF-8; do
    run resolve_language CODING_AGENT_CONTROL_LANG="$locale" LC_MESSAGES= LANG=
    [ "$status" -eq 0 ]
    [ "$output" = en ]
  done
}

@test "explicit override wins over LC_MESSAGES and LANG" {
  run resolve_language CODING_AGENT_CONTROL_LANG=pt LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "explicit override wins over LC_ALL" {
  run resolve_language CODING_AGENT_CONTROL_LANG=pt-BR LC_ALL=C LANG=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "LC_ALL wins over LC_MESSAGES and LANG" {
  run resolve_language CODING_AGENT_CONTROL_LANG= LC_ALL=pt_BR.UTF-8 LC_MESSAGES=en_US.UTF-8 LANG=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "C and POSIX via LC_ALL force English" {
  for locale in C POSIX; do
    run resolve_language CODING_AGENT_CONTROL_LANG= LC_ALL="$locale" LC_MESSAGES=pt_BR.UTF-8 LANG=pt_BR.UTF-8
    [ "$status" -eq 0 ]
    [ "$output" = en ]
  done
}

@test "LC_MESSAGES wins over LANG when no explicit override exists" {
  run resolve_language CODING_AGENT_CONTROL_LANG= LC_ALL= LC_MESSAGES=pt_BR.UTF-8 LANG=en_US.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "LANG is the fallback when stronger locale variables are empty" {
  run resolve_language CODING_AGENT_CONTROL_LANG= LC_ALL= LC_MESSAGES= LANG=pt_BR.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = pt-BR ]
}

@test "unsupported LC_ALL remains an English fallback" {
  run resolve_language CODING_AGENT_CONTROL_LANG= LC_ALL=fr_FR.UTF-8 LC_MESSAGES=pt_BR.UTF-8 LANG=pt_BR.UTF-8
  [ "$status" -eq 0 ]
  [ "$output" = en ]
}

@test "rendering does not mutate the structured underrating result" {
  paths=$'migrations/001.sql\nsrc/a.py\nsrc/b.py\nsrc/c.py'
  result=$(underrating_result "$paths")
  before="$result"

  render_result pt-BR "$result" >/dev/null

  [ "$result" = "$before" ]
  echo "$result" | jq -e '
    .status == "warn" and .severity == "warning" and
    .code == "RISK_POSSIBLY_UNDERRATED" and .risk == "medium" and
    .current_status == "done" and .observed_signals == ["migration"] and
    .missing_requirement == "risk" and
    .message == "Declared Risk '\''medium'\'' may be inconsistent with observed sensitive paths or operations." and
    .suggestion == "Review the declared Risk; signals are advisory and never rewrite it automatically." and
    .paths == ["migrations/001.sql", "src/a.py", "src/b.py", "src/c.py"]
  ' >/dev/null
}

@test "underrating warning is localized without exposing inaccurate missing risk" {
  result=$(underrating_result 'migrations/001.sql')

  en=$(render_result en "$result")
  [[ "$en" == *"[WARNING RISK_POSSIBLY_UNDERRATED]"* ]]
  [[ "$en" == *"migration/schema-sensitive behavior"* ]]
  [[ "$en" == *"Advisory review only"* ]]
  [[ "$en" == *"were not changed automatically"* ]]
  [[ "$en" != *"Missing: risk"* ]]

  pt=$(render_result pt-BR "$result")
  [[ "$pt" == *"[WARNING RISK_POSSIBLY_UNDERRATED]"* ]]
  [[ "$pt" == *"migração/schema"* ]]
  [[ "$pt" == *"Aviso de revisão apenas"* ]]
  [[ "$pt" == *"não foram alterados automaticamente"* ]]
  [[ "$pt" != *"Missing: risk"* ]]
}

@test "human paths are compact while structured paths remain complete" {
  three_paths=$'migrations/001.sql\nsrc/a.py\nsrc/b.py'
  three_result=$(underrating_result "$three_paths")
  three=$(render_result en "$three_result")
  [[ "$three" == *"migrations/001.sql"* ]]
  [[ "$three" == *"src/a.py"* ]]
  [[ "$three" == *"src/b.py"* ]]
  [[ "$three" == *"Related files:"* ]]
  [[ "$three" != *"+1 related files"* ]]

  paths=$'migrations/001.sql\nsrc/a.py\nsrc/b.py\nsrc/c.py\nsrc/d.py'
  result=$(underrating_result "$paths")

  en=$(render_result en "$result")
  [[ "$en" == *"migrations/001.sql"* ]]
  [[ "$en" == *"src/a.py"* ]]
  [[ "$en" == *"src/b.py"* ]]
  [[ "$en" != *"src/c.py"* ]]
  [[ "$en" == *"+2 related files"* ]]

  pt=$(render_result pt-BR "$result")
  [[ "$pt" == *"+2 arquivos relacionados"* ]]
  [ "$(echo "$result" | jq '.paths | length')" -eq 5 ]
  [ "$(echo "$result" | jq -r '.paths[4]')" = src/d.py ]
}

@test "runtime warning remains advisory in English and pt-BR" {
  result=$(runtime_result warn warning)

  en=$(render_result en "$result")
  [[ "$en" == *"[WARNING RISK_RUNTIME_EVIDENCE_REQUIRED]"* ]]
  [[ "$en" == *"completion is not blocked by this warning"* ]]
  [[ "$en" != *"Related files:"* ]]

  pt=$(render_result pt-BR "$result")
  [[ "$pt" == *"[WARNING RISK_RUNTIME_EVIDENCE_REQUIRED]"* ]]
  [[ "$pt" == *"este aviso não bloqueia a conclusão"* ]]
  [[ "$pt" != *"Arquivos relacionados:"* ]]

  echo "$result" | jq -e '
    .status == "warn" and .severity == "warning" and
    .code == "RISK_RUNTIME_EVIDENCE_REQUIRED" and
    .missing_requirement == "runtime-or-smoke"
  ' >/dev/null
}

@test "runtime failure uses blocking wording with the same stable code" {
  warning=$(runtime_result warn warning)
  failure=$(runtime_result fail error)

  en=$(render_result en "$failure")
  [[ "$en" == *"[ERROR RISK_RUNTIME_EVIDENCE_REQUIRED]"* ]]
  [[ "$en" == *"Completion is blocked"* ]]
  [[ "$en" != *"Advisory only"* ]]

  pt=$(render_result pt-BR "$failure")
  [[ "$pt" == *"[ERROR RISK_RUNTIME_EVIDENCE_REQUIRED]"* ]]
  [[ "$pt" == *"A conclusão está bloqueada"* ]]
  [[ "$pt" != *"Aviso apenas"* ]]

  [ "$(echo "$warning" | jq -r '.code')" = "$(echo "$failure" | jq -r '.code')" ]
  [ "$(echo "$warning" | jq -r '.status')" = warn ]
  [ "$(echo "$failure" | jq -r '.status')" = fail ]
}
