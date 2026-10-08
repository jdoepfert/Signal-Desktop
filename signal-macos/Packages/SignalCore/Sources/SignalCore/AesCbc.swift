// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation

// Minimal AES-256-CBC (FIPS-197) for provisioning-envelope decryption.
//
// libsignal's Swift bindings expose no AES-CBC primitive and CryptoKit has
// no CBC mode, so this lives here. Correctness is pinned by
// openssl-generated known-answer vectors in
// Harness/ProvisioningTests.swift (`testAesCbcKnownAnswer`), plus an
// S-box/inverse-S-box consistency assertion in the same test.

public enum AesCbcError: Error, Equatable {
    case invalidKeyLength
    case invalidIvLength
    case invalidInputLength
    case invalidPadding
}

private func gfMul(_ a: UInt8, _ b: UInt8) -> UInt8 {
    var a = a
    var b = b
    var result: UInt8 = 0
    for _ in 0..<8 {
        if b & 1 != 0 {
            result ^= a
        }
        let carry = a & 0x80 != 0
        a <<= 1
        if carry {
            a ^= 0x1b
        }
        b >>= 1
    }
    return result
}

private func gfPow(_ base: UInt8, _ exponent: Int) -> UInt8 {
    var result: UInt8 = 1
    var base = base
    var exponent = exponent
    while exponent > 0 {
        if exponent & 1 != 0 {
            result = gfMul(result, base)
        }
        base = gfMul(base, base)
        exponent >>= 1
    }
    return result
}

private func rotl8(_ value: UInt8, _ shift: Int) -> UInt8 {
    (value << shift) | (value >> (8 - shift))
}

/// FIPS-197 §5.1.1 S-box, computed from the field inverse plus the affine
/// transform — no transcribed tables, so no transcription errors.
private func buildSbox() -> [UInt8] {
    (0..<256).map { i in
        let x = UInt8(i)
        let inverse = x == 0 ? 0 : gfPow(x, 254)
        return inverse ^ rotl8(inverse, 1) ^ rotl8(inverse, 2)
            ^ rotl8(inverse, 3) ^ rotl8(inverse, 4) ^ 0x63
    }
}

private func buildInvSbox(sbox: [UInt8]) -> [UInt8] {
    var inv = [UInt8](repeating: 0, count: 256)
    for i in 0..<256 {
        inv[Int(sbox[i])] = UInt8(i)
    }
    return inv
}

private let sbox = buildSbox()
private let invSbox = buildInvSbox(sbox: sbox)

// First 10 round constants (FIPS-197 §5.2); AES-256 needs rcon[0..<7].
private let rcon: [UInt8] = [
    0x01, 0x02, 0x04, 0x08, 0x10, 0x20, 0x40, 0x80, 0x1b, 0x36,
]

private func expandKey256(_ key: [UInt8]) -> [[UInt8]] {
    // 60 words of 4 bytes for AES-256 (Nr = 14).
    var words = [[UInt8]](repeating: [UInt8](repeating: 0, count: 4), count: 60)
    for i in 0..<8 {
        words[i] = Array(key[(i * 4)..<(i * 4 + 4)])
    }
    for i in 8..<60 {
        var temp = words[i - 1]
        if i % 8 == 0 {
            temp = [
                sbox[Int(temp[1])] ^ rcon[i / 8 - 1],
                sbox[Int(temp[2])],
                sbox[Int(temp[3])],
                sbox[Int(temp[0])],
            ]
        } else if i % 8 == 4 {
            temp = temp.map { sbox[Int($0)] }
        }
        words[i] = zip(words[i - 8], temp).map(^)
    }
    // Group into 15 round keys of 16 bytes.
    var rounds = [[UInt8]]()
    for round in 0..<15 {
        rounds.append(Array(words[(round * 4)..<(round * 4 + 4)].joined()))
    }
    return rounds
}

private func addRoundKey(_ state: inout [UInt8], _ roundKey: [UInt8]) {
    for i in 0..<16 {
        state[i] ^= roundKey[i]
    }
}

private func invShiftRows(_ state: inout [UInt8]) {
    // State is column-major: state[row + 4*col]. Inverse shift right by row.
    var next = state
    for row in 0..<4 {
        for col in 0..<4 {
            next[row + 4 * col] = state[row + 4 * ((col - row + 4) % 4)]
        }
    }
    state = next
}

private func shiftRows(_ state: inout [UInt8]) {
    var next = state
    for row in 0..<4 {
        for col in 0..<4 {
            next[row + 4 * col] = state[row + 4 * ((col + row) % 4)]
        }
    }
    state = next
}

private func invMixColumns(_ state: inout [UInt8]) {
    for col in 0..<4 {
        let a0 = state[0 + 4 * col]
        let a1 = state[1 + 4 * col]
        let a2 = state[2 + 4 * col]
        let a3 = state[3 + 4 * col]
        state[0 + 4 * col] = gfMul(a0, 0x0e) ^ gfMul(a1, 0x0b) ^ gfMul(a2, 0x0d) ^ gfMul(a3, 0x09)
        state[1 + 4 * col] = gfMul(a0, 0x09) ^ gfMul(a1, 0x0e) ^ gfMul(a2, 0x0b) ^ gfMul(a3, 0x0d)
        state[2 + 4 * col] = gfMul(a0, 0x0d) ^ gfMul(a1, 0x09) ^ gfMul(a2, 0x0e) ^ gfMul(a3, 0x0b)
        state[3 + 4 * col] = gfMul(a0, 0x0b) ^ gfMul(a1, 0x0d) ^ gfMul(a2, 0x09) ^ gfMul(a3, 0x0e)
    }
}

private func mixColumns(_ state: inout [UInt8]) {
    for col in 0..<4 {
        let a0 = state[0 + 4 * col]
        let a1 = state[1 + 4 * col]
        let a2 = state[2 + 4 * col]
        let a3 = state[3 + 4 * col]
        state[0 + 4 * col] = gfMul(a0, 0x02) ^ gfMul(a1, 0x03) ^ a2 ^ a3
        state[1 + 4 * col] = a0 ^ gfMul(a1, 0x02) ^ gfMul(a2, 0x03) ^ a3
        state[2 + 4 * col] = a0 ^ a1 ^ gfMul(a2, 0x02) ^ gfMul(a3, 0x03)
        state[3 + 4 * col] = gfMul(a0, 0x03) ^ a1 ^ a2 ^ gfMul(a3, 0x02)
    }
}

private func invCipherBlock(_ block: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
    // Direct Inverse Cipher (FIPS-197 §5.3): the reordered "equivalent"
    // form would need InvMixColumns applied to the round keys, so the
    // direct form with original keys is used instead.
    var state = block
    addRoundKey(&state, roundKeys[14])
    invShiftRows(&state)
    state = state.map { invSbox[Int($0)] }
    for round in (1..<14).reversed() {
        addRoundKey(&state, roundKeys[round])
        invMixColumns(&state)
        invShiftRows(&state)
        state = state.map { invSbox[Int($0)] }
    }
    addRoundKey(&state, roundKeys[0])
    return state
}

private func cipherBlock(_ block: [UInt8], roundKeys: [[UInt8]]) -> [UInt8] {
    var state = block
    addRoundKey(&state, roundKeys[0])
    for round in 1..<14 {
        state = state.map { sbox[Int($0)] }
        shiftRows(&state)
        mixColumns(&state)
        addRoundKey(&state, roundKeys[round])
    }
    state = state.map { sbox[Int($0)] }
    shiftRows(&state)
    addRoundKey(&state, roundKeys[14])
    return state
}

public enum AesCbc {
    private static func checkLengths(key: [UInt8], iv: [UInt8]) throws {
        guard key.count == 32 else {
            throw AesCbcError.invalidKeyLength
        }
        guard iv.count == 16 else {
            throw AesCbcError.invalidIvLength
        }
    }

    /// Decrypts AES-256-CBC with PKCS#7 unpadding.
    public static func decrypt(
        _ ciphertext: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        let input = [UInt8](ciphertext)
        try checkLengths(key: keyBytes, iv: ivBytes)
        guard !input.isEmpty, input.count % 16 == 0 else {
            throw AesCbcError.invalidInputLength
        }
        let roundKeys = expandKey256(keyBytes)
        var previous = ivBytes
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        for offset in stride(from: 0, to: input.count, by: 16) {
            let block = Array(input[offset..<(offset + 16)])
            let decrypted = invCipherBlock(block, roundKeys: roundKeys)
            out.append(contentsOf: zip(decrypted, previous).map(^))
            previous = block
        }
        guard let pad = out.last, pad >= 1, pad <= 16 else {
            throw AesCbcError.invalidPadding
        }
        let padCount = Int(pad)
        guard out.count >= padCount,
              out.suffix(padCount).allSatisfy({ $0 == pad })
        else {
            throw AesCbcError.invalidPadding
        }
        return Data(out.dropLast(padCount))
    }

    /// Encrypts AES-256-CBC with PKCS#7 padding. Used only to assemble test
    /// fixtures; decryption is the independently pinned direction.
    public static func encrypt(
        _ plaintext: Data,
        key: Data,
        iv: Data
    ) throws -> Data {
        let keyBytes = [UInt8](key)
        let ivBytes = [UInt8](iv)
        try checkLengths(key: keyBytes, iv: ivBytes)
        var input = [UInt8](plaintext)
        let padCount = 16 - (input.count % 16)
        input.append(contentsOf: [UInt8](repeating: UInt8(padCount), count: padCount))
        let roundKeys = expandKey256(keyBytes)
        var previous = ivBytes
        var out = [UInt8]()
        out.reserveCapacity(input.count)
        for offset in stride(from: 0, to: input.count, by: 16) {
            let xored = Array(zip(
                input[offset..<(offset + 16)],
                previous
            ).map(^))
            let block = cipherBlock(xored, roundKeys: roundKeys)
            out.append(contentsOf: block)
            previous = block
        }
        return Data(out)
    }
}
