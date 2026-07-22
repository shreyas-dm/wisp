#!/bin/bash
# Assembles dist/Wisp.app from the release binary. Run via `make app`.
set -euo pipefail

cd "$(dirname "$0")/.."

BINARY="${WISP_BUILD_DIR:-.build}/release/wisp"
if [ ! -x "$BINARY" ]; then
    echo "make-app: release binary not found — run 'make release' first" >&2
    exit 1
fi

APP="dist/Wisp.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BINARY" "$APP/Contents/MacOS/wisp"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key>
    <string>so.wisp.app</string>
    <key>CFBundleName</key>
    <string>Wisp</string>
    <key>CFBundleDisplayName</key>
    <string>Wisp</string>
    <key>CFBundleExecutable</key>
    <string>wisp</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleShortVersionString</key>
    <string>0.2.0</string>
    <key>CFBundleVersion</key>
    <string>1</string>
    <key>LSMinimumSystemVersion</key>
    <string>14.0</string>
    <key>LSUIElement</key>
    <true/>
    <key>NSMicrophoneUsageDescription</key>
    <string>Wisp listens only while you hold the push-to-talk keys.</string>
    <key>NSSpeechRecognitionUsageDescription</key>
    <string>Wisp transcribes your voice on-device when possible.</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
PLIST

printf 'APPL????' > "$APP/Contents/PkgInfo"

# Ad-hoc signature so TCC permissions stick to a stable identity.
codesign --force --sign - "$APP"

echo "Built $APP"
echo "Run it with:  open $APP"
