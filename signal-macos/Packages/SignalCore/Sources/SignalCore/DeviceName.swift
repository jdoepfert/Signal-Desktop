// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LibSignalClient

public enum DeviceNameError: Error, Equatable {
    case malformed
    case macMismatch
}

/// Linked-device name encryption, a port of `encryptDeviceName` /
/// `decryptDeviceName` in `ts/Crypto.node.ts`, serialized as the
/// `DeviceName` protobuf of `protos/DeviceName.proto`
/// (`ephemeralPublic = 1`, `syntheticIv = 2`, `ciphertext = 3`, all bytes).
///
/// The name is encrypted to the account's ACI identity PUBLIC key with a
/// fresh ephemeral key: `master = ECDH(ephemeral, identity)`,
/// `syntheticIv = HMAC(HMAC(master, "auth"), plaintext)[0..<16]`,
/// `cipherKey = HMAC(HMAC(master, "cipher"), syntheticIv)`, then AES-256-CTR
/// with an all-zero counter block. The protobuf is hand-encoded (three
/// length-delimited fields) to avoid a generated type for one message.
public enum DeviceName {
    /// Serialized `DeviceName` bytes (the caller base64-encodes them for the
    /// link request). `ephemeral` is injectable only so a golden vector can
    /// pin the output.
    public static func encrypt(
        _ name: String,
        identityPublic: PublicKey,
        ephemeral: PrivateKey = PrivateKey.generate()
    ) throws -> Data {
        let plaintext = Data(name.utf8)
        let master = ephemeral.keyAgreement(with: identityPublic)
        let syntheticIv = Data(hmac(key: hmac(key: master, data: Data("auth".utf8)), data: plaintext).prefix(16))
        let cipherKey = hmac(key: hmac(key: master, data: Data("cipher".utf8)), data: syntheticIv)
        var ciphertext = plaintext
        try Aes256Ctr32.process(&ciphertext, key: cipherKey, nonce: Data(repeating: 0, count: 16))
        return field(1, ephemeral.publicKey.serialize()) + field(2, syntheticIv) + field(3, ciphertext)
    }

    /// Inverse of `encrypt`, checking the synthetic IV like Desktop does.
    public static func decrypt(_ serialized: Data, identityPrivate: PrivateKey) throws -> String {
        let fields = try parse(serialized)
        guard
            let ephemeralBytes = fields[1], let syntheticIv = fields[2], let ciphertext = fields[3],
            let ephemeralPublic = try? PublicKey(ephemeralBytes)
        else {
            throw DeviceNameError.malformed
        }
        let master = identityPrivate.keyAgreement(with: ephemeralPublic)
        let cipherKey = hmac(key: hmac(key: master, data: Data("cipher".utf8)), data: syntheticIv)
        var plaintext = ciphertext
        try Aes256Ctr32.process(&plaintext, key: cipherKey, nonce: Data(repeating: 0, count: 16))
        let ourIv = Data(hmac(key: hmac(key: master, data: Data("auth".utf8)), data: plaintext).prefix(16))
        guard ourIv == syntheticIv else {
            throw DeviceNameError.macMismatch
        }
        guard let name = String(data: plaintext, encoding: .utf8) else {
            throw DeviceNameError.malformed
        }
        return name
    }

    private static func hmac(key: Data, data: Data) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key)))
    }

    private static func field(_ number: UInt8, _ bytes: Data) -> Data {
        var out = Data([number << 3 | 2])
        var length = bytes.count
        while length >= 0x80 {
            out.append(UInt8(length & 0x7f) | 0x80)
            length >>= 7
        }
        out.append(UInt8(length))
        return out + bytes
    }

    private static func parse(_ data: Data) throws -> [UInt8: Data] {
        var fields = [UInt8: Data]()
        var index = data.startIndex
        while index < data.endIndex {
            let tag = data[index]
            index += 1
            guard tag & 7 == 2 else {
                throw DeviceNameError.malformed
            }
            var length = 0
            var shift = 0
            while true {
                guard index < data.endIndex, shift < 28 else {
                    throw DeviceNameError.malformed
                }
                let byte = data[index]
                index += 1
                length |= Int(byte & 0x7f) << shift
                shift += 7
                if byte & 0x80 == 0 {
                    break
                }
            }
            guard length <= data.endIndex - index else {
                throw DeviceNameError.malformed
            }
            fields[tag >> 3] = data[index..<(index + length)]
            index += length
        }
        return fields
    }
}
