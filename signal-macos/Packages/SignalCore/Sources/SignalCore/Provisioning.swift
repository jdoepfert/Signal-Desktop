// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import CryptoKit
import Foundation
import LibSignalClient

// Linked-device credentials. The deviceId is assigned by the chat service
// during provisioning-code verification (Phase 1); the spike takes it as
// input because the ProvisionMessage envelope carries no device id
// (cf. ts/textsecure/Provisioner.preload.ts prepareLinkData).
public struct DeviceCredentials: Sendable, Equatable {
    public let aci: String
    public let deviceId: UInt32
    public let password: String
    /// The server these credentials belong to. Credentials are inherently
    /// per-environment (issued by one chat service); default staging keeps
    /// existing call sites safe.
    public let environment: Net.Environment

    public init(
        aci: String,
        deviceId: UInt32,
        password: String,
        environment: Net.Environment = .staging
    ) {
        self.aci = aci
        self.deviceId = deviceId
        self.password = password
        self.environment = environment
    }
}

public enum ProvisioningError: Error, Equatable {
    /// Structurally invalid envelope: truncated, bad version, undecodable
    /// fields, missing identity, or undecryptable body.
    case envelopeInvalid
    /// Authentication failure (bad MAC): stale key / wrong provisioning
    /// session. Thrown promptly — never a hang. Real address expiry is
    /// server-side; the client observes it as a session timeout.
    case envelopeExpired
    /// Non-staging, non-production host passed to ChatTransport. TLS pinning
    /// itself is enforced by libsignal's Rust transport.
    case untrustedHost
    /// Empty or malformed provisioning code (rejected before any network).
    case invalidCode
    /// A network wait outlived its deadline.
    case timedOut
}

/// Minimal proto2 reader: fields keyed by field number, preserving both
/// length-delimited payloads and varint values.
enum ProtoValue: Equatable {
    case bytes(Data)
    case varint(UInt64)
}

enum ProtoFields {
    static func parse(_ data: Data) throws -> [Int: ProtoValue] {
        var fields = [Int: ProtoValue]()
        var index = data.startIndex
        while index < data.endIndex {
            let (tag, afterTag) = try readVarint(data, from: index)
            index = afterTag
            let fieldNumber = Int(tag >> 3)
            switch tag & 0x07 {
            case 0:
                let (value, afterValue) = try readVarint(data, from: index)
                fields[fieldNumber] = .varint(value)
                index = afterValue
            case 1:
                guard let end = data.index(index, offsetBy: 8, limitedBy: data.endIndex),
                      end == data.index(index, offsetBy: 8)
                else {
                    throw ProvisioningError.envelopeInvalid
                }
                index = end
            case 2:
                let (count, afterCount) = try readVarint(data, from: index)
                guard let end = data.index(
                    afterCount,
                    offsetBy: Int(count),
                    limitedBy: data.endIndex
                ),
                      data.distance(from: afterCount, to: end) == Int(count)
                else {
                    throw ProvisioningError.envelopeInvalid
                }
                fields[fieldNumber] = .bytes(data[afterCount..<end])
                index = end
            case 5:
                guard let end = data.index(index, offsetBy: 4, limitedBy: data.endIndex),
                      data.distance(from: index, to: end) == 4
                else {
                    throw ProvisioningError.envelopeInvalid
                }
                index = end
            default:
                throw ProvisioningError.envelopeInvalid
            }
        }
        return fields
    }

    static func readVarint(_ data: Data, from index: Data.Index) throws -> (UInt64, Data.Index) {
        var result: UInt64 = 0
        var shift = 0
        var index = index
        while true {
            guard index < data.endIndex, shift < 64 else {
                throw ProvisioningError.envelopeInvalid
            }
            let byte = data[index]
            index = data.index(after: index)
            result |= UInt64(byte & 0x7F) << shift
            if byte & 0x80 == 0 {
                return (result, index)
            }
            shift += 7
        }
    }

    static func uuidString(_ bytes: Data) -> String? {
        guard bytes.count == 16 else {
            return nil
        }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        func part(_ from: Int, _ to: Int) -> String {
            let start = hex.index(hex.startIndex, offsetBy: from)
            let end = hex.index(hex.startIndex, offsetBy: to)
            return String(hex[start..<end])
        }
        return "\(part(0, 8))-\(part(8, 12))-\(part(12, 16))-\(part(16, 20))-\(part(20, 32))"
    }
}

/// Secondary-device provisioning: decrypts the ProvisionEnvelope delivered
/// over the provisioning WebSocket. Mirrors
/// ts/textsecure/ProvisioningCipher.node.ts.
public struct Provisioning: Sendable {
    private let privateKeyBytes: Data

    public init(ourPrivateKey: PrivateKey) {
        self.privateKeyBytes = ourPrivateKey.serialize()
    }

    public func publicKey() throws -> PublicKey {
        do {
            return try PrivateKey(privateKeyBytes).publicKey
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
    }

    /// Decrypts `envelopeData` and returns credentials for `deviceId`.
    /// Async for forward compatibility with the transport-driven flow;
    /// the offline decrypt itself does not suspend.
    public func link(envelopeData: Data, deviceId: UInt32) async throws -> DeviceCredentials {
        let aci = try Self.decryptEnvelope(envelopeData, ourPrivateKeyBytes: privateKeyBytes)
        return DeviceCredentials(
            aci: aci,
            deviceId: deviceId,
            password: Self.randomPassword()
        )
    }

    /// Decrypts the envelope and returns the account ACI. Public so the
    /// transport layer and manual tooling can use it without minting
    /// credentials (the device id is server-assigned during verification).
    public static func decryptEnvelope(
        _ envelopeData: Data,
        ourPrivateKeyBytes: Data
    ) throws -> String {
        let envelope: [Int: ProtoValue]
        do {
            envelope = try ProtoFields.parse(envelopeData)
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
        guard case .bytes(let ephemeralBytes) = envelope[1],
              case .bytes(let body) = envelope[2]
        else {
            throw ProvisioningError.envelopeInvalid
        }

        let ourPrivateKey: PrivateKey
        let ephemeralPublicKey: PublicKey
        do {
            ourPrivateKey = try PrivateKey(ourPrivateKeyBytes)
            ephemeralPublicKey = try PublicKey(ephemeralBytes)
        } catch {
            throw ProvisioningError.envelopeInvalid
        }

        let agreement = ourPrivateKey.keyAgreement(with: ephemeralPublicKey)
        let secrets: Data
        do {
            secrets = try hkdf(
                outputLength: 64,
                inputKeyMaterial: agreement,
                salt: Data(repeating: 0, count: 32),
                info: Data("TextSecure Provisioning Message".utf8)
            )
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
        let cipherKey = secrets[0..<32]
        let macKey = secrets[32..<64]

        // body = version(1) | iv(16) | ciphertext | mac(32)
        guard body.count >= 1 + 16 + 16 + 32, body[body.startIndex] == 0x01 else {
            throw ProvisioningError.envelopeInvalid
        }
        let signed = body.prefix(body.count - 32)
        let theirMac = body.suffix(32)
        let ourMac = Data(
            HMAC<SHA256>.authenticationCode(
                for: signed,
                using: SymmetricKey(data: Data(macKey))
            )
        )
        guard constantTimeEqual(ourMac, Data(theirMac)) else {
            throw ProvisioningError.envelopeExpired
        }

        let iv = body[(body.startIndex + 1)..<(body.startIndex + 17)]
        let ciphertext = body[(body.startIndex + 17)..<(body.endIndex - 32)]
        let plaintext: Data
        do {
            plaintext = try AesCbc.decrypt(
                Data(ciphertext),
                key: Data(cipherKey),
                iv: Data(iv)
            )
        } catch {
            throw ProvisioningError.envelopeInvalid
        }

        let message: [Int: ProtoValue]
        do {
            message = try ProtoFields.parse(plaintext)
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
        // Desktop precedence (ProvisioningCipher.node.ts): binary first.
        if case .bytes(let binary) = message[17],
           let aci = ProtoFields.uuidString(binary)
        {
            return aci
        }
        if case .bytes(let aciData) = message[8],
           !aciData.isEmpty,
           let aci = String(data: aciData, encoding: .utf8),
           UUID(uuidString: aci) != nil
        {
            return aci
        }
        throw ProvisioningError.envelopeInvalid
    }

    private static func constantTimeEqual(_ lhs: Data, _ rhs: Data) -> Bool {
        guard lhs.count == rhs.count else {
            return false
        }
        var diff: UInt8 = 0
        for (a, b) in zip(lhs, rhs) {
            diff |= a ^ b
        }
        return diff == 0
    }

    private static func randomPassword() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        return Data(bytes).base64EncodedString()
    }
}
