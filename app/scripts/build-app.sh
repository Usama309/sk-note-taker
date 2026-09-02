#!/bin/zsh
# Builds SK Note Taker.app — a real bundle is required for stable TCC permissions
# (microphone + system audio recording). Signs with Apple Development identity when
# available, ad-hoc otherwise.
set -euo pipefail

APP_DIR="$(cd "$(dirname "$0")/.." && pwd)"
ROOT_DIR="$(dirname "$APP_DIR")"
BUILD_CONFIG="${1:-release}"
BUNDLE_NAME="SK Note Taker.app"
DIST="$APP_DIR/dist"
BUNDLE="$DIST/$BUNDLE_NAME"

echo "==> swift build -c $BUILD_CONFIG"
cd "$APP_DIR"
swift build -c "$BUILD_CONFIG" --product SKNoteTaker

BIN="$(swift build -c "$BUILD_CONFIG" --show-bin-path)/SKNoteTaker"

echo "==> Assembling $BUNDLE_NAME"
rm -rf "$BUNDLE"
mkdir -p "$BUNDLE/Contents/MacOS" "$BUNDLE/Contents/Resources"
cp "$BIN" "$BUNDLE/Contents/MacOS/SKNoteTaker"

# SwiftPM resource bundle (brand logo etc.) → Contents/Resources so Bundle.module resolves it.
RESBUNDLE="$(dirname "$BIN")/SKNoteTaker_SKNoteTakerApp.bundle"
if [[ -d "$RESBUNDLE" ]]; then
    cp -R "$RESBUNDLE" "$BUNDLE/Contents/Resources/"
fi

# Bundle the Google Meet browser extension so users can load it unpacked.
if [[ -d "$APP_DIR/browser-extension" ]]; then
    cp -R "$APP_DIR/browser-extension" "$BUNDLE/Contents/Resources/browser-extension"
fi

echo "==> Icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if [[ -f "$APP_DIR/AppIcon-1024.png" ]]; then
    cp "$APP_DIR/AppIcon-1024.png" "$DIST/icon-1024.png"   # committed brand logo
elif [[ ! -f "$DIST/icon-1024.png" ]]; then
    swift "$APP_DIR/scripts/icongen.swift" "$DIST/icon-1024.png" 1024
fi
for SIZE in 16 32 64 128 256 512; do
    sips -z $SIZE $SIZE "$DIST/icon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}.png" >/dev/null
    DOUBLE=$((SIZE * 2))
    sips -z $DOUBLE $DOUBLE "$DIST/icon-1024.png" --out "$ICONSET/icon_${SIZE}x${SIZE}@2x.png" >/dev/null
done
iconutil -c icns "$ICONSET" -o "$BUNDLE/Contents/Resources/AppIcon.icns"

cat > "$BUNDLE/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleName</key>               <string>SK Note Taker</string>
    <key>CFBundleDisplayName</key>        <string>SK Note Taker</string>
    <key>CFBundleIdentifier</key>         <string>com.saqibkamran.sknotetaker</string>
    <key>CFBundleVersion</key>            <string>1.7.0</string>
    <key>CFBundleShortVersionString</key> <string>1.7.0</string>
    <key>CFBundleExecutable</key>         <string>SKNoteTaker</string>
    <key>CFBundlePackageType</key>        <string>APPL</string>
    <key>CFBundleIconFile</key>           <string>AppIcon</string>
    <key>LSMinimumSystemVersion</key>     <string>26.0</string>
    <key>NSHighResolutionCapable</key>    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>SK Note Taker transcribes your voice during meetings.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>SK Note Taker captures system audio to transcribe the other meeting participants.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>SK Note Taker transcribes meetings on-device.</string>
</dict>
</plist>
PLIST

# Bake the Google OAuth desktop client into the app so end users connect with one click and
# never paste anything. Values come from the git-ignored app/oauth-config.env. For a Desktop
# OAuth client the secret is non-confidential (Google's installed-app model), so embedding it in
# the shipped .app is expected — we just keep the raw value out of git.
OAUTH_ENV="$APP_DIR/oauth-config.env"
if [[ -f "$OAUTH_ENV" ]]; then
    set -a; # shellcheck disable=SC1090
    source "$OAUTH_ENV"; set +a
    PB=/usr/libexec/PlistBuddy
    [[ -n "${SK_GOOGLE_CLIENT_ID:-}" ]] && \
        "$PB" -c "Add :SKGoogleClientID string ${SK_GOOGLE_CLIENT_ID}" "$BUNDLE/Contents/Info.plist"
    [[ -n "${SK_GOOGLE_CLIENT_SECRET:-}" ]] && \
        "$PB" -c "Add :SKGoogleClientSecret string ${SK_GOOGLE_CLIENT_SECRET}" "$BUNDLE/Contents/Info.plist"
    echo "==> Baked built-in Google OAuth client into Info.plist"
else
    echo "==> No oauth-config.env — shipping without a built-in Google client (users paste their own)"
fi

# Strip macOS custom-folder icons and Finder metadata before signing.
# The repo carries committed "Icon\r" stubs in browser-extension/ and Sources/.../Resources/.
# On this Mac they hold com.apple.ResourceFork + com.apple.FinderInfo, which get copied into
# the bundle and make codesign fail with:
#   "resource fork, Finder information, or similar detritus not allowed"
find "$BUNDLE" -name 'Icon?' -delete 2>/dev/null || true
xattr -cr "$BUNDLE"

echo "==> Signing"
# Hardened runtime blocks mic access unless the audio-input entitlement is present.
ENTITLEMENTS="$DIST/entitlements.plist"
cat > "$ENTITLEMENTS" <<'ENT'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>com.apple.security.device.audio-input</key> <true/>
</dict>
</plist>
ENT

# Signing identity, in order of preference:
#   1. Apple Development — a real developer certificate, if one is installed.
#   2. "SK Note Taker Dev" — a local self-signed code-signing certificate.
#   3. ad-hoc.
# Why this matters beyond "it's signed": macOS records privacy grants (Screen Recording, which
# gates system-audio capture) against the app's code signature. Ad-hoc signatures change on
# EVERY rebuild, so each build silently lost the Screen Recording grant while still appearing
# enabled in System Settings. A stable identity keeps the signature constant across rebuilds,
# so the grant is given once and sticks.
# Create the local identity once with: scripts/make-signing-identity.sh
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -z "${IDENTITY:-}" ]]; then
    IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/SK Note Taker Dev/{print $2; exit}')"
fi
if [[ -n "${IDENTITY:-}" ]]; then
    echo "    using identity: $IDENTITY"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$BUNDLE"
else
    echo "    no signing identity found — ad-hoc signing (privacy grants will reset on every"
    echo "    rebuild; run scripts/make-signing-identity.sh once to fix that)"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE"
fi
codesign --verify --deep "$BUNDLE" && echo "    signature OK"

echo "==> Built: $BUNDLE"
