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
    /// The transport reports the member set moved under us. The manager
    /// redistributes to newly-added members and retries the send exactly
    /// once; a second failure propagates.
    case membershipChanged
}

/// Transport seam for group traffic: sealed sender-key envelopes per
/// member device (SKDM distributions and sender-key ciphertext alike).
/// Production implements it over the sealed sender path; tests record.
public protocol GroupDistributionSender: Sendable {
    func sendDistribution(_ envelope: OutboundEnvelope, to recipientAci: String) async throws
}

/// GroupsV2 messaging over sender keys. Distribution IDs derive
/// deterministically from (master key, sender address + device) so restarts
/// reuse the same distribution instead of resetting receiver chains (no
/// schema churn, no spurious redistribution).
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

    public static func distributionId(masterKey: Data, sender: ProtocolAddress) -> UUID {
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
        try groups.save(
            StoredGroupState(masterKey: masterKey, revision: revision, members: members)
        )
    }

    @discardableResult
    public func sendTextToGroup(_ text: String, group masterKey: Data) async throws -> UInt64 {
        guard let state = try groups.load(masterKey: masterKey) else {
            throw GroupSendError.unknownGroup
        }
        let distributionId = Self.distributionId(masterKey: masterKey, sender: ourAddress)
        let (content, timestamp) = try GroupManager.content(
            text: text,
            group: masterKey,
            revision: state.revision
        )
        do {
            try await ensureDistributed(state: state, distributionId: distributionId)
            try await sendCiphertext(content, state: state, distributionId: distributionId)
        } catch GroupSendError.membershipChanged {
            // Re-read: the caller updated membership via joinKnownGroup;
            // distribute to the newly-added members, then retry once.
            // Already-distributed members are skipped, so the retry only
            // covers what the failed attempt missed.
            if let fresh = try groups.load(masterKey: masterKey) {
                try await ensureDistributed(state: fresh, distributionId: distributionId)
            }
            try await sendCiphertext(content, state: state, distributionId: distributionId)
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
        revision: UInt32
    ) throws -> (Data, UInt64) {
        let timestamp = UInt64(Date().timeIntervalSince1970 * 1000)
        var groupV2 = SignalServiceProtos_GroupContextV2()
        groupV2.masterKey = masterKey
        groupV2.revision = revision
        var dataMessage = SignalServiceProtos_DataMessage()
        dataMessage.body = text
        dataMessage.timestamp = timestamp
        dataMessage.groupV2 = groupV2
        var content = SignalServiceProtos_Content()
        content.dataMessage = dataMessage
        return (try Padding.pad(content.serializedData()), timestamp)
    }

    private func distributionKey(group: Data, aci: String, deviceId: UInt32) -> String {
        "\(group.hexString):\(aci):\(deviceId)"
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
                lock.withLock { distributed.insert(key) }
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
