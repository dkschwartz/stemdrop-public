#!/bin/bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

echo "Building StemDrop (release)…"
swift build -c release

APP_DIR="$ROOT_DIR/build/StemDrop.app"
CONTENTS_DIR="$APP_DIR/Contents"
MACOS_DIR="$CONTENTS_DIR/MacOS"
RESOURCES_DIR="$CONTENTS_DIR/Resources"

rm -rf "$APP_DIR"
mkdir -p "$MACOS_DIR" "$RESOURCES_DIR"

BIN_PATH="$(swift build -c release --show-bin-path)/StemDrop"
cp "$BIN_PATH" "$MACOS_DIR/StemDrop"
chmod +x "$MACOS_DIR/StemDrop"

cp "$ROOT_DIR/Resources/Info.plist" "$CONTENTS_DIR/Info.plist"
cp "$ROOT_DIR/Resources/AppIcon.icns" "$RESOURCES_DIR/AppIcon.icns"

if [ -d "$ROOT_DIR/Resources/engine" ]; then
    echo "Copying bundled engine…"
    cp -R "$ROOT_DIR/Resources/engine" "$RESOURCES_DIR/engine"
fi

# Sign with the stable local cert if it exists so macOS keeps the app's
# Documents/Desktop permission across rebuilds (ad-hoc signatures change
# every build and re-trigger the TCC prompt). A local signing identity is optional.
SIGN_ID="-"
if security find-identity -v -p codesigning 2>/dev/null | grep -q "StemDrop Local Signing"; then
    SIGN_ID="StemDrop Local Signing"
    echo "Codesigning with local cert…"
else
    echo "Ad-hoc codesigning (no 'StemDrop Local Signing' cert found)…"
fi
codesign --force --deep --sign "$SIGN_ID" \
    --entitlements "$ROOT_DIR/Resources/StemDrop.entitlements" \
    "$APP_DIR"

echo "$APP_DIR"
