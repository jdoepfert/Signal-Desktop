// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalStorage

/// Group membership from live traffic (Desktop applies `GroupChange`
/// actions; server state fetch is a later milestone). Pure parsing lives
/// here; `MessageStore.persist` applies it revision-gated in the same
/// transaction as the message row.
public enum GroupStateService {
    /// Membership sighting for a group message: master key + revision only.
    /// Message-carried `GroupChange` actions are untrusted (a removed
    /// member could re-add itself; a forged revision could freeze the
    /// roster), so they are never derived here. The sighting flags the
    /// group for a server refresh; the roster comes from fetched state.
    /// Nil when the master key is unusable — the message still threads,
    /// it just flags nothing.
    public static func membership(
        masterKey: Data,
        revision: UInt32
    ) -> GroupMembership? {
        guard masterKey.count == 32 else {
            return nil
        }
        return GroupMembership(masterKey: masterKey, revision: revision, added: [], removed: [])
    }
}
