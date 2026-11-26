# tests/tls-fixture.bash — synthetic TLS chain shared by the suite and the
# integration harness.
#
# tls_fixture_chain <root> <ca-common-name>
#   Writes <root>/ca.key, <root>/source/etc/trust/ca.pem and a localhost leaf
#   (<root>/server.key, server.csr, server.ext, server.pem) signed by that CA.
#
# Key identifiers are declared rather than left to CLI defaults: OpenSSL 4
# stopped adding them, and strict X.509 validation rejects a leaf without AKI.
tls_fixture_chain() {
  local root="$1" cn="$2"
  openssl req -x509 -newkey rsa:2048 -nodes -days 1 \
    -subj "/CN=$cn" -addext 'basicConstraints=critical,CA:TRUE' \
    -addext 'keyUsage=critical,keyCertSign,cRLSign' \
    -addext 'subjectKeyIdentifier=hash' \
    -keyout "$root/ca.key" -out "$root/source/etc/trust/ca.pem" >/dev/null 2>&1 || return 1
  openssl req -newkey rsa:2048 -nodes -subj /CN=localhost \
    -keyout "$root/server.key" -out "$root/server.csr" >/dev/null 2>&1 || return 1
  printf '%s\n' 'subjectAltName=DNS:localhost' 'subjectKeyIdentifier=hash' \
    'authorityKeyIdentifier=keyid:always' > "$root/server.ext"
  openssl x509 -req -days 1 -in "$root/server.csr" \
    -CA "$root/source/etc/trust/ca.pem" -CAkey "$root/ca.key" \
    -CAcreateserial -extfile "$root/server.ext" \
    -out "$root/server.pem" >/dev/null 2>&1
}
