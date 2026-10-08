// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

/// Loads golden vectors produced by Tools/vectors/generate.mjs (Desktop's
/// own libsignal and protobuf stack). Harness only; byte fields are hex.
enum Vectors {
    struct LoadError: Error {
        let name: String
    }

    static func load(_ name: String) throws -> [String: Any] {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appending(path: "Vectors")
            .appending(path: "\(name).json")
        let data = try Data(contentsOf: url)
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw LoadError(name: name)
        }
        return object
    }

    static func data(hex: String) -> Data? {
        guard hex.count.isMultiple(of: 2) else {
            return nil
        }
        var out = Data()
        var index = hex.startIndex
        while index < hex.endIndex {
            let next = hex.index(index, offsetBy: 2)
            guard let byte = UInt8(hex[index..<next], radix: 16) else {
                return nil
            }
            out.append(byte)
            index = next
        }
        return out
    }
}
