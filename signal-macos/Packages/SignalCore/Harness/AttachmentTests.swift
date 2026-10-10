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

    func get(cdnKey: String, cdnNumber: UInt32) async throws -> Data {
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

private func uploadFormJSON() throws -> Data {
    try JSONSerialization.data(withJSONObject: [
        "cdn": 0,
        "key": "form-key",
        "headers": ["Content-Type": "application/octet-stream"],
        "signedUploadLocation": "https://example.invalid/signed-put",
    ])
}

func runLiveCDNTests() async {
    // Live CDN: form issuance, resumable upload (POST initiate with no
    // bytes -> `location`, single PUT with Content-Range), keyed download.
    do {
        final class FormRecorder: @unchecked Sendable {
            var paths = [String]()
        }
        let formPaths = FormRecorder()
        final class HttpRecorder: @unchecked Sendable {
            var requests = [URLRequest]()
            var postBody: Data?
            var putBody: Data?
        }
        let recorder = HttpRecorder()
        let formSend: LiveTransport.AuthenticatedSend = { request in
            formPaths.paths.append(request.pathAndQuery)
            return (200, try uploadFormJSON())
        }
        let http: LiveCDNClient.HttpSend = { request in
            recorder.requests.append(request)
            if request.httpMethod == "POST" {
                recorder.postBody = request.httpBody
                let initiate = HTTPURLResponse(
                    url: request.url!, statusCode: 200, httpVersion: nil,
                    headerFields: ["Location": "https://example.invalid/upload-bytes"]
                )!
                return (Data(), initiate)
            }
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            if request.httpMethod == "PUT" {
                recorder.putBody = request.httpBody
                return (Data(), response)
            }
            return (recorder.putBody ?? Data(), response)
        }
        let client = LiveCDNClient(
            environment: .staging, formSend: formSend, http: http
        )
        let db = try SignalDatabase.open(path: nil, key: "k")
        let service = AttachmentService(cdn: client, attachments: AttachmentTable(queue: db.queue))
        let pointer = try await service.upload(Data("live-blob".utf8), contentType: "text/plain")
        let roundTripped = try await service.download(pointer)
        let posts = recorder.requests.filter { $0.httpMethod == "POST" }
        let puts = recorder.requests.filter { $0.httpMethod == "PUT" }
        let gets = recorder.requests.filter { $0.httpMethod == "GET" }
        check(
            "MessagingTests.testAttachmentTransportRoundTrip",
            formPaths.paths == ["/v4/attachments/form/upload?uploadLength=592"]
                && roundTripped == Data("live-blob".utf8)
                && posts.count == 1
                && posts.first?.url?.absoluteString == "https://example.invalid/signed-put"
                && posts.first?.value(forHTTPHeaderField: "Content-Type") == "application/octet-stream"
                && recorder.postBody == nil
                && puts.count == 1
                && puts.first?.url?.absoluteString == "https://example.invalid/upload-bytes"
                && puts.first?.value(forHTTPHeaderField: "Content-Range") == "bytes 0-*/592"
                && recorder.putBody?.count == 592
                && gets.count == 1
                && gets.first?.url?.absoluteString == "https://cdn-staging.signal.org/attachments/\(pointer.cdnKey)",
            "formPaths=\(formPaths.paths) posts=\(posts.count) puts=\(puts.count) gets=\(gets.count)"
        )
    } catch {
        check("MessagingTests.testAttachmentTransportRoundTrip", false, "\(error)")
    }

    // Upload form with unknown extra fields still decodes (lenient decode).
    do {
        let formSend: LiveTransport.AuthenticatedSend = { _ in
            let json = try JSONSerialization.data(withJSONObject: [
                "cdn": 0,
                "key": "form-key",
                "headers": ["Content-Type": "application/octet-stream"],
                "signedUploadLocation": "https://example.invalid/signed-put",
                "someFutureField": ["nested": 1],
                "anotherUnknown": 42,
            ])
            return (200, json)
        }
        let client = LiveCDNClient(
            environment: .staging, formSend: formSend, http: { _ in throw AttachmentError.transferFailed(status: -1) }
        )
        let form = try await client.uploadForm(byteCount: 10)
        check(
            "MessagingTests.testAttachmentUploadFormIgnoresUnknownFields",
            form.cdn == 0 && form.key == "form-key"
                && form.signedUploadUrl.absoluteString == "https://example.invalid/signed-put"
        )
    } catch {
        check("MessagingTests.testAttachmentUploadFormIgnoresUnknownFields", false, "\(error)")
    }

    // Upload form HTTP 500 surfaces transferFailed(status: 500) with nothing uploaded.
    do {
        final class PutProbe: @unchecked Sendable {
            nonisolated(unsafe) var putCalls = 0
        }
        let probe = PutProbe()
        let formSend: LiveTransport.AuthenticatedSend = { _ in (500, Data()) }
        let http: LiveCDNClient.HttpSend = { request in
            probe.putCalls += 1
            let response = HTTPURLResponse(
                url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil
            )!
            return (Data(), response)
        }
        let client = LiveCDNClient(environment: .staging, formSend: formSend, http: http)
        do {
            _ = try await client.uploadForm(byteCount: 10)
            check("MessagingTests.testAttachmentUploadFormRejected", false, "no error thrown")
        } catch let error as AttachmentError {
            check(
                "MessagingTests.testAttachmentUploadFormRejected",
                error == .transferFailed(status: 500) && probe.putCalls == 0,
                "\(error) putCalls=\(probe.putCalls)"
            )
        }
    } catch {
        check("MessagingTests.testAttachmentUploadFormRejected", false, "\(error)")
    }
}
