#!/bin/zsh
# Creates a self-signed code-signing certificate "ABTrackPTPad-dev" in the login keychain.
# Signing with it keeps the Accessibility / Input Monitoring grants across rebuilds
# (ad-hoc signatures change on every build, so macOS treats each build as a new app).
#
#   ./make-signing-cert.sh
#   CODESIGN_IDENTITY=ABTrackPTPad-dev ./install.sh
set -euo pipefail
NAME="${1:-ABTrackPTPad-dev}"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
  echo "identity \"$NAME\" already exists"; exit 0
fi
TMP=$(mktemp -d); trap 'rm -rf "$TMP"' EXIT
cat > "$TMP/cs.cnf" <<CNF
[req]
distinguished_name=dn
x509_extensions=ext
prompt=no
[dn]
CN=$NAME
[ext]
keyUsage=critical,digitalSignature
extendedKeyUsage=critical,codeSigning
basicConstraints=critical,CA:false
CNF
openssl req -x509 -newkey rsa:2048 -nodes -keyout "$TMP/cs.key" -out "$TMP/cs.crt" -days 3650 -config "$TMP/cs.cnf" 2>/dev/null
openssl pkcs12 -export -legacy -inkey "$TMP/cs.key" -in "$TMP/cs.crt" -out "$TMP/cs.p12" -passout pass:x -name "$NAME"
security import "$TMP/cs.p12" -k ~/Library/Keychains/login.keychain-db -P x -T /usr/bin/codesign
security add-trusted-cert -p codeSign -k ~/Library/Keychains/login.keychain-db "$TMP/cs.crt"
security find-identity -v -p codesigning | grep "$NAME"
echo "done. build with: CODESIGN_IDENTITY=$NAME ./install.sh"
