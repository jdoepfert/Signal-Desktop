// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import RingRTCFFI

public enum CallsSpikeError: Error, Equatable {
    case generationFailed
    case invalidRootKey
}

public enum CallsSpike {
    /// Generates a call-link root key through the RingRTC Rust FFI and
    /// validates it through the FFI. No media devices, no network.
    public static func generateCallLinkRootKey() throws -> Data {
        final class DataBox: @unchecked Sendable {
            var data = Data()
        }
        let box = DataBox()
        let context = Unmanaged.passUnretained(box).toOpaque()
        rtc_calllinks_CallLinkRootKey_generate(context) { context, bytes in
            guard let context, bytes.count > 0, let ptr = bytes.ptr else {
                return
            }
            Unmanaged<DataBox>.fromOpaque(context).takeUnretainedValue().data = Data(
                bytes: ptr,
                count: Int(bytes.count)
            )
        }
        guard !box.data.isEmpty else {
            throw CallsSpikeError.generationFailed
        }
        let valid = box.data.withUnsafeBytes { buffer -> Bool in
            guard let base = buffer.baseAddress else {
                return false
            }
            let rtcBytes = rtc_Bytes(
                ptr: base.assumingMemoryBound(to: UInt8.self),
                count: box.data.count
            )
            return rtc_calllinks_CallLinkRootKey_validate(rtcBytes)
        }
        guard valid else {
            throw CallsSpikeError.invalidRootKey
        }
        return box.data
    }
}
