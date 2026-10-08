// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalMessaging
import SignalStorage

/// Scripted CDN: stores blobs by key, optional tampering on read.
final class FakeCDN: CDNClient, @unchecked Sendable {
    private let lock = NSLock()
    private var blobs = [String: Data]()
    nonisolated(unsafe) var tamperNextRead = false
    nonisolated(unsafe) var formCalls = 0

    func uploadForm(byteCount: UInt64) async throws -> UploadForm {
        lock.withLock { formCalls += 1 }
        return UploadForm(
            cdn: 0,
            key: "key-\(byteCount)",
            headers: [:],
            signedUploadUrl: URL(string: "https://example.invalid/upload")!
        )
    }

    func put(_ bytes: Data, form: UploadForm) async throws -> String {
        lock.withLock { blobs[form.key] = bytes }
        return form.key
    }

    func get(cdnKey: String) async throws -> Data {
        guard var blob = lock.withLock({ blobs[cdnKey] }) else {
            throw AttachmentError.unknownKey
        }
        if tamperNextRead {
            tamperNextRead = false
            blob[0] ^= 0xFF
        }
        return blob
    }
}

private func attachmentTempLeftovers() -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: FileManager.default.temporaryDirectory.path)) ?? []
}

func runAttachmentTests() async {
    // Upload round-trips bytes with a matching digest.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let service = AttachmentService(cdn: FakeCDN(), attachments: AttachmentTable(queue: db.queue))
        let original = Data("attachment-bytes-1234567890".utf8)
        let pointer = try await service.upload(original, contentType: "text/plain")
        let roundTripped = try await service.download(pointer)
        check(
            "MessagingTests.testAttachmentRoundTrip",
            roundTripped == original
                && pointer.size == UInt64(original.count)
                && pointer.contentType == "text/plain"
                && !pointer.digest.isEmpty
        )
    } catch {
        check("MessagingTests.testAttachmentRoundTrip", false, "\(error)")
    }

    // Tampered bytes throw and leave no partial file.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let cdn = FakeCDN()
        let service = AttachmentService(cdn: cdn, attachments: AttachmentTable(queue: db.queue))
        let pointer = try await service.upload(Data("secret-bytes".utf8), contentType: "text/plain")
        cdn.tamperNextRead = true
        do {
            _ = try await service.download(pointer)
            check("MessagingTests.testAttachmentTamper", false, "no error thrown")
        } catch let error as AttachmentError {
            let leftovers = attachmentTempLeftovers().filter { $0.hasPrefix("signal-attachment-") }
            check(
                "MessagingTests.testAttachmentTamper",
                error == .digestMismatch && leftovers.isEmpty,
                "\(leftovers)"
            )
        }
    } catch {
        check("MessagingTests.testAttachmentTamper", false, "\(error)")
    }

    // Oversize input throws before upload.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let cdn = FakeCDN()
        let service = AttachmentService(cdn: cdn, attachments: AttachmentTable(queue: db.queue))
        do {
            _ = try await service.upload(Data(repeating: 0, count: 100 * 1024 * 1024 + 1), contentType: "application/octet-stream")
            check("MessagingTests.testAttachmentOversize", false, "no error thrown")
        } catch let error as AttachmentError {
            check(
                "MessagingTests.testAttachmentOversize",
                error == .oversize && cdn.formCalls == 0
            )
        }
    } catch {
        check("MessagingTests.testAttachmentOversize", false, "\(error)")
    }

    // Pointer + key survive reopen (durable, not just in-memory): fresh
    // service, same CDN (CDNs persist), reopened database.
    do {
        let path = FileManager.default.temporaryDirectory
            .appending(path: "spike-attach-\(UUID().uuidString).sqlite").path
        let original = Data("durable-bytes".utf8)
        let cdn = FakeCDN()
        let pointer: AttachmentPointer
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let service = AttachmentService(cdn: cdn, attachments: AttachmentTable(queue: db.queue))
            pointer = try await service.upload(original, contentType: "text/plain")
        }
        do {
            let db = try SignalDatabase.open(path: path, key: "k")
            let fresh = AttachmentService(cdn: cdn, attachments: AttachmentTable(queue: db.queue))
            let roundTripped = try await fresh.download(pointer)
            check("MessagingTests.testAttachmentDurable", roundTripped == original)
        }
        try? FileManager.default.removeItem(atPath: path)
    } catch {
        check("MessagingTests.testAttachmentDurable", false, "\(error)")
    }
}
