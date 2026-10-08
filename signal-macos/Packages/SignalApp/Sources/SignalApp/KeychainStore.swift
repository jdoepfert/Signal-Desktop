// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import Security

public enum KeychainError: Error, Equatable {
    /// The keychain refused the operation (sandbox, missing entitlement,
    /// locked): callers fall back or skip, never crash.
    case denied(status: OSStatus)
    case notFound
    case unexpected(status: OSStatus)

    /// Statuses that mean "keychain unavailable here" rather than a bug.
    /// 100001 is the observed sandbox denial signature.
    static func denialStatuses() -> Set<OSStatus> {
        [-34018, -25293, -25291, 100001]
    }
}

/// SQLCipher-key storage: service/account-scoped generic-password items.
/// Upsert semantics on save; missing items read as nil (not an error).
public enum KeychainStore {
    public static func save(_ data: Data, service: String, account: String) throws {
        try delete(service: service, account: account)
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecValueData as String: data,
        ]
        let status = SecItemAdd(query as CFDictionary, nil)
        guard status == errSecSuccess else {
            throw denialOrUnexpected(status: status)
        }
    }

    public static func load(service: String, account: String) throws -> Data? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        switch status {
        case errSecSuccess:
            return item as? Data
        case errSecItemNotFound:
            return nil
        default:
            throw denialOrUnexpected(status: status)
        }
    }

    public static func delete(service: String, account: String) throws {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
        let status = SecItemDelete(query as CFDictionary)
        switch status {
        case errSecSuccess, errSecItemNotFound:
            return
        default:
            throw denialOrUnexpected(status: status)
        }
    }

    private static func denialOrUnexpected(status: OSStatus) -> KeychainError {
        if KeychainError.denialStatuses().contains(status) {
            return .denied(status: status)
        }
        return .unexpected(status: status)
    }
}
