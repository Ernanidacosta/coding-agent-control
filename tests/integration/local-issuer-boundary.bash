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
test = "cat marker.txt"
lint = "sleep 3; cat marker.txt"
smoke = "sleep 60"
integration = "python3 -c 'import site; print(site.ENABLE_USER_SITE)'"
runtime = "exit 7"
typecheck = "exit 125"

[verify.policy]
required = ["test"]
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

echo "UIDS: dev=$(id -u dev) agentmd=$(id -u agentmd) agentmd-runner=$(id -u agentmd-runner)"
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

row() { # attacker target operation control actual expected
  local verdict="FAIL"
  if [ "$5" = "$6" ]; then verdict="PASS"; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
  printf '%-14s | %-21s | %-27s | %-23s | %-11s | %-11s | %s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$verdict"
}
skip() { # attacker target operation control reason
  SKIP=$((SKIP+1))
  printf '%-14s | %-21s | %-27s | %-23s | %-11s | %-11s | NOT EXERCISED (%s)\n' "$1" "$2" "$3" "$4" "-" "-" "$5"
}
try() { if "$@" >/dev/null 2>&1; then printf allowed; else printf denied; fi; }
header() {
  echo; echo "== $1"
  printf '%-14s | %-21s | %-27s | %-23s | %-11s | %-11s | %s\n' \
    ATTACKER TARGET OPERATION CONTROL ACTUAL EXPECTED VERDICT
}

enroll_project() {
  rm -rf /var/lib/agent-md/projects/* /var/lib/agent-md/snapshots/* 2>/dev/null
  sudo -u agentmd "$LIB/agent-md-authority" enroll /home/dev/repo --exec-user dev --yes >/dev/null 2>&1
  PID=$(sudo -u agentmd "$LIB/agent-md-authority" show --workspace /home/dev/repo 2>/dev/null | awk '/^project id:/{print $3}')
  [ -n "$PID" ] || return 1
  "$LIB/agent-md-authority" sudoers "$PID" --write >/dev/null
  chmod 0440 "/etc/sudoers.d/agent-md-$PID"
}
prepare() { sudo -u agentmd "$LIB/agent-md-authority" prepare-job "$PID" --check "$1" >/dev/null 2>&1; }
run_job() { sudo -u agentmd sudo -n -u agentmd-runner "$LIB/run-check" "$PID" >/tmp/rc.out 2>/tmp/rc.err; echo $?; }

echo "=== ENROLL + SUDOERS + SNAPSHOT ==="
enroll_project || { echo "ABORT: enrollment failed"; exit 1; }
visudo -cf "/etc/sudoers.d/agent-md-$PID"
visudo -c >/dev/null && echo "global sudoers: valid"
grep -Ev '^(#|$)' "/etc/sudoers.d/agent-md-$PID"
prepare test || { echo "ABORT: prepare-job failed"; exit 1; }
SNAP=/var/lib/agent-md/snapshots/$PID/src
echo "job execution: $(jq -c '{execution,developer}' /var/lib/agent-md/projects/$PID/job.json)"

header "1. sudo capability boundary"
row agentmd root "sudo RunAs root" "sudoers RunAs" "$(try sudo -u agentmd sudo -n -u root id)" denied
row agentmd dev "sudo RunAs dev" "sudoers RunAs" "$(try sudo -u agentmd sudo -n -u dev id)" denied
row agentmd agentmd-runner "arbitrary command" "sudoers Cmnd_Alias" "$(try sudo -u agentmd sudo -n -u agentmd-runner /bin/id)" denied
row agentmd agentmd-runner "run-check other id" "sudoers literal arg" "$(try sudo -u agentmd sudo -n -u agentmd-runner "$LIB/run-check" 00000000-0000-0000-0000-000000000000)" denied
row agentmd agentmd-runner "run-check extra arg" "sudoers literal arg" "$(try sudo -u agentmd sudo -n -u agentmd-runner "$LIB/run-check" "$PID" --root /tmp)" denied
row agentmd-runner any "sudo -l" "sudoers" "$(try sudo -u agentmd-runner sudo -n -l)" denied
row dev agentmd "sudo RunAs agentmd" "no entry hop yet" "$(try sudo -u dev sudo -n -u agentmd id)" denied
row policy descriptors "closefrom_override" "sudoers text" "$(grep -q closefrom_override "/etc/sudoers.d/agent-md-$PID" && printf present || printf absent)" absent

CODE=$(run_job)
RAN=no; [ "$(tr -d '\n' < /tmp/rc.out)" = ORIGINAL ] && RAN=yes
row agentmd agentmd-runner "run-check exact id" "sudoers literal arg" "$([ "$CODE" = 0 ] && printf allowed || printf denied)" allowed
row runner-child snapshot "read approved source" "execution" "$(tr -d '\n' < /tmp/rc.out)" ORIGINAL

header "2. key, state and authority files"
P=/var/lib/agent-md/projects/$PID
row agentmd-runner issuer.key read "DAC 0600 agentmd" "$(try sudo -u agentmd-runner cat /var/lib/agent-md/keys/issuer.key)" denied
row agentmd-runner keys/ list "DAC 0700 agentmd" "$(try sudo -u agentmd-runner ls /var/lib/agent-md/keys)" denied
row dev issuer.key read "DAC 0700 dir" "$(try sudo -u dev cat /var/lib/agent-md/keys/issuer.key)" denied
row agentmd-runner enrollment.json overwrite "DAC agentmd-owned" "$(try sudo -u agentmd-runner bash -c "echo x > $P/enrollment.json")" denied
row agentmd-runner state.json overwrite "DAC agentmd-owned" "$(try sudo -u agentmd-runner bash -c "echo x > $P/state.json")" denied
row agentmd-runner state.json "unlink via parent" "DAC parent dir" "$(try sudo -u agentmd-runner rm "$P/state.json")" denied
row agentmd-runner state.json "rename via parent" "DAC parent dir" "$(try sudo -u agentmd-runner mv "$P/state.json" /tmp/stolen)" denied
row agentmd-runner job.json replace "DAC parent dir" "$(try sudo -u agentmd-runner cp /tmp/rc.out "$P/job.json")" denied
row agentmd-runner projects/ "symlink attack" "DAC parent dir" "$(try sudo -u agentmd-runner ln -s /etc/shadow /var/lib/agent-md/projects/evil)" denied
row dev enrollment.json overwrite "DAC agentmd-owned" "$(try sudo -u dev bash -c "echo x > $P/enrollment.json")" denied
row dev state.json "unlink via parent" "DAC parent dir" "$(try sudo -u dev rm "$P/state.json")" denied
row dev run-check "replace script" "DAC root-owned" "$(try sudo -u dev bash -c "echo x > $LIB/run-check")" denied
row dev authority-lib.sh "replace library" "DAC root-owned" "$(try sudo -u dev bash -c "echo x > $LIB/authority-lib.sh")" denied
row dev lib/ "plant file" "DAC root-owned dir" "$(try sudo -u dev bash -c "echo x > $LIB/evil")" denied
row all issuer.key integrity "post-attack check" "$([ "$(cat /var/lib/agent-md/keys/issuer.key)" = FAKE-PRIVATE-KEY-SENTINEL ] && printf intact || printf changed)" intact

header "3. snapshot"
row dev snapshot "overwrite file" "DAC sealed 0444" "$(try sudo -u dev bash -c "echo x > $SNAP/marker.txt")" denied
row dev snapshot "unlink via parent" "DAC sealed 0555" "$(try sudo -u dev rm "$SNAP/marker.txt")" denied
row dev snapshot "rename via parent" "DAC sealed 0555" "$(try sudo -u dev mv "$SNAP/marker.txt" "$SNAP/m2")" denied
row agentmd-runner snapshot "overwrite file" "DAC sealed 0444" "$(try sudo -u agentmd-runner bash -c "echo x > $SNAP/marker.txt")" denied
row agentmd-runner snapshot "unlink via parent" "DAC sealed 0555" "$(try sudo -u agentmd-runner rm "$SNAP/marker.txt")" denied
row agentmd-runner snapshot "create file" "DAC sealed 0555" "$(try sudo -u agentmd-runner bash -c "echo x > $SNAP/newfile")" denied
row agentmd-runner snapshot "chmod to writable" "DAC not owner" "$(try sudo -u agentmd-runner chmod 0755 "$SNAP")" denied
row agentmd-runner snapshot "read file" "DAC 0444" "$(try sudo -u agentmd-runner cat "$SNAP/marker.txt")" allowed
row all snapshot integrity "post-attack check" "$([ "$(cat "$SNAP/marker.txt")" = ORIGINAL ] && printf intact || printf changed)" intact

header "4. transient mutation during a real run"
prepare lint
( run_job > /tmp/lint.code ) & BG=$!
sleep 1
sudo -u dev bash -c 'printf "TAMPERED\n" > ~/repo/marker.txt'
LIVE=$(cat /home/dev/repo/marker.txt)
sleep 1
sudo -u dev bash -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'
wait "$BG"
row dev worktree "swap file mid-run" "live copy changed" "$LIVE" TAMPERED
row runner-child snapshot "content observed" "sealed snapshot" "$(tr -d '\n' < /tmp/rc.out)" ORIGINAL
row runner-child "check exit" "returned through sudo" "kernel status" "$(cat /tmp/lint.code)" 0

header "5. dev against a live runner process"
prepare smoke
( run_job > /tmp/smoke.code ) & BG=$!
TARGET=""; OBSERVER=""
for _ in $(seq 1 60); do
  TARGET=$(pgrep -u agentmd-runner -x sleep | head -1)
  [ -n "$TARGET" ] && break
  sleep 0.2
done
OBSERVER=$(pgrep -u agentmd-runner -f "timeout -k" | head -1)
echo "target pid=${TARGET:-none} owner=$(ps -o user= -p "${TARGET:-1}" 2>/dev/null)  observer pid=${OBSERVER:-none} owner=$(ps -o user= -p "${OBSERVER:-1}" 2>/dev/null)"

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
  skip dev "runner check" "kill -TERM" "DAC signal uid check" "no runner pid"
  skip dev "runner check" "kill -KILL" "DAC signal uid check" "no runner pid"
  skip dev "runner check" "ptrace attach" "DAC uid + Yama" "no runner pid"
fi
if [ -n "$OBSERVER" ]; then
  row dev "timeout observer" "kill -KILL" "DAC signal uid check" "$(try sudo -u dev kill -KILL "$OBSERVER")" denied
else
  skip dev "timeout observer" "kill -KILL" "DAC signal uid check" "no observer pid"
fi

# Yama attribution: is a same-uid, non-descendant attach denied here anyway?
sudo -u dev sleep 30 & SELF=""
for _ in $(seq 1 30); do SELF=$(pgrep -u dev -x sleep | head -1); [ -n "$SELF" ] && break; sleep 0.2; done
if [ -n "$SELF" ]; then
  echo "   Yama probe (dev -> dev, non-descendant): $(sudo -u dev timeout 3 strace -p "$SELF" -e trace=none 2>&1 | head -1)"
  kill "$SELF" 2>/dev/null
fi
wait "$BG"
row runner-child "sleep 60, 8s limit" "timeout through sudo" "kernel status" "$(cat /tmp/smoke.code)" 124

header "6. developer HOME, PATH shadowing and Python user-site"
rm -f /tmp/MARKER-*
prepare test; CODE=$(run_job)
row dev "~/.bashrc" "sourced by child" "env -i, ephemeral HOME" "$([ -e /tmp/MARKER-bashrc ] && printf loaded || printf absent)" absent
row dev "~/.profile" "sourced by child" "env -i, ephemeral HOME" "$([ -e /tmp/MARKER-profile ] && printf loaded || printf absent)" absent
row dev "~/.local/bin/cat" "shadow a tool" "approved PATH only" "$([ -e /tmp/MARKER-fakecat ] && printf used || printf unused)" unused
row runner-child output "real cat used" "approved PATH only" "$(tr -d '\n' < /tmp/rc.out)" ORIGINAL
prepare integration; CODE=$(run_job)
row dev usercustomize.py "loaded by runner python" "HOME + PYTHONNOUSERSITE" "$([ -e /tmp/MARKER-usersite ] && printf loaded || printf absent)" absent
row runner-child python3 ENABLE_USER_SITE "PYTHONNOUSERSITE=1" "$(tr -d '\n' < /tmp/rc.out)" False
rm -f /tmp/MARKER-usersite
sudo -u dev -i python3 -c pass >/dev/null 2>&1
row dev usercustomize.py "control: dev's own python" "no policy applied" "$([ -e /tmp/MARKER-usersite ] && printf loaded || printf absent)" loaded

header "7. exit status fidelity through sudo"
prepare runtime; row runner-child "exit 7" "status through sudo" "kernel status" "$(run_job)" 7
prepare typecheck; row runner-child "exit 125" "status through sudo" "kernel status" "$(run_job)" 125
install -o dev -g dev -m 0644 /it/exits.toml /home/dev/repo/agent-md.toml
enroll_project || { echo "ABORT: re-enrollment failed"; exit 1; }
prepare test; row runner-child "exit 0" "status through sudo" "kernel status" "$(run_job)" 0
prepare lint; row runner-child "exit 1" "status through sudo" "kernel status" "$(run_job)" 1
prepare smoke; row runner-child "command not found" "status through sudo" "kernel status" "$(run_job)" 127
prepare integration; row runner-child "killed by SIGKILL" "status through sudo" "kernel status" "$(run_job)" 137

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
