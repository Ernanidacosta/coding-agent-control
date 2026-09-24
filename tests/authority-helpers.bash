# tests/authority-helpers.bash — shared fixture support for the local issuer.

# Builds an execution PATH whose eligibility does not depend on how the host
# happens to permission its system directories.
#
# The default approved PATH starts with /usr/local/bin. A GitHub-hosted runner
# gives that directory to the unprivileged user so tooling can install itself,
# which correctly makes a project ineligible there while every developer
# machine stays eligible. The policy is right; a fixture that inherits the
# host's answer is not deterministic. This builds its own directory instead:
# the eligibility rule looks at the directory, so symlinks inside it are fine
# and no binary has to be copied.
trusted_toolchain_path() {
  local base="$1" bin="$1/bin" tool src
  mkdir -p "$bin"
  for tool in cat sleep grep sed awk head tail touch rm ls mkdir mkfifo python3 true false printf; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$bin/$tool"
  done
  chmod 0555 "$bin"
  chmod 0555 "$base"
  printf '%s' "$bin"
}

# External test controls are part of the trusted fixture tool directory. They
# remain read-only inside the sandbox; no host/state tree is exposed for tests.
fixture_controls() {
  chmod u+w "$TOOLCHAIN/bin"
  mkdir -p "$TOOLCHAIN/bin/controls"
  chmod 0555 "$TOOLCHAIN/bin"
  printf '%s' "$TOOLCHAIN/bin/controls"
}

# Mutate as the external developer, after the check has reached its FIFO.
# The check itself cannot reach the live worktree through the mount namespace.
fixture_evaluate() {
  local mutator="" result scratch="$ROOT/var/tmp/agent-md-runner/$PID/test"
  if [ -n "${MUTATE:-}" ] && [ -f "$MUTATE" ]; then
    (
      deadline=$((SECONDS + 30))
      until [ -p "$scratch/mutation" ]; do
        [ "$SECONDS" -lt "$deadline" ] || exit 1
        sleep 0.02
      done
      printf x >> "$WS/marker.txt"
      printf release > "$scratch/mutation"
    ) & mutator=$!
  fi
  if request | bash "$ISSUER" evaluate --root "$ROOT" 2>/dev/null; then result=0; else result=$?; fi
  [ -z "$mutator" ] || wait "$mutator" || return 1
  return "$result"
}

# Prints why an enrollment is not eligible, so a failing assertion says what
# the authority actually objected to instead of only that something refused.
enrollment_diagnosis() {
  local record="$1"
  [ -f "$record" ] || { printf 'no enrollment record at %s\n' "$record"; return 0; }
  printf 'status: %s\n' "$(jq -r '.status' "$record")"
  jq -r '.reasons[]? | "  reason: " + .' "$record"
  jq -r '.path_eligibility[]? | select(.status != "eligible")
    | "  PATH " + .entry + " -> " + .resolved + ": " + .reason' "$record"
  jq -r '.approved_tools[]? | "  tool " + .name + " -> " + .path' "$record"
}
