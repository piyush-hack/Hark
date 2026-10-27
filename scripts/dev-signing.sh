#!/bin/bash
# Creates (once) a self-signed "Hark Local Signing" code-signing identity in a private keychain
# and prints that keychain's path. A stable signature means macOS remembers the permissions you
# grant Hark; ad-hoc signatures change on every build and reset them.
set -euo pipefail

KEYCHAIN="$HOME/Library/Keychains/hark-signing.keychain-db"
PASSWORD="hark-local-signing"
NAME="Hark Local Signing"

if [ ! -f "$KEYCHAIN" ]; then
  security create-keychain -p "$PASSWORD" "$KEYCHAIN" >/dev/null
  security set-keychain-settings "$KEYCHAIN"
fi
security unlock-keychain -p "$PASSWORD" "$KEYCHAIN"
# codesign only finds identities in keychains on the user search list.
CURRENT="$(security list-keychains -d user | tr -d '"' | xargs)"
case "$CURRENT" in
  *hark-signing*) ;;
  *) security list-keychains -d user -s $CURRENT "$KEYCHAIN" ;;
esac

if ! security find-identity -p codesigning "$KEYCHAIN" 2>/dev/null | grep -q "$NAME"; then
  TMP="$(mktemp -d)"
  trap 'rm -rf "$TMP"' EXIT
  cat > "$TMP/cert.cfg" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
basicConstraints = critical, CA:false
EOF
  /usr/bin/openssl req -x509 -newkey rsa:2048 -nodes -days 3650 -config "$TMP/cert.cfg" \
    -keyout "$TMP/key.pem" -out "$TMP/cert.pem" >/dev/null 2>&1
  /usr/bin/openssl pkcs12 -export -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -name "$NAME" \
    -out "$TMP/identity.p12" -passout pass:"$PASSWORD" >/dev/null 2>&1
  security import "$TMP/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null
  security set-key-partition-list -S apple-tool:,apple:,codesign: -s -k "$PASSWORD" "$KEYCHAIN" >/dev/null
fi

echo "$KEYCHAIN"
