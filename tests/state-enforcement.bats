#!/usr/bin/env bats

load helpers

setup() {
  setup_repo
  write_progress active "Exercise state enforcement"
  # Commit the initial progress.md so it's TRACKED. Otherwise it would
  # itself show up as an untracked "change" and mask the tests.
  git add memory/progress.md
  git commit -q -m "init progress"
}
teardown() { teardown_repo; }

@test "noop: no memory/progress.md" {
  rm memory/progress.md
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "noop: no source files changed" {
  echo "export const x = 1" > src.ts
  git add -A && git commit -q -m init
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "blocks: tracked source modified without progress update" {
  echo "export const x = 1" > src.ts
  git add -A && git commit -q -m init
  echo "export const y = 2" >> src.ts
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "blocks: untracked source file counts as a change" {
  echo "export const x = 1" > src.ts
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "blocks: src/foo.py is operationally relevant" {
  mkdir -p src
  echo "x = 1" > src/foo.py
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
  echo "$out" | jq -e '.reason | test("src/foo.py")' > /dev/null
}

@test "adversarial paths with spaces dotfiles and nested packages remain relevant" {
  mkdir -p src packages/a/src
  echo "x = 1" > "src/foo bar.py"
  echo "hidden = true" > .hidden.py
  echo "export const x = 1" > packages/a/src/x.ts
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' >/dev/null
  echo "$out" | jq -e '.reason | test("src/foo bar.py")' >/dev/null
  echo "$out" | jq -e '.reason | contains(".hidden.py")' >/dev/null
  echo "$out" | jq -e '.reason | test("packages/a/src/x.ts")' >/dev/null
}

@test "blocks: test changes are operationally relevant" {
  mkdir -p tests
  echo "def test_x(): pass" > tests/test_x.py
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "blocks: executable source under scripts is not ignored" {
  mkdir -p scripts
  echo '#!/bin/bash' > scripts/task.sh
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "blocks: executable source under tools is not ignored" {
  mkdir -p tools
  echo 'print("tool")' > tools/tool.py
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "ignores non-source metadata under scripts by default" {
  mkdir -p scripts
  echo '{"generated": true}' > scripts/metadata.json
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "passes: source modified AND progress.md updated" {
  echo "export const x = 1" > src.ts
  git add -A && git commit -q -m init
  echo "export const y = 2" >> src.ts
  write_progress active "Reflect the source update"
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "passes: gitignored progress uses the shared mtime fallback" {
  git rm --cached -q memory/progress.md
  git commit -q -m "untrack progress"
  echo 'memory/' > .git/info/exclude
  echo "export const x = 1" > src.ts
  touch memory/progress.md
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "still blocks on stop_hook_active — no retry escape" {
  echo "export const x = 1" > src.ts
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":true}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "ignores markdown-only changes" {
  echo "# doc" > NOTES.md
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "ignores .ai-memory.toml-only changes" {
  echo 'enabled = true' > .ai-memory.toml
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "ignores .gitignore-only changes" {
  echo '.cache/' > .gitignore
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "ignores documentation directory changes" {
  mkdir -p docs
  echo "# Guide" > docs/guide.txt
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "custom source_globs replace defaults" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = ["domain/**"]
EOF
  git add agent-md.toml && git commit -q -m "custom classifier baseline"
  echo "export const ignored = true" > src.ts
  mkdir -p domain
  echo "schema" > domain/model.custom
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
  echo "$out" | jq -e '.reason | test("domain/model.custom")' > /dev/null
  ! echo "$out" | jq -r '.reason' | grep -q 'src.ts'
}

@test "custom ignore_globs apply to untracked files and win over source" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = [
  "generated/**",
  "*.py",
]
ignore_globs = ["generated/**"]
EOF
  git add agent-md.toml && git commit -q -m "custom classifier baseline"
  mkdir -p generated
  echo "x = 1" > generated/client.py
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "empty source_globs disables path-based progress enforcement" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = []
EOF
  git add agent-md.toml && git commit -q -m "empty classifier baseline"
  echo "export const x = 1" > src.ts
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "invalid source_globs block with a configuration error" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = [src/**]
EOF
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
  echo "$out" | jq -e '.reason | test("Invalid agent-md.toml.*state.source_globs")' > /dev/null
}

@test "pre-commit uses the shared classifier for staged source" {
  echo "export const x = 1" > src.ts
  git add src.ts
  run bash .githooks/pre-commit
  [ "$status" -eq 1 ]
  echo "$output" | grep -q 'operationally relevant file(s) changed'
  echo "$output" | grep -q 'ERROR STATE_PROGRESS_STALE'
}

@test "pre-commit accepts locally updated legacy progress without staging it" {
  echo "export const x = 1" > src.ts
  git add src.ts
  write_progress active "Reflect the staged source update"

  run bash .githooks/pre-commit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'operational state up to date'
  ! git diff --cached --name-only | grep -q '^memory/'
}

@test "pre-commit uses the shared classifier for staged documentation" {
  mkdir -p docs
  echo "guide" > docs/guide.txt
  git add docs/guide.txt
  run bash .githooks/pre-commit
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'operational state up to date'
}

@test "ignores .agent/ scratch state" {
  mkdir -p .agent/state .agent/visual
  echo "1" > .agent/state/stop-verify-retries
  echo "img" > .agent/visual/home.png
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "ignores installed agent-md infrastructure" {
  mkdir -p .agent-md/bin .codex/hooks .agents/skills/demo .cursor/rules .windsurf/rules
  echo "#!/bin/bash" > .agent-md/bin/helper.sh
  echo "{}" > .codex/hooks.json
  echo "# hook" > .codex/hooks/stop.sh
  echo "# skill" > .agents/skills/demo/SKILL.md
  echo "# cursor" > .cursor/rules/agent-md.mdc
  echo "# windsurf" > .windsurf/rules/agent-md.md
  out=$(run_hook state-enforcement.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}
