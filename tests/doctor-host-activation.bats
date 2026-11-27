#!/usr/bin/env bats
#
# Installed hooks are not operational hooks. The doctor reports what each
# host lets it inspect: whether the host discovered, approved and enabled the
# coding-agent-control hooks, or that it cannot tell. It never reports
# execution, which only a real session observes.

load helpers

setup() {
  setup_repo
  cp -r "$BATS_TEST_DIRNAME/../.agent-md" "$REPO_DIR/"
  export HOME="$BATS_TEST_TMPDIR/home"
  mkdir -p "$HOME" "$BATS_TEST_TMPDIR/bin"
  export AGENT_MD_CLAUDE_MANAGED_SETTINGS="$BATS_TEST_TMPDIR/managed-settings.json"
  ROOT=$(pwd -P)
  CAC_EVENTS='preToolUse postToolUse subagentStop stop'
}

teardown() { teardown_repo; }

# fake_codex RESULT_JSON — a codex CLI whose app-server answers hooks/list.
fake_codex() {
  printf '%s' "$1" > "$BATS_TEST_TMPDIR/hooks-list.json"
  cat > "$BATS_TEST_TMPDIR/bin/codex" <<SH
#!/bin/bash
[ "\$1" = app-server ] || exit 2
while IFS= read -r line; do
  case "\$line" in
    *'"initialize"'*) printf '%s\n' '{"id":1,"result":{}}' ;;
    *'hooks/list'*) printf '{"id":2,"result":%s}\n' "\$(cat "$BATS_TEST_TMPDIR/hooks-list.json")"; exit 0 ;;
  esac
done
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
}

# listing STATUS ENABLED [EVENTS] — hooks/list data for this project's CAC
# hooks, built from the package's own .codex/hooks.json so the doctor's notion
# of those handlers cannot drift from what the installer writes.
listing() {
  local status="$1" enabled="$2" events="${3-$CAC_EVENTS}"
  jq -c --arg root "$ROOT" --arg status "$status" --argjson enabled "$enabled" --arg events "$events" '
    ($events | split(" ") | map(select(length > 0))) as $want |
    {data:[{cwd:$root, warnings:[], errors:[], hooks:(
      [{key:"/home/u/.codex/hooks.json:pre_tool_use:0:0", eventName:"preToolUse", source:"user",
        sourcePath:"/home/u/.codex/hooks.json", matcher:"Bash", command:"other", enabled:true, trustStatus:"trusted"}] +
      [.hooks | to_entries[] | ((.key[0:1] | ascii_downcase) + .key[1:]) as $event |
        select($want | index($event)) | .value[] | (.matcher // null) as $matcher | .hooks[] |
        {key:($root + "/.codex/hooks.json:" + $event + ":0:0"), eventName:$event, source:"project",
         sourcePath:($root + "/.codex/hooks.json"), matcher:$matcher, command:.command,
         enabled:$enabled, trustStatus:$status}])}]}' "$BATS_TEST_DIRNAME/../.codex/hooks.json"
}

# with_hook LISTING JQ-UPDATE — LISTING with the project hooks rewritten.
with_hook() {
  printf '%s' "$1" | jq -c "(.data[0].hooks[] | select(.source == \"project\")) |= ($2)"
}

doctor() { run env PATH="$BATS_TEST_TMPDIR/bin:/usr/bin:/bin" bash .agent-md/bin/doctor.sh; }

@test "Codex hooks the host does not discover are not reported as installed and working" {
  fake_codex "$(listing trusted true '')"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_NOT_DISCOVERED]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"/hooks"* ]]
  [[ "$output" != *HOST_HOOKS_READY* ]]
}

@test "Codex hooks awaiting review are pending approval, and a changed hook needs review again" {
  fake_codex "$(listing untrusted true)"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_PENDING_APPROVAL]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *preToolUse* ]]
  fake_codex "$(listing modified true)"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_PENDING_APPROVAL]"* ]]
  [[ "$output" == *modified* ]]
}

@test "an approved but disabled Codex hook is reported as disabled" {
  fake_codex "$(listing trusted false)"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_DISABLED]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *preToolUse* ]]
}

@test "a missing coding-agent-control event is not hidden by the others" {
  fake_codex "$(listing trusted true 'postToolUse subagentStop stop')"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_NOT_DISCOVERED]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *preToolUse* ]]
}

@test "approved and enabled Codex hooks confirm prerequisites without claiming execution" {
  fake_codex "$(listing trusted true)"
  doctor
  [[ "$output" == *"[INFO HOST_HOOKS_READY]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"does not observe execution"* ]]
  [[ "$output" != *"[WARNING HOST_HOOKS_"* ]]
}

@test "an unreadable host listing is indeterminate, never ready" {
  printf '#!/bin/bash\nexit 3\n' > "$BATS_TEST_TMPDIR/bin/codex"
  chmod +x "$BATS_TEST_TMPDIR/bin/codex"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_INDETERMINATE]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  fake_codex '{"unexpected":true}'
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_INDETERMINATE]"* ]]
  [[ "$output" != *HOST_HOOKS_READY* ]]
}

@test "without the Codex CLI activation is unknown and needs a human check" {
  doctor
  [[ "$output" == *"[INFO HOST_HOOKS_UNVERIFIED]"*Codex* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"/hooks"* ]]
}

@test "Claude settings that turn hooks off are reported as disabled in every scope" {
  for scope in project local user managed; do
    case "$scope" in
      project) file=.claude/settings.json ;;
      local) file=.claude/settings.local.json ;;
      user) file="$HOME/.claude/settings.json" ;;
      managed) file="$AGENT_MD_CLAUDE_MANAGED_SETTINGS" ;;
    esac
    mkdir -p "$(dirname "$file")"
    [ -f "$file" ] && cp "$file" "$file.orig"
    if [ -f "$file" ]; then jq '. + {disableAllHooks: true}' "$file.orig" > "$file"; else echo '{"disableAllHooks": true}' > "$file"; fi
    doctor
    [[ "$output" == *"[WARNING HOST_HOOKS_DISABLED]"*Claude* ]] || { printf '%s: %s\n' "$scope" "$output" >&2; return 1; }
    if [ -f "$file.orig" ]; then mv "$file.orig" "$file"; else rm "$file"; fi
  done
  echo '{"allowManagedHooksOnly": true}' > "$AGENT_MD_CLAUDE_MANAGED_SETTINGS"
  doctor
  [[ "$output" == *"[WARNING HOST_HOOKS_DISABLED]"*allowManagedHooksOnly* ]]
}

@test "Claude hooks that no setting disables are still only unverified" {
  doctor
  [[ "$output" == *"[INFO HOST_HOOKS_UNVERIFIED]"*Claude* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" != *"HOST_HOOKS_READY]"*Claude* ]]
}

@test "activation findings are diagnostics and leave the doctor exit unchanged" {
  fake_codex "$(listing untrusted false)"
  doctor
  baseline=$status
  fake_codex "$(listing trusted true)"
  doctor
  [ "$status" -eq "$baseline" ]
}

@test "READY means the coding-agent-control handlers, not any trusted handler on the same event" {
  fake_codex "$(with_hook "$(listing trusted true)" 'if .eventName == "stop" then .command = "true" else . end')"
  doctor
  [[ "$output" != *HOST_HOOKS_READY* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"[WARNING HOST_HOOKS_NOT_DISCOVERED]"*stop* ]]
}

@test "a hook file that lost a coding-agent-control handler is not ready" {
  jq 'del(.hooks.Stop)' .codex/hooks.json > hooks.tmp && mv hooks.tmp .codex/hooks.json
  fake_codex "$(listing trusted true 'preToolUse postToolUse subagentStop')"
  doctor
  [[ "$output" != *HOST_HOOKS_READY* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"[WARNING HOST_HOOKS_NOT_DISCOVERED]"*stop* ]]
}

@test "a coding-agent-control handler moved to another matcher is not ready" {
  fake_codex "$(with_hook "$(listing trusted true)" 'if .eventName == "preToolUse" then .matcher = "Edit" else . end')"
  doctor
  [[ "$output" != *HOST_HOOKS_READY* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *"[WARNING HOST_HOOKS_NOT_DISCOVERED]"*preToolUse* ]]
}

@test "a project's own handler beside the coding-agent-control ones does not change their verdict" {
  base=$(listing trusted true)
  fake_codex "$(printf '%s' "$base" | jq -c --arg root "$ROOT" '.data[0].hooks += [{key:($root + "/.codex/hooks.json:stop:1:0"),
    eventName:"stop", source:"project", sourcePath:($root + "/.codex/hooks.json"), matcher:null,
    command:"./scripts/project-stop.sh", enabled:false, trustStatus:"untrusted"}]')"
  doctor
  [[ "$output" == *"[INFO HOST_HOOKS_READY]"* ]] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" != *project-stop.sh* ]]
}
