// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalApp
import SignalCore

func runNotificationTests() {
    let message = DecryptedMessage(senderAci: "a", body: "hi", timestamp: 1)
    let policy = NotificationPolicy(notificationsEnabled: true, locked: false)
    check(
        "MessagingTests.testNotificationAlert",
        policy.decide(message: message, displayName: "Alice", muted: false)
            == .alert(title: "Alice", body: "hi")
    )
    check(
        "MessagingTests.testNotificationMuted",
        policy.decide(message: message, displayName: "Alice", muted: true) == .silent
    )
    let off = NotificationPolicy(notificationsEnabled: false, locked: false)
    check(
        "MessagingTests.testNotificationGlobalOff",
        off.decide(message: message, displayName: "Alice", muted: false) == .silent
    )
    let locked = NotificationPolicy(notificationsEnabled: true, locked: true)
    check(
        "MessagingTests.testNotificationLocked",
        locked.decide(message: message, displayName: "Alice", muted: false)
            == .titleOnly(title: "Alice")
    )
}
