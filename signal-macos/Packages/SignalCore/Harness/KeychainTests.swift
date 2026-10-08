// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp

private let keychainService = "spike-test-keychain"

func runKeychainTests() {
    let account = "spike-\(UUID().uuidString)"
    do {
        try KeychainStore.save(Data("secret".utf8), service: keychainService, account: account)
        let back = try KeychainStore.load(service: keychainService, account: account)
        try KeychainStore.save(Data("secret2".utf8), service: keychainService, account: account)
        let back2 = try KeychainStore.load(service: keychainService, account: account)
        try KeychainStore.delete(service: keychainService, account: account)
        let gone = try KeychainStore.load(service: keychainService, account: account)
        check(
            "MessagingTests.testKeychainRoundTrip",
            back == Data("secret".utf8) && back2 == Data("secret2".utf8) && gone == nil
        )
    } catch let error as KeychainError {
        switch error {
        case .denied:
            // Platform-gated skip: sandboxes and locked keychains refuse
            // Security API. Visible in output; real keychains run the test.
            print("SKIP MessagingTests.testKeychainRoundTrip (keychain denied: \(error))")
        case .notFound, .unexpected:
            check("MessagingTests.testKeychainRoundTrip", false, "\(error)")
        }
    } catch {
        check("MessagingTests.testKeychainRoundTrip", false, "\(error)")
    }
}
