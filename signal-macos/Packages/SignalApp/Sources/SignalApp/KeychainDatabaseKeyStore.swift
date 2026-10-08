// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalMessaging

/// Keychain-backed `DatabaseKeyStore`: the SQLCipher passphrase lives in a
/// generic-password item scoped by environment.
struct KeychainDatabaseKeyStore: DatabaseKeyStore {
    static let service = "org.signal.signal-mac"

    let account: String

    func loadKey() throws -> String? {
        do {
            guard let data = try KeychainStore.load(service: Self.service, account: account) else {
                return nil
            }
            return String(data: data, encoding: .utf8)
        } catch KeychainError.denied {
            // The user answered Deny on the keychain prompt (or the
            // keychain is locked): a retryable launch failure.
            throw DatabaseKeyStoreError.accessDenied
        }
    }

    func saveKey(_ key: String) throws {
        try KeychainStore.save(Data(key.utf8), service: Self.service, account: account)
    }

    func deleteKey() throws {
        try KeychainStore.delete(service: Self.service, account: account)
    }
}
