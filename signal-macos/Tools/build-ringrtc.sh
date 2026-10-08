#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds libringrtc.a (macOS host, lite FFI enabled) for the pinned ringrtc
# revision, and fetches the matching prebuilt macOS WebRTC core.
# Produces: <third-party>/ringrtc/target/debug/libringrtc.a
#           <third-party>/ringrtc-webrtc/release/obj/libwebrtc.a
# Requires: cargo, protoc, python3 on PATH.
#
# macOS note: upstream gates the lite C FFI on target_os=ios, so stock
# macOS builds export no FFI symbols. This script applies the 5-line patch
# (target_os=macos added to the lite gates) idempotently; Phase 1 must land
# it upstream or vendor a fork (see GO-NO-GO.md).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
THIRD_PARTY=${SIGNAL_SPIKE_THIRD_PARTY:-"$ROOT/../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"}
RINGRTC_SHA=331d601894f931337d24e9d56c68b94d28fc4555

# Writable cargo home (CI images allow ~/.cargo; sandboxes often don't —
# note mkdir alone is not a writability proof on an existing dir).
if [ -z "${CARGO_HOME:-}" ]; then
    CARGO_HOME="$HOME/.cargo"
    if ! : > "$CARGO_HOME/.spike-writetest" 2>/dev/null; then
        CARGO_HOME="$THIRD_PARTY/../cargo-home"
        mkdir -p "$CARGO_HOME"
    else
        rm -f "$CARGO_HOME/.spike-writetest"
    fi
    export CARGO_HOME
fi

command -v cargo >/dev/null 2>&1 || {
    echo 'error: cargo required on PATH' >&2
    exit 2
}
command -v protoc >/dev/null 2>&1 || {
    echo 'error: protoc required on PATH (brew install protobuf)' >&2
    exit 2
}
command -v python3 >/dev/null 2>&1 || {
    echo 'error: python3 required on PATH' >&2
    exit 2
}

if [ ! -d "$THIRD_PARTY/ringrtc/.git" ]; then
    mkdir -p "$THIRD_PARTY"
    git clone https://github.com/signalapp/ringrtc.git "$THIRD_PARTY/ringrtc"
fi
git -C "$THIRD_PARTY/ringrtc" fetch --depth 1 origin "$RINGRTC_SHA"
# Only our own cfg patch may dirty the tree; anything else aborts.
UNEXPECTED=$(git -C "$THIRD_PARTY/ringrtc" diff --name-only | grep -v '^src/rust/src/lite/' || true)
if [ -n "$UNEXPECTED" ]; then
    echo 'error: ringrtc checkout has unexpected local changes:' >&2
    echo "$UNEXPECTED" >&2
    exit 3
fi
git -C "$THIRD_PARTY/ringrtc" checkout --detach -f "$RINGRTC_SHA"

{ grep -rl 'any(target_os = "ios", feature = "check-all")' \
    "$THIRD_PARTY/ringrtc/src/rust/src/lite/" 2>/dev/null || true; } \
    | while IFS= read -r f; do
        # -i.bak works on both BSD and GNU sed.
        sed -i.bak 's/any(target_os = "ios", feature = "check-all")/any(target_os = "ios", target_os = "macos", feature = "check-all")/g' "$f"
        rm -f "$f.bak"
    done
# No matches once patched (idempotent on re-runs).

(cd "$THIRD_PARTY/ringrtc" && cargo build -p ringrtc)
ls -la "$THIRD_PARTY/ringrtc/target/debug/libringrtc.a"

WEBRTC_TAG=$(grep '^webrtc.version=' "$THIRD_PARTY/ringrtc/config/version.properties" | cut -d= -f2)
mkdir -p "$THIRD_PARTY/webrtc-archives" "$THIRD_PARTY/ringrtc-webrtc"
python3 "$THIRD_PARTY/ringrtc/bin/fetch-artifact.py" -p mac-arm64 \
    --webrtc-version "$WEBRTC_TAG" \
    -o "$THIRD_PARTY/ringrtc-webrtc" \
    --archive-dir "$THIRD_PARTY/webrtc-archives"
ls -la "$THIRD_PARTY/ringrtc-webrtc/release/obj/libwebrtc.a"
