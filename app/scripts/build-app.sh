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

echo "==> Icon"
ICONSET="$DIST/AppIcon.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
if [[ ! -f "$DIST/icon-1024.png" ]]; then
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
    <key>CFBundleVersion</key>            <string>1.1.0</string>
    <key>CFBundleShortVersionString</key> <string>1.1.0</string>
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

IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development/{print $2; exit}')"
if [[ -n "${IDENTITY:-}" ]]; then
    echo "    using identity: $IDENTITY"
    codesign --force --deep --options runtime --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$BUNDLE"
else
    echo "    no Apple Development identity found — ad-hoc signing"
    codesign --force --deep --entitlements "$ENTITLEMENTS" --sign - "$BUNDLE"
fi
codesign --verify --deep "$BUNDLE" && echo "    signature OK"

echo "==> Built: $BUNDLE"
