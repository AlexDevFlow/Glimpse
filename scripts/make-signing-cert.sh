#!/bin/sh
# Creates a self-signed code-signing certificate in the login keychain so the app keeps
# its Screen Recording / Microphone permissions across rebuilds (ad-hoc signatures change
# on every build, and macOS then treats the app as new).
#
# Usage:  sh scripts/make-signing-cert.sh
# Then:   make bundle SIGN_IDENTITY="Glimpse Dev"
set -e
# Use the system openssl (LibreSSL): OpenSSL 3 writes PKCS#12 files that `security import` rejects.
NAME="${1:-Glimpse Dev}"
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT

# codesign needs the key's partition list, or the identity works once and then
# fails with errSecInternalComponent. Scoped by label so other keys in the login
# keychain keep theirs. Prompts for the login password.
authorise_key() {
  security set-key-partition-list -S apple-tool:,apple:,codesign: -l "$NAME" "$KEYCHAIN" >/dev/null 2>&1 \
    || echo "Warning: could not set the partition list for '$NAME'; codesign may fail with errSecInternalComponent."
}

KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning | grep -q "$NAME"; then
  # Re-authorise rather than bail: anyone hitting errSecInternalComponent has the
  # identity already, and bailing here is what left them stuck.
  echo "Identity '$NAME' already exists; re-authorising it for codesign."
  authorise_key
  exit 0
fi

/usr/bin/openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
  -keyout "$TMP/key.pem" -out "$TMP/cert.pem" -subj "/CN=$NAME" \
  -addext "keyUsage=critical,digitalSignature" \
  -addext "extendedKeyUsage=critical,codeSigning" >/dev/null 2>&1
# -name fixes the keychain item label, which authorise_key matches on with -l.
/usr/bin/openssl pkcs12 -export -name "$NAME" -out "$TMP/cert.p12" -inkey "$TMP/key.pem" -in "$TMP/cert.pem" -passout pass:tmp

security import "$TMP/cert.p12" -k "$KEYCHAIN" -P tmp -T /usr/bin/codesign -T /usr/bin/security
# Trust it for code signing (this prompts for your login password).
security add-trusted-cert -r trustRoot -p codeSign -k "$KEYCHAIN" "$TMP/cert.pem"
authorise_key

echo "Created identity '$NAME'. Build with:  make bundle SIGN_IDENTITY=\"$NAME\""
echo "To remove it later: security delete-certificate -c \"$NAME\""
