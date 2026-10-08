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

// Wire format per protos/DeviceMessages.proto (proto2):
//   ProvisionEnvelope { optional bytes publicKey = 1; optional bytes body = 2; }
//   ProvisionMessage  { ... optional string aci = 8; ... }
private func protoBytesField(_ number: Int, _ bytes: Data) -> Data {
    var out = Data()
    var tag = UInt64(number << 3 | 2)
    repeat {
        var byte = UInt8(tag & 0x7F)
        tag >>= 7
        if tag != 0 {
            byte |= 0x80
        }
        out.append(byte)
    } while tag != 0
    var count = bytes.count
    repeat {
        var byte = UInt8(count & 0x7F)
        count >>= 7
        if count != 0 {
            byte |= 0x80
        }
        out.append(byte)
    } while count != 0
    out.append(bytes)
    return out
}

private func randomBytes(_ count: Int) -> Data {
    Data((0..<count).map { _ in UInt8.random(in: 0...255) })
}

// Builds a ProvisionEnvelope for `aci`, encrypted to `ourPublicKey`,
// mirroring ProvisioningCipherInner.decrypt's inverse. All steps use
// trusted primitives except AES-CBC, which is independently pinned by
// testAesCbcKnownAnswer (openssl-generated vectors).
private func buildEnvelope(
    aci: String,
    ourPublicKey: PublicKey,
    aciBinary: Data? = nil,
    provisioningCode: String? = nil
) throws -> (envelope: Data, ephemeralSecret: Data) {
    let ephemeral = PrivateKey.generate()
    let agreement = ephemeral.keyAgreement(with: ourPublicKey)
    let secrets = try hkdf(
        outputLength: 64,
        inputKeyMaterial: agreement,
        salt: Data(repeating: 0, count: 32),
        info: Data("TextSecure Provisioning Message".utf8)
    )
    let cipherKey = secrets[0..<32]
    let macKey = secrets[32..<64]

    var message = Data()
    message.append(protoBytesField(8, Data(aci.utf8)))
    if let aciBinary {
        message.append(protoBytesField(17, aciBinary))
    }
    if let provisioningCode {
        message.append(protoBytesField(4, Data(provisioningCode.utf8)))
    }

    let iv = randomBytes(16)
    let ciphertext = try AesCbc.encrypt(message, key: cipherKey, iv: iv)

    var body = Data([0x01])
    body.append(iv)
    body.append(ciphertext)
    let mac = Data(
        HMAC<SHA256>.authenticationCode(
            for: body,
            using: SymmetricKey(data: macKey)
        )
    ).prefix(32)
    body.append(mac)

    var envelope = Data()
    envelope.append(protoBytesField(1, ephemeral.publicKey.serialize()))
    envelope.append(protoBytesField(2, body))
    return (envelope, ephemeral.serialize())
}

private func fixtureURL(_ name: String) -> URL {
    let thisFile = URL(filePath: #filePath)
    return thisFile
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .appending(path: "Fixtures")
        .appending(path: name)
}

private struct AesVector: Decodable {
    let plaintextUtf8: String
    let ciphertextHex: String
}

private struct AesFixture: Decodable {
    let key: String
    let iv: String
    let vectors: [AesVector]
}

func runProvisioningTests() async {
    // openssl-generated AES-256-CBC known answers, loaded from a fixture
    // file (never transcribed by hand). Independent of AesCbc.
    do {
        let data = try Data(contentsOf: fixtureURL("aes-cbc-known-answer.json"))
        let fixture = try JSONDecoder().decode(AesFixture.self, from: data)
        guard let key = Data(hexString: fixture.key),
              let iv = Data(hexString: fixture.iv)
        else {
            throw ProvisioningError.envelopeInvalid
        }
        var ok = true
        for vector in fixture.vectors {
            guard let ciphertext = Data(hexString: vector.ciphertextHex) else {
                throw ProvisioningError.envelopeInvalid
            }
            let decrypted = try AesCbc.decrypt(ciphertext, key: key, iv: iv)
            ok = ok && decrypted == Data(vector.plaintextUtf8.utf8)
        }
        // Corrupting the first block must garble deterministically (never
        // silently match): CBC propagates the damage, padding stays valid.
        if var garbled = Data(hexString: fixture.vectors[0].ciphertextHex) {
            garbled[0] ^= 0xFF
            let decrypted = try AesCbc.decrypt(garbled, key: key, iv: iv)
            ok = ok && decrypted != Data(fixture.vectors[0].plaintextUtf8.utf8)
        } else {
            ok = false
        }
        check("ProvisioningTests.testAesCbcKnownAnswer", ok)
    } catch {
        check("ProvisioningTests.testAesCbcKnownAnswer", false, "\(error)")
    }

    do {
        let ours = PrivateKey.generate()
        let expectedAci = "9d0652a3-dcc3-4d11-975f-74d61598733f"
        let (envelope, _) = try buildEnvelope(
            aci: expectedAci,
            ourPublicKey: ours.publicKey
        )
        let provisioning = Provisioning(ourPrivateKey: ours)
        let creds = try await provisioning.link(envelopeData: envelope, deviceId: 2)
        check(
            "ProvisioningTests.testProvisionEnvelopeDecrypts",
            creds.aci == expectedAci && creds.deviceId == 2 && !creds.password.isEmpty
        )
    } catch {
        check("ProvisioningTests.testProvisionEnvelopeDecrypts", false, "\(error)")
    }

    do {
        let ours = PrivateKey.generate()
        let (envelope, _) = try buildEnvelope(
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            ourPublicKey: ours.publicKey
        )
        // Stale session: decrypting with a different key must fail fast.
        let stale = Provisioning(ourPrivateKey: PrivateKey.generate())
        do {
            _ = try await stale.link(envelopeData: envelope, deviceId: 2)
            check("ProvisioningTests.testEnvelopeExpirySurfaced", false, "no error thrown")
        } catch let error as ProvisioningError {
            check(
                "ProvisioningTests.testEnvelopeExpirySurfaced",
                error == .envelopeExpired,
                "got \(error)"
            )
        }
    } catch {
        check("ProvisioningTests.testEnvelopeExpirySurfaced", false, "\(error)")
    }

    do {
        _ = try ChatTransport(host: "evil.example")
        check("ProvisioningTests.testStagingHostPinned", false, "no error thrown")
    } catch let error as ProvisioningError {
        // Asserts the specific rejection: the offline allowlist is the only
        // pinning this spike enforces. Real TLS pinning is delegated to
        // libsignal's Rust transport and is unexercised (see GO-NO-GO).
        check(
            "ProvisioningTests.testStagingHostPinned",
            error == .untrustedHost,
            "got \(error)"
        )
    } catch {
        check("ProvisioningTests.testStagingHostPinned", false, "\(error)")
    }
    do {
        let staging = try ChatTransport(host: "chat.staging.signal.org")
        let production = try ChatTransport(host: "chat.signal.org")
        check(
            "ProvisioningTests.testStagingHostPinnedStaging",
            staging.environment == .staging && production.environment == .production
        )
    } catch {
        check("ProvisioningTests.testStagingHostPinnedStaging", false, "\(error)")
    }

    // Binary ACI (field 17) wins over the string form (field 8), matching
    // Desktop's ProvisioningCipher precedence.
    do {
        let ours = PrivateKey.generate()
        let binaryUuid = Data(hexString: "6838237d02f640988110698253d15961")!
        let (envelope, _) = try buildEnvelope(
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            ourPublicKey: ours.publicKey,
            aciBinary: binaryUuid
        )
        let provisioning = Provisioning(ourPrivateKey: ours)
        let creds = try await provisioning.link(envelopeData: envelope, deviceId: 2)
        check(
            "ProvisioningTests.testProvisionEnvelopeAciPrecedence",
            creds.aci == "6838237d-02f6-4098-8110-698253d15961"
        )
    } catch {
        check("ProvisioningTests.testProvisionEnvelopeAciPrecedence", false, "\(error)")
    }

    // A non-UUID string ACI with no binary form is rejected.
    do {
        let ours = PrivateKey.generate()
        let (envelope, _) = try buildEnvelope(
            aci: "not-a-uuid",
            ourPublicKey: ours.publicKey
        )
        let provisioning = Provisioning(ourPrivateKey: ours)
        do {
            _ = try await provisioning.link(envelopeData: envelope, deviceId: 2)
            check("ProvisioningTests.testProvisionEnvelopeAciShape", false, "no error thrown")
        } catch let error as ProvisioningError {
            check(
                "ProvisioningTests.testProvisionEnvelopeAciShape",
                error == .envelopeInvalid,
                "got \(error)"
            )
        }
    } catch {
        check("ProvisioningTests.testProvisionEnvelopeAciShape", false, "\(error)")
    }
}

private extension Data {
    init?(hexString: String) {
        var bytes = [UInt8]()
        var index = hexString.startIndex
        while index < hexString.endIndex {
            let next = hexString.index(index, offsetBy: 2)
            guard next <= hexString.endIndex,
                  let byte = UInt8(hexString[index..<next], radix: 16)
            else {
                return nil
            }
            bytes.append(byte)
            index = next
        }
        self.init(bytes)
    }
}

func runProvisioningCodeTests() {
    do {
        let ours = PrivateKey.generate()
        let (envelope, _) = try buildEnvelope(
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            ourPublicKey: ours.publicKey,
            provisioningCode: "123-456"
        )
        let decoded = try Provisioning.decryptEnvelopeData(
            envelope,
            ourPrivateKeyBytes: ours.serialize()
        )
        check(
            "ProvisioningTests.testProvisioningCode",
            decoded.aci == "9d0652a3-dcc3-4d11-975f-74d61598733f"
                && decoded.provisioningCode == "123-456"
        )
    } catch {
        check("ProvisioningTests.testProvisioningCode", false, "\(error)")
    }

    // Missing code throws (registration is impossible without it).
    do {
        let ours = PrivateKey.generate()
        let (envelope, _) = try buildEnvelope(
            aci: "9d0652a3-dcc3-4d11-975f-74d61598733f",
            ourPublicKey: ours.publicKey
        )
        do {
            _ = try Provisioning.decryptEnvelopeData(
                envelope,
                ourPrivateKeyBytes: ours.serialize()
            )
            check("ProvisioningTests.testMissingCode", false, "no error thrown")
        } catch let error as ProvisioningError {
            check(
                "ProvisioningTests.testMissingCode",
                error == .envelopeInvalid,
                "got \(error)"
            )
        }
    } catch {
        check("ProvisioningTests.testMissingCode", false, "\(error)")
    }
}
