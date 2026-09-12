#!/usr/bin/env bats

load helpers

setup()    { setup_repo; }
teardown() { teardown_repo; }

@test "silent when no UI files changed" {
  echo "export const x = 1" > src.ts
  git add -A && git commit -q -m init
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  [ -z "$out" ]
}

@test "advisory reminder when UI files changed (default mode)" {
  echo "<div/>" > App.tsx
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null
  echo "$out" | jq -e '
    .hookSpecificOutput.additionalContext |
    test("WARNING QUALITY_VISUAL_EVIDENCE_RECOMMENDED")
  ' > /dev/null
}

@test "blocks when required=true and no artifact exists" {
  cat > agent-md.toml <<EOF
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
  echo "$out" | jq -e '.reason | test("ERROR VERIFY_REQUIRED_FAILED")' > /dev/null
}

@test "blocks when required=true and only an image exists (no markdown)" {
  cat > agent-md.toml <<EOF
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  # A screenshot alone is not verification — must still block.
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "blocks when markdown exists but doesn't reference the image" {
  cat > agent-md.toml <<EOF
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  cat > .agent/visual/note.md <<'EOF'
# Visual check
Some prose that does NOT name the image file.
EOF
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "passes when markdown references the fresh image" {
  cat > agent-md.toml <<EOF
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  mkdir -p .agent/visual
  echo "png" > .agent/visual/home.png
  cat > .agent/visual/note.md <<'EOF'
# Visual check
Changed files:
- App.tsx
Route: /home
Viewport: 1440x900
Artifact: home.png
Observed result: renders without overlap.
EOF
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":false}')
  echo "$out" | jq -e '.hookSpecificOutput.additionalContext' > /dev/null
  # Must not be a block
  echo "$out" | jq -e 'has("decision") | not' > /dev/null
}

@test "still blocks when stop_hook_active=true — no retry escape" {
  cat > agent-md.toml <<EOF
[visual]
required = true
artifacts_dir = ".agent/visual"
freshness_seconds = 3600
EOF
  echo "<div/>" > App.tsx
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":true}')
  echo "$out" | jq -e '.decision == "block"' > /dev/null
}

@test "advisory reminder goes quiet when stop_hook_active=true" {
  # A retry cannot act on a reminder it already received, so repeating it
  # would only restart the agent. See tests/stop-hook-active.bats.
  echo "<div/>" > App.tsx
  out=$(run_hook sensory-reminder.sh '{"stop_hook_active":true}')
  [ -z "$out" ]
}
