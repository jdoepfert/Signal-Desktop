// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalLogging
import SignalStorage

// MARK: - Transport seam

/// How a request is authorized. `accessKey` means sealed sender (each
/// message is a type-6 UNIDENTIFIED_SENDER envelope); `authenticated` means
/// over our own chat socket with unsealed ciphertext (type 1 or 3).
public enum SendAuth: Sendable, Equatable {
    case accessKey(Data)
    case authenticated
}

/// One single-request, multi-device send: PUT v1/messages/{destination}.
public struct SendRequest: Sendable, Equatable {
    public struct Message: Sendable, Equatable {
        public let deviceId: UInt32
        public let registrationId: UInt32
        /// Envelope.Type raw value: 1 CIPHERTEXT, 3 PREKEY_BUNDLE,
        /// 6 UNIDENTIFIED_SENDER.
        public let type: Int
        public let content: Data

        public init(deviceId: UInt32, registrationId: UInt32, type: Int, content: Data) {
            self.deviceId = deviceId
            self.registrationId = registrationId
            self.type = type
            self.content = content
        }
    }

    public let destination: String
    public let timestamp: UInt64
    public let messages: [Message]
    public let auth: SendAuth
    public let online: Bool
    public let urgent: Bool

    public init(
        destination: String,
        timestamp: UInt64,
        messages: [Message],
        auth: SendAuth,
        online: Bool = false,
        urgent: Bool = true
    ) {
        self.destination = destination
        self.timestamp = timestamp
        self.messages = messages
        self.auth = auth
        self.online = online
        self.urgent = urgent
    }
}

/// The server's answer to a `SendRequest`. HTTP 200 / 409 / 410 / 401.
public enum SubmitResult: Sendable, Equatable {
    case ok
    /// 409: the request's device set is wrong. Sessions for `extra` must be
    /// dropped, bundles fetched for `missing`. Both empty means "unknown:
    /// refetch every device" (Desktop's empty-entry case).
    case mismatched(missing: [UInt32], extra: [UInt32])
    /// 410: these devices re-registered; their sessions are stale.
    case stale([UInt32])
    /// 401/403: the access key (or the account) is not accepted.
    case unauthorized
}

/// Seam over libsignal's send APIs. The live implementation is
/// `LiveTransport`; tests replay scripted results.
public protocol MessageSubmitter: Sendable {
    func submit(_ request: SendRequest) async throws -> SubmitResult
}

/// Prekey-bundle source for the send path. `deviceIds == nil` fetches every
/// device of the account; otherwise only the listed ones. `accessKey`
/// authorizes the (unauthenticated) fetch when the recipient's profile key
/// is known.
public protocol PreKeyBundleFetching: Sendable {
    func fetchBundles(
        for aci: String,
        deviceIds: [UInt32]?,
        accessKey: Data?
    ) async throws -> [PreKeyBundle]
}

public enum SendError: Error, Equatable {
    /// Three device-list mismatches in a row (our cap; Desktop has none).
    case deviceMismatchLoop
    /// A retry after a stale-only answer was refused again
    /// (`OutgoingMessage.preload.ts`: "Hit retry limit").
    case staleRetryLimit
    case unauthorized
    /// The recipient's identity key changed since we last saw it (their
    /// safety number changed). All sessions with them were archived, as
    /// Desktop does. The send is refused until the user accepts the new key:
    /// `OutgoingSender.acceptNewIdentity(aci:)`, then retry.
    case identityChanged(String)
    /// `resendText` found no failed outgoing message with that timestamp.
    case noSuchMessage
    case unregisteredUser
    case noDevices
    case server(status: UInt16)
}

/// `ProfileKey.deriveAccessKey` (Desktop `ts/util/zkgroup.node.ts`).
public func deriveAccessKey(profileKey: Data) throws -> Data {
    try ProfileKey(contents: profileKey).deriveAccessKey()
}

public struct PendingRecovery: Sendable, Equatable {
    public let retried: Int
    public let sent: Int
    public let failed: Int
}

// MARK: - OutgoingSender

/// The 1:1 send pipeline: pad, encrypt for every device with a session in
/// ONE store transaction, submit ONE request, and repair the device list on
/// 409/410. A port of `OutgoingMessage.preload.ts` (`doSendMessage`,
/// `reloadDevicesAndSend`, the sealed-to-authenticated failover) and the
/// `SyncMessage.Sent` transcript of `SendMessage.preload.ts`.
///
/// Encryption mutates session state (ratchet advance, prekey processing),
/// so each encrypt step runs inside `GRDBProtocolStore.withTransaction`
/// exactly like the receive side: either every device's session update
/// lands or none does. Network calls (bundle fetch, submit) are outside it.
///
/// The outbox: `sendText` writes the outgoing row (`status = pending`)
/// BEFORE anything touches the network, then flips it to `sent` or
/// `failed`. `recoverPending` is the launch-time pass over rows a crash left
/// `pending`.
public actor OutgoingSender {
    /// Our own cap on device-list mismatches per send (Desktop has none).
    public static let maxSubmits = 3
    /// A `pending` row is only retried once it is older than this.
    public static let pendingGraceMs: UInt64 = 30_000

    private static let logger = Logger(subsystem: "send", category: "outgoing")

    private let store: GRDBProtocolStore
    private let identity: GRDBIdentityStore
    private let messages: MessageStore
    private let contacts: ContactTable
    private let conversations: ConversationStore
    private let ourAci: String
    private let ourDeviceId: UInt32
    private let ourAddress: ProtocolAddress
    private let certs: any SenderCertProvider
    private let bundles: any PreKeyBundleFetching
    private let submitter: any MessageSubmitter
    private let nowMs: @Sendable () -> UInt64
    private var lastTimestamp: UInt64 = 0

    public init(
        store: GRDBProtocolStore,
        identity: GRDBIdentityStore,
        messages: MessageStore,
        contacts: ContactTable,
        conversations: ConversationStore,
        ourAci: String,
        ourDeviceId: UInt32,
        certs: any SenderCertProvider,
        bundles: any PreKeyBundleFetching,
        submitter: any MessageSubmitter,
        nowMs: @escaping @Sendable () -> UInt64 = { UInt64(Date().timeIntervalSince1970 * 1000) }
    ) {
        self.store = store
        self.identity = identity
        self.messages = messages
        self.contacts = contacts
        self.conversations = conversations
        self.ourAci = ourAci.lowercased()
        self.ourDeviceId = ourDeviceId
        // A malformed device id cannot reach here: it came from linking.
        self.ourAddress = try! ProtocolAddress(name: ourAci.lowercased(), deviceId: ourDeviceId)
        self.certs = certs
        self.bundles = bundles
        self.submitter = submitter
        self.nowMs = nowMs
    }

    // MARK: Public API

    /// Pads and sends `content` to every device of `aci`; returns the
    /// timestamp that went out.
    @discardableResult
    public func send(
        _ content: SignalServiceProtos_Content,
        to aci: String,
        timestamp: UInt64
    ) async throws -> UInt64 {
        let padded = Padding.pad(try content.serializedData())
        try await deliver(padded, to: aci.lowercased(), timestamp: timestamp, sealed: true)
        return timestamp
    }

    /// Sends a text message and keeps the outbox row honest. Returns the
    /// timestamp used as the message's `sent_timestamp`.
    public func sendText(_ body: String, to aci: String) async throws -> UInt64 {
        let aci = aci.lowercased()
        let conversationId = "aci:\(aci)"
        let (timer, version) = try conversations.expireTimer(conversationId)
        let (rowId, timestamp) = try insertPending(body: body, aci: aci, timer: timer)
        do {
            try await transmitText(body, to: aci, timestamp: timestamp, timer: timer, version: version)
        } catch {
            markStatus(rowId, MessageStatus.failed)
            throw error
        }
        markStatus(rowId, MessageStatus.sent)
        return timestamp
    }

    /// The user accepted a contact's changed identity ("Safety number
    /// changed ... Send anyway?"). Archives every session with them, fetches
    /// their CURRENT bundles, saves the identity key those bundles present as
    /// trusted for each device, and starts fresh sessions from the same fetch
    /// (so a retry needs no further prekey fetch). Receiving never needs this:
    /// inbound identity changes are trusted automatically.
    public func acceptNewIdentity(aci: String) async throws {
        let aci = aci.lowercased()
        try store.archiveAllSessions(forAci: aci)
        try await fetchAndEstablish(
            aci,
            deviceIds: nil,
            excluding: aci == ourAci ? ourDeviceId : nil,
            trustPresentedIdentity: true
        )
    }

    /// Re-sends a message whose send failed (e.g. `identityChanged`) under
    /// its original timestamp, keeping a single row for it.
    public func resendText(timestamp: UInt64, to aci: String) async throws {
        let aci = aci.lowercased()
        guard
            let row = try messages.message(senderAci: ourAci, timestamp: timestamp),
            row.status == MessageStatus.failed
        else {
            throw SendError.noSuchMessage
        }
        markStatus(row.rowId, MessageStatus.pending)
        do {
            let version = try conversations.expireTimer("aci:\(aci)").version
            try await transmitText(
                row.body,
                to: aci,
                timestamp: row.timestamp,
                timer: row.expireTimer,
                version: version
            )
        } catch {
            markStatus(row.rowId, MessageStatus.failed)
            throw error
        }
        markStatus(row.rowId, MessageStatus.sent)
    }

    /// Launch-time outbox pass. Each `pending` row older than 30 s is
    /// retried ONCE; success marks it `sent`, any failure marks it `failed`,
    /// so a row is never retried a second time. Younger rows are left alone
    /// (they may still be in flight).
    @discardableResult
    public func recoverPending(now: UInt64) async -> PendingRecovery {
        let rows: [StoredMessage]
        do {
            rows = try messages.pendingOutgoing().filter { $0.senderAci == ourAci }
        } catch {
            Self.logger.error("could not read the outbox: \(String(describing: type(of: error)))")
            return PendingRecovery(retried: 0, sent: 0, failed: 0)
        }
        var retried = 0
        var sent = 0
        var failed = 0
        for row in rows where now > row.timestamp + Self.pendingGraceMs {
            guard let conversationId = row.conversationId, conversationId.hasPrefix("aci:") else {
                // Groups are not sent in Milestone A.
                markStatus(row.rowId, MessageStatus.failed)
                failed += 1
                continue
            }
            let aci = String(conversationId.dropFirst(4))
            retried += 1
            do {
                let version = try conversations.expireTimer(conversationId).version
                try await transmitText(
                    row.body,
                    to: aci,
                    timestamp: row.timestamp,
                    timer: row.expireTimer,
                    version: version
                )
                markStatus(row.rowId, MessageStatus.sent)
                sent += 1
            } catch {
                Self.logger.error("outbox retry failed: \(Self.reason(error))")
                markStatus(row.rowId, MessageStatus.failed)
                failed += 1
            }
        }
        return PendingRecovery(retried: retried, sent: sent, failed: failed)
    }

    // MARK: Text, transcript, outbox

    private func transmitText(
        _ body: String,
        to aci: String,
        timestamp: UInt64,
        timer: UInt32?,
        version: UInt32?
    ) async throws {
        var dataMessage = SignalServiceProtos_DataMessage()
        dataMessage.body = body
        dataMessage.timestamp = timestamp
        if let profileKey = try? identity.profileKey() {
            dataMessage.profileKey = profileKey
        }
        if let timer, timer > 0 {
            dataMessage.expireTimer = timer
            if let version {
                dataMessage.expireTimerVersion = version
            }
        }
        var content = SignalServiceProtos_Content()
        content.dataMessage = dataMessage
        try await send(content, to: aci, timestamp: timestamp)

        // Note to Self is a send to our own ACI (our other devices already
        // get it) and needs no separate transcript.
        guard aci != ourAci else {
            return
        }
        var sent = SignalServiceProtos_SyncMessage.Sent()
        sent.destinationServiceID = aci
        sent.timestamp = timestamp
        sent.message = dataMessage
        if let timer, timer > 0 {
            sent.expirationStartTimestamp = timestamp
        }
        var sync = SignalServiceProtos_SyncMessage()
        sync.sent = sent
        var syncContent = SignalServiceProtos_Content()
        syncContent.syncMessage = sync
        do {
            let padded = Padding.pad(try syncContent.serializedData())
            // Desktop sends the transcript non-urgent.
            try await deliver(padded, to: ourAci, timestamp: timestamp, sealed: false, urgent: false)
        } catch {
            // The recipient already has the message; a missing transcript
            // only means our other devices miss it. Not a send failure.
            Self.logger.error("sent-sync transcript failed: \(Self.reason(error))")
        }
    }

    /// Writes the outgoing row (`pending`) with a timestamp unique among our
    /// own messages (two sends in one millisecond must not collide on
    /// UNIQUE(sender_aci, sent_timestamp)).
    private func insertPending(
        body: String,
        aci: String,
        timer: UInt32?
    ) throws -> (rowId: Int64, timestamp: UInt64) {
        while true {
            lastTimestamp = max(nowMs(), lastTimestamp + 1)
            let timestamp = lastTimestamp
            let result = try store.withTransaction { transaction in
                try messages.persist(
                    NewMessage(
                        senderAci: ourAci,
                        senderDevice: ourDeviceId,
                        body: body,
                        sentTimestamp: timestamp,
                        target: .direct(aci: aci),
                        expireTimer: timer,
                        kind: MessageKind.text,
                        status: MessageStatus.pending
                    ),
                    in: transaction
                )
            }
            if result.inserted {
                return (result.rowId, timestamp)
            }
        }
    }

    private func markStatus(_ rowId: Int64, _ status: String) {
        do {
            try messages.setStatus(rowId: rowId, status: status)
        } catch {
            Self.logger.error("could not update outbox status: \(Self.reason(error))")
        }
    }

    // MARK: Delivery loop

    private func deliver(
        _ padded: Data,
        to aci: String,
        timestamp: UInt64,
        sealed: Bool,
        urgent: Bool = true
    ) async throws {
        let excluding: UInt32? = aci == ourAci ? ourDeviceId : nil
        let sealedKey = sealed ? knownAccessKey(for: aci) : nil
        var auth: SendAuth = sealedKey.map { .accessKey($0) } ?? .authenticated
        var mismatches = 0
        // Desktop's `recurse`: false after a stale-only answer, so the one
        // retry that follows may not itself be refused for device reasons.
        var mayRecurse = true
        while true {
            guard let request = try await buildRequest(
                padded,
                to: aci,
                timestamp: timestamp,
                auth: auth,
                excluding: excluding,
                urgent: urgent
            ) else {
                return
            }
            switch try await submitter.submit(request) {
            case .ok:
                return
            case .unauthorized:
                guard case .accessKey = request.auth else {
                    throw SendError.unauthorized
                }
                // Desktop: failover from sealed sender to an authenticated
                // send. Not a device mismatch, so not counted against the
                // cap.
                Self.logger.info("sealed send refused; failing over to authenticated")
                auth = .authenticated
            case .mismatched(let missing, let extra):
                mismatches += 1
                guard mismatches < Self.maxSubmits else {
                    throw SendError.deviceMismatchLoop
                }
                guard mayRecurse else {
                    throw SendError.staleRetryLimit
                }
                try await repairTranslatingIdentity(aci, missing: missing, extra: extra, stale: [], excluding: excluding)
                mayRecurse = true
            case .stale(let devices):
                mismatches += 1
                guard mismatches < Self.maxSubmits else {
                    throw SendError.deviceMismatchLoop
                }
                guard mayRecurse else {
                    throw SendError.staleRetryLimit
                }
                try await repairTranslatingIdentity(aci, missing: [], extra: [], stale: devices, excluding: excluding)
                // Stale-only: try once more, and no further.
                mayRecurse = false
            }
        }
    }

    /// Ensures sessions, then encrypts for every device that has one.
    /// Returns nil when there is nobody to send to (our own account with
    /// no other devices).
    private func buildRequest(
        _ padded: Data,
        to aci: String,
        timestamp: UInt64,
        auth: SendAuth,
        excluding: UInt32?,
        urgent: Bool = true
    ) async throws -> SendRequest? {
        do {
            var devices = try store.activeSessionDevices(forAci: aci).filter { $0.deviceId != excluding }
            if devices.isEmpty {
                try await fetchAndEstablish(aci, deviceIds: nil, excluding: excluding)
                devices = try store.activeSessionDevices(forAci: aci).filter { $0.deviceId != excluding }
            }
            guard !devices.isEmpty else {
                if excluding != nil {
                    return nil
                }
                throw SendError.noDevices
            }
            var effectiveAuth = auth
            var cert: SenderCertificate?
            if case .accessKey = auth {
                do {
                    cert = try await certs.currentCertificate()
                } catch {
                    // Not silent: a persistent failure here (e.g. 401 from an
                    // unauthenticated fetch) means sealed sender never works.
                    // Error type only, no identifiers.
                    Self.logger.error(
                        "sender certificate unavailable (\(Self.reason(error))); sending authenticated"
                    )
                    effectiveAuth = .authenticated
                }
            }
            let encrypted = try encrypt(padded, aci: aci, devices: devices, cert: cert)
            return SendRequest(
                destination: aci,
                timestamp: timestamp,
                messages: encrypted,
                auth: effectiveAuth,
                urgent: urgent
            )
        } catch SignalError.untrustedIdentity {
            // Desktop: archive every session with the recipient, surface
            // the error. The transaction already rolled back.
            try? store.archiveAllSessions(forAci: aci)
            throw SendError.identityChanged(aci)
        }
    }

    /// One transaction for every device: all session updates or none.
    private func encrypt(
        _ padded: Data,
        aci: String,
        devices: [(deviceId: UInt32, registrationId: UInt32)],
        cert: SenderCertificate?
    ) throws -> [SendRequest.Message] {
        let context = NullContext()
        let ourAddress = self.ourAddress
        let store = self.store
        return try store.withTransaction { _ in
            try devices.map { device in
                let address = try ProtocolAddress(name: aci, deviceId: device.deviceId)
                if let cert {
                    let sealed = try sealedSenderEncrypt(
                        padded,
                        from: cert,
                        to: address,
                        senderStore: store,
                        context: context
                    )
                    return SendRequest.Message(
                        deviceId: device.deviceId,
                        registrationId: device.registrationId,
                        type: 6,
                        content: sealed
                    )
                }
                let ciphertext = try signalEncrypt(
                    message: padded,
                    for: address,
                    localAddress: ourAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: context
                )
                return SendRequest.Message(
                    deviceId: device.deviceId,
                    registrationId: device.registrationId,
                    type: ciphertext.messageType == .preKey ? 3 : 1,
                    content: ciphertext.serialize()
                )
            }
        }
    }

    // MARK: Sessions

    /// `repair`, with a refused (changed) identity surfaced as the typed
    /// error exactly like in `buildRequest`: the usual way to meet a changed
    /// key is the refetch after a 410 for a re-registered device.
    private func repairTranslatingIdentity(
        _ aci: String,
        missing: [UInt32],
        extra: [UInt32],
        stale: [UInt32],
        excluding: UInt32?
    ) async throws {
        do {
            try await repair(aci, missing: missing, extra: extra, stale: stale, excluding: excluding)
        } catch SignalError.untrustedIdentity {
            try? store.archiveAllSessions(forAci: aci)
            throw SendError.identityChanged(aci)
        }
    }

    /// `handleMismatchedDevicesError`: sessions for extra and stale devices
    /// are archived; bundles are fetched for missing and stale ones.
    private func repair(
        _ aci: String,
        missing: [UInt32],
        extra: [UInt32],
        stale: [UInt32],
        excluding: UInt32?
    ) async throws {
        if missing.isEmpty && extra.isEmpty && stale.isEmpty {
            try await fetchAndEstablish(aci, deviceIds: nil, excluding: excluding)
            return
        }
        for device in extra + stale {
            try store.archiveSession(for: ProtocolAddress(name: aci, deviceId: device))
        }
        let refetch = Set(missing + stale).sorted()
        if !refetch.isEmpty {
            try await fetchAndEstablish(aci, deviceIds: refetch, excluding: excluding)
        }
    }

    /// Fetches bundles and starts a session per device. A fetch of ALL
    /// devices leaves devices that already have a usable session alone.
    private func fetchAndEstablish(
        _ aci: String,
        deviceIds: [UInt32]?,
        excluding: UInt32?,
        trustPresentedIdentity: Bool = false
    ) async throws {
        let fetched = try await bundles.fetchBundles(
            for: aci,
            deviceIds: deviceIds,
            accessKey: knownAccessKey(for: aci)
        )
        let context = NullContext()
        let ourAddress = self.ourAddress
        let store = self.store
        try store.withTransaction { _ in
            for bundle in fetched where bundle.deviceId != excluding {
                let address = try ProtocolAddress(name: aci, deviceId: bundle.deviceId)
                if deviceIds == nil,
                   try store.loadSession(for: address, context: context)?.hasCurrentState == true
                {
                    continue
                }
                if trustPresentedIdentity {
                    // The user accepted the new safety number: record the
                    // key the server presents BEFORE libsignal compares it.
                    _ = try store.saveIdentity(bundle.identityKey, for: address, context: context)
                }
                try processPreKeyBundle(
                    bundle,
                    for: address,
                    ourAddress: ourAddress,
                    sessionStore: store,
                    identityStore: store,
                    context: context
                )
            }
        }
    }

    /// The recipient's sealed-sender access key, derived from the profile
    /// key we hold for them (ours for our own account); nil when unknown.
    private func knownAccessKey(for aci: String) -> Data? {
        let profileKey: Data?
        if aci == ourAci {
            profileKey = try? identity.profileKey()
        } else {
            profileKey = (try? contacts.profileKey(aci: aci)) ?? nil
        }
        guard let profileKey, profileKey.count == ProfileKey.SIZE else {
            return nil
        }
        return try? deriveAccessKey(profileKey: profileKey)
    }

    private static func reason(_ error: Error) -> String {
        if error is SendError || error is PaddingError {
            return "\(error)"
        }
        return String(describing: type(of: error))
    }
}
