#!/bin/sh
# Copyright 2026 Signal Messenger, LLC
# SPDX-License-Identifier: AGPL-3.0-only
#
# Prints pinned third-party versions as space-separated KEY=value pairs:
#   libsignal=<sha> ringrtc=<sha> webrtc=<tag>
# CI asserts these equal the pinned constants (see spike-ci.yml).
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
# Third-party checkouts live in the spike's workspace dir (all manifests
# point there); override only to relocate the whole tree together.
THIRD_PARTY=${SIGNAL_SPIKE_THIRD_PARTY:-"$ROOT/../.superpowers/sdd/2026-10-07-native-swift-spike/third-party"}

LIBSIGNAL_SHA=$(git -C "$THIRD_PARTY/libsignal" rev-parse HEAD)
RINGRTC_SHA=$(git -C "$THIRD_PARTY/ringrtc" rev-parse HEAD)
WEBRTC_TAG=$(grep '^webrtc.version=' "$THIRD_PARTY/ringrtc/config/version.properties" | cut -d= -f2)

echo "libsignal=$LIBSIGNAL_SHA ringrtc=$RINGRTC_SHA webrtc=$WEBRTC_TAG"
