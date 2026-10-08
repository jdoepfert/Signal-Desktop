// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

// Minimal macOS bridging header for the RingRTC spike. Declares only the
// FFI entry points this spike calls, with layouts matching the cbindgen
// output (out-macos/libringrtc/ringrtc.h in the scratch checkout).
// Using the full generated header would require defining TARGET_OS_IOS;
// these declarations are platform-neutral.

#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct rtc_Bytes {
    const uint8_t *ptr;
    size_t count;
} rtc_Bytes;

void rtc_calllinks_CallLinkRootKey_generate(
    void *context,
    void (*callback)(void *context, struct rtc_Bytes result));

bool rtc_calllinks_CallLinkRootKey_validate(struct rtc_Bytes bytes);
