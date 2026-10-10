// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging

/// Failures fetching server group state. Status codes only — never group
/// titles, member lists, keys, or credential bytes (see `ErrorReason`).
public enum GroupFetchError: Error, Equatable {
    case badMasterKey
    case undecodableCredentials
    case noCredentialForToday
    case noPni
    case transferFailed(status: Int)
    case undecodableGroup
}

/// One dated auth credential from `v1/certificate/auth/group`
/// (`ts/textsecure/WebAPI.preload.ts:901-904`): the base64 `credential`
/// bytes plus the server's `redemptionTime` (seconds), passed through to
/// libsignal's `receiveAuthCredentialWithPniAsServiceId` untouched.
public struct GroupCredentialEntry: Sendable, Equatable {
    public var redemptionTime: UInt64
    public var credential: Data

    public init(redemptionTime: UInt64, credential: Data) {
        self.redemptionTime = redemptionTime
        self.credential = credential
    }
}

/// Credential list plus our PNI as the server reported it (`pni` field of
/// `GetGroupCredentialsResultType`, `WebAPI.preload.ts:1035-1039`).
public struct FetchedGroupCredentials: Sendable, Equatable {
    public var pni: String?
    public var entries: [GroupCredentialEntry]

    public init(pni: String?, entries: [GroupCredentialEntry]) {
        self.pni = pni
        self.entries = entries
    }
}

/// Presentation input for the storage request. The group public params hex
/// is derived locally from the master key at request time (Desktop derives
/// it from the secret params, `ts/groups.preload.ts:4281-4291`); only the
/// presentation hex is injected.
public struct GroupFetchCredentials: Sendable, Equatable {
    public var presentationHex: String

    public init(presentationHex: String) {
        self.presentationHex = presentationHex
    }
}

/// Decrypted server group state: full member ACIs, the revision, and the
/// title when its blob decrypts (nil otherwise — display-only).
public struct FetchedGroupState: Sendable, Equatable {
    public var members: [String]
    public var revision: UInt32
    public var title: String?

    public init(members: [String], revision: UInt32, title: String?) {
        self.members = members
        self.revision = revision
        self.title = title
    }
}

/// Server group-state fetch (Desktop `getGroupCredentials` + `getGroup`,
/// `ts/textsecure/WebAPI.preload.ts:4542-4564,4871-4890`): credential chain
/// over the authenticated chat socket, then `GET {storage}/v2/groups` with
/// `Authorization: Basic base64("{groupPublicParamsHex}:{presentationHex}")`
/// (`generateGroupAuth`, `WebAPI.preload.ts:4533-4540`), `GroupResponse`
/// decode, member/title decrypt via `ClientZkGroupCipher`.
public enum GroupStateFetch {
    public typealias HttpSend = @Sendable (URLRequest) async throws -> (Data, HTTPURLResponse)

    private static let logger = Logger(subsystem: "groups", category: "fetch")

    /// Per-environment server public params, copied from Desktop's public
    /// config: `config/default.json:24` (staging),
    /// `config/production.json:12` (production). TrustRoots-style embedded
    /// constants, pinned by `testServerPublicParamsParse`.
    public static func serverPublicParamsBase64(environment: AppEnvironment) -> String {
        switch environment {
        case .staging:
            return "ABSY21VckQcbSXVNCGRYJcfWHiAMZmpTtTELcDmxgdFbtp/bWsSxZdMKzfCp8rvIs8ocCU3B37fT3r4Mi5qAemeGeR2X+/YmOGR5ofui7tD5mDQfstAI9i+4WpMtIe8KC3wU5w3Inq3uNWVmoGtpKndsNfwJrCg0Hd9zmObhypUnSkfYn2ooMOOnBpfdanRtrvetZUayDMSC5iSRcXKpdlukrpzzsCIvEwjwQlJYVPOQPj4V0F4UXXBdHSLK05uoPBCQG8G9rYIGedYsClJXnbrgGYG3eMTG5hnx4X4ntARBgELuMWWUEEfSK0mjXg+/2lPmWcTZWR9nkqgQQP0tbzuiPm74H2wMO4u1Wafe+UwyIlIT9L7KLS19Aw8r4sPrXZSSsOZ6s7M1+rTJN0bI5CKY2PX29y5Ok3jSWufIKcgKOnWoP67d5b2du2ZVJjpjfibNIHbT/cegy/sBLoFwtHogVYUewANUAXIaMPyCLRArsKhfJ5wBtTminG/PAvuBdJ70Z/bXVPf8TVsR292zQ65xwvWTejROW6AZX6aqucUjlENAErBme1YHmOSpU6tr6doJ66dPzVAWIanmO/5mgjNEDeK7DDqQdB1xd03HT2Qs2TxY3kCK8aAb/0iM0HQiXjxZ9HIgYhbtvGEnDKW5ILSUydqH/KBhW4Pb0jZWnqN/YgbWDKeJxnDbYcUob5ZY5Lt5ZCMKuaGUvCJRrCtuugSMaqjowCGRempsDdJEt+cMaalhZ6gczklJB/IbdwENW9KeVFPoFNFzhxWUIS5ML9riVYhAtE6JE5jX0xiHNVIIPthb458cfA8daR0nYfYAUKogQArm0iBezOO+mPk5vCNWI+wwkyFCqNDXz/qxl1gAntuCJtSfq9OC3NkdhQlgYQ=="
        case .production:
            return "AMhf5ywVwITZMsff/eCyudZx9JDmkkkbV6PInzG4p8x3VqVJSFiMvnvlEKWuRob/1eaIetR31IYeAbm0NdOuHH8Qi+Rexi1wLlpzIo1gstHWBfZzy1+qHRV5A4TqPp15YzBPm0WSggW6PbSn+F4lf57VCnHF7p8SvzAA2ZZJPYJURt8X7bbg+H3i+PEjH9DXItNEqs2sNcug37xZQDLm7X36nOoGPs54XsEGzPdEV+itQNGUFEjY6X9Uv+Acuks7NpyGvCoKxGwgKgE5XyJ+nNKlyHHOLb6N1NuHyBrZrgtY/JYJHRooo5CEqYKBqdFnmbTVGEkCvJKxLnjwKWf+fEPoWeQFj5ObDjcKMZf2Jm2Ae69x+ikU5gBXsRmoF94GXTLfN0/vLt98KDPnxwAQL9j5V1jGOY8jQl6MLxEs56cwXN0dqCnImzVH3TZT1cJ8SW1BRX6qIVxEzjsSGx3yxF3suAilPMqGRp4ffyopjMD1JXiKR2RwLKzizUe5e8XyGOy9fplzhw3jVzTRyUZTRSZKkMLWcQ/gv0E4aONNqs4P+NameAZYOD12qRkxosQQP5uux6B2nRyZ7sAV54DgFyLiRcq1FvwKw2EPQdk4HDoePrO/RNUbyNddnM/mMgj4FW65xCoT1LmjrIjsv/Ggdlx46ueczhMgtBunx1/w8k8V+l8LVZ8gAT6wkU5J+DPQalQguMg12Jzug3q4TbdHiGCmD9EunCwOmsLuLJkz6EcSYXtrlDEnAM+hicw7iergYLLlMXpfTdGxJCWJmP4zqUFeTTmsmhsjGBt7NiEB/9pFFEB3pSbf4iiUukw63Eo8Aqnf4iwob6X1QviCWuc8t0LUlT9vALgh/f2DPVOOmR0RW6bgRvc7DSF20V/omg+YBw=="
        }
    }

    private static func storageBase(environment: AppEnvironment) -> String {
        // `config/default.json:3` (staging), `config/production.json:3`.
        switch environment {
        case .staging:
            return "https://storage-staging.signal.org"
        case .production:
            return "https://storage.signal.org"
        }
    }

    /// Start-of-day UTC seconds for today plus tomorrow: the credential
    /// request range. Selection picks today's entry; tomorrow covers the
    /// day boundary (`getCredentialsForToday` convention).
    public static func credentialRange(now: Date = Date()) -> (startSeconds: UInt64, endSeconds: UInt64) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
        let startOfDay = calendar.startOfDay(for: now)
        let start = UInt64(startOfDay.timeIntervalSince1970)
        return (start, start + 86_400)
    }

    private struct CredentialsJSON: Decodable {
        var pni: String?
        var credentials: [Entry]
        var callLinkAuthCredentials: [Entry]?

        struct Entry: Decodable {
            var credential: String
            var redemptionTime: UInt64
        }
    }

    /// Credential list over the authenticated chat socket. Unknown fields
    /// are ignored (the server may add sibling sections).
    public static func fetchCredentials(
        chatSend: LiveTransport.AuthenticatedSend,
        startSeconds: UInt64,
        endSeconds: UInt64
    ) async throws -> FetchedGroupCredentials {
        let path =
            "/v1/certificate/auth/group?redemptionStartSeconds=\(startSeconds)&" +
            "redemptionEndSeconds=\(endSeconds)&v101=true&zkcCredential=true"
        let response = try await chatSend(ChatRequest(method: "GET", pathAndQuery: path, timeout: 30))
        guard (200..<300).contains(response.status) else {
            Self.logger.error("group credentials rejected: HTTP \(response.status)")
            throw GroupFetchError.transferFailed(status: Int(response.status))
        }
        guard let decoded = try? JSONDecoder().decode(CredentialsJSON.self, from: response.body) else {
            Self.logger.error("group credentials undecodable")
            throw GroupFetchError.undecodableCredentials
        }
        let entries = decoded.credentials.compactMap { entry -> GroupCredentialEntry? in
            guard let bytes = Data(base64Encoded: entry.credential) else {
                return nil
            }
            return GroupCredentialEntry(redemptionTime: entry.redemptionTime, credential: bytes)
        }
        guard entries.count == decoded.credentials.count else {
            Self.logger.error("group credentials undecodable")
            throw GroupFetchError.undecodableCredentials
        }
        return FetchedGroupCredentials(pni: decoded.pni, entries: entries)
    }

    /// Today's presentation from fetched credentials: receive + present
    /// (pure ZK, no I/O). The PNI is the server-reported one — the account
    /// stores no PNI, and the without-PNI path needs registration salt we
    /// do not keep, so a missing PNI throws.
    public static func makeCredentials(
        masterKey: Data,
        serverPublicParamsBase64: String,
        aci: String,
        pni: String?,
        todaySeconds: UInt64,
        entries: [GroupCredentialEntry]
    ) throws -> GroupFetchCredentials {
        guard masterKey.count == GroupMasterKey.SIZE else {
            throw GroupFetchError.badMasterKey
        }
        guard
            let entry = entries.first(where: { $0.redemptionTime == todaySeconds })
        else {
            Self.logger.error("no group credential for today")
            throw GroupFetchError.noCredentialForToday
        }
        guard let pni else {
            Self.logger.error("group credentials report no PNI")
            throw GroupFetchError.noPni
        }
        guard let paramsData = Data(base64Encoded: serverPublicParamsBase64) else {
            throw GroupFetchError.undecodableCredentials
        }
        let secretParams = try GroupSecretParams.deriveFromMasterKey(
            groupMasterKey: GroupMasterKey(contents: masterKey)
        )
        let operations = ClientZkAuthOperations(
            serverPublicParams: try ServerPublicParams(contents: paramsData)
        )
        let received = try operations.receiveAuthCredentialWithPniAsServiceId(
            aci: try Aci.parseFrom(serviceIdString: aci),
            pni: try Pni.parseFrom(serviceIdString: pni),
            redemptionTime: entry.redemptionTime,
            authCredentialResponse: try AuthCredentialWithPniResponse(contents: entry.credential)
        )
        let presentation = try operations.createAuthCredentialPresentation(
            groupSecretParams: secretParams,
            authCredential: received
        )
        return GroupFetchCredentials(presentationHex: Self.hex(presentation.serialize()))
    }

    /// Storage GET + `GroupResponse` decode + member/title decrypt.
    /// A 403 (kicked / unknown group) throws `transferFailed(status: 403)`
    /// without touching any stored state — callers keep the thread.
    /// Undecryptable members are skipped, the rest import (Desktop drops
    /// them); an undecryptable title yields nil, never a failure.
    public static func fetch(
        masterKey: Data,
        environment: AppEnvironment,
        http: HttpSend,
        credentials: GroupFetchCredentials
    ) async throws -> FetchedGroupState {
        guard masterKey.count == GroupMasterKey.SIZE else {
            throw GroupFetchError.badMasterKey
        }
        let secretParams = try GroupSecretParams.deriveFromMasterKey(
            groupMasterKey: GroupMasterKey(contents: masterKey)
        )
        let publicHex = Self.hex(try secretParams.getPublicParams().serialize())
        guard let url = URL(string: storageBase(environment: environment) + "/v2/groups") else {
            throw GroupFetchError.transferFailed(status: -1)
        }
        // Mirrors Desktop `getGroup`: Basic group auth, protobuf content.
        let auth = Data("\(publicHex):\(credentials.presentationHex)".utf8).base64EncodedString()
        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("Basic \(auth)", forHTTPHeaderField: "Authorization")
        request.setValue("application/x-protobuf", forHTTPHeaderField: "Content-Type")
        let (data, response) = try await http(request)
        guard (200..<300).contains(response.statusCode) else {
            Self.logger.error("group state rejected: HTTP \(response.statusCode)")
            throw GroupFetchError.transferFailed(status: response.statusCode)
        }
        guard let groupResponse = try? SignalServiceProtos_GroupResponse(serializedBytes: data) else {
            Self.logger.error("group state undecodable")
            throw GroupFetchError.undecodableGroup
        }
        let group = groupResponse.group
        let cipher = ClientZkGroupCipher(groupSecretParams: secretParams)
        var members = [String]()
        for member in group.members {
            guard
                let ciphertext = try? UuidCiphertext(contents: member.userID),
                let serviceId = try? cipher.decrypt(ciphertext),
                serviceId.kind == .aci
            else {
                Self.logger.error("group member undecryptable, skipping")
                continue
            }
            members.append(serviceId.rawUUID.uuidString.lowercased())
        }
        var title: String?
        if !group.title.isEmpty,
            let plaintext = try? cipher.decryptBlob(blobCiphertext: group.title),
            let blob = try? SignalServiceProtos_GroupAttributeBlob(serializedBytes: plaintext)
        {
            let trimmed = blob.title.trimmingCharacters(in: .whitespacesAndNewlines)
            title = trimmed.isEmpty ? nil : trimmed
        }
        return FetchedGroupState(members: members, revision: group.version, title: title)
    }

    private static func hex(_ data: Data) -> String {
        data.map { String(format: "%02x", $0) }.joined()
    }
}
