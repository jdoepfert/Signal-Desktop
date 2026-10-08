// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import GRDB
import LibSignalClient

/// The full libsignal store surface as one type, so clients (e.g. the
/// message pipe) take a single dependency instead of six. Refines
/// `Sendable`: every conforming store must be safe to hold in an actor.
public protocol SignalProtocolStore: IdentityKeyStore, SessionStore, PreKeyStore,
    SignedPreKeyStore, KyberPreKeyStore, SenderKeyStore, Sendable
{}

/// GRDB-backed `SignalProtocolStore`: delegates identity work to a
/// `GRDBIdentityStore`, session/prekey work to a `GRDBSessionStore`, and
/// sender-key work to a `GRDBSenderKeyStore`.
public final class GRDBProtocolStore: SignalProtocolStore, Sendable {
    private let identity: GRDBIdentityStore
    private let session: GRDBSessionStore
    private let senderKeys: GRDBSenderKeyStore

    /// All three stores must be built over the SAME `DatabaseQueue`:
    /// `withTransaction` opens the transaction on the session store's queue
    /// and expects identity and sender-key callbacks to join it.
    public init(
        identity: GRDBIdentityStore,
        session: GRDBSessionStore,
        senderKeys: GRDBSenderKeyStore
    ) {
        self.identity = identity
        self.session = session
        self.senderKeys = senderKeys
    }

    /// Runs `body` in ONE write transaction. Every libsignal store callback
    /// issued on this thread inside `body` (session, prekey, kyber, identity,
    /// sender-key reads and writes) uses that transaction, so those writes
    /// and whatever `body` writes through the `StoreTransaction` commit
    /// together, or, if `body` throws, not at all. `body` must be
    /// synchronous: the transaction is bound to the executing thread.
    public func withTransaction<T>(_ body: (StoreTransaction) throws -> T) throws -> T {
        try ActiveTransaction.write(session.queue, body)
    }

    /// Usable sessions of `aci`: device id and recorded registration id.
    public func activeSessionDevices(
        forAci aci: String
    ) throws -> [(deviceId: UInt32, registrationId: UInt32)] {
        try session.activeSessionDevices(forAci: aci)
    }

    public func archiveSession(for address: ProtocolAddress) throws {
        try session.archiveSession(for: address)
    }

    public func archiveAllSessions(forAci aci: String) throws {
        try session.archiveAllSessions(forAci: aci)
    }

    public func identityKeyPair(context: StoreContext) throws -> IdentityKeyPair {
        try identity.identityKeyPair(context: context)
    }

    public func localRegistrationId(context: StoreContext) throws -> UInt32 {
        try identity.localRegistrationId(context: context)
    }

    public func saveIdentity(
        _ identityKey: IdentityKey,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityChange {
        try identity.saveIdentity(identityKey, for: address, context: context)
    }

    public func isTrustedIdentity(
        _ identity: IdentityKey,
        for address: ProtocolAddress,
        direction: Direction,
        context: StoreContext
    ) throws -> Bool {
        try self.identity.isTrustedIdentity(identity, for: address, direction: direction, context: context)
    }

    public func identity(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> IdentityKey? {
        try identity.identity(for: address, context: context)
    }

    public func loadSession(
        for address: ProtocolAddress,
        context: StoreContext
    ) throws -> SessionRecord? {
        try session.loadSession(for: address, context: context)
    }

    public func loadExistingSessions(
        for addresses: [ProtocolAddress],
        context: StoreContext
    ) throws -> [SessionRecord] {
        try session.loadExistingSessions(for: addresses, context: context)
    }

    public func storeSession(
        _ record: SessionRecord,
        for address: ProtocolAddress,
        context: StoreContext
    ) throws {
        try session.storeSession(record, for: address, context: context)
    }

    public func loadPreKey(id: UInt32, context: StoreContext) throws -> PreKeyRecord {
        try session.loadPreKey(id: id, context: context)
    }

    public func storePreKey(_ record: PreKeyRecord, id: UInt32, context: StoreContext) throws {
        try session.storePreKey(record, id: id, context: context)
    }

    public func removePreKey(id: UInt32, context: StoreContext) throws {
        try session.removePreKey(id: id, context: context)
    }

    public func loadSignedPreKey(id: UInt32, context: StoreContext) throws -> SignedPreKeyRecord {
        try session.loadSignedPreKey(id: id, context: context)
    }

    public func storeSignedPreKey(
        _ record: SignedPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try session.storeSignedPreKey(record, id: id, context: context)
    }

    public func loadKyberPreKey(id: UInt32, context: StoreContext) throws -> KyberPreKeyRecord {
        try session.loadKyberPreKey(id: id, context: context)
    }

    public func storeKyberPreKey(
        _ record: KyberPreKeyRecord,
        id: UInt32,
        context: StoreContext
    ) throws {
        try session.storeKyberPreKey(record, id: id, context: context)
    }

    public func markKyberPreKeyUsed(
        id: UInt32,
        signedPreKeyId: UInt32,
        baseKey: PublicKey,
        context: StoreContext
    ) throws {
        try session.markKyberPreKeyUsed(
            id: id,
            signedPreKeyId: signedPreKeyId,
            baseKey: baseKey,
            context: context
        )
    }

    public func storeSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        record: SenderKeyRecord,
        context: StoreContext
    ) throws {
        try senderKeys.storeSenderKey(
            from: sender,
            distributionId: distributionId,
            record: record,
            context: context
        )
    }

    public func loadSenderKey(
        from sender: ProtocolAddress,
        distributionId: UUID,
        context: StoreContext
    ) throws -> SenderKeyRecord? {
        try senderKeys.loadSenderKey(
            from: sender,
            distributionId: distributionId,
            context: context
        )
    }
}
