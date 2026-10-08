// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import GRDB

/// Terminal open-failure taxonomy with user-visible meaning. Lives here
/// (not in SignalApp) so no dependency cycle is needed: the app shell maps
/// these to UI in Phase 2 and must surface `.needsReLink` instead of
/// starting empty or crashing.
public enum DatabaseOpenError: Error, Equatable {
    /// Stored state is unusable (wrong key, damaged file): re-link to
    /// start over.
    case needsReLink
    /// Anything else: needs investigation, never silent recovery.
    case corruptStore
}

/// Maps `SignalDatabase.open` failures by SQLite result code (never by
/// message sniffing). Both wrong-key and garbage files surface as
/// `SQLITE_NOTADB` ("file is not a database file").
public func mapDatabaseOpenError(_ error: Error) -> DatabaseOpenError {
    if let dbError = error as? DatabaseError,
       dbError.resultCode == .SQLITE_NOTADB
    {
        return .needsReLink
    }
    return .corruptStore
}

/// True when another connection or process holds the database
/// (SQLITE_BUSY / SQLITE_LOCKED): a retry later can succeed.
public func isDatabaseBusy(_ error: Error) -> Bool {
    guard let dbError = error as? DatabaseError else {
        return false
    }
    return dbError.resultCode == .SQLITE_BUSY || dbError.resultCode == .SQLITE_LOCKED
        || dbError.extendedResultCode == .SQLITE_BUSY || dbError.extendedResultCode == .SQLITE_LOCKED
}
