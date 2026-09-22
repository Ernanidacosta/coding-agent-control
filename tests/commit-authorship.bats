#!/usr/bin/env bats
#
# Human commit authorship.
#
# Two controls are separate and only the second is enforced here:
#
#   commit execution authority — who may run `git commit`. Unchanged; an
#     agent still may not commit.
#   commit authorship — whose name the history carries. An agent may draft a
#     subject and body, but must not credit itself in the result.
#
# The hook must be narrow. A blanket Co-Authored-By ban would break human pair
# authorship, and scanning prose for a model name would block commits that
# merely describe this project.

load helpers

setup() {
  setup_repo
  git config user.name "A Developer"
  git config user.email dev@example.com
}
teardown() { teardown_repo; }

# Runs the hook against a message and reports the decision, without committing.
check_message() {
  printf '%s' "$1" > "$REPO_DIR/msg.txt"
  bash .githooks/commit-msg "$REPO_DIR/msg.txt"
}

blocked_reason() {
  printf '%s' "$1" > "$REPO_DIR/msg.txt"
  bash .githooks/commit-msg "$REPO_DIR/msg.txt" 2>&1 || true
}

# --- allowed ---------------------------------------------------------------

@test "an ordinary commit message is allowed" {
  check_message "fix: correct the nested quote parser

The lexer dropped the closing quote when a string spanned two lines."
}

@test "an agent-drafted subject and body without attribution is allowed" {
  check_message "fix: stop advisory context from looping the Stop hook

The handlers discarded the hook payload, so the retry flag was never read
and advisory warnings were re-emitted on every finish attempt."
}

@test "a model name used legitimately in the body does not block" {
  # This is the false positive that matters most: this repository's own
  # commits describe agent behavior constantly.
  check_message "docs: describe the Claude Code stop contract

Claude Code sets stop_hook_active on any finish attempt that follows one a
hook already answered. Codex reuses the same handlers, and Copilot is out of
scope. Note: ChatGPT is mentioned here only as an example."
}

@test "a human co-author is allowed" {
  check_message "feat: add the importer

Co-Authored-By: Jane Doe <jane@example.com>"
}

@test "human names that contain a model substring are allowed" {
  # Bardot contains 'bard'; Hellman would match a careless 'llm' pattern.
  check_message "feat: add the importer

Co-Authored-By: Brigitte Bardot <bb@example.com>
Signed-off-by: Anna Hellman <anna@example.com>"
}

@test "an ordinary trailer whose value mentions a model is allowed" {
  check_message "fix: thing

Refs: the Claude Code hook contract
Reviewed-by: Jane Doe <jane@example.com>"
}

# --- blocked ---------------------------------------------------------------

@test "Co-Authored-By naming Claude is blocked and names the line" {
  run blocked_reason "fix: thing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
  [ "$status" -eq 0 ]
  echo "$output" | grep -q 'ERROR COMMIT_AI_ATTRIBUTION'
  echo "$output" | grep -q 'line 3: Co-Authored-By: Claude Opus 5'
}

@test "a Claude-Session trailer is blocked" {
  ! check_message "fix: thing

Claude-Session: https://claude.ai/code/session_01EEwwVgsCoo"
}

@test "other supported agents are blocked the same way" {
  ! check_message "fix: thing

Co-Authored-By: Copilot <copilot@github.com>"
  ! check_message "fix: thing

Co-Authored-By: ChatGPT <noreply@openai.com>"
  ! check_message "fix: thing

Co-Authored-By: Cursor Agent <agent@cursor.example>"
  ! check_message "fix: thing

Co-Authored-By: OpenAI Codex <codex@example.com>"
  ! check_message "fix: thing

Co-Authored-By: some-app[bot] <bot@example.com>"
}

@test "generation trailers are blocked whatever the agent" {
  ! check_message "fix: thing

Generated-By: Cursor"
  ! check_message "fix: thing

Generated-With: Windsurf"
  ! check_message "fix: thing

AI-Assisted-By: Gemini"
  ! check_message "fix: thing

Agent-Session: https://example.com/s/1"
}

@test "the standalone generated-with footer and session link are blocked" {
  ! check_message "fix: thing

🤖 Generated with [Claude Code](https://claude.com/claude-code)"
  ! check_message "fix: thing

https://claude.ai/code/session_01EEwwVgsCoo"
}

@test "a signed-off-by naming an agent is blocked" {
  ! check_message "fix: thing

Signed-off-by: Claude <noreply@anthropic.com>"
}

@test "every offending line is reported, not just the first" {
  run blocked_reason "fix: thing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01EEww"
  echo "$output" | grep -q 'line 3: Co-Authored-By'
  echo "$output" | grep -q 'line 4: Claude-Session'
  echo "$output" | grep -q '2 commit message line'
}

# --- boundaries ------------------------------------------------------------

@test "the hook never modifies the message" {
  printf 'fix: thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$REPO_DIR/msg.txt"
  cp "$REPO_DIR/msg.txt" "$REPO_DIR/msg.orig"
  run bash .githooks/commit-msg "$REPO_DIR/msg.txt"
  [ "$status" -ne 0 ]
  diff -q "$REPO_DIR/msg.txt" "$REPO_DIR/msg.orig"
}

@test "the hook never changes the configured identity" {
  printf 'fix: thing\n\nCo-Authored-By: Claude <noreply@anthropic.com>\n' > "$REPO_DIR/msg.txt"
  run bash .githooks/commit-msg "$REPO_DIR/msg.txt"
  [ "$(git config user.name)" = "A Developer" ]
  [ "$(git config user.email)" = "dev@example.com" ]
}

@test "git comments are ignored and a comment-only message is left to git" {
  check_message "# Please enter the commit message for your changes.
# Co-Authored-By: Claude <noreply@anthropic.com>
# On branch main"
}

@test "an empty message keeps normal git behavior" {
  check_message ""
}

@test "a verbose diff below the scissors line is not part of the message" {
  # `git commit --verbose` appends the staged diff. Editing this very test
  # file would otherwise block the commit that adds it.
  check_message "test: add authorship coverage

# ------------------------ >8 ------------------------
# Do not modify or remove the line above.
diff --git a/tests/commit-authorship.bats b/tests/commit-authorship.bats
+Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>
+Claude-Session: https://claude.ai/code/session_01EE"
}

@test "a missing message file leaves git to decide" {
  bash .githooks/commit-msg
  bash .githooks/commit-msg "$REPO_DIR/does-not-exist.txt"
}

@test "a missing shared library fails visibly instead of passing silently" {
  printf 'fix: thing\n' > "$REPO_DIR/msg.txt"
  rm -f .claude/hooks/_lib.sh
  run bash .githooks/commit-msg "$REPO_DIR/msg.txt"
  [ "$status" -ne 0 ]
  echo "$output" | grep -q 'ERROR CONFIG_INVALID'
}

# --- shipped as a versioned file -------------------------------------------

@test "the repository re-includes .githooks so the hook cannot be silently dropped" {
  # A developer's global ignore file commonly excludes .githooks/. The hook is
  # enforcement, so it has to be versioned; this repository already overrides
  # global ignores for the files it deliberately ships.
  root="$BATS_TEST_DIRNAME/.."
  [ -x "$root/.githooks/commit-msg" ]
  grep -Fxq '!/.githooks/' "$root/.gitignore"
  grep -Fxq '!/.githooks/*' "$root/.gitignore"
}

@test "the project lint command covers the commit-msg hook" {
  grep -Fq '.githooks/commit-msg' "$BATS_TEST_DIRNAME/../agent-md.toml"
}

# --- real commits ----------------------------------------------------------

@test "a real commit carrying agent attribution is refused" {
  git config core.hooksPath .githooks
  echo x > src.py
  git add src.py
  run git commit -m "feat: thing

Co-Authored-By: Claude Opus 5 <noreply@anthropic.com>"
  [ "$status" -ne 0 ]
  [ "$(git rev-list --count HEAD 2>/dev/null || echo 0)" -eq 0 ]
  echo "$output" | grep -q 'COMMIT_AI_ATTRIBUTION'
}

@test "a real commit with a clean message records the human author" {
  git config core.hooksPath .githooks
  echo x > src.py
  git add src.py
  run git commit -m "feat: add the thing"
  [ "$status" -eq 0 ]
  [ "$(git log -1 --pretty='%an <%ae>')" = "A Developer <dev@example.com>" ]
  [ -z "$(git log -1 --pretty='%b')" ]
}

@test "setup_repo isolates an inherited Git context without clearing unrelated environment" {
  local outer="$REPO_DIR/outer" before
  git init -q "$outer"
  git -C "$outer" config user.name "Outer Developer"
  git -C "$outer" config user.email outer@example.com
  printf 'outer\n' > "$outer/outer.txt"
  git -C "$outer" add outer.txt
  cp "$outer/.git/index" "$outer/alternate-index"
  before=$(sha256sum "$outer/.git/config" "$outer/.git/index" "$outer/alternate-index")

  run env GIT_DIR="$outer/.git" GIT_WORK_TREE="$outer" \
    GIT_COMMON_DIR="$outer/.git" GIT_OBJECT_DIRECTORY="$outer/.git/objects" \
    GIT_INDEX_FILE="$outer/alternate-index" \
    GIT_CONFIG_COUNT=2 GIT_CONFIG_KEY_0=user.name GIT_CONFIG_VALUE_0="Inherited Developer" \
    GIT_CONFIG_KEY_1=user.email GIT_CONFIG_VALUE_1=inherited@example.com \
    GIT_AUTHOR_NAME="Inherited Author" GIT_AUTHOR_EMAIL=author@example.com \
    GIT_COMMITTER_NAME="Inherited Committer" GIT_COMMITTER_EMAIL=committer@example.com \
    FIXTURE_CONTEXT_MARKER="keep this value" \
    bash -c '
      set -e
      export BATS_TEST_DIRNAME="$1"
      . "$BATS_TEST_DIRNAME/helpers.bash"
      setup_repo
      trap teardown_repo EXIT
      printf "scratch Git directory: %s\n" "$(git rev-parse --absolute-git-dir)"
      [ "$(git rev-parse --absolute-git-dir)" = "$REPO_DIR/.git" ]
      [ "$(git rev-parse --show-toplevel)" = "$REPO_DIR" ]
      [ "$(git config user.name)" = t ]
      [ "$(git config user.email)" = t@t ]
      [[ "$(git var GIT_AUTHOR_IDENT)" == "t <t@t> "* ]]
      [[ "$(git var GIT_COMMITTER_IDENT)" == "t <t@t> "* ]]
      [ "$FIXTURE_CONTEXT_MARKER" = "keep this value" ]
      printf "scratch\n" > scratch.txt
      git add scratch.txt
      [ "$(realpath "$(git rev-parse --git-path index)")" = "$REPO_DIR/.git/index" ]
      [ "$(git ls-files)" = scratch.txt ]
    ' _ "$BATS_TEST_DIRNAME"
  [ "$status" -eq 0 ]
  [ "$(sha256sum "$outer/.git/config" "$outer/.git/index" "$outer/alternate-index")" = "$before" ]
  [ "$(git -C "$outer" config user.name)" = "Outer Developer" ]
  [ "$(git -C "$outer" config user.email)" = outer@example.com ]
  [ "$(git -C "$outer" ls-files)" = outer.txt ]
}
