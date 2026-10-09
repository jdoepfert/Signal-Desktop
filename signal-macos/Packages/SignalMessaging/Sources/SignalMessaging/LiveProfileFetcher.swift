// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

#if canImport(CryptoKit)
import CryptoKit
#else
import Crypto
#endif
import Foundation
import LibSignalClient
import SignalLogging

/// Sealed profile-name crypto (Desktop `ts/Crypto.node.ts:625-693`):
/// AES-256-GCM, 12-byte IV prepended, plaintext `given\0family` zero-padded.
/// Display join mirrors `ts/util/combineNames.std.ts` except CJK
/// family-first ordering, which is deferred (names still resolve, in
/// Western order); see the ledger note on Task 2.
public enum ProfileNameCrypto {
    private static let ivLength = 12

    /// Splits the sealed name, or nil when it does not decrypt or is not
    /// UTF-8. Empty names decode (to ""/nil); callers map blank to nil.
    public static func decrypt(base64: String, key: Data) -> (given: String, family: String?)? {
        guard key.count == 32, let data = Data(base64Encoded: base64), data.count > ivLength else {
            return nil
        }
        // SealedBox(combined:) takes nonce + ciphertext + tag, which is
        // exactly the wire format (IV prepended).
        guard
            let box = try? AES.GCM.SealedBox(combined: data),
            let plain = try? AES.GCM.open(box, using: SymmetricKey(data: key))
        else {
            return nil
        }
        let bytes = Data(plain)
        var givenEnd = bytes.count
        for index in bytes.indices {
            if bytes[index] == 0x00 {
                givenEnd = index
                break
            }
        }
        var familyEnd = givenEnd + 1
        while familyEnd < bytes.count, bytes[familyEnd] != 0x00 {
            familyEnd += 1
        }
        guard
            let given = String(data: bytes.prefix(givenEnd), encoding: .utf8)
        else {
            return nil
        }
        let family: String?
        if familyEnd > givenEnd + 1 {
            family = String(data: bytes[(givenEnd + 1)..<familyEnd], encoding: .utf8)
            guard family != nil else {
                return nil
            }
        } else {
            family = nil
        }
        return (given, family)
    }

    /// Display form; "" when both parts are blank so `ContactStore` falls
    /// through to phone/ACI.
    public static func displayName(given: String, family: String?) -> String {
        let trimmedGiven = given.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedFamily = (family ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        switch (trimmedGiven.isEmpty, trimmedFamily.isEmpty) {
        case (true, true):
            return ""
        case (true, false):
            return trimmedFamily
        case (false, true):
            return trimmedGiven
        case (false, false):
            return "\(trimmedGiven) \(trimmedFamily)"
        }
    }
}

/// Authenticated profile fetch over the chat socket (Desktop
/// `getProfile`, `ts/textsecure/WebAPI.preload.ts:2367-2388`): versioned
/// `GET /v1/profile/{aci}/{version}` when the recipient's profile key is
/// known, unversioned `GET /v1/profile/{aci}` otherwise. Version is
/// libsignal's `ProfileKey.getProfileKeyVersion` rendered as UTF-8 text
/// (never hand-derived). No ZK credential-request flow: version without a
/// credential request on the authenticated socket is a real Desktop path
/// (`ts/services/profiles.preload.ts:383-400`).
///
/// Never returns a cached-able lie: transport failures throw (so
/// `ProfileFetcher` does not cache them as misses and later attempts
/// retry), while semantic absence (non-2xx, missing/undecryptable/blank
/// name) returns nil. Logs status codes and error types only — never ACIs,
/// versions, names, keys or avatars.
public struct LiveProfileFetcher: Sendable {
    public typealias Keys = @Sendable (String) -> Data?

    private static let logger = Logger(subsystem: "contacts", category: "profile")

    private let profileKey: Keys
    private let send: LiveTransport.AuthenticatedSend

    public init(profileKey: @escaping Keys, send: @escaping LiveTransport.AuthenticatedSend) {
        self.profileKey = profileKey
        self.send = send
    }

    private struct ProfileJSON: Decodable {
        var name: String?
        var avatar: String?
    }

    public func fetchProfile(for aci: String) async throws -> Profile? {
        let id = aci.lowercased()
        var key = profileKey(id)
        if key?.count != 32 {
            key = nil
        }
        var path = "/v1/profile/\(id)"
        if let key, let version = Self.version(key: key, aci: id) {
            path += "/\(version)"
        } else {
            key = nil
        }
        // Transport errors propagate (never cached as misses by callers).
        let response = try await send(ChatRequest(method: "GET", pathAndQuery: path, timeout: 30))
        guard (200..<300).contains(response.status) else {
            Self.logger.error("profile fetch rejected: HTTP \(response.status)")
            return nil
        }
        guard
            let body = try? JSONDecoder().decode(ProfileJSON.self, from: response.body),
            let encrypted = body.name,
            let key,
            let split = ProfileNameCrypto.decrypt(base64: encrypted, key: key)
        else {
            return nil
        }
        let display = ProfileNameCrypto.displayName(given: split.given, family: split.family)
        guard !display.isEmpty else {
            return nil
        }
        return Profile(name: display, avatarUrl: body.avatar)
    }

    /// libsignal's version string (64 ASCII chars), or nil when the ACI or
    /// key is unusable — the caller then uses the unversioned path.
    static func version(key: Data, aci: String) -> String? {
        do {
            let userId = try Aci.parseFrom(serviceIdString: aci)
            let version = try ProfileKey(contents: key).getProfileKeyVersion(userId: userId)
            return String(data: version.serialize(), encoding: .utf8)
        } catch {
            return nil
        }
    }
}
