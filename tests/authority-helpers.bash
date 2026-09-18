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
  for tool in cat sleep grep sed awk head tail touch rm ls mkdir python3 true false printf; do
    src=$(command -v "$tool" 2>/dev/null) || continue
    ln -sf "$src" "$bin/$tool"
  done
  chmod 0555 "$bin"
  chmod 0555 "$base"
  printf '%s' "$bin"
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
