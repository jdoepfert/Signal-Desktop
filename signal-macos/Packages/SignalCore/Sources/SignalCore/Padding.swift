// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

public enum PaddingError: Error, Equatable {
    case invalid
}

/// Message padding, ported from Desktop: `getPaddedMessageLength` /
/// `padMessage` (ts/textsecure/OutgoingMessage.preload.ts, PADDING_BLOCK = 80)
/// and `MessageReceiver.#unpad`. Golden vectors: Vectors/padding.json.
public enum Padding {
    static let block = 80

    private static func paddedMessageLength(_ messageLength: Int) -> Int {
        let withTerminator = messageLength + 1
        var parts = withTerminator / block
        if withTerminator % block != 0 {
            parts += 1
        }
        return parts * block
    }

    /// plain + 0x80 + zero fill. Mirrors Desktop's
    /// `new Uint8Array(getPaddedMessageLength(len + 1) - 1)`.
    public static func pad(_ plain: Data) -> Data {
        var out = Data(plain)
        out.append(0x80)
        let total = paddedMessageLength(plain.count + 1) - 1
        out.append(contentsOf: [UInt8](repeating: 0, count: total - out.count))
        return out
    }

    /// Scans back over zero bytes to the 0x80 terminator. Any other byte
    /// first is invalid; no terminator at all returns the input unchanged
    /// (as Desktop does).
    public static func unpad(_ padded: Data) throws -> Data {
        var index = padded.endIndex
        while index > padded.startIndex {
            index = padded.index(before: index)
            let byte = padded[index]
            if byte == 0x80 {
                return Data(padded[padded.startIndex..<index])
            }
            if byte != 0x00 {
                throw PaddingError.invalid
            }
        }
        return padded
    }
}
