// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LibSignalClient
import SignalCore
import SignalStorage

public struct AttachmentPointer: Sendable, Equatable {
    public let cdnKey: String
    public let digest: Data
    public let size: UInt64
    public let contentType: String

    public init(cdnKey: String, digest: Data, size: UInt64, contentType: String) {
        self.cdnKey = cdnKey
        self.digest = digest
        self.size = size
        self.contentType = contentType
    }
}

public enum AttachmentError: Error, Equatable {
    case oversize
    case digestMismatch
    case unknownKey
}

/// CDN seam: upload-form issuance + blob PUT/GET. The real implementation
/// wraps `AuthMessagesService.getUploadForm` and URLSession; tests use an
/// in-memory fake.
public protocol CDNClient: Sendable {
    func uploadForm(byteCount: UInt64) async throws -> UploadForm
    func put(_ bytes: Data, form: UploadForm) async throws -> String
    func get(cdnKey: String) async throws -> Data
}

/// Attachment upload/download with AES-256-GCM passthrough encryption.
/// The digest covers the ciphertext and is verified BEFORE decrypting.
/// Pointer + key persist in the attachments table (digest-addressed), so
/// downloads survive restarts; the message layer will carry keys in
/// DataMessage attachments (Task 6).
public final class AttachmentService: Sendable {
    /// Matches Desktop's attachment cap.
    public static let maxBytes: UInt64 = 100 * 1024 * 1024

    private let cdn: any CDNClient
    private let attachments: AttachmentTable

    public init(cdn: any CDNClient, attachments: AttachmentTable) {
        self.cdn = cdn
        self.attachments = attachments
    }

    public func upload(_ bytes: Data, contentType: String) async throws -> AttachmentPointer {
        guard UInt64(bytes.count) <= Self.maxBytes else {
            throw AttachmentError.oversize
        }
        let keyBytes = SecureRandom.bytes(32)
        let nonceBytes = SecureRandom.bytes(12)
        var ciphertext = bytes
        let encryption = try Aes256GcmEncryption(
            key: keyBytes,
            nonce: nonceBytes,
            associatedData: Data()
        )
        try encryption.encrypt(&ciphertext)
        let tag = try encryption.computeTag()
        let blob = Aes256GcmEncryptedData(
            nonce: Data(nonceBytes),
            ciphertext: ciphertext,
            authenticationTag: tag
        ).concatenate()
        let digest = Data(SHA256.hash(data: blob))

        let form = try await cdn.uploadForm(byteCount: UInt64(blob.count))
        let cdnKey = try await cdn.put(blob, form: form)
        try attachments.save(
            digest: digest,
            cdnKey: cdnKey,
            size: UInt64(bytes.count),
            contentType: contentType,
            key: Data(keyBytes)
        )
        return AttachmentPointer(
            cdnKey: cdnKey,
            digest: digest,
            size: UInt64(bytes.count),
            contentType: contentType
        )
    }

    public func download(_ pointer: AttachmentPointer) async throws -> Data {
        guard let record = try attachments.load(digest: pointer.digest) else {
            throw AttachmentError.unknownKey
        }
        let blob = try await cdn.get(cdnKey: pointer.cdnKey)
        let url = FileManager.default.temporaryDirectory
            .appending(path: "signal-attachment-\(UUID().uuidString).bin")
        do {
            try blob.write(to: url, options: .atomic)
            let stored = try Data(contentsOf: url)
            guard Data(SHA256.hash(data: stored)) == record.digest else {
                throw AttachmentError.digestMismatch
            }
            let encrypted = try Aes256GcmEncryptedData(concatenated: stored)
            let plaintext = try encrypted.decrypt(key: record.key)
            try FileManager.default.removeItem(at: url)
            return plaintext
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
