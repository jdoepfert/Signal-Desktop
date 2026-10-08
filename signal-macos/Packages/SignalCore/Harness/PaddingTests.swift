// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore
import SwiftProtobuf

/// Padding and generated-protobuf checks against golden vectors produced by
/// Desktop's own stack (Tools/vectors/generate.mjs).
func runPaddingTests() {
    do {
        let cases = try Vectors.load("padding")["cases"] as! [[String: Any]]
        for c in cases {
            let plain = Vectors.data(hex: c["plain"] as! String)!
            let padded = Vectors.data(hex: c["padded"] as! String)!
            check("PaddingTests.pad.\(plain.count)", Padding.pad(plain) == padded)
            check("PaddingTests.unpad.\(plain.count)", (try? Padding.unpad(padded)) == plain)
        }
    } catch {
        check("PaddingTests.vectors", false, "\(error)")
    }
    check(
        "PaddingTests.rejectsGarbage",
        (try? Padding.unpad(Data([0x41, 0x80, 0x00, 0x07]))) == nil
    )
    check(
        "PaddingTests.noTerminatorUnchanged",
        (try? Padding.unpad(Data([0, 0, 0]))) == Data([0, 0, 0])
    )
}

func runContentVectorTests() {
    do {
        let cases = try Vectors.load("content")["cases"] as! [[String: Any]]
        for c in cases {
            let name = c["name"] as! String
            let bytes = Vectors.data(hex: c["content"] as! String)!
            let content = try SignalServiceProtos_Content(serializedBytes: bytes)
            let dm = content.dataMessage
            var ok = dm.timestamp == (c["timestamp"] as! NSNumber).uint64Value
            if let body = c["body"] as? String {
                ok = ok && dm.body == body
            } else {
                ok = ok && !dm.hasBody
            }
            if let expire = c["expireTimer"] as? NSNumber {
                ok = ok && dm.expireTimer == expire.uint32Value
            }
            if let key = c["profileKey"] as? String {
                ok = ok && dm.profileKey == Vectors.data(hex: key)
            }
            if let emoji = c["emoji"] as? String {
                ok = ok && dm.reaction.emoji == emoji
                    && dm.reaction.targetSentTimestamp
                    == (c["targetSentTimestamp"] as! NSNumber).uint64Value
            }
            check("PaddingTests.content.decode.\(name)", ok)
            check(
                "PaddingTests.content.reencode.\(name)",
                (try? content.serializedData()) == bytes
            )
            let message = try decodeContentMessage(bytes, senderAci: "a")
            check(
                "PaddingTests.content.message.\(name)",
                message.body == dm.body && message.timestamp == dm.timestamp
                    && message.content == content
            )
        }
    } catch {
        check("PaddingTests.content", false, "\(error)")
    }
}
