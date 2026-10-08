#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Builds libsignal_ffi.a for the pinned libsignal revision.
# Produces: <third-party>/libsignal/target/debug/libsignal_ffi.a
# Requires: cargo, protoc on PATH.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
THIRD_PARTY=${SIGNAL_SPIKE_THIRD_PARTY:-"$ROOT/../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"}
LIBSIGNAL_SHA=4beb029d8a941f81e7d9c6d8af1ed25a677569a8

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

if [ ! -d "$THIRD_PARTY/libsignal/.git" ]; then
    mkdir -p "$THIRD_PARTY"
    git clone --filter=blob:none https://github.com/signalapp/libsignal.git \
        "$THIRD_PARTY/libsignal"
fi
git -C "$THIRD_PARTY/libsignal" fetch --depth 1 origin "$LIBSIGNAL_SHA"
if ! git -C "$THIRD_PARTY/libsignal" diff --quiet; then
    echo 'error: libsignal checkout has local changes; want a pristine pin' >&2
    exit 3
fi
git -C "$THIRD_PARTY/libsignal" checkout --detach "$LIBSIGNAL_SHA"
git -C "$THIRD_PARTY/libsignal" sparse-checkout set swift rust bin

(cd "$THIRD_PARTY/libsignal" && ./swift/build_ffi.sh)
ls -la "$THIRD_PARTY/libsignal/target/debug/libsignal_ffi.a"
