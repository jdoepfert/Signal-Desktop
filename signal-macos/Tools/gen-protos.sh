#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Regenerates Packages/SignalCore/Sources/SignalCore/Proto from Desktop's own
# protos/ (single source of truth). Requires `protoc` and a protoc-gen-swift
# built from the SAME swift-protobuf version the manifests pin; the plugin is
# built from the resolved checkout (.build/checkouts/swift-protobuf) when no
# matching one is on PATH. Fails loudly on a version mismatch.
#
# CI check: Tools/gen-protos.sh && git diff --exit-code Packages/SignalCore/Sources/SignalCore/Proto
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
REPO=$(CDPATH= cd -- "$ROOT/.." && pwd)
if [ -d /opt/swift/usr/bin ]; then
    PATH="/opt/swift/usr/bin:$PATH"
    export PATH
fi
cd "$ROOT"

PINNED=$(sed -n 's|.*swift-protobuf.git", exact: "\([^"]*\)".*|\1|p' Package.swift | head -1)
[ -n "$PINNED" ] || { echo "gen-protos: no swift-protobuf pin in Package.swift" >&2; exit 1; }
for m in Packages/SignalCore/Package.swift Packages/SignalMessaging/Package.swift; do
    grep -q "swift-protobuf.git\", exact: \"$PINNED\"" "$m" \
        || { echo "gen-protos: $m does not pin swift-protobuf $PINNED" >&2; exit 1; }
done

command -v protoc >/dev/null || { echo "gen-protos: protoc not found" >&2; exit 1; }

PLUGIN=""
CHECKOUT="$ROOT/.build/checkouts/swift-protobuf"
if [ -n "${PROTOC_GEN_SWIFT:-}" ]; then
    PLUGIN="$PROTOC_GEN_SWIFT"
else
    if [ ! -d "$CHECKOUT" ]; then
        swift package resolve
    fi
    # Build the plugin from the exact resolved checkout into its own scratch
    # dir so it never disturbs the main build.
    swift build -c release --product protoc-gen-swift \
        --package-path "$CHECKOUT" --scratch-path "$ROOT/.build/protoc-gen-swift"
    PLUGIN="$ROOT/.build/protoc-gen-swift/release/protoc-gen-swift"
fi
[ -x "$PLUGIN" ] || { echo "gen-protos: plugin not executable: $PLUGIN" >&2; exit 1; }

# The plugin stamps its own version into the generated header; verify it
# matches the pin by checking the checkout (or a reported version).
if [ -d "$CHECKOUT" ]; then
    HAVE=$(git -C "$CHECKOUT" describe --tags --exact-match 2>/dev/null || true)
    if [ "$HAVE" != "$PINNED" ]; then
        echo "gen-protos: swift-protobuf checkout is '$HAVE', manifests pin $PINNED" >&2
        exit 1
    fi
fi
REPORTED=$("$PLUGIN" --version 2>&1 | sed -n 's/.*\([0-9][0-9]*\.[0-9][0-9]*\.[0-9][0-9]*\).*/\1/p' | head -1)
if [ "$REPORTED" != "$PINNED" ]; then
    echo "gen-protos: protoc-gen-swift is '$REPORTED', manifests pin $PINNED" >&2
    exit 1
fi

OUT="$ROOT/Packages/SignalCore/Sources/SignalCore/Proto"
WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# Desktop's protos carry no swift_prefix; inject one into a scratch copy
# (never edit protos/) so types come out as SignalServiceProtos_*.
for f in SignalService DeviceMessages Groups; do
    sed 's|^package signalservice;|package signalservice;\noption swift_prefix = "SignalServiceProtos_";|' \
        "$REPO/protos/$f.proto" > "$WORK/$f.proto"
done

rm -rf "$OUT"
mkdir -p "$OUT"
protoc --plugin=protoc-gen-swift="$PLUGIN" \
    --swift_out="$OUT" --swift_opt=Visibility=Public \
    -I "$WORK" "$WORK/SignalService.proto" "$WORK/DeviceMessages.proto" "$WORK/Groups.proto"
echo "gen-protos: generated with swift-protobuf $PINNED into ${OUT#"$ROOT"/}"
