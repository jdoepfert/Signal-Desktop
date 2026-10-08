// Copyright 2026 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only

import Foundation
import SignalCore
import UserNotifications

public enum NotificationDecision: Sendable, Equatable {
    case alert(title: String, body: String)
    case titleOnly(title: String)
    case silent
}

/// Pure alerting decision: muted conversations and globally-disabled
/// notifications stay silent; locked devices show the title only (never
/// message bodies).
public struct NotificationPolicy: Sendable {
    public var notificationsEnabled: Bool
    public var locked: Bool

    public init(notificationsEnabled: Bool = true, locked: Bool = false) {
        self.notificationsEnabled = notificationsEnabled
        self.locked = locked
    }

    public func decide(
        message: DecryptedMessage,
        displayName: String,
        muted: Bool
    ) -> NotificationDecision {
        guard notificationsEnabled, !muted else {
            return .silent
        }
        if locked {
            return .titleOnly(title: displayName)
        }
        return .alert(title: displayName, body: message.body)
    }
}

/// UserNotifications wiring: authorization on first link, delivery per
/// policy, tap opens the conversation. Alert delivery itself needs a
/// running app; the decision logic above carries the unit tests.
public final class Notifications: NSObject, @unchecked Sendable {
    public var onTap: (String) -> Void = { _ in }

    public override init() {
        super.init()
        UNUserNotificationCenter.current().delegate = self
    }

    public func requestAuthorization() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound])
    }

    public func deliver(_ decision: NotificationDecision, conversationId: String) async throws {
        let content = UNMutableNotificationContent()
        switch decision {
        case .alert(let title, let body):
            content.title = title
            content.body = body
        case .titleOnly(let title):
            content.title = title
        case .silent:
            return
        }
        let request = UNNotificationRequest(
            identifier: conversationId,
            content: content,
            trigger: nil
        )
        try await UNUserNotificationCenter.current().add(request)
    }
}

extension Notifications: UNUserNotificationCenterDelegate {
    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        onTap(response.notification.request.identifier)
    }

    public func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .list, .sound]
    }
}
