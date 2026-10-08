#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Linux verification lane: builds SpikeHarness with strict concurrency and
# runs it (macOS-only checks are compiled out; see CI-LANE.md). Extra args
# go to the harness (e.g. a filter substring). Exits with the harness status.
# Requires: Swift 6.3.3, libsqlite3-dev, and libsignal_ffi.a built via
# Tools/build-ffi.sh.
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
if [ -d /opt/swift/usr/bin ]; then
    PATH="/opt/swift/usr/bin:$PATH"
    export PATH
fi
cd "$ROOT"

# Linux resolves a different graph (upstream GRDB, swift-crypto), which
# would rewrite the macOS-owned Package.resolved: restore it on exit.
RESOLVED_BACKUP=$(mktemp)
cp Package.resolved "$RESOLVED_BACKUP"
trap 'cp "$RESOLVED_BACKUP" Package.resolved; rm -f "$RESOLVED_BACKUP"' EXIT

SWIFT_FLAGS="-Xswiftc -strict-concurrency=complete"
swift build --product SpikeHarness $SWIFT_FLAGS
status=0
# Same flags as the build, so swift run reuses it instead of rebuilding.
swift run $SWIFT_FLAGS SpikeHarness "$@" || status=$?
exit "$status"
