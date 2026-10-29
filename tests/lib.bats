#!/usr/bin/env bats

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

@test "read_toml: basic key in section" {
  cat > agent-md.toml <<EOF
[verify]
typecheck = "npx tsc --noEmit"
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml agent-md.toml verify typecheck)"
  [ "$result" = "npx tsc --noEmit" ]
}

@test "read_toml: returns empty for missing key" {
  cat > agent-md.toml <<EOF
[verify]
lint = "eslint"
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml agent-md.toml verify missing)"
  [ -z "$result" ]
}

@test "read_toml: skips other sections" {
  cat > agent-md.toml <<EOF
[other]
typecheck = "wrong"

[verify]
typecheck = "right"
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml agent-md.toml verify typecheck)"
  [ "$result" = "right" ]
}

@test "read_toml: strips inline comments from values" {
  cat > agent-md.toml <<EOF
[verify]
lint = "eslint"  # inline note
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml agent-md.toml verify lint)"
  [ "$result" = "eslint" ]
}

@test "read_toml: handles unquoted bools and numbers" {
  cat > agent-md.toml <<EOF
[visual]
required = true
freshness_seconds = 3600
EOF
  . .claude/hooks/_lib.sh
  [ "$(read_toml agent-md.toml visual required)" = "true" ]
  [ "$(read_toml agent-md.toml visual freshness_seconds)" = "3600" ]
}

@test "read_toml: no file, no output, no error" {
  . .claude/hooks/_lib.sh
  result="$(read_toml nonexistent.toml verify lint)"
  [ -z "$result" ]
}

@test "read_toml_array: parses inline quoted values" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = ["src/**", '*.py']
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml_array agent-md.toml state source_globs)"
  [ "$result" = $'src/**\n*.py' ]
}

@test "read_toml_array: parses multiline values and comments" {
  cat > agent-md.toml <<'EOF'
[state]
ignore_globs = [
  "docs/**", # documentation
  ".ai-memory.toml",
]
EOF
  . .claude/hooks/_lib.sh
  result="$(read_toml_array agent-md.toml state ignore_globs)"
  [ "$result" = $'docs/**\n.ai-memory.toml' ]
}

@test "read_toml_array: distinguishes empty, missing, and invalid arrays" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = []
ignore_globs = [1]
EOF
  . .claude/hooks/_lib.sh
  run read_toml_array agent-md.toml state source_globs
  [ "$status" -eq 0 ]
  [ -z "$output" ]
  run read_toml_array agent-md.toml state absent
  [ "$status" -eq 1 ]
  run read_toml_array agent-md.toml state ignore_globs
  [ "$status" -eq 2 ]
}

@test "read_toml_array: an invalid document is never read in part" {
  cat > agent-md.toml <<'EOF'
[state]
source_globs = []
ignore_globs = [docs/**]
EOF
  . .claude/hooks/_lib.sh
  run read_toml_array agent-md.toml state source_globs
  [ "$status" -eq 2 ]
  [ -z "$output" ]
  run read_toml_array agent-md.toml state ignore_globs
  [ "$status" -eq 2 ]
}

@test "detect_pm: pnpm wins on pnpm-lock" {
  touch pnpm-lock.yaml package-lock.json
  . .claude/hooks/_lib.sh
  [ "$(detect_pm)" = "pnpm" ]
}

@test "detect_pm: yarn wins when no pnpm" {
  touch yarn.lock package-lock.json
  . .claude/hooks/_lib.sh
  [ "$(detect_pm)" = "yarn" ]
}

@test "detect_pm: bun via bun.lock" {
  touch bun.lock
  . .claude/hooks/_lib.sh
  [ "$(detect_pm)" = "bun" ]
}

@test "detect_pm: npm from package.json alone" {
  echo '{}' > package.json
  . .claude/hooks/_lib.sh
  [ "$(detect_pm)" = "npm" ]
}

@test "detect_pm: empty when no node project" {
  . .claude/hooks/_lib.sh
  [ -z "$(detect_pm)" ]
}

@test "npm_test_cmd: maps pm to command" {
  touch pnpm-lock.yaml
  . .claude/hooks/_lib.sh
  [ "$(npm_test_cmd)" = "pnpm test --silent" ]
}

@test "visual_evidence_ok: fails when dir missing" {
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}

@test "visual_evidence_ok: fails with only an image" {
  mkdir -p .agent/visual
  touch .agent/visual/home.png
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}

@test "visual_evidence_ok: fails when markdown does not reference the image" {
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  echo "no image name here" > .agent/visual/note.md
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}

@test "visual_evidence_ok: fails when image is zero bytes" {
  mkdir -p .agent/visual
  touch .agent/visual/home.png
  cat > .agent/visual/note.md <<'EOF'
Changed files:
- App.tsx
Route: /home
Viewport: 1280x800
Artifact: home.png
Observed result: renders
EOF
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}

@test "visual_evidence_ok: fails when required fields are missing" {
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  echo "Artifact: home.png" > .agent/visual/note.md
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}

@test "visual_evidence_ok: passes with fresh structured markdown and image" {
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  cat > .agent/visual/note.md <<'EOF'
Changed files:
- App.tsx
Route: /home
Viewport: 1280x800
Artifact: home.png
Observed result: renders
EOF
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 0 ]
}

@test "visual_evidence_ok: stale markdown does not count" {
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  cat > .agent/visual/note.md <<'EOF'
Changed files:
- App.tsx
Route: /home
Viewport: 1280x800
Artifact: home.png
Observed result: renders
EOF
  # Backdate the markdown file by 2 hours
  if stat -f %m .agent/visual/note.md >/dev/null 2>&1; then
    touch -t "$(date -v-2H '+%Y%m%d%H%M.%S')" .agent/visual/note.md
  else
    touch -d "2 hours ago" .agent/visual/note.md
  fi
  . .claude/hooks/_lib.sh
  run visual_evidence_ok ".agent/visual" 3600
  [ "$status" -eq 1 ]
}
