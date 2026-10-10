// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import LibSignalClient
import SignalCore
import SignalLogging
import SignalStorage

public enum GroupSendError: Error, Equatable {
    case unknownGroup
    /// The roster holds no one but us (bootstrapped from our own message
    /// before any other member was seen). Sending would reach nobody, so
    /// refuse instead of recording a sent row no one receives.
    case noOtherMembers
    /// The member set moved under us (or the transport reports the device
    /// list did). The manager redistributes to newly-added members and
    /// retries the send exactly once; a second failure propagates.
    case membershipChanged
}

/// Transport seam for group traffic: sealed sender-key envelopes per
/// member device (SKDM distributions and sender-key ciphertext alike).
/// Production implements it over the sealed sender path; tests record.
public protocol GroupDistributionSender: Sendable {
    func sendDistribution(_ envelope: OutboundEnvelope, to recipientAci: String) async throws
}

/// GroupsV2 messaging over sender keys. Our distribution id is a random
/// UUID per group, remembered across restarts in `sender_key_info` along
/// with the creation date and the devices that already hold our key
/// (`memberDevices`) — Desktop's `senderKeyInfo` (`sendToGroupViaSenderKey`
/// steps 1, 6–9; `resetSenderKey`). The SKDM travels inside `Content`
/// (field 7 only), sent through the outbox like any 1:1 send.
public final class GroupManager: @unchecked Sendable {
    private static let logger = Logger(subsystem: "groups", category: "send")

    /// Fixed sender-key lifetime (Desktop `MAX_SENDER_KEY_EXPIRE_DURATION =
    /// 90 * DAY`). Desktop reads a remote-config value capped at 90 days;
    /// this port always uses the cap: there is no remote-config channel on
    /// this client yet.
    static let maxSenderKeyAgeMs: Int64 = 90 * 24 * 60 * 60 * 1000

    private let store: any SignalProtocolStore
    private let groups: GroupStateTable
    private let senderKeys: SenderKeyInfoTable
    private let ourAddress: ProtocolAddress
    private let certs: any SenderCertProvider
    private let sessions: SessionSetup
    private let sender: any GroupDistributionSender
    private let outbox: OutgoingSender

    public init(
        store: any SignalProtocolStore,
        groups: GroupStateTable,
        ourAddress: ProtocolAddress,
        certs: any SenderCertProvider,
        sessions: SessionSetup,
        sender: any GroupDistributionSender,
        outbox: OutgoingSender,
        senderKeys: SenderKeyInfoTable
    ) {
        self.store = store
        self.groups = groups
        self.senderKeys = senderKeys
        self.ourAddress = ourAddress
        self.certs = certs
        self.sessions = sessions
        self.sender = sender
        self.outbox = outbox
    }

    /// Master keys flagged by message sightings for a server refresh.
    public func groupsNeedingRefresh() throws -> [Data] {
        try groups.groupsNeedingRefresh()
    }

    public func joinKnownGroup(
        masterKey: Data,
        revision: UInt32,
        members: [String]
    ) throws {
        // Plain save: the sender key no longer derives from roster history,
        // so a removal needs no counter bump here. `prepareSenderKey`
        // detects a removed account via `memberDevices` and rotates there.
        // The (unused) epoch and the refresh flag survive untouched.
        let existing = try groups.load(masterKey: masterKey)
        try groups.save(
            StoredGroupState(
                masterKey: masterKey,
                revision: revision,
                members: members,
                senderEpoch: existing?.senderEpoch ?? 0,
                needsRefresh: existing?.needsRefresh ?? false
            )
        )
    }

    @discardableResult
    public func mergeFetchedGroup(
        masterKey: Data,
        revision: UInt32,
        members: [String]
    ) throws -> Bool {
        // Server state never downgrades the roster: the table gates on the
        // last applied SERVER revision (message-claimed revisions never
        // block it) and clears the refresh flag on apply.
        try groups.applyFetchedState(masterKey: masterKey, revision: revision, members: members)
    }

    /// Applies fetched server state as one gated unit: the revision-gated
    /// roster merge plus the title store. A stale fetch changes nothing
    /// (returns false) — the title never bypasses the gate the roster
    /// honors.
    @discardableResult
    public func applyFetchedState(
        _ fetched: FetchedGroupState,
        masterKey: Data,
        titles: ConversationStore
    ) throws -> Bool {
        guard
            try mergeFetchedGroup(
                masterKey: masterKey,
                revision: fetched.revision,
                members: fetched.members
            )
        else {
            return false
        }
        if let title = fetched.title {
            try titles.setGroupTitle(masterKey: masterKey, title: title)
        }
        return true
    }

    /// Desktop `sendToGroupViaSenderKey` steps 1 and 6–9: ensures our sender
    /// key is distributed to the current roster and returns the distribution
    /// id plus the current devices of every other member. Task 5 consumes
    /// this for the sender-key send itself.
    ///
    /// 1. A key older than the expire duration resets (new random UUID).
    /// 2. The current devices (one ensured session per device, as today)
    ///    diff against the stored `memberDevices`.
    /// 3. A removed device whose account is no longer in the roster resets
    ///    the key and restarts with an empty stored set, so every current
    ///    device counts as new below.
    /// 4. The SKDM (`Content.senderKeyDistributionMessage`, field 7 only)
    ///    goes through `OutgoingSender.send` to each account with a new
    ///    device — one request per account, fanned out to all its devices
    ///    like any 1:1 send (a device that already holds the key harmlessly
    ///    receives a duplicate).
    /// 5. The updated `memberDevices` persist.
    public func prepareSenderKey(
        group masterKey: Data
    ) async throws -> (
        distributionId: UUID,
        devices: [(aci: String, deviceId: UInt32, registrationId: UInt32)]
    ) {
        guard let state = try groups.load(masterKey: masterKey) else {
            throw GroupSendError.unknownGroup
        }
        let roster = Set(state.members.map { $0.lowercased() })
        // Load-or-create our sender-key info.
        var info = try senderKeys.load(masterKey: masterKey)
            ?? senderKeys.reset(masterKey: masterKey)
        // Step 1: an expired key resets.
        if Int64(Self.nowMs()) - info.createdAtMs > Self.maxSenderKeyAgeMs {
            info = try senderKeys.reset(masterKey: masterKey)
        }
        // Steps 6–7: the current device partition.
        var current = [(aci: String, deviceId: UInt32, registrationId: UInt32)]()
        var currentDevices = Set<String>()
        for memberAci in roster where memberAci != ourAddress.name {
            for device in try await sessions.ensureAllSessions(with: memberAci) {
                current.append((
                    aci: memberAci,
                    deviceId: device.deviceId,
                    registrationId: device.registrationId
                ))
                currentDevices.insert(Self.deviceKey(aci: memberAci, deviceId: device.deviceId))
            }
        }
        // Step 8: a removed device whose account left the roster resets the
        // key; distribution starts over with an empty stored set.
        let accountGone = info.memberDevices.subtracting(currentDevices).contains {
            !roster.contains(Self.aci(of: $0))
        }
        if accountGone {
            info = try senderKeys.reset(masterKey: masterKey)
        }
        // Step 9: SKDMs to newly added devices only, then persist.
        let freshAcis = Set(
            currentDevices.subtracting(info.memberDevices).map { Self.aci(of: $0) }
        ).sorted()
        if !freshAcis.isEmpty {
            let timestamp = Self.nowMs()
            for aci in freshAcis {
                let skdm = try SenderKeyDistributionMessage(
                    from: ourAddress,
                    distributionId: info.distributionId,
                    store: store,
                    context: NullContext()
                )
                var content = SignalServiceProtos_Content()
                content.senderKeyDistributionMessage = skdm.serialize()
                try await outbox.send(content, to: aci, timestamp: timestamp)
            }
            info = StoredSenderKeyInfo(
                masterKey: masterKey,
                distributionId: info.distributionId,
                createdAtMs: info.createdAtMs,
                memberDevices: currentDevices
            )
            try senderKeys.save(info)
        } else if info.memberDevices != currentDevices {
            // No new devices, but a device vanished while its account is
            // still present (a stale device pruned server-side): persist
            // the smaller set without rotating.
            info = StoredSenderKeyInfo(
                masterKey: masterKey,
                distributionId: info.distributionId,
                createdAtMs: info.createdAtMs,
                memberDevices: currentDevices
            )
            try senderKeys.save(info)
        }
        return (info.distributionId, current)
    }

    @discardableResult
    public func sendTextToGroup(_ text: String, group masterKey: Data) async throws -> UInt64 {
        guard let state = try groups.load(masterKey: masterKey) else {
            throw GroupSendError.unknownGroup
        }
        guard state.members.contains(where: { $0.lowercased() != ourAddress.name }) else {
            throw GroupSendError.noOtherMembers
        }
        // One timestamp for the attempt and the retry: the outbox row and
        // the wire bytes agree, while the revision is re-read fresh.
        let timestamp = Self.nowMs()
        do {
            let prepared = try await prepareSenderKey(group: masterKey)
            try await sendCiphertext(
                Self.content(text: text, group: masterKey, revision: state.revision, timestamp: timestamp),
                state: state,
                distributionId: prepared.distributionId
            )
        } catch GroupSendError.membershipChanged, SignalError.mismatchedDevices {
            // The roster moved under us (or the transport reports the
            // device list did): re-read, redistribute to newly-added
            // members, then retry once against the fresh roster. A second
            // failure propagates. `prepareSenderKey` rotates onto a fresh
            // chain itself when the new roster dropped a member, so the
            // retry never resumes a removed member's chain.
            guard let fresh = try groups.load(masterKey: masterKey) else {
                // No identifiers: group ids stay out of the log.
                Self.logger.error("group send retry: group vanished after membership change")
                throw GroupSendError.unknownGroup
            }
            let prepared = try await prepareSenderKey(group: masterKey)
            try await sendCiphertext(
                Self.content(text: text, group: masterKey, revision: fresh.revision, timestamp: timestamp),
                state: fresh,
                distributionId: prepared.distributionId
            )
        }
        return timestamp
    }

    /// Processes a sender-key distribution message for a member.
    public func receiveDistribution(_ bytes: Data, from sender: ProtocolAddress) throws {
        let skdm = try SenderKeyDistributionMessage(bytes: bytes)
        try processSenderKeyDistributionMessage(
            skdm,
            from: sender,
            store: store,
            context: NullContext()
        )
    }

    /// Decrypts group ciphertext from a member into a text message.
    public func receiveGroupMessage(
        _ bytes: Data,
        from sender: ProtocolAddress
    ) throws -> DecryptedMessage {
        let plaintext = try groupDecrypt(
            bytes,
            from: sender,
            store: store,
            context: NullContext()
        )
        return try decodeContentMessage(Padding.unpad(plaintext), senderAci: sender.name)
    }

    private static func content(
        text: String,
        group masterKey: Data,
        revision: UInt32,
        timestamp: UInt64
    ) throws -> Data {
        var groupV2 = SignalServiceProtos_GroupContextV2()
        groupV2.masterKey = masterKey
        groupV2.revision = revision
        var dataMessage = SignalServiceProtos_DataMessage()
        dataMessage.body = text
        dataMessage.timestamp = timestamp
        dataMessage.groupV2 = groupV2
        var content = SignalServiceProtos_Content()
        content.dataMessage = dataMessage
        return try Padding.pad(content.serializedData())
    }

    private static func deviceKey(aci: String, deviceId: UInt32) -> String {
        "\(aci.lowercased()):\(deviceId)"
    }

    private static func aci(of deviceKey: String) -> String {
        String(deviceKey.split(separator: ":").first ?? "")
    }

    private func sendCiphertext(
        _ content: Data,
        state: StoredGroupState,
        distributionId: UUID
    ) async throws {
        let ciphertext = try groupEncrypt(
            content,
            from: ourAddress,
            distributionId: distributionId,
            store: store,
            context: NullContext()
        )
        let cert = try await certs.currentCertificate()
        for memberAci in state.members.map({ $0.lowercased() }) where memberAci != ourAddress.name {
            let devices = try await sessions.ensureAllSessions(with: memberAci)
            for device in devices {
                let memberAddress = try ProtocolAddress(name: memberAci, deviceId: device.deviceId)
                let sealed = try sealedSenderEncrypt(
                    ciphertext.serialize(),
                    from: cert,
                    to: memberAddress,
                    senderStore: store,
                    context: NullContext()
                )
                try await sender.sendDistribution(
                    OutboundEnvelope(
                        bytes: sealed,
                        deviceId: device.deviceId,
                        registrationId: device.registrationId,
                        timestamp: Self.nowMs()
                    ),
                    to: memberAci
                )
            }
        }
    }

    private static func nowMs() -> UInt64 {
        UInt64(Date().timeIntervalSince1970 * 1000)
    }
}
