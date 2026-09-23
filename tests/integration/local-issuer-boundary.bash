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

# A contract that stays inside execution long enough for the harness to mutate
# the worktree while a check is demonstrably running. The check reads the file
# under attack, so a snapshot that leaked the live tree would show it.
cat > "$PAYLOAD/mutate.toml" <<'TOML'
[verify]
lint = "cat marker.txt"
test = "cat marker.txt && sleep 5"

[verify.policy]
required = ["lint", "test"]
timeout_seconds = 20
total_timeout_seconds = 120
TOML

# Steered from outside the workspace so the approved contract and the workspace
# identity both stay fixed while the outcome changes.
cat > "$PAYLOAD/flagged.toml" <<'TOML'
[verify]
test = "cat /srv/flag"

[verify.policy]
required = ["test"]
timeout_seconds = 20
total_timeout_seconds = 120
TOML

# Holds inside execution until the harness releases it, so the workspace can be
# changed at a known point rather than raced against. The check cannot mutate
# the developer's tree itself: it runs as the execution account, which has no
# write access there, and that is the correct boundary.
cat > "$PAYLOAD/holdflag.toml" <<'TOML'
[verify]
test = "touch /srv/running; cat /srv/flag || exit 1; while [ -e /srv/hold ]; do sleep 0.2; done; true"

[verify.policy]
required = ["test"]
timeout_seconds = 60
total_timeout_seconds = 180
TOML

cat > "$PAYLOAD/slowflag.toml" <<'TOML'
[verify]
test = "touch /srv/running; cat /srv/flag || exit 1; if [ -e /srv/slow ]; then sleep 40; fi; true"

[verify.policy]
required = ["test"]
timeout_seconds = 60
total_timeout_seconds = 180
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

mkdir -p "$PAYLOAD/hosts"
cp "$ROOT_DIR/.claude/settings.json" "$PAYLOAD/hosts/settings.json"

cat > "$PAYLOAD/setup.sh" <<'SETUP'
#!/bin/bash
# Production layout with three real principals. Runs as root inside the
# container only; nothing here is intended for a host.
set -u
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq jq sudo strace python3 git procps util-linux openssl >/dev/null 2>&1 \
  || { echo "SETUP-FAIL: packages"; exit 1; }

useradd -m -s /bin/bash dev
echo "HOME_MODE_DEFAULT: $(stat -c %a /home/dev)"
# Debian creates homes 0700. The restricted-parent regression below exercises
# that boundary; this fixture is accessible so the full chain can also run.
chmod 0755 /home/dev
useradd -m -s /bin/bash dev2
chmod 0755 /home/dev2

# The installation is performed by the program that ships it, on a host where
# neither service account exists yet. Provisioning them by hand here would have
# hidden the fact that install did not create them, which is exactly the defect
# this harness is meant to catch.
bash /src/agent-md-authority install >/tmp/install.log 2>&1 \
  || { echo "SETUP-FAIL: authority install"; cat /tmp/install.log; exit 1; }
grep -q 'created execution account agentmd-runner' /tmp/install.log \
  || { echo "SETUP-FAIL: install did not create the execution account"; cat /tmp/install.log; exit 1; }
getent passwd agentmd >/dev/null || { echo "SETUP-FAIL: no agentmd"; exit 1; }
getent passwd agentmd-runner >/dev/null || { echo "SETUP-FAIL: no agentmd-runner"; exit 1; }
# Trigger files for the state-machine rows. They sit outside every workspace on
# purpose: steering an outcome must not change the workspace identity.
install -d -o root -g root -m 0777 /srv
# A real issuer key, created the way an operator creates one. Earlier rounds
# planted a sentinel file here; a sentinel proves the directory permissions but
# not that the program that creates a key leaves it in the state it claims.
/usr/local/lib/agent-md/agent-md-authority install-key >/dev/null
KEY_ID=$(cat /var/lib/agent-md/keys/current)
PRIV=/var/lib/agent-md/keys/issuer-$KEY_ID.key
PUB=/var/lib/agent-md/keys/issuer-$KEY_ID.pub
KEY_DIGEST=$(sha256sum "$PRIV" | cut -d' ' -f1)

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

# The key setup.sh installed. Derived here rather than inherited: matrix.sh is
# a separate process and an unbound variable would silently blank a row.
KEY_ID=$(cat /var/lib/agent-md/keys/current)
PRIV=/var/lib/agent-md/keys/issuer-$KEY_ID.key
PUB=/var/lib/agent-md/keys/issuer-$KEY_ID.pub
KEY_DIGEST=$(sha256sum "$PRIV" | cut -d' ' -f1)

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
  "$LIB/agent-md-authority" enroll /home/dev/repo --exec-user dev --yes >/tmp/enroll.log 2>&1 \
    || { cat /tmp/enroll.log; return 1; }
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
prepare() { sudo -u agentmd "$LIB/agent-md-authority" prepare-run "$PID" --check "$1" >/dev/null 2>/tmp/prep.err; }
run_job() { sudo -u agentmd sudo -n -u agentmd-runner "$LIB/run-check" "$PID" "$1" >/tmp/rc.out 2>/tmp/rc.err; echo $?; }

header "0a. inaccessible workspace parents"
install -d -o dev -g dev -m 0700 /home/dev/private
cp -a /home/dev/repo /home/dev/private/repo
BEFORE=$(stat -c '%U:%G:%a' /home/dev/private /home/dev/private/repo)
"$LIB/agent-md-authority" enroll /home/dev/private/repo --exec-user dev --yes >/tmp/private-enroll.log 2>&1
PRIVATE_ID=$("$LIB/agent-md-authority" show --workspace /home/dev/private/repo | awk '/^project id:/{print $3}')
PRIVATE_RECORD=/var/lib/agent-md/projects/$PRIVATE_ID/enrollment.json
row root "private parent" "enrollment eligibility" "runtime traversal" \
  "$(jq -r .status "$PRIVATE_RECORD")" ineligible
for PRINCIPAL in agentmd agentmd-runner; do
  row "$PRINCIPAL" "private parent" "diagnostic names account" "runtime traversal" \
    "$(jq -r --arg user "$PRINCIPAL" 'any(.reasons[]; startswith($user + " cannot traverse workspace"))' "$PRIVATE_RECORD")" true
done
row root workspace "permissions left intact" "no automatic chmod or ACL" \
  "$(stat -c '%U:%G:%a' /home/dev/private /home/dev/private/repo)" "$BEFORE"

header "0b. ownership failure cannot publish enrollment"
cp -a /home/dev/repo /home/dev/chown-failure
BEFORE=$(find /var/lib/agent-md/projects -name enrollment.json | wc -l)
(
  chown() { return 1; }
  export -f chown
  bash "$LIB/agent-md-authority" enroll /home/dev/chown-failure --exec-user dev --yes
) >/tmp/chown-failure.log 2>&1
CHOWN_STATUS=$?
row root chown "failure exit" "fail closed" "$CHOWN_STATUS" 1
row root enrollment "no success announcement" "fail closed" \
  "$(grep -c '^enrolled ' /tmp/chown-failure.log)" 0
row root enrollment "no published record" "fail closed" \
  "$(find /var/lib/agent-md/projects -name enrollment.json | wc -l)" "$BEFORE"
row root enrollment "explicit ownership error" "fail closed" \
  "$(grep -c 'cannot assign enrollment ownership to agentmd' /tmp/chown-failure.log)" 1

header "0c. direct authority enrollment and state migration"
cp -a /home/dev/repo /home/dev/service-repo
row agentmd enrollment "direct service caller" "supported enrollment" \
  "$(try sudo -u agentmd "$LIB/agent-md-authority" enroll /home/dev/service-repo --exec-user dev --yes)" allowed
SERVICE_ID=$("$LIB/agent-md-authority" show --workspace /home/dev/service-repo | awk '/^project id:/{print $3}')
SERVICE_PROJECT=/var/lib/agent-md/projects/$SERVICE_ID
for ARTIFACT in "$SERVICE_PROJECT" "$SERVICE_PROJECT/enrollment.json" "$SERVICE_PROJECT/state.json"; do
  row agentmd "${ARTIFACT##*/}" owner "authority custody" \
    "$(stat -c %U:%G "$ARTIFACT")" agentmd:agentmd
done
row agentmd enrollment eligible "accessible workspace" \
  "$(jq -r .status "$SERVICE_PROJECT/enrollment.json")" eligible
sudo -u agentmd bash -c '
  . "$1/authority-lib.sh"
  state=$(authority_state_read "$2") || exit 1
  jq ".schema = 2 | .scopes.worktree.next_sequence = 42 | .scopes.staged.next_sequence = 9" <<<"$state" > "$3/state.json"
' _ "$LIB" "$SERVICE_ID" "$SERVICE_PROJECT"
BEFORE=$(sha256sum "$SERVICE_PROJECT/state.json" "$SERVICE_PROJECT/enrollment.json")
row root enrollment "duplicate refused" "preserve sequence state" \
  "$(try "$LIB/agent-md-authority" enroll /home/dev/service-repo --exec-user dev --yes)" denied
row root state "duplicate keeps exact bytes" "preserve sequence state" \
  "$(sha256sum "$SERVICE_PROJECT/state.json" "$SERVICE_PROJECT/enrollment.json")" "$BEFORE"
row agentmd state "migrate and persist" "authority write access" \
  "$(try sudo -u agentmd bash -c '. "$1/authority-lib.sh"; state=$(authority_state_read "$2") && authority_state_write "$2" "$state"' _ "$LIB" "$SERVICE_ID")" allowed
row agentmd state "migration keeps sequences" "no reset" \
  "$(jq -c '[.schema, .scopes.worktree.next_sequence, .scopes.staged.next_sequence]' "$SERVICE_PROJECT/state.json")" '[3,42,9]'

echo "=== ENROLL + SUDOERS ==="
enroll_project || { echo "ABORT: enrollment failed"; exit 1; }
header "0. root enrollment leaves authority-owned state"
PROJECT=/var/lib/agent-md/projects/$PID
for ARTIFACT in "$PROJECT" "$PROJECT/enrollment.json" "$PROJECT/state.json"; do
  row root "${ARTIFACT##*/}" owner "enroll normalizes owner" \
    "$(stat -c %U:%G "$ARTIFACT")" agentmd:agentmd
done
row root project mode "enroll permissions" "$(stat -c %a "$PROJECT")" 755
for ARTIFACT in enrollment.json state.json; do
  row root "$ARTIFACT" mode "enroll permissions" "$(stat -c %a "$PROJECT/$ARTIFACT")" 644
done
row agentmd state.json "atomic state update" "authority write access" \
  "$(try sudo -u agentmd bash -c '. "$1/authority-lib.sh"; state=$(authority_state_read "$2") && authority_state_write "$2" "$state"' _ "$LIB" "$PID")" allowed
row root workspace owner "developer custody" "$(stat -c %U:%G /home/dev/repo)" dev:dev
for PRINCIPAL in dev agentmd-runner; do
  row "$PRINCIPAL" project "create file" "no project-store write" \
    "$(try sudo -u "$PRINCIPAL" touch "$PROJECT/unauthorized")" denied
done
[ "$FAIL" -eq 0 ] || { echo "ABORT: root enrollment regression"; exit 1; }
visudo -cf "/etc/sudoers.d/agent-md-$PID"
visudo -c >/dev/null && echo "global sudoers: valid"
grep -Ev '^(#|$)' "/etc/sudoers.d/agent-md-$PID"

header "0e. workspace identity larger than one exec argument"
sudo -u dev python3 - <<'PY'
from pathlib import Path
bulk = Path('/home/dev/repo/identity-bulk')
bulk.mkdir()
for i in range(400):
    (bulk / f'{i}-{"0" * 200}.txt').write_text('same content\n')
PY
sudo -u agentmd sudo -n -u agentmd-runner "$LIB/agent-md-authority" identity "$PID" \
  > /tmp/large-identity.json 2>/tmp/large-identity.err
row agentmd runner "large identity hop exit" "file transport" "$?" 0
jq -c .source /tmp/large-identity.json > /tmp/large-source.json
LARGE_SIZE=$(wc -c < /tmp/large-source.json)
echo "source manifest bytes=$LARGE_SIZE ARG_MAX=$(getconf ARG_MAX) PAGESIZE=$(getconf PAGESIZE)"
row root manifest "exceeds single argv limit" "large fixture" "$([ "$LARGE_SIZE" -gt 131072 ] && echo yes || echo no)" yes
bash -c 'jq -nc --argjson source "$(cat /tmp/large-source.json)" "$1"' _ '{source:$source}' \
  >/tmp/old-identity.out 2>/tmp/old-identity.err
row root "old transport" "exec rejects manifest" "ARG_MAX regression" "$?" 126
row root "old transport" "E2BIG diagnostic" "ARG_MAX regression" \
  "$(grep -c 'Argument list too long' /tmp/old-identity.err)" 1
LARGE_EV=$(evaluate_as dev); LARGE_RC=$?
row dev issuer "large evaluation exit" "full chain" "$LARGE_RC" 0
row dev issuer "large evaluation result" "full chain" "$(jq -r .status <<<"$LARGE_EV")" authenticated_pass
sudo -u dev "$LIB/receipt-verify.sh" /home/dev/repo worktree >/tmp/large-validation.json 2>/tmp/large-validation.err
row dev validator "large live identity exit" "file transport" "$?" 0
row dev validator "large receipt reusable" "exact fingerprints" "$(jq -r .status /tmp/large-validation.json)" reusable_ordinary
row root temporaries "identity directories remain" "cleanup" \
  "$(find /tmp -maxdepth 1 -name 'agent-md-identity-parts.*' | wc -l)" 0
sudo -u dev rm -rf /home/dev/repo/identity-bulk

echo
echo "=== FULL CHAIN: dev -> agentmd -> agentmd-runner ==="
EV=$(evaluate_as dev); EVCODE=$?
printf '%s\n' "$EV" | jq -c '{status,run_id,checks:[.checks[]|{name,exit_code,execution}],budget}' 2>/dev/null || { echo "ABORT: evaluate produced no object"; cat /tmp/ev.err; exit 1; }
# A refusal here is a setup failure, not a boundary result. Say why: the whole
# matrix below is meaningless if the chain never ran.
if [ "$(printf '%s' "$EV" | jq -r .status 2>/dev/null)" = refused ]; then
  echo "ABORT: the chain refused before any boundary was exercised"
  printf '%s\n' "$EV" | jq -r '"  reason: " + (.reason // "none") + "\n  code: " + ((.code // "none")|tostring)' 2>/dev/null
  printf '%s\n' "$EV" | jq . 2>/dev/null | head -40
  cat /tmp/ev.err
  exit 1
fi
prepare test || { echo "ABORT: prepare failed"; cat /tmp/prep.err; exit 1; }
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
row dev repo "whitespace edit" "canonical contract" "$(evaluate_as dev | jq -r .status)" authenticated_pass
row dev repo "caller after repo edit" "boundary-derived caller" "$(evaluate_as dev | jq -r .caller.user)" dev
sudo -u dev bash -c 'truncate -s -1 ~/repo/agent-md.toml'
# Changing what a check actually runs is the change approval exists to catch.
sudo -u dev sed -i 's|^lint = .*|lint = "true"|' /home/dev/repo/agent-md.toml
row dev repo "semantic contract change" "approved fingerprint" "$(evaluate_as dev | jq -r .reason_code)" REFUSED_CONTRACT_CHANGED
sudo -u dev sed -i 's|^lint = .*|lint = "cat marker.txt"|' /home/dev/repo/agent-md.toml
row dev repo "restored contract" "approved fingerprint" "$(evaluate_as dev | jq -r .status)" authenticated_pass

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
row dev evaluation "all required pass" "orchestration" "$(evaluate_as dev | jq -r .status)" authenticated_pass
# The mutation must land while a check is executing, which is the only window
# the sealed snapshot claims to cover. An earlier version slept one second and
# hoped; once identity computation grew a hop it began landing inside the
# before/after bracket instead, where a refusal is the correct answer and the
# row was measuring preparation rather than execution.
#
# The trigger is now the runner's own process: nothing is mutated until a check
# is demonstrably running as agentmd-runner.
install -o dev -g dev -m 0644 /it/mutate.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
MUT_OUT=$(mktemp)
( evaluate_as dev > "$MUT_OUT" ) & MUT_BG=$!
MUT_SEEN=no
for _ in $(seq 1 200); do
  if pgrep -u agentmd-runner -x sleep >/dev/null 2>&1; then MUT_SEEN=yes; break; fi
  sleep 0.1
done
if [ "$MUT_SEEN" = yes ]; then
  sudo -u dev bash -c 'printf "TAMPERED\n" > ~/repo/marker.txt'
fi
wait "$MUT_BG"
if [ "$MUT_SEEN" = yes ]; then
  # Two separate properties, and both must hold.
  #
  # The snapshot property is the exit code below: the check read the bytes as
  # they were when the run was captured, not the mutated ones, so the mutation
  # could not influence the result.
  #
  # The status is identity_changed from C4b onwards. The checks completed, but
  # the workspace no longer matches what they ran against, so the authority
  # concludes a terminal result that supersedes the previous one and publishes
  # nothing. Before C4b there was no revalidation and this read candidate_pass;
  # refusing to publish is the stricter answer, not a weaker one.
  row dev evaluation "worktree mutated mid-run" "pre-terminal revalidation" "$(jq -r .status < "$MUT_OUT")" identity_changed
  row dev "check output" "read the pre-mutation bytes" "sealed snapshot" \
    "$(jq -r '[.checks[]|select(.name=="test")|.exit_code]|first' < "$MUT_OUT")" 0
else
  skip dev evaluation "worktree mutated mid-run" "sealed snapshot" "no runner check was observed executing"
fi
rm -f "$MUT_OUT"
sudo -u dev bash -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'
install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
install -o dev -g dev -m 0644 /it/failing.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
row dev evaluation "required check fails" "orchestration" "$(evaluate_as dev | jq -r .status)" authenticated_fail
install -o dev -g dev -m 0644 /it/slow.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
row dev evaluation "budget exhausted" "never a candidate pass" "$(evaluate_as dev | jq -r .status)" refused
install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null

header "8. what stays out of reach"
# This section used to claim sequence allocation was absent, which stopped
# being true at C4b, and signing, which stopped being true at C4c. What it
# pins now is the surface that must stay closed: no way to ask for a
# signature, no key use outside the one signing step, and an execution
# boundary that still knows nothing about either.
row issuer "signing oracle" "--sign / sign-receipt" "source inspection" "$(grep -qE -- '--sign|sign-receipt|sign-run|receipt-from-run' "$LIB/agent-md-issuer" "$LIB/agent-md-authority" && printf present || printf absent)" absent
row authority "signing entry point" "signs on request" "source inspection" "$(grep -qE 'pkeyutl -sign' "$LIB/agent-md-authority" && printf present || printf absent)" absent
row run-check "key or receipt" "any use at all" "source inspection" "$(grep -qE 'pkeyutl|issuer-.*\.key|publish_receipt|trusted-keys' "$LIB/run-check" && printf present || printf absent)" absent
row run-check "authority state" "reads or writes it" "source inspection" "$(grep -qE 'state\.json|next_sequence|last_terminal' "$LIB/run-check" && printf present || printf absent)" absent
row lib "private key open sites" "how many" "source inspection" "$(grep -c 'pkeyutl -sign' "$LIB/authority-lib.sh")" 1
row agentmd "private key" "unchanged by signing" "post-run check" "$([ "$(sha256sum "$PRIV" | cut -d' ' -f1)" = "$KEY_DIGEST" ] && printf intact || printf changed)" intact

header "8b. issuer key custody, real accounts"
row dev "keys dir" "list" "DAC 0700 agentmd" "$(try sudo -u dev ls /var/lib/agent-md/keys)" denied
row agentmd-runner "keys dir" "list" "DAC 0700 agentmd" "$(try sudo -u agentmd-runner ls /var/lib/agent-md/keys)" denied
row dev "keys dir" "traverse to a known name" "DAC 0700 agentmd" "$(try sudo -u dev cat "$PUB")" denied
row agentmd-runner "keys dir" "traverse to a known name" "DAC 0700 agentmd" "$(try sudo -u agentmd-runner cat "$PUB")" denied
row dev "keys dir" "create a key" "DAC 0700 agentmd" "$(try sudo -u dev bash -c "echo x > /var/lib/agent-md/keys/issuer-evil.key")" denied
row agentmd-runner "current" "repoint to another key" "DAC 0700 agentmd" "$(try sudo -u agentmd-runner bash -c "echo evil > /var/lib/agent-md/keys/current")" denied
row dev "current" "repoint to another key" "DAC 0700 agentmd" "$(try sudo -u dev bash -c "echo evil > /var/lib/agent-md/keys/current")" denied
row dev "install-key" "run it as the developer" "sudoers Cmnd_Alias" "$(try sudo -u dev sudo -n -u agentmd /usr/local/lib/agent-md/agent-md-authority install-key)" denied
row root "private key" "mode on disk" "install-key" "$(stat -c %a "$PRIV")" 600
row root "private key" "owner on disk" "install-key" "$(stat -c %U "$PRIV")" agentmd
row root "keys dir" "mode on disk" "install" "$(stat -c %a /var/lib/agent-md/keys)" 700
row root "key id" "full sha256 of DER SPKI" "install-key" "$(openssl pkey -pubin -in "$PUB" -outform DER | sha256sum | cut -d' ' -f1)" "$KEY_ID"
row root "install-key" "repeat does not regenerate" "idempotence" "$(/usr/local/lib/agent-md/agent-md-authority install-key >/dev/null 2>&1; sha256sum "$PRIV" | cut -d' ' -f1)" "$KEY_DIGEST"
row root "install-key" "repeat creates no second key" "idempotence" "$(ls /var/lib/agent-md/keys/issuer-*.key | wc -l)" 1
row root "rotate-key" "rotates automatically" "explicit refusal" "$(/usr/local/lib/agent-md/agent-md-authority rotate-key >/dev/null 2>&1 && printf rotated || printf refused)" refused
row root "current" "unchanged after rotate-key" "explicit refusal" "$(cat /var/lib/agent-md/keys/current)" "$KEY_ID"
row runner-env "private key" "reachable from a check" "env isolation" "$(sudo -u agentmd-runner env | grep -ciE 'issuer.*key|PRIVATE' || true)" 0
# The key must not have been copied into anything the runner can read. These
# grep the real artefacts of the run that just executed, not the source.
RUNDIR=/var/lib/agent-md/projects/$PID/runs/$(cat "/var/lib/agent-md/projects/$PID/current-run")
row root "run artefacts" "contain key material" "custody" "$(grep -rlF "$(sed -n 2p "$PRIV")" "$RUNDIR" 2>/dev/null | wc -l)" 0
row root "job files" "name the key directory" "custody" "$(grep -rlE 'keys/|issuer-.*\.key' "$RUNDIR/jobs" 2>/dev/null | wc -l)" 0
row root "snapshot" "contains a PEM private key" "custody" "$(grep -rlF 'BEGIN PRIVATE KEY' "$RUNDIR/snapshot" 2>/dev/null | wc -l)" 0

header "8c. evaluation state machine, real accounts"
STATE=/var/lib/agent-md/projects/$PID/state.json
row root "state" "schema on disk" "C4b state machine" "$(jq -r .schema "$STATE")" 3
row root "state" "owner" "authority-owned" "$(stat -c %U "$STATE")" agentmd
row root "state" "mode" "not world-writable" "$(stat -c %a "$STATE")" 644
row dev "state" "write" "DAC agentmd-owned" "$(try sudo -u dev bash -c "echo x > $STATE")" denied
row agentmd-runner "state" "write" "DAC agentmd-owned" "$(try sudo -u agentmd-runner bash -c "echo x > $STATE")" denied
row dev "state" "replace via the project dir" "DAC sealed 0555" "$(try sudo -u dev bash -c "echo x > /var/lib/agent-md/projects/$PID/state.json.new")" denied
row agentmd-runner "evaluation lock" "write" "DAC agentmd-owned" "$(try sudo -u agentmd-runner bash -c "echo x > /var/lib/agent-md/projects/$PID/.evaluation.lock")" denied

# PASS then FAIL through the whole chain, with real accounts and a real lock.
SEQ_BEFORE=$(jq -r '.scopes.worktree.next_sequence' "$STATE")
install -o dev -g dev -m 0644 /it/flagged.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
STATE=/var/lib/agent-md/projects/$PID/state.json
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
row dev evaluation "flag present" "orchestration" "$(evaluate_as dev | jq -r .status)" authenticated_pass
PASS_SEQ=$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")
row root "state" "pass is the terminal" "C4b state machine" "$(jq -r '.scopes.worktree.last_terminal.status' "$STATE")" candidate_pass
rm -f /srv/flag
row dev evaluation "flag removed" "orchestration" "$(evaluate_as dev | jq -r .status)" authenticated_fail
FAIL_SEQ=$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")
row root "state" "fail supersedes the pass" "C4b state machine" "$(jq -r '.scopes.worktree.last_terminal.status' "$STATE")" candidate_fail
row root "sequence" "fail is later than the pass" "monotonicity" "$([ "$FAIL_SEQ" -gt "$PASS_SEQ" ] && printf later || printf "not-later")" later
row root "pending" "cleared after a terminal" "C4b state machine" "$(jq -r '.scopes.worktree.pending | type' "$STATE")" null

# kill -9 during a check must leave the pending, and the previous terminal
# must stay suppressed until a later evaluation takes the reservation over.
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
install -o dev -g dev -m 0644 /it/slowflag.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
STATE=/var/lib/agent-md/projects/$PID/state.json
evaluate_as dev >/dev/null
BEFORE_KILL_SEQ=$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")
rm -f /srv/running
touch /srv/slow
( evaluate_as dev >/dev/null 2>&1 ) & EVBG=$!
for _ in $(seq 1 300); do [ -e /srv/running ] && break; sleep 0.1; done
EVPG=$(ps -o pgid= -p "$EVBG" 2>/dev/null | tr -d ' ')
[ -n "$EVPG" ] && kill -9 -"$EVPG" 2>/dev/null
kill -9 "$EVBG" 2>/dev/null; wait "$EVBG" 2>/dev/null
row root "pending" "survives kill -9" "crash consistency" "$(jq -r '.scopes.worktree.pending | type' "$STATE")" object
ABANDONED=$(jq -r '.scopes.worktree.pending.sequence' "$STATE")
row root "previous terminal" "still suppressed by the pending" "crash consistency" "$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")" "$BEFORE_KILL_SEQ"

# The lock must be free again: the killed tree may not keep holding it.
rm -f /srv/slow
row dev evaluation "recovers after the crash" "lock released on death" "$(evaluate_as dev | jq -r .status)" authenticated_pass
RECOVERED=$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")
row root "sequence" "abandoned number never reused" "monotonicity" "$([ "$RECOVERED" -gt "$ABANDONED" ] && printf later || printf reused)" later
row root "pending" "resolved by the recovery" "crash consistency" "$(jq -r '.scopes.worktree.pending | type' "$STATE")" null

# A second evaluation while one holds the lock must reserve nothing.
rm -f /srv/running; touch /srv/slow
( evaluate_as dev >/dev/null 2>&1 ) & EVBG=$!
for _ in $(seq 1 300); do [ -e /srv/running ] && break; sleep 0.1; done
HELD_NEXT=$(jq -r '.scopes.worktree.next_sequence' "$STATE")
CONC=$(evaluate_as dev)
row dev evaluation "concurrent request" "flock, non-blocking" "$(printf '%s' "$CONC" | jq -r .reason_code)" REFUSED_EVALUATION_IN_PROGRESS
row dev evaluation "concurrent reserved nothing" "flock, non-blocking" "$(printf '%s' "$CONC" | jq -r '.sequence | type')" null
row root "next_sequence" "unchanged by the refusal" "flock, non-blocking" "$(jq -r '.scopes.worktree.next_sequence' "$STATE")" "$HELD_NEXT"
EVPG=$(ps -o pgid= -p "$EVBG" 2>/dev/null | tr -d ' ')
[ -n "$EVPG" ] && kill -9 -"$EVPG" 2>/dev/null
kill -9 "$EVBG" 2>/dev/null; wait "$EVBG" 2>/dev/null
rm -f /srv/slow /srv/running

# The state names the key that signed the current receipt; an identifier is
# not material. What must never appear is the key itself.
row root "state" "carries key material" "C4c names, never carries" "$(grep -cE 'BEGIN |PRIVATE|[.]key' "$STATE" || true)" 0
row root "private key" "untouched by the state machine" "C4b holds no key" "$([ "$(sha256sum "$PRIV" | cut -d' ' -f1)" = "$KEY_DIGEST" ] && printf intact || printf changed)" intact

header "8d. authenticated receipts, real accounts"
install -o dev -g dev -m 0644 /it/flagged.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
STATE=/var/lib/agent-md/projects/$PID/state.json
PROJ=/var/lib/agent-md/projects/$PID
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag

EV=$(evaluate_as dev)
row dev evaluation "signed pass" "C4c issuance" "$(printf '%s' "$EV" | jq -r .status)" authenticated_pass
RSEQ=$(printf '%s' "$EV" | jq -r .sequence)
RPATH=$(printf '%s' "$EV" | jq -r .receipt.path)
RKEY=$(jq -r .authentication.key_id "$RPATH" 2>/dev/null)
row root receipt "published at the sequence" "C4c issuance" "$RPATH" "$PROJ/receipts/worktree/$RSEQ.json"
row root receipt "mode on disk" "immutable" "$(stat -c %a "$RPATH")" 444
row root receipt "directory mode" "immutable" "$(stat -c %a "$PROJ/receipts/worktree")" 555
row root receipt "owner" "authority-owned" "$(stat -c %U "$RPATH")" agentmd
row root "trusted key" "published for the project" "C4c issuance" "$(stat -c %a "$PROJ/trusted-keys/$RKEY.pub")" 444
row root "trusted key" "hashes to its own name" "key_id binding" "$(openssl pkey -pubin -in "$PROJ/trusted-keys/$RKEY.pub" -outform DER | sha256sum | cut -d' ' -f1)" "$RKEY"

# The whole point: verifiable by a party that holds only the public key.
CANON=$(mktemp); SIGB=$(mktemp)
jq -cS 'del(.authentication)' "$RPATH" | tr -d '\n' > "$CANON"
jq -r .authentication.value "$RPATH" | base64 -d > "$SIGB"
row anyone receipt "verifies with the public key" "ed25519" "$(openssl pkeyutl -verify -pubin -inkey "$PROJ/trusted-keys/$RKEY.pub" -rawin -in "$CANON" -sigfile "$SIGB" >/dev/null 2>&1 && printf valid || printf invalid)" valid
printf 'x' >> "$CANON"
row anyone "tampered payload" "verifies with the public key" "ed25519" "$(openssl pkeyutl -verify -pubin -inkey "$PROJ/trusted-keys/$RKEY.pub" -rawin -in "$CANON" -sigfile "$SIGB" >/dev/null 2>&1 && printf valid || printf invalid)" invalid
rm -f "$CANON" "$SIGB"

row dev receipt "overwrite" "DAC 0444 in 0555" "$(try sudo -u dev bash -c "echo x > $RPATH")" denied
row agentmd-runner receipt "overwrite" "DAC 0444 in 0555" "$(try sudo -u agentmd-runner bash -c "echo x > $RPATH")" denied
row dev receipt "remove" "DAC 0555 directory" "$(try sudo -u dev rm -f "$RPATH")" denied
row agentmd-runner receipt "remove" "DAC 0555 directory" "$(try sudo -u agentmd-runner rm -f "$RPATH")" denied
row dev "trusted key" "replace" "DAC 0444 in 0555" "$(try sudo -u dev bash -c "echo x > $PROJ/trusted-keys/$RKEY.pub")" denied
row dev receipts "add a receipt of their own" "DAC 0555 directory" "$(try sudo -u dev bash -c "echo x > $PROJ/receipts/worktree/999.json")" denied

# A signed FAIL supersedes a signed PASS.
rm -f /srv/flag
EV2=$(evaluate_as dev)
row dev evaluation "signed fail" "C4c issuance" "$(printf '%s' "$EV2" | jq -r .status)" authenticated_fail
FSEQ=$(printf '%s' "$EV2" | jq -r .sequence)
row root state "latest is the failure" "supersession" "$(jq -r '.scopes.worktree.last_terminal.sequence' "$STATE")" "$FSEQ"
row root "earlier pass receipt" "still on disk and still signed" "history" "$([ -f "$PROJ/receipts/worktree/$RSEQ.json" ] && printf present || printf gone)" present
row root "earlier pass receipt" "is not current" "state decides latest" "$([ "$(jq -r '.scopes.worktree.last_terminal.receipt.path' "$STATE")" = "$PROJ/receipts/worktree/$RSEQ.json" ] && printf current || printf "not-current")" not-current

# identity_changed opens no key and publishes nothing. The workspace is changed
# while a check is demonstrably executing, then the check is released, so the
# divergence is certain rather than raced for.
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
install -o dev -g dev -m 0644 /it/holdflag.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
STATE=/var/lib/agent-md/projects/$PID/state.json
PROJ=/var/lib/agent-md/projects/$PID
rm -f /srv/running; touch /srv/hold
EV3OUT=$(mktemp)
( evaluate_as dev > "$EV3OUT" 2>/dev/null ) & EV3BG=$!
for _ in $(seq 1 600); do [ -e /srv/running ] && break; sleep 0.1; done
sudo -u dev bash -c 'printf "CHANGED\n" >> ~/repo/marker.txt'
rm -f /srv/hold
wait "$EV3BG" 2>/dev/null
EV3=$(cat "$EV3OUT"); rm -f "$EV3OUT"
row dev evaluation "identity changed before signing" "policy B" "$(printf '%s' "$EV3" | jq -r .status)" identity_changed
row root receipt "published for identity_changed" "policy B" "$(printf '%s' "$EV3" | jq -r '.receipt | type')" null
row root receipts "directory created at all" "policy B" "$(ls -A "$PROJ/receipts/worktree" 2>/dev/null | wc -l)" 0
row root "trusted key" "published without signing" "policy B" "$(ls -A "$PROJ/trusted-keys" 2>/dev/null | wc -l)" 0

sudo -u dev bash -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'

header "8e. unprivileged receipt validation, real accounts"
# Everything below runs as the ordinary developer: no sudo, no issuer, and no
# access to the private key directory.
install -o dev -g dev -m 0644 /it/flagged.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
PROJ=/var/lib/agent-md/projects/$PID
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
RV="sudo -u dev $LIB/receipt-verify.sh /home/dev/repo worktree"

row dev "private key dir" "readable at all" "DAC 0700 agentmd" "$(try sudo -u dev ls /var/lib/agent-md/keys)" denied
row dev validator "before any evaluation" "state is source of truth" "$($RV 2>/dev/null | jq -r .status)" no_evidence

evaluate_as dev >/dev/null
RVOUT=$($RV 2>/dev/null); RVRC=$?
row dev validator "after an authenticated pass" "C4d validation" "$(printf '%s' "$RVOUT" | jq -r .status)" reusable_ordinary
row dev validator "exit code for reusable" "only pass is zero" "$RVRC" 0
row dev validator "authentic" "ed25519 under trusted key" "$(printf '%s' "$RVOUT" | jq -r .authentic)" true
row dev validator "current" "state names this receipt" "$(printf '%s' "$RVOUT" | jq -r .current)" true
row dev validator "applicable" "live identity matches" "$(printf '%s' "$RVOUT" | jq -r .applicable)" true
row dev validator "control plane is one object" "stdout discipline" "$($RV 2>/dev/null | jq -s 'length')" 1

# The validator must reach its verdict without any privileged path.
STATE_BEFORE=$(sha256sum "$PROJ/state.json" | cut -d' ' -f1)
$RV >/dev/null 2>&1
row dev validator "mutates authority state" "read-only" "$([ "$(sha256sum "$PROJ/state.json" | cut -d' ' -f1)" = "$STATE_BEFORE" ] && printf no || printf yes)" no

# Source changes make it stale, restoring makes it reusable again.
sudo -u dev bash -c 'printf "MUTATED\n" >> ~/repo/marker.txt'
row dev validator "source changed" "live fingerprint" "$($RV 2>/dev/null | jq -r .status)" stale
row dev validator "still authentic when stale" "authentic != current" "$($RV 2>/dev/null | jq -r .authentic)" true
sudo -u dev bash -c 'printf "ORIGINAL\n" > ~/repo/marker.txt'
row dev validator "source restored" "live fingerprint" "$($RV 2>/dev/null | jq -r .status)" reusable_ordinary

# A newer authenticated failure supersedes the earlier pass.
PASS_SEQ=$(jq -r '.scopes.worktree.last_terminal.sequence' "$PROJ/state.json")
rm -f /srv/flag
evaluate_as dev >/dev/null
row dev validator "after an authenticated failure" "supersession" "$($RV 2>/dev/null | jq -r .status)" current_fail
row root "earlier pass receipt" "still present" "history" "$([ -f "$PROJ/receipts/worktree/$PASS_SEQ.json" ] && printf present || printf gone)" present
row dev validator "earlier pass is not reusable" "state decides latest" "$($RV >/dev/null 2>&1; [ $? -eq 0 ] && printf reusable || printf "not-reusable")" not-reusable

# A pending left by a crash suppresses everything underneath it.
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
evaluate_as dev >/dev/null
row dev validator "recovered to a pass" "C4d validation" "$($RV 2>/dev/null | jq -r .status)" reusable_ordinary
install -o dev -g dev -m 0644 /it/slowflag.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
PROJ=/var/lib/agent-md/projects/$PID
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag
evaluate_as dev >/dev/null
rm -f /srv/running; touch /srv/slow
( evaluate_as dev >/dev/null 2>&1 ) & RVBG=$!
for _ in $(seq 1 600); do [ -e /srv/running ] && break; sleep 0.1; done
RVPG=$(ps -o pgid= -p "$RVBG" 2>/dev/null | tr -d ' ')
[ -n "$RVPG" ] && kill -9 -"$RVPG" 2>/dev/null
kill -9 "$RVBG" 2>/dev/null; wait "$RVBG" 2>/dev/null
rm -f /srv/slow
row dev validator "pending after a crash" "pending suppresses" "$($RV 2>/dev/null | jq -r .status)" unresolved_pending
row dev validator "pending is not reusable" "fail closed" "$($RV >/dev/null 2>&1; [ $? -eq 0 ] && printf reusable || printf "not-reusable")" not-reusable
evaluate_as dev >/dev/null
row dev validator "after recovery" "pending resolved" "$($RV 2>/dev/null | jq -r .status)" reusable_ordinary

# A receipt is bound to its workspace: a copy elsewhere is not evidence.
sudo -u dev cp -r /home/dev/repo /home/dev/clone
row dev validator "a clone at another path" "workspace binding" "$(sudo -u dev $LIB/receipt-verify.sh /home/dev/clone worktree 2>/dev/null | jq -r .status)" no_evidence
sudo -u dev rm -rf /home/dev/clone

row dev validator "calls sudo internally" "unprivileged by construction" "$(grep -vE '^[[:space:]]*#' "$LIB/receipt-verify.sh" | grep -cE '\bsudo\b')" 0
row dev validator "reads the private key" "unprivileged by construction" "$(grep -cE 'keys_dir|authority_private_key_path' "$LIB/receipt-verify.sh")" 0

install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null

header "8f. receipt-first completion, real accounts"
# The developer's repository gets the real hook library and Stop handler, so
# what runs here is the shipped completion path and not a stand-in.
install -d -o dev -g dev -m 0755 /home/dev/repo/.claude/hooks
for f in _lib.sh stop-verify.sh; do
  install -o dev -g dev -m 0755 "/hooks/$f" "/home/dev/repo/.claude/hooks/$f"
done
# The handler refuses to run when the host envelope cannot be read, so the
# settings the installer would have materialized have to be present too.
install -o dev -g dev -m 0644 /hosts/settings.json /home/dev/repo/.claude/settings.json
install -o dev -g dev -m 0644 /it/flagged.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null
PROJ=/var/lib/agent-md/projects/$PID
printf 'ok\n' > /srv/flag; chmod 0644 /srv/flag

# The ordinary contract appends a mark every time it actually executes, so a
# completion that reuses evidence can be told apart from one that re-ran it.
# A boolean would not distinguish "ran once under the authority" from "ran
# again afterwards", which is the invariant that matters here.
cat > /home/dev/repo/agent-md.toml <<'TOML'
[verify]
test = "printf x >> /srv/RUNS; cat /home/dev/repo/gate"

[verify.policy]
required = ["test"]
timeout_seconds = 60
total_timeout_seconds = 300
TOML
chown dev:dev /home/dev/repo/agent-md.toml
sudo -u dev bash -c 'printf "ok\n" > /home/dev/repo/gate'
enroll_project >/dev/null
PROJ=/var/lib/agent-md/projects/$PID

run_stop() {
  sudo -u dev env -i HOME=/home/dev PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c 'cd /home/dev/repo && printf "{}" | bash .claude/hooks/stop-verify.sh' 2>/dev/null
}
run_stop_stderr() {
  sudo -u dev env -i HOME=/home/dev PATH=/usr/local/bin:/usr/bin:/bin \
    bash -c 'cd /home/dev/repo && printf "{}" | bash .claude/hooks/stop-verify.sh' 2>&1 >/dev/null
}
runs() { [ -f /srv/RUNS ] && wc -c < /srv/RUNS | tr -d ' ' || printf 0; }

: > /srv/RUNS; chmod 0666 /srv/RUNS

T0=$(date +%s); OUT1=$(run_stop); T1=$(date +%s)
R1=$(runs)
row dev completion "first run issues a receipt" "authority on miss" \
  "$([ -n "$(ls "$PROJ/receipts/worktree" 2>/dev/null)" ] && printf issued || printf none)" issued
row dev completion "ordinary ran exactly once" "no double verification" "$R1" 1

T2=$(date +%s); OUT2=$(run_stop); T3=$(date +%s)
row dev completion "second run re-runs nothing" "receipt-first" "$(runs)" "$R1"
row dev completion "second run is not slower" "receipt-first" \
  "$([ $(( T3-T2 )) -le $(( T1-T0 )) ] && printf faster || printf slower)" faster
echo "   timing: first=$(( T1-T0 ))s second=$(( T3-T2 ))s"

BEFORE=$(runs)
sudo -u dev bash -c 'printf "CHANGED\n" >> /home/dev/repo/marker.txt'
run_stop >/dev/null
row dev completion "a source change re-evaluates once" "staleness" "$(runs)" "$(( BEFORE + 1 ))"

BEFORE=$(runs)
sudo -u dev bash -c 'printf "" > /home/dev/repo/gate; printf "FAILNOW\n" >> /home/dev/repo/marker.txt'
sudo -u dev bash -c 'mv /home/dev/repo/gate /home/dev/repo/gate.hidden'
OUTF=$(run_stop)
row dev completion "a failure is recorded" "negative evidence" \
  "$(jq -r '.scopes.worktree.last_terminal.status' "$PROJ/state.json")" candidate_fail
row dev completion "the failing run executed once" "no double verification" "$(runs)" "$(( BEFORE + 1 ))"
row dev completion "the failure blocks completion" "non-success preserved" \
  "$(printf '%s' "$OUTF" | jq -r '.decision // "none"')" block

BEFORE=$(runs)
OUTF2=$(run_stop)
row dev completion "a known failure is not re-run" "negative cache" "$(runs)" "$BEFORE"
row dev completion "a known failure still blocks" "non-success preserved" \
  "$(printf '%s' "$OUTF2" | jq -r '.decision // "none"')" block

BEFORE=$(runs)
sudo -u dev bash -c 'mv /home/dev/repo/gate.hidden /home/dev/repo/gate; printf "FIXED\n" >> /home/dev/repo/marker.txt'
run_stop >/dev/null
row dev completion "a fix re-evaluates" "staleness" "$(runs)" "$(( BEFORE + 1 ))"
row dev completion "and passes again" "negative cache cleared" \
  "$(jq -r '.scopes.worktree.last_terminal.status' "$PROJ/state.json")" candidate_pass

CURSEQ=$(jq -r '.scopes.worktree.last_terminal.sequence' "$PROJ/state.json")
chmod u+w "$PROJ/receipts/worktree" "$PROJ/receipts/worktree/$CURSEQ.json"
jq -cS '.authentication.value = "AAAA" + (.authentication.value[4:])' \
  "$PROJ/receipts/worktree/$CURSEQ.json" > /tmp/t.json && mv /tmp/t.json "$PROJ/receipts/worktree/$CURSEQ.json"
chmod 0444 "$PROJ/receipts/worktree/$CURSEQ.json"; chmod 0555 "$PROJ/receipts/worktree"
BEFORE=$(runs)
WARN=$(run_stop_stderr)
row dev completion "a tampered receipt warns" "corruption is visible" \
  "$(printf '%s' "$WARN" | grep -qi 'WARNING' && printf warned || printf silent)" warned
row dev completion "a tampered receipt is never reused" "fail closed" \
  "$([ "$(runs)" -gt "$BEFORE" ] && printf ran-anyway || printf reused)" ran-anyway

mv /usr/local/lib/agent-md/receipt-verify.sh /usr/local/lib/agent-md/receipt-verify.sh.off
BEFORE=$(runs)
run_stop >/dev/null
row dev completion "no validator installed" "legacy fallback" \
  "$([ "$(runs)" -gt "$BEFORE" ] && printf ran || printf skipped)" ran
mv /usr/local/lib/agent-md/receipt-verify.sh.off /usr/local/lib/agent-md/receipt-verify.sh

sudo -u dev bash -c 'mkdir -p /home/dev/solo/.claude/hooks && cd /home/dev/solo && git init -q'
for f in _lib.sh stop-verify.sh; do
  install -o dev -g dev -m 0755 "/hooks/$f" "/home/dev/solo/.claude/hooks/$f"
done
install -o dev -g dev -m 0644 /hosts/settings.json /home/dev/solo/.claude/settings.json
sudo -u dev bash -c 'printf "[verify]\ntest = \"touch /srv/SOLO_RAN\"\n\n[verify.policy]\nrequired = [\"test\"]\ntimeout_seconds = 60\ntotal_timeout_seconds = 300\n" > /home/dev/solo/agent-md.toml'
sudo -u dev env -i HOME=/home/dev PATH=/usr/local/bin:/usr/bin:/bin \
  bash -c 'cd /home/dev/solo && printf "{}" | bash .claude/hooks/stop-verify.sh' >/dev/null 2>&1
row dev completion "an unenrolled workspace" "legacy fallback" \
  "$([ -e /srv/SOLO_RAN ] && printf ran || printf skipped)" ran

install -o dev -g dev -m 0644 /it/agent-md.toml /home/dev/repo/agent-md.toml
enroll_project >/dev/null

header "9. C3a boundaries still hold"
P=/var/lib/agent-md/projects/$PID
row agentmd-runner "private key" read "DAC 0600 agentmd" "$(try sudo -u agentmd-runner cat "$PRIV")" denied
row dev "private key" read "DAC 0700 dir" "$(try sudo -u dev cat "$PRIV")" denied
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
  -v "$ROOT_DIR/.claude/hooks:/hooks:ro" \
  -v "$PAYLOAD/hosts:/hosts:ro" \
  -v "$PAYLOAD:/it:ro" \
  "$IMAGE" bash -c '/it/setup.sh && /it/matrix.sh'
