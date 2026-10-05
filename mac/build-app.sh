#!/bin/bash
# Builds a universal (Apple Silicon + Intel) ScreenBeam.app into ./build and signs it.
#   SIGN_IDENTITY  codesigning identity to use (default: "ScreenBeam Local Signing" if present, else ad hoc)
#   VERSION        version string for Info.plist (default: 1.0)
set -euo pipefail
cd "$(dirname "$0")"

VERSION="${VERSION:-1.0}"
MIN_MACOS=14.2
BINS=()
for ARCH in arm64 x86_64; do
    TRIPLE="$ARCH-apple-macosx$MIN_MACOS"
    swift build -c release --triple "$TRIPLE"
    BINS+=("$(swift build -c release --triple "$TRIPLE" --show-bin-path)/ScreenBeam")
done
BIN=build/ScreenBeam-universal
mkdir -p build
lipo -create "${BINS[@]}" -output "$BIN"

APP=build/ScreenBeam.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/ScreenBeam"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"

cat > "$APP/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>com.screenbeam.mac</string>
    <key>CFBundleName</key><string>ScreenBeam</string>
    <key>CFBundleDisplayName</key><string>ScreenBeam</string>
    <key>CFBundleExecutable</key><string>ScreenBeam</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>1</string>
    <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
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
IDENTITY="${SIGN_IDENTITY:-$(security find-identity -p codesigning 2>/dev/null | awk '/"ScreenBeam Local Signing"/ {print $2; exit}')}"
codesign --force --deep --sign "${IDENTITY:--}" --identifier com.screenbeam.mac "$APP"
echo "Built $(pwd)/$APP ($(lipo -archs "$APP/Contents/MacOS/ScreenBeam"), version $VERSION)"
