#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds the dogfood .app bundle: release build + assembly + ad-hoc sign.
# Produces: signal-macos/dist/SignalMac.app (run with `open`).
# No Xcode project needed; the full Xcode setup arrives in a later phase.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
DIST="$ROOT/dist"
APP="$DIST/SignalMac.app"
CONTENTS="$APP/Contents"

# --disable-sandbox is a no-op off-sandbox; required under nono.
SWIFT_FLAGS="--disable-sandbox"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

(cd "$ROOT" && swift build -c release --product SignalMac $SWIFT_FLAGS)
cp "$ROOT/.build/release/SignalMac" "$CONTENTS/MacOS/"

VERSION=$(date -u +%Y.%m.%d)
cat > "$CONTENTS/Info.plist" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>SignalMac</string>
    <key>CFBundleIdentifier</key>
    <string>org.signal.signal-mac</string>
    <key>CFBundleName</key>
    <string>SignalMac</string>
    <key>CFBundleVersion</key>
    <string>$VERSION</string>
    <key>CFBundleShortVersionString</key>
    <string>$VERSION</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>LSMinimumSystemVersion</key>
    <string>13.0</string>
    <key>NSPrincipalClass</key>
    <string>NSApplication</string>
    <key>NSHighResolutionCapable</key>
    <true/>
</dict>
</plist>
EOF

codesign --force --deep --sign - "$APP"
echo "built $APP"
