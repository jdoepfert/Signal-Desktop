// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Minimal proto2 encoder for the two shapes MessagePipe emits
/// (Content{dataMessage} / DataMessage{body,timestamp}). Scoped to exactly
/// those shapes — field numbers above 15 need multi-byte tags, which this
/// encoder does not produce. Real protobuf arrives with Phase 2 UI.
enum ContentCodec {
    static func lengthDelimitedField(_ number: Int, _ bytes: Data) -> Data {
        var out = Data()
        out.append(UInt8(number << 3 | 2))
        out.append(contentsOf: varintBytes(bytes.count))
        out.append(bytes)
        return out
    }

    static func varintField(_ number: Int, _ value: UInt64) -> Data {
        var out = Data()
        out.append(UInt8(number << 3))
        out.append(contentsOf: varintBytes(value))
        return out
    }

    private static func varintBytes(_ value: Int) -> [UInt8] {
        varintBytes(UInt64(value))
    }

    private static func varintBytes(_ value: UInt64) -> [UInt8] {
        var out = [UInt8]()
        var rest = value
        repeat {
            var byte = UInt8(rest & 0x7F)
            rest >>= 7
            if rest != 0 {
                byte |= 0x80
            }
            out.append(byte)
        } while rest != 0
        return out
    }
}
