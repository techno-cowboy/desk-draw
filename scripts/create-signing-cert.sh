#!/usr/bin/env bash
# Creates the self-signed "Desk Draw" code signing certificate in the login keychain.
#
# Run this once, ever. macOS ties each user's Screen Recording permission to this certificate, so
# a new one costs every user one more permission prompt. On another release machine, import a
# backup of the existing certificate instead (see docs/RELEASING.md).
set -euo pipefail

NAME="Desk Draw"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -p codesigning | grep -q "\"$NAME\""; then
  echo "A \"$NAME\" signing certificate already exists; keep using it." >&2
  exit 1
fi

umask 077
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

cat >"$WORK/cert.cnf" <<EOF
[req]
distinguished_name = dn
x509_extensions = ext
prompt = no
[dn]
CN = $NAME
[ext]
basicConstraints = critical, CA:false
keyUsage = critical, digitalSignature
extendedKeyUsage = critical, codeSigning
subjectKeyIdentifier = hash
EOF

# 20 years: the certificate must outlive the app, or users get asked again.
openssl req -x509 -newkey rsa:3072 -nodes -days 7300 -config "$WORK/cert.cnf" \
  -keyout "$WORK/key.pem" -out "$WORK/cert.pem" 2>/dev/null

# A throwaway password only protects the bundle on its way into the keychain.
PASSWORD=$(openssl rand -hex 24)
openssl pkcs12 -export -legacy -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
  -out "$WORK/identity.p12" -passout "pass:$PASSWORD" 2>/dev/null \
  || openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" -name "$NAME" \
    -out "$WORK/identity.p12" -passout "pass:$PASSWORD"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P "$PASSWORD" -T /usr/bin/codesign >/dev/null

security find-identity -p codesigning | grep "\"$NAME\""
echo "Created the \"$NAME\" signing certificate. Back it up now (docs/RELEASING.md)."
