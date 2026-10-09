// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
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
    /// 64-byte media keys (AES-256 + HMAC-SHA256 halves), as carried in the
    /// message pointer. Present for rows we uploaded; incoming rows resolve
    /// it from the attachments table (Task 2 wires the message layer).
    public let key: Data

    public init(cdnKey: String, digest: Data, size: UInt64, contentType: String, key: Data) {
        self.cdnKey = cdnKey
        self.digest = digest
        self.size = size
        self.contentType = contentType
        self.key = key
    }
}

public enum AttachmentError: Error, Equatable {
    case oversize
    case digestMismatch
    case unknownKey
    case invalidKey
}

/// Signal attachment crypto (Desktop `ts/Crypto.node.ts:503-606`,
/// `decryptAttachmentV1` / `padAndEncryptAttachment`): AES-256-CBC with
/// PKCS#7 over zero-padded plaintext, HMAC-SHA256 over IV+ciphertext
/// appended, SHA-256 digest over the blob. Blob layout:
/// IV(16) + ciphertext + MAC(32). `size` is the unpadded plaintext length.
public enum AttachmentCrypto {
    public static let keyLength = 64
    private static let ivLength = 16
    private static let macLength = 32

    /// Desktop `logPadSize` (`ts/util/logPadSize.std.ts`): minimum 541,
    /// then 5% geometric steps.
    public static func paddedSize(_ count: Int) -> Int {
        guard count > 0 else {
            return 541
        }
        let steps = ceil(log(Double(count)) / log(1.05))
        return max(541, Int(floor(pow(1.05, steps))))
    }

    public static func digest(_ blob: Data) -> Data {
        Data(SHA256.hash(data: blob))
    }

    public static func plaintextHash(_ plain: Data) -> Data {
        Data(SHA256.hash(data: plain))
    }

    public static func encrypt(plain: Data, keys: Data, iv: Data) throws -> Data {
        guard keys.count == keyLength else {
            throw AttachmentError.invalidKey
        }
        var padded = plain
        padded.append(contentsOf: [UInt8](repeating: 0, count: paddedSize(plain.count) - plain.count))
        let ciphertext = try AesCbc.encrypt(padded, key: keys.prefix(32), iv: iv)
        var blob = Data()
        blob.append(iv)
        blob.append(ciphertext)
        blob.append(mac(key: keys.suffix(from: 32), data: blob))
        return blob
    }

    /// Verifies digest (when given), MAC, then decrypts and trims to `size`.
    /// Every integrity problem surfaces as `digestMismatch`.
    public static func decrypt(blob: Data, key: Data, size: UInt64, digest: Data? = nil) throws -> Data {
        guard key.count == keyLength, blob.count > ivLength + macLength else {
            throw AttachmentError.invalidKey
        }
        if let digest, Self.digest(blob) != digest {
            throw AttachmentError.digestMismatch
        }
        let ivAndCiphertext = blob.prefix(blob.count - macLength)
        let theirMac = blob.suffix(from: blob.count - macLength)
        guard constantTimeEqual(mac(key: key.suffix(from: 32), data: ivAndCiphertext), theirMac) else {
            throw AttachmentError.digestMismatch
        }
        let padded = try AesCbc.decrypt(
            ivAndCiphertext.dropFirst(ivLength),
            key: key.prefix(32),
            iv: blob.prefix(ivLength)
        )
        guard padded.count >= Int(size) else {
            throw AttachmentError.digestMismatch
        }
        return padded.prefix(Int(size))
    }

    private static func mac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
}

/// CDN seam: upload-form issuance + blob PUT/GET. The real implementation
/// wraps the chat socket form request and URLSession; tests use an
/// in-memory fake.
public protocol CDNClient: Sendable {
    func uploadForm(byteCount: UInt64) async throws -> UploadForm
    func put(_ bytes: Data, form: UploadForm) async throws -> String
    func get(cdnKey: String) async throws -> Data
}

/// Attachment upload/download in Signal format (see `AttachmentCrypto`).
/// The digest covers the blob and is verified BEFORE decrypting.
/// Pointer + key persist in the attachments table (digest-addressed), so
/// downloads survive restarts; the message layer carries keys in
/// DataMessage attachments.
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
        let keys = Data(SecureRandom.bytes(64))
        let iv = Data(SecureRandom.bytes(16))
        let blob = try AttachmentCrypto.encrypt(plain: bytes, keys: keys, iv: iv)
        let digest = AttachmentCrypto.digest(blob)

        let form = try await cdn.uploadForm(byteCount: UInt64(blob.count))
        let cdnKey = try await cdn.put(blob, form: form)
        try attachments.save(
            digest: digest,
            cdnKey: cdnKey,
            size: UInt64(bytes.count),
            contentType: contentType,
            key: keys
        )
        return AttachmentPointer(
            cdnKey: cdnKey,
            digest: digest,
            size: UInt64(bytes.count),
            contentType: contentType,
            key: keys
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
            guard AttachmentCrypto.digest(stored) == record.digest else {
                throw AttachmentError.digestMismatch
            }
            let plaintext = try AttachmentCrypto.decrypt(
                blob: stored,
                key: record.key,
                size: record.size
            )
            try FileManager.default.removeItem(at: url)
            return plaintext
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
    }
}
