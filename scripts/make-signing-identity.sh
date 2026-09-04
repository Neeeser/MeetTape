#!/bin/bash
# Creates a self-signed code-signing certificate named "Pipit Development" in
# the login keychain, so local builds keep their permission grants.
#
# macOS ties Microphone, Accessibility and Screen & System Audio Recording
# grants to the application's signature. An ad-hoc signature changes with every
# build, so every reinstall drops all three, and a recording made before they
# are granted again captures a silent far end without saying so. A certificate
# gives the signature a stable designated requirement, and the grants survive.
#
# Run once. `scripts/bundle-app.sh` picks the identity up by name. macOS asks
# for the login password when the certificate is marked trusted for code
# signing; that step is the one thing this script cannot do on its own.
#
# Usage: scripts/make-signing-identity.sh
set -euo pipefail

NAME="Pipit Development"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "\"$NAME\""; then
    echo "==> \"$NAME\" is already in the login keychain"
    exit 0
fi

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> generating the certificate"
openssl req -x509 -newkey rsa:2048 -sha256 -days 3650 -nodes \
    -keyout "$WORK/key.pem" -out "$WORK/cert.pem" \
    -subj "/CN=$NAME" \
    -addext "keyUsage=critical,digitalSignature" \
    -addext "extendedKeyUsage=critical,codeSigning" \
    -addext "basicConstraints=critical,CA:false"
openssl pkcs12 -export -inkey "$WORK/key.pem" -in "$WORK/cert.pem" \
    -out "$WORK/identity.p12" -passout pass:pipit -name "$NAME"

echo "==> importing it into the login keychain"
security import "$WORK/identity.p12" -k "$KEYCHAIN" -P pipit -T /usr/bin/codesign

echo "==> marking it trusted for code signing (macOS asks for your login password)"
security add-trusted-cert -p codeSign -k "$KEYCHAIN" "$WORK/cert.pem"

if security find-identity -v -p codesigning | grep -q "\"$NAME\""; then
    echo "==> done. scripts/bundle-app.sh will sign with \"$NAME\" from now on."
    echo "    Grant Microphone, Accessibility and Screen & System Audio Recording"
    echo "    once more after the next install. They then survive rebuilds."
else
    echo "the identity was imported but codesign cannot see it; open Keychain Access," >&2
    echo "find \"$NAME\" under login, and set Code Signing to Always Trust" >&2
    exit 1
fi
