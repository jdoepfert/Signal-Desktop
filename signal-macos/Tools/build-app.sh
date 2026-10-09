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
BIN_PATH=$(cd "$ROOT" && swift build -c release --product SignalMac --show-bin-path $SWIFT_FLAGS)
cp "$BIN_PATH/SignalMac" "$CONTENTS/MacOS/"
EXE="$CONTENTS/MacOS/SignalMac"

# Embed dynamic frameworks the executable links via @rpath (SwiftPM binary
# targets such as SQLCipher.framework are not copied into the bundle for us;
# without this the app aborts at launch with "Library not loaded").
mkdir -p "$CONTENTS/Frameworks"
install_name_tool -add_rpath "@executable_path/../Frameworks" "$EXE" 2>/dev/null || true
embedded=""
embed_frameworks() {
    # $1: binary to scan. Copies every @rpath/<Name>.framework it needs.
    otool -L "$1" | awk '/@rpath\/.*\.framework\//{print $1}' | while read -r dep; do
        name=$(printf '%s' "$dep" | sed -e 's|@rpath/||' -e 's|\.framework/.*|.framework|')
        [ -d "$CONTENTS/Frameworks/$name" ] && continue
        src=$(find "$BIN_PATH" "$BIN_PATH/PackageFrameworks" "$ROOT/.build" \
            -maxdepth 6 -type d -name "$name" 2>/dev/null | head -n 1)
        if [ -z "$src" ]; then
            echo "error: cannot find $name to embed (needed by $1)" >&2
            exit 1
        fi
        cp -R "$src" "$CONTENTS/Frameworks/"
        echo "embedded $name from $src"
    done
}
# Two passes so frameworks that depend on other frameworks are covered.
embed_frameworks "$EXE"
for fw in "$CONTENTS"/Frameworks/*.framework; do
    [ -e "$fw" ] || continue
    bin="$fw/Versions/A/$(basename "$fw" .framework)"
    [ -f "$bin" ] || bin="$fw/$(basename "$fw" .framework)"
    [ -f "$bin" ] && embed_frameworks "$bin"
done

VERSION=$(date -u +%Y.%m.%d)
COMMIT=$(git -C "$ROOT" rev-parse --short HEAD 2>/dev/null || echo unknown)
BUILD_DATE=$(date -u +%Y-%m-%dT%H:%M:%SZ)
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
    <key>SignalMacCommit</key>
    <string>$COMMIT</string>
    <key>SignalMacBuildDate</key>
    <string>$BUILD_DATE</string>
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

# Sign inside-out: frameworks first, then the app.
for fw in "$CONTENTS"/Frameworks/*.framework; do
    [ -e "$fw" ] || continue
    codesign --force --sign - "$fw"
done
codesign --force --sign - "$APP"

# Verify every @rpath framework resolves inside the bundle (system Swift
# runtime libraries resolve from the OS and are deliberately not checked).
if otool -L "$EXE" | awk '/@rpath\/.*\.framework\//{print $1}' | while read -r dep; do
    rel=$(printf '%s' "$dep" | sed 's|@rpath/||')
    [ -e "$CONTENTS/Frameworks/$rel" ] || { echo "missing in bundle: $rel" >&2; exit 1; }
done; then :; else exit 1; fi
echo "built $APP"
