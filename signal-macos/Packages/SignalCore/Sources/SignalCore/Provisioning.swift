// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LibSignalClient
import SwiftProtobuf

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
}

/// Everything the primary device hands over during linking: account
/// identity (ACI and PNI), the profile key, and the one-time code the chat
/// service expects back in `PUT v1/devices/link`.
public struct ProvisionedAccount: Sendable {
    public let aci: String
    public let pni: String
    public let aciIdentity: IdentityKeyPair
    public let pniIdentity: IdentityKeyPair
    public let profileKey: Data
    public let provisioningCode: String
    public let number: String

    public init(
        aci: String,
        pni: String,
        aciIdentity: IdentityKeyPair,
        pniIdentity: IdentityKeyPair,
        profileKey: Data,
        provisioningCode: String,
        number: String
    ) {
        self.aci = aci
        self.pni = pni
        self.aciIdentity = aciIdentity
        self.pniIdentity = pniIdentity
        self.profileKey = profileKey
        self.provisioningCode = provisioningCode
        self.number = number
    }
}

/// Registration ids are drawn from 1..<16383 (ts/Crypto.node.ts:44).
public func generateRegistrationId() -> UInt32 {
    UInt32.random(in: 1..<16383)
}

extension Provisioning {
    /// The device-link QR payload, mirroring `linkDeviceRoute.toAppUrl` in
    /// ts/util/signalRoutes.std.ts: `URLSearchParams` over standard base64
    /// (with padding) of the type-prefixed public key, so `+ / = ,` are
    /// percent-encoded.
    public static func linkURL(address: String, publicKey: PublicKey) -> URL {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "*-._")
        func encode(_ value: String) -> String {
            value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
        }
        let query = [
            ("uuid", address),
            ("pub_key", publicKey.serialize().base64EncodedString()),
            ("capabilities", "nopni,nopni2"),
        ]
        .map { "\($0.0)=\(encode($0.1))" }
        .joined(separator: "&")
        // Every component is percent-encoded above, so this cannot fail.
        return URL(string: "sgnl://linkdevice?\(query)")!
    }

    /// Decrypts `envelopeData` and returns credentials for `deviceId`.
    /// Async for forward compatibility with the transport-driven flow;
    /// the offline decrypt itself does not suspend.
    public func link(envelopeData: Data, deviceId: UInt32) async throws -> DeviceCredentials {
        let message = try decryptMessage(envelopeData)
        return DeviceCredentials(
            aci: try Self.aci(of: message),
            deviceId: deviceId,
            password: Self.randomPassword()
        )
    }

    /// Decrypts the envelope and returns the full account. Every field the
    /// linked device cannot work without (identities, profile key, code,
    /// ACI, PNI) is required; anything missing is `envelopeInvalid`.
    public func decrypt(envelope envelopeData: Data) throws -> ProvisionedAccount {
        let message = try decryptMessage(envelopeData)
        let aci = try Self.aci(of: message)
        let pni = try Self.pni(of: message)
        guard message.hasProvisioningCode, !message.provisioningCode.isEmpty,
              message.hasProfileKey, !message.profileKey.isEmpty
        else {
            throw ProvisioningError.envelopeInvalid
        }
        do {
            let aciIdentity = try Self.identity(
                public: message.aciIdentityKeyPublic,
                private: message.aciIdentityKeyPrivate
            )
            let pniIdentity = try Self.identity(
                public: message.pniIdentityKeyPublic,
                private: message.pniIdentityKeyPrivate
            )
            return ProvisionedAccount(
                aci: aci,
                pni: pni,
                aciIdentity: aciIdentity,
                pniIdentity: pniIdentity,
                profileKey: message.profileKey,
                provisioningCode: message.provisioningCode,
                number: message.number
            )
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
    }

    /// A key pair whose halves must agree: a mismatched pair would sign
    /// prekeys the server (and peers) cannot verify.
    private static func identity(public publicBytes: Data, private privateBytes: Data) throws
        -> IdentityKeyPair
    {
        let publicKey = try PublicKey(publicBytes)
        let privateKey = try PrivateKey(privateBytes)
        guard privateKey.publicKey.serialize() == publicKey.serialize() else {
            throw ProvisioningError.envelopeInvalid
        }
        return IdentityKeyPair(publicKey: publicKey, privateKey: privateKey)
    }

    private static func uuidString(_ bytes: Data) -> String? {
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

    /// Desktop precedence (ProvisioningCipher.node.ts): binary first.
    private static func aci(of message: SignalServiceProtos_ProvisionMessage) throws -> String {
        if message.hasAciBinary, let aci = uuidString(message.aciBinary) {
            return aci
        }
        if message.hasAci, UUID(uuidString: message.aci) != nil {
            return message.aci
        }
        throw ProvisioningError.envelopeInvalid
    }

    /// Same precedence for the PNI (binary first). The string form is the
    /// untagged UUID Desktop also accepts.
    private static func pni(of message: SignalServiceProtos_ProvisionMessage) throws -> String {
        if message.hasPniBinary, let pni = uuidString(message.pniBinary) {
            return pni
        }
        if message.hasPni, UUID(uuidString: message.pni) != nil {
            return message.pni
        }
        throw ProvisioningError.envelopeInvalid
    }

    private func decryptMessage(
        _ envelopeData: Data
    ) throws -> SignalServiceProtos_ProvisionMessage {
        let envelope: SignalServiceProtos_ProvisionEnvelope
        do {
            envelope = try SignalServiceProtos_ProvisionEnvelope(serializedBytes: envelopeData)
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
        guard envelope.hasPublicKey, envelope.hasBody else {
            throw ProvisioningError.envelopeInvalid
        }
        let ephemeralBytes = envelope.publicKey
        let body = envelope.body

        let ourPrivateKey: PrivateKey
        let ephemeralPublicKey: PublicKey
        do {
            ourPrivateKey = try PrivateKey(privateKeyBytes)
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
        guard Self.constantTimeEqual(ourMac, Data(theirMac)) else {
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

        do {
            return try SignalServiceProtos_ProvisionMessage(serializedBytes: plaintext)
        } catch {
            throw ProvisioningError.envelopeInvalid
        }
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
        Data(SecureRandom.bytes(32)).base64EncodedString()
    }
}
