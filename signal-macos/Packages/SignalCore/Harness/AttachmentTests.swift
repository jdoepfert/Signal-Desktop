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

    func seed(key: String, blob: Data) {
        lock.withLock { blobs[key] = blob }
    }

    func stored(key: String) -> Data? {
        lock.withLock { blobs[key] }
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

private func attachmentFixture() throws -> (
    plain: Data, keys: Data, blob: Data, digest: Data, size: UInt64
) {
    let v = try Vectors.load("attachment")
    guard
        let plainHex = v["plainHex"] as? String, let plain = Vectors.data(hex: plainHex),
        let keysHex = v["keysHex"] as? String, let keys = Vectors.data(hex: keysHex),
        let blobHex = v["blobHex"] as? String, let blob = Vectors.data(hex: blobHex),
        let digestHex = v["digestHex"] as? String, let digest = Vectors.data(hex: digestHex),
        let size = v["size"] as? Int
    else {
        throw Vectors.LoadError(name: "attachment")
    }
    return (plain, keys, blob, digest, UInt64(size))
}

func runAttachmentCryptoTests() async {
    // Oracle decrypt: blob under keys yields the plain bytes, digest verifies.
    do {
        let fixture = try attachmentFixture()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let table = AttachmentTable(queue: db.queue)
        let cdn = FakeCDN()
        try table.save(
            digest: fixture.digest, cdnKey: "cdn-key", size: fixture.size,
            contentType: "text/plain", key: fixture.keys
        )
        cdn.seed(key: "cdn-key", blob: fixture.blob)
        let service = AttachmentService(cdn: cdn, attachments: table)
        let pointer = AttachmentPointer(
            cdnKey: "cdn-key", digest: fixture.digest, size: fixture.size,
            contentType: "text/plain", key: fixture.keys
        )
        let decrypted = try await service.download(pointer)
        check(
            "MessagingTests.testAttachmentDecryptCBC",
            decrypted == fixture.plain
        )
    } catch {
        check("MessagingTests.testAttachmentDecryptCBC", false, "\(error)")
    }

    // Flipped MAC byte throws and leaves no partial file.
    do {
        let fixture = try attachmentFixture()
        let db = try SignalDatabase.open(path: nil, key: "k")
        let table = AttachmentTable(queue: db.queue)
        let cdn = FakeCDN()
        try table.save(
            digest: fixture.digest, cdnKey: "cdn-key", size: fixture.size,
            contentType: "text/plain", key: fixture.keys
        )
        var tampered = fixture.blob
        tampered[tampered.count - 1] ^= 0xFF
        cdn.seed(key: "cdn-key", blob: tampered)
        let service = AttachmentService(cdn: cdn, attachments: table)
        let pointer = AttachmentPointer(
            cdnKey: "cdn-key", digest: fixture.digest, size: fixture.size,
            contentType: "text/plain", key: fixture.keys
        )
        do {
            _ = try await service.download(pointer)
            check("MessagingTests.testAttachmentTamperCBC", false, "no error thrown")
        } catch let error as AttachmentError {
            let leftovers = attachmentTempLeftovers().filter { $0.hasPrefix("signal-attachment-") }
            check(
                "MessagingTests.testAttachmentTamperCBC",
                error == .digestMismatch && leftovers.isEmpty,
                "\(leftovers)"
            )
        }
    } catch {
        check("MessagingTests.testAttachmentTamperCBC", false, "\(error)")
    }

    // Upload carries the key: the stored blob decrypts under pointer.key.
    do {
        let db = try SignalDatabase.open(path: nil, key: "k")
        let cdn = FakeCDN()
        let table = AttachmentTable(queue: db.queue)
        let service = AttachmentService(cdn: cdn, attachments: table)
        let original = Data("carries-its-key".utf8)
        let pointer = try await service.upload(original, contentType: "text/plain")
        let stored = cdn.stored(key: pointer.cdnKey)
        let record = try table.load(digest: pointer.digest)
        check(
            "MessagingTests.testAttachmentUploadPointerCarriesKey",
            pointer.key.count == 64
                && record?.key == pointer.key
                && stored != nil
                && (try? AttachmentCrypto.decrypt(blob: stored!, key: pointer.key, size: pointer.size)) == original
        )
    } catch {
        check("MessagingTests.testAttachmentUploadPointerCarriesKey", false, "\(error)")
    }
}
