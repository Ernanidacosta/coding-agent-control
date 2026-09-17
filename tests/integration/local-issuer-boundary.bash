#!/bin/bash
# tests/integration/local-issuer-boundary.bash
#
# Exercises the local issuer's OS boundary with three real principals. The unit
# suite runs every role as one user, which cannot demonstrate that a developer
# is unable to reach the execution account, the authority state or the signing
# key. This does, against a disposable container, and it changes nothing on the
# host.
#
#   bash tests/integration/local-issuer-boundary.bash
#
# Requires Docker. It is deliberately not part of tests/run.sh: it has its own
# prerequisites and its own runtime.
set -u

ROOT_DIR=$(cd "$(dirname "$0")/../.." && pwd)
IMAGE=${AGENT_MD_INTEGRATION_IMAGE:-debian:stable-slim}

command -v docker >/dev/null 2>&1 || { echo "docker is required" >&2; exit 2; }
docker info >/dev/null 2>&1 || { echo "the docker daemon is not reachable" >&2; exit 2; }

PAYLOAD=$(mktemp -d) || exit 2
trap 'rm -rf "$PAYLOAD"' EXIT

cat > "$PAYLOAD/agent-md.toml" <<'TOML'
[verify]
lint = "cat marker.txt"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 8
TOML

cat > "$PAYLOAD/exits.toml" <<'TOML'
[verify]
test = "exit 0"
lint = "exit 1"
smoke = "definitely-not-a-real-command-xyz"
integration = "kill -KILL $$"
runtime = "exit 7"
typecheck = "exit 125"

[verify.policy]
required = ["test"]
timeout_seconds = 8
TOML

cat > "$PAYLOAD/failing.toml" <<'TOML'
[verify]
lint = "exit 3"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 8
TOML

cat > "$PAYLOAD/slow.toml" <<'TOML'
[verify]
lint = "sleep 30"
test = "cat marker.txt"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 8
total_timeout_seconds = 3
TOML

cat > "$PAYLOAD/setup.sh" <<'SETUP'
#!/bin/bash
# Production layout with three real principals. Runs as root inside the
# container only; nothing here is intended for a host.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq jq sudo strace python3 git procps util-linux >/dev/null 2>&1 \
  || { echo "SETUP-FAIL: packages"; exit 1; }

useradd -m -s /bin/bash dev
echo "HOME_MODE_DEFAULT: $(stat -c %a /home/dev)"
# Debian creates homes 0700 and the authority cannot traverse that, so
# enrollment fails closed. Relaxed here only so the rest can be exercised.
chmod 0755 /home/dev
useradd -m -s /bin/bash dev2
chmod 0755 /home/dev2
useradd -r -M -s /usr/sbin/nologin -d /var/lib/agent-md agentmd
useradd -r -M -s /usr/sbin/nologin -d /nonexistent agentmd-runner

install -d -o root -g root -m 0755 /usr/local/lib/agent-md
for f in authority-lib.sh agent-md-authority agent-md-issuer run-check; do
  install -o root -g root -m 0755 "/src/$f" "/usr/local/lib/agent-md/$f"
done
install -d -o agentmd -g agentmd -m 0755 /var/lib/agent-md
install -d -o agentmd -g agentmd -m 0755 /var/lib/agent-md/projects
install -d -o agentmd -g agentmd -m 0700 /var/lib/agent-md/keys
install -d -o agentmd-runner -g agentmd-runner -m 0700 /var/tmp/agent-md-runner
printf 'FAKE-PRIVATE-KEY-SENTINEL\n' > /var/lib/agent-md/keys/issuer.key
chown agentmd:agentmd /var/lib/agent-md/keys/issuer.key
chmod 0600 /var/lib/agent-md/keys/issuer.key

su dev -c 'mkdir -p ~/repo/.claude/hooks ~/repo/.agent-md/bin'
su dev -c 'cd ~/repo && git init -q'
su dev -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'
su dev -c 'printf "#!/bin/bash\n" > ~/repo/.claude/hooks/_lib.sh'
su dev -c 'printf "#!/bin/bash\n" > ~/repo/.claude/hooks/stop-verify.sh'
su dev -c 'printf "#!/bin/bash\n" > ~/repo/.agent-md/bin/verify.sh'
install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml

# A hostile developer home. Each artefact leaves a marker if anything loads it.
PYVER=$(python3 -c 'import sys; print(f"python{sys.version_info[0]}.{sys.version_info[1]}")')
su dev -c "mkdir -p ~/.local/bin ~/.local/lib/$PYVER/site-packages"
su dev -c 'echo "touch /tmp/MARKER-bashrc" > ~/.bashrc'
su dev -c 'echo "touch /tmp/MARKER-profile" > ~/.profile'
su dev -c 'printf "#!/bin/sh\ntouch /tmp/MARKER-fakecat\necho FAKE\n" > ~/.local/bin/cat && chmod +x ~/.local/bin/cat'
su dev -c "echo 'open(\"/tmp/MARKER-usersite\", \"w\").close()' > ~/.local/lib/$PYVER/site-packages/usercustomize.py"
chmod 1777 /tmp

echo "UIDS: dev=$(id -u dev) dev2=$(id -u dev2) agentmd=$(id -u agentmd) agentmd-runner=$(id -u agentmd-runner)"
echo "YAMA: $(cat /proc/sys/kernel/yama/ptrace_scope 2>/dev/null || echo absent)"
echo "KERNEL: $(uname -r)"
echo "SETUP-OK"
SETUP

cat > "$PAYLOAD/matrix.sh" <<'MATRIX'
#!/bin/bash
# The boundary matrix. A row only counts when the operation actually ran.
set -u
LIB=/usr/local/lib/agent-md
PASS=0; FAIL=0; SKIP=0

row() {
  local verdict="FAIL"
  if [ "$5" = "$6" ]; then verdict="PASS"; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-14s | %-21s | %-29s | %-23s | %-14s | %-14s | %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$verdict"
}
skip() {
  SKIP=$((SKIP+1))
  printf '%-14s | %-21s | %-29s | %-23s | %-14s | %-14s | NOT EXERCISED (%s)\n' "$1" "$2" "$3" "$4" "-" "-" "$5"
}
try() { if "$@" >/dev/null 2>&1; then printf allowed; else printf denied; fi; }
header() {
  echo; echo "== $1"
  printf '%-14s | %-21s | %-29s | %-23s | %-14s | %-14s | %s\n' \
    ATTACKER TARGET OPERATION CONTROL ACTUAL EXPECTED VERDICT
}

enroll_project() {
  chmod -R u+w /var/lib/agent-md/projects 2>/dev/null
  rm -rf /var/lib/agent-md/projects/* 2>/dev/null
  sudo -u agentmd "$LIB/agent-md-authority" enroll /home/dev/repo --exec-user dev --yes >/dev/null 2>&1
  PID=$(sudo -u agentmd "$LIB/agent-md-authority" show --workspace /home/dev/repo 2>/dev/null | awk '/^project id:/{print $3}')
  [ -n "$PID" ] || return 1
  rm -f /etc/sudoers.d/agent-md-*
  "$LIB/agent-md-authority" sudoers "$PID" --write >/dev/null
  chmod 0440 "/etc/sudoers.d/agent-md-$PID"
}
# The whole chain: developer asks, authority orchestrates, runner executes.
evaluate_as() {
  local who="$1"
  sudo -u "$who" env -i PATH=/usr/bin:/bin \
    sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate \
    <<<'{"protocol":1,"scope":"worktree","workspace":"/home/dev/repo"}' 2>/tmp/ev.err
}
prepare() { sudo -u agentmd "$LIB/agent-md-authority" prepare-run "$PID" --check "$1" >/dev/null 2>&1; }
run_job() { sudo -u agentmd sudo -n -u agentmd-runner "$LIB/run-check" "$PID" "$1" >/tmp/rc.out 2>/tmp/rc.err; echo $?; }

echo "=== ENROLL + SUDOERS ==="
enroll_project || { echo "ABORT: enrollment failed"; exit 1; }
visudo -cf "/etc/sudoers.d/agent-md-$PID"
visudo -c >/dev/null && echo "global sudoers: valid"
grep -Ev '^(#|$)' "/etc/sudoers.d/agent-md-$PID"

echo
echo "=== FULL CHAIN: dev -> agentmd -> agentmd-runner ==="
EV=$(evaluate_as dev); EVCODE=$?
printf '%s\n' "$EV" | jq -c '{status,run_id,checks:[.checks[]|{name,exit_code,execution}],budget}' 2>/dev/null || { echo "ABORT: evaluate produced no object"; cat /tmp/ev.err; exit 1; }
prepare test || { echo "ABORT: prepare failed"; exit 1; }
SNAP=$(jq -r .snapshot "/var/lib/agent-md/projects/$PID/runs/$(cat /var/lib/agent-md/projects/$PID/current-run)/jobs/test.json")

header "1. outer sudo boundary (developer -> authority)"
row dev agentmd "issuer evaluate" "sudoers Cmnd_Alias" "$([ "$EVCODE" -eq 0 ] && printf allowed || printf denied)" allowed
row dev agentmd "authority CLI admin" "sudoers Cmnd_Alias" "$(try sudo -u dev sudo -n -u agentmd "$LIB/agent-md-authority" show --workspace /home/dev/repo)" denied
row dev agentmd "issuer eligibility" "sudoers literal subcmd" "$(try sudo -u dev sudo -n -u agentmd "$LIB/agent-md-issuer" eligibility)" denied
row dev agentmd "shell" "sudoers Cmnd_Alias" "$(try sudo -u dev sudo -n -u agentmd /bin/bash -c id)" denied
row dev root "sudo RunAs root" "sudoers RunAs" "$(try sudo -u dev sudo -n -u root id)" denied
row dev agentmd-runner "run-check directly" "sudoers RunAs" "$(try sudo -u dev sudo -n -u agentmd-runner "$LIB/run-check" "$PID" test)" denied
row dev2 agentmd "issuer evaluate" "sudoers user list" "$(try sudo -u dev2 sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate)" denied
row policy environment "SETENV granted" "sudoers directives" "$(grep -Ev '^#' "/etc/sudoers.d/agent-md-$PID" | grep -q SETENV && printf present || printf absent)" absent
row policy descriptors "closefrom_override" "sudoers text" "$(grep -q closefrom_override "/etc/sudoers.d/agent-md-$PID" && printf present || printf absent)" absent
row policy arguments "wildcard in Cmnd_Alias" "sudoers text" "$(grep -E '^ +/usr/local/lib/agent-md/.*\*' "/etc/sudoers.d/agent-md-$PID" >/dev/null && printf present || printf absent)" absent

header "2. caller identity provenance"
# The sudo rule authorises exactly one command, so provenance is observed
# through the issuer's own view of the caller rather than a probe binary.
row sudo "caller uid" "derived on the real hop" "sudo, after env_reset" "$(evaluate_as dev | jq -r .caller.uid)" "$(id -u dev)"
row sudo "caller user" "derived on the real hop" "sudo, after env_reset" "$(evaluate_as dev | jq -r .caller.user)" dev
SPOOF=$(sudo -u dev env -i PATH=/usr/bin:/bin SUDO_UID=0 SUDO_USER=root \
  sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate \
  <<<'{"protocol":1,"scope":"worktree","workspace":"/home/dev/repo"}' 2>/dev/null)
row dev "SUDO_UID" "spoof across the hop" "sudo env_reset" "$(printf '%s' "$SPOOF" | jq -r .caller.uid)" "$(id -u dev)"
row dev "SUDO_USER" "spoof across the hop" "sudo env_reset" "$(printf '%s' "$SPOOF" | jq -r .caller.user)" dev
LEAK=$(sudo -u dev env -i PATH=/usr/bin:/bin LEAK_CANARY=leaked sudo -n -u agentmd /usr/bin/printenv LEAK_CANARY 2>/dev/null)
row dev "caller variable" "cross the hop" "sudo env_reset" "${LEAK:-absent}" absent
DIRECT=$(SUDO_UID=$(id -u dev) SUDO_USER=dev sudo -u dev "$LIB/agent-md-issuer" evaluate <<<'{"protocol":1,"scope":"worktree","workspace":"/home/dev/repo"}' 2>/dev/null | jq -r .reason_code 2>/dev/null)
row dev issuer "direct call, faked caller" "runs-as-authority check" "${DIRECT:-no-object}" REFUSED_CALLER_UNBOUND

header "3. caller binding to the enrollment"
EV2=$(sudo -u dev2 env -i PATH=/usr/bin:/bin sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate <<<'{"protocol":1,"scope":"worktree","workspace":"/home/dev/repo"}' 2>/dev/null | jq -r .reason_code 2>/dev/null)
row dev2 "dev's project" "evaluate" "enrollment caller match" "${EV2:-denied-by-sudo}" denied-by-sudo
sed -i 's/^dev ALL=/dev2 ALL=/' "/etc/sudoers.d/agent-md-$PID"
EV3=$(sudo -u dev2 env -i PATH=/usr/bin:/bin sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate <<<'{"protocol":1,"scope":"worktree","workspace":"/home/dev/repo"}' 2>/dev/null | jq -r .reason_code 2>/dev/null)
row dev2 "dev's project" "evaluate with sudo access" "enrollment caller match" "${EV3:-no-object}" REFUSED_CALLER_MISMATCH
sed -i 's/^dev2 ALL=/dev ALL=/' "/etc/sudoers.d/agent-md-$PID"
# A repository edit cannot change who the caller is; the caller comes from the
# boundary. A cosmetic edit also leaves the approved contract unchanged, which
# is correct: approval is over the canonical contract, not over bytes.
sudo -u dev bash -c 'printf "\n" >> ~/repo/agent-md.toml'
row dev repo "whitespace edit" "canonical contract" "$(evaluate_as dev | jq -r .status)" candidate_pass
row dev repo "caller after repo edit" "boundary-derived caller" "$(evaluate_as dev | jq -r .caller.user)" dev
sudo -u dev bash -c 'truncate -s -1 ~/repo/agent-md.toml'
# Changing what a check actually runs is the change approval exists to catch.
sudo -u dev sed -i 's|^lint = .*|lint = "true"|' /home/dev/repo/agent-md.toml
row dev repo "semantic contract change" "approved fingerprint" "$(evaluate_as dev | jq -r .reason_code)" REFUSED_CONTRACT_CHANGED
sudo -u dev sed -i 's|^lint = .*|lint = "cat marker.txt"|' /home/dev/repo/agent-md.toml
row dev repo "restored contract" "approved fingerprint" "$(evaluate_as dev | jq -r .status)" candidate_pass

header "4. request may not carry authority"
for FIELD in '"command":"true"' '"checks":[]' '"project_id":"x"' '"caller":{"uid":0}' '"fingerprints":{}'; do
  CODE=$(sudo -u dev env -i PATH=/usr/bin:/bin sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate \
    <<<"{\"protocol\":1,\"scope\":\"worktree\",\"workspace\":\"/home/dev/repo\",$FIELD}" 2>/dev/null | jq -r .reason_code 2>/dev/null)
  row dev request "extra field $FIELD" "strict request schema" "${CODE:-no-object}" REFUSED_MALFORMED_REQUEST
done

header "5. revalidation refuses before execution"
sudo -u dev bash -c 'printf "#!/bin/bash\n# tampered\n" > ~/repo/.claude/hooks/_lib.sh'
row dev mechanism "tamper then evaluate" "approved digests" "$(evaluate_as dev | jq -r .reason_code 2>/dev/null)" REFUSED_MECHANISM_CHANGED
sudo -u dev bash -c 'printf "#!/bin/bash\n" > ~/repo/.claude/hooks/_lib.sh'
row dev "not enrolled path" "evaluate elsewhere" "authority binding" "$(sudo -u dev env -i PATH=/usr/bin:/bin sudo -n -u agentmd "$LIB/agent-md-issuer" evaluate <<<'{"protocol":1,"scope":"worktree","workspace":"/tmp"}' 2>/dev/null | jq -r .reason_code 2>/dev/null)" REFUSED_WORKSPACE_UNSUPPORTED

header "6. one snapshot per evaluation"
EV=$(evaluate_as dev)
RUN=$(printf '%s' "$EV" | jq -r .run_id)
RUNS=$(find "/var/lib/agent-md/projects/$PID/runs" -maxdepth 1 -mindepth 1 -type d | wc -l)
row authority runs "one run directory" "run isolation" "$RUNS" 1
JOBS=$(find "/var/lib/agent-md/projects/$PID/runs/$RUN/jobs" -name '*.json' | wc -l)
row authority jobs "one job per check" "run isolation" "$JOBS" 2
A=$(jq -r .snapshot_fingerprint "/var/lib/agent-md/projects/$PID/runs/$RUN/jobs/lint.json")
B=$(jq -r .snapshot_fingerprint "/var/lib/agent-md/projects/$PID/runs/$RUN/jobs/test.json")
row authority checks "same snapshot identity" "run isolation" "$([ "$A" = "$B" ] && printf same || printf different)" same
EV2=$(evaluate_as dev); RUN2=$(printf '%s' "$EV2" | jq -r .run_id)
row authority runs "fresh run per evaluation" "run isolation" "$([ "$RUN" != "$RUN2" ] && printf fresh || printf reused)" fresh
row authority "previous run" "released after switch" "cleanup" "$([ -d "/var/lib/agent-md/projects/$PID/runs/$RUN" ] && printf present || printf removed)" removed
row authority "current run" "kept while in use" "cleanup" "$([ -d "/var/lib/agent-md/projects/$PID/runs/$RUN2" ] && printf present || printf removed)" present

header "7. candidate status through the whole chain"
row dev evaluation "all required pass" "orchestration" "$(evaluate_as dev | jq -r .status)" candidate_pass
row dev evaluation "worktree mutated mid-run" "sealed snapshot" "$( { sleep 1; sudo -u dev bash -c 'printf "TAMPERED\n" > ~/repo/marker.txt'; } & evaluate_as dev | jq -r .status )" candidate_pass
sudo -u dev bash -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'
install -o dev -g dev -m 0644 /it/failing.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
row dev evaluation "required check fails" "orchestration" "$(evaluate_as dev | jq -r .status)" candidate_fail
install -o dev -g dev -m 0644 /it/slow.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
row dev evaluation "budget exhausted" "never a candidate pass" "$(evaluate_as dev | jq -r .status)" refused
install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null

header "8. no evidence capability yet"
row issuer key "reads issuer.key" "source inspection" "$(grep -qE 'issuer\.key' "$LIB/agent-md-issuer" && printf present || printf absent)" absent
row issuer signing "openssl signing" "source inspection" "$(grep -qE 'openssl[[:space:]]+(pkeyutl|dgst[[:space:]]+-sign)' "$LIB/agent-md-issuer" && printf present || printf absent)" absent
row issuer sequence "sequence allocation" "source inspection" "$(grep -qE 'last_terminal|allocate_sequence' "$LIB/agent-md-issuer" && printf present || printf absent)" absent
row issuer receipt "writes a receipt" "source inspection" "$(grep -qE '\.agent/verification' "$LIB/agent-md-issuer" && printf present || printf absent)" absent
row agentmd issuer.key "untouched by evaluation" "post-run check" "$([ "$(cat /var/lib/agent-md/keys/issuer.key)" = FAKE-PRIVATE-KEY-SENTINEL ] && printf intact || printf changed)" intact
row issuer vocabulary "claims authenticity" "response text" "$(evaluate_as dev | jq -r '.status | test("authentic|attested|verified|signed|receipt")')" false

header "9. C3a boundaries still hold"
P=/var/lib/agent-md/projects/$PID
row agentmd-runner issuer.key read "DAC 0600 agentmd" "$(try sudo -u agentmd-runner cat /var/lib/agent-md/keys/issuer.key)" denied
row dev issuer.key read "DAC 0700 dir" "$(try sudo -u dev cat /var/lib/agent-md/keys/issuer.key)" denied
row agentmd-runner enrollment.json overwrite "DAC agentmd-owned" "$(try sudo -u agentmd-runner bash -c "echo x > $P/enrollment.json")" denied
row dev enrollment.json overwrite "DAC agentmd-owned" "$(try sudo -u dev bash -c "echo x > $P/enrollment.json")" denied
row dev run-check "replace script" "DAC root-owned" "$(try sudo -u dev bash -c "echo x > $LIB/run-check")" denied
prepare test
CUR=$(cat "$P/current-run"); SNAPDIR="$P/runs/$CUR/snapshot/src"
row dev snapshot "overwrite file" "DAC sealed 0444" "$(try sudo -u dev bash -c "echo x > $SNAPDIR/marker.txt")" denied
row agentmd-runner snapshot "overwrite file" "DAC sealed 0444" "$(try sudo -u agentmd-runner bash -c "echo x > $SNAPDIR/marker.txt")" denied
row agentmd-runner snapshot "create file" "DAC sealed 0555" "$(try sudo -u agentmd-runner bash -c "echo x > $SNAPDIR/newfile")" denied
row agentmd-runner snapshot "read file" "DAC 0444" "$(try sudo -u agentmd-runner cat "$SNAPDIR/marker.txt")" allowed

header "10. dev against a live runner process"
install -o dev -g dev -m 0644 /it/slow.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
prepare lint
( run_job lint > /tmp/smoke.code ) & BG=$!
TARGET=""
for _ in $(seq 1 60); do TARGET=$(pgrep -u agentmd-runner -x sleep | head -1); [ -n "$TARGET" ] && break; sleep 0.2; done
echo "target pid=${TARGET:-none} owner=$(ps -o user= -p "${TARGET:-1}" 2>/dev/null)"
if [ -n "$TARGET" ]; then
  row dev "runner check" "kill -TERM" "DAC signal uid check" "$(try sudo -u dev kill -TERM "$TARGET")" denied
  row dev "runner check" "kill -KILL" "DAC signal uid check" "$(try sudo -u dev kill -KILL "$TARGET")" denied
  row dev "runner check" "alive after signals" "liveness" "$(kill -0 "$TARGET" 2>/dev/null && printf alive || printf dead)" alive
  ROOTA=$(timeout 3 strace -p "$TARGET" -e trace=none 2>&1 | grep -c attached || true)
  row root "runner check" "ptrace (sandbox control)" "CAP_SYS_PTRACE" "$([ "$ROOTA" -gt 0 ] && printf allowed || printf denied)" allowed
  DEVA=$(sudo -u dev timeout 3 strace -p "$TARGET" -e trace=none 2>&1)
  row dev "runner check" "ptrace attach" "DAC uid + Yama" "$(printf '%s' "$DEVA" | grep -q attached && printf allowed || printf denied)" denied
  echo "   dev ptrace said: $(printf '%s' "$DEVA" | head -1)"
else
  skip dev "runner check" "kill / ptrace" "DAC uid" "no runner pid"
fi
wait "$BG"
install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml

echo
echo "PASS=$PASS FAIL=$FAIL NOT_EXERCISED=$SKIP"
[ "$FAIL" -eq 0 ]
MATRIX

chmod +x "$PAYLOAD"/*.sh
docker run --rm \
  --cap-add=SYS_PTRACE --security-opt seccomp=unconfined \
  -v "$ROOT_DIR/examples/local-issuer:/src:ro" \
  -v "$PAYLOAD:/it:ro" \
  "$IMAGE" bash -c '/it/setup.sh && /it/matrix.sh'
