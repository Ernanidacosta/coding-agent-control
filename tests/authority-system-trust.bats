#!/usr/bin/env bats

load authority-helpers
bats_require_minimum_version 1.5.0

setup() {
  LIB="$BATS_TEST_DIRNAME/../examples/local-issuer/authority-lib.sh"
  FIXTURE=$(mktemp -d)
  mkdir -p "$FIXTURE/source/etc/ssl/certs" "$FIXTURE/source/etc/trust" \
    "$FIXTURE/snapshot" "$FIXTURE/scratch/tmp" "$FIXTURE/scratch/shm"
  export LIB FIXTURE
  make_certificate
}

teardown() {
  [ -z "${SERVER_PID:-}" ] || { kill "$SERVER_PID" 2>/dev/null || true; wait "$SERVER_PID" 2>/dev/null || true; }
  chmod -R u+w "$FIXTURE" 2>/dev/null || true
  rm -rf "$FIXTURE"
}

make_certificate() {
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj /CN=agent-md-local-test-ca -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -keyout "$FIXTURE/ca.key" -out "$FIXTURE/source/etc/trust/ca.pem" >/dev/null 2>&1
  openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
    -keyout "$FIXTURE/server.key" -out "$FIXTURE/server.csr" >/dev/null 2>&1
  printf 'subjectAltName=DNS:localhost\n' > "$FIXTURE/server.ext"
  openssl x509 -req -days 1 -in "$FIXTURE/server.csr" \
    -CA "$FIXTURE/source/etc/trust/ca.pem" -CAkey "$FIXTURE/ca.key" \
    -CAcreateserial -extfile "$FIXTURE/server.ext" \
    -out "$FIXTURE/server.pem" >/dev/null 2>&1
  chmod 0444 "$FIXTURE/source/etc/trust/ca.pem"
  chmod 0555 "$FIXTURE/source/etc/trust"
}

start_tls_server() {
  local cert="${1:-$FIXTURE/server.pem}" key="${2:-$FIXTURE/server.key}"
  cat > "$FIXTURE/server.py" <<'PY'
import socket
import ssl
import sys
from pathlib import Path

root = Path(sys.argv[1])
context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
context.load_cert_chain(sys.argv[2], sys.argv[3])
with socket.socket() as listener:
    listener.bind(('127.0.0.1', 0))
    listener.listen(8)
    (root / 'port').write_text(str(listener.getsockname()[1]))
    while True:
        raw, _ = listener.accept()
        try:
            with context.wrap_socket(raw, server_side=True) as stream:
                stream.recv(1)
                stream.sendall(b'OK')
        except (ssl.SSLError, OSError):
            pass
PY
  python3 "$FIXTURE/server.py" "$FIXTURE" "$cert" "$key" > "$FIXTURE/server.log" 2>&1 &
  SERVER_PID=$!
  deadline=$((SECONDS + 10))
  until [ -s "$FIXTURE/port" ]; do
    [ "$SECONDS" -lt "$deadline" ] || { cat "$FIXTURE/server.log"; return 1; }
    sleep 0.02
  done
}

tls_client() {
  /usr/bin/python3 -c '
import socket, ssl, sys
context = ssl.create_default_context()
with socket.create_connection(("127.0.0.1", int(sys.argv[1])), timeout=3) as raw:
    with context.wrap_socket(raw, server_hostname="localhost") as stream:
        stream.sendall(b"x")
        assert stream.recv(2) == b"OK"
' "$1"
}

seal_trust_source() {
  chmod 0555 "$FIXTURE/source/etc" "$FIXTURE/source/etc/ssl" \
    "$FIXTURE/source/etc/ssl/certs" "$FIXTURE/source/etc/trust"
}

materialize_view() {
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
}

sandbox_python() {
  local code="$1" port="${2:-0}"
  run --separate-stderr bash -c '
    . "$1"
    authority_sandbox_arguments "$2/snapshot" "$2/scratch" /usr/bin "$2/view"
    /usr/bin/env -i PATH=/usr/bin:/bin /usr/bin/bwrap "${AUTHORITY_SANDBOX_ARGS[@]}" -- \
      /usr/bin/python3 -c "$3" "$4"
  ' _ "$LIB" "$FIXTURE" "$code" "$port"
}

tls_code() {
  cat <<'PY'
import socket, ssl, sys
with socket.create_connection(('127.0.0.1', int(sys.argv[1])), timeout=3) as raw:
    with ssl.create_default_context().wrap_socket(raw, server_hostname='localhost') as stream:
        stream.sendall(b'x')
        assert stream.recv(2) == b'OK'
PY
}

regular_ca() {
  chmod u+w "$FIXTURE/source/etc/ssl/certs"
  cp "$FIXTURE/source/etc/trust/ca.pem" "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  cp "$FIXTURE/source/etc/trust/ca.pem" "$FIXTURE/source/etc/ssl/cert.pem"
  chmod 0444 "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt" \
    "$FIXTURE/source/etc/ssl/cert.pem"
  seal_trust_source
}

@test "a relative CA symlink outside the mounted tree breaks TLS before the trust view and works after it" {
  chmod u+w "$FIXTURE/source/etc/ssl/certs"
  ln -s ../../trust/ca.pem "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  ln -s ../trust/ca.pem "$FIXTURE/source/etc/ssl/cert.pem"
  seal_trust_source
  start_tls_server
  port=$(cat "$FIXTURE/port")

  run --separate-stderr /usr/bin/bwrap --unshare-user --unshare-pid \
    --ro-bind /usr /usr --ro-bind /bin /bin --ro-bind /lib /lib \
    --ro-bind /lib64 /lib64 \
    --ro-bind "$FIXTURE/source/etc/ssl/certs" /etc/ssl/certs \
    --proc /proc --dev /dev --remount-ro / -- \
    /usr/bin/python3 -c "import socket,ssl; s=socket.create_connection(('127.0.0.1',$port)); ssl.create_default_context().wrap_socket(s,server_hostname='localhost')"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *CERTIFICATE_VERIFY_FAILED* ]] || { printf '%s\n' "$stderr" >&2; return 1; }

  materialize_view
  sandbox_python "$(tls_code)" "$port"
  [ "$status" -eq 0 ] || { printf 'stdout: %s\nstderr: %s\n' "$output" "$stderr" >&2; return 1; }
}

@test "a regular CA bundle at its logical path validates local HTTPS" {
  regular_ca
  materialize_view
  [ -f "$FIXTURE/view/cert.pem" ]
  [ ! -L "$FIXTURE/view/cert.pem" ]
  start_tls_server
  sandbox_python "$(tls_code)" "$(cat "$FIXTURE/port")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
}

@test "an absolute safe CA symlink is flattened without exposing its parent" {
  chmod u+w "$FIXTURE/source/etc/ssl/certs"
  ln -s "$FIXTURE/source/etc/trust/ca.pem" \
    "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  ln -s "$FIXTURE/source/etc/trust/ca.pem" "$FIXTURE/source/etc/ssl/cert.pem"
  seal_trust_source
  materialize_view
  start_tls_server
  sandbox_python "$(tls_code)" "$(cat "$FIXTURE/port")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
  sandbox_python 'from pathlib import Path; assert Path("/etc/ssl/certs/ca-certificates.crt").is_file(); assert not Path("/etc/trust").exists()'
  [ "$status" -eq 0 ]
}

@test "a missing CA symlink target refuses the trust capability" {
  ln -s ../../trust/missing.pem "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  seal_trust_source
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'does not resolve'* ]]
  [ ! -e "$FIXTURE/view" ]
}

@test "a failed trust copy leaves no view and reports the failing step" {
  regular_ca
  run bash -c '
    . "$1"
    cp() { return 1; }
    authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"
  ' _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'cannot copy system trust certificates'* ]]
  [ ! -e "$FIXTURE/view" ]
}

@test "runner-writable CA material is refused" {
  chmod u+w "$FIXTURE/source/etc/trust/ca.pem"
  ln -s ../../trust/ca.pem "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  seal_trust_source
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unsafe write access'* ]]
  [ ! -e "$FIXTURE/view" ]
}

@test "group-writable trust parents are refused even for an unrelated group or ACL mask" {
  ln -s ../../trust/ca.pem "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  seal_trust_source
  chmod g+w "$FIXTURE/source/etc/trust"
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" 999999 999998' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'unsafe write access'* ]]
  [ ! -e "$FIXTURE/view" ]
}

@test "a CA symlink into a developer home is refused" {
  mkdir -p "$FIXTURE/source/home/developer"
  cp "$FIXTURE/source/etc/trust/ca.pem" "$FIXTURE/source/home/developer/ca.pem"
  ln -s "$FIXTURE/source/home/developer/ca.pem" \
    "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  seal_trust_source
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'outside system paths'* ]]
}

@test "a CA symlink into authority keys or state is refused" {
  mkdir -p "$FIXTURE/source/var/lib/agent-md/keys"
  cp "$FIXTURE/source/etc/trust/ca.pem" "$FIXTURE/source/var/lib/agent-md/keys/ca.pem"
  ln -s "$FIXTURE/source/var/lib/agent-md/keys/ca.pem" \
    "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  seal_trust_source
  run bash -c '. "$1"; authority_materialize_system_trust "$2/view" "$2/source" "$(id -u)"' \
    _ "$LIB" "$FIXTURE"
  [ "$status" -ne 0 ]
  [[ "$output" == *'outside system paths'* ]]
}

@test "only safe external certificate targets enter the trust view" {
  ln -s ../../trust/ca.pem "$FIXTURE/source/etc/ssl/certs/ca-certificates.crt"
  ln -s ../../trust/ca.pem "$FIXTURE/source/etc/ssl/certs/01234567.0"
  seal_trust_source
  materialize_view
  [ -f "$FIXTURE/view/certs/01234567.0" ]
  [ ! -L "$FIXTURE/view/certs/01234567.0" ]
  sandbox_python 'from pathlib import Path; assert Path("/etc/ssl/certs/01234567.0").is_file(); assert not Path("/etc/trust").exists(); assert not Path("/home").exists(); assert not Path("/var/lib/agent-md").exists()'
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
}

@test "a hostile snapshot cannot replace system trust" {
  regular_ca
  mkdir -p "$FIXTURE/snapshot/etc/ssl"
  printf 'not a certificate\n' > "$FIXTURE/snapshot/etc/ssl/cert.pem"
  materialize_view
  start_tls_server
  sandbox_python "$(tls_code)" "$(cat "$FIXTURE/port")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
}

@test "preparation cannot write the CA and the following check receives clean trust" {
  regular_ca
  materialize_view
  before=$(sha256sum "$FIXTURE/view/cert.pem" | cut -d' ' -f1)
  sandbox_python "$(cat <<'PY'
from pathlib import Path
try:
    Path('/etc/ssl/cert.pem').write_bytes(b'poison')
except OSError:
    pass
else:
    raise AssertionError('CA was writable')
PY
)"
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
  [ "$(sha256sum "$FIXTURE/view/cert.pem" | cut -d' ' -f1)" = "$before" ]
  start_tls_server
  sandbox_python "$(tls_code)" "$(cat "$FIXTURE/port")"
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
}

@test "DNS configuration and private filesystem exclusions survive the trust mount" {
  regular_ca
  materialize_view
  sandbox_python 'import socket; from pathlib import Path; assert Path("/etc/resolv.conf").is_file(); assert socket.getaddrinfo("localhost", 443); assert not Path("/home/developer").exists(); assert not Path("/var/lib/agent-md/keys").exists(); assert not Path("/var/lib/agent-md/projects/p/state.json").exists(); assert not Path("/runtime/../other-check").exists()'
  [ "$status" -eq 0 ] || { printf '%s\n' "$stderr" >&2; return 1; }
}

@test "untrusted local HTTPS remains rejected with the trust view" {
  regular_ca
  materialize_view
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 -subj /CN=localhost \
    -addext 'subjectAltName=DNS:localhost' \
    -keyout "$FIXTURE/untrusted.key" -out "$FIXTURE/snapshot/untrusted.pem" >/dev/null 2>&1
  start_tls_server "$FIXTURE/snapshot/untrusted.pem" "$FIXTURE/untrusted.key"
  sandbox_python "$(tls_code)" "$(cat "$FIXTURE/port")"
  [ "$status" -ne 0 ]
  [[ "$stderr" == *CERTIFICATE_VERIFY_FAILED* ]]
}

@test "local issuer doctor proves trusted and untrusted HTTPS without public internet" {
  run bash "$BATS_TEST_DIRNAME/../examples/local-issuer/agent-md-authority" doctor --root "$FIXTURE/staging"
  [ "$status" -eq 0 ] || { printf '%s\n' "$output" >&2; return 1; }
  [[ "$output" == *'trusted local HTTPS passed; untrusted certificate rejected'* ]]
}
