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

/// GroupsV2 messaging over sender keys. Distribution IDs derive
/// deterministically from (master key, sender address + device, sender
/// epoch) so restarts reuse the same distribution instead of resetting
/// receiver chains (no spurious redistribution), while a member removal
/// bumps the epoch and starts a fresh chain the removed member never gets.
public final class GroupManager: @unchecked Sendable {
    private let store: any SignalProtocolStore
    private let groups: GroupStateTable
    private let ourAddress: ProtocolAddress
    private let certs: any SenderCertProvider
    private let sessions: SessionSetup
    private let sender: any GroupDistributionSender
    // All `distributed` access holds the lock.
    private let lock = NSLock()
    private var distributed: Set<String> = []

    public init(
        store: any SignalProtocolStore,
        groups: GroupStateTable,
        ourAddress: ProtocolAddress,
        certs: any SenderCertProvider,
        sessions: SessionSetup,
        sender: any GroupDistributionSender
    ) {
        self.store = store
        self.groups = groups
        self.ourAddress = ourAddress
        self.certs = certs
        self.sessions = sessions
        self.sender = sender
    }

    public static func distributionId(masterKey: Data, sender: ProtocolAddress, epoch: UInt32 = 0) -> UUID {
        var input = Data()
        input.append(masterKey)
        input.append(Data(sender.name.utf8))
        let device = sender.deviceId
        input.append(contentsOf: [
            UInt8((device >> 24) & 0xFF),
            UInt8((device >> 16) & 0xFF),
            UInt8((device >> 8) & 0xFF),
            UInt8(device & 0xFF),
        ])
        input.append(contentsOf: [
            UInt8((epoch >> 24) & 0xFF),
            UInt8((epoch >> 16) & 0xFF),
            UInt8((epoch >> 8) & 0xFF),
            UInt8(epoch & 0xFF),
        ])
        let digest = Array(SHA256.hash(data: input).prefix(16))
        return UUID(uuid: (
            digest[0], digest[1], digest[2], digest[3],
            digest[4], digest[5], digest[6], digest[7],
            digest[8], digest[9], digest[10], digest[11],
            digest[12], digest[13], digest[14], digest[15]
        ))
    }

    public func joinKnownGroup(
        masterKey: Data,
        revision: UInt32,
        members: [String]
    ) throws {
        // A removed member must not keep reading our chain: bump the epoch
        // so the next send starts a fresh distribution. Pure additions (or
        // a first sighting) keep the epoch and reuse the chain.
        let existing = try groups.load(masterKey: masterKey)
        let removed = Set(existing?.members ?? []).subtracting(members)
        try groups.save(
            StoredGroupState(
                masterKey: masterKey,
                revision: revision,
                members: members,
                senderEpoch: (existing?.senderEpoch ?? 0) + (removed.isEmpty ? 0 : 1)
            )
        )
    }

    @discardableResult
    public func mergeFetchedGroup(
        masterKey: Data,
        revision: UInt32,
        members: [String]
    ) throws -> Bool {
        // Server state never downgrades the roster: a stored revision at or
        // past the fetched one wins (same gate as `applyMembership`).
        if let existing = try groups.load(masterKey: masterKey), existing.revision >= revision {
            return false
        }
        try joinKnownGroup(masterKey: masterKey, revision: revision, members: members)
        return true
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

    @discardableResult
    public func sendTextToGroup(_ text: String, group masterKey: Data) async throws -> UInt64 {
        guard let state = try groups.load(masterKey: masterKey) else {
            throw GroupSendError.unknownGroup
        }
        guard state.members.contains(where: { $0 != ourAddress.name }) else {
            throw GroupSendError.noOtherMembers
        }
        let distributionId = Self.distributionId(
            masterKey: masterKey,
            sender: ourAddress,
            epoch: state.senderEpoch
        )
        // One timestamp for the attempt and the retry: the outbox row and
        // the wire bytes agree, while the revision is re-read fresh.
        let timestamp = Self.nowMs()
        do {
            try await ensureDistributed(state: state, distributionId: distributionId)
            try await sendCiphertext(
                Self.content(text: text, group: masterKey, revision: state.revision, timestamp: timestamp),
                state: state,
                distributionId: distributionId
            )
        } catch GroupSendError.membershipChanged, SignalError.mismatchedDevices {
            // The roster moved under us (or the transport reports the
            // device list did): re-read, redistribute to newly-added
            // members, then retry once against the fresh roster. A second
            // failure propagates. The distribution id comes from the fresh
            // epoch: a removal mid-send must not resume the removed
            // member's old chain.
            guard let fresh = try groups.load(masterKey: masterKey) else {
                throw GroupSendError.unknownGroup
            }
            let freshDistributionId = Self.distributionId(
                masterKey: masterKey,
                sender: ourAddress,
                epoch: fresh.senderEpoch
            )
            try await ensureDistributed(state: fresh, distributionId: freshDistributionId)
            try await sendCiphertext(
                Self.content(text: text, group: masterKey, revision: fresh.revision, timestamp: timestamp),
                state: fresh,
                distributionId: freshDistributionId
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

    private func distributionKey(group: Data, epoch: UInt32, aci: String, deviceId: UInt32) -> String {
        "\(group.hexString):\(epoch):\(aci):\(deviceId)"
    }

    private func ensureDistributed(
        state: StoredGroupState,
        distributionId: UUID
    ) async throws {
        let cert = try await certs.currentCertificate()
        for memberAci in state.members where memberAci != ourAddress.name {
            let devices = try await sessions.ensureAllSessions(with: memberAci)
            for device in devices {
                let deviceId = device.deviceId
                let key = distributionKey(
                    group: state.masterKey,
                    epoch: state.senderEpoch,
                    aci: memberAci,
                    deviceId: deviceId
                )
                let already = lock.withLock { distributed.contains(key) }
                if already {
                    continue
                }
                let memberAddress = try ProtocolAddress(name: memberAci, deviceId: deviceId)
                let skdm = try SenderKeyDistributionMessage(
                    from: ourAddress,
                    distributionId: distributionId,
                    store: store,
                    context: NullContext()
                )
                let sealed = try sealedSenderEncrypt(
                    skdm.serialize(),
                    from: cert,
                    to: memberAddress,
                    senderStore: store,
                    context: NullContext()
                )
                // Marked only after the send succeeds: a failed distribution
                // retries instead of being skipped forever.
                try await sender.sendDistribution(
                    OutboundEnvelope(
                        bytes: sealed,
                        deviceId: deviceId,
                        registrationId: device.registrationId,
                        timestamp: Self.nowMs()
                    ),
                    to: memberAci
                )
                lock.withLock { _ = distributed.insert(key) }
            }
        }
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
        for memberAci in state.members where memberAci != ourAddress.name {
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

private extension Data {
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
