#!/bin/zsh
# Creates a STABLE local code-signing identity for SK Note Taker, once.
#
# WHY: macOS records privacy grants — notably Screen Recording, which gates the
# ScreenCaptureKit system-audio capture — against the app's code signature. Ad-hoc signatures
# change on every rebuild, so each new build silently loses the grant: System Settings still
# shows the app enabled, but CGPreflightScreenCaptureAccess() reports denied and capture
# falls back. Signing with a stable certificate keeps the signature constant across rebuilds,
# so you grant the permission once.
#
# This creates a self-signed certificate in ~/.sknote-signing and imports it into the login
# keychain. It does NOT touch system trust settings. Safe to re-run: it no-ops if the
# identity already exists.
#
# Usage: scripts/make-signing-identity.sh
set -euo pipefail

NAME="SK Note Taker Dev"
DIR="$HOME/.sknote-signing"
KEYCHAIN="$HOME/Library/Keychains/login.keychain-db"
P12_PASS="sknote"

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✅ signing identity \"$NAME\" already present — nothing to do"
    exit 0
fi

mkdir -p "$DIR"; chmod 700 "$DIR"; cd "$DIR"

if [[ ! -f cert.pem || ! -f key.pem ]]; then
    echo "==> creating self-signed code-signing certificate"
    openssl req -x509 -newkey rsa:2048 -keyout key.pem -out cert.pem -days 3650 -nodes \
        -subj "/CN=$NAME/O=SK Note Taker" \
        -addext "basicConstraints=critical,CA:false" \
        -addext "keyUsage=critical,digitalSignature" \
        -addext "extendedKeyUsage=critical,codeSigning"
    chmod 600 key.pem
fi

echo "==> packaging as PKCS#12"
# Apple's `security` tool cannot read OpenSSL 3's default PKCS12 MAC — force the legacy algs.
rm -f cert.p12
if ! openssl pkcs12 -export -legacy -out cert.p12 -inkey key.pem -in cert.pem \
        -passout "pass:$P12_PASS" -name "$NAME" 2>/dev/null; then
    openssl pkcs12 -export -out cert.p12 -inkey key.pem -in cert.pem \
        -passout "pass:$P12_PASS" -name "$NAME" \
        -macalg sha1 -certpbe PBE-SHA1-3DES -keypbe PBE-SHA1-3DES
fi
chmod 600 cert.p12

echo "==> importing into the login keychain"
security import cert.p12 -k "$KEYCHAIN" -P "$P12_PASS" -A

if security find-identity -v -p codesigning 2>/dev/null | grep -q "$NAME"; then
    echo "✅ signing identity \"$NAME\" is ready — build-app.sh will use it automatically"
    echo "   NOTE: this changes the app's signature once, so re-grant Screen Recording"
    echo "   (System Settings → Privacy & Security → Screen & System Audio Recording)."
    echo "   After that the grant persists across rebuilds."
else
    echo "❌ identity did not become valid; the build will fall back to ad-hoc signing" >&2
    exit 1
fi
