// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalLogging
import SignalStorage

/// Group membership from live traffic (Desktop applies `GroupChange`
/// actions; server state fetch is a later milestone). Pure parsing lives
/// here; `MessageStore.persist` applies it revision-gated in the same
/// transaction as the message row.
public enum GroupStateService {
    private static let logger = Logger(subsystem: "groups", category: "membership")

    /// Membership delta for a group message: change actions plus the
    /// sender (who is necessarily a member). Nil when there is no usable
    /// change — the message still threads, it just updates nothing.
    /// Change signatures are NOT validated (deferred): actions arrive
    /// inside sealed sender-key-encrypted content from a member.
    public static func membership(
        masterKey: Data,
        revision: UInt32,
        senderAci: String,
        changeBytes: Data?
    ) -> GroupMembership? {
        guard masterKey.count == 32 else {
            return nil
        }
        guard let changeBytes, !changeBytes.isEmpty else {
            return GroupMembership(masterKey: masterKey, revision: revision, added: [], removed: [])
        }
        // `groupChange` carries a serialized GroupChange wrapper; the member
        // actions live in its `actions` field (Desktop groups.preload.ts),
        // not at the top level of the bytes.
        guard
            let change = try? SignalServiceProtos_GroupChange(serializedBytes: changeBytes),
            !change.actions.isEmpty,
            let actions = try? SignalServiceProtos_GroupChange.Actions(serializedBytes: change.actions)
        else {
            Self.logger.error("group change unparseable")
            return nil
        }
        let added = actions.addMembers.compactMap { uuidString($0.added.userID) }
        let removed = actions.deleteMembers.compactMap { uuidString($0.deletedUserID) }
        return GroupMembership(masterKey: masterKey, revision: revision, added: added, removed: removed)
    }

    private static func uuidString(_ bytes: Data) -> String? {
        guard bytes.count == 16 else {
            return nil
        }
        let b = [UInt8](bytes)
        return UUID(uuid: (
            b[0], b[1], b[2], b[3], b[4], b[5], b[6], b[7],
            b[8], b[9], b[10], b[11], b[12], b[13], b[14], b[15]
        )).uuidString.lowercased()
    }
}
