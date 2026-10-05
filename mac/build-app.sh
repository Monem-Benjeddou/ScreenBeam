#!/bin/bash
# Builds ScreenBeam.app (menu bar app) into ./build and signs it ad-hoc.
set -euo pipefail
cd "$(dirname "$0")"

swift build -c release
BIN="$(swift build -c release --show-bin-path)/ScreenBeam"

APP=build/ScreenBeam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenBeam"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.screenbeam.mac</string>
    <key>CFBundleName</key><string>ScreenBeam</string>
    <key>CFBundleDisplayName</key><string>ScreenBeam</string>
    <key>CFBundleExecutable</key><string>ScreenBeam</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>1.0</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSLocalNetworkUsageDescription</key>
    <string>ScreenBeam streams your screen to your phone over the local network.</string>
    <key>NSAudioCaptureUsageDescription</key>
    <string>ScreenBeam sends your Mac's sound to your phone.</string>
    <key>NSBonjourServices</key>
    <array><string>_screenbeam._tcp</string></array>
</dict>
</plist>
PLIST

# Sign with a stable local certificate when available so macOS keeps the Screen Recording
# permission across rebuilds (ad-hoc signatures change every build, which resets it).
IDENTITY="$(security find-identity -p codesigning 2>/dev/null | awk '/"ScreenBeam Local Signing"/ {print $2; exit}')"
codesign --force --deep --sign "${IDENTITY:--}" --identifier com.screenbeam.mac "$APP"
echo "Built $(pwd)/$APP"
